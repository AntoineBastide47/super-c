/* The state of the art beside simd-math-bench, on x86-64 with AVX2: per function and lane type, ns
   per element of the scalar C library loop, glibc's vector library (libmvec, AVX2 entry points) and
   SLEEF's AVX2 functions at 1.0 ULP (u10) and 3.5 ULP (u35), over the same input distributions as
   the bench (`bench.spc`). A vector function the installed libraries lack prints n/a.

     gcc -O2 -march=x86-64-v3 -o sota tools/simd_math/sota.c -Wl,--no-as-needed -lsleef -lmvec -lm && ./sota */
#define _GNU_SOURCE
#include <immintrin.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define ELEMS 4096
#define ROUNDS 100
#define TRIALS 9

typedef __m256d (*vd1)(__m256d);
typedef __m256 (*vf1)(__m256);
typedef __m256d (*vd2)(__m256d, __m256d);
typedef __m256 (*vf2)(__m256, __m256);

#define W __attribute__((weak))
#define DECL1(n)                                                                                       \
  __m256d _ZGVdN4v_##n(__m256d) W;                                                                     \
  __m256 _ZGVdN8v_##n##f(__m256) W;                                                                    \
  __m256d Sleef_##n##d4_u10avx2(__m256d) W;                                                            \
  __m256 Sleef_##n##f8_u10avx2(__m256) W;                                                              \
  __m256d Sleef_##n##d4_u35avx2(__m256d) W;                                                            \
  __m256 Sleef_##n##f8_u35avx2(__m256) W;
#define DECL2(n)                                                                                       \
  __m256d _ZGVdN4vv_##n(__m256d, __m256d) W;                                                           \
  __m256 _ZGVdN8vv_##n##f(__m256, __m256) W;                                                           \
  __m256d Sleef_##n##d4_u10avx2(__m256d, __m256d) W;                                                   \
  __m256 Sleef_##n##f8_u10avx2(__m256, __m256) W;                                                      \
  __m256d Sleef_##n##d4_u35avx2(__m256d, __m256d) W;                                                   \
  __m256 Sleef_##n##f8_u35avx2(__m256, __m256) W;                                                      \
  __m256d Sleef_##n##d4_u05avx2(__m256d, __m256d) W;                                                   \
  __m256 Sleef_##n##f8_u05avx2(__m256, __m256) W;

#define ONE(X)                                                                                         \
  X(exp, -80, 80, 0, 0, 0) X(exp2, -120, 120, 0, 0, 0) X(exp10, -35, 35, 0, 0, 0)                     \
  X(expm1, -30, 3, 1, 1, 0) X(log, -100, 100, 1, 0, 0) X(log2, -100, 100, 1, 0, 0)                     \
  X(log10, -100, 100, 1, 0, 0) X(log1p, -30, 20, 1, 0, 0) X(cbrt, -100, 100, 1, 1, 0)                  \
  X(sin, -100, 100, 0, 0, 0) X(cos, -100, 100, 0, 0, 0) X(tan, -100, 100, 0, 0, 0)                     \
  X(asin, -1, 1, 0, 0, 0) X(acos, -1, 1, 0, 0, 0) X(atan, -20, 20, 1, 1, 0)                            \
  X(sinh, -80, 80, 0, 0, 0) X(cosh, -80, 80, 0, 0, 0) X(tanh, -20, 20, 0, 0, 0)                        \
  X(asinh, -20, 30, 1, 1, 0) X(acosh, -20, 30, 1, 0, 1) X(atanh, -1, 1, 0, 0, 0)                       \
  X(erf, -5, 5, 0, 0, 0) X(erfc, -5, 25, 0, 0, 0)
#define TWO(X) X(pow) X(atan2) X(hypot)

#define D1(n, a, b, c, d, e) DECL1(n)
#define D2(n) DECL2(n)
ONE(D1)
TWO(D2)

static double xs[ELEMS], ys[ELEMS], out[ELEMS];
static float xf[ELEMS], yf[ELEMS], outf[ELEMS];
static uint64_t S = 0x5EED;
static volatile double SINK;

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}

static double unit(void) {
  S = S * 6364136223846793005ULL + 1442695040888963407ULL;
  return (double)(S >> 11) * 0x1p-53;
}

/* As `bench.spc`'s `Dist`: uniform on [lo, hi), or off + m 2^e with e per binade in [lo, hi). */
static double draw(double lo, double hi, int lg, int sg, double off) {
  if (!lg) return lo + (hi - lo) * unit();
  double v = ldexp(1.0 + unit(), (int)floor(lo + (hi - lo) * unit()));
  return off + (sg && unit() < 0.5 ? -v : v);
}

static void fill(double lo, double hi, int lg, int sg, double off, double ylo, double yhi, int ylg) {
  for (int i = 0; i < ELEMS; i++) {
    xs[i] = draw(lo, hi, lg, sg, off);
    ys[i] = draw(ylo, yhi, ylg, ylg, 0);
    xf[i] = (float)xs[i];
    yf[i] = (float)ys[i];
  }
}

#define TIME(body)                                                                                     \
  ({                                                                                                   \
    double best = 1e30;                                                                                \
    for (int t = 0; t < TRIALS; t++) {                                                                 \
      double t0 = now();                                                                               \
      for (int r = 0; r < ROUNDS; r++) body;                                                           \
      double d = now() - t0;                                                                           \
      if (d < best) best = d;                                                                          \
    }                                                                                                  \
    SINK += out[0] + outf[0];                                                                          \
    best / (ROUNDS * ELEMS);                                                                           \
  })

static double td1(vd1 f) {
  if (!f) return -1;
  return TIME(for (int i = 0; i < ELEMS; i += 4) _mm256_storeu_pd(out + i, f(_mm256_loadu_pd(xs + i))));
}
static double tf1(vf1 f) {
  if (!f) return -1;
  return TIME(for (int i = 0; i < ELEMS; i += 8) _mm256_storeu_ps(outf + i, f(_mm256_loadu_ps(xf + i))));
}
static double td2(vd2 f) {
  if (!f) return -1;
  return TIME(for (int i = 0; i < ELEMS; i += 4)
                  _mm256_storeu_pd(out + i, f(_mm256_loadu_pd(xs + i), _mm256_loadu_pd(ys + i))));
}
static double tf2(vf2 f) {
  if (!f) return -1;
  return TIME(for (int i = 0; i < ELEMS; i += 8)
                  _mm256_storeu_ps(outf + i, f(_mm256_loadu_ps(xf + i), _mm256_loadu_ps(yf + i))));
}

static void line(const char *name, int bits, double lib, double mvec, double u10, double u35) {
  printf("%s f%d: libm %.4g", name, bits, lib);
  const char *k[3] = {"libmvec", "sleef_u10", "sleef_u35"};
  double v[3] = {mvec, u10, u35};
  for (int i = 0; i < 3; i++) {
    if (v[i] < 0) printf(", %s n/a", k[i]);
    else printf(", %s %.4g", k[i], v[i]);
  }
  printf("\n");
}

#define RUN1(n, lo, hi, lg, sg, off)                                                                   \
  fill(lo, hi, lg, sg, off, 0, 1, 0);                                                                     \
  line(#n, 64, TIME(for (int i = 0; i < ELEMS; i++) out[i] = n(xs[i])), td1(_ZGVdN4v_##n),             \
       td1(Sleef_##n##d4_u10avx2), td1(Sleef_##n##d4_u35avx2));                                        \
  line(#n, 32, TIME(for (int i = 0; i < ELEMS; i++) outf[i] = n##f(xf[i])), tf1(_ZGVdN8v_##n##f),      \
       tf1(Sleef_##n##f8_u10avx2), tf1(Sleef_##n##f8_u35avx2));

#define RUN2(n, lo, hi, lg, sg, ylo, yhi, ylg)                                                         \
  fill(lo, hi, lg, sg, 0, ylo, yhi, ylg);                                                                    \
  line(#n, 64, TIME(for (int i = 0; i < ELEMS; i++) out[i] = n(xs[i], ys[i])), td2(_ZGVdN4vv_##n),     \
       td2(Sleef_##n##d4_u10avx2) >= 0 ? td2(Sleef_##n##d4_u10avx2) : td2(Sleef_##n##d4_u05avx2),      \
       td2(Sleef_##n##d4_u35avx2));                                                                    \
  line(#n, 32, TIME(for (int i = 0; i < ELEMS; i++) outf[i] = n##f(xf[i], yf[i])), tf2(_ZGVdN8vv_##n##f), \
       tf2(Sleef_##n##f8_u10avx2) >= 0 ? tf2(Sleef_##n##f8_u10avx2) : tf2(Sleef_##n##f8_u05avx2),      \
       tf2(Sleef_##n##f8_u35avx2));

int main(void) {
  /* Half a second of work first: the clock ramps up before the first function is timed. */
  double w0 = now();
  uint64_t spin = 1;
  while (now() - w0 < 5e8) spin = spin * 6364136223846793005ULL + 1;
  SINK += (double)(spin & 1);
  ONE(RUN1)
  RUN2(pow, -10, 10, 1, 0, -20, 20, 0)
  RUN2(atan2, -10, 10, 0, 0, -10, 10, 0)
  RUN2(hypot, -30, 30, 1, 1, -30, 30, 1)
  return SINK == 0.123;
}
