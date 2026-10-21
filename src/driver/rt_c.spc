// The generated-C runtime strings: the C standard library include block every generated TU
// shares (super_rt.h) and the leak-tracker implementation TU (super_rt.c). Emission-agnostic:
// the driver writes them verbatim next to whatever backend produced the code.

/// Whether `super_rt.h` includes header `h` (spelled as an `extern "C"` block names it), so every
/// generated file sees it already.
pub fn rt_has_header(h: str) bool {
    let mut line = String::from_str("#include <");
    line.push_str(h);
    line.push_str(">\n");
    return unsafe str::from_cstr(super_rt_includes()).contains(line.as_str());
}

/// The full C standard library include block the generated runtime pulls in, emitted verbatim into
/// the shared super_rt.h together with the atomic shims, the
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
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
/* Memory order: the enum value (Relaxed=0,Acquire=1,Release=2,AcqRel=3,SeqCst=4) maps to the matching
   __ATOMIC_* constant. A ternary rather than a runtime order argument so a constant order folds to a
   single instruction at -O1+. An order the operation cannot take traps: a load and a compare-exchange
   failure take Relaxed, Acquire or SeqCst; a store takes Relaxed, Release or SeqCst; a read-modify-write,
   a compare-exchange success and a fence take all five. SC_MO_CAS strengthens the success order to at
   least the failure order, as the C builtin requires. */
_Noreturn void __sc_trap_order(void);
#define SC_MO_BAD (__sc_trap_order(), __ATOMIC_SEQ_CST)
#define SC_MO_RMW(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==1?__ATOMIC_ACQUIRE:(mo)==2?__ATOMIC_RELEASE:(mo)==3?__ATOMIC_ACQ_REL:(mo)==4?__ATOMIC_SEQ_CST:SC_MO_BAD)
#define SC_MO_LD(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==1?__ATOMIC_ACQUIRE:(mo)==4?__ATOMIC_SEQ_CST:SC_MO_BAD)
#define SC_MO_ST(mo) ((mo)==0?__ATOMIC_RELAXED:(mo)==2?__ATOMIC_RELEASE:(mo)==4?__ATOMIC_SEQ_CST:SC_MO_BAD)
#define SC_MO_CAS(so,fo) ((unsigned)(so)>4u?SC_MO_BAD:SC_MO_RMW((fo)==4?4:(fo)==1&&(so)==0?1:(fo)==1&&(so)==2?3:(so)))
/* The aarch64 `target` attribute of a function's features: clang adds extensions (`+dotprod`); GCC
   names the architecture level too (`arch=armv8.2-a+dotprod`), since binutils assembles an extension's
   instructions only at its level. */
#ifdef __clang__
#define SC_TGT_A64(c, g) c
#else
#define SC_TGT_A64(c, g) g
#endif
/* A static in a named section (`@unsafe(link_section)`) is the section's entry: clang's AddressSanitizer
   would pad it with a redzone, which in an init array is an entry with no target, a link error. GCC does
   not instrument such a static and rejects the attribute on a variable. */
#ifdef __clang__
#define SC_SECTION_DATA __attribute__((no_sanitize("address")))
#else
#define SC_SECTION_DATA
#endif
#define SC_AT(T,S) \
static inline T __sc_atomic_load_##S(const T*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));} \
static inline void __sc_atomic_store_##S(T*p,T v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));} \
static inline T __sc_atomic_swap_##S(T*p,T v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_add_##S(T*p,T v,int mo){return __atomic_fetch_add(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_sub_##S(T*p,T v,int mo){return __atomic_fetch_sub(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_and_##S(T*p,T v,int mo){return __atomic_fetch_and(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_or_##S(T*p,T v,int mo){return __atomic_fetch_or(p,v,SC_MO_RMW(mo));} \
static inline T __sc_atomic_xor_##S(T*p,T v,int mo){return __atomic_fetch_xor(p,v,SC_MO_RMW(mo));} \
static inline bool __sc_atomic_cas_##S(T*p,T e,T d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_CAS(so,fo),SC_MO_LD(fo));}
SC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)
SC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)
#undef SC_AT
static inline bool __sc_atomic_load_bool(const bool*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));}
static inline void __sc_atomic_store_bool(bool*p,bool v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));}
static inline bool __sc_atomic_swap_bool(bool*p,bool v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));}
static inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_CAS(so,fo),SC_MO_LD(fo));}
static inline void __sc_atomic_fence(int mo){__atomic_thread_fence(SC_MO_RMW(mo));}
#undef SC_MO_BAD
#undef SC_MO_RMW
#undef SC_MO_LD
#undef SC_MO_ST
#undef SC_MO_CAS
#pragma GCC diagnostic pop
#endif
/* Task attribution: a coroutine runtime stores the running task's id here, so a panic names the task it
   happened in rather than just the process. Zero on a plain thread. */
extern _Thread_local uint64_t __sc_task_id;
void __sc_set_task_id(uint64_t __id);
/* The traps, defined once in super_rt.c (a static copy would land in every object): a message on
   stderr, then abort. `__sc_assert_fail` is the failure path of `assert`, out of line so a function
   that asserts stays small enough for the C compiler to inline. */
_Noreturn __attribute__((cold)) void __sc_panic(const char *__m);
_Noreturn __attribute__((cold)) void __sc_panic_str(const uint8_t *__p, size_t __n);
_Noreturn __attribute__((cold, noinline, format(printf, 1, 2))) void __sc_assert_fail(const char *__f, ...);
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
/* Integer arithmetic the C operators do not give (language skill, operations.md). + - * and signed
   negation trap on overflow, or wrap modulo the width when the build defines SC_ARITH_WRAP (a profile
   without overflow checks). Division and remainder by zero, signed MIN / -1 and MIN % -1, and shifts by a
   negative count or by the width or more trap in every build. Narrow unsigned results truncate to their
   width (C computes them in int). U is an unsigned type at least as wide as int and as T. */
#define SC_AI static __attribute__((unused)) inline
#ifdef SC_ARITH_WRAP
#define SC_ARITH_OVF(T, U, S) \
SC_AI T __sc_add_##S(T __a, T __b) { return (T)(U)((U)__a + (U)__b); } \
SC_AI T __sc_sub_##S(T __a, T __b) { return (T)(U)((U)__a - (U)__b); } \
SC_AI T __sc_mul_##S(T __a, T __b) { return (T)(U)((U)__a * (U)__b); }
#define SC_ARITH_NEG(T, U, S) SC_AI T __sc_neg_##S(T __a) { return (T)(U)(0u - (U)__a); }
#else
#define SC_ARITH_OVF(T, U, S) \
SC_AI T __sc_add_##S(T __a, T __b) { T __r; if (__builtin_add_overflow(__a, __b, &__r)) __sc_panic("attempt to add with overflow"); return __r; } \
SC_AI T __sc_sub_##S(T __a, T __b) { T __r; if (__builtin_sub_overflow(__a, __b, &__r)) __sc_panic("attempt to subtract with overflow"); return __r; } \
SC_AI T __sc_mul_##S(T __a, T __b) { T __r; if (__builtin_mul_overflow(__a, __b, &__r)) __sc_panic("attempt to multiply with overflow"); return __r; }
#define SC_ARITH_NEG(T, U, S) SC_AI T __sc_neg_##S(T __a) { T __r; if (__builtin_sub_overflow((T)0, __a, &__r)) __sc_panic("attempt to negate with overflow"); return __r; }
#endif
#define SC_ARITH_SHIFT(T, U, S) \
SC_AI T __sc_shl_##S(T __a, uint64_t __c) { if (__c >= sizeof(T) * 8) __sc_panic("attempt to shift left with overflow"); return (T)(U)((U)__a << __c); } \
SC_AI T __sc_shr_##S(T __a, uint64_t __c) { if (__c >= sizeof(T) * 8) __sc_panic("attempt to shift right with overflow"); return (T)(__a >> __c); }
#define SC_ARITH_SIGNED(T, U, S, MIN) SC_ARITH_OVF(T, U, S) SC_ARITH_NEG(T, U, S) SC_ARITH_SHIFT(T, U, S) \
SC_AI T __sc_div_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to divide by zero"); if (__b == -1 && __a == MIN) __sc_panic("attempt to divide with overflow"); return (T)(__a / __b); } \
SC_AI T __sc_rem_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to calculate the remainder with a divisor of zero"); if (__b == -1 && __a == MIN) __sc_panic("attempt to calculate the remainder with overflow"); return (T)(__a % __b); }
#define SC_ARITH_UNSIGNED(T, U, S) SC_ARITH_OVF(T, U, S) SC_ARITH_SHIFT(T, U, S) \
SC_AI T __sc_not_##S(T __a) { return (T)~(U)__a; } \
SC_AI T __sc_div_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to divide by zero"); return (T)(__a / __b); } \
SC_AI T __sc_rem_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to calculate the remainder with a divisor of zero"); return (T)(__a % __b); }
/* Float to integer `as` saturates: NaN is 0, a value past either end is that end. */
#define SC_F2I_SIGNED(T, S, MIN, MAX) \
SC_AI T __sc_f2i_##S(double __x) { return __x != __x ? (T)0 : __x <= (double)MIN ? (T)MIN : __x >= (double)MAX + 1.0 ? (T)MAX : (T)__x; }
#define SC_F2I_UNSIGNED(T, S, MAX) \
SC_AI T __sc_f2i_##S(double __x) { return !(__x > 0) ? (T)0 : __x >= (double)MAX + 1.0 ? (T)MAX : (T)__x; }
SC_ARITH_SIGNED(int8_t, uint32_t, i8, INT8_MIN) SC_ARITH_SIGNED(int16_t, uint32_t, i16, INT16_MIN)
SC_ARITH_SIGNED(int32_t, uint32_t, i32, INT32_MIN) SC_ARITH_SIGNED(int64_t, uint64_t, i64, INT64_MIN)
SC_ARITH_SIGNED(intptr_t, uintptr_t, isize, INTPTR_MIN)
SC_ARITH_UNSIGNED(uint8_t, uint32_t, u8) SC_ARITH_UNSIGNED(uint16_t, uint32_t, u16)
SC_ARITH_UNSIGNED(uint32_t, uint32_t, u32) SC_ARITH_UNSIGNED(uint64_t, uint64_t, u64)
SC_ARITH_UNSIGNED(size_t, size_t, usize)
SC_F2I_SIGNED(int8_t, i8, INT8_MIN, INT8_MAX) SC_F2I_SIGNED(int16_t, i16, INT16_MIN, INT16_MAX)
SC_F2I_SIGNED(int32_t, i32, INT32_MIN, INT32_MAX) SC_F2I_SIGNED(int64_t, i64, INT64_MIN, INT64_MAX)
SC_F2I_SIGNED(intptr_t, isize, INTPTR_MIN, INTPTR_MAX)
SC_F2I_UNSIGNED(uint8_t, u8, UINT8_MAX) SC_F2I_UNSIGNED(uint16_t, u16, UINT16_MAX)
SC_F2I_UNSIGNED(uint32_t, u32, UINT32_MAX) SC_F2I_UNSIGNED(uint64_t, u64, UINT64_MAX)
SC_F2I_UNSIGNED(size_t, usize, SIZE_MAX) SC_F2I_UNSIGNED(char, char, UCHAR_MAX)
#undef SC_AI
#undef SC_ARITH_OVF
#undef SC_ARITH_NEG
#undef SC_ARITH_SHIFT
#undef SC_ARITH_SIGNED
#undef SC_ARITH_UNSIGNED
#undef SC_F2I_SIGNED
#undef SC_F2I_UNSIGNED
/* Pointer distance over a zero-sized element type: bytes cannot encode an element count. */
_Noreturn __attribute__((cold)) void __sc_zst_ptrdiff(void);
/* Preemption hook, installed by the scheduler BEFORE it starts any worker, so every read of it
   happens-after that write and no synchronization is needed here. */
extern void (*__sc_pre_hook)(void);
void __sc_set_preempt_hook(void (*__f)(void));
/* The stack-overflow report (super_rt.c) that ffi/sc_runtime.spc arms each thread with: the thread's stack
   bounds when known, the signal stack to release at its end (or null), the task stack size the message
   quotes, and on Windows the report of an exhausted coroutine stack. */
void *__sc_stack_arm(uintptr_t __lo, uintptr_t __hi);
void __sc_stack_disarm(void *__alt);
void __sc_stack_task_size(size_t __b);
void __sc_stack_overflow(void);
/* Cold half of the function-local safepoint tick (`__sc_spc` in emitted bodies): runs the hook
   check and hands back the reset value, so the hot path is one register decrement + branch. */
static inline __attribute__((unused)) int32_t __sc_preempt_check(void) {
  if (__sc_pre_hook) __sc_pre_hook();
  return 2048;
}
/* Strip-mined counted loop (IN_CHUNK): the exclusive end of the chunk that starts at `__i`
   (`__i < __end`, the loop's induction values as 64-bit two's complement). The safepoint before it
   counted the chunk's first iteration; the others fit the budget left and are charged here, so the
   chunk's backedges need no tick and a tick still comes at most every 2048 iterations. */
static inline __attribute__((unused)) uint64_t __sc_chunk_end(int32_t *__spc, uint64_t __i, uint64_t __end) {
  uint64_t __n = __end - __i;
  if (__n > (uint64_t)*__spc) __n = (uint64_t)*__spc;
  *__spc -= (int32_t)(__n - 1U);
  return __i + __n;
}
/* Cancellation half of a combined safepoint (emitted only on its cold path): asks the runtime
   whether the current task has an unmasked pending cancellation, ACCEPTING it on yes -- the
   emitted branch then enters the frame's cancellation ladder. Inert (null) until the scheduler installs
   it, before it starts any worker. */
extern int32_t (*__sc_cancel_hook)(void);
void __sc_set_cancel_hook(int32_t (*__f)(void));
static inline __attribute__((unused)) int32_t __sc_cancel_tick(void) {
  return __sc_cancel_hook ? __sc_cancel_hook() : 0;
}
/* reflection registry (super_rt.c): the registry TU's constructor registers its static table of the
   `@reflect`-tagged concrete types' exported `sc_typeinfo_<name>` descriptors. External tools dlopen
   the binary and walk the SAME static descriptors the program reads: __sc_reflect_types yields the
   registered pointers (each a `const TypeInfo *`; layout per std/core.spc, policed by the emitted
   layout asserts). The runtime keeps only the table's address: no copy, no capacity, no allocation. */
void __sc_reflect_register(const void *const *__roots, size_t __n);
const void *const *__sc_reflect_types(size_t *__n);
/* leak tracker (super_rt.c): interposes the emitted code's malloc/realloc/free call sites.
   Inert unless the SC_LEAK_CHECK environment variable is set; compile with -DSC_NO_LEAK_CHECK to
   drop the interposition entirely (super_rt.c still links: the coroutine runtime calls sc_lk_bt_*). */
void *sc_lk_malloc(size_t __n);
void *sc_lk_calloc(size_t __n, size_t __m);
void *sc_lk_realloc(void *__p, size_t __n);
void sc_lk_free(void *__p);
/* Over-aligned blocks (std's Global allocator): `__align` is a power of two, at least sizeof(void *). */
void *sc_lk_aligned_alloc(size_t __n, size_t __align);
void sc_lk_aligned_free(void *__p);
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
/* The bit counts, wrapping arithmetic and 128-bit fast paths std binds without a header: the C
   backend's primitives. */
/* Bit counts for the built-in integer methods in core.spc (`trailing_zeros`, `leading_zeros`,
   `count_ones`). The GCC/Clang builtins lower to the target's instruction (x86 tzcnt/lzcnt/popcnt or a
   short sequence, aarch64 rbit+clz/cnt, wasm i64.ctz/i64.clz/i64.popcnt). The builtins are undefined
   for a zero input, so the zero case is explicit: 64 bits. The IR interpreter models these three names
   for compile-time evaluation. */
static inline uint32_t sc_ctz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_ctzll(sc_x) : 64u; }
static inline uint32_t sc_clz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_clzll(sc_x) : 64u; }
static inline uint32_t sc_popcount64(uint64_t sc_x) { return (uint32_t)__builtin_popcountll(sc_x); }
/* The 64 bits of `sc_x` in reverse order (vector `reverse_bits`): swap halves, then bytes, then bits. */
static inline uint64_t sc_bitrev64(uint64_t sc_x) {
  sc_x = __builtin_bswap64(sc_x);
  sc_x = (sc_x & 0x0F0F0F0F0F0F0F0FULL) << 4 | (sc_x >> 4 & 0x0F0F0F0F0F0F0F0FULL);
  sc_x = (sc_x & 0x3333333333333333ULL) << 2 | (sc_x >> 2 & 0x3333333333333333ULL);
  return (sc_x & 0x5555555555555555ULL) << 1 | (sc_x >> 1 & 0x5555555555555555ULL);
}
/* Wrapping arithmetic for the built-in integer methods in core.spc (`wrapping_*`, `overflowing_*`,
   `checked_*`, `saturating_*`): C's unsigned operators, modulo 2^64 in every profile; a narrower method
   truncates the result. A shift count is below 64. `sc_mulo_*` tell whether the full product overflows 64
   bits. The IR interpreter models these names for compile-time evaluation. */
static inline uint64_t sc_wadd64(uint64_t sc_a, uint64_t sc_b) { return sc_a + sc_b; }
static inline uint64_t sc_wsub64(uint64_t sc_a, uint64_t sc_b) { return sc_a - sc_b; }
static inline uint64_t sc_wmul64(uint64_t sc_a, uint64_t sc_b) { return sc_a * sc_b; }
static inline uint64_t sc_wshl64(uint64_t sc_a, uint32_t sc_n) { return sc_a << sc_n; }
static inline uint64_t sc_wshr64(uint64_t sc_a, uint32_t sc_n) { return sc_a >> sc_n; }
static inline int64_t sc_wsar64(int64_t sc_a, uint32_t sc_n) { return sc_a >> sc_n; }
static inline bool sc_mulo_u64(uint64_t sc_a, uint64_t sc_b) { uint64_t sc_r; return __builtin_mul_overflow(sc_a, sc_b, &sc_r); }
static inline bool sc_mulo_i64(int64_t sc_a, int64_t sc_b) { int64_t sc_r; return __builtin_mul_overflow(sc_a, sc_b, &sc_r); }
/* Native 128-bit fast path for std's UInt<128>/Int<128> (see int.spc). Where the C compiler building
   the emitted code has a 128-bit integer type, sc_has_i128() folds to 1 and these replace the limb
   loops; where it does not, it folds to 0, the limb code stands, and the stubs are never reached.
   Limbs pass as explicit 64-bit halves, least significant first, so byte order never enters into it. */
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wpedantic" /* gcc: ISO C does not support __int128 */
#endif
#if defined(__SIZEOF_INT128__)
static inline int sc_has_i128(void) { return 1; }
static inline void sc_i128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_c) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_s = sc_a + ((unsigned __int128)sc_bh << 64 | sc_bl);
  *sc_rl = (uint64_t)sc_s; *sc_rh = (uint64_t)(sc_s >> 64); *sc_c = sc_s < sc_a;
}
static inline void sc_i128_sub(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_b) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_y = (unsigned __int128)sc_bh << 64 | sc_bl;
  unsigned __int128 sc_d = sc_a - sc_y;
  *sc_rl = (uint64_t)sc_d; *sc_rh = (uint64_t)(sc_d >> 64); *sc_b = sc_a < sc_y;
}
static inline void sc_i128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_hl, uint64_t *sc_hh) {
  /* The full 256-bit product from four 64x64 partials. sc_m1 cannot overflow (at most 2^128 - 2^64 - 1);
     sc_m2 can, and its carry sits 128 bits up, inside sc_hi's headroom. */
  unsigned __int128 sc_p0 = (unsigned __int128)sc_al * sc_bl;
  unsigned __int128 sc_m1 = (unsigned __int128)sc_al * sc_bh + (uint64_t)(sc_p0 >> 64);
  unsigned __int128 sc_m2 = sc_m1 + (unsigned __int128)sc_ah * sc_bl;
  unsigned __int128 sc_hi = (unsigned __int128)sc_ah * sc_bh + (uint64_t)(sc_m2 >> 64) + ((unsigned __int128)(sc_m2 < sc_m1) << 64);
  *sc_rl = (uint64_t)sc_p0; *sc_rh = (uint64_t)sc_m2;
  *sc_hl = (uint64_t)sc_hi; *sc_hh = (uint64_t)(sc_hi >> 64);
}
static inline void sc_i128_divmod(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_ql, uint64_t *sc_qh, uint64_t *sc_rl, uint64_t *sc_rh) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_b = (unsigned __int128)sc_bh << 64 | sc_bl;
  unsigned __int128 sc_q = sc_a / sc_b, sc_r = sc_a % sc_b;
  *sc_ql = (uint64_t)sc_q; *sc_qh = (uint64_t)(sc_q >> 64);
  *sc_rl = (uint64_t)sc_r; *sc_rh = (uint64_t)(sc_r >> 64);
}
/* The full 64x64 product: the low half returned, the high half stored. */
static inline uint64_t sc_mul64(uint64_t sc_a, uint64_t sc_b, uint64_t *sc_hi) {
  unsigned __int128 sc_p = (unsigned __int128)sc_a * sc_b;
  *sc_hi = (uint64_t)(sc_p >> 64);
  return (uint64_t)sc_p;
}
/* (sc_u1 : sc_u0) / sc_v for sc_u1 < sc_v: the quotient fits one limb. */
static inline uint64_t sc_div128by64(uint64_t sc_u1, uint64_t sc_u0, uint64_t sc_v, uint64_t *sc_r) {
  unsigned __int128 sc_u = (unsigned __int128)sc_u1 << 64 | sc_u0;
  *sc_r = (uint64_t)(sc_u % sc_v);
  return (uint64_t)(sc_u / sc_v);
}
#else
static inline int sc_has_i128(void) { return 0; }
static inline uint64_t sc_mul64(uint64_t sc_a, uint64_t sc_b, uint64_t *sc_hi) {
  (void)sc_a; (void)sc_b; (void)sc_hi; abort();
}
static inline uint64_t sc_div128by64(uint64_t sc_u1, uint64_t sc_u0, uint64_t sc_v, uint64_t *sc_r) {
  (void)sc_u1; (void)sc_u0; (void)sc_v; (void)sc_r; abort();
}
static inline void sc_i128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_c) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_c; abort();
}
static inline void sc_i128_sub(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_b) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_b; abort();
}
static inline void sc_i128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_hl, uint64_t *sc_hh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_hl; (void)sc_hh; abort();
}
static inline void sc_i128_divmod(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_ql, uint64_t *sc_qh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_ql; (void)sc_qh; (void)sc_rl; (void)sc_rh; abort();
}
#endif
/* Overflow in std's Int<N> and UInt<N> operators: the built-in trap (`__sc_panic` from super_rt.h), or a
   return when the build wraps (-DSC_ARITH_WRAP), and the operator then keeps its wrapped value. A zero
   divisor and MIN / -1 trap in every profile, as the built-in `/` and `%` do. The IR interpreter models
   these three names for compile-time evaluation. */
static inline void sc_int_overflow(const uint8_t *sc_m) {
#ifdef SC_ARITH_WRAP
  (void)sc_m;
#else
  __sc_panic((const char *)sc_m);
#endif
}
static inline void sc_int_div_zero(const uint8_t *sc_m) { __sc_panic((const char *)sc_m); }
static inline void sc_int_div_overflow(const uint8_t *sc_m) { __sc_panic((const char *)sc_m); }
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
/* Native binary128 fast path for std's f128 (`Float<15, 112>`, see float.spc). Where the C compiler
   building the emitted code has an IEEE binary128 type (`__float128`, or a `long double` with a
   113-bit significand), sc_has_f128() folds to 1 and these replace the limb code for add, multiply
   and divide: correctly rounded, so the same bits (NaN aside, which float.spc canonicalizes). The
   operations are the compiler's runtime (libgcc's `__addtf3` and the like, or hardware). Where it has
   none, sc_has_f128() folds to 0, the limb code stands, and the stubs are never reached. Values pass
   as explicit 64-bit halves of the encoding, least significant first. */
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wpedantic" /* gcc: ISO C does not support __float128 */
#endif
#if defined(__SIZEOF_FLOAT128__)
#define SC_F128_NATIVE 1
typedef __float128 sc_f128;
#elif defined(__LDBL_MANT_DIG__) && __LDBL_MANT_DIG__ == 113
#define SC_F128_NATIVE 1
typedef long double sc_f128;
#endif
#ifdef SC_F128_NATIVE
static inline int sc_has_f128(void) { return 1; }
static inline sc_f128 sc_f128_of(uint64_t sc_lo, uint64_t sc_hi) {
  uint64_t sc_w[2];
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  sc_w[0] = sc_hi; sc_w[1] = sc_lo;
#else
  sc_w[0] = sc_lo; sc_w[1] = sc_hi;
#endif
  sc_f128 sc_v;
  memcpy(&sc_v, sc_w, sizeof sc_v);
  return sc_v;
}
static inline void sc_f128_out(sc_f128 sc_v, uint64_t *sc_lo, uint64_t *sc_hi) {
  uint64_t sc_w[2];
  memcpy(sc_w, &sc_v, sizeof sc_w);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  *sc_lo = sc_w[1]; *sc_hi = sc_w[0];
#else
  *sc_lo = sc_w[0]; *sc_hi = sc_w[1];
#endif
}
static inline void sc_f128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) + sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
static inline void sc_f128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) * sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
static inline void sc_f128_div(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) / sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
#else
static inline int sc_has_f128(void) { return 0; }
static inline void sc_f128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
static inline void sc_f128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
static inline void sc_f128_div(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
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
/* The test-timeout dump below enumerates threads (mach on macOS, /proc and tgkill on Linux). */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <limits.h>
#include <stdarg.h>
#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <malloc.h>
#endif

/* The language's char is unsigned; every compile of the generated tree passes -funsigned-char. */
_Static_assert(CHAR_MIN == 0, "super-c: compile the generated C with -funsigned-char");

#if defined(_WIN32)
/* Windows opens the standard streams in text mode, which writes "\n" as "\r\n" and folds "\r\n" to
   "\n" on read. Every program switches them to binary before main: its standard streams carry the
   same bytes on every host. */
__attribute__((constructor)) static void __sc_binary_stdio(void) {
  (void)_setmode(_fileno(stdin), _O_BINARY);
  (void)_setmode(_fileno(stdout), _O_BINARY);
  (void)_setmode(_fileno(stderr), _O_BINARY);
}
#endif

/* ASan's use-after-return check moves frames to a fake stack, where GCC (13.3 to 15) places an object
   aligned above 32 bytes 32 bytes off: an AVX-512 build faults on its aligned moves. The fake stack is
   off by default. An illegal instruction (a jump through a corrupt code address) gets ASan's report, with
   the faulting pc and the stack, instead of a bare SIGILL. ASAN_OPTIONS still overrides both. */
#if defined(__SANITIZE_ADDRESS__)
#define SC_RT_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define SC_RT_ASAN 1
#endif
#endif
#if defined(SC_RT_ASAN)
const char *__asan_default_options(void) { return "detect_stack_use_after_return=0:handle_sigill=1"; }
#endif
/* Bound by ffi/sc_runtime.spc: ASan's redzones make frames larger, and the coroutine runtime sizes its default
   task stack by this. */
int sc_rt_asan(void) {
#if defined(SC_RT_ASAN)
  return 1;
#else
  return 0;
#endif
}

/* Task id of the coroutine running on this thread (see super_rt.h); 0 = none. */
_Thread_local uint64_t __sc_task_id = 0;
void __sc_set_task_id(uint64_t __id) { __sc_task_id = __id; }

/* The traps super_rt.h declares. abort() does not flush, and stdout and stderr are block-buffered when
   captured into a pipe or a file: the output printed before the trap and the diagnostic these print are
   then lost. Flush both first. */
_Noreturn __attribute__((cold)) void __sc_panic(const char *__m) {
  if (__sc_task_id) fprintf(stderr, "super-c: [task %llu] %s\n", (unsigned long long)__sc_task_id, __m);
  else fprintf(stderr, "super-c: %s\n", __m);
  fflush(NULL);
  abort();
}
_Noreturn __attribute__((cold)) void __sc_panic_str(const uint8_t *__p, size_t __n) {
  if (__sc_task_id) fprintf(stderr, "panic: [task %llu] %.*s\n", (unsigned long long)__sc_task_id, (int)__n, (const char *)__p);
  else fprintf(stderr, "panic: %.*s\n", (int)__n, (const char *)__p);
  fflush(NULL);
  abort();
}
_Noreturn __attribute__((cold, noinline, format(printf, 1, 2))) void __sc_assert_fail(const char *__f, ...) {
  va_list __a;
  va_start(__a, __f);
  vfprintf(stderr, __f, __a);
  va_end(__a);
  fflush(NULL);
  abort();
}
_Noreturn void __sc_trap_order(void) {
  __sc_panic("invalid memory order");
}
_Noreturn __attribute__((cold)) void __sc_zst_ptrdiff(void) {
  __sc_panic("pointer distance on a zero-sized element type");
}

/* Stack overflow report. A stack that runs into its guard faults, and without a handler the process dies
   on a bare SIGSEGV or SIGBUS. This prints which stack ran out and exits with 134, the status of the abort
   a panic ends in (the test runner reads both as a panic). The main thread is armed before main; std's
   runtime arms every thread it starts (`__sc_stack_arm`, ffi/sc_runtime.spc). On POSIX an armed thread runs the
   handler on a signal stack of its own, since the faulting stack has no room left, and the base of that
   signal stack records the bounds of the thread's own stack. The handler finds the record through
   sigaltstack, so it reads no thread-local storage before it knows the thread is armed. A fault is an
   overflow when its address is in the guard region below the running thread's own stack or, while the
   thread runs on another stack (a coroutine's), within SC_STK_NEAR of the stack pointer. Any other fault
   goes to the handler installed before this one, else to the default action: a wild pointer still
   crashes as one, and under AddressSanitizer gets ASan's report. Windows raises EXCEPTION_STACK_OVERFLOW
   for an exhausted stack only: a vectored handler reports it, and every armed thread keeps a stack
   guarantee for the report to run in. Every function the handlers call is async-signal-safe. */
#if !defined(__wasm__)
static size_t __sc_stk_task = 0; /* the task stack size std's runtime hands out, for the message only */
void __sc_stack_task_size(size_t __b) { __atomic_store_n(&__sc_stk_task, __b, __ATOMIC_RELAXED); }
static size_t __sc_stk_put(char *__b, size_t __n, const char *__s) {
  while (*__s != 0 && __n < 255) __b[__n++] = *__s++;
  return __n;
}
static size_t __sc_stk_num(char *__b, size_t __n, uint64_t __v) {
  char d[24];
  int i = 23;
  d[i] = 0;
  do {
    d[--i] = (char)('0' + __v % 10);
    __v /= 10;
  } while (__v != 0);
  return __sc_stk_put(__b, __n, d + i);
}
/* The report, into a 256-byte `__b` so it reaches stderr in one write: `__task` when the running
   coroutine's stack ran out, else the thread's own stack, of `__size` bytes when known. */
static size_t __sc_stk_text(char *__b, int __task, int __main, uint64_t __size) {
  size_t n = __sc_stk_put(__b, 0, "\nsuper-c: ");
  const uint64_t id = __sc_task_id;
  if (id != 0) {
    n = __sc_stk_put(__b, n, "\133task "); /* '[' and ']' as escapes: this text's matchers must pair */
    n = __sc_stk_num(__b, n, id);
    n = __sc_stk_put(__b, n, "\135 ");
  }
  n = __sc_stk_put(__b, n, "stack overflow");
  const size_t ts = __atomic_load_n(&__sc_stk_task, __ATOMIC_RELAXED);
  if (__task && ts != 0) {
    n = __sc_stk_put(__b, n, " (");
    n = __sc_stk_num(__b, n, ts);
    n = __sc_stk_put(__b, n, " byte task stack exhausted; raise it with runtime::set_stack_size)");
  } else if (!__task) {
    n = __sc_stk_put(__b, n, __main ? " in the main thread" : " in a thread");
    if (__size != 0) {
      n = __sc_stk_put(__b, n, " (");
      n = __sc_stk_num(__b, n, __size);
      n = __sc_stk_put(__b, n, " byte stack)");
    }
  }
  return __sc_stk_put(__b, n, "\n");
}
#endif
#if defined(_WIN32)
/* kernel32, declared by hand as GetModuleHandleA is: <windows.h> is not included here. */
void *AddVectoredExceptionHandler(unsigned long __first, long (*__h)(void *));
int SetThreadStackGuarantee(unsigned long *__bytes);
unsigned long GetCurrentThreadId(void);
void GetCurrentThreadStackLimits(uintptr_t *__lo, uintptr_t *__hi);
void *GetStdHandle(unsigned long __which);
int WriteFile(void *__h, const void *__p, unsigned long __n, unsigned long *__done, void *__ov);
void *GetCurrentProcess(void);
int TerminateProcess(void *__p, unsigned __code);
static unsigned long __sc_stk_main_id = 0;
static void __sc_stk_report(int __task) {
  char b[256];
  uintptr_t lo = 0, hi = 0;
  if (!__task) GetCurrentThreadStackLimits(&lo, &hi);
  const size_t n = __sc_stk_text(b, __task, GetCurrentThreadId() == __sc_stk_main_id, hi - lo);
  unsigned long w = 0;
  WriteFile(GetStdHandle((unsigned long)-12), b, (unsigned long)n, &w, 0); /* STD_ERROR_HANDLE */
  /* Not ExitProcess: its DLL detach and CRT teardown would run on the exhausted stack. */
  TerminateProcess(GetCurrentProcess(), 134);
}
/* A coroutine stack ran out (ffi/sc_runtime.spc grows and guards those itself). */
void __sc_stack_overflow(void) { __sc_stk_report(1); }
/* `__ep` is the EXCEPTION_POINTERS; its first member points at the EXCEPTION_RECORD, whose first member
   is the code. */
static long __sc_stk_veh(void *__ep) {
  if (**(const unsigned long *const *)__ep == 0xC00000FDul) __sc_stk_report(0); /* EXCEPTION_STACK_OVERFLOW */
  return 0; /* EXCEPTION_CONTINUE_SEARCH */
}
/* The stack the report runs in once the guard is gone: the exception record alone, with its AVX-512
   register state, fills the page the system leaves. */
void *__sc_stack_arm(uintptr_t __lo, uintptr_t __hi) {
  (void)__lo;
  (void)__hi;
  unsigned long g = 16384;
  (void)SetThreadStackGuarantee(&g);
  return 0;
}
void __sc_stack_disarm(void *__alt) { (void)__alt; }
__attribute__((constructor)) static void __sc_stk_boot(void) {
  __sc_stk_main_id = GetCurrentThreadId();
  (void)AddVectoredExceptionHandler(0, __sc_stk_veh);
  (void)__sc_stack_arm(0, 0);
}
#elif defined(__wasm__)
/* No signals: the engine reports an exhausted call stack itself. */
#else
#include <signal.h>
#include <stddef.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#include <sys/auxv.h>
#include <sys/ucontext.h>
#endif
#define SC_STK_MAGIC 0x31544b535f4353ull /* "SC_STK1" */
/* A fault this close to the stack pointer is the stack running out: wider than any frame that stays
   near its guard, far narrower than where a wild pointer lands. */
#define SC_STK_NEAR ((uintptr_t)128 << 10)
/* Around a stack's low end: its guard (glibc counted the guard into the stack, pages may be 64 KiB),
   and how far below it a frame has already moved the stack pointer at the fault where no probe touches
   the frame first (Linux). Smaller than a coroutine stack, so a coroutine stack mapped just below a
   worker's own stack does not read as the worker's. */
#define SC_STK_SLACK ((uintptr_t)64 << 10)
typedef struct {
  uint64_t magic;
  uintptr_t lo, hi; /* the thread's own stack runs from lo up to hi; lo == 0 when unknown */
  uint64_t main;
} __sc_stk_rec;
static int __sc_stk_on = 0; /* the handler is installed */
static size_t __sc_stk_alt = 0; /* bytes of each signal stack */
static struct sigaction __sc_stk_prev[2]; /* SIGSEGV's and SIGBUS's actions before this one */
static _Thread_local void *__sc_stk_mine = 0; /* this thread's signal stack */
/* Signal stacks of ended threads, for the next armed thread: a fresh mapping, its first touch and its
   unmap cost about 2 us of each thread's start. Each slot is taken and filled with one atomic operation,
   so the cache needs no lock; at most SC_STK_CACHE stacks wait in it, the rest are unmapped. */
#define SC_STK_CACHE 64
static void *__sc_stk_cache[SC_STK_CACHE];
static void *__sc_stk_take(void) {
  for (int i = 0; i < SC_STK_CACHE; i++) {
    void *m = __atomic_exchange_n(&__sc_stk_cache[i], (void *)0, __ATOMIC_ACQUIRE);
    if (m != 0) return m;
  }
  return 0;
}
static void __sc_stk_give(void *__m) {
  for (int i = 0; i < SC_STK_CACHE; i++) {
    void *none = 0;
    if (__atomic_compare_exchange_n(&__sc_stk_cache[i], &none, __m, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED))
      return;
  }
  munmap(__m, __sc_stk_alt);
}

/* The calling thread's stack, when it can be known without reading /proc. The main thread's on Linux
   from its size limit and its top, where the kernel copies the program's path (AT_EXECFN):
   pthread_getattr_np would read /proc/self/maps and needs libpthread on older glibc. */
static void __sc_stk_bounds(uintptr_t *__lo, uintptr_t *__hi, int __main) {
#if defined(__APPLE__)
  (void)__main;
  pthread_t t = pthread_self();
  *__hi = (uintptr_t)pthread_get_stackaddr_np(t);
  *__lo = *__hi - (uintptr_t)pthread_get_stacksize_np(t);
#elif defined(__linux__)
  struct rlimit rl;
  const char *top = __main ? (const char *)getauxval(AT_EXECFN) : 0;
  if (top == 0 || getrlimit(RLIMIT_STACK, &rl) != 0 || rl.rlim_cur == RLIM_INFINITY) return;
  const uintptr_t pg = (uintptr_t)sysconf(_SC_PAGESIZE);
  const uintptr_t hi = ((uintptr_t)top + strlen(top) + pg) & ~(pg - 1);
  if ((uintptr_t)rl.rlim_cur >= hi) return;
  *__hi = hi;
  *__lo = hi - (uintptr_t)rl.rlim_cur;
#else
  (void)__lo;
  (void)__hi;
  (void)__main;
#endif
}

/* The stack pointer at the fault, from the signal context; 0 where the layout is not known. */
static uintptr_t __sc_stk_sp(void *__uc) {
#if defined(__APPLE__)
  /* Darwin hands the handler a context aligned to 8 bytes while its type asks for 16: read the two
     fields as bytes, not through the misaligned types. */
  const char *mc;
  uint64_t sp;
  memcpy(&mc, (const char *)__uc + offsetof(ucontext_t, uc_mcontext), sizeof mc);
#if defined(__aarch64__)
  memcpy(&sp, mc + offsetof(struct __darwin_mcontext64, __ss.__sp), sizeof sp);
#else
  memcpy(&sp, mc + offsetof(struct __darwin_mcontext64, __ss.__rsp), sizeof sp);
#endif
  return (uintptr_t)sp;
#elif defined(__linux__) && defined(__aarch64__)
  return (uintptr_t)((ucontext_t *)__uc)->uc_mcontext.sp;
#elif defined(__linux__) && defined(__x86_64__)
  return (uintptr_t)((ucontext_t *)__uc)->uc_mcontext.gregs[REG_RSP];
#else
  (void)__uc;
  return 0;
#endif
}

static void __sc_stk_fault(int __sig, siginfo_t *__si, void *__uc) {
  stack_t cur;
  const __sc_stk_rec *r = 0;
  if (sigaltstack(0, &cur) == 0 && (cur.ss_flags & SS_ONSTACK) != 0 && cur.ss_size >= sizeof *r &&
      ((const __sc_stk_rec *)cur.ss_sp)->magic == SC_STK_MAGIC)
    r = (const __sc_stk_rec *)cur.ss_sp;
  const int code = __si->si_code;
  const int fault = __sig == SIGSEGV ? code == SEGV_MAPERR || code == SEGV_ACCERR
                                     : code == BUS_ADRALN || code == BUS_ADRERR || code == BUS_OBJERR;
  if (r != 0 && fault) {
    const uintptr_t a = (uintptr_t)__si->si_addr;
    const uintptr_t sp = __sc_stk_sp(__uc);
    const int near = sp != 0 && (a > sp ? a - sp : sp - a) < SC_STK_NEAR;
    const uintptr_t floor = r->lo > SC_STK_SLACK ? r->lo - SC_STK_SLACK : 0;
    const int own = r->lo != 0 && sp >= floor && sp < r->hi;
    const int guard = r->lo != 0 && a >= floor && a < r->lo + SC_STK_SLACK;
    /* On its own stack, the thread overflowed when the fault is at the guard, or near the stack pointer
       below the top (the Linux main thread grows until another mapping stops it). */
    if ((own || sp == 0) ? (guard || (own && near && a >= floor && a < r->hi)) : near) {
      char b[256];
      const int task = !own && sp != 0 && __sc_task_id != 0; /* off the thread's stack: a coroutine's */
      const size_t n = __sc_stk_text(b, task, r->main != 0, own ? r->hi - r->lo : 0);
      const ssize_t w = write(2, b, n);
      (void)w;
      _exit(134);
    }
  }
  const struct sigaction *p = &__sc_stk_prev[__sig == SIGSEGV ? 0 : 1];
  if ((p->sa_flags & SA_SIGINFO) != 0 && p->sa_sigaction != 0) {
    p->sa_sigaction(__sig, __si, __uc);
    return;
  }
  if ((p->sa_flags & SA_SIGINFO) == 0 && p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) {
    p->sa_handler(__sig);
    return;
  }
  struct sigaction d;
  memset(&d, 0, sizeof d);
  d.sa_handler = SIG_DFL;
  sigemptyset(&d.sa_mask);
  sigaction(__sig, &d, 0);
  raise(__sig);
}

static void *__sc_stk_arm(uintptr_t __lo, uintptr_t __hi, uint64_t __main) {
  /* Reading the thread-local first also has macOS allocate this thread's block here, never in the
     handler (which reads __sc_task_id). */
  if (__sc_stk_mine != 0 || !__atomic_load_n(&__sc_stk_on, __ATOMIC_ACQUIRE)) return 0;
  const size_t sz = __sc_stk_alt;
  void *m = __sc_stk_take();
  if (m == 0) m = mmap(0, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (m == MAP_FAILED) return 0;
  if (__lo == 0) __sc_stk_bounds(&__lo, &__hi, __main != 0);
  __sc_stk_rec *r = (__sc_stk_rec *)m;
  r->magic = SC_STK_MAGIC;
  r->lo = __lo;
  r->hi = __hi;
  r->main = __main;
  stack_t ss;
  memset(&ss, 0, sizeof ss);
  ss.ss_sp = m;
  ss.ss_size = sz;
  stack_t old;
  if (sigaltstack(&ss, &old) != 0) {
    __sc_stk_give(m);
    return 0;
  }
#if defined(SC_RT_ASAN)
  /* ASan gives each thread a signal stack and unmaps the one in place when the thread ends: this one
     replaces ASan's, which nothing else frees. */
  if ((old.ss_flags & SS_DISABLE) == 0 && old.ss_sp != 0) munmap(old.ss_sp, old.ss_size);
#else
  (void)old;
#endif
  __sc_stk_mine = m;
  return m;
}
/* Arm the calling thread, its stack from __lo up to __hi when the caller knows it (0, 0 otherwise).
   Returns the signal stack to release with `__sc_stack_disarm` when the thread ends, or 0 when nothing
   was armed: no handler, already armed, or no memory. */
void *__sc_stack_arm(uintptr_t __lo, uintptr_t __hi) { return __sc_stk_arm(__lo, __hi, 0); }
void __sc_stack_disarm(void *__alt) {
#if defined(SC_RT_ASAN)
  /* ASan's end of the thread unmaps the signal stack in place: it stays, and the cache never holds one. */
  (void)__alt;
#else
  stack_t ss;
  memset(&ss, 0, sizeof ss);
  ss.ss_flags = SS_DISABLE;
  ss.ss_size = __sc_stk_alt; /* Darwin checks the size even when disabling */
  sigaltstack(&ss, 0);
  __sc_stk_give(__alt);
#endif
}
/* An illegal instruction is a jump through a corrupt code address, or code for a CPU feature this one
   lacks: the report names the address, then the handler installed before, else the default action, ends
   the process (its status still says SIGILL). Async-signal-safe, as the overflow handler. */
static struct sigaction __sc_ill_prev;
static void __sc_ill_fault(int __sig, siginfo_t *__si, void *__uc) {
  char b[64];
  size_t n = __sc_stk_put(b, 0, "\nsuper-c: illegal instruction at 0x");
  const uintptr_t a = (uintptr_t)__si->si_addr;
  for (int s = (int)sizeof a * 8 - 4; s >= 0; s -= 4) b[n++] = "0123456789abcdef"[(a >> s) & 15];
  b[n++] = '\n';
  const ssize_t w = write(2, b, n);
  (void)w;
  if ((__sc_ill_prev.sa_flags & SA_SIGINFO) != 0 && __sc_ill_prev.sa_sigaction != 0) {
    __sc_ill_prev.sa_sigaction(__sig, __si, __uc);
    return;
  }
  if ((__sc_ill_prev.sa_flags & SA_SIGINFO) == 0 && __sc_ill_prev.sa_handler != SIG_DFL && __sc_ill_prev.sa_handler != SIG_IGN) {
    __sc_ill_prev.sa_handler(__sig);
    return;
  }
  struct sigaction d;
  memset(&d, 0, sizeof d);
  d.sa_handler = SIG_DFL;
  sigemptyset(&d.sa_mask);
  sigaction(__sig, &d, 0);
  raise(__sig);
}
__attribute__((constructor)) static void __sc_stk_boot(void) {
  struct sigaction ill;
  memset(&ill, 0, sizeof ill);
  ill.sa_sigaction = __sc_ill_fault;
  ill.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&ill.sa_mask);
  (void)sigaction(SIGILL, &ill, &__sc_ill_prev);
  const size_t pg = (size_t)sysconf(_SC_PAGESIZE);
  const size_t want = (size_t)SIGSTKSZ < 65536 ? 65536 : (size_t)SIGSTKSZ;
  __sc_stk_alt = (want + pg - 1) & ~(pg - 1);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = __sc_stk_fault;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGSEGV, &sa, &__sc_stk_prev[0]) != 0) return;
#if defined(__APPLE__)
  (void)sigaction(SIGBUS, &sa, &__sc_stk_prev[1]); /* macOS reports a guard-page hit as SIGBUS */
#endif
  __atomic_store_n(&__sc_stk_on, 1, __ATOMIC_RELEASE);
  (void)__sc_stk_arm(0, 0, 1);
}
#endif

/* Preemption hook (see super_rt.h). Inert until a scheduler installs it. */
void (*__sc_pre_hook)(void) = 0;
/* Installed by a scheduler before it starts any worker, so every safepoint's read happens-after it. */
void __sc_set_preempt_hook(void (*__f)(void)) { __sc_pre_hook = __f; }
/* Combined-safepoint cancellation hook (see super_rt.h), installed the same way. */
int32_t (*__sc_cancel_hook)(void) = 0;
void __sc_set_cancel_hook(int32_t (*__f)(void)) { __sc_cancel_hook = __f; }

/* Reflection registry (see super_rt.h): the registry TU's root table, recorded by its constructor
   before main. */
static const void *const *__sc_refl = 0;
static size_t __sc_refl_n = 0;
void __sc_reflect_register(const void *const *__roots, size_t __n) {
  __sc_refl = __roots;
  __sc_refl_n = __n;
}
const void *const *__sc_reflect_types(size_t *__n) {
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
void *sc_lk_aligned_alloc(size_t __n, size_t __align);
void sc_lk_aligned_free(void *__p);
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
  uint32_t aligned; /* 1: from sc_lk_aligned_alloc, released by sc_lk_release_block */
} sc_lk_ent;
/* Release block `e` with the call matching its allocation (Windows over-aligned blocks need _aligned_free). */
static void sc_lk_release_block(const sc_lk_ent *e) {
#if defined(_WIN32)
  if (e->aligned) {
    _aligned_free(e->ptr);
    return;
  }
#endif
  (free)(e->ptr);
}
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
static int sc_lk_state; /* 0 = unprobed, 1 = off, 2 = report, 3 = fatal; atomic: any thread probes it */
static uint32_t sc_lk_epoch; /* tag for every allocation recorded from now on (sc_lk_epoch_set) */
static int sc_lk_get(void) { return __atomic_load_n(&sc_lk_state, __ATOMIC_RELAXED); }
static void sc_lk_set(int __st) { __atomic_store_n(&sc_lk_state, __st, __ATOMIC_RELAXED); }
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
/* Drop a shard's table, counters and freed history, releasing the blocks the history holds (the lock word
   is left to the caller). */
static void sc_lk_shard_clear(sc_lk_shard *s) {
  for (size_t i = 0; i < s->freed_count; i++) sc_lk_release_block(&s->freed[i]);
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
/* The history keeps its blocks allocated and frees each one only when a newer entry evicts it. No allocator,
   the tracked one or a foreign one, can hand out a held address, so a later free or realloc of an address
   in the history is always a real double free, never a reused block. */
static void sc_lk_remember_free(sc_lk_shard *s, const sc_lk_ent *entry, void *site) {
  if (s->freed_count == SC_LK_FREED_HISTORY) sc_lk_release_block(&s->freed[s->freed_next]);
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
  e->aligned = 0;
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
  if (sc_lk_get() == 3) {
    fflush(NULL);
    abort();
  }
}
static void sc_lk_disable(void) {
  sc_lk_set(1);
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
  int enabled = sc_lk_get() >= 2;
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
  int fatal = enabled && sc_lk_get() == 3;
  sc_lk_set(1); /* the report's own prints may allocate: stop tracking */
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
  if (fatal && (n != 0 || dbl != 0)) {
    fflush(NULL); /* _Exit does not flush */
    _Exit(23);
  }
}
static int sc_lk_on(void) {
  int cur = sc_lk_get();
  if (cur == 0) {
    const char *e = getenv("SC_LEAK_CHECK");
    int st = 1;
    if (e != NULL && e[0] != '\0' && e[0] != '0') st = (e[0] == 'f' || e[0] == 'F') ? 3 : 2;
    /* One probe wins the move out of the unprobed state, so the exit report is registered once. */
    if (__atomic_compare_exchange_n(&sc_lk_state, &cur, st, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
      if (st >= 2) atexit(sc_lk_report);
      cur = st;
    }
  }
  return cur >= 2;
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
#if !defined(_WIN32) && !defined(__wasm__)
/* Test-timeout diagnostics. A process whose environment names a file in SC_TEST_DIAG (the test runner sets
   it in each test's process; every process the test starts inherits it) answers SIGURG by appending
   to that file a header naming itself and the stack of each of its threads, one thread at a time, each
   asked with SIGUSR2. SIGURG is ignored by default, so the runner can ask every process of a test's tree:
   one that is not a Super-C program (cc, ld) ignores it. The handlers use only open/write/close,
   backtrace and short sleeps: the process is killed after it. Elsewhere SIGURG keeps its default. */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#elif defined(__linux__)
#include <dirent.h>
#include <sys/syscall.h>
#endif
static char sc_diag_path[1024];
static int sc_diag_fd = -1;
static volatile sig_atomic_t sc_diag_ack;
static void sc_diag_say(const char *s) {
  ssize_t r = write(sc_diag_fd, s, strlen(s));
  (void)r;
}
static void sc_diag_num(long v) {
  char b[24];
  int i = 23;
  b[i] = 0;
  do {
    b[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v > 0 && i > 0);
  sc_diag_say(b + i);
}
static void sc_diag_stack(int sig) {
  (void)sig;
#ifdef SC_LK_SYMS
  void *f[64];
  const int n = backtrace(f, 64);
  sc_diag_say("--- thread\n");
  backtrace_symbols_fd(f, n, sc_diag_fd);
#else
  sc_diag_say("--- thread (no backtrace on this platform)\n");
#endif
  sc_diag_ack = 1;
}
#if defined(__APPLE__) || defined(__linux__)
/* Ask one other thread for its stack and wait for it, at most half a second. */
static void sc_diag_ask(int (*send)(void *), void *t) {
  sc_diag_ack = 0;
  if (send(t) != 0) return;
  struct timespec ms = { 0, 1000000 };
  for (int i = 0; i < 500 && !sc_diag_ack; i++) nanosleep(&ms, NULL);
  if (!sc_diag_ack) sc_diag_say("--- thread (did not answer: it blocks the signal)\n");
}
#if defined(__APPLE__)
static int sc_diag_send(void *t) { return pthread_kill((pthread_t)t, SIGUSR2); }
#else
static int sc_diag_send(void *t) { return (int)syscall(SYS_tgkill, getpid(), (pid_t)(intptr_t)t, SIGUSR2); }
#endif
#endif
static void sc_diag_dump(int sig) {
  (void)sig;
  sc_diag_fd = open(sc_diag_path, O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (sc_diag_fd < 0) return;
  sc_diag_say("\n--- process ");
  sc_diag_num((long)getpid());
#if defined(__APPLE__) || defined(__ANDROID__)
  sc_diag_say(" ");
  sc_diag_say(getprogname());
#elif defined(__linux__)
  sc_diag_say(" ");
  sc_diag_say(program_invocation_short_name);
#endif
  sc_diag_say(": the stack of every thread\n");
  sc_diag_stack(0);
#if defined(__APPLE__)
  thread_act_array_t th;
  mach_msg_type_number_t nth = 0;
  if (task_threads(mach_task_self(), &th, &nth) == KERN_SUCCESS) {
    for (mach_msg_type_number_t i = 0; i < nth; i++) {
      pthread_t t = pthread_from_mach_thread_np(th[i]);
      if (t != NULL && !pthread_equal(t, pthread_self())) sc_diag_ask(sc_diag_send, (void *)t);
      mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof th[0]);
  }
#elif defined(__linux__)
  DIR *d = opendir("/proc/self/task");
  if (d != NULL) {
    const pid_t self = (pid_t)syscall(SYS_gettid);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
      const pid_t tid = (pid_t)atoi(e->d_name);
      if (tid > 0 && tid != self) sc_diag_ask(sc_diag_send, (void *)(intptr_t)tid);
    }
    closedir(d);
  }
#endif
  close(sc_diag_fd);
  sc_diag_fd = -1;
}
/* Install the dump when SC_TEST_DIAG names a file: at startup, and again by the test runner once it has
   set the variable in a test's process. */
void __sc_diag_install(void) {
  const char *p = getenv("SC_TEST_DIAG");
  if (p == NULL || p[0] == 0 || strlen(p) >= sizeof sc_diag_path) return;
  memcpy(sc_diag_path, p, strlen(p) + 1);
#ifdef SC_LK_SYMS
  void *f[1];
  (void)backtrace(f, 1); /* the first call loads the unwinder, which allocates: never in a handler */
#endif
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sa.sa_handler = sc_diag_stack;
  sigaction(SIGUSR2, &sa, NULL);
  sa.sa_handler = sc_diag_dump;
  sigaction(SIGURG, &sa, NULL);
}
__attribute__((constructor)) static void __sc_diag_boot(void) { __sc_diag_install(); }
#else
void __sc_diag_install(void) {}
#endif
/* Track from here on without an exit report (SC_LEAK_CHECK, when set, keeps its own state). Returns 1:
   the tracker counts (a runtime without one reports 0 through the driver's stand-in). */
int sc_lk_stats_enable(void) {
  sc_lk_on();
  int off = 1;
  __atomic_compare_exchange_n(&sc_lk_state, &off, 2, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
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
/* Record new block `p` of `n` bytes allocated at `site`. */
static void sc_lk_track(void *p, size_t n, void *site, uint32_t aligned) {
  if (p != NULL && sc_lk_on()) {
    sc_lk_ent e;
    sc_lk_capture(&e, p, n, site);
    e.aligned = aligned;
    sc_lk_shard *s = sc_lk_shard_for(p);
    sc_lk_acquire(s);
    if (sc_lk_get() >= 2 && !sc_lk_insert(s, &e)) sc_lk_disable();
    sc_lk_release(s);
  }
}
void *sc_lk_malloc(size_t __n) {
  void *site = SC_LK_SITE();
  void *p = (malloc)(__n);
  sc_lk_track(p, __n, site, 0);
  return p;
}
void *sc_lk_calloc(size_t __n, size_t __m) {
  void *site = SC_LK_SITE();
  void *p = (calloc)(__n, __m);
  sc_lk_track(p, __n * __m, site, 0);
  return p;
}
void *sc_lk_aligned_alloc(size_t __n, size_t __align) {
  void *site = SC_LK_SITE();
#if defined(_WIN32)
  void *p = _aligned_malloc(__n, __align);
#else
  /* C11 aligned_alloc takes a size that is a multiple of the alignment. */
  void *p = __n > SIZE_MAX - __align ? NULL : aligned_alloc(__align, (__n + __align - 1) & ~(__align - 1));
#endif
  sc_lk_track(p, __n, site, 1);
  return p;
}
void *sc_lk_realloc(void *__p, size_t __n) {
  void *site = SC_LK_SITE();
  /* The registry key is an ADDRESS, and an address survives the realloc that invalidates the pointer
     holding it: reading `__p` again after a realloc is undefined (and GCC's -Wuse-after-free says so).
     A tracked block therefore never goes through realloc: it is copied into a new block and the freed
     history keeps the old one allocated, so no other thread can receive its address before the
     bookkeeping below is done. Only untracked blocks go through realloc. */
  const uintptr_t __pa = (uintptr_t)__p;
  int track = sc_lk_on();
  sc_lk_shard *held = NULL;
  sc_lk_ent *old = NULL;
  if (__p != NULL && track) {
    held = sc_lk_shard_for(__p);
    sc_lk_acquire(held);
  }
  if (__p != NULL && track && sc_lk_get() >= 2) {
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
      if (sc_lk_get() == 3) {
        fflush(NULL);
        abort();
      }
      /* the history still holds the old block: hand back fresh memory with its contents */
      void *fresh = sc_lk_malloc(__n);
      if (fresh != NULL) memcpy(fresh, __p, snap.size < __n ? snap.size : __n);
      return fresh;
    }
  }
  void *q;
  if (old != NULL) {
    /* A tracked block moves, and the old one goes to the freed history, which keeps it allocated. */
    q = (malloc)(__n);
    if (q != NULL) memcpy(q, __p, old->size < __n ? old->size : __n);
  } else {
    q = (realloc)(__p, __n);
  }
  if (q != NULL && track && sc_lk_get() >= 2) {
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
      if (sc_lk_get() >= 2 && !sc_lk_insert(held, &e)) sc_lk_disable();
    }
  }
  if (held != NULL) sc_lk_release(held);
  return q;
}
/* Unrecord block `__p` freed at `site`, reporting a double free. Returns 1 when the caller must not
   release the block: the freed history holds it, or it was freed before. */
static int sc_lk_untrack(void *__p, void *site) {
  int skip = 0;
  if (__p != NULL && sc_lk_on()) {
    int dbl = 0;
    sc_lk_ent snap;
    snap.ptr = NULL;
    snap.size = 0;
    snap.site = NULL;
    sc_lk_shard *s = sc_lk_shard_for(__p);
    sc_lk_acquire(s);
    if (sc_lk_get() >= 2) {
      sc_lk_ent *e = sc_lk_find(s, __p);
      if (e != NULL) {
        sc_lk_ent freed = *e;
        s->bytes -= e->size;
        s->live--;
        sc_lk_erase(s, e);
        sc_lk_remember_free(s, &freed, site);
        skip = 1; /* the history holds the block */
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
  return skip;
}
void sc_lk_free(void *__p) {
  if (!sc_lk_untrack(__p, SC_LK_SITE())) (free)(__p);
}
void sc_lk_aligned_free(void *__p) {
  if (sc_lk_untrack(__p, SC_LK_SITE())) return;
#if defined(_WIN32)
  _aligned_free(__p);
#else
  (free)(__p);
#endif
}
)".ptr() as *const char;
}
