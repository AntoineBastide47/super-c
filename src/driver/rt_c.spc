// The generated-C runtime strings: the C standard library include block every generated TU
// shares (super_rt.h) and the leak-tracker implementation TU (super_rt.c). Emission-agnostic:
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
/* Range validation for safe slicing: proves start <= end <= len BEFORE any pointer arithmetic
   and returns the exclusive end. */
static __attribute__((unused)) inline size_t __sc_range(size_t __s, size_t __e, size_t __n) {
  if (__s > __e || __e > __n) __sc_panic("range out of bounds");
  return __e;
}
/* Coalesced element checks: index + width <= len in overflow-safe form; returns the index. */
static __attribute__((unused)) inline size_t __sc_bounds_group(size_t __i, size_t __n, size_t __w) {
  if (__i > __n || __w > __n - __i) __sc_panic("index out of bounds");
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
/* Cancellation half of a combined safepoint (emitted only on its cold path): asks the runtime
   whether the current task has an unmasked pending cancellation, ACCEPTING it on yes -- the
   emitted branch then enters the frame's cancellation ladder. The hook lives in sc_rt.c and is
   inert until the scheduler installs it. */
extern int32_t (*__sc_cancel_hook)(void);
static inline __attribute__((unused)) int32_t __sc_cancel_tick(void) {
  return __sc_cancel_hook ? __sc_cancel_hook() : 0;
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
void sc_lk_fork_child_reset(void);
void sc_lk_report_now(void);
/* Suspend/resume per-thread allocation-site capture. A coroutine runtime brackets task execution with
   these because a makecontext/fiber stack has no standard frame base. Detection stays active. */
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
/// when set, live allocations are recorded with their call-site address and the survivors are reported
/// to stderr at process exit, grouped by allocation site. Every libc call is
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
#if defined(__has_include) && !defined(__ANDROID__)
/* bionic ships <execinfo.h> but only declares its functions from API 33. Keep site symbolization off there. */
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define SC_LK_SYMS 1
#endif
#endif
#if defined(_WIN32)
void *GetModuleHandleA(const char *lpModuleName);
#endif
#if defined(__wasm__)
/* No frame walk on wasm: leaks and double frees are still counted and reported, without call sites. */
#define SC_LK_SITE() NULL
#elif defined(__GNUC__) || defined(__clang__)
#define SC_LK_SITE() __builtin_extract_return_addr(__builtin_return_address(0))
#elif defined(_MSC_VER)
#include <intrin.h>
#define SC_LK_SITE() _ReturnAddress()
#else
#define SC_LK_SITE() NULL
#endif
void *sc_lk_malloc(size_t __n);
void *sc_lk_calloc(size_t __n, size_t __m);
void *sc_lk_realloc(void *__p, size_t __n);
void sc_lk_free(void *__p);
void sc_lk_fork_child_reset(void);
void sc_lk_report_now(void);
int sc_lk_stats_enable(void);
void sc_lk_epoch_set(uint32_t __e);
void sc_lk_stats(uint64_t *__out);
void sc_lk_counts(uint64_t *__out);
typedef struct {
  void *ptr;
  void *site;
  size_t size;
  uint32_t epoch; /* sc_lk_epoch when the block was recorded */
} sc_lk_ent;
#define SC_LK_EPOCHS 8
#define SC_LK_SHARDS 64
#define SC_LK_SHARD_BITS 6
#define SC_LK_FREED_HISTORY 32
_Static_assert((SC_LK_SHARDS & (SC_LK_SHARDS - 1)) == 0, "leak shard count must be a power of two");
_Static_assert(SC_LK_SHARDS == (1U << SC_LK_SHARD_BITS), "leak shard bits must match the shard count");
typedef struct {
  sc_lk_ent *tab;
  size_t cap;  /* power of two */
  size_t live;
  size_t bytes;
  size_t dbl;
  size_t alloc_n;     /* recorded allocation calls, cumulative */
  size_t alloc_bytes; /* bytes those calls requested, cumulative */
  sc_lk_ent freed[SC_LK_FREED_HISTORY];
  size_t freed_next;
  size_t freed_count;
  volatile int lock;
} sc_lk_shard;
static sc_lk_shard sc_lk_shards[SC_LK_SHARDS];
static int sc_lk_state; /* 0 = unprobed, 1 = off, 2 = report, 3 = fatal */
static uint32_t sc_lk_epoch; /* tag for every allocation recorded from now on (sc_lk_epoch_set) */
static uintptr_t sc_lk_hash(const void *p) {
  return ((uintptr_t)p >> 4) * (uintptr_t)0x9E3779B97F4A7C15ULL;
}
static sc_lk_shard *sc_lk_shard_for(const void *p) {
  return &sc_lk_shards[sc_lk_hash(p) & (SC_LK_SHARDS - 1)];
}
static void sc_lk_acquire(sc_lk_shard *s) {
  while (__sync_lock_test_and_set(&s->lock, 1)) {}
}
static void sc_lk_release(sc_lk_shard *s) { __sync_lock_release(&s->lock); }
/* Drop a shard's table and counters (the lock word is left to the caller). */
static void sc_lk_shard_clear(sc_lk_shard *s) {
  (free)(s->tab);
  s->tab = NULL;
  s->cap = 0;
  s->live = 0;
  s->bytes = 0;
  s->dbl = 0;
  s->alloc_n = 0;
  s->alloc_bytes = 0;
  s->freed_next = 0;
  s->freed_count = 0;
}
static size_t sc_lk_slot(const void *p, size_t cap) {
  return (size_t)(sc_lk_hash(p) >> SC_LK_SHARD_BITS) & (cap - 1);
}
static sc_lk_ent *sc_lk_find(sc_lk_shard *s, void *p) {
  if (s->cap == 0) return NULL;
  size_t i = sc_lk_slot(p, s->cap);
  for (size_t probes = 0; probes < s->cap && s->tab[i].ptr != NULL; probes++) {
    if (s->tab[i].ptr == p) return &s->tab[i];
    i = (i + 1) & (s->cap - 1);
  }
  return NULL;
}
static void sc_lk_put(sc_lk_ent *tab, size_t cap, const sc_lk_ent *e) {
  size_t i = sc_lk_slot(e->ptr, cap);
  for (size_t probes = 0; probes < cap; probes++) {
    if (tab[i].ptr == NULL) {
      tab[i] = *e;
      return;
    }
    i = (i + 1) & (cap - 1);
  }
  abort();
}
/* Per-thread site-suppression depth for coroutine and fiber stacks. */
static _Thread_local int sc_lk_bt_off = 0;
static int sc_lk_grow(sc_lk_shard *s) {
  if (s->cap > SIZE_MAX / 2) return 0;
  size_t ncap = s->cap != 0 ? s->cap * 2 : 64;
  sc_lk_ent *nt = (sc_lk_ent *)(calloc)(ncap, sizeof(sc_lk_ent));
  if (nt == NULL) return 0;
  for (size_t i = 0; i < s->cap; i++) {
    if (s->tab[i].ptr != NULL) sc_lk_put(nt, ncap, &s->tab[i]);
  }
  (free)(s->tab);
  s->tab = nt;
  s->cap = ncap;
  return 1;
}
static void sc_lk_erase(sc_lk_shard *s, sc_lk_ent *entry) {
  size_t hole = (size_t)(entry - s->tab);
  size_t i = (hole + 1) & (s->cap - 1);
  for (size_t probes = 0; probes < s->cap && s->tab[i].ptr != NULL; probes++) {
    size_t home = sc_lk_slot(s->tab[i].ptr, s->cap);
    if (((i - home) & (s->cap - 1)) >= ((i - hole) & (s->cap - 1))) {
      s->tab[hole] = s->tab[i];
      hole = i;
    }
    i = (i + 1) & (s->cap - 1);
  }
  s->tab[hole].ptr = NULL;
  s->tab[hole].site = NULL;
  s->tab[hole].size = 0;
}
static void sc_lk_remember_free(sc_lk_shard *s, const sc_lk_ent *entry, void *site) {
  sc_lk_ent freed = *entry;
  freed.site = sc_lk_bt_off == 0 ? site : NULL;
  s->freed[s->freed_next] = freed;
  s->freed_next = (s->freed_next + 1) % SC_LK_FREED_HISTORY;
  if (s->freed_count < SC_LK_FREED_HISTORY) s->freed_count++;
}
static sc_lk_ent *sc_lk_find_freed(sc_lk_shard *s, void *p) {
  size_t i = s->freed_next;
  for (size_t n = 0; n < s->freed_count; n++) {
    i = (i + SC_LK_FREED_HISTORY - 1) % SC_LK_FREED_HISTORY;
    if (s->freed[i].ptr == p) return &s->freed[i];
  }
  return NULL;
}
void sc_lk_bt_pause(void) { sc_lk_bt_off++; }
void sc_lk_bt_resume(void) { sc_lk_bt_off--; }
static void sc_lk_capture(sc_lk_ent *e, void *p, size_t n, void *site) {
  e->ptr = p;
  e->site = sc_lk_bt_off == 0 ? site : NULL;
  e->size = n;
  e->epoch = __atomic_load_n(&sc_lk_epoch, __ATOMIC_RELAXED);
}
static void sc_lk_site_print(void *site) {
  if (site == NULL) return;
#ifdef SC_LK_SYMS
  char **syms = backtrace_symbols(&site, 1);
  if (syms != NULL) {
    fprintf(stderr, "    %s\n", syms[0]);
    (free)(syms);
    return;
  }
#endif
#ifdef _WIN32
  /* No runtime DWARF symbolizer: print an ASLR-stable PE-base offset so `addr2line` resolves it. */
  {
    char *base = (char *)GetModuleHandleA(NULL);
    fprintf(stderr, "    leak-site +0x%llx\n", (unsigned long long)((char *)site - base));
    return;
  }
#endif
  fprintf(stderr, "    %p\n", site);
}
/* `snap` holds the entry recorded when the block was first freed. */
static void sc_lk_double(void *p, const sc_lk_ent *snap, void *site) {
  fprintf(stderr, "== super-c double free: %p (%llu byte(s)) ==\n", p, (unsigned long long)snap->size);
  fprintf(stderr, "previously freed at:\n");
  sc_lk_site_print(snap->site);
  fprintf(stderr, "freed again at:\n");
  sc_lk_site_print(site);
  if (sc_lk_state == 3) abort();
}
static void sc_lk_disable(void) {
  sc_lk_state = 1;
}
static int sc_lk_group_cmp(const void *va, const void *vb) {
  const sc_lk_ent *a = (const sc_lk_ent *)va;
  const sc_lk_ent *b = (const sc_lk_ent *)vb;
  if (a->site != b->site) return (uintptr_t)a->site < (uintptr_t)b->site ? -1 : 1;
  if (a->size != b->size) return a->size < b->size ? -1 : 1;
  return 0;
}
static void sc_lk_report(void) {
  for (size_t h = 0; h < SC_LK_SHARDS; h++) sc_lk_acquire(&sc_lk_shards[h]);
  int enabled = sc_lk_state >= 2;
  size_t n = 0;
  size_t bytes = 0;
  size_t dbl = 0;
  if (enabled) {
    for (size_t h = 0; h < SC_LK_SHARDS; h++) {
      n += sc_lk_shards[h].live;
      bytes += sc_lk_shards[h].bytes;
      dbl += sc_lk_shards[h].dbl;
    }
  }
  sc_lk_ent *v = NULL;
  if (n != 0) v = (sc_lk_ent *)(malloc)(n * sizeof(sc_lk_ent));
  if (v != NULL) {
    size_t k = 0;
    for (size_t h = 0; h < SC_LK_SHARDS; h++) {
      sc_lk_shard *s = &sc_lk_shards[h];
      for (size_t i = 0; i < s->cap && k < n; i++) {
        if (s->tab[i].ptr != NULL) v[k++] = s->tab[i];
      }
    }
    n = k;
  } else {
    n = 0;
  }
  int fatal = enabled && sc_lk_state == 3;
  sc_lk_state = 1; /* the report's own prints may allocate: stop tracking */
  for (size_t h = 0; h < SC_LK_SHARDS; h++) {
    sc_lk_shard *s = &sc_lk_shards[h];
    sc_lk_shard_clear(s);
    sc_lk_release(s);
  }
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
        sc_lk_site_print(v[i].site);
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
void sc_lk_fork_child_reset(void) {
  if (!sc_lk_on()) return;
  for (size_t h = 0; h < SC_LK_SHARDS; h++) {
    sc_lk_shard *s = &sc_lk_shards[h];
    s->lock = 0;
    sc_lk_shard_clear(s);
  }
}
void sc_lk_report_now(void) {
  if (sc_lk_on()) sc_lk_report();
}
/* Track from here on without an exit report (SC_LEAK_CHECK, when set, keeps its own state). Returns 1:
   the tracker counts (a runtime without one reports 0 through the driver's stand-in). */
int sc_lk_stats_enable(void) {
  sc_lk_on();
  if (sc_lk_state == 1) sc_lk_state = 2;
  return 1;
}
void sc_lk_epoch_set(uint32_t __e) { __atomic_store_n(&sc_lk_epoch, __e, __ATOMIC_RELAXED); }
/* out[0] allocation calls, out[1] bytes requested: the cumulative counters only (no table walk). */
void sc_lk_counts(uint64_t *__out) {
  __out[0] = 0;
  __out[1] = 0;
  for (size_t h = 0; h < SC_LK_SHARDS; h++) {
    sc_lk_shard *s = &sc_lk_shards[h];
    sc_lk_acquire(s);
    __out[0] += s->alloc_n;
    __out[1] += s->alloc_bytes;
    sc_lk_release(s);
  }
}
/* out[0] allocation calls, out[1] bytes requested, out[2 + 2e] / out[3 + 2e] live count / bytes of epoch e
   (epochs past SC_LK_EPOCHS - 1 fold into the last slot). All zero while tracking is off. */
void sc_lk_stats(uint64_t *__out) {
  memset(__out, 0, (2 + 2 * SC_LK_EPOCHS) * sizeof *__out);
  for (size_t h = 0; h < SC_LK_SHARDS; h++) {
    sc_lk_shard *s = &sc_lk_shards[h];
    sc_lk_acquire(s);
    __out[0] += s->alloc_n;
    __out[1] += s->alloc_bytes;
    for (size_t i = 0; i < s->cap; i++) {
      const sc_lk_ent *e = &s->tab[i];
      if (e->ptr == NULL) continue;
      size_t k = e->epoch < SC_LK_EPOCHS ? e->epoch : SC_LK_EPOCHS - 1;
      __out[2 + 2 * k] += 1;
      __out[3 + 2 * k] += e->size;
    }
    sc_lk_release(s);
  }
}
/* Insert under the held lock. An existing live entry means the block was freed behind the tracker's
   back and then reused. Returns 0 when bookkeeping memory ran out. */
static int sc_lk_insert(sc_lk_shard *s, const sc_lk_ent *e) {
  s->alloc_n++;
  s->alloc_bytes += e->size;
  sc_lk_ent *old = sc_lk_find(s, e->ptr);
  if (old != NULL) {
    s->bytes -= old->size;
    *old = *e;
    s->bytes += e->size;
    return 1;
  }
  if ((s->live + 1) * 10 >= s->cap * 7 && !sc_lk_grow(s)) return 0;
  sc_lk_put(s->tab, s->cap, e);
  s->live++;
  s->bytes += e->size;
  return 1;
}
void *sc_lk_malloc(size_t __n) {
  void *site = SC_LK_SITE();
  void *p = (malloc)(__n);
  if (p != NULL && sc_lk_on()) {
    sc_lk_ent e;
    sc_lk_capture(&e, p, __n, site);
    sc_lk_shard *s = sc_lk_shard_for(p);
    sc_lk_acquire(s);
    if (sc_lk_state >= 2 && !sc_lk_insert(s, &e)) sc_lk_disable();
    sc_lk_release(s);
  }
  return p;
}
void *sc_lk_calloc(size_t __n, size_t __m) {
  void *site = SC_LK_SITE();
  void *p = (calloc)(__n, __m);
  if (p != NULL && sc_lk_on()) {
    sc_lk_ent e;
    sc_lk_capture(&e, p, __n * __m, site);
    sc_lk_shard *s = sc_lk_shard_for(p);
    sc_lk_acquire(s);
    if (sc_lk_state >= 2 && !sc_lk_insert(s, &e)) sc_lk_disable();
    sc_lk_release(s);
  }
  return p;
}
void *sc_lk_realloc(void *__p, size_t __n) {
  void *site = SC_LK_SITE();
  /* The registry key is an ADDRESS, and an address survives the realloc that invalidates the pointer
     holding it: reading `__p` again after this call is undefined (and GCC's -Wuse-after-free says so).
     The lock is held ACROSS the realloc: the moment it returns, the old block is free for another
     thread to receive from malloc, so releasing between the call and the bookkeeping lets that
     thread's fresh entry at the same address be marked freed here -- a false use-after-free later. */
  const uintptr_t __pa = (uintptr_t)__p;
  int track = sc_lk_on();
  sc_lk_shard *held = NULL;
  sc_lk_ent *old = NULL;
  if (__p != NULL && track) {
    held = sc_lk_shard_for(__p);
    sc_lk_acquire(held);
  }
  if (__p != NULL && track && sc_lk_state >= 2) {
    old = sc_lk_find(held, __p);
    sc_lk_ent *freed = old == NULL ? sc_lk_find_freed(held, __p) : NULL;
    if (freed != NULL) {
      sc_lk_ent snap = *freed;
      held->dbl++;
      sc_lk_release(held);
      fprintf(stderr, "== super-c realloc of freed pointer: %p ==\n", __p);
      fprintf(stderr, "previously freed at:\n");
      sc_lk_site_print(snap.site);
      fprintf(stderr, "reallocated again at:\n");
      sc_lk_site_print(site);
      if (sc_lk_state == 3) abort();
      return sc_lk_malloc(__n); /* the old block is gone: hand back fresh memory */
    }
  }
  void *q = (realloc)(__p, __n);
  if (q != NULL && track && sc_lk_state >= 2) {
    sc_lk_ent e;
    sc_lk_capture(&e, q, __n, site);
    int was_tracked = 0;
    if (old != NULL) {
      sc_lk_ent consumed = *old;
      held->bytes -= old->size;
      held->live--;
      sc_lk_erase(held, old);
      sc_lk_remember_free(held, &consumed, site);
      was_tracked = 1;
    }
    /* memory the tracker never saw (a foreign allocator) stays untracked */
    if (was_tracked || __pa == 0) {
      sc_lk_shard *next = sc_lk_shard_for(q);
      if (next != held) {
        if (held != NULL) sc_lk_release(held);
        sc_lk_acquire(next);
        held = next;
      }
      if (sc_lk_state >= 2 && !sc_lk_insert(held, &e)) sc_lk_disable();
    }
  }
  if (held != NULL) sc_lk_release(held);
  return q;
}
void sc_lk_free(void *__p) {
  void *site = SC_LK_SITE();
  int skip = 0;
  if (__p != NULL && sc_lk_on()) {
    int dbl = 0;
    sc_lk_ent snap;
    snap.ptr = NULL;
    snap.size = 0;
    snap.site = NULL;
    sc_lk_shard *s = sc_lk_shard_for(__p);
    sc_lk_acquire(s);
    if (sc_lk_state >= 2) {
      sc_lk_ent *e = sc_lk_find(s, __p);
      if (e != NULL) {
        sc_lk_ent freed = *e;
        s->bytes -= e->size;
        s->live--;
        sc_lk_erase(s, e);
        sc_lk_remember_free(s, &freed, site);
      } else {
        sc_lk_ent *freed = sc_lk_find_freed(s, __p);
        if (freed != NULL) {
          snap = *freed;
          dbl = 1;
          skip = 1; /* the block may belong to someone else now: never free it twice */
          s->dbl++;
        }
      }
    }
    sc_lk_release(s);
    if (dbl) sc_lk_double(__p, &snap, site);
  }
  if (!skip) (free)(__p);
}
)".ptr() as *const char;
}
