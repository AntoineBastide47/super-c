// The compiler-rt routines the native backends call (`loader::Package::rt_builtins`): 128-bit division
// and remainder, 128-bit integer and float conversions, and on wasm 128-bit multiplication and the 64-bit
// multiply with overflow. glibc, the Windows C runtime and wasm export none of them (only the C
// toolchains' libgcc and compiler-rt archives hold them); macOS's libSystem does, so Apple's targets do
// not load this module.
//
// The cores compute on 64-bit halves, so no C compiler turns their arithmetic into a call of themselves,
// and give compiler-rt's results, out-of-range conversions included. Each target's entry points take
// compiler-rt's calling convention for a 128-bit value: two registers (System V, AAPCS64), two i64 and
// a result through a pointer first (wasm). Windows passes it through a pointer and returns it in xmm0,
// which no Super-C function can: the x86-64 backend calls `__sc_<name>` there, with the result through
// a pointer first, and the routines that return a float keep compiler-rt's names and convention.

/// A 128-bit value as its halves; the System V and AAPCS64 conventions return it as they return
/// `__int128`.
@platform(linux | android | windows | wasm)
struct Pair {
    pub lo: u64,
    pub hi: u64,
}

@platform(linux | android | windows | wasm)
extend Pair as Copy {}

@platform(linux | android | windows | wasm)
union F64 {
    pub f: f64,
    pub i: u64,
}

@platform(linux | android | windows | wasm)
union F32 {
    pub f: f32,
    pub i: u32,
}

@platform(linux | android | windows | wasm)
const fn bits(x: f64) u64 {
    let u = F64 { f: x };
    return u.i;
}

@platform(linux | android | windows | wasm)
const fn dbl(i: u64) f64 {
    let u = F64 { i: i };
    return u.f;
}

@platform(linux | android | windows | wasm)
const fn bitsf(x: f32) u32 {
    let u = F32 { f: x };
    return u.i;
}

@platform(linux | android | windows | wasm)
const fn flt(i: u32) f32 {
    let u = F32 { i: i };
    return u.f;
}

// ---- the cores ----------------------------------------------------------------------------------------

// The leading zero bits of (lo, hi).
@platform(linux | android | windows | wasm)
const fn clz(lo: u64, hi: u64) u32 {
    if hi != 0 {
        return hi.leading_zeros() as u32;
    }
    return 64 + lo.leading_zeros() as u32;
}

// (lo, hi) shifted left by `s` (below 128).
@platform(linux | android | windows | wasm)
const fn shl(lo: u64, hi: u64, s: u32) Pair {
    if s == 0 {
        return Pair { lo: lo, hi: hi };
    }
    if s >= 64 {
        return Pair { lo: 0, hi: lo << (s - 64) as u64 };
    }
    return Pair { lo: lo << s as u64, hi: hi << s as u64 | lo >> (64 - s) as u64 };
}

// (lo, hi) shifted right by `s` (below 128).
@platform(linux | android | windows | wasm)
const fn shr(lo: u64, hi: u64, s: u32) Pair {
    if s == 0 {
        return Pair { lo: lo, hi: hi };
    }
    if s >= 64 {
        return Pair { lo: hi >> (s - 64) as u64, hi: 0 };
    }
    return Pair { lo: lo >> s as u64 | hi << (64 - s) as u64, hi: hi >> s as u64 };
}

// The negation of `x`, modulo 2^128.
@platform(linux | android | windows | wasm)
const fn neg(x: Pair) Pair {
    return Pair { lo: x.lo.wrapping_neg(), hi: (~x.hi).wrapping_add((x.lo == 0) as u64) };
}

// The 128-bit product of `a` and `b`, from 32-bit pieces. No product or sum here overflows, and none is
// checked: wasm's check of a 64-bit product calls `__multi3`, this routine's caller.
@platform(linux | android | windows | wasm)
const fn mul64(a: u64, b: u64) Pair {
    let a0 = a & 0xFFFFFFFF;
    let a1 = a >> 32;
    let b0 = b & 0xFFFFFFFF;
    let b1 = b >> 32;
    let p00 = a0.wrapping_mul(b0);
    let p01 = a0.wrapping_mul(b1);
    let p10 = a1.wrapping_mul(b0);
    let p11 = a1.wrapping_mul(b1);
    let mid = (p00 >> 32).wrapping_add(p01 & 0xFFFFFFFF).wrapping_add(p10 & 0xFFFFFFFF);
    return Pair {
        lo: p00 & 0xFFFFFFFF | mid << 32,
        hi: p11.wrapping_add(p01 >> 32).wrapping_add(p10 >> 32).wrapping_add(mid >> 32),
    };
}

// The quotient (`rem` false) or remainder of a / b, unsigned (b nonzero): binary long division from the
// divisor aligned under the dividend's top bit, at most 128 steps.
@platform(linux | android | windows | wasm)
fn udivmod(a: Pair, b: Pair, rem: bool) Pair {
    if a.hi == 0 && b.hi == 0 {
        return if rem {
            Pair { lo: a.lo % b.lo, hi: 0 }
        } else {
            Pair { lo: a.lo / b.lo, hi: 0 }
        };
    }
    if b.hi > a.hi || b.hi == a.hi && b.lo > a.lo {
        return if rem {
            a
        } else {
            Pair { lo: 0, hi: 0 }
        };
    }
    let s = clz(b.lo, b.hi) - clz(a.lo, a.hi);
    let mut d = shl(b.lo, b.hi, s);
    let mut r = a;
    let mut q = Pair { lo: 0, hi: 0 };
    for _ in 0..s + 1 {
        q = shl(q.lo, q.hi, 1);
        if r.hi > d.hi || r.hi == d.hi && r.lo >= d.lo {
            let borrow = (r.lo < d.lo) as u64;
            r.lo = r.lo.wrapping_sub(d.lo);
            r.hi = r.hi.wrapping_sub(d.hi).wrapping_sub(borrow);
            q.lo |= 1;
        }
        d = shr(d.lo, d.hi, 1);
    }
    return if rem {
        r
    } else {
        q
    };
}

// The magnitude of signed `x`, and whether it is negative.
@platform(linux | android | windows | wasm)
fn magnitude(x: Pair) (Pair, bool) {
    if x.hi >> 63 == 0 {
        return (x, false);
    }
    return (neg(x), true);
}

@platform(linux | android | windows | wasm)
fn signed(u: Pair, negative: bool) Pair {
    if negative {
        return neg(u);
    }
    return u;
}

// Signed division and remainder: C's, truncating, the remainder taking the dividend's sign.
@platform(linux | android | windows | wasm)
fn sdivmod(a: Pair, b: Pair, rem: bool) Pair {
    let (ua, na) = magnitude(a);
    let (ub, nb) = magnitude(b);
    let r = udivmod(ua, ub, rem);
    return signed(
        r,
        if rem {
            na
        } else {
            na != nb
        },
    );
}

@platform(linux | android | windows | wasm)
fn mul(a: Pair, b: Pair) Pair {
    let p = mul64(a.lo, b.lo);
    return Pair { lo: p.lo, hi: p.hi.wrapping_add(a.lo.wrapping_mul(b.hi)).wrapping_add(a.hi.wrapping_mul(b.lo)) };
}

// The low `s` bits (1 to 64) set.
@platform(linux | android | windows | wasm)
const fn low_mask(s: u32) u64 {
    if s >= 64 {
        return 0xFFFFFFFFFFFFFFFF;
    }
    return (1u64 << s as u64) - 1;
}

// An unsigned 128-bit value as a float, rounded to nearest even: one conversion of its top 64 bits, the
// bits below folded into the lowest one (they only break ties), then an exact scaling.
@platform(linux | android | windows | wasm)
fn u_to_f64(x: Pair) f64 {
    if x.hi == 0 {
        return x.lo as f64;
    }
    let s = 64 - x.hi.leading_zeros() as u32;
    let t = shr(x.lo, x.hi, s).lo;
    let sticky = (x.lo & low_mask(s)) != 0;
    return (t | sticky as u64) as f64 * dbl(1023 + s as u64 << 52);
}

@platform(linux | android | windows | wasm)
fn u_to_f32(x: Pair) f32 {
    if x.hi == 0 {
        return x.lo as f32;
    }
    let s = 64 - x.hi.leading_zeros() as u32;
    let t = shr(x.lo, x.hi, s).lo;
    let sticky = (x.lo & low_mask(s)) != 0;
    return (t | sticky as u64) as f32 * flt(127 + s << 23);
}

@platform(linux | android | windows | wasm)
fn s_to_f64(x: Pair) f64 {
    let (u, n) = magnitude(x);
    let r = u_to_f64(u);
    if n {
        return -r;
    }
    return r;
}

@platform(linux | android | windows | wasm)
fn s_to_f32(x: Pair) f32 {
    let (u, n) = magnitude(x);
    let r = u_to_f32(u);
    if n {
        return -r;
    }
    return r;
}

// The integer part of a float of significand `m` (its implicit bit set), unbiased exponent `e` (0 to
// 127) and `frac` fraction bits.
@platform(linux | android | windows | wasm)
fn int_part(m: u64, e: u32, frac: u32) Pair {
    if e < frac {
        return Pair { lo: m >> (frac - e) as u64, hi: 0 };
    }
    return shl(m, 0, e - frac);
}

@platform(linux | android | windows | wasm)
const ONES: Pair = Pair { lo: 0xFFFFFFFFFFFFFFFF, hi: 0xFFFFFFFFFFFFFFFF };
@platform(linux | android | windows | wasm)
const MIN: Pair = Pair { lo: 0, hi: 0x8000000000000000 };
@platform(linux | android | windows | wasm)
const MAX: Pair = Pair { lo: 0xFFFFFFFFFFFFFFFF, hi: 0x7FFFFFFFFFFFFFFF };

// A float of bits `b` (`fbits` fraction and `ebits` exponent bits) to an integer, signed or not:
// truncated, saturated past the range (NaN by its sign), as compiler-rt's.
@platform(linux | android | windows | wasm)
fn to_int(b: u64, fbits: u32, ebits: u32, sgn: bool) Pair {
    let bias = (1i64 << (ebits - 1) as i64) - 1;
    let e = (b >> fbits as u64 & (1u64 << ebits as u64) - 1) as i64 - bias;
    let negative = b >> (fbits + ebits) as u64 != 0;
    if !sgn && negative || e < 0 {
        return Pair { lo: 0, hi: 0 };
    }
    if !sgn && e >= 128 {
        return ONES;
    }
    if sgn && e >= 127 {
        return if negative {
            MIN
        } else {
            MAX
        };
    }
    let m = b & (1u64 << fbits as u64) - 1 | 1u64 << fbits as u64;
    return signed(int_part(m, e as u32, fbits), negative);
}

// ---- System V and AAPCS64: a 128-bit value in two registers -------------------------------------------

@platform(linux | android)
@export("__udivti3")
fn udivti3(alo: u64, ahi: u64, blo: u64, bhi: u64) Pair {
    return udivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, false);
}

@platform(linux | android)
@export("__umodti3")
fn umodti3(alo: u64, ahi: u64, blo: u64, bhi: u64) Pair {
    return udivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, true);
}

@platform(linux | android)
@export("__divti3")
fn divti3(alo: u64, ahi: u64, blo: u64, bhi: u64) Pair {
    return sdivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, false);
}

@platform(linux | android)
@export("__modti3")
fn modti3(alo: u64, ahi: u64, blo: u64, bhi: u64) Pair {
    return sdivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, true);
}

@platform(linux | android)
@export("__floatuntidf")
fn floatuntidf(lo: u64, hi: u64) f64 {
    return u_to_f64(Pair { lo: lo, hi: hi });
}

@platform(linux | android)
@export("__floatuntisf")
fn floatuntisf(lo: u64, hi: u64) f32 {
    return u_to_f32(Pair { lo: lo, hi: hi });
}

@platform(linux | android)
@export("__floattidf")
fn floattidf(lo: u64, hi: u64) f64 {
    return s_to_f64(Pair { lo: lo, hi: hi });
}

@platform(linux | android)
@export("__floattisf")
fn floattisf(lo: u64, hi: u64) f32 {
    return s_to_f32(Pair { lo: lo, hi: hi });
}

@platform(linux | android)
@export("__fixunsdfti")
fn fixunsdfti(a: f64) Pair {
    return to_int(bits(a), 52, 11, false);
}

@platform(linux | android)
@export("__fixunssfti")
fn fixunssfti(a: f32) Pair {
    return to_int(bitsf(a), 23, 8, false);
}

@platform(linux | android)
@export("__fixdfti")
fn fixdfti(a: f64) Pair {
    return to_int(bits(a), 52, 11, true);
}

@platform(linux | android)
@export("__fixsfti")
fn fixsfti(a: f32) Pair {
    return to_int(bitsf(a), 23, 8, true);
}

// ---- wasm: a 128-bit argument as two i64, a 128-bit result through a pointer first --------------------

@platform(wasm)
@export("__udivti3")
fn wasm_udivti3(out: *mut Pair, alo: u64, ahi: u64, blo: u64, bhi: u64) {
    unsafe *out = udivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, false);
}

@platform(wasm)
@export("__umodti3")
fn wasm_umodti3(out: *mut Pair, alo: u64, ahi: u64, blo: u64, bhi: u64) {
    unsafe *out = udivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, true);
}

@platform(wasm)
@export("__divti3")
fn wasm_divti3(out: *mut Pair, alo: u64, ahi: u64, blo: u64, bhi: u64) {
    unsafe *out = sdivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, false);
}

@platform(wasm)
@export("__modti3")
fn wasm_modti3(out: *mut Pair, alo: u64, ahi: u64, blo: u64, bhi: u64) {
    unsafe *out = sdivmod(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi }, true);
}

@platform(wasm)
@export("__multi3")
fn wasm_multi3(out: *mut Pair, alo: u64, ahi: u64, blo: u64, bhi: u64) {
    unsafe *out = mul(Pair { lo: alo, hi: ahi }, Pair { lo: blo, hi: bhi });
}

@platform(wasm)
@export("__floatuntidf")
fn wasm_floatuntidf(lo: u64, hi: u64) f64 {
    return u_to_f64(Pair { lo: lo, hi: hi });
}

@platform(wasm)
@export("__floatuntisf")
fn wasm_floatuntisf(lo: u64, hi: u64) f32 {
    return u_to_f32(Pair { lo: lo, hi: hi });
}

@platform(wasm)
@export("__floattidf")
fn wasm_floattidf(lo: u64, hi: u64) f64 {
    return s_to_f64(Pair { lo: lo, hi: hi });
}

@platform(wasm)
@export("__floattisf")
fn wasm_floattisf(lo: u64, hi: u64) f32 {
    return s_to_f32(Pair { lo: lo, hi: hi });
}

@platform(wasm)
@export("__fixunsdfti")
fn wasm_fixunsdfti(out: *mut Pair, a: f64) {
    unsafe *out = to_int(bits(a), 52, 11, false);
}

@platform(wasm)
@export("__fixunssfti")
fn wasm_fixunssfti(out: *mut Pair, a: f32) {
    unsafe *out = to_int(bitsf(a), 23, 8, false);
}

@platform(wasm)
@export("__fixdfti")
fn wasm_fixdfti(out: *mut Pair, a: f64) {
    unsafe *out = to_int(bits(a), 52, 11, true);
}

@platform(wasm)
@export("__fixsfti")
fn wasm_fixsfti(out: *mut Pair, a: f32) {
    unsafe *out = to_int(bitsf(a), 23, 8, true);
}

// a * b with `*overflow` set when the product does not fit, as compiler-rt computes it.
@platform(wasm)
@export("__mulodi4")
fn mulodi4(a: i64, b: i64, overflow: *mut i32) i64 {
    let min: i64 = -9223372036854775807 - 1;
    let max: i64 = 9223372036854775807;
    unsafe *overflow = 0;
    let result = a.wrapping_mul(b);
    if a == min {
        if b != 0 && b != 1 {
            unsafe *overflow = 1;
        }
        return result;
    }
    if b == min {
        if a != 0 && a != 1 {
            unsafe *overflow = 1;
        }
        return result;
    }
    let sa = a >> 63;
    let abs_a = (a ^ sa) - sa;
    let sb = b >> 63;
    let abs_b = (b ^ sb) - sb;
    if abs_a < 2 || abs_b < 2 {
        return result;
    }
    if sa == sb {
        if abs_a > max / abs_b {
            unsafe *overflow = 1;
        }
    } else if abs_a > min / -abs_b {
        unsafe *overflow = 1;
    }
    return result;
}

// ---- Windows x64: a 128-bit argument through a pointer ------------------------------------------------

@platform(windows)
@export("__sc_udivti3")
fn win_udivti3(out: *mut Pair, a: *const Pair, b: *const Pair) {
    unsafe *out = udivmod(unsafe *a, unsafe *b, false);
}

@platform(windows)
@export("__sc_umodti3")
fn win_umodti3(out: *mut Pair, a: *const Pair, b: *const Pair) {
    unsafe *out = udivmod(unsafe *a, unsafe *b, true);
}

@platform(windows)
@export("__sc_divti3")
fn win_divti3(out: *mut Pair, a: *const Pair, b: *const Pair) {
    unsafe *out = sdivmod(unsafe *a, unsafe *b, false);
}

@platform(windows)
@export("__sc_modti3")
fn win_modti3(out: *mut Pair, a: *const Pair, b: *const Pair) {
    unsafe *out = sdivmod(unsafe *a, unsafe *b, true);
}

@platform(windows)
@export("__floatuntidf")
fn win_floatuntidf(a: *const Pair) f64 {
    return u_to_f64(unsafe *a);
}

@platform(windows)
@export("__floatuntisf")
fn win_floatuntisf(a: *const Pair) f32 {
    return u_to_f32(unsafe *a);
}

@platform(windows)
@export("__floattidf")
fn win_floattidf(a: *const Pair) f64 {
    return s_to_f64(unsafe *a);
}

@platform(windows)
@export("__floattisf")
fn win_floattisf(a: *const Pair) f32 {
    return s_to_f32(unsafe *a);
}

@platform(windows)
@export("__sc_fixunsdfti")
fn win_fixunsdfti(out: *mut Pair, a: f64) {
    unsafe *out = to_int(bits(a), 52, 11, false);
}

@platform(windows)
@export("__sc_fixunssfti")
fn win_fixunssfti(out: *mut Pair, a: f32) {
    unsafe *out = to_int(bitsf(a), 23, 8, false);
}

@platform(windows)
@export("__sc_fixdfti")
fn win_fixdfti(out: *mut Pair, a: f64) {
    unsafe *out = to_int(bits(a), 52, 11, true);
}

@platform(windows)
@export("__sc_fixsfti")
fn win_fixsfti(out: *mut Pair, a: f32) {
    unsafe *out = to_int(bitsf(a), 23, 8, true);
}

// ---- the Windows C library's static part --------------------------------------------------------------

/// The stack canaries' value (`-fstack-protector`), as mingw-w64's static library defines it: a
/// constructor the driver adds fills it at start (`native_registry`).
@platform(windows)
@export("__sc_ucrt___stack_chk_guard")
pub static mut STACK_CHK_GUARD: u64 = 0;

@platform(windows)
extern "C" {
    fn abort() void;
}

/// A function's canary changed before it returned: its stack memory overflowed.
@platform(windows)
@export("__sc_ucrt___stack_chk_fail")
pub fn stack_chk_fail() {
    unsafe abort();
}

// The C runtime DLL (ucrtbase.dll) exports none of these: its headers define them inline over the
// `__stdio_common_*` exports, and mingw-w64's import library carries them as code. The own linker binds
// each undefined `<name>` to `__sc_ucrt_<name>` (`link::pe`); the options are UCRT's defaults, as
// mingw-w64's definitions pass them.
@platform(windows)
extern "C" "stdio.h" {
    type FILE;
    fn __stdio_common_vsprintf(options: u64, buf: *mut char, n: usize, fmt: *const char, locale: *mut void, ap: va_list) i32;
    fn __stdio_common_vfprintf(options: u64, f: *mut FILE, fmt: *const char, locale: *mut void, ap: va_list) i32;
    fn __stdio_common_vsscanf(
        options: u64,
        buf: *const char,
        n: usize,
        fmt: *const char,
        locale: *mut void,
        ap: va_list,
    ) i32;
    fn __stdio_common_vfscanf(options: u64, f: *mut FILE, fmt: *const char, locale: *mut void, ap: va_list) i32;
    fn __acrt_iob_func(i: u32) *mut FILE;
}

// `snprintf`'s C99 behavior: the length the whole output has, the buffer always terminated.
@platform(windows)
const STANDARD_SNPRINTF: u64 = 2;

@platform(windows)
@export("__sc_ucrt_snprintf")
fn ucrt_snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vsprintf(STANDARD_SNPRINTF, buf, n, fmt, null, ap);
    va_end(ap);
    return if r < 0 {
        -1
    } else {
        r
    };
}

@platform(windows)
@export("__sc_ucrt_fprintf")
fn ucrt_fprintf(f: *mut FILE, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vfprintf(0, f, fmt, null, ap);
    va_end(ap);
    return r;
}

@platform(windows)
@export("__sc_ucrt_printf")
fn ucrt_printf(fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vfprintf(0, __acrt_iob_func(1), fmt, null, ap);
    va_end(ap);
    return r;
}

@platform(windows)
@export("__sc_ucrt_sscanf")
fn ucrt_sscanf(buf: *const char, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vsscanf(0, buf, 0xFFFFFFFFFFFFFFFF, fmt, null, ap);
    va_end(ap);
    return r;
}

@platform(windows)
@export("__sc_ucrt_fscanf")
fn ucrt_fscanf(f: *mut FILE, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vfscanf(0, f, fmt, null, ap);
    va_end(ap);
    return r;
}

@platform(windows)
@export("__sc_ucrt_scanf")
fn ucrt_scanf(fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let r = unsafe __stdio_common_vfscanf(0, __acrt_iob_func(0), fmt, null, ap);
    va_end(ap);
    return r;
}

@platform(windows)
@export("__sc_ucrt_fabsf")
fn ucrt_fabsf(x: f32) f32 {
    return flt(bitsf(x) & 0x7FFFFFFF);
}

@platform(windows)
extern "C" "math.h" {
    fn ldexp(x: f64, e: i32) f64;
    fn frexp(x: f64, e: *mut i32) f64;
}

// The float forms through the double ones, as the UCRT headers define them: exact, then one rounding.
@platform(windows)
@export("__sc_ucrt_ldexpf")
fn ucrt_ldexpf(x: f32, e: i32) f32 {
    return (unsafe ldexp(x, e)) as f32;
}

@platform(windows)
@export("__sc_ucrt_frexpf")
fn ucrt_frexpf(x: f32, e: *mut i32) f32 {
    return (unsafe frexp(x, e)) as f32;
}
