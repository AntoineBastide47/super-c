// The `core` prelude module: standard-interface conformances for the builtin scalar types, so they
// behave as ordinary nominal types behind `T: Hash`/`Eq`/`Ord`/`Clone`/`Default`/`Free`/`Copy` bounds
// (e.g. `Map<i32, V>`) and so user code may `extend i32 { .. }` with its own methods. The compiler seeds a
// synthetic decl per builtin in this module; these `extend` blocks attach to them and lower to
// `i32__eq`, etc. `free` is empty (a scalar owns nothing): the C compiler optimizes the call away.
//
// `void` and `va_list` are omitted: they are not ordinary scalar values. Floats implement `Eq`/`Ord`/
// `Hash` through the IEEE-754 TOTAL order (`total_cmp`): -NaN < -inf < .. < -0.0 < +0.0 < .. < +inf < NaN,
// every value equal to itself (including NaN), so sorting and Map/Set keys work: note `-0.0 != 0.0`
// under this order, unlike `==`. Complex numbers stay out: they admit no total order.

/// Branch-layout hint: this condition is expected to be TRUE. The identity function (and
/// const-evaluable): the inliner removes the call and the emitted C carries no branch hint, so the
/// call records intent only.
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

    // The runtime trap: prints `panic: <msg>`, aborts.
    fn __sc_panic_str(msg: *const u8, len: usize) void;
}

// Bit counts and wrapping arithmetic over a u64 (bits.h, shipped next to this file): the C compiler's
// builtins with the zero input defined as 64, and C's unsigned operators, which wrap in every profile.
// The IR interpreter models these names, so the `trailing_zeros`, `leading_zeros`, `count_ones`,
// `wrapping_*`, `overflowing_*`, `checked_*` and `saturating_*` methods below evaluate at compile time
// and a `const fn` may call them. The methods are plain `fn`s: the bootstrap release rejects a `const
// fn` that calls an extern function it does not model.
extern "C" "bits.h" {
    fn sc_ctz64(x: u64) u32;
    fn sc_clz64(x: u64) u32;
    fn sc_popcount64(x: u64) u32;
    fn sc_wadd64(a: u64, b: u64) u64;
    fn sc_wsub64(a: u64, b: u64) u64;
    fn sc_wmul64(a: u64, b: u64) u64;
    fn sc_wshl64(a: u64, n: u32) u64;
    fn sc_wshr64(a: u64, n: u32) u64;
    fn sc_wsar64(a: i64, n: u32) i64;
    fn sc_mulo_u64(a: u64, b: u64) bool;
    fn sc_mulo_i64(a: i64, b: i64) bool;
}

/// Abort the program with a message on stderr. There is no unwinding: no cleanup runs, the process
/// dies via abort(). A `@c.noreturn` call types as `never`, so a panicking switch/if arm unifies
/// with value-producing siblings (`None => panic("empty")`).
@c.noreturn
@c.cold
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
// Restates the derived conformance for the bootstrap compiler, which checks a `T: Copy` bound against
// written conformances only (the compiler's node-list pool is a `SplitVec<u32>`).
extend u32 as Copy {}

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
// non-negative one yields unsigned integers that order exactly like totalOrder: the basis for the
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
    /// The smallest value.
    pub const MIN: i8 = -128;
    /// The largest value.
    pub const MAX: i8 = 127;
    /// Zero bits below the lowest set bit of the two's complement pattern (8 for zero).
    pub fn trailing_zeros(self: i8) usize {
        return (self as u8).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (8 for zero).
    pub fn leading_zeros(self: i8) usize {
        return (self as u8).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub fn count_ones(self: i8) usize {
        return (self as u8).count_ones();
    }
    /// Absolute value; MIN overflows as `-MIN` does (a trap with overflow checks, MIN itself without).
    pub const fn abs(self: i8) i8 {
        if self < 0 {
            return -self;
        }
        return self;
    }
    /// -1, 0, or 1 by sign.
    pub const fn signum(self: i8) i8 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    /// True when greater than zero.
    pub const fn is_positive(self: i8) bool {
        return self > 0;
    }
    /// True when less than zero.
    pub const fn is_negative(self: i8) bool {
        return self < 0;
    }
    /// The smaller of the two.
    pub const fn min(self: i8, other: i8) i8 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: i8, other: i8) i8 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: i8, min: i8, max: i8) i8 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: i8, rhs: i8) i8 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i8;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: i8, rhs: i8) i8 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i8;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: i8, rhs: i8) i8 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i8;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub fn wrapping_neg(self: i8) i8 {
        return (unsafe sc_wsub64(0, self as u64)) as i8;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: i8, n: u32) i8 {
        return (unsafe sc_wshl64(self as u64, n & 7)) as i8;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub fn wrapping_shr(self: i8, n: u32) i8 {
        return (unsafe sc_wsar64(self, n & 7)) as i8;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: i8, rhs: i8) (i8, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: i8, rhs: i8) (i8, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: i8, rhs: i8) (i8, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i8;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub fn checked_rem(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub fn checked_neg(self: i8) Option<i8> {
        if self == -128 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: i8, n: u32) Option<i8> {
        if n >= 8 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: i8, n: u32) Option<i8> {
        if n >= 8 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub fn saturating_add(self: i8, rhs: i8) i8 {
        let (r, o) = self.overflowing_add(rhs);
        if !o {
            return r;
        }
        if rhs < 0 {
            return -128;
        }
        return 127;
    }
    /// `self - rhs`, clamped to [MIN, MAX].
    pub fn saturating_sub(self: i8, rhs: i8) i8 {
        let (r, o) = self.overflowing_sub(rhs);
        if !o {
            return r;
        }
        if rhs > 0 {
            return -128;
        }
        return 127;
    }
    /// `self * rhs`, clamped to [MIN, MAX].
    pub fn saturating_mul(self: i8, rhs: i8) i8 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -128;
        }
        return 127;
    }
}

extend i16 {
    /// The smallest value.
    pub const MIN: i16 = -32768;
    /// The largest value.
    pub const MAX: i16 = 32767;
    /// Zero bits below the lowest set bit of the two's complement pattern (16 for zero).
    pub fn trailing_zeros(self: i16) usize {
        return (self as u16).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (16 for zero).
    pub fn leading_zeros(self: i16) usize {
        return (self as u16).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub fn count_ones(self: i16) usize {
        return (self as u16).count_ones();
    }
    /// Absolute value; MIN overflows as `-MIN` does (a trap with overflow checks, MIN itself without).
    pub const fn abs(self: i16) i16 {
        if self < 0 {
            return -self;
        }
        return self;
    }
    /// -1, 0, or 1 by sign.
    pub const fn signum(self: i16) i16 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    /// True when greater than zero.
    pub const fn is_positive(self: i16) bool {
        return self > 0;
    }
    /// True when less than zero.
    pub const fn is_negative(self: i16) bool {
        return self < 0;
    }
    /// The smaller of the two.
    pub const fn min(self: i16, other: i16) i16 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: i16, other: i16) i16 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: i16, min: i16, max: i16) i16 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: i16, rhs: i16) i16 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i16;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: i16, rhs: i16) i16 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i16;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: i16, rhs: i16) i16 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i16;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub fn wrapping_neg(self: i16) i16 {
        return (unsafe sc_wsub64(0, self as u64)) as i16;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: i16, n: u32) i16 {
        return (unsafe sc_wshl64(self as u64, n & 15)) as i16;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub fn wrapping_shr(self: i16, n: u32) i16 {
        return (unsafe sc_wsar64(self, n & 15)) as i16;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: i16, rhs: i16) (i16, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: i16, rhs: i16) (i16, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: i16, rhs: i16) (i16, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i16;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub fn checked_rem(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub fn checked_neg(self: i16) Option<i16> {
        if self == -32768 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: i16, n: u32) Option<i16> {
        if n >= 16 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: i16, n: u32) Option<i16> {
        if n >= 16 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub fn saturating_add(self: i16, rhs: i16) i16 {
        let (r, o) = self.overflowing_add(rhs);
        if !o {
            return r;
        }
        if rhs < 0 {
            return -32768;
        }
        return 32767;
    }
    /// `self - rhs`, clamped to [MIN, MAX].
    pub fn saturating_sub(self: i16, rhs: i16) i16 {
        let (r, o) = self.overflowing_sub(rhs);
        if !o {
            return r;
        }
        if rhs > 0 {
            return -32768;
        }
        return 32767;
    }
    /// `self * rhs`, clamped to [MIN, MAX].
    pub fn saturating_mul(self: i16, rhs: i16) i16 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -32768;
        }
        return 32767;
    }
}

extend i32 {
    /// The smallest value.
    pub const MIN: i32 = -2147483648;
    /// The largest value.
    pub const MAX: i32 = 2147483647;
    /// Zero bits below the lowest set bit of the two's complement pattern (32 for zero).
    pub fn trailing_zeros(self: i32) usize {
        return (self as u32).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (32 for zero).
    pub fn leading_zeros(self: i32) usize {
        return (self as u32).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub fn count_ones(self: i32) usize {
        return (self as u32).count_ones();
    }
    /// Absolute value; MIN overflows as `-MIN` does (a trap with overflow checks, MIN itself without).
    pub const fn abs(self: i32) i32 {
        if self < 0 {
            return -self;
        }
        return self;
    }
    /// -1, 0, or 1 by sign.
    pub const fn signum(self: i32) i32 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    /// True when greater than zero.
    pub const fn is_positive(self: i32) bool {
        return self > 0;
    }
    /// True when less than zero.
    pub const fn is_negative(self: i32) bool {
        return self < 0;
    }
    /// The smaller of the two.
    pub const fn min(self: i32, other: i32) i32 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: i32, other: i32) i32 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: i32, min: i32, max: i32) i32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: i32, rhs: i32) i32 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i32;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: i32, rhs: i32) i32 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i32;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: i32, rhs: i32) i32 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i32;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub fn wrapping_neg(self: i32) i32 {
        return (unsafe sc_wsub64(0, self as u64)) as i32;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: i32, n: u32) i32 {
        return (unsafe sc_wshl64(self as u64, n & 31)) as i32;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub fn wrapping_shr(self: i32, n: u32) i32 {
        return (unsafe sc_wsar64(self, n & 31)) as i32;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: i32, rhs: i32) (i32, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: i32, rhs: i32) (i32, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: i32, rhs: i32) (i32, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i32;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub fn checked_rem(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub fn checked_neg(self: i32) Option<i32> {
        if self == -2147483648 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: i32, n: u32) Option<i32> {
        if n >= 32 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: i32, n: u32) Option<i32> {
        if n >= 32 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub fn saturating_add(self: i32, rhs: i32) i32 {
        let (r, o) = self.overflowing_add(rhs);
        if !o {
            return r;
        }
        if rhs < 0 {
            return -2147483648;
        }
        return 2147483647;
    }
    /// `self - rhs`, clamped to [MIN, MAX].
    pub fn saturating_sub(self: i32, rhs: i32) i32 {
        let (r, o) = self.overflowing_sub(rhs);
        if !o {
            return r;
        }
        if rhs > 0 {
            return -2147483648;
        }
        return 2147483647;
    }
    /// `self * rhs`, clamped to [MIN, MAX].
    pub fn saturating_mul(self: i32, rhs: i32) i32 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -2147483648;
        }
        return 2147483647;
    }
}

extend i64 {
    /// The smallest value.
    pub const MIN: i64 = -9223372036854775808;
    /// The largest value.
    pub const MAX: i64 = 9223372036854775807;
    /// Zero bits below the lowest set bit of the two's complement pattern (64 for zero).
    pub fn trailing_zeros(self: i64) usize {
        return (self as u64).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (64 for zero).
    pub fn leading_zeros(self: i64) usize {
        return (self as u64).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub fn count_ones(self: i64) usize {
        return (self as u64).count_ones();
    }
    /// Absolute value; MIN overflows as `-MIN` does (a trap with overflow checks, MIN itself without).
    pub const fn abs(self: i64) i64 {
        if self < 0 {
            return -self;
        }
        return self;
    }
    /// -1, 0, or 1 by sign.
    pub const fn signum(self: i64) i64 {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    /// True when greater than zero.
    pub const fn is_positive(self: i64) bool {
        return self > 0;
    }
    /// True when less than zero.
    pub const fn is_negative(self: i64) bool {
        return self < 0;
    }
    /// The smaller of the two.
    pub const fn min(self: i64, other: i64) i64 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: i64, other: i64) i64 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: i64, min: i64, max: i64) i64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: i64, rhs: i64) i64 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i64;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: i64, rhs: i64) i64 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i64;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: i64, rhs: i64) i64 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i64;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub fn wrapping_neg(self: i64) i64 {
        return (unsafe sc_wsub64(0, self as u64)) as i64;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: i64, n: u32) i64 {
        return (unsafe sc_wshl64(self as u64, n & 63)) as i64;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub fn wrapping_shr(self: i64, n: u32) i64 {
        return unsafe sc_wsar64(self, n & 63);
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: i64, rhs: i64) (i64, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: i64, rhs: i64) (i64, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: i64, rhs: i64) (i64, bool) {
        return self.wrapping_mul(rhs), unsafe sc_mulo_i64(self, rhs);
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub fn checked_rem(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub fn checked_neg(self: i64) Option<i64> {
        if self == -9223372036854775807 - 1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: i64, n: u32) Option<i64> {
        if n >= 64 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: i64, n: u32) Option<i64> {
        if n >= 64 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub fn saturating_add(self: i64, rhs: i64) i64 {
        let (r, o) = self.overflowing_add(rhs);
        if !o {
            return r;
        }
        if rhs < 0 {
            return -9223372036854775807 - 1;
        }
        return 9223372036854775807;
    }
    /// `self - rhs`, clamped to [MIN, MAX].
    pub fn saturating_sub(self: i64, rhs: i64) i64 {
        let (r, o) = self.overflowing_sub(rhs);
        if !o {
            return r;
        }
        if rhs > 0 {
            return -9223372036854775807 - 1;
        }
        return 9223372036854775807;
    }
    /// `self * rhs`, clamped to [MIN, MAX].
    pub fn saturating_mul(self: i64, rhs: i64) i64 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -9223372036854775807 - 1;
        }
        return 9223372036854775807;
    }
}

extend isize {
    /// The smallest value (the target's pointer width).
    pub const MIN: isize = -((~0usize >> 1) as isize) - 1;
    /// The largest value (the target's pointer width).
    pub const MAX: isize = (~0usize >> 1) as isize;
    /// Zero bits below the lowest set bit of the two's complement pattern (the width for zero).
    pub fn trailing_zeros(self: isize) usize {
        return (self as usize).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (the width for zero).
    pub fn leading_zeros(self: isize) usize {
        return (self as usize).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub fn count_ones(self: isize) usize {
        return (self as usize).count_ones();
    }
    /// Absolute value; MIN overflows as `-MIN` does (a trap with overflow checks, MIN itself without).
    pub const fn abs(self: isize) isize {
        if self < 0 {
            return -self;
        }
        return self;
    }
    /// -1, 0, or 1 by sign.
    pub const fn signum(self: isize) isize {
        if self < 0 {
            return -1;
        }
        if self > 0 {
            return 1;
        }
        return 0;
    }
    /// True when greater than zero.
    pub const fn is_positive(self: isize) bool {
        return self > 0;
    }
    /// True when less than zero.
    pub const fn is_negative(self: isize) bool {
        return self < 0;
    }
    /// The smaller of the two.
    pub const fn min(self: isize, other: isize) isize {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: isize, other: isize) isize {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: isize, min: isize, max: isize) isize {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: isize, rhs: isize) isize {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as isize;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: isize, rhs: isize) isize {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as isize;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: isize, rhs: isize) isize {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as isize;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub fn wrapping_neg(self: isize) isize {
        return (unsafe sc_wsub64(0, self as u64)) as isize;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: isize, n: u32) isize {
        return (unsafe sc_wshl64(self as u64, n & sizeof(isize) as u32 * 8 - 1)) as isize;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub fn wrapping_shr(self: isize, n: u32) isize {
        return (unsafe sc_wsar64(self as i64, n & sizeof(isize) as u32 * 8 - 1)) as isize;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: isize, rhs: isize) (isize, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: isize, rhs: isize) (isize, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: isize, rhs: isize) (isize, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64;
        let r = p as isize;
        return r, unsafe sc_mulo_i64(self as i64, rhs as i64) || r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub fn checked_rem(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub fn checked_neg(self: isize) Option<isize> {
        if self == -((~0usize >> 1) as isize) - 1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: isize, n: u32) Option<isize> {
        if n >= sizeof(isize) as u32 * 8 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: isize, n: u32) Option<isize> {
        if n >= sizeof(isize) as u32 * 8 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub fn saturating_add(self: isize, rhs: isize) isize {
        let (r, o) = self.overflowing_add(rhs);
        if !o {
            return r;
        }
        if rhs < 0 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return (~0usize >> 1) as isize;
    }
    /// `self - rhs`, clamped to [MIN, MAX].
    pub fn saturating_sub(self: isize, rhs: isize) isize {
        let (r, o) = self.overflowing_sub(rhs);
        if !o {
            return r;
        }
        if rhs > 0 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return (~0usize >> 1) as isize;
    }
    /// `self * rhs`, clamped to [MIN, MAX].
    pub fn saturating_mul(self: isize, rhs: isize) isize {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return (~0usize >> 1) as isize;
    }
}

extend u8 {
    /// The smallest value.
    pub const MIN: u8 = 0;
    /// The largest value.
    pub const MAX: u8 = 255;
    /// Zero bits below the lowest set bit (8 for zero).
    pub fn trailing_zeros(self: u8) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 8)) as usize; // bit 8 set: a zero counts 8
    }
    /// Zero bits above the highest set bit (8 for zero).
    pub fn leading_zeros(self: u8) usize {
        return (unsafe sc_clz64(self)) as usize - 56;
    }
    /// Number of set bits.
    pub fn count_ones(self: u8) usize {
        return (unsafe sc_popcount64(self)) as usize;
    }
    /// True for exactly one set bit (0 is not a power of two).
    pub const fn is_power_of_two(self: u8) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    /// The smaller of the two.
    pub const fn min(self: u8, other: u8) u8 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: u8, other: u8) u8 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: u8, min: u8, max: u8) u8 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: u8, rhs: u8) u8 {
        return (unsafe sc_wadd64(self, rhs)) as u8;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: u8, rhs: u8) u8 {
        return (unsafe sc_wsub64(self, rhs)) as u8;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: u8, rhs: u8) u8 {
        return (unsafe sc_wmul64(self, rhs)) as u8;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub fn wrapping_neg(self: u8) u8 {
        return (unsafe sc_wsub64(0, self)) as u8;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: u8, n: u32) u8 {
        return (unsafe sc_wshl64(self, n & 7)) as u8;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub fn wrapping_shr(self: u8, n: u32) u8 {
        return (unsafe sc_wshr64(self, n & 7)) as u8;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: u8, rhs: u8) (u8, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: u8, rhs: u8) (u8, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: u8, rhs: u8) (u8, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u8, p > 255;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub fn checked_div(self: u8, rhs: u8) Option<u8> {
        if rhs == 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub fn checked_rem(self: u8, rhs: u8) Option<u8> {
        if rhs == 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub fn checked_neg(self: u8) Option<u8> {
        if self != 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: u8, n: u32) Option<u8> {
        if n >= 8 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: u8, n: u32) Option<u8> {
        if n >= 8 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub fn saturating_add(self: u8, rhs: u8) u8 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 255;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub fn saturating_sub(self: u8, rhs: u8) u8 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub fn saturating_mul(self: u8, rhs: u8) u8 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 255;
        }
        return r;
    }
}

extend u16 {
    /// The smallest value.
    pub const MIN: u16 = 0;
    /// The largest value.
    pub const MAX: u16 = 65535;
    /// Zero bits below the lowest set bit (16 for zero).
    pub fn trailing_zeros(self: u16) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 16)) as usize; // bit 16 set: a zero counts 16
    }
    /// Zero bits above the highest set bit (16 for zero).
    pub fn leading_zeros(self: u16) usize {
        return (unsafe sc_clz64(self)) as usize - 48;
    }
    /// Number of set bits.
    pub fn count_ones(self: u16) usize {
        return (unsafe sc_popcount64(self)) as usize;
    }
    /// True for exactly one set bit (0 is not a power of two).
    pub const fn is_power_of_two(self: u16) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    /// The smaller of the two.
    pub const fn min(self: u16, other: u16) u16 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: u16, other: u16) u16 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: u16, min: u16, max: u16) u16 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: u16, rhs: u16) u16 {
        return (unsafe sc_wadd64(self, rhs)) as u16;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: u16, rhs: u16) u16 {
        return (unsafe sc_wsub64(self, rhs)) as u16;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: u16, rhs: u16) u16 {
        return (unsafe sc_wmul64(self, rhs)) as u16;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub fn wrapping_neg(self: u16) u16 {
        return (unsafe sc_wsub64(0, self)) as u16;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: u16, n: u32) u16 {
        return (unsafe sc_wshl64(self, n & 15)) as u16;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub fn wrapping_shr(self: u16, n: u32) u16 {
        return (unsafe sc_wshr64(self, n & 15)) as u16;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: u16, rhs: u16) (u16, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: u16, rhs: u16) (u16, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: u16, rhs: u16) (u16, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u16, p > 65535;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub fn checked_div(self: u16, rhs: u16) Option<u16> {
        if rhs == 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub fn checked_rem(self: u16, rhs: u16) Option<u16> {
        if rhs == 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub fn checked_neg(self: u16) Option<u16> {
        if self != 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: u16, n: u32) Option<u16> {
        if n >= 16 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: u16, n: u32) Option<u16> {
        if n >= 16 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub fn saturating_add(self: u16, rhs: u16) u16 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 65535;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub fn saturating_sub(self: u16, rhs: u16) u16 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub fn saturating_mul(self: u16, rhs: u16) u16 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 65535;
        }
        return r;
    }
}

extend u32 {
    /// The smallest value.
    pub const MIN: u32 = 0;
    /// The largest value.
    pub const MAX: u32 = 4294967295;
    /// Zero bits below the lowest set bit (32 for zero).
    pub fn trailing_zeros(self: u32) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 32)) as usize; // bit 32 set: a zero counts 32
    }
    /// Zero bits above the highest set bit (32 for zero).
    pub fn leading_zeros(self: u32) usize {
        return (unsafe sc_clz64(self)) as usize - 32;
    }
    /// Number of set bits.
    pub fn count_ones(self: u32) usize {
        return (unsafe sc_popcount64(self)) as usize;
    }
    /// True for exactly one set bit (0 is not a power of two).
    pub const fn is_power_of_two(self: u32) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    /// The smaller of the two.
    pub const fn min(self: u32, other: u32) u32 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: u32, other: u32) u32 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: u32, min: u32, max: u32) u32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: u32, rhs: u32) u32 {
        return (unsafe sc_wadd64(self, rhs)) as u32;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: u32, rhs: u32) u32 {
        return (unsafe sc_wsub64(self, rhs)) as u32;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: u32, rhs: u32) u32 {
        return (unsafe sc_wmul64(self, rhs)) as u32;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub fn wrapping_neg(self: u32) u32 {
        return (unsafe sc_wsub64(0, self)) as u32;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: u32, n: u32) u32 {
        return (unsafe sc_wshl64(self, n & 31)) as u32;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub fn wrapping_shr(self: u32, n: u32) u32 {
        return (unsafe sc_wshr64(self, n & 31)) as u32;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: u32, rhs: u32) (u32, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: u32, rhs: u32) (u32, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: u32, rhs: u32) (u32, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u32, p > 4294967295;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub fn checked_div(self: u32, rhs: u32) Option<u32> {
        if rhs == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub fn checked_rem(self: u32, rhs: u32) Option<u32> {
        if rhs == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub fn checked_neg(self: u32) Option<u32> {
        if self != 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: u32, n: u32) Option<u32> {
        if n >= 32 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: u32, n: u32) Option<u32> {
        if n >= 32 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub fn saturating_add(self: u32, rhs: u32) u32 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 4294967295;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub fn saturating_sub(self: u32, rhs: u32) u32 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub fn saturating_mul(self: u32, rhs: u32) u32 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 4294967295;
        }
        return r;
    }
}

extend u64 {
    /// The smallest value.
    pub const MIN: u64 = 0;
    /// The largest value.
    pub const MAX: u64 = 18446744073709551615;
    /// Zero bits below the lowest set bit (64 for zero).
    pub fn trailing_zeros(self: u64) usize {
        return (unsafe sc_ctz64(self)) as usize;
    }
    /// Zero bits above the highest set bit (64 for zero).
    pub fn leading_zeros(self: u64) usize {
        return (unsafe sc_clz64(self)) as usize;
    }
    /// Number of set bits.
    pub fn count_ones(self: u64) usize {
        return (unsafe sc_popcount64(self)) as usize;
    }
    /// True for exactly one set bit (0 is not a power of two).
    pub const fn is_power_of_two(self: u64) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    /// The smaller of the two.
    pub const fn min(self: u64, other: u64) u64 {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: u64, other: u64) u64 {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: u64, min: u64, max: u64) u64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: u64, rhs: u64) u64 {
        return unsafe sc_wadd64(self, rhs);
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: u64, rhs: u64) u64 {
        return unsafe sc_wsub64(self, rhs);
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: u64, rhs: u64) u64 {
        return unsafe sc_wmul64(self, rhs);
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub fn wrapping_neg(self: u64) u64 {
        return unsafe sc_wsub64(0, self);
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: u64, n: u32) u64 {
        return unsafe sc_wshl64(self, n & 63);
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub fn wrapping_shr(self: u64, n: u32) u64 {
        return unsafe sc_wshr64(self, n & 63);
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: u64, rhs: u64) (u64, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: u64, rhs: u64) (u64, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: u64, rhs: u64) (u64, bool) {
        return self.wrapping_mul(rhs), unsafe sc_mulo_u64(self, rhs);
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub fn checked_div(self: u64, rhs: u64) Option<u64> {
        if rhs == 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub fn checked_rem(self: u64, rhs: u64) Option<u64> {
        if rhs == 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub fn checked_neg(self: u64) Option<u64> {
        if self != 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: u64, n: u32) Option<u64> {
        if n >= 64 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: u64, n: u32) Option<u64> {
        if n >= 64 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub fn saturating_add(self: u64, rhs: u64) u64 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 18446744073709551615;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub fn saturating_sub(self: u64, rhs: u64) u64 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub fn saturating_mul(self: u64, rhs: u64) u64 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 18446744073709551615;
        }
        return r;
    }
}

extend usize {
    /// The smallest value (the target's pointer width).
    pub const MIN: usize = 0;
    /// The largest value (the target's pointer width).
    pub const MAX: usize = ~0usize;
    /// Zero bits below the lowest set bit (the width for zero).
    pub fn trailing_zeros(self: usize) usize {
        let n = (unsafe sc_ctz64(self as u64)) as usize;
        return n.min(sizeof(usize) * 8);
    }
    /// Zero bits above the highest set bit (the width for zero).
    pub fn leading_zeros(self: usize) usize {
        return (unsafe sc_clz64(self as u64)) as usize - (64 - sizeof(usize) * 8);
    }
    /// Number of set bits.
    pub fn count_ones(self: usize) usize {
        return (unsafe sc_popcount64(self as u64)) as usize;
    }
    /// True for exactly one set bit (0 is not a power of two).
    pub const fn is_power_of_two(self: usize) bool {
        return self != 0 && (self & self - 1) == 0;
    }
    /// The smaller of the two.
    pub const fn min(self: usize, other: usize) usize {
        if self < other {
            return self;
        }
        return other;
    }
    /// The larger of the two.
    pub const fn max(self: usize, other: usize) usize {
        if self > other {
            return self;
        }
        return other;
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: usize, min: usize, max: usize) usize {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// `self + rhs` modulo 2^N (N the width): never overflows.
    pub fn wrapping_add(self: usize, rhs: usize) usize {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as usize;
    }
    /// `self - rhs` modulo 2^N.
    pub fn wrapping_sub(self: usize, rhs: usize) usize {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as usize;
    }
    /// `self * rhs` modulo 2^N.
    pub fn wrapping_mul(self: usize, rhs: usize) usize {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as usize;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub fn wrapping_neg(self: usize) usize {
        return (unsafe sc_wsub64(0, self as u64)) as usize;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub fn wrapping_shl(self: usize, n: u32) usize {
        return (unsafe sc_wshl64(self as u64, n & sizeof(usize) as u32 * 8 - 1)) as usize;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub fn wrapping_shr(self: usize, n: u32) usize {
        return (unsafe sc_wshr64(self as u64, n & sizeof(usize) as u32 * 8 - 1)) as usize;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub fn overflowing_add(self: usize, rhs: usize) (usize, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub fn overflowing_sub(self: usize, rhs: usize) (usize, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub fn overflowing_mul(self: usize, rhs: usize) (usize, bool) {
        let p = unsafe sc_wmul64(self as u64, rhs as u64);
        return p as usize, unsafe sc_mulo_u64(self as u64, rhs as u64) || p > (~0usize) as u64;
    }
    /// `self + rhs`, or None when it overflows.
    pub fn checked_add(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub fn checked_sub(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub fn checked_mul(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub fn checked_div(self: usize, rhs: usize) Option<usize> {
        if rhs == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub fn checked_rem(self: usize, rhs: usize) Option<usize> {
        if rhs == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub fn checked_neg(self: usize) Option<usize> {
        if self != 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub fn checked_shl(self: usize, n: u32) Option<usize> {
        if n >= sizeof(usize) as u32 * 8 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub fn checked_shr(self: usize, n: u32) Option<usize> {
        if n >= sizeof(usize) as u32 * 8 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub fn saturating_add(self: usize, rhs: usize) usize {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return ~0usize;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub fn saturating_sub(self: usize, rhs: usize) usize {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub fn saturating_mul(self: usize, rhs: usize) usize {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return ~0usize;
        }
        return r;
    }
}

extend f32 {
    /// The most negative finite value.
    pub const MIN: f32 = -3.40282347e38;
    /// The largest finite value.
    pub const MAX: f32 = 3.40282347e38;
    /// True for any NaN.
    pub const fn is_nan(self: f32) bool {
        return self != self;
    }
    /// True for +inf or -inf.
    pub const fn is_infinite(self: f32) bool {
        return !self.is_nan() && self == 1.0 / 0.0 || self == -1.0 / 0.0;
    }
    /// True when neither NaN nor infinite.
    pub const fn is_finite(self: f32) bool {
        return !self.is_nan() && !self.is_infinite();
    }
    /// True when the sign bit is clear (+0.0 and positive NaN included).
    pub const fn is_sign_positive(self: f32) bool {
        return unsafe copysignf(1.0, self) > 0.0;
    }
    /// True when the sign bit is set (-0.0 and negative NaN included).
    pub const fn is_sign_negative(self: f32) bool {
        return unsafe copysignf(1.0, self) < 0.0;
    }
    /// Absolute value: clears the sign bit (-0.0 gives +0.0, a NaN stays a NaN).
    pub const fn abs(self: f32) f32 {
        return unsafe fabsf(self);
    }
    /// 1.0 when the sign bit is clear (+0.0 included), -1.0 when it is set (-0.0 included); NaN stays NaN.
    pub const fn signum(self: f32) f32 {
        if self.is_nan() {
            return self;
        }
        return unsafe copysignf(1.0, self);
    }
    /// `self`'s magnitude with `sign`'s sign.
    pub const fn copysign(self: f32, sign: f32) f32 {
        return unsafe copysignf(self, sign);
    }
    /// The smaller of the two.
    pub const fn min(self: f32, other: f32) f32 {
        return unsafe fminf(self, other);
    }
    /// The larger of the two.
    pub const fn max(self: f32, other: f32) f32 {
        return unsafe fmaxf(self, other);
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: f32, min: f32, max: f32) f32 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// Largest integral value not above `self`.
    pub const fn floor(self: f32) f32 {
        return unsafe floorf(self);
    }
    /// Smallest integral value not below `self`.
    pub const fn ceil(self: f32) f32 {
        return unsafe ceilf(self);
    }
    /// Nearest integral value, halves away from zero.
    pub const fn round(self: f32) f32 {
        return unsafe roundf(self);
    }
    /// Integral part, toward zero.
    pub const fn trunc(self: f32) f32 {
        return unsafe truncf(self);
    }
    /// `self - self.trunc()`, with `self`'s sign.
    pub const fn fract(self: f32) f32 {
        return self - unsafe truncf(self);
    }
    /// `1 / self`.
    pub const fn recip(self: f32) f32 {
        return 1.0 / self;
    }
    /// Square root; NaN for a negative value.
    pub const fn sqrt(self: f32) f32 {
        return unsafe sqrtf(self);
    }
    /// Cube root (defined for negatives).
    pub const fn cbrt(self: f32) f32 {
        return unsafe cbrtf(self);
    }
    /// `self` raised to `n`.
    pub const fn powf(self: f32, n: f32) f32 {
        return unsafe powf(self, n);
    }
    /// `self` raised to the integer `n` (through `pow`).
    pub const fn powi(self: f32, n: i32) f32 {
        return unsafe powf(self, n as f32);
    }
    /// e^self.
    pub const fn exp(self: f32) f32 {
        return unsafe expf(self);
    }
    /// 2^self.
    pub const fn exp2(self: f32) f32 {
        return unsafe exp2f(self);
    }
    /// e^self - 1, accurate near zero.
    pub const fn exp_m1(self: f32) f32 {
        return unsafe expm1f(self);
    }
    /// Natural logarithm; -inf at 0, NaN below.
    pub const fn ln(self: f32) f32 {
        return unsafe logf(self);
    }
    /// Logarithm in `base` (as ln(self) / ln(base)).
    pub const fn log(self: f32, base: f32) f32 {
        return unsafe logf(self) / unsafe logf(base);
    }
    /// Base-2 logarithm.
    pub const fn log2(self: f32) f32 {
        return unsafe log2f(self);
    }
    /// Base-10 logarithm.
    pub const fn log10(self: f32) f32 {
        return unsafe log10f(self);
    }
    /// ln(1 + self), accurate near zero.
    pub const fn ln_1p(self: f32) f32 {
        return unsafe log1pf(self);
    }
    /// sqrt(self^2 + other^2) without intermediate overflow.
    pub const fn hypot(self: f32, other: f32) f32 {
        return unsafe hypotf(self, other);
    }
    /// Sine of an angle in radians.
    pub const fn sin(self: f32) f32 {
        return unsafe sinf(self);
    }
    /// Cosine of an angle in radians.
    pub const fn cos(self: f32) f32 {
        return unsafe cosf(self);
    }
    /// Tangent of an angle in radians.
    pub const fn tan(self: f32) f32 {
        return unsafe tanf(self);
    }
    /// Arc sine in radians; NaN outside [-1, 1].
    pub const fn asin(self: f32) f32 {
        return unsafe asinf(self);
    }
    /// Arc cosine in radians; NaN outside [-1, 1].
    pub const fn acos(self: f32) f32 {
        return unsafe acosf(self);
    }
    /// Arc tangent in radians.
    pub const fn atan(self: f32) f32 {
        return unsafe atanf(self);
    }
    /// Arc tangent of self/other using both signs to pick the quadrant.
    pub const fn atan2(self: f32, other: f32) f32 {
        return unsafe atan2f(self, other);
    }
    /// (sin, cos) of an angle in radians.
    pub const fn sin_cos(self: f32) (f32, f32) {
        return unsafe sinf(self), unsafe cosf(self);
    }
    /// Hyperbolic sine.
    pub const fn sinh(self: f32) f32 {
        return unsafe sinhf(self);
    }
    /// Hyperbolic cosine.
    pub const fn cosh(self: f32) f32 {
        return unsafe coshf(self);
    }
    /// Hyperbolic tangent.
    pub const fn tanh(self: f32) f32 {
        return unsafe tanhf(self);
    }
    /// Inverse hyperbolic sine.
    pub const fn asinh(self: f32) f32 {
        return unsafe asinhf(self);
    }
    /// Inverse hyperbolic cosine; NaN below 1.
    pub const fn acosh(self: f32) f32 {
        return unsafe acoshf(self);
    }
    /// Inverse hyperbolic tangent; NaN outside [-1, 1].
    pub const fn atanh(self: f32) f32 {
        return unsafe atanhf(self);
    }
    /// `self * a + b` with a single rounding.
    pub const fn mul_add(self: f32, a: f32, b: f32) f32 {
        return unsafe fmaf(self, a, b);
    }
    /// IEEE-754 totalOrder: negative / zero / positive; NaN sorts above +inf (and -NaN below -inf).
    pub const fn total_cmp(self: f32, other: f32) i32 {
        return self.cmp(&other);
    }
    /// Radians to degrees.
    pub const fn to_degrees(self: f32) f32 {
        return self * 57.29577951308232;
    }
    /// Degrees to radians.
    pub const fn to_radians(self: f32) f32 {
        return self * 0.017453292519943295;
    }
}

extend f64 {
    /// The most negative finite value.
    pub const MIN: f64 = -1.7976931348623157e308;
    /// The largest finite value.
    pub const MAX: f64 = 1.7976931348623157e308;
    /// True for any NaN.
    pub const fn is_nan(self: f64) bool {
        return self != self;
    }
    /// True for +inf or -inf.
    pub const fn is_infinite(self: f64) bool {
        return !self.is_nan() && self == 1.0 as f64 / 0.0 as f64 || self == (-1.0) as f64 / 0.0 as f64;
    }
    /// True when neither NaN nor infinite.
    pub const fn is_finite(self: f64) bool {
        return !self.is_nan() && !self.is_infinite();
    }
    /// True when the sign bit is clear (+0.0 and positive NaN included).
    pub const fn is_sign_positive(self: f64) bool {
        return unsafe copysign(1.0, self) > 0.0;
    }
    /// True when the sign bit is set (-0.0 and negative NaN included).
    pub const fn is_sign_negative(self: f64) bool {
        return unsafe copysign(1.0, self) < 0.0;
    }
    /// Absolute value: clears the sign bit (-0.0 gives +0.0, a NaN stays a NaN).
    pub const fn abs(self: f64) f64 {
        return unsafe fabs(self);
    }
    /// 1.0 when the sign bit is clear (+0.0 included), -1.0 when it is set (-0.0 included); NaN stays NaN.
    pub const fn signum(self: f64) f64 {
        if self.is_nan() {
            return self;
        }
        return unsafe copysign(1.0, self);
    }
    /// `self`'s magnitude with `sign`'s sign.
    pub const fn copysign(self: f64, sign: f64) f64 {
        return unsafe copysign(self, sign);
    }
    /// The smaller of the two.
    pub const fn min(self: f64, other: f64) f64 {
        return unsafe fmin(self, other);
    }
    /// The larger of the two.
    pub const fn max(self: f64, other: f64) f64 {
        return unsafe fmax(self, other);
    }
    /// `self` limited to [min, max]; `min` must not exceed `max`.
    pub const fn clamp(self: f64, min: f64, max: f64) f64 {
        if self < min {
            return min;
        }
        if self > max {
            return max;
        }
        return self;
    }
    /// Largest integral value not above `self`.
    pub const fn floor(self: f64) f64 {
        return unsafe floor(self);
    }
    /// Smallest integral value not below `self`.
    pub const fn ceil(self: f64) f64 {
        return unsafe ceil(self);
    }
    /// Nearest integral value, halves away from zero.
    pub const fn round(self: f64) f64 {
        return unsafe round(self);
    }
    /// Integral part, toward zero.
    pub const fn trunc(self: f64) f64 {
        return unsafe trunc(self);
    }
    /// `self - self.trunc()`, with `self`'s sign.
    pub const fn fract(self: f64) f64 {
        return self - unsafe trunc(self);
    }
    /// `1 / self`.
    pub const fn recip(self: f64) f64 {
        return 1.0 / self;
    }
    /// Square root; NaN for a negative value.
    pub const fn sqrt(self: f64) f64 {
        return unsafe sqrt(self);
    }
    /// Cube root (defined for negatives).
    pub const fn cbrt(self: f64) f64 {
        return unsafe cbrt(self);
    }
    /// `self` raised to `n`.
    pub const fn powf(self: f64, n: f64) f64 {
        return unsafe pow(self, n);
    }
    /// `self` raised to the integer `n` (through `pow`).
    pub const fn powi(self: f64, n: i32) f64 {
        return unsafe pow(self, n as f64);
    }
    /// e^self.
    pub const fn exp(self: f64) f64 {
        return unsafe exp(self);
    }
    /// 2^self.
    pub const fn exp2(self: f64) f64 {
        return unsafe exp2(self);
    }
    /// e^self - 1, accurate near zero.
    pub const fn exp_m1(self: f64) f64 {
        return unsafe expm1(self);
    }
    /// Natural logarithm; -inf at 0, NaN below.
    pub const fn ln(self: f64) f64 {
        return unsafe log(self);
    }
    /// Logarithm in `base` (as ln(self) / ln(base)).
    pub const fn log(self: f64, base: f64) f64 {
        return unsafe log(self) / unsafe log(base);
    }
    /// Base-2 logarithm.
    pub const fn log2(self: f64) f64 {
        return unsafe log2(self);
    }
    /// Base-10 logarithm.
    pub const fn log10(self: f64) f64 {
        return unsafe log10(self);
    }
    /// ln(1 + self), accurate near zero.
    pub const fn ln_1p(self: f64) f64 {
        return unsafe log1p(self);
    }
    /// sqrt(self^2 + other^2) without intermediate overflow.
    pub const fn hypot(self: f64, other: f64) f64 {
        return unsafe hypot(self, other);
    }
    /// Sine of an angle in radians.
    pub const fn sin(self: f64) f64 {
        return unsafe sin(self);
    }
    /// Cosine of an angle in radians.
    pub const fn cos(self: f64) f64 {
        return unsafe cos(self);
    }
    /// Tangent of an angle in radians.
    pub const fn tan(self: f64) f64 {
        return unsafe tan(self);
    }
    /// Arc sine in radians; NaN outside [-1, 1].
    pub const fn asin(self: f64) f64 {
        return unsafe asin(self);
    }
    /// Arc cosine in radians; NaN outside [-1, 1].
    pub const fn acos(self: f64) f64 {
        return unsafe acos(self);
    }
    /// Arc tangent in radians.
    pub const fn atan(self: f64) f64 {
        return unsafe atan(self);
    }
    /// Arc tangent of self/other using both signs to pick the quadrant.
    pub const fn atan2(self: f64, other: f64) f64 {
        return unsafe atan2(self, other);
    }
    /// (sin, cos) of an angle in radians.
    pub const fn sin_cos(self: f64) (f64, f64) {
        return unsafe sin(self), unsafe cos(self);
    }
    /// IEEE-754 totalOrder: negative / zero / positive; NaN sorts above +inf (and -NaN below -inf).
    pub const fn total_cmp(self: f64, other: f64) i32 {
        return self.cmp(&other);
    }
    /// Hyperbolic sine.
    pub const fn sinh(self: f64) f64 {
        return unsafe sinh(self);
    }
    /// Hyperbolic cosine.
    pub const fn cosh(self: f64) f64 {
        return unsafe cosh(self);
    }
    /// Hyperbolic tangent.
    pub const fn tanh(self: f64) f64 {
        return unsafe tanh(self);
    }
    /// Inverse hyperbolic sine.
    pub const fn asinh(self: f64) f64 {
        return unsafe asinh(self);
    }
    /// Inverse hyperbolic cosine; NaN below 1.
    pub const fn acosh(self: f64) f64 {
        return unsafe acosh(self);
    }
    /// Inverse hyperbolic tangent; NaN outside [-1, 1].
    pub const fn atanh(self: f64) f64 {
        return unsafe atanh(self);
    }
    /// `self * a + b` with a single rounding.
    pub const fn mul_add(self: f64, a: f64, b: f64) f64 {
        return unsafe fma(self, a, b);
    }
    /// Radians to degrees.
    pub const fn to_degrees(self: f64) f64 {
        return self * 57.29577951308232;
    }
    /// Degrees to radians.
    pub const fn to_radians(self: f64) f64 {
        return self * 0.017453292519943295;
    }
}

/// Move the value out of `slot`, installing `value` in its place: the ownership-safe way to take
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
/// race: it makes interior mutability *expressible*, not automatically safe.
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
        // The value is read out bitwise and the emptied cell is abandoned, so its drop never runs.
        let v = unsafe *self.get();
        forget(self);
        return v;
    }
}

// The overlapping-storage cell `forget` moves its value into: unions never run destructors, so the
// payload is deliberately abandoned. Generic so no per-type cells are needed.
union ForgetCell<T> {
    pub some: T,
    pub none: u8,
}

/// Take ownership of `value` and never free it: the SANCTIONED deliberate leak (tests,
/// process-lifetime singletons, FFI handoffs that outlive the program). The leak tracker
/// (SC_LEAK_CHECK) still reports the abandoned allocations, which is the point: every intentional
/// leak stays visible and greppable instead of being laundered through raw pointers.
pub fn forget<T>(value: T) {
    let cell = ForgetCell::<T> { some: value };
    let _ = (&cell) as *const ForgetCell<T>;
}

/// Non-null, `T`-aligned pointer backed by NO storage: the canonical element pointer for
/// zero-sized-type buffers (`Vector<ZST>`, `Box<ZST>`). It must never be dereferenced for a
/// material `T`, never passed to an allocator, and never assumed unique: distinct zero-sized
/// values may share it.
pub const fn dangling<T>() *mut T {
    return alignof(T) as *mut T;
}

/// What sort of type `type_info::<T>()` described. `Slice` covers `[]T`/`[]mut T`, `Str` is `str`;
/// every other named struct instance (`Vector<T>`, `Box<T>`, user structs) reports `Struct`. `Simd`
/// and `Mask` describe `Simd<T, N>` and `Mask<N>`: `elem` is the lane type's tag (`Bool` for a
/// mask) and `len` the lane count.
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
    Simd,
    Mask,
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
/// compiled program uses; for a union every field reports offset 0. `kind` is the tag of
/// the field's own type (one level: reflect that type itself to go deeper). `meta` holds the
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

    /// True when a `@reflect` entry named `name` is attached.
    pub const fn has_meta(self: &FieldInfo, name: str) bool {
        return self.meta(name).is_some();
    }
}

/// One variant of a reflected enum. `tag` is the value the variant has at runtime: the declared
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

    /// True when a `@reflect` entry named `name` is attached.
    pub const fn has_meta(self: &VariantInfo, name: str) bool {
        return self.meta(name).is_some();
    }
}

/// One method a reflected type declares in an `extend` block: inherent or conformance, `self`
/// receiver or associated. ENUMERATION only: reflection cannot invoke a method (there is no value
/// call path through a descriptor); use the name to document, filter by `meta`, or dispatch by
/// hand. `arity` counts the value parameters with the `self` receiver excluded; `ret` is the
/// one-level tag of the return type (`Void` for none, for several, or for one that has no tag,
/// e.g. an unsubstituted generic). A conformance left fully inherited (`extend T as I {}`)
/// declares no methods, so its defaults are not listed. `meta` holds the declaration's `@reflect`
/// entries, in written order.
pub struct MethodInfo {
    pub name: str<'static>,
    pub arity: usize,
    pub is_pub: bool,
    pub ret: TypeTag,
    pub meta: Slice<'static, MetaInfo>,
}

extend MethodInfo {
    /// The first `@reflect` entry named `name`, or None.
    pub const fn meta(self: &MethodInfo, name: str) Option<MetaInfo> {
        for i in 0..self.meta.len {
            let m = self.meta.get(i);
            if m.name == name {
                return Option::<MetaInfo>::Some(*m);
            }
        }
        return Option::<MetaInfo>::None;
    }

    /// True when a `@reflect` entry named `name` is attached.
    pub const fn has_meta(self: &MethodInfo, name: str) bool {
        return self.meta(name).is_some();
    }
}

/// The result of `type_info::<T>()`, a compiler intrinsic that folds at compile time; there is no
/// declaration of `type_info` anywhere, and the value costs nothing unless it is reached. Fully
/// non-owning: every member is a scalar or a `'static` view into static data, so a `TypeInfo` is
/// never freed and can be stored or passed anywhere. `fields` is empty unless `kind` is
/// `Struct`/`Tuple`/`Union`; `variants` is empty unless `kind` is `Enum`; `elem` is the tag of the
/// pointee/element type for `Pointer`/`Reference`/`Array`/`Slice` (else `Void`); `len` is the
/// element count for `Array` (else 0). `methods` lists every `extend` function declared FOR a
/// decl-backed or builtin type, across all modules, in declaration order.
pub struct TypeInfo {
    pub name: str<'static>,
    pub kind: TypeTag,
    pub elem: TypeTag, // beside `kind`: two 4-byte tags share one 8-byte slot
    pub size: usize,
    pub align: usize,
    pub len: usize,
    pub fields: Slice<'static, FieldInfo>,
    pub variants: Slice<'static, VariantInfo>,
    pub meta: Slice<'static, MetaInfo>,
    pub methods: Slice<'static, MethodInfo>,
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

    /// True when a `@reflect` entry named `name` is attached.
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

    /// The first method named `name`, or None (conformances can declare the same name more than
    /// once; iterate `methods` to see every declaration).
    pub const fn method(self: &TypeInfo, name: str) Option<MethodInfo> {
        for i in 0..self.methods.len {
            let m = self.methods.get(i);
            if m.name == name {
                return Option::<MethodInfo>::Some(*m);
            }
        }
        return Option::<MethodInfo>::None;
    }

    /// The variant whose runtime value is `tag`, or None: the reverse lookup a `Display` for a
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

extend i8 as SimdElement {}
extend i16 as SimdElement {}
extend i32 as SimdElement {}
extend i64 as SimdElement {}
extend u8 as SimdElement {}
extend u16 as SimdElement {}
extend u32 as SimdElement {}
extend u64 as SimdElement {}
extend f32 as SimdElement {}
extend f64 as SimdElement {}
extend i8 as SimdInt {
    type Unsigned = u8;
}
extend i16 as SimdInt {
    type Unsigned = u16;
}
extend i32 as SimdInt {
    type Unsigned = u32;
}
extend i64 as SimdInt {
    type Unsigned = u64;
}
extend u8 as SimdInt {
    type Unsigned = u8;
}
extend u16 as SimdInt {
    type Unsigned = u16;
}
extend u32 as SimdInt {
    type Unsigned = u32;
}
extend u64 as SimdInt {
    type Unsigned = u64;
}
extend i8 as SimdSigned {}
extend i16 as SimdSigned {}
extend i32 as SimdSigned {}
extend i64 as SimdSigned {}
extend f32 as SimdSigned {}
extend f64 as SimdSigned {}
extend f32 as SimdFloat {
    type Bits = u32;
}
extend f64 as SimdFloat {
    type Bits = u64;
}
