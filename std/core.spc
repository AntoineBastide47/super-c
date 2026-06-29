// The `core` prelude module: standard-interface conformances for the builtin scalar types, so they
// behave as ordinary nominal types behind `T: Hash`/`Eq`/`Ord`/`Clone`/`Default`/`Free`/`Copy` bounds
// (e.g. `Map<i32, V>`) and so user code may `extend i32 { .. }` with its own methods. The compiler seeds a
// synthetic decl per builtin in this module; these `extend` blocks attach to them and lower to
// `i32__eq`, etc. `free` is empty (a scalar owns nothing) -- the C compiler optimizes the call away.
//
// `void` and `va_list` are omitted: they are not ordinary scalar values. Floats and complex numbers do not
// implement `Eq`/`Ord`/`Hash`: NaN breaks reflexive equality and total ordering, and complex numbers admit
// no total order.

extern "C" {
    fn sqrt(x: f64) f64;
    fn cbrt(x: f64) f64;
    fn pow(base: f64, exponent: f64) f64;
    fn exp(x: f64) f64;
    fn exp2(x: f64) f64;
    fn expm1(x: f64) f64;
    fn log(x: f64) f64;
    fn log2(x: f64) f64;
    fn log10(x: f64) f64;
    fn log1p(x: f64) f64;
    fn hypot(x: f64, y: f64) f64;
    fn sin(x: f64) f64;
    fn cos(x: f64) f64;
    fn tan(x: f64) f64;
    fn asin(x: f64) f64;
    fn acos(x: f64) f64;
    fn atan(x: f64) f64;
    fn atan2(y: f64, x: f64) f64;
    fn sinh(x: f64) f64;
    fn cosh(x: f64) f64;
    fn tanh(x: f64) f64;
    fn asinh(x: f64) f64;
    fn acosh(x: f64) f64;
    fn atanh(x: f64) f64;
    fn floor(x: f64) f64;
    fn ceil(x: f64) f64;
    fn round(x: f64) f64;
    fn trunc(x: f64) f64;
    fn fabs(x: f64) f64;
    fn fmod(x: f64, y: f64) f64;
    fn copysign(x: f64, y: f64) f64;
    fn fmin(x: f64, y: f64) f64;
    fn fmax(x: f64, y: f64) f64;
    fn fma(x: f64, y: f64, z: f64) f64;

    fn sqrtf(x: f32) f32;
    fn cbrtf(x: f32) f32;
    fn powf(base: f32, exponent: f32) f32;
    fn expf(x: f32) f32;
    fn exp2f(x: f32) f32;
    fn expm1f(x: f32) f32;
    fn logf(x: f32) f32;
    fn log2f(x: f32) f32;
    fn log10f(x: f32) f32;
    fn log1pf(x: f32) f32;
    fn hypotf(x: f32, y: f32) f32;
    fn sinf(x: f32) f32;
    fn cosf(x: f32) f32;
    fn tanf(x: f32) f32;
    fn asinf(x: f32) f32;
    fn acosf(x: f32) f32;
    fn atanf(x: f32) f32;
    fn atan2f(y: f32, x: f32) f32;
    fn sinhf(x: f32) f32;
    fn coshf(x: f32) f32;
    fn tanhf(x: f32) f32;
    fn asinhf(x: f32) f32;
    fn acoshf(x: f32) f32;
    fn atanhf(x: f32) f32;
    fn floorf(x: f32) f32;
    fn ceilf(x: f32) f32;
    fn roundf(x: f32) f32;
    fn truncf(x: f32) f32;
    fn fabsf(x: f32) f32;
    fn fmodf(x: f32, y: f32) f32;
    fn copysignf(x: f32, y: f32) f32;
    fn fminf(x: f32, y: f32) f32;
    fn fmaxf(x: f32, y: f32) f32;
    fn fmaf(x: f32, y: f32, z: f32) f32;
}

extend i8 as Eq {
    pub fn eq(self: &i8, other: &i8) bool { return (*self) == (*other); }
}
extend i8 as Ord {
    pub fn cmp(self: &i8, other: &i8) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend i8 as Hash {
    pub fn hash(self: &i8) u64 { return (*self) as u64; }
}
extend i8 as Clone {
    pub fn clone(self: &i8) i8 { return *self; }
}
extend i8 as Default {
    pub fn default() i8 { return 0; }
}
extend i8 as Free {
    pub fn free(self: &mut i8) {}
}
extend i8 as Copy {}

extend i16 as Eq {
    pub fn eq(self: &i16, other: &i16) bool { return (*self) == (*other); }
}
extend i16 as Ord {
    pub fn cmp(self: &i16, other: &i16) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend i16 as Hash {
    pub fn hash(self: &i16) u64 { return (*self) as u64; }
}
extend i16 as Clone {
    pub fn clone(self: &i16) i16 { return *self; }
}
extend i16 as Default {
    pub fn default() i16 { return 0; }
}
extend i16 as Free {
    pub fn free(self: &mut i16) {}
}
extend i16 as Copy {}

extend i32 as Eq {
    pub fn eq(self: &i32, other: &i32) bool { return (*self) == (*other); }
}
extend i32 as Ord {
    pub fn cmp(self: &i32, other: &i32) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend i32 as Hash {
    pub fn hash(self: &i32) u64 { return (*self) as u64; }
}
extend i32 as Clone {
    pub fn clone(self: &i32) i32 { return *self; }
}
extend i32 as Default {
    pub fn default() i32 { return 0; }
}
extend i32 as Free {
    pub fn free(self: &mut i32) {}
}
extend i32 as Copy {}

extend i64 as Eq {
    pub fn eq(self: &i64, other: &i64) bool { return (*self) == (*other); }
}
extend i64 as Ord {
    pub fn cmp(self: &i64, other: &i64) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend i64 as Hash {
    pub fn hash(self: &i64) u64 { return (*self) as u64; }
}
extend i64 as Clone {
    pub fn clone(self: &i64) i64 { return *self; }
}
extend i64 as Default {
    pub fn default() i64 { return 0; }
}
extend i64 as Free {
    pub fn free(self: &mut i64) {}
}
extend i64 as Copy {}

extend isize as Eq {
    pub fn eq(self: &isize, other: &isize) bool { return (*self) == (*other); }
}
extend isize as Ord {
    pub fn cmp(self: &isize, other: &isize) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend isize as Hash {
    pub fn hash(self: &isize) u64 { return (*self) as u64; }
}
extend isize as Clone {
    pub fn clone(self: &isize) isize { return *self; }
}
extend isize as Default {
    pub fn default() isize { return 0; }
}
extend isize as Free {
    pub fn free(self: &mut isize) {}
}
extend isize as Copy {}

extend u8 as Eq {
    pub fn eq(self: &u8, other: &u8) bool { return (*self) == (*other); }
}
extend u8 as Ord {
    pub fn cmp(self: &u8, other: &u8) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend u8 as Hash {
    pub fn hash(self: &u8) u64 { return (*self) as u64; }
}
extend u8 as Clone {
    pub fn clone(self: &u8) u8 { return *self; }
}
extend u8 as Default {
    pub fn default() u8 { return 0; }
}
extend u8 as Free {
    pub fn free(self: &mut u8) {}
}
extend u8 as Copy {}

extend u16 as Eq {
    pub fn eq(self: &u16, other: &u16) bool { return (*self) == (*other); }
}
extend u16 as Ord {
    pub fn cmp(self: &u16, other: &u16) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend u16 as Hash {
    pub fn hash(self: &u16) u64 { return (*self) as u64; }
}
extend u16 as Clone {
    pub fn clone(self: &u16) u16 { return *self; }
}
extend u16 as Default {
    pub fn default() u16 { return 0; }
}
extend u16 as Free {
    pub fn free(self: &mut u16) {}
}
extend u16 as Copy {}

extend u32 as Eq {
    pub fn eq(self: &u32, other: &u32) bool { return (*self) == (*other); }
}
extend u32 as Ord {
    pub fn cmp(self: &u32, other: &u32) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend u32 as Hash {
    pub fn hash(self: &u32) u64 { return (*self) as u64; }
}
extend u32 as Clone {
    pub fn clone(self: &u32) u32 { return *self; }
}
extend u32 as Default {
    pub fn default() u32 { return 0; }
}
extend u32 as Free {
    pub fn free(self: &mut u32) {}
}
extend u32 as Copy {}

extend u64 as Eq {
    pub fn eq(self: &u64, other: &u64) bool { return (*self) == (*other); }
}
extend u64 as Ord {
    pub fn cmp(self: &u64, other: &u64) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend u64 as Hash {
    pub fn hash(self: &u64) u64 { return (*self) as u64; }
}
extend u64 as Clone {
    pub fn clone(self: &u64) u64 { return *self; }
}
extend u64 as Default {
    pub fn default() u64 { return 0; }
}
extend u64 as Free {
    pub fn free(self: &mut u64) {}
}
extend u64 as Copy {}

extend usize as Eq {
    pub fn eq(self: &usize, other: &usize) bool { return (*self) == (*other); }
}
extend usize as Ord {
    pub fn cmp(self: &usize, other: &usize) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend usize as Hash {
    pub fn hash(self: &usize) u64 { return (*self) as u64; }
}
extend usize as Clone {
    pub fn clone(self: &usize) usize { return *self; }
}
extend usize as Default {
    pub fn default() usize { return 0; }
}
extend usize as Free {
    pub fn free(self: &mut usize) {}
}
extend usize as Copy {}

extend char as Eq {
    pub fn eq(self: &char, other: &char) bool { return (*self) == (*other); }
}
extend char as Ord {
    pub fn cmp(self: &char, other: &char) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend char as Hash {
    pub fn hash(self: &char) u64 { return (*self) as u64; }
}
extend char as Clone {
    pub fn clone(self: &char) char { return *self; }
}
extend char as Default {
    pub fn default() char { return 0 as char; }
}
extend char as Free {
    pub fn free(self: &mut char) {}
}
extend char as Copy {}

extend bool as Eq {
    pub fn eq(self: &bool, other: &bool) bool { return (*self) == (*other); }
}
extend bool as Ord {
    pub fn cmp(self: &bool, other: &bool) i32 {
        if (*self) < (*other) { return -1; }
        if (*self) > (*other) { return 1; }
        return 0;
    }
}
extend bool as Hash {
    pub fn hash(self: &bool) u64 { return (*self) as u64; }
}
extend bool as Clone {
    pub fn clone(self: &bool) bool { return *self; }
}
extend bool as Default {
    pub fn default() bool { return false; }
}
extend bool as Free {
    pub fn free(self: &mut bool) {}
}
extend bool as Copy {}

extend f32 as Clone {
    pub fn clone(self: &f32) f32 { return *self; }
}
extend f32 as Default {
    pub fn default() f32 { return 0.0; }
}
extend f32 as Free {
    pub fn free(self: &mut f32) {}
}
extend f32 as Copy {}

extend f64 as Clone {
    pub fn clone(self: &f64) f64 { return *self; }
}
extend f64 as Default {
    pub fn default() f64 { return 0.0; }
}
extend f64 as Free {
    pub fn free(self: &mut f64) {}
}
extend f64 as Copy {}

extend c32 as Clone {
    pub fn clone(self: &c32) c32 { return *self; }
}
extend c32 as Default {
    pub fn default() c32 { return 0.0 as c32; }
}
extend c32 as Free {
    pub fn free(self: &mut c32) {}
}
extend c32 as Copy {}

extend c64 as Clone {
    pub fn clone(self: &c64) c64 { return *self; }
}
extend c64 as Default {
    pub fn default() c64 { return 0.0 as c64; }
}
extend c64 as Free {
    pub fn free(self: &mut c64) {}
}
extend c64 as Copy {}

extend i8 {
    pub fn abs(self: i8) i8 { if self < 0 { return (0 - (self as u8)) as i8; } return self; } // unsigned negate: no MIN overflow
    pub fn signum(self: i8) i8 { if self < 0 { return -1; } if self > 0 { return 1; } return 0; }
    pub fn is_positive(self: i8) bool { return self > 0; }
    pub fn is_negative(self: i8) bool { return self < 0; }
    pub fn min(self: i8, other: i8) i8 { if self < other { return self; } return other; }
    pub fn max(self: i8, other: i8) i8 { if self > other { return self; } return other; }
    pub fn clamp(self: i8, min: i8, max: i8) i8 { if self < min { return min; } if self > max { return max; } return self; }
}

extend i16 {
    pub fn abs(self: i16) i16 { if self < 0 { return (0 - (self as u16)) as i16; } return self; } // unsigned negate: no MIN overflow
    pub fn signum(self: i16) i16 { if self < 0 { return -1; } if self > 0 { return 1; } return 0; }
    pub fn is_positive(self: i16) bool { return self > 0; }
    pub fn is_negative(self: i16) bool { return self < 0; }
    pub fn min(self: i16, other: i16) i16 { if self < other { return self; } return other; }
    pub fn max(self: i16, other: i16) i16 { if self > other { return self; } return other; }
    pub fn clamp(self: i16, min: i16, max: i16) i16 { if self < min { return min; } if self > max { return max; } return self; }
}

extend i32 {
    pub fn abs(self: i32) i32 { if self < 0 { return (0 - (self as u32)) as i32; } return self; } // unsigned negate: no MIN overflow
    pub fn signum(self: i32) i32 { if self < 0 { return -1; } if self > 0 { return 1; } return 0; }
    pub fn is_positive(self: i32) bool { return self > 0; }
    pub fn is_negative(self: i32) bool { return self < 0; }
    pub fn min(self: i32, other: i32) i32 { if self < other { return self; } return other; }
    pub fn max(self: i32, other: i32) i32 { if self > other { return self; } return other; }
    pub fn clamp(self: i32, min: i32, max: i32) i32 { if self < min { return min; } if self > max { return max; } return self; }
}

extend i64 {
    pub fn abs(self: i64) i64 { if self < 0 { return (0 - (self as u64)) as i64; } return self; } // unsigned negate: no MIN overflow
    pub fn signum(self: i64) i64 { if self < 0 { return -1; } if self > 0 { return 1; } return 0; }
    pub fn is_positive(self: i64) bool { return self > 0; }
    pub fn is_negative(self: i64) bool { return self < 0; }
    pub fn min(self: i64, other: i64) i64 { if self < other { return self; } return other; }
    pub fn max(self: i64, other: i64) i64 { if self > other { return self; } return other; }
    pub fn clamp(self: i64, min: i64, max: i64) i64 { if self < min { return min; } if self > max { return max; } return self; }
}

extend isize {
    pub fn abs(self: isize) isize { if self < 0 { return (0 - (self as usize)) as isize; } return self; } // unsigned negate: no MIN overflow
    pub fn signum(self: isize) isize { if self < 0 { return -1; } if self > 0 { return 1; } return 0; }
    pub fn is_positive(self: isize) bool { return self > 0; }
    pub fn is_negative(self: isize) bool { return self < 0; }
    pub fn min(self: isize, other: isize) isize { if self < other { return self; } return other; }
    pub fn max(self: isize, other: isize) isize { if self > other { return self; } return other; }
    pub fn clamp(self: isize, min: isize, max: isize) isize { if self < min { return min; } if self > max { return max; } return self; }
}

extend u8 {
    pub fn is_power_of_two(self: u8) bool { return self != 0 && (self & (self - 1)) == 0; }
    pub fn min(self: u8, other: u8) u8 { if self < other { return self; } return other; }
    pub fn max(self: u8, other: u8) u8 { if self > other { return self; } return other; }
    pub fn clamp(self: u8, min: u8, max: u8) u8 { if self < min { return min; } if self > max { return max; } return self; }
}

extend u16 {
    pub fn is_power_of_two(self: u16) bool { return self != 0 && (self & (self - 1)) == 0; }
    pub fn min(self: u16, other: u16) u16 { if self < other { return self; } return other; }
    pub fn max(self: u16, other: u16) u16 { if self > other { return self; } return other; }
    pub fn clamp(self: u16, min: u16, max: u16) u16 { if self < min { return min; } if self > max { return max; } return self; }
}

extend u32 {
    pub fn is_power_of_two(self: u32) bool { return self != 0 && (self & (self - 1)) == 0; }
    pub fn min(self: u32, other: u32) u32 { if self < other { return self; } return other; }
    pub fn max(self: u32, other: u32) u32 { if self > other { return self; } return other; }
    pub fn clamp(self: u32, min: u32, max: u32) u32 { if self < min { return min; } if self > max { return max; } return self; }
}

extend u64 {
    pub fn is_power_of_two(self: u64) bool { return self != 0 && (self & (self - 1)) == 0; }
    pub fn min(self: u64, other: u64) u64 { if self < other { return self; } return other; }
    pub fn max(self: u64, other: u64) u64 { if self > other { return self; } return other; }
    pub fn clamp(self: u64, min: u64, max: u64) u64 { if self < min { return min; } if self > max { return max; } return self; }
}

extend usize {
    pub fn is_power_of_two(self: usize) bool { return self != 0 && (self & (self - 1)) == 0; }
    pub fn min(self: usize, other: usize) usize { if self < other { return self; } return other; }
    pub fn max(self: usize, other: usize) usize { if self > other { return self; } return other; }
    pub fn clamp(self: usize, min: usize, max: usize) usize { if self < min { return min; } if self > max { return max; } return self; }
}

extend f32 {
    pub fn is_nan(self: f32) bool { return self != self; }
    pub fn is_infinite(self: f32) bool { return !self.is_nan() && self == 1.0 / 0.0 || self == -1.0 / 0.0; }
    pub fn is_finite(self: f32) bool { return !self.is_nan() && !self.is_infinite(); }
    pub fn is_sign_positive(self: f32) bool { return copysignf(1.0, self) > 0.0; }
    pub fn is_sign_negative(self: f32) bool { return copysignf(1.0, self) < 0.0; }
    pub fn abs(self: f32) f32 { return fabsf(self); }
    pub fn signum(self: f32) f32 { if self.is_nan() { return self; } return copysignf(1.0, self); }
    pub fn copysign(self: f32, sign: f32) f32 { return copysignf(self, sign); }
    pub fn min(self: f32, other: f32) f32 { return fminf(self, other); }
    pub fn max(self: f32, other: f32) f32 { return fmaxf(self, other); }
    pub fn clamp(self: f32, min: f32, max: f32) f32 { if self < min { return min; } if self > max { return max; } return self; }
    pub fn floor(self: f32) f32 { return floorf(self); }
    pub fn ceil(self: f32) f32 { return ceilf(self); }
    pub fn round(self: f32) f32 { return roundf(self); }
    pub fn trunc(self: f32) f32 { return truncf(self); }
    pub fn fract(self: f32) f32 { return self - truncf(self); }
    pub fn recip(self: f32) f32 { return 1.0 / self; }
    pub fn sqrt(self: f32) f32 { return sqrtf(self); }
    pub fn cbrt(self: f32) f32 { return cbrtf(self); }
    pub fn powf(self: f32, n: f32) f32 { return powf(self, n); }
    pub fn powi(self: f32, n: i32) f32 { return powf(self, n as f32); }
    pub fn exp(self: f32) f32 { return expf(self); }
    pub fn exp2(self: f32) f32 { return exp2f(self); }
    pub fn exp_m1(self: f32) f32 { return expm1f(self); }
    pub fn ln(self: f32) f32 { return logf(self); }
    pub fn log(self: f32, base: f32) f32 { return logf(self) / logf(base); }
    pub fn log2(self: f32) f32 { return log2f(self); }
    pub fn log10(self: f32) f32 { return log10f(self); }
    pub fn ln_1p(self: f32) f32 { return log1pf(self); }
    pub fn hypot(self: f32, other: f32) f32 { return hypotf(self, other); }
    pub fn sin(self: f32) f32 { return sinf(self); }
    pub fn cos(self: f32) f32 { return cosf(self); }
    pub fn tan(self: f32) f32 { return tanf(self); }
    pub fn asin(self: f32) f32 { return asinf(self); }
    pub fn acos(self: f32) f32 { return acosf(self); }
    pub fn atan(self: f32) f32 { return atanf(self); }
    pub fn atan2(self: f32, other: f32) f32 { return atan2f(self, other); }
    pub fn sin_cos(self: f32) (f32, f32) { return sinf(self), cosf(self); }
    pub fn sinh(self: f32) f32 { return sinhf(self); }
    pub fn cosh(self: f32) f32 { return coshf(self); }
    pub fn tanh(self: f32) f32 { return tanhf(self); }
    pub fn asinh(self: f32) f32 { return asinhf(self); }
    pub fn acosh(self: f32) f32 { return acoshf(self); }
    pub fn atanh(self: f32) f32 { return atanhf(self); }
    pub fn mul_add(self: f32, a: f32, b: f32) f32 { return fmaf(self, a, b); }
    pub fn to_degrees(self: f32) f32 { return self * 57.29577951308232; }
    pub fn to_radians(self: f32) f32 { return self * 0.017453292519943295; }
}

extend f64 {
    pub fn is_nan(self: f64) bool { return self != self; }
    pub fn is_infinite(self: f64) bool {
        return !self.is_nan() && self == (1.0 as f64) / (0.0 as f64) || self == (-1.0 as f64) / (0.0 as f64);
    }
    pub fn is_finite(self: f64) bool { return !self.is_nan() && !self.is_infinite(); }
    pub fn is_sign_positive(self: f64) bool { return copysign(1.0, self) > 0.0; }
    pub fn is_sign_negative(self: f64) bool { return copysign(1.0, self) < 0.0; }
    pub fn abs(self: f64) f64 { return fabs(self); }
    pub fn signum(self: f64) f64 { if self.is_nan() { return self; } return copysign(1.0, self); }
    pub fn copysign(self: f64, sign: f64) f64 { return copysign(self, sign); }
    pub fn min(self: f64, other: f64) f64 { return fmin(self, other); }
    pub fn max(self: f64, other: f64) f64 { return fmax(self, other); }
    pub fn clamp(self: f64, min: f64, max: f64) f64 { if self < min { return min; } if self > max { return max; } return self; }
    pub fn floor(self: f64) f64 { return floor(self); }
    pub fn ceil(self: f64) f64 { return ceil(self); }
    pub fn round(self: f64) f64 { return round(self); }
    pub fn trunc(self: f64) f64 { return trunc(self); }
    pub fn fract(self: f64) f64 { return self - trunc(self); }
    pub fn recip(self: f64) f64 { return 1.0 / self; }
    pub fn sqrt(self: f64) f64 { return sqrt(self); }
    pub fn cbrt(self: f64) f64 { return cbrt(self); }
    pub fn powf(self: f64, n: f64) f64 { return pow(self, n); }
    pub fn powi(self: f64, n: i32) f64 { return pow(self, n as f64); }
    pub fn exp(self: f64) f64 { return exp(self); }
    pub fn exp2(self: f64) f64 { return exp2(self); }
    pub fn exp_m1(self: f64) f64 { return expm1(self); }
    pub fn ln(self: f64) f64 { return log(self); }
    pub fn log(self: f64, base: f64) f64 { return log(self) / log(base); }
    pub fn log2(self: f64) f64 { return log2(self); }
    pub fn log10(self: f64) f64 { return log10(self); }
    pub fn ln_1p(self: f64) f64 { return log1p(self); }
    pub fn hypot(self: f64, other: f64) f64 { return hypot(self, other); }
    pub fn sin(self: f64) f64 { return sin(self); }
    pub fn cos(self: f64) f64 { return cos(self); }
    pub fn tan(self: f64) f64 { return tan(self); }
    pub fn asin(self: f64) f64 { return asin(self); }
    pub fn acos(self: f64) f64 { return acos(self); }
    pub fn atan(self: f64) f64 { return atan(self); }
    pub fn atan2(self: f64, other: f64) f64 { return atan2(self, other); }
    pub fn sin_cos(self: f64) (f64, f64) { return sin(self), cos(self); }
    pub fn sinh(self: f64) f64 { return sinh(self); }
    pub fn cosh(self: f64) f64 { return cosh(self); }
    pub fn tanh(self: f64) f64 { return tanh(self); }
    pub fn asinh(self: f64) f64 { return asinh(self); }
    pub fn acosh(self: f64) f64 { return acosh(self); }
    pub fn atanh(self: f64) f64 { return atanh(self); }
    pub fn mul_add(self: f64, a: f64, b: f64) f64 { return fma(self, a, b); }
    pub fn to_degrees(self: f64) f64 { return self * 57.29577951308232; }
    pub fn to_radians(self: f64) f64 { return self * 0.017453292519943295; }
}
