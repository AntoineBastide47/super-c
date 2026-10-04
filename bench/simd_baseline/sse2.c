// SSE2 kernels: the x86_64 baseline, so no target attribute.
#include <emmintrin.h>

#include "sb.h"
#include "sse2.h"

#define LD(p) _mm_loadu_si128((const __m128i *)(p))
#define ST(p, v) _mm_storeu_si128((__m128i *)(p), v)

static void saxpy_f32(float a, const float *x, float *y, size_t n) {
    __m128 va = _mm_set1_ps(a);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (size_t j = i; j < i + 16; j += 4)
            _mm_storeu_ps(y + j, _mm_add_ps(_mm_mul_ps(va, _mm_loadu_ps(x + j)), _mm_loadu_ps(y + j)));
    for (; i < n; i++) y[i] = a * x[i] + y[i];
}

static float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f, p[4];
    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        _mm_storeu_ps(p, _mm_mul_ps(_mm_loadu_ps(x + i), _mm_loadu_ps(y + i)));
        for (int j = 0; j < 4; j++) s += p[j];
    }
    for (; i < n; i++) s += x[i] * y[i];
    return s;
}

static float dot_f32_tree(const float *x, const float *y, size_t n) {
    __m128 acc[8];
    for (int u = 0; u < 8; u++) acc[u] = _mm_set1_ps(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++)
            acc[u] = _mm_add_ps(acc[u], _mm_mul_ps(_mm_loadu_ps(x + i + 4 * u), _mm_loadu_ps(y + i + 4 * u)));
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) _mm_storeu_ps(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

static size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    __m128i vv = _mm_set1_epi8((char)v), z = _mm_setzero_si128(), tot = z;
    size_t i = 0;
    while (i + 64 <= n) {
        __m128i acc[4] = {z, z, z, z}; // a count per byte lane, summed before it can wrap
        for (int b = 0; b < 255 && i + 64 <= n; b++, i += 64)
            for (int u = 0; u < 4; u++) acc[u] = _mm_sub_epi8(acc[u], _mm_cmpeq_epi8(LD(x + i + 16 * u), vv));
        for (int u = 0; u < 4; u++) tot = _mm_add_epi64(tot, _mm_sad_epu8(acc[u], z));
    }
    size_t c = (size_t)_mm_cvtsi128_si64(tot) + (size_t)_mm_cvtsi128_si64(_mm_unpackhi_epi64(tot, tot));
    for (; i < n; i++) c += x[i] == v;
    return c;
}

static int32_t sum_i32(const int32_t *x, size_t n) {
    __m128i acc[4];
    for (int u = 0; u < 4; u++) acc[u] = _mm_setzero_si128();
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) acc[u] = _mm_add_epi32(acc[u], LD(x + i + 4 * u));
    uint32_t l[16];
    for (int u = 0; u < 4; u++) ST(l + 4 * u, acc[u]);
    return sb_sum_end(l, 16, x, i, n);
}

static void min_max_f32(const float *x, size_t n, float *out) {
    // MINPS and MAXPS return the second operand when either is NaN or both are equal: a NaN lane keeps the
    // accumulator, and an equal pair takes the OR (min) or the AND (max) of both, so -0 < +0.
    __m128 lo[4], hi[4];
    for (int u = 0; u < 4; u++) lo[u] = _mm_set1_ps(INFINITY), hi[u] = _mm_set1_ps(-INFINITY);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) {
            __m128 v = _mm_loadu_ps(x + i + 4 * u);
            lo[u] = _mm_or_ps(_mm_min_ps(v, lo[u]), _mm_and_ps(_mm_cmpeq_ps(v, lo[u]), v));
            hi[u] = _mm_andnot_ps(_mm_andnot_ps(v, _mm_cmpeq_ps(v, hi[u])), _mm_max_ps(v, hi[u]));
        }
    float l[16], h[16];
    for (int u = 0; u < 4; u++) _mm_storeu_ps(l + 4 * u, lo[u]), _mm_storeu_ps(h + 4 * u, hi[u]);
    sb_min_max_end(l, h, 16, x, i, n, out);
}

static size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    __m128 vt = _mm_set1_ps(t);
    size_t i = 0, k = 0;
    // SSE2 has no variable shuffle: every lane is stored, and the count moves past the selected ones.
    for (; i + 4 <= n; i += 4) {
        int m = _mm_movemask_ps(_mm_cmpgt_ps(_mm_loadu_ps(x + i), vt));
        for (size_t j = 0; j < 4; j++) out[k] = x[i + j], k += (size_t)(m >> j & 1);
    }
    for (; i < n; i++)
        if (x[i] > t) out[k++] = x[i];
    return k;
}

static float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    __m128 acc[8];
    for (int u = 0; u < 8; u++) acc[u] = _mm_set1_ps(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++) {
            const uint32_t *j = idx + i + 4 * u;
            acc[u] = _mm_add_ps(acc[u], _mm_setr_ps(x[j[0]], x[j[1]], x[j[2]], x[j[3]]));
        }
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) _mm_storeu_ps(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    __m128 va = _mm_set1_ps(a);
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE) {
        for (int j = 0; j < 12; j += 4) _mm_storeu_ps(y + j, _mm_mul_ps(va, _mm_loadu_ps(x + j)));
        _mm_store_ss(y + 12, _mm_mul_ss(va, _mm_load_ss(x + 12))); // the one-lane tail
    }
}

static void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    __m128 vt = _mm_set1_ps(t);
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        __m128i c[4];
        for (int u = 0; u < 4; u++) c[u] = _mm_castps_si128(_mm_cmpgt_ps(_mm_loadu_ps(x + i + 4 * u), vt));
        __m128i m = _mm_packs_epi16(_mm_packs_epi32(c[0], c[1]), _mm_packs_epi32(c[2], c[3]));
        ST(out + i, _mm_or_si128(_mm_and_si128(m, LD(p + i)), _mm_andnot_si128(m, LD(q + i))));
    }
    for (; i < n; i++) out[i] = x[i] > t ? p[i] : q[i];
}

static void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (size_t j = i; j < i + 64; j += 16) {
            __m128i va = LD(a + j), vb = LD(b + j);
            ST(out + j, _mm_or_si128(_mm_subs_epu8(va, vb), _mm_subs_epu8(vb, va)));
        }
    for (; i < n; i++) out[i] = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
}

static const sb_kernels table = {
    "sse2",      saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32, filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_sse2(void) { return &table; }
