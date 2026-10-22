// wasm's C library (`std::rt::libc`, `std::rt::libm`) against wasi-libc, the C library it replaces: one
// program built with `--target=wasm` on it, and the same program in C built with the wasi-sdk's clang on
// wasi-libc, run under wasmtime and print the same bytes. The first pair: the bits of every math function at
// 300 arguments (`f64` and `f32`), the printf conversions, strtod, strtof, strtoll, strtoull, atoi and
// qsort; the Super-C program's debug binary holds no wasi-libc function (its name section names none). The
// second pair: the scanf family over strings, files and stdin, setlocale and localeconv with UTF-8
// characters, the broken-down time functions, signal and raise, sbrk beside malloc, creat, setvbuf, environ,
// pthread_self and pthread_exit. The test needs a wasi-sdk in WASI_SDK_PATH and wasmtime on the PATH, as the
// wasm lane sets them; without the SDK it returns early.

import std::platform::env;
import std::platform::fs;
import std::platform::process;
import tests::platform_harness as ph;
import tools::std_packages::files as sfiles;
import tools::std_packages::scan as sscan;

const PROGRAM: str = M"(
extern "C" "math.h" {
    fn sqrt(x: f64) f64;
    fn sqrtf(x: f32) f32;
    fn floor(x: f64) f64;
    fn floorf(x: f32) f32;
    fn ceil(x: f64) f64;
    fn ceilf(x: f32) f32;
    fn trunc(x: f64) f64;
    fn truncf(x: f32) f32;
    fn rint(x: f64) f64;
    fn rintf(x: f32) f32;
    fn nearbyint(x: f64) f64;
    fn nearbyintf(x: f32) f32;
    fn fabs(x: f64) f64;
    fn fabsf(x: f32) f32;
    fn round(x: f64) f64;
    fn roundf(x: f32) f32;
    fn exp(x: f64) f64;
    fn expf(x: f32) f32;
    fn exp2(x: f64) f64;
    fn exp2f(x: f32) f32;
    fn expm1(x: f64) f64;
    fn expm1f(x: f32) f32;
    fn log(x: f64) f64;
    fn logf(x: f32) f32;
    fn log2(x: f64) f64;
    fn log2f(x: f32) f32;
    fn log10(x: f64) f64;
    fn log10f(x: f32) f32;
    fn log1p(x: f64) f64;
    fn log1pf(x: f32) f32;
    fn sin(x: f64) f64;
    fn sinf(x: f32) f32;
    fn cos(x: f64) f64;
    fn cosf(x: f32) f32;
    fn tan(x: f64) f64;
    fn tanf(x: f32) f32;
    fn asin(x: f64) f64;
    fn asinf(x: f32) f32;
    fn acos(x: f64) f64;
    fn acosf(x: f32) f32;
    fn atan(x: f64) f64;
    fn atanf(x: f32) f32;
    fn sinh(x: f64) f64;
    fn sinhf(x: f32) f32;
    fn cosh(x: f64) f64;
    fn coshf(x: f32) f32;
    fn tanh(x: f64) f64;
    fn tanhf(x: f32) f32;
    fn asinh(x: f64) f64;
    fn asinhf(x: f32) f32;
    fn acosh(x: f64) f64;
    fn acoshf(x: f32) f32;
    fn atanh(x: f64) f64;
    fn atanhf(x: f32) f32;
    fn cbrt(x: f64) f64;
    fn cbrtf(x: f32) f32;
    fn erf(x: f64) f64;
    fn erff(x: f32) f32;
    fn tgamma(x: f64) f64;
    fn tgammaf(x: f32) f32;
    fn lgamma(x: f64) f64;
    fn lgammaf(x: f32) f32;
    fn copysign(x: f64, y: f64) f64;
    fn copysignf(x: f32, y: f32) f32;
    fn fmod(x: f64, y: f64) f64;
    fn fmodf(x: f32, y: f32) f32;
    fn remainder(x: f64, y: f64) f64;
    fn remainderf(x: f32, y: f32) f32;
    fn fmin(x: f64, y: f64) f64;
    fn fminf(x: f32, y: f32) f32;
    fn fmax(x: f64, y: f64) f64;
    fn fmaxf(x: f32, y: f32) f32;
    fn pow(x: f64, y: f64) f64;
    fn powf(x: f32, y: f32) f32;
    fn atan2(x: f64, y: f64) f64;
    fn atan2f(x: f32, y: f32) f32;
    fn hypot(x: f64, y: f64) f64;
    fn hypotf(x: f32, y: f32) f32;
    fn fma(x: f64, y: f64, z: f64) f64;
    fn fmaf(x: f32, y: f32, z: f32) f32;
    fn scalbn(x: f64, n: i32) f64;
    fn remquo(x: f64, y: f64, q: *mut i32) f64;
}

extern "C" "stdio.h" {
    fn printf(fmt: *const char, ...) i32;
    fn snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32;
}

extern "C" "stdlib.h" {
    fn strtod(s: *const char, end: *mut *mut char) f64;
    fn strtof(s: *const char, end: *mut *mut char) f32;
    fn strtoll(s: *const char, end: *mut *mut char, base: i32) i64;
    fn strtoull(s: *const char, end: *mut *mut char, base: i32) u64;
    fn atoi(s: *const char) i32;
    fn qsort(base: *mut void, n: usize, size: usize, cmp: fn(*const void, *const void) i32);
}

extern "C" "errno.h" {
    @import("errno")
    @thread_local
    static mut errno: i32;
}

union B64 {
    pub f: f64,
    pub u: u64,
}

union B32 {
    pub f: f32,
    pub u: u32,
}

static mut ST: u64 = 0x9e3779b97f4a7c15;

fn rnd() u64 {
    unsafe ST = (unsafe ST).wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return unsafe ST;
}

fn gd(i: i32) f64 {
    let r = rnd();
    let u = (r >> 11) as f64 * 0x1p-53;
    return switch i % 5 {
        0 => {
            let b = B64 { u: r };
            b.f;
        },
        1 => u * 20.0 - 10.0,
        2 => u * 2000.0 - 1000.0,
        3 => u * 2.0 - 1.0,
        _ => (u - 0.5) * 1e20,
    };
}

fn gf(i: i32) f32 {
    let r = rnd();
    let u = ((r >> 40) as f64 * 0x1p-24) as f32;
    return switch i % 5 {
        0 => {
            let b = B32 { u: (r >> 32) as u32 };
            b.f;
        },
        1 => u * 20.0f32 - 10.0f32,
        2 => u * 200.0f32 - 100.0f32,
        3 => u * 2.0f32 - 1.0f32,
        _ => u * 1e5f32 - 5e4f32,
    };
}

fn bd(d: f64) u64 {
    let b = B64 { f: d };
    return b.u;
}

fn bf(f: f32) u32 {
    let b = B32 { f: f };
    return b.u;
}

fn u1(k: i32, x: f64) f64 {
    return unsafe switch k {
        0 => sqrt(x),
        1 => floor(x),
        2 => ceil(x),
        3 => trunc(x),
        4 => rint(x),
        5 => nearbyint(x),
        6 => fabs(x),
        7 => round(x),
        8 => exp(x),
        9 => exp2(x),
        10 => expm1(x),
        11 => log(x),
        12 => log2(x),
        13 => log10(x),
        14 => log1p(x),
        15 => sin(x),
        16 => cos(x),
        17 => tan(x),
        18 => asin(x),
        19 => acos(x),
        20 => atan(x),
        21 => sinh(x),
        22 => cosh(x),
        23 => tanh(x),
        24 => asinh(x),
        25 => acosh(x),
        26 => atanh(x),
        27 => cbrt(x),
        28 => erf(x),
        29 => tgamma(x),
        30 => lgamma(x),
        _ => 0.0,
    };
}

fn u1f(k: i32, x: f32) f32 {
    return unsafe switch k {
        0 => sqrtf(x),
        1 => floorf(x),
        2 => ceilf(x),
        3 => truncf(x),
        4 => rintf(x),
        5 => nearbyintf(x),
        6 => fabsf(x),
        7 => roundf(x),
        8 => expf(x),
        9 => exp2f(x),
        10 => expm1f(x),
        11 => logf(x),
        12 => log2f(x),
        13 => log10f(x),
        14 => log1pf(x),
        15 => sinf(x),
        16 => cosf(x),
        17 => tanf(x),
        18 => asinf(x),
        19 => acosf(x),
        20 => atanf(x),
        21 => sinhf(x),
        22 => coshf(x),
        23 => tanhf(x),
        24 => asinhf(x),
        25 => acoshf(x),
        26 => atanhf(x),
        27 => cbrtf(x),
        28 => erff(x),
        29 => tgammaf(x),
        30 => lgammaf(x),
        _ => 0.0f32,
    };
}

fn b2(k: i32, x: f64, y: f64) f64 {
    return unsafe switch k {
        0 => copysign(x, y),
        1 => fmod(x, y),
        2 => remainder(x, y),
        3 => fmin(x, y),
        4 => fmax(x, y),
        5 => pow(x, y),
        6 => atan2(x, y),
        7 => hypot(x, y),
        _ => 0.0,
    };
}

fn b2f(k: i32, x: f32, y: f32) f32 {
    return unsafe switch k {
        0 => copysignf(x, y),
        1 => fmodf(x, y),
        2 => remainderf(x, y),
        3 => fminf(x, y),
        4 => fmaxf(x, y),
        5 => powf(x, y),
        6 => atan2f(x, y),
        7 => hypotf(x, y),
        _ => 0.0f32,
    };
}

const FD: [str; 19] = [
    "%.17g",
    "%g",
    "%e",
    "%.0e",
    "%f",
    "%.0f",
    "%.10f",
    "%a",
    "%.3a",
    "%A",
    "%+12.4g",
    "%-15.6e|",
    "%015.3f",
    "%#g",
    "%#.0f",
    "% .5g",
    "%.30f",
    "%.40e",
    "%G",
];

const FI: [str; 15] = [
    "%d",
    "%5d",
    "%-5d|",
    "%05d",
    "%+d",
    "% d",
    "%x",
    "%X",
    "%#x",
    "%o",
    "%#o",
    "%u",
    "%.3d",
    "%8.3d",
    "%p",
];

const FL: [str; 5] = [
    "%lld",
    "%llx",
    "%llu",
    "%20lld",
    "%-20llx|",
];

const STRS: [str; 32] = [
    "0",
    "-1",
    "1e10",
    "1.5e-300",
    "4.9e-324",
    "2.4703282292062327e-324",
    "2.4703282292062328e-324",
    "1.7976931348623157e308",
    "1.7976931348623159e308",
    "inf",
    "-INF",
    "nan",
    "NaN(123)",
    "0x1p-1074",
    "0x1.fffffffffffffp1023",
    "  12.5abc",
    "1e",
    "1e+",
    "-.5",
    ".e1",
    "123456789012345678901234567890",
    "0.30000000000000004",
    "3.14159265358979323846264338327950288419716939937510",
    "1e-400",
    "1e400",
    "-0",
    "0x",
    "0x.8p1",
    "infinity",
    "infinit",
    "9007199254740993",
    "2.2250738585072011e-308",
];

const IS: [str; 15] = [
    "0",
    "123",
    "-123",
    "0x1F",
    "0777",
    "  +42xyz",
    "9223372036854775807",
    "9223372036854775808",
    "-9223372036854775809",
    "18446744073709551615",
    "18446744073709551616",
    "z",
    "0x",
    "-0x10",
    "1234567890123456789012",
];

fn cmpi(a: *const void, b: *const void) i32 {
    let x = unsafe *(a as *const i32);
    let y = unsafe *(b as *const i32);
    return (x > y) as i32 - (x < y) as i32;
}

fn cs(s: str) *const char {
    return s.ptr() as *const char;
}

fn main() i32 {
    let mut buf = [0 as char; 512];
    let mut end: *mut char = null;
    for k in 0..31 {
        for i in 0..300 {
            let x = gd(i);
            unsafe printf(cs("u%d %d %016llx\n"), k, i, bd(u1(k, x)));
            let f = gf(i);
            unsafe printf(cs("uf%d %d %08x\n"), k, i, bf(u1f(k, f)));
        }
    }
    for k in 0..8 {
        for i in 0..300 {
            let x = gd(i);
            let y = gd(i + 1);
            unsafe printf(cs("b%d %d %016llx\n"), k, i, bd(b2(k, x, y)));
            let f = gf(i);
            let g = gf(i + 1);
            unsafe printf(cs("bf%d %d %08x\n"), k, i, bf(b2f(k, f, g)));
        }
    }
    for i in 0..300 {
        let x = gd(i);
        let y = gd(i + 1);
        let z = gd(i + 2);
        let f = gf(i);
        let g = gf(i + 1);
        let h = gf(i + 2);
        let n = (rnd() % 4200) as i32 - 2100;
        let mut q: i32 = 0;
        let r = unsafe remquo(x, y, &mut q);
        unsafe printf(
            cs("t %d %016llx %08x %016llx %016llx %d\n"),
            i,
            bd(unsafe fma(x, y, z)),
            bf(unsafe fmaf(f, g, h)),
            bd(unsafe scalbn(x, n)),
            bd(r),
            q,
        );
    }
    for k in 0..19 {
        for i in 0..60 {
            let n = unsafe snprintf(&mut buf[0], 512, cs(unsafe FD[k]), gd(i));
            unsafe printf(cs("d%d %d %d %s\n"), k, i, n, &buf[0]);
        }
    }
    for k in 0..15 {
        for i in 0..60 {
            let mut x = rnd() as i32;
            if i % 3 == 0 {
                x %= 1000;
            }
            let n = if k == 14 {
                let p = if i % 2 == 0 {
                    0usize;
                } else {
                    x as u32 as usize;
                };
                unsafe snprintf(&mut buf[0], 512, cs(unsafe FI[k]), p as *const void);
            } else {
                unsafe snprintf(&mut buf[0], 512, cs(unsafe FI[k]), x);
            };
            unsafe printf(cs("i%d %d %d %s\n"), k, i, n, &buf[0]);
        }
    }
    for k in 0..5 {
        for i in 0..60 {
            let n = unsafe snprintf(&mut buf[0], 512, cs(unsafe FL[k]), rnd() as i64);
            unsafe printf(cs("l%d %d %d %s\n"), k, i, n, &buf[0]);
        }
    }
    for i in 0..12 {
        for j in 0..20 {
            unsafe buf[j] = '#' as char;
        }
        let n = unsafe snprintf(&mut buf[0], i as usize, cs("%s-%d|%5.2s|%c%%"), cs("hello"), 12345, cs("abc"), 65);
        buf[19] = 0 as char;
        unsafe printf(cs("s %d %d %s\n"), i, n, &buf[0]);
    }
    for i in 0..32 {
        let p = cs(unsafe STRS[i]);
        unsafe errno = 0;
        let d = unsafe strtod(p, &mut end);
        let e = unsafe errno;
        let f = unsafe strtof(p, null);
        unsafe printf(cs("f %d %a %d %d %a\n"), i, d, (end as usize - p as usize) as i32, e, f as f64);
    }
    for i in 0..1000 {
        unsafe snprintf(&mut buf[0], 512, cs("%.*g"), (rnd() % 20) as i32 + 1, gd(i));
        unsafe printf(cs("r %d %s %a\n"), i, &buf[0], unsafe strtod(&buf[0], null));
    }
    for i in 0..15 {
        let p = cs(unsafe IS[i]);
        unsafe errno = 0;
        let a = unsafe strtoll(p, &mut end, 0);
        let e1 = unsafe errno;
        let o1 = (end as usize - p as usize) as i32;
        unsafe errno = 0;
        let b = unsafe strtoull(p, &mut end, 0);
        let e2 = unsafe errno;
        let o2 = (end as usize - p as usize) as i32;
        unsafe printf(cs("n %d %lld %d %d %llu %d %d %d\n"), i, a, e1, o1, b, e2, o2, unsafe atoi(p));
    }
    let mut a = [0i32; 3000];
    for i in 0..3000 {
        unsafe a[i] = (rnd() % 1000) as i32;
    }
    unsafe qsort(&mut a[0] as *mut i32, 3000, 4, cmpi);
    let mut h: u64 = 0;
    for i in 0..3000 {
        h = h.wrapping_mul(31).wrapping_add(unsafe a[i] as u32);
    }
    unsafe printf(cs("q %llu\n"), h);
    return 0;
}
)";

const REFERENCE: str = M"(
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t st = 0x9e3779b97f4a7c15ULL;
static uint64_t rnd(void) { st = st * 6364136223846793005ULL + 1442695040888963407ULL; return st; }
static double gd(int i) { uint64_t r = rnd(); double u = (double)(r >> 11) * 0x1p-53; double d; switch (i % 5) { case 0: memcpy(&d, &r, 8); return d; case 1: return u * 20 - 10; case 2: return u * 2000 - 1000; case 3: return u * 2 - 1; default: return (u - 0.5) * 1e20; } }
static float gf(int i) { uint64_t r = rnd(); float u = (float)((r >> 40) * 0x1p-24); float f; uint32_t b = (uint32_t)(r >> 32); switch (i % 5) { case 0: memcpy(&f, &b, 4); return f; case 1: return u * 20 - 10; case 2: return u * 200 - 100; case 3: return u * 2 - 1; default: return u * 1e5f - 5e4f; } }
static uint64_t bd(double d) { uint64_t b; memcpy(&b, &d, 8); return b; }
static uint32_t bf(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static double u1(int k, double x) {
  switch (k) {
  case 0: return sqrt(x);
  case 1: return floor(x);
  case 2: return ceil(x);
  case 3: return trunc(x);
  case 4: return rint(x);
  case 5: return nearbyint(x);
  case 6: return fabs(x);
  case 7: return round(x);
  case 8: return exp(x);
  case 9: return exp2(x);
  case 10: return expm1(x);
  case 11: return log(x);
  case 12: return log2(x);
  case 13: return log10(x);
  case 14: return log1p(x);
  case 15: return sin(x);
  case 16: return cos(x);
  case 17: return tan(x);
  case 18: return asin(x);
  case 19: return acos(x);
  case 20: return atan(x);
  case 21: return sinh(x);
  case 22: return cosh(x);
  case 23: return tanh(x);
  case 24: return asinh(x);
  case 25: return acosh(x);
  case 26: return atanh(x);
  case 27: return cbrt(x);
  case 28: return erf(x);
  case 29: return tgamma(x);
  case 30: return lgamma(x);
  }
  return 0;
}
static float u1f(int k, float x) {
  switch (k) {
  case 0: return sqrtf(x);
  case 1: return floorf(x);
  case 2: return ceilf(x);
  case 3: return truncf(x);
  case 4: return rintf(x);
  case 5: return nearbyintf(x);
  case 6: return fabsf(x);
  case 7: return roundf(x);
  case 8: return expf(x);
  case 9: return exp2f(x);
  case 10: return expm1f(x);
  case 11: return logf(x);
  case 12: return log2f(x);
  case 13: return log10f(x);
  case 14: return log1pf(x);
  case 15: return sinf(x);
  case 16: return cosf(x);
  case 17: return tanf(x);
  case 18: return asinf(x);
  case 19: return acosf(x);
  case 20: return atanf(x);
  case 21: return sinhf(x);
  case 22: return coshf(x);
  case 23: return tanhf(x);
  case 24: return asinhf(x);
  case 25: return acoshf(x);
  case 26: return atanhf(x);
  case 27: return cbrtf(x);
  case 28: return erff(x);
  case 29: return tgammaf(x);
  case 30: return lgammaf(x);
  }
  return 0;
}
static double b2(int k, double x, double y) {
  switch (k) {
  case 0: return copysign(x, y);
  case 1: return fmod(x, y);
  case 2: return remainder(x, y);
  case 3: return fmin(x, y);
  case 4: return fmax(x, y);
  case 5: return pow(x, y);
  case 6: return atan2(x, y);
  case 7: return hypot(x, y);
  }
  return 0;
}
static float b2f(int k, float x, float y) {
  switch (k) {
  case 0: return copysignf(x, y);
  case 1: return fmodf(x, y);
  case 2: return remainderf(x, y);
  case 3: return fminf(x, y);
  case 4: return fmaxf(x, y);
  case 5: return powf(x, y);
  case 6: return atan2f(x, y);
  case 7: return hypotf(x, y);
  }
  return 0;
}
static const char *FD[] = {"%.17g", "%g", "%e", "%.0e", "%f", "%.0f", "%.10f", "%a", "%.3a", "%A", "%+12.4g", "%-15.6e|", "%015.3f", "%#g", "%#.0f", "% .5g", "%.30f", "%.40e", "%G"};
static const char *FI[] = {"%d", "%5d", "%-5d|", "%05d", "%+d", "% d", "%x", "%X", "%#x", "%o", "%#o", "%u", "%.3d", "%8.3d", "%p"};
static const char *FL[] = {"%lld", "%llx", "%llu", "%20lld", "%-20llx|"};
static const char *STRS[] = {"0", "-1", "1e10", "1.5e-300", "4.9e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "1.7976931348623157e308", "1.7976931348623159e308", "inf", "-INF", "nan", "NaN(123)", "0x1p-1074", "0x1.fffffffffffffp1023", "  12.5abc", "1e", "1e+", "-.5", ".e1", "123456789012345678901234567890", "0.30000000000000004", "3.14159265358979323846264338327950288419716939937510", "1e-400", "1e400", "-0", "0x", "0x.8p1", "infinity", "infinit", "9007199254740993", "2.2250738585072011e-308"};
static const char *IS[] = {"0", "123", "-123", "0x1F", "0777", "  +42xyz", "9223372036854775807", "9223372036854775808", "-9223372036854775809", "18446744073709551615", "18446744073709551616", "z", "0x", "-0x10", "1234567890123456789012"};
static int cmpi(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
int main(void) {
  char buf[512];
  char *end;
  for (int k = 0; k < 31; k++) {
    for (int i = 0; i < 300; i++) {
      double x = gd(i);
      printf("u%d %d %016llx\n", k, i, (unsigned long long)bd(u1(k, x)));
      float f = gf(i);
      printf("uf%d %d %08x\n", k, i, (unsigned)bf(u1f(k, f)));
    }
  }
  for (int k = 0; k < 8; k++) {
    for (int i = 0; i < 300; i++) {
      double x = gd(i), y = gd(i + 1);
      printf("b%d %d %016llx\n", k, i, (unsigned long long)bd(b2(k, x, y)));
      float f = gf(i), g = gf(i + 1);
      printf("bf%d %d %08x\n", k, i, (unsigned)bf(b2f(k, f, g)));
    }
  }
  for (int i = 0; i < 300; i++) {
    double x = gd(i), y = gd(i + 1), z = gd(i + 2);
    float f = gf(i), g = gf(i + 1), h = gf(i + 2);
    int n = (int)(rnd() % 4200) - 2100;
    int q = 0;
    double r = remquo(x, y, &q);
    printf("t %d %016llx %08x %016llx %016llx %d\n", i, (unsigned long long)bd(fma(x, y, z)), (unsigned)bf(fmaf(f, g, h)), (unsigned long long)bd(scalbn(x, n)), (unsigned long long)bd(r), q);
  }
  for (int k = 0; k < 19; k++) {
    for (int i = 0; i < 60; i++) {
      int n = snprintf(buf, sizeof buf, FD[k], gd(i));
      printf("d%d %d %d %s\n", k, i, n, buf);
    }
  }
  for (int k = 0; k < 15; k++) {
    for (int i = 0; i < 60; i++) {
      int x = (int)rnd();
      if (i % 3 == 0) x %= 1000;
      int n = k == 14 ? snprintf(buf, sizeof buf, FI[k], i % 2 == 0 ? (void *)0 : (void *)(uintptr_t)x) : snprintf(buf, sizeof buf, FI[k], x);
      printf("i%d %d %d %s\n", k, i, n, buf);
    }
  }
  for (int k = 0; k < 5; k++) {
    for (int i = 0; i < 60; i++) {
      int n = snprintf(buf, sizeof buf, FL[k], (long long)rnd());
      printf("l%d %d %d %s\n", k, i, n, buf);
    }
  }
  for (int i = 0; i < 12; i++) {
    memset(buf, '#', 20);
    int n = snprintf(buf, (size_t)i, "%s-%d|%5.2s|%c%%", "hello", 12345, "abc", 65);
    buf[19] = 0;
    printf("s %d %d %s\n", i, n, buf);
  }
  for (int i = 0; i < 32; i++) {
    errno = 0;
    double d = strtod(STRS[i], &end);
    int e = errno;
    printf("f %d %a %d %d %a\n", i, d, (int)(end - STRS[i]), e, (double)strtof(STRS[i], 0));
  }
  for (int i = 0; i < 1000; i++) {
    snprintf(buf, sizeof buf, "%.*g", (int)(rnd() % 20) + 1, gd(i));
    printf("r %d %s %a\n", i, buf, strtod(buf, 0));
  }
  for (int i = 0; i < 15; i++) {
    errno = 0;
    long long a = strtoll(IS[i], &end, 0);
    int e1 = errno, o1 = (int)(end - IS[i]);
    errno = 0;
    unsigned long long b = strtoull(IS[i], &end, 0);
    int e2 = errno, o2 = (int)(end - IS[i]);
    printf("n %d %lld %d %d %llu %d %d %d\n", i, a, e1, o1, b, e2, o2, atoi(IS[i]));
  }
  static int a[3000];
  for (int i = 0; i < 3000; i++) a[i] = (int)(rnd() % 1000);
  qsort(a, 3000, sizeof(int), cmpi);
  unsigned long long h = 0;
  for (int i = 0; i < 3000; i++) h = h * 31 + (unsigned)a[i];
  printf("q %llu\n", h);
  return 0;
}
)";

// Run `argv` in `dir` with its output in file `out` and, when `input` is not empty, file `input` on its stdin;
// whether it exits with 0. A failure prints the output.
@platform(macos | linux)
fn run(argv: []str, dir: str, out: str, input: str) bool {
    let mut c = process::Command::new(argv);
    c.cwd = Option::<str>::Some(dir);
    if input.len() != 0 {
        c.stdin = process::Redirect::Path(input);
    }
    c.stdout = process::Redirect::Path(out);
    c.stderr = process::Redirect::Stdout;
    let st = process::spawn(c).unwrap().wait().unwrap();
    if st != process::ExitStatus::Code(0) {
        eprintln("{}", ph::read_text(out).as_str());
        return false;
    }
    return true;
}

// Build `program` (`prog`) with the compiler under test and `reference` (`ref.wasm`) with the wasi-sdk's clang
// and `cflags` in a scratch directory, run both under wasmtime with `wasmtime` before the module and `input`
// (when not empty) on stdin, and assert they print the same bytes, more than `min` of them. The scratch.
@platform(macos | linux)
fn compare(program: str, reference: str, cflags: []str, wasmtime: []str, input: str, min: usize) ph::Scratch {
    let sdk = env::get("WASI_SDK_PATH").unwrap().unwrap_or(String::new());
    let s = ph::scratch();
    ph::write_text(s.at("main.spc").as_str(), program);
    ph::write_text(s.at("ref.c").as_str(), reference);
    ph::write_text(s.at("build.toml").as_str(), "bin = \"prog\"\nroot = \"main.spc\"\n");
    let named = env::get("SUPERC").unwrap().unwrap_or(String::from_str("./super-c"));
    let superc = fs::realpath(named.as_str()).unwrap();
    let mut transpiler = String::from_str("--transpiler=");
    transpiler.push_string(&superc);
    let mut argv = Vector::<str>::new();
    argv.push(superc.as_str());
    argv.push("build");
    argv.push("--target=wasm");
    // On the wasm lane SUPERC is the wasm compiler's wrapper: the build engine runs natively and hands
    // the transpile step to it.
    if superc.contains("wasm") {
        argv.push(transpiler.as_str());
    }
    argv.push("-o");
    argv.push("prog");
    assert(run(argv[0..argv.len()], s.dir.as_str(), s.at("build.log").as_str(), ""), "the program builds");
    let clang = format("{}/bin/clang", sdk.as_str());
    let mut cc = Vector::<str>::new();
    cc.push(clang.as_str());
    cc.push("--target=wasm32-wasip1");
    cc.push("-O1");
    for f in cflags {
        cc.push(f);
    }
    cc.push("ref.c");
    cc.push("-o");
    cc.push("ref.wasm");
    cc.push("-lm");
    assert(run(cc[0..cc.len()], s.dir.as_str(), s.at("cc.log").as_str(), ""), "the reference builds");
    let inp = if input.len() == 0 {
        String::new();
    } else {
        s.at("in.txt");
    };
    if input.len() != 0 {
        ph::write_text(inp.as_str(), input);
    }
    for m in ["prog", "ref.wasm"] {
        let mut w = Vector::<str>::new();
        w.push("wasmtime");
        for a in wasmtime {
            w.push(a);
        }
        w.push(m);
        let out = format("{}.out", m);
        assert(run(w[0..w.len()], s.dir.as_str(), s.at(out.as_str()).as_str(), inp.as_str()), "the module runs");
    }
    let got = ph::read_text(s.at("prog.out").as_str());
    let want = ph::read_text(s.at("ref.wasm.out").as_str());
    assert(got.len() > min, "the program prints every line");
    assert(got.eq_str(want.as_str()), "the outputs match");
    return s;
}

@platform(macos | linux)
@test(timeout = 600)
fn wasm_libc_matches_wasi_libc() {
    if env::get("WASI_SDK_PATH").unwrap().unwrap_or(String::new()).len() == 0 {
        return;
    }
    let none: [str; 0] = [];
    let s = compare(PROGRAM, REFERENCE, none, none, "", 500000);
    let bin = ph::read_text(s.at("prog").as_str());
    assert(bin.as_str().contains("sc_stdio_stream"), "the name section names the C library's functions");
    assert(
        !bin.as_str().contains("__wasilibc_populate_preopens") && !bin.as_str().contains("__stdio_write"),
        "no wasi-libc function",
    );
}

const PROGRAM2: str = M"(
import stdio;
import locale;
import fcntl;

extern "C" "math.h" {
    fn erfc(x: f64) f64;
    fn erfcf(x: f32) f32;
    fn frexp(x: f64, e: *mut i32) f64;
    fn frexpf(x: f32, e: *mut i32) f32;
    fn modf(x: f64, ip: *mut f64) f64;
    fn modff(x: f32, ip: *mut f32) f32;
    fn nextafter(x: f64, y: f64) f64;
    fn nextafterf(x: f32, y: f32) f32;
}

extern "C" "stdio.h" {
    fn printf(fmt: *const char, ...) i32;
    fn snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32;
    fn setvbuf(f: *mut stdio::FILE, buf: *mut char, mode: i32, size: usize) i32;
    const _IOFBF: i32;
    const _IOLBF: i32;
    const _IONBF: i32;
}

extern "C" "stdlib.h" {
    fn malloc(n: usize) *mut void;
    fn free(p: *mut void);
    const MB_CUR_MAX: usize;
}

extern "C" "string.h" {
    fn strsignal(sig: i32) *mut char;
}

extern "C" "errno.h" {
    @import("errno")
    @thread_local
    static mut errno: i32;
}

extern "C" "unistd.h" {
    fn sbrk(inc: isize) *mut void;
    fn write(fd: i32, buf: *const void, n: usize) isize;
    fn close(fd: i32) i32;
}

extern "C" {
    static mut environ: *mut *mut char;
    fn pthread_exit(r: *mut void);
}

extern "C" "pthread.h" {
    @layout(sizeof(usize), sizeof(usize))
    type pthread_t;
    fn pthread_self() pthread_t;
    fn pthread_equal(a: pthread_t, b: pthread_t) i32;
}

extern "C" "signal.h" {
    fn signal(sig: i32, f: fn(i32)) fn(i32);
    fn raise(sig: i32) i32;
    @import("__SIG_IGN")
    fn sig_ign(sig: i32);
    @import("__SIG_ERR")
    fn sig_err(sig: i32);
    const SIGUSR1: i32;
    const SIGKILL: i32;
    const SIGCHLD: i32;
    const SIGCONT: i32;
}

extern "C" "locale.h" {
    struct lconv {
        pub decimal_point: *mut char,
        pub thousands_sep: *mut char,
        pub grouping: *mut char,
        pub int_curr_symbol: *mut char,
        pub currency_symbol: *mut char,
        pub mon_decimal_point: *mut char,
        pub mon_thousands_sep: *mut char,
        pub mon_grouping: *mut char,
        pub positive_sign: *mut char,
        pub negative_sign: *mut char,
        pub int_frac_digits: char,
        pub frac_digits: char,
        pub p_cs_precedes: char,
        pub p_sep_by_space: char,
        pub n_cs_precedes: char,
        pub n_sep_by_space: char,
        pub p_sign_posn: char,
        pub n_sign_posn: char,
        pub int_p_cs_precedes: char,
        pub int_p_sep_by_space: char,
        pub int_n_cs_precedes: char,
        pub int_n_sep_by_space: char,
        pub int_p_sign_posn: char,
        pub int_n_sign_posn: char,
    }
}

extern "C" "time.h" {
    struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
        @import("__tm_gmtoff")
        pub gmtoff: i32,
        @import("__tm_zone")
        pub zone: *const char,
        @import("__tm_nsec")
        pub nsec: i32,
    }
    fn gmtime(t: *const i64) *mut tm;
    fn localtime(t: *const i64) *mut tm;
    fn mktime(t: *mut tm) i64;
    fn strftime(s: *mut char, n: usize, f: *const char, t: *const tm) usize;
}

union B64 {
    pub f: f64,
    pub u: u64,
}

union B32 {
    pub f: f32,
    pub u: u32,
}

static mut ST: u64 = 0x2545f4914f6cdd1d;

fn rnd() u64 {
    unsafe ST = (unsafe ST).wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return unsafe ST;
}

fn gd(i: i32) f64 {
    let r = rnd();
    let u = (r >> 11) as f64 * 0x1p-53;
    return switch i % 5 {
        0 => B64 { u: r }.f,
        1 => u * 20.0 - 10.0,
        2 => u * 2000.0 - 1000.0,
        3 => u * 2.0 - 1.0,
        _ => (u - 0.5) * 1e20,
    };
}

fn gf(i: i32) f32 {
    let r = rnd();
    let u = ((r >> 40) as f64 * 0x1p-24) as f32;
    return switch i % 5 {
        0 => B32 { u: (r >> 32) as u32 }.f,
        1 => u * 20.0f32 - 10.0f32,
        2 => u * 200.0f32 - 100.0f32,
        3 => u * 2.0f32 - 1.0f32,
        _ => u * 1e5f32 - 5e4f32,
    };
}

fn bd(d: f64) u64 {
    return B64 { f: d }.u;
}

fn bf(f: f32) u32 {
    return B32 { f: f }.u;
}

fn cs(s: str) *const char {
    return s.ptr() as *const char;
}

fn on_usr(s: i32) {
    unsafe printf(cs("H %d\n"), s);
}

const TS: [str; 3] = [
    "%a|%A|%b|%B|%c|%C|%d|%D|%e|%F|%g|%G|%h|%H|%I|%j|%m|%M|%n|%p|%r|%R|%s|%S|%t|%T|%u|%U|%V|%w|%W|%x|%X|%y|%Y|%z|%Z|%%",
    "%-d|%_d|%0e|%+4Y|%10C|%+5G|%Ey|%Od|%-j|%_H|%+Y|%3Y|%+3C",
    "%Y-%m%q-%d",
];
const TT: [i64; 20] = [
    0,
    1,
    -1,
    86399,
    86400,
    951782400,
    1709210096,
    -2208988800,
    253402300799,
    253402300800,
    67767976233532799,
    67768036191676800,
    -67768040609740800,
    -67768040609740801,
    1230768000,
    1262217600,
    1293753600,
    1104537600,
    1136073600,
    -62167219200,
];

fn pt(k: str, i: i32, t: *const tm) {
    if t == null {
        unsafe printf(cs("%s %d null %d\n"), cs(k), i, unsafe errno);
        return;
    }
    let m = unsafe &*t;
    unsafe printf(
        cs("%s %d %d %d %d %d %d %d %d %d %d %d\n"),
        cs(k),
        i,
        m.tm_sec,
        m.tm_min,
        m.tm_hour,
        m.tm_mday,
        m.tm_mon,
        m.tm_year,
        m.tm_wday,
        m.tm_yday,
        m.tm_isdst,
        m.gmtoff,
    );
}

fn ps(k: str, s: *const char) {
    unsafe printf(
        cs("%s %s\n"),
        cs(k),
        if s == null {
            cs("(null)");
        } else {
            s;
        },
    );
}

fn tm0() tm {
    return tm {
        tm_sec: 0,
        tm_min: 0,
        tm_hour: 0,
        tm_mday: 0,
        tm_mon: 0,
        tm_year: 0,
        tm_wday: 0,
        tm_yday: 0,
        tm_isdst: 0,
        gmtoff: 0,
        zone: null,
        nsec: 0,
    };
}

fn main() i32 {
    let mut buf = [0 as char; 512];
    let b = &mut buf[0] as *mut char;
    for i in 0..300 {
        let x = gd(i);
        let y = gd(i + 1);
        let f = gf(i);
        let g = gf(i + 1);
        let mut e1: i32 = 0;
        let mut e2: i32 = 0;
        let mut ip: f64 = 0.0;
        let mut ipf: f32 = 0.0f32;
        let fr = unsafe frexp(x, &mut e1);
        let frf = unsafe frexpf(f, &mut e2);
        let mf = unsafe modf(x, &mut ip);
        let mff = unsafe modff(f, &mut ipf);
        unsafe printf(
            cs("m %d %016llx %08x %016llx %d %08x %d %016llx %016llx %08x %08x %016llx %08x\n"),
            i,
            bd(unsafe erfc(x)),
            bf(unsafe erfcf(f)),
            bd(fr),
            e1,
            bf(frf),
            e2,
            bd(mf),
            bd(ip),
            bf(mff),
            bf(ipf),
            bd(unsafe nextafter(x, y)),
            bf(unsafe nextafterf(f, g)),
        );
        unsafe printf(cs("m2 %d %016llx %016llx %08x\n"), i, bd(unsafe erfc(x * 1e-3)), bd(unsafe nextafter(x, x)), bf(unsafe erfcf(f * 1e-2f32)));
    }
    scans();
    ps("L1", unsafe locale::setlocale(locale::LC_ALL, null));
    unsafe printf(cs("L2 %zu\n"), MB_CUR_MAX);
    ps("L3", unsafe locale::setlocale(locale::LC_CTYPE, cs("C.UTF-8")));
    unsafe printf(cs("L4 %zu\n"), MB_CUR_MAX);
    ps("L5", unsafe locale::setlocale(locale::LC_NUMERIC, cs("C.UTF-8")));
    ps("L6", unsafe locale::setlocale(locale::LC_ALL, null));
    ps("L7", unsafe locale::setlocale(locale::LC_ALL, cs("POSIX")));
    unsafe printf(cs("L8 %zu\n"), MB_CUR_MAX);
    ps("L9", unsafe locale::setlocale(locale::LC_ALL, cs("en_US.UTF-8")));
    unsafe printf(cs("L10 %zu\n"), MB_CUR_MAX);
    ps("L11", unsafe locale::setlocale(locale::LC_TIME, cs("fr_FR")));
    ps("L12", unsafe locale::setlocale(locale::LC_ALL, null));
    ps("L13", unsafe locale::setlocale(locale::LC_ALL, cs("C;de_DE;C;C;C;C")));
    ps("L14", unsafe locale::setlocale(locale::LC_ALL, cs("a/b")));
    ps("L15", unsafe locale::setlocale(locale::LC_ALL, cs(".x")));
    ps("L16", unsafe locale::setlocale(locale::LC_ALL, cs("123456789012345678901234567890")));
    ps("L17", unsafe locale::setlocale(7, cs("C")));
    ps("L18", unsafe locale::setlocale(-1, cs("C")));
    ps("L19", unsafe locale::setlocale(locale::LC_ALL, cs("C;123456789012345678901234567890;x;y")));
    ps("L20", unsafe locale::setlocale(locale::LC_ALL, cs("")));
    ps("L21", unsafe locale::setlocale(5, null));
    let lc = unsafe &*(unsafe locale::localeconv() as *const lconv);
    unsafe printf(
        cs("L22 [%s] [%s] [%s] [%s] %d %d\n"),
        lc.decimal_point,
        lc.thousands_sep,
        lc.grouping,
        lc.currency_symbol,
        (lc.frac_digits == 255 as char) as i32,
        (lc.n_sign_posn == 255 as char) as i32,
    );
    wide(b);
    times(b);
    signals();
    heap();
    files();
    let mut a: i32 = 0;
    let mut c: i32 = 0;
    let mut r = unsafe stdio::scanf(cs("%d %d"), &mut a, &mut c);
    unsafe printf(cs("I1 %d %d %d\n"), r, a, c);
    let mut w = [0 as char; 8];
    r = unsafe stdio::scanf(cs("%7s"), &mut w[0]);
    unsafe printf(cs("I2 %d %s\n"), r, &w[0]);
    r = unsafe stdio::scanf(cs("%d"), &mut a);
    unsafe printf(cs("I3 %d\n"), r);
    let o = stdio::stdout();
    unsafe printf(
        cs("V1 %d %d %d\n"),
        unsafe setvbuf(o, null, _IOLBF, 0),
        unsafe setvbuf(o, null, 7, 0),
        unsafe setvbuf(o, null, _IOFBF, 0),
    );
    let mut e = unsafe environ;
    while unsafe *e != null {
        unsafe printf(cs("E %s\n"), unsafe *e);
        e = unsafe (e + 1);
    }
    unsafe printf(cs("P %d %d\n"), unsafe pthread_equal(unsafe pthread_self(), unsafe pthread_self()), 1);
    unsafe pthread_exit(null);
    return 1;
}

fn scans() {
    let mut a: i32 = 0;
    let mut bb: i32 = 0;
    let mut c: i32 = 0;
    let mut d: i32 = 0;
    let mut n: i32 = -1;
    let mut u: u32 = 0;
    let mut r = unsafe stdio::sscanf(cs("  42 -17 0x1F 017 +9"), cs("%d %i %i %i %u"), &mut a, &mut bb, &mut c, &mut d, &mut u);
    unsafe printf(cs("S1 %d %d %d %d %d %u\n"), r, a, bb, c, d, u);
    r = unsafe stdio::sscanf(cs("ff 777 1010"), cs("%x %o %3d%n"), &mut a, &mut bb, &mut c, &mut n);
    unsafe printf(cs("S2 %d %d %d %d %d\n"), r, a, bb, c, n);
    let mut f: f32 = 0.0f32;
    let mut d1: f64 = 0.0;
    let mut d2: f64 = 0.0;
    let mut d3: f64 = 0.0;
    let mut d4: f64 = 0.0;
    r = unsafe stdio::sscanf(cs("3.25 -1e10 0x1.8p3 inf nan"), cs("%f %lf %lf %lf %lf"), &mut f, &mut d1, &mut d2, &mut d3, &mut d4);
    unsafe printf(cs("S3 %d %08x %016llx %016llx %016llx %016llx\n"), r, bf(f), bd(d1), bd(d2), bd(d3), bd(d4));
    let mut s1 = ['.' as char; 64];
    let mut s2 = ['.' as char; 64];
    let mut s3 = [0 as char; 64];
    s2[10] = 0 as char;
    r = unsafe stdio::sscanf(cs("hello world"), cs("%s %5c"), &mut s1[0], &mut s2[0]);
    unsafe printf(cs("S4 %d %s %s\n"), r, &s1[0], &s2[0]);
    r = unsafe stdio::sscanf(cs("abc123def"), cs("%[a-z]%[0-9]%n"), &mut s1[0], &mut s2[0], &mut n);
    unsafe printf(cs("S5 %d %s %s %d\n"), r, &s1[0], &s2[0], n);
    r = unsafe stdio::sscanf(cs("key=value;rest"), cs("%[^=]=%[^;];%s"), &mut s1[0], &mut s2[0], &mut s3[0]);
    unsafe printf(cs("S6 %d %s %s %s\n"), r, &s1[0], &s2[0], &s3[0]);
    a = 0;
    r = unsafe stdio::sscanf(cs("12 34"), cs("%*d %d"), &mut a);
    unsafe printf(cs("S7 %d %d\n"), r, a);
    r = unsafe stdio::sscanf(cs(""), cs("%d"), &mut a);
    unsafe printf(cs("S8 %d\n"), r);
    r = unsafe stdio::sscanf(cs("   "), cs("%d"), &mut a);
    unsafe printf(cs("S8b %d\n"), r);
    r = unsafe stdio::sscanf(cs("abc"), cs("%d"), &mut a);
    unsafe printf(cs("S9 %d\n"), r);
    a = 0;
    bb = 0;
    r = unsafe stdio::sscanf(cs("12abc"), cs("%d%d"), &mut a, &mut bb);
    unsafe printf(cs("S10 %d %d %d\n"), r, a, bb);
    let mut hh: i8 = 0;
    let mut h: i16 = 0;
    let mut ll: i64 = 0;
    let mut z: usize = 0;
    let mut l: isize = 0;
    r = unsafe stdio::sscanf(cs("300 70000 5000000000 4294967297 -5"), cs("%hhd %hd %lld %zu %ld"), &mut hh, &mut h, &mut ll, &mut z, &mut l);
    unsafe printf(cs("S11 %d %d %d %lld %zu %ld\n"), r, hh as i32, h as i32, ll, z, l);
    let mut c1 = '.' as char;
    let mut c2 = '.' as char;
    r = unsafe stdio::sscanf(cs("x"), cs("%c%c"), &mut c1, &mut c2);
    unsafe printf(cs("S12 %d %c %c\n"), r, c1 as i32, c2 as i32);
    a = 0;
    r = unsafe stdio::sscanf(cs("  %  5"), cs(" %% %d"), &mut a);
    unsafe printf(cs("S13 %d %d\n"), r, a);
    a = 7;
    n = -1;
    r = unsafe stdio::sscanf(cs("0x"), cs("%x%n"), &mut a, &mut n);
    unsafe printf(cs("S14 %d %d %d\n"), r, a, n);
    f = 7.0f32;
    n = -1;
    r = unsafe stdio::sscanf(cs("1.5e"), cs("%f%n"), &mut f, &mut n);
    unsafe printf(cs("S15 %d %08x %d\n"), r, bf(f), n);
    s1 = [0 as char; 64];
    r = unsafe stdio::sscanf(cs("infinity in"), cs("%f %2s"), &mut f, &mut s1[0]);
    unsafe printf(cs("S16 %d %08x %s\n"), r, bf(f), &s1[0]);
    c1 = '.' as char;
    r = unsafe stdio::sscanf(cs("nan(abc) z"), cs("%lf %c"), &mut d1, &mut c1);
    unsafe printf(cs("S17 %d %016llx %c\n"), r, bd(d1), c1 as i32);
    r = unsafe stdio::sscanf(cs("  -0x1p-3"), cs("%a"), &mut f);
    unsafe printf(cs("S18 %d %08x\n"), r, bf(f));
    let mut p1: *mut char = null;
    let mut p2: *mut char = null;
    r = unsafe stdio::sscanf(cs("dynamic string"), cs("%ms %m[a-z]"), &mut p1, &mut p2);
    unsafe printf(
        cs("S19 %d %s %s\n"),
        r,
        if p1 != null {
            p1 as *const char;
        } else {
            cs("-");
        },
        if p2 != null {
            p2 as *const char;
        } else {
            cs("-");
        },
    );
    unsafe free(p1);
    unsafe free(p2);
    a = 0;
    bb = 0;
    r = unsafe stdio::sscanf(cs("7 8"), cs("%2$d %1$d"), &mut a, &mut bb);
    unsafe printf(cs("S20 %d %d %d\n"), r, a, bb);
    let mut vp: *mut void = null;
    r = unsafe stdio::sscanf(cs("0x1234"), cs("%p"), &mut vp);
    unsafe printf(cs("S21 %d %lx\n"), r, vp as usize);
    let mut wc: i32 = 0;
    let mut ws = [0i32; 8];
    r = unsafe stdio::sscanf(cs("\xc3\xa9x"), cs("%lc%ls"), &mut wc, &mut ws[0]);
    unsafe printf(cs("S22 %d %x %x %x\n"), r, wc, ws[0], ws[1]);
    s1 = [0 as char; 64];
    r = unsafe stdio::sscanf(cs("abcdef"), cs("%3s%n"), &mut s1[0], &mut n);
    unsafe printf(cs("S23 %d %s %d\n"), r, &s1[0], n);
    s1 = [0 as char; 64];
    r = unsafe stdio::sscanf(cs("\x5d\x5d\x5dx"), cs("%[\x5d]"), &mut s1[0]);
    unsafe printf(cs("S24 %d %s\n"), r, &s1[0]);
    s1 = [0 as char; 64];
    r = unsafe stdio::sscanf(cs("ab-\x5dx"), cs("%[^\x5dx]"), &mut s1[0]);
    unsafe printf(cs("S25 %d %s\n"), r, &s1[0]);
    s1 = [0 as char; 64];
    r = unsafe stdio::sscanf(cs("a-b-cdz"), cs("%5[a-c-]"), &mut s1[0]);
    unsafe printf(cs("S26 %d %s\n"), r, &s1[0]);
    f = 3.0f32;
    r = unsafe stdio::sscanf(cs("1.5"), cs("%hf"), &mut f);
    unsafe printf(cs("S27 %d %08x\n"), r, bf(f));
    a = 1;
    r = unsafe stdio::sscanf(cs("5"), cs("%q"), &mut a);
    unsafe printf(cs("S28 %d %d\n"), r, a);
    a = 0;
    r = unsafe stdio::sscanf(cs("123456"), cs("%2d%n"), &mut a, &mut n);
    unsafe printf(cs("S29 %d %d %d\n"), r, a, n);
    let mut ull: u64 = 0;
    r = unsafe stdio::sscanf(cs("-1 18446744073709551616"), cs("%llu"), &mut ull);
    unsafe printf(cs("S30 %d %llu\n"), r, ull);
    r = unsafe stdio::sscanf(cs("18446744073709551616"), cs("%llu"), &mut ull);
    unsafe printf(cs("S31 %d %llu %d\n"), r, ull, (unsafe errno == 68) as i32);
    r = unsafe stdio::sscanf(cs("x 1"), cs("x%d"), &mut a);
    unsafe printf(cs("S32 %d %d\n"), r, a);
    r = unsafe stdio::sscanf(cs("1 2 3"), cs("%d %d %d %d"), &mut a, &mut bb, &mut c, &mut d);
    unsafe printf(cs("S33 %d\n"), r);
}

fn wide(b: *mut char) {
    let mut wc: i32 = 0;
    let mut wd: i32 = 0;
    let mut r = unsafe stdio::sscanf(cs("\xc3\xa9\xe2\x82\xac"), cs("%lc%lc"), &mut wc, &mut wd);
    unsafe printf(cs("U1 %d %x %x\n"), r, wc, wd);
    r = unsafe stdio::sscanf(cs("\xc3\x28"), cs("%lc"), &mut wc);
    unsafe printf(cs("U2 %d %d\n"), r, (unsafe errno == 25) as i32);
    let mut ws = [0i32; 8];
    r = unsafe stdio::sscanf(cs("\xf0\x9f\x98\x80z"), cs("%ls"), &mut ws[0]);
    unsafe printf(cs("U3 %d %x %x\n"), r, ws[0], ws[1]);
    r = unsafe stdio::sscanf(cs("\xe2\x82"), cs("%lc"), &mut wc);
    unsafe printf(cs("U4 %d\n"), r);
    let w1 = [0x20aci32, 0x78, 0];
    let w2 = [0x61i32, 0x62, 0];
    let w3 = [0xe9i32, 0x20ac, 0];
    r = unsafe snprintf(b, 512, cs("%lc|%ls|%5ls|%.4ls"), 0xe9, &w1[0], &w2[0], &w3[0]);
    unsafe printf(cs("U5 %d %s\n"), r, b);
    r = unsafe snprintf(b, 512, cs("%lc"), 0xd800);
    unsafe printf(cs("U6 %d\n"), r);
    unsafe locale::setlocale(locale::LC_ALL, cs("C"));
    r = unsafe snprintf(b, 512, cs("%lc"), 0xe9);
    unsafe printf(cs("U7 %d\n"), r);
    r = unsafe snprintf(b, 512, cs("%lc"), 0xdf80);
    unsafe printf(cs("U8 %d %02x\n"), r, unsafe b[0] as u8 as i32);
}

fn times(b: *mut char) {
    for i in 0..20 {
        let t = unsafe TT[i];
        unsafe errno = 0;
        pt("G", i, unsafe gmtime(&t));
        unsafe errno = 0;
        pt("T", i, unsafe localtime(&t));
    }
    let mut m = tm0();
    m.tm_year = 99;
    m.tm_mon = 14;
    m.tm_mday = -3;
    m.tm_hour = 25;
    m.tm_min = -70;
    m.tm_sec = 3700;
    m.tm_isdst = -1;
    let mut t = unsafe mktime(&mut m);
    unsafe printf(cs("K1 %lld\n"), t);
    pt("K1", 0, &m);
    let mut o = tm0();
    o.tm_year = 2147483647;
    o.tm_mon = 40;
    o.tm_mday = 1;
    unsafe errno = 0;
    t = unsafe mktime(&mut o);
    unsafe printf(cs("K2 %lld %d %d\n"), t, unsafe errno, o.tm_year);
    let mut q = tm0();
    q.tm_year = -1900 - 4000;
    q.tm_mday = 400;
    t = unsafe mktime(&mut q);
    unsafe printf(cs("K3 %lld\n"), t);
    pt("K3", 0, &q);
    for i in 0..14 {
        let tt = unsafe TT[i];
        let g = unsafe gmtime(&tt);
        if g == null {
            continue;
        }
        for k in 0..3 {
            for j in 0..512 {
                unsafe b[j] = '#' as char;
            }
            let n = unsafe strftime(b, 512, cs(unsafe TS[k]), g);
            unsafe b[511] = 0 as char;
            unsafe printf(cs("F %d %d %zu %s\n"), i, k, n, b);
        }
    }
    let mut m2 = tm0();
    m2.tm_year = 12345 - 1900;
    m2.tm_mon = 13;
    m2.tm_wday = 9;
    m2.tm_yday = 400;
    m2.tm_isdst = -1;
    m2.tm_mday = 3;
    for k in 0..3 {
        for j in 0..512 {
            unsafe b[j] = 0 as char;
        }
        let n = unsafe strftime(b, 512, cs(unsafe TS[k]), &m2);
        unsafe printf(cs("F2 %d %zu %s\n"), k, n, b);
    }
    m2.tm_year = -2000 - 1900;
    m2.tm_wday = 3;
    m2.tm_mon = 2;
    m2.tm_hour = 13;
    for k in 0..3 {
        for j in 0..512 {
            unsafe b[j] = 0 as char;
        }
        let n = unsafe strftime(b, 512, cs(unsafe TS[k]), &m2);
        unsafe printf(cs("F3 %d %zu %s\n"), k, n, b);
    }
    for n in 0..12usize {
        for j in 0..20 {
            unsafe b[j] = '#' as char;
        }
        unsafe b[19] = 0 as char;
        let r = unsafe strftime(b, n, cs("%Y-%m-%d"), &m2);
        unsafe printf(cs("F4 %d %zu %s\n"), n as i32, r, b);
    }
}

fn signals() {
    let mut r = unsafe signal(SIGUSR1, on_usr);
    unsafe printf(cs("G1 %d\n"), (r as usize == 0) as i32);
    unsafe printf(cs("G2 %d\n"), unsafe raise(SIGUSR1));
    r = unsafe signal(SIGUSR1, unsafe sig_ign);
    unsafe printf(cs("G3 %d\n"), (r as usize == on_usr as usize) as i32);
    unsafe printf(cs("G4 %d\n"), unsafe raise(SIGUSR1));
    unsafe errno = 0;
    r = unsafe signal(SIGKILL, on_usr);
    unsafe printf(cs("G5 %d %d\n"), (r as usize == (unsafe sig_err) as usize) as i32, unsafe errno);
    unsafe errno = 0;
    r = unsafe signal(65, on_usr);
    unsafe printf(cs("G6 %d %d\n"), (r as usize == (unsafe sig_err) as usize) as i32, unsafe errno);
    unsafe errno = 0;
    let g7 = unsafe raise(65);
    unsafe printf(cs("G7 %d %d\n"), g7, unsafe errno);
    unsafe printf(cs("G8 %d %d\n"), unsafe raise(SIGCHLD), unsafe raise(SIGCONT));
    r = unsafe signal(SIGUSR1, unsafe (0usize as fn(i32)));
    unsafe printf(cs("G9 %d\n"), (r as usize == (unsafe sig_ign) as usize) as i32);
    for i in -1..67 {
        unsafe printf(cs("G10 %d %s\n"), i, unsafe strsignal(i));
    }
}

fn heap() {
    let p0 = unsafe sbrk(0) as usize;
    let a = unsafe malloc(100);
    let q = unsafe sbrk(65536) as *mut u8;
    unsafe printf(cs("B1 %d %d\n"), (q as usize != ~0usize) as i32, ((q as usize & 65535) == 0) as i32);
    for i in 0..65536usize {
        unsafe q[i] = 0xab;
    }
    let mut bad: i32 = 0;
    let mut keep = Vector::<*mut void>::new();
    for i in 0..2000usize {
        let m = unsafe malloc(1000) as *mut u8;
        keep.push(m);
        if m == null || m as usize + 1000 > q as usize && (m as usize) < q as usize + 65536 {
            bad += 1;
        }
        for j in 0..1000usize {
            unsafe m[j] = (i & 255) as u8;
        }
    }
    for i in 0..65536usize {
        if unsafe q[i] != 0xab {
            bad += 1;
            break;
        }
    }
    for i in 0..2000usize {
        unsafe free(keep[i]);
    }
    unsafe free(a);
    unsafe printf(cs("B2 %d %d\n"), bad, (unsafe sbrk(0) as usize > p0) as i32);
}

fn files() {
    let fd = unsafe fcntl::creat(cs("t.txt"), 0o644);
    unsafe printf(cs("C1 %d\n"), (fd >= 0) as i32);
    let txt = "10 20.5 word\n";
    let _ = unsafe write(fd, txt.ptr(), txt.len());
    let _ = unsafe close(fd);
    let mut f = stdio::fopen("t.txt", "r");
    let mut a: i32 = 0;
    let mut d: f64 = 0.0;
    let mut w = [0 as char; 16];
    let mut r = unsafe stdio::fscanf(f, cs("%d %lf %15s"), &mut a, &mut d, &mut w[0]);
    unsafe printf(cs("C2 %d %d %016llx %s\n"), r, a, bd(d), &w[0]);
    r = unsafe stdio::fscanf(f, cs("%d"), &mut a);
    unsafe printf(cs("C3 %d\n"), r);
    unsafe stdio::fclose(f);
    f = stdio::fopen("n.txt", "w");
    for i in 0..6000 {
        unsafe stdio::fprintf(
            f,
            cs("%d%c"),
            i * 37 - 999,
            if i % 13 == 0 {
                10;
            } else {
                32;
            },
        );
    }
    unsafe stdio::fclose(f);
    for mode in 0..2 {
        f = stdio::fopen("n.txt", "r");
        if mode != 0 {
            unsafe printf(cs("C4b %d\n"), unsafe setvbuf(f, null, _IONBF, 0));
        }
        let mut sum: i64 = 0;
        let mut cnt: i32 = 0;
        let mut v: i32 = 0;
        while unsafe stdio::fscanf(f, cs("%d"), &mut v) == 1 {
            sum += v;
            cnt += 1;
        }
        unsafe printf(cs("C4 %d %lld %d %d\n"), mode, sum, cnt, (unsafe stdio::feof(f) != 0) as i32);
        unsafe stdio::fclose(f);
    }
    f = stdio::fopen("w.txt", "w");
    unsafe stdio::fputs(cs("0x1p+3 1e400 -0 abc"), f);
    unsafe stdio::fclose(f);
    f = stdio::fopen("w.txt", "r");
    let mut x: f64 = 0.0;
    let mut y: f64 = 0.0;
    let mut z: f64 = 0.0;
    let mut s = [0 as char; 8];
    r = unsafe stdio::fscanf(f, cs("%lf %lf %lf %7s"), &mut x, &mut y, &mut z, &mut s[0]);
    unsafe printf(cs("C5 %d %016llx %016llx %016llx %s\n"), r, bd(x), bd(y), bd(z), &s[0]);
    unsafe stdio::fclose(f);
    f = stdio::fopen("w.txt", "a");
    r = unsafe stdio::fscanf(f, cs("%d"), &mut a);
    unsafe printf(cs("C6 %d\n"), r);
    unsafe stdio::fclose(f);
}
)";

const REFERENCE2: str = M"(
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

extern char **environ;
_Noreturn void pthread_exit(void *);

static uint64_t st = 0x2545f4914f6cdd1dULL;
static uint64_t rnd(void) { st = st * 6364136223846793005ULL + 1442695040888963407ULL; return st; }
static double gd(int i) { uint64_t r = rnd(); double u = (double)(r >> 11) * 0x1p-53; double d; switch (i % 5) { case 0: memcpy(&d, &r, 8); return d; case 1: return u * 20 - 10; case 2: return u * 2000 - 1000; case 3: return u * 2 - 1; default: return (u - 0.5) * 1e20; } }
static float gf(int i) { uint64_t r = rnd(); float u = (float)((r >> 40) * 0x1p-24); float f; uint32_t b = (uint32_t)(r >> 32); switch (i % 5) { case 0: memcpy(&f, &b, 4); return f; case 1: return u * 20 - 10; case 2: return u * 200 - 100; case 3: return u * 2 - 1; default: return u * 1e5f - 5e4f; } }
static uint64_t bd(double d) { uint64_t b; memcpy(&b, &d, 8); return b; }
static uint32_t bf(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static void on_usr(int s) { printf("H %d\n", s); }

static const char *TS[] = {"%a|%A|%b|%B|%c|%C|%d|%D|%e|%F|%g|%G|%h|%H|%I|%j|%m|%M|%n|%p|%r|%R|%s|%S|%t|%T|%u|%U|%V|%w|%W|%x|%X|%y|%Y|%z|%Z|%%",
  "%-d|%_d|%0e|%+4Y|%10C|%+5G|%Ey|%Od|%-j|%_H|%+Y|%3Y|%+3C", "%Y-%m%q-%d"};
static const long long TT[] = {0, 1, -1, 86399, 86400, 951782400, 1709210096, -2208988800LL, 253402300799LL, 253402300800LL, 67767976233532799LL, 67768036191676800LL, -67768040609740800LL, -67768040609740801LL, 1230768000, 1262217600, 1293753600, 1104537600, 1136073600, -62167219200LL};

static void pt(const char *k, int i, const struct tm *t) {
  if (!t) { printf("%s %d null %d\n", k, i, errno); return; }
  printf("%s %d %d %d %d %d %d %d %d %d %d %d\n", k, i, t->tm_sec, t->tm_min, t->tm_hour, t->tm_mday, t->tm_mon, t->tm_year, t->tm_wday, t->tm_yday, t->tm_isdst, t->__tm_gmtoff);
}
static void ps(const char *k, const char *s) { printf("%s %s\n", k, s ? s : "(null)"); }

int main(void) {
  char buf[512];
  for (int i = 0; i < 300; i++) {
    double x = gd(i), y = gd(i + 1);
    float f = gf(i), g = gf(i + 1);
    int e1 = 0, e2 = 0;
    double ip = 0;
    float ipf = 0;
    double fr = frexp(x, &e1);
    float frf = frexpf(f, &e2);
    double mf = modf(x, &ip);
    float mff = modff(f, &ipf);
    printf("m %d %016llx %08x %016llx %d %08x %d %016llx %016llx %08x %08x %016llx %08x\n", i, (unsigned long long)bd(erfc(x)), (unsigned)bf(erfcf(f)), (unsigned long long)bd(fr), e1, (unsigned)bf(frf), e2, (unsigned long long)bd(mf), (unsigned long long)bd(ip), (unsigned)bf(mff), (unsigned)bf(ipf), (unsigned long long)bd(nextafter(x, y)), (unsigned)bf(nextafterf(f, g)));
    printf("m2 %d %016llx %016llx %08x\n", i, (unsigned long long)bd(erfc(x * 1e-3)), (unsigned long long)bd(nextafter(x, x)), (unsigned)bf(erfcf(f * 1e-2f)));
  }
  {
    int a = 0, b = 0, c = 0, d = 0, n = -1; unsigned u = 0;
    int r = sscanf("  42 -17 0x1F 017 +9", "%d %i %i %i %u", &a, &b, &c, &d, &u);
    printf("S1 %d %d %d %d %d %u\n", r, a, b, c, d, u);
    r = sscanf("ff 777 1010", "%x %o %3d%n", &a, &b, &c, &n);
    printf("S2 %d %d %d %d %d\n", r, a, b, c, n);
    float f = 0; double d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    r = sscanf("3.25 -1e10 0x1.8p3 inf nan", "%f %lf %lf %lf %lf", &f, &d1, &d2, &d3, &d4);
    printf("S3 %d %08x %016llx %016llx %016llx %016llx\n", r, (unsigned)bf(f), (unsigned long long)bd(d1), (unsigned long long)bd(d2), (unsigned long long)bd(d3), (unsigned long long)bd(d4));
    char s1[64], s2[64], s3[64];
    memset(s1, '.', sizeof s1); memset(s2, '.', sizeof s2); s2[10] = 0;
    r = sscanf("hello world", "%s %5c", s1, s2);
    printf("S4 %d %s %s\n", r, s1, s2);
    r = sscanf("abc123def", "%[a-z]%[0-9]%n", s1, s2, &n);
    printf("S5 %d %s %s %d\n", r, s1, s2, n);
    r = sscanf("key=value;rest", "%[^=]=%[^;];%s", s1, s2, s3);
    printf("S6 %d %s %s %s\n", r, s1, s2, s3);
    a = 0; r = sscanf("12 34", "%*d %d", &a); printf("S7 %d %d\n", r, a);
    r = sscanf("", "%d", &a); printf("S8 %d\n", r);
    r = sscanf("   ", "%d", &a); printf("S8b %d\n", r);
    r = sscanf("abc", "%d", &a); printf("S9 %d\n", r);
    a = b = 0; r = sscanf("12abc", "%d%d", &a, &b); printf("S10 %d %d %d\n", r, a, b);
    signed char hh = 0; short h = 0; long long ll = 0; size_t z = 0; long l = 0;
    r = sscanf("300 70000 5000000000 4294967297 -5", "%hhd %hd %lld %zu %ld", &hh, &h, &ll, &z, &l);
    printf("S11 %d %d %d %lld %zu %ld\n", r, hh, h, ll, z, l);
    char c1 = '.', c2 = '.';
    r = sscanf("x", "%c%c", &c1, &c2); printf("S12 %d %c %c\n", r, c1, c2);
    a = 0; r = sscanf("  %  5", " %% %d", &a); printf("S13 %d %d\n", r, a);
    a = 7; n = -1; r = sscanf("0x", "%x%n", &a, &n); printf("S14 %d %d %d\n", r, a, n);
    f = 7; n = -1; r = sscanf("1.5e", "%f%n", &f, &n); printf("S15 %d %08x %d\n", r, (unsigned)bf(f), n);
    memset(s1, 0, sizeof s1);
    r = sscanf("infinity in", "%f %2s", &f, s1); printf("S16 %d %08x %s\n", r, (unsigned)bf(f), s1);
    c1 = '.'; r = sscanf("nan(abc) z", "%lf %c", &d1, &c1); printf("S17 %d %016llx %c\n", r, (unsigned long long)bd(d1), c1);
    r = sscanf("  -0x1p-3", "%a", &f); printf("S18 %d %08x\n", r, (unsigned)bf(f));
    char *p1 = 0, *p2 = 0;
    r = sscanf("dynamic string", "%ms %m[a-z]", &p1, &p2); printf("S19 %d %s %s\n", r, p1 ? p1 : "-", p2 ? p2 : "-"); free(p1); free(p2);
    a = b = 0; r = sscanf("7 8", "%2$d %1$d", &a, &b); printf("S20 %d %d %d\n", r, a, b);
    void *vp = 0; r = sscanf("0x1234", "%p", &vp); printf("S21 %d %lx\n", r, (unsigned long)(uintptr_t)vp);
    wchar_t wc = 0, ws[8] = {0};
    r = sscanf("\xc3\xa9x", "%lc%ls", &wc, ws); printf("S22 %d %x %x %x\n", r, (unsigned)wc, (unsigned)ws[0], (unsigned)ws[1]);
    memset(s1, 0, sizeof s1); r = sscanf("abcdef", "%3s%n", s1, &n); printf("S23 %d %s %d\n", r, s1, n);
    memset(s1, 0, sizeof s1); r = sscanf("\x5d\x5d\x5dx", "%[\x5d]", s1); printf("S24 %d %s\n", r, s1);
    memset(s1, 0, sizeof s1); r = sscanf("ab-\x5dx", "%[^\x5dx]", s1); printf("S25 %d %s\n", r, s1);
    memset(s1, 0, sizeof s1); r = sscanf("a-b-cdz", "%5[a-c-]", s1); printf("S26 %d %s\n", r, s1);
    f = 3; r = sscanf("1.5", "%hf", &f); printf("S27 %d %08x\n", r, (unsigned)bf(f));
    a = 1; r = sscanf("5", "%q", &a); printf("S28 %d %d\n", r, a);
    a = 0; r = sscanf("123456", "%2d%n", &a, &n); printf("S29 %d %d %d\n", r, a, n);
    unsigned long long ull = 0; r = sscanf("-1 18446744073709551616", "%llu", &ull); printf("S30 %d %llu\n", r, ull);
    r = sscanf("18446744073709551616", "%llu", &ull); printf("S31 %d %llu %d\n", r, ull, errno == ERANGE);
    r = sscanf("x 1", "x%d", &a); printf("S32 %d %d\n", r, a);
    r = sscanf("1 2 3", "%d %d %d %d", &a, &b, &c, &d); printf("S33 %d\n", r);
  }
  ps("L1", setlocale(LC_ALL, NULL));
  printf("L2 %zu\n", MB_CUR_MAX);
  ps("L3", setlocale(LC_CTYPE, "C.UTF-8"));
  printf("L4 %zu\n", MB_CUR_MAX);
  ps("L5", setlocale(LC_NUMERIC, "C.UTF-8"));
  ps("L6", setlocale(LC_ALL, NULL));
  ps("L7", setlocale(LC_ALL, "POSIX"));
  printf("L8 %zu\n", MB_CUR_MAX);
  ps("L9", setlocale(LC_ALL, "en_US.UTF-8"));
  printf("L10 %zu\n", MB_CUR_MAX);
  ps("L11", setlocale(LC_TIME, "fr_FR"));
  ps("L12", setlocale(LC_ALL, NULL));
  ps("L13", setlocale(LC_ALL, "C;de_DE;C;C;C;C"));
  ps("L14", setlocale(LC_ALL, "a/b"));
  ps("L15", setlocale(LC_ALL, ".x"));
  ps("L16", setlocale(LC_ALL, "123456789012345678901234567890"));
  ps("L17", setlocale(7, "C"));
  ps("L18", setlocale(-1, "C"));
  ps("L19", setlocale(LC_ALL, "C;123456789012345678901234567890;x;y"));
  ps("L20", setlocale(LC_ALL, ""));
  ps("L21", setlocale(LC_MESSAGES, NULL));
  struct lconv *lc = localeconv();
  printf("L22 [%s] [%s] [%s] [%s] %d %d\n", lc->decimal_point, lc->thousands_sep, lc->grouping, lc->currency_symbol, lc->frac_digits == CHAR_MAX, lc->n_sign_posn == CHAR_MAX);
  {
    wchar_t wc = 0, wd = 0;
    int r = sscanf("\xc3\xa9\xe2\x82\xac", "%lc%lc", &wc, &wd); printf("U1 %d %x %x\n", r, (unsigned)wc, (unsigned)wd);
    r = sscanf("\xc3\x28", "%lc", &wc); printf("U2 %d %d\n", r, errno == EILSEQ);
    wchar_t ws[8] = {0};
    r = sscanf("\xf0\x9f\x98\x80z", "%ls", ws); printf("U3 %d %x %x\n", r, (unsigned)ws[0], (unsigned)ws[1]);
    r = sscanf("\xe2\x82", "%lc", &wc); printf("U4 %d\n", r);
    r = snprintf(buf, sizeof buf, "%lc|%ls|%5ls|%.4ls", (wint_t)0xe9, L"\x20acx", L"ab", L"\xe9\x20ac"); printf("U5 %d %s\n", r, buf);
    r = snprintf(buf, sizeof buf, "%lc", (wint_t)0xd800); printf("U6 %d\n", r);
    setlocale(LC_ALL, "C");
    r = snprintf(buf, sizeof buf, "%lc", (wint_t)0xe9); printf("U7 %d\n", r);
    r = snprintf(buf, sizeof buf, "%lc", (wint_t)0xdf80); printf("U8 %d %02x\n", r, (unsigned char)buf[0]);
  }
  for (int i = 0; i < (int)(sizeof TT / sizeof TT[0]); i++) {
    time_t t = TT[i];
    errno = 0;
    pt("G", i, gmtime(&t));
    errno = 0;
    pt("T", i, localtime(&t));
  }
  {
    struct tm m = {0};
    m.tm_year = 99; m.tm_mon = 14; m.tm_mday = -3; m.tm_hour = 25; m.tm_min = -70; m.tm_sec = 3700; m.tm_isdst = -1;
    time_t t = mktime(&m);
    printf("K1 %lld\n", (long long)t);
    pt("K1", 0, &m);
    struct tm o = {0};
    o.tm_year = INT_MAX; o.tm_mon = 40; o.tm_mday = 1;
    errno = 0; t = mktime(&o); printf("K2 %lld %d %d\n", (long long)t, errno, o.tm_year);
    struct tm q = {0}; q.tm_year = -1900 - 4000; q.tm_mday = 400; q.tm_isdst = 0;
    t = mktime(&q); printf("K3 %lld\n", (long long)t); pt("K3", 0, &q);
  }
  for (int i = 0; i < (int)(sizeof TT / sizeof TT[0]) - 6; i++) {
    time_t t = TT[i];
    struct tm *g = gmtime(&t);
    if (!g) continue;
    for (int k = 0; k < 3; k++) {
      memset(buf, '#', sizeof buf);
      size_t n = strftime(buf, sizeof buf, TS[k], g);
      buf[sizeof buf - 1] = 0;
      printf("F %d %d %zu %s\n", i, k, n, buf);
    }
  }
  {
    struct tm m = {0};
    m.tm_year = 12345 - 1900; m.tm_mon = 13; m.tm_wday = 9; m.tm_yday = 400; m.tm_isdst = -1; m.tm_mday = 3; m.tm_hour = 0;
    for (int k = 0; k < 3; k++) { memset(buf, 0, sizeof buf); size_t n = strftime(buf, sizeof buf, TS[k], &m); printf("F2 %d %zu %s\n", k, n, buf); }
    m.tm_year = -2000 - 1900; m.tm_wday = 3; m.tm_mon = 2; m.tm_hour = 13;
    for (int k = 0; k < 3; k++) { memset(buf, 0, sizeof buf); size_t n = strftime(buf, sizeof buf, TS[k], &m); printf("F3 %d %zu %s\n", k, n, buf); }
    for (int n = 0; n < 12; n++) { memset(buf, '#', 20); buf[19] = 0; size_t r = strftime(buf, (size_t)n, "%Y-%m-%d", &m); printf("F4 %d %zu %s\n", n, r, buf); }
  }
  {
    void (*r)(int) = signal(SIGUSR1, on_usr);
    printf("G1 %d\n", r == SIG_DFL);
    printf("G2 %d\n", raise(SIGUSR1));
    r = signal(SIGUSR1, SIG_IGN);
    printf("G3 %d\n", r == on_usr);
    printf("G4 %d\n", raise(SIGUSR1));
    errno = 0; r = signal(SIGKILL, on_usr); printf("G5 %d %d\n", r == SIG_ERR, errno);
    errno = 0; r = signal(65, on_usr); printf("G6 %d %d\n", r == SIG_ERR, errno);
    errno = 0; printf("G7 %d %d\n", raise(65), errno);
    printf("G8 %d %d\n", raise(SIGCHLD), raise(SIGCONT));
    r = signal(SIGUSR1, SIG_DFL); printf("G9 %d\n", r == SIG_IGN);
    for (int i = -1; i < 67; i++) printf("G10 %d %s\n", i, strsignal(i));
  }
  {
    void *p0 = sbrk(0);
    void *a = malloc(100);
    unsigned char *q = sbrk(65536);
    printf("B1 %d %d\n", q != (void *)-1, ((uintptr_t)q & 65535) == 0);
    memset(q, 0xab, 65536);
    int bad = 0;
    void *keep[2000];
    for (int i = 0; i < 2000; i++) {
      unsigned char *m = malloc(1000);
      keep[i] = m;
      if (!m || (m + 1000 > q && m < q + 65536)) bad++;
      memset(m, i & 255, 1000);
    }
    for (int i = 0; i < 65536; i++) if (q[i] != 0xab) { bad++; break; }
    for (int i = 0; i < 2000; i++) free(keep[i]);
    free(a);
    printf("B2 %d %d\n", bad, sbrk(0) > p0);
  }
  {
    int fd = creat("t.txt", 0644);
    printf("C1 %d\n", fd >= 0);
    const char *txt = "10 20.5 word\n";
    write(fd, txt, strlen(txt));
    close(fd);
    FILE *f = fopen("t.txt", "r");
    int a = 0; double d = 0; char w[16] = {0};
    int r = fscanf(f, "%d %lf %15s", &a, &d, w);
    printf("C2 %d %d %016llx %s\n", r, a, (unsigned long long)bd(d), w);
    r = fscanf(f, "%d", &a); printf("C3 %d\n", r);
    fclose(f);
    f = fopen("n.txt", "w");
    for (int i = 0; i < 6000; i++) fprintf(f, "%d%c", i * 37 - 999, i % 13 == 0 ? '\n' : ' ');
    fclose(f);
    for (int mode = 0; mode < 2; mode++) {
      f = fopen("n.txt", "r");
      if (mode) printf("C4b %d\n", setvbuf(f, NULL, _IONBF, 0));
      long long sum = 0; int cnt = 0, v = 0;
      while (fscanf(f, "%d", &v) == 1) { sum += v; cnt++; }
      printf("C4 %d %lld %d %d\n", mode, sum, cnt, feof(f) != 0);
      fclose(f);
    }
    f = fopen("w.txt", "w");
    fputs("0x1p+3 1e400 -0 abc", f);
    fclose(f);
    f = fopen("w.txt", "r");
    double x = 0, y = 0, z = 0; char s[8] = {0};
    r = fscanf(f, "%lf %lf %lf %7s", &x, &y, &z, s);
    printf("C5 %d %016llx %016llx %016llx %s\n", r, (unsigned long long)bd(x), (unsigned long long)bd(y), (unsigned long long)bd(z), s);
    fclose(f);
    f = fopen("w.txt", "a");
    r = fscanf(f, "%d", &a); printf("C6 %d\n", r);
    fclose(f);
  }
  {
    int a = 0, b = 0;
    int r = scanf("%d %d", &a, &b); printf("I1 %d %d %d\n", r, a, b);
    char w[8] = {0};
    r = scanf("%7s", w); printf("I2 %d %s\n", r, w);
    r = scanf("%d", &a); printf("I3 %d\n", r);
  }
  printf("V1 %d %d %d\n", setvbuf(stdout, NULL, _IOLBF, 0), setvbuf(stdout, NULL, 7, 0), setvbuf(stdout, NULL, _IOFBF, 0));
  for (char **e = environ; *e; e++) printf("E %s\n", *e);
  printf("P %d %d\n", pthread_equal(pthread_self(), pthread_self()), pthread_self() != 0);
  pthread_exit(NULL);
}
)";

@platform(macos | linux)
@test(timeout = 600)
fn wasm_libc_io_time_locale_and_signals_match_wasi_libc() {
    if env::get("WASI_SDK_PATH").unwrap().unwrap_or(String::new()).len() == 0 {
        return;
    }
    let cflags: [str; 2] = ["-D_WASI_EMULATED_SIGNAL", "-lwasi-emulated-signal"];
    let wt: [str; 7] = ["--dir=.", "--env", "LANG=xx_YY", "--env", "LC_TIME=tt_TT", "--env", "A=1"];
    let _ = compare(PROGRAM2, REFERENCE2, cflags, wt, "5 6\nword\n", 40000);
}

// The C symbols a wasm build may bind that neither `std::rt::libc` nor `std::rt::libm` defines, besides the
// runtime's own (`sc_*`, `__sc_*`: `std::rt::base` and `super_rt.h` define them), the sanitizer hooks
// (`__tsan_*`: wasm has no sanitizer) and the SIMD128 intrinsics (`wasm_*`, inline in `wasm_simd128.h`):
// the standard streams, macros of `super_rt.h` on wasm, and the functions WASI has no call for, which
// wasi-libc's C library lacks too. A program that calls one of those fails to link.
const NO_WASM_C: [str; 17] = [
    "stdin",
    "stdout",
    "stderr",
    "chown",
    "dlclose",
    "dlerror",
    "dlopen",
    "dlsym",
    "dup",
    "dup2",
    "execvp",
    "fork",
    "getppid",
    "pipe",
    "pthread_create",
    "pthread_detach",
    "pthread_join",
];

// The names `@export("..")` gives in `text`, and the `.globl` symbols of its module asm.
fn exports_of(text: str, out: &mut Vector<String>) {
    for marker in ["@export(\"", ".globl "] {
        let mut i: usize = 0;
        // Each pass moves past one marker.
        loop {
            let f = text.slice(i, text.len()).find(marker);
            if f < 0 {
                break;
            }
            let start = i + f as usize + marker.len();
            let mut end = start;
            while end < text.len() && text.byte_at(end) != b'"' && text.byte_at(end) != b'\n' {
                end += 1;
            }
            out.push(String::from_str(text.slice(start, end)));
            i = end;
        }
    }
}

// Every C function and static that ffi, std and the compiler bind for a wasm build is defined by wasm's C
// library, the runtime or the intrinsics header, or is one of `NO_WASM_C`: a binding with no definition
// fails only at a wasm link, which no other host's test reaches.
@test
fn every_c_symbol_a_wasm_build_binds_is_defined() {
    let mut defined = Vector::<String>::new();
    for f in ["std/rt/libc.spc", "std/rt/libm.spc"] {
        exports_of(sfiles::read_file(f).unwrap().as_str(), &mut defined);
    }
    let mut missing = String::new();
    for root in ["ffi", "std", "src"] {
        let mut files = Vector::<String>::new();
        assert(sfiles::list_spc(root, &mut files), "the sources list");
        for rel in files.iter() {
            let path = format("{}/{}", root, rel.as_str());
            if path.as_str() == "std/rt/libc.spc" || path.as_str() == "std/rt/libm.spc" {
                continue;
            }
            let sc = sscan::scan(sfiles::read_file(path.as_str()).unwrap().as_str());
            if !sc.error.is_empty() {
                missing.format_into("{}:{}: {}\n", path.as_str(), sc.error_line, sc.error.as_str());
                continue;
            }
            for e in sc.externs.iter() {
                let n = e.name.as_str();
                if !e.wasm || n.starts_with("sc_") || n.starts_with("__sc_") || n.starts_with("__tsan_") || n.starts_with(
                    "wasm_",
                ) {
                    continue;
                }
                let mut known = false;
                for d in defined.iter() {
                    known = known || d.as_str() == n;
                }
                for x in NO_WASM_C {
                    known = known || x == n;
                }
                if !known {
                    missing.format_into("{}:{}: {}\n", path.as_str(), e.line, n);
                }
            }
        }
    }
    if !missing.is_empty() {
        eprintln("bound for wasm, defined by no C library:\n{}", missing.as_str());
    }
    assert(missing.is_empty(), "every C symbol a wasm build binds is defined");
}
