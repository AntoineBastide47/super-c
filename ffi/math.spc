// FFI bindings for <math.h>. Thin: C's math functions are already direct numeric operations, so these are
// raw `pub` bindings. Import with `import math;` and call e.g. `math::sqrt(2.0)`.
// Carries `@c.link("m")` (links libm); every call site requires `unsafe`.

@c.link("m")
extern "C" {
    // Powers, roots, exponentials, logarithms.
    /// Square root; NaN for a negative argument.
    pub fn sqrt(x: f64) f64;
    /// Cube root (defined for negatives).
    pub fn cbrt(x: f64) f64;
    /// `base` raised to `exponent`.
    pub fn pow(base: f64, exponent: f64) f64;
    /// e^x.
    pub fn exp(x: f64) f64;
    /// 2^x.
    pub fn exp2(x: f64) f64;
    /// e^x - 1, accurate near zero.
    pub fn expm1(x: f64) f64;
    /// Natural logarithm; -inf at 0, NaN below.
    pub fn log(x: f64) f64;
    /// Base-2 logarithm.
    pub fn log2(x: f64) f64;
    /// Base-10 logarithm.
    pub fn log10(x: f64) f64;
    /// ln(1 + x), accurate near zero.
    pub fn log1p(x: f64) f64;
    /// sqrt(x^2 + y^2) without intermediate overflow.
    pub fn hypot(x: f64, y: f64) f64;

    // Trigonometry.
    /// Sine of an angle in radians.
    pub fn sin(x: f64) f64;
    /// Cosine of an angle in radians.
    pub fn cos(x: f64) f64;
    /// Tangent of an angle in radians.
    pub fn tan(x: f64) f64;
    /// Arc sine in radians; NaN outside [-1, 1].
    pub fn asin(x: f64) f64;
    /// Arc cosine in radians; NaN outside [-1, 1].
    pub fn acos(x: f64) f64;
    /// Arc tangent in radians.
    pub fn atan(x: f64) f64;
    /// Arc tangent of y/x using both signs to pick the quadrant.
    pub fn atan2(y: f64, x: f64) f64;

    // Hyperbolic.
    /// Hyperbolic sine.
    pub fn sinh(x: f64) f64;
    /// Hyperbolic cosine.
    pub fn cosh(x: f64) f64;
    /// Hyperbolic tangent.
    pub fn tanh(x: f64) f64;
    /// Inverse hyperbolic sine.
    pub fn asinh(x: f64) f64;
    /// Inverse hyperbolic cosine; NaN below 1.
    pub fn acosh(x: f64) f64;
    /// Inverse hyperbolic tangent; NaN outside [-1, 1].
    pub fn atanh(x: f64) f64;

    // Rounding and remainder.
    /// Largest integral value not above x.
    pub fn floor(x: f64) f64;
    /// Smallest integral value not below x.
    pub fn ceil(x: f64) f64;
    /// Nearest integral value, halves away from zero.
    pub fn round(x: f64) f64;
    /// Integral part, toward zero.
    pub fn trunc(x: f64) f64;
    /// Absolute value.
    pub fn fabs(x: f64) f64;
    /// Remainder of x/y with the sign of x.
    pub fn fmod(x: f64, y: f64) f64;
    /// IEEE remainder: x - n*y with n the nearest integer to x/y.
    pub fn remainder(x: f64, y: f64) f64;
    /// x with the sign of y.
    pub fn copysign(x: f64, y: f64) f64;

    // Min/max, fused multiply-add, and special functions.
    /// The smaller argument; a NaN argument is ignored.
    pub fn fmin(x: f64, y: f64) f64;
    /// The larger argument; a NaN argument is ignored.
    pub fn fmax(x: f64, y: f64) f64;
    /// x*y + z with a single rounding.
    pub fn fma(x: f64, y: f64, z: f64) f64;
    /// Error function.
    pub fn erf(x: f64) f64;
    /// Gamma function.
    pub fn tgamma(x: f64) f64;
    /// Natural log of the absolute gamma function.
    pub fn lgamma(x: f64) f64;

    // f32 variants.
    /// Square root; NaN for a negative argument (f32).
    pub fn sqrtf(x: f32) f32;
    /// Cube root (defined for negatives). (f32)
    pub fn cbrtf(x: f32) f32;
    /// `base` raised to `exponent`. (f32)
    pub fn powf(base: f32, exponent: f32) f32;
    /// e^x. (f32)
    pub fn expf(x: f32) f32;
    /// 2^x. (f32)
    pub fn exp2f(x: f32) f32;
    /// e^x - 1, accurate near zero. (f32)
    pub fn expm1f(x: f32) f32;
    /// Natural logarithm; -inf at 0, NaN below. (f32)
    pub fn logf(x: f32) f32;
    /// Base-2 logarithm. (f32)
    pub fn log2f(x: f32) f32;
    /// Base-10 logarithm. (f32)
    pub fn log10f(x: f32) f32;
    /// ln(1 + x), accurate near zero. (f32)
    pub fn log1pf(x: f32) f32;
    /// sqrt(x^2 + y^2) without intermediate overflow. (f32)
    pub fn hypotf(x: f32, y: f32) f32;
    /// Sine of an angle in radians. (f32)
    pub fn sinf(x: f32) f32;
    /// Cosine of an angle in radians. (f32)
    pub fn cosf(x: f32) f32;
    /// Tangent of an angle in radians. (f32)
    pub fn tanf(x: f32) f32;
    /// Arc sine in radians; NaN outside [-1, 1]. (f32)
    pub fn asinf(x: f32) f32;
    /// Arc cosine in radians; NaN outside [-1, 1]. (f32)
    pub fn acosf(x: f32) f32;
    /// Arc tangent in radians. (f32)
    pub fn atanf(x: f32) f32;
    /// Arc tangent of y/x using both signs to pick the quadrant. (f32)
    pub fn atan2f(y: f32, x: f32) f32;
    /// Hyperbolic sine. (f32)
    pub fn sinhf(x: f32) f32;
    /// Hyperbolic cosine. (f32)
    pub fn coshf(x: f32) f32;
    /// Hyperbolic tangent. (f32)
    pub fn tanhf(x: f32) f32;
    /// Inverse hyperbolic sine. (f32)
    pub fn asinhf(x: f32) f32;
    /// Inverse hyperbolic cosine; NaN below 1. (f32)
    pub fn acoshf(x: f32) f32;
    /// Inverse hyperbolic tangent; NaN outside [-1, 1]. (f32)
    pub fn atanhf(x: f32) f32;
    /// Largest integral value not above x. (f32)
    pub fn floorf(x: f32) f32;
    /// Smallest integral value not below x. (f32)
    pub fn ceilf(x: f32) f32;
    /// Nearest integral value, halves away from zero. (f32)
    pub fn roundf(x: f32) f32;
    /// Integral part, toward zero. (f32)
    pub fn truncf(x: f32) f32;
    /// Absolute value. (f32)
    pub fn fabsf(x: f32) f32;
    /// Remainder of x/y with the sign of x. (f32)
    pub fn fmodf(x: f32, y: f32) f32;
    /// IEEE remainder: x - n*y with n the nearest integer to x/y. (f32)
    pub fn remainderf(x: f32, y: f32) f32;
    /// x with the sign of y. (f32)
    pub fn copysignf(x: f32, y: f32) f32;
    /// The smaller argument; a NaN argument is ignored. (f32)
    pub fn fminf(x: f32, y: f32) f32;
    /// The larger argument; a NaN argument is ignored. (f32)
    pub fn fmaxf(x: f32, y: f32) f32;
    /// x*y + z with a single rounding. (f32)
    pub fn fmaf(x: f32, y: f32, z: f32) f32;
    /// Error function. (f32)
    pub fn erff(x: f32) f32;
    /// Gamma function. (f32)
    pub fn tgammaf(x: f32) f32;
    /// Natural log of the absolute gamma function. (f32)
    pub fn lgammaf(x: f32) f32;
}
