/* Bit counts for the built-in integer methods in core.spc (`trailing_zeros`, `leading_zeros`,
   `count_ones`). The GCC/Clang builtins lower to the target's instruction (x86 tzcnt/lzcnt/popcnt or a
   short sequence, aarch64 rbit+clz/cnt, wasm i64.ctz/i64.clz/i64.popcnt). The builtins are undefined
   for a zero input, so the zero case is explicit: 64 bits. The IR interpreter models these three names
   for compile-time evaluation. */
#ifndef SC_BITS_H
#define SC_BITS_H
#include <stdint.h>
static inline uint32_t sc_ctz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_ctzll(sc_x) : 64u; }
static inline uint32_t sc_clz64(uint64_t sc_x) { return sc_x ? (uint32_t)__builtin_clzll(sc_x) : 64u; }
static inline uint32_t sc_popcount64(uint64_t sc_x) { return (uint32_t)__builtin_popcountll(sc_x); }
#endif
