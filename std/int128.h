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
static inline void sc_i128_add(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__c) {
  unsigned __int128 __a = (unsigned __int128)__ah << 64 | __al;
  unsigned __int128 __s = __a + ((unsigned __int128)__bh << 64 | __bl);
  *__rl = (uint64_t)__s; *__rh = (uint64_t)(__s >> 64); *__c = __s < __a;
}
static inline void sc_i128_sub(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__b) {
  unsigned __int128 __a = (unsigned __int128)__ah << 64 | __al;
  unsigned __int128 __y = (unsigned __int128)__bh << 64 | __bl;
  unsigned __int128 __d = __a - __y;
  *__rl = (uint64_t)__d; *__rh = (uint64_t)(__d >> 64); *__b = __a < __y;
}
static inline void sc_i128_mul(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__hl, uint64_t *__hh) {
  /* The full 256-bit product from four 64x64 partials. __m1 cannot overflow (at most 2^128 - 2^64 - 1);
     __m2 can, and its carry sits 128 bits up, inside __hi's headroom. */
  unsigned __int128 __p0 = (unsigned __int128)__al * __bl;
  unsigned __int128 __m1 = (unsigned __int128)__al * __bh + (uint64_t)(__p0 >> 64);
  unsigned __int128 __m2 = __m1 + (unsigned __int128)__ah * __bl;
  unsigned __int128 __hi = (unsigned __int128)__ah * __bh + (uint64_t)(__m2 >> 64) + ((unsigned __int128)(__m2 < __m1) << 64);
  *__rl = (uint64_t)__p0; *__rh = (uint64_t)__m2;
  *__hl = (uint64_t)__hi; *__hh = (uint64_t)(__hi >> 64);
}
static inline void sc_i128_divmod(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__ql, uint64_t *__qh, uint64_t *__rl, uint64_t *__rh) {
  unsigned __int128 __a = (unsigned __int128)__ah << 64 | __al;
  unsigned __int128 __b = (unsigned __int128)__bh << 64 | __bl;
  unsigned __int128 __q = __a / __b, __r = __a % __b;
  *__ql = (uint64_t)__q; *__qh = (uint64_t)(__q >> 64);
  *__rl = (uint64_t)__r; *__rh = (uint64_t)(__r >> 64);
}
#else
static inline int sc_has_i128(void) { return 0; }
static inline void sc_i128_add(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__c) {
  (void)__al; (void)__ah; (void)__bl; (void)__bh; (void)__rl; (void)__rh; (void)__c; abort();
}
static inline void sc_i128_sub(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__b) {
  (void)__al; (void)__ah; (void)__bl; (void)__bh; (void)__rl; (void)__rh; (void)__b; abort();
}
static inline void sc_i128_mul(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__rl, uint64_t *__rh, uint64_t *__hl, uint64_t *__hh) {
  (void)__al; (void)__ah; (void)__bl; (void)__bh; (void)__rl; (void)__rh; (void)__hl; (void)__hh; abort();
}
static inline void sc_i128_divmod(uint64_t __al, uint64_t __ah, uint64_t __bl, uint64_t __bh, uint64_t *__ql, uint64_t *__qh, uint64_t *__rl, uint64_t *__rh) {
  (void)__al; (void)__ah; (void)__bl; (void)__bh; (void)__ql; (void)__qh; (void)__rl; (void)__rh; abort();
}
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
#endif /* SC_INT128_H */
