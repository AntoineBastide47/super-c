/* Native 128-bit fast path for std's UInt<128>/Int<128> (see int.spc). Where the C compiler building
   the emitted code has a 128-bit integer type, sc_has_i128() folds to 1 and these replace the limb
   loops; where it does not, it folds to 0, the limb code stands, and the stubs are never reached.
   Limbs pass as explicit 64-bit halves, least significant first, so byte order never enters into it. */
#ifndef SC_INT128_H
#define SC_INT128_H
#include <stdint.h>
#include <stdlib.h>
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
#else
static inline int sc_has_i128(void) { return 0; }
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
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
#endif /* SC_INT128_H */
