// The element types of std::math. `Elem` is every vector element (`bool` and the numbers), `Scalar` the
// numbers, `Float` f32 and f64, `Int` the integers. `+ - * / %`, negation and shifts of `u8`..`u64`,
// `i8` and `i16` wrap; on `i32` and `i64` they keep Super-C's checked overflow: a trap in a profile with
// overflow checks. Float comparisons are IEEE (NaN is unordered), not the total order of `Ord`.

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

/// A number: `i8`..`i64`, `u8`..`u64`, `f32` or `f64`. The operators of a generic `T: Scalar` dispatch
/// to these methods.
pub interface Scalar: Elem + SimdElement {
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
    /// `self` converted to `U` with `as`, once from the exact value.
    fn cast<U: Scalar>(self: Self) U;
    fn is_float() bool;
    fn is_signed() bool;
}

/// `f32` or `f64`. The functions are the C library's (`sqrt`, `sin`, ..).
pub interface Float: Scalar {
    /// The signed integer of the same width (`i32`, `i64`).
    type Int;
    /// The unsigned integer of the same width (`u32`, `u64`).
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
    /// The bit pattern, zero-extended (the low 32 bits for `f32`).
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

/// `i8`..`i64` or `u8`..`u64`. Shift counts have the shifted type.
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
    pub fn cast<U: Scalar>(self: f32) U {
        return U::from_f32(self);
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
        return f, i;
    }
    pub fn frexp(self: f32) (f32, i32) {
        let mut e: i32 = 0;
        let m = unsafe frexpf(self, &mut e);
        return m, e;
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
    pub fn cast<U: Scalar>(self: f64) U {
        return U::from_f64(self);
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
        return f, i;
    }
    pub fn frexp(self: f64) (f64, i32) {
        let mut e: i32 = 0;
        let m = unsafe frexp(self, &mut e);
        return m, e;
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
    pub fn cast<U: Scalar>(self: i8) U {
        return U::from_i64(self);
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
    pub fn cast<U: Scalar>(self: i16) U {
        return U::from_i64(self);
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
    pub fn cast<U: Scalar>(self: i32) U {
        return U::from_i64(self);
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
    pub fn cast<U: Scalar>(self: i64) U {
        return U::from_i64(self);
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
    pub fn cast<U: Scalar>(self: u8) U {
        return U::from_u64(self);
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
    pub fn cast<U: Scalar>(self: u16) U {
        return U::from_u64(self);
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
    pub fn cast<U: Scalar>(self: u32) U {
        return U::from_u64(self);
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
    pub fn cast<U: Scalar>(self: u64) U {
        return U::from_u64(self);
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
    return T::from_f64(3.14159265358979323846264338327950288);
}

/// cos(1 / 2).
pub fn cos_one_over_two<T: Scalar>() T {
    return T::from_f64(0.877582561890372716130286068203503191);
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
    return T::from_f64(6.28318530717958647692528676655900576);
}

/// pi * 2, the unit circle's circumference.
pub fn tau<T: Scalar>() T {
    return two_pi::<T>();
}

/// The square root of pi.
pub fn root_pi<T: Scalar>() T {
    return T::from_f64(1.772453850905516027);
}

/// pi / 2.
pub fn half_pi<T: Scalar>() T {
    return T::from_f64(1.57079632679489661923132169163975144);
}

/// pi * 3 / 2.
pub fn three_over_two_pi<T: Scalar>() T {
    return T::from_f64(4.71238898038468985769396507491925432);
}

/// pi / 4.
pub fn quarter_pi<T: Scalar>() T {
    return T::from_f64(0.785398163397448309615660845819875721);
}

/// 1 / pi.
pub fn one_over_pi<T: Scalar>() T {
    return T::from_f64(0.318309886183790671537767526745028724);
}

/// 1 / (pi * 2).
pub fn one_over_two_pi<T: Scalar>() T {
    return T::from_f64(0.159154943091895335768883763372514362);
}

/// 2 / pi.
pub fn two_over_pi<T: Scalar>() T {
    return T::from_f64(0.636619772367581343075535053490057448);
}

/// 4 / pi.
pub fn four_over_pi<T: Scalar>() T {
    return T::from_f64(1.273239544735162686151070106980114898);
}

/// 2 / sqrt(pi).
pub fn two_over_root_pi<T: Scalar>() T {
    return T::from_f64(1.12837916709551257389615890312154517);
}

/// 1 / sqrt(2).
pub fn one_over_root_two<T: Scalar>() T {
    return T::from_f64(0.707106781186547524400844362104849039);
}

/// sqrt(pi / 2).
pub fn root_half_pi<T: Scalar>() T {
    return T::from_f64(1.253314137315500251);
}

/// sqrt(pi * 2).
pub fn root_two_pi<T: Scalar>() T {
    return T::from_f64(2.506628274631000502);
}

/// sqrt(ln(4)).
pub fn root_ln_four<T: Scalar>() T {
    return T::from_f64(1.17741002251547469);
}

/// e.
pub fn e<T: Scalar>() T {
    return T::from_f64(2.71828182845904523536);
}

/// Euler's constant.
pub fn euler<T: Scalar>() T {
    return T::from_f64(0.577215664901532860606);
}

/// sqrt(2).
pub fn root_two<T: Scalar>() T {
    return T::from_f64(1.41421356237309504880168872420969808);
}

/// sqrt(3).
pub fn root_three<T: Scalar>() T {
    return T::from_f64(1.73205080756887729352744634150587236);
}

/// sqrt(5).
pub fn root_five<T: Scalar>() T {
    return T::from_f64(2.23606797749978969640917366873127623);
}

/// ln(2).
pub fn ln_two<T: Scalar>() T {
    return T::from_f64(0.693147180559945309417232121458176568);
}

/// ln(10).
pub fn ln_ten<T: Scalar>() T {
    return T::from_f64(2.30258509299404568401799145468436421);
}

/// ln(ln(2)).
pub fn ln_ln_two<T: Scalar>() T {
    return T::from_f64(-0.3665129205816643);
}

/// 1 / 3.
pub fn third<T: Scalar>() T {
    return T::from_f64(0.3333333333333333333333333333333333333333);
}

/// 2 / 3.
pub fn two_thirds<T: Scalar>() T {
    return T::from_f64(0.666666666666666666666666666666666666667);
}

/// The golden ratio.
pub fn golden_ratio<T: Scalar>() T {
    return T::from_f64(1.61803398874989484820458683436563811);
}
