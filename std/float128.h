/* Native binary128 fast path for std's f128 (`Float<15, 112>`, see float.spc). Where the C compiler
   building the emitted code has an IEEE binary128 type (`__float128`, or a `long double` with a
   113-bit significand), sc_has_f128() folds to 1 and these replace the limb code for add, multiply
   and divide: correctly rounded, so the same bits (NaN aside, which float.spc canonicalizes). The
   operations are the compiler's runtime (libgcc's `__addtf3` and the like, or hardware). Where it has
   none, sc_has_f128() folds to 0, the limb code stands, and the stubs are never reached. Values pass
   as explicit 64-bit halves of the encoding, least significant first. */
#ifndef SC_FLOAT128_H
#define SC_FLOAT128_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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
#endif /* SC_FLOAT128_H */
