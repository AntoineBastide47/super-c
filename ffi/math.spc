// FFI bindings for <math.h>. Thin: C's math functions are already direct numeric operations, so these are
// raw `pub` bindings. Import with `import math;` and call e.g. `math::sqrt(2.0)`.
// Carries `@c.link("m")` (links libm); every call site requires `unsafe`.

@c.link("m")
extern "C" {
    // Powers, roots, exponentials, logarithms.
    pub fn sqrt(x: f64) f64;
    pub fn cbrt(x: f64) f64;
    pub fn pow(base: f64, exponent: f64) f64;
    pub fn exp(x: f64) f64;
    pub fn exp2(x: f64) f64;
    pub fn expm1(x: f64) f64;
    pub fn log(x: f64) f64;
    pub fn log2(x: f64) f64;
    pub fn log10(x: f64) f64;
    pub fn log1p(x: f64) f64;
    pub fn hypot(x: f64, y: f64) f64;

    // Trigonometry.
    pub fn sin(x: f64) f64;
    pub fn cos(x: f64) f64;
    pub fn tan(x: f64) f64;
    pub fn asin(x: f64) f64;
    pub fn acos(x: f64) f64;
    pub fn atan(x: f64) f64;
    pub fn atan2(y: f64, x: f64) f64;

    // Hyperbolic.
    pub fn sinh(x: f64) f64;
    pub fn cosh(x: f64) f64;
    pub fn tanh(x: f64) f64;
    pub fn asinh(x: f64) f64;
    pub fn acosh(x: f64) f64;
    pub fn atanh(x: f64) f64;

    // Rounding and remainder.
    pub fn floor(x: f64) f64;
    pub fn ceil(x: f64) f64;
    pub fn round(x: f64) f64;
    pub fn trunc(x: f64) f64;
    pub fn fabs(x: f64) f64;
    pub fn fmod(x: f64, y: f64) f64;
    pub fn remainder(x: f64, y: f64) f64;
    pub fn copysign(x: f64, y: f64) f64;

    // Min/max, fused multiply-add, and special functions.
    pub fn fmin(x: f64, y: f64) f64;
    pub fn fmax(x: f64, y: f64) f64;
    pub fn fma(x: f64, y: f64, z: f64) f64;
    pub fn erf(x: f64) f64;
    pub fn tgamma(x: f64) f64;
    pub fn lgamma(x: f64) f64;

    // f32 variants.
    pub fn sqrtf(x: f32) f32;
    pub fn cbrtf(x: f32) f32;
    pub fn powf(base: f32, exponent: f32) f32;
    pub fn expf(x: f32) f32;
    pub fn exp2f(x: f32) f32;
    pub fn expm1f(x: f32) f32;
    pub fn logf(x: f32) f32;
    pub fn log2f(x: f32) f32;
    pub fn log10f(x: f32) f32;
    pub fn log1pf(x: f32) f32;
    pub fn hypotf(x: f32, y: f32) f32;
    pub fn sinf(x: f32) f32;
    pub fn cosf(x: f32) f32;
    pub fn tanf(x: f32) f32;
    pub fn asinf(x: f32) f32;
    pub fn acosf(x: f32) f32;
    pub fn atanf(x: f32) f32;
    pub fn atan2f(y: f32, x: f32) f32;
    pub fn sinhf(x: f32) f32;
    pub fn coshf(x: f32) f32;
    pub fn tanhf(x: f32) f32;
    pub fn asinhf(x: f32) f32;
    pub fn acoshf(x: f32) f32;
    pub fn atanhf(x: f32) f32;
    pub fn floorf(x: f32) f32;
    pub fn ceilf(x: f32) f32;
    pub fn roundf(x: f32) f32;
    pub fn truncf(x: f32) f32;
    pub fn fabsf(x: f32) f32;
    pub fn fmodf(x: f32, y: f32) f32;
    pub fn remainderf(x: f32, y: f32) f32;
    pub fn copysignf(x: f32, y: f32) f32;
    pub fn fminf(x: f32, y: f32) f32;
    pub fn fmaxf(x: f32, y: f32) f32;
    pub fn fmaf(x: f32, y: f32, z: f32) f32;
    pub fn erff(x: f32) f32;
    pub fn tgammaf(x: f32) f32;
    pub fn lgammaf(x: f32) f32;
}
