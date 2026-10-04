// wasm SIMD128 kernels: each function enables simd128; an engine without it rejects the module.
#include <wasm_simd128.h>

#include "sb.h"
#include "simd128.h"

#define T __attribute__((target("simd128")))

static T void saxpy_f32(float a, const float *x, float *y, size_t n) {
    v128_t va = wasm_f32x4_splat(a);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (size_t j = i; j < i + 16; j += 4)
            wasm_v128_store(y + j, wasm_f32x4_add(wasm_f32x4_mul(va, wasm_v128_load(x + j)), wasm_v128_load(y + j)));
    for (; i < n; i++) y[i] = a * x[i] + y[i];
}

static T float dot_f32_ordered(const float *x, const float *y, size_t n) {
    float s = -0.0f, p[4];
    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        wasm_v128_store(p, wasm_f32x4_mul(wasm_v128_load(x + i), wasm_v128_load(y + i)));
        for (int j = 0; j < 4; j++) s += p[j];
    }
    for (; i < n; i++) s += x[i] * y[i];
    return s;
}

static T float dot_f32_tree(const float *x, const float *y, size_t n) {
    v128_t acc[8];
    for (int u = 0; u < 8; u++) acc[u] = wasm_f32x4_splat(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++)
            acc[u] = wasm_f32x4_add(acc[u], wasm_f32x4_mul(wasm_v128_load(x + i + 4 * u), wasm_v128_load(y + i + 4 * u)));
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) wasm_v128_store(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[i] * y[i];
    return sb_tree(l);
}

static T size_t count_eq_u8(const uint8_t *x, size_t n, uint8_t v) {
    v128_t vv = wasm_u8x16_splat(v), z = wasm_i8x16_splat(0);
    size_t i = 0, c = 0;
    while (i + 64 <= n) {
        v128_t acc[4] = {z, z, z, z}; // a count per byte lane, summed before it can wrap
        for (int b = 0; b < 255 && i + 64 <= n; b++, i += 64)
            for (int u = 0; u < 4; u++) acc[u] = wasm_i8x16_sub(acc[u], wasm_i8x16_eq(wasm_v128_load(x + i + 16 * u), vv));
        for (int u = 0; u < 4; u++) {
            v128_t s = wasm_u32x4_extadd_pairwise_u16x8(wasm_u16x8_extadd_pairwise_u8x16(acc[u]));
            c += wasm_u32x4_extract_lane(s, 0) + wasm_u32x4_extract_lane(s, 1) + wasm_u32x4_extract_lane(s, 2) +
                 wasm_u32x4_extract_lane(s, 3);
        }
    }
    for (; i < n; i++) c += x[i] == v;
    return c;
}

static T int32_t sum_i32(const int32_t *x, size_t n) {
    v128_t acc[4];
    for (int u = 0; u < 4; u++) acc[u] = wasm_i32x4_splat(0);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) acc[u] = wasm_i32x4_add(acc[u], wasm_v128_load(x + i + 4 * u));
    uint32_t l[16];
    for (int u = 0; u < 4; u++) wasm_v128_store(l + 4 * u, acc[u]);
    return sb_sum_end(l, 16, x, i, n);
}

static T void min_max_f32(const float *x, size_t n, float *out) {
    // PMIN and PMAX keep the accumulator when the element is NaN or equal; an equal pair then takes the OR
    // (min) or the AND (max) of both, so -0 < +0.
    v128_t lo[4], hi[4];
    for (int u = 0; u < 4; u++) lo[u] = wasm_f32x4_splat(INFINITY), hi[u] = wasm_f32x4_splat(-INFINITY);
    size_t i = 0;
    for (; i + 16 <= n; i += 16)
        for (int u = 0; u < 4; u++) {
            v128_t v = wasm_v128_load(x + i + 4 * u);
            v128_t el = wasm_f32x4_eq(v, lo[u]), eh = wasm_f32x4_eq(v, hi[u]);
            lo[u] = wasm_v128_or(wasm_f32x4_pmin(lo[u], v), wasm_v128_and(el, v));
            hi[u] = wasm_v128_andnot(wasm_f32x4_pmax(hi[u], v), wasm_v128_andnot(eh, v));
        }
    float l[16], h[16];
    for (int u = 0; u < 4; u++) wasm_v128_store(l + 4 * u, lo[u]), wasm_v128_store(h + 4 * u, hi[u]);
    sb_min_max_end(l, h, 16, x, i, n, out);
}

static T size_t filter_gt_f32(const float *x, size_t n, float t, float *out) {
    v128_t vt = wasm_f32x4_splat(t);
    size_t i = 0, k = 0;
    for (; i + 4 <= n; i += 4) {
        v128_t v = wasm_v128_load(x + i);
        uint32_t m = wasm_i32x4_bitmask(wasm_f32x4_gt(v, vt));
        wasm_v128_store(out + k, wasm_i8x16_swizzle(v, wasm_v128_load(sb_compress4[m])));
        k += (size_t)__builtin_popcount(m);
    }
    for (; i < n; i++)
        if (x[i] > t) out[k++] = x[i];
    return k;
}

static T float gather_sum_f32(const float *x, const uint32_t *idx, size_t n) {
    v128_t acc[8];
    for (int u = 0; u < 8; u++) acc[u] = wasm_f32x4_splat(-0.0f);
    size_t i = 0;
    for (; i + SB_TREE <= n; i += SB_TREE)
        for (int u = 0; u < 8; u++) {
            const uint32_t *j = idx + i + 4 * u;
            acc[u] = wasm_f32x4_add(acc[u], wasm_f32x4_make(x[j[0]], x[j[1]], x[j[2]], x[j[3]]));
        }
    float l[SB_TREE];
    for (int u = 0; u < 8; u++) wasm_v128_store(l + 4 * u, acc[u]);
    for (; i < n; i++) l[i % SB_TREE] += x[idx[i]];
    return sb_tree(l);
}

static T void tail_load_f32(float a, const float *x, float *y, size_t rows) {
    v128_t va = wasm_f32x4_splat(a);
    for (size_t r = 0; r < rows; r++, x += SB_ROW, y += SB_STRIDE) {
        for (int j = 0; j < 12; j += 4) wasm_v128_store(y + j, wasm_f32x4_mul(va, wasm_v128_load(x + j)));
        y[12] = a * x[12]; // the one-lane tail
    }
}

static T void mix_width(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n) {
    v128_t vt = wasm_f32x4_splat(t);
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        v128_t c[4];
        for (int u = 0; u < 4; u++) c[u] = wasm_f32x4_gt(wasm_v128_load(x + i + 4 * u), vt);
        v128_t m = wasm_i8x16_narrow_i16x8(wasm_i16x8_narrow_i32x4(c[0], c[1]), wasm_i16x8_narrow_i32x4(c[2], c[3]));
        wasm_v128_store(out + i, wasm_v128_bitselect(wasm_v128_load(p + i), wasm_v128_load(q + i), m));
    }
    for (; i < n; i++) out[i] = x[i] > t ? p[i] : q[i];
}

static T void abs_diff_u8(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
    size_t i = 0;
    for (; i + 64 <= n; i += 64)
        for (size_t j = i; j < i + 64; j += 16) {
            v128_t va = wasm_v128_load(a + j), vb = wasm_v128_load(b + j);
            wasm_v128_store(out + j, wasm_v128_or(wasm_u8x16_sub_sat(va, vb), wasm_u8x16_sub_sat(vb, va)));
        }
    for (; i < n; i++) out[i] = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
}

static const sb_kernels table = {
    "simd128",   saxpy_f32,     dot_f32_ordered, dot_f32_tree,  count_eq_u8, sum_i32,
    min_max_f32, filter_gt_f32, gather_sum_f32,  tail_load_f32, mix_width,   abs_diff_u8,
};

const void *sb_simd128(void) { return &table; }
