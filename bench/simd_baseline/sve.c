// SVE kernels: vector-length agnostic loops whose tail is one WHILELT-predicated pass, except the two
// fixed 32-lane trees, which hold 8 vectors of 4 lanes (a 128-bit vector length). `sb_sve` returns the
// table only on Linux when the CPU has SVE and a 128-bit vector length.
#include <stddef.h>
#include <stdint.h>

#include "sb.h"
#include "sve.h"

#if defined(__aarch64__) && defined(__linux__)
#include <sys/auxv.h>

#ifdef __clang__
#pragma clang attribute push(__attribute__((target("sve"))), apply_to = function)
#else
#pragma GCC push_options
#pragma GCC target("+sve")
#endif
#include <arm_sve.h>

static void saxpy_f32(float a, const float *x, float *y, size_t n) {
    svbool_t all = svptrue_b32();
    size_t w = svcntw(), i = 0;
    for (; i + 4 * w <= n; i += 4 * w)
        for (size_t j = i; j < i + 4 * w; j += w)
            svst1_f32(all, y + j, svadd_f32_x(all, svmul_n_f32_x(all, svld1_f32(all, x + j), a), svld1_f32(all, y + j)));
    for (; i < n; i += w) {
        svbool_t pg = svwhilelt_b32_u64(i, n);
        svst1_f32(pg, y + i, svadd_f32_x(pg, svmul_n_f32_x(pg, svld1_f32(pg, x + i), a), svld1_f32(pg, y + i)));
    }
}

// FADDA adds the active lanes to the scalar in lane order: the scalar loop's order.
static float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f;
    for (size_t i = 0; i < n; i += svcntw()) {
        svbool_t pg = svwhilelt_b32_u64(i, n);
        s = svadda_f32(pg, s, svmul_f32_x(pg, svld1_f32(pg, x + i), svld1_f32(pg, y + i)));
    }
    return s;
}

#define SB_ACC8(F) F(0) F(1) F(2) F(3) F(4) F(5) F(6) F(7)

static float dot_f32_tree(const float *x, const float *y, size_t n) {
    svbool_t all = svptrue_b32();
    svfloat32_t z = svdup_n_f32(-0.0f), a0 = z, a1 = z, a2 = z, a3 = z, a4 = z, a5 = z, a6 = z, a7 = z;
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE) {
#define F(u) a##u = svadd_f32_x(all, a##u, svmul_f32_x(all, svld1_f32(all, x + i + 4 * u), svld1_f32(all, y + i + 4 * u)));
        SB_ACC8(F)
#undef F
    }
    float l[SB_TREE];
#define F(u) svst1_f32(all, l + 4 * u, a##u);
    SB_ACC8(F)
#undef F
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

// A count per byte lane, summed before it can wrap.
static size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    svbool_t all = svptrue_b8();
    size_t w = svcntb(), i = 0, c = 0;
    while (i + 4 * w <= n) {
        svuint8_t z = svdup_n_u8(0), a0 = z, a1 = z, a2 = z, a3 = z;
        for (int b = 0; b < 255 && i + 4 * w <= n; b++, i += 4 * w) {
            a0 = svadd_n_u8_m(svcmpeq_n_u8(all, svld1_u8(all, x + i), v), a0, 1);
            a1 = svadd_n_u8_m(svcmpeq_n_u8(all, svld1_u8(all, x + i + w), v), a1, 1);
            a2 = svadd_n_u8_m(svcmpeq_n_u8(all, svld1_u8(all, x + i + 2 * w), v), a2, 1);
            a3 = svadd_n_u8_m(svcmpeq_n_u8(all, svld1_u8(all, x + i + 3 * w), v), a3, 1);
        }
        c += svaddv_u8(all, a0) + svaddv_u8(all, a1) + svaddv_u8(all, a2) + svaddv_u8(all, a3);
    }
    for (; i < n; i += w) {
        svbool_t pg = svwhilelt_b8_u64(i, n);
        c += svcntp_b8(pg, svcmpeq_n_u8(pg, svld1_u8(pg, x + i), v));
    }
    return c;
}

static int32_t sum_i32(const int32_t *x, size_t n) {
    const uint32_t *u = (const uint32_t *)x;
    svbool_t all = svptrue_b32();
    svuint32_t z = svdup_n_u32(0), a0 = z, a1 = z, a2 = z, a3 = z;
    size_t w = svcntw(), i = 0;
    for (; i + 4 * w <= n; i += 4 * w) {
        a0 = svadd_u32_x(all, a0, svld1_u32(all, u + i));
        a1 = svadd_u32_x(all, a1, svld1_u32(all, u + i + w));
        a2 = svadd_u32_x(all, a2, svld1_u32(all, u + i + 2 * w));
        a3 = svadd_u32_x(all, a3, svld1_u32(all, u + i + 3 * w));
    }
    for (; i < n; i += w) {
        svbool_t pg = svwhilelt_b32_u64(i, n);
        a0 = svadd_u32_m(pg, a0, svld1_u32(pg, u + i));
    }
    svuint32_t s = svadd_u32_x(all, svadd_u32_x(all, a0, a1), svadd_u32_x(all, a2, a3));
    return (int32_t)(uint32_t)svaddv_u32(all, s);
}

// A NaN lane keeps the accumulator (the merging forms). FMIN, FMAX and their reductions order -0 < +0;
// the accumulators never hold a NaN.
static void min_max_f32(const float *x, size_t n, float *out) {
    svbool_t all = svptrue_b32();
    svfloat32_t lo0 = svdup_n_f32(INFINITY), lo1 = lo0, hi0 = svdup_n_f32(-INFINITY), hi1 = hi0;
    size_t w = svcntw(), i = 0;
    for (; i + 2 * w <= n; i += 2 * w) {
        svfloat32_t v0 = svld1_f32(all, x + i), v1 = svld1_f32(all, x + i + w);
        svbool_t n0 = svcmpeq_f32(all, v0, v0), n1 = svcmpeq_f32(all, v1, v1);
        lo0 = svmin_f32_m(n0, lo0, v0), hi0 = svmax_f32_m(n0, hi0, v0);
        lo1 = svmin_f32_m(n1, lo1, v1), hi1 = svmax_f32_m(n1, hi1, v1);
    }
    for (; i < n; i += w) {
        svbool_t pg = svwhilelt_b32_u64(i, n);
        svfloat32_t v = svld1_f32(pg, x + i);
        svbool_t num = svcmpeq_f32(pg, v, v);
        lo0 = svmin_f32_m(num, lo0, v), hi0 = svmax_f32_m(num, hi0, v);
    }
    float l = svminv_f32(all, svmin_f32_x(all, lo0, lo1)), h = svmaxv_f32(all, svmax_f32_x(all, hi0, hi1));
    sb_min_max_end(&l, &h, 1, x, n, n, out);
}

// COMPACT moves the active lanes to the front; a full vector stores whole (k <= i), the tail its count.
static size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    svbool_t all = svptrue_b32();
    size_t w = svcntw(), i = 0, k = 0;
    for (; i + w <= n; i += w) {
        svfloat32_t v = svld1_f32(all, x + i);
        svbool_t m = svcmpgt_n_f32(all, v, t);
        svst1_f32(all, out + k, svcompact_f32(m, v));
        k += svcntp_b32(all, m);
    }
    if (i < n) {
        svbool_t pg = svwhilelt_b32_u64(i, n);
        svfloat32_t v = svld1_f32(pg, x + i);
        svbool_t m = svcmpgt_n_f32(pg, v, t);
        uint64_t c = svcntp_b32(pg, m);
        svst1_f32(svwhilelt_b32_u64(0, c), out + k, svcompact_f32(m, v));
        k += c;
    }
    return k;
}

static float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    svbool_t all = svptrue_b32();
    svfloat32_t z = svdup_n_f32(-0.0f), a0 = z, a1 = z, a2 = z, a3 = z, a4 = z, a5 = z, a6 = z, a7 = z;
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE) {
#define F(u) a##u = svadd_f32_x(all, a##u, svld1_gather_u32index_f32(all, x, svld1_u32(all, idx + i + 4 * u)));
        SB_ACC8(F)
#undef F
    }
    float l[SB_TREE];
#define F(u) svst1_f32(all, l + 4 * u, a##u);
    SB_ACC8(F)
#undef F
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    size_t w = svcntw();
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE)
        for (size_t j = 0; j < SB_ROW; j += w) {
            svbool_t pg = svwhilelt_b32_u64(j, SB_ROW);
            svst1_f32(pg, y + j, svmul_n_f32_x(pg, svld1_f32(pg, x + j), a));
        }
}

// Four f32 predicates pack into one byte predicate: UZP1 keeps each element's low predicate bit.
static void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    size_t w = svcntw(), b = svcntb();
    for (size_t i = 0; i < n; i += b) {
#define F(u) svcmpgt_n_f32(svwhilelt_b32_u64(i + u * w, n), svld1_f32(svwhilelt_b32_u64(i + u * w, n), x + i + u * w), t)
        svbool_t m = svuzp1_b8(svuzp1_b16(F(0), F(1)), svuzp1_b16(F(2), F(3)));
#undef F
        svbool_t pb = svwhilelt_b8_u64(i, n);
        svst1_u8(pb, out + i, svsel_u8(m, svld1_u8(pb, p + i), svld1_u8(pb, q + i)));
    }
}

static void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    svbool_t all = svptrue_b8();
    size_t w = svcntb(), i = 0;
    for (; i + 4 * w <= n; i += 4 * w)
        for (size_t j = i; j < i + 4 * w; j += w)
            svst1_u8(all, out + j, svabd_u8_x(all, svld1_u8(all, a + j), svld1_u8(all, b + j)));
    for (; i < n; i += w) {
        svbool_t pg = svwhilelt_b8_u64(i, n);
        svst1_u8(pg, out + i, svabd_u8_x(pg, svld1_u8(pg, a + i), svld1_u8(pg, b + i)));
    }
}

static uint64_t words(void) { return svcntw(); }

#ifdef __clang__
#pragma clang attribute pop
#else
#pragma GCC pop_options
#endif

static const sb_kernels table = {
    "sve",          saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32,    filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_sve(void) {
    // HWCAP_SVE, bit 22 of the kernel's arch/arm64/include/uapi/asm/hwcap.h.
    return (getauxval(AT_HWCAP) & (1ul << 22)) != 0 && words() == 4 ? &table : NULL;
}
#else
const void *sb_sve(void) { return NULL; }
#endif
