// The kernel table every instruction set's C file defines, and the scalar parts the files share. Each
// kernel is specified by its scalar loop in kernels.spc; `Kernels` there reads a table in this field order.
#ifndef SB_H
#define SB_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

#define SB_TREE 32 // lanes of the fixed reduction tree of dot_f32_tree and gather_sum_f32
#define SB_ROW 13 // tail_load_f32: elements per input row
#define SB_STRIDE 16 // tail_load_f32: output row stride

typedef struct {
    const char *name;
    void (*saxpy_f32)(float a, const float *x, float *y, size_t n);
    float (*dot_f32_ordered)(const float *x, const float *y, size_t n);
    float (*dot_f32_tree)(const float *x, const float *y, size_t n);
    size_t (*count_eq_u8)(const uint8_t *x, size_t n, uint8_t v);
    int32_t (*sum_i32)(const int32_t *x, size_t n);
    void (*min_max_f32)(const float *x, size_t n, float *out);
    size_t (*filter_gt_f32)(const float *x, size_t n, float t, float *out);
    float (*gather_sum_f32)(const float *x, const uint32_t *idx, size_t n);
    void (*tail_load_f32)(float a, const float *x, float *y, size_t rows);
    void (*mix_width)(const float *x, float t, const uint8_t *p, const uint8_t *q, uint8_t *out, size_t n);
    void (*abs_diff_u8)(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n);
} sb_kernels;

// Halves the SB_TREE lanes until one is left: lane j adds lane j + w for w = 16, 8, 4, 2, 1.
static inline float sb_tree(float *l) {
    for (int w = SB_TREE / 2; w > 0; w /= 2)
        for (int j = 0; j < w; j++) l[j] += l[j + w];
    return l[0];
}

// IEEE 754-2019 minimumNumber and maximumNumber of an accumulator a that is never NaN: a NaN b keeps a,
// and -0 < +0, so the reduction does not depend on the order.
static inline float sb_min(float a, float b) { return b < a || (b == a && signbit(b)) ? b : a; }
static inline float sb_max(float a, float b) { return b > a || (b == a && !signbit(b)) ? b : a; }

// Ends min_max_f32 from k lanes and the tail elements i..n; NaN when no element is a number.
static inline void sb_min_max_end(const float *lo, const float *hi, int k, const float *x, size_t i, size_t n,
                                  float *out) {
    float a = INFINITY, b = -INFINITY;
    for (int j = 0; j < k; j++) a = sb_min(a, lo[j]), b = sb_max(b, hi[j]);
    for (; i < n; i++) a = sb_min(a, x[i]), b = sb_max(b, x[i]);
    out[0] = a > b ? NAN : a;
    out[1] = a > b ? NAN : b;
}

// Wraps the sum of k lanes and the tail elements i..n.
static inline int32_t sb_sum_end(const uint32_t *l, int k, const int32_t *x, size_t i, size_t n) {
    uint32_t s = 0;
    for (int j = 0; j < k; j++) s += l[j];
    for (; i < n; i++) s += (uint32_t)x[i];
    return (int32_t)s;
}

// Byte shuffles that move the lanes a 4-bit mask selects to the front of a 4 x 32-bit vector.
#define SB_L(a, b, c, d) \
    {4 * a, 4 * a + 1, 4 * a + 2, 4 * a + 3, 4 * b, 4 * b + 1, 4 * b + 2, 4 * b + 3, \
     4 * c, 4 * c + 1, 4 * c + 2, 4 * c + 3, 4 * d, 4 * d + 1, 4 * d + 2, 4 * d + 3}
static const uint8_t sb_compress4[16][16] = {
    SB_L(0, 0, 0, 0), SB_L(0, 0, 0, 0), SB_L(1, 0, 0, 0), SB_L(0, 1, 0, 0), SB_L(2, 0, 0, 0), SB_L(0, 2, 0, 0),
    SB_L(1, 2, 0, 0), SB_L(0, 1, 2, 0), SB_L(3, 0, 0, 0), SB_L(0, 3, 0, 0), SB_L(1, 3, 0, 0), SB_L(0, 1, 3, 0),
    SB_L(2, 3, 0, 0), SB_L(0, 2, 3, 0), SB_L(1, 2, 3, 0), SB_L(0, 1, 2, 3),
};

#endif
