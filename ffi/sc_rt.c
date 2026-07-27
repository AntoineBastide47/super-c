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

/* ---- current worker index: -1 on any thread that is not a pool worker ------------------------------ */
static _Thread_local int32_t sc_rt_widx_slot = -1;
void sc_rt_widx_set(int32_t i) { sc_rt_widx_slot = i; }
int32_t sc_rt_widx_get(void) { return sc_rt_widx_slot; }

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

void sc_rt_sleep_ns(int64_t ns) {
  if (ns <= 0) return;
  Sleep((DWORD)(ns / 1000000)); /* millisecond granularity is all Sleep offers */
}

/* WaitOnAddress-based parking (Win8+). It lives in the synchronization API set, not kernel32's import
   library, so the Windows build links -lsynchronization (see ffi/sc_runtime.spc). */
void sc_rt_park(int32_t *word, int32_t expected, int64_t timeout_ns) {
  int32_t cmp = expected;
  DWORD ms = timeout_ns < 0 ? INFINITE : (DWORD)(timeout_ns / 1000000);
  WaitOnAddress(word, &cmp, sizeof(cmp), ms);
}
void sc_rt_unpark_one(int32_t *word) { WakeByAddressSingle(word); }
void sc_rt_unpark_all(int32_t *word) { WakeByAddressAll(word); }

/* A real stack, guarded like the POSIX one: reserve size + a page, commit the usable part read/write, and
   leave the low page PAGE_NOACCESS so an overflow faults instead of walking into whatever is below. It used
   to be reserved and never committed, because fibers brought their own stacks -- the x86-64 switch runs
   coroutines on THIS memory, so it has to be memory. Committed pages are still faulted in lazily, so the
   cost of a task that never touches its stack is unchanged. */
void *sc_rt_stack_alloc(size_t size) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  size_t pg = si.dwPageSize;
  char *m = (char *)VirtualAlloc(0, size + pg, MEM_RESERVE, PAGE_NOACCESS);
  if (!m) return 0;
  if (!VirtualAlloc(m + pg, size, MEM_COMMIT, PAGE_READWRITE)) {
    VirtualFree(m, 0, MEM_RELEASE);
    return 0;
  }
  return m + pg;
}
void sc_rt_stack_free(void *usable, size_t size) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  (void)size;
  VirtualFree((char *)usable - si.dwPageSize, 0, MEM_RELEASE);
}

/* Threads. `_beginthreadex` rather than CreateThread: the runtime allocates on worker threads, and this is
   the entry point that sets up (and tears down) the CRT's per-thread state. The pthread-shaped entry
   (`void *(*)(void *)`) is adapted here so the Super-C side needs no per-OS signature; the pair is heap
   allocated because __stdcall passes only the one argument. */
#include <process.h>

typedef struct {
  void *(*entry)(void *);
  void *arg;
} sc_rt_thr_win;

static unsigned __stdcall sc_rt_thread_tramp(void *p) {
  sc_rt_thr_win t = *(sc_rt_thr_win *)p;
  free(p);
  t.entry(t.arg);
  return 0;
}

int sc_rt_thread_create(void **out, void *(*entry)(void *), void *arg) {
  sc_rt_thr_win *t = (sc_rt_thr_win *)malloc(sizeof *t);
  if (!t) return -1;
  t->entry = entry;
  t->arg = arg;
  uintptr_t h = _beginthreadex(0, 0, sc_rt_thread_tramp, t, 0, 0);
  if (!h) {
    free(t);
    return -1;
  }
  *out = (void *)h;
  return 0;
}

int sc_rt_thread_join(void *handle) {
  if (!handle) return -1;
  WaitForSingleObject((HANDLE)handle, INFINITE);
  CloseHandle((HANDLE)handle);
  return 0;
}

/* SRWLOCK + CONDITION_VARIABLE: the pair Windows pairs natively (SleepConditionVariableSRW), both
   allocation-free to initialise and with no destroy call to make. */
void *sc_rt_mutex_new(void) {
  SRWLOCK *m = (SRWLOCK *)malloc(sizeof *m);
  if (m) InitializeSRWLock(m);
  return m;
}
void sc_rt_mutex_free(void *m) { free(m); }
void sc_rt_mutex_lock(void *m) { AcquireSRWLockExclusive((SRWLOCK *)m); }
void sc_rt_mutex_unlock(void *m) { ReleaseSRWLockExclusive((SRWLOCK *)m); }

void *sc_rt_cond_new(void) {
  CONDITION_VARIABLE *c = (CONDITION_VARIABLE *)malloc(sizeof *c);
  if (c) InitializeConditionVariable(c);
  return c;
}
void sc_rt_cond_free(void *c) { free(c); }
void sc_rt_cond_wait(void *c, void *m) {
  SleepConditionVariableSRW((CONDITION_VARIABLE *)c, (SRWLOCK *)m, INFINITE, 0);
}
int sc_rt_cond_timedwait_ns(void *c, void *m, int64_t rel_ns) {
  DWORD ms = rel_ns < 0 ? INFINITE : (DWORD)(rel_ns / 1000000);
  /* A sub-millisecond deadline must still be a deadline, not an indefinite wait. */
  if (rel_ns >= 0 && ms == 0) ms = 1;
  if (SleepConditionVariableSRW((CONDITION_VARIABLE *)c, (SRWLOCK *)m, ms, 0)) return 0;
  return GetLastError() == ERROR_TIMEOUT ? 1 : -1;
}
void sc_rt_cond_signal(void *c) { WakeConditionVariable((CONDITION_VARIABLE *)c); }
void sc_rt_cond_broadcast(void *c) { WakeAllConditionVariable((CONDITION_VARIABLE *)c); }

/* Fibers. The context is the fiber handle plus the entry closure; the root context converts the current
   thread to a fiber on first use. */
#if defined(__x86_64__)
/* Hand-written switch, same shape as the POSIX one below: a suspended context is one stack pointer, and the
   register state lives on the stack it belongs to. SwitchToFiber does the same job through the OS, at a few
   hundred nanoseconds and a fiber-owned stack we cannot guard ourselves.
   Win64 saves more than SysV: eight GPRs, xmm6-xmm15 (callee-saved here, unlike SysV where no xmm is), and
   three TEB fields. The TEB is the part that is easy to miss and impossible to skip -- __chkstk probes and
   the SEH unwinder both read the running thread's stack bounds from it, so a coroutine that leaves them
   pointing at the WORKER's stack faults the moment a function with a big frame runs on it. */
#define SC_ASM_FN(n) ".globl " n "\n.p2align 4\n" n ":\n"

/* 160 bytes of xmm + 64 of GPRs + 24 of TEB + 16 of padding. Sized so that sp stays 16-aligned through the
   frame (movaps demands it) and so the trampoline starts with a 16-aligned sp; the return address the
   trailing `ret` consumes sits just above, at +264. */
#define SC_CTX_FRAME 264
/* clang-format off */
__asm__(
  ".text\n"
  ".seh_proc sc_ctx_swap\n"
  SC_ASM_FN("sc_ctx_swap")
  "  subq $264, %rsp\n"
  "  .seh_stackalloc 264\n"
  "  movaps %xmm6,    0(%rsp)\n"
  "  movaps %xmm7,   16(%rsp)\n"
  "  movaps %xmm8,   32(%rsp)\n"
  "  movaps %xmm9,   48(%rsp)\n"
  "  movaps %xmm10,  64(%rsp)\n"
  "  movaps %xmm11,  80(%rsp)\n"
  "  movaps %xmm12,  96(%rsp)\n"
  "  movaps %xmm13, 112(%rsp)\n"
  "  movaps %xmm14, 128(%rsp)\n"
  "  movaps %xmm15, 144(%rsp)\n"
  "  .seh_savexmm %xmm6, 0\n    .seh_savexmm %xmm7, 16\n   .seh_savexmm %xmm8, 32\n"
  "  .seh_savexmm %xmm9, 48\n   .seh_savexmm %xmm10, 64\n  .seh_savexmm %xmm11, 80\n"
  "  .seh_savexmm %xmm12, 96\n  .seh_savexmm %xmm13, 112\n .seh_savexmm %xmm14, 128\n"
  "  .seh_savexmm %xmm15, 144\n"
  "  movq %rbx, 160(%rsp)\n"
  "  .seh_savereg %rbx, 160\n"
  "  movq %rbp, 168(%rsp)\n"
  "  .seh_savereg %rbp, 168\n"
  "  movq %rdi, 176(%rsp)\n"
  "  .seh_savereg %rdi, 176\n"
  "  movq %rsi, 184(%rsp)\n"
  "  .seh_savereg %rsi, 184\n"
  "  movq %r12, 192(%rsp)\n"
  "  .seh_savereg %r12, 192\n"
  "  movq %r13, 200(%rsp)\n"
  "  .seh_savereg %r13, 200\n"
  "  movq %r14, 208(%rsp)\n"
  "  .seh_savereg %r14, 208\n"
  "  movq %r15, 216(%rsp)\n"
  "  .seh_savereg %r15, 216\n"
  "  .seh_endprologue\n"
  "  movq %gs:0x08, %rax\n"   /* StackBase */
  "  movq %rax, 224(%rsp)\n"
  "  movq %gs:0x10, %rax\n"   /* StackLimit */
  "  movq %rax, 232(%rsp)\n"
  "  movq %gs:0x1478, %rax\n" /* DeallocationStack */
  "  movq %rax, 240(%rsp)\n"
  "  stmxcsr 248(%rsp)\n" /* MXCSR + x87 control word, in what was the alignment padding */
  "  fnstcw  252(%rsp)\n"
  "  movq %rsp, (%rcx)\n"
  "  movq %rdx, %rsp\n"
  "  ldmxcsr 248(%rsp)\n"
  "  fldcw   252(%rsp)\n"
  "  movq 224(%rsp), %rax\n"
  "  movq %rax, %gs:0x08\n"
  "  movq 232(%rsp), %rax\n"
  "  movq %rax, %gs:0x10\n"
  "  movq 240(%rsp), %rax\n"
  "  movq %rax, %gs:0x1478\n"
  "  movaps    0(%rsp), %xmm6\n"
  "  movaps   16(%rsp), %xmm7\n"
  "  movaps   32(%rsp), %xmm8\n"
  "  movaps   48(%rsp), %xmm9\n"
  "  movaps   64(%rsp), %xmm10\n"
  "  movaps   80(%rsp), %xmm11\n"
  "  movaps   96(%rsp), %xmm12\n"
  "  movaps  112(%rsp), %xmm13\n"
  "  movaps  128(%rsp), %xmm14\n"
  "  movaps  144(%rsp), %xmm15\n"
  "  movq 160(%rsp), %rbx\n"
  "  movq 168(%rsp), %rbp\n"
  "  movq 176(%rsp), %rdi\n"
  "  movq 184(%rsp), %rsi\n"
  "  movq 192(%rsp), %r12\n"
  "  movq 200(%rsp), %r13\n"
  "  movq 208(%rsp), %r14\n"
  "  movq 216(%rsp), %r15\n"
  "  addq $264, %rsp\n"
  "  ret\n"
  "  .seh_endproc\n"
  SC_ASM_FN("sc_ctx_entry")
  "  movq %r13, %rcx\n"
  "  subq $32, %rsp\n" /* shadow space: the callee owns it, and Win64 makes the CALLER provide it */
  "  callq *%r12\n"
  "  ud2\n"); /* the scheduler's trampoline switches away instead of returning; reaching here is a bug */
/* clang-format on */

extern void sc_ctx_swap(void **save_sp, void *to_sp);
extern void sc_ctx_entry(void);

typedef struct {
  void *sp; /* NULL until the first switch away from this context fills it in */
} sc_rt_ctx_asm;

/* A forged frame must carry a LEGAL FP control word. Zero is not one: on x86-64 it unmasks every SSE
   exception, so the first inexact multiply on a fresh coroutine would trap. Seed it from the thread that
   arms the context, which is the same state that thread would have handed over anyway. */
static void sc_ctx_save_fpctl(void *slot) {
#if defined(__x86_64__)
  unsigned char *p = (unsigned char *)slot;
  uint32_t mx = 0;
  uint16_t cw = 0;
  __asm__ volatile("stmxcsr %0" : "=m"(mx));
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  memcpy(p, &mx, sizeof mx);
  memcpy(p + 4, &cw, sizeof cw);
#else
  uint64_t fpcr = 0;
  __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
  memcpy(slot, &fpcr, sizeof fpcr);
#endif
}

void *sc_rt_ctx_alloc(void) { return calloc(1, sizeof(sc_rt_ctx_asm)); }

void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  uintptr_t base = (uintptr_t)stack;
  uintptr_t top = (base + size) & ~(uintptr_t)15;
  /* 8 above the frame for the return address, keeping the forged sp itself 16-aligned. */
  void **f = (void **)(top - SC_CTX_FRAME - 8);
  memset(f, 0, SC_CTX_FRAME + 8);
  sc_ctx_save_fpctl(&f[31]);    /* MXCSR + x87 control word */
  f[24] = (void *)entry;        /* r12 */
  f[25] = arg;                  /* r13 */
  f[28] = (void *)top;          /* StackBase: the high end this coroutine runs on */
  f[29] = (void *)base;         /* StackLimit: its lowest committed byte */
  f[30] = (void *)(base - si.dwPageSize); /* DeallocationStack: the reservation, guard page included */
  f[33] = (void *)sc_ctx_entry; /* the return address the trailing `ret` jumps to */
  ((sc_rt_ctx_asm *)ctx)->sp = f;
}

void sc_rt_ctx_switch(void *from, void *to) {
  sc_rt_ctx_asm *f = (sc_rt_ctx_asm *)from;
  sc_ctx_swap(&f->sp, ((sc_rt_ctx_asm *)to)->sp);
}

void sc_rt_ctx_free(void *ctx) { free(ctx); }

#else
/* Any other Windows ABI (arm64): fibers, which cost a call into the OS per switch but need no ABI of ours. */
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
#endif

#else
/* ================================ POSIX ============================================================ */
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

uint64_t sc_rt_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

size_t sc_rt_ncpu(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (size_t)n : 1;
}

void sc_rt_sleep_ns(int64_t ns) {
  if (ns <= 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)(ns / 1000000000ll);
  ts.tv_nsec = (long)(ns % 1000000000ll);
  while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
  } /* resume the remaining time after a signal */
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

/* Threads and their locks. The handle is a heap `pthread_t` rather than a cast: `pthread_t` is opaque and
   need not fit a pointer. Freed by the join that consumes it. */
int sc_rt_thread_create(void **out, void *(*entry)(void *), void *arg) {
  pthread_t *h = (pthread_t *)malloc(sizeof *h);
  if (!h) return -1;
  int rc = pthread_create(h, 0, entry, arg);
  if (rc != 0) {
    free(h);
    return rc;
  }
  *out = h;
  return 0;
}

int sc_rt_thread_join(void *handle) {
  if (!handle) return -1;
  void *ret = 0;
  int rc = pthread_join(*(pthread_t *)handle, &ret);
  free(handle);
  return rc;
}

void *sc_rt_mutex_new(void) {
  pthread_mutex_t *m = (pthread_mutex_t *)malloc(sizeof *m);
  if (m) pthread_mutex_init(m, 0);
  return m;
}
void sc_rt_mutex_free(void *p) {
  pthread_mutex_t *m = (pthread_mutex_t *)p;
  if (m) {
    pthread_mutex_destroy(m);
    free(m);
  }
}
void sc_rt_mutex_lock(void *m) { pthread_mutex_lock((pthread_mutex_t *)m); }
void sc_rt_mutex_unlock(void *m) { pthread_mutex_unlock((pthread_mutex_t *)m); }

void *sc_rt_cond_new(void) {
  pthread_cond_t *c = (pthread_cond_t *)malloc(sizeof *c);
  if (c) pthread_cond_init(c, 0);
  return c;
}
void sc_rt_cond_free(void *p) {
  pthread_cond_t *c = (pthread_cond_t *)p;
  if (c) {
    pthread_cond_destroy(c);
    free(c);
  }
}
void sc_rt_cond_wait(void *c, void *m) { pthread_cond_wait((pthread_cond_t *)c, (pthread_mutex_t *)m); }

int sc_rt_cond_timedwait_ns(void *cp, void *mp, int64_t rel_ns) {
  pthread_cond_t *c = (pthread_cond_t *)cp;
  pthread_mutex_t *m = (pthread_mutex_t *)mp;
  if (rel_ns < 0) return pthread_cond_wait(c, m);
  /* pthread_cond_timedwait takes an ABSOLUTE deadline on the cond's clock (realtime by default). */
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  int64_t ns = (int64_t)ts.tv_nsec + rel_ns % 1000000000ll;
  ts.tv_sec += (time_t)(rel_ns / 1000000000ll + ns / 1000000000ll);
  ts.tv_nsec = (long)(ns % 1000000000ll);
  return pthread_cond_timedwait(c, m, &ts);
}
void sc_rt_cond_signal(void *c) { pthread_cond_signal((pthread_cond_t *)c); }
void sc_rt_cond_broadcast(void *c) { pthread_cond_broadcast((pthread_cond_t *)c); }

#if defined(__x86_64__) || defined(__aarch64__)
/* Hand-written switch. `swapcontext` saves and restores the signal mask, which is a syscall on every switch
   (~400ns measured here) against ~20ns for spilling the callee-saved registers and swapping stacks; since a
   coroutine may also resume on a different worker thread, no per-thread state (signal mask, MXCSR, x87
   control word) is stable across a park anyway, so saving it bought nothing but the syscall.
   The whole function is emitted from a file-scope asm block: `naked` is unsupported on x86-64 gcc, and a
   compiler-generated prologue would move the stack out from under the register spills below.

   Two things it deliberately does not do. It carries no CFI, so an unwinder walking out of a coroutine
   stops at the switch instead of continuing onto the resuming stack -- which is the right answer at a
   coroutine boundary, but it does mean no backtrace crosses one. And it is not shadow-stack safe: CET
   checks that a `ret` returns where the matching `call` came from, and the first resume of a coroutine
   returns to an address this code forged, so a build with user-space CET enabled needs
   -fcf-protection=none. No distribution enables user shadow stacks by default today. */
#if defined(__APPLE__)
#define SC_ASM_NAME(n) "_" n
#define SC_ASM_FN(n) ".globl " SC_ASM_NAME(n) "\n.private_extern " SC_ASM_NAME(n) "\n.p2align 4\n" SC_ASM_NAME(n) ":\n"
#else
#define SC_ASM_NAME(n) n
#define SC_ASM_FN(n) ".globl " n "\n.hidden " n "\n.p2align 4\n" n ":\n"
#endif

/* `sc_ctx_swap(void **save_sp, void *to_sp)` pushes the callee-saved set onto the running stack, parks the
   resulting sp through the first argument, and pops the same layout off the second -- so a suspended context
   is nothing but that one stack pointer, and `sc_rt_ctx_init` resumes a brand-new coroutine by forging the
   frame by hand. Everything not listed is caller-saved and already spilled by the C call that got here.
   `sc_ctx_entry` is where a forged frame's final `ret` lands: it moves the saved argument into the first
   argument register and calls the coroutine body. */
#if defined(__x86_64__)
/* 48 bytes of registers + the return address `ret` consumes. Chosen so sp+56 (where the trampoline starts)
   is 16-aligned: SysV wants rsp 16-aligned at a `call`, i.e. 8 mod 16 once inside the callee. */
#define SC_CTX_FRAME 64
/* clang-format off */
__asm__(
  ".text\n"
  SC_ASM_FN("sc_ctx_swap")
  "  .cfi_startproc\n"
  "  pushq %rbp\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %rbp, -16\n"
  "  pushq %rbx\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %rbx, -24\n"
  "  pushq %r12\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %r12, -32\n"
  "  pushq %r13\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %r13, -40\n"
  "  pushq %r14\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %r14, -48\n"
  "  pushq %r15\n"
  "  .cfi_adjust_cfa_offset 8\n  .cfi_offset %r15, -56\n"
  "  subq  $8, %rsp\n"
  "  .cfi_adjust_cfa_offset 8\n"        /* MXCSR and the x87 control word: callee-saved by SysV, and swapcontext */
  "  stmxcsr (%rsp)\n"        /* saved them, so dropping them here would be a regression rather than a */
  "  fnstcw  4(%rsp)\n"       /* choice -- a coroutine that sets a rounding mode keeps it across a park */
  "  movq  %rsp, (%rdi)\n"
  "  movq  %rsi, %rsp\n"
  "  ldmxcsr (%rsp)\n"
  "  fldcw   4(%rsp)\n"
  "  addq  $8, %rsp\n"
  "  .cfi_adjust_cfa_offset -8\n"
  "  popq  %r15\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %r15\n"
  "  popq  %r14\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %r14\n"
  "  popq  %r13\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %r13\n"
  "  popq  %r12\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %r12\n"
  "  popq  %rbx\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %rbx\n"
  "  popq  %rbp\n"
  "  .cfi_adjust_cfa_offset -8\n  .cfi_restore %rbp\n"
  "  ret\n"
  "  .cfi_endproc\n"
  SC_ASM_FN("sc_ctx_entry")
  "  .cfi_startproc\n"
  "  .cfi_undefined %rip\n" /* the coroutine boundary: tell the unwinder to stop rather than guess */
  "  movq  %r13, %rdi\n"
  "  callq *%r12\n"
  "  ud2\n"
  "  .cfi_endproc\n"); /* the scheduler's trampoline switches away instead of returning; reaching here is a bug */
/* clang-format on */
#else
/* x19-x28 + fp + lr + d8-d15, the AArch64 callee-saved set; already a multiple of 16, which sp must stay. */
#define SC_CTX_FRAME 176
/* clang-format off */
__asm__(
  ".text\n"
  SC_ASM_FN("sc_ctx_swap")
  "  .cfi_startproc\n"
  "  sub  sp, sp, #176\n"
  "  .cfi_def_cfa_offset 176\n"
  "  stp  x19, x20, [sp, #0]\n"
  "  stp  x21, x22, [sp, #16]\n"
  "  stp  x23, x24, [sp, #32]\n"
  "  stp  x25, x26, [sp, #48]\n"
  "  stp  x27, x28, [sp, #64]\n"
  "  stp  x29, x30, [sp, #80]\n"
  "  .cfi_offset x19, -176\n  .cfi_offset x20, -168\n  .cfi_offset x21, -160\n  .cfi_offset x22, -152\n"
  "  .cfi_offset x23, -144\n  .cfi_offset x24, -136\n  .cfi_offset x25, -128\n  .cfi_offset x26, -120\n"
  "  .cfi_offset x27, -112\n  .cfi_offset x28, -104\n  .cfi_offset x29,  -96\n  .cfi_offset x30,  -88\n"
  "  stp  d8,  d9,  [sp, #96]\n"
  "  stp  d10, d11, [sp, #112]\n"
  "  stp  d12, d13, [sp, #128]\n"
  "  stp  d14, d15, [sp, #144]\n"
  "  mrs  x2, fpcr\n"          /* the rounding/exception mode travels with the coroutine, as it did */
  "  str  x2, [sp, #160]\n"    /* under ucontext -- see the x86-64 note above */
  "  mov  x2, sp\n"          /* sp cannot be a store operand, so it goes through a caller-saved scratch */
  "  str  x2, [x0]\n"
  "  mov  sp, x1\n"
  "  ldr  x2, [sp, #160]\n"
  "  msr  fpcr, x2\n"
  "  ldp  x19, x20, [sp, #0]\n"
  "  ldp  x21, x22, [sp, #16]\n"
  "  ldp  x23, x24, [sp, #32]\n"
  "  ldp  x25, x26, [sp, #48]\n"
  "  ldp  x27, x28, [sp, #64]\n"
  "  ldp  x29, x30, [sp, #80]\n"
  "  ldp  d8,  d9,  [sp, #96]\n"
  "  ldp  d10, d11, [sp, #112]\n"
  "  ldp  d12, d13, [sp, #128]\n"
  "  ldp  d14, d15, [sp, #144]\n"
  "  add  sp, sp, #176\n"
  "  .cfi_def_cfa_offset 0\n"
  "  ret\n"
  "  .cfi_endproc\n"
  SC_ASM_FN("sc_ctx_entry")
  "  .cfi_startproc\n"
  "  .cfi_undefined x30\n" /* the coroutine boundary: tell the unwinder to stop rather than guess */
  "  mov  x0, x20\n"
  "  blr  x19\n"
  "  brk  #0\n"
  "  .cfi_endproc\n"); /* the scheduler's trampoline switches away instead of returning; reaching here is a bug */
/* clang-format on */
#endif

extern void sc_ctx_swap(void **save_sp, void *to_sp);
extern void sc_ctx_entry(void);

typedef struct {
  void *sp; /* NULL until the first switch away from this context fills it in */
} sc_rt_ctx_asm;

/* A forged frame must carry a LEGAL FP control word. Zero is not one: on x86-64 it unmasks every SSE
   exception, so the first inexact multiply on a fresh coroutine would trap. Seed it from the thread that
   arms the context, which is the same state that thread would have handed over anyway. */
static void sc_ctx_save_fpctl(void *slot) {
#if defined(__x86_64__)
  unsigned char *p = (unsigned char *)slot;
  uint32_t mx = 0;
  uint16_t cw = 0;
  __asm__ volatile("stmxcsr %0" : "=m"(mx));
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  memcpy(p, &mx, sizeof mx);
  memcpy(p + 4, &cw, sizeof cw);
#else
  uint64_t fpcr = 0;
  __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
  memcpy(slot, &fpcr, sizeof fpcr);
#endif
}

void *sc_rt_ctx_alloc(void) { return calloc(1, sizeof(sc_rt_ctx_asm)); }

void sc_rt_ctx_init(void *ctx, void *stack, size_t size, void (*entry)(void *), void *arg) {
  /* Forge the frame the first swap-in will pop, slot for slot in the order sc_ctx_swap stores them. The
     coroutine body and its argument ride in callee-saved registers because they survive that pop unchanged;
     the frame pointer slot stays zero so a backtrace stops at the coroutine boundary instead of walking off
     the top of a stack that has no caller. */
  uintptr_t top = ((uintptr_t)stack + size) & ~(uintptr_t)15;
  void **f = (void **)(top - SC_CTX_FRAME);
  memset(f, 0, SC_CTX_FRAME);
#if defined(__x86_64__)
  sc_ctx_save_fpctl(&f[0]);    /* MXCSR + x87 control word */
  f[3] = arg;                  /* r13 */
  f[4] = (void *)entry;        /* r12 */
  f[7] = (void *)sc_ctx_entry; /* the return address the trailing `ret` jumps to */
#else
  sc_ctx_save_fpctl(&f[20]);    /* FPCR */
  f[0] = (void *)entry;         /* x19 */
  f[1] = arg;                   /* x20 */
  f[11] = (void *)sc_ctx_entry; /* x30, so the trailing `ret` lands on the trampoline */
#endif
  ((sc_rt_ctx_asm *)ctx)->sp = f;
}

void sc_rt_ctx_switch(void *from, void *to) {
  sc_rt_ctx_asm *f = (sc_rt_ctx_asm *)from;
  sc_ctx_swap(&f->sp, ((sc_rt_ctx_asm *)to)->sp);
}

void sc_rt_ctx_free(void *ctx) { free(ctx); }

#else
/* Fallback for any other ABI: ucontext. makecontext passes only int args, so the ctx pointer is split into
   two halves and reassembled in the trampoline. */
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wdeprecated-declarations" /* ucontext is deprecated on macOS but works */
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
#include <ucontext.h>

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

#endif
