// The element types of std::math. `Elem` is every vector element (`bool` and the numbers), `Scalar` the
// numbers, `Float` f32, f64 and every `Float<E, F>` (f16, bf16, f128, ..), `Int` the built-in integers,
// `Int<N>` and `UInt<N>`. `+ - * / %`, negation and shifts of `u8`..`u64`, `i8` and `i16` wrap; on `i32`,
// `i64`, `Int<N>` and `UInt<N>` they keep Super-C's checked overflow: a trap in a profile with overflow
// checks. A `Float<E, F>` rounds once per operation, as its own operators do; its elementary functions are
// std::math::wide's. Float comparisons are IEEE (NaN is unordered), not the total order of `Ord`.

import std::float as sf;
import std::int as si;
import std::math::wide as wd;

extern "C" {
    fn frexp(x: f64, e: *mut i32) f64;
    fn frexpf(x: f32, e: *mut i32) f32;
    fn ldexp(x: f64, e: i32) f64;
    fn ldexpf(x: f32, e: i32) f32;
    fn modf(x: f64, i: *mut f64) f64;
    fn modff(x: f32, i: *mut f32) f32;
    fn nextafter(x: f64, y: f64) f64;
    fn nextafterf(x: f32, y: f32) f32;
}

/// A vector element: `bool` or a `Scalar`. `equal` and `not_equal` are IEEE for floats.
pub interface Elem: Copy {
    fn equal(self: Self, other: Self) bool;
    fn not_equal(self: Self, other: Self) bool;
}

/// A number: `i8`..`i64`, `u8`..`u64`, `f32`, `f64`, `Int<N>`, `UInt<N>` or `Float<E, F>`. The operators
/// of a generic `T: Scalar` dispatch to these methods.
pub interface Scalar: Elem {
    fn add(self: &Self, other: &Self) Self;
    fn sub(self: &Self, other: &Self) Self;
    fn mul(self: &Self, other: &Self) Self;
    /// Traps on an integer division by zero and on `MIN / -1` of `i32` and `i64`.
    fn div(self: &Self, other: &Self) Self;
    fn neg(self: &Self) Self;
    fn less(self: Self, other: Self) bool;
    fn less_equal(self: Self, other: Self) bool;
    fn greater(self: Self, other: Self) bool;
    fn greater_equal(self: Self, other: Self) bool;
    fn zero() Self;
    fn one() Self;
    /// `v as Self`: rounds to nearest for a float, truncates and saturates for an integer.
    fn from_f64(v: f64) Self;
    fn from_f32(v: f32) Self;
    /// `v as Self`: wraps for an integer, rounds to nearest for a float.
    fn from_i64(v: i64) Self;
    fn from_u64(v: u64) Self;
    /// `v as Self`, once from the exact value: rounds to nearest for a float, truncates and saturates
    /// for an integer (NaN gives 0).
    fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) Self;
    /// `v as Self`: wraps for an integer, rounds to nearest for a float.
    fn from_uint<const M: usize>(v: si::UInt<M>) Self;
    fn from_int<const M: usize>(v: si::Int<M>) Self;
    /// A constant written as the f64 literal `v` and the decimal text `digits` of its exact value (60 or more
    /// significant digits): `from_f64(v)` for f32, f64, the integers and the float formats exact in f64,
    /// `digits` rounded once for a wider float format (decimal text needs an exponent field of at most 28
    /// bits).
    fn from_decimal(v: f64, digits: str) Self;
    /// `self` converted to `U` with `as`, once from the exact value.
    fn cast<U: Scalar>(self: Self) U;
    /// The type letters of a vector, matrix or quaternion name: "" for f32, "d" for f64, "i" and "u" for
    /// i32 and u32, "i8" .. "u64" for the other built-in integers, "i128", "u256", .. for `Int<N>` and
    /// `UInt<N>`, a float format's std alias ("f16", "bf16", "f128", ..) or "f<bits>e<E>m<F>".
    fn push_name(s: &mut String);
    /// The text of a component: C's `%f` of a built-in float or of a format exact in f64, C's `%d` of the
    /// low 32 bits of a built-in integer, a wider float format's own `to_string` (`1.5e+0`: the digits that
    /// read back as the value, in scientific notation), and the decimal value of `Int<N>` and `UInt<N>`.
    fn push_value(s: &mut String, v: Self);
    fn is_float() bool;
    fn is_signed() bool;
}

/// `f32`, `f64` or a `Float<E, F>`. The functions of f32 and f64 are the C library's (`sqrt`, `sin`, ..),
/// those of `Float<E, F>` std::math::wide's.
pub interface Float: Scalar {
    /// The signed integer of the same width (`i32`, `i64`, `Int<1 + E + F>`).
    type Int;
    /// The unsigned integer of the same width (`u32`, `u64`, `UInt<1 + E + F>`).
    type UInt;
    fn abs(self: Self) Self;
    fn floor(self: Self) Self;
    fn ceil(self: Self) Self;
    fn trunc(self: Self) Self;
    /// Halves away from zero.
    fn round(self: Self) Self;
    fn sqrt(self: Self) Self;
    fn exp(self: Self) Self;
    fn exp2(self: Self) Self;
    /// The natural logarithm.
    fn ln(self: Self) Self;
    fn log2(self: Self) Self;
    fn pow(self: Self, e: Self) Self;
    fn sin(self: Self) Self;
    fn cos(self: Self) Self;
    fn tan(self: Self) Self;
    fn asin(self: Self) Self;
    fn acos(self: Self) Self;
    fn atan(self: Self) Self;
    /// `atan2(self, x)`.
    fn atan2(self: Self, x: Self) Self;
    fn sinh(self: Self) Self;
    fn cosh(self: Self) Self;
    fn tanh(self: Self) Self;
    fn asinh(self: Self) Self;
    fn acosh(self: Self) Self;
    fn atanh(self: Self) Self;
    /// `self * a + b` rounded once.
    fn fma(self: Self, a: Self, b: Self) Self;
    /// C's `fmod`: the remainder of `self / y`, with the sign of `self`.
    fn fmod(self: Self, y: Self) Self;
    /// C's `fmin`: the smaller value; a NaN loses to a number.
    fn fmin(self: Self, other: Self) Self;
    /// C's `fmax`: the larger value; a NaN loses to a number.
    fn fmax(self: Self, other: Self) Self;
    /// C's `modf`: (fractional part, integral part), both with the sign of `self`.
    fn modf(self: Self) (Self, Self);
    /// C's `frexp`: (mantissa in [0.5, 1), exponent).
    fn frexp(self: Self) (Self, i32);
    /// C's `ldexp`: `self * 2^e`.
    fn ldexp(self: Self, e: i32) Self;
    /// C's `nextafter`: the next representable value after `self` toward `toward`.
    fn next_after(self: Self, toward: Self) Self;
    fn is_nan(self: Self) bool;
    fn is_inf(self: Self) bool;
    /// The bit pattern, zero-extended (the low 32 bits for `f32`; the low 64 of a wider format).
    fn to_bits(self: Self) u64;
    /// The value of the low `size * 8` bits of `b`.
    fn from_bits(b: u64) Self;
    /// The bit pattern as a signed integer.
    fn bits_int(self: Self) Self::Int;
    /// The bit pattern as an unsigned integer.
    fn bits_uint(self: Self) Self::UInt;
    /// The value of the bit pattern `b`.
    fn from_bits_int(b: Self::Int) Self;
    /// The value of the bit pattern `b`.
    fn from_bits_uint(b: Self::UInt) Self;
    /// The distance of the encodings of `self` and `other` (the values between them, one more) when both
    /// have the same sign bit; `u64::MAX` for different sign bits or a distance past it.
    fn ulp_distance(self: Self, other: Self) u64;
    /// The difference between 1 and the next larger value.
    fn epsilon() Self;
    /// The largest finite value.
    fn max_finite() Self;
    /// The smallest positive normal value.
    fn min_positive() Self;
    fn infinity() Self;
    /// A quiet NaN.
    fn nan() Self;
}

/// `i8`..`i64`, `u8`..`u64`, `Int<N>` or `UInt<N>`. Shift counts have the shifted type.
pub interface Int: Scalar {
    /// Traps on a zero divisor and on `MIN % -1` of `i32` and `i64`.
    fn rem(self: &Self, other: &Self) Self;
    fn bit_and(self: &Self, other: &Self) Self;
    fn bit_or(self: &Self, other: &Self) Self;
    fn bit_xor(self: &Self, other: &Self) Self;
    fn bit_not(self: &Self) Self;
    /// Traps on a count below 0 or of 32 or more for 8-, 16- and 32-bit types (an 8- or 16-bit value
    /// shifts as an `i32`), of 64 or more for 64-bit ones.
    fn shl(self: &Self, n: Self) Self;
    /// Arithmetic for a signed type; the same counts trap as for `shl`.
    fn shr(self: &Self, n: Self) Self;
    fn count_ones(self: Self) i32;
    /// The bit width for zero.
    fn leading_zeros(self: Self) i32;
    /// The bit width for zero.
    fn trailing_zeros(self: Self) i32;
    fn bits() i32;
    fn min_value() Self;
    fn max_value() Self;
    /// Sign-extended for a signed type, zero-extended for an unsigned one.
    fn to_i64(self: Self) i64;
    fn to_u64(self: Self) u64;
}

extend bool as Elem {
    pub fn equal(self: bool, other: bool) bool {
        return self == other;
    }
    pub fn not_equal(self: bool, other: bool) bool {
        return self != other;
    }
}

extend f32 as Elem {
    pub fn equal(self: f32, other: f32) bool {
        return self == other;
    }
    pub fn not_equal(self: f32, other: f32) bool {
        return self != other;
    }
}

extend f32 as Scalar {
    pub fn add(self: &f32, other: &f32) f32 {
        return *self + *other;
    }
    pub fn sub(self: &f32, other: &f32) f32 {
        return *self - *other;
    }
    pub fn mul(self: &f32, other: &f32) f32 {
        return *self * *other;
    }
    pub fn div(self: &f32, other: &f32) f32 {
        return *self / *other;
    }
    pub fn neg(self: &f32) f32 {
        return -*self;
    }
    pub fn less(self: f32, other: f32) bool {
        return self < other;
    }
    pub fn less_equal(self: f32, other: f32) bool {
        return self <= other;
    }
    pub fn greater(self: f32, other: f32) bool {
        return self > other;
    }
    pub fn greater_equal(self: f32, other: f32) bool {
        return self >= other;
    }
    pub fn zero() f32 {
        return 0.0;
    }
    pub fn one() f32 {
        return 1.0;
    }
    pub fn from_f64(v: f64) f32 {
        return v as f32;
    }
    pub fn from_f32(v: f32) f32 {
        return v;
    }
    pub fn from_i64(v: i64) f32 {
        return v as f32;
    }
    pub fn from_u64(v: u64) f32 {
        return v as f32;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) f32 {
        return v.to_f32();
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) f32 {
        return v.to_f32();
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) f32 {
        return v.to_f32();
    }
    pub fn from_decimal(v: f64, digits: str) f32 {
        return v as f32;
    }
    pub fn cast<U: Scalar>(self: f32) U {
        return U::from_f32(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("");
    }
    pub fn push_value(s: &mut String, v: f32) {
        s.push_f64_prec(v, 6);
    }
    pub fn is_float() bool {
        return true;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend f32 as Float {
    type Int = i32;
    type UInt = u32;
    pub fn abs(self: f32) f32 {
        return self.abs();
    }
    pub fn floor(self: f32) f32 {
        return self.floor();
    }
    pub fn ceil(self: f32) f32 {
        return self.ceil();
    }
    pub fn trunc(self: f32) f32 {
        return self.trunc();
    }
    pub fn round(self: f32) f32 {
        return self.round();
    }
    pub fn sqrt(self: f32) f32 {
        return self.sqrt();
    }
    pub fn exp(self: f32) f32 {
        return self.exp();
    }
    pub fn exp2(self: f32) f32 {
        return self.exp2();
    }
    pub fn ln(self: f32) f32 {
        return self.ln();
    }
    pub fn log2(self: f32) f32 {
        return self.log2();
    }
    pub fn pow(self: f32, e: f32) f32 {
        return self.powf(e);
    }
    pub fn sin(self: f32) f32 {
        return self.sin();
    }
    pub fn cos(self: f32) f32 {
        return self.cos();
    }
    pub fn tan(self: f32) f32 {
        return self.tan();
    }
    pub fn asin(self: f32) f32 {
        return self.asin();
    }
    pub fn acos(self: f32) f32 {
        return self.acos();
    }
    pub fn atan(self: f32) f32 {
        return self.atan();
    }
    pub fn atan2(self: f32, x: f32) f32 {
        return self.atan2(x);
    }
    pub fn sinh(self: f32) f32 {
        return self.sinh();
    }
    pub fn cosh(self: f32) f32 {
        return self.cosh();
    }
    pub fn tanh(self: f32) f32 {
        return self.tanh();
    }
    pub fn asinh(self: f32) f32 {
        return self.asinh();
    }
    pub fn acosh(self: f32) f32 {
        return self.acosh();
    }
    pub fn atanh(self: f32) f32 {
        return self.atanh();
    }
    pub fn fma(self: f32, a: f32, b: f32) f32 {
        return self.mul_add(a, b);
    }
    pub fn fmod(self: f32, y: f32) f32 {
        return self % y;
    }
    pub fn fmin(self: f32, other: f32) f32 {
        return self.min(other);
    }
    pub fn fmax(self: f32, other: f32) f32 {
        return self.max(other);
    }
    pub fn modf(self: f32) (f32, f32) {
        let mut i: f32 = 0.0;
        let f = unsafe modff(self, &mut i);
        return (f, i);
    }
    pub fn frexp(self: f32) (f32, i32) {
        let mut e: i32 = 0;
        let m = unsafe frexpf(self, &mut e);
        return (m, e);
    }
    pub fn ldexp(self: f32, e: i32) f32 {
        return unsafe ldexpf(self, e);
    }
    pub fn next_after(self: f32, toward: f32) f32 {
        return unsafe nextafterf(self, toward);
    }
    pub fn is_nan(self: f32) bool {
        return self.is_nan();
    }
    pub fn is_inf(self: f32) bool {
        return self.is_infinite();
    }
    pub fn to_bits(self: f32) u64 {
        return f32_bits(self);
    }
    pub fn from_bits(b: u64) f32 {
        return f32_from_bits(b as u32);
    }
    pub fn bits_int(self: f32) i32 {
        return f32_bits(self) as i32;
    }
    pub fn bits_uint(self: f32) u32 {
        return f32_bits(self);
    }
    pub fn from_bits_int(b: i32) f32 {
        return f32_from_bits(b as u32);
    }
    pub fn from_bits_uint(b: u32) f32 {
        return f32_from_bits(b);
    }
    pub fn ulp_distance(self: f32, other: f32) u64 {
        let a = f32_bits(self);
        let b = f32_bits(other);
        if (a ^ b) >> 31 != 0 {
            return u64::MAX;
        }
        return if a > b {
            a - b
        } else {
            b - a
        };
    }
    pub fn epsilon() f32 {
        return f32_from_bits(0x34000000);
    }
    pub fn max_finite() f32 {
        return f32_from_bits(0x7F7FFFFF);
    }
    pub fn min_positive() f32 {
        return f32_from_bits(0x00800000);
    }
    pub fn infinity() f32 {
        return f32_from_bits(0x7F800000);
    }
    pub fn nan() f32 {
        return f32_from_bits(0x7FC00000);
    }
}

extend f64 as Elem {
    pub fn equal(self: f64, other: f64) bool {
        return self == other;
    }
    pub fn not_equal(self: f64, other: f64) bool {
        return self != other;
    }
}

extend f64 as Scalar {
    pub fn add(self: &f64, other: &f64) f64 {
        return *self + *other;
    }
    pub fn sub(self: &f64, other: &f64) f64 {
        return *self - *other;
    }
    pub fn mul(self: &f64, other: &f64) f64 {
        return *self * *other;
    }
    pub fn div(self: &f64, other: &f64) f64 {
        return *self / *other;
    }
    pub fn neg(self: &f64) f64 {
        return -*self;
    }
    pub fn less(self: f64, other: f64) bool {
        return self < other;
    }
    pub fn less_equal(self: f64, other: f64) bool {
        return self <= other;
    }
    pub fn greater(self: f64, other: f64) bool {
        return self > other;
    }
    pub fn greater_equal(self: f64, other: f64) bool {
        return self >= other;
    }
    pub fn zero() f64 {
        return 0.0;
    }
    pub fn one() f64 {
        return 1.0;
    }
    pub fn from_f64(v: f64) f64 {
        return v;
    }
    pub fn from_f32(v: f32) f64 {
        return v;
    }
    pub fn from_i64(v: i64) f64 {
        return v as f64;
    }
    pub fn from_u64(v: u64) f64 {
        return v as f64;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) f64 {
        return v.to_f64();
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) f64 {
        return v.to_f64();
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) f64 {
        return v.to_f64();
    }
    pub fn from_decimal(v: f64, digits: str) f64 {
        return v;
    }
    pub fn cast<U: Scalar>(self: f64) U {
        return U::from_f64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("d");
    }
    pub fn push_value(s: &mut String, v: f64) {
        s.push_f64_prec(v, 6);
    }
    pub fn is_float() bool {
        return true;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend f64 as Float {
    type Int = i64;
    type UInt = u64;
    pub fn abs(self: f64) f64 {
        return self.abs();
    }
    pub fn floor(self: f64) f64 {
        return self.floor();
    }
    pub fn ceil(self: f64) f64 {
        return self.ceil();
    }
    pub fn trunc(self: f64) f64 {
        return self.trunc();
    }
    pub fn round(self: f64) f64 {
        return self.round();
    }
    pub fn sqrt(self: f64) f64 {
        return self.sqrt();
    }
    pub fn exp(self: f64) f64 {
        return self.exp();
    }
    pub fn exp2(self: f64) f64 {
        return self.exp2();
    }
    pub fn ln(self: f64) f64 {
        return self.ln();
    }
    pub fn log2(self: f64) f64 {
        return self.log2();
    }
    pub fn pow(self: f64, e: f64) f64 {
        return self.powf(e);
    }
    pub fn sin(self: f64) f64 {
        return self.sin();
    }
    pub fn cos(self: f64) f64 {
        return self.cos();
    }
    pub fn tan(self: f64) f64 {
        return self.tan();
    }
    pub fn asin(self: f64) f64 {
        return self.asin();
    }
    pub fn acos(self: f64) f64 {
        return self.acos();
    }
    pub fn atan(self: f64) f64 {
        return self.atan();
    }
    pub fn atan2(self: f64, x: f64) f64 {
        return self.atan2(x);
    }
    pub fn sinh(self: f64) f64 {
        return self.sinh();
    }
    pub fn cosh(self: f64) f64 {
        return self.cosh();
    }
    pub fn tanh(self: f64) f64 {
        return self.tanh();
    }
    pub fn asinh(self: f64) f64 {
        return self.asinh();
    }
    pub fn acosh(self: f64) f64 {
        return self.acosh();
    }
    pub fn atanh(self: f64) f64 {
        return self.atanh();
    }
    pub fn fma(self: f64, a: f64, b: f64) f64 {
        return self.mul_add(a, b);
    }
    pub fn fmod(self: f64, y: f64) f64 {
        return self % y;
    }
    pub fn fmin(self: f64, other: f64) f64 {
        return self.min(other);
    }
    pub fn fmax(self: f64, other: f64) f64 {
        return self.max(other);
    }
    pub fn modf(self: f64) (f64, f64) {
        let mut i: f64 = 0.0;
        let f = unsafe modf(self, &mut i);
        return (f, i);
    }
    pub fn frexp(self: f64) (f64, i32) {
        let mut e: i32 = 0;
        let m = unsafe frexp(self, &mut e);
        return (m, e);
    }
    pub fn ldexp(self: f64, e: i32) f64 {
        return unsafe ldexp(self, e);
    }
    pub fn next_after(self: f64, toward: f64) f64 {
        return unsafe nextafter(self, toward);
    }
    pub fn is_nan(self: f64) bool {
        return self.is_nan();
    }
    pub fn is_inf(self: f64) bool {
        return self.is_infinite();
    }
    pub fn to_bits(self: f64) u64 {
        return f64_bits(self);
    }
    pub fn from_bits(b: u64) f64 {
        return f64_from_bits(b);
    }
    pub fn bits_int(self: f64) i64 {
        return f64_bits(self) as i64;
    }
    pub fn bits_uint(self: f64) u64 {
        return f64_bits(self);
    }
    pub fn from_bits_int(b: i64) f64 {
        return f64_from_bits(b as u64);
    }
    pub fn from_bits_uint(b: u64) f64 {
        return f64_from_bits(b);
    }
    pub fn ulp_distance(self: f64, other: f64) u64 {
        let a = f64_bits(self);
        let b = f64_bits(other);
        if (a ^ b) >> 63 != 0 {
            return u64::MAX;
        }
        return if a > b {
            a - b
        } else {
            b - a
        };
    }
    pub fn epsilon() f64 {
        return f64_from_bits(0x3CB0000000000000);
    }
    pub fn max_finite() f64 {
        return f64_from_bits(0x7FEFFFFFFFFFFFFF);
    }
    pub fn min_positive() f64 {
        return f64_from_bits(0x0010000000000000);
    }
    pub fn infinity() f64 {
        return f64_from_bits(0x7FF0000000000000);
    }
    pub fn nan() f64 {
        return f64_from_bits(0x7FF8000000000000);
    }
}

extend i8 as Elem {
    pub fn equal(self: i8, other: i8) bool {
        return self == other;
    }
    pub fn not_equal(self: i8, other: i8) bool {
        return self != other;
    }
}

extend i8 as Scalar {
    pub fn add(self: &i8, other: &i8) i8 {
        return ((*self) as i32 + (*other) as i32) as i8;
    }
    pub fn sub(self: &i8, other: &i8) i8 {
        return ((*self) as i32 - (*other) as i32) as i8;
    }
    pub fn mul(self: &i8, other: &i8) i8 {
        return ((*self) as i32 * (*other) as i32) as i8;
    }
    pub fn div(self: &i8, other: &i8) i8 {
        return ((*self) as i32 / (*other) as i32) as i8;
    }
    pub fn neg(self: &i8) i8 {
        return (-((*self) as i32)) as i8;
    }
    pub fn less(self: i8, other: i8) bool {
        return self < other;
    }
    pub fn less_equal(self: i8, other: i8) bool {
        return self <= other;
    }
    pub fn greater(self: i8, other: i8) bool {
        return self > other;
    }
    pub fn greater_equal(self: i8, other: i8) bool {
        return self >= other;
    }
    pub fn zero() i8 {
        return 0;
    }
    pub fn one() i8 {
        return 1;
    }
    pub fn from_f64(v: f64) i8 {
        return v as i8;
    }
    pub fn from_f32(v: f32) i8 {
        return v as i8;
    }
    pub fn from_i64(v: i64) i8 {
        return v as i8;
    }
    pub fn from_u64(v: u64) i8 {
        return v as i8;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) i8 {
        let mut r = si::Int::<64>::zero();
        v.to_int(&mut r);
        let x = r.to_i64();
        if x < i8::MIN as i64 {
            return i8::MIN;
        }
        if x > i8::MAX as i64 {
            return i8::MAX;
        }
        return x as i8;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) i8 {
        return v.to_u64() as i8;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) i8 {
        return v.to_i64() as i8;
    }
    pub fn from_decimal(v: f64, digits: str) i8 {
        return v as i8;
    }
    pub fn cast<U: Scalar>(self: i8) U {
        return U::from_i64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("i8");
    }
    pub fn push_value(s: &mut String, v: i8) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend i8 as Int {
    pub fn rem(self: &i8, other: &i8) i8 {
        return ((*self) as i32 % (*other) as i32) as i8;
    }
    pub fn bit_and(self: &i8, other: &i8) i8 {
        return *self & *other;
    }
    pub fn bit_or(self: &i8, other: &i8) i8 {
        return *self | *other;
    }
    pub fn bit_xor(self: &i8, other: &i8) i8 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &i8) i8 {
        return ~*self;
    }
    pub fn shl(self: &i8, n: i8) i8 {
        return ((*self) as i32 << n as i32) as i8;
    }
    pub fn shr(self: &i8, n: i8) i8 {
        return ((*self) as i32 >> n as i32) as i8;
    }
    pub fn count_ones(self: i8) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: i8) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: i8) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 8;
    }
    pub fn min_value() i8 {
        return i8::MIN;
    }
    pub fn max_value() i8 {
        return i8::MAX;
    }
    pub fn to_i64(self: i8) i64 {
        return self;
    }
    pub fn to_u64(self: i8) u64 {
        return self as u64;
    }
}

extend i16 as Elem {
    pub fn equal(self: i16, other: i16) bool {
        return self == other;
    }
    pub fn not_equal(self: i16, other: i16) bool {
        return self != other;
    }
}

extend i16 as Scalar {
    pub fn add(self: &i16, other: &i16) i16 {
        return ((*self) as i32 + (*other) as i32) as i16;
    }
    pub fn sub(self: &i16, other: &i16) i16 {
        return ((*self) as i32 - (*other) as i32) as i16;
    }
    pub fn mul(self: &i16, other: &i16) i16 {
        return ((*self) as i32 * (*other) as i32) as i16;
    }
    pub fn div(self: &i16, other: &i16) i16 {
        return ((*self) as i32 / (*other) as i32) as i16;
    }
    pub fn neg(self: &i16) i16 {
        return (-((*self) as i32)) as i16;
    }
    pub fn less(self: i16, other: i16) bool {
        return self < other;
    }
    pub fn less_equal(self: i16, other: i16) bool {
        return self <= other;
    }
    pub fn greater(self: i16, other: i16) bool {
        return self > other;
    }
    pub fn greater_equal(self: i16, other: i16) bool {
        return self >= other;
    }
    pub fn zero() i16 {
        return 0;
    }
    pub fn one() i16 {
        return 1;
    }
    pub fn from_f64(v: f64) i16 {
        return v as i16;
    }
    pub fn from_f32(v: f32) i16 {
        return v as i16;
    }
    pub fn from_i64(v: i64) i16 {
        return v as i16;
    }
    pub fn from_u64(v: u64) i16 {
        return v as i16;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) i16 {
        let mut r = si::Int::<64>::zero();
        v.to_int(&mut r);
        let x = r.to_i64();
        if x < i16::MIN as i64 {
            return i16::MIN;
        }
        if x > i16::MAX as i64 {
            return i16::MAX;
        }
        return x as i16;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) i16 {
        return v.to_u64() as i16;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) i16 {
        return v.to_i64() as i16;
    }
    pub fn from_decimal(v: f64, digits: str) i16 {
        return v as i16;
    }
    pub fn cast<U: Scalar>(self: i16) U {
        return U::from_i64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("i16");
    }
    pub fn push_value(s: &mut String, v: i16) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend i16 as Int {
    pub fn rem(self: &i16, other: &i16) i16 {
        return ((*self) as i32 % (*other) as i32) as i16;
    }
    pub fn bit_and(self: &i16, other: &i16) i16 {
        return *self & *other;
    }
    pub fn bit_or(self: &i16, other: &i16) i16 {
        return *self | *other;
    }
    pub fn bit_xor(self: &i16, other: &i16) i16 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &i16) i16 {
        return ~*self;
    }
    pub fn shl(self: &i16, n: i16) i16 {
        return ((*self) as i32 << n as i32) as i16;
    }
    pub fn shr(self: &i16, n: i16) i16 {
        return ((*self) as i32 >> n as i32) as i16;
    }
    pub fn count_ones(self: i16) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: i16) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: i16) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 16;
    }
    pub fn min_value() i16 {
        return i16::MIN;
    }
    pub fn max_value() i16 {
        return i16::MAX;
    }
    pub fn to_i64(self: i16) i64 {
        return self;
    }
    pub fn to_u64(self: i16) u64 {
        return self as u64;
    }
}

extend i32 as Elem {
    pub fn equal(self: i32, other: i32) bool {
        return self == other;
    }
    pub fn not_equal(self: i32, other: i32) bool {
        return self != other;
    }
}

extend i32 as Scalar {
    pub fn add(self: &i32, other: &i32) i32 {
        return *self + *other;
    }
    pub fn sub(self: &i32, other: &i32) i32 {
        return *self - *other;
    }
    pub fn mul(self: &i32, other: &i32) i32 {
        return *self * *other;
    }
    pub fn div(self: &i32, other: &i32) i32 {
        return *self / *other;
    }
    pub fn neg(self: &i32) i32 {
        return -*self;
    }
    pub fn less(self: i32, other: i32) bool {
        return self < other;
    }
    pub fn less_equal(self: i32, other: i32) bool {
        return self <= other;
    }
    pub fn greater(self: i32, other: i32) bool {
        return self > other;
    }
    pub fn greater_equal(self: i32, other: i32) bool {
        return self >= other;
    }
    pub fn zero() i32 {
        return 0;
    }
    pub fn one() i32 {
        return 1;
    }
    pub fn from_f64(v: f64) i32 {
        return v as i32;
    }
    pub fn from_f32(v: f32) i32 {
        return v as i32;
    }
    pub fn from_i64(v: i64) i32 {
        return v as i32;
    }
    pub fn from_u64(v: u64) i32 {
        return v as i32;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) i32 {
        let mut r = si::Int::<64>::zero();
        v.to_int(&mut r);
        let x = r.to_i64();
        if x < i32::MIN as i64 {
            return i32::MIN;
        }
        if x > i32::MAX as i64 {
            return i32::MAX;
        }
        return x as i32;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) i32 {
        return v.to_u64() as i32;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) i32 {
        return v.to_i64() as i32;
    }
    pub fn from_decimal(v: f64, digits: str) i32 {
        return v as i32;
    }
    pub fn cast<U: Scalar>(self: i32) U {
        return U::from_i64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("i");
    }
    pub fn push_value(s: &mut String, v: i32) {
        s.push_i64(v);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend i32 as Int {
    pub fn rem(self: &i32, other: &i32) i32 {
        return *self % *other;
    }
    pub fn bit_and(self: &i32, other: &i32) i32 {
        return *self & *other;
    }
    pub fn bit_or(self: &i32, other: &i32) i32 {
        return *self | *other;
    }
    pub fn bit_xor(self: &i32, other: &i32) i32 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &i32) i32 {
        return ~*self;
    }
    pub fn shl(self: &i32, n: i32) i32 {
        return *self << n;
    }
    pub fn shr(self: &i32, n: i32) i32 {
        return *self >> n;
    }
    pub fn count_ones(self: i32) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: i32) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: i32) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 32;
    }
    pub fn min_value() i32 {
        return i32::MIN;
    }
    pub fn max_value() i32 {
        return i32::MAX;
    }
    pub fn to_i64(self: i32) i64 {
        return self;
    }
    pub fn to_u64(self: i32) u64 {
        return self as u64;
    }
}

extend i64 as Elem {
    pub fn equal(self: i64, other: i64) bool {
        return self == other;
    }
    pub fn not_equal(self: i64, other: i64) bool {
        return self != other;
    }
}

extend i64 as Scalar {
    pub fn add(self: &i64, other: &i64) i64 {
        return *self + *other;
    }
    pub fn sub(self: &i64, other: &i64) i64 {
        return *self - *other;
    }
    pub fn mul(self: &i64, other: &i64) i64 {
        return *self * *other;
    }
    pub fn div(self: &i64, other: &i64) i64 {
        return *self / *other;
    }
    pub fn neg(self: &i64) i64 {
        return -*self;
    }
    pub fn less(self: i64, other: i64) bool {
        return self < other;
    }
    pub fn less_equal(self: i64, other: i64) bool {
        return self <= other;
    }
    pub fn greater(self: i64, other: i64) bool {
        return self > other;
    }
    pub fn greater_equal(self: i64, other: i64) bool {
        return self >= other;
    }
    pub fn zero() i64 {
        return 0;
    }
    pub fn one() i64 {
        return 1;
    }
    pub fn from_f64(v: f64) i64 {
        return v as i64;
    }
    pub fn from_f32(v: f32) i64 {
        return v as i64;
    }
    pub fn from_i64(v: i64) i64 {
        return v;
    }
    pub fn from_u64(v: u64) i64 {
        return v as i64;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) i64 {
        let mut r = si::Int::<64>::zero();
        v.to_int(&mut r);
        let x = r.to_i64();
        return x;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) i64 {
        return v.to_u64() as i64;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) i64 {
        return v.to_i64();
    }
    pub fn from_decimal(v: f64, digits: str) i64 {
        return v as i64;
    }
    pub fn cast<U: Scalar>(self: i64) U {
        return U::from_i64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("i64");
    }
    pub fn push_value(s: &mut String, v: i64) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend i64 as Int {
    pub fn rem(self: &i64, other: &i64) i64 {
        return *self % *other;
    }
    pub fn bit_and(self: &i64, other: &i64) i64 {
        return *self & *other;
    }
    pub fn bit_or(self: &i64, other: &i64) i64 {
        return *self | *other;
    }
    pub fn bit_xor(self: &i64, other: &i64) i64 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &i64) i64 {
        return ~*self;
    }
    pub fn shl(self: &i64, n: i64) i64 {
        return *self << n;
    }
    pub fn shr(self: &i64, n: i64) i64 {
        return *self >> n;
    }
    pub fn count_ones(self: i64) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: i64) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: i64) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 64;
    }
    pub fn min_value() i64 {
        return i64::MIN;
    }
    pub fn max_value() i64 {
        return i64::MAX;
    }
    pub fn to_i64(self: i64) i64 {
        return self;
    }
    pub fn to_u64(self: i64) u64 {
        return self as u64;
    }
}

extend u8 as Elem {
    pub fn equal(self: u8, other: u8) bool {
        return self == other;
    }
    pub fn not_equal(self: u8, other: u8) bool {
        return self != other;
    }
}

extend u8 as Scalar {
    pub fn add(self: &u8, other: &u8) u8 {
        return ((*self) as u32).wrapping_add(*other) as u8;
    }
    pub fn sub(self: &u8, other: &u8) u8 {
        return ((*self) as u32).wrapping_sub(*other) as u8;
    }
    pub fn mul(self: &u8, other: &u8) u8 {
        return ((*self) as u32).wrapping_mul(*other) as u8;
    }
    pub fn div(self: &u8, other: &u8) u8 {
        return *self / *other;
    }
    pub fn neg(self: &u8) u8 {
        return 0u32.wrapping_sub(*self) as u8;
    }
    pub fn less(self: u8, other: u8) bool {
        return self < other;
    }
    pub fn less_equal(self: u8, other: u8) bool {
        return self <= other;
    }
    pub fn greater(self: u8, other: u8) bool {
        return self > other;
    }
    pub fn greater_equal(self: u8, other: u8) bool {
        return self >= other;
    }
    pub fn zero() u8 {
        return 0;
    }
    pub fn one() u8 {
        return 1;
    }
    pub fn from_f64(v: f64) u8 {
        return v as u8;
    }
    pub fn from_f32(v: f32) u8 {
        return v as u8;
    }
    pub fn from_i64(v: i64) u8 {
        return v as u8;
    }
    pub fn from_u64(v: u64) u8 {
        return v as u8;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) u8 {
        let mut r = si::UInt::<64>::zero();
        v.to_uint(&mut r);
        let x = r.to_u64();
        if x > u8::MAX as u64 {
            return u8::MAX;
        }
        return x as u8;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) u8 {
        return v.to_u64() as u8;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) u8 {
        return v.to_i64() as u8;
    }
    pub fn from_decimal(v: f64, digits: str) u8 {
        return v as u8;
    }
    pub fn cast<U: Scalar>(self: u8) U {
        return U::from_u64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("u8");
    }
    pub fn push_value(s: &mut String, v: u8) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return false;
    }
}

extend u8 as Int {
    pub fn rem(self: &u8, other: &u8) u8 {
        return *self % *other;
    }
    pub fn bit_and(self: &u8, other: &u8) u8 {
        return *self & *other;
    }
    pub fn bit_or(self: &u8, other: &u8) u8 {
        return *self | *other;
    }
    pub fn bit_xor(self: &u8, other: &u8) u8 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &u8) u8 {
        return ~*self;
    }
    pub fn shl(self: &u8, n: u8) u8 {
        return ((*self) as i32 << n as i32) as u8;
    }
    pub fn shr(self: &u8, n: u8) u8 {
        return ((*self) as i32 >> n as i32) as u8;
    }
    pub fn count_ones(self: u8) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: u8) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: u8) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 8;
    }
    pub fn min_value() u8 {
        return u8::MIN;
    }
    pub fn max_value() u8 {
        return u8::MAX;
    }
    pub fn to_i64(self: u8) i64 {
        return self;
    }
    pub fn to_u64(self: u8) u64 {
        return self;
    }
}

extend u16 as Elem {
    pub fn equal(self: u16, other: u16) bool {
        return self == other;
    }
    pub fn not_equal(self: u16, other: u16) bool {
        return self != other;
    }
}

extend u16 as Scalar {
    pub fn add(self: &u16, other: &u16) u16 {
        return ((*self) as u32).wrapping_add(*other) as u16;
    }
    pub fn sub(self: &u16, other: &u16) u16 {
        return ((*self) as u32).wrapping_sub(*other) as u16;
    }
    pub fn mul(self: &u16, other: &u16) u16 {
        return ((*self) as u32).wrapping_mul(*other) as u16;
    }
    pub fn div(self: &u16, other: &u16) u16 {
        return *self / *other;
    }
    pub fn neg(self: &u16) u16 {
        return 0u32.wrapping_sub(*self) as u16;
    }
    pub fn less(self: u16, other: u16) bool {
        return self < other;
    }
    pub fn less_equal(self: u16, other: u16) bool {
        return self <= other;
    }
    pub fn greater(self: u16, other: u16) bool {
        return self > other;
    }
    pub fn greater_equal(self: u16, other: u16) bool {
        return self >= other;
    }
    pub fn zero() u16 {
        return 0;
    }
    pub fn one() u16 {
        return 1;
    }
    pub fn from_f64(v: f64) u16 {
        return v as u16;
    }
    pub fn from_f32(v: f32) u16 {
        return v as u16;
    }
    pub fn from_i64(v: i64) u16 {
        return v as u16;
    }
    pub fn from_u64(v: u64) u16 {
        return v as u16;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) u16 {
        let mut r = si::UInt::<64>::zero();
        v.to_uint(&mut r);
        let x = r.to_u64();
        if x > u16::MAX as u64 {
            return u16::MAX;
        }
        return x as u16;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) u16 {
        return v.to_u64() as u16;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) u16 {
        return v.to_i64() as u16;
    }
    pub fn from_decimal(v: f64, digits: str) u16 {
        return v as u16;
    }
    pub fn cast<U: Scalar>(self: u16) U {
        return U::from_u64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("u16");
    }
    pub fn push_value(s: &mut String, v: u16) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return false;
    }
}

extend u16 as Int {
    pub fn rem(self: &u16, other: &u16) u16 {
        return *self % *other;
    }
    pub fn bit_and(self: &u16, other: &u16) u16 {
        return *self & *other;
    }
    pub fn bit_or(self: &u16, other: &u16) u16 {
        return *self | *other;
    }
    pub fn bit_xor(self: &u16, other: &u16) u16 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &u16) u16 {
        return ~*self;
    }
    pub fn shl(self: &u16, n: u16) u16 {
        return ((*self) as i32 << n as i32) as u16;
    }
    pub fn shr(self: &u16, n: u16) u16 {
        return ((*self) as i32 >> n as i32) as u16;
    }
    pub fn count_ones(self: u16) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: u16) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: u16) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 16;
    }
    pub fn min_value() u16 {
        return u16::MIN;
    }
    pub fn max_value() u16 {
        return u16::MAX;
    }
    pub fn to_i64(self: u16) i64 {
        return self;
    }
    pub fn to_u64(self: u16) u64 {
        return self;
    }
}

extend u32 as Elem {
    pub fn equal(self: u32, other: u32) bool {
        return self == other;
    }
    pub fn not_equal(self: u32, other: u32) bool {
        return self != other;
    }
}

extend u32 as Scalar {
    pub fn add(self: &u32, other: &u32) u32 {
        return self.wrapping_add(*other);
    }
    pub fn sub(self: &u32, other: &u32) u32 {
        return self.wrapping_sub(*other);
    }
    pub fn mul(self: &u32, other: &u32) u32 {
        return self.wrapping_mul(*other);
    }
    pub fn div(self: &u32, other: &u32) u32 {
        return *self / *other;
    }
    pub fn neg(self: &u32) u32 {
        return self.wrapping_neg();
    }
    pub fn less(self: u32, other: u32) bool {
        return self < other;
    }
    pub fn less_equal(self: u32, other: u32) bool {
        return self <= other;
    }
    pub fn greater(self: u32, other: u32) bool {
        return self > other;
    }
    pub fn greater_equal(self: u32, other: u32) bool {
        return self >= other;
    }
    pub fn zero() u32 {
        return 0;
    }
    pub fn one() u32 {
        return 1;
    }
    pub fn from_f64(v: f64) u32 {
        return v as u32;
    }
    pub fn from_f32(v: f32) u32 {
        return v as u32;
    }
    pub fn from_i64(v: i64) u32 {
        return v as u32;
    }
    pub fn from_u64(v: u64) u32 {
        return v as u32;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) u32 {
        let mut r = si::UInt::<64>::zero();
        v.to_uint(&mut r);
        let x = r.to_u64();
        if x > u32::MAX as u64 {
            return u32::MAX;
        }
        return x as u32;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) u32 {
        return v.to_u64() as u32;
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) u32 {
        return v.to_i64() as u32;
    }
    pub fn from_decimal(v: f64, digits: str) u32 {
        return v as u32;
    }
    pub fn cast<U: Scalar>(self: u32) U {
        return U::from_u64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("u");
    }
    pub fn push_value(s: &mut String, v: u32) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return false;
    }
}

extend u32 as Int {
    pub fn rem(self: &u32, other: &u32) u32 {
        return *self % *other;
    }
    pub fn bit_and(self: &u32, other: &u32) u32 {
        return *self & *other;
    }
    pub fn bit_or(self: &u32, other: &u32) u32 {
        return *self | *other;
    }
    pub fn bit_xor(self: &u32, other: &u32) u32 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &u32) u32 {
        return ~*self;
    }
    pub fn shl(self: &u32, n: u32) u32 {
        return *self << n;
    }
    pub fn shr(self: &u32, n: u32) u32 {
        return *self >> n;
    }
    pub fn count_ones(self: u32) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: u32) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: u32) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 32;
    }
    pub fn min_value() u32 {
        return u32::MIN;
    }
    pub fn max_value() u32 {
        return u32::MAX;
    }
    pub fn to_i64(self: u32) i64 {
        return self;
    }
    pub fn to_u64(self: u32) u64 {
        return self;
    }
}

extend u64 as Elem {
    pub fn equal(self: u64, other: u64) bool {
        return self == other;
    }
    pub fn not_equal(self: u64, other: u64) bool {
        return self != other;
    }
}

extend u64 as Scalar {
    pub fn add(self: &u64, other: &u64) u64 {
        return self.wrapping_add(*other);
    }
    pub fn sub(self: &u64, other: &u64) u64 {
        return self.wrapping_sub(*other);
    }
    pub fn mul(self: &u64, other: &u64) u64 {
        return self.wrapping_mul(*other);
    }
    pub fn div(self: &u64, other: &u64) u64 {
        return *self / *other;
    }
    pub fn neg(self: &u64) u64 {
        return self.wrapping_neg();
    }
    pub fn less(self: u64, other: u64) bool {
        return self < other;
    }
    pub fn less_equal(self: u64, other: u64) bool {
        return self <= other;
    }
    pub fn greater(self: u64, other: u64) bool {
        return self > other;
    }
    pub fn greater_equal(self: u64, other: u64) bool {
        return self >= other;
    }
    pub fn zero() u64 {
        return 0;
    }
    pub fn one() u64 {
        return 1;
    }
    pub fn from_f64(v: f64) u64 {
        return v as u64;
    }
    pub fn from_f32(v: f32) u64 {
        return v as u64;
    }
    pub fn from_i64(v: i64) u64 {
        return v as u64;
    }
    pub fn from_u64(v: u64) u64 {
        return v;
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) u64 {
        let mut r = si::UInt::<64>::zero();
        v.to_uint(&mut r);
        let x = r.to_u64();
        return x;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) u64 {
        return v.to_u64();
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) u64 {
        return v.to_i64() as u64;
    }
    pub fn from_decimal(v: f64, digits: str) u64 {
        return v as u64;
    }
    pub fn cast<U: Scalar>(self: u64) U {
        return U::from_u64(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("u64");
    }
    pub fn push_value(s: &mut String, v: u64) {
        s.push_i64(v as i32);
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return false;
    }
}

extend u64 as Int {
    pub fn rem(self: &u64, other: &u64) u64 {
        return *self % *other;
    }
    pub fn bit_and(self: &u64, other: &u64) u64 {
        return *self & *other;
    }
    pub fn bit_or(self: &u64, other: &u64) u64 {
        return *self | *other;
    }
    pub fn bit_xor(self: &u64, other: &u64) u64 {
        return *self ^ *other;
    }
    pub fn bit_not(self: &u64) u64 {
        return ~*self;
    }
    pub fn shl(self: &u64, n: u64) u64 {
        return *self << n;
    }
    pub fn shr(self: &u64, n: u64) u64 {
        return *self >> n;
    }
    pub fn count_ones(self: u64) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: u64) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: u64) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return 64;
    }
    pub fn min_value() u64 {
        return u64::MIN;
    }
    pub fn max_value() u64 {
        return u64::MAX;
    }
    pub fn to_i64(self: u64) i64 {
        return self as i64;
    }
    pub fn to_u64(self: u64) u64 {
        return self;
    }
}

// Each constant is its literal rounded to f64, then converted to `T` with `as` (an integer `T`
// truncates).

/// The difference between 1 and the next larger `T`.
pub fn epsilon<T: Float>() T {
    return T::epsilon();
}

/// pi.
pub fn pi<T: Float>() T {
    return T::from_decimal(
        3.14159265358979323846264338327950288,
        "3.1415926535897932384626433832795028841971693993751058209749445923078164062862090",
    );
}

/// cos(1 / 2).
pub fn cos_one_over_two<T: Scalar>() T {
    return T::from_decimal(
        0.877582561890372716130286068203503191,
        "0.87758256189037271611628158260382965199164519710974405299761086831595076327421395",
    );
}

/// 0.
pub fn zero<T: Scalar>() T {
    return T::zero();
}

/// 1.
pub fn one<T: Scalar>() T {
    return T::one();
}

/// pi * 2.
pub fn two_pi<T: Scalar>() T {
    return T::from_decimal(
        6.28318530717958647692528676655900576,
        "6.2831853071795864769252867665590057683943387987502116419498891846156328125724180",
    );
}

/// pi * 2, the unit circle's circumference.
pub fn tau<T: Scalar>() T {
    return two_pi::<T>();
}

/// The square root of pi.
pub fn root_pi<T: Scalar>() T {
    return T::from_decimal(
        1.772453850905516027,
        "1.7724538509055160272981674833411451827975494561223871282138077898529112845910322",
    );
}

/// pi / 2.
pub fn half_pi<T: Scalar>() T {
    return T::from_decimal(
        1.57079632679489661923132169163975144,
        "1.5707963267948966192313216916397514420985846996875529104874722961539082031431045",
    );
}

/// pi * 3 / 2.
pub fn three_over_two_pi<T: Scalar>() T {
    return T::from_decimal(
        4.71238898038468985769396507491925432,
        "4.7123889803846898576939650749192543262957540990626587314624168884617246094293135",
    );
}

/// pi / 4.
pub fn quarter_pi<T: Scalar>() T {
    return T::from_decimal(
        0.785398163397448309615660845819875721,
        "0.78539816339744830961566084581987572104929234984377645524373614807695410157155225",
    );
}

/// 1 / pi.
pub fn one_over_pi<T: Scalar>() T {
    return T::from_decimal(
        0.318309886183790671537767526745028724,
        "0.31830988618379067153776752674502872406891929148091289749533468811779359526845307",
    );
}

/// 1 / (pi * 2).
pub fn one_over_two_pi<T: Scalar>() T {
    return T::from_decimal(
        0.159154943091895335768883763372514362,
        "0.15915494309189533576888376337251436203445964574045644874766734405889679763422654",
    );
}

/// 2 / pi.
pub fn two_over_pi<T: Scalar>() T {
    return T::from_decimal(
        0.636619772367581343075535053490057448,
        "0.63661977236758134307553505349005744813783858296182579499066937623558719053690614",
    );
}

/// 4 / pi.
pub fn four_over_pi<T: Scalar>() T {
    return T::from_decimal(
        1.273239544735162686151070106980114898,
        "1.2732395447351626861510701069801148962756771659236515899813387524711743810738123",
    );
}

/// 2 / sqrt(pi).
pub fn two_over_root_pi<T: Scalar>() T {
    return T::from_decimal(
        1.12837916709551257389615890312154517,
        "1.1283791670955125738961589031215451716881012586579977136881714434212849368829868",
    );
}

/// 1 / sqrt(2).
pub fn one_over_root_two<T: Scalar>() T {
    return T::from_decimal(
        0.707106781186547524400844362104849039,
        "0.70710678118654752440084436210484903928483593768847403658833986899536623923105352",
    );
}

/// sqrt(pi / 2).
pub fn root_half_pi<T: Scalar>() T {
    return T::from_decimal(
        1.253314137315500251,
        "1.2533141373155002512078826424055226265034933703049691583149617881711468273039210",
    );
}

/// sqrt(pi * 2).
pub fn root_two_pi<T: Scalar>() T {
    return T::from_decimal(
        2.506628274631000502,
        "2.5066282746310005024157652848110452530069867406099383166299235763422936546078420",
    );
}

/// sqrt(ln(4)).
pub fn root_ln_four<T: Scalar>() T {
    return T::from_decimal(
        1.17741002251547469,
        "1.1774100225154746910115693264596996377473856893858205385225257565000265885469849",
    );
}

/// e.
pub fn e<T: Scalar>() T {
    return T::from_decimal(
        2.71828182845904523536,
        "2.7182818284590452353602874713526624977572470936999595749669676277240766303535476",
    );
}

/// Euler's constant.
pub fn euler<T: Scalar>() T {
    return T::from_decimal(
        0.577215664901532860606,
        "0.57721566490153286060651209008240243104215933593992359880576723488486772677766467",
    );
}

/// sqrt(2).
pub fn root_two<T: Scalar>() T {
    return T::from_decimal(
        1.41421356237309504880168872420969808,
        "1.4142135623730950488016887242096980785696718753769480731766797379907324784621070",
    );
}

/// sqrt(3).
pub fn root_three<T: Scalar>() T {
    return T::from_decimal(
        1.73205080756887729352744634150587236,
        "1.7320508075688772935274463415058723669428052538103806280558069794519330169088000",
    );
}

/// sqrt(5).
pub fn root_five<T: Scalar>() T {
    return T::from_decimal(
        2.23606797749978969640917366873127623,
        "2.2360679774997896964091736687312762354406183596115257242708972454105209256378049",
    );
}

/// ln(2).
pub fn ln_two<T: Scalar>() T {
    return T::from_decimal(
        0.693147180559945309417232121458176568,
        "0.69314718055994530941723212145817656807550013436025525412068000949339362196969472",
    );
}

/// ln(10).
pub fn ln_ten<T: Scalar>() T {
    return T::from_decimal(
        2.30258509299404568401799145468436421,
        "2.3025850929940456840179914546843642076011014886287729760333279009675726096773525",
    );
}

/// ln(ln(2)).
pub fn ln_ln_two<T: Scalar>() T {
    return T::from_decimal(
        -0.3665129205816643,
        "-0.36651292058166432701243915823266946945426344783710526305367771367056161531935274",
    );
}

/// 1 / 3.
pub fn third<T: Scalar>() T {
    return T::from_decimal(
        0.3333333333333333333333333333333333333333,
        "0.33333333333333333333333333333333333333333333333333333333333333333333333333333333",
    );
}

/// 2 / 3.
pub fn two_thirds<T: Scalar>() T {
    return T::from_decimal(
        0.666666666666666666666666666666666666667,
        "0.66666666666666666666666666666666666666666666666666666666666666666666666666666667",
    );
}

/// The golden ratio.
pub fn golden_ratio<T: Scalar>() T {
    return T::from_decimal(
        1.61803398874989484820458683436563811,
        "1.6180339887498948482045868343656381177203091798057628621354486227052604628189024",
    );
}

// ---- Int<N>, UInt<N> and Float<E, F> --------------------------------------------------------------------
// Their arithmetic is their own operators': checked overflow (a trap in a profile with overflow checks)
// for `Int<N>` and `UInt<N>`, one rounding to nearest for `Float<E, F>`.

extend<const B: usize> si::UInt<B> as Elem {
    pub fn equal(self: si::UInt<B>, other: si::UInt<B>) bool {
        return self == other;
    }
    pub fn not_equal(self: si::UInt<B>, other: si::UInt<B>) bool {
        return !(self == other);
    }
}

extend<const B: usize> si::UInt<B> as Scalar {
    pub fn add(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self + *other;
    }
    pub fn sub(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self - *other;
    }
    pub fn mul(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self * *other;
    }
    pub fn div(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self / *other;
    }
    /// `0 - self`: a trap for every value but 0 in a profile with overflow checks.
    pub fn neg(self: &si::UInt<B>) si::UInt<B> {
        return si::UInt::<B>::zero() - *self;
    }
    pub fn less(self: si::UInt<B>, other: si::UInt<B>) bool {
        return self < other;
    }
    pub fn less_equal(self: si::UInt<B>, other: si::UInt<B>) bool {
        return self <= other;
    }
    pub fn greater(self: si::UInt<B>, other: si::UInt<B>) bool {
        return self > other;
    }
    pub fn greater_equal(self: si::UInt<B>, other: si::UInt<B>) bool {
        return self >= other;
    }
    pub fn zero() si::UInt<B> {
        return si::UInt::<B>::zero();
    }
    pub fn one() si::UInt<B> {
        return si::UInt::<B>::one();
    }
    pub fn from_f64(v: f64) si::UInt<B> {
        return si::UInt::<B>::from_f64(v);
    }
    pub fn from_f32(v: f32) si::UInt<B> {
        return si::UInt::<B>::from_f64(v);
    }
    pub fn from_i64(v: i64) si::UInt<B> {
        let w = si::Int::<64>::from_i64(v);
        return si::UInt::<B>::cast_signed(&w);
    }
    pub fn from_u64(v: u64) si::UInt<B> {
        return si::UInt::<B>::from_u64(v);
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) si::UInt<B> {
        let mut r = si::UInt::<B>::zero();
        v.to_uint(&mut r);
        return r;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) si::UInt<B> {
        return si::UInt::<B>::cast_unsigned(&v);
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) si::UInt<B> {
        return si::UInt::<B>::cast_signed(&v);
    }
    pub fn from_decimal(v: f64, digits: str) si::UInt<B> {
        return si::UInt::<B>::from_f64(v);
    }
    pub fn cast<U: Scalar>(self: si::UInt<B>) U {
        return U::from_uint(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("u");
        s.push_u64(B as u64);
    }
    pub fn push_value(s: &mut String, v: si::UInt<B>) {
        s.push_str(v.to_string().as_str());
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return false;
    }
}

// A shift count of `Int`'s `shl` and `shr`: past the width it shifts every bit out, as the type's own
// shift does.
const fn wide_count<const B: usize>(n: si::UInt<B>) usize {
    if n >= si::UInt::<B>::from_u64(B as u64) {
        return B;
    }
    return n.to_u64() as usize;
}

extend<const B: usize> si::UInt<B> as Int {
    pub fn rem(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self % *other;
    }
    pub fn bit_and(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self & *other;
    }
    pub fn bit_or(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self | *other;
    }
    pub fn bit_xor(self: &si::UInt<B>, other: &si::UInt<B>) si::UInt<B> {
        return *self ^ *other;
    }
    pub fn bit_not(self: &si::UInt<B>) si::UInt<B> {
        return ~*self;
    }
    /// Past the width every bit shifts out, as the type's own `<<` does.
    pub fn shl(self: &si::UInt<B>, n: si::UInt<B>) si::UInt<B> {
        return *self << wide_count(n);
    }
    pub fn shr(self: &si::UInt<B>, n: si::UInt<B>) si::UInt<B> {
        return *self >> wide_count(n);
    }
    pub fn count_ones(self: si::UInt<B>) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: si::UInt<B>) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: si::UInt<B>) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return B as i32;
    }
    pub fn min_value() si::UInt<B> {
        return si::UInt::<B>::zero();
    }
    pub fn max_value() si::UInt<B> {
        return si::UInt::<B>::max();
    }
    /// The low 64 bits.
    pub fn to_i64(self: si::UInt<B>) i64 {
        return self.to_u64() as i64;
    }
    pub fn to_u64(self: si::UInt<B>) u64 {
        return self.to_u64();
    }
}

extend<const B: usize> si::Int<B> as Elem {
    pub fn equal(self: si::Int<B>, other: si::Int<B>) bool {
        return self == other;
    }
    pub fn not_equal(self: si::Int<B>, other: si::Int<B>) bool {
        return !(self == other);
    }
}

extend<const B: usize> si::Int<B> as Scalar {
    pub fn add(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self + *other;
    }
    pub fn sub(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self - *other;
    }
    pub fn mul(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self * *other;
    }
    pub fn div(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self / *other;
    }
    /// `0 - self`: a trap for `MIN` in a profile with overflow checks.
    pub fn neg(self: &si::Int<B>) si::Int<B> {
        return si::Int::<B>::zero() - *self;
    }
    pub fn less(self: si::Int<B>, other: si::Int<B>) bool {
        return self < other;
    }
    pub fn less_equal(self: si::Int<B>, other: si::Int<B>) bool {
        return self <= other;
    }
    pub fn greater(self: si::Int<B>, other: si::Int<B>) bool {
        return self > other;
    }
    pub fn greater_equal(self: si::Int<B>, other: si::Int<B>) bool {
        return self >= other;
    }
    pub fn zero() si::Int<B> {
        return si::Int::<B>::zero();
    }
    pub fn one() si::Int<B> {
        return si::Int::<B>::one();
    }
    pub fn from_f64(v: f64) si::Int<B> {
        return si::Int::<B>::from_f64(v);
    }
    pub fn from_f32(v: f32) si::Int<B> {
        return si::Int::<B>::from_f64(v);
    }
    pub fn from_i64(v: i64) si::Int<B> {
        return si::Int::<B>::from_i64(v);
    }
    pub fn from_u64(v: u64) si::Int<B> {
        let w = si::UInt::<64>::from_u64(v);
        return si::Int::<B>::cast_unsigned(&w);
    }
    pub fn from_float<const E: usize, const F: usize, const FAM: sf::FloatFamily>(v: sf::Float<E, F, FAM>) si::Int<B> {
        let mut r = si::Int::<B>::zero();
        v.to_int(&mut r);
        return r;
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) si::Int<B> {
        return si::Int::<B>::cast_unsigned(&v);
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) si::Int<B> {
        return si::Int::<B>::cast_signed(&v);
    }
    pub fn from_decimal(v: f64, digits: str) si::Int<B> {
        return si::Int::<B>::from_f64(v);
    }
    pub fn cast<U: Scalar>(self: si::Int<B>) U {
        return U::from_int(self);
    }
    pub fn push_name(s: &mut String) {
        s.push_str("i");
        s.push_u64(B as u64);
    }
    pub fn push_value(s: &mut String, v: si::Int<B>) {
        s.push_str(v.to_string().as_str());
    }
    pub fn is_float() bool {
        return false;
    }
    pub fn is_signed() bool {
        return true;
    }
}

extend<const B: usize> si::Int<B> as Int {
    pub fn rem(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self % *other;
    }
    pub fn bit_and(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self & *other;
    }
    pub fn bit_or(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self | *other;
    }
    pub fn bit_xor(self: &si::Int<B>, other: &si::Int<B>) si::Int<B> {
        return *self ^ *other;
    }
    pub fn bit_not(self: &si::Int<B>) si::Int<B> {
        return ~*self;
    }
    /// Past the width every bit shifts out, as the type's own `<<` does; a negative count traps.
    pub fn shl(self: &si::Int<B>, n: si::Int<B>) si::Int<B> {
        if n.is_negative() {
            panic("attempt to shift left with overflow");
        }
        return *self << wide_count(n.to_unsigned());
    }
    /// Arithmetic; past the width the sign fills every bit, as the type's own `>>` does.
    pub fn shr(self: &si::Int<B>, n: si::Int<B>) si::Int<B> {
        if n.is_negative() {
            panic("attempt to shift right with overflow");
        }
        return *self >> wide_count(n.to_unsigned());
    }
    pub fn count_ones(self: si::Int<B>) i32 {
        return self.count_ones() as i32;
    }
    pub fn leading_zeros(self: si::Int<B>) i32 {
        return self.leading_zeros() as i32;
    }
    pub fn trailing_zeros(self: si::Int<B>) i32 {
        return self.trailing_zeros() as i32;
    }
    pub fn bits() i32 {
        return B as i32;
    }
    pub fn min_value() si::Int<B> {
        return si::Int::<B>::min();
    }
    pub fn max_value() si::Int<B> {
        return si::Int::<B>::max();
    }
    /// The low 64 bits, sign-extended below 64.
    pub fn to_i64(self: si::Int<B>) i64 {
        return self.to_i64();
    }
    pub fn to_u64(self: si::Int<B>) u64 {
        return self.to_i64() as u64;
    }
}

// `==` and `<` of a `Float<E, F>` element are IEEE's (NaN unordered, -0 == +0), as for f32 and f64; the
// type's own `==` is its total order over the encodings.
extend<const E: usize, const F: usize, const FAM: sf::FloatFamily> sf::Float<E, F, FAM> as Elem {
    pub fn equal(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return self.ieee_eq(&other);
    }
    pub fn not_equal(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return !self.ieee_eq(&other);
    }
}

extend<const E: usize, const F: usize, const FAM: sf::FloatFamily> sf::Float<E, F, FAM> as Scalar {
    pub fn add(self: &sf::Float<E, F, FAM>, other: &sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return *self + *other;
    }
    pub fn sub(self: &sf::Float<E, F, FAM>, other: &sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return *self - *other;
    }
    pub fn mul(self: &sf::Float<E, F, FAM>, other: &sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return *self * *other;
    }
    pub fn div(self: &sf::Float<E, F, FAM>, other: &sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return *self / *other;
    }
    pub fn neg(self: &sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.neg();
    }
    pub fn less(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return self.ieee_lt(&other);
    }
    pub fn less_equal(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return self.ieee_le(&other);
    }
    pub fn greater(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return other.ieee_lt(&self);
    }
    pub fn greater_equal(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) bool {
        return other.ieee_le(&self);
    }
    pub fn zero() sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::zero();
    }
    pub fn one() sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::one();
    }
    pub fn from_f64(v: f64) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_f64(v);
    }
    pub fn from_f32(v: f32) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_f32(v);
    }
    pub fn from_i64(v: i64) sf::Float<E, F, FAM> {
        let w = si::Int::<64>::from_i64(v);
        return sf::Float::<E, F, FAM>::from_int(&w);
    }
    pub fn from_u64(v: u64) sf::Float<E, F, FAM> {
        let w = si::UInt::<64>::from_u64(v);
        return sf::Float::<E, F, FAM>::from_uint(&w);
    }
    pub fn from_float<const E2: usize, const F2: usize, const FAM2: sf::FloatFamily>(v: sf::Float<E2, F2, FAM2>) sf::Float<
        E,
        F,
        FAM
    > {
        return sf::Float::<E, F, FAM>::convert(&v);
    }
    pub fn from_uint<const M: usize>(v: si::UInt<M>) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_uint(&v);
    }
    pub fn from_int<const M: usize>(v: si::Int<M>) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_int(&v);
    }
    pub fn from_decimal(v: f64, digits: str) sf::Float<E, F, FAM> {
        if wd::exact_in_f64::<E, F, FAM>() {
            return sf::Float::<E, F, FAM>::from_f64(v);
        }
        return sf::Float::<E, F, FAM>::from_str(digits).unwrap();
    }
    pub fn cast<U: Scalar>(self: sf::Float<E, F, FAM>) U {
        return U::from_float(self);
    }
    pub fn push_name(s: &mut String) {
        let fin = FAM == sf::FloatFamily::FF_FINITE_ONLY;
        if !fin && E == 5 && F == 10 {
            s.push_str("f16");
        } else if !fin && E == 8 && F == 7 {
            s.push_str("bf16");
        } else if !fin && E == 15 && F == 112 {
            s.push_str("f128");
        } else if !fin && E == 19 && F == 236 {
            s.push_str("f256");
        } else {
            s.push_str("f");
            s.push_u64((1 + E + F) as u64);
            s.push_str("e");
            s.push_u64(E as u64);
            s.push_str("m");
            s.push_u64(F as u64);
            if fin {
                s.push_str("fn");
            }
        }
    }
    pub fn push_value(s: &mut String, v: sf::Float<E, F, FAM>) {
        if wd::exact_in_f64::<E, F, FAM>() {
            s.push_f64_prec(v.to_f64(), 6);
        } else {
            s.push_str(v.to_string().as_str());
        }
    }
    pub fn is_float() bool {
        return true;
    }
    pub fn is_signed() bool {
        return true;
    }
}

// The functions are std::math::wide's: through f64 for a format exact there, in extended precision for a
// wider one.
extend<const E: usize, const F: usize, const FAM: sf::FloatFamily> sf::Float<E, F, FAM> as Float {
    type Int = si::Int<{1 + E + F}>;
    type UInt = si::UInt<{1 + E + F}>;
    pub fn abs(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.abs();
    }
    pub fn floor(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.floor();
    }
    pub fn ceil(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.ceil();
    }
    pub fn trunc(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.trunc();
    }
    pub fn round(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.round();
    }
    pub fn sqrt(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.sqrt();
    }
    pub fn exp(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_exp(self);
    }
    pub fn exp2(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_exp2(self);
    }
    pub fn ln(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_ln(self);
    }
    pub fn log2(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_log2(self);
    }
    pub fn pow(self: sf::Float<E, F, FAM>, e: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_pow(self, e);
    }
    pub fn sin(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_sin(self);
    }
    pub fn cos(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_cos(self);
    }
    pub fn tan(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_tan(self);
    }
    pub fn asin(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_asin(self);
    }
    pub fn acos(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_acos(self);
    }
    pub fn atan(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_atan(self);
    }
    pub fn atan2(self: sf::Float<E, F, FAM>, x: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_atan2(self, x);
    }
    pub fn sinh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_sinh(self);
    }
    pub fn cosh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_cosh(self);
    }
    pub fn tanh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_tanh(self);
    }
    pub fn asinh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_asinh(self);
    }
    pub fn acosh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_acosh(self);
    }
    pub fn atanh(self: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return wd::wide_atanh(self);
    }
    pub fn fma(self: sf::Float<E, F, FAM>, a: sf::Float<E, F, FAM>, b: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.fma(&a, &b);
    }
    pub fn fmod(self: sf::Float<E, F, FAM>, y: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self % y;
    }
    pub fn fmin(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.min(&other);
    }
    pub fn fmax(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        return self.max(&other);
    }
    pub fn modf(self: sf::Float<E, F, FAM>) (sf::Float<E, F, FAM>, sf::Float<E, F, FAM>) {
        if self.is_infinite() {
            return (sf::Float::<E, F, FAM>::zero().copysign(&self), self);
        }
        return (self.fract().copysign(&self), self.trunc());
    }
    pub fn frexp(self: sf::Float<E, F, FAM>) (sf::Float<E, F, FAM>, i32) {
        if self.is_nan() || self.is_infinite() || self.is_zero() {
            return (self, 0);
        }
        // The exponent of the leading bit, plus one.
        let (_, eb, fr) = self.to_parts();
        let bias = (1i64 << (E - 1) as i64) - 1;
        let e = if eb == 0 {
            1 - bias - F as i64 + fr.bit_length() as i64
        } else {
            eb as i64 - bias + 1
        };
        return (self.scalbn(-e), e as i32);
    }
    pub fn ldexp(self: sf::Float<E, F, FAM>, e: i32) sf::Float<E, F, FAM> {
        return self.scalbn(e);
    }
    pub fn next_after(self: sf::Float<E, F, FAM>, toward: sf::Float<E, F, FAM>) sf::Float<E, F, FAM> {
        if self.is_nan() || toward.is_nan() {
            return sf::Float::<E, F, FAM>::nan();
        }
        if self.ieee_eq(&toward) {
            return toward;
        }
        if self.ieee_lt(&toward) {
            return self.next_up();
        }
        return self.next_down();
    }
    pub fn is_nan(self: sf::Float<E, F, FAM>) bool {
        return self.is_nan();
    }
    pub fn is_inf(self: sf::Float<E, F, FAM>) bool {
        return self.is_infinite();
    }
    /// The low 64 bits of the encoding.
    pub fn to_bits(self: sf::Float<E, F, FAM>) u64 {
        return self.to_raw().to_u64();
    }
    /// The value of an encoding whose bits past 64 are zero.
    pub fn from_bits(b: u64) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_raw(si::UInt::<{1 + E + F}>::from_u64(b));
    }
    pub fn bits_int(self: sf::Float<E, F, FAM>) si::Int<{1 + E + F}> {
        let r = self.to_raw();
        return si::Int::<{1 + E + F}>::cast_unsigned(&r);
    }
    pub fn bits_uint(self: sf::Float<E, F, FAM>) si::UInt<{1 + E + F}> {
        return self.to_raw();
    }
    pub fn from_bits_int(b: si::Int<{1 + E + F}>) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_raw(si::UInt::<{1 + E + F}>::cast_signed(&b));
    }
    pub fn from_bits_uint(b: si::UInt<{1 + E + F}>) sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::from_raw(b);
    }
    pub fn ulp_distance(self: sf::Float<E, F, FAM>, other: sf::Float<E, F, FAM>) u64 {
        if self.is_negative() != other.is_negative() {
            return u64::MAX;
        }
        let a = self.to_raw();
        let b = other.to_raw();
        let d = if a > b {
            a - b
        } else {
            b - a
        };
        if d.bit_length() > 64 {
            return u64::MAX;
        }
        return d.to_u64();
    }
    pub fn epsilon() sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::one().ulp();
    }
    pub fn max_finite() sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::max_finite(false);
    }
    /// The smallest positive normal value, 2^(1 - bias).
    pub fn min_positive() sf::Float<E, F, FAM> {
        let bias = (1i64 << (E - 1) as i64) - 1;
        return sf::Float::<E, F, FAM>::one().scalbn(1 - bias);
    }
    /// Infinity; the largest finite value for a format without one (`FINITE_ONLY`), where overflow
    /// saturates there.
    pub fn infinity() sf::Float<E, F, FAM> {
        if FAM == sf::FloatFamily::FF_FINITE_ONLY {
            return sf::Float::<E, F, FAM>::max_finite(false);
        }
        return sf::Float::<E, F, FAM>::infinity(false);
    }
    pub fn nan() sf::Float<E, F, FAM> {
        return sf::Float::<E, F, FAM>::nan();
    }
}
