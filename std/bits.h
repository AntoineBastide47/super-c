/* Bit counts for the built-in integer methods in core.spc (`trailing_zeros`, `leading_zeros`,
   `count_ones`). The GCC/Clang builtins lower to the target's instruction (x86 tzcnt/lzcnt/popcnt or a
   short sequence, aarch64 rbit+clz/cnt, wasm i64.ctz/i64.clz/i64.popcnt). The builtins are undefined
   for a zero input, so the zero case is explicit: 64 bits. The IR interpreter models these three names
   for compile-time evaluation. */
#ifndef SC_BITS_H
#define SC_BITS_H
#include <stdbool.h>
#include <stdint.h>
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
#endif
