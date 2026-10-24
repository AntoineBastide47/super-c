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
//
// The inherent blocks hold the scalar methods under Rust's names, every one a `const fn`: integer bit
// counts, rotations, byte order and byte arrays, powers, roots, logarithms, Euclidean division and the
// wrapping, checked, overflowing and saturating flavors; float encodings, classes, neighbors and the IEEE
// 754-2019 `maximum` and `minimum`; the bool and the char and u8 ASCII methods. A method that uses a plain
// operator traps where the operator does (operations.md); the flavored methods never trap on overflow.
// Each method is O(1), except `pow` (O(log exp) multiplications) and `ilog` (O(log_base self) divisions).

/// Branch hint: this condition is expected to be TRUE. Returns `c` (const-evaluable); the branch that
/// tests the call tells the C compiler (`__builtin_expect(c, 1)`), which then lays out the expected
/// path first and keeps the branch instead of turning it into a select.
@intrinsic("hint.likely")
pub const fn likely(c: bool) bool;

/// Branch hint: this condition is expected to be FALSE (error paths, rare updates such as a new
/// minimum in a scan). See `likely`; the C is `__builtin_expect(c, 0)`.
@intrinsic("hint.unlikely")
pub const fn unlikely(c: bool) bool;

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

    // The runtime traps: print `panic: <msg>` (or `panic: <head><tail>`), abort.
    fn __sc_panic_str(msg: *const u8, len: usize) void;
    fn __sc_panic_str2(head: *const u8, hlen: usize, tail: *const u8, tlen: usize) void;
}

// Bit counts and wrapping arithmetic over a u64 (primitives of the C backend's runtime): the C compiler's
// builtins with the zero input defined as 64, and C's unsigned operators, which wrap in every profile.
// The IR interpreter models these names, so every integer method below evaluates at compile time. The
// methods call no other runtime helper (`sc_bitrev64` has no model): a helper the interpreter or the
// release's runtime header lacks would fail the constant or the bootstrap build.
extern "C" {
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
/// dies via abort(). A `@noreturn` call types as `never`, so a panicking switch/if arm unifies
/// with value-producing siblings (`None => panic("empty")`).
@noreturn
@cold
@no_const
pub fn panic(msg: str) {
    unsafe __sc_panic_str(msg.ptr(), msg.len());
}

/// `panic` with the message `head` then `tail`, built without allocating: a panic site whose
/// message names a type passes the name as `head` (`panic_parts("Vector<T, A>", "[i]: index out of
/// bounds")`).
@noreturn
@cold
@no_const
pub fn panic_parts(head: str, tail: str) {
    unsafe __sc_panic_str2(head.ptr(), head.len(), tail.ptr(), tail.len());
}

// Every power of ten a u64 holds, 10^0 to 10^19: the table of `ilog10_u64`.
const POW10_U64: [u64; 20] = [
    1,
    10,
    100,
    1000,
    10000,
    100000,
    1000000,
    10000000,
    100000000,
    1000000000,
    10000000000,
    100000000000,
    1000000000000,
    10000000000000,
    100000000000000,
    1000000000000000,
    10000000000000000,
    100000000000000000,
    1000000000000000000,
    10000000000000000000,
];

// The floor of log10(x) for x > 0. The bit length times 1233 / 4096 (just below log10(2)) is the result
// or one above it; one table compare decides. The estimate is at most 19, inside the table.
const fn ilog10_u64(x: u64) u32 {
    let t = (64 - x.leading_zeros() as u32) * 1233 >> 12;
    return t - (x < unsafe POW10_U64[t as usize]) as u32;
}

// The floor of log_b(x) for x > 0 and b >= 2: at most 63 divisions.
const fn ilog_u64(x: u64, b: u64) u32 {
    let mut n: u32 = 0;
    let mut r = x;
    while r >= b {
        r /= b;
        n += 1;
    }
    return n;
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
    pub const fn hash_into<H: Hasher>(self: &i8, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &i16, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &i32, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &i64, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &isize, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &u8, h: &mut H) {
        h.write_u64(*self);
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
    pub const fn hash_into<H: Hasher>(self: &u16, h: &mut H) {
        h.write_u64(*self);
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
    pub const fn hash_into<H: Hasher>(self: &u32, h: &mut H) {
        h.write_u64(*self);
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
    pub const fn hash_into<H: Hasher>(self: &u64, h: &mut H) {
        h.write_u64(*self);
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
    pub const fn hash_into<H: Hasher>(self: &usize, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &char, h: &mut H) {
        h.write_u64((*self) as u64);
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
    pub const fn hash_into<H: Hasher>(self: &bool, h: &mut H) {
        h.write_u64((*self) as u64);
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

const fn f32_total_key(x: f32) u32 {
    let b = F32Bits { f: x };
    if b.u >> 31 == 1 {
        return b.u ^ 0xFFFF_FFFFu32;
    }
    return b.u ^ 0x8000_0000u32;
}

const fn f64_total_key(x: f64) u64 {
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
    /// The total-order key `Eq` compares, so equal values hash alike.
    pub const fn hash_into<H: Hasher>(self: &f32, h: &mut H) {
        h.write_u64(f32_total_key(*self));
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
    /// The total-order key `Eq` compares, so equal values hash alike.
    pub const fn hash_into<H: Hasher>(self: &f64, h: &mut H) {
        h.write_u64(f64_total_key(*self));
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
    /// The width in bits.
    pub const BITS: u32 = 8;
    /// Zero bits below the lowest set bit of the two's complement pattern (8 for zero).
    pub const fn trailing_zeros(self: i8) usize {
        return (self as u8).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (8 for zero).
    pub const fn leading_zeros(self: i8) usize {
        return (self as u8).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub const fn count_ones(self: i8) usize {
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
    pub const fn wrapping_add(self: i8, rhs: i8) i8 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i8;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: i8, rhs: i8) i8 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i8;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: i8, rhs: i8) i8 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i8;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_neg(self: i8) i8 {
        return (unsafe sc_wsub64(0, self as u64)) as i8;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: i8, n: u32) i8 {
        return (unsafe sc_wshl64(self as u64, n & 7)) as i8;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub const fn wrapping_shr(self: i8, n: u32) i8 {
        return (unsafe sc_wsar64(self, n & 7)) as i8;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: i8, rhs: i8) (i8, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: i8, rhs: i8) (i8, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: i8, rhs: i8) (i8, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i8;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: i8, rhs: i8) Option<i8> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub const fn checked_neg(self: i8) Option<i8> {
        if self == -128 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: i8, n: u32) Option<i8> {
        if n >= 8 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: i8, n: u32) Option<i8> {
        if n >= 8 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub const fn saturating_add(self: i8, rhs: i8) i8 {
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
    pub const fn saturating_sub(self: i8, rhs: i8) i8 {
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
    pub const fn saturating_mul(self: i8, rhs: i8) i8 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -128;
        }
        return 127;
    }
    /// Number of clear bits in the two's complement pattern.
    pub const fn count_zeros(self: i8) usize {
        return (self as u8).count_zeros();
    }
    /// One bits above the highest clear bit of the two's complement pattern (the width for -1).
    pub const fn leading_ones(self: i8) usize {
        return (self as u8).leading_ones();
    }
    /// One bits below the lowest clear bit of the two's complement pattern (the width for -1).
    pub const fn trailing_ones(self: i8) usize {
        return (self as u8).trailing_ones();
    }
    /// The two's complement bits rotated toward the high end by `n % N`.
    pub const fn rotate_left(self: i8, n: u32) i8 {
        return (self as u8).rotate_left(n) as i8;
    }
    /// The two's complement bits rotated toward the low end by `n % N`.
    pub const fn rotate_right(self: i8, n: u32) i8 {
        return (self as u8).rotate_right(n) as i8;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: i8) i8 {
        return (self as u8).swap_bytes() as i8;
    }
    /// The two's complement bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: i8) i8 {
        return (self as u8).reverse_bits() as i8;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: i8) i8 {
        return (self as u8).to_be() as i8;
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: i8) i8 {
        return (self as u8).to_le() as i8;
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: i8) i8 {
        return (x as u8).to_be() as i8;
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: i8) i8 {
        return (x as u8).to_le() as i8;
    }
    /// The two's complement bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: i8) [u8; 1] {
        return (self as u8).to_be_bytes();
    }
    /// The two's complement bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: i8) [u8; 1] {
        return (self as u8).to_le_bytes();
    }
    /// The two's complement bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: i8) [u8; 1] {
        return (self as u8).to_ne_bytes();
    }
    /// The value of the two's complement bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 1]) i8 {
        return u8::from_be_bytes(b) as i8;
    }
    /// The value of the two's complement bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 1]) i8 {
        return u8::from_le_bytes(b) as i8;
    }
    /// The value of the two's complement bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 1]) i8 {
        return u8::from_ne_bytes(b) as i8;
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: i8, exp: u32) i8 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: i8 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root. Panics when `self` is negative.
    pub const fn isqrt(self: i8) i8 {
        if self < 0 {
            panic("argument of integer square root cannot be negative");
        }
        return (self as u8).isqrt() as i8;
    }
    /// The floor of log2(self). Panics when `self` is not positive.
    pub const fn ilog2(self: i8) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return (self as u8).ilog2();
    }
    /// The floor of log10(self). Panics when `self` is not positive.
    pub const fn ilog10(self: i8) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is not
    /// positive.
    pub const fn ilog(self: i8, base: i8) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|` as a `u8`: exact for every pair.
    pub const fn abs_diff(self: i8, other: i8) u8 {
        if self < other {
            return (other as u8).wrapping_sub(self as u8);
        }
        return (self as u8).wrapping_sub(other as u8);
    }
    /// `|self|` as a `u8`: exact for MIN too.
    pub const fn unsigned_abs(self: i8) u8 {
        return self.wrapping_abs() as u8;
    }
    /// `(self + rhs) / 2` rounded toward zero, without overflow.
    pub const fn midpoint(self: i8, rhs: i8) i8 {
        let floor = (self & rhs) + ((self ^ rhs) >> 1);
        if floor < 0 && ((self ^ rhs) & 1) == 1 {
            return floor + 1;
        }
        return floor;
    }
    /// The Euclidean quotient: the `q` with `self == q * rhs + r` and `0 <= r < |rhs|`. Traps on a zero
    /// divisor and on MIN / -1.
    pub const fn div_euclid(self: i8, rhs: i8) i8 {
        let q = self / rhs;
        if self % rhs < 0 {
            if rhs > 0 {
                return q - 1;
            }
            return q + 1;
        }
        return q;
    }
    /// The Euclidean remainder, in `[0, |rhs|)`. Traps on a zero divisor and on MIN % -1.
    pub const fn rem_euclid(self: i8, rhs: i8) i8 {
        let r = self % rhs;
        if r < 0 {
            return r.wrapping_add(rhs.wrapping_abs());
        }
        return r;
    }
    /// The same bits as a `u8`: negative values become large.
    pub const fn cast_unsigned(self: i8) u8 {
        return self as u8;
    }
    /// `self / rhs`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div(self: i8, rhs: i8) i8 {
        if self == -128 && rhs == -1 {
            return -128;
        }
        return self / rhs;
    }
    /// `self % rhs`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem(self: i8, rhs: i8) i8 {
        if rhs == -1 {
            return 0;
        }
        return self % rhs;
    }
    /// `self.div_euclid(rhs)`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: i8, rhs: i8) i8 {
        if self == -128 && rhs == -1 {
            return -128;
        }
        return self.div_euclid(rhs);
    }
    /// `self.rem_euclid(rhs)`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: i8, rhs: i8) i8 {
        if rhs == -1 {
            return 0;
        }
        return self.rem_euclid(rhs);
    }
    /// `|self|` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_abs(self: i8) i8 {
        if self < 0 {
            return self.wrapping_neg();
        }
        return self;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: i8, exp: u32) i8 {
        return (self as u8).wrapping_pow(exp) as i8;
    }
    /// `-self` modulo 2^N and whether `self` is MIN.
    pub const fn overflowing_neg(self: i8) (i8, bool) {
        return self.wrapping_neg(), self == -128;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: i8, n: u32) (i8, bool) {
        return self.wrapping_shl(n), n >= 8;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: i8, n: u32) (i8, bool) {
        return self.wrapping_shr(n), n >= 8;
    }
    /// `self.wrapping_div(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div(self: i8, rhs: i8) (i8, bool) {
        if self == -128 && rhs == -1 {
            return self, true;
        }
        return self / rhs, false;
    }
    /// `self.wrapping_rem(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem(self: i8, rhs: i8) (i8, bool) {
        if rhs == -1 {
            return 0, self == -128;
        }
        return self % rhs, false;
    }
    /// `self.wrapping_div_euclid(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: i8, rhs: i8) (i8, bool) {
        if self == -128 && rhs == -1 {
            return self, true;
        }
        return self.div_euclid(rhs), false;
    }
    /// `self.wrapping_rem_euclid(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: i8, rhs: i8) (i8, bool) {
        if rhs == -1 {
            return 0, self == -128;
        }
        return self.rem_euclid(rhs), false;
    }
    /// `self.wrapping_abs()` and whether `self` is MIN.
    pub const fn overflowing_abs(self: i8) (i8, bool) {
        return self.wrapping_abs(), self == -128;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: i8, exp: u32) (i8, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: i8 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `|self|`, or None for MIN.
    pub const fn checked_abs(self: i8) Option<i8> {
        if self == -128 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.wrapping_abs());
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: i8, exp: u32) Option<i8> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(r);
    }
    /// The floor of the square root, or None when `self` is negative.
    pub const fn checked_isqrt(self: i8) Option<i8> {
        if self < 0 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some((self as u8).isqrt() as i8);
    }
    /// The floor of log2(self), or None when `self` is not positive.
    pub const fn checked_ilog2(self: i8) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some((self as u8).ilog2());
    }
    /// The floor of log10(self), or None when `self` is not positive.
    pub const fn checked_ilog10(self: i8) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is not
    /// positive.
    pub const fn checked_ilog(self: i8, base: i8) Option<u32> {
        if base < 2 || self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self.div_euclid(rhs)`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div_euclid(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.div_euclid(rhs));
    }
    /// `self.rem_euclid(rhs)`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem_euclid(self: i8, rhs: i8) Option<i8> {
        if rhs == 0 || self == -128 && rhs == -1 {
            return Option::<i8>::None;
        }
        return Option::<i8>::Some(self.rem_euclid(rhs));
    }
    /// `-self`, with MIN giving MAX.
    pub const fn saturating_neg(self: i8) i8 {
        if self == -128 {
            return 127;
        }
        return -self;
    }
    /// `|self|`, with MIN giving MAX.
    pub const fn saturating_abs(self: i8) i8 {
        if self == -128 {
            return 127;
        }
        return self.wrapping_abs();
    }
    /// `self / rhs`, with MIN / -1 giving MAX. Traps on a zero divisor.
    pub const fn saturating_div(self: i8, rhs: i8) i8 {
        if self == -128 && rhs == -1 {
            return 127;
        }
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to [MIN, MAX].
    pub const fn saturating_pow(self: i8, exp: u32) i8 {
        let (r, o) = self.overflowing_pow(exp);
        if !o {
            return r;
        }
        if self < 0 && (exp & 1) == 1 {
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
    /// The width in bits.
    pub const BITS: u32 = 16;
    /// Zero bits below the lowest set bit of the two's complement pattern (16 for zero).
    pub const fn trailing_zeros(self: i16) usize {
        return (self as u16).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (16 for zero).
    pub const fn leading_zeros(self: i16) usize {
        return (self as u16).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub const fn count_ones(self: i16) usize {
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
    pub const fn wrapping_add(self: i16, rhs: i16) i16 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i16;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: i16, rhs: i16) i16 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i16;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: i16, rhs: i16) i16 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i16;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_neg(self: i16) i16 {
        return (unsafe sc_wsub64(0, self as u64)) as i16;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: i16, n: u32) i16 {
        return (unsafe sc_wshl64(self as u64, n & 15)) as i16;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub const fn wrapping_shr(self: i16, n: u32) i16 {
        return (unsafe sc_wsar64(self, n & 15)) as i16;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: i16, rhs: i16) (i16, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: i16, rhs: i16) (i16, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: i16, rhs: i16) (i16, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i16;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: i16, rhs: i16) Option<i16> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub const fn checked_neg(self: i16) Option<i16> {
        if self == -32768 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: i16, n: u32) Option<i16> {
        if n >= 16 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: i16, n: u32) Option<i16> {
        if n >= 16 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub const fn saturating_add(self: i16, rhs: i16) i16 {
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
    pub const fn saturating_sub(self: i16, rhs: i16) i16 {
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
    pub const fn saturating_mul(self: i16, rhs: i16) i16 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -32768;
        }
        return 32767;
    }
    /// Number of clear bits in the two's complement pattern.
    pub const fn count_zeros(self: i16) usize {
        return (self as u16).count_zeros();
    }
    /// One bits above the highest clear bit of the two's complement pattern (the width for -1).
    pub const fn leading_ones(self: i16) usize {
        return (self as u16).leading_ones();
    }
    /// One bits below the lowest clear bit of the two's complement pattern (the width for -1).
    pub const fn trailing_ones(self: i16) usize {
        return (self as u16).trailing_ones();
    }
    /// The two's complement bits rotated toward the high end by `n % N`.
    pub const fn rotate_left(self: i16, n: u32) i16 {
        return (self as u16).rotate_left(n) as i16;
    }
    /// The two's complement bits rotated toward the low end by `n % N`.
    pub const fn rotate_right(self: i16, n: u32) i16 {
        return (self as u16).rotate_right(n) as i16;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: i16) i16 {
        return (self as u16).swap_bytes() as i16;
    }
    /// The two's complement bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: i16) i16 {
        return (self as u16).reverse_bits() as i16;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: i16) i16 {
        return (self as u16).to_be() as i16;
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: i16) i16 {
        return (self as u16).to_le() as i16;
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: i16) i16 {
        return (x as u16).to_be() as i16;
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: i16) i16 {
        return (x as u16).to_le() as i16;
    }
    /// The two's complement bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: i16) [u8; 2] {
        return (self as u16).to_be_bytes();
    }
    /// The two's complement bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: i16) [u8; 2] {
        return (self as u16).to_le_bytes();
    }
    /// The two's complement bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: i16) [u8; 2] {
        return (self as u16).to_ne_bytes();
    }
    /// The value of the two's complement bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 2]) i16 {
        return u16::from_be_bytes(b) as i16;
    }
    /// The value of the two's complement bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 2]) i16 {
        return u16::from_le_bytes(b) as i16;
    }
    /// The value of the two's complement bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 2]) i16 {
        return u16::from_ne_bytes(b) as i16;
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: i16, exp: u32) i16 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: i16 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root. Panics when `self` is negative.
    pub const fn isqrt(self: i16) i16 {
        if self < 0 {
            panic("argument of integer square root cannot be negative");
        }
        return (self as u16).isqrt() as i16;
    }
    /// The floor of log2(self). Panics when `self` is not positive.
    pub const fn ilog2(self: i16) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return (self as u16).ilog2();
    }
    /// The floor of log10(self). Panics when `self` is not positive.
    pub const fn ilog10(self: i16) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is not
    /// positive.
    pub const fn ilog(self: i16, base: i16) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|` as a `u16`: exact for every pair.
    pub const fn abs_diff(self: i16, other: i16) u16 {
        if self < other {
            return (other as u16).wrapping_sub(self as u16);
        }
        return (self as u16).wrapping_sub(other as u16);
    }
    /// `|self|` as a `u16`: exact for MIN too.
    pub const fn unsigned_abs(self: i16) u16 {
        return self.wrapping_abs() as u16;
    }
    /// `(self + rhs) / 2` rounded toward zero, without overflow.
    pub const fn midpoint(self: i16, rhs: i16) i16 {
        let floor = (self & rhs) + ((self ^ rhs) >> 1);
        if floor < 0 && ((self ^ rhs) & 1) == 1 {
            return floor + 1;
        }
        return floor;
    }
    /// The Euclidean quotient: the `q` with `self == q * rhs + r` and `0 <= r < |rhs|`. Traps on a zero
    /// divisor and on MIN / -1.
    pub const fn div_euclid(self: i16, rhs: i16) i16 {
        let q = self / rhs;
        if self % rhs < 0 {
            if rhs > 0 {
                return q - 1;
            }
            return q + 1;
        }
        return q;
    }
    /// The Euclidean remainder, in `[0, |rhs|)`. Traps on a zero divisor and on MIN % -1.
    pub const fn rem_euclid(self: i16, rhs: i16) i16 {
        let r = self % rhs;
        if r < 0 {
            return r.wrapping_add(rhs.wrapping_abs());
        }
        return r;
    }
    /// The same bits as a `u16`: negative values become large.
    pub const fn cast_unsigned(self: i16) u16 {
        return self as u16;
    }
    /// `self / rhs`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div(self: i16, rhs: i16) i16 {
        if self == -32768 && rhs == -1 {
            return -32768;
        }
        return self / rhs;
    }
    /// `self % rhs`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem(self: i16, rhs: i16) i16 {
        if rhs == -1 {
            return 0;
        }
        return self % rhs;
    }
    /// `self.div_euclid(rhs)`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: i16, rhs: i16) i16 {
        if self == -32768 && rhs == -1 {
            return -32768;
        }
        return self.div_euclid(rhs);
    }
    /// `self.rem_euclid(rhs)`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: i16, rhs: i16) i16 {
        if rhs == -1 {
            return 0;
        }
        return self.rem_euclid(rhs);
    }
    /// `|self|` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_abs(self: i16) i16 {
        if self < 0 {
            return self.wrapping_neg();
        }
        return self;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: i16, exp: u32) i16 {
        return (self as u16).wrapping_pow(exp) as i16;
    }
    /// `-self` modulo 2^N and whether `self` is MIN.
    pub const fn overflowing_neg(self: i16) (i16, bool) {
        return self.wrapping_neg(), self == -32768;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: i16, n: u32) (i16, bool) {
        return self.wrapping_shl(n), n >= 16;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: i16, n: u32) (i16, bool) {
        return self.wrapping_shr(n), n >= 16;
    }
    /// `self.wrapping_div(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div(self: i16, rhs: i16) (i16, bool) {
        if self == -32768 && rhs == -1 {
            return self, true;
        }
        return self / rhs, false;
    }
    /// `self.wrapping_rem(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem(self: i16, rhs: i16) (i16, bool) {
        if rhs == -1 {
            return 0, self == -32768;
        }
        return self % rhs, false;
    }
    /// `self.wrapping_div_euclid(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: i16, rhs: i16) (i16, bool) {
        if self == -32768 && rhs == -1 {
            return self, true;
        }
        return self.div_euclid(rhs), false;
    }
    /// `self.wrapping_rem_euclid(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: i16, rhs: i16) (i16, bool) {
        if rhs == -1 {
            return 0, self == -32768;
        }
        return self.rem_euclid(rhs), false;
    }
    /// `self.wrapping_abs()` and whether `self` is MIN.
    pub const fn overflowing_abs(self: i16) (i16, bool) {
        return self.wrapping_abs(), self == -32768;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: i16, exp: u32) (i16, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: i16 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `|self|`, or None for MIN.
    pub const fn checked_abs(self: i16) Option<i16> {
        if self == -32768 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.wrapping_abs());
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: i16, exp: u32) Option<i16> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(r);
    }
    /// The floor of the square root, or None when `self` is negative.
    pub const fn checked_isqrt(self: i16) Option<i16> {
        if self < 0 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some((self as u16).isqrt() as i16);
    }
    /// The floor of log2(self), or None when `self` is not positive.
    pub const fn checked_ilog2(self: i16) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some((self as u16).ilog2());
    }
    /// The floor of log10(self), or None when `self` is not positive.
    pub const fn checked_ilog10(self: i16) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is not
    /// positive.
    pub const fn checked_ilog(self: i16, base: i16) Option<u32> {
        if base < 2 || self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self.div_euclid(rhs)`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div_euclid(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.div_euclid(rhs));
    }
    /// `self.rem_euclid(rhs)`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem_euclid(self: i16, rhs: i16) Option<i16> {
        if rhs == 0 || self == -32768 && rhs == -1 {
            return Option::<i16>::None;
        }
        return Option::<i16>::Some(self.rem_euclid(rhs));
    }
    /// `-self`, with MIN giving MAX.
    pub const fn saturating_neg(self: i16) i16 {
        if self == -32768 {
            return 32767;
        }
        return -self;
    }
    /// `|self|`, with MIN giving MAX.
    pub const fn saturating_abs(self: i16) i16 {
        if self == -32768 {
            return 32767;
        }
        return self.wrapping_abs();
    }
    /// `self / rhs`, with MIN / -1 giving MAX. Traps on a zero divisor.
    pub const fn saturating_div(self: i16, rhs: i16) i16 {
        if self == -32768 && rhs == -1 {
            return 32767;
        }
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to [MIN, MAX].
    pub const fn saturating_pow(self: i16, exp: u32) i16 {
        let (r, o) = self.overflowing_pow(exp);
        if !o {
            return r;
        }
        if self < 0 && (exp & 1) == 1 {
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
    /// The width in bits.
    pub const BITS: u32 = 32;
    /// Zero bits below the lowest set bit of the two's complement pattern (32 for zero).
    pub const fn trailing_zeros(self: i32) usize {
        return (self as u32).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (32 for zero).
    pub const fn leading_zeros(self: i32) usize {
        return (self as u32).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub const fn count_ones(self: i32) usize {
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
    pub const fn wrapping_add(self: i32, rhs: i32) i32 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i32;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: i32, rhs: i32) i32 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i32;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: i32, rhs: i32) i32 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i32;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_neg(self: i32) i32 {
        return (unsafe sc_wsub64(0, self as u64)) as i32;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: i32, n: u32) i32 {
        return (unsafe sc_wshl64(self as u64, n & 31)) as i32;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub const fn wrapping_shr(self: i32, n: u32) i32 {
        return (unsafe sc_wsar64(self, n & 31)) as i32;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: i32, rhs: i32) (i32, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: i32, rhs: i32) (i32, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: i32, rhs: i32) (i32, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64; // exact: the operands are narrow
        let r = p as i32;
        return r, r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: i32, rhs: i32) Option<i32> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub const fn checked_neg(self: i32) Option<i32> {
        if self == -2147483648 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: i32, n: u32) Option<i32> {
        if n >= 32 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: i32, n: u32) Option<i32> {
        if n >= 32 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub const fn saturating_add(self: i32, rhs: i32) i32 {
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
    pub const fn saturating_sub(self: i32, rhs: i32) i32 {
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
    pub const fn saturating_mul(self: i32, rhs: i32) i32 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -2147483648;
        }
        return 2147483647;
    }
    /// Number of clear bits in the two's complement pattern.
    pub const fn count_zeros(self: i32) usize {
        return (self as u32).count_zeros();
    }
    /// One bits above the highest clear bit of the two's complement pattern (the width for -1).
    pub const fn leading_ones(self: i32) usize {
        return (self as u32).leading_ones();
    }
    /// One bits below the lowest clear bit of the two's complement pattern (the width for -1).
    pub const fn trailing_ones(self: i32) usize {
        return (self as u32).trailing_ones();
    }
    /// The two's complement bits rotated toward the high end by `n % N`.
    pub const fn rotate_left(self: i32, n: u32) i32 {
        return (self as u32).rotate_left(n) as i32;
    }
    /// The two's complement bits rotated toward the low end by `n % N`.
    pub const fn rotate_right(self: i32, n: u32) i32 {
        return (self as u32).rotate_right(n) as i32;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: i32) i32 {
        return (self as u32).swap_bytes() as i32;
    }
    /// The two's complement bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: i32) i32 {
        return (self as u32).reverse_bits() as i32;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: i32) i32 {
        return (self as u32).to_be() as i32;
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: i32) i32 {
        return (self as u32).to_le() as i32;
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: i32) i32 {
        return (x as u32).to_be() as i32;
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: i32) i32 {
        return (x as u32).to_le() as i32;
    }
    /// The two's complement bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: i32) [u8; 4] {
        return (self as u32).to_be_bytes();
    }
    /// The two's complement bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: i32) [u8; 4] {
        return (self as u32).to_le_bytes();
    }
    /// The two's complement bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: i32) [u8; 4] {
        return (self as u32).to_ne_bytes();
    }
    /// The value of the two's complement bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 4]) i32 {
        return u32::from_be_bytes(b) as i32;
    }
    /// The value of the two's complement bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 4]) i32 {
        return u32::from_le_bytes(b) as i32;
    }
    /// The value of the two's complement bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 4]) i32 {
        return u32::from_ne_bytes(b) as i32;
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: i32, exp: u32) i32 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: i32 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root. Panics when `self` is negative.
    pub const fn isqrt(self: i32) i32 {
        if self < 0 {
            panic("argument of integer square root cannot be negative");
        }
        return (self as u32).isqrt() as i32;
    }
    /// The floor of log2(self). Panics when `self` is not positive.
    pub const fn ilog2(self: i32) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return (self as u32).ilog2();
    }
    /// The floor of log10(self). Panics when `self` is not positive.
    pub const fn ilog10(self: i32) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is not
    /// positive.
    pub const fn ilog(self: i32, base: i32) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|` as a `u32`: exact for every pair.
    pub const fn abs_diff(self: i32, other: i32) u32 {
        if self < other {
            return (other as u32).wrapping_sub(self as u32);
        }
        return (self as u32).wrapping_sub(other as u32);
    }
    /// `|self|` as a `u32`: exact for MIN too.
    pub const fn unsigned_abs(self: i32) u32 {
        return self.wrapping_abs() as u32;
    }
    /// `(self + rhs) / 2` rounded toward zero, without overflow.
    pub const fn midpoint(self: i32, rhs: i32) i32 {
        let floor = (self & rhs) + ((self ^ rhs) >> 1);
        if floor < 0 && ((self ^ rhs) & 1) == 1 {
            return floor + 1;
        }
        return floor;
    }
    /// The Euclidean quotient: the `q` with `self == q * rhs + r` and `0 <= r < |rhs|`. Traps on a zero
    /// divisor and on MIN / -1.
    pub const fn div_euclid(self: i32, rhs: i32) i32 {
        let q = self / rhs;
        if self % rhs < 0 {
            if rhs > 0 {
                return q - 1;
            }
            return q + 1;
        }
        return q;
    }
    /// The Euclidean remainder, in `[0, |rhs|)`. Traps on a zero divisor and on MIN % -1.
    pub const fn rem_euclid(self: i32, rhs: i32) i32 {
        let r = self % rhs;
        if r < 0 {
            return r.wrapping_add(rhs.wrapping_abs());
        }
        return r;
    }
    /// The same bits as a `u32`: negative values become large.
    pub const fn cast_unsigned(self: i32) u32 {
        return self as u32;
    }
    /// `self / rhs`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div(self: i32, rhs: i32) i32 {
        if self == -2147483648 && rhs == -1 {
            return -2147483648;
        }
        return self / rhs;
    }
    /// `self % rhs`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem(self: i32, rhs: i32) i32 {
        if rhs == -1 {
            return 0;
        }
        return self % rhs;
    }
    /// `self.div_euclid(rhs)`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: i32, rhs: i32) i32 {
        if self == -2147483648 && rhs == -1 {
            return -2147483648;
        }
        return self.div_euclid(rhs);
    }
    /// `self.rem_euclid(rhs)`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: i32, rhs: i32) i32 {
        if rhs == -1 {
            return 0;
        }
        return self.rem_euclid(rhs);
    }
    /// `|self|` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_abs(self: i32) i32 {
        if self < 0 {
            return self.wrapping_neg();
        }
        return self;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: i32, exp: u32) i32 {
        return (self as u32).wrapping_pow(exp) as i32;
    }
    /// `-self` modulo 2^N and whether `self` is MIN.
    pub const fn overflowing_neg(self: i32) (i32, bool) {
        return self.wrapping_neg(), self == -2147483648;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: i32, n: u32) (i32, bool) {
        return self.wrapping_shl(n), n >= 32;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: i32, n: u32) (i32, bool) {
        return self.wrapping_shr(n), n >= 32;
    }
    /// `self.wrapping_div(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div(self: i32, rhs: i32) (i32, bool) {
        if self == -2147483648 && rhs == -1 {
            return self, true;
        }
        return self / rhs, false;
    }
    /// `self.wrapping_rem(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem(self: i32, rhs: i32) (i32, bool) {
        if rhs == -1 {
            return 0, self == -2147483648;
        }
        return self % rhs, false;
    }
    /// `self.wrapping_div_euclid(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: i32, rhs: i32) (i32, bool) {
        if self == -2147483648 && rhs == -1 {
            return self, true;
        }
        return self.div_euclid(rhs), false;
    }
    /// `self.wrapping_rem_euclid(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: i32, rhs: i32) (i32, bool) {
        if rhs == -1 {
            return 0, self == -2147483648;
        }
        return self.rem_euclid(rhs), false;
    }
    /// `self.wrapping_abs()` and whether `self` is MIN.
    pub const fn overflowing_abs(self: i32) (i32, bool) {
        return self.wrapping_abs(), self == -2147483648;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: i32, exp: u32) (i32, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: i32 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `|self|`, or None for MIN.
    pub const fn checked_abs(self: i32) Option<i32> {
        if self == -2147483648 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.wrapping_abs());
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: i32, exp: u32) Option<i32> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(r);
    }
    /// The floor of the square root, or None when `self` is negative.
    pub const fn checked_isqrt(self: i32) Option<i32> {
        if self < 0 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some((self as u32).isqrt() as i32);
    }
    /// The floor of log2(self), or None when `self` is not positive.
    pub const fn checked_ilog2(self: i32) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some((self as u32).ilog2());
    }
    /// The floor of log10(self), or None when `self` is not positive.
    pub const fn checked_ilog10(self: i32) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is not
    /// positive.
    pub const fn checked_ilog(self: i32, base: i32) Option<u32> {
        if base < 2 || self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self.div_euclid(rhs)`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div_euclid(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.div_euclid(rhs));
    }
    /// `self.rem_euclid(rhs)`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem_euclid(self: i32, rhs: i32) Option<i32> {
        if rhs == 0 || self == -2147483648 && rhs == -1 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.rem_euclid(rhs));
    }
    /// `-self`, with MIN giving MAX.
    pub const fn saturating_neg(self: i32) i32 {
        if self == -2147483648 {
            return 2147483647;
        }
        return -self;
    }
    /// `|self|`, with MIN giving MAX.
    pub const fn saturating_abs(self: i32) i32 {
        if self == -2147483648 {
            return 2147483647;
        }
        return self.wrapping_abs();
    }
    /// `self / rhs`, with MIN / -1 giving MAX. Traps on a zero divisor.
    pub const fn saturating_div(self: i32, rhs: i32) i32 {
        if self == -2147483648 && rhs == -1 {
            return 2147483647;
        }
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to [MIN, MAX].
    pub const fn saturating_pow(self: i32, exp: u32) i32 {
        let (r, o) = self.overflowing_pow(exp);
        if !o {
            return r;
        }
        if self < 0 && (exp & 1) == 1 {
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
    /// The width in bits.
    pub const BITS: u32 = 64;
    /// Zero bits below the lowest set bit of the two's complement pattern (64 for zero).
    pub const fn trailing_zeros(self: i64) usize {
        return (self as u64).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (64 for zero).
    pub const fn leading_zeros(self: i64) usize {
        return (self as u64).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub const fn count_ones(self: i64) usize {
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
    pub const fn wrapping_add(self: i64, rhs: i64) i64 {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as i64;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: i64, rhs: i64) i64 {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as i64;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: i64, rhs: i64) i64 {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as i64;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_neg(self: i64) i64 {
        return (unsafe sc_wsub64(0, self as u64)) as i64;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: i64, n: u32) i64 {
        return (unsafe sc_wshl64(self as u64, n & 63)) as i64;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub const fn wrapping_shr(self: i64, n: u32) i64 {
        return unsafe sc_wsar64(self, n & 63);
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: i64, rhs: i64) (i64, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: i64, rhs: i64) (i64, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: i64, rhs: i64) (i64, bool) {
        return self.wrapping_mul(rhs), unsafe sc_mulo_i64(self, rhs);
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: i64, rhs: i64) Option<i64> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub const fn checked_neg(self: i64) Option<i64> {
        if self == -9223372036854775807 - 1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: i64, n: u32) Option<i64> {
        if n >= 64 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: i64, n: u32) Option<i64> {
        if n >= 64 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub const fn saturating_add(self: i64, rhs: i64) i64 {
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
    pub const fn saturating_sub(self: i64, rhs: i64) i64 {
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
    pub const fn saturating_mul(self: i64, rhs: i64) i64 {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -9223372036854775807 - 1;
        }
        return 9223372036854775807;
    }
    /// Number of clear bits in the two's complement pattern.
    pub const fn count_zeros(self: i64) usize {
        return (self as u64).count_zeros();
    }
    /// One bits above the highest clear bit of the two's complement pattern (the width for -1).
    pub const fn leading_ones(self: i64) usize {
        return (self as u64).leading_ones();
    }
    /// One bits below the lowest clear bit of the two's complement pattern (the width for -1).
    pub const fn trailing_ones(self: i64) usize {
        return (self as u64).trailing_ones();
    }
    /// The two's complement bits rotated toward the high end by `n % N`.
    pub const fn rotate_left(self: i64, n: u32) i64 {
        return (self as u64).rotate_left(n) as i64;
    }
    /// The two's complement bits rotated toward the low end by `n % N`.
    pub const fn rotate_right(self: i64, n: u32) i64 {
        return (self as u64).rotate_right(n) as i64;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: i64) i64 {
        return (self as u64).swap_bytes() as i64;
    }
    /// The two's complement bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: i64) i64 {
        return (self as u64).reverse_bits() as i64;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: i64) i64 {
        return (self as u64).to_be() as i64;
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: i64) i64 {
        return (self as u64).to_le() as i64;
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: i64) i64 {
        return (x as u64).to_be() as i64;
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: i64) i64 {
        return (x as u64).to_le() as i64;
    }
    /// The two's complement bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: i64) [u8; 8] {
        return (self as u64).to_be_bytes();
    }
    /// The two's complement bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: i64) [u8; 8] {
        return (self as u64).to_le_bytes();
    }
    /// The two's complement bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: i64) [u8; 8] {
        return (self as u64).to_ne_bytes();
    }
    /// The value of the two's complement bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 8]) i64 {
        return u64::from_be_bytes(b) as i64;
    }
    /// The value of the two's complement bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 8]) i64 {
        return u64::from_le_bytes(b) as i64;
    }
    /// The value of the two's complement bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 8]) i64 {
        return u64::from_ne_bytes(b) as i64;
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: i64, exp: u32) i64 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: i64 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root. Panics when `self` is negative.
    pub const fn isqrt(self: i64) i64 {
        if self < 0 {
            panic("argument of integer square root cannot be negative");
        }
        return (self as u64).isqrt() as i64;
    }
    /// The floor of log2(self). Panics when `self` is not positive.
    pub const fn ilog2(self: i64) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return (self as u64).ilog2();
    }
    /// The floor of log10(self). Panics when `self` is not positive.
    pub const fn ilog10(self: i64) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is not
    /// positive.
    pub const fn ilog(self: i64, base: i64) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|` as a `u64`: exact for every pair.
    pub const fn abs_diff(self: i64, other: i64) u64 {
        if self < other {
            return (other as u64).wrapping_sub(self as u64);
        }
        return (self as u64).wrapping_sub(other as u64);
    }
    /// `|self|` as a `u64`: exact for MIN too.
    pub const fn unsigned_abs(self: i64) u64 {
        return self.wrapping_abs() as u64;
    }
    /// `(self + rhs) / 2` rounded toward zero, without overflow.
    pub const fn midpoint(self: i64, rhs: i64) i64 {
        let floor = (self & rhs) + ((self ^ rhs) >> 1);
        if floor < 0 && ((self ^ rhs) & 1) == 1 {
            return floor + 1;
        }
        return floor;
    }
    /// The Euclidean quotient: the `q` with `self == q * rhs + r` and `0 <= r < |rhs|`. Traps on a zero
    /// divisor and on MIN / -1.
    pub const fn div_euclid(self: i64, rhs: i64) i64 {
        let q = self / rhs;
        if self % rhs < 0 {
            if rhs > 0 {
                return q - 1;
            }
            return q + 1;
        }
        return q;
    }
    /// The Euclidean remainder, in `[0, |rhs|)`. Traps on a zero divisor and on MIN % -1.
    pub const fn rem_euclid(self: i64, rhs: i64) i64 {
        let r = self % rhs;
        if r < 0 {
            return r.wrapping_add(rhs.wrapping_abs());
        }
        return r;
    }
    /// The same bits as a `u64`: negative values become large.
    pub const fn cast_unsigned(self: i64) u64 {
        return self as u64;
    }
    /// `self / rhs`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div(self: i64, rhs: i64) i64 {
        if self == -9223372036854775807 - 1 && rhs == -1 {
            return -9223372036854775807 - 1;
        }
        return self / rhs;
    }
    /// `self % rhs`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem(self: i64, rhs: i64) i64 {
        if rhs == -1 {
            return 0;
        }
        return self % rhs;
    }
    /// `self.div_euclid(rhs)`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: i64, rhs: i64) i64 {
        if self == -9223372036854775807 - 1 && rhs == -1 {
            return -9223372036854775807 - 1;
        }
        return self.div_euclid(rhs);
    }
    /// `self.rem_euclid(rhs)`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: i64, rhs: i64) i64 {
        if rhs == -1 {
            return 0;
        }
        return self.rem_euclid(rhs);
    }
    /// `|self|` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_abs(self: i64) i64 {
        if self < 0 {
            return self.wrapping_neg();
        }
        return self;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: i64, exp: u32) i64 {
        return (self as u64).wrapping_pow(exp) as i64;
    }
    /// `-self` modulo 2^N and whether `self` is MIN.
    pub const fn overflowing_neg(self: i64) (i64, bool) {
        return self.wrapping_neg(), self == -9223372036854775807 - 1;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: i64, n: u32) (i64, bool) {
        return self.wrapping_shl(n), n >= 64;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: i64, n: u32) (i64, bool) {
        return self.wrapping_shr(n), n >= 64;
    }
    /// `self.wrapping_div(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div(self: i64, rhs: i64) (i64, bool) {
        if self == -9223372036854775807 - 1 && rhs == -1 {
            return self, true;
        }
        return self / rhs, false;
    }
    /// `self.wrapping_rem(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem(self: i64, rhs: i64) (i64, bool) {
        if rhs == -1 {
            return 0, self == -9223372036854775807 - 1;
        }
        return self % rhs, false;
    }
    /// `self.wrapping_div_euclid(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: i64, rhs: i64) (i64, bool) {
        if self == -9223372036854775807 - 1 && rhs == -1 {
            return self, true;
        }
        return self.div_euclid(rhs), false;
    }
    /// `self.wrapping_rem_euclid(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: i64, rhs: i64) (i64, bool) {
        if rhs == -1 {
            return 0, self == -9223372036854775807 - 1;
        }
        return self.rem_euclid(rhs), false;
    }
    /// `self.wrapping_abs()` and whether `self` is MIN.
    pub const fn overflowing_abs(self: i64) (i64, bool) {
        return self.wrapping_abs(), self == -9223372036854775807 - 1;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: i64, exp: u32) (i64, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: i64 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `|self|`, or None for MIN.
    pub const fn checked_abs(self: i64) Option<i64> {
        if self == -9223372036854775807 - 1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.wrapping_abs());
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: i64, exp: u32) Option<i64> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(r);
    }
    /// The floor of the square root, or None when `self` is negative.
    pub const fn checked_isqrt(self: i64) Option<i64> {
        if self < 0 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some((self as u64).isqrt() as i64);
    }
    /// The floor of log2(self), or None when `self` is not positive.
    pub const fn checked_ilog2(self: i64) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some((self as u64).ilog2());
    }
    /// The floor of log10(self), or None when `self` is not positive.
    pub const fn checked_ilog10(self: i64) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is not
    /// positive.
    pub const fn checked_ilog(self: i64, base: i64) Option<u32> {
        if base < 2 || self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self.div_euclid(rhs)`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div_euclid(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.div_euclid(rhs));
    }
    /// `self.rem_euclid(rhs)`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem_euclid(self: i64, rhs: i64) Option<i64> {
        if rhs == 0 || self == -9223372036854775807 - 1 && rhs == -1 {
            return Option::<i64>::None;
        }
        return Option::<i64>::Some(self.rem_euclid(rhs));
    }
    /// `-self`, with MIN giving MAX.
    pub const fn saturating_neg(self: i64) i64 {
        if self == -9223372036854775807 - 1 {
            return 9223372036854775807;
        }
        return -self;
    }
    /// `|self|`, with MIN giving MAX.
    pub const fn saturating_abs(self: i64) i64 {
        if self == -9223372036854775807 - 1 {
            return 9223372036854775807;
        }
        return self.wrapping_abs();
    }
    /// `self / rhs`, with MIN / -1 giving MAX. Traps on a zero divisor.
    pub const fn saturating_div(self: i64, rhs: i64) i64 {
        if self == -9223372036854775807 - 1 && rhs == -1 {
            return 9223372036854775807;
        }
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to [MIN, MAX].
    pub const fn saturating_pow(self: i64, exp: u32) i64 {
        let (r, o) = self.overflowing_pow(exp);
        if !o {
            return r;
        }
        if self < 0 && (exp & 1) == 1 {
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
    /// The width in bits.
    pub const BITS: u32 = usize::BITS;
    /// Zero bits below the lowest set bit of the two's complement pattern (the width for zero).
    pub const fn trailing_zeros(self: isize) usize {
        return (self as usize).trailing_zeros();
    }
    /// Zero bits above the highest set bit of the two's complement pattern (the width for zero).
    pub const fn leading_zeros(self: isize) usize {
        return (self as usize).leading_zeros();
    }
    /// Number of set bits in the two's complement pattern.
    pub const fn count_ones(self: isize) usize {
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
    pub const fn wrapping_add(self: isize, rhs: isize) isize {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as isize;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: isize, rhs: isize) isize {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as isize;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: isize, rhs: isize) isize {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as isize;
    }
    /// `-self` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_neg(self: isize) isize {
        return (unsafe sc_wsub64(0, self as u64)) as isize;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: isize, n: u32) isize {
        return (unsafe sc_wshl64(self as u64, n & sizeof(isize) as u32 * 8 - 1)) as isize;
    }
    /// `self >> (n % N)`, arithmetic: the count wraps at the width.
    pub const fn wrapping_shr(self: isize, n: u32) isize {
        return (unsafe sc_wsar64(self as i64, n & sizeof(isize) as u32 * 8 - 1)) as isize;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: isize, rhs: isize) (isize, bool) {
        let r = self.wrapping_add(rhs);
        return r, ((self ^ r) & (rhs ^ r)) < 0;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: isize, rhs: isize) (isize, bool) {
        let r = self.wrapping_sub(rhs);
        return r, ((self ^ rhs) & (self ^ r)) < 0;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: isize, rhs: isize) (isize, bool) {
        let p = (unsafe sc_wmul64(self as u64, rhs as u64)) as i64;
        let r = p as isize;
        return r, unsafe sc_mulo_i64(self as i64, rhs as i64) || r as i64 != p;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: isize, rhs: isize) Option<isize> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self % rhs);
    }
    /// `-self`, or None for MIN.
    pub const fn checked_neg(self: isize) Option<isize> {
        if self == -((~0usize >> 1) as isize) - 1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_neg());
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: isize, n: u32) Option<isize> {
        if n >= sizeof(isize) as u32 * 8 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: isize, n: u32) Option<isize> {
        if n >= sizeof(isize) as u32 * 8 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to [MIN, MAX].
    pub const fn saturating_add(self: isize, rhs: isize) isize {
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
    pub const fn saturating_sub(self: isize, rhs: isize) isize {
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
    pub const fn saturating_mul(self: isize, rhs: isize) isize {
        let (r, o) = self.overflowing_mul(rhs);
        if !o {
            return r;
        }
        if (self ^ rhs) < 0 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return (~0usize >> 1) as isize;
    }
    /// Number of clear bits in the two's complement pattern.
    pub const fn count_zeros(self: isize) usize {
        return (self as usize).count_zeros();
    }
    /// One bits above the highest clear bit of the two's complement pattern (the width for -1).
    pub const fn leading_ones(self: isize) usize {
        return (self as usize).leading_ones();
    }
    /// One bits below the lowest clear bit of the two's complement pattern (the width for -1).
    pub const fn trailing_ones(self: isize) usize {
        return (self as usize).trailing_ones();
    }
    /// The two's complement bits rotated toward the high end by `n % N`.
    pub const fn rotate_left(self: isize, n: u32) isize {
        return (self as usize).rotate_left(n) as isize;
    }
    /// The two's complement bits rotated toward the low end by `n % N`.
    pub const fn rotate_right(self: isize, n: u32) isize {
        return (self as usize).rotate_right(n) as isize;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: isize) isize {
        return (self as usize).swap_bytes() as isize;
    }
    /// The two's complement bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: isize) isize {
        return (self as usize).reverse_bits() as isize;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: isize) isize {
        return (self as usize).to_be() as isize;
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: isize) isize {
        return (self as usize).to_le() as isize;
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: isize) isize {
        return (x as usize).to_be() as isize;
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: isize) isize {
        return (x as usize).to_le() as isize;
    }
    /// The two's complement bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: isize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_be_bytes();
        } else {
            return (self as u64).to_be_bytes();
        }
    }
    /// The two's complement bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: isize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_le_bytes();
        } else {
            return (self as u64).to_le_bytes();
        }
    }
    /// The two's complement bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: isize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_ne_bytes();
        } else {
            return (self as u64).to_ne_bytes();
        }
    }
    /// The value of the two's complement bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; sizeof(usize)]) isize {
        if POINTER_WIDTH == 32 {
            return u32::from_be_bytes(b) as isize;
        } else {
            return u64::from_be_bytes(b) as isize;
        }
    }
    /// The value of the two's complement bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; sizeof(usize)]) isize {
        if POINTER_WIDTH == 32 {
            return u32::from_le_bytes(b) as isize;
        } else {
            return u64::from_le_bytes(b) as isize;
        }
    }
    /// The value of the two's complement bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; sizeof(usize)]) isize {
        if POINTER_WIDTH == 32 {
            return u32::from_ne_bytes(b) as isize;
        } else {
            return u64::from_ne_bytes(b) as isize;
        }
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: isize, exp: u32) isize {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: isize = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root. Panics when `self` is negative.
    pub const fn isqrt(self: isize) isize {
        if self < 0 {
            panic("argument of integer square root cannot be negative");
        }
        return (self as usize).isqrt() as isize;
    }
    /// The floor of log2(self). Panics when `self` is not positive.
    pub const fn ilog2(self: isize) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return (self as usize).ilog2();
    }
    /// The floor of log10(self). Panics when `self` is not positive.
    pub const fn ilog10(self: isize) u32 {
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is not
    /// positive.
    pub const fn ilog(self: isize, base: isize) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self <= 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|` as a `usize`: exact for every pair.
    pub const fn abs_diff(self: isize, other: isize) usize {
        if self < other {
            return (other as usize).wrapping_sub(self as usize);
        }
        return (self as usize).wrapping_sub(other as usize);
    }
    /// `|self|` as a `usize`: exact for MIN too.
    pub const fn unsigned_abs(self: isize) usize {
        return self.wrapping_abs() as usize;
    }
    /// `(self + rhs) / 2` rounded toward zero, without overflow.
    pub const fn midpoint(self: isize, rhs: isize) isize {
        let floor = (self & rhs) + ((self ^ rhs) >> 1);
        if floor < 0 && ((self ^ rhs) & 1) == 1 {
            return floor + 1;
        }
        return floor;
    }
    /// The Euclidean quotient: the `q` with `self == q * rhs + r` and `0 <= r < |rhs|`. Traps on a zero
    /// divisor and on MIN / -1.
    pub const fn div_euclid(self: isize, rhs: isize) isize {
        let q = self / rhs;
        if self % rhs < 0 {
            if rhs > 0 {
                return q - 1;
            }
            return q + 1;
        }
        return q;
    }
    /// The Euclidean remainder, in `[0, |rhs|)`. Traps on a zero divisor and on MIN % -1.
    pub const fn rem_euclid(self: isize, rhs: isize) isize {
        let r = self % rhs;
        if r < 0 {
            return r.wrapping_add(rhs.wrapping_abs());
        }
        return r;
    }
    /// The same bits as a `usize`: negative values become large.
    pub const fn cast_unsigned(self: isize) usize {
        return self as usize;
    }
    /// `self / rhs`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div(self: isize, rhs: isize) isize {
        if self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return self / rhs;
    }
    /// `self % rhs`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem(self: isize, rhs: isize) isize {
        if rhs == -1 {
            return 0;
        }
        return self % rhs;
    }
    /// `self.div_euclid(rhs)`, with MIN / -1 giving MIN. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: isize, rhs: isize) isize {
        if self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return -((~0usize >> 1) as isize) - 1;
        }
        return self.div_euclid(rhs);
    }
    /// `self.rem_euclid(rhs)`, with MIN % -1 giving 0. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: isize, rhs: isize) isize {
        if rhs == -1 {
            return 0;
        }
        return self.rem_euclid(rhs);
    }
    /// `|self|` modulo 2^N (MIN stays MIN).
    pub const fn wrapping_abs(self: isize) isize {
        if self < 0 {
            return self.wrapping_neg();
        }
        return self;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: isize, exp: u32) isize {
        return (self as usize).wrapping_pow(exp) as isize;
    }
    /// `-self` modulo 2^N and whether `self` is MIN.
    pub const fn overflowing_neg(self: isize) (isize, bool) {
        return self.wrapping_neg(), self == -((~0usize >> 1) as isize) - 1;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: isize, n: u32) (isize, bool) {
        return self.wrapping_shl(n), n >= sizeof(usize) as u32 * 8;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: isize, n: u32) (isize, bool) {
        return self.wrapping_shr(n), n >= sizeof(usize) as u32 * 8;
    }
    /// `self.wrapping_div(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div(self: isize, rhs: isize) (isize, bool) {
        if self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return self, true;
        }
        return self / rhs, false;
    }
    /// `self.wrapping_rem(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem(self: isize, rhs: isize) (isize, bool) {
        if rhs == -1 {
            return 0, self == -((~0usize >> 1) as isize) - 1;
        }
        return self % rhs, false;
    }
    /// `self.wrapping_div_euclid(rhs)` and whether it is MIN / -1. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: isize, rhs: isize) (isize, bool) {
        if self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return self, true;
        }
        return self.div_euclid(rhs), false;
    }
    /// `self.wrapping_rem_euclid(rhs)` and whether it is MIN % -1. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: isize, rhs: isize) (isize, bool) {
        if rhs == -1 {
            return 0, self == -((~0usize >> 1) as isize) - 1;
        }
        return self.rem_euclid(rhs), false;
    }
    /// `self.wrapping_abs()` and whether `self` is MIN.
    pub const fn overflowing_abs(self: isize) (isize, bool) {
        return self.wrapping_abs(), self == -((~0usize >> 1) as isize) - 1;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: isize, exp: u32) (isize, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: isize = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `|self|`, or None for MIN.
    pub const fn checked_abs(self: isize) Option<isize> {
        if self == -((~0usize >> 1) as isize) - 1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.wrapping_abs());
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: isize, exp: u32) Option<isize> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(r);
    }
    /// The floor of the square root, or None when `self` is negative.
    pub const fn checked_isqrt(self: isize) Option<isize> {
        if self < 0 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some((self as usize).isqrt() as isize);
    }
    /// The floor of log2(self), or None when `self` is not positive.
    pub const fn checked_ilog2(self: isize) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some((self as usize).ilog2());
    }
    /// The floor of log10(self), or None when `self` is not positive.
    pub const fn checked_ilog10(self: isize) Option<u32> {
        if self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is not
    /// positive.
    pub const fn checked_ilog(self: isize, base: isize) Option<u32> {
        if base < 2 || self <= 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self.div_euclid(rhs)`, or None for a zero divisor or MIN / -1.
    pub const fn checked_div_euclid(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.div_euclid(rhs));
    }
    /// `self.rem_euclid(rhs)`, or None for a zero divisor or MIN % -1.
    pub const fn checked_rem_euclid(self: isize, rhs: isize) Option<isize> {
        if rhs == 0 || self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return Option::<isize>::None;
        }
        return Option::<isize>::Some(self.rem_euclid(rhs));
    }
    /// `-self`, with MIN giving MAX.
    pub const fn saturating_neg(self: isize) isize {
        if self == -((~0usize >> 1) as isize) - 1 {
            return (~0usize >> 1) as isize;
        }
        return -self;
    }
    /// `|self|`, with MIN giving MAX.
    pub const fn saturating_abs(self: isize) isize {
        if self == -((~0usize >> 1) as isize) - 1 {
            return (~0usize >> 1) as isize;
        }
        return self.wrapping_abs();
    }
    /// `self / rhs`, with MIN / -1 giving MAX. Traps on a zero divisor.
    pub const fn saturating_div(self: isize, rhs: isize) isize {
        if self == -((~0usize >> 1) as isize) - 1 && rhs == -1 {
            return (~0usize >> 1) as isize;
        }
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to [MIN, MAX].
    pub const fn saturating_pow(self: isize, exp: u32) isize {
        let (r, o) = self.overflowing_pow(exp);
        if !o {
            return r;
        }
        if self < 0 && (exp & 1) == 1 {
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
    /// The width in bits.
    pub const BITS: u32 = 8;
    /// Zero bits below the lowest set bit (8 for zero).
    pub const fn trailing_zeros(self: u8) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 8)) as usize; // bit 8 set: a zero counts 8
    }
    /// Zero bits above the highest set bit (8 for zero).
    pub const fn leading_zeros(self: u8) usize {
        return (unsafe sc_clz64(self)) as usize - 56;
    }
    /// Number of set bits.
    pub const fn count_ones(self: u8) usize {
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
    pub const fn wrapping_add(self: u8, rhs: u8) u8 {
        return (unsafe sc_wadd64(self, rhs)) as u8;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: u8, rhs: u8) u8 {
        return (unsafe sc_wsub64(self, rhs)) as u8;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: u8, rhs: u8) u8 {
        return (unsafe sc_wmul64(self, rhs)) as u8;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub const fn wrapping_neg(self: u8) u8 {
        return (unsafe sc_wsub64(0, self)) as u8;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: u8, n: u32) u8 {
        return (unsafe sc_wshl64(self, n & 7)) as u8;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub const fn wrapping_shr(self: u8, n: u32) u8 {
        return (unsafe sc_wshr64(self, n & 7)) as u8;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: u8, rhs: u8) (u8, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: u8, rhs: u8) (u8, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: u8, rhs: u8) (u8, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u8, p > 255;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: u8, rhs: u8) Option<u8> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div(self: u8, rhs: u8) Option<u8> {
        if rhs == 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem(self: u8, rhs: u8) Option<u8> {
        if rhs == 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub const fn checked_neg(self: u8) Option<u8> {
        if self != 0 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: u8, n: u32) Option<u8> {
        if n >= 8 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: u8, n: u32) Option<u8> {
        if n >= 8 {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub const fn saturating_add(self: u8, rhs: u8) u8 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 255;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub const fn saturating_sub(self: u8, rhs: u8) u8 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub const fn saturating_mul(self: u8, rhs: u8) u8 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 255;
        }
        return r;
    }
    /// Number of clear bits.
    pub const fn count_zeros(self: u8) usize {
        return (~self).count_ones();
    }
    /// One bits above the highest clear bit (the width for MAX).
    pub const fn leading_ones(self: u8) usize {
        return (~self).leading_zeros();
    }
    /// One bits below the lowest clear bit (the width for MAX).
    pub const fn trailing_ones(self: u8) usize {
        return (~self).trailing_zeros();
    }
    /// The bits rotated toward the high end by `n % N`: the bits shifted out enter at the low end.
    pub const fn rotate_left(self: u8, n: u32) u8 {
        let k = (n & 7) as u8;
        return self << k | self >> (8 - k & 7);
    }
    /// The bits rotated toward the low end by `n % N`: the bits shifted out enter at the high end.
    pub const fn rotate_right(self: u8, n: u32) u8 {
        let k = (n & 7) as u8;
        return self >> k | self << (8 - k & 7);
    }
    /// The bytes in reverse order: `self` for a single byte.
    pub const fn swap_bytes(self: u8) u8 {
        return self;
    }
    /// The bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: u8) u8 {
        let mut x = self >> 4 | self << 4;
        x = x >> 2 & 0x33 | (x & 0x33) << 2;
        return x >> 1 & 0x55 | (x & 0x55) << 1;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: u8) u8 {
        if ENDIAN == Endian::Big {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: u8) u8 {
        if ENDIAN == Endian::Little {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: u8) u8 {
        return x.to_be();
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: u8) u8 {
        return x.to_le();
    }
    /// The bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: u8) [u8; 1] {
        return [self];
    }
    /// The bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: u8) [u8; 1] {
        return [self];
    }
    /// The bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: u8) [u8; 1] {
        if ENDIAN == Endian::Big {
            return self.to_be_bytes();
        } else {
            return self.to_le_bytes();
        }
    }
    /// The value of the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 1]) u8 {
        return b[0];
    }
    /// The value of the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 1]) u8 {
        return b[0];
    }
    /// The value of the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 1]) u8 {
        if ENDIAN == Endian::Big {
            return u8::from_be_bytes(b);
        } else {
            return u8::from_le_bytes(b);
        }
    }
    /// The smallest power of two not below `self` (1 for 0). Above the largest power of two it traps
    /// with overflow checks and gives 0 without.
    pub const fn next_power_of_two(self: u8) u8 {
        if self <= 1 {
            return 1;
        }
        return (255 >> (self - 1).leading_zeros() as u8) + 1;
    }
    /// The smallest power of two not below `self` (1 for 0), or None when it does not fit.
    pub const fn checked_next_power_of_two(self: u8) Option<u8> {
        if self <= 1 {
            return Option::<u8>::Some(1);
        }
        return (255u8 >> (self - 1).leading_zeros() as u8).checked_add(1);
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: u8, exp: u32) u8 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u8 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root.
    pub const fn isqrt(self: u8) u8 {
        return (self as u32).isqrt() as u8;
    }
    /// The floor of log2(self). Panics when `self` is 0.
    pub const fn ilog2(self: u8) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return 7 - self.leading_zeros() as u32;
    }
    /// The floor of log10(self). Panics when `self` is 0.
    pub const fn ilog10(self: u8) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is 0.
    pub const fn ilog(self: u8, base: u8) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self, base);
    }
    /// `|self - other|`.
    pub const fn abs_diff(self: u8, other: u8) u8 {
        if self < other {
            return other - self;
        }
        return self - other;
    }
    /// `(self + rhs) / 2` rounded down, without overflow.
    pub const fn midpoint(self: u8, rhs: u8) u8 {
        return (self & rhs) + ((self ^ rhs) >> 1);
    }
    /// `self / rhs` rounded up. Traps on a zero divisor.
    pub const fn div_ceil(self: u8, rhs: u8) u8 {
        let q = self / rhs;
        if self % rhs > 0 {
            return q + 1;
        }
        return q;
    }
    /// The smallest multiple of `rhs` not below `self`. Traps on a zero `rhs`; overflow traps with
    /// overflow checks and wraps without.
    pub const fn next_multiple_of(self: u8, rhs: u8) u8 {
        let r = self % rhs;
        if r == 0 {
            return self;
        }
        return self + (rhs - r);
    }
    /// The smallest multiple of `rhs` not below `self`, or None for a zero `rhs` or on overflow.
    pub const fn checked_next_multiple_of(self: u8, rhs: u8) Option<u8> {
        if rhs == 0 {
            return Option::<u8>::None;
        }
        let r = self % rhs;
        if r == 0 {
            return Option::<u8>::Some(self);
        }
        return self.checked_add(rhs - r);
    }
    /// True when `self` is a multiple of `rhs`; for a zero `rhs`, only 0 is.
    pub const fn is_multiple_of(self: u8, rhs: u8) bool {
        if rhs == 0 {
            return self == 0;
        }
        return self % rhs == 0;
    }
    /// `self / rhs`: unsigned division is already Euclidean. Traps on a zero divisor.
    pub const fn div_euclid(self: u8, rhs: u8) u8 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder is already Euclidean. Traps on a zero divisor.
    pub const fn rem_euclid(self: u8, rhs: u8) u8 {
        return self % rhs;
    }
    /// The same bits as a `i8`: values above `127` become negative.
    pub const fn cast_signed(self: u8) i8 {
        return self as i8;
    }
    /// `self / rhs`: unsigned division never wraps. Traps on a zero divisor.
    pub const fn wrapping_div(self: u8, rhs: u8) u8 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder never wraps. Traps on a zero divisor.
    pub const fn wrapping_rem(self: u8, rhs: u8) u8 {
        return self % rhs;
    }
    /// `self / rhs`. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: u8, rhs: u8) u8 {
        return self / rhs;
    }
    /// `self % rhs`. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: u8, rhs: u8) u8 {
        return self % rhs;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: u8, exp: u32) u8 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u8 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc.wrapping_mul(base);
            }
            e = e >> 1;
            base = base.wrapping_mul(base);
        }
        return acc.wrapping_mul(base);
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`.
    pub const fn wrapping_add_signed(self: u8, rhs: i8) u8 {
        return self.wrapping_add(rhs as u8);
    }
    /// `0 - self` modulo 2^N and whether `self` is nonzero.
    pub const fn overflowing_neg(self: u8) (u8, bool) {
        return self.wrapping_neg(), self != 0;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: u8, n: u32) (u8, bool) {
        return self.wrapping_shl(n), n >= 8;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: u8, n: u32) (u8, bool) {
        return self.wrapping_shr(n), n >= 8;
    }
    /// `self / rhs` and false: unsigned division never overflows. Traps on a zero divisor.
    pub const fn overflowing_div(self: u8, rhs: u8) (u8, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false: unsigned remainder never overflows. Traps on a zero divisor.
    pub const fn overflowing_rem(self: u8, rhs: u8) (u8, bool) {
        return self % rhs, false;
    }
    /// `self / rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: u8, rhs: u8) (u8, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: u8, rhs: u8) (u8, bool) {
        return self % rhs, false;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: u8, exp: u32) (u8, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: u8 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`, and whether the exact sum leaves [0, MAX].
    pub const fn overflowing_add_signed(self: u8, rhs: i8) (u8, bool) {
        let (r, o) = self.overflowing_add(rhs as u8);
        return r, o != rhs < 0;
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: u8, exp: u32) Option<u8> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// The floor of log2(self), or None for 0.
    pub const fn checked_ilog2(self: u8) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.ilog2());
    }
    /// The floor of log10(self), or None for 0.
    pub const fn checked_ilog10(self: u8) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is 0.
    pub const fn checked_ilog(self: u8, base: u8) Option<u32> {
        if base < 2 || self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self, base));
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div_euclid(self: u8, rhs: u8) Option<u8> {
        return self.checked_div(rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem_euclid(self: u8, rhs: u8) Option<u8> {
        return self.checked_rem(rhs);
    }
    /// `self + rhs` for a signed `rhs`, or None when the sum leaves [0, MAX].
    pub const fn checked_add_signed(self: u8, rhs: i8) Option<u8> {
        let (r, o) = self.overflowing_add_signed(rhs);
        if o {
            return Option::<u8>::None;
        }
        return Option::<u8>::Some(r);
    }
    /// `self / rhs`: unsigned division never saturates. Traps on a zero divisor.
    pub const fn saturating_div(self: u8, rhs: u8) u8 {
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to MAX.
    pub const fn saturating_pow(self: u8, exp: u32) u8 {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return 255;
        }
        return r;
    }
    /// `self + rhs` for a signed `rhs`, clamped to [0, MAX].
    pub const fn saturating_add_signed(self: u8, rhs: i8) u8 {
        let (r, o) = self.overflowing_add(rhs as u8);
        if o == rhs < 0 {
            return r;
        }
        if o {
            return 255;
        }
        return 0;
    }
    /// True for an ASCII byte: 0x00 to 0x7F.
    pub const fn is_ascii(self: u8) bool {
        return self < 0x80;
    }
    /// True for `A` to `Z` and `a` to `z`.
    pub const fn is_ascii_alphabetic(self: u8) bool {
        return self.is_ascii_uppercase() || self.is_ascii_lowercase();
    }
    /// True for `A` to `Z`.
    pub const fn is_ascii_uppercase(self: u8) bool {
        return self >= b'A' && self <= b'Z';
    }
    /// True for `a` to `z`.
    pub const fn is_ascii_lowercase(self: u8) bool {
        return self >= b'a' && self <= b'z';
    }
    /// True for `0` to `9`, `A` to `Z` and `a` to `z`.
    pub const fn is_ascii_alphanumeric(self: u8) bool {
        return self.is_ascii_digit() || self.is_ascii_alphabetic();
    }
    /// True for `0` to `9`.
    pub const fn is_ascii_digit(self: u8) bool {
        return self >= b'0' && self <= b'9';
    }
    /// True for `0` to `9`, `A` to `F` and `a` to `f`.
    pub const fn is_ascii_hexdigit(self: u8) bool {
        return self.is_ascii_digit() || self >= b'A' && self <= b'F' || self >= b'a' && self <= b'f';
    }
    /// True for the graphic ASCII bytes that are not alphanumeric: `!` to `/`, `:` to `@`, `[` to 0x60
    /// and `{` to `~`.
    pub const fn is_ascii_punctuation(self: u8) bool {
        return self.is_ascii_graphic() && !self.is_ascii_alphanumeric();
    }
    /// True for the visible ASCII bytes: `!` (0x21) to `~` (0x7E).
    pub const fn is_ascii_graphic(self: u8) bool {
        return self >= 0x21 && self <= 0x7E;
    }
    /// True for space, tab, line feed, form feed and carriage return; not vertical tab (the WHATWG set).
    pub const fn is_ascii_whitespace(self: u8) bool {
        return self == b' ' || self == b'\t' || self == b'\n' || self == 0x0C || self == b'\r';
    }
    /// True for the ASCII control bytes: 0x00 to 0x1F and 0x7F.
    pub const fn is_ascii_control(self: u8) bool {
        return self < 0x20 || self == 0x7F;
    }
    /// `self` with `a` to `z` mapped to `A` to `Z`; every other byte unchanged.
    pub const fn to_ascii_uppercase(self: u8) u8 {
        return self ^ self.is_ascii_lowercase() as u8 << 5;
    }
    /// `self` with `A` to `Z` mapped to `a` to `z`; every other byte unchanged.
    pub const fn to_ascii_lowercase(self: u8) u8 {
        return self ^ self.is_ascii_uppercase() as u8 << 5;
    }
    /// True when `self` and `other` are equal after `to_ascii_lowercase`.
    pub const fn eq_ignore_ascii_case(self: u8, other: u8) bool {
        return self.to_ascii_lowercase() == other.to_ascii_lowercase();
    }
}

extend u16 {
    /// The smallest value.
    pub const MIN: u16 = 0;
    /// The largest value.
    pub const MAX: u16 = 65535;
    /// The width in bits.
    pub const BITS: u32 = 16;
    /// Zero bits below the lowest set bit (16 for zero).
    pub const fn trailing_zeros(self: u16) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 16)) as usize; // bit 16 set: a zero counts 16
    }
    /// Zero bits above the highest set bit (16 for zero).
    pub const fn leading_zeros(self: u16) usize {
        return (unsafe sc_clz64(self)) as usize - 48;
    }
    /// Number of set bits.
    pub const fn count_ones(self: u16) usize {
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
    pub const fn wrapping_add(self: u16, rhs: u16) u16 {
        return (unsafe sc_wadd64(self, rhs)) as u16;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: u16, rhs: u16) u16 {
        return (unsafe sc_wsub64(self, rhs)) as u16;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: u16, rhs: u16) u16 {
        return (unsafe sc_wmul64(self, rhs)) as u16;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub const fn wrapping_neg(self: u16) u16 {
        return (unsafe sc_wsub64(0, self)) as u16;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: u16, n: u32) u16 {
        return (unsafe sc_wshl64(self, n & 15)) as u16;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub const fn wrapping_shr(self: u16, n: u32) u16 {
        return (unsafe sc_wshr64(self, n & 15)) as u16;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: u16, rhs: u16) (u16, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: u16, rhs: u16) (u16, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: u16, rhs: u16) (u16, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u16, p > 65535;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: u16, rhs: u16) Option<u16> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div(self: u16, rhs: u16) Option<u16> {
        if rhs == 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem(self: u16, rhs: u16) Option<u16> {
        if rhs == 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub const fn checked_neg(self: u16) Option<u16> {
        if self != 0 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: u16, n: u32) Option<u16> {
        if n >= 16 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: u16, n: u32) Option<u16> {
        if n >= 16 {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub const fn saturating_add(self: u16, rhs: u16) u16 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 65535;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub const fn saturating_sub(self: u16, rhs: u16) u16 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub const fn saturating_mul(self: u16, rhs: u16) u16 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 65535;
        }
        return r;
    }
    /// Number of clear bits.
    pub const fn count_zeros(self: u16) usize {
        return (~self).count_ones();
    }
    /// One bits above the highest clear bit (the width for MAX).
    pub const fn leading_ones(self: u16) usize {
        return (~self).leading_zeros();
    }
    /// One bits below the lowest clear bit (the width for MAX).
    pub const fn trailing_ones(self: u16) usize {
        return (~self).trailing_zeros();
    }
    /// The bits rotated toward the high end by `n % N`: the bits shifted out enter at the low end.
    pub const fn rotate_left(self: u16, n: u32) u16 {
        let k = (n & 15) as u16;
        return self << k | self >> (16 - k & 15);
    }
    /// The bits rotated toward the low end by `n % N`: the bits shifted out enter at the high end.
    pub const fn rotate_right(self: u16, n: u32) u16 {
        let k = (n & 15) as u16;
        return self >> k | self << (16 - k & 15);
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: u16) u16 {
        return self << 8 | self >> 8;
    }
    /// The bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: u16) u16 {
        let mut x = self.swap_bytes();
        x = x >> 4 & 0x0F0F | (x & 0x0F0F) << 4;
        x = x >> 2 & 0x3333 | (x & 0x3333) << 2;
        return x >> 1 & 0x5555 | (x & 0x5555) << 1;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: u16) u16 {
        if ENDIAN == Endian::Big {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: u16) u16 {
        if ENDIAN == Endian::Little {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: u16) u16 {
        return x.to_be();
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: u16) u16 {
        return x.to_le();
    }
    /// The bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: u16) [u8; 2] {
        return [(self >> 8) as u8, self as u8];
    }
    /// The bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: u16) [u8; 2] {
        return [self as u8, (self >> 8) as u8];
    }
    /// The bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: u16) [u8; 2] {
        if ENDIAN == Endian::Big {
            return self.to_be_bytes();
        } else {
            return self.to_le_bytes();
        }
    }
    /// The value of the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 2]) u16 {
        return b[0] as u16 << 8 | b[1] as u16;
    }
    /// The value of the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 2]) u16 {
        return b[0] as u16 | b[1] as u16 << 8;
    }
    /// The value of the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 2]) u16 {
        if ENDIAN == Endian::Big {
            return u16::from_be_bytes(b);
        } else {
            return u16::from_le_bytes(b);
        }
    }
    /// The smallest power of two not below `self` (1 for 0). Above the largest power of two it traps
    /// with overflow checks and gives 0 without.
    pub const fn next_power_of_two(self: u16) u16 {
        if self <= 1 {
            return 1;
        }
        return (65535 >> (self - 1).leading_zeros() as u16) + 1;
    }
    /// The smallest power of two not below `self` (1 for 0), or None when it does not fit.
    pub const fn checked_next_power_of_two(self: u16) Option<u16> {
        if self <= 1 {
            return Option::<u16>::Some(1);
        }
        return (65535u16 >> (self - 1).leading_zeros() as u16).checked_add(1);
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: u16, exp: u32) u16 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u16 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root.
    pub const fn isqrt(self: u16) u16 {
        return (self as u32).isqrt() as u16;
    }
    /// The floor of log2(self). Panics when `self` is 0.
    pub const fn ilog2(self: u16) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return 15 - self.leading_zeros() as u32;
    }
    /// The floor of log10(self). Panics when `self` is 0.
    pub const fn ilog10(self: u16) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is 0.
    pub const fn ilog(self: u16, base: u16) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self, base);
    }
    /// `|self - other|`.
    pub const fn abs_diff(self: u16, other: u16) u16 {
        if self < other {
            return other - self;
        }
        return self - other;
    }
    /// `(self + rhs) / 2` rounded down, without overflow.
    pub const fn midpoint(self: u16, rhs: u16) u16 {
        return (self & rhs) + ((self ^ rhs) >> 1);
    }
    /// `self / rhs` rounded up. Traps on a zero divisor.
    pub const fn div_ceil(self: u16, rhs: u16) u16 {
        let q = self / rhs;
        if self % rhs > 0 {
            return q + 1;
        }
        return q;
    }
    /// The smallest multiple of `rhs` not below `self`. Traps on a zero `rhs`; overflow traps with
    /// overflow checks and wraps without.
    pub const fn next_multiple_of(self: u16, rhs: u16) u16 {
        let r = self % rhs;
        if r == 0 {
            return self;
        }
        return self + (rhs - r);
    }
    /// The smallest multiple of `rhs` not below `self`, or None for a zero `rhs` or on overflow.
    pub const fn checked_next_multiple_of(self: u16, rhs: u16) Option<u16> {
        if rhs == 0 {
            return Option::<u16>::None;
        }
        let r = self % rhs;
        if r == 0 {
            return Option::<u16>::Some(self);
        }
        return self.checked_add(rhs - r);
    }
    /// True when `self` is a multiple of `rhs`; for a zero `rhs`, only 0 is.
    pub const fn is_multiple_of(self: u16, rhs: u16) bool {
        if rhs == 0 {
            return self == 0;
        }
        return self % rhs == 0;
    }
    /// `self / rhs`: unsigned division is already Euclidean. Traps on a zero divisor.
    pub const fn div_euclid(self: u16, rhs: u16) u16 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder is already Euclidean. Traps on a zero divisor.
    pub const fn rem_euclid(self: u16, rhs: u16) u16 {
        return self % rhs;
    }
    /// The same bits as a `i16`: values above `32767` become negative.
    pub const fn cast_signed(self: u16) i16 {
        return self as i16;
    }
    /// `self / rhs`: unsigned division never wraps. Traps on a zero divisor.
    pub const fn wrapping_div(self: u16, rhs: u16) u16 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder never wraps. Traps on a zero divisor.
    pub const fn wrapping_rem(self: u16, rhs: u16) u16 {
        return self % rhs;
    }
    /// `self / rhs`. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: u16, rhs: u16) u16 {
        return self / rhs;
    }
    /// `self % rhs`. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: u16, rhs: u16) u16 {
        return self % rhs;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: u16, exp: u32) u16 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u16 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc.wrapping_mul(base);
            }
            e = e >> 1;
            base = base.wrapping_mul(base);
        }
        return acc.wrapping_mul(base);
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`.
    pub const fn wrapping_add_signed(self: u16, rhs: i16) u16 {
        return self.wrapping_add(rhs as u16);
    }
    /// `0 - self` modulo 2^N and whether `self` is nonzero.
    pub const fn overflowing_neg(self: u16) (u16, bool) {
        return self.wrapping_neg(), self != 0;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: u16, n: u32) (u16, bool) {
        return self.wrapping_shl(n), n >= 16;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: u16, n: u32) (u16, bool) {
        return self.wrapping_shr(n), n >= 16;
    }
    /// `self / rhs` and false: unsigned division never overflows. Traps on a zero divisor.
    pub const fn overflowing_div(self: u16, rhs: u16) (u16, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false: unsigned remainder never overflows. Traps on a zero divisor.
    pub const fn overflowing_rem(self: u16, rhs: u16) (u16, bool) {
        return self % rhs, false;
    }
    /// `self / rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: u16, rhs: u16) (u16, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: u16, rhs: u16) (u16, bool) {
        return self % rhs, false;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: u16, exp: u32) (u16, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: u16 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`, and whether the exact sum leaves [0, MAX].
    pub const fn overflowing_add_signed(self: u16, rhs: i16) (u16, bool) {
        let (r, o) = self.overflowing_add(rhs as u16);
        return r, o != rhs < 0;
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: u16, exp: u32) Option<u16> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// The floor of log2(self), or None for 0.
    pub const fn checked_ilog2(self: u16) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.ilog2());
    }
    /// The floor of log10(self), or None for 0.
    pub const fn checked_ilog10(self: u16) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is 0.
    pub const fn checked_ilog(self: u16, base: u16) Option<u32> {
        if base < 2 || self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self, base));
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div_euclid(self: u16, rhs: u16) Option<u16> {
        return self.checked_div(rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem_euclid(self: u16, rhs: u16) Option<u16> {
        return self.checked_rem(rhs);
    }
    /// `self + rhs` for a signed `rhs`, or None when the sum leaves [0, MAX].
    pub const fn checked_add_signed(self: u16, rhs: i16) Option<u16> {
        let (r, o) = self.overflowing_add_signed(rhs);
        if o {
            return Option::<u16>::None;
        }
        return Option::<u16>::Some(r);
    }
    /// `self / rhs`: unsigned division never saturates. Traps on a zero divisor.
    pub const fn saturating_div(self: u16, rhs: u16) u16 {
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to MAX.
    pub const fn saturating_pow(self: u16, exp: u32) u16 {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return 65535;
        }
        return r;
    }
    /// `self + rhs` for a signed `rhs`, clamped to [0, MAX].
    pub const fn saturating_add_signed(self: u16, rhs: i16) u16 {
        let (r, o) = self.overflowing_add(rhs as u16);
        if o == rhs < 0 {
            return r;
        }
        if o {
            return 65535;
        }
        return 0;
    }
}

extend u32 {
    /// The smallest value.
    pub const MIN: u32 = 0;
    /// The largest value.
    pub const MAX: u32 = 4294967295;
    /// The width in bits.
    pub const BITS: u32 = 32;
    /// Zero bits below the lowest set bit (32 for zero).
    pub const fn trailing_zeros(self: u32) usize {
        return (unsafe sc_ctz64(self as u64 | 1u64 << 32)) as usize; // bit 32 set: a zero counts 32
    }
    /// Zero bits above the highest set bit (32 for zero).
    pub const fn leading_zeros(self: u32) usize {
        return (unsafe sc_clz64(self)) as usize - 32;
    }
    /// Number of set bits.
    pub const fn count_ones(self: u32) usize {
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
    pub const fn wrapping_add(self: u32, rhs: u32) u32 {
        return (unsafe sc_wadd64(self, rhs)) as u32;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: u32, rhs: u32) u32 {
        return (unsafe sc_wsub64(self, rhs)) as u32;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: u32, rhs: u32) u32 {
        return (unsafe sc_wmul64(self, rhs)) as u32;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub const fn wrapping_neg(self: u32) u32 {
        return (unsafe sc_wsub64(0, self)) as u32;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: u32, n: u32) u32 {
        return (unsafe sc_wshl64(self, n & 31)) as u32;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub const fn wrapping_shr(self: u32, n: u32) u32 {
        return (unsafe sc_wshr64(self, n & 31)) as u32;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: u32, rhs: u32) (u32, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: u32, rhs: u32) (u32, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: u32, rhs: u32) (u32, bool) {
        let p = unsafe sc_wmul64(self, rhs); // exact: the operands are narrow
        return p as u32, p > 4294967295;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: u32, rhs: u32) Option<u32> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div(self: u32, rhs: u32) Option<u32> {
        if rhs == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem(self: u32, rhs: u32) Option<u32> {
        if rhs == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub const fn checked_neg(self: u32) Option<u32> {
        if self != 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: u32, n: u32) Option<u32> {
        if n >= 32 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: u32, n: u32) Option<u32> {
        if n >= 32 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub const fn saturating_add(self: u32, rhs: u32) u32 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 4294967295;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub const fn saturating_sub(self: u32, rhs: u32) u32 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub const fn saturating_mul(self: u32, rhs: u32) u32 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 4294967295;
        }
        return r;
    }
    /// Number of clear bits.
    pub const fn count_zeros(self: u32) usize {
        return (~self).count_ones();
    }
    /// One bits above the highest clear bit (the width for MAX).
    pub const fn leading_ones(self: u32) usize {
        return (~self).leading_zeros();
    }
    /// One bits below the lowest clear bit (the width for MAX).
    pub const fn trailing_ones(self: u32) usize {
        return (~self).trailing_zeros();
    }
    /// The bits rotated toward the high end by `n % N`: the bits shifted out enter at the low end.
    pub const fn rotate_left(self: u32, n: u32) u32 {
        let k = n & 31;
        return self << k | self >> (32 - k & 31);
    }
    /// The bits rotated toward the low end by `n % N`: the bits shifted out enter at the high end.
    pub const fn rotate_right(self: u32, n: u32) u32 {
        let k = n & 31;
        return self >> k | self << (32 - k & 31);
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: u32) u32 {
        let x = self << 16 | self >> 16;
        return (x & 0x00FF_00FF) << 8 | x >> 8 & 0x00FF_00FF;
    }
    /// The bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: u32) u32 {
        let mut x = self.swap_bytes();
        x = x >> 4 & 0x0F0F_0F0F | (x & 0x0F0F_0F0F) << 4;
        x = x >> 2 & 0x3333_3333 | (x & 0x3333_3333) << 2;
        return x >> 1 & 0x5555_5555 | (x & 0x5555_5555) << 1;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: u32) u32 {
        if ENDIAN == Endian::Big {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: u32) u32 {
        if ENDIAN == Endian::Little {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: u32) u32 {
        return x.to_be();
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: u32) u32 {
        return x.to_le();
    }
    /// The bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: u32) [u8; 4] {
        return [(self >> 24) as u8, (self >> 16) as u8, (self >> 8) as u8, self as u8];
    }
    /// The bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: u32) [u8; 4] {
        return [self as u8, (self >> 8) as u8, (self >> 16) as u8, (self >> 24) as u8];
    }
    /// The bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: u32) [u8; 4] {
        if ENDIAN == Endian::Big {
            return self.to_be_bytes();
        } else {
            return self.to_le_bytes();
        }
    }
    /// The value of the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 4]) u32 {
        return b[0] as u32 << 24 | b[1] as u32 << 16 | b[2] as u32 << 8 | b[3] as u32;
    }
    /// The value of the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 4]) u32 {
        return b[0] as u32 | b[1] as u32 << 8 | b[2] as u32 << 16 | b[3] as u32 << 24;
    }
    /// The value of the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 4]) u32 {
        if ENDIAN == Endian::Big {
            return u32::from_be_bytes(b);
        } else {
            return u32::from_le_bytes(b);
        }
    }
    /// The smallest power of two not below `self` (1 for 0). Above the largest power of two it traps
    /// with overflow checks and gives 0 without.
    pub const fn next_power_of_two(self: u32) u32 {
        if self <= 1 {
            return 1;
        }
        return (4294967295 >> (self - 1).leading_zeros() as u32) + 1;
    }
    /// The smallest power of two not below `self` (1 for 0), or None when it does not fit.
    pub const fn checked_next_power_of_two(self: u32) Option<u32> {
        if self <= 1 {
            return Option::<u32>::Some(1);
        }
        return (4294967295u32 >> (self - 1).leading_zeros() as u32).checked_add(1);
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: u32, exp: u32) u32 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u32 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root.
    pub const fn isqrt(self: u32) u32 {
        // Exact: the f64 square root of a 32-bit value is never within rounding error of the next integer.
        return unsafe (self as f64).sqrt().to_int_unchecked::<u32>();
    }
    /// The floor of log2(self). Panics when `self` is 0.
    pub const fn ilog2(self: u32) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return 31 - self.leading_zeros() as u32;
    }
    /// The floor of log10(self). Panics when `self` is 0.
    pub const fn ilog10(self: u32) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is 0.
    pub const fn ilog(self: u32, base: u32) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self, base);
    }
    /// `|self - other|`.
    pub const fn abs_diff(self: u32, other: u32) u32 {
        if self < other {
            return other - self;
        }
        return self - other;
    }
    /// `(self + rhs) / 2` rounded down, without overflow.
    pub const fn midpoint(self: u32, rhs: u32) u32 {
        return (self & rhs) + ((self ^ rhs) >> 1);
    }
    /// `self / rhs` rounded up. Traps on a zero divisor.
    pub const fn div_ceil(self: u32, rhs: u32) u32 {
        let q = self / rhs;
        if self % rhs > 0 {
            return q + 1;
        }
        return q;
    }
    /// The smallest multiple of `rhs` not below `self`. Traps on a zero `rhs`; overflow traps with
    /// overflow checks and wraps without.
    pub const fn next_multiple_of(self: u32, rhs: u32) u32 {
        let r = self % rhs;
        if r == 0 {
            return self;
        }
        return self + (rhs - r);
    }
    /// The smallest multiple of `rhs` not below `self`, or None for a zero `rhs` or on overflow.
    pub const fn checked_next_multiple_of(self: u32, rhs: u32) Option<u32> {
        if rhs == 0 {
            return Option::<u32>::None;
        }
        let r = self % rhs;
        if r == 0 {
            return Option::<u32>::Some(self);
        }
        return self.checked_add(rhs - r);
    }
    /// True when `self` is a multiple of `rhs`; for a zero `rhs`, only 0 is.
    pub const fn is_multiple_of(self: u32, rhs: u32) bool {
        if rhs == 0 {
            return self == 0;
        }
        return self % rhs == 0;
    }
    /// `self / rhs`: unsigned division is already Euclidean. Traps on a zero divisor.
    pub const fn div_euclid(self: u32, rhs: u32) u32 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder is already Euclidean. Traps on a zero divisor.
    pub const fn rem_euclid(self: u32, rhs: u32) u32 {
        return self % rhs;
    }
    /// The same bits as a `i32`: values above `2147483647` become negative.
    pub const fn cast_signed(self: u32) i32 {
        return self as i32;
    }
    /// `self / rhs`: unsigned division never wraps. Traps on a zero divisor.
    pub const fn wrapping_div(self: u32, rhs: u32) u32 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder never wraps. Traps on a zero divisor.
    pub const fn wrapping_rem(self: u32, rhs: u32) u32 {
        return self % rhs;
    }
    /// `self / rhs`. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: u32, rhs: u32) u32 {
        return self / rhs;
    }
    /// `self % rhs`. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: u32, rhs: u32) u32 {
        return self % rhs;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: u32, exp: u32) u32 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u32 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc.wrapping_mul(base);
            }
            e = e >> 1;
            base = base.wrapping_mul(base);
        }
        return acc.wrapping_mul(base);
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`.
    pub const fn wrapping_add_signed(self: u32, rhs: i32) u32 {
        return self.wrapping_add(rhs as u32);
    }
    /// `0 - self` modulo 2^N and whether `self` is nonzero.
    pub const fn overflowing_neg(self: u32) (u32, bool) {
        return self.wrapping_neg(), self != 0;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: u32, n: u32) (u32, bool) {
        return self.wrapping_shl(n), n >= 32;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: u32, n: u32) (u32, bool) {
        return self.wrapping_shr(n), n >= 32;
    }
    /// `self / rhs` and false: unsigned division never overflows. Traps on a zero divisor.
    pub const fn overflowing_div(self: u32, rhs: u32) (u32, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false: unsigned remainder never overflows. Traps on a zero divisor.
    pub const fn overflowing_rem(self: u32, rhs: u32) (u32, bool) {
        return self % rhs, false;
    }
    /// `self / rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: u32, rhs: u32) (u32, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: u32, rhs: u32) (u32, bool) {
        return self % rhs, false;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: u32, exp: u32) (u32, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: u32 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`, and whether the exact sum leaves [0, MAX].
    pub const fn overflowing_add_signed(self: u32, rhs: i32) (u32, bool) {
        let (r, o) = self.overflowing_add(rhs as u32);
        return r, o != rhs < 0;
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: u32, exp: u32) Option<u32> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// The floor of log2(self), or None for 0.
    pub const fn checked_ilog2(self: u32) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.ilog2());
    }
    /// The floor of log10(self), or None for 0.
    pub const fn checked_ilog10(self: u32) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is 0.
    pub const fn checked_ilog(self: u32, base: u32) Option<u32> {
        if base < 2 || self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self, base));
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div_euclid(self: u32, rhs: u32) Option<u32> {
        return self.checked_div(rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem_euclid(self: u32, rhs: u32) Option<u32> {
        return self.checked_rem(rhs);
    }
    /// `self + rhs` for a signed `rhs`, or None when the sum leaves [0, MAX].
    pub const fn checked_add_signed(self: u32, rhs: i32) Option<u32> {
        let (r, o) = self.overflowing_add_signed(rhs);
        if o {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(r);
    }
    /// `self / rhs`: unsigned division never saturates. Traps on a zero divisor.
    pub const fn saturating_div(self: u32, rhs: u32) u32 {
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to MAX.
    pub const fn saturating_pow(self: u32, exp: u32) u32 {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return 4294967295;
        }
        return r;
    }
    /// `self + rhs` for a signed `rhs`, clamped to [0, MAX].
    pub const fn saturating_add_signed(self: u32, rhs: i32) u32 {
        let (r, o) = self.overflowing_add(rhs as u32);
        if o == rhs < 0 {
            return r;
        }
        if o {
            return 4294967295;
        }
        return 0;
    }
}

extend u64 {
    /// The smallest value.
    pub const MIN: u64 = 0;
    /// The largest value.
    pub const MAX: u64 = 18446744073709551615;
    /// The width in bits.
    pub const BITS: u32 = 64;
    /// Zero bits below the lowest set bit (64 for zero).
    pub const fn trailing_zeros(self: u64) usize {
        return (unsafe sc_ctz64(self)) as usize;
    }
    /// Zero bits above the highest set bit (64 for zero).
    pub const fn leading_zeros(self: u64) usize {
        return (unsafe sc_clz64(self)) as usize;
    }
    /// Number of set bits.
    pub const fn count_ones(self: u64) usize {
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
    pub const fn wrapping_add(self: u64, rhs: u64) u64 {
        return unsafe sc_wadd64(self, rhs);
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: u64, rhs: u64) u64 {
        return unsafe sc_wsub64(self, rhs);
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: u64, rhs: u64) u64 {
        return unsafe sc_wmul64(self, rhs);
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub const fn wrapping_neg(self: u64) u64 {
        return unsafe sc_wsub64(0, self);
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: u64, n: u32) u64 {
        return unsafe sc_wshl64(self, n & 63);
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub const fn wrapping_shr(self: u64, n: u32) u64 {
        return unsafe sc_wshr64(self, n & 63);
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: u64, rhs: u64) (u64, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: u64, rhs: u64) (u64, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: u64, rhs: u64) (u64, bool) {
        return self.wrapping_mul(rhs), unsafe sc_mulo_u64(self, rhs);
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: u64, rhs: u64) Option<u64> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div(self: u64, rhs: u64) Option<u64> {
        if rhs == 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem(self: u64, rhs: u64) Option<u64> {
        if rhs == 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub const fn checked_neg(self: u64) Option<u64> {
        if self != 0 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: u64, n: u32) Option<u64> {
        if n >= 64 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: u64, n: u32) Option<u64> {
        if n >= 64 {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub const fn saturating_add(self: u64, rhs: u64) u64 {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return 18446744073709551615;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub const fn saturating_sub(self: u64, rhs: u64) u64 {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub const fn saturating_mul(self: u64, rhs: u64) u64 {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return 18446744073709551615;
        }
        return r;
    }
    /// Number of clear bits.
    pub const fn count_zeros(self: u64) usize {
        return (~self).count_ones();
    }
    /// One bits above the highest clear bit (the width for MAX).
    pub const fn leading_ones(self: u64) usize {
        return (~self).leading_zeros();
    }
    /// One bits below the lowest clear bit (the width for MAX).
    pub const fn trailing_ones(self: u64) usize {
        return (~self).trailing_zeros();
    }
    /// The bits rotated toward the high end by `n % N`: the bits shifted out enter at the low end.
    pub const fn rotate_left(self: u64, n: u32) u64 {
        let k = n & 63;
        return self << k | self >> (64 - k & 63);
    }
    /// The bits rotated toward the low end by `n % N`: the bits shifted out enter at the high end.
    pub const fn rotate_right(self: u64, n: u32) u64 {
        let k = n & 63;
        return self >> k | self << (64 - k & 63);
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: u64) u64 {
        let mut x = self << 32 | self >> 32;
        x = (x & 0x0000_FFFF_0000_FFFF) << 16 | x >> 16 & 0x0000_FFFF_0000_FFFF;
        return (x & 0x00FF_00FF_00FF_00FF) << 8 | x >> 8 & 0x00FF_00FF_00FF_00FF;
    }
    /// The bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: u64) u64 {
        let mut x = self.swap_bytes();
        x = x >> 4 & 0x0F0F_0F0F_0F0F_0F0F | (x & 0x0F0F_0F0F_0F0F_0F0F) << 4;
        x = x >> 2 & 0x3333_3333_3333_3333 | (x & 0x3333_3333_3333_3333) << 2;
        return x >> 1 & 0x5555_5555_5555_5555 | (x & 0x5555_5555_5555_5555) << 1;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: u64) u64 {
        if ENDIAN == Endian::Big {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: u64) u64 {
        if ENDIAN == Endian::Little {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: u64) u64 {
        return x.to_be();
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: u64) u64 {
        return x.to_le();
    }
    /// The bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: u64) [u8; 8] {
        return [
            (self >> 56) as u8,
            (self >> 48) as u8,
            (self >> 40) as u8,
            (self >> 32) as u8,
            (self >> 24) as u8,
            (self >> 16) as u8,
            (self >> 8) as u8,
            self as u8,
        ];
    }
    /// The bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: u64) [u8; 8] {
        return [
            self as u8,
            (self >> 8) as u8,
            (self >> 16) as u8,
            (self >> 24) as u8,
            (self >> 32) as u8,
            (self >> 40) as u8,
            (self >> 48) as u8,
            (self >> 56) as u8,
        ];
    }
    /// The bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: u64) [u8; 8] {
        if ENDIAN == Endian::Big {
            return self.to_be_bytes();
        } else {
            return self.to_le_bytes();
        }
    }
    /// The value of the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 8]) u64 {
        return b[0] as u64 << 56 | b[1] as u64 << 48 | b[2] as u64 << 40 | b[3] as u64 << 32 | b[4] as u64 << 24 | b[5] as u64 << 16 | b[6] as u64 << 8 | b[7] as u64;
    }
    /// The value of the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 8]) u64 {
        return b[0] as u64 | b[1] as u64 << 8 | b[2] as u64 << 16 | b[3] as u64 << 24 | b[4] as u64 << 32 | b[5] as u64 << 40 | b[6] as u64 << 48 | b[7] as u64 << 56;
    }
    /// The value of the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 8]) u64 {
        if ENDIAN == Endian::Big {
            return u64::from_be_bytes(b);
        } else {
            return u64::from_le_bytes(b);
        }
    }
    /// The smallest power of two not below `self` (1 for 0). Above the largest power of two it traps
    /// with overflow checks and gives 0 without.
    pub const fn next_power_of_two(self: u64) u64 {
        if self <= 1 {
            return 1;
        }
        return (18446744073709551615 >> (self - 1).leading_zeros() as u64) + 1;
    }
    /// The smallest power of two not below `self` (1 for 0), or None when it does not fit.
    pub const fn checked_next_power_of_two(self: u64) Option<u64> {
        if self <= 1 {
            return Option::<u64>::Some(1);
        }
        return (18446744073709551615u64 >> (self - 1).leading_zeros() as u64).checked_add(1);
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: u64, exp: u32) u64 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u64 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root.
    pub const fn isqrt(self: u64) u64 {
        // The f64 estimate is within one of the result: correct it once in each direction.
        let mut r = unsafe (self as f64).sqrt().to_int_unchecked::<u64>();
        let (sq, o) = r.overflowing_mul(r);
        if o || sq > self {
            r -= 1;
        }
        let (sq_next, o_next) = (r + 1).overflowing_mul(r + 1);
        if !o_next && sq_next <= self {
            r += 1;
        }
        return r;
    }
    /// The floor of log2(self). Panics when `self` is 0.
    pub const fn ilog2(self: u64) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return 63 - self.leading_zeros() as u32;
    }
    /// The floor of log10(self). Panics when `self` is 0.
    pub const fn ilog10(self: u64) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is 0.
    pub const fn ilog(self: u64, base: u64) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self, base);
    }
    /// `|self - other|`.
    pub const fn abs_diff(self: u64, other: u64) u64 {
        if self < other {
            return other - self;
        }
        return self - other;
    }
    /// `(self + rhs) / 2` rounded down, without overflow.
    pub const fn midpoint(self: u64, rhs: u64) u64 {
        return (self & rhs) + ((self ^ rhs) >> 1);
    }
    /// `self / rhs` rounded up. Traps on a zero divisor.
    pub const fn div_ceil(self: u64, rhs: u64) u64 {
        let q = self / rhs;
        if self % rhs > 0 {
            return q + 1;
        }
        return q;
    }
    /// The smallest multiple of `rhs` not below `self`. Traps on a zero `rhs`; overflow traps with
    /// overflow checks and wraps without.
    pub const fn next_multiple_of(self: u64, rhs: u64) u64 {
        let r = self % rhs;
        if r == 0 {
            return self;
        }
        return self + (rhs - r);
    }
    /// The smallest multiple of `rhs` not below `self`, or None for a zero `rhs` or on overflow.
    pub const fn checked_next_multiple_of(self: u64, rhs: u64) Option<u64> {
        if rhs == 0 {
            return Option::<u64>::None;
        }
        let r = self % rhs;
        if r == 0 {
            return Option::<u64>::Some(self);
        }
        return self.checked_add(rhs - r);
    }
    /// True when `self` is a multiple of `rhs`; for a zero `rhs`, only 0 is.
    pub const fn is_multiple_of(self: u64, rhs: u64) bool {
        if rhs == 0 {
            return self == 0;
        }
        return self % rhs == 0;
    }
    /// `self / rhs`: unsigned division is already Euclidean. Traps on a zero divisor.
    pub const fn div_euclid(self: u64, rhs: u64) u64 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder is already Euclidean. Traps on a zero divisor.
    pub const fn rem_euclid(self: u64, rhs: u64) u64 {
        return self % rhs;
    }
    /// The same bits as a `i64`: values above `9223372036854775807` become negative.
    pub const fn cast_signed(self: u64) i64 {
        return self as i64;
    }
    /// `self / rhs`: unsigned division never wraps. Traps on a zero divisor.
    pub const fn wrapping_div(self: u64, rhs: u64) u64 {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder never wraps. Traps on a zero divisor.
    pub const fn wrapping_rem(self: u64, rhs: u64) u64 {
        return self % rhs;
    }
    /// `self / rhs`. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: u64, rhs: u64) u64 {
        return self / rhs;
    }
    /// `self % rhs`. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: u64, rhs: u64) u64 {
        return self % rhs;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: u64, exp: u32) u64 {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: u64 = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc.wrapping_mul(base);
            }
            e = e >> 1;
            base = base.wrapping_mul(base);
        }
        return acc.wrapping_mul(base);
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`.
    pub const fn wrapping_add_signed(self: u64, rhs: i64) u64 {
        return self.wrapping_add(rhs as u64);
    }
    /// `0 - self` modulo 2^N and whether `self` is nonzero.
    pub const fn overflowing_neg(self: u64) (u64, bool) {
        return self.wrapping_neg(), self != 0;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: u64, n: u32) (u64, bool) {
        return self.wrapping_shl(n), n >= 64;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: u64, n: u32) (u64, bool) {
        return self.wrapping_shr(n), n >= 64;
    }
    /// `self / rhs` and false: unsigned division never overflows. Traps on a zero divisor.
    pub const fn overflowing_div(self: u64, rhs: u64) (u64, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false: unsigned remainder never overflows. Traps on a zero divisor.
    pub const fn overflowing_rem(self: u64, rhs: u64) (u64, bool) {
        return self % rhs, false;
    }
    /// `self / rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: u64, rhs: u64) (u64, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: u64, rhs: u64) (u64, bool) {
        return self % rhs, false;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: u64, exp: u32) (u64, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: u64 = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`, and whether the exact sum leaves [0, MAX].
    pub const fn overflowing_add_signed(self: u64, rhs: i64) (u64, bool) {
        let (r, o) = self.overflowing_add(rhs as u64);
        return r, o != rhs < 0;
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: u64, exp: u32) Option<u64> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// The floor of log2(self), or None for 0.
    pub const fn checked_ilog2(self: u64) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.ilog2());
    }
    /// The floor of log10(self), or None for 0.
    pub const fn checked_ilog10(self: u64) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is 0.
    pub const fn checked_ilog(self: u64, base: u64) Option<u32> {
        if base < 2 || self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self, base));
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div_euclid(self: u64, rhs: u64) Option<u64> {
        return self.checked_div(rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem_euclid(self: u64, rhs: u64) Option<u64> {
        return self.checked_rem(rhs);
    }
    /// `self + rhs` for a signed `rhs`, or None when the sum leaves [0, MAX].
    pub const fn checked_add_signed(self: u64, rhs: i64) Option<u64> {
        let (r, o) = self.overflowing_add_signed(rhs);
        if o {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(r);
    }
    /// `self / rhs`: unsigned division never saturates. Traps on a zero divisor.
    pub const fn saturating_div(self: u64, rhs: u64) u64 {
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to MAX.
    pub const fn saturating_pow(self: u64, exp: u32) u64 {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return 18446744073709551615;
        }
        return r;
    }
    /// `self + rhs` for a signed `rhs`, clamped to [0, MAX].
    pub const fn saturating_add_signed(self: u64, rhs: i64) u64 {
        let (r, o) = self.overflowing_add(rhs as u64);
        if o == rhs < 0 {
            return r;
        }
        if o {
            return 18446744073709551615;
        }
        return 0;
    }
}

extend usize {
    /// The smallest value (the target's pointer width).
    pub const MIN: usize = 0;
    /// The largest value (the target's pointer width).
    pub const MAX: usize = ~0usize;
    /// The width in bits.
    pub const BITS: u32 = sizeof(usize) as u32 * 8;
    /// Zero bits below the lowest set bit (the width for zero).
    pub const fn trailing_zeros(self: usize) usize {
        let n = (unsafe sc_ctz64(self as u64)) as usize;
        return n.min(sizeof(usize) * 8);
    }
    /// Zero bits above the highest set bit (the width for zero).
    pub const fn leading_zeros(self: usize) usize {
        return (unsafe sc_clz64(self as u64)) as usize - (64 - sizeof(usize) * 8);
    }
    /// Number of set bits.
    pub const fn count_ones(self: usize) usize {
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
    pub const fn wrapping_add(self: usize, rhs: usize) usize {
        return (unsafe sc_wadd64(self as u64, rhs as u64)) as usize;
    }
    /// `self - rhs` modulo 2^N.
    pub const fn wrapping_sub(self: usize, rhs: usize) usize {
        return (unsafe sc_wsub64(self as u64, rhs as u64)) as usize;
    }
    /// `self * rhs` modulo 2^N.
    pub const fn wrapping_mul(self: usize, rhs: usize) usize {
        return (unsafe sc_wmul64(self as u64, rhs as u64)) as usize;
    }
    /// `-self` modulo 2^N (`0 - self`).
    pub const fn wrapping_neg(self: usize) usize {
        return (unsafe sc_wsub64(0, self as u64)) as usize;
    }
    /// `self << (n % N)`: the count wraps at the width.
    pub const fn wrapping_shl(self: usize, n: u32) usize {
        return (unsafe sc_wshl64(self as u64, n & sizeof(usize) as u32 * 8 - 1)) as usize;
    }
    /// `self >> (n % N)`: the count wraps at the width.
    pub const fn wrapping_shr(self: usize, n: u32) usize {
        return (unsafe sc_wshr64(self as u64, n & sizeof(usize) as u32 * 8 - 1)) as usize;
    }
    /// The wrapped sum and whether `self + rhs` overflows.
    pub const fn overflowing_add(self: usize, rhs: usize) (usize, bool) {
        let r = self.wrapping_add(rhs);
        return r, r < self;
    }
    /// The wrapped difference and whether `self - rhs` overflows.
    pub const fn overflowing_sub(self: usize, rhs: usize) (usize, bool) {
        return self.wrapping_sub(rhs), rhs > self;
    }
    /// The wrapped product and whether `self * rhs` overflows.
    pub const fn overflowing_mul(self: usize, rhs: usize) (usize, bool) {
        let p = unsafe sc_wmul64(self as u64, rhs as u64);
        return p as usize, unsafe sc_mulo_u64(self as u64, rhs as u64) || p > (~0usize) as u64;
    }
    /// `self + rhs`, or None when it overflows.
    pub const fn checked_add(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self - rhs`, or None when it overflows.
    pub const fn checked_sub(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_sub(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self * rhs`, or None when it overflows.
    pub const fn checked_mul(self: usize, rhs: usize) Option<usize> {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div(self: usize, rhs: usize) Option<usize> {
        if rhs == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self / rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem(self: usize, rhs: usize) Option<usize> {
        if rhs == 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self % rhs);
    }
    /// `-self`, or None unless `self` is 0.
    pub const fn checked_neg(self: usize) Option<usize> {
        if self != 0 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(0);
    }
    /// `self << n`, or None when `n` is at least the width.
    pub const fn checked_shl(self: usize, n: u32) Option<usize> {
        if n >= sizeof(usize) as u32 * 8 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self.wrapping_shl(n));
    }
    /// `self >> n`, or None when `n` is at least the width.
    pub const fn checked_shr(self: usize, n: u32) Option<usize> {
        if n >= sizeof(usize) as u32 * 8 {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(self.wrapping_shr(n));
    }
    /// `self + rhs`, clamped to MAX.
    pub const fn saturating_add(self: usize, rhs: usize) usize {
        let (r, o) = self.overflowing_add(rhs);
        if o {
            return ~0usize;
        }
        return r;
    }
    /// `self - rhs`, clamped to 0.
    pub const fn saturating_sub(self: usize, rhs: usize) usize {
        if rhs > self {
            return 0;
        }
        return self.wrapping_sub(rhs);
    }
    /// `self * rhs`, clamped to MAX.
    pub const fn saturating_mul(self: usize, rhs: usize) usize {
        let (r, o) = self.overflowing_mul(rhs);
        if o {
            return ~0usize;
        }
        return r;
    }
    /// Number of clear bits.
    pub const fn count_zeros(self: usize) usize {
        return (~self).count_ones();
    }
    /// One bits above the highest clear bit (the width for MAX).
    pub const fn leading_ones(self: usize) usize {
        return (~self).leading_zeros();
    }
    /// One bits below the lowest clear bit (the width for MAX).
    pub const fn trailing_ones(self: usize) usize {
        return (~self).trailing_zeros();
    }
    /// The bits rotated toward the high end by `n % N`: the bits shifted out enter at the low end.
    pub const fn rotate_left(self: usize, n: u32) usize {
        let k = n & sizeof(usize) as u32 * 8 - 1;
        return self << k as usize | self >> (sizeof(usize) as u32 * 8 - k & sizeof(usize) as u32 * 8 - 1) as usize;
    }
    /// The bits rotated toward the low end by `n % N`: the bits shifted out enter at the high end.
    pub const fn rotate_right(self: usize, n: u32) usize {
        let k = n & sizeof(usize) as u32 * 8 - 1;
        return self >> k as usize | self << (sizeof(usize) as u32 * 8 - k & sizeof(usize) as u32 * 8 - 1) as usize;
    }
    /// The bytes in reverse order.
    pub const fn swap_bytes(self: usize) usize {
        return ((self as u64).swap_bytes() >> 64 - sizeof(usize) as u32 * 8) as usize;
    }
    /// The bits in reverse order: bit 0 becomes bit N - 1.
    pub const fn reverse_bits(self: usize) usize {
        return ((self as u64).reverse_bits() >> 64 - sizeof(usize) as u32 * 8) as usize;
    }
    /// `self` in big-endian byte order: `swap_bytes` on a little-endian target, `self` on a big-endian one.
    pub const fn to_be(self: usize) usize {
        if ENDIAN == Endian::Big {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// `self` in little-endian byte order: `self` on a little-endian target, `swap_bytes` on a big-endian one.
    pub const fn to_le(self: usize) usize {
        if ENDIAN == Endian::Little {
            return self;
        } else {
            return self.swap_bytes();
        }
    }
    /// The value whose big-endian representation is `x`.
    pub const fn from_be(x: usize) usize {
        return x.to_be();
    }
    /// The value whose little-endian representation is `x`.
    pub const fn from_le(x: usize) usize {
        return x.to_le();
    }
    /// The bytes of `self`, most significant first.
    pub const fn to_be_bytes(self: usize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_be_bytes();
        } else {
            return (self as u64).to_be_bytes();
        }
    }
    /// The bytes of `self`, least significant first.
    pub const fn to_le_bytes(self: usize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_le_bytes();
        } else {
            return (self as u64).to_le_bytes();
        }
    }
    /// The bytes of `self` in the target's byte order.
    pub const fn to_ne_bytes(self: usize) [u8; sizeof(usize)] {
        if POINTER_WIDTH == 32 {
            return (self as u32).to_ne_bytes();
        } else {
            return (self as u64).to_ne_bytes();
        }
    }
    /// The value of the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; sizeof(usize)]) usize {
        if POINTER_WIDTH == 32 {
            return u32::from_be_bytes(b) as usize;
        } else {
            return u64::from_be_bytes(b) as usize;
        }
    }
    /// The value of the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; sizeof(usize)]) usize {
        if POINTER_WIDTH == 32 {
            return u32::from_le_bytes(b) as usize;
        } else {
            return u64::from_le_bytes(b) as usize;
        }
    }
    /// The value of the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; sizeof(usize)]) usize {
        if POINTER_WIDTH == 32 {
            return u32::from_ne_bytes(b) as usize;
        } else {
            return u64::from_ne_bytes(b) as usize;
        }
    }
    /// The smallest power of two not below `self` (1 for 0). Above the largest power of two it traps
    /// with overflow checks and gives 0 without.
    pub const fn next_power_of_two(self: usize) usize {
        if self <= 1 {
            return 1;
        }
        return (~0usize >> (self - 1).leading_zeros()) + 1;
    }
    /// The smallest power of two not below `self` (1 for 0), or None when it does not fit.
    pub const fn checked_next_power_of_two(self: usize) Option<usize> {
        if self <= 1 {
            return Option::<usize>::Some(1);
        }
        return (~0usize >> (self - 1).leading_zeros()).checked_add(1);
    }
    /// `self` raised to `exp` (1 for `exp` 0); overflow traps with overflow checks and wraps without.
    pub const fn pow(self: usize, exp: u32) usize {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: usize = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc * base;
            }
            e = e >> 1;
            base = base * base;
        }
        return acc * base;
    }
    /// The floor of the square root.
    pub const fn isqrt(self: usize) usize {
        return (self as u64).isqrt() as usize;
    }
    /// The floor of log2(self). Panics when `self` is 0.
    pub const fn ilog2(self: usize) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return sizeof(usize) as u32 * 8 - 1 - self.leading_zeros() as u32;
    }
    /// The floor of log10(self). Panics when `self` is 0.
    pub const fn ilog10(self: usize) u32 {
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog10_u64(self as u64);
    }
    /// The floor of the logarithm of `self` in `base`. Panics when `base` is below 2 or `self` is 0.
    pub const fn ilog(self: usize, base: usize) u32 {
        if base < 2 {
            panic("base of integer logarithm must be at least 2");
        }
        if self == 0 {
            panic("argument of integer logarithm must be positive");
        }
        return ilog_u64(self as u64, base as u64);
    }
    /// `|self - other|`.
    pub const fn abs_diff(self: usize, other: usize) usize {
        if self < other {
            return other - self;
        }
        return self - other;
    }
    /// `(self + rhs) / 2` rounded down, without overflow.
    pub const fn midpoint(self: usize, rhs: usize) usize {
        return (self & rhs) + ((self ^ rhs) >> 1);
    }
    /// `self / rhs` rounded up. Traps on a zero divisor.
    pub const fn div_ceil(self: usize, rhs: usize) usize {
        let q = self / rhs;
        if self % rhs > 0 {
            return q + 1;
        }
        return q;
    }
    /// The smallest multiple of `rhs` not below `self`. Traps on a zero `rhs`; overflow traps with
    /// overflow checks and wraps without.
    pub const fn next_multiple_of(self: usize, rhs: usize) usize {
        let r = self % rhs;
        if r == 0 {
            return self;
        }
        return self + (rhs - r);
    }
    /// The smallest multiple of `rhs` not below `self`, or None for a zero `rhs` or on overflow.
    pub const fn checked_next_multiple_of(self: usize, rhs: usize) Option<usize> {
        if rhs == 0 {
            return Option::<usize>::None;
        }
        let r = self % rhs;
        if r == 0 {
            return Option::<usize>::Some(self);
        }
        return self.checked_add(rhs - r);
    }
    /// True when `self` is a multiple of `rhs`; for a zero `rhs`, only 0 is.
    pub const fn is_multiple_of(self: usize, rhs: usize) bool {
        if rhs == 0 {
            return self == 0;
        }
        return self % rhs == 0;
    }
    /// `self / rhs`: unsigned division is already Euclidean. Traps on a zero divisor.
    pub const fn div_euclid(self: usize, rhs: usize) usize {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder is already Euclidean. Traps on a zero divisor.
    pub const fn rem_euclid(self: usize, rhs: usize) usize {
        return self % rhs;
    }
    /// The same bits as a `isize`: values above `((~0usize >> 1) as isize)` become negative.
    pub const fn cast_signed(self: usize) isize {
        return self as isize;
    }
    /// `self / rhs`: unsigned division never wraps. Traps on a zero divisor.
    pub const fn wrapping_div(self: usize, rhs: usize) usize {
        return self / rhs;
    }
    /// `self % rhs`: unsigned remainder never wraps. Traps on a zero divisor.
    pub const fn wrapping_rem(self: usize, rhs: usize) usize {
        return self % rhs;
    }
    /// `self / rhs`. Traps on a zero divisor.
    pub const fn wrapping_div_euclid(self: usize, rhs: usize) usize {
        return self / rhs;
    }
    /// `self % rhs`. Traps on a zero divisor.
    pub const fn wrapping_rem_euclid(self: usize, rhs: usize) usize {
        return self % rhs;
    }
    /// `self` raised to `exp` modulo 2^N.
    pub const fn wrapping_pow(self: usize, exp: u32) usize {
        if exp == 0 {
            return 1;
        }
        let mut base = self;
        let mut acc: usize = 1;
        let mut e = exp;
        while e > 1 {
            if (e & 1) == 1 {
                acc = acc.wrapping_mul(base);
            }
            e = e >> 1;
            base = base.wrapping_mul(base);
        }
        return acc.wrapping_mul(base);
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`.
    pub const fn wrapping_add_signed(self: usize, rhs: isize) usize {
        return self.wrapping_add(rhs as usize);
    }
    /// `0 - self` modulo 2^N and whether `self` is nonzero.
    pub const fn overflowing_neg(self: usize) (usize, bool) {
        return self.wrapping_neg(), self != 0;
    }
    /// `self.wrapping_shl(n)` and whether `n` is at least the width.
    pub const fn overflowing_shl(self: usize, n: u32) (usize, bool) {
        return self.wrapping_shl(n), n >= sizeof(usize) as u32 * 8;
    }
    /// `self.wrapping_shr(n)` and whether `n` is at least the width.
    pub const fn overflowing_shr(self: usize, n: u32) (usize, bool) {
        return self.wrapping_shr(n), n >= sizeof(usize) as u32 * 8;
    }
    /// `self / rhs` and false: unsigned division never overflows. Traps on a zero divisor.
    pub const fn overflowing_div(self: usize, rhs: usize) (usize, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false: unsigned remainder never overflows. Traps on a zero divisor.
    pub const fn overflowing_rem(self: usize, rhs: usize) (usize, bool) {
        return self % rhs, false;
    }
    /// `self / rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_div_euclid(self: usize, rhs: usize) (usize, bool) {
        return self / rhs, false;
    }
    /// `self % rhs` and false. Traps on a zero divisor.
    pub const fn overflowing_rem_euclid(self: usize, rhs: usize) (usize, bool) {
        return self % rhs, false;
    }
    /// `self` raised to `exp` modulo 2^N and whether the exact power overflows.
    pub const fn overflowing_pow(self: usize, exp: u32) (usize, bool) {
        if exp == 0 {
            return 1, false;
        }
        let mut base = self;
        let mut acc: usize = 1;
        let mut e = exp;
        let mut o = false;
        while e > 1 {
            if (e & 1) == 1 {
                let (r, ro) = acc.overflowing_mul(base);
                acc = r;
                o = o || ro;
            }
            e = e >> 1;
            let (sq, so) = base.overflowing_mul(base);
            base = sq;
            o = o || so;
        }
        let (r, ro) = acc.overflowing_mul(base);
        return r, o || ro;
    }
    /// `self + rhs` modulo 2^N for a signed `rhs`, and whether the exact sum leaves [0, MAX].
    pub const fn overflowing_add_signed(self: usize, rhs: isize) (usize, bool) {
        let (r, o) = self.overflowing_add(rhs as usize);
        return r, o != rhs < 0;
    }
    /// `self` raised to `exp`, or None when it overflows.
    pub const fn checked_pow(self: usize, exp: u32) Option<usize> {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// The floor of log2(self), or None for 0.
    pub const fn checked_ilog2(self: usize) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(self.ilog2());
    }
    /// The floor of log10(self), or None for 0.
    pub const fn checked_ilog10(self: usize) Option<u32> {
        if self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog10_u64(self as u64));
    }
    /// The floor of the logarithm of `self` in `base`, or None when `base` is below 2 or `self` is 0.
    pub const fn checked_ilog(self: usize, base: usize) Option<u32> {
        if base < 2 || self == 0 {
            return Option::<u32>::None;
        }
        return Option::<u32>::Some(ilog_u64(self as u64, base as u64));
    }
    /// `self / rhs`, or None for a zero divisor.
    pub const fn checked_div_euclid(self: usize, rhs: usize) Option<usize> {
        return self.checked_div(rhs);
    }
    /// `self % rhs`, or None for a zero divisor.
    pub const fn checked_rem_euclid(self: usize, rhs: usize) Option<usize> {
        return self.checked_rem(rhs);
    }
    /// `self + rhs` for a signed `rhs`, or None when the sum leaves [0, MAX].
    pub const fn checked_add_signed(self: usize, rhs: isize) Option<usize> {
        let (r, o) = self.overflowing_add_signed(rhs);
        if o {
            return Option::<usize>::None;
        }
        return Option::<usize>::Some(r);
    }
    /// `self / rhs`: unsigned division never saturates. Traps on a zero divisor.
    pub const fn saturating_div(self: usize, rhs: usize) usize {
        return self / rhs;
    }
    /// `self` raised to `exp`, clamped to MAX.
    pub const fn saturating_pow(self: usize, exp: u32) usize {
        let (r, o) = self.overflowing_pow(exp);
        if o {
            return ~0usize;
        }
        return r;
    }
    /// `self + rhs` for a signed `rhs`, clamped to [0, MAX].
    pub const fn saturating_add_signed(self: usize, rhs: isize) usize {
        let (r, o) = self.overflowing_add(rhs as usize);
        if o == rhs < 0 {
            return r;
        }
        if o {
            return ~0usize;
        }
        return 0;
    }
}

extend f32 {
    /// The most negative finite value.
    pub const MIN: f32 = -3.40282347e38;
    /// The largest finite value.
    pub const MAX: f32 = 3.40282347e38;
    /// The difference between 1.0 and the next larger value: 2^-23.
    pub const EPSILON: f32 = 1.19209290e-7;
    /// The smallest positive normal value: 2^-126.
    pub const MIN_POSITIVE: f32 = 1.17549435e-38;
    /// A quiet NaN with a clear sign and a zero payload (0x7FC0_0000).
    pub const NAN: f32 = f32::from_bits(0x7FC0_0000);
    /// Positive infinity.
    pub const INFINITY: f32 = f32::from_bits(0x7F80_0000);
    /// Negative infinity.
    pub const NEG_INFINITY: f32 = f32::from_bits(0xFF80_0000);
    /// The base of the encoding.
    pub const RADIX: u32 = 2;
    /// Significand bits, the implicit leading bit included.
    pub const MANTISSA_DIGITS: u32 = 24;
    /// Decimal digits that survive a decimal to f32 to decimal round trip.
    pub const DIGITS: u32 = 6;
    /// One above the smallest normal binary exponent: MIN_POSITIVE is 2^(MIN_EXP - 1).
    pub const MIN_EXP: i32 = -125;
    /// One above the largest binary exponent: MAX is below 2^MAX_EXP.
    pub const MAX_EXP: i32 = 128;
    /// The smallest `n` with 10^n a normal value.
    pub const MIN_10_EXP: i32 = -37;
    /// The largest `n` with 10^n a finite value.
    pub const MAX_10_EXP: i32 = 38;
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
    /// `self` truncated toward zero to the integer type `I`, as one conversion instruction: `as`
    /// without its saturation checks. `self` must not be NaN and its truncation must fit `I`; any
    /// other value is undefined behavior, and an error in a constant.
    @intrinsic("float.to_int_unchecked")
    pub unsafe const fn to_int_unchecked<I: SimdInt>(self: f32) I;
    /// The IEEE 754 encoding of `self`, NaN payload included.
    pub const fn to_bits(self: f32) u32 {
        let v = F32Bits { f: self };
        return v.u;
    }
    /// The value with the IEEE 754 encoding `v`, NaN payload included.
    pub const fn from_bits(v: u32) f32 {
        let b = F32Bits { u: v };
        return b.f;
    }
    /// The bytes of the encoding, most significant first.
    pub const fn to_be_bytes(self: f32) [u8; 4] {
        return self.to_bits().to_be_bytes();
    }
    /// The bytes of the encoding, least significant first.
    pub const fn to_le_bytes(self: f32) [u8; 4] {
        return self.to_bits().to_le_bytes();
    }
    /// The bytes of the encoding in the target's byte order.
    pub const fn to_ne_bytes(self: f32) [u8; 4] {
        return self.to_bits().to_ne_bytes();
    }
    /// The value whose encoding has the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 4]) f32 {
        return f32::from_bits(u32::from_be_bytes(b));
    }
    /// The value whose encoding has the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 4]) f32 {
        return f32::from_bits(u32::from_le_bytes(b));
    }
    /// The value whose encoding has the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 4]) f32 {
        return f32::from_bits(u32::from_ne_bytes(b));
    }
    /// The IEEE 754 class of `self`: zero, subnormal, normal, infinite or NaN (either sign).
    pub const fn classify(self: f32) FpClass {
        let v = self.to_bits();
        let e = v >> 23 & 0xFF;
        let m = v & 0x7F_FFFF;
        if e == 0 {
            if m == 0 {
                return FpClass::FP_ZERO;
            }
            return FpClass::FP_SUBNORMAL;
        }
        if e == 0xFF {
            if m == 0 {
                return FpClass::FP_INFINITE;
            }
            return FpClass::FP_NAN;
        }
        return FpClass::FP_NORMAL;
    }
    /// True when `self` is neither zero, subnormal, infinite nor NaN.
    pub const fn is_normal(self: f32) bool {
        let e = self.to_bits() >> 23 & 0xFF;
        return e != 0 && e != 0xFF;
    }
    /// True for a nonzero value whose magnitude is below MIN_POSITIVE.
    pub const fn is_subnormal(self: f32) bool {
        let a = self.to_bits() & 0x7FFF_FFFF;
        return a != 0 && a < 0x0080_0000;
    }
    /// The least value above `self`: NaN and +inf return themselves, -inf gives MIN, both zeros give the
    /// smallest positive subnormal, and MAX gives +inf.
    pub const fn next_up(self: f32) f32 {
        let v = self.to_bits();
        if self.is_nan() || v == 0x7F80_0000 {
            return self;
        }
        let a = v & 0x7FFF_FFFF;
        if a == 0 {
            return f32::from_bits(1);
        }
        if v == a {
            return f32::from_bits(v + 1);
        }
        return f32::from_bits(v - 1);
    }
    /// The greatest value below `self`: NaN and -inf return themselves, +inf gives MAX, both zeros give
    /// the negative subnormal closest to zero, and MIN gives -inf.
    pub const fn next_down(self: f32) f32 {
        let v = self.to_bits();
        if self.is_nan() || v == 0xFF80_0000 {
            return self;
        }
        let a = v & 0x7FFF_FFFF;
        if a == 0 {
            return f32::from_bits(0x8000_0000 | 1);
        }
        if v == a {
            return f32::from_bits(v - 1);
        }
        return f32::from_bits(v + 1);
    }
    /// `(self + other) / 2` without intermediate overflow: NaN when either is NaN or for +inf and -inf.
    pub const fn midpoint(self: f32, other: f32) f32 {
        // The f64 sum of two f32 values cannot overflow.
        return ((self as f64 + other as f64) / 2.0) as f32;
    }
    /// The Euclidean quotient: `(self / rhs).trunc()` moved down by one step when `self % rhs` is
    /// negative (up for a negative `rhs`), so that `self.rem_euclid(rhs)` is not negative.
    pub const fn div_euclid(self: f32, rhs: f32) f32 {
        let q = (self / rhs).trunc();
        if self % rhs < 0.0 {
            if rhs > 0.0 {
                return q - 1.0;
            }
            return q + 1.0;
        }
        return q;
    }
    /// The least non-negative remainder of `self / rhs`: in `[0, |rhs|]`, where rounding can give
    /// exactly `|rhs|`. NaN for a zero `rhs`, as `%`.
    pub const fn rem_euclid(self: f32, rhs: f32) f32 {
        let r = self % rhs;
        if r < 0.0 {
            return r + rhs.abs();
        }
        return r;
    }
    /// The larger of the two by IEEE 754-2019 `maximum`: NaN when either is NaN, and +0.0 above -0.0.
    pub const fn maximum(self: f32, other: f32) f32 {
        if self > other {
            return self;
        }
        if other > self {
            return other;
        }
        if self == other {
            if self.is_sign_positive() && other.is_sign_negative() {
                return self;
            }
            return other;
        }
        return self + other; // a NaN operand: the sum is a quiet NaN
    }
    /// The smaller of the two by IEEE 754-2019 `minimum`: NaN when either is NaN, and -0.0 below +0.0.
    pub const fn minimum(self: f32, other: f32) f32 {
        if self < other {
            return self;
        }
        if other < self {
            return other;
        }
        if self == other {
            if self.is_sign_negative() && other.is_sign_positive() {
                return self;
            }
            return other;
        }
        return self + other; // a NaN operand: the sum is a quiet NaN
    }
}

extend f64 {
    /// The most negative finite value.
    pub const MIN: f64 = -1.7976931348623157e308;
    /// The largest finite value.
    pub const MAX: f64 = 1.7976931348623157e308;
    /// The difference between 1.0 and the next larger value: 2^-52.
    pub const EPSILON: f64 = 2.220446049250313e-16;
    /// The smallest positive normal value: 2^-1022.
    pub const MIN_POSITIVE: f64 = 2.2250738585072014e-308;
    /// A quiet NaN with a clear sign and a zero payload (0x7FF8_0000_0000_0000).
    pub const NAN: f64 = f64::from_bits(0x7FF8_0000_0000_0000);
    /// Positive infinity.
    pub const INFINITY: f64 = f64::from_bits(0x7FF0_0000_0000_0000);
    /// Negative infinity.
    pub const NEG_INFINITY: f64 = f64::from_bits(0xFFF0_0000_0000_0000);
    /// The base of the encoding.
    pub const RADIX: u32 = 2;
    /// Significand bits, the implicit leading bit included.
    pub const MANTISSA_DIGITS: u32 = 53;
    /// Decimal digits that survive a decimal to f64 to decimal round trip.
    pub const DIGITS: u32 = 15;
    /// One above the smallest normal binary exponent: MIN_POSITIVE is 2^(MIN_EXP - 1).
    pub const MIN_EXP: i32 = -1021;
    /// One above the largest binary exponent: MAX is below 2^MAX_EXP.
    pub const MAX_EXP: i32 = 1024;
    /// The smallest `n` with 10^n a normal value.
    pub const MIN_10_EXP: i32 = -307;
    /// The largest `n` with 10^n a finite value.
    pub const MAX_10_EXP: i32 = 308;
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
    /// `self` truncated toward zero to the integer type `I`, as one conversion instruction: `as`
    /// without its saturation checks. `self` must not be NaN and its truncation must fit `I`; any
    /// other value is undefined behavior, and an error in a constant.
    @intrinsic("float.to_int_unchecked")
    pub unsafe const fn to_int_unchecked<I: SimdInt>(self: f64) I;
    /// The IEEE 754 encoding of `self`, NaN payload included.
    pub const fn to_bits(self: f64) u64 {
        let v = F64Bits { f: self };
        return v.u;
    }
    /// The value with the IEEE 754 encoding `v`, NaN payload included.
    pub const fn from_bits(v: u64) f64 {
        let b = F64Bits { u: v };
        return b.f;
    }
    /// The bytes of the encoding, most significant first.
    pub const fn to_be_bytes(self: f64) [u8; 8] {
        return self.to_bits().to_be_bytes();
    }
    /// The bytes of the encoding, least significant first.
    pub const fn to_le_bytes(self: f64) [u8; 8] {
        return self.to_bits().to_le_bytes();
    }
    /// The bytes of the encoding in the target's byte order.
    pub const fn to_ne_bytes(self: f64) [u8; 8] {
        return self.to_bits().to_ne_bytes();
    }
    /// The value whose encoding has the bytes `b`, most significant first.
    pub const fn from_be_bytes(b: [u8; 8]) f64 {
        return f64::from_bits(u64::from_be_bytes(b));
    }
    /// The value whose encoding has the bytes `b`, least significant first.
    pub const fn from_le_bytes(b: [u8; 8]) f64 {
        return f64::from_bits(u64::from_le_bytes(b));
    }
    /// The value whose encoding has the bytes `b` in the target's byte order.
    pub const fn from_ne_bytes(b: [u8; 8]) f64 {
        return f64::from_bits(u64::from_ne_bytes(b));
    }
    /// The IEEE 754 class of `self`: zero, subnormal, normal, infinite or NaN (either sign).
    pub const fn classify(self: f64) FpClass {
        let v = self.to_bits();
        let e = v >> 52 & 0x7FF;
        let m = v & 0x000F_FFFF_FFFF_FFFF;
        if e == 0 {
            if m == 0 {
                return FpClass::FP_ZERO;
            }
            return FpClass::FP_SUBNORMAL;
        }
        if e == 0x7FF {
            if m == 0 {
                return FpClass::FP_INFINITE;
            }
            return FpClass::FP_NAN;
        }
        return FpClass::FP_NORMAL;
    }
    /// True when `self` is neither zero, subnormal, infinite nor NaN.
    pub const fn is_normal(self: f64) bool {
        let e = self.to_bits() >> 52 & 0x7FF;
        return e != 0 && e != 0x7FF;
    }
    /// True for a nonzero value whose magnitude is below MIN_POSITIVE.
    pub const fn is_subnormal(self: f64) bool {
        let a = self.to_bits() & 0x7FFF_FFFF_FFFF_FFFF;
        return a != 0 && a < 0x0010_0000_0000_0000;
    }
    /// The least value above `self`: NaN and +inf return themselves, -inf gives MIN, both zeros give the
    /// smallest positive subnormal, and MAX gives +inf.
    pub const fn next_up(self: f64) f64 {
        let v = self.to_bits();
        if self.is_nan() || v == 0x7FF0_0000_0000_0000 {
            return self;
        }
        let a = v & 0x7FFF_FFFF_FFFF_FFFF;
        if a == 0 {
            return f64::from_bits(1);
        }
        if v == a {
            return f64::from_bits(v + 1);
        }
        return f64::from_bits(v - 1);
    }
    /// The greatest value below `self`: NaN and -inf return themselves, +inf gives MAX, both zeros give
    /// the negative subnormal closest to zero, and MIN gives -inf.
    pub const fn next_down(self: f64) f64 {
        let v = self.to_bits();
        if self.is_nan() || v == 0xFFF0_0000_0000_0000 {
            return self;
        }
        let a = v & 0x7FFF_FFFF_FFFF_FFFF;
        if a == 0 {
            return f64::from_bits(0x8000_0000_0000_0000 | 1);
        }
        if v == a {
            return f64::from_bits(v - 1);
        }
        return f64::from_bits(v + 1);
    }
    /// `(self + other) / 2` without intermediate overflow: NaN when either is NaN or for +inf and -inf.
    pub const fn midpoint(self: f64, other: f64) f64 {
        let lo: f64 = 4.450147717014403e-308; // MIN_POSITIVE * 2
        let hi: f64 = 8.988465674311579e307; // MAX / 2
        let a = self.abs();
        let b = other.abs();
        if a <= hi && b <= hi {
            return (self + other) / 2.0; // no overflow
        }
        if a < lo {
            return self + other / 2.0; // halving `self` would lose its bits
        }
        if b < lo {
            return self / 2.0 + other;
        }
        return self / 2.0 + other / 2.0;
    }
    /// The Euclidean quotient: `(self / rhs).trunc()` moved down by one step when `self % rhs` is
    /// negative (up for a negative `rhs`), so that `self.rem_euclid(rhs)` is not negative.
    pub const fn div_euclid(self: f64, rhs: f64) f64 {
        let q = (self / rhs).trunc();
        if self % rhs < 0.0 {
            if rhs > 0.0 {
                return q - 1.0;
            }
            return q + 1.0;
        }
        return q;
    }
    /// The least non-negative remainder of `self / rhs`: in `[0, |rhs|]`, where rounding can give
    /// exactly `|rhs|`. NaN for a zero `rhs`, as `%`.
    pub const fn rem_euclid(self: f64, rhs: f64) f64 {
        let r = self % rhs;
        if r < 0.0 {
            return r + rhs.abs();
        }
        return r;
    }
    /// The larger of the two by IEEE 754-2019 `maximum`: NaN when either is NaN, and +0.0 above -0.0.
    pub const fn maximum(self: f64, other: f64) f64 {
        if self > other {
            return self;
        }
        if other > self {
            return other;
        }
        if self == other {
            if self.is_sign_positive() && other.is_sign_negative() {
                return self;
            }
            return other;
        }
        return self + other; // a NaN operand: the sum is a quiet NaN
    }
    /// The smaller of the two by IEEE 754-2019 `minimum`: NaN when either is NaN, and -0.0 below +0.0.
    pub const fn minimum(self: f64, other: f64) f64 {
        if self < other {
            return self;
        }
        if other < self {
            return other;
        }
        if self == other {
            if self.is_sign_negative() && other.is_sign_positive() {
                return self;
            }
            return other;
        }
        return self + other; // a NaN operand: the sum is a quiet NaN
    }
}

extend bool {
    /// `Some(f())` when `self` is true, else None; `f` runs only when `self` is true.
    pub const fn then<T, F: fn() T>(self: bool, f: F) Option<T> {
        if self {
            return Option::<T>::Some(f());
        }
        return Option::<T>::None;
    }
    /// `Some(v)` when `self` is true, else None. `v` is evaluated either way and dropped when false.
    pub const fn then_some<T>(self: bool, v: T) Option<T> {
        if self {
            return Option::<T>::Some(v);
        }
        return Option::<T>::None;
    }
}

extend char {
    /// True for an ASCII character: 0x00 to 0x7F.
    pub const fn is_ascii(self: char) bool {
        return (self as u8).is_ascii();
    }
    /// True for `A` to `Z` and `a` to `z`.
    pub const fn is_ascii_alphabetic(self: char) bool {
        return (self as u8).is_ascii_alphabetic();
    }
    /// True for `A` to `Z`.
    pub const fn is_ascii_uppercase(self: char) bool {
        return (self as u8).is_ascii_uppercase();
    }
    /// True for `a` to `z`.
    pub const fn is_ascii_lowercase(self: char) bool {
        return (self as u8).is_ascii_lowercase();
    }
    /// True for `0` to `9`, `A` to `Z` and `a` to `z`.
    pub const fn is_ascii_alphanumeric(self: char) bool {
        return (self as u8).is_ascii_alphanumeric();
    }
    /// True for `0` to `9`.
    pub const fn is_ascii_digit(self: char) bool {
        return (self as u8).is_ascii_digit();
    }
    /// True for `0` to `9`, `A` to `F` and `a` to `f`.
    pub const fn is_ascii_hexdigit(self: char) bool {
        return (self as u8).is_ascii_hexdigit();
    }
    /// True for the graphic ASCII characters that are not alphanumeric: `!` to `/`, `:` to `@`, `[` to
    /// 0x60 and `{` to `~`.
    pub const fn is_ascii_punctuation(self: char) bool {
        return (self as u8).is_ascii_punctuation();
    }
    /// True for the visible ASCII characters: `!` (0x21) to `~` (0x7E).
    pub const fn is_ascii_graphic(self: char) bool {
        return (self as u8).is_ascii_graphic();
    }
    /// True for space, tab, line feed, form feed and carriage return; not vertical tab (the WHATWG set).
    pub const fn is_ascii_whitespace(self: char) bool {
        return (self as u8).is_ascii_whitespace();
    }
    /// True for the ASCII control characters: 0x00 to 0x1F and 0x7F.
    pub const fn is_ascii_control(self: char) bool {
        return (self as u8).is_ascii_control();
    }
    /// `self` with `a` to `z` mapped to `A` to `Z`; every other character unchanged.
    pub const fn to_ascii_uppercase(self: char) char {
        return (self as u8).to_ascii_uppercase() as char;
    }
    /// `self` with `A` to `Z` mapped to `a` to `z`; every other character unchanged.
    pub const fn to_ascii_lowercase(self: char) char {
        return (self as u8).to_ascii_lowercase() as char;
    }
    /// True when `self` and `other` are equal after `to_ascii_lowercase`.
    pub const fn eq_ignore_ascii_case(self: char, other: char) bool {
        return (self as u8).eq_ignore_ascii_case(other as u8);
    }
    /// The value of `self` as a digit in `radix`: `0` to `9`, then `a` to `z` or `A` to `Z` for 10 to 35;
    /// None when it is not a digit below `radix`. Panics when `radix` is outside 2 to 36.
    pub const fn to_digit(self: char, radix: u32) Option<u32> {
        if radix < 2 || radix > 36 {
            panic("to_digit: radix must be in 2 to 36");
        }
        let c = self as u32;
        let mut d: u32 = 36; // not a digit in any radix
        if self.is_ascii_digit() {
            d = c - 48;
        } else if self.is_ascii_alphabetic() {
            d = (c | 0x20) - 87;
        }
        if d < radix {
            return Option::<u32>::Some(d);
        }
        return Option::<u32>::None;
    }
    /// The character of digit `num` in `radix`: `0` to `9`, then `a` to `z`; None when `num` is not below
    /// `radix`. Panics when `radix` is outside 2 to 36.
    pub const fn from_digit(num: u32, radix: u32) Option<char> {
        if radix < 2 || radix > 36 {
            panic("from_digit: radix must be in 2 to 36");
        }
        if num >= radix {
            return Option::<char>::None;
        }
        if num < 10 {
            return Option::<char>::Some((48 + num) as char);
        }
        return Option::<char>::Some((87 + num) as char);
    }
}

/// Move the value out of `slot`, installing `value` in its place: the ownership-safe way to take
/// a field out of a value that implements Free (a plain `let x = v.field;` is rejected there: the
/// destructor cannot run on a partial value). The raw-pointer read/write pair transfers ownership
/// without dropping either side; drop-on-assign deliberately ignores raw places.
pub const fn replace<T>(slot: &mut T, value: T) T {
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
pub const fn forget<T>(value: T) {
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
    /// The entry's key (`hidden` in `@reflect(hidden)`).
    pub name: str<'static>,
    /// Which of `b`, `i` and `s` holds the value.
    pub kind: MetaKind,
    /// The value of a `Bool` entry (true for a bare key), else false.
    pub b: bool,
    /// The value of an `Int` entry, else 0.
    pub i: i64,
    /// The value of a `Str` entry (its raw source bytes), else "".
    pub s: str<'static>,
}

/// One field of a reflected struct or union. `offset` is the byte offset in the C layout the
/// compiled program uses; for a union every field reports offset 0. `kind` is the tag of
/// the field's own type (one level: reflect that type itself to go deeper). `meta` holds the
/// declaration's `@reflect` entries, in written order.
pub struct FieldInfo {
    /// The field's name (`_0`, `_1`, .. for a tuple).
    pub name: str<'static>,
    /// The field's byte offset in the C layout (0 for every field of a union).
    pub offset: usize,
    /// The field's size in bytes.
    pub size: usize,
    /// The tag of the field's type, one level deep.
    pub kind: TypeTag,
    /// The field declaration's `@reflect` entries, in written order.
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
    /// The variant's name.
    pub name: str<'static>,
    /// The variant's runtime value: the declared constant, or the declaration index with payloads.
    pub tag: i32,
    /// The variant's number of payload values (0 for a unit variant).
    pub payload: usize,
    /// The variant declaration's `@reflect` entries, in written order.
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

/// One method a reflected type declares in an `extend` block, or a generic conformance whose bounds
/// it satisfies (`extend<T: B> T as I`) gives it: inherent or conformance, `self` receiver or
/// associated. ENUMERATION only: reflection cannot invoke a method (there is no value
/// call path through a descriptor); use the name to document, filter by `meta`, or dispatch by
/// hand. `arity` counts the value parameters with the `self` receiver excluded; `ret` is the
/// one-level tag of the return type (`Void` for none, for several, or for one that has no tag,
/// e.g. an unsubstituted generic). A conformance left fully inherited (`extend T as I {}`)
/// declares no methods, so its defaults are not listed. `meta` holds the declaration's `@reflect`
/// entries, in written order.
pub struct MethodInfo {
    /// The method's name.
    pub name: str<'static>,
    /// The method's value parameters, the `self` receiver excluded.
    pub arity: usize,
    /// Whether the method is `pub`.
    pub is_pub: bool,
    /// The tag of the return type, one level deep (`Void` for none, several, or an untagged one).
    pub ret: TypeTag,
    /// The method declaration's `@reflect` entries, in written order.
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
/// decl-backed or builtin type, across all modules, in declaration order, then the methods of the
/// generic conformances whose bounds the type satisfies.
pub struct TypeInfo {
    /// The type's name: a builtin's spelling or the declaration's name ("" for an anonymous kind).
    pub name: str<'static>,
    /// What sort of type it is.
    pub kind: TypeTag,
    /// The tag of the pointee, element or lane type (`Void` for another kind).
    pub elem: TypeTag, // beside `kind`: two 4-byte tags share one 8-byte slot
    /// The type's size in bytes.
    pub size: usize,
    /// The type's alignment in bytes.
    pub align: usize,
    /// An array's element count or a vector's lane count (0 for another kind).
    pub len: usize,
    /// The fields of a struct, tuple or union, in declaration order.
    pub fields: Slice<'static, FieldInfo>,
    /// The variants of an enum, in declaration order.
    pub variants: Slice<'static, VariantInfo>,
    /// The type declaration's `@reflect` entries, in written order.
    pub meta: Slice<'static, MetaInfo>,
    /// The methods the type declares, then those of the generic conformances that apply to it.
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
