// The coefficient generator: writes std/simd/math/coeffs_f32.spc and coeffs_f64.spc, the constants
// of the math kernels (`Konsts`), the bits of 2/pi for the exact pi/2 reduction (f64; f32 reduces in
// f64), and one minimax polynomial per kernel and lane type (Remez exchange in f128, coefficients
// rounded to the lane type, the degree the smallest that meets the kernel's error target with the
// rounded coefficients; a target no degree meets stops the generator). Deterministic: every value
// comes from IEEE and std `Float` operations, and the fits that run in parallel are independent of
// each other.
//
//   super-c release tools/simd_math && tools/simd_math/build/release/simd-math-gen [--jobs=N] [out-dir]
//
// `out-dir` defaults to std/simd/math (run from the repository root); `--jobs=N` runs N worker threads
// (default one per CPU).
import real as *;
import ref as *;
import remez as *;
import std::float as fl;
import std::parallel::data as parallel;
import std::parallel::runtime as runtime;
import stdio;

type Q = fl::f128;
// The constants need more than f128: pi/2 in four parts spans 155 bits.
type Z = fl::f256;

// One polynomial: p(z) ~ g(z) on [lo, hi], minimizing max |w(z) (p(z) - g(z))|; `err` is the target
// weighted error as -log2 per lane type, `var` the variable's name, `what` the documentation line.
struct Spec {
    pub name: str<'static>,
    pub var: str<'static>,
    pub lo: f64,
    pub hi: f64,
    pub err32: f64,
    pub err64: f64,
    pub g: fn(&Ref<Q>, Q) Q,
    pub w: fn(&Ref<Q>, Q) Q,
    pub what: str<'static>,
}

const LN2_2: f64 = 0.34658; // just past ln2 / 2
const LN2_256: f64 = 0.0027076; // just past ln2 / 256: the reduced range of the 128-entry exp table
const R_LOG_T: f64 = 0.0078125; // 2^-7: the reduced range of the 128-entry log table (checked)
const PIO4_SQ: f64 = 0.61686; // just past (pi/4)^2
const PIO8_SQ: f64 = 0.15422; // just past (pi/8)^2
const TANPIO8_SQ: f64 = 0.171575; // just past tan(pi/8)^2
const LOG_S_SQ: f64 = 0.0294374; // just past ((sqrt2 - 1) / (sqrt2 + 1))^2
const PIO2_SQ: f64 = 2.48; // past (pi/2 + 2^-8)^2: the fast reduction's q may be off by one ulp of x/pi

fn q(x: f64) Q {
    return Q::of(x);
}

const fn wz(_r: &Ref<Q>, z: Q) Q {
    return z;
}

const fn wz2(_r: &Ref<Q>, z: Q) Q {
    return z * z;
}

// A power series sum_{n >= 0} a(n) z^n with a(n) from `term(n, previous)`, to f128 precision.
fn series(z: Q, a0: Q, term: fn(i32, Q) Q) Q {
    let mut a = a0;
    let mut p = q(1.0);
    let mut s = a0;
    for n in 1..400 {
        a = term(n, a);
        p = p * z;
        let t = a * p;
        s = s + t;
        if !(Ref::<Q>::abs(s) * q(1.0).scale(-125)).lt(Ref::<Q>::abs(t)) && n > 2 {
            return s;
        }
    }
    panic("series: no convergence");
}

// (e^r - 1 - r - r^2/2) / r^3 = sum r^n / (n + 3)!
fn g_exp(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(1.0) / q(6.0),
        fn(n: i32, a: Q) Q {
            return a / q((n + 3) as f64);
        },
    );
}

fn wz3(_r: &Ref<Q>, z: Q) Q {
    return Ref::<Q>::abs(z * z * z);
}

// (2 atanh(s) / s - 2) / s^2 = sum 2 z^n / (2n + 3), z = s^2
fn g_log(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(2.0) / q(3.0),
        fn(n: i32, _a: Q) Q {
            return q(2.0) / q((2 * n + 3) as f64);
        },
    );
}

// (e^r - 1 - r) / r^2 = sum r^n / (n + 2)!
fn g_expf(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(0.5),
        fn(n: i32, a: Q) Q {
            return a / q((n + 2) as f64);
        },
    );
}

// (log1p(r) - r + r^2/2) / r^3 = sum (-1)^n r^n / (n + 3)
fn g_logt(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(1.0) / q(3.0),
        fn(n: i32, a: Q) Q {
            let m = q(1.0) / q((n + 3) as f64);
            return if a.lt(q(0.0)) {
                m;
            } else {
                q(0.0) - m;
            };
        },
    );
}

// (2 atanh(s) / s - 2 - 2 z / 3 - 2 z^2 / 5) / z^3 = sum 2 z^n / (2n + 7)
fn g_logk(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(2.0) / q(7.0),
        fn(n: i32, _a: Q) Q {
            return q(2.0) / q((2 * n + 7) as f64);
        },
    );
}

const fn wz3p(_r: &Ref<Q>, z: Q) Q {
    return z * z * z;
}

// (sin r - r) / r^3 = sum (-1)^(n+1) z^n / (2n + 3)!
fn g_sin(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(-1.0) / q(6.0),
        fn(n: i32, a: Q) Q {
            return q(0.0) - a / q(((2 * n + 2) * (2 * n + 3)) as f64);
        },
    );
}

// (cos r - 1 + z/2) / z^2 = sum (-1)^n z^n / (2n + 4)!
fn g_cos(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(1.0) / q(24.0),
        fn(n: i32, a: Q) Q {
            return q(0.0) - a / q(((2 * n + 3) * (2 * n + 4)) as f64);
        },
    );
}

// (asin x - x) / x^3 = sum c(n+1) z^n, c(n) = (2n)! / (4^n n!^2 (2n + 1))
fn g_asin(_r: &Ref<Q>, z: Q) Q {
    // c(n+1) / c(n) = (2n + 1)^2 / ((2n + 2) (2n + 3)); c(1) = 1/6.
    return series(
        z,
        q(1.0) / q(6.0),
        fn(n: i32, a: Q) Q {
            return a * q(((2 * n + 1) * (2 * n + 1)) as f64) / q(((2 * n + 2) * (2 * n + 3)) as f64);
        },
    );
}

// (atan t - t) / t^3 = sum (-1)^(n+1) z^n / (2n + 3)
fn g_atan(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(-1.0) / q(3.0),
        fn(n: i32, a: Q) Q {
            let m = q(1.0) / q((2 * n + 3) as f64);
            return if a.lt(q(0.0)) {
                m;
            } else {
                q(0.0) - m;
            };
        },
    );
}

// tan u / u = sum t(n) z^n, z = u^2, from (sin u / u) / cos u coefficient by coefficient; built once in
// `main`, before the fits.
static mut TAN_T: *const Vector<Q> = null;

fn tan_series() Vector<Q> {
    let terms: usize = 40;
    let mut s = Vector::<Q>::new(); // sin u / u = sum (-1)^n z^n / (2n + 1)!
    let mut c = Vector::<Q>::new(); // cos u = sum (-1)^n z^n / (2n)!
    let mut fs = q(1.0);
    let mut fc = q(1.0);
    for n in 0..terms {
        if n > 0 {
            fs = q(0.0) - fs / q((2 * n * (2 * n + 1)) as f64);
            fc = q(0.0) - fc / q(((2 * n - 1) * (2 * n)) as f64);
        }
        s.push(fs);
        c.push(fc);
    }
    let mut t = Vector::<Q>::new();
    for n in 0..terms {
        let mut v = s[n];
        for k in 0..n {
            v = v - t[k] * c[n - k];
        }
        t.push(v);
    }
    return t;
}

// (sinh x - x) / x^3 = sum z^n / (2n + 3)!, z = x^2
fn g_sinh(_r: &Ref<Q>, z: Q) Q {
    return series(
        z,
        q(1.0) / q(6.0),
        fn(n: i32, a: Q) Q {
            return a / q(((2 * n + 2) * (2 * n + 3)) as f64);
        },
    );
}

// (tanh x - x) / x^3 = sum t(n + 1) (-z)^n, z = x^2, from tan u / u = sum t(n) u^(2n)
fn g_tanh(_r: &Ref<Q>, z: Q) Q {
    let t = unsafe &*TAN_T;
    let mut sum = q(0.0);
    let mz = q(0.0) - z;
    let mut k = t.len() - 1;
    while k >= 1 {
        sum = sum * mz + t[k];
        k -= 1;
    }
    return q(0.0) - sum;
}

// (tan u - u) / u^3 = (tan u / u - 1) / z = sum t(n + 1) z^n
fn g_tan(_r: &Ref<Q>, z: Q) Q {
    let t = unsafe &*TAN_T;
    let mut sum = q(0.0);
    let mut k = t.len() - 1;
    while k >= 1 {
        sum = sum * z + t[k];
        k -= 1;
    }
    return sum;
}

// (erf(x) / x - 2/sqrt(pi)) / z = 2/sqrt(pi) sum (-1)^(n+1) z^n / ((n + 1)! (2n + 3)), z = x^2
fn g_erf(r: &Ref<Q>, z: Q) Q {
    return r.two_sqrtpi * series(
        z,
        q(-1.0) / q(3.0),
        fn(n: i32, a: Q) Q {
            return q(0.0) - a * q((2 * n + 1) as f64) / q(((n + 1) * (2 * n + 3)) as f64);
        },
    );
}

// cbrt(m), m in [1, 2]: Newton in Q from 1.
fn g_cbrt(_r: &Ref<Q>, m: Q) Q {
    let mut y = q(1.0);
    for _ in 0..60 {
        y = y - (y * y * y - m) / (q(3.0) * y * y);
    }
    return y;
}

fn w_cbrt(r: &Ref<Q>, m: Q) Q {
    return q(1.0) / g_cbrt(r, m);
}

fn specs() Vector<Spec> {
    let mut v = Vector::<Spec>::new();
    v.push(
        Spec {
            name: "ExpP",
            var: "r",
            lo: -LN2_2,
            hi: LN2_2,
            err32: 31.0,
            err64: 60.0,
            g: g_exp,
            w: wz3,
            what: "e^r = 1 + r + r^2/2 + r^3 p(r); error weighted by |r|^3",
        },
    );
    v.push(
        Spec {
            name: "LogP",
            var: "z",
            lo: 0.0,
            hi: LOG_S_SQ,
            err32: 29.0,
            err64: 58.0,
            g: g_log,
            w: wz,
            what: "log((1 + s)/(1 - s)) = 2s + s z p(z), z = s^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "LogkP",
            var: "z",
            lo: 0.0,
            hi: LOG_S_SQ,
            err32: 40.0,
            err64: 70.0,
            g: g_logk,
            w: wz3p,
            what: "log((1 + s)/(1 - s)) = 2s + 2/3 s^3 + 2/5 s^5 + s^7 p(z), z = s^2; error weighted by z^3",
        },
    );
    v.push(
        Spec {
            name: "SinP",
            var: "z",
            lo: 0.0,
            hi: PIO4_SQ,
            err32: 28.0,
            err64: 57.0,
            g: g_sin,
            w: wz,
            what: "sin r = r + r z p(z), z = r^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "CosP",
            var: "z",
            lo: 0.0,
            hi: PIO4_SQ,
            err32: 29.0,
            err64: 58.0,
            g: g_cos,
            w: wz2,
            what: "cos r = 1 - z/2 + z^2 p(z), z = r^2; error weighted by z^2",
        },
    );
    v.push(
        Spec {
            name: "TanP",
            var: "z",
            lo: 0.0,
            hi: PIO8_SQ,
            err32: 29.0,
            err64: 58.0,
            g: g_tan,
            w: wz,
            what: "tan u = u + u z p(z), z = u^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "AsinP",
            var: "z",
            lo: 0.0,
            hi: 0.25,
            err32: 29.0,
            err64: 58.0,
            g: g_asin,
            w: wz,
            what: "asin x = x + x z p(z), z = x^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "AtanP",
            var: "z",
            lo: 0.0,
            hi: TANPIO8_SQ,
            err32: 28.0,
            err64: 57.0,
            g: g_atan,
            w: wz,
            what: "atan t = t + t z p(z), z = t^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "ErfP",
            var: "z",
            lo: 0.0,
            hi: 0.25,
            err32: 28.0,
            err64: 57.0,
            g: g_erf,
            w: wz,
            what: "erf x = 2/sqrt(pi) x + x z p(z), z = x^2, |x| < 1/2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "ExpT",
            var: "r",
            lo: -LN2_256,
            hi: LN2_256,
            err32: 30.0,
            err64: 66.0,
            g: g_expf,
            w: wz2,
            what: "f64 table exp: e^r = 1 + r + r^2 p(r), |r| <= ln2/256; error weighted by r^2",
        },
    );
    v.push(
        Spec {
            name: "LogT",
            var: "r",
            lo: -R_LOG_T,
            hi: R_LOG_T,
            err32: 30.0,
            err64: 62.0,
            g: g_logt,
            w: wz2,
            what: "f64 table log: log1p(r) = r - r^2/2 + r^3 p(r), |r| < 2^-7; error weighted by r^2",
        },
    );
    v.push(
        Spec {
            name: "LogTP",
            var: "r",
            lo: -R_LOG_T,
            hi: R_LOG_T,
            err32: 30.0,
            err64: 69.0,
            g: g_logt,
            w: wz2,
            what: "f64 table log of pow: as LogT, to 2^-69 relative; error weighted by r^2",
        },
    );
    v.push(
        Spec {
            name: "SinhP",
            var: "z",
            lo: 0.0,
            hi: 0.25,
            err32: 27.0,
            err64: 57.0,
            g: g_sinh,
            w: wz,
            what: "sinh x = x + x z p(z), z = x^2, |x| <= 1/2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "TanhP",
            var: "z",
            lo: 0.0,
            hi: 0.3025,
            err32: 27.0,
            err64: 57.0,
            g: g_tanh,
            w: wz,
            what: "tanh x = x + x z p(z), z = x^2, |x| <= 0.55; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "ExpF",
            var: "r",
            lo: -LN2_2,
            hi: LN2_2,
            err32: 14.0,
            err64: 25.0,
            g: g_expf,
            w: wz2,
            what: "fast: e^r = 1 + r + r^2 p(r); error weighted by r^2 (expm1 scales it by up to 2^2.4)",
        },
    );
    v.push(
        Spec {
            name: "ExpB",
            var: "r",
            lo: -LN2_2,
            hi: LN2_2,
            err32: 22.0,
            err64: 55.0,
            g: g_exp,
            w: wz3,
            what: "balanced: e^r = 1 + r + r^2/2 + r^3 p(r) (e^x, not e^x - 1); error weighted by |r|^3",
        },
    );
    v.push(
        Spec {
            name: "LogF",
            var: "z",
            lo: 0.0,
            hi: LOG_S_SQ,
            err32: 13.0,
            err64: 24.0,
            g: g_log,
            w: wz,
            what: "fast: log((1 + s)/(1 - s)) = 2s + s z p(z), z = s^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "SinF",
            var: "z",
            lo: 0.0,
            hi: PIO2_SQ,
            err32: 13.0,
            err64: 24.0,
            g: g_sin,
            w: wz,
            what: "fast: sin r = r + r z p(z), z = r^2, |r| <= pi/2 + 2^-8; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "TanF",
            var: "z",
            lo: 0.0,
            hi: 0.63,
            err32: 13.0,
            err64: 24.0,
            g: g_tan,
            w: wz,
            what: "fast: tan r = r + r z p(z), z = r^2, |r| <= pi/4 + 2^-8; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "AsinF",
            var: "z",
            lo: 0.0,
            hi: 0.25,
            err32: 13.0,
            err64: 24.0,
            g: g_asin,
            w: wz,
            what: "fast: asin x = x + x z p(z), z = x^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "AtanF",
            var: "z",
            lo: 0.0,
            hi: TANPIO8_SQ,
            err32: 13.0,
            err64: 24.0,
            g: g_atan,
            w: wz,
            what: "fast: atan t = t + t z p(z), z = t^2; error weighted by z",
        },
    );
    v.push(
        Spec {
            name: "CbrtP",
            var: "m",
            lo: 1.0,
            hi: 2.0,
            err32: 9.0,
            err64: 16.0,
            g: g_cbrt,
            w: w_cbrt,
            what: "cbrt m = p(m), the Newton start; relative error",
        },
    );
    v.push(
        Spec {
            name: "CbrtB",
            var: "m",
            lo: 1.0,
            hi: 2.0,
            err32: 9.0,
            err64: 19.0,
            g: g_cbrt,
            w: w_cbrt,
            what: "cbrt m = p(m), the Halley start of the balanced class; relative error",
        },
    );
    return v;
}

// cos(i pi / m1) rounded to f64, from the reference library (the same on every host).
static mut COS_REF: *const Ref<Q> = null;

fn cos_node(i: usize, m: usize) f64 {
    let r = unsafe &*COS_REF;
    return r.cos(i as f64 * 3.141592653589793 / (m - 1) as f64).near();
}

// The fit on grid `g` for a lane type of `bits` significand bits: the smallest number of coefficients
// from 2 whose rounded values meet the target, measured on `dense` (finer than `g`). Returns the
// coefficients (f64 values exact in the lane type; `dw0`: the constant term as a double word, two
// values first) and the achieved weighted error as -log2. A target that one more coefficient no
// longer brings closer by a quarter bit (the rounding to the lane type limits it) stops the generator.
fn fit_grid(g: &Grid<Q>, dense: &Grid<Q>, dw0: bool, bits: i32, target: f64) (Vector<f64>, f64) {
    let mut prev_lg: f64 = -1.0;
    for n in 2usize..40 {
        let (cf, lg) = fit_n(g, dense, dw0, n, bits);
        if lg >= target {
            return cf, lg;
        }
        if prev_lg >= 0.0 && lg < prev_lg + 0.25 {
            eprintln("gen: {} coefficients reach 2^-{}, the target is 2^-{}", n, lg, target);
            panic("gen: a fit misses its target");
        }
        prev_lg = lg;
    }
    panic("gen: no degree below 40 meets the target");
}

// The Remez fit of n coefficients rounded to the lane type, and its weighted error on `dense`.
fn fit_n(g: &Grid<Q>, dense: &Grid<Q>, dw0: bool, n: usize, bits: i32) (Vector<f64>, f64) {
    let f = g.remez(n, 0);
    assert(f.converged, "gen: the Remez exchange does not converge");
    let mut c = Vector::<Q>::new();
    let mut cf = Vector::<f64>::new();
    for k in 0..n {
        let v = rnd_q(f.c[k], bits);
        cf.push(v);
        if k == 0 && dw0 {
            let l = rnd_q(f.c[0] - q(v), bits);
            cf.push(l);
            c.push(q(v) + q(l));
        } else {
            c.push(q(v));
        }
    }
    let mut emax = q(0.0);
    for i in 0..dense.z.len() {
        let e = Ref::<Q>::abs(dense.error_at(&c, 0, i));
        if emax.lt(e) {
            emax = e;
        }
    }
    assert(emax.is_finite() && !emax.is_zero(), "fit: the Remez solution is not finite");
    return cf, -log2(emax.to_f64());
}

// `v` rounded to the lane type of `bits` significand bits, as an f64.
const fn rnd_q(v: Q, bits: i32) f64 {
    if bits == 24 {
        return v.to_f32();
    }
    return v.to_f64();
}

fn report(name: str, bits: i32, deg: usize, lg: f64) {
    eprintln(
        "gen: {} f{}: degree {}, weighted error 2^-{}",
        name,
        if bits == 24 {
            32;
        } else {
            64;
        },
        deg,
        lg,
    );
}

// Points of the fit grids (the dense grid has four times as many).
const M_FIT: usize = 1500;

fn grid(r: &Ref<Q>, s: &Spec, m: usize) Grid<Q> {
    let mut g = Grid::<Q> { z: Vector::<Q>::new(), g: Vector::<Q>::new(), w: Vector::<Q>::new() };
    let zs = Grid::<Q>::lobatto(s.lo, s.hi, m, cos_node);
    for i in 0..m {
        let z = q(zs[i]);
        g.z.push(z);
        g.g.push(s.g(r, z));
        g.w.push(s.w(r, z));
    }
    return g;
}

fn log2(v: f64) f64 {
    // Exact enough for a report: exponent plus the mantissa's log by its series in f64.
    let e = exponent(v);
    let m = v / fl::f64_from_bits((1023 + e) as u64 << 52);
    let t = (m - 1.0) / (m + 1.0);
    let mut s = t;
    let mut p = t;
    for k in 1..30 {
        p = p * t * t;
        s = s + p / (2 * k + 1) as f64;
    }
    return e as f64 + 2.0 * s / 0.6931471805599453;
}

/// `v` as an exact hexadecimal float literal.
pub fn hex(v: f64, out: &mut String) {
    if v == 0.0 {
        out.push_str(
            if v.is_sign_negative() {
                "-0.0";
            } else {
                "0.0";
            },
        );
        return;
    }
    if v < 0.0 {
        out.push_byte(b'-');
    }
    let b = fl::f64_bits(v.abs());
    let mut e = (b >> 52) as i64 - 1023;
    let mut f = b & 0xFFFFFFFFFFFFF;
    if e == -1023 {
        // A subnormal: normalize.
        e = -1022;
        while (f & 1u64 << 52) == 0 {
            f = f << 1;
            e -= 1;
        }
        f = f & 0xFFFFFFFFFFFFF;
    }
    out.push_str("0x1");
    if f != 0 {
        out.push_byte(b'.');
        let mut digits: usize = 13;
        while (f & 0xF) == 0 {
            f = f >> 4;
            digits -= 1;
        }
        let mut s = String::new();
        s.push_hex(f, false);
        for _ in s.len()..digits {
            out.push_byte(b'0');
        }
        out.push_string(&s);
    }
    out.format_into("p{}", e);
}

// The f64 nearest `x`, or (lane type of 24 bits) the f32 nearest, as an f64.
const fn rnd(x: Z, bits: i32) f64 {
    if bits == 24 {
        return x.to_f32();
    }
    return x.to_f64();
}

// `x` split into `hi` (rounded) and `lo` (the rest, rounded).
fn split(x: Z, bits: i32) (f64, f64) {
    let hi = rnd(x, bits);
    return hi, rnd(x - Z::of(hi), bits);
}

// `x` truncated to `n` significant bits, |x| in [1, 2) times a power of two.
fn trunc_bits(x: Z, n: i32) f64 {
    let e = exponent(x.to_f64());
    return x.scale(n - 1 - e).floor().scale(-(n - 1 - e)).to_f64();
}

// The largest value of the lane type below `x` (or `x` itself when representable), and the smallest
// above.
fn below(x: Z, bits: i32) f64 {
    let v = rnd(x, bits);
    if x.lt(Z::of(v)) {
        return step(v, bits, false);
    }
    return v;
}

fn above(x: Z, bits: i32) f64 {
    let v = rnd(x, bits);
    if Z::of(v).lt(x) {
        return step(v, bits, true);
    }
    return v;
}

// The neighbor of `v` in the lane type, up or down.
const fn step(v: f64, bits: i32, up: bool) f64 {
    if bits == 24 {
        let b = fl::f32_bits(v as f32);
        let n = if v > 0.0 == up {
            b + 1;
        } else {
            b - 1;
        };
        return fl::f32_from_bits(n);
    }
    let b = fl::f64_bits(v);
    let n = if v > 0.0 == up {
        b + 1;
    } else {
        b - 1;
    };
    return fl::f64_from_bits(n);
}

// `head` then the array of `c` and `;`, as `super-c fmt` lays it out: on one line when it fits in
// 120 columns, else one element per line.
fn array(head: str, c: &Vector<f64>, out: &mut String) {
    let mut line = String::from_str(head);
    line.push_str("[");
    for k in 0..c.len() {
        if k > 0 {
            line.push_str(", ");
        }
        hex(c[k], &mut line);
    }
    line.push_str("];");
    if line.len() <= 120 {
        out.push_string(&line);
        out.push_str("\n");
        return;
    }
    out.push_str(head);
    out.push_str("[\n");
    for k in 0..c.len() {
        out.push_str("    ");
        hex(c[k], out);
        out.push_str(",\n");
    }
    out.push_str("];\n");
}

fn field(out: &mut String, name: str, v: f64) {
    out.format_into("    {}: ", name);
    hex(v, out);
    out.push_str(",\n");
}

fn konsts(r: &Ref<Z>, rq: &Ref<Q>, bits: i32, out: &mut String) {
    let p = bits as i64;
    let emax: i64 = if bits == 24 {
        127;
    } else {
        1023;
    };
    let emin = 1 - emax;
    let ty = if bits == 24 {
        "f32";
    } else {
        "f64";
    };
    let sub_bits: i64 = if bits == 24 {
        24;
    } else {
        54;
    };
    let cw_bits: i32 = if bits == 24 {
        8;
    } else {
        19;
    };
    let ln2 = r.ln2;
    let ln10 = r.ln10;
    // Overflow at (2 - 2^-p) 2^emax (the rounding boundary), underflow below half the smallest subnormal.
    let ovf = (Z::of(2.0) - Z::of(1.0).scale(-p)).scale(emax);
    let unf = Z::of(1.0).scale(emin - p);
    let lovf = r.log(ovf);
    let lunf = r.log(unf);
    out.format_into("pub const K: Konsts<{}> = Konsts::<{}> {{\n", ty, ty);
    field(out, "emin", emin as f64);
    field(out, "emax", emax as f64);
    field(out, "min_normal", Z::of(1.0).scale(emin).to_f64());
    field(out, "sub_scale", Z::of(1.0).scale(sub_bits).to_f64());
    field(out, "sub_bits", sub_bits as f64);
    let (l2h, l2l) = split(ln2, bits);
    field(out, "ln2_hi", l2h);
    field(out, "ln2_lo", l2l);
    field(out, "exp_max", below(lovf, bits));
    field(out, "exp_min", above(lunf, bits));
    field(out, "exp2_max", below(lovf / ln2, bits));
    field(out, "exp2_min", above(lunf / ln2, bits));
    field(out, "log2_10", rnd(ln10 / ln2, bits));
    let (lgh, lgl) = split(ln2 / ln10, bits);
    field(out, "lg2_hi", lgh);
    field(out, "lg2_lo", lgl);
    let (lth, ltl) = split(ln10, bits);
    field(out, "ln10_hi", lth);
    field(out, "ln10_lo", ltl);
    field(out, "exp10_max", below(lovf / ln10, bits));
    field(out, "exp10_min", above(lunf / ln10, bits));
    field(out, "expm1_min", above(r.log(Z::of(1.0).scale(-p - 1)), bits));
    field(out, "sqrt2", rnd(r.sqrt2, bits));
    let (eh, el) = split(Z::of(1.0) / ln2, bits);
    field(out, "log2e_hi", eh);
    field(out, "log2e_lo", el);
    let (th, tl) = split(Z::of(1.0) / ln10, bits);
    field(out, "log10e_hi", th);
    field(out, "log10e_lo", tl);
    let (wh, wl) = split(Z::of(2.0) / Z::of(3.0), bits);
    field(out, "two_thirds_hi", wh);
    field(out, "two_thirds_lo", wl);
    let (vh, vl) = split(Z::of(2.0) / Z::of(5.0), bits);
    field(out, "two_fifths_hi", vh);
    field(out, "two_fifths_lo", vl);
    field(out, "two_over_pi", rnd(Z::of(2.0) / r.pi, bits));
    // pi/2 in parts of bits - cw_bits bits: k pio2_i is exact for |k| < 2^cw_bits.
    let pb = bits - cw_bits;
    let p1 = trunc_bits(r.pio2, pb);
    let p2 = trunc_bits(r.pio2 - Z::of(p1), pb);
    let p3 = trunc_bits(r.pio2 - Z::of(p1) - Z::of(p2), pb);
    field(out, "pio2_1", p1);
    field(out, "pio2_2", p2);
    field(out, "pio2_3", p3);
    field(out, "pio2_4", rnd(r.pio2 - Z::of(p1) - Z::of(p2) - Z::of(p3), bits));
    // pi/2 = pio2_1 + pio2_2f + pio2_3f with the last two rounded (`rem_pio2`: k pio2_2f as an exact
    // double word).
    let p2f = rnd(r.pio2 - Z::of(p1), bits);
    field(out, "pio2_2f", p2f);
    field(out, "pio2_3f", rnd(r.pio2 - Z::of(p1) - Z::of(p2f), bits));
    field(out, "cw_max", Z::of(1.0).scale(cw_bits).to_f64());
    let (ph, pl) = split(r.pio2, bits);
    field(out, "pio2_hi", ph);
    field(out, "pio2_lo", pl);
    let (ih, il) = split(r.pi, bits);
    field(out, "pi_hi", ih);
    field(out, "pi_lo", il);
    field(out, "tan_pio8", rnd(r.sqrt2 - Z::of(1.0), bits));
    field(out, "tan_3pio8", rnd(r.sqrt2 + Z::of(1.0), bits));
    // sin x = x (1 - x^2/6 ..) rounds to x once x^2/3 < 2^-p; asinh x = log(2x) once 1/(4x^2) < 2^-p-2.
    field(out, "tiny", Z::of(1.0).scale(-(p + 1) / 2 - 1).to_f64());
    field(out, "big", Z::of(1.0).scale((p + 3) / 2).to_f64());
    // e^-2|x| below 2^-(p + 3): |x| > (p + 3) ln2 / 2, rounded up to an integer.
    let hb = ((p + 3) as f64 * 0.34657359027997264).ceil();
    field(out, "hyp_big", hb);
    field(out, "cosh_max", below(lovf + ln2, bits));
    field(out, "tanh_one", hb);
    let (sh, sl) = split(r.two_sqrtpi, bits);
    field(out, "two_sqrtpi_hi", sh);
    field(out, "two_sqrtpi_lo", sl);
    field(out, "erfc_max", erfc_max(rq, bits));
    // hi^2 below the overflow; for hi from hyp_lo, a lo that changes hi^2 + lo^2 (lo > hi 2^-(p/2 + 1))
    // has a normal square.
    field(out, "hyp_lo", Z::of(1.0).scale((emin + 1) / 2 + p / 2 + 2).to_f64());
    field(out, "hyp_hi", Z::of(1.0).scale(emax / 2 - 1).to_f64());
    field(out, "exp_norm", above(r.log(Z::of(1.0).scale(emin)), bits));
    // The 128-entry table exp: x = k ln2/128 + r, k ln2_hi/128 exact for |k| < 2^18 (every finite
    // argument of exp, 2^x and 10^x).
    let nb = bits - 18;
    field(out, "inv_ln2n", rnd(Z::of(128.0) / ln2, bits));
    let l2nh = trunc_bits(ln2 / Z::of(128.0), nb);
    field(out, "ln2n_hi", l2nh);
    field(out, "ln2n_lo", rnd(ln2 / Z::of(128.0) - Z::of(l2nh), bits));
    field(out, "inv_lg2n", rnd(Z::of(128.0) * ln10 / ln2, bits));
    let lgnh = trunc_bits(ln2 / ln10 / Z::of(128.0), nb);
    field(out, "lg2n_hi", lgnh);
    field(out, "lg2n_lo", rnd(ln2 / ln10 / Z::of(128.0) - Z::of(lgnh), bits));
    field(out, "exp10_norm", above(r.log(Z::of(1.0).scale(emin)) / ln10, bits));
    out.push_str("};\n");
}

// The 2/pi stream of f64's `rem_pio2_big`: 64 zero bits, then the bits of 2/pi after the point, 32 per
// word, as many words as its largest finite x reads (window word (2046 - 1013) / 32, then seven more).
// The f64 kernels' tables. EXP_TAB: per j < 128, 2^(j/128) rounded and the tail t with 2^(j/128) =
// hi (1 + t). LOG_TAB: per cell i < 128 of z in [0x1.6p-1, 0x1.6p0) (bits 0x3fe6000000000000 + i 2^45
// on), invc and log(1/invc) as a double word: invc 1 in the two cells around 1, else 1/c rounded to a
// multiple of 2^-7 (invc >= 1) or 2^-8, so that r = z invc - 1 is exact: |r| < 2^-7 (checked).
fn f64_tables(r: &Ref<Z>, out: &mut String) {
    let mut e = Vector::<f64>::new();
    for j in 0..128 {
        let v = r.exp(Z::of(j as f64 / 128.0) * r.ln2);
        let hi = v.to_f64();
        e.push(hi);
        e.push(((v - Z::of(hi)) / Z::of(hi)).to_f64());
    }
    out.push_str("\n/// 2^(j/128) as hi and hi (1 + tail), per j (`expk`).\n");
    array("pub const EXP_TAB: [f64; 256] = ", &e, out);
    let mut l = Vector::<f64>::new();
    for i in 0..128 {
        let zlo = fl::f64_from_bits(0x3fe6000000000000u64 + (i as u64 << 45));
        let zhi = fl::f64_from_bits(0x3fe6000000000000u64 + (i as u64 + 1 << 45) - 1); // the last z of the cell
        let invc = if zlo >= 1.0 - 0x1p-8 && zhi <= 1.0 + 0x1p-7 {
            1.0;
        } else {
            let ic = 2.0 / (zlo + zhi);
            let g = if ic >= 1.0 {
                128.0;
            } else {
                256.0;
            };
            (ic * g).round() / g;
        };
        let rmax = (zlo * invc - 1.0).abs().max((zhi * invc - 1.0).abs());
        assert(rmax < 0x1p-7, "gen: a log table cell's r reaches 2^-7");
        let lc = Z::of(0.0) - r.log(Z::of(invc));
        let (h, lo) = split(lc, 53);
        l.push(invc);
        l.push(h);
        l.push(lo);
    }
    out.push_str("\n/// Per cell of z: invc, log(1/invc) as hi and lo (`log_parts`, `logk`).\n");
    array("pub const LOG_TAB: [f64; 384] = ", &l, out);
}

fn two_over_pi(out: &mut String) {
    let words = two_over_pi_words();
    let (w, n, pad) = (32, (2046 - 1013) / 32 + 8, 64);
    out.format_into(
        "\n/// 2/pi for `rem_pio2_big`: {} zero bits, then the bits of 2/pi after the point, {} per word.\npub const TWO_OVER_PI: [u64; {}] = [\n",
        pad,
        w,
        n,
    );
    for k in 0..n {
        // Stream bit j (0-based) is 2/pi bit j - pad + 1.
        let mut v: u64 = 0;
        for b in 0..w {
            let j = (k * w + b) as i64 - pad as i64;
            let bit: u64 = if j < 0 {
                0;
            } else {
                (unsafe words[(j / 32) as usize]) as u64 >> (31 - j % 32) as u64 & 1;
            };
            v = v << 1 | bit;
        }
        out.push_str("    ");
        out.push_str("0x");
        out.push_hex(v, false);
        out.push_str(",\n");
    }
    out.push_str("];\n");
}

// One fit's slot: its grids (shared by both lane types), and the coefficients and weighted error it
// found for the lane type at hand.
struct Slot {
    pub i: usize,
    pub g: Grid<Q>,
    pub dense: Grid<Q>,
    pub c: Vector<f64>,
    pub lg: f64,
}

fn empty_grid() Grid<Q> {
    return Grid::<Q> { z: Vector::<Q>::new(), g: Vector::<Q>::new(), w: Vector::<Q>::new() };
}

// `n` slots, the grids of each from `build(i)`, in parallel.
fn slots(n: usize, build: fn(usize) (Grid<Q>, Grid<Q>)) Vector<Slot> {
    let mut v = Vector::<Slot>::with_capacity(n);
    for i in 0..n {
        v.push(Slot { i: i, g: empty_grid(), dense: empty_grid(), c: Vector::<f64>::new(), lg: 0.0 });
    }
    parallel::chunks_mut_with(
        v.index_range_mut(0..n),
        1,
        ONE_EACH,
        |slot: []mut Slot| {
            let (g, dense) = build(slot[0].i);
            slot[0].g = g;
            slot[0].dense = dense;
        },
    );
    return v;
}

// The specs' grids: the fit's and one four times as dense.
fn spec_grids(i: usize) (Grid<Q>, Grid<Q>) {
    let r = unsafe &*COS_REF;
    let sp = specs();
    let s = sp.at(i);
    return grid(r, s, M_FIT), grid(r, s, 4 * M_FIT);
}

// The erfc pieces' grids: the fit's and one twice as dense.
fn piece_grids(i: usize) (Grid<Q>, Grid<Q>) {
    let r = unsafe &*COS_REF;
    let (lo, hi) = piece(i);
    return piece_grid(r, lo, hi, M_PIECE), piece_grid(r, lo, hi, 2 * M_PIECE);
}

fn polys(sp: &Vector<Spec>, fits: &mut Vector<Slot>, bits: i32, out: &mut String) {
    let ty = if bits == 24 {
        "f32";
    } else {
        "f64";
    };
    parallel::chunks_mut_with(
        fits.index_range_mut(0..sp.len()),
        1,
        ONE_EACH,
        |slot: []mut Slot| {
            let s = sp.at(slot[0].i);
            let target = if bits == 24 {
                s.err32;
            } else {
                s.err64;
            };
            let (c, lg) = fit_grid(&slot[0].g, &slot[0].dense, false, bits, target);
            slot[0].c = c;
            slot[0].lg = lg;
        },
    );
    let mut sw = String::new();
    let mut names = Vector::<String>::new();
    for i in 0..sp.len() {
        let s = sp.at(i);
        let c = &fits[i].c;
        let lg = fits[i].lg;
        report(s.name, bits, c.len() - 1, lg);
        let mut up = String::new();
        for ch in s.name.bytes() {
            if ch >= b'A' && ch <= b'Z' && up.len() > 0 {
                up.push_byte(b'_');
            }
            up.push_byte(
                if ch >= b'a' && ch <= b'z' {
                    ch - 32;
                } else {
                    ch;
                },
            );
        }
        // A polynomial equal to an earlier one is that one's array.
        let mut same = i;
        for j in 0..i {
            if fits[j].c.eq(c) {
                same = j;
                break;
            }
        }
        if same != i {
            sw.format_into("        {} => horner(z, &{}),\n", s.name, names[same].as_str());
            names.push(names[same].clone());
            continue;
        }
        out.format_into("\n/// {}; {} in [", s.what, s.var);
        hex(s.lo, out);
        out.push_str(", ");
        hex(s.hi, out);
        out.format_into("], degree {}, weighted error 2^-{}.\n", c.len() - 1, (lg * 10.0).floor() / 10.0);
        let mut head = String::new();
        head.format_into("const {}: [{}; {}] = ", up.as_str(), ty, c.len());
        array(head.as_str(), c, out);
        sw.format_into("        {} => horner(z, &{}),\n", s.name, up.as_str());
        names.push(up);
    }
    out.format_into(
        "\n/// Polynomial `P` of the kernels at `z`.\npub const fn poly<const P: Poly, const N: usize>(z: Simd<{}, N>) Simd<{}, N> {{\n    return switch P {{\n",
        ty,
        ty,
    );
    out.push_string(&sw);
    out.push_str("    };\n}\n");
}

// A fit per claim: few heavy units, spread over every worker.
const ONE_EACH: parallel::Options = parallel::Options { schedule: parallel::Schedule::Dynamic, grain_size: 1 };

// erfc past this rounds to 0 with a factor 2 to spare: the smallest half-integer past the x with
// erfc(x) = 2^(emin - p - 2), a quarter of the smallest subnormal.
fn erfc_max(r: &Ref<Q>, bits: i32) f64 {
    let tiny = q(1.0).scale(
        if bits == 24 {
            -152;
        } else {
            -1077;
        },
    );
    let mut lo = 1.0;
    let mut hi = 40.0;
    for _ in 0..60 {
        let mid = (lo + hi) * 0.5;
        if tiny.lt(r.erfc(mid)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return (hi * 2.0).ceil() * 0.5;
}

// The pieces of the erfc table: 8 per binade from 1/2 (a wider piece would leave the rounding of the
// linear coefficient above the target), up to the one that holds `erfc_max`.
fn erfc_pieces(r: &Ref<Q>, bits: i32) usize {
    let top = erfc_max(r, bits);
    for n in 1usize..64 {
        let (_, hi) = piece(n - 1);
        if hi > top {
            return n;
        }
    }
    panic("gen: the erfc table needs more than 63 pieces");
}

// Piece i: [lo, hi) = 2^(i/8 - 1) [1 + (i%8)/8, 1 + (i%8 + 1)/8).
const fn piece(i: usize) (f64, f64) {
    let e = fl::f64_from_bits((1022 + i / 8) as u64 << 52);
    return e * (1.0 + (i % 8) as f64 * 0.125), e * (1.0 + (i % 8 + 1) as f64 * 0.125);
}

// g(x) = erfc(x) e^(x^2) on a grid of [lo, hi), weighted relative to g, the abscissa u = x - mid.
fn piece_grid(r: &Ref<Q>, lo: f64, hi: f64, m: usize) Grid<Q> {
    let mid = (lo + hi) * 0.5;
    let mut g = empty_grid();
    let xs = Grid::<Q>::lobatto(lo, hi, m, cos_node);
    for i in 0..m {
        let x = q(xs[i]);
        let v = r.erfc(xs[i]) * r.exp(x * x);
        g.z.push(x - q(mid));
        g.g.push(v);
        g.w.push(q(1.0) / v);
    }
    return g;
}

// The erfc table of `np` pieces: per piece its midpoint, then P(u) ~ g(mid + u) lowest power first with
// the constant term as hi and lo; one degree for all pieces, the smallest that meets the target in each.
fn erfc_table(ps: &mut Vector<Slot>, np: usize, bits: i32, out: &mut String) {
    let ty = if bits == 24 {
        "f32";
    } else {
        "f64";
    };
    // 2^-(p + 4): a sixteenth of an ULP at most.
    let target = (bits + 4) as f64;
    // In parallel: the coefficient count each piece needs alone; then every piece again at the largest
    // count (one stride for the table).
    parallel::chunks_mut_with(
        ps.index_range_mut(0..np),
        1,
        ONE_EACH,
        |slot: []mut Slot| {
            let (c, _) = fit_grid(&slot[0].g, &slot[0].dense, true, bits, target);
            slot[0].c = c;
        },
    );
    let mut n: usize = 0;
    for i in 0..np {
        n = n.max(ps[i].c.len() - 1);
    }
    parallel::chunks_mut_with(
        ps.index_range_mut(0..np),
        1,
        ONE_EACH,
        |slot: []mut Slot| {
            let (c, lg) = fit_n(&slot[0].g, &slot[0].dense, true, n, bits);
            slot[0].c = c;
            slot[0].lg = lg;
        },
    );
    let stride = n + 2;
    let mut worst: f64 = 1000.0;
    let mut body = String::new();
    for i in 0..np {
        let (lo, hi) = piece(i);
        let c = &ps[i].c;
        worst = worst.min(ps[i].lg);
        // One element per line, as `super-c fmt` lays out an array this long.
        body.push_str("    ");
        hex((lo + hi) * 0.5, &mut body);
        body.push_str(",\n");
        for k in 0..c.len() {
            body.push_str("    ");
            hex(c[k], &mut body);
            body.push_str(",\n");
        }
    }
    report("ErfcTab", bits, n - 1, worst);
    let (_, top) = piece(np - 1);
    out.format_into(
        "\n/// erfc(a) e^(a^2) for a in [1/2, {}), piece i on 2^(i/8 - 1) [1 + (i%8)/8, 1 + (i%8 + 1)/8): its\n",
        top,
    );
    out.format_into(
        "/// midpoint, then P with P(u) ~ g(mid + u), lowest power first, the constant as hi and lo; degree\n",
    );
    out.format_into(
        "/// {}, relative error 2^-{}.\npub const ERFC_TAB: [{}; {}] = [\n",
        n - 1,
        (worst * 10.0).floor() / 10.0,
        ty,
        np * stride,
    );
    out.push_string(&body);
    out.format_into(
        "];\n\n/// erfc(a) e^(a^2) as a double word from piece `i` of `ERFC_TAB`.\npub fn erfc_g<const N: usize>(a: Simd<{}, N>, i: Simd<{}, N>) (Simd<{}, N>, Simd<{}, N>) {{\n    let (h, l) = table_poly::<{}, N, {}>(a, i, ERFC_TAB);\n    return h, l;\n}}\n",
        ty,
        ty,
        ty,
        ty,
        ty,
        stride,
    );
}

// Points of a piece's fit grid.
const M_PIECE: usize = 160;

fn write(path: str, text: &String) {
    let f = stdio::fopen(path, "wb");
    assert(f != null, "gen: cannot open the output file");
    let n = unsafe stdio::fwrite(text.as_str().ptr(), 1, text.len(), f);
    assert(n == text.len() && unsafe stdio::fclose(f) == 0, "gen: cannot write the output file");
}

fn main(args: Vector<str>) i32 {
    let mut dir = "std/simd/math";
    for i in 1..args.len() {
        let a = args[i];
        if a.starts_with("--jobs=") {
            runtime::set_worker_count(a.slice(7, a.len()).parse_u64().unwrap() as usize);
        } else {
            dir = a;
        }
    }
    let r = Ref::<Q>::new();
    let rz = Ref::<Z>::new();
    let tan_t = tan_series();
    unsafe COS_REF = &r;
    unsafe TAN_T = &tan_t;
    // The grids, once for both lane types: the pieces f32 needs are the first of f64's.
    let sp = specs();
    let mut fits = slots(sp.len(), spec_grids);
    let mut pieces = slots(erfc_pieces(&r, 53), piece_grids);
    for bits in [24, 53] {
        let mut out = String::new();
        out.format_into(
            "// Generated by tools/simd_math/gen.spc: the {} constants{} and the minimax polynomials of the math\n// kernels (`lane.spc`). Do not edit; rerun the generator.\nimport std::simd::math::lane as *;\n\n",
            if bits == 24 {
                "f32";
            } else {
                "f64";
            },
            if bits == 24 {
                "";
            } else {
                ", the bits of 2/pi";
            },
        );
        konsts(&rz, &r, bits, &mut out);
        if bits == 53 {
            two_over_pi(&mut out);
            f64_tables(&rz, &mut out);
        }
        polys(&sp, &mut fits, bits, &mut out);
        erfc_table(&mut pieces, erfc_pieces(&r, bits), bits, &mut out);
        let mut path = String::from_str(dir);
        path.push_str(
            if bits == 24 {
                "/coeffs_f32.spc";
            } else {
                "/coeffs_f64.spc";
            },
        );
        write(path.as_str(), &out);
    }
    return 0;
}
