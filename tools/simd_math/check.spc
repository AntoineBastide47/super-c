// The accuracy check of the vector math classes: per function, lane type and class, the largest error
// (ULP for `precise` and `balanced`, relative for `fast`), the input that produced it and the count
// of results over the class bound (which must be 0). f32: every one of the 2^32 inputs of a
// one-argument function (or `--sample32` random ones), shaped random pairs for the others, against
// the f64 C library, whose error is far below an f32 ULP. f64: `--n` inputs per function (uniform
// per binade of the domain, the neighbors of special points, multiples of pi/2, random bits) against
// the double-word reference (`ref.spc`), every result within 0.01 ULP of the bound (and every zero or
// subnormal one) again against f128. First, per function, the special-value table: signed zeros,
// infinities, NaN, the subnormal and normal extremes, small values and every threshold of the lane
// constants with its neighbors; a special input (a zero, an infinity, NaN) must give the C library's
// result exactly (fast: NaN and infinities exactly, zeros within the bound and with the sign).
//
//   super-c release tools/simd_math --bin=simd-math-check
//   tools/simd_math/build/release-bin-simd-math-check/simd-math-check
//       [--f32] [--f64] [--only=NAME] [--part=K/N] [--n=COUNT] [--sample32=COUNT] [--jobs=N] [--write]
//
// `--jobs=N` runs N worker threads (default one per CPU).
// `--write` (with every function and both lane types) replaces the measured table at the top of each
// class module (run from the repository root); the exit status is 1 when any result is over its
// bound or a special value is wrong.
import real as *;
import ref as *;
import std::float as fl;
import std::parallel::data as parallel;
import std::parallel::runtime as runtime;
import std::simd::math as mp;
import std::simd::math::balanced as mb;
import std::simd::math::fast as mf;
import std::simd::math::lane as ln;
import std::simd::math::coeffs_f32 as c32;
import std::simd::math::coeffs_f64 as c64;
import math;
import stdio;

type Q = fl::f128;
type V32 = Simd<f32, 8>;
type V64 = Simd<f64, 4>;

extern "C" {
    @unsafe(safe)
    fn erfc(x: f64) f64;
}

/// The classes, by bound: precise (1.0 ULP), balanced (3.5 ULP), fast (relative 2^-11 or 2^-22).
pub const CLASSES: usize = 3;
const CLASS_NAMES: [str<'static>; 3] = ["precise", "balanced", "fast"];

// One function of one argument: its forms per class and lane type, the C library and the references.
struct F1 {
    pub name: str<'static>,
    pub v32: [fn(V32) V32; CLASSES],
    pub v64: [fn(V64) V64; CLASSES],
    pub lib: fn(f64) f64,
    pub dw: fn(&Ref<Dw>, f64) Dw,
    pub q: fn(&Ref<Q>, f64) Q,
    pub lo: f64, // the domain the f64 sampling covers
    pub hi: f64,
    pub kind: u8, // K_PLAIN, K_TRIG: the samples near multiples of pi/2
    pub has: u32, // bit c: class c has the function (erf: precise only; erfc: precise and balanced)
    pub fmax32: f64, // the largest |x| of the fast class's range, per lane type
    pub fmax64: f64,
    pub fsub: bool, // the fast class takes a subnormal argument as 0
}

const INF: f64 = 1.0 / 0.0;
const K_PLAIN: u8 = 0;
const K_TRIG: u8 = 1;

// The f64 C library has no exp10 in C99: 10^x through pow is within an f64 ULP or two of it, far
// below an f32 ULP.
fn lib_exp10(x: f64) f64 {
    return math::pow(10.0, x);
}

fn lib_erfc(x: f64) f64 {
    return erfc(x);
}

// The references whose argument the reference takes in its own format, in either format (`Dw`, the
// double word, and `Q`, f128); the others are `Ref`'s own (`Ref::sin`).
extend<R: Real + Add<Output = R> + Sub<Output = R> + Mul<Output = R> + Div<Output = R>> Ref<R> {
    fn exp_x(self: &Ref<R>, x: f64) R {
        return self.exp(R::of(x));
    }

    fn exp2_x(self: &Ref<R>, x: f64) R {
        return self.exp(R::of(x) * self.ln2);
    }

    fn exp10_x(self: &Ref<R>, x: f64) R {
        return self.exp(R::of(x) * self.ln10);
    }

    fn expm1_x(self: &Ref<R>, x: f64) R {
        return self.expm1(R::of(x));
    }

    fn log_x(self: &Ref<R>, x: f64) R {
        return self.log(R::of(x));
    }

    fn log2_x(self: &Ref<R>, x: f64) R {
        return self.log(R::of(x)) / self.ln2;
    }

    fn log10_x(self: &Ref<R>, x: f64) R {
        return self.log(R::of(x)) / self.ln10;
    }

    fn log1p_x(self: &Ref<R>, x: f64) R {
        return self.log1p(R::of(x));
    }

    fn cbrt_x(self: &Ref<R>, x: f64) R {
        let c = self.cbrt(R::of(x.abs()));
        return if x < 0.0 {
            R::of(0.0) - c;
        } else {
            c;
        };
    }

    fn atan_x(self: &Ref<R>, x: f64) R {
        return self.atan(R::of(x));
    }

    // x^y, the sign of a negative x to an odd y.
    fn pow_xy(self: &Ref<R>, x: f64, y: f64) R {
        let m = self.exp(R::of(y) * self.log(R::of(x.abs())));
        // Times -1, not 0 - m: an underflow to 0 keeps its sign.
        return if x < 0.0 && (y * 0.5).trunc() != y * 0.5 {
            R::of(-1.0) * m;
        } else {
            m;
        };
    }
}

// One result of class `C`'s sincos.
fn sincos_s<const C: usize, T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    if C == 0 {
        let (s, _) = mp::sincos(x);
        return s;
    }
    if C == 1 {
        let (s, _) = mb::sincos(x);
        return s;
    }
    let (s, _) = mf::sincos(x);
    return s;
}

fn sincos_c<const C: usize, T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    if C == 0 {
        let (_, c) = mp::sincos(x);
        return c;
    }
    if C == 1 {
        let (_, c) = mb::sincos(x);
        return c;
    }
    let (_, c) = mf::sincos(x);
    return c;
}

// One function of two arguments (`powi` takes its integer as the second, a float holding it).
struct F2 {
    pub name: str<'static>,
    pub v32: [fn(V32, V32) V32; CLASSES],
    pub v64: [fn(V64, V64) V64; CLASSES],
    pub lib: fn(f64, f64) f64,
    pub dw: fn(&Ref<Dw>, f64, f64) Dw,
    pub q: fn(&Ref<Q>, f64, f64) Q,
    pub kind: u8, // S_POW, S_POWI, S_ATAN2, S_HYPOT: the pair sampler
    pub has: u32,
}

// Whether the fast class's range holds pair (x, y): hypot's squares neither overflow nor flush
// (the max of |x| and |y| within hyp_lo .. hyp_hi, `lane.spc`), every pair for the others.
fn fast_pair(kind: u8, x: f64, y: f64, f64_lanes: bool) bool {
    if kind != S_HYPOT {
        return true;
    }
    let hi = x.abs().max(y.abs());
    return hi == 0.0 || !hi.is_finite() || if f64_lanes {
        hi >= c64::K.hyp_lo && hi <= c64::K.hyp_hi;
    } else {
        hi >= c32::K.hyp_lo as f64 && hi <= c32::K.hyp_hi as f64;
    };
}

const S_POW: u8 = 0;
const S_POWI: u8 = 1;
const S_ATAN2: u8 = 2;
const S_HYPOT: u8 = 3;

// Class `C`'s powi with the integer held in a float.
fn powi_p<const C: usize, T: ln::Lane, const N: usize>(x: Simd<T, N>, n: Simd<T, N>) Simd<T, N> {
    return switch C {
        0 => mp::powi(x, n.cast::<i32>()),
        1 => mb::powi(x, n.cast::<i32>()),
        _ => mf::powi(x, n.cast::<i32>()),
    };
}

fn f2s() Vector<F2> {
    let mut v = Vector::<F2>::new();
    v.push(
        F2 {
            name: "pow",
            v32: [mp::pow::<f32, 8>, mb::pow::<f32, 8>, mf::pow::<f32, 8>],
            v64: [mp::pow::<f64, 4>, mb::pow::<f64, 4>, mf::pow::<f64, 4>],
            lib: math::pow,
            dw: Ref::<Dw>::pow_xy,
            q: Ref::<Q>::pow_xy,
            kind: S_POW,
            has: 7,
        },
    );
    v.push(
        F2 {
            name: "powi",
            v32: [powi_p::<0, f32, 8>, powi_p::<1, f32, 8>, powi_p::<2, f32, 8>],
            v64: [powi_p::<0, f64, 4>, powi_p::<1, f64, 4>, powi_p::<2, f64, 4>],
            lib: math::pow,
            dw: Ref::<Dw>::pow_xy,
            q: Ref::<Q>::pow_xy,
            kind: S_POWI,
            has: 7,
        },
    );
    v.push(
        F2 {
            name: "atan2",
            v32: [mp::atan2::<f32, 8>, mb::atan2::<f32, 8>, mf::atan2::<f32, 8>],
            v64: [mp::atan2::<f64, 4>, mb::atan2::<f64, 4>, mf::atan2::<f64, 4>],
            lib: math::atan2,
            dw: Ref::<Dw>::atan2,
            q: Ref::<Q>::atan2,
            kind: S_ATAN2,
            has: 7,
        },
    );
    v.push(
        F2 {
            name: "hypot",
            v32: [mp::hypot::<f32, 8>, mb::hypot::<f32, 8>, mf::hypot::<f32, 8>],
            v64: [mp::hypot::<f64, 4>, mb::hypot::<f64, 4>, mf::hypot::<f64, 4>],
            lib: math::hypot,
            dw: Ref::<Dw>::hypot,
            q: Ref::<Q>::hypot,
            kind: S_HYPOT,
            has: 7,
        },
    );
    return v;
}

// A binade-uniform positive value with exponent in [lo, hi] (the lane type's range applies later).
fn binade(g: &mut Rng, lo: i32, hi: i32) f64 {
    let e = lo + (g.next() % (hi - lo + 1) as u64) as i32;
    let m = 1.0 + g.unit();
    if e < -1022 {
        return m * 0x1p-1022 * fl::f64_from_bits((e + 1022 + 1023) as u64 << 52);
    }
    return m * fl::f64_from_bits((e + 1023) as u64 << 52);
}

// A pair for `f`: a quarter random bits, the rest shaped by the function (`emax` and `p`: the lane
// type's largest exponent and precision).
fn pair(kind: u8, g: &mut Rng, emax: i32, p: i32, f32_lanes: bool) (f64, f64) {
    let pick = g.next() % 4;
    if pick == 0 && kind != S_POWI {
        if f32_lanes {
            return fl::f32_from_bits(g.next() as u32), fl::f32_from_bits((g.next() >> 32) as u32);
        }
        return fl::f64_from_bits(g.next()), fl::f64_from_bits(g.next());
    }
    let emin = 2 - emax - p;
    if kind == S_POW {
        if pick == 1 {
            // log2 x times y over the whole result range.
            let x = binade(g, emin, emax);
            let l2 = (exponent(x) as f64).max(-1e9) + 0.5;
            let t = emin as f64 - 2.0 + g.unit() * ((emax - emin) as f64 + 4.0);
            return x, t / if l2.abs() < 0.25 {
                1.0;
            } else {
                l2;
            };
        }
        if pick == 2 {
            // A negative x and an integer y.
            let x = -binade(g, -40, 40);
            return x, (g.next() % 161) as f64 - 80.0;
        }
        // Near 1, a large y.
        let x = 1.0 + (g.unit() - 0.5) * binade(g, -p, -1);
        return x, (g.unit() - 0.5) * binade(g, 0, p);
    }
    if kind == S_POWI {
        let x = if g.next() % 2 == 0 {
            binade(g, -8, 8);
        } else {
            -binade(g, emin, emax);
        };
        let n = if pick < 2 {
            (g.next() % 257) as f64 - 128.0;
        } else if pick == 2 {
            ((g.next() >> 33) as i64 - (1i64 << 30)) as f64;
        } else {
            (g.next() % 4097) as f64 - 2048.0;
        };
        return x, n;
    }
    if kind == S_ATAN2 {
        let y = binade(g, emin, emax);
        let x = if pick == 1 {
            y * (0.5 + g.unit());
        } else {
            binade(g, emin, emax);
        };
        let sy = if g.next() % 2 == 0 {
            1.0;
        } else {
            -1.0;
        };
        let sx = if g.next() % 2 == 0 {
            1.0;
        } else {
            -1.0;
        };
        return sy * y, sx * x;
    }
    let x = binade(g, emin, emax);
    let y = if pick == 1 {
        x * (0.25 + g.unit());
    } else {
        binade(g, emin, emax);
    };
    return x, y;
}

// 8 pairs of `f` in f32 lanes against the f64 C library into `st`, a result near the bound again
// against f128.
fn eval32_2(f: &F2, st: &mut Stat, xa: &[f32; 8], ya: &[f32; 8], rq: &Ref<Q>) {
    let x = V32::from_array(*xa);
    let y = V32::from_array(*ya);
    for c in 0..CLASSES {
        let r = (unsafe f.v32[c])(x, y);
        let b = bound(c, false);
        for k in 0..8 {
            let xv = (unsafe xa[k]) as f64;
            let yv = (unsafe ya[k]) as f64;
            if c == 2 && !fast_pair(f.kind, xv, yv, false) {
                continue;
            }
            let lr = f.lib(xv, yv);
            let mut e = err32(c, r[k], lr);
            if near_bound(c, e, b) && lr.is_finite() && lr != 0.0 && !special_arg(xv) && !special_arg(yv) {
                e = err32q(c, r[k], f.q(rq, xv, yv));
            }
            st.add(c, e, xv, yv, b);
        }
    }
    st.n += 8;
}

// `n` pairs of `f` in f32 lanes (shaped random ones, `pair`), then, but for powi, every pair of
// binades of the lane type in each sign quadrant (a random significand each).
fn run32_2(f: &F2, n: u64, rq: &Ref<Q>) Stat {
    let nchunks: usize = 1024;
    let mut chunks = Vector::<Stat>::with_capacity(nchunks);
    for c in 0..nchunks {
        chunks.push(Stat::new(c));
    }
    let per = (n + nchunks as u64 - 1) / nchunks as u64;
    parallel::chunks_mut(
        chunks.index_range_mut(0..nchunks),
        1,
        |s: []mut Stat| {
            let st = &mut s[0];
            let mut g = Rng { s: 0x32F00000 + st.chunk as u64 };
            let mut xa: [f32; 8] = [0.0; 8];
            let mut ya: [f32; 8] = [0.0; 8];
            let mut i: u64 = 0;
            while i < per {
                for k in 0..8 {
                    let (x, y) = pair(f.kind, &mut g, 127, 24, true);
                    unsafe xa[k] = x as f32;
                    unsafe ya[k] = y as f32;
                }
                eval32_2(f, st, &xa, &ya, rq);
                i += 8;
            }
            // The grid: chunk c takes the binades of x from -149 + c, every 1024th.
            let mut ex = -149 + st.chunk as i32;
            while f.kind != S_POWI && ex <= 127 {
                let mut m: usize = 0;
                for ey in -149..128 {
                    for q in 0..4 {
                        unsafe xa[m] = (binade(&mut g, ex, ex) * if q % 2 == 0 {
                            1.0;
                        } else {
                            -1.0;
                        }) as f32;
                        unsafe ya[m] = (binade(&mut g, ey, ey) * if q < 2 {
                            1.0;
                        } else {
                            -1.0;
                        }) as f32;
                        m += 1;
                        if m == 8 {
                            eval32_2(f, st, &xa, &ya, rq);
                            m = 0;
                        }
                    }
                }
                ex += nchunks as i32;
            }
        },
    );
    let mut t = Stat::new(0);
    for c in 0..nchunks {
        t.merge(&chunks[c]);
    }
    return t;
}

// `n` pairs of `f` in f64 lanes against the double-word reference, as `run64`.
fn run64_2(f: &F2, n: u64, rd: &Ref<Dw>, rq: &Ref<Q>) Stat {
    let nchunks: usize = 1024;
    let mut chunks = Vector::<Stat>::with_capacity(nchunks);
    for c in 0..nchunks {
        chunks.push(Stat::new(c));
    }
    let per = (n + nchunks as u64 - 1) / nchunks as u64;
    parallel::chunks_mut(
        chunks.index_range_mut(0..nchunks),
        1,
        |s: []mut Stat| {
            let st = &mut s[0];
            let mut g = Rng { s: 0x64F00000 + st.chunk as u64 };
            let mut i: u64 = 0;
            while i < per {
                let mut xa: [f64; 4] = [0.0; 4];
                let mut ya: [f64; 4] = [0.0; 4];
                for k in 0..4 {
                    let (x, y) = pair(f.kind, &mut g, 1023, 53, false);
                    unsafe xa[k] = x;
                    unsafe ya[k] = y;
                }
                let x = V64::from_array(xa);
                let y = V64::from_array(ya);
                let mut refs: [Dw; 4] = [Dw::of(0.0); 4];
                let mut kinds: [u8; 4] = [0; 4]; // as `run64`
                for k in 0..4 {
                    let xv = unsafe xa[k];
                    let yv = unsafe ya[k];
                    let lib = f.lib(xv, yv);
                    if lib.is_nan() || lib.is_infinite() || !xv.is_finite() || !yv.is_finite() || xv == 0.0 || yv == 0.0 {
                        unsafe refs[k] = Dw::of(lib);
                        unsafe kinds[k] = 1;
                    } else if lib.abs() < 0x1p-1000 {
                        unsafe kinds[k] = 2;
                    } else {
                        unsafe refs[k] = f.dw(rd, xv, yv);
                    }
                }
                // Each input's f128 result, computed once for every class that needs it.
                let mut qr: [Q; 4] = [Q::of(0.0); 4];
                let mut qd: [bool; 4] = [false; 4];
                for c in 0..CLASSES {
                    let r = (unsafe f.v64[c])(x, y);
                    let b = bound(c, true);
                    for k in 0..4 {
                        let xv = unsafe xa[k];
                        let yv = unsafe ya[k];
                        if c == 2 && !fast_pair(f.kind, xv, yv, true) {
                            continue;
                        }
                        let kind = unsafe kinds[k];
                        let mut e = if kind == 2 {
                            b + 1.0;
                        } else {
                            err64(c, r[k], unsafe refs[k]);
                        };
                        if kind != 1 && near_bound(c, e, b) || kind == 2 {
                            if !unsafe qd[k] {
                                unsafe qr[k] = f.q(rq, xv, yv);
                                unsafe qd[k] = true;
                            }
                            e = err64q(c, r[k], unsafe qr[k]);
                        }
                        st.add(c, e, xv, yv, b);
                    }
                }
                st.n += 4;
                i += 4;
            }
        },
    );
    let mut t = Stat::new(0);
    for c in 0..nchunks {
        t.merge(&chunks[c]);
    }
    return t;
}

fn f1s() Vector<F1> {
    let mut v = Vector::<F1>::new();
    v.push(
        F1 {
            name: "exp",
            v32: [mp::exp::<f32, 8>, mb::exp::<f32, 8>, mf::exp::<f32, 8>],
            v64: [mp::exp::<f64, 4>, mb::exp::<f64, 4>, mf::exp::<f64, 4>],
            lib: math::exp,
            dw: Ref::<Dw>::exp_x,
            q: Ref::<Q>::exp_x,
            lo: -746.0,
            hi: 710.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "exp2",
            v32: [mp::exp2::<f32, 8>, mb::exp2::<f32, 8>, mf::exp2::<f32, 8>],
            v64: [mp::exp2::<f64, 4>, mb::exp2::<f64, 4>, mf::exp2::<f64, 4>],
            lib: math::exp2,
            dw: Ref::<Dw>::exp2_x,
            q: Ref::<Q>::exp2_x,
            lo: -1076.0,
            hi: 1025.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "exp10",
            v32: [mp::exp10::<f32, 8>, mb::exp10::<f32, 8>, mf::exp10::<f32, 8>],
            v64: [mp::exp10::<f64, 4>, mb::exp10::<f64, 4>, mf::exp10::<f64, 4>],
            lib: lib_exp10,
            dw: Ref::<Dw>::exp10_x,
            q: Ref::<Q>::exp10_x,
            lo: -324.0,
            hi: 309.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "expm1",
            v32: [mp::expm1::<f32, 8>, mb::expm1::<f32, 8>, mf::expm1::<f32, 8>],
            v64: [mp::expm1::<f64, 4>, mb::expm1::<f64, 4>, mf::expm1::<f64, 4>],
            lib: math::expm1,
            dw: Ref::<Dw>::expm1_x,
            q: Ref::<Q>::expm1_x,
            lo: -40.0,
            hi: 710.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "log",
            v32: [mp::log::<f32, 8>, mb::log::<f32, 8>, mf::log::<f32, 8>],
            v64: [mp::log::<f64, 4>, mb::log::<f64, 4>, mf::log::<f64, 4>],
            lib: math::log,
            dw: Ref::<Dw>::log_x,
            q: Ref::<Q>::log_x,
            lo: 0.0,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: true,
        },
    );
    v.push(
        F1 {
            name: "log2",
            v32: [mp::log2::<f32, 8>, mb::log2::<f32, 8>, mf::log2::<f32, 8>],
            v64: [mp::log2::<f64, 4>, mb::log2::<f64, 4>, mf::log2::<f64, 4>],
            lib: math::log2,
            dw: Ref::<Dw>::log2_x,
            q: Ref::<Q>::log2_x,
            lo: 0.0,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: true,
        },
    );
    v.push(
        F1 {
            name: "log10",
            v32: [mp::log10::<f32, 8>, mb::log10::<f32, 8>, mf::log10::<f32, 8>],
            v64: [mp::log10::<f64, 4>, mb::log10::<f64, 4>, mf::log10::<f64, 4>],
            lib: math::log10,
            dw: Ref::<Dw>::log10_x,
            q: Ref::<Q>::log10_x,
            lo: 0.0,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: true,
        },
    );
    v.push(
        F1 {
            name: "log1p",
            v32: [mp::log1p::<f32, 8>, mb::log1p::<f32, 8>, mf::log1p::<f32, 8>],
            v64: [mp::log1p::<f64, 4>, mb::log1p::<f64, 4>, mf::log1p::<f64, 4>],
            lib: math::log1p,
            dw: Ref::<Dw>::log1p_x,
            q: Ref::<Q>::log1p_x,
            lo: -1.0,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "cbrt",
            v32: [mp::cbrt::<f32, 8>, mb::cbrt::<f32, 8>, mf::cbrt::<f32, 8>],
            v64: [mp::cbrt::<f64, 4>, mb::cbrt::<f64, 4>, mf::cbrt::<f64, 4>],
            lib: math::cbrt,
            dw: Ref::<Dw>::cbrt_x,
            q: Ref::<Q>::cbrt_x,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "sin",
            v32: [mp::sin::<f32, 8>, mb::sin::<f32, 8>, mf::sin::<f32, 8>],
            v64: [mp::sin::<f64, 4>, mb::sin::<f64, 4>, mf::sin::<f64, 4>],
            lib: math::sin,
            dw: Ref::<Dw>::sin,
            q: Ref::<Q>::sin,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_TRIG,
            has: 7,
            fmax32: 8192.0,
            fmax64: 16777216.0,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "cos",
            v32: [mp::cos::<f32, 8>, mb::cos::<f32, 8>, mf::cos::<f32, 8>],
            v64: [mp::cos::<f64, 4>, mb::cos::<f64, 4>, mf::cos::<f64, 4>],
            lib: math::cos,
            dw: Ref::<Dw>::cos,
            q: Ref::<Q>::cos,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_TRIG,
            has: 7,
            fmax32: 8192.0,
            fmax64: 16777216.0,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "tan",
            v32: [mp::tan::<f32, 8>, mb::tan::<f32, 8>, mf::tan::<f32, 8>],
            v64: [mp::tan::<f64, 4>, mb::tan::<f64, 4>, mf::tan::<f64, 4>],
            lib: math::tan,
            dw: Ref::<Dw>::tan,
            q: Ref::<Q>::tan,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_TRIG,
            has: 7,
            fmax32: 8192.0,
            fmax64: 16777216.0,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "sincos.sin",
            v32: [sincos_s::<0, f32, 8>, sincos_s::<1, f32, 8>, sincos_s::<2, f32, 8>],
            v64: [sincos_s::<0, f64, 4>, sincos_s::<1, f64, 4>, sincos_s::<2, f64, 4>],
            lib: math::sin,
            dw: Ref::<Dw>::sin,
            q: Ref::<Q>::sin,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_TRIG,
            has: 7,
            fmax32: 8192.0,
            fmax64: 16777216.0,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "sincos.cos",
            v32: [sincos_c::<0, f32, 8>, sincos_c::<1, f32, 8>, sincos_c::<2, f32, 8>],
            v64: [sincos_c::<0, f64, 4>, sincos_c::<1, f64, 4>, sincos_c::<2, f64, 4>],
            lib: math::cos,
            dw: Ref::<Dw>::cos,
            q: Ref::<Q>::cos,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_TRIG,
            has: 7,
            fmax32: 8192.0,
            fmax64: 16777216.0,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "asin",
            v32: [mp::asin::<f32, 8>, mb::asin::<f32, 8>, mf::asin::<f32, 8>],
            v64: [mp::asin::<f64, 4>, mb::asin::<f64, 4>, mf::asin::<f64, 4>],
            lib: math::asin,
            dw: Ref::<Dw>::asin,
            q: Ref::<Q>::asin,
            lo: -1.0,
            hi: 1.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "acos",
            v32: [mp::acos::<f32, 8>, mb::acos::<f32, 8>, mf::acos::<f32, 8>],
            v64: [mp::acos::<f64, 4>, mb::acos::<f64, 4>, mf::acos::<f64, 4>],
            lib: math::acos,
            dw: Ref::<Dw>::acos,
            q: Ref::<Q>::acos,
            lo: -1.0,
            hi: 1.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "atan",
            v32: [mp::atan::<f32, 8>, mb::atan::<f32, 8>, mf::atan::<f32, 8>],
            v64: [mp::atan::<f64, 4>, mb::atan::<f64, 4>, mf::atan::<f64, 4>],
            lib: math::atan,
            dw: Ref::<Dw>::atan_x,
            q: Ref::<Q>::atan_x,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "sinh",
            v32: [mp::sinh::<f32, 8>, mb::sinh::<f32, 8>, mf::sinh::<f32, 8>],
            v64: [mp::sinh::<f64, 4>, mb::sinh::<f64, 4>, mf::sinh::<f64, 4>],
            lib: math::sinh,
            dw: Ref::<Dw>::sinh,
            q: Ref::<Q>::sinh,
            lo: -711.0,
            hi: 711.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "cosh",
            v32: [mp::cosh::<f32, 8>, mb::cosh::<f32, 8>, mf::cosh::<f32, 8>],
            v64: [mp::cosh::<f64, 4>, mb::cosh::<f64, 4>, mf::cosh::<f64, 4>],
            lib: math::cosh,
            dw: Ref::<Dw>::cosh,
            q: Ref::<Q>::cosh,
            lo: -711.0,
            hi: 711.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "tanh",
            v32: [mp::tanh::<f32, 8>, mb::tanh::<f32, 8>, mf::tanh::<f32, 8>],
            v64: [mp::tanh::<f64, 4>, mb::tanh::<f64, 4>, mf::tanh::<f64, 4>],
            lib: math::tanh,
            dw: Ref::<Dw>::tanh,
            q: Ref::<Q>::tanh,
            lo: -23.0,
            hi: 23.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "asinh",
            v32: [mp::asinh::<f32, 8>, mb::asinh::<f32, 8>, mf::asinh::<f32, 8>],
            v64: [mp::asinh::<f64, 4>, mb::asinh::<f64, 4>, mf::asinh::<f64, 4>],
            lib: math::asinh,
            dw: Ref::<Dw>::asinh,
            q: Ref::<Q>::asinh,
            lo: -1.7976931348623157e308,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "acosh",
            v32: [mp::acosh::<f32, 8>, mb::acosh::<f32, 8>, mf::acosh::<f32, 8>],
            v64: [mp::acosh::<f64, 4>, mb::acosh::<f64, 4>, mf::acosh::<f64, 4>],
            lib: math::acosh,
            dw: Ref::<Dw>::acosh,
            q: Ref::<Q>::acosh,
            lo: 1.0,
            hi: 1.7976931348623157e308,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "atanh",
            v32: [mp::atanh::<f32, 8>, mb::atanh::<f32, 8>, mf::atanh::<f32, 8>],
            v64: [mp::atanh::<f64, 4>, mb::atanh::<f64, 4>, mf::atanh::<f64, 4>],
            lib: math::atanh,
            dw: Ref::<Dw>::atanh,
            q: Ref::<Q>::atanh,
            lo: -1.0,
            hi: 1.0,
            kind: K_PLAIN,
            has: 7,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "erf",
            v32: [mp::erf::<f32, 8>, mp::erf::<f32, 8>, mp::erf::<f32, 8>],
            v64: [mp::erf::<f64, 4>, mp::erf::<f64, 4>, mp::erf::<f64, 4>],
            lib: math::erf,
            dw: Ref::<Dw>::erf,
            q: Ref::<Q>::erf,
            lo: -7.0,
            hi: 7.0,
            kind: K_PLAIN,
            has: 1,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    v.push(
        F1 {
            name: "erfc",
            v32: [mp::erfc::<f32, 8>, mb::erfc::<f32, 8>, mb::erfc::<f32, 8>],
            v64: [mp::erfc::<f64, 4>, mb::erfc::<f64, 4>, mb::erfc::<f64, 4>],
            lib: lib_erfc,
            dw: Ref::<Dw>::erfc,
            q: Ref::<Q>::erfc,
            lo: -7.0,
            hi: 28.0,
            kind: K_PLAIN,
            has: 3,
            fmax32: INF,
            fmax64: INF,
            fsub: false,
        },
    );
    return v;
}

// The class bounds: ULP for precise and balanced; for fast the relative bound per lane type.
fn bound(class: usize, f64_lanes: bool) f64 {
    if class == 0 {
        return 1.0;
    }
    if class == 1 {
        return 3.5;
    }
    return if f64_lanes {
        0x1p-22;
    } else {
        0x1p-11;
    };
}

/// The unit in the last place of the f32 result nearest `r` (subnormals at the subnormal ULP, past
/// the largest finite at its ULP).
fn ulp32(r: f64) f64 {
    let a = r.abs();
    if a < 0x1p-126 {
        return 0x1p-149;
    }
    let e = exponent(a.min(3.4028234663852886e38));
    return fl::f64_from_bits((e - 23 + 1023) as u64 << 52);
}

fn ulp64(r: f64) f64 {
    let a = r.abs();
    if a < 0x1p-1022 {
        return 0x1p-1074;
    }
    let u = exponent(a.min(1.7976931348623157e308)) - 52;
    if u < -1022 {
        return fl::f64_from_bits(1u64 << (u + 1074) as u64); // a subnormal ULP
    }
    return fl::f64_from_bits((u + 1023) as u64 << 52);
}

/// The error of result `y` against reference `r` in the class's unit: 0 for the same NaN, infinity or
/// zero, infinity (1e300) for a NaN, an infinity or a zero sign the reference does not have.
fn err32(class: usize, y: f32, r: f64) f64 {
    if y == 0.0 && r as f32 == 0.0 && y.is_sign_negative() != r.is_sign_negative() {
        return 1e300;
    }
    if r.is_nan() || y.is_nan() {
        return if r.is_nan() && y.is_nan() {
            0.0;
        } else {
            1e300;
        };
    }
    let rr = r as f32; // the correctly rounded result
    if y.is_infinite() || rr.is_infinite() {
        return if y == rr {
            0.0;
        } else if y.is_infinite() && class == 2 && y == r.signum() * (1.0 / 0.0) && r.abs() * (1.0 + 0x1p-11) >= 3.4028234663852886e38 {
            0.0; // fast may overflow within its bound of the largest finite value
        } else if y.is_infinite() && class == 2 {
            1e300;
        } else if class == 2 {
            (y as f64 - r).abs() / r.abs();
        } else {
            (y as f64 - r).abs() / ulp32(r);
        };
    }
    if class == 2 {
        if r.abs() < 0x1p-126 {
            // Fast may flush: a result within the smallest normal of a subnormal reference is exact.
            return if (y as f64 - r).abs() <= 0x1p-126 {
                0.0;
            } else {
                1e300;
            };
        }
        return (y as f64 - r).abs() / r.abs();
    }
    return (y as f64 - r).abs() / ulp32(r);
}

fn err64(class: usize, y: f64, r: Dw) f64 {
    let rn = r.near();
    if y == 0.0 && rn == 0.0 && y.is_sign_negative() != rn.is_sign_negative() {
        return 1e300;
    }
    if rn.is_nan() || y.is_nan() {
        return if rn.is_nan() && y.is_nan() {
            0.0;
        } else {
            1e300;
        };
    }
    if y.is_infinite() || rn.is_infinite() {
        return if y == rn {
            0.0;
        } else if y.is_infinite() && class == 2 && y == rn.signum() * (1.0 / 0.0) && rn.abs() * (1.0 + 0x1p-22) >= 1.7976931348623157e308 {
            0.0; // fast may overflow within its bound of the largest finite value
        } else if y.is_infinite() {
            1e300;
        } else if class == 2 {
            (Dw::of(y) - r).near().abs() / r.near().abs();
        } else {
            (Dw::of(y) - r).near().abs() / ulp64(rn);
        };
    }
    let d = (Dw::of(y) - r).near().abs();
    if class == 2 {
        if rn.abs() < 0x1p-1022 {
            return if d <= 0x1p-1022 {
                0.0;
            } else {
                1e300;
            };
        }
        return d / rn.abs();
    }
    return d / ulp64(rn);
}

// The error of one f32 result against the f128 reference (as `err32`; an infinity or a zero, of the
// result or the rounded reference, as `err32` decides).
fn err32q(class: usize, y: f32, r: Q) f64 {
    let rn = r.to_f64();
    let rr = rn as f32;
    if !y.is_finite() || !rr.is_finite() || y == 0.0 || rr == 0.0 {
        return err32(class, y, rn);
    }
    if class == 2 && rn.abs() < 0x1p-126 {
        return if (Q::of(y) - r).to_f64().abs() <= 0x1p-126 {
            0.0;
        } else {
            1e300;
        };
    }
    let u = if class == 2 {
        Q::of(rn.abs());
    } else {
        Q::of(ulp32(rn));
    };
    return ((Q::of(y) - r) / u).to_f64().abs();
}

// The error of one f64 result against the f128 reference.
fn err64q(class: usize, y: f64, r: Q) f64 {
    // The quotient in f128: a subnormal difference would round in f64.
    let rn = r.to_f64();
    if !y.is_finite() || !rn.is_finite() || y == 0.0 || rn == 0.0 {
        return err64(class, y, Dw::of(rn));
    }
    if class == 2 && rn.abs() < 0x1p-1022 {
        return if (Q::of(y) - r).to_f64().abs() <= 0x1p-1022 {
            0.0;
        } else {
            1e300;
        };
    }
    let u = if class == 2 {
        Q::of(rn.abs());
    } else {
        Q::of(ulp64(rn));
    };
    return ((Q::of(y) - r) / u).to_f64().abs();
}

/// One chunk's tally per class: the largest error, its input (`arg2`: the second argument), the
/// count over the bound.
struct Stat {
    pub chunk: usize,
    pub max: [f64; CLASSES],
    pub arg: [f64; CLASSES],
    pub arg2: [f64; CLASSES],
    pub over: [u64; CLASSES],
    pub n: u64,
}

extend Stat {
    fn new(chunk: usize) Stat {
        return Stat {
            chunk: chunk,
            max: [0.0; CLASSES],
            arg: [0.0; CLASSES],
            arg2: [0.0; CLASSES],
            over: [0; CLASSES],
            n: 0,
        };
    }

    fn add(self: &mut Stat, class: usize, e: f64, x: f64, y: f64, b: f64) {
        if e > unsafe self.max[class] || unsafe self.max[class] == 0.0 && e > 0.0 {
            unsafe self.max[class] = e;
            unsafe self.arg[class] = x;
            unsafe self.arg2[class] = y;
        }
        if e > b {
            unsafe self.over[class] += 1;
        }
    }

    fn merge(self: &mut Stat, o: &Stat) {
        for c in 0..CLASSES {
            if unsafe o.max[c] > unsafe self.max[c] {
                unsafe self.max[c] = unsafe o.max[c];
                unsafe self.arg[c] = unsafe o.arg[c];
                unsafe self.arg2[c] = unsafe o.arg2[c];
            }
            unsafe self.over[c] += unsafe o.over[c];
        }
        self.n += o.n;
    }
}

// Every f32 input of `f` (2^32 bit patterns in 4096 chunks), or `sample` random ones when not 0,
// against the f64 C library; a result within 0.01 ULP (1% of a relative bound) of the bound again
// against f128.
fn run32(f: &F1, sample: u64, rq: &Ref<Q>) Stat {
    let mut chunks = Vector::<Stat>::with_capacity(4096);
    for c in 0usize..4096 {
        chunks.push(Stat::new(c));
    }
    let per = if sample == 0 {
        1u64 << 20;
    } else {
        (sample + 4095) / 4096 + 7 & ~7u64;
    };
    parallel::chunks_mut(
        chunks.index_range_mut(0..4096),
        1,
        |s: []mut Stat| {
            let st = &mut s[0];
            let base = st.chunk as u64 << 20;
            let mut g = Rng { s: 0x32320000 + st.chunk as u64 };
            let mut i: u64 = 0;
            while i < per {
                let mut xa: [f32; 8] = [0.0; 8];
                for k in 0..8 {
                    unsafe xa[k] = fl::f32_from_bits(
                        if sample == 0 {
                            (base + i + k as u64) as u32;
                        } else {
                            (g.next() >> 32) as u32;
                        },
                    );
                }
                let x = V32::from_array(xa);
                let mut r: [f64; 8] = [0.0; 8];
                for k in 0..8 {
                    unsafe r[k] = f.lib(unsafe xa[k]);
                }
                for c in 0..CLASSES {
                    if (f.has >> c as u32 & 1) == 0 {
                        continue;
                    }
                    let y = (unsafe f.v32[c])(x);
                    for k in 0..8 {
                        let xv = unsafe xa[k];
                        if c == 2 && (!(xv.abs() <= f.fmax32) && xv.is_finite() || f.fsub && xv != 0.0 && xv.abs() < 0x1p-126) {
                            continue;
                        }
                        let b = bound(c, false);
                        let mut e = err32(c, y[k], unsafe r[k]);
                        if near_bound(c, e, b) && !special_arg(xv) && unsafe r[k].is_finite() {
                            e = err32q(c, y[k], f.q(rq, xv));
                        }
                        st.add(c, e, xv, 0.0, b);
                    }
                }
                st.n += 8;
                i += 8;
            }
        },
    );
    let mut t = Stat::new(0);
    for c in 0usize..4096 {
        t.merge(&chunks[c]);
    }
    return t;
}

// Whether error `e` is within 0.01 ULP (1% of a relative bound) of bound `b`: the f128 reference
// decides it.
fn near_bound(c: usize, e: f64, b: f64) bool {
    return (e - b).abs() <= 0.01 * if c == 2 {
        b;
    } else {
        1.0;
    };
}

// A splitmix64 stream: the samples are the same on every host.
struct Rng {
    pub s: u64,
}

extend Rng {
    fn next(self: &mut Rng) u64 {
        self.s = self.s.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.s;
        z = (z ^ z >> 30).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ z >> 27).wrapping_mul(0x94D049BB133111EB);
        return z ^ z >> 31;
    }

    // A uniform double in [0, 1).
    fn unit(self: &mut Rng) f64 {
        return (self.next() >> 11) as f64 * 0x1p-53;
    }
}

// A uniform value of a random binade of [-hi, hi] (positive when `pos`): a random exponent among the
// domain's, subnormals included, a random significand.
fn binade_of(g: &mut Rng, hi: f64, pos: bool) f64 {
    let e = -1074 + (g.next() % (exponent(hi) + 1075) as u64) as i32;
    let mut v = (1.0 + g.unit()) * fl::f64_from_bits((e.max(-1022) + 1023) as u64 << 52);
    if e < -1022 {
        v = v * fl::f64_from_bits((e + 1022 + 1023) as u64 << 52);
    }
    return if !pos && g.next() % 2 == 0 {
        -v;
    } else {
        v;
    };
}

// A neighbor of `p` at most `d` ULP away in magnitude (finite, the sign kept), negated half the time
// when `neg`.
fn neighbor(g: &mut Rng, p: f64, d: i64, neg: bool) f64 {
    let b = (fl::f64_bits(p.abs()) as i64 + (g.next() % (2 * d as u64 + 1)) as i64 - d).max(0).min(0x7FEFFFFFFFFFFFFF);
    let v = fl::f64_from_bits(b as u64);
    return if neg && g.next() % 2 == 0 {
        -v;
    } else if p < 0.0 {
        -v;
    } else {
        v;
    };
}

// A function's f64 input: a quarter random bits, a quarter near a special point (0, 1, 1/2, 2, the
// domain ends, every lane-constant threshold, at up to 2^40 ULP, log-spread), and half uniform per
// binade of the domain, or for the trigonometric functions a quarter of those near multiples of pi/2
// (the nearest double to k pi/2 and its neighbors, the double nearest one of all,
// 6381956970095103 2^797).
fn sample(f: &F1, g: &mut Rng, rd: &Ref<Dw>) f64 {
    let pick = g.next() % 4;
    let hi = f.hi.abs().max(f.lo.abs());
    if pick == 0 {
        return fl::f64_from_bits(g.next());
    }
    if pick == 1 {
        let k = &c64::K;
        let pts: [f64; 26] = [
            0.0,
            1.0,
            0.5,
            2.0,
            f.lo,
            f.hi,
            k.min_normal,
            k.exp_max,
            k.exp_min,
            k.exp2_max,
            k.exp2_min,
            k.exp10_max,
            k.exp10_min,
            k.expm1_min,
            k.cw_max,
            k.tiny,
            k.big,
            k.hyp_big,
            k.cosh_max,
            k.tanh_one,
            k.erfc_max,
            k.hyp_lo,
            k.hyp_hi,
            k.exp_norm,
            k.exp10_norm,
            k.sqrt2,
        ];
        let p = unsafe pts[(g.next() % 26) as usize];
        let v = neighbor(g, p, 1i64 << (g.next() % 41) as i64, f.lo < 0.0);
        return v.max(f.lo).min(f.hi);
    }
    if pick == 2 && f.kind == K_TRIG {
        if g.next() % 16 == 0 {
            return neighbor(g, 0x1.6ac5b262ca1ffp849, 4, true);
        }
        let k = (g.next() >> 11 + g.next() % 53) as f64;
        return neighbor(g, (Dw::of(k) * rd.pio2).near(), 4, true);
    }
    return binade_of(g, hi, f.lo >= 0.0).max(f.lo).min(f.hi);
}

// `n` f64 inputs of `f` in 1024 chunks against the double-word reference; each result within 0.01
// of the bound again against f128.
fn run64(f: &F1, n: u64, rd: &Ref<Dw>, rq: &Ref<Q>) Stat {
    let nchunks: usize = 1024;
    let mut chunks = Vector::<Stat>::with_capacity(nchunks);
    for c in 0..nchunks {
        chunks.push(Stat::new(c));
    }
    let per = (n + nchunks as u64 - 1) / nchunks as u64;
    parallel::chunks_mut(
        chunks.index_range_mut(0..nchunks),
        1,
        |s: []mut Stat| {
            let st = &mut s[0];
            let mut g = Rng { s: 0x5EED0000 + st.chunk as u64 };
            let mut i: u64 = 0;
            while i < per {
                let mut xa: [f64; 4] = [0.0; 4];
                for k in 0..4 {
                    unsafe xa[k] = sample(f, &mut g, rd);
                }
                let x = V64::from_array(xa);
                // Per lane the reference once: special results (NaN, infinities, poles) are the C
                // library's, by Annex F; a zero or subnormal one is f128's (no double word holds it).
                let mut refs: [Dw; 4] = [Dw::of(0.0); 4];
                let mut kinds: [u8; 4] = [0; 4]; // 0: double word, 1: special, 2: f128 only
                for k in 0..4 {
                    let xv = unsafe xa[k];
                    let lib = f.lib(xv);
                    if lib.is_nan() || lib.is_infinite() || !xv.is_finite() || xv == 0.0 {
                        unsafe refs[k] = Dw::of(lib);
                        unsafe kinds[k] = 1;
                    } else if lib.abs() < 0x1p-1000 {
                        unsafe kinds[k] = 2;
                    } else {
                        unsafe refs[k] = f.dw(rd, xv);
                    }
                }
                // Each input's f128 result, computed once for every class that needs it.
                let mut qr: [Q; 4] = [Q::of(0.0); 4];
                let mut qd: [bool; 4] = [false; 4];
                for c in 0..CLASSES {
                    if (f.has >> c as u32 & 1) == 0 {
                        continue;
                    }
                    let y = (unsafe f.v64[c])(x);
                    let b = bound(c, true);
                    for k in 0..4 {
                        let xv = unsafe xa[k];
                        if c == 2 && (!(xv.abs() <= f.fmax64) && xv.is_finite() || f.fsub && xv != 0.0 && xv.abs() < 0x1p-1022) {
                            continue;
                        }
                        let kind = unsafe kinds[k];
                        let mut e = if kind == 2 {
                            b + 1.0;
                        } else {
                            err64(c, y[k], unsafe refs[k]);
                        };
                        if kind != 1 && near_bound(c, e, b) || kind == 2 {
                            if !unsafe qd[k] {
                                unsafe qr[k] = f.q(rq, xv);
                                unsafe qd[k] = true;
                            }
                            e = err64q(c, y[k], unsafe qr[k]);
                        }
                        st.add(c, e, xv, 0.0, b);
                    }
                }
                st.n += 4;
                i += 4;
            }
        },
    );
    let mut t = Stat::new(0);
    for c in 0..nchunks {
        t.merge(&chunks[c]);
    }
    return t;
}

fn arg_text(x: f64, out: &mut String) {
    // The input exactly, as a hexadecimal float.
    if x != x {
        out.push_str("nan");
        return;
    }
    let b = fl::f64_bits(x);
    out.format_into("{}", x);
    out.push_str(" (0x");
    out.push_hex(b, false);
    out.push_str(")");
}

// The special inputs, per lane type: signed zeros, infinities, NaN, the subnormal and normal
// extremes, small values, and every threshold of the lane constants (`Konsts`) with its neighbors.
fn specials32() Vector<f32> {
    let k = &c32::K;
    let mut v = Vector::<f32>::new();
    let base: [u32; 12] = [
        0,
        0x80000000,
        0x7F800000,
        0xFF800000,
        0x7FC00000,
        1,
        0x80000001,
        0x007FFFFF,
        0x00800000,
        0x7F7FFFFF,
        0xFF7FFFFF,
        0x80800000,
    ];
    for b in base {
        v.push(fl::f32_from_bits(b));
    }
    let small: [f32; 8] = [1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0];
    for x in small {
        v.push(x);
    }
    let th: [f32; 20] = [
        k.exp_max,
        k.exp_min,
        k.exp2_max,
        k.exp2_min,
        k.exp10_max,
        k.exp10_min,
        k.expm1_min,
        k.cw_max,
        k.tiny,
        k.big,
        k.hyp_big,
        k.cosh_max,
        k.tanh_one,
        k.erfc_max,
        k.hyp_lo,
        k.hyp_hi,
        k.exp_norm,
        k.exp10_norm,
        k.min_normal,
        k.sqrt2,
    ];
    for x in th {
        for d in [-1i64, 0, 1] {
            let b = (fl::f32_bits(x) as i64 + d) as u32;
            v.push(fl::f32_from_bits(b));
            v.push(-fl::f32_from_bits(b));
        }
    }
    return v;
}

fn specials64() Vector<f64> {
    let k = &c64::K;
    let mut v = Vector::<f64>::new();
    let base: [u64; 12] = [
        0,
        0x8000000000000000,
        0x7FF0000000000000,
        0xFFF0000000000000,
        0x7FF8000000000000,
        1,
        0x8000000000000001,
        0x000FFFFFFFFFFFFF,
        0x0010000000000000,
        0x7FEFFFFFFFFFFFFF,
        0xFFEFFFFFFFFFFFFF,
        0x8010000000000000,
    ];
    for b in base {
        v.push(fl::f64_from_bits(b));
    }
    let small: [f64; 8] = [1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0];
    for x in small {
        v.push(x);
    }
    let th: [f64; 20] = [
        k.exp_max,
        k.exp_min,
        k.exp2_max,
        k.exp2_min,
        k.exp10_max,
        k.exp10_min,
        k.expm1_min,
        k.cw_max,
        k.tiny,
        k.big,
        k.hyp_big,
        k.cosh_max,
        k.tanh_one,
        k.erfc_max,
        k.hyp_lo,
        k.hyp_hi,
        k.exp_norm,
        k.exp10_norm,
        k.min_normal,
        k.sqrt2,
    ];
    for x in th {
        for d in [-1i64, 0, 1] {
            let b = (fl::f64_bits(x) as i64 + d) as u64;
            v.push(fl::f64_from_bits(b));
            v.push(-fl::f64_from_bits(b));
        }
    }
    return v;
}

// A zero, an infinity or NaN: an argument whose result Annex F (and the class contract) fixes.
fn special_arg(x: f64) bool {
    return x == 0.0 || !x.is_finite();
}

// Whether class `c`'s result `y` for a special case is right against the C library's `r` (rounded to
// the lane type): exactly (bits, any NaN as NaN), or for a fast zero within the bound with its sign.
fn special_ok(c: usize, y: f64, r: f64, f64_lanes: bool) bool {
    if y.is_nan() || r.is_nan() {
        return y.is_nan() && r.is_nan();
    }
    if c == 2 && r == 0.0 && y == 0.0 || c == 2 && r != 0.0 && r.is_finite() && (y - r).abs() <= r.abs() * bound(
        c,
        f64_lanes,
    ) {
        return y.is_sign_negative() == r.is_sign_negative();
    }
    return fl::f64_bits(y) == fl::f64_bits(r);
}

// The special-value table of `f` in lane type `t` (0: f32, 1: f64): the count of wrong results per
// class, each printed. A special argument must give the exact result; any other must be within the
// class bound, and a zero result must keep the C library's sign.
fn special1(f: &F1, t: i32, rd: &Ref<Dw>, rq: &Ref<Q>) [u64; CLASSES] {
    let mut bad: [u64; CLASSES] = [0; CLASSES];
    let xs = if t == 0 {
        let s32 = specials32();
        let mut v = Vector::<f64>::new();
        for i in 0..s32.len() {
            v.push(s32[i]);
        }
        v;
    } else {
        specials64();
    };
    for i in 0..xs.len() {
        let x = xs[i];
        let lib = f.lib(x);
        let fmax = if t == 0 {
            f.fmax32;
        } else {
            f.fmax64;
        };
        let min_normal: f64 = if t == 0 {
            0x1p-126;
        } else {
            0x1p-1022;
        };
        let subnormal = x != 0.0 && x.abs() < min_normal;
        // Outside the fast class's range: past its trigonometric range, a subnormal it takes as 0.
        let fast_out = !(x.abs() <= fmax) && x.is_finite() || f.fsub && subnormal;
        for c in 0..CLASSES {
            if (f.has >> c as u32 & 1) == 0 || c == 2 && fast_out {
                continue;
            }
            // A special result is the C library's (Annex F); a subnormal one f128's (a double word
            // rounds its high part alone onto the subnormal grid).
            let lt = if t == 0 {
                (lib as f32) as f64;
            } else {
                lib;
            };
            let special = lt.is_nan() || lt.is_infinite() || lt == 0.0;
            let (y, r, e) = if t == 0 {
                let y = (unsafe f.v32[c])(V32::splat(x as f32))[0];
                (
                    y as f64,
                    (lib as f32) as f64,
                    if special {
                        err32(c, y, lib);
                    } else {
                        err32q(c, y, f.q(rq, x));
                    }
                );
            } else {
                let y = (unsafe f.v64[c])(V64::splat(x))[0];
                (
                    y,
                    lib,
                    if special {
                        err64(c, y, Dw::of(lib));
                    } else if lib.abs() < 0x1p-1000 {
                        err64q(c, y, f.q(rq, x));
                    } else {
                        err64(c, y, f.dw(rd, x));
                    }
                );
            };
            let ok = if special_arg(x) {
                special_ok(c, y, r, t == 1);
            } else {
                e <= bound(c, t == 1) && !(y == 0.0 && r == 0.0 && y.is_sign_negative() != r.is_sign_negative());
            };
            if !ok {
                unsafe bad[c] += 1;
                eprintln(
                    "special: {} {} f{}: x = {} gives {}, the C library {}",
                    unsafe CLASS_NAMES[c],
                    f.name,
                    if t == 0 {
                        32;
                    } else {
                        64;
                    },
                    x,
                    y,
                    r,
                );
            }
        }
    }
    return bad;
}

// The same for a function of two arguments over pairs of special inputs (powi: integer second ones).
fn special2(f: &F2, t: i32, rq: &Ref<Q>) [u64; CLASSES] {
    let mut bad: [u64; CLASSES] = [0; CLASSES];
    let vals: [f64; 16] = [
        0.0,
        -0.0,
        1.0 / 0.0,
        -1.0 / 0.0,
        0.0 / 0.0,
        1.0,
        -1.0,
        0.5,
        -0.5,
        2.0,
        -2.0,
        3.0,
        -3.0,
        0x1p-1074,
        1.7976931348623157e308,
        -0x1p-149,
    ];
    let ints: [f64; 10] = [0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 127.0, -1074.0, 2147483647.0];
    let nj: usize = if f.kind == S_POWI {
        10;
    } else {
        16;
    };
    for i in 0..16 {
        for j in 0..nj {
            let mut x = unsafe vals[i];
            let mut y = if f.kind == S_POWI {
                unsafe ints[j];
            } else {
                unsafe vals[j];
            };
            if t == 0 {
                x = x as f32;
                y = if f.kind == S_POWI {
                    y;
                } else {
                    y as f32;
                };
            }
            let lib = f.lib(x, y);
            let r = if t == 0 {
                (lib as f32) as f64;
            } else {
                lib;
            };
            // Exact: a special argument, x = 1 or y = 0 (pow), or a special result.
            let exact = special_arg(x) || special_arg(y) || f.kind <= S_POWI && (x == 1.0 || y == 0.0) || !r.is_finite();
            for c in 0..CLASSES {
                if c == 2 && !fast_pair(f.kind, x, y, t == 1) {
                    continue;
                }
                let v = if t == 0 {
                    (unsafe f.v32[c])(V32::splat(x as f32), V32::splat(y as f32))[0] as f64;
                } else {
                    (unsafe f.v64[c])(V64::splat(x), V64::splat(y))[0];
                };
                // Any other result against the f128 reference, at the class bound.
                let ok = if exact {
                    special_ok(c, v, r, t == 1);
                } else if t == 0 {
                    err32q(c, v as f32, f.q(rq, x, y)) <= bound(c, false);
                } else {
                    err64q(c, v, f.q(rq, x, y)) <= bound(c, true);
                };
                if !ok {
                    unsafe bad[c] += 1;
                    eprintln(
                        "special: {} {} f{}: ({}, {}) gives {}, the C library {}",
                        unsafe CLASS_NAMES[c],
                        f.name,
                        if t == 0 {
                            32;
                        } else {
                            64;
                        },
                        x,
                        y,
                        v,
                        r,
                    );
                }
            }
        }
    }
    return bad;
}

// The measured table of one class: per function, its largest error in each lane type and the input
// that gives it (`two`: of two arguments).
struct Row {
    pub name: str<'static>,
    pub err: [f64; 2],
    pub x: [f64; 2],
    pub y: [f64; 2],
    pub two: bool,
}

// The comment block `--write` puts at the top of class `c`'s module.
fn table(c: usize, rows: &Vector<Row>, n: u64) String {
    let mut t = String::new();
    t.format_into(
        "// Measured by `tools/simd_math` (`simd-math-check --write`; f32: every input, f64: {} inputs per\n",
        n,
    );
    t.push_str("// function and the special values, 0 results over the bound): the largest error per lane type,\n");
    if c == 2 {
        t.push_str("// relative.\n");
    } else {
        t.push_str("// in ULP.\n");
    }
    for i in 0..rows.len() {
        let r = rows.at(i);
        for k in 0..2 {
            let e = unsafe r.err[k];
            let mut line = String::new();
            line.format_into(
                "//   {}",
                if k == 0 {
                    r.name;
                } else {
                    "";
                },
            );
            for _ in line.len()..17 {
                line.push_byte(b' ');
            }
            line.format_into(
                "f{} ",
                if k == 0 {
                    32;
                } else {
                    64;
                },
            );
            if c == 2 {
                line.format_into("2^{}", (log2_of(e) * 10.0).ceil() / 10.0);
            } else {
                line.format_into("{}", (e * 1000.0).ceil() / 1000.0);
            }
            line.push_str(" at ");
            hex_arg(unsafe r.x[k], &mut line);
            if r.two {
                line.push_str(", ");
                hex_arg(unsafe r.y[k], &mut line);
            }
            t.push_string(&line);
            t.push_str("\n");
        }
    }
    t.push_str("//\n");
    return t;
}

// `x` as an exact hexadecimal float (`%a`).
fn hex_arg(x: f64, out: &mut String) {
    if x != x || x == 0.0 || !x.is_finite() {
        out.format_into("{}", x);
        return;
    }
    if x < 0.0 {
        out.push_byte(b'-');
    }
    let b = fl::f64_bits(x.abs());
    let e = (b >> 52) as i64;
    out.format_into(
        "0x{}.",
        if e == 0 {
            0;
        } else {
            1;
        },
    );
    let mut m = String::new();
    m.push_hex(b & 0xFFFFFFFFFFFFF, false);
    for _ in m.len()..13 {
        out.push_byte(b'0');
    }
    out.push_string(&m);
    out.format_into(
        "p{}",
        if e == 0 {
            -1022;
        } else {
            e - 1023;
        },
    );
}

fn log2_of(v: f64) f64 {
    if v <= 0.0 {
        return -1000.0;
    }
    return exponent(v) as f64 + (v / fl::f64_from_bits((1023 + exponent(v)) as u64 << 52)).log2();
}

// Replace the measured block at the top of `path` (or add one) with `block`.
fn write_table(path: str, block: &String) {
    let f = stdio::fopen(path, "rb");
    assert(f != null, "check: cannot open a class module");
    let mut text = String::new();
    let mut buf: [u8; 4096] = [0; 4096];
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 4096, f);
        if n == 0 {
            break;
        }
        for i in 0..n {
            text.push_byte(unsafe buf[i]);
        }
    }
    let _ = unsafe stdio::fclose(f);
    let mut rest = text.as_str();
    if rest.starts_with("// Measured by `tools/simd_math`") {
        // The old block ends at its first bare `//` line.
        let end = rest.find("\n//\n");
        assert(end >= 0, "check: an unterminated measured block");
        rest = rest.slice(end as usize + 4, rest.len());
    }
    let mut out = block.clone();
    out.push_str(rest);
    let w = stdio::fopen(path, "wb");
    assert(w != null, "check: cannot write a class module");
    let n = unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), w);
    assert(n == out.len() && unsafe stdio::fclose(w) == 0, "check: cannot write a class module");
}

// Print one function's tallies per class (`two`: of two arguments); true when a result is over its
// bound.
fn report(name: str, t: i32, st: &Stat, has: u32, two: bool) bool {
    let mut bad = false;
    for c in 0..CLASSES {
        if (has >> c as u32 & 1) == 0 {
            continue;
        }
        let mut line = String::new();
        line.format_into(
            "{} {} f{}: max {} at ",
            unsafe CLASS_NAMES[c],
            name,
            if t == 0 {
                32;
            } else {
                64;
            },
            unsafe st.max[c],
        );
        arg_text(unsafe st.arg[c], &mut line);
        if two {
            line.push_str(", ");
            arg_text(unsafe st.arg2[c], &mut line);
        }
        line.format_into(", {} of {} over the bound", unsafe st.over[c], st.n);
        println("{}", line.as_str());
        bad = bad || unsafe st.over[c] != 0;
    }
    return bad;
}

fn main(args: Vector<str>) i32 {
    let mut do32 = false;
    let mut do64 = false;
    let mut only = "";
    let mut n: u64 = 1000000000;
    let mut sample32: u64 = 0;
    let mut write = false;
    // `--part=K/N`: the functions whose index (the one-argument ones first) is K modulo N.
    let mut part: u64 = 0;
    let mut parts: u64 = 1;
    for i in 1..args.len() {
        let a = args[i];
        if a == "--f32" {
            do32 = true;
        } else if a == "--f64" {
            do64 = true;
        } else if a.starts_with("--only=") {
            only = a.slice(7, a.len());
        } else if a.starts_with("--n=") {
            n = a.slice(4, a.len()).parse_u64().unwrap();
        } else if a.starts_with("--sample32=") {
            sample32 = a.slice(11, a.len()).parse_u64().unwrap();
        } else if a.starts_with("--jobs=") {
            runtime::set_worker_count(a.slice(7, a.len()).parse_u64().unwrap() as usize);
        } else if a.starts_with("--part=") {
            let kn = a.slice(7, a.len());
            let sl = kn.find("/");
            if sl < 0 {
                eprintln("check: --part needs K/N");
                return 2;
            }
            part = kn.slice(0, sl as usize).parse_u64().unwrap();
            parts = kn.slice(sl as usize + 1, kn.len()).parse_u64().unwrap();
            if parts == 0 || part >= parts {
                eprintln("check: --part needs K below N");
                return 2;
            }
        } else if a == "--write" {
            write = true;
        } else {
            eprintln("check: unknown argument {}", a);
            return 2;
        }
    }
    if !do32 && !do64 {
        do32 = true;
        do64 = true;
    }
    if write && (only.len() != 0 || !do32 || !do64 || sample32 != 0 || parts != 1) {
        eprintln("check: --write needs every function, both lane types and every f32 input");
        return 2;
    }
    let fs = f1s();
    let rd = Ref::<Dw>::new();
    let rq = Ref::<Q>::new();
    let mut bad = false;
    let mut rows: [Vector<Row>; CLASSES] = [Vector::<Row>::new(), Vector::<Row>::new(), Vector::<Row>::new()];
    for i in 0..fs.len() {
        let f = fs.at(i);
        // `--only=sincos` names both of its results (`sincos.sin`, `sincos.cos`).
        if only.len() != 0 && f.name != only && !(f.name.starts_with(only) && f.name.slice(only.len(), f.name.len()).starts_with(
            ".",
        )) || i as u64 % parts != part {
            continue;
        }
        let mut rws = [Row { name: f.name, err: [0.0; 2], x: [0.0; 2], y: [0.0; 2], two: false }; CLASSES];
        for t in 0..2 {
            if t == 0 && !do32 || t == 1 && !do64 {
                continue;
            }
            let sb = special1(f, t, &rd, &rq);
            let st = if t == 0 {
                run32(f, sample32, &rq);
            } else {
                run64(f, n, &rd, &rq);
            };
            for c in 0..CLASSES {
                unsafe rws[c].err[t as usize] = unsafe st.max[c];
                unsafe rws[c].x[t as usize] = unsafe st.arg[c];
                bad = bad || unsafe sb[c] != 0;
            }
            bad = report(f.name, t, &st, f.has, false) || bad;
        }
        for c in 0..CLASSES {
            if (f.has >> c as u32 & 1) != 0 {
                unsafe rows[c].push(unsafe rws[c]);
            }
        }
    }
    let f2 = f2s();
    for i in 0..f2.len() {
        let f = f2.at(i);
        if only.len() != 0 && f.name != only || (fs.len() + i) as u64 % parts != part {
            continue;
        }
        let mut rws = [Row { name: f.name, err: [0.0; 2], x: [0.0; 2], y: [0.0; 2], two: true }; CLASSES];
        for t in 0..2 {
            if t == 0 && !do32 || t == 1 && !do64 {
                continue;
            }
            let sb = special2(f, t, &rq);
            let st = if t == 0 {
                run32_2(
                    f,
                    n.min(
                        if sample32 == 0 {
                            n;
                        } else {
                            sample32;
                        },
                    ),
                    &rq,
                );
            } else {
                run64_2(f, n, &rd, &rq);
            };
            for c in 0..CLASSES {
                unsafe rws[c].err[t as usize] = unsafe st.max[c];
                unsafe rws[c].x[t as usize] = unsafe st.arg[c];
                unsafe rws[c].y[t as usize] = unsafe st.arg2[c];
                bad = bad || unsafe sb[c] != 0;
            }
            bad = report(f.name, t, &st, f.has, true) || bad;
        }
        for c in 0..CLASSES {
            unsafe rows[c].push(unsafe rws[c]);
        }
    }
    if write && !bad {
        let paths: [str<'static>; 3] = ["std/simd/math.spc", "std/simd/math/balanced.spc", "std/simd/math/fast.spc"];
        for c in 0..CLASSES {
            let t = table(c, &unsafe rows[c], n);
            write_table(unsafe paths[c], &t);
        }
    }
    return if bad {
        1;
    } else {
        0;
    };
}
