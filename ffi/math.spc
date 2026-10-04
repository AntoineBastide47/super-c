// FFI bindings for <math.h>. Thin: C's math functions are already direct numeric operations, so these are
// raw `pub` bindings. Import with `import math;` and call e.g. `math::sqrt(2.0)`.
// Carries `@c.link("m")` (links libm). Every function is `@unsafe(safe)` except `lgamma`/`lgammaf`,
// which write the global `signgam` (a data race between threads).

@c.link("m")
extern "C" {
    // Powers, roots, exponentials, logarithms.
    /// Square root; NaN for a negative argument.
    @unsafe(safe)
    pub fn sqrt(x: f64) f64;
    /// Cube root (defined for negatives).
    @unsafe(safe)
    pub fn cbrt(x: f64) f64;
    /// `base` raised to `exponent`.
    @unsafe(safe)
    pub fn pow(base: f64, exponent: f64) f64;
    /// e^x.
    @unsafe(safe)
    pub fn exp(x: f64) f64;
    /// 2^x.
    @unsafe(safe)
    pub fn exp2(x: f64) f64;
    /// e^x - 1, accurate near zero.
    @unsafe(safe)
    pub fn expm1(x: f64) f64;
    /// Natural logarithm; -inf at 0, NaN below.
    @unsafe(safe)
    pub fn log(x: f64) f64;
    /// Base-2 logarithm.
    @unsafe(safe)
    pub fn log2(x: f64) f64;
    /// Base-10 logarithm.
    @unsafe(safe)
    pub fn log10(x: f64) f64;
    /// ln(1 + x), accurate near zero.
    @unsafe(safe)
    pub fn log1p(x: f64) f64;
    /// sqrt(x^2 + y^2) without intermediate overflow.
    @unsafe(safe)
    pub fn hypot(x: f64, y: f64) f64;

    // Trigonometry.
    /// Sine of an angle in radians.
    @unsafe(safe)
    pub fn sin(x: f64) f64;
    /// Cosine of an angle in radians.
    @unsafe(safe)
    pub fn cos(x: f64) f64;
    /// Tangent of an angle in radians.
    @unsafe(safe)
    pub fn tan(x: f64) f64;
    /// Arc sine in radians; NaN outside [-1, 1].
    @unsafe(safe)
    pub fn asin(x: f64) f64;
    /// Arc cosine in radians; NaN outside [-1, 1].
    @unsafe(safe)
    pub fn acos(x: f64) f64;
    /// Arc tangent in radians.
    @unsafe(safe)
    pub fn atan(x: f64) f64;
    /// Arc tangent of y/x using both signs to pick the quadrant.
    @unsafe(safe)
    pub fn atan2(y: f64, x: f64) f64;

    // Hyperbolic.
    /// Hyperbolic sine.
    @unsafe(safe)
    pub fn sinh(x: f64) f64;
    /// Hyperbolic cosine.
    @unsafe(safe)
    pub fn cosh(x: f64) f64;
    /// Hyperbolic tangent.
    @unsafe(safe)
    pub fn tanh(x: f64) f64;
    /// Inverse hyperbolic sine.
    @unsafe(safe)
    pub fn asinh(x: f64) f64;
    /// Inverse hyperbolic cosine; NaN below 1.
    @unsafe(safe)
    pub fn acosh(x: f64) f64;
    /// Inverse hyperbolic tangent; NaN outside [-1, 1].
    @unsafe(safe)
    pub fn atanh(x: f64) f64;

    // Rounding and remainder.
    /// Largest integral value not above x.
    @unsafe(safe)
    pub fn floor(x: f64) f64;
    /// Smallest integral value not below x.
    @unsafe(safe)
    pub fn ceil(x: f64) f64;
    /// Nearest integral value, halves away from zero.
    @unsafe(safe)
    pub fn round(x: f64) f64;
    /// Integral part, toward zero.
    @unsafe(safe)
    pub fn trunc(x: f64) f64;
    /// Absolute value.
    @unsafe(safe)
    pub fn fabs(x: f64) f64;
    /// Remainder of x/y with the sign of x.
    @unsafe(safe)
    pub fn fmod(x: f64, y: f64) f64;
    /// IEEE remainder: x - n*y with n the nearest integer to x/y.
    @unsafe(safe)
    pub fn remainder(x: f64, y: f64) f64;
    /// x with the sign of y.
    @unsafe(safe)
    pub fn copysign(x: f64, y: f64) f64;

    // Min/max, fused multiply-add, and special functions.
    /// The smaller argument; a NaN argument is ignored.
    @unsafe(safe)
    pub fn fmin(x: f64, y: f64) f64;
    /// The larger argument; a NaN argument is ignored.
    @unsafe(safe)
    pub fn fmax(x: f64, y: f64) f64;
    /// x*y + z with a single rounding.
    @unsafe(safe)
    pub fn fma(x: f64, y: f64, z: f64) f64;
    /// Error function.
    @unsafe(safe)
    pub fn erf(x: f64) f64;
    /// Gamma function.
    @unsafe(safe)
    pub fn tgamma(x: f64) f64;
    /// Natural log of the absolute gamma function.
    pub fn lgamma(x: f64) f64;

    // f32 variants.
    /// Square root; NaN for a negative argument (f32).
    @unsafe(safe)
    pub fn sqrtf(x: f32) f32;
    /// Cube root (defined for negatives). (f32)
    @unsafe(safe)
    pub fn cbrtf(x: f32) f32;
    /// `base` raised to `exponent`. (f32)
    @unsafe(safe)
    pub fn powf(base: f32, exponent: f32) f32;
    /// e^x. (f32)
    @unsafe(safe)
    pub fn expf(x: f32) f32;
    /// 2^x. (f32)
    @unsafe(safe)
    pub fn exp2f(x: f32) f32;
    /// e^x - 1, accurate near zero. (f32)
    @unsafe(safe)
    pub fn expm1f(x: f32) f32;
    /// Natural logarithm; -inf at 0, NaN below. (f32)
    @unsafe(safe)
    pub fn logf(x: f32) f32;
    /// Base-2 logarithm. (f32)
    @unsafe(safe)
    pub fn log2f(x: f32) f32;
    /// Base-10 logarithm. (f32)
    @unsafe(safe)
    pub fn log10f(x: f32) f32;
    /// ln(1 + x), accurate near zero. (f32)
    @unsafe(safe)
    pub fn log1pf(x: f32) f32;
    /// sqrt(x^2 + y^2) without intermediate overflow. (f32)
    @unsafe(safe)
    pub fn hypotf(x: f32, y: f32) f32;
    /// Sine of an angle in radians. (f32)
    @unsafe(safe)
    pub fn sinf(x: f32) f32;
    /// Cosine of an angle in radians. (f32)
    @unsafe(safe)
    pub fn cosf(x: f32) f32;
    /// Tangent of an angle in radians. (f32)
    @unsafe(safe)
    pub fn tanf(x: f32) f32;
    /// Arc sine in radians; NaN outside [-1, 1]. (f32)
    @unsafe(safe)
    pub fn asinf(x: f32) f32;
    /// Arc cosine in radians; NaN outside [-1, 1]. (f32)
    @unsafe(safe)
    pub fn acosf(x: f32) f32;
    /// Arc tangent in radians. (f32)
    @unsafe(safe)
    pub fn atanf(x: f32) f32;
    /// Arc tangent of y/x using both signs to pick the quadrant. (f32)
    @unsafe(safe)
    pub fn atan2f(y: f32, x: f32) f32;
    /// Hyperbolic sine. (f32)
    @unsafe(safe)
    pub fn sinhf(x: f32) f32;
    /// Hyperbolic cosine. (f32)
    @unsafe(safe)
    pub fn coshf(x: f32) f32;
    /// Hyperbolic tangent. (f32)
    @unsafe(safe)
    pub fn tanhf(x: f32) f32;
    /// Inverse hyperbolic sine. (f32)
    @unsafe(safe)
    pub fn asinhf(x: f32) f32;
    /// Inverse hyperbolic cosine; NaN below 1. (f32)
    @unsafe(safe)
    pub fn acoshf(x: f32) f32;
    /// Inverse hyperbolic tangent; NaN outside [-1, 1]. (f32)
    @unsafe(safe)
    pub fn atanhf(x: f32) f32;
    /// Largest integral value not above x. (f32)
    @unsafe(safe)
    pub fn floorf(x: f32) f32;
    /// Smallest integral value not below x. (f32)
    @unsafe(safe)
    pub fn ceilf(x: f32) f32;
    /// Nearest integral value, halves away from zero. (f32)
    @unsafe(safe)
    pub fn roundf(x: f32) f32;
    /// Integral part, toward zero. (f32)
    @unsafe(safe)
    pub fn truncf(x: f32) f32;
    /// Absolute value. (f32)
    @unsafe(safe)
    pub fn fabsf(x: f32) f32;
    /// Remainder of x/y with the sign of x. (f32)
    @unsafe(safe)
    pub fn fmodf(x: f32, y: f32) f32;
    /// IEEE remainder: x - n*y with n the nearest integer to x/y. (f32)
    @unsafe(safe)
    pub fn remainderf(x: f32, y: f32) f32;
    /// x with the sign of y. (f32)
    @unsafe(safe)
    pub fn copysignf(x: f32, y: f32) f32;
    /// The smaller argument; a NaN argument is ignored. (f32)
    @unsafe(safe)
    pub fn fminf(x: f32, y: f32) f32;
    /// The larger argument; a NaN argument is ignored. (f32)
    @unsafe(safe)
    pub fn fmaxf(x: f32, y: f32) f32;
    /// x*y + z with a single rounding. (f32)
    @unsafe(safe)
    pub fn fmaf(x: f32, y: f32, z: f32) f32;
    /// Error function. (f32)
    @unsafe(safe)
    pub fn erff(x: f32) f32;
    /// Gamma function. (f32)
    @unsafe(safe)
    pub fn tgammaf(x: f32) f32;
    /// Natural log of the absolute gamma function. (f32)
    pub fn lgammaf(x: f32) f32;
}
