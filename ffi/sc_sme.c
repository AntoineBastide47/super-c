/* SME matrix kernels (sc_sme.h). `a` is packed into column-major panels through a ZA tile (rows in
   horizontally, columns out vertically), each block of `c` accumulates in the ZA tiles, one outer
   product (FMOPA) per tile per p, and is stored from them. FMOPA adds each product to its element with
   one rounding, in p order, from the zeroed tile (+0.0): the portable kernel's fused multiply-add chain.
   No pointer leaves its array. */
#include "sc_sme.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if (defined(__aarch64__) || defined(_M_ARM64)) && !defined(_WIN32) && defined(__has_include)
#if __has_include(<arm_sme.h>)
#define SC_SME 1
#endif
#endif

#ifdef SC_SME

#ifdef __clang__
#pragma clang attribute push(__attribute__((target("sme,sme-f64f64"))), apply_to = function)
#else
#pragma GCC push_options
#pragma GCC target("+sme+sme-f64f64")
#endif
#include <arm_sme.h>

/* SME2 for the f32 kernel and its entry only: the f64 kernel needs no more than SME and its f64 outer
   products. */
#ifdef __clang__
#define SC_SME2 __attribute__((target("sme2")))
#else
#define SC_SME2 __attribute__((target("+sme2")))
#endif

/* The smaller of two sizes, as an expression: a function called from a kernel would leave streaming
   mode or save ZA around each call (the compiler inlines no function whose SME attributes differ). */
#define MIN_SIZE(a, b) ((a) < (b) ? (a) : (b))

/* c = a * b (f32): L = SVL / 32. The whole of `a` is packed first into panels of L rows, column-major
   (`pa`, ceil(m / L) * L * k floats, zero rows past m), through tile 0; then each block of 4L columns of
   `b` is copied into `pb` (k * 4L floats, zeros past n) with SME2 four-vector loads, and each L x 4L block
   of `c` takes one A vector and one four-vector load of the panel per p, one FMOPA per tile. The outer
   products run on whole tiles over the zero padding; the stores cover the rows and columns of `c` only.
   This is the 1 VL x 4 VL shape of MpGEMM (arXiv 2512.21473): about 1.9 to 2.0 TFLOP/s on one Apple M5
   Pro core from n = 512 to 2048, the unit's peak; a 2 VL x 2 VL block without the B panel reached
   0.7 TFLOP/s at n = 2048 (B rows a page apart). */
SC_SME2 __arm_new("za") __arm_locally_streaming static void mul_f32_za(float *c, const float *a, const float *b, size_t m,
                                                               size_t k, size_t n, float *pa, float *pb) {
    uint64_t L = svcntw();
    svbool_t all = svptrue_b32();
    svcount_t all4 = svptrue_c32();
    for (size_t i = 0; i < m; i += L) {
        size_t rows = MIN_SIZE(m - i, L);
        float *pan = pa + (i / L) * k * L;
        for (size_t p0 = 0; p0 < k; p0 += L) {
            svbool_t pp = svwhilelt_b32_u64(p0, k);
            svzero_mask_za(0x11);
            for (uint64_t r = 0; r < rows; r++) svld1_hor_za32(0, r, pp, a + (i + r) * k + p0);
            size_t cols = MIN_SIZE(k - p0, L);
            for (uint64_t q = 0; q < cols; q++) svst1_ver_za32(0, q, all, pan + (p0 + q) * L);
        }
    }
    for (size_t j = 0; j < n; j += 4 * L) {
        size_t w = MIN_SIZE(n - j, 4 * L); /* the block's columns */
        /* The block's rows of B: in place when whole and a row is at most 1 KiB (the copy costs more
           than the strided reads save: 10 to 20% at n = 64 to 128 on an M5 Pro), else the panel. */
        const float *bs = pb;
        size_t bstride = 4 * L;
        if (w == 4 * L && n * sizeof(float) <= 1024) {
            bs = b + j;
            bstride = n;
        } else if (w == 4 * L) {
            for (size_t p = 0; p < k; p++) svst1_f32_x4(all4, pb + p * 4 * L, svld1_f32_x4(all4, b + p * n + j));
        } else {
            for (size_t p = 0; p < k; p++)
                for (uint64_t t = 0; t < 4; t++) {
                    svfloat32_t v = svdup_n_f32(0);
                    if (t * L < w) v = svld1_f32(svwhilelt_b32_u64(t * L, w), b + p * n + j + t * L);
                    svst1_f32(all, pb + p * 4 * L + t * L, v);
                }
        }
        for (size_t i = 0; i < m; i += L) {
            size_t rows = MIN_SIZE(m - i, L);
            const float *pan = pa + (i / L) * k * L;
            svzero_za();
            for (size_t p = 0; p < k; p++) {
                svfloat32_t av = svld1_f32(all, pan + p * L);
                svfloat32x4_t bv = svld1_f32_x4(all4, bs + p * bstride);
                svmopa_za32_f32_m(0, all, all, av, svget4_f32(bv, 0));
                svmopa_za32_f32_m(1, all, all, av, svget4_f32(bv, 1));
                svmopa_za32_f32_m(2, all, all, av, svget4_f32(bv, 2));
                svmopa_za32_f32_m(3, all, all, av, svget4_f32(bv, 3));
            }
            if (w == 4 * L) {
                for (uint64_t r = 0; r < rows; r++) {
                    float *cr = c + (i + r) * n + j;
                    svst1_hor_za32(0, r, all, cr);
                    svst1_hor_za32(1, r, all, cr + L);
                    svst1_hor_za32(2, r, all, cr + 2 * L);
                    svst1_hor_za32(3, r, all, cr + 3 * L);
                }
            } else {
                svbool_t q0 = svwhilelt_b32_u64(0, w), q1 = svwhilelt_b32_u64(L, w);
                svbool_t q2 = svwhilelt_b32_u64(2 * L, w), q3 = svwhilelt_b32_u64(3 * L, w);
                for (uint64_t r = 0; r < rows; r++) {
                    float *cr = c + (i + r) * n + j;
                    svst1_hor_za32(0, r, q0, cr);
                    if (L < w) svst1_hor_za32(1, r, q1, cr + L);
                    if (2 * L < w) svst1_hor_za32(2, r, q2, cr + 2 * L);
                    if (3 * L < w) svst1_hor_za32(3, r, q3, cr + 3 * L);
                }
            }
        }
    }
}

/* c = a * b (f64): L = SVL / 64. As the f32 kernel, with blocks of 2L x 4L: `a` packed into panels of
   2L rows (`pa`, ceil(m / 2L) * 2L * k doubles) through 64-bit tiles 0 and 1, each block of 4L columns
   of `b` copied into `pb` (k * 4L doubles, zeros past n), and the eight 64-bit tiles: 0 to 3 the first L
   rows over the four column vectors, 4 to 7 the next L rows. SME and its f64 outer products only.
   Without the B panel, the M5 Pro fell from 0.5 to 0.2 TFLOP/s at n = 2048. */
__arm_new("za") __arm_locally_streaming static void mul_f64_za(double *c, const double *a, const double *b, size_t m,
                                                               size_t k, size_t n, double *pa, double *pb) {
    uint64_t L = svcntd();
    svbool_t all = svptrue_b64();
    for (size_t i = 0; i < m; i += 2 * L) {
        size_t rows = MIN_SIZE(m - i, 2 * L);
        double *pan = pa + (i / (2 * L)) * k * 2 * L;
        for (size_t p0 = 0; p0 < k; p0 += L) {
            svbool_t pp = svwhilelt_b64_u64(p0, k);
            svzero_mask_za(0x03);
            for (uint64_t r = 0; r < L && r < rows; r++) svld1_hor_za64(0, r, pp, a + (i + r) * k + p0);
            for (uint64_t r = 0; L + r < rows && r < L; r++) svld1_hor_za64(1, r, pp, a + (i + L + r) * k + p0);
            size_t cols = MIN_SIZE(k - p0, L);
            for (uint64_t q = 0; q < cols; q++) {
                svst1_ver_za64(0, q, all, pan + (p0 + q) * 2 * L);
                svst1_ver_za64(1, q, all, pan + (p0 + q) * 2 * L + L);
            }
        }
    }
    for (size_t j = 0; j < n; j += 4 * L) {
        size_t w = MIN_SIZE(n - j, 4 * L);
        for (size_t p = 0; p < k; p++)
            for (uint64_t t = 0; t < 4; t++) {
                svfloat64_t v = svdup_n_f64(0);
                if (t * L < w) v = svld1_f64(svwhilelt_b64_u64(t * L, w), b + p * n + j + t * L);
                svst1_f64(all, pb + p * 4 * L + t * L, v);
            }
        for (size_t i = 0; i < m; i += 2 * L) {
            size_t rows = MIN_SIZE(m - i, 2 * L);
            const double *pan = pa + (i / (2 * L)) * k * 2 * L;
            svzero_za();
            for (size_t p = 0; p < k; p++) {
                svfloat64_t a0 = svld1_f64(all, pan + p * 2 * L), a1 = svld1_f64(all, pan + p * 2 * L + L);
                const double *bp = pb + p * 4 * L;
                svfloat64_t b0 = svld1_f64(all, bp), b1 = svld1_f64(all, bp + L);
                svfloat64_t b2 = svld1_f64(all, bp + 2 * L), b3 = svld1_f64(all, bp + 3 * L);
                svmopa_za64_f64_m(0, all, all, a0, b0);
                svmopa_za64_f64_m(1, all, all, a0, b1);
                svmopa_za64_f64_m(2, all, all, a0, b2);
                svmopa_za64_f64_m(3, all, all, a0, b3);
                svmopa_za64_f64_m(4, all, all, a1, b0);
                svmopa_za64_f64_m(5, all, all, a1, b1);
                svmopa_za64_f64_m(6, all, all, a1, b2);
                svmopa_za64_f64_m(7, all, all, a1, b3);
            }
            svbool_t q0 = svwhilelt_b64_u64(0, w), q1 = svwhilelt_b64_u64(L, w);
            svbool_t q2 = svwhilelt_b64_u64(2 * L, w), q3 = svwhilelt_b64_u64(3 * L, w);
            for (uint64_t r = 0; r < L && r < rows; r++) {
                double *cr = c + (i + r) * n + j;
                svst1_hor_za64(0, r, q0, cr);
                if (L < w) svst1_hor_za64(1, r, q1, cr + L);
                if (2 * L < w) svst1_hor_za64(2, r, q2, cr + 2 * L);
                if (3 * L < w) svst1_hor_za64(3, r, q3, cr + 3 * L);
            }
            for (uint64_t r = 0; L + r < rows && r < L; r++) {
                double *cr = c + (i + L + r) * n + j;
                svst1_hor_za64(4, r, q0, cr);
                if (L < w) svst1_hor_za64(5, r, q1, cr + L);
                if (2 * L < w) svst1_hor_za64(6, r, q2, cr + 2 * L);
                if (3 * L < w) svst1_hor_za64(7, r, q3, cr + 3 * L);
            }
        }
    }
}

/* c = a * b (i8 to i32): L = SVL / 32. SMOPA adds to each 32-bit element the sum of four products of
   consecutive p, so `a` and `b` arrive packed in groups of four (`sc_sme_mul_i8`, outside streaming
   mode): pa holds, per panel of L rows and per group, each row's four bytes; pb, per panel of 4L columns
   and per group, each column's four bytes. Zeros pad the rows, columns and the last group. Each
   L x 4L block takes one A vector and one SME2 four-vector load of B per group, one SMOPA per tile.
   Integer sums wrap modulo 2^32 in any order: the portable kernel's results. */
SC_SME2 __arm_new("za") __arm_locally_streaming static void mul_i8_za(int32_t *c, const int8_t *pa, const int8_t *pb,
                                                                      size_t m, size_t g, size_t n) {
    uint64_t L = svcntw();
    svbool_t all8 = svptrue_b8(), all32 = svptrue_b32();
    svcount_t all4 = svptrue_c8();
    for (size_t j = 0; j < n; j += 4 * L) {
        size_t w = MIN_SIZE(n - j, 4 * L);
        const int8_t *pbj = pb + (j / (4 * L)) * g * 16 * L;
        svbool_t q0 = svwhilelt_b32_u64(0, w), q1 = svwhilelt_b32_u64(L, w);
        svbool_t q2 = svwhilelt_b32_u64(2 * L, w), q3 = svwhilelt_b32_u64(3 * L, w);
        for (size_t i = 0; i < m; i += L) {
            size_t rows = MIN_SIZE(m - i, L);
            const int8_t *pan = pa + (i / L) * g * 4 * L;
            svzero_za();
            for (size_t q = 0; q < g; q++) {
                svint8_t av = svld1_s8(all8, pan + q * 4 * L);
                svint8x4_t bv = svld1_s8_x4(all4, pbj + q * 16 * L);
                svmopa_za32_s8_m(0, all8, all8, av, svget4_s8(bv, 0));
                svmopa_za32_s8_m(1, all8, all8, av, svget4_s8(bv, 1));
                svmopa_za32_s8_m(2, all8, all8, av, svget4_s8(bv, 2));
                svmopa_za32_s8_m(3, all8, all8, av, svget4_s8(bv, 3));
            }
            for (uint64_t r = 0; r < rows; r++) {
                int32_t *cr = c + (i + r) * n + j;
                svst1_hor_za32(0, r, w == 4 * L ? all32 : q0, cr);
                if (L < w) svst1_hor_za32(1, r, w == 4 * L ? all32 : q1, cr + L);
                if (2 * L < w) svst1_hor_za32(2, r, w == 4 * L ? all32 : q2, cr + 2 * L);
                if (3 * L < w) svst1_hor_za32(3, r, w == 4 * L ? all32 : q3, cr + 3 * L);
            }
        }
    }
}

int sc_sme_built(void) { return 1; }

/* k rows of `lanes` elements of `esz` bytes; NULL when the size overflows or cannot be allocated. */
static void *panel(size_t k, size_t lanes, size_t esz) {
    if (lanes != 0 && esz > SIZE_MAX / lanes) return NULL;
    size_t row = lanes * esz;
    return row != 0 && k > SIZE_MAX / row ? NULL : malloc(k * row == 0 ? 1 : k * row);
}

SC_SME2 int sc_sme_mul_f32(float *c, const float *a, const float *b, size_t m, size_t k, size_t n) {
    size_t L = svcntsw(), panels = m / L + (m % L != 0);
    /* One allocation: pa, panels * L * k floats, then pb, 4L * k floats. */
    float *pa = panel(k, panels * L + 4 * L, sizeof(float));
    if (pa == NULL) return -1;
    mul_f32_za(c, a, b, m, k, n, pa, pa + panels * L * k);
    free(pa);
    return 0;
}

int sc_sme_mul_f64(double *c, const double *a, const double *b, size_t m, size_t k, size_t n) {
    size_t L = svcntsd(), panels = m / (2 * L) + (m % (2 * L) != 0);
    double *pa = panel(k, panels * 2 * L + 4 * L, sizeof(double));
    if (pa == NULL) return -1;
    mul_f64_za(c, a, b, m, k, n, pa, pa + panels * 2 * L * k);
    free(pa);
    return 0;
}

SC_SME2 int sc_sme_mul_i8(int32_t *c, const int8_t *a, const int8_t *b, size_t m, size_t k, size_t n) {
    size_t L = svcntsw(), g = k / 4 + (k % 4 != 0);
    size_t pm = (m / L + (m % L != 0)) * L, pn = (n / (4 * L) + (n % (4 * L) != 0)) * 4 * L;
    /* pa: pm rows of 4g bytes; pb: pn columns of 4g bytes. */
    int8_t *pa = panel(g, 4 * (pm + pn), 1);
    if (pa == NULL) return -1;
    int8_t *pb = pa + pm * 4 * g;
    /* pa: each row's groups of four bytes, one word per group (zeros past m and k). */
    memset(pa, 0, pm * 4 * g);
    for (size_t i = 0; i < m; i++) {
        int8_t *dst = pa + (i / L) * 4 * L * g + (i % L) * 4;
        const int8_t *src = a + i * k;
        size_t whole = k / 4;
        for (size_t q = 0; q < whole; q++) memcpy(dst + q * 4 * L, src + 4 * q, 4);
        for (size_t p = 4 * whole; p < k; p++) dst[whole * 4 * L + p - 4 * whole] = src[p];
    }
    /* pb: per group, the four rows interleaved byte by byte over each panel's 4L columns (zeros past n
       and k); a whole group of a whole panel has no condition, which the C compiler vectorizes. */
    memset(pb, 0, pn * 4 * g);
    for (size_t j = 0; j < pn; j += 4 * L)
        for (size_t q = 0; q < g; q++) {
            int8_t *dst = pb + j * 4 * g + q * 16 * L;
            if (j + 4 * L <= n && 4 * q + 4 <= k) {
                const int8_t *r0 = b + 4 * q * n + j, *r1 = r0 + n, *r2 = r1 + n, *r3 = r2 + n;
                for (size_t col = 0; col < 4 * L; col++) {
                    dst[col * 4] = r0[col];
                    dst[col * 4 + 1] = r1[col];
                    dst[col * 4 + 2] = r2[col];
                    dst[col * 4 + 3] = r3[col];
                }
            } else {
                for (size_t col = 0; col < 4 * L && j + col < n; col++)
                    for (size_t t = 0; t < 4 && 4 * q + t < k; t++) dst[col * 4 + t] = b[(4 * q + t) * n + j + col];
            }
        }
    mul_i8_za(c, pa, pb, m, g, n);
    free(pa);
    return 0;
}

#ifdef __clang__
#pragma clang attribute pop
#else
#pragma GCC pop_options
#endif

#else

int sc_sme_built(void) { return 0; }

int sc_sme_mul_f32(float *c, const float *a, const float *b, size_t m, size_t k, size_t n) {
    (void)c, (void)a, (void)b, (void)m, (void)k, (void)n;
    return -1;
}

int sc_sme_mul_f64(double *c, const double *a, const double *b, size_t m, size_t k, size_t n) {
    (void)c, (void)a, (void)b, (void)m, (void)k, (void)n;
    return -1;
}

int sc_sme_mul_i8(int32_t *c, const int8_t *a, const int8_t *b, size_t m, size_t k, size_t n) {
    (void)c, (void)a, (void)b, (void)m, (void)k, (void)n;
    return -1;
}

#endif
