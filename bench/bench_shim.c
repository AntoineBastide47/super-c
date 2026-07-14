/* Implementations for bench_shim.h -- compiled automatically as the same-stem sibling of
   bench_shim.spc (see src/driver_shim.spc for the mechanism). */

#if defined(__APPLE__)
/* The build compiles C with -D_POSIX_C_SOURCE=200809L; strict POSIX on Darwin hides ru_maxrss and
   breaks <sys/sysctl.h> (u_int). _DARWIN_C_SOURCE restores the full API level (same landmine as the
   test runner's sysctl note in src/driver/test.spc). */
#define _DARWIN_C_SOURCE 1
#elif defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L /* open_memstream + getrusage under any -std strictness */
#endif

#include "bench_shim.h"

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define PSAPI_VERSION 2 /* GetProcessMemoryInfo resolves to K32... in kernel32: no -lpsapi needed */
#include <windows.h>
#include <psapi.h>

long long sc_peak_rss(void) {
  PROCESS_MEMORY_COUNTERS pmc;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) return 0;
  return (long long)pmc.PeakWorkingSetSize;
}

long long sc_cpu_cycles(void) {
  ULONG64 c = 0;
  QueryProcessCycleTime(GetCurrentProcess(), &c);
  return (long long)c;
}

int sc_cpu_model(char *buf, size_t cap) {
  DWORD len = (DWORD)cap; /* RegGetValueA nul-terminates and fails cleanly on overflow */
  if (RegGetValueA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                   "ProcessorNameString", RRF_RT_REG_SZ, NULL, buf, &len) != ERROR_SUCCESS)
    return -1;
  return 0;
}

void *sc_memstream_open(char **buf, size_t *size) {
  (void)buf;
  (void)size;
  return NULL; /* no open_memstream on Windows; callers are @platform-gated away */
}

/* No malloc shadowing on Windows: there is no safe "real malloc" to forward to across CRTs. */
long long sc_alloc_count(void) { return 0; }
long long sc_alloc_bytes(void) { return 0; }

#else /* POSIX */

#include <stdio.h>
#include <sys/resource.h>

/* Allocation counting: this TU defines the malloc family, and at static link every OTHER object of
   the binary binds its malloc/realloc/... references here (object files win over shared libc), so
   the compiler's own allocations are counted; libc-internal ones are not. Forwarding goes to the
   real allocator (zone API on macOS, __libc_* on glibc), so pointers stay freely mixable with
   libc-allocated memory in both directions. Bench is single-threaded -- plain counters. */
static unsigned long long g_alloc_count = 0;
static unsigned long long g_alloc_bytes = 0;
long long sc_alloc_count(void) { return (long long)g_alloc_count; }
long long sc_alloc_bytes(void) { return (long long)g_alloc_bytes; }

long long sc_peak_rss(void) {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
#if defined(__APPLE__)
  return (long long)ru.ru_maxrss; /* bytes */
#else
  return (long long)ru.ru_maxrss * 1024LL; /* KiB */
#endif
}

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <libproc.h>
#include <unistd.h>
int sc_cpu_model(char *buf, size_t cap) {
  size_t l = cap;
  if (sysctlbyname("machdep.cpu.brand_string", buf, &l, NULL, 0) != 0) return -1;
  return 0;
}
/* Same source as `time -l`'s "cycles elapsed": unprivileged, per-process, all threads. */
long long sc_cpu_cycles(void) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
  return (long long)ri.ri_cycles;
}

#include <malloc/malloc.h>
void *malloc(size_t n) {
  g_alloc_count++;
  g_alloc_bytes += n;
  return malloc_zone_malloc(malloc_default_zone(), n);
}
void *calloc(size_t c, size_t n) {
  g_alloc_count++;
  g_alloc_bytes += c * n;
  return malloc_zone_calloc(malloc_default_zone(), c, n);
}
void *realloc(void *p, size_t n) {
  malloc_zone_t *z = p ? malloc_zone_from_ptr(p) : NULL;
  g_alloc_count++;
  g_alloc_bytes += n;
  return malloc_zone_realloc(z ? z : malloc_default_zone(), p, n);
}
void free(void *p) {
  if (p) malloc_zone_free(malloc_zone_from_ptr(p), p);
}
#else
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>
/* PERF_COUNT_HW_CPU_CYCLES scoped to this process, user-space only (exclude_kernel lets it work at
   perf_event_paranoid<=2, the common default). Unavailable (containers, paranoid=3, no PMU) -> 0. */
long long sc_cpu_cycles(void) {
  static int fd = -2; /* -2 = not yet opened; bench is single-threaded */
  if (fd == -2) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof pe);
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof pe;
    pe.config = PERF_COUNT_HW_CPU_CYCLES;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    fd = (int)syscall(__NR_perf_event_open, &pe, 0, -1, -1, 0);
  }
  long long v = 0;
  if (fd < 0 || read(fd, &v, sizeof v) != (ssize_t)sizeof v) return 0;
  return v;
}
#if defined(__GLIBC__)
extern void *__libc_malloc(size_t n);
extern void *__libc_calloc(size_t c, size_t n);
extern void *__libc_realloc(void *p, size_t n);
extern void __libc_free(void *p);
void *malloc(size_t n) {
  g_alloc_count++;
  g_alloc_bytes += n;
  return __libc_malloc(n);
}
void *calloc(size_t c, size_t n) {
  g_alloc_count++;
  g_alloc_bytes += c * n;
  return __libc_calloc(c, n);
}
void *realloc(void *p, size_t n) {
  g_alloc_count++;
  g_alloc_bytes += n;
  return __libc_realloc(p, n);
}
void free(void *p) { __libc_free(p); }
#endif

int sc_cpu_model(char *buf, size_t cap) {
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

void *sc_memstream_open(char **buf, size_t *size) {
  return open_memstream(buf, size);
}

#endif
