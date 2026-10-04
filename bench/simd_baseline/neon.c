// Neon kernels: the aarch64 baseline, so no target attribute.
#include <arm_neon.h>

#include "neon.h"
#include "sb.h"

static void saxpy_f32(float a, const float *x, float *y, size_t n) {
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (size_t j = i; j < i + 16; j += 4) vst1q_f32(y + j, vaddq_f32(vmulq_n_f32(vld1q_f32(x + j), a), vld1q_f32(y + j)));
    for (; i < n; i++) y[i] = a * x[i] + y[i];
}

static float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f, p[4];
    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        vst1q_f32(p, vmulq_f32(vld1q_f32(x + i), vld1q_f32(y + i)));
        for (int j = 0; j < 4; j++) s += p[j];
    }
    for (; i < n; i++) s += x[i] * y[i];
    return s;
}

static float dot_f32_tree(const float *x, const float *y, size_t n) {
    float32x4_t acc[8];
    for (int u = 0; u < 8; u++) acc[u] = vdupq_n_f32(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++)
            acc[u] = vaddq_f32(acc[u], vmulq_f32(vld1q_f32(x + i + 4 * u), vld1q_f32(y + i + 4 * u)));
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) vst1q_f32(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

static size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    uint8x16_t vv = vdupq_n_u8(v);
    size_t i = 0, c = 0;
    while (i + 64 <= n) {
        uint8x16_t acc[4]; // a count per byte lane, summed before it can wrap
        for (int u = 0; u < 4; u++) acc[u] = vdupq_n_u8(0);
        for (int b = 0; b < 255 && i + 64 <= n; b++, i += 64)
            for (int u = 0; u < 4; u++) acc[u] = vsubq_u8(acc[u], vceqq_u8(vld1q_u8(x + i + 16 * u), vv));
        for (int u = 0; u < 4; u++) c += vaddlvq_u8(acc[u]);
    }
    for (; i < n; i++) c += x[i] == v;
    return c;
}

static int32_t sum_i32(const int32_t *x, size_t n) {
    uint32x4_t acc[4];
    for (int u = 0; u < 4; u++) acc[u] = vdupq_n_u32(0);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) acc[u] = vaddq_u32(acc[u], vld1q_u32((const uint32_t *)x + i + 4 * u));
    uint32_t l[16];
    for (int u = 0; u < 4; u++) vst1q_u32(l + 4 * u, acc[u]);
    return sb_sum_end(l, 16, x, i, n);
}

static void min_max_f32(const float *x, size_t n, float *out) {
    // A NaN lane takes the accumulator's value first: FMINNM would return a NaN for a signaling one. FMIN
    // and FMAX order -0 < +0.
    float32x4_t lo[4], hi[4];
    for (int u = 0; u < 4; u++) lo[u] = vdupq_n_f32(INFINITY), hi[u] = vdupq_n_f32(-INFINITY);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) {
            float32x4_t v = vld1q_f32(x + i + 4 * u);
            uint32x4_t num = vceqq_f32(v, v);
            lo[u] = vminq_f32(lo[u], vbslq_f32(num, v, lo[u]));
            hi[u] = vmaxq_f32(hi[u], vbslq_f32(num, v, hi[u]));
        }
    float l[16], h[16];
    for (int u = 0; u < 4; u++) vst1q_f32(l + 4 * u, lo[u]), vst1q_f32(h + 4 * u, hi[u]);
    sb_min_max_end(l, h, 16, x, i, n, out);
}

static size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    const uint32x4_t bit = {1, 2, 4, 8};
    float32x4_t vt = vdupq_n_f32(t);
    size_t i = 0, k = 0;
    for (; i + 4 <= n; i += 4) {
        float32x4_t v = vld1q_f32(x + i);
        uint32_t m = vaddvq_u32(vandq_u32(vcgtq_f32(v, vt), bit));
        vst1q_u8((uint8_t *)(out + k), vqtbl1q_u8(vreinterpretq_u8_f32(v), vld1q_u8(sb_compress4[m])));
        k += (size_t)__builtin_popcount(m);
    }
    for (; i < n; i++)
        if (x[i] > t) out[k++] = x[i];
    return k;
}

static float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    float32x4_t acc[8];
    for (int u = 0; u < 8; u++) acc[u] = vdupq_n_f32(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++) {
            const uint32_t *j = idx + i + 4 * u;
            float g[4] = {x[j[0]], x[j[1]], x[j[2]], x[j[3]]};
            acc[u] = vaddq_f32(acc[u], vld1q_f32(g));
        }
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) vst1q_f32(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE) {
        for (int j = 0; j < 12; j += 4) vst1q_f32(y + j, vmulq_n_f32(vld1q_f32(x + j), a));
        y[12] = a * x[12]; // the one-lane tail
    }
}

static void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    float32x4_t vt = vdupq_n_f32(t);
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint32x4_t c[4];
        for (int u = 0; u < 4; u++) c[u] = vcgtq_f32(vld1q_f32(x + i + 4 * u), vt);
        uint16x8_t c01 = vuzp1q_u16(vreinterpretq_u16_u32(c[0]), vreinterpretq_u16_u32(c[1]));
        uint16x8_t c23 = vuzp1q_u16(vreinterpretq_u16_u32(c[2]), vreinterpretq_u16_u32(c[3]));
        uint8x16_t m = vuzp1q_u8(vreinterpretq_u8_u16(c01), vreinterpretq_u8_u16(c23));
        vst1q_u8(out + i, vbslq_u8(m, vld1q_u8(p + i), vld1q_u8(q + i)));
    }
    for (; i < n; i++) out[i] = x[i] > t ? p[i] : q[i];
}

static void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (size_t j = i; j < i + 64; j += 16) vst1q_u8(out + j, vabdq_u8(vld1q_u8(a + j), vld1q_u8(b + j)));
    for (; i < n; i++) out[i] = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
}

static const sb_kernels table = {
    "neon",         saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32,    filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_neon(void) { return &table; }
