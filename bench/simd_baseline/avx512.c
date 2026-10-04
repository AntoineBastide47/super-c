// AVX-512 kernels, with AVX-512BW and POPCNT: each function enables them, and `sb_avx512` returns the table
// only when the CPU has them.
#include <immintrin.h>

#include "avx512.h"
#include "sb.h"

#define T __attribute__((target("avx512f,avx512bw,popcnt")))
#define I(v) _mm512_castps_si512(v)

static T void saxpy_f32(float a, const float *x, float *y, size_t n) {
    __m512 va = _mm512_set1_ps(a);
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (size_t j = i; j < i + 64; j += 16)
            _mm512_storeu_ps(y + j, _mm512_add_ps(_mm512_mul_ps(va, _mm512_loadu_ps(x + j)), _mm512_loadu_ps(y + j)));
    for (; i < n; i++) y[i] = a * x[i] + y[i];
}

static T float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f, p[16];
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        _mm512_storeu_ps(p, _mm512_mul_ps(_mm512_loadu_ps(x + i), _mm512_loadu_ps(y + i)));
        for (int j = 0; j < 16; j++) s += p[j];
    }
    for (; i < n; i++) s += x[i] * y[i];
    return s;
}

static T float dot_f32_tree(const float *x, const float *y, size_t n) {
    __m512 acc[2] = {_mm512_set1_ps(-0.0f), _mm512_set1_ps(-0.0f)};
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 2; u++)
            acc[u] = _mm512_add_ps(acc[u], _mm512_mul_ps(_mm512_loadu_ps(x + i + 16 * u), _mm512_loadu_ps(y + i + 16 * u)));
    float l[SB_TREE];
    for (int u = 0; u < 2; u++) _mm512_storeu_ps(l + 16 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

static T size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    __m512i vv = _mm512_set1_epi8((char)v), z = _mm512_setzero_si512(), one = _mm512_set1_epi8(1), tot = z;
    size_t i = 0;
    while (i + 256 <= n) {
        __m512i acc[4] = {z, z, z, z}; // a count per byte lane, summed before it can wrap
        for (int b = 0; b < 255 && i + 256 <= n; b++, i += 256)
            for (int u = 0; u < 4; u++)
                acc[u] = _mm512_mask_add_epi8(acc[u], _mm512_cmpeq_epi8_mask(_mm512_loadu_si512(x + i + 64 * u), vv), acc[u], one);
        for (int u = 0; u < 4; u++) tot = _mm512_add_epi64(tot, _mm512_sad_epu8(acc[u], z));
    }
    size_t c = (size_t)_mm512_reduce_add_epi64(tot);
    for (; i < n; i++) c += x[i] == v;
    return c;
}

static T int32_t sum_i32(const int32_t *x, size_t n) {
    __m512i acc[4];
    for (int u = 0; u < 4; u++) acc[u] = _mm512_setzero_si512();
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (int u = 0; u < 4; u++) acc[u] = _mm512_add_epi32(acc[u], _mm512_loadu_si512(x + i + 16 * u));
    uint32_t l[64];
    for (int u = 0; u < 4; u++) _mm512_storeu_si512(l + 16 * u, acc[u]);
    return sb_sum_end(l, 64, x, i, n);
}

static T void min_max_f32(const float *x, size_t n, float *out) {
    // VMINPS and VMAXPS return the second operand when either is NaN or both are equal: a NaN lane keeps
    // the accumulator, and an equal pair takes the OR (min) or the AND (max) of both, so -0 < +0.
    __m512 lo[4], hi[4];
    for (int u = 0; u < 4; u++) lo[u] = _mm512_set1_ps(INFINITY), hi[u] = _mm512_set1_ps(-INFINITY);
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (int u = 0; u < 4; u++) {
            __m512 v = _mm512_loadu_ps(x + i + 16 * u);
            __mmask16 el = _mm512_cmp_ps_mask(v, lo[u], _CMP_EQ_OQ), eh = _mm512_cmp_ps_mask(v, hi[u], _CMP_EQ_OQ);
            __m512i mn = I(_mm512_min_ps(v, lo[u])), mx = I(_mm512_max_ps(v, hi[u]));
            lo[u] = _mm512_castsi512_ps(_mm512_mask_or_epi32(mn, el, mn, I(v)));
            hi[u] = _mm512_castsi512_ps(_mm512_mask_and_epi32(mx, eh, mx, I(v)));
        }
    float l[64], h[64];
    for (int u = 0; u < 4; u++) _mm512_storeu_ps(l + 16 * u, lo[u]), _mm512_storeu_ps(h + 16 * u, hi[u]);
    sb_min_max_end(l, h, 64, x, i, n, out);
}

static T size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    __m512 vt = _mm512_set1_ps(t);
    size_t i = 0, k = 0;
    // VCOMPRESSPS into a register, then a masked store of the count: the memory form is slow on AMD.
    for (; i + 16 <= n; i += 16) {
        __m512 v = _mm512_loadu_ps(x + i);
        __mmask16 m = _mm512_cmp_ps_mask(v, vt, _CMP_GT_OQ);
        int c = __builtin_popcount(m);
        _mm512_mask_storeu_ps(out + k, (__mmask16)((1u << c) - 1), _mm512_maskz_compress_ps(m, v));
        k += (size_t)c;
    }
    for (; i < n; i++)
        if (x[i] > t) out[k++] = x[i];
    return k;
}

static T float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    __m512 acc[2] = {_mm512_set1_ps(-0.0f), _mm512_set1_ps(-0.0f)};
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 2; u++)
            acc[u] = _mm512_add_ps(acc[u], _mm512_i32gather_ps(_mm512_loadu_si512(idx + i + 16 * u), x, 4));
    float l[SB_TREE];
    for (int u = 0; u < 2; u++) _mm512_storeu_ps(l + 16 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static T void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    __m512 va = _mm512_set1_ps(a);
    __mmask16 m = (1u << SB_ROW) - 1; // a whole row is one masked load and store
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE)
        _mm512_mask_storeu_ps(y, m, _mm512_mul_ps(va, _mm512_maskz_loadu_ps(m, x)));
}

static T void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    __m512 vt = _mm512_set1_ps(t);
    size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        __mmask64 m = 0;
        for (int u = 0; u < 4; u++)
            m |= (__mmask64)_mm512_cmp_ps_mask(_mm512_loadu_ps(x + i + 16 * u), vt, _CMP_GT_OQ) << (16 * u);
        _mm512_storeu_si512(out + i, _mm512_mask_blend_epi8(m, _mm512_loadu_si512(q + i), _mm512_loadu_si512(p + i)));
    }
    for (; i < n; i++) out[i] = x[i] > t ? p[i] : q[i];
}

static T void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    size_t i = 0;
    for (; i + 256 <= n; i += 256)
        for (size_t j = i; j < i + 256; j += 64) {
            __m512i va = _mm512_loadu_si512(a + j), vb = _mm512_loadu_si512(b + j);
            _mm512_storeu_si512(out + j, _mm512_or_si512(_mm512_subs_epu8(va, vb), _mm512_subs_epu8(vb, va)));
        }
    for (; i < n; i++) out[i] = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
}

static const sb_kernels table = {
    "avx512",    saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32, filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_avx512(void) {
    int ok = __builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw") &&
             __builtin_cpu_supports("popcnt");
    return ok ? &table : NULL;
}
