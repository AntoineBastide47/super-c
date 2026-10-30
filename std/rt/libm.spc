// wasm's C math library (`loader::Package::rt_libm`), with `std::rt::libc`: the <math.h> functions the
// prelude, the ffi bindings and the compiler call, as wasi-libc computes them. `sqrt`, `floor`, `ceil`,
// `trunc`, `rint`, `nearbyint`, `fabs` and `copysign` are single wasm instructions, as wasi-libc compiles
// them; the others are ports of musl's code (FreeBSD's msun and ARM's optimized routines), so every
// result is wasi-libc's to the bit. See LICENSE in this directory.
//
// wasm has no floating-point exceptions and one rounding mode, to nearest: musl's code that only raises
// an exception (`FORCE_EVAL`) is left out. Its unsigned arithmetic that wraps on purpose uses the
// wrapping methods.

// ---- the instruction functions ---------------------------------------------------------------------------

asm(M"(
.globl sqrt
.type sqrt,@function
sqrt:
.functype sqrt (f64) -> (f64)
local.get 0
f64.sqrt
end_function
.globl sqrtf
.type sqrtf,@function
sqrtf:
.functype sqrtf (f32) -> (f32)
local.get 0
f32.sqrt
end_function
.globl floor
.type floor,@function
floor:
.functype floor (f64) -> (f64)
local.get 0
f64.floor
end_function
.globl floorf
.type floorf,@function
floorf:
.functype floorf (f32) -> (f32)
local.get 0
f32.floor
end_function
.globl ceil
.type ceil,@function
ceil:
.functype ceil (f64) -> (f64)
local.get 0
f64.ceil
end_function
.globl ceilf
.type ceilf,@function
ceilf:
.functype ceilf (f32) -> (f32)
local.get 0
f32.ceil
end_function
.globl trunc
.type trunc,@function
trunc:
.functype trunc (f64) -> (f64)
local.get 0
f64.trunc
end_function
.globl truncf
.type truncf,@function
truncf:
.functype truncf (f32) -> (f32)
local.get 0
f32.trunc
end_function
.globl rint
.type rint,@function
rint:
.functype rint (f64) -> (f64)
local.get 0
f64.nearest
end_function
.globl rintf
.type rintf,@function
rintf:
.functype rintf (f32) -> (f32)
local.get 0
f32.nearest
end_function
.globl nearbyint
.type nearbyint,@function
nearbyint:
.functype nearbyint (f64) -> (f64)
local.get 0
f64.nearest
end_function
.globl nearbyintf
.type nearbyintf,@function
nearbyintf:
.functype nearbyintf (f32) -> (f32)
local.get 0
f32.nearest
end_function
.globl fabs
.type fabs,@function
fabs:
.functype fabs (f64) -> (f64)
local.get 0
f64.abs
end_function
.globl fabsf
.type fabsf,@function
fabsf:
.functype fabsf (f32) -> (f32)
local.get 0
f32.abs
end_function
.globl copysign
.type copysign,@function
copysign:
.functype copysign (f64, f64) -> (f64)
local.get 0
local.get 1
f64.copysign
end_function
.globl copysignf
.type copysignf,@function
copysignf:
.functype copysignf (f32, f32) -> (f32)
local.get 0
local.get 1
f32.copysign
end_function
)");

// The functions above, as this module calls them.
extern "C" {
    @import("sqrt")
    fn sqrt_i(x: f64) f64;
    @import("sqrtf")
    fn sqrtf_i(x: f32) f32;
    @import("floor")
    fn floor_i(x: f64) f64;
    @import("floorf")
    fn floorf_i(x: f32) f32;
    @import("fabs")
    fn fabs_i(x: f64) f64;
    @import("fabsf")
    fn fabsf_i(x: f32) f32;
}

// ---- bits ------------------------------------------------------------------------------------------------

union U64 {
    pub f: f64,
    pub i: u64,
}

union U32 {
    pub f: f32,
    pub i: u32,
}

const fn bits(x: f64) u64 {
    let u = U64 { f: x };
    return u.i;
}

const fn dbl(i: u64) f64 {
    let u = U64 { i: i };
    return u.f;
}

const fn bitsf(x: f32) u32 {
    let u = U32 { f: x };
    return u.i;
}

const fn flt(i: u32) f32 {
    let u = U32 { i: i };
    return u.f;
}

// The high and low words of a double, and a double from them (musl's EXTRACT_WORDS and INSERT_WORDS).
const fn hi(x: f64) u32 {
    return (bits(x) >> 32) as u32;
}

const fn lo(x: f64) u32 {
    return bits(x) as u32;
}

const fn words(h: u32, l: u32) f64 {
    return dbl(h as u64 << 32 | l as u64);
}

fn sqrt(x: f64) f64 {
    return unsafe sqrt_i(x);
}

fn sqrtf(x: f32) f32 {
    return unsafe sqrtf_i(x);
}

fn floor(x: f64) f64 {
    return unsafe floor_i(x);
}

fn floorf(x: f32) f32 {
    return unsafe floorf_i(x);
}

fn fabs(x: f64) f64 {
    return unsafe fabs_i(x);
}

fn fabsf(x: f32) f32 {
    return unsafe fabsf_i(x);
}

const INF: f64 = dbl(0x7ff0000000000000);
const INFF: f32 = flt(0x7f800000);

const fn isnan(x: f64) bool {
    return x != x;
}

const fn isnanf(x: f32) bool {
    return x != x;
}

// musl's `__math_*`: the results of the special cases, computed so they are correctly signed.
const fn xflow(sign: u32, y: f64) f64 {
    return if sign != 0 {
        -y
    } else {
        y
    } * y;
}

const fn oflow(sign: u32) f64 {
    return xflow(sign, 0x1p769);
}

const fn uflow(sign: u32) f64 {
    return xflow(sign, 0x1p-767);
}

const fn invalid(x: f64) f64 {
    return (x - x) / (x - x);
}

const fn divzero(sign: u32) f64 {
    return if sign != 0 {
        -1.0
    } else {
        1.0
    } / 0.0;
}

const fn xflowf(sign: u32, y: f32) f32 {
    return if sign != 0 {
        -y
    } else {
        y
    } * y;
}

const fn oflowf(sign: u32) f32 {
    return xflowf(sign, 0x1p97f32);
}

const fn uflowf(sign: u32) f32 {
    return xflowf(sign, 0x1p-95f32);
}

const fn invalidf(x: f32) f32 {
    return (x - x) / (x - x);
}

const fn divzerof(sign: u32) f32 {
    return if sign != 0 {
        -1.0f32
    } else {
        1.0f32
    } / 0.0f32;
}

// ---- rounding, remainders, min and max -------------------------------------------------------------------

const TOINT: f64 = 1.0 / 2.220446049250313e-16;
const TOINTF: f32 = 1.0f32 / 1.1920929e-7f32;

/// x rounded to the nearest integer, a half away from zero.
@export("round")
pub const fn round(x0: f64) f64 {
    let mut x = x0;
    let ui = bits(x);
    let e = (ui >> 52 & 0x7ff) as i32;
    if e >= 0x3ff + 52 {
        return x;
    }
    if ui >> 63 != 0 {
        x = -x;
    }
    if e < 0x3ff - 1 {
        return 0.0 * x0;
    }
    let mut y = x + TOINT - TOINT - x;
    if y > 0.5 {
        y = y + x - 1.0;
    } else if y <= -0.5 {
        y = y + x + 1.0;
    } else {
        y = y + x;
    }
    if ui >> 63 != 0 {
        y = -y;
    }
    return y;
}

/// x rounded to the nearest integer, a half away from zero.
@export("roundf")
pub const fn roundf(x0: f32) f32 {
    let mut x = x0;
    let ui = bitsf(x);
    let e = (ui >> 23 & 0xff) as i32;
    if e >= 0x7f + 23 {
        return x;
    }
    if ui >> 31 != 0 {
        x = -x;
    }
    if e < 0x7f - 1 {
        return 0.0f32 * x0;
    }
    let mut y = x + TOINTF - TOINTF - x;
    if y > 0.5f32 {
        y = y + x - 1.0f32;
    } else if y <= -0.5f32 {
        y = y + x + 1.0f32;
    } else {
        y = y + x;
    }
    if ui >> 31 != 0 {
        y = -y;
    }
    return y;
}

/// x - n*y, n the quotient truncated, exactly.
@export("fmod")
pub const fn fmod(x: f64, y: f64) f64 {
    let ux = bits(x);
    let mut uy = bits(y);
    let mut ex = (ux >> 52 & 0x7ff) as i32;
    let mut ey = (uy >> 52 & 0x7ff) as i32;
    let sx = ux >> 63;
    let mut uxi = ux;
    if uy << 1 == 0 || isnan(y) || ex == 0x7ff {
        return x * y / (x * y);
    }
    if uxi << 1 <= uy << 1 {
        if uxi << 1 == uy << 1 {
            return 0.0 * x;
        }
        return x;
    }
    // Normalize x and y.
    if ex == 0 {
        let mut i = uxi << 12;
        while i >> 63 == 0 {
            ex -= 1;
            i <<= 1;
        }
        uxi <<= (1 - ex) as u64;
    } else {
        uxi &= ~0u64 >> 12;
        uxi |= 1u64 << 52;
    }
    if ey == 0 {
        let mut i = uy << 12;
        while i >> 63 == 0 {
            ey -= 1;
            i <<= 1;
        }
        uy <<= (1 - ey) as u64;
    } else {
        uy &= ~0u64 >> 12;
        uy |= 1u64 << 52;
    }
    // x mod y
    while ex > ey {
        let i = uxi.wrapping_sub(uy);
        if i >> 63 == 0 {
            if i == 0 {
                return 0.0 * x;
            }
            uxi = i;
        }
        uxi <<= 1;
        ex -= 1;
    }
    let i = uxi.wrapping_sub(uy);
    if i >> 63 == 0 {
        if i == 0 {
            return 0.0 * x;
        }
        uxi = i;
    }
    while uxi >> 52 == 0 {
        uxi <<= 1;
        ex -= 1;
    }
    // Scale the result.
    if ex > 0 {
        uxi -= 1u64 << 52;
        uxi |= ex as u64 << 52;
    } else {
        uxi >>= (1 - ex) as u64;
    }
    uxi |= sx << 63;
    return dbl(uxi);
}

/// x - n*y, n the quotient truncated, exactly.
@export("fmodf")
pub const fn fmodf(x: f32, y: f32) f32 {
    let ux = bitsf(x);
    let mut uy = bitsf(y);
    let mut ex = (ux >> 23 & 0xff) as i32;
    let mut ey = (uy >> 23 & 0xff) as i32;
    let sx = ux & 0x80000000;
    let mut uxi = ux;
    if uy << 1 == 0 || isnanf(y) || ex == 0xff {
        return x * y / (x * y);
    }
    if uxi << 1 <= uy << 1 {
        if uxi << 1 == uy << 1 {
            return 0.0f32 * x;
        }
        return x;
    }
    if ex == 0 {
        let mut i = uxi << 9;
        while i >> 31 == 0 {
            ex -= 1;
            i <<= 1;
        }
        uxi <<= (1 - ex) as u32;
    } else {
        uxi &= ~0u32 >> 9;
        uxi |= 1u32 << 23;
    }
    if ey == 0 {
        let mut i = uy << 9;
        while i >> 31 == 0 {
            ey -= 1;
            i <<= 1;
        }
        uy <<= (1 - ey) as u32;
    } else {
        uy &= ~0u32 >> 9;
        uy |= 1u32 << 23;
    }
    while ex > ey {
        let i = uxi.wrapping_sub(uy);
        if i >> 31 == 0 {
            if i == 0 {
                return 0.0f32 * x;
            }
            uxi = i;
        }
        uxi <<= 1;
        ex -= 1;
    }
    let i = uxi.wrapping_sub(uy);
    if i >> 31 == 0 {
        if i == 0 {
            return 0.0f32 * x;
        }
        uxi = i;
    }
    while uxi >> 23 == 0 {
        uxi <<= 1;
        ex -= 1;
    }
    if ex > 0 {
        uxi -= 1u32 << 23;
        uxi |= ex as u32 << 23;
    } else {
        uxi >>= (1 - ex) as u32;
    }
    uxi |= sx;
    return flt(uxi);
}

/// x - n*y, n the quotient rounded to nearest even; the low bits of n through `quo`.
@export("remquo")
pub const fn remquo(x0: f64, y0: f64, quo: *mut i32) f64 {
    let mut x = x0;
    let mut y = y0;
    let ux = bits(x);
    let mut uy = bits(y);
    let mut ex = (ux >> 52 & 0x7ff) as i32;
    let mut ey = (uy >> 52 & 0x7ff) as i32;
    let sx = ux >> 63 != 0;
    let sy = uy >> 63 != 0;
    let mut q: u32 = 0;
    let mut uxi = ux;
    unsafe *quo = 0;
    if uy << 1 == 0 || isnan(y) || ex == 0x7ff {
        return x * y / (x * y);
    }
    if ux << 1 == 0 {
        return x;
    }
    if ex == 0 {
        let mut i = uxi << 12;
        while i >> 63 == 0 {
            ex -= 1;
            i <<= 1;
        }
        uxi <<= (1 - ex) as u64;
    } else {
        uxi &= ~0u64 >> 12;
        uxi |= 1u64 << 52;
    }
    if ey == 0 {
        let mut i = uy << 12;
        while i >> 63 == 0 {
            ey -= 1;
            i <<= 1;
        }
        uy <<= (1 - ey) as u64;
    } else {
        uy &= ~0u64 >> 12;
        uy |= 1u64 << 52;
    }
    let mut skip = false;
    if ex < ey {
        if ex + 1 != ey {
            return x;
        }
        skip = true;
    }
    if !skip {
        while ex > ey {
            let i = uxi.wrapping_sub(uy);
            if i >> 63 == 0 {
                uxi = i;
                q += 1;
            }
            uxi <<= 1;
            q <<= 1;
            ex -= 1;
        }
        let i = uxi.wrapping_sub(uy);
        if i >> 63 == 0 {
            uxi = i;
            q += 1;
        }
        if uxi == 0 {
            ex = -60;
        } else {
            while uxi >> 52 == 0 {
                uxi <<= 1;
                ex -= 1;
            }
        }
    }
    if ex > 0 {
        uxi -= 1u64 << 52;
        uxi |= ex as u64 << 52;
    } else {
        uxi >>= (1 - ex) as u64;
    }
    x = dbl(uxi);
    if sy {
        y = -y;
    }
    if ex == ey || ex + 1 == ey && (2.0 * x > y || 2.0 * x == y && q % 2 != 0) {
        x -= y;
        q += 1;
    }
    q &= 0x7fffffff;
    unsafe *quo = if sx != sy {
        0 - q as i32
    } else {
        q as i32
    };
    return if sx {
        -x
    } else {
        x
    };
}

/// x - n*y, n the quotient rounded to nearest even; the low bits of n through `quo`.
@export("remquof")
pub const fn remquof(x0: f32, y0: f32, quo: *mut i32) f32 {
    let mut x = x0;
    let mut y = y0;
    let ux = bitsf(x);
    let mut uy = bitsf(y);
    let mut ex = (ux >> 23 & 0xff) as i32;
    let mut ey = (uy >> 23 & 0xff) as i32;
    let sx = ux >> 31 != 0;
    let sy = uy >> 31 != 0;
    let mut q: u32 = 0;
    let mut uxi = ux;
    unsafe *quo = 0;
    if uy << 1 == 0 || isnanf(y) || ex == 0xff {
        return x * y / (x * y);
    }
    if ux << 1 == 0 {
        return x;
    }
    if ex == 0 {
        let mut i = uxi << 9;
        while i >> 31 == 0 {
            ex -= 1;
            i <<= 1;
        }
        uxi <<= (1 - ex) as u32;
    } else {
        uxi &= ~0u32 >> 9;
        uxi |= 1u32 << 23;
    }
    if ey == 0 {
        let mut i = uy << 9;
        while i >> 31 == 0 {
            ey -= 1;
            i <<= 1;
        }
        uy <<= (1 - ey) as u32;
    } else {
        uy &= ~0u32 >> 9;
        uy |= 1u32 << 23;
    }
    let mut skip = false;
    if ex < ey {
        if ex + 1 != ey {
            return x;
        }
        skip = true;
    }
    if !skip {
        while ex > ey {
            let i = uxi.wrapping_sub(uy);
            if i >> 31 == 0 {
                uxi = i;
                q += 1;
            }
            uxi <<= 1;
            q <<= 1;
            ex -= 1;
        }
        let i = uxi.wrapping_sub(uy);
        if i >> 31 == 0 {
            uxi = i;
            q += 1;
        }
        if uxi == 0 {
            ex = -30;
        } else {
            while uxi >> 23 == 0 {
                uxi <<= 1;
                ex -= 1;
            }
        }
    }
    if ex > 0 {
        uxi -= 1u32 << 23;
        uxi |= ex as u32 << 23;
    } else {
        uxi >>= (1 - ex) as u32;
    }
    x = flt(uxi);
    if sy {
        y = -y;
    }
    if ex == ey || ex + 1 == ey && (2.0f32 * x > y || 2.0f32 * x == y && q % 2 != 0) {
        x -= y;
        q += 1;
    }
    q &= 0x7fffffff;
    unsafe *quo = if sx != sy {
        0 - q as i32
    } else {
        q as i32
    };
    return if sx {
        -x
    } else {
        x
    };
}

/// x - n*y, n the quotient rounded to nearest even.
@export("remainder")
pub const fn remainder(x: f64, y: f64) f64 {
    let mut q: i32 = 0;
    return remquo(x, y, &mut q);
}

/// x - n*y, n the quotient rounded to nearest even.
@export("remainderf")
pub const fn remainderf(x: f32, y: f32) f32 {
    let mut q: i32 = 0;
    return remquof(x, y, &mut q);
}

/// The smaller of x and y, a NaN ignored, -0 below +0.
@export("fmin")
pub const fn fmin(x: f64, y: f64) f64 {
    if isnan(x) {
        return y;
    }
    if isnan(y) {
        return x;
    }
    let sx = bits(x) >> 63 != 0;
    if sx != (bits(y) >> 63 != 0) {
        return if sx {
            x
        } else {
            y
        };
    }
    return if x < y {
        x
    } else {
        y
    };
}

/// The larger of x and y, a NaN ignored, +0 above -0.
@export("fmax")
pub const fn fmax(x: f64, y: f64) f64 {
    if isnan(x) {
        return y;
    }
    if isnan(y) {
        return x;
    }
    let sx = bits(x) >> 63 != 0;
    if sx != (bits(y) >> 63 != 0) {
        return if sx {
            y
        } else {
            x
        };
    }
    return if x < y {
        y
    } else {
        x
    };
}

/// The smaller of x and y, a NaN ignored, -0 below +0.
@export("fminf")
pub const fn fminf(x: f32, y: f32) f32 {
    if isnanf(x) {
        return y;
    }
    if isnanf(y) {
        return x;
    }
    let sx = bitsf(x) >> 31 != 0;
    if sx != (bitsf(y) >> 31 != 0) {
        return if sx {
            x
        } else {
            y
        };
    }
    return if x < y {
        x
    } else {
        y
    };
}

/// The larger of x and y, a NaN ignored, +0 above -0.
@export("fmaxf")
pub const fn fmaxf(x: f32, y: f32) f32 {
    if isnanf(x) {
        return y;
    }
    if isnanf(y) {
        return x;
    }
    let sx = bitsf(x) >> 31 != 0;
    if sx != (bitsf(y) >> 31 != 0) {
        return if sx {
            y
        } else {
            x
        };
    }
    return if x < y {
        y
    } else {
        x
    };
}

/// x * 2^n, rounded once.
@export("scalbn")
pub const fn scalbn(x: f64, n0: i32) f64 {
    let mut n = n0;
    let mut y = x;
    if n > 1023 {
        y *= 0x1p1023;
        n -= 1023;
        if n > 1023 {
            y *= 0x1p1023;
            n -= 1023;
            if n > 1023 {
                n = 1023;
            }
        }
    } else if n < -1022 {
        // Two steps, so a subnormal result rounds once.
        y *= 0x1p-1022 * 0x1p53;
        n += 1022 - 53;
        if n < -1022 {
            y *= 0x1p-1022 * 0x1p53;
            n += 1022 - 53;
            if n < -1022 {
                n = -1022;
            }
        }
    }
    return y * dbl((0x3ff + n) as u64 << 52);
}

/// x * 2^n, rounded once.
@export("scalbnf")
pub const fn scalbnf(x: f32, n0: i32) f32 {
    let mut n = n0;
    let mut y = x;
    if n > 127 {
        y *= 0x1p127f32;
        n -= 127;
        if n > 127 {
            y *= 0x1p127f32;
            n -= 127;
            if n > 127 {
                n = 127;
            }
        }
    } else if n < -126 {
        y *= 0x1p-126f32 * 0x1p24f32;
        n += 126 - 24;
        if n < -126 {
            y *= 0x1p-126f32 * 0x1p24f32;
            n += 126 - 24;
            if n < -126 {
                n = -126;
            }
        }
    }
    return y * flt((0x7f + n) as u32 << 23);
}

/// x * 2^n.
@export("ldexp")
pub const fn ldexp(x: f64, n: i32) f64 {
    return scalbn(x, n);
}

/// x * 2^n.
@export("ldexpf")
pub const fn ldexpf(x: f32, n: i32) f32 {
    return scalbnf(x, n);
}

// ---- fused multiply-add ----------------------------------------------------------------------------------

// A finite nonzero double as m * 2^e with m a 54-bit integer (the significand doubled), or e >= ZEROINFNAN
// for zero, an infinity or a NaN.
const ZEROINFNAN: i32 = 0x7ff - 0x3ff - 52 - 1;

struct Num {
    pub m: u64,
    pub e: i32,
    pub sign: i32,
}

const fn normalize(x: f64) Num {
    let mut ix = bits(x);
    let mut e = (ix >> 52) as i32;
    let sign = e & 0x800;
    e &= 0x7ff;
    if e == 0 {
        ix = bits(x * 0x1p63);
        e = (ix >> 52 & 0x7ff) as i32;
        e = if e != 0 {
            e - 63
        } else {
            0x800
        };
    }
    ix &= (1u64 << 52) - 1;
    ix |= 1u64 << 52;
    ix <<= 1;
    e -= 0x3ff + 52 + 1;
    return Num { m: ix, e: e, sign: sign };
}

// The 128-bit product of x and y.
const fn mul128(hi: &mut u64, lo: &mut u64, x: u64, y: u64) {
    let xlo = x & 0xFFFFFFFF;
    let xhi = x >> 32;
    let ylo = y & 0xFFFFFFFF;
    let yhi = y >> 32;
    let t1 = xlo * ylo;
    let t2 = (xlo * yhi).wrapping_add(xhi * ylo);
    let t3 = xhi * yhi;
    *lo = t1.wrapping_add(t2 << 32);
    *hi = t3.wrapping_add(t2 >> 32).wrapping_add((t1 > *lo) as u64);
}

const fn clz64(x: u64) i32 {
    return x.leading_zeros() as i32;
}

/// x * y + z, rounded once.
@export("fma")
pub const fn fma(x: f64, y: f64, z: f64) f64 {
    let nx = normalize(x);
    let ny = normalize(y);
    let nz = normalize(z);
    if nx.e >= ZEROINFNAN || ny.e >= ZEROINFNAN {
        return x * y + z;
    }
    if nz.e >= ZEROINFNAN {
        if nz.e > ZEROINFNAN {
            // z is 0
            return x * y + z;
        }
        return z;
    }
    // mul: r = x*y
    let mut rhi: u64 = 0;
    let mut rlo: u64 = 0;
    let mut zhi: u64 = 0;
    let mut zlo: u64 = 0;
    mul128(&mut rhi, &mut rlo, nx.m, ny.m);
    // Either top 20 or 21 bits of rhi and last 2 bits of rlo are 0.
    // Align exponents.
    let mut e = nx.e + ny.e;
    let mut d = nz.e - e;
    // Shift bits z<<=kz, r>>=kr, so kz+kr == d, set e = e+kr (== ez-kz).
    if d > 0 {
        if d < 64 {
            zlo = nz.m << d as u64;
            zhi = nz.m >> (64 - d) as u64;
        } else {
            zlo = 0;
            zhi = nz.m;
            e = nz.e - 64;
            d -= 64;
            if d == 0 {
                // Nothing.
            } else if d < 64 {
                rlo = rhi << (64 - d) as u64 | rlo >> d as u64 | (rlo << (64 - d) as u64 != 0) as u64;
                rhi = rhi >> d as u64;
            } else {
                rlo = 1;
                rhi = 0;
            }
        }
    } else {
        zhi = 0;
        d = 0 - d;
        if d == 0 {
            zlo = nz.m;
        } else if d < 64 {
            zlo = nz.m >> d as u64 | (nz.m << (64 - d) as u64 != 0) as u64;
        } else {
            zlo = 1;
        }
    }
    // Add.
    let mut sign = nx.sign ^ ny.sign;
    let samesign = (sign ^ nz.sign) == 0;
    let mut nonzero = true;
    if samesign {
        // r += z
        rlo = rlo.wrapping_add(zlo);
        rhi = rhi.wrapping_add(zhi).wrapping_add((rlo < zlo) as u64);
    } else {
        // r -= z
        let t = rlo;
        rlo = rlo.wrapping_sub(zlo);
        rhi = rhi.wrapping_sub(zhi).wrapping_sub((t < rlo) as u64);
        if rhi >> 63 != 0 {
            rlo = rlo.wrapping_neg();
            rhi = rhi.wrapping_neg().wrapping_sub((rlo != 0) as u64);
            sign = (sign == 0) as i32;
        }
        nonzero = rhi != 0;
    }
    // Set rhi to the top 63 bits of the result (last bit is sticky).
    if nonzero {
        e += 64;
        d = clz64(rhi) - 1;
        // Note: d > 0.
        rhi = rhi << d as u64 | rlo >> (64 - d) as u64 | (rlo << d as u64 != 0) as u64;
    } else if rlo != 0 {
        d = clz64(rlo) - 1;
        if d < 0 {
            rhi = rlo >> 1 | rlo & 1;
        } else {
            rhi = rlo << d as u64;
        }
    } else {
        // Exact +-0.
        return x * y + z;
    }
    e -= d;
    // Convert to double.
    let mut i = rhi as i64; // i is in [1<<62,(1<<63)-1]
    if sign != 0 {
        i = 0 - i;
    }
    let mut r = i as f64; // |r| is in [0x1p62,0x1p63]
    if e < -1022 - 62 {
        // Result is subnormal before rounding.
        if e == -1022 - 63 {
            let mut c: f64 = 0x1p63;
            if sign != 0 {
                c = -c;
            }
            if r == c {
                // Min normal after rounding, underflow depends on arch behaviour which can be imitated
                // by a double to float conversion.
                let fltmin = (0x0.ffffff8p-63 * 1.17549435e-38f32 as f64 * r) as f32;
                return 2.2250738585072014e-308 / 1.17549435e-38f32 as f64 * fltmin as f64;
            }
            // One bit is lost when scaled, add another top bit to only round once at conversion if it
            // is inexact.
            if rhi << 53 != 0 {
                i = (rhi >> 1 | rhi & 1 | 1u64 << 62) as i64;
                if sign != 0 {
                    i = 0 - i;
                }
                r = i as f64;
                r = 2.0 * r - c; // remove top bit
                // Raise underflow portably, such that it cannot be optimized away.
                let tiny = 2.2250738585072014e-308 / 1.17549435e-38f32 as f64 * r;
                r += tiny * tiny * (r - r);
            }
        } else {
            // Only round once when scaled.
            d = 10;
            i = ((rhi >> d as u64 | (rhi << (64 - d) as u64 != 0) as u64) << d as u64) as i64;
            if sign != 0 {
                i = 0 - i;
            }
            r = i as f64;
        }
    }
    return scalbn(r, e);
}

/// x * y + z, rounded once: the double product is exact, and a sum that lands exactly between two floats
/// is corrected toward the true value.
@export("fmaf")
pub const fn fmaf(x: f32, y: f32, z: f32) f32 {
    let xy = x as f64 * y as f64;
    let result = xy + z as f64;
    let mut ui = bits(result);
    let e = (ui >> 52 & 0x7ff) as i32;
    // Common case: the double precision result is fine.
    if (ui & 0x1fffffff) != 0x10000000 || e == 0x7ff || result - xy == z as f64 && result - z as f64 == xy {
        return result as f32;
    }
    // If result is inexact, and exactly halfway between two float values, we need to adjust the low-order
    // bit in the direction of the error.
    let neg = ui >> 63 != 0;
    let err = if neg == z as f64 > xy {
        xy - result + z as f64
    } else {
        z as f64 - result + xy
    };
    if neg == err < 0.0 {
        ui += 1;
    } else {
        ui -= 1;
    }
    return dbl(ui) as f32;
}

// ---- argument reduction ----------------------------------------------------------------------------------

// The bits of 2/pi, 24 per entry: enough for any double.
const IPIO2: [i32; 66] = [
    0xA2F983,
    0x6E4E44,
    0x1529FC,
    0x2757D1,
    0xF534DD,
    0xC0DB62,
    0x95993C,
    0x439041,
    0xFE5163,
    0xABDEBB,
    0xC561B7,
    0x246E3A,
    0x424DD2,
    0xE00649,
    0x2EEA09,
    0xD1921C,
    0xFE1DEB,
    0x1CB129,
    0xA73EE8,
    0x8235F5,
    0x2EBB44,
    0x84E99C,
    0x7026B4,
    0x5F7E41,
    0x3991D6,
    0x398353,
    0x39F49C,
    0x845F8B,
    0xBDF928,
    0x3B1FF8,
    0x97FFDE,
    0x05980F,
    0xEF2F11,
    0x8B5A0A,
    0x6D1F6D,
    0x367ECF,
    0x27CB09,
    0xB74F46,
    0x3F669E,
    0x5FEA2D,
    0x7527BA,
    0xC7EBE5,
    0xF17B3D,
    0x0739F7,
    0x8A5292,
    0xEA6BFB,
    0x5FB11F,
    0x8D5D08,
    0x560330,
    0x46FC7B,
    0x6BABF0,
    0xCFBC20,
    0x9AF436,
    0x1DA9E3,
    0x91615E,
    0xE61B08,
    0x659985,
    0x5F14A0,
    0x68408D,
    0xFFD880,
    0x4D7327,
    0x310606,
    0x1556CA,
    0x73A8C9,
    0x60E27B,
    0xC08C6B,
];

// pi/2 in 24-bit pieces.
const PIO2: [f64; 8] = [
    1.57079625129699707031e+00,
    7.54978941586159635335e-08,
    5.39030252995776476554e-15,
    3.28200341580791294123e-22,
    1.27065575308067607349e-29,
    1.22933308981111328932e-36,
    2.73370053816464559624e-44,
    2.16741683877804819444e-51,
];

// musl's `__rem_pio2_large` (Payne and Hanek) for `prec` 0 (24 bits, one result word) and 1 (53 bits,
// two): x (`nx` 24-bit pieces, scaled by 2^-e0) minus n*pi/2 into `y`, and n mod 8.
fn rem_pio2_large(x: &[f64; 3], y: &mut [f64; 2], e0: i32, nx: i32, prec: i32) i32 {
    let mut iq = [0i32; 20];
    let mut f: [f64; 20] = [0.0; 20];
    let mut fq: [f64; 20] = [0.0; 20];
    let mut q: [f64; 20] = [0.0; 20];
    let jk: i32 = if prec == 0 {
        3
    } else {
        4
    };
    let jp = jk;
    // Determine jx, jv, q0; note that 3 > q0.
    let jx = nx - 1;
    let mut jv = (e0 - 3) / 24;
    if jv < 0 {
        jv = 0;
    }
    let mut q0 = e0 - 24 * (jv + 1);
    // Set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk].
    let mut j = jv - jx;
    let m = jx + jk;
    for i in 0..(m + 1) as usize {
        unsafe f[i] = if j < 0 {
            0.0
        } else {
            (unsafe IPIO2[j as usize]) as f64
        };
        j += 1;
    }
    // Compute q[0], q[1], ... q[jk].
    for i in 0..(jk + 1) as usize {
        let mut fw: f64 = 0.0;
        for jj in 0..(jx + 1) as usize {
            fw += unsafe x[jj] * unsafe f[jx as usize + i - jj];
        }
        unsafe q[i] = fw;
    }
    let mut jz = jk;
    let mut z: f64 = 0.0;
    let mut n: i32 = 0;
    let mut ih: i32 = 0;
    // Each pass widens the slice of 2/pi until the result has bits, a fixed number of times for a double.
    loop {
        // Distill q[] into iq[] reversingly.
        let mut i: usize = 0;
        let mut jj = jz as usize;
        z = unsafe q[jz as usize];
        while jj > 0 {
            let fw = ((0x1p-24 * z) as i32) as f64;
            unsafe iq[i] = (z - 0x1p24 * fw) as i32;
            z = unsafe q[jj - 1] + fw;
            i += 1;
            jj -= 1;
        }
        // Compute n.
        z = scalbn(z, q0); // actual value of z
        z -= 8.0 * floor(z * 0.125); // trim off integer >= 8
        n = z as i32;
        z -= n as f64;
        ih = 0;
        let top = (jz - 1) as usize;
        if q0 > 0 {
            // need iq[jz-1] to determine n
            let i2 = unsafe iq[top] >> 24 - q0;
            n += i2;
            unsafe iq[top] -= i2 << 24 - q0;
            ih = unsafe iq[top] >> 23 - q0;
        } else if q0 == 0 {
            ih = unsafe iq[top] >> 23;
        } else if z >= 0.5 {
            ih = 2;
        }
        if ih > 0 {
            // q > 0.5
            n += 1;
            let mut carry = 0;
            for k in 0..jz as usize {
                // compute 1-q
                let jw = unsafe iq[k];
                if carry == 0 {
                    if jw != 0 {
                        carry = 1;
                        unsafe iq[k] = 0x1000000 - jw;
                    }
                } else {
                    unsafe iq[k] = 0xffffff - jw;
                }
            }
            if q0 > 0 {
                // rare case: chance is 1 in 12
                if q0 == 1 {
                    unsafe iq[top] &= 0x7fffff;
                } else if q0 == 2 {
                    unsafe iq[top] &= 0x3fffff;
                }
            }
            if ih == 2 {
                z = 1.0 - z;
                if carry != 0 {
                    z -= scalbn(1.0, q0);
                }
            }
        }
        // Check if recomputation is needed.
        if z == 0.0 {
            let mut jw = 0;
            let mut k = jz - 1;
            while k >= jk {
                jw |= unsafe iq[k as usize];
                k -= 1;
            }
            if jw == 0 {
                // need recomputation
                let mut kk: i32 = 1;
                while unsafe iq[(jk - kk) as usize] == 0 {
                    kk += 1; // k = no. of terms needed
                }
                for ii in (jz + 1) as usize..(jz + kk + 1) as usize {
                    // add q[jz+1] to q[jz+k]
                    unsafe f[jx as usize + ii] = (unsafe IPIO2[jv as usize + ii]) as f64;
                    let mut fw: f64 = 0.0;
                    for jj2 in 0..(jx + 1) as usize {
                        fw += unsafe x[jj2] * unsafe f[jx as usize + ii - jj2];
                    }
                    unsafe q[ii] = fw;
                }
                jz += kk;
                continue;
            }
        }
        break;
    }
    // Chop off zero terms.
    if z == 0.0 {
        jz -= 1;
        q0 -= 24;
        while unsafe iq[jz as usize] == 0 {
            jz -= 1;
            q0 -= 24;
        }
    } else {
        // break z into 24-bit if necessary
        z = scalbn(z, 0 - q0);
        if z >= 0x1p24 {
            let fw = ((0x1p-24 * z) as i32) as f64;
            unsafe iq[jz as usize] = (z - 0x1p24 * fw) as i32;
            jz += 1;
            q0 += 24;
            unsafe iq[jz as usize] = fw as i32;
        } else {
            unsafe iq[jz as usize] = z as i32;
        }
    }
    // Convert integer "bit" chunk to floating-point value.
    let mut fw = scalbn(1.0, q0);
    let mut i = jz;
    while i >= 0 {
        unsafe q[i as usize] = fw * (unsafe iq[i as usize]) as f64;
        fw *= 0x1p-24;
        i -= 1;
    }
    // Compute PIo2[0,...,jp]*q[jz,...,0].
    i = jz;
    while i >= 0 {
        let mut fw2: f64 = 0.0;
        let mut k: i32 = 0;
        while k <= jp && k <= jz - i {
            fw2 += unsafe PIO2[k as usize] * unsafe q[(i + k) as usize];
            k += 1;
        }
        unsafe fq[(jz - i) as usize] = fw2;
        i -= 1;
    }
    // Compress fq[] into y[].
    let mut fw3: f64 = 0.0;
    i = jz;
    while i >= 0 {
        fw3 += unsafe fq[i as usize];
        i -= 1;
    }
    y[0] = if ih == 0 {
        fw3
    } else {
        -fw3
    };
    if prec != 0 {
        fw3 = fq[0] - fw3;
        for ii in 1..(jz + 1) as usize {
            fw3 += unsafe fq[ii];
        }
        y[1] = if ih == 0 {
            fw3
        } else {
            -fw3
        };
    }
    return n & 7;
}

const TOINT_R: f64 = 1.5 / 2.220446049250313e-16;
const INVPIO2: f64 = 6.36619772367581382433e-01;
const PIO2_1: f64 = 1.57079632673412561417e+00;
const PIO2_1T: f64 = 6.07710050650619224932e-11;
const PIO2_2: f64 = 6.07710050630396597660e-11;
const PIO2_2T: f64 = 2.02226624879595063154e-21;
const PIO2_3: f64 = 2.02226624871116645580e-21;
const PIO2_3T: f64 = 8.47842766036889956997e-32;

// The medium-size reduction of `__rem_pio2` (Cody and Waite, with the extra pieces of pi/2 when bits
// cancel). wasi-libc leaves out upstream musl's correction of n by one.
const fn rem_pio2_medium(x: f64, ix: u32, y: &mut [f64; 2]) i32 {
    let fn_ = x * INVPIO2 + TOINT_R - TOINT_R;
    let n = fn_ as i32;
    let mut r = x - fn_ * PIO2_1;
    let mut w = fn_ * PIO2_1T; // 1st round, good to 85 bits
    y[0] = r - w;
    let mut ey = (bits(y[0]) >> 52 & 0x7ff) as i32;
    let ex = (ix >> 20) as i32;
    if ex - ey > 16 {
        // 2nd round, good to 118 bits
        let mut t = r;
        w = fn_ * PIO2_2;
        r = t - w;
        w = fn_ * PIO2_2T - (t - r - w);
        y[0] = r - w;
        ey = (bits(y[0]) >> 52 & 0x7ff) as i32;
        if ex - ey > 49 {
            // 3rd round, good to 151 bits, covers all cases
            t = r;
            w = fn_ * PIO2_3;
            r = t - w;
            w = fn_ * PIO2_3T - (t - r - w);
            y[0] = r - w;
        }
    }
    y[1] = r - y[0] - w;
    return n;
}

// musl's `__rem_pio2`: x - n*pi/2 as y[0] + y[1], and n.
fn rem_pio2(x: f64, y: &mut [f64; 2]) i32 {
    let u = bits(x);
    let sign = u >> 63 != 0;
    let ix = (u >> 32 & 0x7fffffff) as u32;
    if ix <= 0x400f6a7a {
        // |x| ~<= 5pi/4
        if (ix & 0xfffff) == 0x921fb {
            // |x| ~= pi/2 or 2pi/2: cancellation, use the medium case
            return rem_pio2_medium(x, ix, y);
        }
        if ix <= 0x4002d97c {
            // |x| ~<= 3pi/4
            if !sign {
                let z = x - PIO2_1; // one round good to 85 bits
                y[0] = z - PIO2_1T;
                y[1] = z - y[0] - PIO2_1T;
                return 1;
            }
            let z = x + PIO2_1;
            y[0] = z + PIO2_1T;
            y[1] = z - y[0] + PIO2_1T;
            return -1;
        }
        if !sign {
            let z = x - 2.0 * PIO2_1;
            y[0] = z - 2.0 * PIO2_1T;
            y[1] = z - y[0] - 2.0 * PIO2_1T;
            return 2;
        }
        let z = x + 2.0 * PIO2_1;
        y[0] = z + 2.0 * PIO2_1T;
        y[1] = z - y[0] + 2.0 * PIO2_1T;
        return -2;
    }
    if ix <= 0x401c463b {
        // |x| ~<= 9pi/4
        if ix <= 0x4015fdbc {
            // |x| ~<= 7pi/4
            if ix == 0x4012d97c {
                // |x| ~= 3pi/2
                return rem_pio2_medium(x, ix, y);
            }
            if !sign {
                let z = x - 3.0 * PIO2_1;
                y[0] = z - 3.0 * PIO2_1T;
                y[1] = z - y[0] - 3.0 * PIO2_1T;
                return 3;
            }
            let z = x + 3.0 * PIO2_1;
            y[0] = z + 3.0 * PIO2_1T;
            y[1] = z - y[0] + 3.0 * PIO2_1T;
            return -3;
        }
        if ix == 0x401921fb {
            // |x| ~= 4pi/2
            return rem_pio2_medium(x, ix, y);
        }
        if !sign {
            let z = x - 4.0 * PIO2_1;
            y[0] = z - 4.0 * PIO2_1T;
            y[1] = z - y[0] - 4.0 * PIO2_1T;
            return 4;
        }
        let z = x + 4.0 * PIO2_1;
        y[0] = z + 4.0 * PIO2_1T;
        y[1] = z - y[0] + 4.0 * PIO2_1T;
        return -4;
    }
    if ix < 0x413921fb {
        // |x| ~< 2^20*(pi/2), medium size
        return rem_pio2_medium(x, ix, y);
    }
    // all other (large) arguments
    if ix >= 0x7ff00000 {
        // x is inf or NaN
        y[0] = x - x;
        y[1] = y[0];
        return 0;
    }
    // set z = scalbn(|x|,-ilogb(x)+23)
    let mut z = dbl(u & ~0u64 >> 12 | (0x3ff + 23) as u64 << 52);
    let mut tx: [f64; 3] = [0.0; 3];
    let mut ty: [f64; 2] = [0.0; 2];
    let mut i: usize = 0;
    while i < 2 {
        unsafe tx[i] = (z as i32) as f64;
        z = (z - unsafe tx[i]) * 0x1p24;
        i += 1;
    }
    unsafe tx[i] = z;
    // skip zero terms, first term is non-zero
    while unsafe tx[i] == 0.0 {
        i -= 1;
    }
    let n = rem_pio2_large(&tx, &mut ty, (ix >> 20) as i32 - (0x3ff + 23), (i + 1) as i32, 1);
    if sign {
        y[0] = -ty[0];
        y[1] = -ty[1];
        return 0 - n;
    }
    y[0] = ty[0];
    y[1] = ty[1];
    return n;
}

const PIO2F_1: f64 = 1.57079631090164184570e+00;
const PIO2F_1T: f64 = 1.58932547735281966916e-08;

// musl's `__rem_pio2f`: x - n*pi/2 in `*y`, and n.
fn rem_pio2f(x: f32, y: &mut f64) i32 {
    let u = bitsf(x);
    let ix = u & 0x7fffffff;
    // 25+53 bit pi is good enough for medium size
    if ix < 0x4dc90fdb {
        // |x| ~< 2^28*(pi/2), medium size
        let fn_ = x as f64 * INVPIO2 + TOINT_R - TOINT_R;
        let n = fn_ as i32;
        *y = x as f64 - fn_ * PIO2F_1 - fn_ * PIO2F_1T;
        return n;
    }
    if ix >= 0x7f800000 {
        // x is inf or NaN
        *y = x - x;
        return 0;
    }
    // scale x into [2^23, 2^24-1]
    let sign = u >> 31 != 0;
    let e0 = (ix >> 23) as i32 - (0x7f + 23); // e0 = ilogb(|x|)-23, positive
    let tx = [flt(ix - (e0 as u32 << 23)) as f64, 0.0, 0.0];
    let mut ty: [f64; 2] = [0.0; 2];
    let n = rem_pio2_large(&tx, &mut ty, e0, 1, 0);
    if sign {
        *y = -ty[0];
        return 0 - n;
    }
    *y = ty[0];
    return n;
}

// ---- sin, cos, tan ---------------------------------------------------------------------------------------

const S1: f64 = -1.66666666666666324348e-01;
const S2: f64 = 8.33333333332248946124e-03;
const S3: f64 = -1.98412698298579493134e-04;
const S4: f64 = 2.75573137070700676789e-06;
const S5: f64 = -2.50507602534068634195e-08;
const S6: f64 = 1.58969099521155010221e-10;

// sin(x + y) on [-pi/4, pi/4], y the tail of x when `iy` is 1.
const fn k_sin(x: f64, y: f64, iy: i32) f64 {
    let z = x * x;
    let w = z * z;
    let r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    let v = z * x;
    if iy == 0 {
        return x + v * (S1 + z * r);
    }
    return x - (z * (0.5 * y - v * r) - y - v * S1);
}

const C1: f64 = 4.16666666666666019037e-02;
const C2: f64 = -1.38888888888741095749e-03;
const C3: f64 = 2.48015872894767294178e-05;
const C4: f64 = -2.75573143513906633035e-07;
const C5: f64 = 2.08757232129817482790e-09;
const C6: f64 = -1.13596475577881948265e-11;

// cos(x + y) on [-pi/4, pi/4].
const fn k_cos(x: f64, y: f64) f64 {
    let z = x * x;
    let mut w = z * z;
    let r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    let hz = 0.5 * z;
    w = 1.0 - hz;
    return w + (1.0 - w - hz + (z * r - x * y));
}

const TT: [f64; 13] = [
    3.33333333333334091986e-01,
    1.33333333333201242699e-01,
    5.39682539762260521377e-02,
    2.18694882948595424599e-02,
    8.86323982359930005737e-03,
    3.59207910759131235356e-03,
    1.45620945432529025516e-03,
    5.88041240820264096874e-04,
    2.46463134818469906812e-04,
    7.81794442939557092300e-05,
    7.14072491382608190305e-05,
    -1.85586374855275456654e-05,
    2.59073051863633712884e-05,
];
const PIO4: f64 = 7.85398163397448278999e-01;
const PIO4LO: f64 = 3.06161699786838301793e-17;

// tan(x + y) on [-pi/4, pi/4], or -1/tan when `odd` is 1.
const fn k_tan(x0: f64, y0: f64, odd: i32) f64 {
    let mut x = x0;
    let mut y = y0;
    let hx = hi(x);
    let big = (hx & 0x7fffffff) >= 0x3FE59428; // |x| >= 0.6744
    let sign = hx >> 31 != 0;
    if big {
        if sign {
            x = -x;
            y = -y;
        }
        x = PIO4 - x + (PIO4LO - y);
        y = 0.0;
    }
    let z = x * x;
    let mut w = z * z;
    let mut r = TT[1] + w * (TT[3] + w * (TT[5] + w * (TT[7] + w * (TT[9] + w * TT[11]))));
    let mut v = z * (TT[2] + w * (TT[4] + w * (TT[6] + w * (TT[8] + w * (TT[10] + w * TT[12])))));
    let mut s = z * x;
    r = y + z * (s * (r + v) + y) + s * TT[0];
    w = x + r;
    if big {
        s = (1 - 2 * odd) as f64;
        v = s - 2.0 * (x + (r - w * w / (w + s)));
        return if sign {
            -v
        } else {
            v
        };
    }
    if odd == 0 {
        return w;
    }
    // -1.0/(x+r) has up to 2ulp error, so compute it accurately
    let w0 = dbl(bits(w) & 0xFFFFFFFF00000000);
    v = r - (w0 - x); // w0+v = r+x
    let a = -1.0 / w;
    let a0 = dbl(bits(a) & 0xFFFFFFFF00000000);
    return a0 + a * (1.0 + a0 * w0 + a0 * v);
}

/// The sine of x radians.
@export("sin")
pub fn sin(x: f64) f64 {
    let ix = hi(x) & 0x7fffffff;
    // |x| ~< pi/4
    if ix <= 0x3fe921fb {
        if ix < 0x3e500000 {
            // |x| < 2**-26
            return x;
        }
        return k_sin(x, 0.0, 0);
    }
    // sin(Inf or NaN) is NaN
    if ix >= 0x7ff00000 {
        return x - x;
    }
    // argument reduction needed
    let mut y: [f64; 2] = [0.0; 2];
    let n = rem_pio2(x, &mut y) as u32;
    let k = n & 3;
    if k == 0 {
        return k_sin(y[0], y[1], 1);
    }
    if k == 1 {
        return k_cos(y[0], y[1]);
    }
    if k == 2 {
        return -k_sin(y[0], y[1], 1);
    }
    return -k_cos(y[0], y[1]);
}

/// The cosine of x radians.
@export("cos")
pub fn cos(x: f64) f64 {
    let ix = hi(x) & 0x7fffffff;
    // |x| ~< pi/4
    if ix <= 0x3fe921fb {
        if ix < 0x3e46a09e {
            // |x| < 2**-27 * sqrt(2)
            return 1.0;
        }
        return k_cos(x, 0.0);
    }
    // cos(Inf or NaN) is NaN
    if ix >= 0x7ff00000 {
        return x - x;
    }
    let mut y: [f64; 2] = [0.0; 2];
    let n = rem_pio2(x, &mut y) as u32;
    let k = n & 3;
    if k == 0 {
        return k_cos(y[0], y[1]);
    }
    if k == 1 {
        return -k_sin(y[0], y[1], 1);
    }
    if k == 2 {
        return -k_cos(y[0], y[1]);
    }
    return k_sin(y[0], y[1], 1);
}

/// The tangent of x radians.
@export("tan")
pub fn tan(x: f64) f64 {
    let ix = hi(x) & 0x7fffffff;
    // |x| ~< pi/4
    if ix <= 0x3fe921fb {
        if ix < 0x3e400000 {
            // |x| < 2**-27
            return x;
        }
        return k_tan(x, 0.0, 0);
    }
    // tan(Inf or NaN) is NaN
    if ix >= 0x7ff00000 {
        return x - x;
    }
    let mut y: [f64; 2] = [0.0; 2];
    let n = rem_pio2(x, &mut y) as u32;
    return k_tan(y[0], y[1], (n & 1) as i32);
}

// |sin(x)/x - s(x)| < 2**-37.5 (~[-4.89e-12, 4.824e-12]).
const SF1: f64 = -0x15555554cbac77.0p-55;
const SF2: f64 = 0x111110896efbb2.0p-59;
const SF3: f64 = -0x1a00f9e2cae774.0p-65;
const SF4: f64 = 0x16cd878c3b46a7.0p-71;

const fn k_sindf(x: f64) f32 {
    let z = x * x;
    let w = z * z;
    let r = SF3 + z * SF4;
    let s = z * x;
    return (x + s * (SF1 + z * SF2) + s * w * r) as f32;
}

// |cos(x) - c(x)| < 2**-34.1 (~[-5.37e-11, 5.295e-11]).
const CF0: f64 = -0x1ffffffd0c5e81.0p-54;
const CF1: f64 = 0x155553e1053a42.0p-57;
const CF2: f64 = -0x16c087e80f1e27.0p-62;
const CF3: f64 = 0x199342e0ee5069.0p-68;

const fn k_cosdf(x: f64) f32 {
    let z = x * x;
    let w = z * z;
    let r = CF2 + z * CF3;
    return (1.0 + z * CF0 + w * CF1 + w * z * r) as f32;
}

// |tan(x)/x - t(x)| < 2**-25.5 (~[-2e-08, 2e-08]).
const TF: [f64; 6] = [
    0x15554d3418c99f.0p-54,
    0x1112fd38999f72.0p-55,
    0x1b54c91d865afe.0p-57,
    0x191df3908c33ce.0p-58,
    0x185dadfcecf44e.0p-61,
    0x1362b9bf971bcd.0p-59,
];

const fn k_tandf(x: f64, odd: i32) f32 {
    let z = x * x;
    let mut r = TF[4] + z * TF[5];
    let t = TF[2] + z * TF[3];
    let w = z * z;
    let s = z * x;
    let u = TF[0] + z * TF[1];
    r = x + s * u + s * w * (t + w * r);
    return if odd != 0 {
        -1.0 / r
    } else {
        r
    } as f32;
}

const PIO2_D1: f64 = 1.0 * 1.57079632679489661923;
const PIO2_D2: f64 = 2.0 * 1.57079632679489661923;
const PIO2_D3: f64 = 3.0 * 1.57079632679489661923;
const PIO2_D4: f64 = 4.0 * 1.57079632679489661923;

/// The sine of x radians.
@export("sinf")
pub fn sinf(x: f32) f32 {
    let u = bitsf(x);
    let sign = u >> 31 != 0;
    let ix = u & 0x7fffffff;
    let xd = x as f64;
    if ix <= 0x3f490fda {
        // |x| ~<= pi/4
        if ix < 0x39800000 {
            // |x| < 2**-12
            return x;
        }
        return k_sindf(xd);
    }
    if ix <= 0x407b53d1 {
        // |x| ~<= 5*pi/4
        if ix <= 0x4016cbe3 {
            // |x| ~<= 3pi/4
            if sign {
                return -k_cosdf(xd + PIO2_D1);
            }
            return k_cosdf(xd - PIO2_D1);
        }
        return k_sindf(
            if sign {
                -(xd + PIO2_D2)
            } else {
                -(xd - PIO2_D2)
            },
        );
    }
    if ix <= 0x40e231d5 {
        // |x| ~<= 9*pi/4
        if ix <= 0x40afeddf {
            // |x| ~<= 7*pi/4
            if sign {
                return k_cosdf(xd + PIO2_D3);
            }
            return -k_cosdf(xd - PIO2_D3);
        }
        return k_sindf(
            if sign {
                xd + PIO2_D4
            } else {
                xd - PIO2_D4
            },
        );
    }
    // sin(Inf or NaN) is NaN
    if ix >= 0x7f800000 {
        return x - x;
    }
    // general argument reduction needed
    let mut y: f64 = 0.0;
    let n = rem_pio2f(x, &mut y) as u32;
    let k = n & 3;
    if k == 0 {
        return k_sindf(y);
    }
    if k == 1 {
        return k_cosdf(y);
    }
    if k == 2 {
        return k_sindf(-y);
    }
    return -k_cosdf(y);
}

/// The cosine of x radians.
@export("cosf")
pub fn cosf(x: f32) f32 {
    let u = bitsf(x);
    let sign = u >> 31 != 0;
    let ix = u & 0x7fffffff;
    let xd = x as f64;
    if ix <= 0x3f490fda {
        // |x| ~<= pi/4
        if ix < 0x39800000 {
            // |x| < 2**-12
            return 1.0f32;
        }
        return k_cosdf(xd);
    }
    if ix <= 0x407b53d1 {
        // |x| ~<= 5*pi/4
        if ix > 0x4016cbe3 {
            // |x| ~> 3*pi/4
            return -k_cosdf(
                if sign {
                    xd + PIO2_D2
                } else {
                    xd - PIO2_D2
                },
            );
        }
        if sign {
            return k_sindf(xd + PIO2_D1);
        }
        return k_sindf(PIO2_D1 - xd);
    }
    if ix <= 0x40e231d5 {
        // |x| ~<= 9*pi/4
        if ix > 0x40afeddf {
            // |x| ~> 7*pi/4
            return k_cosdf(
                if sign {
                    xd + PIO2_D4
                } else {
                    xd - PIO2_D4
                },
            );
        }
        if sign {
            return k_sindf(-xd - PIO2_D3);
        }
        return k_sindf(xd - PIO2_D3);
    }
    // cos(Inf or NaN) is NaN
    if ix >= 0x7f800000 {
        return x - x;
    }
    let mut y: f64 = 0.0;
    let n = rem_pio2f(x, &mut y) as u32;
    let k = n & 3;
    if k == 0 {
        return k_cosdf(y);
    }
    if k == 1 {
        return k_sindf(-y);
    }
    if k == 2 {
        return -k_cosdf(y);
    }
    return k_sindf(y);
}

/// The tangent of x radians.
@export("tanf")
pub fn tanf(x: f32) f32 {
    let u = bitsf(x);
    let sign = u >> 31 != 0;
    let ix = u & 0x7fffffff;
    let xd = x as f64;
    if ix <= 0x3f490fda {
        // |x| ~<= pi/4
        if ix < 0x39800000 {
            // |x| < 2**-12
            return x;
        }
        return k_tandf(xd, 0);
    }
    if ix <= 0x407b53d1 {
        // |x| ~<= 5*pi/4
        if ix <= 0x4016cbe3 {
            // |x| ~<= 3pi/4
            return k_tandf(
                if sign {
                    xd + PIO2_D1
                } else {
                    xd - PIO2_D1
                },
                1,
            );
        }
        return k_tandf(
            if sign {
                xd + PIO2_D2
            } else {
                xd - PIO2_D2
            },
            0,
        );
    }
    if ix <= 0x40e231d5 {
        // |x| ~<= 9*pi/4
        if ix <= 0x40afeddf {
            // |x| ~<= 7*pi/4
            return k_tandf(
                if sign {
                    xd + PIO2_D3
                } else {
                    xd - PIO2_D3
                },
                1,
            );
        }
        return k_tandf(
            if sign {
                xd + PIO2_D4
            } else {
                xd - PIO2_D4
            },
            0,
        );
    }
    // tan(Inf or NaN) is NaN
    if ix >= 0x7f800000 {
        return x - x;
    }
    // argument reduction
    let mut y: f64 = 0.0;
    let n = rem_pio2f(x, &mut y) as u32;
    return k_tandf(y, (n & 1) as i32);
}

// ---- exp, exp2, log, log2, pow ---------------------------------------------------------------------------
// ARM's optimized routines as musl carries them, with wasi-libc's WANT_ROUNDING 0 (wasm has one rounding
// mode) and without fused multiply-add (`__FP_FAST_FMA` is unset on wasm).

// The data of exp, exp2 and pow: 2^(k/128) = H[k] * (1 + T[k]) with EXP_TAB[2k] = bits(T[k]) and
// EXP_TAB[2k+1] = bits(H[k]) - (k << 52) / 128.
const EXP_INVLN2N: f64 = 0x1.71547652b82fep+7;
const EXP_SHIFT: f64 = 0x1.8000000000000p+52;
const EXP_NEGLN2HIN: f64 = -0x1.62e42fefa0000p-8;
const EXP_NEGLN2LON: f64 = -0x1.cf79abc9e3b3ap-47;
const EXP_EXP2_SHIFT: f64 = 0x1.8000000000000p+45;
const EXP_POLY: [f64; 4] = [0x1.ffffffffffdbdp-2, 0x1.555555555543cp-3, 0x1.55555cf172b91p-5, 0x1.1111167a4d017p-7];
const EXP2_POLY: [f64; 5] = [
    0x1.62e42fefa39efp-1,
    0x1.ebfbdff82c424p-3,
    0x1.c6b08d70cf4b5p-5,
    0x1.3b2abd24650ccp-7,
    0x1.5d7e09b4e3a84p-10,
];
const EXP_TAB: [u64; 256] = [
    0x0,
    0x3ff0000000000000,
    0x3c9b3b4f1a88bf6e,
    0x3feff63da9fb3335,
    0xbc7160139cd8dc5d,
    0x3fefec9a3e778061,
    0xbc905e7a108766d1,
    0x3fefe315e86e7f85,
    0x3c8cd2523567f613,
    0x3fefd9b0d3158574,
    0xbc8bce8023f98efa,
    0x3fefd06b29ddf6de,
    0x3c60f74e61e6c861,
    0x3fefc74518759bc8,
    0x3c90a3e45b33d399,
    0x3fefbe3ecac6f383,
    0x3c979aa65d837b6d,
    0x3fefb5586cf9890f,
    0x3c8eb51a92fdeffc,
    0x3fefac922b7247f7,
    0x3c3ebe3d702f9cd1,
    0x3fefa3ec32d3d1a2,
    0xbc6a033489906e0b,
    0x3fef9b66affed31b,
    0xbc9556522a2fbd0e,
    0x3fef9301d0125b51,
    0xbc5080ef8c4eea55,
    0x3fef8abdc06c31cc,
    0xbc91c923b9d5f416,
    0x3fef829aaea92de0,
    0x3c80d3e3e95c55af,
    0x3fef7a98c8a58e51,
    0xbc801b15eaa59348,
    0x3fef72b83c7d517b,
    0xbc8f1ff055de323d,
    0x3fef6af9388c8dea,
    0x3c8b898c3f1353bf,
    0x3fef635beb6fcb75,
    0xbc96d99c7611eb26,
    0x3fef5be084045cd4,
    0x3c9aecf73e3a2f60,
    0x3fef54873168b9aa,
    0xbc8fe782cb86389d,
    0x3fef4d5022fcd91d,
    0x3c8a6f4144a6c38d,
    0x3fef463b88628cd6,
    0x3c807a05b0e4047d,
    0x3fef3f49917ddc96,
    0x3c968efde3a8a894,
    0x3fef387a6e756238,
    0x3c875e18f274487d,
    0x3fef31ce4fb2a63f,
    0x3c80472b981fe7f2,
    0x3fef2b4565e27cdd,
    0xbc96b87b3f71085e,
    0x3fef24dfe1f56381,
    0x3c82f7e16d09ab31,
    0x3fef1e9df51fdee1,
    0xbc3d219b1a6fbffa,
    0x3fef187fd0dad990,
    0x3c8b3782720c0ab4,
    0x3fef1285a6e4030b,
    0x3c6e149289cecb8f,
    0x3fef0cafa93e2f56,
    0x3c834d754db0abb6,
    0x3fef06fe0a31b715,
    0x3c864201e2ac744c,
    0x3fef0170fc4cd831,
    0x3c8fdd395dd3f84a,
    0x3feefc08b26416ff,
    0xbc86a3803b8e5b04,
    0x3feef6c55f929ff1,
    0xbc924aedcc4b5068,
    0x3feef1a7373aa9cb,
    0xbc9907f81b512d8e,
    0x3feeecae6d05d866,
    0xbc71d1e83e9436d2,
    0x3feee7db34e59ff7,
    0xbc991919b3ce1b15,
    0x3feee32dc313a8e5,
    0x3c859f48a72a4c6d,
    0x3feedea64c123422,
    0xbc9312607a28698a,
    0x3feeda4504ac801c,
    0xbc58a78f4817895b,
    0x3feed60a21f72e2a,
    0xbc7c2c9b67499a1b,
    0x3feed1f5d950a897,
    0x3c4363ed60c2ac11,
    0x3feece086061892d,
    0x3c9666093b0664ef,
    0x3feeca41ed1d0057,
    0x3c6ecce1daa10379,
    0x3feec6a2b5c13cd0,
    0x3c93ff8e3f0f1230,
    0x3feec32af0d7d3de,
    0x3c7690cebb7aafb0,
    0x3feebfdad5362a27,
    0x3c931dbdeb54e077,
    0x3feebcb299fddd0d,
    0xbc8f94340071a38e,
    0x3feeb9b2769d2ca7,
    0xbc87deccdc93a349,
    0x3feeb6daa2cf6642,
    0xbc78dec6bd0f385f,
    0x3feeb42b569d4f82,
    0xbc861246ec7b5cf6,
    0x3feeb1a4ca5d920f,
    0x3c93350518fdd78e,
    0x3feeaf4736b527da,
    0x3c7b98b72f8a9b05,
    0x3feead12d497c7fd,
    0x3c9063e1e21c5409,
    0x3feeab07dd485429,
    0x3c34c7855019c6ea,
    0x3feea9268a5946b7,
    0x3c9432e62b64c035,
    0x3feea76f15ad2148,
    0xbc8ce44a6199769f,
    0x3feea5e1b976dc09,
    0xbc8c33c53bef4da8,
    0x3feea47eb03a5585,
    0xbc845378892be9ae,
    0x3feea34634ccc320,
    0xbc93cedd78565858,
    0x3feea23882552225,
    0x3c5710aa807e1964,
    0x3feea155d44ca973,
    0xbc93b3efbf5e2228,
    0x3feea09e667f3bcd,
    0xbc6a12ad8734b982,
    0x3feea012750bdabf,
    0xbc6367efb86da9ee,
    0x3fee9fb23c651a2f,
    0xbc80dc3d54e08851,
    0x3fee9f7df9519484,
    0xbc781f647e5a3ecf,
    0x3fee9f75e8ec5f74,
    0xbc86ee4ac08b7db0,
    0x3fee9f9a48a58174,
    0xbc8619321e55e68a,
    0x3fee9feb564267c9,
    0x3c909ccb5e09d4d3,
    0x3feea0694fde5d3f,
    0xbc7b32dcb94da51d,
    0x3feea11473eb0187,
    0x3c94ecfd5467c06b,
    0x3feea1ed0130c132,
    0x3c65ebe1abd66c55,
    0x3feea2f336cf4e62,
    0xbc88a1c52fb3cf42,
    0x3feea427543e1a12,
    0xbc9369b6f13b3734,
    0x3feea589994cce13,
    0xbc805e843a19ff1e,
    0x3feea71a4623c7ad,
    0xbc94d450d872576e,
    0x3feea8d99b4492ed,
    0x3c90ad675b0e8a00,
    0x3feeaac7d98a6699,
    0x3c8db72fc1f0eab4,
    0x3feeace5422aa0db,
    0xbc65b6609cc5e7ff,
    0x3feeaf3216b5448c,
    0x3c7bf68359f35f44,
    0x3feeb1ae99157736,
    0xbc93091fa71e3d83,
    0x3feeb45b0b91ffc6,
    0xbc5da9b88b6c1e29,
    0x3feeb737b0cdc5e5,
    0xbc6c23f97c90b959,
    0x3feeba44cbc8520f,
    0xbc92434322f4f9aa,
    0x3feebd829fde4e50,
    0xbc85ca6cd7668e4b,
    0x3feec0f170ca07ba,
    0x3c71affc2b91ce27,
    0x3feec49182a3f090,
    0x3c6dd235e10a73bb,
    0x3feec86319e32323,
    0xbc87c50422622263,
    0x3feecc667b5de565,
    0x3c8b1c86e3e231d5,
    0x3feed09bec4a2d33,
    0xbc91bbd1d3bcbb15,
    0x3feed503b23e255d,
    0x3c90cc319cee31d2,
    0x3feed99e1330b358,
    0x3c8469846e735ab3,
    0x3feede6b5579fdbf,
    0xbc82dfcd978e9db4,
    0x3feee36bbfd3f37a,
    0x3c8c1a7792cb3387,
    0x3feee89f995ad3ad,
    0xbc907b8f4ad1d9fa,
    0x3feeee07298db666,
    0xbc55c3d956dcaeba,
    0x3feef3a2b84f15fb,
    0xbc90a40e3da6f640,
    0x3feef9728de5593a,
    0xbc68d6f438ad9334,
    0x3feeff76f2fb5e47,
    0xbc91eee26b588a35,
    0x3fef05b030a1064a,
    0x3c74ffd70a5fddcd,
    0x3fef0c1e904bc1d2,
    0xbc91bdfbfa9298ac,
    0x3fef12c25bd71e09,
    0x3c736eae30af0cb3,
    0x3fef199bdd85529c,
    0x3c8ee3325c9ffd94,
    0x3fef20ab5fffd07a,
    0x3c84e08fd10959ac,
    0x3fef27f12e57d14b,
    0x3c63cdaf384e1a67,
    0x3fef2f6d9406e7b5,
    0x3c676b2c6c921968,
    0x3fef3720dcef9069,
    0xbc808a1883ccb5d2,
    0x3fef3f0b555dc3fa,
    0xbc8fad5d3ffffa6f,
    0x3fef472d4a07897c,
    0xbc900dae3875a949,
    0x3fef4f87080d89f2,
    0x3c74a385a63d07a7,
    0x3fef5818dcfba487,
    0xbc82919e2040220f,
    0x3fef60e316c98398,
    0x3c8e5a50d5c192ac,
    0x3fef69e603db3285,
    0x3c843a59ac016b4b,
    0x3fef7321f301b460,
    0xbc82d52107b43e1f,
    0x3fef7c97337b9b5f,
    0xbc892ab93b470dc9,
    0x3fef864614f5a129,
    0x3c74b604603a88d3,
    0x3fef902ee78b3ff6,
    0x3c83c5ec519d7271,
    0x3fef9a51fbc74c83,
    0xbc8ff7128fd391f0,
    0x3fefa4afa2a490da,
    0xbc8dae98e223747d,
    0x3fefaf482d8e67f1,
    0x3c8ec3bc41aa2008,
    0x3fefba1bee615a27,
    0x3c842b94c3a9eb32,
    0x3fefc52b376bba97,
    0x3c8a64a931d185ee,
    0x3fefd0765b6e4540,
    0xbc8e37bae43be3ed,
    0x3fefdbfdad9cbe14,
    0x3c77893b4d91cd9d,
    0x3fefe7c1819e90d8,
    0x3c5305c14160cc89,
    0x3feff3c22b8f71f1,
];

const fn top12(x: f64) u32 {
    return (bits(x) >> 52) as u32;
}

// exp(x) in the cases scale * (1 + tmp) overflows or underflows: k is out of the exponent range.
const fn exp_special(tmp: f64, sbits0: u64, ki: u64) f64 {
    let mut sbits = sbits0;
    if (ki & 0x80000000) == 0 {
        // k > 0, the exponent of scale might have overflowed by <= 460.
        sbits = sbits.wrapping_sub(1009u64 << 52);
        let scale = dbl(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0, need special care in the subnormal range.
    sbits = sbits.wrapping_add(1022u64 << 52);
    let scale = dbl(sbits);
    let mut y = scale + scale * tmp;
    if y < 1.0 {
        // Round y to the right precision before scaling it into the subnormal range to avoid double
        // rounding that can cause 0.5+E/2 ulp error where E is the worst-case ulp error outside the
        // subnormal range.
        let mut lo = scale - y + scale * tmp;
        let hi = 1.0 + y;
        lo = 1.0 - hi + y + lo;
        y = hi + lo - 1.0;
    }
    return 0x1p-1022 * y;
}

/// e^x.
@export("exp")
pub const fn exp(x: f64) f64 {
    let mut abstop = top12(x) & 0x7ff;
    if abstop.wrapping_sub(top12(0x1p-54)) >= top12(512.0) - top12(0x1p-54) {
        if abstop.wrapping_sub(top12(0x1p-54)) >= 0x80000000 {
            // Avoid spurious underflow for tiny x. Note: 0 is common input.
            return 1.0;
        }
        if abstop >= top12(1024.0) {
            if bits(x) == bits(-INF) {
                return 0.0;
            }
            if abstop >= top12(INF) {
                return 1.0 + x;
            }
            if bits(x) >> 63 != 0 {
                return uflow(0);
            }
            return oflow(0);
        }
        // Large x is special cased below.
        abstop = 0;
    }
    // exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)].
    // x = ln2/N*k + r, with int k and r in [-ln2/2N, ln2/2N].
    let z = EXP_INVLN2N * x;
    // z - kd is in [-1, 1] in non-nearest rounding modes.
    let mut kd = z + EXP_SHIFT;
    let ki = bits(kd);
    kd -= EXP_SHIFT;
    let r = x + kd * EXP_NEGLN2HIN + kd * EXP_NEGLN2LON;
    // 2^(k/N) ~= scale * (1 + tail).
    let idx = (2 * (ki % 128)) as usize;
    let top = ki << 52 - 7;
    let tail = dbl(unsafe EXP_TAB[idx]);
    // This is only a valid scale when -1023*N < k < 1024*N.
    let sbits = unsafe EXP_TAB[idx + 1].wrapping_add(top);
    // exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1).
    // Evaluation is optimized assuming superscalar pipelined execution.
    let r2 = r * r;
    // Without fma the worst case error is 0.25/N ulp larger.
    // Worst case error is less than 0.5+1.11/N+(abs poly error * 2^53) ulp.
    let tmp = tail + r + r2 * (EXP_POLY[0] + r * EXP_POLY[1]) + r2 * r2 * (EXP_POLY[2] + r * EXP_POLY[3]);
    if abstop == 0 {
        return exp_special(tmp, sbits, ki);
    }
    let scale = dbl(sbits);
    // Note: tmp == 0 or |tmp| > 2^-200 and scale > 2^-739, so there is no spurious underflow here even
    // without fma.
    return scale + scale * tmp;
}

const fn exp2_special(tmp: f64, sbits0: u64, ki: u64) f64 {
    let mut sbits = sbits0;
    if (ki & 0x80000000) == 0 {
        // k > 0, the exponent of scale might have overflowed by 1.
        sbits = sbits.wrapping_sub(1u64 << 52);
        let scale = dbl(sbits);
        return 2.0 * (scale + scale * tmp);
    }
    // k < 0, need special care in the subnormal range.
    sbits = sbits.wrapping_add(1022u64 << 52);
    let scale = dbl(sbits);
    let mut y = scale + scale * tmp;
    if y < 1.0 {
        let mut lo = scale - y + scale * tmp;
        let hi = 1.0 + y;
        lo = 1.0 - hi + y + lo;
        y = hi + lo - 1.0;
    }
    return 0x1p-1022 * y;
}

/// 2^x.
@export("exp2")
pub const fn exp2(x: f64) f64 {
    let mut abstop = top12(x) & 0x7ff;
    if abstop.wrapping_sub(top12(0x1p-54)) >= top12(512.0) - top12(0x1p-54) {
        if abstop.wrapping_sub(top12(0x1p-54)) >= 0x80000000 {
            // Avoid spurious underflow for tiny x. Note: 0 is common input.
            return 1.0;
        }
        if abstop >= top12(1024.0) {
            if bits(x) == bits(-INF) {
                return 0.0;
            }
            if abstop >= top12(INF) {
                return 1.0 + x;
            }
            if bits(x) >> 63 == 0 {
                return oflow(0);
            } else if bits(x) >= bits(-1075.0) {
                return uflow(0);
            }
        }
        if bits(x) << 1 > bits(928.0) << 1 {
            // Large x is special cased below.
            abstop = 0;
        }
    }
    // exp2(x) = 2^(k/N) * 2^r, with 2^r in [2^(-1/2N),2^(1/2N)].
    // x = k/N + r, with int k and r in [-1/2N, 1/2N].
    let mut kd = x + EXP_EXP2_SHIFT;
    let ki = bits(kd); // k
    kd -= EXP_EXP2_SHIFT; // k/N for int k
    let r = x - kd;
    // 2^(k/N) ~= scale * (1 + tail).
    let idx = (2 * (ki % 128)) as usize;
    let top = ki << 52 - 7;
    let tail = dbl(unsafe EXP_TAB[idx]);
    // This is only a valid scale when -1023*N < k < 1024*N.
    let sbits = unsafe EXP_TAB[idx + 1].wrapping_add(top);
    // exp2(x) = 2^(k/N) * 2^r ~= scale + scale * (tail + 2^r - 1).
    // Evaluation is optimized assuming superscalar pipelined execution.
    let r2 = r * r;
    // Without fma the worst case error is 0.5/N ulp larger.
    // Worst case error is less than 0.5+0.86/N+(abs poly error * 2^53) ulp.
    let tmp = tail + r * EXP2_POLY[0] + r2 * (EXP2_POLY[1] + r * EXP2_POLY[2]) + r2 * r2 * (EXP2_POLY[3] + r * EXP2_POLY[4]);
    if abstop == 0 {
        return exp2_special(tmp, sbits, ki);
    }
    let scale = dbl(sbits);
    // Note: tmp == 0 or |tmp| > 2^-65 and scale > 2^-928, so there is no spurious underflow here even
    // without fma.
    return scale + scale * tmp;
}

// The data of log: LOG_TAB holds (invc, logc) pairs and LOG_TAB2 (chi, clo) pairs, 128 of each.
const LOG_LN2HI: f64 = 0x1.62e42fefa3800p-1;
const LOG_LN2LO: f64 = 0x1.ef35793c76730p-45;
const LOG_POLY: [f64; 5] = [
    -0x1.0000000000001p-1,
    0x1.555555551305bp-2,
    -0x1.fffffffeb4590p-3,
    0x1.999b324f10111p-3,
    -0x1.55575e506c89fp-3,
];
const LOG_POLY1: [f64; 11] = [
    -0x1.0000000000000p-1,
    0x1.5555555555577p-2,
    -0x1.ffffffffffdcbp-3,
    0x1.999999995dd0cp-3,
    -0x1.55555556745a7p-3,
    0x1.24924a344de30p-3,
    -0x1.fffffa4423d65p-4,
    0x1.c7184282ad6cap-4,
    -0x1.999eb43b068ffp-4,
    0x1.78182f7afd085p-4,
    -0x1.5521375d145cdp-4,
];
const LOG_TAB: [f64; 256] = [
    0x1.734f0c3e0de9fp+0,
    -0x1.7cc7f79e69000p-2,
    0x1.713786a2ce91fp+0,
    -0x1.76feec20d0000p-2,
    0x1.6f26008fab5a0p+0,
    -0x1.713e31351e000p-2,
    0x1.6d1a61f138c7dp+0,
    -0x1.6b85b38287800p-2,
    0x1.6b1490bc5b4d1p+0,
    -0x1.65d5590807800p-2,
    0x1.69147332f0cbap+0,
    -0x1.602d076180000p-2,
    0x1.6719f18224223p+0,
    -0x1.5a8ca86909000p-2,
    0x1.6524f99a51ed9p+0,
    -0x1.54f4356035000p-2,
    0x1.63356aa8f24c4p+0,
    -0x1.4f637c36b4000p-2,
    0x1.614b36b9ddc14p+0,
    -0x1.49da7fda85000p-2,
    0x1.5f66452c65c4cp+0,
    -0x1.445923989a800p-2,
    0x1.5d867b5912c4fp+0,
    -0x1.3edf439b0b800p-2,
    0x1.5babccb5b90dep+0,
    -0x1.396ce448f7000p-2,
    0x1.59d61f2d91a78p+0,
    -0x1.3401e17bda000p-2,
    0x1.5805612465687p+0,
    -0x1.2e9e2ef468000p-2,
    0x1.56397cee76bd3p+0,
    -0x1.2941b3830e000p-2,
    0x1.54725e2a77f93p+0,
    -0x1.23ec58cda8800p-2,
    0x1.52aff42064583p+0,
    -0x1.1e9e129279000p-2,
    0x1.50f22dbb2bddfp+0,
    -0x1.1956d2b48f800p-2,
    0x1.4f38f4734ded7p+0,
    -0x1.141679ab9f800p-2,
    0x1.4d843cfde2840p+0,
    -0x1.0edd094ef9800p-2,
    0x1.4bd3ec078a3c8p+0,
    -0x1.09aa518db1000p-2,
    0x1.4a27fc3e0258ap+0,
    -0x1.047e65263b800p-2,
    0x1.4880524d48434p+0,
    -0x1.feb224586f000p-3,
    0x1.46dce1b192d0bp+0,
    -0x1.f474a7517b000p-3,
    0x1.453d9d3391854p+0,
    -0x1.ea4443d103000p-3,
    0x1.43a2744b4845ap+0,
    -0x1.e020d44e9b000p-3,
    0x1.420b54115f8fbp+0,
    -0x1.d60a22977f000p-3,
    0x1.40782da3ef4b1p+0,
    -0x1.cc00104959000p-3,
    0x1.3ee8f5d57fe8fp+0,
    -0x1.c202956891000p-3,
    0x1.3d5d9a00b4ce9p+0,
    -0x1.b81178d811000p-3,
    0x1.3bd60c010c12bp+0,
    -0x1.ae2c9ccd3d000p-3,
    0x1.3a5242b75dab8p+0,
    -0x1.a45402e129000p-3,
    0x1.38d22cd9fd002p+0,
    -0x1.9a877681df000p-3,
    0x1.3755bc5847a1cp+0,
    -0x1.90c6d69483000p-3,
    0x1.35dce49ad36e2p+0,
    -0x1.87120a645c000p-3,
    0x1.34679984dd440p+0,
    -0x1.7d68fb4143000p-3,
    0x1.32f5cceffcb24p+0,
    -0x1.73cb83c627000p-3,
    0x1.3187775a10d49p+0,
    -0x1.6a39a9b376000p-3,
    0x1.301c8373e3990p+0,
    -0x1.60b3154b7a000p-3,
    0x1.2eb4ebb95f841p+0,
    -0x1.5737d76243000p-3,
    0x1.2d50a0219a9d1p+0,
    -0x1.4dc7b8fc23000p-3,
    0x1.2bef9a8b7fd2ap+0,
    -0x1.4462c51d20000p-3,
    0x1.2a91c7a0c1babp+0,
    -0x1.3b08abc830000p-3,
    0x1.293726014b530p+0,
    -0x1.31b996b490000p-3,
    0x1.27dfa5757a1f5p+0,
    -0x1.2875490a44000p-3,
    0x1.268b39b1d3bbfp+0,
    -0x1.1f3b9f879a000p-3,
    0x1.2539d838ff5bdp+0,
    -0x1.160c8252ca000p-3,
    0x1.23eb7aac9083bp+0,
    -0x1.0ce7f57f72000p-3,
    0x1.22a012ba940b6p+0,
    -0x1.03cdc49fea000p-3,
    0x1.2157996cc4132p+0,
    -0x1.f57bdbc4b8000p-4,
    0x1.201201dd2fc9bp+0,
    -0x1.e370896404000p-4,
    0x1.1ecf4494d480bp+0,
    -0x1.d17983ef94000p-4,
    0x1.1d8f5528f6569p+0,
    -0x1.bf9674ed8a000p-4,
    0x1.1c52311577e7cp+0,
    -0x1.adc79202f6000p-4,
    0x1.1b17c74cb26e9p+0,
    -0x1.9c0c3e7288000p-4,
    0x1.19e010c2c1ab6p+0,
    -0x1.8a646b372c000p-4,
    0x1.18ab07bb670bdp+0,
    -0x1.78d01b3ac0000p-4,
    0x1.1778a25efbcb6p+0,
    -0x1.674f145380000p-4,
    0x1.1648d354c31dap+0,
    -0x1.55e0e6d878000p-4,
    0x1.151b990275fddp+0,
    -0x1.4485cdea1e000p-4,
    0x1.13f0ea432d24cp+0,
    -0x1.333d94d6aa000p-4,
    0x1.12c8b7210f9dap+0,
    -0x1.22079f8c56000p-4,
    0x1.11a3028ecb531p+0,
    -0x1.10e4698622000p-4,
    0x1.107fbda8434afp+0,
    -0x1.ffa6c6ad20000p-5,
    0x1.0f5ee0f4e6bb3p+0,
    -0x1.dda8d4a774000p-5,
    0x1.0e4065d2a9fcep+0,
    -0x1.bbcece4850000p-5,
    0x1.0d244632ca521p+0,
    -0x1.9a1894012c000p-5,
    0x1.0c0a77ce2981ap+0,
    -0x1.788583302c000p-5,
    0x1.0af2f83c636d1p+0,
    -0x1.5715e67d68000p-5,
    0x1.09ddb98a01339p+0,
    -0x1.35c8a49658000p-5,
    0x1.08cabaf52e7dfp+0,
    -0x1.149e364154000p-5,
    0x1.07b9f2f4e28fbp+0,
    -0x1.e72c082eb8000p-6,
    0x1.06ab58c358f19p+0,
    -0x1.a55f152528000p-6,
    0x1.059eea5ecf92cp+0,
    -0x1.63d62cf818000p-6,
    0x1.04949cdd12c90p+0,
    -0x1.228fb8caa0000p-6,
    0x1.038c6c6f0ada9p+0,
    -0x1.c317b20f90000p-7,
    0x1.02865137932a9p+0,
    -0x1.419355daa0000p-7,
    0x1.0182427ea7348p+0,
    -0x1.81203c2ec0000p-8,
    0x1.008040614b195p+0,
    -0x1.0040979240000p-9,
    0x1.fe01ff726fa1ap-1,
    0x1.feff384900000p-9,
    0x1.fa11cc261ea74p-1,
    0x1.7dc41353d0000p-7,
    0x1.f6310b081992ep-1,
    0x1.3cea3c4c28000p-6,
    0x1.f25f63ceeadcdp-1,
    0x1.b9fc114890000p-6,
    0x1.ee9c8039113e7p-1,
    0x1.1b0d8ce110000p-5,
    0x1.eae8078cbb1abp-1,
    0x1.58a5bd001c000p-5,
    0x1.e741aa29d0c9bp-1,
    0x1.95c8340d88000p-5,
    0x1.e3a91830a99b5p-1,
    0x1.d276aef578000p-5,
    0x1.e01e009609a56p-1,
    0x1.07598e598c000p-4,
    0x1.dca01e577bb98p-1,
    0x1.253f5e30d2000p-4,
    0x1.d92f20b7c9103p-1,
    0x1.42edd8b380000p-4,
    0x1.d5cac66fb5ccep-1,
    0x1.606598757c000p-4,
    0x1.d272caa5ede9dp-1,
    0x1.7da76356a0000p-4,
    0x1.cf26e3e6b2ccdp-1,
    0x1.9ab434e1c6000p-4,
    0x1.cbe6da2a77902p-1,
    0x1.b78c7bb0d6000p-4,
    0x1.c8b266d37086dp-1,
    0x1.d431332e72000p-4,
    0x1.c5894bd5d5804p-1,
    0x1.f0a3171de6000p-4,
    0x1.c26b533bb9f8cp-1,
    0x1.067152b914000p-3,
    0x1.bf583eeece73fp-1,
    0x1.147858292b000p-3,
    0x1.bc4fd75db96c1p-1,
    0x1.2266ecdca3000p-3,
    0x1.b951e0c864a28p-1,
    0x1.303d7a6c55000p-3,
    0x1.b65e2c5ef3e2cp-1,
    0x1.3dfc33c331000p-3,
    0x1.b374867c9888bp-1,
    0x1.4ba366b7a8000p-3,
    0x1.b094b211d304ap-1,
    0x1.5933928d1f000p-3,
    0x1.adbe885f2ef7ep-1,
    0x1.66acd2418f000p-3,
    0x1.aaf1d31603da2p-1,
    0x1.740f8ec669000p-3,
    0x1.a82e63fd358a7p-1,
    0x1.815c0f51af000p-3,
    0x1.a5740ef09738bp-1,
    0x1.8e92954f68000p-3,
    0x1.a2c2a90ab4b27p-1,
    0x1.9bb3602f84000p-3,
    0x1.a01a01393f2d1p-1,
    0x1.a8bed1c2c0000p-3,
    0x1.9d79f24db3c1bp-1,
    0x1.b5b515c01d000p-3,
    0x1.9ae2505c7b190p-1,
    0x1.c2967ccbcc000p-3,
    0x1.9852ef297ce2fp-1,
    0x1.cf635d5486000p-3,
    0x1.95cbaeea44b75p-1,
    0x1.dc1bd3446c000p-3,
    0x1.934c69de74838p-1,
    0x1.e8c01b8cfe000p-3,
    0x1.90d4f2f6752e6p-1,
    0x1.f5509c0179000p-3,
    0x1.8e6528effd79dp-1,
    0x1.00e6c121fb800p-2,
    0x1.8bfce9fcc007cp-1,
    0x1.071b80e93d000p-2,
    0x1.899c0dabec30ep-1,
    0x1.0d46b9e867000p-2,
    0x1.87427aa2317fbp-1,
    0x1.13687334bd000p-2,
    0x1.84f00acb39a08p-1,
    0x1.1980d67234800p-2,
    0x1.82a49e8653e55p-1,
    0x1.1f8ffe0cc8000p-2,
    0x1.8060195f40260p-1,
    0x1.2595fd7636800p-2,
    0x1.7e22563e0a329p-1,
    0x1.2b9300914a800p-2,
    0x1.7beb377dcb5adp-1,
    0x1.3187210436000p-2,
    0x1.79baa679725c2p-1,
    0x1.377266dec1800p-2,
    0x1.77907f2170657p-1,
    0x1.3d54ffbaf3000p-2,
    0x1.756cadbd6130cp-1,
    0x1.432eee32fe000p-2,
];
const LOG_TAB2: [f64; 256] = [
    0x1.61000014fb66bp-1,
    0x1.e026c91425b3cp-56,
    0x1.63000034db495p-1,
    0x1.dbfea48005d41p-55,
    0x1.650000d94d478p-1,
    0x1.e7fa786d6a5b7p-55,
    0x1.67000074e6fadp-1,
    0x1.1fcea6b54254cp-57,
    0x1.68ffffedf0faep-1,
    -0x1.c7e274c590efdp-56,
    0x1.6b0000763c5bcp-1,
    -0x1.ac16848dcda01p-55,
    0x1.6d0001e5cc1f6p-1,
    0x1.33f1c9d499311p-55,
    0x1.6efffeb05f63ep-1,
    -0x1.e80041ae22d53p-56,
    0x1.710000e869780p-1,
    0x1.bff6671097952p-56,
    0x1.72ffffc67e912p-1,
    0x1.c00e226bd8724p-55,
    0x1.74fffdf81116ap-1,
    -0x1.e02916ef101d2p-57,
    0x1.770000f679c90p-1,
    -0x1.7fc71cd549c74p-57,
    0x1.78ffffa7ec835p-1,
    0x1.1bec19ef50483p-55,
    0x1.7affffe20c2e6p-1,
    -0x1.07e1729cc6465p-56,
    0x1.7cfffed3fc900p-1,
    -0x1.08072087b8b1cp-55,
    0x1.7efffe9261a76p-1,
    0x1.dc0286d9df9aep-55,
    0x1.81000049ca3e8p-1,
    0x1.97fd251e54c33p-55,
    0x1.8300017932c8fp-1,
    -0x1.afee9b630f381p-55,
    0x1.850000633739cp-1,
    0x1.9bfbf6b6535bcp-55,
    0x1.87000204289c6p-1,
    -0x1.bbf65f3117b75p-55,
    0x1.88fffebf57904p-1,
    -0x1.9006ea23dcb57p-55,
    0x1.8b00022bc04dfp-1,
    -0x1.d00df38e04b0ap-56,
    0x1.8cfffe50c1b8ap-1,
    -0x1.8007146ff9f05p-55,
    0x1.8effffc918e43p-1,
    0x1.3817bd07a7038p-55,
    0x1.910001efa5fc7p-1,
    0x1.93e9176dfb403p-55,
    0x1.9300013467bb9p-1,
    0x1.f804e4b980276p-56,
    0x1.94fffe6ee076fp-1,
    -0x1.f7ef0d9ff622ep-55,
    0x1.96fffde3c12d1p-1,
    -0x1.082aa962638bap-56,
    0x1.98ffff4458a0dp-1,
    -0x1.7801b9164a8efp-55,
    0x1.9afffdd982e3ep-1,
    -0x1.740e08a5a9337p-55,
    0x1.9cfffed49fb66p-1,
    0x1.fce08c19be000p-60,
    0x1.9f00020f19c51p-1,
    -0x1.a3faa27885b0ap-55,
    0x1.a10001145b006p-1,
    0x1.4ff489958da56p-56,
    0x1.a300007bbf6fap-1,
    0x1.cbeab8a2b6d18p-55,
    0x1.a500010971d79p-1,
    0x1.8fecadd787930p-55,
    0x1.a70001df52e48p-1,
    -0x1.f41763dd8abdbp-55,
    0x1.a90001c593352p-1,
    -0x1.ebf0284c27612p-55,
    0x1.ab0002a4f3e4bp-1,
    -0x1.9fd043cff3f5fp-57,
    0x1.acfffd7ae1ed1p-1,
    -0x1.23ee7129070b4p-55,
    0x1.aefffee510478p-1,
    0x1.a063ee00edea3p-57,
    0x1.b0fffdb650d5bp-1,
    0x1.a06c8381f0ab9p-58,
    0x1.b2ffffeaaca57p-1,
    -0x1.9011e74233c1dp-56,
    0x1.b4fffd995badcp-1,
    -0x1.9ff1068862a9fp-56,
    0x1.b7000249e659cp-1,
    0x1.aff45d0864f3ep-55,
    0x1.b8ffff9871640p-1,
    0x1.cfe7796c2c3f9p-56,
    0x1.bafffd204cb4fp-1,
    -0x1.3ff27eef22bc4p-57,
    0x1.bcfffd2415c45p-1,
    -0x1.cffb7ee3bea21p-57,
    0x1.beffff86309dfp-1,
    -0x1.14103972e0b5cp-55,
    0x1.c0fffe1b57653p-1,
    0x1.bc16494b76a19p-55,
    0x1.c2ffff1fa57e3p-1,
    -0x1.4feef8d30c6edp-57,
    0x1.c4fffdcbfe424p-1,
    -0x1.43f68bcec4775p-55,
    0x1.c6fffed54b9f7p-1,
    0x1.47ea3f053e0ecp-55,
    0x1.c8fffeb998fd5p-1,
    0x1.383068df992f1p-56,
    0x1.cb0002125219ap-1,
    -0x1.8fd8e64180e04p-57,
    0x1.ccfffdd94469cp-1,
    0x1.e7ebe1cc7ea72p-55,
    0x1.cefffeafdc476p-1,
    0x1.ebe39ad9f88fep-55,
    0x1.d1000169af82bp-1,
    0x1.57d91a8b95a71p-56,
    0x1.d30000d0ff71dp-1,
    0x1.9c1906970c7dap-55,
    0x1.d4fffea790fc4p-1,
    -0x1.80e37c558fe0cp-58,
    0x1.d70002edc87e5p-1,
    -0x1.f80d64dc10f44p-56,
    0x1.d900021dc82aap-1,
    -0x1.47c8f94fd5c5cp-56,
    0x1.dafffd86b0283p-1,
    0x1.c7f1dc521617ep-55,
    0x1.dd000296c4739p-1,
    0x1.8019eb2ffb153p-55,
    0x1.defffe54490f5p-1,
    0x1.e00d2c652cc89p-57,
    0x1.e0fffcdabf694p-1,
    -0x1.f8340202d69d2p-56,
    0x1.e2fffdb52c8ddp-1,
    0x1.b00c1ca1b0864p-56,
    0x1.e4ffff24216efp-1,
    0x1.2ffa8b094ab51p-56,
    0x1.e6fffe88a5e11p-1,
    -0x1.7f673b1efbe59p-58,
    0x1.e9000119eff0dp-1,
    -0x1.4808d5e0bc801p-55,
    0x1.eafffdfa51744p-1,
    0x1.80006d54320b5p-56,
    0x1.ed0001a127fa1p-1,
    -0x1.002f860565c92p-58,
    0x1.ef00007babcc4p-1,
    -0x1.540445d35e611p-55,
    0x1.f0ffff57a8d02p-1,
    -0x1.ffb3139ef9105p-59,
    0x1.f30001ee58ac7p-1,
    0x1.a81acf2731155p-55,
    0x1.f4ffff5823494p-1,
    0x1.a3f41d4d7c743p-55,
    0x1.f6ffffca94c6bp-1,
    -0x1.202f41c987875p-57,
    0x1.f8fffe1f9c441p-1,
    0x1.77dd1f477e74bp-56,
    0x1.fafffd2e0e37ep-1,
    -0x1.f01199a7ca331p-57,
    0x1.fd0001c77e49ep-1,
    0x1.181ee4bceacb1p-56,
    0x1.feffff7e0c331p-1,
    -0x1.e05370170875ap-57,
    0x1.00ffff465606ep+0,
    -0x1.a7ead491c0adap-55,
    0x1.02ffff3867a58p+0,
    -0x1.77f69c3fcb2e0p-54,
    0x1.04ffffdfc0d17p+0,
    0x1.7bffe34cb945bp-54,
    0x1.0700003cd4d82p+0,
    0x1.20083c0e456cbp-55,
    0x1.08ffff9f2cbe8p+0,
    -0x1.dffdfbe37751ap-57,
    0x1.0b000010cda65p+0,
    -0x1.13f7faee626ebp-54,
    0x1.0d00001a4d338p+0,
    0x1.07dfa79489ff7p-55,
    0x1.0effffadafdfdp+0,
    -0x1.7040570d66bc0p-56,
    0x1.110000bbafd96p+0,
    0x1.e80d4846d0b62p-55,
    0x1.12ffffae5f45dp+0,
    0x1.dbffa64fd36efp-54,
    0x1.150000dd59ad9p+0,
    0x1.a0077701250aep-54,
    0x1.170000f21559ap+0,
    0x1.dfdf9e2e3deeep-55,
    0x1.18ffffc275426p+0,
    0x1.10030dc3b7273p-54,
    0x1.1b000123d3c59p+0,
    0x1.97f7980030188p-54,
    0x1.1cffff8299eb7p+0,
    -0x1.5f932ab9f8c67p-57,
    0x1.1effff48ad400p+0,
    0x1.37fbf9da75bebp-54,
    0x1.210000c8b86a4p+0,
    0x1.f806b91fd5b22p-54,
    0x1.2300003854303p+0,
    0x1.3ffc2eb9fbf33p-54,
    0x1.24fffffbcf684p+0,
    0x1.601e77e2e2e72p-56,
    0x1.26ffff52921d9p+0,
    0x1.ffcbb767f0c61p-56,
    0x1.2900014933a3cp+0,
    -0x1.202ca3c02412bp-56,
    0x1.2b00014556313p+0,
    -0x1.2808233f21f02p-54,
    0x1.2cfffebfe523bp+0,
    -0x1.8ff7e384fdcf2p-55,
    0x1.2f0000bb8ad96p+0,
    -0x1.5ff51503041c5p-55,
    0x1.30ffffb7ae2afp+0,
    -0x1.10071885e289dp-55,
    0x1.32ffffeac5f7fp+0,
    -0x1.1ff5d3fb7b715p-54,
    0x1.350000ca66756p+0,
    0x1.57f82228b82bdp-54,
    0x1.3700011fbf721p+0,
    0x1.000bac40dd5ccp-55,
    0x1.38ffff9592fb9p+0,
    -0x1.43f9d2db2a751p-54,
    0x1.3b00004ddd242p+0,
    0x1.57f6b707638e1p-55,
    0x1.3cffff5b2c957p+0,
    0x1.a023a10bf1231p-56,
    0x1.3efffeab0b418p+0,
    0x1.87f6d66b152b0p-54,
    0x1.410001532aff4p+0,
    0x1.7f8375f198524p-57,
    0x1.4300017478b29p+0,
    0x1.301e672dc5143p-55,
    0x1.44fffe795b463p+0,
    0x1.9ff69b8b2895ap-55,
    0x1.46fffe80475e0p+0,
    -0x1.5c0b19bc2f254p-54,
    0x1.48fffef6fc1e7p+0,
    0x1.b4009f23a2a72p-54,
    0x1.4afffe5bea704p+0,
    -0x1.4ffb7bf0d7d45p-54,
    0x1.4d000171027dep+0,
    -0x1.9c06471dc6a3dp-54,
    0x1.4f0000ff03ee2p+0,
    0x1.77f890b85531cp-54,
    0x1.5100012dc4bd1p+0,
    0x1.004657166a436p-57,
    0x1.530001605277ap+0,
    -0x1.6bfcece233209p-54,
    0x1.54fffecdb704cp+0,
    -0x1.902720505a1d7p-55,
    0x1.56fffef5f54a9p+0,
    0x1.bbfe60ec96412p-54,
    0x1.5900017e61012p+0,
    0x1.87ec581afef90p-55,
    0x1.5b00003c93e92p+0,
    -0x1.f41080abf0cc0p-54,
    0x1.5d0001d4919bcp+0,
    -0x1.8812afb254729p-54,
    0x1.5efffe7b87a89p+0,
    -0x1.47eb780ed6904p-54,
];

const fn top16(x: f64) u32 {
    return (bits(x) >> 48) as u32;
}

/// The natural logarithm of x.
@export("log")
pub const fn log(x: f64) f64 {
    let mut ix = bits(x);
    let top = top16(x);
    let lo_b = bits(1.0 - 0x1p-4);
    let hi_b = bits(1.0 + 0x1.09p-4);
    if ix.wrapping_sub(lo_b) < hi_b - lo_b {
        // Handle close to 1.0 inputs separately.
        let r = x - 1.0;
        let r2 = r * r;
        let r3 = r * r2;
        let mut y = r3 * (LOG_POLY1[1] + r * LOG_POLY1[2] + r2 * LOG_POLY1[3] + r3 * (LOG_POLY1[4] + r * LOG_POLY1[5] + r2 * LOG_POLY1[6] + r3 * (LOG_POLY1[7] + r * LOG_POLY1[8] + r2 * LOG_POLY1[9] + r3 * LOG_POLY1[10])));
        // Worst-case error is around 0.507 ULP.
        let mut w = r * 0x1p27;
        let rhi = r + w - w;
        let rlo = r - rhi;
        w = rhi * rhi * LOG_POLY1[0]; // B[0] == -0.5.
        let hi = r + w;
        let mut lo = r - hi + w;
        lo += LOG_POLY1[0] * rlo * (rhi + r);
        y += lo;
        y += hi;
        return y;
    }
    if top.wrapping_sub(0x0010) >= 0x7ff0 - 0x0010 {
        // x < 0x1p-1022 or inf or nan.
        if ix << 1 == 0 {
            return divzero(1);
        }
        if ix == bits(INF) {
            // log(inf) == inf.
            return x;
        }
        if (top & 0x8000) != 0 || (top & 0x7ff0) == 0x7ff0 {
            return invalid(x);
        }
        // x is subnormal, normalize it.
        ix = bits(x * 0x1p52);
        ix = ix.wrapping_sub(52u64 << 52);
    }
    // x = 2^k z; where z is in range [OFF,2*OFF) and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3fe6000000000000);
    let i = ((tmp >> 52 - 7) % 128) as usize;
    let k = (tmp as i64 >> 52) as i32; // arithmetic shift
    let iz = ix.wrapping_sub(tmp & 0xfffu64 << 52);
    let invc = unsafe LOG_TAB[2 * i];
    let logc = unsafe LOG_TAB[2 * i + 1];
    let z = dbl(iz);
    // log(x) = log1p(z/c-1) + log(c) + k*Ln2.
    // r ~= z/c - 1, |r| < 1/(2*N).
    // rounding error: 0x1p-55/N + 0x1p-66.
    let r = (z - unsafe LOG_TAB2[2 * i] - unsafe LOG_TAB2[2 * i + 1]) * invc;
    let kd = k as f64;
    // hi + lo = r + log(c) + k*Ln2.
    let w = kd * LOG_LN2HI + logc;
    let hi = w + r;
    let lo = w - hi + r + kd * LOG_LN2LO;
    // log(x) = lo + (log1p(r) - r) + hi.
    let r2 = r * r; // rounding error: 0x1p-54/N^2.
    // Worst case error if |y| > 0x1p-5:
    // 0.5 + 4.13/N + abs-poly-error*2^57 ULP (+ 0.002 ULP without fma)
    // Worst case error if |y| > 0x1p-4:
    // 0.5 + 2.06/N + abs-poly-error*2^56 ULP (+ 0.001 ULP without fma).
    return lo + r2 * LOG_POLY[0] + r * r2 * (LOG_POLY[1] + r * LOG_POLY[2] + r2 * (LOG_POLY[3] + r * LOG_POLY[4])) + hi;
}

// The data of log2: LOG2_TAB holds (invc, logc) pairs and LOG2_TAB2 (chi, clo) pairs, 64 of each.
const LOG2_INVLN2HI: f64 = 0x1.7154765200000p+0;
const LOG2_INVLN2LO: f64 = 0x1.705fc2eefa200p-33;
const LOG2_POLY: [f64; 6] = [
    -0x1.71547652b8339p-1,
    0x1.ec709dc3a04bep-2,
    -0x1.7154764702ffbp-2,
    0x1.2776c50034c48p-2,
    -0x1.ec7b328ea92bcp-3,
    0x1.a6225e117f92ep-3,
];
const LOG2_POLY1: [f64; 10] = [
    -0x1.71547652b82fep-1,
    0x1.ec709dc3a03f7p-2,
    -0x1.71547652b7c3fp-2,
    0x1.2776c50f05be4p-2,
    -0x1.ec709dd768fe5p-3,
    0x1.a61761ec4e736p-3,
    -0x1.7153fbc64a79bp-3,
    0x1.484d154f01b4ap-3,
    -0x1.289e4a72c383cp-3,
    0x1.0b32f285aee66p-3,
];
const LOG2_TAB: [f64; 128] = [
    0x1.724286bb1acf8p+0,
    -0x1.1095feecdb000p-1,
    0x1.6e1f766d2cca1p+0,
    -0x1.08494bd76d000p-1,
    0x1.6a13d0e30d48ap+0,
    -0x1.00143aee8f800p-1,
    0x1.661ec32d06c85p+0,
    -0x1.efec5360b4000p-2,
    0x1.623fa951198f8p+0,
    -0x1.dfdd91ab7e000p-2,
    0x1.5e75ba4cf026cp+0,
    -0x1.cffae0cc79000p-2,
    0x1.5ac055a214fb8p+0,
    -0x1.c043811fda000p-2,
    0x1.571ed0f166e1ep+0,
    -0x1.b0b67323ae000p-2,
    0x1.53909590bf835p+0,
    -0x1.a152f5a2db000p-2,
    0x1.5014fed61adddp+0,
    -0x1.9217f5af86000p-2,
    0x1.4cab88e487bd0p+0,
    -0x1.8304db0719000p-2,
    0x1.49539b4334feep+0,
    -0x1.74189f9a9e000p-2,
    0x1.460cbdfafd569p+0,
    -0x1.6552bb5199000p-2,
    0x1.42d664ee4b953p+0,
    -0x1.56b23a29b1000p-2,
    0x1.3fb01111dd8a6p+0,
    -0x1.483650f5fa000p-2,
    0x1.3c995b70c5836p+0,
    -0x1.39de937f6a000p-2,
    0x1.3991c4ab6fd4ap+0,
    -0x1.2baa1538d6000p-2,
    0x1.3698e0ce099b5p+0,
    -0x1.1d98340ca4000p-2,
    0x1.33ae48213e7b2p+0,
    -0x1.0fa853a40e000p-2,
    0x1.30d191985bdb1p+0,
    -0x1.01d9c32e73000p-2,
    0x1.2e025cab271d7p+0,
    -0x1.e857da2fa6000p-3,
    0x1.2b404cf13cd82p+0,
    -0x1.cd3c8633d8000p-3,
    0x1.288b02c7ccb50p+0,
    -0x1.b26034c14a000p-3,
    0x1.25e2263944de5p+0,
    -0x1.97c1c2f4fe000p-3,
    0x1.234563d8615b1p+0,
    -0x1.7d6023f800000p-3,
    0x1.20b46e33eaf38p+0,
    -0x1.633a71a05e000p-3,
    0x1.1e2eefdcda3ddp+0,
    -0x1.494f5e9570000p-3,
    0x1.1bb4a580b3930p+0,
    -0x1.2f9e424e0a000p-3,
    0x1.19453847f2200p+0,
    -0x1.162595afdc000p-3,
    0x1.16e06c0d5d73cp+0,
    -0x1.f9c9a75bd8000p-4,
    0x1.1485f47b7e4c2p+0,
    -0x1.c7b575bf9c000p-4,
    0x1.12358ad0085d1p+0,
    -0x1.960c60ff48000p-4,
    0x1.0fef00f532227p+0,
    -0x1.64ce247b60000p-4,
    0x1.0db2077d03a8fp+0,
    -0x1.33f78b2014000p-4,
    0x1.0b7e6d65980d9p+0,
    -0x1.0387d1a42c000p-4,
    0x1.0953efe7b408dp+0,
    -0x1.a6f9208b50000p-5,
    0x1.07325cac53b83p+0,
    -0x1.47a954f770000p-5,
    0x1.05197e40d1b5cp+0,
    -0x1.d23a8c50c0000p-6,
    0x1.03091c1208ea2p+0,
    -0x1.16a2629780000p-6,
    0x1.0101025b37e21p+0,
    -0x1.720f8d8e80000p-8,
    0x1.fc07ef9caa76bp-1,
    0x1.6fe53b1500000p-7,
    0x1.f4465d3f6f184p-1,
    0x1.11ccce10f8000p-5,
    0x1.ecc079f84107fp-1,
    0x1.c4dfc8c8b8000p-5,
    0x1.e573a99975ae8p-1,
    0x1.3aa321e574000p-4,
    0x1.de5d6f0bd3de6p-1,
    0x1.918a0d08b8000p-4,
    0x1.d77b681ff38b3p-1,
    0x1.e72e9da044000p-4,
    0x1.d0cb5724de943p-1,
    0x1.1dcd2507f6000p-3,
    0x1.ca4b2dc0e7563p-1,
    0x1.476ab03dea000p-3,
    0x1.c3f8ee8d6cb51p-1,
    0x1.7074377e22000p-3,
    0x1.bdd2b4f020c4cp-1,
    0x1.98ede8ba94000p-3,
    0x1.b7d6c006015cap-1,
    0x1.c0db86ad2e000p-3,
    0x1.b20366e2e338fp-1,
    0x1.e840aafcee000p-3,
    0x1.ac57026295039p-1,
    0x1.0790ab4678000p-2,
    0x1.a6d01bc2731ddp-1,
    0x1.1ac056801c000p-2,
    0x1.a16d3bc3ff18bp-1,
    0x1.2db11d4fee000p-2,
    0x1.9c2d14967feadp-1,
    0x1.406464ec58000p-2,
    0x1.970e4f47c9902p-1,
    0x1.52dbe093af000p-2,
    0x1.920fb3982bcf2p-1,
    0x1.651902050d000p-2,
    0x1.8d30187f759f1p-1,
    0x1.771d2cdeaf000p-2,
    0x1.886e5ebb9f66dp-1,
    0x1.88e9c857d9000p-2,
    0x1.83c97b658b994p-1,
    0x1.9a80155e16000p-2,
    0x1.7f405ffc61022p-1,
    0x1.abe186ed3d000p-2,
    0x1.7ad22181415cap-1,
    0x1.bd0f2aea0e000p-2,
    0x1.767dcf99eff8cp-1,
    0x1.ce0a43dbf4000p-2,
];
const LOG2_TAB2: [f64; 128] = [
    0x1.6200012b90a8ep-1,
    0x1.904ab0644b605p-55,
    0x1.66000045734a6p-1,
    0x1.1ff9bea62f7a9p-57,
    0x1.69fffc325f2c5p-1,
    0x1.27ecfcb3c90bap-55,
    0x1.6e00038b95a04p-1,
    0x1.8ff8856739326p-55,
    0x1.71fffe09994e3p-1,
    0x1.afd40275f82b1p-55,
    0x1.7600015590e10p-1,
    -0x1.2fd75b4238341p-56,
    0x1.7a00012655bd5p-1,
    0x1.808e67c242b76p-56,
    0x1.7e0003259e9a6p-1,
    -0x1.208e426f622b7p-57,
    0x1.81fffedb4b2d2p-1,
    -0x1.402461ea5c92fp-55,
    0x1.860002dfafcc3p-1,
    0x1.df7f4a2f29a1fp-57,
    0x1.89ffff78c6b50p-1,
    -0x1.e0453094995fdp-55,
    0x1.8e00039671566p-1,
    -0x1.a04f3bec77b45p-55,
    0x1.91fffe2bf1745p-1,
    -0x1.7fa34400e203cp-56,
    0x1.95fffcc5c9fd1p-1,
    -0x1.6ff8005a0695dp-56,
    0x1.9a0003bba4767p-1,
    0x1.0f8c4c4ec7e03p-56,
    0x1.9dfffe7b92da5p-1,
    0x1.e7fd9478c4602p-55,
    0x1.a1fffd72efdafp-1,
    -0x1.a0c554dcdae7ep-57,
    0x1.a5fffde04ff95p-1,
    0x1.67da98ce9b26bp-55,
    0x1.a9fffca5e8d2bp-1,
    -0x1.284c9b54c13dep-55,
    0x1.adfffddad03eap-1,
    0x1.812c8ea602e3cp-58,
    0x1.b1ffff10d3d4dp-1,
    -0x1.efaddad27789cp-55,
    0x1.b5fffce21165ap-1,
    0x1.3cb1719c61237p-58,
    0x1.b9fffd950e674p-1,
    0x1.3f7d94194ce00p-56,
    0x1.be000139ca8afp-1,
    0x1.50ac4215d9bc0p-56,
    0x1.c20005b46df99p-1,
    0x1.beea653e9c1c9p-57,
    0x1.c600040b9f7aep-1,
    -0x1.c079f274a70d6p-56,
    0x1.ca0006255fd8ap-1,
    -0x1.a0b4076e84c1fp-56,
    0x1.cdfffd94c095dp-1,
    0x1.8f933f99ab5d7p-55,
    0x1.d1ffff975d6cfp-1,
    -0x1.82c08665fe1bep-58,
    0x1.d5fffa2561c93p-1,
    -0x1.b04289bd295f3p-56,
    0x1.d9fff9d228b0cp-1,
    0x1.70251340fa236p-55,
    0x1.de00065bc7e16p-1,
    -0x1.5011e16a4d80cp-56,
    0x1.e200002f64791p-1,
    0x1.9802f09ef62e0p-55,
    0x1.e600057d7a6d8p-1,
    -0x1.e0b75580cf7fap-56,
    0x1.ea00027edc00cp-1,
    -0x1.c848309459811p-55,
    0x1.ee0006cf5cb7cp-1,
    -0x1.f8027951576f4p-55,
    0x1.f2000782b7dccp-1,
    -0x1.f81d97274538fp-55,
    0x1.f6000260c450ap-1,
    -0x1.071002727ffdcp-59,
    0x1.f9fffe88cd533p-1,
    -0x1.81bdce1fda8b0p-58,
    0x1.fdfffd50f8689p-1,
    0x1.7f91acb918e6ep-55,
    0x1.0200004292367p+0,
    0x1.b7ff365324681p-54,
    0x1.05fffe3e3d668p+0,
    0x1.6fa08ddae957bp-55,
    0x1.0a0000a85a757p+0,
    -0x1.7e2de80d3fb91p-58,
    0x1.0e0001a5f3fccp+0,
    -0x1.1823305c5f014p-54,
    0x1.11ffff8afbaf5p+0,
    -0x1.bfabb6680bac2p-55,
    0x1.15fffe54d91adp+0,
    -0x1.d7f121737e7efp-54,
    0x1.1a00011ac36e1p+0,
    0x1.c000a0516f5ffp-54,
    0x1.1e00019c84248p+0,
    -0x1.082fbe4da5da0p-54,
    0x1.220000ffe5e6ep+0,
    -0x1.8fdd04c9cfb43p-55,
    0x1.26000269fd891p+0,
    0x1.cfe2a7994d182p-55,
    0x1.2a00029a6e6dap+0,
    -0x1.00273715e8bc5p-56,
    0x1.2dfffe0293e39p+0,
    0x1.b7c39dab2a6f9p-54,
    0x1.31ffff7dcf082p+0,
    0x1.df1336edc5254p-56,
    0x1.35ffff05a8b60p+0,
    -0x1.e03564ccd31ebp-54,
    0x1.3a0002e0eaeccp+0,
    0x1.5f0e74bd3a477p-56,
    0x1.3e000043bb236p+0,
    0x1.c7dcb149d8833p-54,
    0x1.4200002d187ffp+0,
    0x1.e08afcf2d3d28p-56,
    0x1.460000d387cb1p+0,
    0x1.20837856599a6p-55,
    0x1.4a00004569f89p+0,
    -0x1.9fa5c904fbcd2p-55,
    0x1.4e000043543f3p+0,
    -0x1.81125ed175329p-56,
    0x1.51fffcc027f0fp+0,
    0x1.883d8847754dcp-54,
    0x1.55ffffd87b36fp+0,
    -0x1.709e731d02807p-55,
    0x1.59ffff21df7bap+0,
    0x1.7f79f68727b02p-55,
    0x1.5dfffebfc3481p+0,
    -0x1.180902e30e93ep-54,
];

/// The base-2 logarithm of x.
@export("log2")
pub const fn log2(x: f64) f64 {
    let mut ix = bits(x);
    let top = top16(x);
    let lo_b = bits(1.0 - 0x1.5b51p-5);
    let hi_b = bits(1.0 + 0x1.6ab2p-5);
    if ix.wrapping_sub(lo_b) < hi_b - lo_b {
        // Handle close to 1.0 inputs separately.
        let r = x - 1.0;
        let rhi = dbl(bits(r) & ~0u64 << 32);
        let rlo = r - rhi;
        let hi = rhi * LOG2_INVLN2HI;
        let mut lo = rlo * LOG2_INVLN2HI + r * LOG2_INVLN2LO;
        let r2 = r * r; // rounding error: 0x1p-62.
        let r4 = r2 * r2;
        // Worst-case error is less than 0.54 ULP (0.55 ULP without fma).
        let p = r2 * (LOG2_POLY1[0] + r * LOG2_POLY1[1]);
        let mut y = hi + p;
        lo += hi - y + p;
        lo += r4 * (LOG2_POLY1[2] + r * LOG2_POLY1[3] + r2 * (LOG2_POLY1[4] + r * LOG2_POLY1[5]) + r4 * (LOG2_POLY1[6] + r * LOG2_POLY1[7] + r2 * (LOG2_POLY1[8] + r * LOG2_POLY1[9])));
        y += lo;
        return y;
    }
    if top.wrapping_sub(0x0010) >= 0x7ff0 - 0x0010 {
        // x < 0x1p-1022 or inf or nan.
        if ix << 1 == 0 {
            return divzero(1);
        }
        if ix == bits(INF) {
            // log(inf) == inf.
            return x;
        }
        if (top & 0x8000) != 0 || (top & 0x7ff0) == 0x7ff0 {
            return invalid(x);
        }
        // x is subnormal, normalize it.
        ix = bits(x * 0x1p52);
        ix = ix.wrapping_sub(52u64 << 52);
    }
    // x = 2^k z; where z is in range [OFF,2*OFF) and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3fe6000000000000);
    let i = ((tmp >> 52 - 6) % 64) as usize;
    let k = (tmp as i64 >> 52) as i32; // arithmetic shift
    let iz = ix.wrapping_sub(tmp & 0xfffu64 << 52);
    let invc = unsafe LOG2_TAB[2 * i];
    let logc = unsafe LOG2_TAB[2 * i + 1];
    let z = dbl(iz);
    let kd = k as f64;
    // log2(x) = log2(z/c) + log2(c) + k.
    // r ~= z/c - 1, |r| < 1/(2*N).
    // rounding error: 0x1p-55/N + 0x1p-65.
    let r = (z - unsafe LOG2_TAB2[2 * i] - unsafe LOG2_TAB2[2 * i + 1]) * invc;
    let rhi = dbl(bits(r) & ~0u64 << 32);
    let rlo = r - rhi;
    let t1 = rhi * LOG2_INVLN2HI;
    let t2 = rlo * LOG2_INVLN2HI + r * LOG2_INVLN2LO;
    // hi + lo = r/ln2 + log2(c) + k.
    let t3 = kd + logc;
    let hi = t3 + t1;
    let lo = t3 - hi + t1 + t2;
    // log2(r+1) = r/ln2 + r^2*poly(r).
    // Evaluation is optimized assuming superscalar pipelined execution.
    let r2 = r * r; // rounding error: 0x1p-54/N^2.
    let r4 = r2 * r2;
    // Worst-case error if |y| > 0x1p-4: 0.547 ULP (0.550 ULP without fma).
    // ~ 0.5 + 2/N/ln2 + abs-poly-error*0x1p56 ULP (+ 0.003 ULP without fma).
    let p = LOG2_POLY[0] + r * LOG2_POLY[1] + r2 * (LOG2_POLY[2] + r * LOG2_POLY[3]) + r4 * (LOG2_POLY[4] + r * LOG2_POLY[5]);
    return lo + r2 * p + hi;
}

// The data of pow's logarithm: POW_TAB holds (invc, pad, logc, logctail) quadruples, 128 of them.
const POW_LN2HI: f64 = 0x1.62e42fefa3800p-1;
const POW_LN2LO: f64 = 0x1.ef35793c76730p-45;
const POW_POLY: [f64; 7] = [
    -0x1.0000000000000p-1,
    -0x1.5555555555560p-1,
    0x1.0000000000006p-1,
    0x1.999999959554ep-1,
    -0x1.555555529a47ap-1,
    -0x1.2495b9b4845e9p+0,
    0x1.0002b8b263fc3p+0,
];
const POW_TAB: [f64; 512] = [
    0x1.6a00000000000p+0,
    0.0,
    -0x1.62c82f2b9c800p-2,
    0x1.ab42428375680p-48,
    0x1.6800000000000p+0,
    0.0,
    -0x1.5d1bdbf580800p-2,
    -0x1.ca508d8e0f720p-46,
    0x1.6600000000000p+0,
    0.0,
    -0x1.5767717455800p-2,
    -0x1.362a4d5b6506dp-45,
    0x1.6400000000000p+0,
    0.0,
    -0x1.51aad872df800p-2,
    -0x1.684e49eb067d5p-49,
    0x1.6200000000000p+0,
    0.0,
    -0x1.4be5f95777800p-2,
    -0x1.41b6993293ee0p-47,
    0x1.6000000000000p+0,
    0.0,
    -0x1.4618bc21c6000p-2,
    0x1.3d82f484c84ccp-46,
    0x1.5e00000000000p+0,
    0.0,
    -0x1.404308686a800p-2,
    0x1.c42f3ed820b3ap-50,
    0x1.5c00000000000p+0,
    0.0,
    -0x1.3a64c55694800p-2,
    0x1.0b1c686519460p-45,
    0x1.5a00000000000p+0,
    0.0,
    -0x1.347dd9a988000p-2,
    0x1.5594dd4c58092p-45,
    0x1.5800000000000p+0,
    0.0,
    -0x1.2e8e2bae12000p-2,
    0x1.67b1e99b72bd8p-45,
    0x1.5600000000000p+0,
    0.0,
    -0x1.2895a13de8800p-2,
    0x1.5ca14b6cfb03fp-46,
    0x1.5600000000000p+0,
    0.0,
    -0x1.2895a13de8800p-2,
    0x1.5ca14b6cfb03fp-46,
    0x1.5400000000000p+0,
    0.0,
    -0x1.22941fbcf7800p-2,
    -0x1.65a242853da76p-46,
    0x1.5200000000000p+0,
    0.0,
    -0x1.1c898c1699800p-2,
    -0x1.fafbc68e75404p-46,
    0x1.5000000000000p+0,
    0.0,
    -0x1.1675cababa800p-2,
    0x1.f1fc63382a8f0p-46,
    0x1.4e00000000000p+0,
    0.0,
    -0x1.1058bf9ae4800p-2,
    -0x1.6a8c4fd055a66p-45,
    0x1.4c00000000000p+0,
    0.0,
    -0x1.0a324e2739000p-2,
    -0x1.c6bee7ef4030ep-47,
    0x1.4a00000000000p+0,
    0.0,
    -0x1.0402594b4d000p-2,
    -0x1.036b89ef42d7fp-48,
    0x1.4a00000000000p+0,
    0.0,
    -0x1.0402594b4d000p-2,
    -0x1.036b89ef42d7fp-48,
    0x1.4800000000000p+0,
    0.0,
    -0x1.fb9186d5e4000p-3,
    0x1.d572aab993c87p-47,
    0x1.4600000000000p+0,
    0.0,
    -0x1.ef0adcbdc6000p-3,
    0x1.b26b79c86af24p-45,
    0x1.4400000000000p+0,
    0.0,
    -0x1.e27076e2af000p-3,
    -0x1.72f4f543fff10p-46,
    0x1.4200000000000p+0,
    0.0,
    -0x1.d5c216b4fc000p-3,
    0x1.1ba91bbca681bp-45,
    0x1.4000000000000p+0,
    0.0,
    -0x1.c8ff7c79aa000p-3,
    0x1.7794f689f8434p-45,
    0x1.4000000000000p+0,
    0.0,
    -0x1.c8ff7c79aa000p-3,
    0x1.7794f689f8434p-45,
    0x1.3e00000000000p+0,
    0.0,
    -0x1.bc286742d9000p-3,
    0x1.94eb0318bb78fp-46,
    0x1.3c00000000000p+0,
    0.0,
    -0x1.af3c94e80c000p-3,
    0x1.a4e633fcd9066p-52,
    0x1.3a00000000000p+0,
    0.0,
    -0x1.a23bc1fe2b000p-3,
    -0x1.58c64dc46c1eap-45,
    0x1.3a00000000000p+0,
    0.0,
    -0x1.a23bc1fe2b000p-3,
    -0x1.58c64dc46c1eap-45,
    0x1.3800000000000p+0,
    0.0,
    -0x1.9525a9cf45000p-3,
    -0x1.ad1d904c1d4e3p-45,
    0x1.3600000000000p+0,
    0.0,
    -0x1.87fa06520d000p-3,
    0x1.bbdbf7fdbfa09p-45,
    0x1.3400000000000p+0,
    0.0,
    -0x1.7ab890210e000p-3,
    0x1.bdb9072534a58p-45,
    0x1.3400000000000p+0,
    0.0,
    -0x1.7ab890210e000p-3,
    0x1.bdb9072534a58p-45,
    0x1.3200000000000p+0,
    0.0,
    -0x1.6d60fe719d000p-3,
    -0x1.0e46aa3b2e266p-46,
    0x1.3000000000000p+0,
    0.0,
    -0x1.5ff3070a79000p-3,
    -0x1.e9e439f105039p-46,
    0x1.3000000000000p+0,
    0.0,
    -0x1.5ff3070a79000p-3,
    -0x1.e9e439f105039p-46,
    0x1.2e00000000000p+0,
    0.0,
    -0x1.526e5e3a1b000p-3,
    -0x1.0de8b90075b8fp-45,
    0x1.2c00000000000p+0,
    0.0,
    -0x1.44d2b6ccb8000p-3,
    0x1.70cc16135783cp-46,
    0x1.2c00000000000p+0,
    0.0,
    -0x1.44d2b6ccb8000p-3,
    0x1.70cc16135783cp-46,
    0x1.2a00000000000p+0,
    0.0,
    -0x1.371fc201e9000p-3,
    0x1.178864d27543ap-48,
    0x1.2800000000000p+0,
    0.0,
    -0x1.29552f81ff000p-3,
    -0x1.48d301771c408p-45,
    0x1.2600000000000p+0,
    0.0,
    -0x1.1b72ad52f6000p-3,
    -0x1.e80a41811a396p-45,
    0x1.2600000000000p+0,
    0.0,
    -0x1.1b72ad52f6000p-3,
    -0x1.e80a41811a396p-45,
    0x1.2400000000000p+0,
    0.0,
    -0x1.0d77e7cd09000p-3,
    0x1.a699688e85bf4p-47,
    0x1.2400000000000p+0,
    0.0,
    -0x1.0d77e7cd09000p-3,
    0x1.a699688e85bf4p-47,
    0x1.2200000000000p+0,
    0.0,
    -0x1.fec9131dbe000p-4,
    -0x1.575545ca333f2p-45,
    0x1.2000000000000p+0,
    0.0,
    -0x1.e27076e2b0000p-4,
    0x1.a342c2af0003cp-45,
    0x1.2000000000000p+0,
    0.0,
    -0x1.e27076e2b0000p-4,
    0x1.a342c2af0003cp-45,
    0x1.1e00000000000p+0,
    0.0,
    -0x1.c5e548f5bc000p-4,
    -0x1.d0c57585fbe06p-46,
    0x1.1c00000000000p+0,
    0.0,
    -0x1.a926d3a4ae000p-4,
    0x1.53935e85baac8p-45,
    0x1.1c00000000000p+0,
    0.0,
    -0x1.a926d3a4ae000p-4,
    0x1.53935e85baac8p-45,
    0x1.1a00000000000p+0,
    0.0,
    -0x1.8c345d631a000p-4,
    0x1.37c294d2f5668p-46,
    0x1.1a00000000000p+0,
    0.0,
    -0x1.8c345d631a000p-4,
    0x1.37c294d2f5668p-46,
    0x1.1800000000000p+0,
    0.0,
    -0x1.6f0d28ae56000p-4,
    -0x1.69737c93373dap-45,
    0x1.1600000000000p+0,
    0.0,
    -0x1.51b073f062000p-4,
    0x1.f025b61c65e57p-46,
    0x1.1600000000000p+0,
    0.0,
    -0x1.51b073f062000p-4,
    0x1.f025b61c65e57p-46,
    0x1.1400000000000p+0,
    0.0,
    -0x1.341d7961be000p-4,
    0x1.c5edaccf913dfp-45,
    0x1.1400000000000p+0,
    0.0,
    -0x1.341d7961be000p-4,
    0x1.c5edaccf913dfp-45,
    0x1.1200000000000p+0,
    0.0,
    -0x1.16536eea38000p-4,
    0x1.47c5e768fa309p-46,
    0x1.1000000000000p+0,
    0.0,
    -0x1.f0a30c0118000p-5,
    0x1.d599e83368e91p-45,
    0x1.1000000000000p+0,
    0.0,
    -0x1.f0a30c0118000p-5,
    0x1.d599e83368e91p-45,
    0x1.0e00000000000p+0,
    0.0,
    -0x1.b42dd71198000p-5,
    0x1.c827ae5d6704cp-46,
    0x1.0e00000000000p+0,
    0.0,
    -0x1.b42dd71198000p-5,
    0x1.c827ae5d6704cp-46,
    0x1.0c00000000000p+0,
    0.0,
    -0x1.77458f632c000p-5,
    -0x1.cfc4634f2a1eep-45,
    0x1.0c00000000000p+0,
    0.0,
    -0x1.77458f632c000p-5,
    -0x1.cfc4634f2a1eep-45,
    0x1.0a00000000000p+0,
    0.0,
    -0x1.39e87b9fec000p-5,
    0x1.502b7f526feaap-48,
    0x1.0a00000000000p+0,
    0.0,
    -0x1.39e87b9fec000p-5,
    0x1.502b7f526feaap-48,
    0x1.0800000000000p+0,
    0.0,
    -0x1.f829b0e780000p-6,
    -0x1.980267c7e09e4p-45,
    0x1.0800000000000p+0,
    0.0,
    -0x1.f829b0e780000p-6,
    -0x1.980267c7e09e4p-45,
    0x1.0600000000000p+0,
    0.0,
    -0x1.7b91b07d58000p-6,
    -0x1.88d5493faa639p-45,
    0x1.0400000000000p+0,
    0.0,
    -0x1.fc0a8b0fc0000p-7,
    -0x1.f1e7cf6d3a69cp-50,
    0x1.0400000000000p+0,
    0.0,
    -0x1.fc0a8b0fc0000p-7,
    -0x1.f1e7cf6d3a69cp-50,
    0x1.0200000000000p+0,
    0.0,
    -0x1.fe02a6b100000p-8,
    -0x1.9e23f0dda40e4p-46,
    0x1.0200000000000p+0,
    0.0,
    -0x1.fe02a6b100000p-8,
    -0x1.9e23f0dda40e4p-46,
    0x1.0000000000000p+0,
    0.0,
    0.0,
    0.0,
    0x1.0000000000000p+0,
    0.0,
    0.0,
    0.0,
    0x1.fc00000000000p-1,
    0.0,
    0x1.0101575890000p-7,
    -0x1.0c76b999d2be8p-46,
    0x1.f800000000000p-1,
    0.0,
    0x1.0205658938000p-6,
    -0x1.3dc5b06e2f7d2p-45,
    0x1.f400000000000p-1,
    0.0,
    0x1.8492528c90000p-6,
    -0x1.aa0ba325a0c34p-45,
    0x1.f000000000000p-1,
    0.0,
    0x1.0415d89e74000p-5,
    0x1.111c05cf1d753p-47,
    0x1.ec00000000000p-1,
    0.0,
    0x1.466aed42e0000p-5,
    -0x1.c167375bdfd28p-45,
    0x1.e800000000000p-1,
    0.0,
    0x1.894aa149fc000p-5,
    -0x1.97995d05a267dp-46,
    0x1.e400000000000p-1,
    0.0,
    0x1.ccb73cdddc000p-5,
    -0x1.a68f247d82807p-46,
    0x1.e200000000000p-1,
    0.0,
    0x1.eea31c006c000p-5,
    -0x1.e113e4fc93b7bp-47,
    0x1.de00000000000p-1,
    0.0,
    0x1.1973bd1466000p-4,
    -0x1.5325d560d9e9bp-45,
    0x1.da00000000000p-1,
    0.0,
    0x1.3bdf5a7d1e000p-4,
    0x1.cc85ea5db4ed7p-45,
    0x1.d600000000000p-1,
    0.0,
    0x1.5e95a4d97a000p-4,
    -0x1.c69063c5d1d1ep-45,
    0x1.d400000000000p-1,
    0.0,
    0x1.700d30aeac000p-4,
    0x1.c1e8da99ded32p-49,
    0x1.d000000000000p-1,
    0.0,
    0x1.9335e5d594000p-4,
    0x1.3115c3abd47dap-45,
    0x1.cc00000000000p-1,
    0.0,
    0x1.b6ac88dad6000p-4,
    -0x1.390802bf768e5p-46,
    0x1.ca00000000000p-1,
    0.0,
    0x1.c885801bc4000p-4,
    0x1.646d1c65aacd3p-45,
    0x1.c600000000000p-1,
    0.0,
    0x1.ec739830a2000p-4,
    -0x1.dc068afe645e0p-45,
    0x1.c400000000000p-1,
    0.0,
    0x1.fe89139dbe000p-4,
    -0x1.534d64fa10afdp-45,
    0x1.c000000000000p-1,
    0.0,
    0x1.1178e8227e000p-3,
    0x1.1ef78ce2d07f2p-45,
    0x1.be00000000000p-1,
    0.0,
    0x1.1aa2b7e23f000p-3,
    0x1.ca78e44389934p-45,
    0x1.ba00000000000p-1,
    0.0,
    0x1.2d1610c868000p-3,
    0x1.39d6ccb81b4a1p-47,
    0x1.b800000000000p-1,
    0.0,
    0x1.365fcb0159000p-3,
    0x1.62fa8234b7289p-51,
    0x1.b400000000000p-1,
    0.0,
    0x1.4913d8333b000p-3,
    0x1.5837954fdb678p-45,
    0x1.b200000000000p-1,
    0.0,
    0x1.527e5e4a1b000p-3,
    0x1.633e8e5697dc7p-45,
    0x1.ae00000000000p-1,
    0.0,
    0x1.6574ebe8c1000p-3,
    0x1.9cf8b2c3c2e78p-46,
    0x1.ac00000000000p-1,
    0.0,
    0x1.6f0128b757000p-3,
    -0x1.5118de59c21e1p-45,
    0x1.aa00000000000p-1,
    0.0,
    0x1.7898d85445000p-3,
    -0x1.c661070914305p-46,
    0x1.a600000000000p-1,
    0.0,
    0x1.8beafeb390000p-3,
    -0x1.73d54aae92cd1p-47,
    0x1.a400000000000p-1,
    0.0,
    0x1.95a5adcf70000p-3,
    0x1.7f22858a0ff6fp-47,
    0x1.a000000000000p-1,
    0.0,
    0x1.a93ed3c8ae000p-3,
    -0x1.8724350562169p-45,
    0x1.9e00000000000p-1,
    0.0,
    0x1.b31d8575bd000p-3,
    -0x1.c358d4eace1aap-47,
    0x1.9c00000000000p-1,
    0.0,
    0x1.bd087383be000p-3,
    -0x1.d4bc4595412b6p-45,
    0x1.9a00000000000p-1,
    0.0,
    0x1.c6ffbc6f01000p-3,
    -0x1.1ec72c5962bd2p-48,
    0x1.9600000000000p-1,
    0.0,
    0x1.db13db0d49000p-3,
    -0x1.aff2af715b035p-45,
    0x1.9400000000000p-1,
    0.0,
    0x1.e530effe71000p-3,
    0x1.212276041f430p-51,
    0x1.9200000000000p-1,
    0.0,
    0x1.ef5ade4dd0000p-3,
    -0x1.a211565bb8e11p-51,
    0x1.9000000000000p-1,
    0.0,
    0x1.f991c6cb3b000p-3,
    0x1.bcbecca0cdf30p-46,
    0x1.8c00000000000p-1,
    0.0,
    0x1.07138604d5800p-2,
    0x1.89cdb16ed4e91p-48,
    0x1.8a00000000000p-1,
    0.0,
    0x1.0c42d67616000p-2,
    0x1.7188b163ceae9p-45,
    0x1.8800000000000p-1,
    0.0,
    0x1.1178e8227e800p-2,
    -0x1.c210e63a5f01cp-45,
    0x1.8600000000000p-1,
    0.0,
    0x1.16b5ccbacf800p-2,
    0x1.b9acdf7a51681p-45,
    0x1.8400000000000p-1,
    0.0,
    0x1.1bf99635a6800p-2,
    0x1.ca6ed5147bdb7p-45,
    0x1.8200000000000p-1,
    0.0,
    0x1.214456d0eb800p-2,
    0x1.a87deba46baeap-47,
    0x1.7e00000000000p-1,
    0.0,
    0x1.2bef07cdc9000p-2,
    0x1.a9cfa4a5004f4p-45,
    0x1.7c00000000000p-1,
    0.0,
    0x1.314f1e1d36000p-2,
    -0x1.8e27ad3213cb8p-45,
    0x1.7a00000000000p-1,
    0.0,
    0x1.36b6776be1000p-2,
    0x1.16ecdb0f177c8p-46,
    0x1.7800000000000p-1,
    0.0,
    0x1.3c25277333000p-2,
    0x1.83b54b606bd5cp-46,
    0x1.7600000000000p-1,
    0.0,
    0x1.419b423d5e800p-2,
    0x1.8e436ec90e09dp-47,
    0x1.7400000000000p-1,
    0.0,
    0x1.4718dc271c800p-2,
    -0x1.f27ce0967d675p-45,
    0x1.7200000000000p-1,
    0.0,
    0x1.4c9e09e173000p-2,
    -0x1.e20891b0ad8a4p-45,
    0x1.7000000000000p-1,
    0.0,
    0x1.522ae0738a000p-2,
    0x1.ebe708164c759p-45,
    0x1.6e00000000000p-1,
    0.0,
    0x1.57bf753c8d000p-2,
    0x1.fadedee5d40efp-46,
    0x1.6c00000000000p-1,
    0.0,
    0x1.5d5bddf596000p-2,
    -0x1.a0b2a08a465dcp-47,
];

// log(x) as hi + *tail, for pow: about 68 bits.
const fn pow_log(ix: u64, tail: &mut f64) f64 {
    // x = 2^k z; where z is in range [OFF,2*OFF) and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3fe6955500000000);
    let i = ((tmp >> 52 - 7) % 128) as usize;
    let k = (tmp as i64 >> 52) as i32; // arithmetic shift
    let iz = ix.wrapping_sub(tmp & 0xfffu64 << 52);
    let z = dbl(iz);
    let kd = k as f64;
    // log(x) = k*Ln2 + log(c) + log1p(z/c-1).
    let invc = unsafe POW_TAB[4 * i];
    let logc = unsafe POW_TAB[4 * i + 2];
    let logctail = unsafe POW_TAB[4 * i + 3];
    // Note: 1/c is j/N or j/N/2 where j is an integer in [N,2N) and |z/c - 1| < 1/N, so r = z/c - 1 is
    // exactly representible.
    // Split z such that rhi, rlo and rhi*rhi are exact and not subnormal.
    let zhi = dbl(iz.wrapping_add(1u64 << 31) & ~0u64 << 32);
    let zlo = z - zhi;
    let rhi = zhi * invc - 1.0;
    let rlo = zlo * invc;
    let r = rhi + rlo;
    // k*Ln2 + log(c) + r.
    let t1 = kd * POW_LN2HI + logc;
    let t2 = t1 + r;
    let lo1 = kd * POW_LN2LO + logctail;
    let lo2 = t1 - t2 + r;
    // Evaluation is optimized assuming superscalar pipelined execution.
    let ar = POW_POLY[0] * r; // A[0] = -0.5.
    let ar2 = r * ar;
    let ar3 = r * ar2;
    // k*Ln2 + log(c) + r + A[0]*r*r.
    let arhi = POW_POLY[0] * rhi;
    let arhi2 = rhi * arhi;
    let hi = t2 + arhi2;
    let lo3 = rlo * (ar + arhi);
    let lo4 = t2 - hi + arhi2;
    // p = log1p(r) - r - A[0]*r*r.
    let p = ar3 * (POW_POLY[1] + r * POW_POLY[2] + ar2 * (POW_POLY[3] + r * POW_POLY[4] + ar2 * (POW_POLY[5] + r * POW_POLY[6])));
    let lo = lo1 + lo2 + lo3 + lo4 + p;
    let y = hi + lo;
    *tail = hi - y + lo;
    return y;
}

fn pow_special(tmp: f64, sbits0: u64, ki: u64) f64 {
    let mut sbits = sbits0;
    if (ki & 0x80000000) == 0 {
        // k > 0, the exponent of scale might have overflowed by <= 460.
        sbits = sbits.wrapping_sub(1009u64 << 52);
        let scale = dbl(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0, need special care in the subnormal range.
    sbits = sbits.wrapping_add(1022u64 << 52);
    // Note: sbits is signed scale.
    let scale = dbl(sbits);
    let mut y = scale + scale * tmp;
    if fabs(y) < 1.0 {
        // Round y to the right precision before scaling it into the subnormal range to avoid double
        // rounding that can cause 0.5+E/2 ulp error where E is the worst-case ulp error outside the
        // subnormal range. So this is only useful if the goal is better than 1 ulp worst-case error.
        let one = if y < 0.0 {
            -1.0
        } else {
            1.0
        };
        let mut lo = scale - y + scale * tmp;
        let hi = one + y;
        lo = one - hi + y + lo;
        y = hi + lo - one;
        // Fix the sign of 0.
        if y == 0.0 {
            y = dbl(sbits & 0x8000000000000000);
        }
    }
    return 0x1p-1022 * y;
}

const SIGN_BIAS: u32 = 0x800 << 7;

// exp(x + xtail), negated when `sign_bias` is SIGN_BIAS: the second half of pow.
fn pow_exp(x: f64, xtail: f64, sign_bias: u32) f64 {
    let mut abstop = top12(x) & 0x7ff;
    if abstop.wrapping_sub(top12(0x1p-54)) >= top12(512.0) - top12(0x1p-54) {
        if abstop.wrapping_sub(top12(0x1p-54)) >= 0x80000000 {
            // Avoid spurious underflow for tiny x. Note: 0 is common input.
            return if sign_bias != 0 {
                -1.0
            } else {
                1.0
            };
        }
        if abstop >= top12(1024.0) {
            // Note: inf and nan are already handled.
            if bits(x) >> 63 != 0 {
                return uflow(sign_bias);
            }
            return oflow(sign_bias);
        }
        // Large x is special cased below.
        abstop = 0;
    }
    // exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)].
    // x = ln2/N*k + r, with int k and r in [-ln2/2N, ln2/2N].
    let z = EXP_INVLN2N * x;
    // z - kd is in [-1, 1] in non-nearest rounding modes.
    let mut kd = z + EXP_SHIFT;
    let ki = bits(kd);
    kd -= EXP_SHIFT;
    let mut r = x + kd * EXP_NEGLN2HIN + kd * EXP_NEGLN2LON;
    // The code assumes 2^-200 < |xtail| < 2^-8/N.
    r += xtail;
    // 2^(k/N) ~= scale * (1 + tail).
    let idx = (2 * (ki % 128)) as usize;
    let top = ki.wrapping_add(sign_bias) << 52 - 7;
    let tail = dbl(unsafe EXP_TAB[idx]);
    // This is only a valid scale when -1023*N < k < 1024*N.
    let sbits = unsafe EXP_TAB[idx + 1].wrapping_add(top);
    // exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1).
    // Evaluation is optimized assuming superscalar pipelined execution.
    let r2 = r * r;
    // Without fma the worst case error is 0.25/N ulp larger.
    // Worst case error is less than 0.5+1.11/N+(abs poly error * 2^53) ulp.
    let tmp = tail + r + r2 * (EXP_POLY[0] + r * EXP_POLY[1]) + r2 * r2 * (EXP_POLY[2] + r * EXP_POLY[3]);
    if abstop == 0 {
        return pow_special(tmp, sbits, ki);
    }
    let scale = dbl(sbits);
    // Note: tmp == 0 or |tmp| > 2^-200 and scale > 2^-739, so there is no spurious underflow here even
    // without fma.
    return scale + scale * tmp;
}

// 0 when y is not an integer, 1 when it is odd, 2 when it is even.
const fn checkint(iy: u64) i32 {
    let e = (iy >> 52 & 0x7ff) as i32;
    if e < 0x3ff {
        return 0;
    }
    if e > 0x3ff + 52 {
        return 2;
    }
    if (iy & (1u64 << (0x3ff + 52 - e) as u64) - 1) != 0 {
        return 0;
    }
    if (iy & 1u64 << (0x3ff + 52 - e) as u64) != 0 {
        return 1;
    }
    return 2;
}

// Whether x (its bits) is zero, an infinity or a NaN.
const fn zeroinfnan(i: u64) bool {
    return (i << 1).wrapping_sub(1) >= (bits(INF) << 1) - 1;
}

/// x^y.
@export("pow")
pub fn pow(x: f64, y: f64) f64 {
    let mut sign_bias: u32 = 0;
    let mut ix = bits(x);
    let iy = bits(y);
    let mut topx = top12(x);
    let topy = top12(y);
    if topx.wrapping_sub(0x001) >= 0x7ff - 0x001 || (topy & 0x7ff).wrapping_sub(0x3be) >= 0x43e - 0x3be {
        // Note: if |y| > 1075 * ln2 * 2^53 ~= 0x1.749p62 then pow(x,y) = inf/0 and if |y| < 2^-54 / 1075
        // ~= 0x1.e7b6p-65 then pow(x,y) = +-1.
        // Special cases: (x < 0x1p-126 or inf or nan) or (|y| < 0x1p-65 or |y| >= 0x1p63 or nan).
        if zeroinfnan(iy) {
            if iy << 1 == 0 {
                return 1.0;
            }
            if ix == bits(1.0) {
                return 1.0;
            }
            if ix << 1 > bits(INF) << 1 || iy << 1 > bits(INF) << 1 {
                return x + y;
            }
            if ix << 1 == bits(1.0) << 1 {
                return 1.0;
            }
            if ix << 1 < bits(1.0) << 1 == (iy >> 63 == 0) {
                // |x|<1 && y==inf or |x|>1 && y==-inf.
                return 0.0;
            }
            // |x|>1 && y==inf or |x|<1 && y==-inf.
            return y * y;
        }
        if zeroinfnan(ix) {
            let mut x2 = x * x;
            if ix >> 63 != 0 && checkint(iy) == 1 {
                x2 = -x2;
            }
            // Without the barrier some versions of clang hoist the 1/x2 and thus division by zero
            // exception can be signaled spuriously.
            return if iy >> 63 != 0 {
                1.0 / x2
            } else {
                x2
            };
        }
        // Here x and y are non-zero finite.
        if ix >> 63 != 0 {
            // Finite x < 0.
            let yint = checkint(iy);
            if yint == 0 {
                return invalid(x);
            }
            if yint == 1 {
                sign_bias = SIGN_BIAS;
            }
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if (topy & 0x7ff).wrapping_sub(0x3be) >= 0x43e - 0x3be {
            // Note: sign_bias == 0 here because y is not odd.
            if ix == bits(1.0) {
                return 1.0;
            }
            if (topy & 0x7ff) < 0x3be {
                // |y| < 2^-65, x^y ~= 1 + y*log(x).
                return 1.0;
            }
            return if ix > bits(1.0) == topy < 0x800 {
                oflow(0)
            } else {
                uflow(0)
            };
        }
        if topx == 0 {
            // Normalize subnormal x so exponent becomes negative.
            ix = bits(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix = ix.wrapping_sub(52u64 << 52);
        }
    }
    let mut lo: f64 = 0.0;
    let hi = pow_log(ix, &mut lo);
    let yhi = dbl(iy & ~0u64 << 27);
    let ylo = y - yhi;
    let lhi = dbl(bits(hi) & ~0u64 << 27);
    let llo = hi - lhi + lo;
    let ehi = yhi * lhi;
    let elo = ylo * lhi + y * llo; // |elo| < |y| * 0x1p-25.
    return pow_exp(ehi, elo, sign_bias);
}

// ---- expf, exp2f, logf, log2f, powf ----------------------------------------------------------------------

// The data of expf, exp2f and powf: EXP2F_TAB[i] = bits(2^(i/32)) - (i << 52) / 32.
const EXP2F_TAB: [u64; 32] = [
    0x3ff0000000000000,
    0x3fefd9b0d3158574,
    0x3fefb5586cf9890f,
    0x3fef9301d0125b51,
    0x3fef72b83c7d517b,
    0x3fef54873168b9aa,
    0x3fef387a6e756238,
    0x3fef1e9df51fdee1,
    0x3fef06fe0a31b715,
    0x3feef1a7373aa9cb,
    0x3feedea64c123422,
    0x3feece086061892d,
    0x3feebfdad5362a27,
    0x3feeb42b569d4f82,
    0x3feeab07dd485429,
    0x3feea47eb03a5585,
    0x3feea09e667f3bcd,
    0x3fee9f75e8ec5f74,
    0x3feea11473eb0187,
    0x3feea589994cce13,
    0x3feeace5422aa0db,
    0x3feeb737b0cdc5e5,
    0x3feec49182a3f090,
    0x3feed503b23e255d,
    0x3feee89f995ad3ad,
    0x3feeff76f2fb5e47,
    0x3fef199bdd85529c,
    0x3fef3720dcef9069,
    0x3fef5818dcfba487,
    0x3fef7c97337b9b5f,
    0x3fefa4afa2a490da,
    0x3fefd0765b6e4540,
];
const EXP2F_SHIFT_SCALED: f64 = 0x1.8000000000000p+47;
const EXP2F_SHIFT: f64 = 0x1.8000000000000p+52;
const EXP2F_INVLN2_SCALED: f64 = 0x1.71547652b82fep+5;
const EXP2F_POLY: [f64; 3] = [0x1.c6af84b912394p-5, 0x1.ebfce50fac4f3p-3, 0x1.62e42ff0c52d6p-1];
const EXP2F_POLY_SCALED: [f64; 3] = [0x1.c6af84b912394p-20, 0x1.ebfce50fac4f3p-13, 0x1.62e42ff0c52d6p-6];

const fn top12f(x: f32) u32 {
    return bitsf(x) >> 20;
}

/// e^x.
@export("expf")
pub const fn expf(x: f32) f32 {
    let xd = x as f64;
    let abstop = top12f(x) & 0x7ff;
    if abstop >= top12f(88.0f32) {
        // |x| >= 88 or x is nan.
        if bitsf(x) == bitsf(-INFF) {
            return 0.0f32;
        }
        if abstop >= top12f(INFF) {
            return x + x;
        }
        if x > 0x1.62e42ep6f32 {
            // x > log(0x1p128) ~= 88.72
            return oflowf(0);
        }
        if x < -0x1.9fe368p6f32 {
            // x < log(0x1p-150) ~= -103.97
            return uflowf(0);
        }
    }
    // x*N/Ln2 = k + r with r in [-1/2, 1/2] and int k.
    let mut z = EXP2F_INVLN2_SCALED * xd;
    // Round and convert z to int, the result is in [-150*N, 128*N] and ideally ties-to-even rule is used,
    // otherwise the magnitude of r can be bigger which gives larger approximation error.
    let mut kd = z + EXP2F_SHIFT;
    let ki = bits(kd);
    kd -= EXP2F_SHIFT;
    let r = z - kd;
    // exp(x) = 2^(k/N) * 2^(r/N) ~= s * (C0*r^3 + C1*r^2 + C2*r + 1)
    let mut t = unsafe EXP2F_TAB[(ki % 32) as usize];
    t = t.wrapping_add(ki << 52 - 5);
    let s = dbl(t);
    z = EXP2F_POLY_SCALED[0] * r + EXP2F_POLY_SCALED[1];
    let r2 = r * r;
    let mut y = EXP2F_POLY_SCALED[2] * r + 1.0;
    y = z * r2 + y;
    y = y * s;
    return y as f32;
}

/// 2^x.
@export("exp2f")
pub const fn exp2f(x: f32) f32 {
    let xd = x as f64;
    let abstop = top12f(x) & 0x7ff;
    if abstop >= top12f(128.0f32) {
        // |x| >= 128 or x is nan.
        if bitsf(x) == bitsf(-INFF) {
            return 0.0f32;
        }
        if abstop >= top12f(INFF) {
            return x + x;
        }
        if x > 0.0f32 {
            return oflowf(0);
        }
        if x <= -150.0f32 {
            return uflowf(0);
        }
    }
    // x = k/N + r with r in [-1/(2N), 1/(2N)] and int k.
    let mut kd = xd + EXP2F_SHIFT_SCALED;
    let ki = bits(kd);
    kd -= EXP2F_SHIFT_SCALED; // k/N for int k
    let r = xd - kd;
    // exp2(x) = 2^(k/N) * 2^r ~= s * (C0*r^3 + C1*r^2 + C2*r + 1)
    let mut t = unsafe EXP2F_TAB[(ki % 32) as usize];
    t = t.wrapping_add(ki << 52 - 5);
    let s = dbl(t);
    let z = EXP2F_POLY[0] * r + EXP2F_POLY[1];
    let r2 = r * r;
    let mut y = EXP2F_POLY[2] * r + 1.0;
    y = z * r2 + y;
    y = y * s;
    return y as f32;
}

// The data of logf: LOGF_TAB holds (invc, logc) pairs, 16 of them.
const LOGF_TAB: [f64; 32] = [
    0x1.661ec79f8f3bep+0,
    -0x1.57bf7808caadep-2,
    0x1.571ed4aaf883dp+0,
    -0x1.2bef0a7c06ddbp-2,
    0x1.49539f0f010b0p+0,
    -0x1.01eae7f513a67p-2,
    0x1.3c995b0b80385p+0,
    -0x1.b31d8a68224e9p-3,
    0x1.30d190c8864a5p+0,
    -0x1.6574f0ac07758p-3,
    0x1.25e227b0b8ea0p+0,
    -0x1.1aa2bc79c8100p-3,
    0x1.1bb4a4a1a343fp+0,
    -0x1.a4e76ce8c0e5ep-4,
    0x1.12358f08ae5bap+0,
    -0x1.1973c5a611cccp-4,
    0x1.0953f419900a7p+0,
    -0x1.252f438e10c1ep-5,
    0x1.0000000000000p+0,
    0.0,
    0x1.e608cfd9a47acp-1,
    0x1.aa5aa5df25984p-5,
    0x1.ca4b31f026aa0p-1,
    0x1.c5e53aa362eb4p-4,
    0x1.b2036576afce6p-1,
    0x1.526e57720db08p-3,
    0x1.9c2d163a1aa2dp-1,
    0x1.bc2860d224770p-3,
    0x1.886e6037841edp-1,
    0x1.1058bc8a07ee1p-2,
    0x1.767dcf5534862p-1,
    0x1.4043057b6ee09p-2,
];
const LOGF_LN2: f64 = 0x1.62e42fefa39efp-1;
const LOGF_POLY: [f64; 3] = [-0x1.00ea348b88334p-2, 0x1.5575b0be00b6ap-2, -0x1.ffffef20a4123p-2];

/// The natural logarithm of x.
@export("logf")
pub const fn logf(x: f32) f32 {
    let mut ix = bitsf(x);
    if ix.wrapping_sub(0x00800000) >= 0x7f800000 - 0x00800000 {
        // x < 0x1p-126 or inf or nan.
        if ix << 1 == 0 {
            return divzerof(1);
        }
        if ix == 0x7f800000 {
            // log(inf) == inf.
            return x;
        }
        if (ix & 0x80000000) != 0 || ix << 1 >= 0xff000000 {
            return invalidf(x);
        }
        // x is subnormal, normalize it.
        ix = bitsf(x * 0x1p23f32);
        ix = ix.wrapping_sub(23 << 23);
    }
    // x = 2^k z; where z is in range [OFF,2*OFF] and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3f330000);
    let i = ((tmp >> 23 - 4) % 16) as usize;
    let k = tmp as i32 >> 23; // arithmetic shift
    let iz = ix.wrapping_sub(tmp & 0x1ff << 23);
    let invc = unsafe LOGF_TAB[2 * i];
    let logc = unsafe LOGF_TAB[2 * i + 1];
    let z = flt(iz) as f64;
    // log(x) = log1p(z/c-1) + log(c) + k*Ln2
    let r = z * invc - 1.0;
    let y0 = logc + k as f64 * LOGF_LN2;
    // Pipelined polynomial evaluation to approximate log1p(r).
    let r2 = r * r;
    let mut y = LOGF_POLY[1] * r + LOGF_POLY[2];
    y = LOGF_POLY[0] * r2 + y;
    y = y * r2 + (y0 + r);
    return y as f32;
}

// The data of log2f: LOG2F_TAB holds (invc, logc) pairs, 16 of them.
const LOG2F_TAB: [f64; 32] = [
    0x1.661ec79f8f3bep+0,
    -0x1.efec65b963019p-2,
    0x1.571ed4aaf883dp+0,
    -0x1.b0b6832d4fca4p-2,
    0x1.49539f0f010b0p+0,
    -0x1.7418b0a1fb77bp-2,
    0x1.3c995b0b80385p+0,
    -0x1.39de91a6dcf7bp-2,
    0x1.30d190c8864a5p+0,
    -0x1.01d9bf3f2b631p-2,
    0x1.25e227b0b8ea0p+0,
    -0x1.97c1d1b3b7af0p-3,
    0x1.1bb4a4a1a343fp+0,
    -0x1.2f9e393af3c9fp-3,
    0x1.12358f08ae5bap+0,
    -0x1.960cbbf788d5cp-4,
    0x1.0953f419900a7p+0,
    -0x1.a6f9db6475fcep-5,
    0x1.0000000000000p+0,
    0.0,
    0x1.e608cfd9a47acp-1,
    0x1.338ca9f24f53dp-4,
    0x1.ca4b31f026aa0p-1,
    0x1.476a9543891bap-3,
    0x1.b2036576afce6p-1,
    0x1.e840b4ac4e4d2p-3,
    0x1.9c2d163a1aa2dp-1,
    0x1.40645f0c6651cp-2,
    0x1.886e6037841edp-1,
    0x1.88e9c2c1b9ff8p-2,
    0x1.767dcf5534862p-1,
    0x1.ce0a44eb17bccp-2,
];
const LOG2F_POLY: [f64; 4] = [-0x1.712b6f70a7e4dp-2, 0x1.ecabf496832e0p-2, -0x1.715479ffae3dep-1, 0x1.715475f35c8b8p+0];

/// The base-2 logarithm of x.
@export("log2f")
pub const fn log2f(x: f32) f32 {
    let mut ix = bitsf(x);
    if ix.wrapping_sub(0x00800000) >= 0x7f800000 - 0x00800000 {
        // x < 0x1p-126 or inf or nan.
        if ix << 1 == 0 {
            return divzerof(1);
        }
        if ix == 0x7f800000 {
            // log2(inf) == inf.
            return x;
        }
        if (ix & 0x80000000) != 0 || ix << 1 >= 0xff000000 {
            return invalidf(x);
        }
        // x is subnormal, normalize it.
        ix = bitsf(x * 0x1p23f32);
        ix = ix.wrapping_sub(23 << 23);
    }
    // x = 2^k z; where z is in range [OFF,2*OFF] and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3f330000);
    let i = ((tmp >> 23 - 4) % 16) as usize;
    let top = tmp & 0xff800000;
    let iz = ix.wrapping_sub(top);
    let k = tmp as i32 >> 23; // arithmetic shift
    let invc = unsafe LOG2F_TAB[2 * i];
    let logc = unsafe LOG2F_TAB[2 * i + 1];
    let z = flt(iz) as f64;
    // log2(x) = log1p(z/c-1)/ln2 + log2(c) + k
    let r = z * invc - 1.0;
    let y0 = logc + k as f64;
    // Pipelined polynomial evaluation to approximate log1p(r)/ln2.
    let r2 = r * r;
    let mut y = LOG2F_POLY[1] * r + LOG2F_POLY[2];
    y = LOG2F_POLY[0] * r2 + y;
    let p = LOG2F_POLY[3] * r + y0;
    y = y * r2 + p;
    return y as f32;
}

// The data of powf's logarithm: POWF_TAB holds (invc, logc) pairs, 16 of them.
const POWF_TAB: [f64; 32] = [
    0x1.661ec79f8f3bep+0,
    -0x1.efec65b963019p-2,
    0x1.571ed4aaf883dp+0,
    -0x1.b0b6832d4fca4p-2,
    0x1.49539f0f010b0p+0,
    -0x1.7418b0a1fb77bp-2,
    0x1.3c995b0b80385p+0,
    -0x1.39de91a6dcf7bp-2,
    0x1.30d190c8864a5p+0,
    -0x1.01d9bf3f2b631p-2,
    0x1.25e227b0b8ea0p+0,
    -0x1.97c1d1b3b7af0p-3,
    0x1.1bb4a4a1a343fp+0,
    -0x1.2f9e393af3c9fp-3,
    0x1.12358f08ae5bap+0,
    -0x1.960cbbf788d5cp-4,
    0x1.0953f419900a7p+0,
    -0x1.a6f9db6475fcep-5,
    0x1.0000000000000p+0,
    0.0,
    0x1.e608cfd9a47acp-1,
    0x1.338ca9f24f53dp-4,
    0x1.ca4b31f026aa0p-1,
    0x1.476a9543891bap-3,
    0x1.b2036576afce6p-1,
    0x1.e840b4ac4e4d2p-3,
    0x1.9c2d163a1aa2dp-1,
    0x1.40645f0c6651cp-2,
    0x1.886e6037841edp-1,
    0x1.88e9c2c1b9ff8p-2,
    0x1.767dcf5534862p-1,
    0x1.ce0a44eb17bccp-2,
];
const POWF_POLY: [f64; 5] = [
    0x1.27616c9496e0bp-2,
    -0x1.71969a075c67ap-2,
    0x1.ec70a6ca7baddp-2,
    -0x1.7154748bef6c8p-1,
    0x1.71547652ab82bp+0,
];

// log2(x), x a normal positive float given by its bits, to about 1.27 ulp of a double.
const fn powf_log2(ix: u32) f64 {
    // x = 2^k z; where z is in range [OFF,2*OFF] and exact.
    // The range is split into N subintervals.
    // The ith subinterval contains z and c is near its center.
    let tmp = ix.wrapping_sub(0x3f330000);
    let i = ((tmp >> 23 - 4) % 16) as usize;
    let top = tmp & 0xff800000;
    let iz = ix.wrapping_sub(top);
    let k = top as i32 >> 23; // arithmetic shift
    let invc = unsafe POWF_TAB[2 * i];
    let logc = unsafe POWF_TAB[2 * i + 1];
    let z = flt(iz) as f64;
    // log2(x) = log1p(z/c-1)/ln2 + log2(c) + k
    let r = z * invc - 1.0;
    let y0 = logc + k as f64;
    // Pipelined polynomial evaluation to approximate log1p(r)/ln2.
    let r2 = r * r;
    let mut y = POWF_POLY[0] * r + POWF_POLY[1];
    let p = POWF_POLY[2] * r + POWF_POLY[3];
    let r4 = r2 * r2;
    let mut q = POWF_POLY[4] * r + y0;
    q = p * r2 + q;
    y = y * r4 + q;
    return y;
}

const SIGN_BIASF: u32 = 1 << 5 + 11;

// 2^xd, negated when `sign_bias` is SIGN_BIASF: the second half of powf.
const fn powf_exp2(xd: f64, sign_bias: u32) f32 {
    // x = k/N + r with r in [-1/(2N), 1/(2N)]
    let mut kd = xd + EXP2F_SHIFT_SCALED;
    let ki = bits(kd);
    kd -= EXP2F_SHIFT_SCALED; // k/N
    let r = xd - kd;
    // exp2(x) = 2^(k/N) * 2^r ~= s * (C0*r^3 + C1*r^2 + C2*r + 1)
    let mut t = unsafe EXP2F_TAB[(ki % 32) as usize];
    let ski = ki.wrapping_add(sign_bias);
    t = t.wrapping_add(ski << 52 - 5);
    let s = dbl(t);
    let z = EXP2F_POLY[0] * r + EXP2F_POLY[1];
    let r2 = r * r;
    let mut y = EXP2F_POLY[2] * r + 1.0;
    y = z * r2 + y;
    y = y * s;
    return y as f32;
}

// 0 when y is not an integer, 1 when it is odd, 2 when it is even.
const fn checkintf(iy: u32) i32 {
    let e = (iy >> 23 & 0xff) as i32;
    if e < 0x7f {
        return 0;
    }
    if e > 0x7f + 23 {
        return 2;
    }
    if (iy & (1u32 << (0x7f + 23 - e) as u32) - 1) != 0 {
        return 0;
    }
    if (iy & 1u32 << (0x7f + 23 - e) as u32) != 0 {
        return 1;
    }
    return 2;
}

// Whether x (its bits) is zero, an infinity or a NaN.
const fn zeroinfnanf(ix: u32) bool {
    return (ix << 1).wrapping_sub(1) >= (0x7f800000u32 << 1) - 1;
}

/// x^y.
@export("powf")
pub const fn powf(x: f32, y: f32) f32 {
    let mut sign_bias: u32 = 0;
    let mut ix = bitsf(x);
    let iy = bitsf(y);
    if ix.wrapping_sub(0x00800000) >= 0x7f800000 - 0x00800000 || zeroinfnanf(iy) {
        // Either (x < 0x1p-126 or inf or nan) or (y is 0 or inf or nan).
        if zeroinfnanf(iy) {
            if iy << 1 == 0 {
                return 1.0f32;
            }
            if ix == 0x3f800000 {
                return 1.0f32;
            }
            if ix << 1 > 0x7f800000u32 << 1 || iy << 1 > 0x7f800000u32 << 1 {
                return x + y;
            }
            if ix << 1 == 0x3f800000u32 << 1 {
                return 1.0f32;
            }
            if ix << 1 < 0x3f800000u32 << 1 == ((iy & 0x80000000) == 0) {
                // |x|<1 && y==inf or |x|>1 && y==-inf.
                return 0.0f32;
            }
            // |x|>1 && y==inf or |x|<1 && y==-inf.
            return y * y;
        }
        if zeroinfnanf(ix) {
            let mut x2 = x * x;
            if (ix & 0x80000000) != 0 && checkintf(iy) == 1 {
                x2 = -x2;
            }
            // Without the barrier some versions of clang hoist the 1/x2 and thus division by zero
            // exception can be signaled spuriously.
            return if (iy & 0x80000000) != 0 {
                1.0f32 / x2
            } else {
                x2
            };
        }
        // x and y are non-zero finite.
        if (ix & 0x80000000) != 0 {
            // Finite x < 0.
            let yint = checkintf(iy);
            if yint == 0 {
                return invalidf(x);
            }
            if yint == 1 {
                sign_bias = SIGN_BIASF;
            }
            ix &= 0x7fffffff;
        }
        if ix < 0x00800000 {
            // Normalize subnormal x so exponent becomes negative.
            ix = bitsf(x * 0x1p23f32);
            ix &= 0x7fffffff;
            ix = ix.wrapping_sub(23 << 23);
        }
    }
    let logx = powf_log2(ix);
    let ylogx = y as f64 * logx; // Note: cannot overflow, y is single prec.
    if (bits(ylogx) >> 47 & 0xffff) >= bits(126.0) >> 47 {
        // |y*log(x)| >= 126.
        if ylogx > 0x1.fffffffd1d571p+6 {
            // |x^y| > 0x1.ffffffp127.
            return oflowf(sign_bias);
        }
        if ylogx <= -150.0 {
            return uflowf(sign_bias);
        }
    }
    return powf_exp2(ylogx, sign_bias);
}

// ---- asin, acos, atan, atan2 -----------------------------------------------------------------------------

const PIO2_HI: f64 = 1.57079632679489655800e+00;
const PIO2_LO: f64 = 6.12323399573676603587e-17;
const PS0: f64 = 1.66666666666666657415e-01;
const PS1: f64 = -3.25565818622400915405e-01;
const PS2: f64 = 2.01212532134862925881e-01;
const PS3: f64 = -4.00555345006794114027e-02;
const PS4: f64 = 7.91534994289814532176e-04;
const PS5: f64 = 3.47933107596021167570e-05;
const QS1: f64 = -2.40339491173441421878e+00;
const QS2: f64 = 2.02094576023350569471e+00;
const QS3: f64 = -6.88283971605453293030e-01;
const QS4: f64 = 7.70381505559019352791e-02;

// (asin(sqrt(z)) - sqrt(z)) / sqrt(z)^3, a rational approximation.
const fn asin_r(z: f64) f64 {
    let p = z * (PS0 + z * (PS1 + z * (PS2 + z * (PS3 + z * (PS4 + z * PS5)))));
    let q = 1.0 + z * (QS1 + z * (QS2 + z * (QS3 + z * QS4)));
    return p / q;
}

/// The arcsine of x, in [-pi/2, pi/2].
@export("asin")
pub fn asin(x0: f64) f64 {
    let mut x = x0;
    let hx = hi(x);
    let ix = hx & 0x7fffffff;
    // |x| >= 1 or nan
    if ix >= 0x3ff00000 {
        let lx = lo(x);
        if (ix - 0x3ff00000 | lx) == 0 {
            // asin(1) = +-pi/2 with inexact
            return x * PIO2_HI + 0x1p-120;
        }
        return 0.0 / (x - x);
    }
    // |x| < 0.5
    if ix < 0x3fe00000 {
        // if 0x1p-1022 <= |x| < 0x1p-26, avoid raising underflow
        if ix < 0x3e500000 && ix >= 0x00100000 {
            return x;
        }
        return x + x * asin_r(x * x);
    }
    // 1 > |x| >= 0.5
    let z = (1.0 - fabs(x)) * 0.5;
    let s = sqrt(z);
    let r = asin_r(z);
    if ix >= 0x3fef3333 {
        // if |x| > 0.975
        x = PIO2_HI - (2.0 * (s + s * r) - PIO2_LO);
    } else {
        // f+c = sqrt(z)
        let f = words(hi(s), 0);
        let c = (z - f * f) / (s + f);
        x = 0.5 * PIO2_HI - (2.0 * s * r - (PIO2_LO - 2.0 * c) - (0.5 * PIO2_HI - 2.0 * f));
    }
    if hx >> 31 != 0 {
        return -x;
    }
    return x;
}

/// The arccosine of x, in [0, pi].
@export("acos")
pub fn acos(x: f64) f64 {
    let hx = hi(x);
    let ix = hx & 0x7fffffff;
    // |x| >= 1 or nan
    if ix >= 0x3ff00000 {
        let lx = lo(x);
        if (ix - 0x3ff00000 | lx) == 0 {
            // acos(1)=0, acos(-1)=pi
            if hx >> 31 != 0 {
                return 2.0 * PIO2_HI + 0x1p-120;
            }
            return 0.0;
        }
        return 0.0 / (x - x);
    }
    // |x| < 0.5
    if ix < 0x3fe00000 {
        if ix <= 0x3c600000 {
            // |x| < 2**-57
            return PIO2_HI + 0x1p-120;
        }
        return PIO2_HI - (x - (PIO2_LO - x * asin_r(x * x)));
    }
    // x < -0.5
    if hx >> 31 != 0 {
        let z = (1.0 + x) * 0.5;
        let s = sqrt(z);
        let w = asin_r(z) * s - PIO2_LO;
        return 2.0 * (PIO2_HI - (s + w));
    }
    // x > 0.5
    let z = (1.0 - x) * 0.5;
    let s = sqrt(z);
    let df = words(hi(s), 0);
    let c = (z - df * df) / (s + df);
    let w = asin_r(z) * s + c;
    return 2.0 * (df + w);
}

const PS0F: f32 = 1.6666586697e-01f32;
const PS1F: f32 = -4.2743422091e-02f32;
const PS2F: f32 = -8.6563630030e-03f32;
const QS1F: f32 = -7.0662963390e-01f32;

const fn asinf_r(z: f32) f32 {
    let p = z * (PS0F + z * (PS1F + z * PS2F));
    let q = 1.0f32 + z * QS1F;
    return p / q;
}

/// The arcsine of x, in [-pi/2, pi/2].
@export("asinf")
pub fn asinf(x: f32) f32 {
    let pio2: f64 = 1.570796326794896558e+00;
    let hx = bitsf(x);
    let ix = hx & 0x7fffffff;
    if ix >= 0x3f800000 {
        // |x| >= 1
        if ix == 0x3f800000 {
            // |x| == 1
            return (x as f64 * pio2 + 0x1p-120) as f32; // asin(+-1) = +-pi/2 with inexact
        }
        return 0.0f32 / (x - x); // asin(|x|>1) is NaN
    }
    if ix < 0x3f000000 {
        // |x| < 0.5
        // if 0x1p-126 <= |x| < 0x1p-12, avoid raising underflow
        if ix < 0x39800000 && ix >= 0x00800000 {
            return x;
        }
        return x + x * asinf_r(x * x);
    }
    // 1 > |x| >= 0.5
    let z = (1.0f32 - fabsf(x)) * 0.5f32;
    let s = sqrt(z);
    let r = (pio2 - 2.0 * (s + s * asinf_r(z) as f64)) as f32;
    if hx >> 31 != 0 {
        return -r;
    }
    return r;
}

const PIO2F_HI: f32 = 1.5707962513e+00f32;
const PIO2F_LO: f32 = 7.5497894159e-08f32;

/// The arccosine of x, in [0, pi].
@export("acosf")
pub fn acosf(x: f32) f32 {
    let hx = bitsf(x);
    let ix = hx & 0x7fffffff;
    // |x| >= 1 or nan
    if ix >= 0x3f800000 {
        if ix == 0x3f800000 {
            if hx >> 31 != 0 {
                return 2.0f32 * PIO2F_HI + 0x1p-120f32;
            }
            return 0.0f32;
        }
        return 0.0f32 / (x - x);
    }
    // |x| < 0.5
    if ix < 0x3f000000 {
        if ix <= 0x32800000 {
            // |x| < 2**-26
            return PIO2F_HI + 0x1p-120f32;
        }
        return PIO2F_HI - (x - (PIO2F_LO - x * asinf_r(x * x)));
    }
    // x < -0.5
    if hx >> 31 != 0 {
        let z = (1.0f32 + x) * 0.5f32;
        let s = sqrtf(z);
        let w = asinf_r(z) * s - PIO2F_LO;
        return 2.0f32 * (PIO2F_HI - (s + w));
    }
    // x > 0.5
    let z = (1.0f32 - x) * 0.5f32;
    let s = sqrtf(z);
    let df = flt(bitsf(s) & 0xfffff000);
    let c = (z - df * df) / (s + df);
    let w = asinf_r(z) * s + c;
    return 2.0f32 * (df + w);
}

const ATANHI: [f64; 4] = [
    4.63647609000806093515e-01, // atan(0.5)hi
    7.85398163397448278999e-01, // atan(1.0)hi
    9.82793723247329054082e-01, // atan(1.5)hi
    1.57079632679489655800e+00, // atan(inf)hi
];
const ATANLO: [f64; 4] = [
    2.26987774529616870924e-17, // atan(0.5)lo
    3.06161699786838301793e-17, // atan(1.0)lo
    1.39033110312309984516e-17, // atan(1.5)lo
    6.12323399573676603587e-17, // atan(inf)lo
];
const AT: [f64; 11] = [
    3.33333333333329318027e-01,
    -1.99999999998764832476e-01,
    1.42857142725034663711e-01,
    -1.11111104054623557880e-01,
    9.09088713343650656196e-02,
    -7.69187620504482999495e-02,
    6.66107313738753120669e-02,
    -5.83357013379057348645e-02,
    4.97687799461593236017e-02,
    -3.65315727442169155270e-02,
    1.62858201153657823623e-02,
];

/// The arctangent of x, in [-pi/2, pi/2].
@export("atan")
pub fn atan(x0: f64) f64 {
    let mut x = x0;
    let mut ix = hi(x);
    let sign = ix >> 31;
    ix &= 0x7fffffff;
    if ix >= 0x44100000 {
        // if |x| >= 2^66
        if isnan(x) {
            return x;
        }
        let z = ATANHI[3] + 0x1p-120;
        return if sign != 0 {
            -z
        } else {
            z
        };
    }
    let mut id: i32 = -1;
    if ix < 0x3fdc0000 {
        // |x| < 0.4375
        if ix < 0x3e400000 {
            // |x| < 2^-27
            return x;
        }
    } else {
        x = fabs(x);
        if ix < 0x3ff30000 {
            // |x| < 1.1875
            if ix < 0x3fe60000 {
                // 7/16 <= |x| < 11/16
                id = 0;
                x = (2.0 * x - 1.0) / (2.0 + x);
            } else {
                // 11/16 <= |x| < 19/16
                id = 1;
                x = (x - 1.0) / (x + 1.0);
            }
        } else if ix < 0x40038000 {
            // |x| < 2.4375
            id = 2;
            x = (x - 1.5) / (1.0 + 1.5 * x);
        } else {
            // 2.4375 <= |x| < 2^66
            id = 3;
            x = -1.0 / x;
        }
    }
    // end of argument reduction
    let mut z = x * x;
    let w = z * z;
    // break sum from i=0 to 10 aT[i]z**(i+1) into odd and even poly
    let s1 = z * (AT[0] + w * (AT[2] + w * (AT[4] + w * (AT[6] + w * (AT[8] + w * AT[10])))));
    let s2 = w * (AT[1] + w * (AT[3] + w * (AT[5] + w * (AT[7] + w * AT[9]))));
    if id < 0 {
        return x - x * (s1 + s2);
    }
    z = unsafe ATANHI[id as usize] - (x * (s1 + s2) - unsafe ATANLO[id as usize] - x);
    return if sign != 0 {
        -z
    } else {
        z
    };
}

const PI: f64 = 3.1415926535897931160E+00;
const PI_LO: f64 = 1.2246467991473531772E-16;

/// The angle of the point (x, y), in [-pi, pi].
@export("atan2")
pub fn atan2(y: f64, x: f64) f64 {
    if isnan(x) || isnan(y) {
        return x + y;
    }
    let mut ix = hi(x);
    let lx = lo(x);
    let mut iy = hi(y);
    let ly = lo(y);
    if (ix.wrapping_sub(0x3ff00000) | lx) == 0 {
        // x = 1.0
        return atan(y);
    }
    let m = iy >> 31 & 1 | ix >> 30 & 2; // 2*sign(x)+sign(y)
    ix = ix & 0x7fffffff;
    iy = iy & 0x7fffffff;
    // when y = 0
    if (iy | ly) == 0 {
        if m <= 1 {
            return y; // atan(+-0,+anything)=+-0
        }
        if m == 2 {
            return PI; // atan(+0,-anything) = pi
        }
        return -PI; // atan(-0,-anything) =-pi
    }
    // when x = 0
    if (ix | lx) == 0 {
        return if (m & 1) != 0 {
            -PI / 2.0
        } else {
            PI / 2.0
        };
    }
    // when x is INF
    if ix == 0x7ff00000 {
        if iy == 0x7ff00000 {
            if m == 0 {
                return PI / 4.0; // atan(+INF,+INF)
            }
            if m == 1 {
                return -PI / 4.0; // atan(-INF,+INF)
            }
            if m == 2 {
                return 3.0 * PI / 4.0; // atan(+INF,-INF)
            }
            return -3.0 * PI / 4.0; // atan(-INF,-INF)
        }
        if m == 0 {
            return 0.0; // atan(+...,+INF)
        }
        if m == 1 {
            return -0.0; // atan(-...,+INF)
        }
        if m == 2 {
            return PI; // atan(+...,-INF)
        }
        return -PI; // atan(-...,-INF)
    }
    // |y/x| > 0x1p64
    if ix + (64 << 20) < iy || iy == 0x7ff00000 {
        return if (m & 1) != 0 {
            -PI / 2.0
        } else {
            PI / 2.0
        };
    }
    // z = atan(|y/x|) without spurious underflow
    let z = if (m & 2) != 0 && iy + (64 << 20) < ix {
        // |y/x| < 0x1p-64, x<0
        0.0
    } else {
        atan(fabs(y / x))
    };
    if m == 0 {
        return z; // atan(+,+)
    }
    if m == 1 {
        return -z; // atan(-,+)
    }
    if m == 2 {
        return PI - (z - PI_LO); // atan(+,-)
    }
    return z - PI_LO - PI; // atan(-,-)
}

const ATANHIF: [f32; 4] = [4.6364760399e-01f32, 7.8539812565e-01f32, 9.8279368877e-01f32, 1.5707962513e+00f32];
const ATANLOF: [f32; 4] = [5.0121582440e-09f32, 3.7748947079e-08f32, 3.4473217170e-08f32, 7.5497894159e-08f32];
const ATF: [f32; 5] = [
    3.3333328366e-01f32,
    -1.9999158382e-01f32,
    1.4253635705e-01f32,
    -1.0648017377e-01f32,
    6.1687607318e-02f32,
];

/// The arctangent of x, in [-pi/2, pi/2].
@export("atanf")
pub fn atanf(x0: f32) f32 {
    let mut x = x0;
    let mut ix = bitsf(x);
    let sign = ix >> 31;
    ix &= 0x7fffffff;
    if ix >= 0x4c800000 {
        // if |x| >= 2**26
        if isnanf(x) {
            return x;
        }
        let z = ATANHIF[3] + 0x1p-120f32;
        return if sign != 0 {
            -z
        } else {
            z
        };
    }
    let mut id: i32 = -1;
    if ix < 0x3ee00000 {
        // |x| < 0.4375
        if ix < 0x39800000 {
            // |x| < 2**-12
            return x;
        }
    } else {
        x = fabsf(x);
        if ix < 0x3f980000 {
            // |x| < 1.1875
            if ix < 0x3f300000 {
                // 7/16 <= |x| < 11/16
                id = 0;
                x = (2.0f32 * x - 1.0f32) / (2.0f32 + x);
            } else {
                // 11/16 <= |x| < 19/16
                id = 1;
                x = (x - 1.0f32) / (x + 1.0f32);
            }
        } else if ix < 0x401c0000 {
            // |x| < 2.4375
            id = 2;
            x = (x - 1.5f32) / (1.0f32 + 1.5f32 * x);
        } else {
            // 2.4375 <= |x| < 2**26
            id = 3;
            x = -1.0f32 / x;
        }
    }
    // end of argument reduction
    let mut z = x * x;
    let w = z * z;
    // break sum from i=0 to 10 aT[i]z**(i+1) into odd and even poly
    let s1 = z * (ATF[0] + w * (ATF[2] + w * ATF[4]));
    let s2 = w * (ATF[1] + w * ATF[3]);
    if id < 0 {
        return x - x * (s1 + s2);
    }
    z = unsafe ATANHIF[id as usize] - (x * (s1 + s2) - unsafe ATANLOF[id as usize] - x);
    return if sign != 0 {
        -z
    } else {
        z
    };
}

const PIF: f32 = 3.1415927410e+00f32;
const PIF_LO: f32 = -8.7422776573e-08f32;

/// The angle of the point (x, y), in [-pi, pi].
@export("atan2f")
pub fn atan2f(y: f32, x: f32) f32 {
    if isnanf(x) || isnanf(y) {
        return x + y;
    }
    let mut ix = bitsf(x);
    let mut iy = bitsf(y);
    if ix == 0x3f800000 {
        // x=1.0
        return atanf(y);
    }
    let m = iy >> 31 & 1 | ix >> 30 & 2; // 2*sign(x)+sign(y)
    ix &= 0x7fffffff;
    iy &= 0x7fffffff;
    // when y = 0
    if iy == 0 {
        if m <= 1 {
            return y; // atan(+-0,+anything)=+-0
        }
        if m == 2 {
            return PIF; // atan(+0,-anything) = pi
        }
        return -PIF; // atan(-0,-anything) =-pi
    }
    // when x = 0
    if ix == 0 {
        return if (m & 1) != 0 {
            -PIF / 2.0f32
        } else {
            PIF / 2.0f32
        };
    }
    // when x is INF
    if ix == 0x7f800000 {
        if iy == 0x7f800000 {
            if m == 0 {
                return PIF / 4.0f32; // atan(+INF,+INF)
            }
            if m == 1 {
                return -PIF / 4.0f32; // atan(-INF,+INF)
            }
            if m == 2 {
                return 3.0f32 * PIF / 4.0f32; // atan(+INF,-INF)
            }
            return -3.0f32 * PIF / 4.0f32; // atan(-INF,-INF)
        }
        if m == 0 {
            return 0.0f32; // atan(+...,+INF)
        }
        if m == 1 {
            return -0.0f32; // atan(-...,+INF)
        }
        if m == 2 {
            return PIF; // atan(+...,-INF)
        }
        return -PIF; // atan(-...,-INF)
    }
    // |y/x| > 0x1p26
    if ix + (26 << 23) < iy || iy == 0x7f800000 {
        return if (m & 1) != 0 {
            -PIF / 2.0f32
        } else {
            PIF / 2.0f32
        };
    }
    // z = atan(|y/x|) with correct underflow
    let z = if (m & 2) != 0 && iy + (26 << 23) < ix {
        // |y/x| < 0x1p-26, x < 0
        0.0f32
    } else {
        atanf(fabsf(y / x))
    };
    if m == 0 {
        return z; // atan(+,+)
    }
    if m == 1 {
        return -z; // atan(-,+)
    }
    if m == 2 {
        return PIF - (z - PIF_LO); // atan(+,-)
    }
    return z - PIF_LO - PIF; // atan(-,-)
}

// ---- expm1, log1p, log10 ---------------------------------------------------------------------------------

const O_THRESHOLD: f64 = 7.09782712893383973096e+02;
const LN2_HI: f64 = 6.93147180369123816490e-01;
const LN2_LO: f64 = 1.90821492927058770002e-10;
const INVLN2: f64 = 1.44269504088896338700e+00;
// Scaled coefficients related to expm1.
const EQ1: f64 = -3.33333333333331316428e-02;
const EQ2: f64 = 1.58730158725481460165e-03;
const EQ3: f64 = -7.93650757867487942473e-05;
const EQ4: f64 = 4.00821782732936239552e-06;
const EQ5: f64 = -2.01099218183624371326e-07;

/// e^x - 1, accurate for x near 0.
@export("expm1")
pub const fn expm1(x0: f64) f64 {
    let mut x = x0;
    let hx = (bits(x) >> 32 & 0x7fffffff) as u32;
    let sign = bits(x) >> 63 != 0;
    // filter out huge and non-finite argument
    if hx >= 0x4043687A {
        // if |x|>=56*ln2
        if isnan(x) {
            return x;
        }
        if sign {
            return -1.0;
        }
        if x > O_THRESHOLD {
            x *= 0x1p1023;
            return x;
        }
    }
    let mut k: i32 = 0;
    let mut c: f64 = 0.0;
    // argument reduction
    if hx > 0x3fd62e42 {
        // if |x| > 0.5 ln2
        let mut hi_: f64 = 0.0;
        let mut lo_: f64 = 0.0;
        if hx < 0x3FF0A2B2 {
            // and |x| < 1.5 ln2
            if !sign {
                hi_ = x - LN2_HI;
                lo_ = LN2_LO;
                k = 1;
            } else {
                hi_ = x + LN2_HI;
                lo_ = -LN2_LO;
                k = -1;
            }
        } else {
            k = (INVLN2 * x + if sign {
                -0.5
            } else {
                0.5
            }) as i32;
            let t = k as f64;
            hi_ = x - t * LN2_HI; // t*ln2_hi is exact here
            lo_ = t * LN2_LO;
        }
        x = hi_ - lo_;
        c = hi_ - x - lo_;
    } else if hx < 0x3c900000 {
        // |x| < 2**-54, return x
        return x;
    }
    // x is now in primary range
    let hfx = 0.5 * x;
    let hxs = x * hfx;
    let r1 = 1.0 + hxs * (EQ1 + hxs * (EQ2 + hxs * (EQ3 + hxs * (EQ4 + hxs * EQ5))));
    let t = 3.0 - r1 * hfx;
    let mut e = hxs * ((r1 - t) / (6.0 - x * t));
    if k == 0 {
        // c is 0
        return x - (x * e - hxs);
    }
    e = x * (e - c) - c;
    e -= hxs;
    // exp(x) ~ 2^k (Xreduced - e + 1)
    if k == -1 {
        return 0.5 * (x - e) - 0.5;
    }
    if k == 1 {
        if x < -0.25 {
            return -2.0 * (e - (x + 0.5));
        }
        return 1.0 + 2.0 * (x - e);
    }
    let twopk = dbl((0x3ff + k) as u64 << 52); // 2^k
    if k < 0 || k > 56 {
        // suffice to return exp(x)-1
        let mut y = x - e + 1.0;
        if k == 1024 {
            y = y * 2.0 * 0x1p1023;
        } else {
            y = y * twopk;
        }
        return y - 1.0;
    }
    let u = dbl((0x3ff - k) as u64 << 52); // 2^-k
    if k < 20 {
        return (x - e + (1.0 - u)) * twopk;
    }
    return (x - (e + u) + 1.0) * twopk;
}

const LN2F_HI: f32 = 6.9313812256e-01f32;
const LN2F_LO: f32 = 9.0580006145e-06f32;
const INVLN2F: f32 = 1.4426950216e+00f32;
// Domain [-0.34568, 0.34568], range ~[-6.694e-10, 6.696e-10]: |6 / x * (1 + 2 * (1 / (exp(x) - 1) - 1 /
// x)) - q(x)| < 2**-30.04.
const EQ1F: f32 = -3.3333212137e-2f32; // -0x888868.0p-28
const EQ2F: f32 = 1.5807170421e-3f32; //  0xcf3010.0p-33

/// e^x - 1, accurate for x near 0.
@export("expm1f")
pub const fn expm1f(x0: f32) f32 {
    let mut x = x0;
    let hx = bitsf(x) & 0x7fffffff;
    let sign = bitsf(x) >> 31 != 0;
    // filter out huge and non-finite argument
    if hx >= 0x4195b844 {
        // if |x|>=27*ln2
        if hx > 0x7f800000 {
            // NaN
            return x;
        }
        if sign {
            return -1.0f32;
        }
        if hx > 0x42b17217 {
            // x > log(FLT_MAX)
            x *= 0x1p127f32;
            return x;
        }
    }
    let mut k: i32 = 0;
    let mut c: f32 = 0.0f32;
    // argument reduction
    if hx > 0x3eb17218 {
        // if |x| > 0.5 ln2
        let mut hi_: f32 = 0.0f32;
        let mut lo_: f32 = 0.0f32;
        if hx < 0x3F851592 {
            // and |x| < 1.5 ln2
            if !sign {
                hi_ = x - LN2F_HI;
                lo_ = LN2F_LO;
                k = 1;
            } else {
                hi_ = x + LN2F_HI;
                lo_ = -LN2F_LO;
                k = -1;
            }
        } else {
            k = (INVLN2F * x + if sign {
                -0.5f32
            } else {
                0.5f32
            }) as i32;
            let t = k as f32;
            hi_ = x - t * LN2F_HI; // t*ln2_hi is exact here
            lo_ = t * LN2F_LO;
        }
        x = hi_ - lo_;
        c = hi_ - x - lo_;
    } else if hx < 0x33000000 {
        // when |x|<2**-25, return x
        return x;
    }
    // x is now in primary range
    let hfx = 0.5f32 * x;
    let hxs = x * hfx;
    let r1 = 1.0f32 + hxs * (EQ1F + hxs * EQ2F);
    let t = 3.0f32 - r1 * hfx;
    let mut e = hxs * ((r1 - t) / (6.0f32 - x * t));
    if k == 0 {
        // c is 0
        return x - (x * e - hxs);
    }
    e = x * (e - c) - c;
    e -= hxs;
    // exp(x) ~ 2^k (Xreduced - e + 1)
    if k == -1 {
        return 0.5f32 * (x - e) - 0.5f32;
    }
    if k == 1 {
        if x < -0.25f32 {
            return -2.0f32 * (e - (x + 0.5f32));
        }
        return 1.0f32 + 2.0f32 * (x - e);
    }
    let twopk = flt((0x7f + k) as u32 << 23); // 2^k
    if k < 0 || k > 56 {
        // suffice to return exp(x)-1
        let mut y = x - e + 1.0f32;
        if k == 128 {
            y = y * 2.0f32 * 0x1p127f32;
        } else {
            y = y * twopk;
        }
        return y - 1.0f32;
    }
    let u = flt((0x7f - k) as u32 << 23); // 2^-k
    if k < 23 {
        return (x - e + (1.0f32 - u)) * twopk;
    }
    return (x - (e + u) + 1.0f32) * twopk;
}

const LG1: f64 = 6.666666666666735130e-01;
const LG2: f64 = 3.999999999940941908e-01;
const LG3: f64 = 2.857142874366239149e-01;
const LG4: f64 = 2.222219843214978396e-01;
const LG5: f64 = 1.818357216161805012e-01;
const LG6: f64 = 1.531383769920937332e-01;
const LG7: f64 = 1.479819860511658591e-01;

/// log(1 + x), accurate for x near 0.
@export("log1p")
pub const fn log1p(x: f64) f64 {
    let hx = hi(x);
    let mut k: i32 = 1;
    let mut c: f64 = 0.0;
    let mut f: f64 = 0.0;
    if hx < 0x3fda827a || hx >> 31 != 0 {
        // 1+x < sqrt(2)+
        if hx >= 0xbff00000 {
            // x <= -1.0
            if x == -1.0 {
                return x / 0.0; // log1p(-1) = -inf
            }
            return (x - x) / 0.0; // log1p(x<-1) = NaN
        }
        if hx << 1 < 0x3ca00000u32 << 1 {
            // |x| < 2**-53
            return x;
        }
        if hx <= 0xbfd2bec4 {
            // sqrt(2)/2- <= 1+x < sqrt(2)+
            k = 0;
            c = 0.0;
            f = x;
        }
    } else if hx >= 0x7ff00000 {
        return x;
    }
    if k != 0 {
        let uf = 1.0 + x;
        let mut hu = hi(uf);
        hu += 0x3ff00000 - 0x3fe6a09e;
        k = (hu >> 20) as i32 - 0x3ff;
        // correction term ~ log(1+x)-log(u), avoid underflow in c/u
        if k < 54 {
            c = if k >= 2 {
                1.0 - (uf - x)
            } else {
                x - (uf - 1.0)
            };
            c /= uf;
        } else {
            c = 0.0;
        }
        // reduce u into [sqrt(2)/2, sqrt(2)]
        hu = (hu & 0x000fffff) + 0x3fe6a09e;
        f = words(hu, lo(uf)) - 1.0;
    }
    let hfsq = 0.5 * f * f;
    let s = f / (2.0 + f);
    let z = s * s;
    let w = z * z;
    let t1 = w * (LG2 + w * (LG4 + w * LG6));
    let t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
    let r = t2 + t1;
    let dk = k as f64;
    return s * (hfsq + r) + (dk * LN2_LO + c) - hfsq + f + dk * LN2_HI;
}

// |(log(1+s)-log(1-s))/s - Lg(s)| < 2**-34.24 (~[-4.95e-11, 4.97e-11]).
const LG1F: f32 = 0xaaaaaa.0p-24f32; // 0.66666662693
const LG2F: f32 = 0xccce13.0p-25f32; // 0.40000972152
const LG3F: f32 = 0x91e9ee.0p-25f32; // 0.28498786688
const LG4F: f32 = 0xf89e26.0p-26f32; // 0.24279078841

/// log(1 + x), accurate for x near 0.
@export("log1pf")
pub const fn log1pf(x: f32) f32 {
    let ix = bitsf(x);
    let mut k: i32 = 1;
    let mut c: f32 = 0.0f32;
    let mut f: f32 = 0.0f32;
    if ix < 0x3ed413d0 || ix >> 31 != 0 {
        // 1+x < sqrt(2)+
        if ix >= 0xbf800000 {
            // x <= -1.0
            if x == -1.0f32 {
                return x / 0.0f32; // log1p(-1)=+inf
            }
            return (x - x) / 0.0f32; // log1p(x<-1)=NaN
        }
        if ix << 1 < 0x33800000u32 << 1 {
            // |x| < 2**-24
            return x;
        }
        if ix <= 0xbe95f619 {
            // sqrt(2)/2- <= 1+x < sqrt(2)+
            k = 0;
            c = 0.0f32;
            f = x;
        }
    } else if ix >= 0x7f800000 {
        return x;
    }
    if k != 0 {
        let uf = 1.0f32 + x;
        let mut iu = bitsf(uf);
        iu += 0x3f800000 - 0x3f3504f3;
        k = (iu >> 23) as i32 - 0x7f;
        // correction term ~ log(1+x)-log(u), avoid underflow in c/u
        if k < 25 {
            c = if k >= 2 {
                1.0f32 - (uf - x)
            } else {
                x - (uf - 1.0f32)
            };
            c /= uf;
        } else {
            c = 0.0f32;
        }
        // reduce u into [sqrt(2)/2, sqrt(2)]
        iu = (iu & 0x007fffff) + 0x3f3504f3;
        f = flt(iu) - 1.0f32;
    }
    let s = f / (2.0f32 + f);
    let z = s * s;
    let w = z * z;
    let t1 = w * (LG2F + w * LG4F);
    let t2 = z * (LG1F + w * LG3F);
    let r = t2 + t1;
    let hfsq = 0.5f32 * f * f;
    let dk = k as f32;
    return s * (hfsq + r) + (dk * LN2F_LO + c) - hfsq + f + dk * LN2F_HI;
}

const IVLN10HI: f64 = 4.34294481878168880939e-01;
const IVLN10LO: f64 = 2.50829467116452752298e-11;
const LOG10_2HI: f64 = 3.01029995663611771306e-01;
const LOG10_2LO: f64 = 3.69423907715893078616e-13;

/// The base-10 logarithm of x.
@export("log10")
pub const fn log10(x0: f64) f64 {
    let mut x = x0;
    let mut hx = hi(x);
    let mut k: i32 = 0;
    if hx < 0x00100000 || hx >> 31 != 0 {
        if bits(x) << 1 == 0 {
            return -1.0 / (x * x); // log(+-0)=-inf
        }
        if hx >> 31 != 0 {
            return (x - x) / 0.0; // log(-#) = NaN
        }
        // subnormal number, scale x up
        k -= 54;
        x *= 0x1p54;
        hx = hi(x);
    } else if hx >= 0x7ff00000 {
        return x;
    } else if hx == 0x3ff00000 && bits(x) << 32 == 0 {
        return 0.0;
    }
    // reduce x into [sqrt(2)/2, sqrt(2)]
    hx += 0x3ff00000 - 0x3fe6a09e;
    k += (hx >> 20) as i32 - 0x3ff;
    hx = (hx & 0x000fffff) + 0x3fe6a09e;
    x = words(hx, lo(x));
    let f = x - 1.0;
    let hfsq = 0.5 * f * f;
    let s = f / (2.0 + f);
    let z = s * s;
    let mut w = z * z;
    let t1 = w * (LG2 + w * (LG4 + w * LG6));
    let t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
    let r = t2 + t1;
    // hi+lo = f - hfsq + s*(hfsq+R) ~ log(1+f)
    let hi_ = dbl(bits(f - hfsq) & ~0u64 << 32);
    let lo_ = f - hi_ - hfsq + s * (hfsq + r);
    // val_hi+val_lo ~ log10(1+f) + k*log10(2)
    let mut val_hi = hi_ * IVLN10HI;
    let dk = k as f64;
    let y = dk * LOG10_2HI;
    let mut val_lo = dk * LOG10_2LO + (lo_ + hi_) * IVLN10LO + lo_ * IVLN10HI;
    // Extra precision in for adding y is not strictly needed since there is no very large cancellation
    // near x = sqrt(2) or x = 1/sqrt(2), but we do it anyway since it costs little on CPUs with some
    // parallelism and it reduces the error for many args.
    w = y + val_hi;
    val_lo += y - w + val_hi;
    val_hi = w;
    return val_lo + val_hi;
}

const IVLN10HIF: f32 = 4.3432617188e-01f32;
const IVLN10LOF: f32 = -3.1689971365e-05f32;
const LOG10_2HIF: f32 = 3.0102920532e-01f32;
const LOG10_2LOF: f32 = 7.9034151668e-07f32;

/// The base-10 logarithm of x.
@export("log10f")
pub const fn log10f(x0: f32) f32 {
    let mut x = x0;
    let mut ix = bitsf(x);
    let mut k: i32 = 0;
    if ix < 0x00800000 || ix >> 31 != 0 {
        // x < 2**-126
        if ix << 1 == 0 {
            return -1.0f32 / (x * x); // log(+-0)=-inf
        }
        if ix >> 31 != 0 {
            return (x - x) / 0.0f32; // log(-#) = NaN
        }
        // subnormal number, scale up x
        k -= 25;
        x *= 0x1p25f32;
        ix = bitsf(x);
    } else if ix >= 0x7f800000 {
        return x;
    } else if ix == 0x3f800000 {
        return 0.0f32;
    }
    // reduce x into [sqrt(2)/2, sqrt(2)]
    ix += 0x3f800000 - 0x3f3504f3;
    k += (ix >> 23) as i32 - 0x7f;
    ix = (ix & 0x007fffff) + 0x3f3504f3;
    x = flt(ix);
    let f = x - 1.0f32;
    let s = f / (2.0f32 + f);
    let z = s * s;
    let w = z * z;
    let t1 = w * (LG2F + w * LG4F);
    let t2 = z * (LG1F + w * LG3F);
    let r = t2 + t1;
    let hfsq = 0.5f32 * f * f;
    let hi_ = flt(bitsf(f - hfsq) & 0xfffff000);
    let lo_ = f - hi_ - hfsq + s * (hfsq + r);
    let dk = k as f32;
    return dk * LOG10_2LOF + (lo_ + hi_) * IVLN10LOF + lo_ * IVLN10HIF + hi_ * IVLN10HIF + dk * LOG10_2HIF;
}

// ---- sinh, cosh, tanh ------------------------------------------------------------------------------------

// exp(x)/2 for x >= log(DBL_MAX), slightly better than 0.5*exp(x/2)*exp(x/2).
const fn expo2(x: f64) f64 {
    // note that k is odd and scale*scale overflows
    let scale = words((0x3ff + 2043 / 2) as u32 << 20, 0);
    // exp(x - k ln2) * 2**(k-1)
    return exp(x - 0x1.62066151add8bp+10) * scale * scale;
}

// expf(x)/2 for x >= log(FLT_MAX), slightly better than 0.5f*expf(x/2)*expf(x/2).
const fn expo2f(x: f32) f32 {
    // note that k is odd and scale*scale overflows
    let scale = flt((0x7f + 235 / 2) as u32 << 23);
    // exp(x - k ln2) * 2**(k-1)
    return expf(x - 0x1.45c778p+7f32) * scale * scale;
}

/// The hyperbolic sine of x.
@export("sinh")
pub const fn sinh(x: f64) f64 {
    let mut h: f64 = 0.5;
    if bits(x) >> 63 != 0 {
        h = -h;
    }
    // |x|
    let ui = bits(x) & 0x7fffffffffffffff;
    let absx = dbl(ui);
    let w = (ui >> 32) as u32;
    // |x| < log(DBL_MAX)
    if w < 0x40862e42 {
        let t = expm1(absx);
        if w < 0x3ff00000 {
            if w < 0x3ff00000 - (26 << 20) {
                // note: inexact and underflow are raised by expm1 handling them separately would only
                // matter for underflow
                return x;
            }
            return h * (2.0 * t - t * t / (t + 1.0));
        }
        // note: |x|>log(0x1p26)+eps could be just h*exp(x)
        return h * (t + t / (t + 1.0));
    }
    // |x| > log(DBL_MAX) or nan
    // note: the result is stored to handle overflow
    return 2.0 * h * expo2(absx);
}

/// The hyperbolic sine of x.
@export("sinhf")
pub const fn sinhf(x: f32) f32 {
    let mut h: f32 = 0.5f32;
    if bitsf(x) >> 31 != 0 {
        h = -h;
    }
    // |x|
    let ui = bitsf(x) & 0x7fffffff;
    let absx = flt(ui);
    let w = ui;
    // |x| < log(FLT_MAX)
    if w < 0x42b17217 {
        let t = expm1f(absx);
        if w < 0x3f800000 {
            if w < 0x3f800000 - (12 << 23) {
                return x;
            }
            return h * (2.0f32 * t - t * t / (t + 1.0f32));
        }
        return h * (t + t / (t + 1.0f32));
    }
    // |x| > logf(FLT_MAX) or nan
    return 2.0f32 * h * expo2f(absx);
}

/// The hyperbolic cosine of x.
@export("cosh")
pub const fn cosh(x0: f64) f64 {
    // |x|
    let ui = bits(x0) & 0x7fffffffffffffff;
    let x = dbl(ui);
    let w = (ui >> 32) as u32;
    // |x| < log(2)
    if w < 0x3fe62e42 {
        if w < 0x3ff00000 - (26 << 20) {
            return 1.0;
        }
        let t = expm1(x);
        return 1.0 + t * t / (2.0 * (1.0 + t));
    }
    // |x| < log(DBL_MAX)
    if w < 0x40862e42 {
        let t = exp(x);
        // note: if x>log(0x1p26) then the 1/t is not needed
        return 0.5 * (t + 1.0 / t);
    }
    // |x| > log(DBL_MAX) or nan
    // note: the result is stored to handle overflow
    return expo2(x);
}

/// The hyperbolic cosine of x.
@export("coshf")
pub const fn coshf(x0: f32) f32 {
    // |x|
    let ui = bitsf(x0) & 0x7fffffff;
    let x = flt(ui);
    let w = ui;
    // |x| < log(2)
    if w < 0x3f317217 {
        if w < 0x3f800000 - (12 << 23) {
            return 1.0f32;
        }
        let t = expm1f(x);
        return 1.0f32 + t * t / (2.0f32 * (1.0f32 + t));
    }
    // |x| < log(FLT_MAX)
    if w < 0x42b17217 {
        let t = expf(x);
        return 0.5f32 * (t + 1.0f32 / t);
    }
    // |x| > log(FLT_MAX) or nan
    return expo2f(x);
}

/// The hyperbolic tangent of x.
@export("tanh")
pub const fn tanh(x0: f64) f64 {
    let sign = bits(x0) >> 63 != 0;
    // x = |x|
    let ui = bits(x0) & 0x7fffffffffffffff;
    let x = dbl(ui);
    let w = (ui >> 32) as u32;
    let mut t: f64 = 0.0;
    if w > 0x3fe193ea {
        // |x| > log(3)/2 ~= 0.5493 or nan
        if w > 0x40340000 {
            // |x| > 20 or nan
            // note: this branch avoids raising overflow
            t = 1.0 - 0.0 / x;
        } else {
            t = expm1(2.0 * x);
            t = 1.0 - 2.0 / (t + 2.0);
        }
    } else if w > 0x3fd058ae {
        // |x| > log(5/3)/2 ~= 0.2554
        t = expm1(2.0 * x);
        t = t / (t + 2.0);
    } else if w >= 0x00100000 {
        // |x| >= 0x1p-1022, up to 2ulp error in [0.1,0.2554]
        t = expm1(-2.0 * x);
        t = -t / (t + 2.0);
    } else {
        // |x| is subnormal
        // note: the branch above would not raise underflow in [0x1p-1023,0x1p-1022)
        t = x;
    }
    return if sign {
        -t
    } else {
        t
    };
}

/// The hyperbolic tangent of x.
@export("tanhf")
pub const fn tanhf(x0: f32) f32 {
    let sign = bitsf(x0) >> 31 != 0;
    // x = |x|
    let ui = bitsf(x0) & 0x7fffffff;
    let x = flt(ui);
    let w = ui;
    let mut t: f32 = 0.0f32;
    if w > 0x3f0c9f54 {
        // |x| > log(3)/2 ~= 0.5493 or nan
        if w > 0x41200000 {
            // |x| > 10
            t = 1.0f32 + 0.0f32 / x;
        } else {
            t = expm1f(2.0f32 * x);
            t = 1.0f32 - 2.0f32 / (t + 2.0f32);
        }
    } else if w > 0x3e82c578 {
        // |x| > log(5/3)/2 ~= 0.2554
        t = expm1f(2.0f32 * x);
        t = t / (t + 2.0f32);
    } else if w >= 0x00800000 {
        // |x| >= 0x1p-126
        t = expm1f(-2.0f32 * x);
        t = -t / (t + 2.0f32);
    } else {
        // |x| is subnormal
        t = x;
    }
    return if sign {
        -t
    } else {
        t
    };
}

// ---- asinh, acosh, atanh ---------------------------------------------------------------------------------

const LN2: f64 = 0.693147180559945309417232121458176568;
const LN2F: f32 = 0.693147180559945309417232121458176568f32;

/// The inverse hyperbolic sine of x.
@export("asinh")
pub fn asinh(x0: f64) f64 {
    let e = (bits(x0) >> 52 & 0x7ff) as u32;
    let s = bits(x0) >> 63 != 0;
    // |x|
    let mut x = dbl(bits(x0) & 0x7fffffffffffffff);
    if e >= 0x3ff + 26 {
        // |x| >= 0x1p26 or inf or nan
        x = log(x) + LN2;
    } else if e >= 0x3ff + 1 {
        // |x| >= 2
        x = log(2.0 * x + 1.0 / (sqrt(x * x + 1.0) + x));
    } else if e >= 0x3ff - 26 {
        // |x| >= 0x1p-26, up to 1.6ulp in [0.125,0.5]
        x = log1p(x + x * x / (sqrt(x * x + 1.0) + 1.0));
    }
    return if s {
        -x
    } else {
        x
    };
}

/// The inverse hyperbolic sine of x.
@export("asinhf")
pub fn asinhf(x0: f32) f32 {
    let i = bitsf(x0) & 0x7fffffff;
    let s = bitsf(x0) >> 31 != 0;
    // |x|
    let mut x = flt(i);
    if i >= 0x3f800000 + (12 << 23) {
        // |x| >= 0x1p12 or inf or nan
        x = logf(x) + LN2F;
    } else if i >= 0x3f800000 + (1 << 23) {
        // |x| >= 2
        x = logf(2.0f32 * x + 1.0f32 / (sqrtf(x * x + 1.0f32) + x));
    } else if i >= 0x3f800000 - (12 << 23) {
        // |x| >= 0x1p-12, up to 1.6ulp in [0.125,0.5]
        x = log1pf(x + x * x / (sqrtf(x * x + 1.0f32) + 1.0f32));
    }
    return if s {
        -x
    } else {
        x
    };
}

/// The inverse hyperbolic cosine of x.
@export("acosh")
pub fn acosh(x: f64) f64 {
    let e = (bits(x) >> 52 & 0x7ff) as u32;
    // x < 1 domain error is handled in the called functions
    if e < 0x3ff + 1 {
        // |x| < 2, up to 2ulp error in [1,1.125]
        return log1p(x - 1.0 + sqrt((x - 1.0) * (x - 1.0) + 2.0 * (x - 1.0)));
    }
    if e < 0x3ff + 26 {
        // |x| < 0x1p26
        return log(2.0 * x - 1.0 / (x + sqrt(x * x - 1.0)));
    }
    // |x| >= 0x1p26 or nan
    return log(x) + LN2;
}

/// The inverse hyperbolic cosine of x.
@export("acoshf")
pub fn acoshf(x: f32) f32 {
    let u = bitsf(x);
    let a = u & 0x7fffffff;
    if a < 0x3f800000 + (1 << 23) {
        // |x| < 2, invalid if x < 1
        // up to 2ulp error in [1,1.125]
        return log1pf(x - 1.0f32 + sqrtf((x - 1.0f32) * (x - 1.0f32) + 2.0f32 * (x - 1.0f32)));
    }
    if u < 0x3f800000 + (12 << 23) {
        // 2 <= x < 0x1p12
        return logf(2.0f32 * x - 1.0f32 / (x + sqrtf(x * x - 1.0f32)));
    }
    // x >= 0x1p12 or x <= -2 or nan
    return logf(x) + LN2F;
}

/// The inverse hyperbolic tangent of x.
@export("atanh")
pub const fn atanh(x: f64) f64 {
    let e = (bits(x) >> 52 & 0x7ff) as u32;
    let s = bits(x) >> 63 != 0;
    // |x|
    let mut y = dbl(bits(x) & 0x7fffffffffffffff);
    if e < 0x3ff - 1 {
        if e >= 0x3ff - 32 {
            // |x| < 0.5, up to 1.7ulp error
            y = 0.5 * log1p(2.0 * y + 2.0 * y * y / (1.0 - y));
        }
    } else {
        // avoid overflow
        y = 0.5 * log1p(2.0 * (y / (1.0 - y)));
    }
    return if s {
        -y
    } else {
        y
    };
}

/// The inverse hyperbolic tangent of x.
@export("atanhf")
pub const fn atanhf(x: f32) f32 {
    let s = bitsf(x) >> 31 != 0;
    // |x|
    let u = bitsf(x) & 0x7fffffff;
    let mut y = flt(u);
    if u < 0x3f800000 - (1 << 23) {
        if u >= 0x3f800000 - (32 << 23) {
            // |x| < 0.5, up to 1.7ulp error
            y = 0.5f32 * log1pf(2.0f32 * y + 2.0f32 * y * y / (1.0f32 - y));
        }
    } else {
        // avoid overflow
        y = 0.5f32 * log1pf(2.0f32 * (y / (1.0f32 - y)));
    }
    return if s {
        -y
    } else {
        y
    };
}

// ---- cbrt, hypot -----------------------------------------------------------------------------------------

const CB1: u32 = 715094163; // B1 = (1023-1023/3-0.03306235651)*2**20
const CB2: u32 = 696219795; // B2 = (1023-1023/3-54/3-0.03306235651)*2**20
// |1/cbrt(x) - p(x)| < 2**-23.5 (~[-7.93e-8, 7.929e-8]).
const CP0: f64 = 1.87595182427177009643;
const CP1: f64 = -1.88497979543377169875;
const CP2: f64 = 1.621429720105354466140;
const CP3: f64 = -0.758397934778766047437;
const CP4: f64 = 0.145996192886612446982;

/// The cube root of x.
@export("cbrt")
pub const fn cbrt(x: f64) f64 {
    let mut ui = bits(x);
    let mut hx = (ui >> 32 & 0x7fffffff) as u32;
    if hx >= 0x7ff00000 {
        // cbrt(NaN,INF) is itself
        return x + x;
    }
    // Rough cbrt to 5 bits.
    if hx < 0x00100000 {
        // zero or subnormal?
        ui = bits(x * 0x1p54);
        hx = (ui >> 32 & 0x7fffffff) as u32;
        if hx == 0 {
            return x; // cbrt(0) is itself
        }
        hx = hx / 3 + CB2;
    } else {
        hx = hx / 3 + CB1;
    }
    ui &= 1u64 << 63;
    ui |= hx as u64 << 32;
    let mut t = dbl(ui);
    // New cbrt to 23 bits: cbrt(x) = t*cbrt(x/t**3) ~= t*P(t**3/x).
    let mut r = t * t * (t / x);
    t = t * (CP0 + r * (CP1 + r * CP2) + r * r * r * (CP3 + r * CP4));
    // Round t away from zero to 23 bits.
    t = dbl(bits(t) + 0x80000000 & 0xffffffffc0000000);
    // one step Newton iteration to 53 bits with error < 0.667 ulps
    let s = t * t; // t*t is exact
    r = x / s; // error <= 0.5 ulps; |r| < |t|
    let w = t + t; // t+t is exact
    r = (r - t) / (w + r); // r-t is exact; w+r ~= 3*t
    t = t + t * r; // error <= 0.5 + 0.5/3 + epsilon
    return t;
}

const CB1F: u32 = 709958130; // B1 = (127-127.0/3-0.03306235651)*2**23
const CB2F: u32 = 642849266; // B2 = (127-127.0/3-24/3-0.03306235651)*2**23

/// The cube root of x.
@export("cbrtf")
pub const fn cbrtf(x: f32) f32 {
    let mut ui = bitsf(x);
    let mut hx = ui & 0x7fffffff;
    if hx >= 0x7f800000 {
        // cbrt(NaN,INF) is itself
        return x + x;
    }
    // rough cbrt to 5 bits
    if hx < 0x00800000 {
        // zero or subnormal?
        if hx == 0 {
            return x; // cbrt(+-0) is itself
        }
        ui = bitsf(x * 0x1p24f32);
        hx = ui & 0x7fffffff;
        hx = hx / 3 + CB2F;
    } else {
        hx = hx / 3 + CB1F;
    }
    ui &= 0x80000000;
    ui |= hx;
    // First step Newton iteration (solving t*t-x/t == 0) to 16 bits. In double precision so that its
    // terms can be arranged for efficiency without causing overflow or underflow.
    let xd = x as f64;
    let mut t = flt(ui) as f64;
    let mut r = t * t * t;
    t = t * (xd + xd + r) / (xd + r + r);
    // Second step Newton iteration to 47 bits. In double precision for efficiency and accuracy.
    r = t * t * t;
    t = t * (xd + xd + r) / (xd + r + r);
    // rounding to 24 bits is perfect in round-to-nearest mode
    return t as f32;
}

// x*x as hi + lo exactly.
const fn sq(hi_: &mut f64, lo_: &mut f64, x: f64) {
    let xc = x * (0x1p27 + 1.0);
    let xh = x - xc + xc;
    let xl = x - xh;
    *hi_ = x * x;
    *lo_ = xh * xh - *hi_ + 2.0 * xh * xl + xl * xl;
}

/// sqrt(x^2 + y^2) without undue overflow or underflow.
@export("hypot")
pub fn hypot(x0: f64, y0: f64) f64 {
    let mut ux = bits(x0) & ~0u64 >> 1;
    let mut uy = bits(y0) & ~0u64 >> 1;
    // arrange |x| >= |y|
    if ux < uy {
        let ut = ux;
        ux = uy;
        uy = ut;
    }
    // special cases
    let ex = (ux >> 52) as i32;
    let ey = (uy >> 52) as i32;
    let mut x = dbl(ux);
    let mut y = dbl(uy);
    // note: hypot(inf,nan) == inf
    if ey == 0x7ff {
        return y;
    }
    if ex == 0x7ff || uy == 0 {
        return x;
    }
    // note: hypot(x,y) ~= x + y*y/x/2 with inexact for small y/x 64 difference is enough for ld80 double_t
    if ex - ey > 64 {
        return x + y;
    }
    // precise sqrt argument in nearest rounding mode without overflow xh*xh must not overflow and xl*xl
    // must not underflow in sq
    let mut z: f64 = 1.0;
    if ex > 0x3ff + 510 {
        z = 0x1p700;
        x *= 0x1p-700;
        y *= 0x1p-700;
    } else if ey < 0x3ff - 450 {
        z = 0x1p-700;
        x *= 0x1p700;
        y *= 0x1p700;
    }
    let mut hx: f64 = 0.0;
    let mut lx: f64 = 0.0;
    let mut hy: f64 = 0.0;
    let mut ly: f64 = 0.0;
    sq(&mut hx, &mut lx, x);
    sq(&mut hy, &mut ly, y);
    return z * sqrt(ly + lx + hy + hx);
}

/// sqrt(x^2 + y^2) without undue overflow or underflow.
@export("hypotf")
pub fn hypotf(x0: f32, y0: f32) f32 {
    let mut ux = bitsf(x0) & ~0u32 >> 1;
    let mut uy = bitsf(y0) & ~0u32 >> 1;
    if ux < uy {
        let ut = ux;
        ux = uy;
        uy = ut;
    }
    let mut x = flt(ux);
    let mut y = flt(uy);
    if uy == 0xff << 23 {
        return y;
    }
    if ux >= 0xff << 23 || uy == 0 || ux - uy >= 25 << 23 {
        return x + y;
    }
    let mut z: f32 = 1.0f32;
    if ux >= 0x7f + 60 << 23 {
        z = 0x1p90f32;
        x *= 0x1p-90f32;
        y *= 0x1p-90f32;
    } else if uy < 0x7f - 60 << 23 {
        z = 0x1p-90f32;
        x *= 0x1p90f32;
        y *= 0x1p90f32;
    }
    return z * sqrtf((x as f64 * x as f64 + y as f64 * y as f64) as f32);
}

// ---- erf -------------------------------------------------------------------------------------------------

const EERX: f64 = 8.45062911510467529297e-01;
const EEFX8: f64 = 1.02703333676410069053e+00;
const EPP0: f64 = 1.28379167095512558561e-01;
const EPP1: f64 = -3.25042107247001499370e-01;
const EPP2: f64 = -2.84817495755985104766e-02;
const EPP3: f64 = -5.77027029648944159157e-03;
const EPP4: f64 = -2.37630166566501626084e-05;
const EQQ1: f64 = 3.97917223959155352819e-01;
const EQQ2: f64 = 6.50222499887672944485e-02;
const EQQ3: f64 = 5.08130628187576562776e-03;
const EQQ4: f64 = 1.32494738004321644526e-04;
const EQQ5: f64 = -3.96022827877536812320e-06;
const EPA0: f64 = -2.36211856075265944077e-03;
const EPA1: f64 = 4.14856118683748331666e-01;
const EPA2: f64 = -3.72207876035701323847e-01;
const EPA3: f64 = 3.18346619901161753674e-01;
const EPA4: f64 = -1.10894694282396677476e-01;
const EPA5: f64 = 3.54783043256182359371e-02;
const EPA6: f64 = -2.16637559486879084300e-03;
const EQA1: f64 = 1.06420880400844228286e-01;
const EQA2: f64 = 5.40397917702171048937e-01;
const EQA3: f64 = 7.18286544141962662868e-02;
const EQA4: f64 = 1.26171219808761642112e-01;
const EQA5: f64 = 1.36370839120290507362e-02;
const EQA6: f64 = 1.19844998467991074170e-02;
const ERA0: f64 = -9.86494403484714822705e-03;
const ERA1: f64 = -6.93858572707181764372e-01;
const ERA2: f64 = -1.05586262253232909814e+01;
const ERA3: f64 = -6.23753324503260060396e+01;
const ERA4: f64 = -1.62396669462573470355e+02;
const ERA5: f64 = -1.84605092906711035994e+02;
const ERA6: f64 = -8.12874355063065934246e+01;
const ERA7: f64 = -9.81432934416914548592e+00;
const ESA1: f64 = 1.96512716674392571292e+01;
const ESA2: f64 = 1.37657754143519042600e+02;
const ESA3: f64 = 4.34565877475229228821e+02;
const ESA4: f64 = 6.45387271733267880336e+02;
const ESA5: f64 = 4.29008140027567833386e+02;
const ESA6: f64 = 1.08635005541779435134e+02;
const ESA7: f64 = 6.57024977031928170135e+00;
const ESA8: f64 = -6.04244152148580987438e-02;
const ERB0: f64 = -9.86494292470009928597e-03;
const ERB1: f64 = -7.99283237680523006574e-01;
const ERB2: f64 = -1.77579549177547519889e+01;
const ERB3: f64 = -1.60636384855821916062e+02;
const ERB4: f64 = -6.37566443368389627722e+02;
const ERB5: f64 = -1.02509513161107724954e+03;
const ERB6: f64 = -4.83519191608651397019e+02;
const ESB1: f64 = 3.03380607434824582924e+01;
const ESB2: f64 = 3.25792512996573918826e+02;
const ESB3: f64 = 1.53672958608443695994e+03;
const ESB4: f64 = 3.19985821950859553908e+03;
const ESB5: f64 = 2.55305040643316442583e+03;
const ESB6: f64 = 4.74528541206955367215e+02;
const ESB7: f64 = -2.24409524465858183362e+01;

const EERXF: f32 = 8.4506291151e-01f32;
const EEFX8F: f32 = 1.0270333290e+00f32;
const EPP0F: f32 = 1.2837916613e-01f32;
const EPP1F: f32 = -3.2504209876e-01f32;
const EPP2F: f32 = -2.8481749818e-02f32;
const EPP3F: f32 = -5.7702702470e-03f32;
const EPP4F: f32 = -2.3763017452e-05f32;
const EQQ1F: f32 = 3.9791721106e-01f32;
const EQQ2F: f32 = 6.5022252500e-02f32;
const EQQ3F: f32 = 5.0813062117e-03f32;
const EQQ4F: f32 = 1.3249473704e-04f32;
const EQQ5F: f32 = -3.9602282413e-06f32;
const EPA0F: f32 = -2.3621185683e-03f32;
const EPA1F: f32 = 4.1485610604e-01f32;
const EPA2F: f32 = -3.7220788002e-01f32;
const EPA3F: f32 = 3.1834661961e-01f32;
const EPA4F: f32 = -1.1089469492e-01f32;
const EPA5F: f32 = 3.5478305072e-02f32;
const EPA6F: f32 = -2.1663755178e-03f32;
const EQA1F: f32 = 1.0642088205e-01f32;
const EQA2F: f32 = 5.4039794207e-01f32;
const EQA3F: f32 = 7.1828655899e-02f32;
const EQA4F: f32 = 1.2617121637e-01f32;
const EQA5F: f32 = 1.3637083583e-02f32;
const EQA6F: f32 = 1.1984500103e-02f32;
const ERA0F: f32 = -9.8649440333e-03f32;
const ERA1F: f32 = -6.9385856390e-01f32;
const ERA2F: f32 = -1.0558626175e+01f32;
const ERA3F: f32 = -6.2375331879e+01f32;
const ERA4F: f32 = -1.6239666748e+02f32;
const ERA5F: f32 = -1.8460508728e+02f32;
const ERA6F: f32 = -8.1287437439e+01f32;
const ERA7F: f32 = -9.8143291473e+00f32;
const ESA1F: f32 = 1.9651271820e+01f32;
const ESA2F: f32 = 1.3765776062e+02f32;
const ESA3F: f32 = 4.3456588745e+02f32;
const ESA4F: f32 = 6.4538726807e+02f32;
const ESA5F: f32 = 4.2900814819e+02f32;
const ESA6F: f32 = 1.0863500214e+02f32;
const ESA7F: f32 = 6.5702495575e+00f32;
const ESA8F: f32 = -6.0424413532e-02f32;
const ERB0F: f32 = -9.8649431020e-03f32;
const ERB1F: f32 = -7.9928326607e-01f32;
const ERB2F: f32 = -1.7757955551e+01f32;
const ERB3F: f32 = -1.6063638306e+02f32;
const ERB4F: f32 = -6.3756646729e+02f32;
const ERB5F: f32 = -1.0250950928e+03f32;
const ERB6F: f32 = -4.8351919556e+02f32;
const ESB1F: f32 = 3.0338060379e+01f32;
const ESB2F: f32 = 3.2579251099e+02f32;
const ESB3F: f32 = 1.5367296143e+03f32;
const ESB4F: f32 = 3.1998581543e+03f32;
const ESB5F: f32 = 2.5530502930e+03f32;
const ESB6F: f32 = 4.7452853394e+02f32;
const ESB7F: f32 = -2.2440952301e+01f32;

// erfc(x) for 0.84375 <= |x| < 1.25.
fn erfc1(x: f64) f64 {
    let s = fabs(x) - 1.0;
    let p = EPA0 + s * (EPA1 + s * (EPA2 + s * (EPA3 + s * (EPA4 + s * (EPA5 + s * EPA6)))));
    let q = 1.0 + s * (EQA1 + s * (EQA2 + s * (EQA3 + s * (EQA4 + s * (EQA5 + s * EQA6)))));
    return 1.0 - EERX - p / q;
}

// erfc(x) for 0.84375 <= |x| < 28, `ix` the high word of |x|.
fn erfc2(ix: u32, x0: f64) f64 {
    if ix < 0x3ff40000 {
        // |x| < 1.25
        return erfc1(x0);
    }
    let x = fabs(x0);
    let s = 1.0 / (x * x);
    let mut r: f64 = 0.0;
    let mut ss: f64 = 0.0;
    if ix < 0x4006db6d {
        // |x| < 1/.35 ~ 2.85714
        r = ERA0 + s * (ERA1 + s * (ERA2 + s * (ERA3 + s * (ERA4 + s * (ERA5 + s * (ERA6 + s * ERA7))))));
        ss = 1.0 + s * (ESA1 + s * (ESA2 + s * (ESA3 + s * (ESA4 + s * (ESA5 + s * (ESA6 + s * (ESA7 + s * ESA8)))))));
    } else {
        // |x| > 1/.35
        r = ERB0 + s * (ERB1 + s * (ERB2 + s * (ERB3 + s * (ERB4 + s * (ERB5 + s * ERB6)))));
        ss = 1.0 + s * (ESB1 + s * (ESB2 + s * (ESB3 + s * (ESB4 + s * (ESB5 + s * (ESB6 + s * ESB7))))));
    }
    let z = words(hi(x), 0);
    return exp(-z * z - 0.5625) * exp((z - x) * (z + x) + r / ss) / x;
}

/// The error function of x.
@export("erf")
pub fn erf(x: f64) f64 {
    let mut ix = hi(x);
    let sign = (ix >> 31) as i32;
    ix &= 0x7fffffff;
    if ix >= 0x7ff00000 {
        // erf(nan)=nan, erf(+-inf)=+-1
        return (1 - 2 * sign) as f64 + 1.0 / x;
    }
    if ix < 0x3feb0000 {
        // |x| < 0.84375
        if ix < 0x3e300000 {
            // |x| < 2**-28
            // avoid underflow
            return 0.125 * (8.0 * x + EEFX8 * x);
        }
        let z = x * x;
        let r = EPP0 + z * (EPP1 + z * (EPP2 + z * (EPP3 + z * EPP4)));
        let s = 1.0 + z * (EQQ1 + z * (EQQ2 + z * (EQQ3 + z * (EQQ4 + z * EQQ5))));
        let y = r / s;
        return x + x * y;
    }
    let y = if ix < 0x40180000 {
        // 0.84375 <= |x| < 6
        1.0 - erfc2(ix, x)
    } else {
        1.0 - 0x1p-1022
    };
    return if sign != 0 {
        -y
    } else {
        y
    };
}

fn erfc1f(x: f32) f32 {
    let s = fabsf(x) - 1.0f32;
    let p = EPA0F + s * (EPA1F + s * (EPA2F + s * (EPA3F + s * (EPA4F + s * (EPA5F + s * EPA6F)))));
    let q = 1.0f32 + s * (EQA1F + s * (EQA2F + s * (EQA3F + s * (EQA4F + s * (EQA5F + s * EQA6F)))));
    return 1.0f32 - EERXF - p / q;
}

fn erfc2f(ix: u32, x0: f32) f32 {
    if ix < 0x3fa00000 {
        // |x| < 1.25
        return erfc1f(x0);
    }
    let x = fabsf(x0);
    let s = 1.0f32 / (x * x);
    let mut r: f32 = 0.0f32;
    let mut ss: f32 = 0.0f32;
    if ix < 0x4036db6d {
        // |x| < 1/0.35
        r = ERA0F + s * (ERA1F + s * (ERA2F + s * (ERA3F + s * (ERA4F + s * (ERA5F + s * (ERA6F + s * ERA7F))))));
        ss = 1.0f32 + s * (ESA1F + s * (ESA2F + s * (ESA3F + s * (ESA4F + s * (ESA5F + s * (ESA6F + s * (ESA7F + s * ESA8F)))))));
    } else {
        // |x| >= 1/0.35
        r = ERB0F + s * (ERB1F + s * (ERB2F + s * (ERB3F + s * (ERB4F + s * (ERB5F + s * ERB6F)))));
        ss = 1.0f32 + s * (ESB1F + s * (ESB2F + s * (ESB3F + s * (ESB4F + s * (ESB5F + s * (ESB6F + s * ESB7F))))));
    }
    let z = flt(bitsf(x) & 0xffffe000);
    return expf(-z * z - 0.5625f32) * expf((z - x) * (z + x) + r / ss) / x;
}

/// The error function of x.
@export("erff")
pub fn erff(x: f32) f32 {
    let mut ix = bitsf(x);
    let sign = (ix >> 31) as i32;
    ix &= 0x7fffffff;
    if ix >= 0x7f800000 {
        // erf(nan)=nan, erf(+-inf)=+-1
        return (1 - 2 * sign) as f32 + 1.0f32 / x;
    }
    if ix < 0x3f580000 {
        // |x| < 0.84375
        if ix < 0x31800000 {
            // |x| < 2**-28
            // avoid underflow
            return 0.125f32 * (8.0f32 * x + EEFX8F * x);
        }
        let z = x * x;
        let r = EPP0F + z * (EPP1F + z * (EPP2F + z * (EPP3F + z * EPP4F)));
        let s = 1.0f32 + z * (EQQ1F + z * (EQQ2F + z * (EQQ3F + z * (EQQ4F + z * EQQ5F))));
        let y = r / s;
        return x + x * y;
    }
    let y = if ix < 0x40c00000 {
        // |x| < 6
        1.0f32 - erfc2f(ix, x)
    } else {
        1.0f32 - 0x1p-120f32
    };
    return if sign != 0 {
        -y
    } else {
        y
    };
}

/// The complementary error function of x, 1 - erf(x).
@export("erfc")
pub fn erfc(x: f64) f64 {
    let mut ix = hi(x);
    let sign = (ix >> 31) as i32;
    ix &= 0x7fffffff;
    if ix >= 0x7ff00000 {
        // erfc(nan)=nan, erfc(+-inf)=0,2
        return (2 * sign) as f64 + 1.0 / x;
    }
    if ix < 0x3feb0000 {
        // |x| < 0.84375
        if ix < 0x3c700000 {
            // |x| < 2**-56
            return 1.0 - x;
        }
        let z = x * x;
        let r = EPP0 + z * (EPP1 + z * (EPP2 + z * (EPP3 + z * EPP4)));
        let s = 1.0 + z * (EQQ1 + z * (EQQ2 + z * (EQQ3 + z * (EQQ4 + z * EQQ5))));
        let y = r / s;
        if sign != 0 || ix < 0x3fd00000 {
            // x < 1/4
            return 1.0 - (x + x * y);
        }
        return 0.5 - (x - 0.5 + x * y);
    }
    if ix < 0x403c0000 {
        // 0.84375 <= |x| < 28
        return if sign != 0 {
            2.0 - erfc2(ix, x)
        } else {
            erfc2(ix, x)
        };
    }
    return if sign != 0 {
        2.0 - 0x1p-1022
    } else {
        0x1p-1022 * 0x1p-1022
    };
}

/// The complementary error function of x, 1 - erf(x).
@export("erfcf")
pub fn erfcf(x: f32) f32 {
    let mut ix = bitsf(x);
    let sign = (ix >> 31) as i32;
    ix &= 0x7fffffff;
    if ix >= 0x7f800000 {
        // erfc(nan)=nan, erfc(+-inf)=0,2
        return (2 * sign) as f32 + 1.0f32 / x;
    }
    if ix < 0x3f580000 {
        // |x| < 0.84375
        if ix < 0x23800000 {
            // |x| < 2**-56
            return 1.0f32 - x;
        }
        let z = x * x;
        let r = EPP0F + z * (EPP1F + z * (EPP2F + z * (EPP3F + z * EPP4F)));
        let s = 1.0f32 + z * (EQQ1F + z * (EQQ2F + z * (EQQ3F + z * (EQQ4F + z * EQQ5F))));
        let y = r / s;
        if sign != 0 || ix < 0x3e800000 {
            // x < 1/4
            return 1.0f32 - (x + x * y);
        }
        return 0.5f32 - (x - 0.5f32 + x * y);
    }
    if ix < 0x41e00000 {
        // |x| < 28
        return if sign != 0 {
            2.0f32 - erfc2f(ix, x)
        } else {
            erfc2f(ix, x)
        };
    }
    return if sign != 0 {
        2.0f32 - 0x1p-120f32
    } else {
        0x1p-120f32 * 0x1p-120f32
    };
}

// ---- frexp, modf, nextafter --------------------------------------------------------------------------------

/// The fraction of x in [0.5, 1), with its sign, and through `e` the power of two that scales it back to x;
/// x and 0 for a zero, an infinity or a NaN.
@export("frexp")
pub fn frexp(x: f64, e: *mut i32) f64 {
    let i = bits(x);
    let ee = (i >> 52 & 0x7ff) as i32;
    if ee == 0 {
        if x != 0.0 {
            let y = frexp(x * 0x1p64, e);
            unsafe *e -= 64;
            return y;
        }
        unsafe *e = 0;
        return x;
    }
    if ee == 0x7ff {
        return x;
    }
    unsafe *e = ee - 0x3fe;
    return dbl(i & 0x800fffffffffffff | 0x3fe0000000000000);
}

/// The fraction of x in [0.5, 1), with its sign, and through `e` the power of two that scales it back to x;
/// x and 0 for a zero, an infinity or a NaN.
@export("frexpf")
pub fn frexpf(x: f32, e: *mut i32) f32 {
    let i = bitsf(x);
    let ee = (i >> 23 & 0xff) as i32;
    if ee == 0 {
        if x != 0.0f32 {
            let y = frexpf((x as f64 * 0x1p64) as f32, e);
            unsafe *e -= 64;
            return y;
        }
        unsafe *e = 0;
        return x;
    }
    if ee == 0xff {
        return x;
    }
    unsafe *e = ee - 0x7e;
    return flt(i & 0x807fffff | 0x3f000000);
}

/// The fractional part of x, with x's sign, and through `ip` its integral part.
@export("modf")
pub const fn modf(x: f64, ip: *mut f64) f64 {
    let i = bits(x);
    let e = (i >> 52 & 0x7ff) as i32 - 0x3ff;
    if e >= 52 {
        // No fractional part.
        unsafe *ip = x;
        if e == 0x400 && i << 12 != 0 {
            return x;
        }
        return dbl(i & 1u64 << 63);
    }
    if e < 0 {
        // No integral part.
        unsafe *ip = dbl(i & 1u64 << 63);
        return x;
    }
    let mask = ~0u64 >> 12 >> e as u64;
    if (i & mask) == 0 {
        unsafe *ip = x;
        return dbl(i & 1u64 << 63);
    }
    let n = dbl(i & ~mask);
    unsafe *ip = n;
    return x - n;
}

/// The fractional part of x, with x's sign, and through `ip` its integral part.
@export("modff")
pub const fn modff(x: f32, ip: *mut f32) f32 {
    let i = bitsf(x);
    let e = (i >> 23 & 0xff) as i32 - 0x7f;
    if e >= 23 {
        // No fractional part.
        unsafe *ip = x;
        if e == 0x80 && i << 9 != 0 {
            return x;
        }
        return flt(i & 0x80000000);
    }
    if e < 0 {
        // No integral part.
        unsafe *ip = flt(i & 0x80000000);
        return x;
    }
    let mask = 0x007fffffu32 >> e as u32;
    if (i & mask) == 0 {
        unsafe *ip = x;
        return flt(i & 0x80000000);
    }
    let n = flt(i & ~mask);
    unsafe *ip = n;
    return x - n;
}

/// The next double after x toward y; y when they are equal, a NaN when either is one.
@export("nextafter")
pub const fn nextafter(x: f64, y: f64) f64 {
    if x != x || y != y {
        return x + y;
    }
    let mut ux = bits(x);
    let uy = bits(y);
    if ux == uy {
        return y;
    }
    let ax = ux & ~0u64 >> 1;
    let ay = uy & ~0u64 >> 1;
    if ax == 0 {
        if ay == 0 {
            return y;
        }
        ux = uy & 1u64 << 63 | 1;
    } else if ax > ay || ((ux ^ uy) & 1u64 << 63) != 0 {
        ux -= 1;
    } else {
        ux += 1;
    }
    return dbl(ux);
}

/// The next float after x toward y; y when they are equal, a NaN when either is one.
@export("nextafterf")
pub const fn nextafterf(x: f32, y: f32) f32 {
    if x != x || y != y {
        return x + y;
    }
    let mut ux = bitsf(x);
    let uy = bitsf(y);
    if ux == uy {
        return y;
    }
    let ax = ux & 0x7fffffff;
    let ay = uy & 0x7fffffff;
    if ax == 0 {
        if ay == 0 {
            return y;
        }
        ux = uy & 0x80000000 | 1;
    } else if ax > ay || ((ux ^ uy) & 0x80000000) != 0 {
        ux -= 1;
    } else {
        ux += 1;
    }
    return flt(ux);
}

// ---- lgamma, tgamma -----------------------------------------------------------------------------------

const LG_PI: f64 = 3.14159265358979311600e+00;
const LG_A0: f64 = 7.72156649015328655494e-02;
const LG_A1: f64 = 3.22467033424113591611e-01;
const LG_A2: f64 = 6.73523010531292681824e-02;
const LG_A3: f64 = 2.05808084325167332806e-02;
const LG_A4: f64 = 7.38555086081402883957e-03;
const LG_A5: f64 = 2.89051383673415629091e-03;
const LG_A6: f64 = 1.19270763183362067845e-03;
const LG_A7: f64 = 5.10069792153511336608e-04;
const LG_A8: f64 = 2.20862790713908385557e-04;
const LG_A9: f64 = 1.08011567247583939954e-04;
const LG_A10: f64 = 2.52144565451257326939e-05;
const LG_A11: f64 = 4.48640949618915160150e-05;
const LG_TC: f64 = 1.46163214496836224576e+00;
const LG_TF: f64 = -1.21486290535849611461e-01;
const LG_TT: f64 = -3.63867699703950536541e-18;
const LG_T0: f64 = 4.83836122723810047042e-01;
const LG_T1: f64 = -1.47587722994593911752e-01;
const LG_T2: f64 = 6.46249402391333854778e-02;
const LG_T3: f64 = -3.27885410759859649565e-02;
const LG_T4: f64 = 1.79706750811820387126e-02;
const LG_T5: f64 = -1.03142241298341437450e-02;
const LG_T6: f64 = 6.10053870246291332635e-03;
const LG_T7: f64 = -3.68452016781138256760e-03;
const LG_T8: f64 = 2.25964780900612472250e-03;
const LG_T9: f64 = -1.40346469989232843813e-03;
const LG_T10: f64 = 8.81081882437654011382e-04;
const LG_T11: f64 = -5.38595305356740546715e-04;
const LG_T12: f64 = 3.15632070903625950361e-04;
const LG_T13: f64 = -3.12754168375120860518e-04;
const LG_T14: f64 = 3.35529192635519073543e-04;
const LG_U0: f64 = -7.72156649015328655494e-02;
const LG_U1: f64 = 6.32827064025093366517e-01;
const LG_U2: f64 = 1.45492250137234768737e+00;
const LG_U3: f64 = 9.77717527963372745603e-01;
const LG_U4: f64 = 2.28963728064692451092e-01;
const LG_U5: f64 = 1.33810918536787660377e-02;
const LG_V1: f64 = 2.45597793713041134822e+00;
const LG_V2: f64 = 2.12848976379893395361e+00;
const LG_V3: f64 = 7.69285150456672783825e-01;
const LG_V4: f64 = 1.04222645593369134254e-01;
const LG_V5: f64 = 3.21709242282423911810e-03;
const LG_S0: f64 = -7.72156649015328655494e-02;
const LG_S1: f64 = 2.14982415960608852501e-01;
const LG_S2: f64 = 3.25778796408930981787e-01;
const LG_S3: f64 = 1.46350472652464452805e-01;
const LG_S4: f64 = 2.66422703033638609560e-02;
const LG_S5: f64 = 1.84028451407337715652e-03;
const LG_S6: f64 = 3.19475326584100867617e-05;
const LG_R1: f64 = 1.39200533467621045958e+00;
const LG_R2: f64 = 7.21935547567138069525e-01;
const LG_R3: f64 = 1.71933865632803078993e-01;
const LG_R4: f64 = 1.86459191715652901344e-02;
const LG_R5: f64 = 7.77942496381893596434e-04;
const LG_R6: f64 = 7.32668430744625636189e-06;
const LG_W0: f64 = 4.18938533204672725052e-01;
const LG_W1: f64 = 8.33333333333329678849e-02;
const LG_W2: f64 = -2.77777777728775536470e-03;
const LG_W3: f64 = 7.93650558643019558500e-04;
const LG_W4: f64 = -5.95187557450339963135e-04;
const LG_W5: f64 = 8.36339918996282139126e-04;
const LG_W6: f64 = -1.63092934096575273989e-03;

const LGF_PI: f32 = 3.1415927410e+00f32;
const LGF_A0: f32 = 7.7215664089e-02f32;
const LGF_A1: f32 = 3.2246702909e-01f32;
const LGF_A2: f32 = 6.7352302372e-02f32;
const LGF_A3: f32 = 2.0580807701e-02f32;
const LGF_A4: f32 = 7.3855509982e-03f32;
const LGF_A5: f32 = 2.8905137442e-03f32;
const LGF_A6: f32 = 1.1927076848e-03f32;
const LGF_A7: f32 = 5.1006977446e-04f32;
const LGF_A8: f32 = 2.2086278477e-04f32;
const LGF_A9: f32 = 1.0801156895e-04f32;
const LGF_A10: f32 = 2.5214456400e-05f32;
const LGF_A11: f32 = 4.4864096708e-05f32;
const LGF_TC: f32 = 1.4616321325e+00f32;
const LGF_TF: f32 = -1.2148628384e-01f32;
const LGF_TT: f32 = 6.6971006518e-09f32;
const LGF_T0: f32 = 4.8383611441e-01f32;
const LGF_T1: f32 = -1.4758771658e-01f32;
const LGF_T2: f32 = 6.4624942839e-02f32;
const LGF_T3: f32 = -3.2788541168e-02f32;
const LGF_T4: f32 = 1.7970675603e-02f32;
const LGF_T5: f32 = -1.0314224288e-02f32;
const LGF_T6: f32 = 6.1005386524e-03f32;
const LGF_T7: f32 = -3.6845202558e-03f32;
const LGF_T8: f32 = 2.2596477065e-03f32;
const LGF_T9: f32 = -1.4034647029e-03f32;
const LGF_T10: f32 = 8.8108185446e-04f32;
const LGF_T11: f32 = -5.3859531181e-04f32;
const LGF_T12: f32 = 3.1563205994e-04f32;
const LGF_T13: f32 = -3.1275415677e-04f32;
const LGF_T14: f32 = 3.3552918467e-04f32;
const LGF_U0: f32 = -7.7215664089e-02f32;
const LGF_U1: f32 = 6.3282704353e-01f32;
const LGF_U2: f32 = 1.4549225569e+00f32;
const LGF_U3: f32 = 9.7771751881e-01f32;
const LGF_U4: f32 = 2.2896373272e-01f32;
const LGF_U5: f32 = 1.3381091878e-02f32;
const LGF_V1: f32 = 2.4559779167e+00f32;
const LGF_V2: f32 = 2.1284897327e+00f32;
const LGF_V3: f32 = 7.6928514242e-01f32;
const LGF_V4: f32 = 1.0422264785e-01f32;
const LGF_V5: f32 = 3.2170924824e-03f32;
const LGF_S0: f32 = -7.7215664089e-02f32;
const LGF_S1: f32 = 2.1498242021e-01f32;
const LGF_S2: f32 = 3.2577878237e-01f32;
const LGF_S3: f32 = 1.4635047317e-01f32;
const LGF_S4: f32 = 2.6642270386e-02f32;
const LGF_S5: f32 = 1.8402845599e-03f32;
const LGF_S6: f32 = 3.1947532989e-05f32;
const LGF_R1: f32 = 1.3920053244e+00f32;
const LGF_R2: f32 = 7.2193557024e-01f32;
const LGF_R3: f32 = 1.7193385959e-01f32;
const LGF_R4: f32 = 1.8645919859e-02f32;
const LGF_R5: f32 = 7.7794247773e-04f32;
const LGF_R6: f32 = 7.3266842264e-06f32;
const LGF_W0: f32 = 4.1893854737e-01f32;
const LGF_W1: f32 = 8.3333335817e-02f32;
const LGF_W2: f32 = -2.7777778450e-03f32;
const LGF_W3: f32 = 7.9365057172e-04f32;
const LGF_W4: f32 = -5.9518753551e-04f32;
const LGF_W5: f32 = 8.3633989561e-04f32;
const LGF_W6: f32 = -1.6309292987e-03f32;

// sin(pi*x) for x > 0, as tgamma and lgamma need it; an integer x gives 0.
fn sin_pi(x0: f64) f64 {
    // spurious inexact if odd int
    let mut x = 2.0 * (x0 * 0.5 - floor(x0 * 0.5)); // x mod 2.0
    let mut n = (x * 4.0) as i32;
    n = (n + 1) / 2;
    x -= n as f64 * 0.5;
    x *= LG_PI;
    if n == 1 {
        return k_cos(x, 0.0);
    }
    if n == 2 {
        return k_sin(-x, 0.0, 0);
    }
    if n == 3 {
        return -k_cos(x, 0.0);
    }
    // n is 0 or 4: x is in [0, 2)
    return k_sin(x, 0.0, 0);
}

/// The sign of the gamma function at the argument of the last `lgamma` or `lgammaf`: 1 or -1.
@export("signgam")
pub static mut SIGNGAM: i32 = 0;

// log(|gamma(x)|), the sign of gamma(x) in `*signgamp`.
fn lgamma_r(x0: f64, signgamp: &mut i32) f64 {
    let mut x = x0;
    let u = bits(x);
    let mut t: f64 = 0.0;
    let mut nadj: f64 = 0.0;
    let mut r: f64 = 0.0;
    // purge off +-inf, NaN, +-0, tiny and negative arguments
    *signgamp = 1;
    let sign = u >> 63 != 0;
    let ix = (u >> 32 & 0x7fffffff) as u32;
    if ix >= 0x7ff00000 {
        return x * x;
    }
    if ix < 0x3ff - 70 << 20 {
        // |x|<2**-70, return -log(|x|)
        if sign {
            x = -x;
            *signgamp = -1;
        }
        return -log(x);
    }
    if sign {
        x = -x;
        t = sin_pi(x);
        if t == 0.0 {
            // -integer
            return 1.0 / (x - x);
        }
        if t > 0.0 {
            *signgamp = -1;
        } else {
            t = -t;
        }
        nadj = log(LG_PI / (t * x));
    }
    // purge off 1 and 2
    if (ix == 0x3ff00000 || ix == 0x40000000) && u as u32 == 0 {
        r = 0.0;
    } else if ix < 0x40000000 {
        // for x < 2.0
        let mut y: f64 = 0.0;
        let mut i: i32 = 0;
        if ix <= 0x3feccccc {
            // lgamma(x) = lgamma(x+1)-log(x)
            r = -log(x);
            if ix >= 0x3FE76944 {
                y = 1.0 - x;
                i = 0;
            } else if ix >= 0x3FCDA661 {
                y = x - (LG_TC - 1.0);
                i = 1;
            } else {
                y = x;
                i = 2;
            }
        } else {
            r = 0.0;
            if ix >= 0x3FFBB4C3 {
                // [1.7316,2]
                y = 2.0 - x;
                i = 0;
            } else if ix >= 0x3FF3B4C4 {
                // [1.23,1.73]
                y = x - LG_TC;
                i = 1;
            } else {
                y = x - 1.0;
                i = 2;
            }
        }
        if i == 0 {
            let z = y * y;
            let p1 = LG_A0 + z * (LG_A2 + z * (LG_A4 + z * (LG_A6 + z * (LG_A8 + z * LG_A10))));
            let p2 = z * (LG_A1 + z * (LG_A3 + z * (LG_A5 + z * (LG_A7 + z * (LG_A9 + z * LG_A11)))));
            let p = y * p1 + p2;
            r += p - 0.5 * y;
        } else if i == 1 {
            let z = y * y;
            let w = z * y;
            let p1 = LG_T0 + w * (LG_T3 + w * (LG_T6 + w * (LG_T9 + w * LG_T12))); // parallel comp
            let p2 = LG_T1 + w * (LG_T4 + w * (LG_T7 + w * (LG_T10 + w * LG_T13)));
            let p3 = LG_T2 + w * (LG_T5 + w * (LG_T8 + w * (LG_T11 + w * LG_T14)));
            let p = z * p1 - (LG_TT - w * (p2 + y * p3));
            r += LG_TF + p;
        } else {
            let p1 = y * (LG_U0 + y * (LG_U1 + y * (LG_U2 + y * (LG_U3 + y * (LG_U4 + y * LG_U5)))));
            let p2 = 1.0 + y * (LG_V1 + y * (LG_V2 + y * (LG_V3 + y * (LG_V4 + y * LG_V5))));
            r += -0.5 * y + p1 / p2;
        }
    } else if ix < 0x40200000 {
        // x < 8.0
        let i = x as i32;
        let y = x - i as f64;
        let p = y * (LG_S0 + y * (LG_S1 + y * (LG_S2 + y * (LG_S3 + y * (LG_S4 + y * (LG_S5 + y * LG_S6))))));
        let q = 1.0 + y * (LG_R1 + y * (LG_R2 + y * (LG_R3 + y * (LG_R4 + y * (LG_R5 + y * LG_R6)))));
        r = 0.5 * y + p / q;
        // lgamma(1+s) = log(s) + lgamma(s): C's switch from case i down to case 3
        if i >= 3 {
            let mut z: f64 = 1.0;
            let mut k = i;
            while k >= 3 {
                z *= y + (k - 1) as f64;
                k -= 1;
            }
            r += log(z);
        }
    } else if ix < 0x43900000 {
        // 8.0 <= x < 2**58
        t = log(x);
        let z = 1.0 / x;
        let y = z * z;
        let w = LG_W0 + z * (LG_W1 + y * (LG_W2 + y * (LG_W3 + y * (LG_W4 + y * (LG_W5 + y * LG_W6)))));
        r = (x - 0.5) * (t - 1.0) + w;
    } else {
        // 2**58 <= x <= inf
        r = x * (log(x) - 1.0);
    }
    if sign {
        r = nadj - r;
    }
    return r;
}

/// log(|gamma(x)|); the sign of gamma(x) goes to `signgam`.
@export("lgamma")
pub fn lgamma(x: f64) f64 {
    let mut s: i32 = 0;
    let r = lgamma_r(x, &mut s);
    unsafe SIGNGAM = s;
    return r;
}

fn sin_pif(x0: f32) f32 {
    // spurious inexact if odd int
    let x = 2.0f32 * (x0 * 0.5f32 - floorf(x0 * 0.5f32)); // x mod 2.0
    let mut n = (x * 4.0f32) as i32;
    n = (n + 1) / 2;
    let mut y = (x - n as f32 * 0.5f32) as f64;
    y *= 3.14159265358979323846;
    if n == 1 {
        return k_cosdf(y);
    }
    if n == 2 {
        return k_sindf(-y);
    }
    if n == 3 {
        return -k_cosdf(y);
    }
    return k_sindf(y);
}

fn lgammaf_r(x0: f32, signgamp: &mut i32) f32 {
    let mut x = x0;
    let u = bitsf(x);
    let mut t: f32 = 0.0f32;
    let mut nadj: f32 = 0.0f32;
    let mut r: f32 = 0.0f32;
    // purge off +-inf, NaN, +-0, tiny and negative arguments
    *signgamp = 1;
    let sign = u >> 31 != 0;
    let ix = u & 0x7fffffff;
    if ix >= 0x7f800000 {
        return x * x;
    }
    if ix < 0x35000000 {
        // |x| < 2**-21, return -log(|x|)
        if sign {
            *signgamp = -1;
            x = -x;
        }
        return -logf(x);
    }
    if sign {
        x = -x;
        t = sin_pif(x);
        if t == 0.0f32 {
            // -integer
            return 1.0f32 / (x - x);
        }
        if t > 0.0f32 {
            *signgamp = -1;
        } else {
            t = -t;
        }
        nadj = logf(LGF_PI / (t * x));
    }
    // purge off 1 and 2
    if ix == 0x3f800000 || ix == 0x40000000 {
        r = 0.0f32;
    } else if ix < 0x40000000 {
        // for x < 2.0
        let mut y: f32 = 0.0f32;
        let mut i: i32 = 0;
        if ix <= 0x3f666666 {
            // lgamma(x) = lgamma(x+1)-log(x)
            r = -logf(x);
            if ix >= 0x3f3b4a20 {
                y = 1.0f32 - x;
                i = 0;
            } else if ix >= 0x3e6d3308 {
                y = x - (LGF_TC - 1.0f32);
                i = 1;
            } else {
                y = x;
                i = 2;
            }
        } else {
            r = 0.0f32;
            if ix >= 0x3fdda618 {
                // [1.7316,2]
                y = 2.0f32 - x;
                i = 0;
            } else if ix >= 0x3F9da620 {
                // [1.23,1.73]
                y = x - LGF_TC;
                i = 1;
            } else {
                y = x - 1.0f32;
                i = 2;
            }
        }
        if i == 0 {
            let z = y * y;
            let p1 = LGF_A0 + z * (LGF_A2 + z * (LGF_A4 + z * (LGF_A6 + z * (LGF_A8 + z * LGF_A10))));
            let p2 = z * (LGF_A1 + z * (LGF_A3 + z * (LGF_A5 + z * (LGF_A7 + z * (LGF_A9 + z * LGF_A11)))));
            let p = y * p1 + p2;
            r += p - 0.5f32 * y;
        } else if i == 1 {
            let z = y * y;
            let w = z * y;
            let p1 = LGF_T0 + w * (LGF_T3 + w * (LGF_T6 + w * (LGF_T9 + w * LGF_T12))); // parallel comp
            let p2 = LGF_T1 + w * (LGF_T4 + w * (LGF_T7 + w * (LGF_T10 + w * LGF_T13)));
            let p3 = LGF_T2 + w * (LGF_T5 + w * (LGF_T8 + w * (LGF_T11 + w * LGF_T14)));
            let p = z * p1 - (LGF_TT - w * (p2 + y * p3));
            r += LGF_TF + p;
        } else {
            let p1 = y * (LGF_U0 + y * (LGF_U1 + y * (LGF_U2 + y * (LGF_U3 + y * (LGF_U4 + y * LGF_U5)))));
            let p2 = 1.0f32 + y * (LGF_V1 + y * (LGF_V2 + y * (LGF_V3 + y * (LGF_V4 + y * LGF_V5))));
            r += -0.5f32 * y + p1 / p2;
        }
    } else if ix < 0x41000000 {
        // x < 8.0
        let i = x as i32;
        let y = x - i as f32;
        let p = y * (LGF_S0 + y * (LGF_S1 + y * (LGF_S2 + y * (LGF_S3 + y * (LGF_S4 + y * (LGF_S5 + y * LGF_S6))))));
        let q = 1.0f32 + y * (LGF_R1 + y * (LGF_R2 + y * (LGF_R3 + y * (LGF_R4 + y * (LGF_R5 + y * LGF_R6)))));
        r = 0.5f32 * y + p / q;
        // lgamma(1+s) = log(s) + lgamma(s): C's switch from case i down to case 3
        if i >= 3 {
            let mut z: f32 = 1.0f32;
            let mut k = i;
            while k >= 3 {
                z *= y + (k - 1) as f32;
                k -= 1;
            }
            r += logf(z);
        }
    } else if ix < 0x5c800000 {
        // 8.0 <= x < 2**58
        t = logf(x);
        let z = 1.0f32 / x;
        let y = z * z;
        let w = LGF_W0 + z * (LGF_W1 + y * (LGF_W2 + y * (LGF_W3 + y * (LGF_W4 + y * (LGF_W5 + y * LGF_W6)))));
        r = (x - 0.5f32) * (t - 1.0f32) + w;
    } else {
        // 2**58 <= x <= inf
        r = x * (logf(x) - 1.0f32);
    }
    if sign {
        r = nadj - r;
    }
    return r;
}

/// log(|gamma(x)|); the sign of gamma(x) goes to `signgam`.
@export("lgammaf")
pub fn lgammaf(x: f32) f32 {
    let mut s: i32 = 0;
    let r = lgammaf_r(x, &mut s);
    unsafe SIGNGAM = s;
    return r;
}

// Lanczos approximation of gamma: gamma(x) ~ S(x) * pow(x + G - 1/2, x - 1/2) / exp(x + G - 1/2), G
// = 6.024680040776729583740234375 (Boost's g), N = 12 terms; S as a rational function.
const GMHALF: f64 = 5.524680040776729583740234375;
const SNUM: [f64; 13] = [
    23531376880.410759688572007674451636754734846804940,
    42919803642.649098768957899047001988850926355848959,
    35711959237.355668049440185451547166705960488635843,
    17921034426.037209699919755754458931112671403265390,
    6039542586.3520280050642916443072979210699388420708,
    1439720407.3117216736632230727949123939715485786772,
    248874557.86205415651146038641322942321632125127801,
    31426415.585400194380614231628318205362874684987640,
    2876370.6289353724412254090516208496135991145378768,
    186056.26539522349504029498971604569928220784236328,
    8071.6720023658162106380029022722506138218516325024,
    210.82427775157934587250973392071336271166969580291,
    2.5066282746310002701649081771338373386264310793408,
];
const SDEN: [f64; 13] = [
    0.0,
    39916800.0,
    120543840.0,
    150917976.0,
    105258076.0,
    45995730.0,
    13339535.0,
    2637558.0,
    357423.0,
    32670.0,
    1925.0,
    66.0,
    1.0,
];
// n! for n in [0, 22]: tgamma(n + 1).
const FACT: [f64; 23] = [
    1.0,
    1.0,
    2.0,
    6.0,
    24.0,
    120.0,
    720.0,
    5040.0,
    40320.0,
    362880.0,
    3628800.0,
    39916800.0,
    479001600.0,
    6227020800.0,
    87178291200.0,
    1307674368000.0,
    20922789888000.0,
    355687428096000.0,
    6402373705728000.0,
    121645100408832000.0,
    2432902008176640000.0,
    51090942171709440000.0,
    1124000727777607680000.0,
];

// S(x) rational function for positive x.
const fn lanczos_s(x: f64) f64 {
    let mut num: f64 = 0.0;
    let mut den: f64 = 0.0;
    // to avoid overflow handle large x differently
    if x < 8.0 {
        let mut i: usize = 13;
        while i > 0 {
            i -= 1;
            num = num * x + unsafe SNUM[i];
            den = den * x + unsafe SDEN[i];
        }
    } else {
        for i in 0..13 {
            num = num / x + unsafe SNUM[i];
            den = den / x + unsafe SDEN[i];
        }
    }
    return num / den;
}

/// The gamma function of x.
@export("tgamma")
pub fn tgamma(x0: f64) f64 {
    let mut x = x0;
    let ui = bits(x);
    let ix = (ui >> 32 & 0x7fffffff) as u32;
    let sign = ui >> 63 != 0;
    // special cases
    if ix >= 0x7ff00000 {
        // tgamma(nan)=nan, tgamma(inf)=inf, tgamma(-inf)=nan with invalid
        return x + INF;
    }
    if ix < 0x3ff - 54 << 20 {
        // |x| < 2^-54: tgamma(x) ~ 1/x, +-0 raises div-by-zero
        return 1.0 / x;
    }
    // integer arguments
    // raise inexact when non-integer
    if x == floor(x) {
        if sign {
            return 0.0 / 0.0;
        }
        if x <= 23.0 {
            return unsafe FACT[x as usize - 1];
        }
    }
    // x >= 172: tgamma(x)=inf with overflow
    // x =< -184: tgamma(x)=+-0 with underflow
    if ix >= 0x40670000 {
        // |x| >= 184
        if sign {
            if floor(x) * 0.5 == floor(x * 0.5) {
                return 0.0;
            }
            return -0.0;
        }
        x *= 0x1p1023;
        return x;
    }
    let absx = if sign {
        -x
    } else {
        x
    };
    // handle the error of x + g - 0.5
    let mut y = absx + GMHALF;
    let mut dy: f64 = 0.0;
    if absx > GMHALF {
        dy = y - absx;
        dy -= GMHALF;
    } else {
        dy = y - GMHALF;
        dy -= absx;
    }
    let mut z = absx - 0.5;
    let mut r = lanczos_s(absx) * exp(-y);
    if x < 0.0 {
        // reflection formula for negative x
        // sinpi(absx) is not 0, integers are already handled
        r = -LG_PI / (sin_pi(absx) * absx * r);
        dy = -dy;
        z = -z;
    }
    r += dy * (GMHALF + 0.5) * r / y;
    z = pow(y, 0.5 * z);
    y = r * z * z;
    return y;
}

/// The gamma function of x.
@export("tgammaf")
pub fn tgammaf(x: f32) f32 {
    return tgamma(x) as f32;
}
