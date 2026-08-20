// The generated-C runtime strings: the C standard library include block every generated TU
// shares (super_rt.h) and the leak-tracker implementation TU (super_rt.c). Emission-agnostic --
// the driver writes them verbatim next to whatever backend produced the code.

/// The full C standard library include block the generated runtime pulls in, emitted verbatim into
/// the shared super_rt.h (single-TU builds inline it instead) together with the atomic shims, the
/// panic/bounds helpers, and the leak-tracker macros that interpose malloc/realloc/free call sites.
pub const fn super_rt_includes() *const char {
    return M"(#if __has_include(<assert.h>)
#include <assert.h>
#endif
#if __has_include(<complex.h>)
#include <complex.h>
#endif
#if __has_include(<ctype.h>)
#include <ctype.h>
#endif
#if __has_include(<errno.h>)
#include <errno.h>
#endif
#if __has_include(<fenv.h>)
#include <fenv.h>
#endif
#if __has_include(<float.h>)
#include <float.h>
#endif
#if __has_include(<inttypes.h>)
#include <inttypes.h>
#endif
#if __has_include(<iso646.h>)
#include <iso646.h>
#endif
#if __has_include(<limits.h>)
#include <limits.h>
#endif
#if __has_include(<locale.h>)
#include <locale.h>
#endif
#if __has_include(<math.h>)
#include <math.h>
#endif
#if __has_include(<dlfcn.h>)
#include <dlfcn.h>
#endif
#if __has_include(<signal.h>)
#include <signal.h>
#endif
#if __has_include(<stdalign.h>)
#include <stdalign.h>
#endif
#if __has_include(<stdarg.h>)
#include <stdarg.h>
#endif
#if __has_include(<stdatomic.h>)
#include <stdatomic.h>
#endif
#if __has_include(<stdbit.h>)
#include <stdbit.h>
#endif
#if __has_include(<stdbool.h>)
#include <stdbool.h>
#endif
#if __has_include(<stdckdint.h>)
#include <stdckdint.h>
#endif
#if __has_include(<stddef.h>)
#include <stddef.h>
#endif
#if __has_include(<stdint.h>)
#include <stdint.h>
#endif
#if __has_include(<stdio.h>)
#include <stdio.h>
#endif
#if __has_include(<stdlib.h>)
#include <stdlib.h>
#endif
#if __has_include(<stdnoreturn.h>)
#include <stdnoreturn.h>
#endif
#if __has_include(<string.h>)
#include <string.h>
#endif
#if __has_include(<tgmath.h>)
#include <tgmath.h>
#endif
#if __has_include(<threads.h>)
#include <threads.h>
#endif
#if __has_include(<pthread.h>)
#include <pthread.h>
#endif
#if __has_include(<time.h>)
#include <time.h>
#endif
#if __has_include(<uchar.h>)
#include <uchar.h>
#endif
#if __has_include(<wchar.h>)
#include <wchar.h>
#endif
#if __has_include(<wctype.h>)
#include <wctype.h>
#endif
/* Branch-layout hints (std/core `likely`/`unlikely`): __builtin_expect steers block placement on
   GCC/Clang; every other compiler sees the bare condition. */
#if defined(__GNUC__) || defined(__clang__)
#define SC_LIKELY(x) __builtin_expect(!!(x), 1)
#define SC_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define SC_LIKELY(x) (x)
#define SC_UNLIKELY(x) (x)
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
/* Memory order: the enum value (Relaxed=0,Acquire=1,Release=2,AcqRel=3,SeqCst=4) maps to the matching
   __ATOMIC_* constant. A ternary rather than a runtime order argument so a constant order folds to a
   single instruction at -O1+; orders illegal for an op (e.g. Release on a load) clamp to SeqCst. */
#define SC_MO_RMW(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==1?__ATOMIC_ACQUIRE:(mo)==2?__ATOMIC_RELEASE:(mo)==3?__ATOMIC_ACQ_REL:__ATOMIC_SEQ_CST)
#define SC_MO_LD(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==1?__ATOMIC_ACQUIRE:__ATOMIC_SEQ_CST)
#define SC_MO_ST(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==2?__ATOMIC_RELEASE:__ATOMIC_SEQ_CST)
#define SC_AT(T,S) \
static inline T __sc_atomic_load_##S(const T*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));} \
static inline void __sc_atomic_store_##S(T*p,T v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));} \
static inline T __sc_atomic_swap_##S(T*p,T v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_add_##S(T*p,T v,int mo){return __atomic_fetch_add(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_sub_##S(T*p,T v,int mo){return __atomic_fetch_sub(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_and_##S(T*p,T v,int mo){return __atomic_fetch_and(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_or_##S(T*p,T v,int mo){return __atomic_fetch_or(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_xor_##S(T*p,T v,int mo){return __atomic_fetch_xor(p,v,SC_MO_RMW(mo));} \
static inline bool __sc_atomic_cas_##S(T*p,T e,T d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_RMW(so),SC_MO_LD(fo));}
SC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)
SC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)
#undef SC_AT
static inline bool __sc_atomic_load_bool(const bool*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));}
static inline void __sc_atomic_store_bool(bool*p,bool v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));}
static inline bool __sc_atomic_swap_bool(bool*p,bool v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));}
static inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_RMW(so),SC_MO_LD(fo));}
static inline void __sc_atomic_fence(int mo){__atomic_thread_fence(SC_MO_RMW(mo));}
#undef SC_MO_RMW
#undef SC_MO_LD
#undef SC_MO_ST
#pragma GCC diagnostic pop
#endif
static inline __attribute__((unused)) FILE* __sc_stdin(void){return stdin;}
static inline __attribute__((unused)) FILE* __sc_stdout(void){return stdout;}
static inline __attribute__((unused)) FILE* __sc_stderr(void){return stderr;}
static inline __attribute__((unused)) int* __sc_errno_location(void){return &errno;}
/* Task attribution: a coroutine runtime stores the running task's id here, so a panic names the task it
   happened in rather than just the process. Zero on a plain thread. */
extern _Thread_local uint64_t __sc_task_id;
void __sc_set_task_id(uint64_t __id);
/* abort() does not flush, and stderr is only guaranteed unbuffered when it is a terminal -- captured into
   a pipe it is block-buffered, and the diagnostic these print is exactly what is then lost. Flush first. */
static _Noreturn __attribute__((unused)) void __sc_panic(const char *__m) {
  if (__sc_task_id) fprintf(stderr, "super-c: [task %llu] %s\n", (unsigned long long)__sc_task_id, __m);
  else fprintf(stderr, "super-c: %s\n", __m);
  fflush(stderr);
  abort();
}
static _Noreturn __attribute__((unused)) void __sc_panic_str(const uint8_t *__p, size_t __n) {
  if (__sc_task_id) fprintf(stderr, "panic: [task %llu] %.*s\n", (unsigned long long)__sc_task_id, (int)__n, (const char *)__p);
  else fprintf(stderr, "panic: %.*s\n", (int)__n, (const char *)__p);
  fflush(stderr);
  abort();
}
static __attribute__((unused)) inline size_t __sc_bounds(size_t __i, size_t __n) {
  if (__i >= __n) __sc_panic("index out of bounds");
  return __i;
}
/* Pointer distance over a zero-sized element type: bytes cannot encode an element count. */
static _Noreturn __attribute__((unused)) void __sc_zst_ptrdiff(void) {
  __sc_panic("pointer distance on a zero-sized element type");
}
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
/* Preemption safepoint. Emitted at loop backedges ONLY when the program uses the coroutine runtime, so
   one that never `launch`es pays nothing at all -- and when it is emitted the cost is a thread-local
   decrement and a not-taken branch, not a call. The hook is installed by the scheduler BEFORE it starts
   any worker, so every read of it happens-after that write and no synchronization is needed here. */
extern _Thread_local int32_t __sc_pre_tick;
extern void (*__sc_pre_hook)(void);
void __sc_set_preempt_hook(void (*__f)(void));
static inline __attribute__((unused)) void __sc_safepoint(void) {
  if (--__sc_pre_tick > 0) return;
  __sc_pre_tick = 2048;
  if (__sc_pre_hook) __sc_pre_hook();
}
/* Cold half of the function-local safepoint tick (`__sc_spc` in emitted bodies): runs the hook
   check and hands back the reset value, so the hot path is one register decrement + branch. */
static inline __attribute__((unused)) int32_t __sc_preempt_check(void) {
  if (__sc_pre_hook) __sc_pre_hook();
  return 2048;
}
/* reflection registry (super_rt.c): `@reflect`-tagged concrete types register their exported
   `sc_typeinfo_<name>` descriptor at startup (constructor order). External tools dlopen the binary
   and walk the SAME static descriptors the program reads: __sc_reflect_types yields the registered
   pointers (each a `const TypeInfo *`; layout per std/core.spc, policed by the emitted layout
   asserts). Fixed capacity: no allocation, so the leak tracker stays silent. */
void __sc_reflect_register(const void *__ti);
const void **__sc_reflect_types(size_t *__n);
/* leak tracker (super_rt.c): interposes the emitted code's malloc/realloc/free call sites.
   Inert unless the SC_LEAK_CHECK environment variable is set; compile with -DSC_NO_LEAK_CHECK to
   drop the interposition entirely (super_rt.c still links: the coroutine runtime calls sc_lk_bt_*). */
void *sc_lk_malloc(size_t __n);
void *sc_lk_calloc(size_t __n, size_t __m);
void *sc_lk_realloc(void *__p, size_t __n);
void sc_lk_free(void *__p);
/* Suspend/resume per-thread backtrace capture: a coroutine runtime brackets a task's execution with these
   so the tracker never unwinds a makecontext/fiber stack (which has no clean base frame). Leak DETECTION is
   unaffected -- only the per-allocation call stack is skipped while paused. Balanced; safe to nest. */
void sc_lk_bt_pause(void);
void sc_lk_bt_resume(void);
#ifndef SC_NO_LEAK_CHECK
#define malloc(__n) sc_lk_malloc(__n)
#define calloc(__n, __m) sc_lk_calloc(__n, __m)
#define realloc(__p, __n) sc_lk_realloc(__p, __n)
#define free(__p) sc_lk_free(__p)
#endif
)".ptr() as *const char;
}

/// The leak-tracker runtime backing the `super_rt.h` interposition macros, written as `super_rt.c`
/// next to the header (the build engine compiles every `.c` in the generated tree). Runtime-gated by
/// the SC_LEAK_CHECK environment variable: when unset the hooks are a branch over the real calls;
/// when set, live allocations are recorded (with call stacks where <execinfo.h> exists) and the
/// survivors are reported to stderr at process exit, grouped by allocation stack. Every libc call is
/// spelled `(malloc)(...)`-parenthesized so the same text also compiles inlined after the macros.
pub const fn super_rt_source() *const char {
    return M"(/* super-c runtime: leak tracker (see super_rt.h). Generated; do not edit. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

/* Task id of the coroutine running on this thread (see super_rt.h); 0 = none. */
_Thread_local uint64_t __sc_task_id = 0;
void __sc_set_task_id(uint64_t __id) { __sc_task_id = __id; }

/* Preemption safepoint state (see super_rt.h). Inert until a scheduler installs the hook. */
_Thread_local int32_t __sc_pre_tick = 2048;
void (*__sc_pre_hook)(void) = 0;
/* Installed by a scheduler before it starts any worker, so every safepoint's read happens-after it. */
void __sc_set_preempt_hook(void (*__f)(void)) { __sc_pre_hook = __f; }

/* Reflection registry (see super_rt.h). A fixed static table: registration happens in constructors,
   before main and before any allocator interposition question can arise. */
#define SC_REFLECT_MAX 1024
static const void *__sc_refl[SC_REFLECT_MAX];
static size_t __sc_refl_n = 0;
void __sc_reflect_register(const void *__ti) {
  if (__sc_refl_n < SC_REFLECT_MAX) __sc_refl[__sc_refl_n++] = __ti;
}
const void **__sc_reflect_types(size_t *__n) {
  if (__n) *__n = __sc_refl_n;
  return __sc_refl;
}
#include <stdint.h>
#if defined(__has_include) && !defined(__ANDROID__)
/* bionic ships <execinfo.h> but only DECLARES backtrace()/backtrace_symbols() from API 33, so the
   header alone does not mean they are callable: leaks are still tracked there, without call stacks. */
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define SC_LK_BT 10
#define SC_LK_SYMS 1
#endif
#endif
#if defined(_WIN32)
void *GetModuleHandleA(const char *lpModuleName);
#endif
#if !defined(SC_LK_BT) && defined(_WIN32)
unsigned short RtlCaptureStackBackTrace(unsigned long FramesToSkip, unsigned long FramesToCapture, void **BackTrace, unsigned long *BackTraceHash);
#define SC_LK_BT 10
#endif
void *sc_lk_malloc(size_t __n);
void *sc_lk_calloc(size_t __n, size_t __m);
void *sc_lk_realloc(void *__p, size_t __n);
void sc_lk_free(void *__p);
typedef struct {
  void *ptr;
  size_t size;
  int nbt;
  unsigned char st; /* 1 = live, 2 = freed (kept until rehash for double-free detection) */
#ifdef SC_LK_BT
  void *bt[SC_LK_BT];
#endif
} sc_lk_ent;
static sc_lk_ent *sc_lk_tab;
static size_t sc_lk_cap;  /* power of two */
static size_t sc_lk_used; /* live + freed-history */
static size_t sc_lk_live;
static size_t sc_lk_bytes;
static size_t sc_lk_dbl;
static volatile int sc_lk_lock;
static int sc_lk_state; /* 0 = unprobed, 1 = off, 2 = report, 3 = fatal */
static void sc_lk_acquire(void) {
  while (__sync_lock_test_and_set(&sc_lk_lock, 1)) {}
}
static void sc_lk_release(void) { __sync_lock_release(&sc_lk_lock); }
static size_t sc_lk_slot(const void *p, size_t cap) {
  return (size_t)(((uintptr_t)p >> 4) * (uintptr_t)0x9E3779B97F4A7C15ULL) & (cap - 1);
}
static sc_lk_ent *sc_lk_find(void *p) {
  if (sc_lk_cap == 0) return NULL;
  size_t i = sc_lk_slot(p, sc_lk_cap);
  while (sc_lk_tab[i].st != 0) {
    if (sc_lk_tab[i].ptr == p) return &sc_lk_tab[i];
    i = (i + 1) & (sc_lk_cap - 1);
  }
  return NULL;
}
static void sc_lk_put(sc_lk_ent *tab, size_t cap, const sc_lk_ent *e) {
  size_t i = sc_lk_slot(e->ptr, cap);
  while (tab[i].st != 0) i = (i + 1) & (cap - 1);
  tab[i] = *e;
}
static int sc_lk_grow(void) {
  size_t ncap = sc_lk_cap != 0 ? sc_lk_cap * 2 : 4096;
  sc_lk_ent *nt = (sc_lk_ent *)(calloc)(ncap, sizeof(sc_lk_ent));
  if (nt == NULL) return 0;
  size_t kept = 0;
  for (size_t i = 0; i < sc_lk_cap; i++) {
    if (sc_lk_tab[i].st == 1) {
      sc_lk_put(nt, ncap, &sc_lk_tab[i]);
      kept++;
    }
  }
  (free)(sc_lk_tab);
  sc_lk_tab = nt;
  sc_lk_cap = ncap;
  sc_lk_used = kept; /* freed-history entries are dropped: detection is best-effort */
  return 1;
}
/* Per-thread backtrace-suppression depth: nonzero while this thread runs on a coroutine/fiber stack, whose
   frame chain has no clean terminator for backtrace() to stop at. */
static _Thread_local int sc_lk_bt_off = 0;
void sc_lk_bt_pause(void) { sc_lk_bt_off++; }
void sc_lk_bt_resume(void) { sc_lk_bt_off--; }
static void sc_lk_capture(sc_lk_ent *e, void *p, size_t n) {
  e->ptr = p;
  e->size = n;
  e->st = 1;
  e->nbt = 0;
  if (sc_lk_bt_off == 0) {
#ifdef SC_LK_SYMS
    e->nbt = backtrace(e->bt, SC_LK_BT);
#elif defined(SC_LK_BT)
    e->nbt = (int)RtlCaptureStackBackTrace(0UL, (unsigned long)SC_LK_BT, e->bt, (unsigned long *)0);
#endif
  }
}
#ifdef SC_LK_BT
static void sc_lk_bt_print(void *const *bt, int n) {
#ifdef SC_LK_SYMS
  char **syms = backtrace_symbols(bt, n);
  if (syms != NULL) {
    for (int f = 0; f < n; f++) {
      if (strstr(syms[f], "sc_lk_") == NULL) fprintf(stderr, "    %s\n", syms[f]);
    }
    (free)(syms);
    return;
  }
#endif
#ifdef _WIN32
  /* No runtime DWARF symbolizer: print each frame as an ASLR-stable PE-base offset, like the crash
     trace, so `addr2line` against the same binary resolves it. */
  {
    char *base = (char *)GetModuleHandleA(NULL);
    for (int f = 0; f < n; f++)
      fprintf(stderr, "    leak-frame +0x%llx\n", (unsigned long long)((char *)bt[f] - base));
    return;
  }
#endif
  for (int f = 0; f < n; f++) fprintf(stderr, "    %p\n", bt[f]);
}
#endif
/* `snap` holds the entry recorded when the block was FIRST freed (its stack is the freeing site). */
static void sc_lk_double(void *p, const sc_lk_ent *snap) {
  fprintf(stderr, "== super-c double free: %p (%llu byte(s)) ==\n", p, (unsigned long long)snap->size);
#ifdef SC_LK_BT
  fprintf(stderr, "previously freed at:\n");
  sc_lk_bt_print(snap->bt, snap->nbt);
  sc_lk_ent now;
  sc_lk_capture(&now, p, 0);
  fprintf(stderr, "freed again at:\n");
  sc_lk_bt_print(now.bt, now.nbt);
#endif
  if (sc_lk_state == 3) abort();
}
static void sc_lk_disable(void) {
  sc_lk_state = 1;
  (free)(sc_lk_tab);
  sc_lk_tab = NULL;
  sc_lk_cap = 0;
  sc_lk_used = 0;
  sc_lk_live = 0;
  sc_lk_bytes = 0;
}
static int sc_lk_group_cmp(const void *va, const void *vb) {
  const sc_lk_ent *a = (const sc_lk_ent *)va;
  const sc_lk_ent *b = (const sc_lk_ent *)vb;
#ifdef SC_LK_BT
  if (a->nbt != b->nbt) return a->nbt < b->nbt ? -1 : 1;
  int c = memcmp(a->bt, b->bt, (size_t)(a->nbt < 0 ? 0 : a->nbt) * sizeof(void *));
  if (c != 0) return c;
#endif
  if (a->size != b->size) return a->size < b->size ? -1 : 1;
  return 0;
}
static void sc_lk_report(void) {
  sc_lk_acquire();
  size_t n = sc_lk_live;
  size_t bytes = sc_lk_bytes;
  sc_lk_ent *v = NULL;
  if (n != 0) v = (sc_lk_ent *)(malloc)(n * sizeof(sc_lk_ent));
  if (v != NULL) {
    size_t k = 0;
    for (size_t i = 0; i < sc_lk_cap && k < n; i++) {
      if (sc_lk_tab[i].st == 1) v[k++] = sc_lk_tab[i];
    }
    n = k;
  } else {
    n = 0;
  }
  int fatal = sc_lk_state == 3;
  size_t dbl = sc_lk_dbl;
  sc_lk_state = 1; /* the report's own prints may allocate: stop tracking */
  sc_lk_release();
  if (n != 0) {
    qsort(v, n, sizeof(sc_lk_ent), sc_lk_group_cmp);
    fprintf(stderr, "== super-c leaks: %llu allocation(s), %llu byte(s) ==\n",
            (unsigned long long)n, (unsigned long long)bytes);
    size_t shown = 0;
    for (size_t i = 0; i < n;) {
      size_t j = i;
      size_t gbytes = 0;
      while (j < n && sc_lk_group_cmp(&v[i], &v[j]) == 0) gbytes += v[j++].size;
      if (shown < 64) {
        fprintf(stderr, "leak: %llu allocation(s), %llu byte(s)\n",
                (unsigned long long)(j - i), (unsigned long long)gbytes);
#ifdef SC_LK_BT
        sc_lk_bt_print(v[i].bt, v[i].nbt);
#endif
      }
      shown++;
      i = j;
    }
    if (shown > 64)
      fprintf(stderr, "... (%llu more leak site(s))\n", (unsigned long long)(shown - 64));
  }
  (free)(v);
  if (dbl != 0)
    fprintf(stderr, "== super-c double frees: %llu ==\n", (unsigned long long)dbl);
  if (fatal && (n != 0 || dbl != 0)) _Exit(23);
}
static int sc_lk_on(void) {
  if (sc_lk_state == 0) {
    const char *e = getenv("SC_LEAK_CHECK");
    int st = 1;
    if (e != NULL && e[0] != '\0' && e[0] != '0') st = (e[0] == 'f' || e[0] == 'F') ? 3 : 2;
    sc_lk_state = st;
    if (st >= 2) atexit(sc_lk_report);
  }
  return sc_lk_state >= 2;
}
/* Insert under the held lock. An existing entry at `p` is overwritten: freed-history means the
   address was legitimately reused; a live one means the block was freed behind the tracker's back
   (a foreign free) and then reused. Returns 0 when bookkeeping memory ran out. */
static int sc_lk_insert(const sc_lk_ent *e) {
  sc_lk_ent *old = sc_lk_find(e->ptr);
  if (old != NULL) {
    if (old->st == 1) {
      sc_lk_bytes -= old->size;
      sc_lk_live--;
    }
    *old = *e;
    sc_lk_live++;
    sc_lk_bytes += e->size;
    return 1;
  }
  if ((sc_lk_used + 1) * 10 >= sc_lk_cap * 7 && !sc_lk_grow()) return 0;
  sc_lk_put(sc_lk_tab, sc_lk_cap, e);
  sc_lk_used++;
  sc_lk_live++;
  sc_lk_bytes += e->size;
  return 1;
}
void *sc_lk_malloc(size_t __n) {
  void *p = (malloc)(__n);
  if (p != NULL && sc_lk_on()) {
    sc_lk_ent e;
    sc_lk_capture(&e, p, __n);
    sc_lk_acquire();
    if (sc_lk_state >= 2 && !sc_lk_insert(&e)) sc_lk_disable();
    sc_lk_release();
  }
  return p;
}
void *sc_lk_calloc(size_t __n, size_t __m) {
  void *p = (calloc)(__n, __m);
  if (p != NULL && sc_lk_on()) {
    sc_lk_ent e;
    sc_lk_capture(&e, p, __n * __m);
    sc_lk_acquire();
    if (sc_lk_state >= 2 && !sc_lk_insert(&e)) sc_lk_disable();
    sc_lk_release();
  }
  return p;
}
void *sc_lk_realloc(void *__p, size_t __n) {
  if (__p != NULL && sc_lk_on()) {
    int uaf = 0;
    sc_lk_ent snap;
    snap.size = 0;
    snap.nbt = 0;
    sc_lk_acquire();
    if (sc_lk_state >= 2) {
      sc_lk_ent *e0 = sc_lk_find(__p);
      if (e0 != NULL && e0->st == 2) {
        snap = *e0;
        uaf = 1;
        sc_lk_dbl++;
      }
    }
    sc_lk_release();
    if (uaf) {
      fprintf(stderr, "== super-c realloc of freed pointer: %p ==\n", __p);
#ifdef SC_LK_BT
      fprintf(stderr, "previously freed at:\n");
      sc_lk_bt_print(snap.bt, snap.nbt);
#endif
      if (sc_lk_state == 3) abort();
      return sc_lk_malloc(__n); /* the old block is gone: hand back fresh memory */
    }
  }
  /* The registry key is an ADDRESS, and an address survives the realloc that invalidates the pointer
     holding it: reading `__p` again after this call is undefined (and GCC's -Wuse-after-free says so).
     The lock is held ACROSS the realloc: the moment it returns, the old block is free for another
     thread to receive from malloc, so releasing between the call and the bookkeeping lets that
     thread's fresh entry at the same address be marked freed here -- a false use-after-free later. */
  const uintptr_t __pa = (uintptr_t)__p;
  int track = sc_lk_on();
  if (track) sc_lk_acquire();
  void *q = (realloc)(__p, __n);
  if (q != NULL && track && sc_lk_state >= 2) {
    sc_lk_ent e;
    sc_lk_capture(&e, q, __n);
    sc_lk_ent *old = __pa != 0 ? sc_lk_find((void *)__pa) : NULL;
    int was_tracked = 0;
    if (old != NULL && old->st == 1) {
      sc_lk_bytes -= old->size;
      sc_lk_live--;
      size_t osz = old->size;
      void *op = old->ptr;
      sc_lk_capture(old, op, osz); /* the realloc consumed it: record this site */
      old->st = 2;
      was_tracked = 1;
    }
    /* memory the tracker never saw (a foreign allocator) stays untracked */
    if ((was_tracked || __pa == 0) && !sc_lk_insert(&e)) sc_lk_disable();
  }
  if (track) sc_lk_release();
  return q;
}
void sc_lk_free(void *__p) {
  int skip = 0;
  if (__p != NULL && sc_lk_on()) {
    int dbl = 0;
    sc_lk_ent snap;
    snap.size = 0;
    snap.nbt = 0;
    sc_lk_acquire();
    if (sc_lk_state >= 2) {
      sc_lk_ent *e = sc_lk_find(__p);
      if (e != NULL) {
        if (e->st == 2) {
          snap = *e;
          dbl = 1;
          skip = 1; /* the block may belong to someone else now: never free it twice */
          sc_lk_dbl++;
        } else {
          sc_lk_bytes -= e->size;
          sc_lk_live--;
          size_t sz = e->size;
          sc_lk_capture(e, __p, sz); /* record the freeing site for double-free reports */
          e->st = 2;
        }
      }
    }
    sc_lk_release();
    if (dbl) sc_lk_double(__p, &snap);
  }
  if (!skip) (free)(__p);
}
)".ptr() as *const char;
}
