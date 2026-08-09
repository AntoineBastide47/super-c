// The `core` prelude module: standard-interface conformances for the builtin scalar types, so they
// behave as ordinary nominal types behind `T: Hash`/`Eq`/`Ord`/`Clone`/`Default`/`Free`/`Copy` bounds
// (e.g. `Map<i32, V>`) and so user code may `extend i32 { .. }` with its own methods. The compiler seeds a
// synthetic decl per builtin in this module; these `extend` blocks attach to them and lower to
// `i32__eq`, etc. `free` is empty (a scalar owns nothing) -- the C compiler optimizes the call away.
//
// `void` and `va_list` are omitted: they are not ordinary scalar values. Floats implement `Eq`/`Ord`/
// `Hash` through the IEEE-754 TOTAL order (`total_cmp`): -NaN < -inf < .. < -0.0 < +0.0 < .. < +inf < NaN,
// every value equal to itself (including NaN), so sorting and Map/Set keys work -- note `-0.0 != 0.0`
// under this order, unlike `==`. Complex numbers stay out: they admit no total order.

/// Branch-layout hint: this condition is expected to be TRUE. Semantically the identity function
/// (and const-evaluable); codegen lowers direct calls to SC_LIKELY (__builtin_expect on GCC/Clang,
/// the bare condition elsewhere), which steers hot-path block placement -- not the hardware predictor.
pub const fn likely(c: bool) bool {
    return c;
}

/// Branch-layout hint: this condition is expected to be FALSE (error paths, cold branches).
/// See `likely` for the lowering.
pub const fn unlikely(c: bool) bool {
    return c;
}

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

    fn __sc_panic_str(msg: *const u8, len: usize) void; // the runtime trap: prints `panic: <msg>`, aborts
}

/// Abort the program with a message on stderr. There is no unwinding: no cleanup runs, the process
/// dies via abort(). A `@c.noreturn` call types as `never`, so a panicking switch/if arm unifies
/// with value-producing siblings (`None => panic("empty")`).
@c.noreturn
pub fn panic(msg: str) {
    unsafe __sc_panic_str(msg.ptr(), msg.len());
}

extend i8 as Eq {
    pub const fn eq(self: &i8, other: &i8) bool {
        return *self == *other;
    }
}
extend i8 as Ord {
    pub const fn cmp(self: &i8, other: &i8) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend i8 as Hash {
    pub const fn hash(self: &i8) u64 {
        return (*self) as u64;
    }
}
extend i8 as Clone {
    pub const fn clone(self: &i8) i8 {
        return *self;
    }
}
extend i8 as Default {
    pub const fn default() i8 {
        return 0;
    }
}
extend i8 as Free {
    pub fn free(self: &mut i8) {}
}

extend i16 as Eq {
    pub const fn eq(self: &i16, other: &i16) bool {
        return *self == *other;
    }
}
extend i16 as Ord {
    pub const fn cmp(self: &i16, other: &i16) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend i16 as Hash {
    pub const fn hash(self: &i16) u64 {
        return (*self) as u64;
    }
}
extend i16 as Clone {
    pub const fn clone(self: &i16) i16 {
        return *self;
    }
}
extend i16 as Default {
    pub const fn default() i16 {
        return 0;
    }
}
extend i16 as Free {
    pub fn free(self: &mut i16) {}
}

extend i32 as Eq {
    pub const fn eq(self: &i32, other: &i32) bool {
        return *self == *other;
    }
}
extend i32 as Ord {
    pub const fn cmp(self: &i32, other: &i32) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend i32 as Hash {
    pub const fn hash(self: &i32) u64 {
        return (*self) as u64;
    }
}
extend i32 as Clone {
    pub const fn clone(self: &i32) i32 {
        return *self;
    }
}
extend i32 as Default {
    pub const fn default() i32 {
        return 0;
    }
}
extend i32 as Free {
    pub fn free(self: &mut i32) {}
}

extend i64 as Eq {
    pub const fn eq(self: &i64, other: &i64) bool {
        return *self == *other;
    }
}
extend i64 as Ord {
    pub const fn cmp(self: &i64, other: &i64) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend i64 as Hash {
    pub const fn hash(self: &i64) u64 {
        return (*self) as u64;
    }
}
extend i64 as Clone {
    pub const fn clone(self: &i64) i64 {
        return *self;
    }
}
extend i64 as Default {
    pub const fn default() i64 {
        return 0;
    }
}
extend i64 as Free {
    pub fn free(self: &mut i64) {}
}

extend isize as Eq {
    pub const fn eq(self: &isize, other: &isize) bool {
        return *self == *other;
    }
}
extend isize as Ord {
    pub const fn cmp(self: &isize, other: &isize) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend isize as Hash {
    pub const fn hash(self: &isize) u64 {
        return (*self) as u64;
    }
}
extend isize as Clone {
    pub const fn clone(self: &isize) isize {
        return *self;
    }
}
extend isize as Default {
    pub const fn default() isize {
        return 0;
    }
}
extend isize as Free {
    pub fn free(self: &mut isize) {}
}

extend u8 as Eq {
    pub const fn eq(self: &u8, other: &u8) bool {
        return *self == *other;
    }
}
extend u8 as Ord {
    pub const fn cmp(self: &u8, other: &u8) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend u8 as Hash {
    pub const fn hash(self: &u8) u64 {
        return *self;
    }
}
extend u8 as Clone {
    pub const fn clone(self: &u8) u8 {
        return *self;
    }
}
extend u8 as Default {
    pub const fn default() u8 {
        return 0;
    }
}
extend u8 as Free {
    pub fn free(self: &mut u8) {}
}

extend u16 as Eq {
    pub const fn eq(self: &u16, other: &u16) bool {
        return *self == *other;
    }
}
extend u16 as Ord {
    pub const fn cmp(self: &u16, other: &u16) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend u16 as Hash {
    pub const fn hash(self: &u16) u64 {
        return *self;
    }
}
extend u16 as Clone {
    pub const fn clone(self: &u16) u16 {
        return *self;
    }
}
extend u16 as Default {
    pub const fn default() u16 {
        return 0;
    }
}
extend u16 as Free {
    pub fn free(self: &mut u16) {}
}

extend u32 as Eq {
    pub const fn eq(self: &u32, other: &u32) bool {
        return *self == *other;
    }
}
extend u32 as Ord {
    pub const fn cmp(self: &u32, other: &u32) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend u32 as Hash {
    pub const fn hash(self: &u32) u64 {
        return *self;
    }
}
extend u32 as Clone {
    pub const fn clone(self: &u32) u32 {
        return *self;
    }
}
extend u32 as Default {
    pub const fn default() u32 {
        return 0;
    }
}
extend u32 as Free {
    pub fn free(self: &mut u32) {}
}

extend u64 as Eq {
    pub const fn eq(self: &u64, other: &u64) bool {
        return *self == *other;
    }
}
extend u64 as Ord {
    pub const fn cmp(self: &u64, other: &u64) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend u64 as Hash {
    pub const fn hash(self: &u64) u64 {
        return *self;
    }
}
extend u64 as Clone {
    pub const fn clone(self: &u64) u64 {
        return *self;
    }
}
extend u64 as Default {
    pub const fn default() u64 {
        return 0;
    }
}
extend u64 as Free {
    pub fn free(self: &mut u64) {}
}

extend usize as Eq {
    pub const fn eq(self: &usize, other: &usize) bool {
        return *self == *other;
    }
}
extend usize as Ord {
    pub const fn cmp(self: &usize, other: &usize) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend usize as Hash {
    pub const fn hash(self: &usize) u64 {
        return (*self) as u64;
    }
}
extend usize as Clone {
    pub const fn clone(self: &usize) usize {
        return *self;
    }
}
extend usize as Default {
    pub const fn default() usize {
        return 0;
    }
}
extend usize as Free {
    pub fn free(self: &mut usize) {}
}

extend char as Eq {
    pub const fn eq(self: &char, other: &char) bool {
        return *self == *other;
    }
}
extend char as Ord {
    pub const fn cmp(self: &char, other: &char) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend char as Hash {
    pub const fn hash(self: &char) u64 {
        return (*self) as u64;
    }
}
extend char as Clone {
    pub const fn clone(self: &char) char {
        return *self;
    }
}
extend char as Default {
    pub const fn default() char {
        return 0 as char;
    }
}
extend char as Free {
    pub fn free(self: &mut char) {}
}

extend bool as Eq {
    pub const fn eq(self: &bool, other: &bool) bool {
        return *self == *other;
    }
}
extend bool as Ord {
    pub const fn cmp(self: &bool, other: &bool) i32 {
        if *self < *other {
            return -1;
        }
        if *self > *other {
            return 1;
        }
        return 0;
    }
}
extend bool as Hash {
    pub const fn hash(self: &bool) u64 {
        return (*self) as u64;
    }
}
extend bool as Clone {
    pub const fn clone(self: &bool) bool {
        return *self;
    }
}
extend bool as Default {
    pub const fn default() bool {
        return false;
    }
}
extend bool as Free {
    pub fn free(self: &mut bool) {}
}

// IEEE-754 totalOrder bit trick: flipping ALL bits of a negative float and only the sign bit of a
// non-negative one yields unsigned integers that order exactly like totalOrder -- the basis for the
// float `Eq`/`Ord`/`Hash` conformances and the `total_cmp` methods below.
union F32Bits {
    pub u: u32,
    pub f: f32,
}
union F64Bits {
    pub u: u64,
    pub f: f64,
}

fn f32_total_key(x: f32) u32 {
    let b = F32Bits { f: x };
    if b.u >> 31 == 1 {
        return b.u ^ 0xFFFF_FFFFu32;
    }
    return b.u ^ 0x8000_0000u32;
}

fn f64_total_key(x: f64) u64 {
    let b = F64Bits { f: x };
    if b.u >> 63 == 1 {
        return b.u ^ 0xFFFF_FFFF_FFFF_FFFFu64;
    }
    return b.u ^ 0x8000_0000_0000_0000u64;
}

extend f32 as Eq {
    pub const fn eq(self: &f32, other: &f32) bool {
        return f32_total_key(*self) == f32_total_key(*other);
    }
}
extend f32 as Ord {
    pub const fn cmp(self: &f32, other: &f32) i32 {
        let a = f32_total_key(*self);
        let b = f32_total_key(*other);
        if a < b {
            return -1;
        }
        if a > b {
            return 1;
        }
        return 0;
    }
}
extend f32 as Hash {
    pub const fn hash(self: &f32) u64 {
        return f32_total_key(*self);
    }
}
extend f32 as Clone {
    pub const fn clone(self: &f32) f32 {
        return *self;
    }
}
extend f32 as Default {
    pub const fn default() f32 {
        return 0.0;
    }
}
extend f32 as Free {
    pub fn free(self: &mut f32) {}
}

extend f64 as Eq {
    pub const fn eq(self: &f64, other: &f64) bool {
        return f64_total_key(*self) == f64_total_key(*other);
    }
}
extend f64 as Ord {
    pub const fn cmp(self: &f64, other: &f64) i32 {
        let a = f64_total_key(*self);
        let b = f64_total_key(*other);
        if a < b {
            return -1;
        }
        if a > b {
            return 1;
        }
        return 0;
    }
}
extend f64 as Hash {
    pub const fn hash(self: &f64) u64 {
        return f64_total_key(*self);
    }
}
extend f64 as Clone {
    pub const fn clone(self: &f64) f64 {
        return *self;
    }
}
extend f64 as Default {
    pub const fn default() f64 {
        return 0.0;
    }
}
extend f64 as Free {
    pub fn free(self: &mut f64) {}
}

extend c32 as Clone {
    pub const fn clone(self: &c32) c32 {
        return *self;
    }
}
extend c32 as Default {
    pub const fn default() c32 {
        return 0.0;
    }
}
extend c32 as Free {
    pub fn free(self: &mut c32) {}
}

extend c64 as Clone {
    pub const fn clone(self: &c64) c64 {
        return *self;
    }
}
extend c64 as Default {
    pub const fn default() c64 {
        return 0.0;
    }
}
extend c64 as Free {
    pub fn free(self: &mut c64) {}
}

extend i8 {
    pub const fn abs(self: i8) i8 {
        if self < 0 {
            return (0 - self as u8) as i8;
        }
        return self;
    } // unsigned negate: no MIN overflow
    pub const fn signum(self: i8) i8 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    pub const fn is_positive(self: i8) bool {
        return self > 0;
    }
    pub const fn is_negative(self: i8) bool {
        return self < 0;
    }
    pub const fn min(self: i8, other: i8) i8 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: i8, other: i8) i8 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: i8, min: i8, max: i8) i8 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend i16 {
    pub const fn abs(self: i16) i16 {
        if self < 0 {
            return (0 - self as u16) as i16;
        }
        return self;
    } // unsigned negate: no MIN overflow
    pub const fn signum(self: i16) i16 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    pub const fn is_positive(self: i16) bool {
        return self > 0;
    }
    pub const fn is_negative(self: i16) bool {
        return self < 0;
    }
    pub const fn min(self: i16, other: i16) i16 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: i16, other: i16) i16 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: i16, min: i16, max: i16) i16 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend i32 {
    pub const fn abs(self: i32) i32 {
        if self < 0 {
            return (0 - self as u32) as i32;
        }
        return self;
    } // unsigned negate: no MIN overflow
    pub const fn signum(self: i32) i32 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    pub const fn is_positive(self: i32) bool {
        return self > 0;
    }
    pub const fn is_negative(self: i32) bool {
        return self < 0;
    }
    pub const fn min(self: i32, other: i32) i32 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: i32, other: i32) i32 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: i32, min: i32, max: i32) i32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend i64 {
    pub const fn abs(self: i64) i64 {
        if self < 0 {
            return (0 - self as u64) as i64;
        }
        return self;
    } // unsigned negate: no MIN overflow
    pub const fn signum(self: i64) i64 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    pub const fn is_positive(self: i64) bool {
        return self > 0;
    }
    pub const fn is_negative(self: i64) bool {
        return self < 0;
    }
    pub const fn min(self: i64, other: i64) i64 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: i64, other: i64) i64 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: i64, min: i64, max: i64) i64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend isize {
    pub const fn abs(self: isize) isize {
        if self < 0 {
            return (0 - self as usize) as isize;
        }
        return self;
    } // unsigned negate: no MIN overflow
    pub const fn signum(self: isize) isize {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    pub const fn is_positive(self: isize) bool {
        return self > 0;
    }
    pub const fn is_negative(self: isize) bool {
        return self < 0;
    }
    pub const fn min(self: isize, other: isize) isize {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: isize, other: isize) isize {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: isize, min: isize, max: isize) isize {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend u8 {
    pub const fn is_power_of_two(self: u8) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    pub const fn min(self: u8, other: u8) u8 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: u8, other: u8) u8 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: u8, min: u8, max: u8) u8 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend u16 {
    pub const fn is_power_of_two(self: u16) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    pub const fn min(self: u16, other: u16) u16 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: u16, other: u16) u16 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: u16, min: u16, max: u16) u16 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend u32 {
    pub const fn is_power_of_two(self: u32) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    pub const fn min(self: u32, other: u32) u32 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: u32, other: u32) u32 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: u32, min: u32, max: u32) u32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend u64 {
    pub const fn is_power_of_two(self: u64) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    pub const fn min(self: u64, other: u64) u64 {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: u64, other: u64) u64 {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: u64, min: u64, max: u64) u64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend usize {
    pub const fn is_power_of_two(self: usize) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    pub const fn min(self: usize, other: usize) usize {
        if self < other {
            return self;
        }
        return other;
    }
    pub const fn max(self: usize, other: usize) usize {
        if self > other {
            return self;
        }
        return other;
    }
    pub const fn clamp(self: usize, min: usize, max: usize) usize {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
}

extend f32 {
    pub const fn is_nan(self: f32) bool {
        return self != self;
    }
    pub const fn is_infinite(self: f32) bool {
        return !self.is_nan() && self == 1.0 / 0.0 || self == -1.0 / 0.0;
    }
    pub const fn is_finite(self: f32) bool {
        return !self.is_nan() && !self.is_infinite();
    }
    pub const fn is_sign_positive(self: f32) bool {
        return unsafe copysignf(1.0, self) > 0.0;
    }
    pub const fn is_sign_negative(self: f32) bool {
        return unsafe copysignf(1.0, self) < 0.0;
    }
    pub const fn abs(self: f32) f32 {
        return unsafe fabsf(self);
    }
    pub const fn signum(self: f32) f32 {
        if self.is_nan() {
            return self;
        }
        return unsafe copysignf(1.0, self);
    }
    pub const fn copysign(self: f32, sign: f32) f32 {
        return unsafe copysignf(self, sign);
    }
    pub const fn min(self: f32, other: f32) f32 {
        return unsafe fminf(self, other);
    }
    pub const fn max(self: f32, other: f32) f32 {
        return unsafe fmaxf(self, other);
    }
    pub const fn clamp(self: f32, min: f32, max: f32) f32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    pub const fn floor(self: f32) f32 {
        return unsafe floorf(self);
    }
    pub const fn ceil(self: f32) f32 {
        return unsafe ceilf(self);
    }
    pub const fn round(self: f32) f32 {
        return unsafe roundf(self);
    }
    pub const fn trunc(self: f32) f32 {
        return unsafe truncf(self);
    }
    pub const fn fract(self: f32) f32 {
        return self - unsafe truncf(self);
    }
    pub const fn recip(self: f32) f32 {
        return 1.0 / self;
    }
    pub const fn sqrt(self: f32) f32 {
        return unsafe sqrtf(self);
    }
    pub const fn cbrt(self: f32) f32 {
        return unsafe cbrtf(self);
    }
    pub const fn powf(self: f32, n: f32) f32 {
        return unsafe powf(self, n);
    }
    pub const fn powi(self: f32, n: i32) f32 {
        return unsafe powf(self, n as f32);
    }
    pub const fn exp(self: f32) f32 {
        return unsafe expf(self);
    }
    pub const fn exp2(self: f32) f32 {
        return unsafe exp2f(self);
    }
    pub const fn exp_m1(self: f32) f32 {
        return unsafe expm1f(self);
    }
    pub const fn ln(self: f32) f32 {
        return unsafe logf(self);
    }
    pub const fn log(self: f32, base: f32) f32 {
        return unsafe logf(self) / unsafe logf(base);
    }
    pub const fn log2(self: f32) f32 {
        return unsafe log2f(self);
    }
    pub const fn log10(self: f32) f32 {
        return unsafe log10f(self);
    }
    pub const fn ln_1p(self: f32) f32 {
        return unsafe log1pf(self);
    }
    pub const fn hypot(self: f32, other: f32) f32 {
        return unsafe hypotf(self, other);
    }
    pub const fn sin(self: f32) f32 {
        return unsafe sinf(self);
    }
    pub const fn cos(self: f32) f32 {
        return unsafe cosf(self);
    }
    pub const fn tan(self: f32) f32 {
        return unsafe tanf(self);
    }
    pub const fn asin(self: f32) f32 {
        return unsafe asinf(self);
    }
    pub const fn acos(self: f32) f32 {
        return unsafe acosf(self);
    }
    pub const fn atan(self: f32) f32 {
        return unsafe atanf(self);
    }
    pub const fn atan2(self: f32, other: f32) f32 {
        return unsafe atan2f(self, other);
    }
    pub const fn sin_cos(self: f32) (f32, f32) {
        return unsafe sinf(self), unsafe cosf(self);
    }
    pub const fn sinh(self: f32) f32 {
        return unsafe sinhf(self);
    }
    pub const fn cosh(self: f32) f32 {
        return unsafe coshf(self);
    }
    pub const fn tanh(self: f32) f32 {
        return unsafe tanhf(self);
    }
    pub const fn asinh(self: f32) f32 {
        return unsafe asinhf(self);
    }
    pub const fn acosh(self: f32) f32 {
        return unsafe acoshf(self);
    }
    pub const fn atanh(self: f32) f32 {
        return unsafe atanhf(self);
    }
    pub const fn mul_add(self: f32, a: f32, b: f32) f32 {
        return unsafe fmaf(self, a, b);
    }
    /// IEEE-754 totalOrder: negative / zero / positive; NaN sorts above +inf (and -NaN below -inf).
    pub const fn total_cmp(self: f32, other: f32) i32 {
        return self.cmp(&other);
    }
    pub const fn to_degrees(self: f32) f32 {
        return self * 57.29577951308232;
    }
    pub const fn to_radians(self: f32) f32 {
        return self * 0.017453292519943295;
    }
}

extend f64 {
    pub const fn is_nan(self: f64) bool {
        return self != self;
    }
    pub const fn is_infinite(self: f64) bool {
        return !self.is_nan() && self == 1.0 as f64 / 0.0 as f64 || self == (-1.0) as f64 / 0.0 as f64;
    }
    pub const fn is_finite(self: f64) bool {
        return !self.is_nan() && !self.is_infinite();
    }
    pub const fn is_sign_positive(self: f64) bool {
        return unsafe copysign(1.0, self) > 0.0;
    }
    pub const fn is_sign_negative(self: f64) bool {
        return unsafe copysign(1.0, self) < 0.0;
    }
    pub const fn abs(self: f64) f64 {
        return unsafe fabs(self);
    }
    pub const fn signum(self: f64) f64 {
        if self.is_nan() {
            return self;
        }
        return unsafe copysign(1.0, self);
    }
    pub const fn copysign(self: f64, sign: f64) f64 {
        return unsafe copysign(self, sign);
    }
    pub const fn min(self: f64, other: f64) f64 {
        return unsafe fmin(self, other);
    }
    pub const fn max(self: f64, other: f64) f64 {
        return unsafe fmax(self, other);
    }
    pub const fn clamp(self: f64, min: f64, max: f64) f64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    pub const fn floor(self: f64) f64 {
        return unsafe floor(self);
    }
    pub const fn ceil(self: f64) f64 {
        return unsafe ceil(self);
    }
    pub const fn round(self: f64) f64 {
        return unsafe round(self);
    }
    pub const fn trunc(self: f64) f64 {
        return unsafe trunc(self);
    }
    pub const fn fract(self: f64) f64 {
        return self - unsafe trunc(self);
    }
    pub const fn recip(self: f64) f64 {
        return 1.0 / self;
    }
    pub const fn sqrt(self: f64) f64 {
        return unsafe sqrt(self);
    }
    pub const fn cbrt(self: f64) f64 {
        return unsafe cbrt(self);
    }
    pub const fn powf(self: f64, n: f64) f64 {
        return unsafe pow(self, n);
    }
    pub const fn powi(self: f64, n: i32) f64 {
        return unsafe pow(self, n as f64);
    }
    pub const fn exp(self: f64) f64 {
        return unsafe exp(self);
    }
    pub const fn exp2(self: f64) f64 {
        return unsafe exp2(self);
    }
    pub const fn exp_m1(self: f64) f64 {
        return unsafe expm1(self);
    }
    pub const fn ln(self: f64) f64 {
        return unsafe log(self);
    }
    pub const fn log(self: f64, base: f64) f64 {
        return unsafe log(self) / unsafe log(base);
    }
    pub const fn log2(self: f64) f64 {
        return unsafe log2(self);
    }
    pub const fn log10(self: f64) f64 {
        return unsafe log10(self);
    }
    pub const fn ln_1p(self: f64) f64 {
        return unsafe log1p(self);
    }
    pub const fn hypot(self: f64, other: f64) f64 {
        return unsafe hypot(self, other);
    }
    pub const fn sin(self: f64) f64 {
        return unsafe sin(self);
    }
    pub const fn cos(self: f64) f64 {
        return unsafe cos(self);
    }
    pub const fn tan(self: f64) f64 {
        return unsafe tan(self);
    }
    pub const fn asin(self: f64) f64 {
        return unsafe asin(self);
    }
    pub const fn acos(self: f64) f64 {
        return unsafe acos(self);
    }
    pub const fn atan(self: f64) f64 {
        return unsafe atan(self);
    }
    pub const fn atan2(self: f64, other: f64) f64 {
        return unsafe atan2(self, other);
    }
    pub const fn sin_cos(self: f64) (f64, f64) {
        return unsafe sin(self), unsafe cos(self);
    }
    /// IEEE-754 totalOrder: negative / zero / positive; NaN sorts above +inf (and -NaN below -inf).
    pub const fn total_cmp(self: f64, other: f64) i32 {
        return self.cmp(&other);
    }
    pub const fn sinh(self: f64) f64 {
        return unsafe sinh(self);
    }
    pub const fn cosh(self: f64) f64 {
        return unsafe cosh(self);
    }
    pub const fn tanh(self: f64) f64 {
        return unsafe tanh(self);
    }
    pub const fn asinh(self: f64) f64 {
        return unsafe asinh(self);
    }
    pub const fn acosh(self: f64) f64 {
        return unsafe acosh(self);
    }
    pub const fn atanh(self: f64) f64 {
        return unsafe atanh(self);
    }
    pub const fn mul_add(self: f64, a: f64, b: f64) f64 {
        return unsafe fma(self, a, b);
    }
    pub const fn to_degrees(self: f64) f64 {
        return self * 57.29577951308232;
    }
    pub const fn to_radians(self: f64) f64 {
        return self * 0.017453292519943295;
    }
}

/// Move the value out of `slot`, installing `value` in its place -- the ownership-safe way to take
/// a field out of a value that implements Free (a plain `let x = v.field;` is rejected there: the
/// destructor cannot run on a partial value). The raw-pointer read/write pair transfers ownership
/// without dropping either side; drop-on-assign deliberately ignores raw places.
pub fn replace<T>(slot: &mut T, value: T) T {
    let p = slot as *mut T;
    let old = unsafe *p;
    unsafe *p = value;
    return old;
}

/// The interior-mutability primitive. `get` is the ONE sanctioned place an immutable borrow becomes a
/// mutable pointer: everywhere else `&T as *mut T` is a hard error, so mutation through a shared `&` must
/// go through an `UnsafeCell`. Its storage is never emitted `const`, so writing through that pointer is
/// sound even when the cell lives in an immutable binding. Atomics and the type checker's in-place AST are
/// built on it. Sharing an `UnsafeCell` across threads without external synchronisation is still a data
/// race -- it makes interior mutability *expressible*, not automatically safe.
pub struct UnsafeCell<T> {
    value: T,
}

extend<T> UnsafeCell<T> {
    /// Wrap `value` in a cell.
    pub const fn new(value: T) UnsafeCell<T> {
        return UnsafeCell::<T> { value: value };
    }
    /// A raw mutable pointer to the contained value, valid while the cell is alive. The caller is
    /// responsible for avoiding conflicting concurrent access.
    pub const fn get(self: &UnsafeCell<T>) *mut T {
        return (&self.value) as *mut T;
    }
    /// A shared borrow of the contained value.
    pub const fn get_ref(self: &UnsafeCell<T>) &T {
        return &self.value;
    }
    /// Consume the cell and return the contained value.
    pub const fn into_inner(self: UnsafeCell<T>) T {
        return self.value;
    }
}

// The overlapping-storage cell `forget` moves its value into: unions never run destructors, so the
// payload is deliberately abandoned. Generic so no per-type cells are needed.
union ForgetCell<T> {
    pub some: T,
    pub none: u8,
}

/// Take ownership of `value` and never free it -- the SANCTIONED deliberate leak (tests,
/// process-lifetime singletons, FFI handoffs that outlive the program). The leak tracker
/// (SC_LEAK_CHECK) still reports the abandoned allocations, which is the point: every intentional
/// leak stays visible and greppable instead of being laundered through raw pointers.
pub fn forget<T>(value: T) {
    let cell = ForgetCell::<T> { some: value };
    let _ = (&cell) as *const ForgetCell<T>;
}

/// What sort of type `type_info::<T>()` described. `Slice` covers `[]T`/`[]mut T`, `Str` is `str`;
/// every other named struct instance -- `Vector<T>`, `Box<T>`, user structs -- reports `Struct`.
pub enum TypeTag {
    Void,
    Bool,
    Int,
    Uint,
    Float,
    Complex,
    Pointer,
    Reference,
    Function,
    Array,
    Slice,
    Str,
    Tuple,
    Struct,
    Union,
    Enum,
    Dyn,
    Opaque,
}

/// The value form of one `@reflect(key = value)` entry. A bare key (`@reflect(hidden)`) is `Bool`
/// with `b == true`.
pub enum MetaKind {
    Bool,
    Int,
    Str,
}

/// One `@reflect` entry attached to a type, field, or variant declaration. A value of views: it
/// owns nothing. Exactly one of `b`/`i`/`s` is meaningful, named by `kind`; the inactive slots
/// read false / 0 / "".
pub struct MetaInfo {
    pub name: str<'static>,
    pub kind: MetaKind,
    pub b: bool,
    pub i: i64,
    pub s: str<'static>,
}

/// One field of a reflected struct or union. `offset` is the byte offset in the C layout the
/// compiled program actually uses; for a union every field reports offset 0. `kind` is the tag of
/// the field's own type (one level -- reflect that type itself to go deeper). `meta` holds the
/// declaration's `@reflect` entries, in written order.
pub struct FieldInfo {
    pub name: str<'static>,
    pub offset: usize,
    pub size: usize,
    pub kind: TypeTag,
    pub meta: Slice<'static, MetaInfo>,
}

extend FieldInfo {
    /// The first `@reflect` entry named `name`, or None.
    pub const fn meta(self: &FieldInfo, name: str) Option<MetaInfo> {
        for i in 0..self.meta.len {
            let m = self.meta.get(i);
            if m.name == name {
                return Option::<MetaInfo>::Some(*m);
            }
        }
        return Option::<MetaInfo>::None;
    }

    pub const fn has_meta(self: &FieldInfo, name: str) bool {
        return self.meta(name).is_some();
    }
}

/// One variant of a reflected enum. `tag` is the value the variant has at runtime -- the declared
/// constant for a payload-less enum, the declaration index for an enum with payloads. `payload` is
/// the variant's number of payload values (0 = a unit variant).
pub struct VariantInfo {
    pub name: str<'static>,
    pub tag: i32,
    pub payload: usize,
    pub meta: Slice<'static, MetaInfo>,
}

extend VariantInfo {
    /// The first `@reflect` entry named `name`, or None.
    pub const fn meta(self: &VariantInfo, name: str) Option<MetaInfo> {
        for i in 0..self.meta.len {
            let m = self.meta.get(i);
            if m.name == name {
                return Option::<MetaInfo>::Some(*m);
            }
        }
        return Option::<MetaInfo>::None;
    }

    pub const fn has_meta(self: &VariantInfo, name: str) bool {
        return self.meta(name).is_some();
    }
}

/// The result of `type_info::<T>()`, a compiler intrinsic that folds at compile time -- there is no
/// declaration of `type_info` anywhere, and the value costs nothing unless it is reached. Fully
/// non-owning: every member is a scalar or a `'static` view into static data, so a `TypeInfo` is
/// never freed and can be stored or passed anywhere. `fields` is empty unless `kind` is
/// `Struct`/`Tuple`/`Union`; `variants` is empty unless `kind` is `Enum`; `elem` is the tag of the
/// pointee/element type for `Pointer`/`Reference`/`Array`/`Slice` (else `Void`); `len` is the
/// element count for `Array` (else 0).
pub struct TypeInfo {
    pub name: str<'static>,
    pub kind: TypeTag,
    pub size: usize,
    pub align: usize,
    pub elem: TypeTag,
    pub len: usize,
    pub fields: Slice<'static, FieldInfo>,
    pub variants: Slice<'static, VariantInfo>,
    pub meta: Slice<'static, MetaInfo>,
}

extend TypeInfo {
    /// The field named `name`, or None. FieldInfo is a value of views: returning it copies nothing
    /// it owns, because it owns nothing.
    pub const fn field(self: &TypeInfo, name: str) Option<FieldInfo> {
        for i in 0..self.fields.len {
            let f = self.fields.get(i);
            if f.name == name {
                return Option::<FieldInfo>::Some(*f);
            }
        }
        return Option::<FieldInfo>::None;
    }

    /// The first `@reflect` entry named `name` on the TYPE declaration itself, or None.
    pub const fn meta(self: &TypeInfo, name: str) Option<MetaInfo> {
        for i in 0..self.meta.len {
            let m = self.meta.get(i);
            if m.name == name {
                return Option::<MetaInfo>::Some(*m);
            }
        }
        return Option::<MetaInfo>::None;
    }

    pub const fn has_meta(self: &TypeInfo, name: str) bool {
        return self.meta(name).is_some();
    }

    /// The variant named `name`, or None.
    pub const fn variant(self: &TypeInfo, name: str) Option<VariantInfo> {
        for i in 0..self.variants.len {
            let v = self.variants.get(i);
            if v.name == name {
                return Option::<VariantInfo>::Some(*v);
            }
        }
        return Option::<VariantInfo>::None;
    }

    /// The variant whose runtime value is `tag`, or None -- the reverse lookup a `Display` for a
    /// C-valued enum needs.
    pub const fn variant_by_tag(self: &TypeInfo, tag: i32) Option<VariantInfo> {
        for i in 0..self.variants.len {
            let v = self.variants.get(i);
            if v.tag == tag {
                return Option::<VariantInfo>::Some(*v);
            }
        }
        return Option::<VariantInfo>::None;
    }
}

// `Format` for the builtin scalars: `{}` formats them natively, but a `V: Format` bound (the
// reflection derives dispatch through one) needs the conformance to exist as an interface fact.

extend i8 as Format {
    pub fn fmt(self: &i8) String {
        return format("{}", *self);
    }
}

extend i16 as Format {
    pub fn fmt(self: &i16) String {
        return format("{}", *self);
    }
}

extend i32 as Format {
    pub fn fmt(self: &i32) String {
        return format("{}", *self);
    }
}

extend i64 as Format {
    pub fn fmt(self: &i64) String {
        return format("{}", *self);
    }
}

extend isize as Format {
    pub fn fmt(self: &isize) String {
        return format("{}", *self);
    }
}

extend u8 as Format {
    pub fn fmt(self: &u8) String {
        return format("{}", *self);
    }
}

extend u16 as Format {
    pub fn fmt(self: &u16) String {
        return format("{}", *self);
    }
}

extend u32 as Format {
    pub fn fmt(self: &u32) String {
        return format("{}", *self);
    }
}

extend u64 as Format {
    pub fn fmt(self: &u64) String {
        return format("{}", *self);
    }
}

extend usize as Format {
    pub fn fmt(self: &usize) String {
        return format("{}", *self);
    }
}

extend f32 as Format {
    pub fn fmt(self: &f32) String {
        return format("{}", *self);
    }
}

extend f64 as Format {
    pub fn fmt(self: &f64) String {
        return format("{}", *self);
    }
}

extend bool as Format {
    pub fn fmt(self: &bool) String {
        return format("{}", *self);
    }
}

extend char as Format {
    pub fn fmt(self: &char) String {
        return format("{}", *self);
    }
}
