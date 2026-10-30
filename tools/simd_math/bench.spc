// The performance check of the vector math classes: per function and lane type, nanoseconds per
// element of each class and of the scalar C library loop over the same inputs, the ratios, and the
// class gates on this target: precise not slower than the library loop; balanced at least 20% faster
// than precise and fast at least 20% faster than balanced for exp, log, sin and cos, and faster for
// every other function. A failed gate prints a `gate:` line and the exit status is 1. Inputs spread
// as the functions' users meet them: wide ranges log-uniform per binade. Every call is direct (a
// const generic selects it), so it inlines as in a user's loop.
//
//   super-c release tools/simd_math --bin=simd-math-bench
//   tools/simd_math/build/release-bin-simd-math-bench/simd-math-bench [--only=NAME]
import std::parallel::platform as platform;
import std::simd::math as mp;
import std::simd::math::balanced as mb;
import std::simd::math::fast as mf;
import std::simd::math::lane as ln;

extern "C" {
    @unsafe(safe)
    fn erff(x: f32) f32;
    @unsafe(safe)
    fn erfcf(x: f32) f32;
    @unsafe(safe)
    fn erf(x: f64) f64;
    @unsafe(safe)
    fn erfc(x: f64) f64;
}

const ELEMS: usize = 4096; // in L1: the kernels, not memory, are measured
// The lanes of one hardware register: 16 bytes on aarch64 (Neon), 32 elsewhere (AVX2).
const N32: usize = if ARCH == Arch::AArch64 {
    4
} else {
    8
};
const N64: usize = N32 / 2;
const ROUNDS: usize = 100;
const TRIALS: usize = 9;

/// The classes measured.
const CLASSES: usize = 3;
const CLASS_NAMES: [str<'static>; 3] = ["precise", "balanced", "fast"];

/// The functions measured, by name.
pub enum Fun {
    Exp,
    Exp2,
    Exp10,
    Expm1,
    Log,
    Log2,
    Log10,
    Log1p,
    Cbrt,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Sinh,
    Cosh,
    Tanh,
    Asinh,
    Acosh,
    Atanh,
    Erf,
    Erfc,
    Pow,
    Powi,
    Hypot,
    Atan2,
    Sincos,
}

// Function `F` of class `C` at `x` (and `y`: the second argument, a float holding powi's integer).
fn call<const F: Fun, const C: usize, T: ln::Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    return switch C {
        0 => call_p::<F, T, N>(x, y),
        1 => call_b::<F, T, N>(x, y),
        _ => call_f::<F, T, N>(x, y),
    };
}

fn call_p<const F: Fun, T: ln::Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let _ = y;
    return switch F {
        Exp => mp::exp(x),
        Exp2 => mp::exp2(x),
        Exp10 => mp::exp10(x),
        Expm1 => mp::expm1(x),
        Log => mp::log(x),
        Log2 => mp::log2(x),
        Log10 => mp::log10(x),
        Log1p => mp::log1p(x),
        Cbrt => mp::cbrt(x),
        Sin => mp::sin(x),
        Cos => mp::cos(x),
        Tan => mp::tan(x),
        Asin => mp::asin(x),
        Acos => mp::acos(x),
        Atan => mp::atan(x),
        Sinh => mp::sinh(x),
        Cosh => mp::cosh(x),
        Tanh => mp::tanh(x),
        Asinh => mp::asinh(x),
        Acosh => mp::acosh(x),
        Atanh => mp::atanh(x),
        Erf => mp::erf(x),
        Erfc => mp::erfc(x),
        Pow => mp::pow(x, y),
        Powi => mp::powi(x, y.cast::<i32>()),
        Hypot => mp::hypot(x, y),
        Atan2 => mp::atan2(x, y),
        Sincos => sincos_sum_p(x),
    };
}

fn sincos_sum_p<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (s, c) = mp::sincos(x);
    return s + c;
}

fn call_b<const F: Fun, T: ln::Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let _ = y;
    return switch F {
        Exp => mb::exp(x),
        Exp2 => mb::exp2(x),
        Exp10 => mb::exp10(x),
        Expm1 => mb::expm1(x),
        Log => mb::log(x),
        Log2 => mb::log2(x),
        Log10 => mb::log10(x),
        Log1p => mb::log1p(x),
        Cbrt => mb::cbrt(x),
        Sin => mb::sin(x),
        Cos => mb::cos(x),
        Tan => mb::tan(x),
        Asin => mb::asin(x),
        Acos => mb::acos(x),
        Atan => mb::atan(x),
        Sinh => mb::sinh(x),
        Cosh => mb::cosh(x),
        Tanh => mb::tanh(x),
        Asinh => mb::asinh(x),
        Acosh => mb::acosh(x),
        Atanh => mb::atanh(x),
        Erf => mp::erf(x), // not timed: balanced and fast have no erf
        Erfc => mb::erfc(x),
        Pow => mb::pow(x, y),
        Powi => mb::powi(x, y.cast::<i32>()),
        Hypot => mb::hypot(x, y),
        Atan2 => mb::atan2(x, y),
        Sincos => sincos_sum_b(x),
    };
}

fn sincos_sum_b<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (s, c) = mb::sincos(x);
    return s + c;
}

fn call_f<const F: Fun, T: ln::Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let _ = y;
    return switch F {
        Exp => mf::exp(x),
        Exp2 => mf::exp2(x),
        Exp10 => mf::exp10(x),
        Expm1 => mf::expm1(x),
        Log => mf::log(x),
        Log2 => mf::log2(x),
        Log10 => mf::log10(x),
        Log1p => mf::log1p(x),
        Cbrt => mf::cbrt(x),
        Sin => mf::sin(x),
        Cos => mf::cos(x),
        Tan => mf::tan(x),
        Asin => mf::asin(x),
        Acos => mf::acos(x),
        Atan => mf::atan(x),
        Sinh => mf::sinh(x),
        Cosh => mf::cosh(x),
        Tanh => mf::tanh(x),
        Asinh => mf::asinh(x),
        Acosh => mf::acosh(x),
        Atanh => mf::atanh(x),
        Erf => mp::erf(x), // not timed: balanced and fast have no erf
        Erfc => mb::erfc(x),
        Pow => mf::pow(x, y),
        Powi => mf::powi(x, y.cast::<i32>()),
        Hypot => mf::hypot(x, y),
        Atan2 => mf::atan2(x, y),
        Sincos => sincos_sum_f(x),
    };
}

fn sincos_sum_f<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (s, c) = mf::sincos(x);
    return s + c;
}

// The C library's function `F` at `x` (and `y`).
fn lib32<const F: Fun>(x: f32, y: f32) f32 {
    let _ = y;
    let t10: f32 = 10.0;
    return switch F {
        Exp => x.exp(),
        Exp2 => x.exp2(),
        Exp10 => t10.powf(x),
        Expm1 => x.exp_m1(),
        Log => x.ln(),
        Log2 => x.log2(),
        Log10 => x.log10(),
        Log1p => x.ln_1p(),
        Cbrt => x.cbrt(),
        Sin => x.sin(),
        Cos => x.cos(),
        Tan => x.tan(),
        Asin => x.asin(),
        Acos => x.acos(),
        Atan => x.atan(),
        Sinh => x.sinh(),
        Cosh => x.cosh(),
        Tanh => x.tanh(),
        Asinh => x.asinh(),
        Acosh => x.acosh(),
        Atanh => x.atanh(),
        Erf => erff(x),
        Erfc => erfcf(x),
        Pow => x.powf(y),
        Powi => x.powi(y as i32),
        Hypot => x.hypot(y),
        Atan2 => x.atan2(y),
        Sincos => sc32(x),
    };
}

const fn sc32(x: f32) f32 {
    let (s, c) = x.sin_cos();
    return s + c;
}

// The C library's function `F` at `x` (and `y`).
fn lib64<const F: Fun>(x: f64, y: f64) f64 {
    let _ = y;
    let t10: f64 = 10.0;
    return switch F {
        Exp => x.exp(),
        Exp2 => x.exp2(),
        Exp10 => t10.powf(x),
        Expm1 => x.exp_m1(),
        Log => x.ln(),
        Log2 => x.log2(),
        Log10 => x.log10(),
        Log1p => x.ln_1p(),
        Cbrt => x.cbrt(),
        Sin => x.sin(),
        Cos => x.cos(),
        Tan => x.tan(),
        Asin => x.asin(),
        Acos => x.acos(),
        Atan => x.atan(),
        Sinh => x.sinh(),
        Cosh => x.cosh(),
        Tanh => x.tanh(),
        Asinh => x.asinh(),
        Acosh => x.acosh(),
        Atanh => x.atanh(),
        Erf => erf(x),
        Erfc => erfc(x),
        Pow => x.powf(y),
        Powi => x.powi(y as i32),
        Hypot => x.hypot(y),
        Atan2 => x.atan2(y),
        Sincos => sc64(x),
    };
}

const fn sc64(x: f64) f64 {
    let (s, c) = x.sin_cos();
    return s + c;
}

// Deterministic inputs: a linear congruential stream mapped to [lo, hi).
struct Rng {
    pub s: u64,
}

extend Rng {
    pub const fn next(self: &mut Rng, lo: f64, hi: f64) f64 {
        self.s = self.s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        return lo + (hi - lo) * ((self.s >> 11) as f64 * 0x1p-53);
    }
}

static mut SINK: f64 = 0.0;

// The best of `TRIALS` timings of `ROUNDS` passes of class `C` mapping the inputs into `out`, in
// nanoseconds per element (a map, as a user's loop: the iterations are independent).
fn vec<const F: Fun, const C: usize, T: ln::Lane, const N: usize>(
    xs: &Vector<Simd<T, N>>,
    ys: &Vector<Simd<T, N>>,
    out: &mut Vector<Simd<T, N>>,
) f64 {
    let mut best: u64 = 0xFFFFFFFFFFFFFFFF;
    for _ in 0..TRIALS {
        let t0 = platform::now_ns();
        for _ in 0..ROUNDS {
            for i in 0..xs.len() {
                out[i] = call::<F, C, T, N>(xs[i], ys[i]);
            }
        }
        best = best.min(platform::now_ns() - t0);
    }
    unsafe SINK += out[0][0] as f64;
    return best as f64 / (ROUNDS * ELEMS) as f64;
}

fn lib_loop32<const F: Fun>(xs: &Vector<f32>, ys: &Vector<f32>, out: &mut Vector<f32>) f64 {
    let mut best: u64 = 0xFFFFFFFFFFFFFFFF;
    for _ in 0..TRIALS {
        let t0 = platform::now_ns();
        for _ in 0..ROUNDS {
            for i in 0..xs.len() {
                out[i] = lib32::<F>(xs[i], ys[i]);
            }
        }
        best = best.min(platform::now_ns() - t0);
    }
    unsafe SINK += out[0];
    return best as f64 / (ROUNDS * ELEMS) as f64;
}

fn lib_loop64<const F: Fun>(xs: &Vector<f64>, ys: &Vector<f64>, out: &mut Vector<f64>) f64 {
    let mut best: u64 = 0xFFFFFFFFFFFFFFFF;
    for _ in 0..TRIALS {
        let t0 = platform::now_ns();
        for _ in 0..ROUNDS {
            for i in 0..xs.len() {
                out[i] = lib64::<F>(xs[i], ys[i]);
            }
        }
        best = best.min(platform::now_ns() - t0);
    }
    unsafe SINK += out[0];
    return best as f64 / (ROUNDS * ELEMS) as f64;
}

// An input distribution: uniform on [lo, hi), or (`log`) off + m 2^e with e uniform on [lo, hi) as
// binade exponents, m uniform on [1, 2), negative half the time when `sign`.
struct Dist {
    pub lo: f64,
    pub hi: f64,
    pub log: bool,
    pub sign: bool,
    pub off: f64,
}

const fn uni(lo: f64, hi: f64) Dist {
    return Dist { lo: lo, hi: hi, log: false, sign: false, off: 0.0 };
}

const fn logu(lo: f64, hi: f64, sign: bool, off: f64) Dist {
    return Dist { lo: lo, hi: hi, log: true, sign: sign, off: off };
}

const fn draw(g: &mut Rng, d: &Dist) f64 {
    if !d.log {
        return g.next(d.lo, d.hi);
    }
    let e = g.next(d.lo, d.hi).floor() as i64;
    let v = g.next(1.0, 2.0) * Simd::<f64, 2>::from_bits(Simd::<u64, 2>::splat((1023 + e) as u64 << 52))[0];
    return d.off + if d.sign && g.next(0.0, 1.0) < 0.5 {
        -v
    } else {
        v
    };
}

// The inputs of `d`: per lane type, as vectors and as scalars.
fn args(g: &mut Rng, d: &Dist) (Vector<Simd<f32, N32>>, Vector<f32>, Vector<Simd<f64, N64>>, Vector<f64>) {
    let mut v32 = Vector::<Simd<f32, N32>>::with_capacity(ELEMS / N32);
    let mut s32 = Vector::<f32>::with_capacity(ELEMS);
    let mut v64 = Vector::<Simd<f64, N64>>::with_capacity(ELEMS / N64);
    let mut s64 = Vector::<f64>::with_capacity(ELEMS);
    for _ in 0..ELEMS / N32 {
        let mut a: [f32; N32] = [0.0; N32];
        for j in 0..N32 {
            let x = draw(g, d) as f32;
            unsafe a[j] = x;
            s32.push(x);
        }
        v32.push(Simd::<f32, N32>::from_array(a));
    }
    for _ in 0..ELEMS / N64 {
        let mut a: [f64; N64] = [0.0; N64];
        for j in 0..N64 {
            let x = draw(g, d);
            unsafe a[j] = x;
            s64.push(x);
        }
        v64.push(Simd::<f64, N64>::from_array(a));
    }
    return (v32, s32, v64, s64);
}

static mut FAILED: usize = 0;

// A gate: `ratio` (a speedup) at least `need`, else a `gate:` line and a failure.
fn gate(name: str, t: i32, what: str, ratio: f64, need: f64) {
    if ratio < need {
        println("gate: {} f{}: {} {}x, needs {}x", name, t, what, ratio, need);
        unsafe FAILED += 1;
    }
}

// One line per function and lane type: ns per element of the library loop and each class, with the
// ratios the gates use; then the gates.
fn line(name: str, t: i32, lib: f64, cls: &[f64; 3]) {
    let mut s = String::new();
    s.format_into("{} f{}: libm {}", name, t, lib);
    // erf is precise only, erfc precise and balanced.
    let nc = if name == "erf" {
        1usize
    } else if name == "erfc" {
        2
    } else {
        CLASSES
    };
    for c in 0..nc {
        s.format_into(", {} {} ({}x libm", unsafe CLASS_NAMES[c], unsafe cls[c], lib / unsafe cls[c]);
        if c > 0 {
            s.format_into(", {}x {}", unsafe cls[c - 1] / unsafe cls[c], unsafe CLASS_NAMES[c - 1]);
        }
        s.push_str(")");
    }
    println("{}", s.as_str());
    let main4 = name == "exp" || name == "log" || name == "sin" || name == "cos";
    let need = if main4 {
        1.2
    } else {
        1.0
    };
    gate(name, t, "precise vs libm", lib / cls[0], 1.0);
    for c in 1..nc {
        gate(name, t, unsafe CLASS_NAMES[c], unsafe cls[c - 1] / unsafe cls[c], need);
    }
}

// Function `F` over x from `dx` and y from `dy`: every class and the library loop, both lane types.
fn bench<const F: Fun>(name: str, only: str, g: &mut Rng, dx: Dist, dy: Dist) {
    if only.len() != 0 && name != only {
        return;
    }
    let (x32, xs32, x64, xs64) = args(g, &dx);
    let (y32, ys32, y64, ys64) = args(g, &dy);
    let du = uni(0.0, 1.0);
    let (mut o32, mut os32, mut o64, mut os64) = args(g, &du);
    let mut c32: [f64; 3] = [0.0; 3];
    let mut c64: [f64; 3] = [0.0; 3];
    c32[0] = vec::<F, 0, f32, N32>(&x32, &y32, &mut o32);
    c64[0] = vec::<F, 0, f64, N64>(&x64, &y64, &mut o64);
    c32[1] = vec::<F, 1, f32, N32>(&x32, &y32, &mut o32);
    c64[1] = vec::<F, 1, f64, N64>(&x64, &y64, &mut o64);
    c32[2] = vec::<F, 2, f32, N32>(&x32, &y32, &mut o32);
    c64[2] = vec::<F, 2, f64, N64>(&x64, &y64, &mut o64);
    line(name, 32, lib_loop32::<F>(&xs32, &ys32, &mut os32), &c32);
    line(name, 64, lib_loop64::<F>(&xs64, &ys64, &mut os64), &c64);
}

fn main(argv: Vector<str>) i32 {
    let mut only = "";
    for i in 1..argv.len() {
        if argv[i].starts_with("--only=") {
            only = argv[i].slice(7, argv[i].len());
        }
    }
    // Half a second of work first: the core's clock ramps up before the first function is timed.
    let w0 = platform::now_ns();
    let mut spin: u64 = 1;
    while platform::now_ns() - w0 < 500000000 {
        for _ in 0..10000 {
            spin = spin.wrapping_mul(6364136223846793005).wrapping_add(1);
        }
    }
    unsafe SINK += (spin & 1) as f64;
    let mut g = Rng { s: 0x5EED };
    let one = uni(0.0, 1.0);
    bench::<{Fun::Exp}>("exp", only, &mut g, uni(-80.0, 80.0), one);
    bench::<{Fun::Exp2}>("exp2", only, &mut g, uni(-120.0, 120.0), one);
    bench::<{Fun::Exp10}>("exp10", only, &mut g, uni(-35.0, 35.0), one);
    bench::<{Fun::Expm1}>("expm1", only, &mut g, logu(-30.0, 3.0, true, 0.0), one);
    bench::<{Fun::Log}>("log", only, &mut g, logu(-100.0, 100.0, false, 0.0), one);
    bench::<{Fun::Log2}>("log2", only, &mut g, logu(-100.0, 100.0, false, 0.0), one);
    bench::<{Fun::Log10}>("log10", only, &mut g, logu(-100.0, 100.0, false, 0.0), one);
    bench::<{Fun::Log1p}>("log1p", only, &mut g, logu(-30.0, 20.0, false, 0.0), one);
    bench::<{Fun::Cbrt}>("cbrt", only, &mut g, logu(-100.0, 100.0, true, 0.0), one);
    bench::<{Fun::Sin}>("sin", only, &mut g, uni(-100.0, 100.0), one);
    bench::<{Fun::Cos}>("cos", only, &mut g, uni(-100.0, 100.0), one);
    bench::<{Fun::Tan}>("tan", only, &mut g, uni(-100.0, 100.0), one);
    bench::<{Fun::Asin}>("asin", only, &mut g, uni(-1.0, 1.0), one);
    bench::<{Fun::Acos}>("acos", only, &mut g, uni(-1.0, 1.0), one);
    bench::<{Fun::Atan}>("atan", only, &mut g, logu(-20.0, 20.0, true, 0.0), one);
    bench::<{Fun::Sinh}>("sinh", only, &mut g, uni(-80.0, 80.0), one);
    bench::<{Fun::Cosh}>("cosh", only, &mut g, uni(-80.0, 80.0), one);
    bench::<{Fun::Tanh}>("tanh", only, &mut g, uni(-20.0, 20.0), one);
    bench::<{Fun::Asinh}>("asinh", only, &mut g, logu(-20.0, 30.0, true, 0.0), one);
    bench::<{Fun::Acosh}>("acosh", only, &mut g, logu(-20.0, 30.0, false, 1.0), one);
    bench::<{Fun::Atanh}>("atanh", only, &mut g, uni(-1.0, 1.0), one);
    bench::<{Fun::Erf}>("erf", only, &mut g, uni(-5.0, 5.0), one);
    bench::<{Fun::Erfc}>("erfc", only, &mut g, uni(-5.0, 25.0), one);
    bench::<{Fun::Pow}>("pow", only, &mut g, logu(-10.0, 10.0, false, 0.0), uni(-20.0, 20.0));
    bench::<{Fun::Powi}>("powi", only, &mut g, uni(-10.0, 10.0), uni(-30.0, 30.0));
    bench::<{Fun::Hypot}>("hypot", only, &mut g, logu(-30.0, 30.0, true, 0.0), logu(-30.0, 30.0, true, 0.0));
    bench::<{Fun::Atan2}>("atan2", only, &mut g, uni(-10.0, 10.0), uni(-10.0, 10.0));
    bench::<{Fun::Sincos}>("sincos", only, &mut g, uni(-100.0, 100.0), one);
    println("gates failed: {}", unsafe FAILED);
    return if unsafe SINK == 0.123 || unsafe FAILED != 0 {
        1
    } else {
        0
    };
}
