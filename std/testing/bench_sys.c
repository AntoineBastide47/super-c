/* Implementations for bench_sys.h -- compiled automatically as the same-stem sibling of the header (see
   src/driver_shim.spc for the mechanism). */

#if defined(__APPLE__)
/* The build compiles C with -D_POSIX_C_SOURCE=200809L; strict POSIX on Darwin breaks <sys/sysctl.h>
   (u_int). _DARWIN_C_SOURCE restores the full API level (same landmine as the test runner's sysctl
   note in src/driver/test.spc). */
#define _DARWIN_C_SOURCE 1
#elif defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1 /* perf_event_open, gettid and friends under any -std strictness */
#endif

#include "bench_sys.h"

#include <stdio.h>
#include <string.h>

/* ---- the optimisation barrier ------------------------------------------------------------------------- */
static volatile unsigned long long sc_bs_sink_cell;
void sc_bs_sink(unsigned long long v) { sc_bs_sink_cell = v; }
unsigned long long sc_bs_sunk(void) { return sc_bs_sink_cell; }

/* ---- identity ------------------------------------------------------------------------------------------ */
const char *sc_bs_os(void) {
#if defined(_WIN32)
  return "windows";
#elif defined(__APPLE__)
  return "macos";
#elif defined(__linux__)
  return "linux";
#elif defined(__wasm__)
  return "wasm";
#else
  return "posix";
#endif
}
const char *sc_bs_arch(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
  return "aarch64";
#elif defined(__x86_64__) || defined(_M_X64)
  return "x86_64";
#elif defined(__wasm32__)
  return "wasm32";
#else
  return "unknown";
#endif
}

/* ---- allocation accounting (see the header for what is counted) ------------------------------------- */
/* Counted only where this file can interpose malloc and forward to the real allocator: macOS (zone API)
   and glibc (__libc_*). Everywhere else (Windows, wasm, other libcs) the counters stay at zero and
   `supported` says so. */
#if !defined(__APPLE__) && !defined(__GLIBC__)
int sc_bs_alloc_supported(void) { return 0; }
void sc_bs_alloc_enable(int on) { (void)on; }
int sc_bs_alloc_enabled(void) { return 0; }
void sc_bs_alloc_snapshot(long long out[4]) { out[0] = out[1] = out[2] = out[3] = 0; }
long long sc_bs_alloc_calls(void) { return 0; }
long long sc_bs_alloc_bytes(void) { return 0; }
#else
typedef struct {
  unsigned long long calls;
  unsigned long long bytes;
  int shared; /* the overflow line: updated with atomic read-modify-writes */
} __attribute__((aligned(64))) sc_bs_acct;
static sc_bs_acct sc_bs_lines[SC_BS_ACCT_THREADS];
static sc_bs_acct sc_bs_over = {0, 0, 1};
static unsigned sc_bs_line_n = 0; /* lines handed out (atomic) */
static int sc_bs_on = 0;           /* accounting switch (atomic) */
static _Thread_local sc_bs_acct *sc_bs_mine = 0;

int sc_bs_alloc_supported(void) { return 1; }
void sc_bs_alloc_enable(int on) { __atomic_store_n(&sc_bs_on, on != 0, __ATOMIC_RELAXED); }
int sc_bs_alloc_enabled(void) { return __atomic_load_n(&sc_bs_on, __ATOMIC_RELAXED); }

static inline void sc_bs_note(size_t n) {
  if (!__atomic_load_n(&sc_bs_on, __ATOMIC_RELAXED)) return;
  sc_bs_acct *a = sc_bs_mine;
  if (!a) {
    unsigned i = __atomic_fetch_add(&sc_bs_line_n, 1u, __ATOMIC_RELAXED);
    a = i < SC_BS_ACCT_THREADS ? &sc_bs_lines[i] : &sc_bs_over;
    sc_bs_mine = a;
  }
  if (a->shared) {
    __atomic_fetch_add(&a->calls, 1ull, __ATOMIC_RELAXED);
    __atomic_fetch_add(&a->bytes, (unsigned long long)n, __ATOMIC_RELAXED);
    return;
  }
  /* Owner-only lines: a relaxed load/store pair is a plain load and store on every target, and defined
     against the snapshot's concurrent relaxed loads. Bytes first, so a snapshot that sees the new call
     count also sees its bytes. */
  __atomic_store_n(&a->bytes, __atomic_load_n(&a->bytes, __ATOMIC_RELAXED) + (unsigned long long)n, __ATOMIC_RELAXED);
  __atomic_store_n(&a->calls, __atomic_load_n(&a->calls, __ATOMIC_RELAXED) + 1ull, __ATOMIC_RELAXED);
}

void sc_bs_alloc_snapshot(long long out[4]) {
  unsigned n = __atomic_load_n(&sc_bs_line_n, __ATOMIC_RELAXED);
  unsigned k = n < SC_BS_ACCT_THREADS ? n : SC_BS_ACCT_THREADS;
  unsigned long long calls = __atomic_load_n(&sc_bs_over.calls, __ATOMIC_RELAXED);
  unsigned long long bytes = __atomic_load_n(&sc_bs_over.bytes, __ATOMIC_RELAXED);
  for (unsigned i = 0; i < k; i++) {
    calls += __atomic_load_n(&sc_bs_lines[i].calls, __ATOMIC_RELAXED);
    bytes += __atomic_load_n(&sc_bs_lines[i].bytes, __ATOMIC_RELAXED);
  }
  out[0] = (long long)calls;
  out[1] = (long long)bytes;
  out[2] = (long long)n;
  out[3] = n > SC_BS_ACCT_THREADS;
}
long long sc_bs_alloc_calls(void) {
  long long v[4];
  sc_bs_alloc_snapshot(v);
  return v[0];
}
long long sc_bs_alloc_bytes(void) {
  long long v[4];
  sc_bs_alloc_snapshot(v);
  return v[1];
}

/* This TU defines the malloc family, and at static link every other object of the binary binds its
   malloc/realloc/... references here (object files win over shared libc). Forwarding goes to the real
   allocator (zone API on macOS, __libc_* on glibc), so pointers stay freely mixable with libc-allocated
   memory in both directions. */
#if defined(__APPLE__)
#include <malloc/malloc.h>
/* The default zone, cached on first use and called through its own entry points: the zone API's
   wrappers (`malloc_zone_malloc` and friends) add validation and a second zone lookup that cost about
   3 ns per call on top of the 19 ns allocation itself (measured on an M3 Max); the zone's function table
   is the public contract of <malloc/malloc.h>, and the default zone never changes once the process
   has allocated. `free` and `realloc` still find the zone of the pointer they are given, so memory from
   any zone stays freely mixable. */
static malloc_zone_t *sc_bs_zone0;
static inline malloc_zone_t *sc_bs_zone(void) {
  malloc_zone_t *z = __atomic_load_n(&sc_bs_zone0, __ATOMIC_RELAXED);
  if (!z) {
    z = malloc_default_zone();
    __atomic_store_n(&sc_bs_zone0, z, __ATOMIC_RELAXED);
  }
  return z;
}
void *malloc(size_t n) {
  sc_bs_note(n);
  malloc_zone_t *z = sc_bs_zone();
  return z->malloc(z, n);
}
void *calloc(size_t c, size_t n) {
  sc_bs_note(c * n);
  malloc_zone_t *z = sc_bs_zone();
  return z->calloc(z, c, n);
}
void *realloc(void *p, size_t n) {
  sc_bs_note(n);
  malloc_zone_t *z = p ? malloc_zone_from_ptr(p) : NULL;
  if (!z) z = sc_bs_zone();
  return z->realloc(z, p, n);
}
void free(void *p) {
  if (!p) return;
  malloc_zone_t *z = malloc_zone_from_ptr(p);
  if (z) z->free(z, p);
}
#elif defined(__GLIBC__)
extern void *__libc_malloc(size_t n);
extern void *__libc_calloc(size_t c, size_t n);
extern void *__libc_realloc(void *p, size_t n);
extern void __libc_free(void *p);
void *malloc(size_t n) {
  sc_bs_note(n);
  return __libc_malloc(n);
}
void *calloc(size_t c, size_t n) {
  sc_bs_note(c * n);
  return __libc_calloc(c, n);
}
void *realloc(void *p, size_t n) {
  sc_bs_note(n);
  return __libc_realloc(p, n);
}
void free(void *p) { __libc_free(p); }
#endif
#endif

void sc_bs_flush(void) { fflush(NULL); }

/* ---- platform arms ------------------------------------------------------------------------------------ */
#if defined(_WIN32)

long long sc_bs_fork(void) { return -1; }
int sc_bs_wait(long long pid) {
  (void)pid;
  return -1;
}

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>

/* All threads of the process, user and kernel mode alike. */
long long sc_bs_cycles(void) {
  ULONG64 c = 0;
  if (!QueryProcessCycleTime(GetCurrentProcess(), &c)) return 0;
  return (long long)c;
}
int sc_bs_cycles_scope(void) { return SC_BS_CYC_ALL | SC_BS_CYC_KERNEL | SC_BS_CYC_EXISTING; }
long long sc_bs_cpu_ns(void) {
  FILETIME c, e, k, u;
  if (!GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) return -1;
  ULARGE_INTEGER ku, uu;
  ku.LowPart = k.dwLowDateTime;
  ku.HighPart = k.dwHighDateTime;
  uu.LowPart = u.dwLowDateTime;
  uu.HighPart = u.dwHighDateTime;
  return (long long)((ku.QuadPart + uu.QuadPart) * 100ull);
}
long long sc_bs_rss_peak(void) {
  PROCESS_MEMORY_COUNTERS pmc;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) return -1;
  return (long long)pmc.PeakWorkingSetSize;
}
long long sc_bs_rss_now(void) {
  PROCESS_MEMORY_COUNTERS pmc;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) return -1;
  return (long long)pmc.WorkingSetSize;
}
int sc_bs_cpu_model(char *buf, size_t cap) {
  DWORD len = (DWORD)cap; /* RegGetValueA nul-terminates and fails cleanly on overflow */
  if (RegGetValueA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                   "ProcessorNameString", RRF_RT_REG_SZ, NULL, buf, &len) != ERROR_SUCCESS)
    return -1;
  return 0;
}

#elif defined(__wasm__)

#include <time.h>
long long sc_bs_fork(void) { return -1; }
int sc_bs_wait(long long pid) {
  (void)pid;
  return -1;
}
long long sc_bs_cycles(void) { return 0; }
int sc_bs_cycles_scope(void) { return 0; }
long long sc_bs_cpu_ns(void) { return (long long)((double)clock() * (1e9 / (double)CLOCKS_PER_SEC)); }
long long sc_bs_rss_peak(void) { return -1; }
long long sc_bs_rss_now(void) { return -1; }
int sc_bs_cpu_model(char *buf, size_t cap) {
  (void)buf;
  (void)cap;
  return -1;
}

#else /* POSIX */

#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static void sc_bs_child_reset(void);
long long sc_bs_fork(void) {
  pid_t pid = fork();
  if (pid == 0) sc_bs_child_reset();
  return (long long)pid;
}
int sc_bs_wait(long long pid) {
  int st = 0;
  if (waitpid((pid_t)pid, &st, 0) != (pid_t)pid) return -1;
  if (WIFEXITED(st)) return WEXITSTATUS(st);
  if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
  return -1;
}

long long sc_bs_cpu_ns(void) {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
  return ((long long)ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000000ll +
         ((long long)ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000ll;
}
long long sc_bs_rss_peak(void) {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
#if defined(__APPLE__)
  return (long long)ru.ru_maxrss; /* bytes */
#else
  return (long long)ru.ru_maxrss * 1024ll; /* KiB */
#endif
}

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <libproc.h>
int sc_bs_cpu_model(char *buf, size_t cap) {
  size_t l = cap;
  if (sysctlbyname("machdep.cpu.brand_string", buf, &l, NULL, 0) != 0) return -1;
  return 0;
}
/* Same source as `time -l`'s "cycles elapsed": unprivileged, per process, every thread, user and kernel
   mode (measured: a syscall-bound loop reports cycles/(user+system time) at the core clock and
   cycles/user time far above it). */
static long long sc_bs_mac_cycles(void) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
  return (long long)ri.ri_cycles;
}
long long sc_bs_cycles(void) {
  long long c = sc_bs_mac_cycles();
  return c < 0 ? 0 : c;
}
/* A virtual machine (the hosted CI runners among them) answers the call successfully with a counter that
   does not move. Availability therefore means the counter advanced by at least one cycle per step of a
   dependent multiply chain (the physical minimum; a real core spends three to four), decided once per
   process; a counter that stays put or under-counts is reported as unavailable, never as zero work. */
static int sc_bs_mac_scope = -1;
int sc_bs_cycles_scope(void) {
  int s = __atomic_load_n(&sc_bs_mac_scope, __ATOMIC_ACQUIRE);
  if (s >= 0) return s;
  long long c0 = sc_bs_mac_cycles();
  s = 0;
  if (c0 >= 0) {
    const int steps = 200000;
    volatile unsigned long long x = 1;
    for (int i = 0; i < steps; i++) x = x * 6364136223846793005ull + (unsigned long long)i;
    long long c1 = sc_bs_mac_cycles();
    if (c1 - c0 >= (long long)steps) s = SC_BS_CYC_ALL | SC_BS_CYC_KERNEL | SC_BS_CYC_EXISTING;
  }
  __atomic_store_n(&sc_bs_mac_scope, s, __ATOMIC_RELEASE);
  return s;
}
long long sc_bs_rss_now(void) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
  return (long long)ri.ri_resident_size;
}
/* The rusage counters read here are the calling process's own, so a forked child has nothing to reset. */
static void sc_bs_child_reset(void) {}
#else /* Linux and the rest of POSIX */
#include <dirent.h>
#include <stdlib.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/perf_event.h>
#include <errno.h>

/* PERF_COUNT_HW_CPU_CYCLES, one event per thread alive at the first call, each with `inherit` so every
   thread those threads create later is counted through its creator's event. Kernel-mode cycles are
   requested first and given up (exclude_kernel) when perf_event_paranoid forbids them. Unavailable
   (containers, paranoid=3, no PMU, more than SC_BS_MAX_EVENTS threads at the first call) -> scope 0. */
#define SC_BS_MAX_EVENTS 256
static int sc_bs_fds[SC_BS_MAX_EVENTS];
static int sc_bs_nfd = 0;
static int sc_bs_scope = -1; /* -1 = not yet opened */

static int sc_bs_open_one(long tid, int exclude_kernel) {
  struct perf_event_attr pe;
  memset(&pe, 0, sizeof pe);
  pe.type = PERF_TYPE_HARDWARE;
  pe.size = sizeof pe;
  pe.config = PERF_COUNT_HW_CPU_CYCLES;
  pe.inherit = 1;
  pe.exclude_kernel = exclude_kernel;
  pe.exclude_hv = 1;
  return (int)syscall(__NR_perf_event_open, &pe, (pid_t)tid, -1, -1, 0);
}
static void sc_bs_close_all(void) {
  for (int i = 0; i < sc_bs_nfd; i++) close(sc_bs_fds[i]);
  sc_bs_nfd = 0;
}
static void sc_bs_open(void) {
  int kernel = 1;
  int all_existing = 1;
  DIR *d = opendir("/proc/self/task");
  if (!d) {
    sc_bs_scope = 0;
    return;
  }
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
    long tid = strtol(e->d_name, NULL, 10);
    if (sc_bs_nfd >= SC_BS_MAX_EVENTS) {
      all_existing = 0;
      break;
    }
    int fd = sc_bs_open_one(tid, !kernel);
    if (fd < 0 && kernel && (errno == EACCES || errno == EPERM)) {
      kernel = 0; /* paranoid >= 2: user-space cycles only, for every event */
      sc_bs_close_all();
      closedir(d);
      d = opendir("/proc/self/task");
      if (!d) {
        sc_bs_scope = 0;
        return;
      }
      continue;
    }
    if (fd < 0) {
      sc_bs_close_all();
      closedir(d);
      sc_bs_scope = 0;
      return;
    }
    sc_bs_fds[sc_bs_nfd++] = fd;
  }
  closedir(d);
  if (sc_bs_nfd == 0) {
    sc_bs_scope = 0;
    return;
  }
  sc_bs_scope = SC_BS_CYC_ALL | (kernel ? SC_BS_CYC_KERNEL : 0) | (all_existing ? SC_BS_CYC_EXISTING : 0);
}
int sc_bs_cycles_scope(void) {
  if (sc_bs_scope < 0) sc_bs_open();
  return sc_bs_scope;
}
/* An inherited event counts the child only once the child exits, so a forked child drops the parent's
   events and opens its own on the next read. */
static void sc_bs_child_reset(void) {
  sc_bs_close_all();
  sc_bs_scope = -1;
}
long long sc_bs_cycles(void) {
  if (sc_bs_cycles_scope() == 0) return 0;
  long long total = 0;
  for (int i = 0; i < sc_bs_nfd; i++) {
    long long v = 0;
    if (read(sc_bs_fds[i], &v, sizeof v) != (ssize_t)sizeof v) return 0;
    total += v;
  }
  return total;
}
#else
static void sc_bs_child_reset(void) {}
long long sc_bs_cycles(void) { return 0; }
int sc_bs_cycles_scope(void) { return 0; }
#endif

long long sc_bs_rss_now(void) {
  FILE *f = fopen("/proc/self/statm", "rb");
  if (!f) return -1;
  unsigned long long size = 0, resident = 0;
  int n = fscanf(f, "%llu %llu", &size, &resident);
  fclose(f);
  if (n != 2) return -1;
  return (long long)resident * (long long)sysconf(_SC_PAGESIZE);
}

int sc_bs_cpu_model(char *buf, size_t cap) {
  FILE *f;
  char line[512];
  int ok = -1;
  if (cap == 0) return -1;
  f = fopen("/proc/cpuinfo", "rb");
  if (!f) return -1;
  while (fgets(line, sizeof line, f)) {
    /* "model name" is x86 convention; absent on some ARM kernels -> -1, caller prints "unknown" */
    if (strncmp(line, "model name", 10) == 0) {
      const char *c = strchr(line, ':');
      size_t n;
      if (!c) break;
      c++;
      while (*c == ' ' || *c == '\t') c++;
      n = strlen(c);
      while (n && (c[n - 1] == '\n' || c[n - 1] == '\r')) n--;
      if (n >= cap) n = cap - 1;
      memcpy(buf, c, n);
      buf[n] = 0;
      ok = 0;
      break;
    }
  }
  fclose(f);
  return ok;
}
#endif

#endif
