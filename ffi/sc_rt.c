/* Portable implementation of the concurrency substrate declared in sc_rt.h. The build engine compiles
   every .c in the generated tree, and this file is auto-discovered as the backing source of sc_rt.h.
   POSIX and Windows are selected with the preprocessor so a single #include per platform pulls the right
   code; the Super-C side never sees the difference. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include "sc_rt.h"
#include <stdlib.h>
#include <string.h>

/* ---- current-coroutine TLS: one C11 thread-local void* per OS thread ------------------------------- */
static _Thread_local void *sc_rt_tls_slot = 0;
void sc_rt_tls_set(void *p) { sc_rt_tls_slot = p; }
void *sc_rt_tls_get(void) { return sc_rt_tls_slot; }

#ifdef _WIN32
/* ================================ Windows ========================================================== */
#include <windows.h>

uint64_t sc_rt_now_ns(void) {
  static LARGE_INTEGER freq;
  LARGE_INTEGER c;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&c);
  /* scale to ns without overflowing: (ticks / freq) seconds -> ns */
  return (uint64_t)((double)c.QuadPart * 1e9 / (double)freq.QuadPart);
}

size_t sc_rt_ncpu(void) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return si.dwNumberOfProcessors ? (size_t)si.dwNumberOfProcessors : 1;
}

/* WaitOnAddress-based parking (Win8+, in kernel32 via API set; no extra -l with MinGW's default libs). */
void sc_rt_park(int32_t *word, int32_t expected, int64_t timeout_ns) {
  int32_t cmp = expected;
  DWORD ms = timeout_ns < 0 ? INFINITE : (DWORD)(timeout_ns / 1000000);
  WaitOnAddress(word, &cmp, sizeof(cmp), ms);
}
void sc_rt_unpark_one(int32_t *word) { WakeByAddressSingle(word); }
void sc_rt_unpark_all(int32_t *word) { WakeByAddressAll(word); }

void *sc_rt_stack_alloc(size_t size) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  size_t pg = si.dwPageSize;
  size_t total = size + pg;
  char *m = (char *)VirtualAlloc(0, total, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (!m) return 0;
  DWORD old;
  VirtualProtect(m, pg, PAGE_NOACCESS, &old); /* guard page at the low end */
  return m + pg;
}
void sc_rt_stack_free(void *usable, size_t size) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  (void)size;
  VirtualFree((char *)usable - si.dwPageSize, 0, MEM_RELEASE);
}

/* Fibers. The context is the fiber handle plus the entry closure; the root context converts the current
   thread to a fiber on first use. */
typedef struct {
  void *fiber;
  int is_root;
  void (*entry)(void *);
  void *arg;
} sc_rt_ctx_win;

static void CALLBACK sc_rt_fiber_entry(void *p) {
  sc_rt_ctx_win *c = (sc_rt_ctx_win *)p;
  c->entry(c->arg);
}

void *sc_rt_ctx_alloc(void) { return calloc(1, sizeof(sc_rt_ctx_win)); }

void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg) {
  sc_rt_ctx_win *c = (sc_rt_ctx_win *)ctx;
  (void)stack; /* fibers own their stacks */
  c->entry = entry;
  c->arg = arg;
  c->fiber = CreateFiber(size, sc_rt_fiber_entry, c);
}

void sc_rt_ctx_switch(void *from, void *to) {
  sc_rt_ctx_win *f = (sc_rt_ctx_win *)from;
  sc_rt_ctx_win *t = (sc_rt_ctx_win *)to;
  if (!f->fiber) { /* first switch away from a thread: become a fiber */
    f->fiber = ConvertThreadToFiber(0);
    f->is_root = 1;
  }
  SwitchToFiber(t->fiber);
}

void sc_rt_ctx_free(void *ctx) {
  sc_rt_ctx_win *c = (sc_rt_ctx_win *)ctx;
  if (c->fiber && !c->is_root) DeleteFiber(c->fiber);
  free(c);
}

#else
/* ================================ POSIX ============================================================ */
#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wdeprecated-declarations" /* ucontext is deprecated on macOS but works */
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
#include <ucontext.h>

uint64_t sc_rt_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

size_t sc_rt_ncpu(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (size_t)n : 1;
}

/* Parking lot: a fixed set of (mutex, cond) buckets keyed by address hash. Broadcasting on unpark wakes
   every waiter in the bucket; each re-checks its own word and re-parks if it was not the target. This is
   the portable POSIX path (no futex / no private macOS ulock syscalls). */
#define SC_RT_BUCKETS 64
static struct {
  pthread_mutex_t m;
  pthread_cond_t cv;
} sc_rt_lot[SC_RT_BUCKETS] = {[0 ... SC_RT_BUCKETS - 1] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER}};

static unsigned sc_rt_bucket(void *addr) { return (unsigned)(((uintptr_t)addr >> 4) & (SC_RT_BUCKETS - 1)); }

void sc_rt_park(int32_t *word, int32_t expected, int64_t timeout_ns) {
  unsigned b = sc_rt_bucket(word);
  pthread_mutex_lock(&sc_rt_lot[b].m);
  if (__atomic_load_n(word, __ATOMIC_ACQUIRE) == expected) {
    if (timeout_ns < 0) {
      pthread_cond_wait(&sc_rt_lot[b].cv, &sc_rt_lot[b].m);
    } else {
      struct timespec ts;
      clock_gettime(CLOCK_REALTIME, &ts);
      int64_t ns = ts.tv_nsec + timeout_ns % 1000000000ll;
      ts.tv_sec += (time_t)(timeout_ns / 1000000000ll + ns / 1000000000ll);
      ts.tv_nsec = (long)(ns % 1000000000ll);
      pthread_cond_timedwait(&sc_rt_lot[b].cv, &sc_rt_lot[b].m, &ts);
    }
  }
  pthread_mutex_unlock(&sc_rt_lot[b].m);
}

static void sc_rt_wake(int32_t *word, int all) {
  unsigned b = sc_rt_bucket(word);
  pthread_mutex_lock(&sc_rt_lot[b].m);
  if (all)
    pthread_cond_broadcast(&sc_rt_lot[b].cv);
  else
    pthread_cond_broadcast(&sc_rt_lot[b].cv); /* buckets are shared, so a targeted wake still broadcasts */
  pthread_mutex_unlock(&sc_rt_lot[b].m);
}
void sc_rt_unpark_one(int32_t *word) { sc_rt_wake(word, 0); }
void sc_rt_unpark_all(int32_t *word) { sc_rt_wake(word, 1); }

void *sc_rt_stack_alloc(size_t size) {
  long pg = sysconf(_SC_PAGESIZE);
  size_t total = size + (size_t)pg;
  void *m = mmap(0, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (m == MAP_FAILED) return 0;
  mprotect(m, (size_t)pg, PROT_NONE); /* guard page below the usable region */
  return (char *)m + pg;
}
void sc_rt_stack_free(void *usable, size_t size) {
  long pg = sysconf(_SC_PAGESIZE);
  munmap((char *)usable - pg, size + (size_t)pg);
}

/* ucontext-based switch. makecontext passes only int args, so the ctx pointer is split into two halves and
   reassembled in the trampoline. */
typedef struct {
  ucontext_t uc;
  void (*entry)(void *);
  void *arg;
} sc_rt_ctx_posix;

static void sc_rt_uc_tramp(unsigned hi, unsigned lo) {
  sc_rt_ctx_posix *c = (sc_rt_ctx_posix *)(((uintptr_t)hi << 32) | (uintptr_t)lo);
  c->entry(c->arg);
}

void *sc_rt_ctx_alloc(void) { return calloc(1, sizeof(sc_rt_ctx_posix)); }

void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg) {
  sc_rt_ctx_posix *c = (sc_rt_ctx_posix *)ctx;
  c->entry = entry;
  c->arg = arg;
  getcontext(&c->uc);
  c->uc.uc_stack.ss_sp = stack;
  c->uc.uc_stack.ss_size = size;
  c->uc.uc_link = 0;
  uintptr_t p = (uintptr_t)c;
  makecontext(&c->uc, (void (*)(void))sc_rt_uc_tramp, 2, (unsigned)(p >> 32), (unsigned)(p & 0xffffffffu));
}

void sc_rt_ctx_switch(void *from, void *to) {
  swapcontext(&((sc_rt_ctx_posix *)from)->uc, &((sc_rt_ctx_posix *)to)->uc);
}

void sc_rt_ctx_free(void *ctx) { free(ctx); }

#endif
