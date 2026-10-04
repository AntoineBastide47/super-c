// AVX2 kernels, with BMI2 and POPCNT (x86-64-v3): each function enables them, and `sb_avx2` returns the
// table only when the CPU has them.
#include <immintrin.h>

#include "avx2.h"
#include "sb.h"

#define T __attribute__((target("avx2,bmi2,popcnt")))
#define LD(p) _mm256_loadu_si256((const __m256i *)(p))
#define ST(p, v) _mm256_storeu_si256((__m256i *)(p), v)

static T void saxpy_f32(float a, const float *x, float *y, size_t n) {
    __m256 va = _mm256_set1_ps(a);
    size_t i = 0;
    for (; i + 32 <= n; i += 32)
        for (size_t j = i; j < i + 32; j += 8)
            _mm256_storeu_ps(y + j, _mm256_add_ps(_mm256_mul_ps(va, _mm256_loadu_ps(x + j)), _mm256_loadu_ps(y + j)));
    for (; i < n; i++) y[i] = a * x[i] + y[i];
}

static T float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f, p[8];
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        _mm256_storeu_ps(p, _mm256_mul_ps(_mm256_loadu_ps(x + i), _mm256_loadu_ps(y + i)));
        for (int j = 0; j < 8; j++) s += p[j];
    }
    for (; i < n; i++) s += x[i] * y[i];
    return s;
}

static T float dot_f32_tree(const float *x, const float *y, size_t n) {
    __m256 acc[4];
    for (int u = 0; u < 4; u++) acc[u] = _mm256_set1_ps(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 4; u++)
            acc[u] = _mm256_add_ps(acc[u], _mm256_mul_ps(_mm256_loadu_ps(x + i + 8 * u), _mm256_loadu_ps(y + i + 8 * u)));
    float l[SB_TREE];
    for (int u = 0; u < 4; u++) _mm256_storeu_ps(l + 8 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

static T size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    __m256i vv = _mm256_set1_epi8((char)v), z = _mm256_setzero_si256(), tot = z;
    size_t i = 0;
    while (i + 128 <= n) {
        __m256i acc[4] = {z, z, z, z}; // a count per byte lane, summed before it can wrap
        for (int b = 0; b < 255 && i + 128 <= n; b++, i += 128)
            for (int u = 0; u < 4; u++) acc[u] = _mm256_sub_epi8(acc[u], _mm256_cmpeq_epi8(LD(x + i + 32 * u), vv));
        for (int u = 0; u < 4; u++) tot = _mm256_add_epi64(tot, _mm256_sad_epu8(acc[u], z));
    }
    uint64_t l[4];
    ST(l, tot);
    size_t c = (size_t)(l[0] + l[1] + l[2] + l[3]);
    for (; i < n; i++) c += x[i] == v;
    return c;
}

static T int32_t sum_i32(const int32_t *x, size_t n) {
    __m256i acc[4];
    for (int u = 0; u < 4; u++) acc[u] = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 32 <= n; i += 32)
        for (int u = 0; u < 4; u++) acc[u] = _mm256_add_epi32(acc[u], LD(x + i + 8 * u));
    uint32_t l[32];
    for (int u = 0; u < 4; u++) ST(l + 8 * u, acc[u]);
    return sb_sum_end(l, 32, x, i, n);
}

static T void min_max_f32(const float *x, size_t n, float *out) {
    // VMINPS and VMAXPS return the second operand when either is NaN or both are equal: a NaN lane keeps
    // the accumulator, and an equal pair takes the OR (min) or the AND (max) of both, so -0 < +0.
    __m256 lo[4], hi[4];
    for (int u = 0; u < 4; u++) lo[u] = _mm256_set1_ps(INFINITY), hi[u] = _mm256_set1_ps(-INFINITY);
    size_t i = 0;
    for (; i + 32 <= n; i += 32)
        for (int u = 0; u < 4; u++) {
            __m256 v = _mm256_loadu_ps(x + i + 8 * u);
            __m256 el = _mm256_cmp_ps(v, lo[u], _CMP_EQ_OQ), eh = _mm256_cmp_ps(v, hi[u], _CMP_EQ_OQ);
            lo[u] = _mm256_or_ps(_mm256_min_ps(v, lo[u]), _mm256_and_ps(el, v));
            hi[u] = _mm256_andnot_ps(_mm256_andnot_ps(v, eh), _mm256_max_ps(v, hi[u]));
        }
    float l[32], h[32];
    for (int u = 0; u < 4; u++) _mm256_storeu_ps(l + 8 * u, lo[u]), _mm256_storeu_ps(h + 8 * u, hi[u]);
    sb_min_max_end(l, h, 32, x, i, n, out);
}

static T size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    __m256 vt = _mm256_set1_ps(t);
    size_t i = 0, k = 0;
    for (; i + 8 <= n; i += 8) {
        __m256 v = _mm256_loadu_ps(x + i);
        unsigned m = (unsigned)_mm256_movemask_ps(_mm256_cmp_ps(v, vt, _CMP_GT_OQ));
        // PDEP spreads mask bit j to byte j, and PEXT packs the indexes of the selected lanes to the front.
        uint64_t sel = _pext_u64(0x0706050403020100ull, _pdep_u64(m, 0x0101010101010101ull) * 0xff);
        __m256i perm = _mm256_cvtepu8_epi32(_mm_cvtsi64_si128((long long)sel));
        _mm256_storeu_ps(out + k, _mm256_permutevar8x32_ps(v, perm));
        k += (size_t)__builtin_popcount(m);
    }
    for (; i < n; i++)
        if (x[i] > t) out[k++] = x[i];
    return k;
}

static T float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    __m256 acc[4];
    for (int u = 0; u < 4; u++) acc[u] = _mm256_set1_ps(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 4; u++) acc[u] = _mm256_add_ps(acc[u], _mm256_i32gather_ps(x, LD(idx + i + 8 * u), 4));
    float l[SB_TREE];
    for (int u = 0; u < 4; u++) _mm256_storeu_ps(l + 8 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static T void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    __m256 va = _mm256_set1_ps(a);
    __m256i m = _mm256_setr_epi32(-1, -1, -1, -1, -1, 0, 0, 0); // elements 8 to 12 of a row
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE) {
        _mm256_storeu_ps(y, _mm256_mul_ps(va, _mm256_loadu_ps(x)));
        _mm256_maskstore_ps(y + 8, m, _mm256_mul_ps(va, _mm256_maskload_ps(x + 8, m)));
    }
}

static T void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    __m256 vt = _mm256_set1_ps(t);
    __m256i order = _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7);
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        __m256i c[4];
        for (int u = 0; u < 4; u++) c[u] = _mm256_castps_si256(_mm256_cmp_ps(_mm256_loadu_ps(x + i + 8 * u), vt, _CMP_GT_OQ));
        // The packs work in 128-bit halves; the permute puts the 4-byte groups back in element order.
        __m256i m = _mm256_packs_epi16(_mm256_packs_epi32(c[0], c[1]), _mm256_packs_epi32(c[2], c[3]));
        ST(out + i, _mm256_blendv_epi8(LD(q + i), LD(p + i), _mm256_permutevar8x32_epi32(m, order)));
    }
    for (; i < n; i++) out[i] = x[i] > t ? p[i] : q[i];
}

static T void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    size_t i = 0;
    for (; i + 128 <= n; i += 128)
        for (size_t j = i; j < i + 128; j += 32) {
            __m256i va = LD(a + j), vb = LD(b + j);
            ST(out + j, _mm256_or_si256(_mm256_subs_epu8(va, vb), _mm256_subs_epu8(vb, va)));
        }
    for (; i < n; i++) out[i] = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
}

static const sb_kernels table = {
    "avx2",      saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32, filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_avx2(void) {
    int ok = __builtin_cpu_supports("avx2") && __builtin_cpu_supports("bmi2") && __builtin_cpu_supports("popcnt");
    return ok ? &table : NULL;
}
