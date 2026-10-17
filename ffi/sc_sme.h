/* SME matrix kernels for std/simd/matrix.spc: row-major products on the ZA tiles (outer products), each
   kernel entering streaming mode itself. A kernel runs only where the CPU has its features
   (`cpu::Feature::Sme`, `SmeF64f64`); every result equals the portable kernel's bit for bit (NaN payloads
   aside): element (i, j) is the fused multiply-add chain over p in order, from +0.0. */
#ifndef SC_SME_H
#define SC_SME_H

#include <stddef.h>
#include <stdint.h>

/* 1 when this file was built with the kernels (an aarch64 C compiler with <arm_sme.h>), else 0. */
int sc_sme_built(void);
/* c (m x n) = a (m x k) * b (k x n), row-major `float`: 0, or -1 (c untouched) when the kernels are not
   built or the packing scratch cannot be allocated. Needs SME2. */
int sc_sme_mul_f32(float *c, const float *a, const float *b, size_t m, size_t k, size_t n);
/* The same for `double`. Needs SME and its f64 outer products. */
int sc_sme_mul_f64(double *c, const double *a, const double *b, size_t m, size_t k, size_t n);
/* c (m x n, `int32_t`) = a (m x k) * b (k x n), `int8_t`: each element the sum of the products modulo
   2^32. Needs SME2. */
int sc_sme_mul_i8(int32_t *c, const int8_t *a, const int8_t *b, size_t m, size_t k, size_t n);

#endif
