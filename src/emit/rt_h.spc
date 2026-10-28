// The runtime header of the C backend, `super_rt.h`: the C standard library includes every generated
// file shares, the atomic shims, the bounds and arithmetic helpers the emitted code calls inline, the 128-bit
// fast paths std binds without a header, and the prototypes of the runtime entry points the emitted code
// calls (std/rt/base.spc defines them). The C emitter owns it: another backend lowers these helpers itself.

/// Whether `super_rt.h` includes header `h` (spelled as an `extern "C"` block names it), so every
/// generated file sees it already.
pub(package) fn rt_has_header(h: str) bool {
    let mut line = String::from_str("#include <");
    line.push_str(h);
    line.push_str(">\n");
    return super_rt_h().contains(line.as_str());
}

/// Whether `super_rt.h` defines function `name` itself (a helper std binds without a header, as
/// `sc_ctz64`): the emitted C must not declare it again, since a declaration without `inline` would make
/// the unit's inline definition an external one.
pub(package) const fn rt_defines(name: str) bool {
    for line in super_rt_h().lines() {
        if line.starts_with("inline ") {
            let open = line.find_byte(b'(');
            if open > 0 {
                let head = line.slice(0, open as usize);
                if head.len() > name.len() && head.ends_with(name) && head.byte_at(head.len() - name.len() - 1) == b' ' {
                    return true;
                }
            }
        }
    }
    return false;
}

/// The text of `super_rt.h`, without its include guard.
pub(package) const fn super_rt_h() str<'static> {
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
/* The language's char is unsigned: every compile of the generated tree passes -funsigned-char. */
_Static_assert(CHAR_MIN == 0, "super-c: compile the generated C with -funsigned-char");
/* wasm's C library (std/rt/libc.spc) cannot define the standard streams and the clocks, which its
   headers declare as `const` objects: the stream names reach them through its `sc_stdio_stream`, and a
   clock is its WASI clock id plus one, which its `clock_gettime` reads. */
#ifdef __wasi__
FILE *sc_stdio_stream(int32_t __fd);
#undef stdin
#undef stdout
#undef stderr
#define stdin (sc_stdio_stream(0))
#define stdout (sc_stdio_stream(1))
#define stderr (sc_stdio_stream(2))
#undef CLOCK_REALTIME
#undef CLOCK_MONOTONIC
#define CLOCK_REALTIME ((clockid_t)(uintptr_t)1)
#define CLOCK_MONOTONIC ((clockid_t)(uintptr_t)2)
#endif
/* Every helper below has external linkage, so an inline function with external linkage may call it
   (C11 6.7.4p3). Each unit holds an inline definition; the registry unit expands SC_RT_EXTERNS (at the
   end), whose declarations make its definitions the external ones (C11 6.7.4p7) whatever the order of
   its includes (a precompiled header, a unity or pack file). */
#define SC_RT_X(N) extern __typeof__(N) N;
#if defined(__GNUC__) || defined(__clang__)
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
/* The same for a function with SME features: GCC 15 compiles SME only with SVE2 enabled, GCC 13 has no
   SME (`g13` leaves the SME features out). */
#ifdef __clang__
#define SC_TGT_A64_SME(c, g, g13) c
#elif __GNUC__ >= 15
#define SC_TGT_A64_SME(c, g, g13) g "+sve2"
#elif __GNUC__ >= 14
#define SC_TGT_A64_SME(c, g, g13) g
#else
#define SC_TGT_A64_SME(c, g, g13) g13
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
inline T __sc_atomic_load_##S(const T*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));} \
inline void __sc_atomic_store_##S(T*p,T v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));} \
inline T __sc_atomic_swap_##S(T*p,T v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));} \
inline T __sc_atomic_add_##S(T*p,T v,int mo){return __atomic_fetch_add(p,v,SC_MO_RMW(mo));} \
inline T __sc_atomic_sub_##S(T*p,T v,int mo){return __atomic_fetch_sub(p,v,SC_MO_RMW(mo));} \
inline T __sc_atomic_and_##S(T*p,T v,int mo){return __atomic_fetch_and(p,v,SC_MO_RMW(mo));} \
inline T __sc_atomic_or_##S(T*p,T v,int mo){return __atomic_fetch_or(p,v,SC_MO_RMW(mo));} \
inline T __sc_atomic_xor_##S(T*p,T v,int mo){return __atomic_fetch_xor(p,v,SC_MO_RMW(mo));} \
inline bool __sc_atomic_cas_##S(T*p,T e,T d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_CAS(so,fo),SC_MO_LD(fo));}
#define SC_AT_TYPES(X) X(int8_t,i8) X(int16_t,i16) X(int32_t,i32) X(int64_t,i64) X(intptr_t,isize) \
X(uint8_t,u8) X(uint16_t,u16) X(uint32_t,u32) X(uint64_t,u64) X(size_t,usize)
SC_AT_TYPES(SC_AT)
#undef SC_AT
#define SC_AT_NAMES(T,S) SC_RT_X(__sc_atomic_load_##S) SC_RT_X(__sc_atomic_store_##S) SC_RT_X(__sc_atomic_swap_##S) \
SC_RT_X(__sc_atomic_add_##S) SC_RT_X(__sc_atomic_sub_##S) SC_RT_X(__sc_atomic_and_##S) SC_RT_X(__sc_atomic_or_##S) \
SC_RT_X(__sc_atomic_xor_##S) SC_RT_X(__sc_atomic_cas_##S)
#define SC_RT_ATOMIC_NAMES SC_AT_TYPES(SC_AT_NAMES) SC_RT_X(__sc_atomic_load_bool) SC_RT_X(__sc_atomic_store_bool) \
SC_RT_X(__sc_atomic_swap_bool) SC_RT_X(__sc_atomic_cas_bool) SC_RT_X(__sc_atomic_fence)
inline bool __sc_atomic_load_bool(const bool*p,int mo){return __atomic_load_n(p,SC_MO_LD(mo));}
inline void __sc_atomic_store_bool(bool*p,bool v,int mo){__atomic_store_n(p,v,SC_MO_ST(mo));}
inline bool __sc_atomic_swap_bool(bool*p,bool v,int mo){return __atomic_exchange_n(p,v,SC_MO_RMW(mo));}
inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d,bool wk,int so,int fo){return __atomic_compare_exchange_n(p,&e,d,wk,SC_MO_CAS(so,fo),SC_MO_LD(fo));}
inline void __sc_atomic_fence(int mo){__atomic_thread_fence(SC_MO_RMW(mo));}
#undef SC_MO_BAD
#undef SC_MO_RMW
#undef SC_MO_LD
#undef SC_MO_ST
#undef SC_MO_CAS
#else
#define SC_RT_ATOMIC_NAMES
#endif
/* The traps, defined once by the runtime (std/rt/base.spc): a message on stderr, then abort.
   `__sc_assert_fail` is the failure path of `assert`, out of line so a function that asserts stays small
   enough for the C compiler to inline: it prints `__head`, the `__n` bytes at `__m` and `__tail`. */
_Noreturn __attribute__((cold)) void __sc_panic(const char *__m);
_Noreturn __attribute__((cold)) void __sc_panic_str(const uint8_t *__p, size_t __n);
_Noreturn __attribute__((cold)) void __sc_panic_str2(const uint8_t *__p, size_t __n, const uint8_t *__q, size_t __m);
_Noreturn __attribute__((cold, noinline)) void __sc_assert_fail(const char *__head, const uint8_t *__m, size_t __n, const char *__tail);
inline size_t __sc_bounds(size_t __i, size_t __n) {
  if (__i >= __n) __sc_panic("index out of bounds");
  return __i;
}
/* Range validation for safe slicing: proves start <= end <= len BEFORE any pointer arithmetic
   and returns the exclusive end. */
inline size_t __sc_range(size_t __s, size_t __e, size_t __n) {
  if (__s > __e || __e > __n) __sc_panic("range out of bounds");
  return __e;
}
/* Coalesced element checks: index + width <= len in overflow-safe form; returns the index. */
inline size_t __sc_bounds_group(size_t __i, size_t __n, size_t __w) {
  if (__i > __n || __w > __n - __i) __sc_panic("index out of bounds");
  return __i;
}
/* A widened panic guard's test (IN_GROUP_FITS): index + width <= len in overflow-safe form. */
inline bool __sc_fits(size_t __i, size_t __n, size_t __w) {
  return __i <= __n && __w <= __n - __i;
}
/* Integer arithmetic the C operators do not give (language skill, operations.md). + - * and signed
   negation trap on overflow, or wrap modulo the width when the build defines SC_ARITH_WRAP (a profile
   without overflow checks). Division and remainder by zero, signed MIN / -1 and MIN % -1, and shifts by a
   negative count or by the width or more trap in every build. Narrow unsigned results truncate to their
   width (C computes them in int). U is an unsigned type at least as wide as int and as T. */
#ifdef SC_ARITH_WRAP
#define SC_ARITH_OVF(T, U, S) \
inline T __sc_add_##S(T __a, T __b) { return (T)(U)((U)__a + (U)__b); } \
inline T __sc_sub_##S(T __a, T __b) { return (T)(U)((U)__a - (U)__b); } \
inline T __sc_mul_##S(T __a, T __b) { return (T)(U)((U)__a * (U)__b); }
#define SC_ARITH_NEG(T, U, S) inline T __sc_neg_##S(T __a) { return (T)(U)(0u - (U)__a); }
#else
#define SC_ARITH_OVF(T, U, S) \
inline T __sc_add_##S(T __a, T __b) { T __r; if (__builtin_add_overflow(__a, __b, &__r)) __sc_panic("attempt to add with overflow"); return __r; } \
inline T __sc_sub_##S(T __a, T __b) { T __r; if (__builtin_sub_overflow(__a, __b, &__r)) __sc_panic("attempt to subtract with overflow"); return __r; } \
inline T __sc_mul_##S(T __a, T __b) { T __r; if (__builtin_mul_overflow(__a, __b, &__r)) __sc_panic("attempt to multiply with overflow"); return __r; }
#define SC_ARITH_NEG(T, U, S) inline T __sc_neg_##S(T __a) { T __r; if (__builtin_sub_overflow((T)0, __a, &__r)) __sc_panic("attempt to negate with overflow"); return __r; }
#endif
#define SC_ARITH_SHIFT(T, U, S) \
inline T __sc_shl_##S(T __a, uint64_t __c) { if (__c >= sizeof(T) * 8) __sc_panic("attempt to shift left with overflow"); return (T)(U)((U)__a << __c); } \
inline T __sc_shr_##S(T __a, uint64_t __c) { if (__c >= sizeof(T) * 8) __sc_panic("attempt to shift right with overflow"); return (T)(__a >> __c); }
#define SC_ARITH_SIGNED(T, U, S, MIN) SC_ARITH_OVF(T, U, S) SC_ARITH_NEG(T, U, S) SC_ARITH_SHIFT(T, U, S) \
inline T __sc_div_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to divide by zero"); if (__b == -1 && __a == MIN) __sc_panic("attempt to divide with overflow"); return (T)(__a / __b); } \
inline T __sc_rem_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to calculate the remainder with a divisor of zero"); if (__b == -1 && __a == MIN) __sc_panic("attempt to calculate the remainder with overflow"); return (T)(__a % __b); }
#define SC_ARITH_UNSIGNED(T, U, S) SC_ARITH_OVF(T, U, S) SC_ARITH_SHIFT(T, U, S) \
inline T __sc_not_##S(T __a) { return (T)~(U)__a; } \
inline T __sc_div_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to divide by zero"); return (T)(__a / __b); } \
inline T __sc_rem_##S(T __a, T __b) { if (__b == 0) __sc_panic("attempt to calculate the remainder with a divisor of zero"); return (T)(__a % __b); }
/* Float to integer `as` saturates: NaN is 0, a value past either end is that end. */
#define SC_F2I_SIGNED(T, S, MIN, MAX) \
inline T __sc_f2i_##S(double __x) { return __x != __x ? (T)0 : __x <= (double)MIN ? (T)MIN : __x >= (double)MAX + 1.0 ? (T)MAX : (T)__x; }
#define SC_F2I_UNSIGNED(T, S, MAX) \
inline T __sc_f2i_##S(double __x) { return !(__x > 0) ? (T)0 : __x >= (double)MAX + 1.0 ? (T)MAX : (T)__x; }
#define SC_SIGNED_TYPES(X) X(int8_t, uint32_t, i8, INT8_MIN) X(int16_t, uint32_t, i16, INT16_MIN) \
X(int32_t, uint32_t, i32, INT32_MIN) X(int64_t, uint64_t, i64, INT64_MIN) X(intptr_t, uintptr_t, isize, INTPTR_MIN)
#define SC_UNSIGNED_TYPES(X) X(uint8_t, uint32_t, u8) X(uint16_t, uint32_t, u16) X(uint32_t, uint32_t, u32) \
X(uint64_t, uint64_t, u64) X(size_t, size_t, usize)
#define SC_F2I_SIGNED_TYPES(X) X(int8_t, i8, INT8_MIN, INT8_MAX) X(int16_t, i16, INT16_MIN, INT16_MAX) \
X(int32_t, i32, INT32_MIN, INT32_MAX) X(int64_t, i64, INT64_MIN, INT64_MAX) X(intptr_t, isize, INTPTR_MIN, INTPTR_MAX)
#define SC_F2I_UNSIGNED_TYPES(X) X(uint8_t, u8, UINT8_MAX) X(uint16_t, u16, UINT16_MAX) X(uint32_t, u32, UINT32_MAX) \
X(uint64_t, u64, UINT64_MAX) X(size_t, usize, SIZE_MAX) X(char, char, UCHAR_MAX)
SC_SIGNED_TYPES(SC_ARITH_SIGNED)
SC_UNSIGNED_TYPES(SC_ARITH_UNSIGNED)
SC_F2I_SIGNED_TYPES(SC_F2I_SIGNED)
SC_F2I_UNSIGNED_TYPES(SC_F2I_UNSIGNED)
#define SC_SIGNED_NAMES(T, U, S, MIN) SC_RT_X(__sc_add_##S) SC_RT_X(__sc_sub_##S) SC_RT_X(__sc_mul_##S) \
SC_RT_X(__sc_neg_##S) SC_RT_X(__sc_shl_##S) SC_RT_X(__sc_shr_##S) SC_RT_X(__sc_div_##S) SC_RT_X(__sc_rem_##S)
#define SC_UNSIGNED_NAMES(T, U, S) SC_RT_X(__sc_add_##S) SC_RT_X(__sc_sub_##S) SC_RT_X(__sc_mul_##S) \
SC_RT_X(__sc_shl_##S) SC_RT_X(__sc_shr_##S) SC_RT_X(__sc_not_##S) SC_RT_X(__sc_div_##S) SC_RT_X(__sc_rem_##S)
#define SC_F2I_SIGNED_NAMES(T, S, MIN, MAX) SC_RT_X(__sc_f2i_##S)
#define SC_F2I_UNSIGNED_NAMES(T, S, MAX) SC_RT_X(__sc_f2i_##S)
#undef SC_ARITH_OVF
#undef SC_ARITH_NEG
#undef SC_ARITH_SHIFT
#undef SC_ARITH_SIGNED
#undef SC_ARITH_UNSIGNED
#undef SC_F2I_SIGNED
#undef SC_F2I_UNSIGNED
/* Pointer distance over a zero-sized element type: bytes cannot encode an element count. */
_Noreturn __attribute__((cold)) void __sc_zst_ptrdiff(void);
/* Cold half of the function-local safepoint tick (`__sc_spc` in emitted bodies), in the runtime: runs the
   scheduler's preemption hook and hands back the reset value, so the hot path is one register decrement
   and a branch. */
int32_t __sc_preempt_check(void);
/* Strip-mined counted loop (IN_CHUNK): the exclusive end of the chunk that starts at `__i`
   (`__i < __end`, the loop's induction values as 64-bit two's complement). The safepoint before it
   counted the chunk's first iteration; the others fit the budget left and are charged here, so the
   chunk's backedges need no tick and a tick still comes at most every 2048 iterations. */
inline uint64_t __sc_chunk_end(int32_t *__spc, uint64_t __i, uint64_t __end) {
  uint64_t __n = __end - __i;
  if (__n > (uint64_t)*__spc) __n = (uint64_t)*__spc;
  *__spc -= (int32_t)(__n - 1U);
  return __i + __n;
}
/* Cancellation half of a combined safepoint (emitted only on its cold path), in the runtime: asks the
   scheduler whether the current task has an unmasked pending cancellation, ACCEPTING it on yes; the
   emitted branch then enters the frame's cancellation ladder. */
int32_t __sc_cancel_tick(void);
/* Reflection registry (the runtime): the registry unit's constructor registers its static table of the
   `@reflect`-tagged concrete types' exported `sc_typeinfo_<name>` descriptors. */
void __sc_reflect_register(const void *const *__roots, size_t __n);
/* The leak tracker's entry points (the runtime): the emitter spells every extern C `malloc`, `calloc`,
   `realloc` and `free` call as these (`Mangler::tracked_alloc`). Inert unless SC_LEAK_CHECK is set. */
void *sc_lk_malloc(size_t __n);
void *sc_lk_calloc(size_t __n, size_t __m);
void *sc_lk_realloc(void *__p, size_t __n);
void sc_lk_free(void *__p);
/* The bit counts, wrapping arithmetic and 128-bit fast paths std binds without a header: the C
   backend's primitives. */
/* Bit counts for the built-in integer methods in core.spc (`trailing_zeros`, `leading_zeros`,
   `count_ones`). The GCC/Clang builtins lower to the target's instruction (x86 tzcnt/lzcnt/popcnt or a
   short sequence, aarch64 rbit+clz/cnt, wasm i64.ctz/i64.clz/i64.popcnt). The builtins are undefined
   for a zero input, so the zero case is explicit: 64 bits. The IR interpreter models these three names
   for compile-time evaluation. */
inline uint32_t sc_ctz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_ctzll(sc_x) : 64u; }
inline uint32_t sc_clz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_clzll(sc_x) : 64u; }
inline uint32_t sc_popcount64(uint64_t sc_x) { return (uint32_t)__builtin_popcountll(sc_x); }
/* The 64 bits of `sc_x` in reverse order (vector `reverse_bits`): swap halves, then bytes, then bits. */
inline uint64_t sc_bitrev64(uint64_t sc_x) {
  sc_x = __builtin_bswap64(sc_x);
  sc_x = (sc_x & 0x0F0F0F0F0F0F0F0FULL) << 4 | (sc_x >> 4 & 0x0F0F0F0F0F0F0F0FULL);
  sc_x = (sc_x & 0x3333333333333333ULL) << 2 | (sc_x >> 2 & 0x3333333333333333ULL);
  return (sc_x & 0x5555555555555555ULL) << 1 | (sc_x >> 1 & 0x5555555555555555ULL);
}
/* Wrapping arithmetic for the built-in integer methods in core.spc (`wrapping_*`, `overflowing_*`,
   `checked_*`, `saturating_*`): C's unsigned operators, modulo 2^64 in every profile; a narrower method
   truncates the result. A shift count is below 64. `sc_mulo_*` tell whether the full product overflows 64
   bits. The IR interpreter models these names for compile-time evaluation. */
inline uint64_t sc_wadd64(uint64_t sc_a, uint64_t sc_b) { return sc_a + sc_b; }
inline uint64_t sc_wsub64(uint64_t sc_a, uint64_t sc_b) { return sc_a - sc_b; }
inline uint64_t sc_wmul64(uint64_t sc_a, uint64_t sc_b) { return sc_a * sc_b; }
inline uint64_t sc_wshl64(uint64_t sc_a, uint32_t sc_n) { return sc_a << sc_n; }
inline uint64_t sc_wshr64(uint64_t sc_a, uint32_t sc_n) { return sc_a >> sc_n; }
inline int64_t sc_wsar64(int64_t sc_a, uint32_t sc_n) { return sc_a >> sc_n; }
/* The processor operations (`lir::ir::SYS_*`) std and the runtime bind without a header, as the
   native backends expand them. */
inline void sc_sys_barrier(void) { __asm__ volatile("" ::: "memory"); }
inline void sc_sys_keep(void *sc_p) { __asm__ volatile("" : : "r"(sc_p) : "memory"); }
#if defined(__x86_64__)
inline void sc_sys_spin(void) { __asm__ volatile("pause" ::: "memory"); }
inline uint64_t sc_sys_cycles(void) {
  uint32_t sc_lo, sc_hi;
  __asm__ volatile("rdtsc" : "=a"(sc_lo), "=d"(sc_hi));
  return (uint64_t)sc_hi << 32 | sc_lo;
}
inline void sc_sys_fp_save(void *sc_p) { __asm__ volatile("stmxcsr (%0)\n\tfnstcw 4(%0)" : : "r"(sc_p) : "memory"); }
inline uint64_t sc_sys_gs_load(uint64_t sc_o) {
  uint64_t sc_v;
  __asm__ volatile("movq %%gs:(%1), %0" : "=r"(sc_v) : "r"(sc_o));
  return sc_v;
}
inline void sc_sys_gs_store(uint64_t sc_o, uint64_t sc_v) { __asm__ volatile("movq %0, %%gs:(%1)" : : "r"(sc_v), "r"(sc_o) : "memory"); }
inline void sc_sys_cpuid(uint32_t *sc_r, uint32_t sc_l, uint32_t sc_s) {
  __asm__ volatile("cpuid" : "=a"(sc_r[0]), "=b"(sc_r[1]), "=c"(sc_r[2]), "=d"(sc_r[3]) : "a"(sc_l), "c"(sc_s) : "memory");
}
inline uint64_t sc_sys_xgetbv(uint32_t sc_x) {
  uint32_t sc_lo, sc_hi;
  __asm__ volatile("xgetbv" : "=a"(sc_lo), "=d"(sc_hi) : "c"(sc_x));
  return (uint64_t)sc_hi << 32 | sc_lo;
}
#define SC_RT_SYS_NAMES SC_RT_X(sc_sys_spin) SC_RT_X(sc_sys_cycles) SC_RT_X(sc_sys_fp_save) SC_RT_X(sc_sys_gs_load) \
SC_RT_X(sc_sys_gs_store) SC_RT_X(sc_sys_cpuid) SC_RT_X(sc_sys_xgetbv)
#elif defined(__aarch64__)
/* `isb`, not `yield`: `yield` is a no-op on Apple cores. */
inline void sc_sys_spin(void) { __asm__ volatile("isb" ::: "memory"); }
inline uint64_t sc_sys_cycles(void) {
  uint64_t sc_v;
  __asm__ volatile("mrs %0, cntvct_el0" : "=r"(sc_v));
  return sc_v;
}
inline void sc_sys_fp_save(void *sc_p) {
  uint64_t sc_v;
  __asm__ volatile("mrs %0, fpcr" : "=r"(sc_v));
  *(uint64_t *)sc_p = sc_v;
}
inline uint64_t sc_sys_svl(void) {
  uint64_t sc_v;
  __asm__ volatile(".arch_extension sme\n\trdsvl %0, #1" : "=r"(sc_v));
  return sc_v;
}
#define SC_RT_SYS_NAMES SC_RT_X(sc_sys_spin) SC_RT_X(sc_sys_cycles) SC_RT_X(sc_sys_fp_save) SC_RT_X(sc_sys_svl)
#else
/* wasm has no spin instruction: a compiler barrier. */
inline void sc_sys_spin(void) { __asm__ volatile("" ::: "memory"); }
#define SC_RT_SYS_NAMES SC_RT_X(sc_sys_spin)
#endif
inline bool sc_mulo_u64(uint64_t sc_a, uint64_t sc_b) { uint64_t sc_r; return __builtin_mul_overflow(sc_a, sc_b, &sc_r); }
inline bool sc_mulo_i64(int64_t sc_a, int64_t sc_b) { int64_t sc_r; return __builtin_mul_overflow(sc_a, sc_b, &sc_r); }
/* Native 128-bit fast path for std's UInt<128>/Int<128> (see int.spc). Where the C compiler building
   the emitted code has a 128-bit integer type, sc_has_i128() folds to 1 and these replace the limb
   loops; where it does not, it folds to 0, the limb code stands, and the stubs are never reached.
   Limbs pass as explicit 64-bit halves, least significant first, so byte order never enters into it. */
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic" /* gcc: ISO C does not support __int128 */
#endif
#if defined(__SIZEOF_INT128__)
inline int sc_has_i128(void) { return 1; }
inline void sc_i128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_c) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_s = sc_a + ((unsigned __int128)sc_bh << 64 | sc_bl);
  *sc_rl = (uint64_t)sc_s; *sc_rh = (uint64_t)(sc_s >> 64); *sc_c = sc_s < sc_a;
}
inline void sc_i128_sub(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_b) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_y = (unsigned __int128)sc_bh << 64 | sc_bl;
  unsigned __int128 sc_d = sc_a - sc_y;
  *sc_rl = (uint64_t)sc_d; *sc_rh = (uint64_t)(sc_d >> 64); *sc_b = sc_a < sc_y;
}
inline void sc_i128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_hl, uint64_t *sc_hh) {
  /* The full 256-bit product from four 64x64 partials. sc_m1 cannot overflow (at most 2^128 - 2^64 - 1);
     sc_m2 can, and its carry sits 128 bits up, inside sc_hi's headroom. */
  unsigned __int128 sc_p0 = (unsigned __int128)sc_al * sc_bl;
  unsigned __int128 sc_m1 = (unsigned __int128)sc_al * sc_bh + (uint64_t)(sc_p0 >> 64);
  unsigned __int128 sc_m2 = sc_m1 + (unsigned __int128)sc_ah * sc_bl;
  unsigned __int128 sc_hi = (unsigned __int128)sc_ah * sc_bh + (uint64_t)(sc_m2 >> 64) + ((unsigned __int128)(sc_m2 < sc_m1) << 64);
  *sc_rl = (uint64_t)sc_p0; *sc_rh = (uint64_t)sc_m2;
  *sc_hl = (uint64_t)sc_hi; *sc_hh = (uint64_t)(sc_hi >> 64);
}
inline void sc_i128_divmod(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_ql, uint64_t *sc_qh, uint64_t *sc_rl, uint64_t *sc_rh) {
  unsigned __int128 sc_a = (unsigned __int128)sc_ah << 64 | sc_al;
  unsigned __int128 sc_b = (unsigned __int128)sc_bh << 64 | sc_bl;
  unsigned __int128 sc_q = sc_a / sc_b, sc_r = sc_a % sc_b;
  *sc_ql = (uint64_t)sc_q; *sc_qh = (uint64_t)(sc_q >> 64);
  *sc_rl = (uint64_t)sc_r; *sc_rh = (uint64_t)(sc_r >> 64);
}
/* The full 64x64 product: the low half returned, the high half stored. */
inline uint64_t sc_mul64(uint64_t sc_a, uint64_t sc_b, uint64_t *sc_hi) {
  unsigned __int128 sc_p = (unsigned __int128)sc_a * sc_b;
  *sc_hi = (uint64_t)(sc_p >> 64);
  return (uint64_t)sc_p;
}
/* (sc_u1 : sc_u0) / sc_v for sc_u1 < sc_v: the quotient fits one limb. */
inline uint64_t sc_div128by64(uint64_t sc_u1, uint64_t sc_u0, uint64_t sc_v, uint64_t *sc_r) {
  unsigned __int128 sc_u = (unsigned __int128)sc_u1 << 64 | sc_u0;
  *sc_r = (uint64_t)(sc_u % sc_v);
  return (uint64_t)(sc_u / sc_v);
}
#else
inline int sc_has_i128(void) { return 0; }
inline uint64_t sc_mul64(uint64_t sc_a, uint64_t sc_b, uint64_t *sc_hi) {
  (void)sc_a; (void)sc_b; (void)sc_hi; abort();
}
inline uint64_t sc_div128by64(uint64_t sc_u1, uint64_t sc_u0, uint64_t sc_v, uint64_t *sc_r) {
  (void)sc_u1; (void)sc_u0; (void)sc_v; (void)sc_r; abort();
}
inline void sc_i128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_c) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_c; abort();
}
inline void sc_i128_sub(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_b) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_b; abort();
}
inline void sc_i128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh, uint64_t *sc_hl, uint64_t *sc_hh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; (void)sc_hl; (void)sc_hh; abort();
}
inline void sc_i128_divmod(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_ql, uint64_t *sc_qh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_ql; (void)sc_qh; (void)sc_rl; (void)sc_rh; abort();
}
#endif
/* Overflow in std's Int<N> and UInt<N> operators: the built-in trap (`__sc_panic`, above), or a
   return when the build wraps (-DSC_ARITH_WRAP), and the operator then keeps its wrapped value. A zero
   divisor and MIN / -1 trap in every profile, as the built-in `/` and `%` do. The IR interpreter models
   these three names for compile-time evaluation. */
inline void sc_int_overflow(const uint8_t *sc_m) {
#ifdef SC_ARITH_WRAP
  (void)sc_m;
#else
  __sc_panic((const char *)sc_m);
#endif
}
inline void sc_int_div_zero(const uint8_t *sc_m) { __sc_panic((const char *)sc_m); }
inline void sc_int_div_overflow(const uint8_t *sc_m) { __sc_panic((const char *)sc_m); }
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
#define SC_RT_F128_CODEC SC_RT_X(sc_f128_of) SC_RT_X(sc_f128_out)
inline int sc_has_f128(void) { return 1; }
inline sc_f128 sc_f128_of(uint64_t sc_lo, uint64_t sc_hi) {
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
inline void sc_f128_out(sc_f128 sc_v, uint64_t *sc_lo, uint64_t *sc_hi) {
  uint64_t sc_w[2];
  memcpy(sc_w, &sc_v, sizeof sc_w);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  *sc_lo = sc_w[1]; *sc_hi = sc_w[0];
#else
  *sc_lo = sc_w[0]; *sc_hi = sc_w[1];
#endif
}
inline void sc_f128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) + sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
inline void sc_f128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) * sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
inline void sc_f128_div(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  sc_f128_out(sc_f128_of(sc_al, sc_ah) / sc_f128_of(sc_bl, sc_bh), sc_rl, sc_rh);
}
#else
#define SC_RT_F128_CODEC
inline int sc_has_f128(void) { return 0; }
inline void sc_f128_add(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
inline void sc_f128_mul(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
inline void sc_f128_div(uint64_t sc_al, uint64_t sc_ah, uint64_t sc_bl, uint64_t sc_bh, uint64_t *sc_rl, uint64_t *sc_rh) {
  (void)sc_al; (void)sc_ah; (void)sc_bl; (void)sc_bh; (void)sc_rl; (void)sc_rh; abort();
}
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
/* The external declaration of every helper above, for the registry unit. */
#define SC_RT_EXTERNS SC_RT_ATOMIC_NAMES SC_RT_X(__sc_bounds) SC_RT_X(__sc_range) SC_RT_X(__sc_bounds_group) SC_RT_X(__sc_fits) \
SC_SIGNED_TYPES(SC_SIGNED_NAMES) SC_UNSIGNED_TYPES(SC_UNSIGNED_NAMES) SC_F2I_SIGNED_TYPES(SC_F2I_SIGNED_NAMES) \
SC_F2I_UNSIGNED_TYPES(SC_F2I_UNSIGNED_NAMES) SC_RT_X(__sc_chunk_end) SC_RT_X(sc_ctz64) SC_RT_X(sc_clz64) \
SC_RT_X(sc_popcount64) SC_RT_X(sc_bitrev64) SC_RT_X(sc_wadd64) SC_RT_X(sc_wsub64) SC_RT_X(sc_wmul64) SC_RT_X(sc_wshl64) \
SC_RT_X(sc_wshr64) SC_RT_X(sc_wsar64) SC_RT_X(sc_mulo_u64) SC_RT_X(sc_mulo_i64) SC_RT_X(sc_has_i128) SC_RT_X(sc_i128_add) \
SC_RT_X(sc_i128_sub) SC_RT_X(sc_i128_mul) SC_RT_X(sc_i128_divmod) SC_RT_X(sc_mul64) SC_RT_X(sc_div128by64) \
SC_RT_X(sc_int_overflow) SC_RT_X(sc_int_div_zero) SC_RT_X(sc_int_div_overflow) SC_RT_X(sc_has_f128) \
SC_RT_X(sc_f128_add) SC_RT_X(sc_f128_mul) SC_RT_X(sc_f128_div) SC_RT_F128_CODEC SC_RT_X(sc_sys_barrier) \
SC_RT_X(sc_sys_keep) SC_RT_SYS_NAMES
)";
}
