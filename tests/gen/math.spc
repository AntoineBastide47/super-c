// Math model: calls of the vector math classes (`std::simd::math`, `balanced`, `fast`) on inputs drawn
// near their special points: zeros, infinities, NaN, the subnormal and normal extremes, the overflow
// and underflow thresholds of exp, multiples of pi/2 (small and huge), and random bits. Oracle 0: every
// result lane at compile time equals its run time (`const_runtime_parity`). Oracle 1: the planned build
// and the scalar lowering (`SC_SIMD_SCALAR=1`) print the same result bits, and each lane equals the
// same function on that lane's input alone (no lane depends on its neighbors). Each build runs one
// compile job (`--jobs=1`), as `simd_math_test.spc`.
import tests::gen::driver as *;
import tests::harness as h;

// The functions: name and arity (`powi` takes an i32 second argument).
const FUNS: [str<'static>; 27] = [
    "exp",
    "exp2",
    "exp10",
    "expm1",
    "log",
    "log2",
    "log10",
    "log1p",
    "cbrt",
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "sinh",
    "cosh",
    "tanh",
    "asinh",
    "acosh",
    "atanh",
    "erf",
    "erfc",
    "pow",
    "atan2",
    "hypot",
    "powi",
];
const ONE_ARG: usize = 23; // FUNS below this take one argument
const MODS: [str<'static>; 3] = ["mp", "mb", "mf"];

/// One call: the class module, the function, the lane type and the lane bits of each argument.
@derive(Clone)
pub struct MathCase {
    pub m: usize,
    pub f: usize,
    pub t64: bool,
    pub xs: Vector<u64>,
    pub ys: Vector<u64>, // powi: the integers, as u64 bit patterns of i32
}

/// The math model: 1 to `cases_max` calls.
@derive(Clone)
pub struct MathModel {
    pub cases: Vector<MathCase>,
    pub cases_max: u64,
}

pub fn math_model(cases_max: u64) MathModel {
    return MathModel { cases: Vector::<MathCase>::new(), cases_max: cases_max };
}

// An input near a special point, as the lane type's bits.
fn draw(rng: &mut Rng, t64: bool) u64 {
    let pick = rng.below(6);
    if pick == 0 {
        return if t64 {
            rng.next();
        } else {
            rng.next() >> 32;
        };
    }
    if pick == 1 {
        // A multiple of pi/2 (k below 2^20: the product is within an ULP of k pi/2), a few ULP away,
        // either sign; or the double closest to a multiple of pi/2, 6381956970095103 2^797.
        let k = (rng.next() >> 44 + rng.below(20)) as f64;
        let x = if rng.one_in(8) {
            0x1.6ac5b262ca1ffp849;
        } else {
            k * 1.5707963267948966;
        };
        let d = rng.below(5) as i64 - 2;
        let sign = rng.below(2);
        if t64 {
            return (bits64(x) as i64 + d) as u64 & 0x7FFFFFFFFFFFFFFF | sign << 63;
        }
        return (bits32(x as f32) as i64 + d) as u64 & 0x7FFFFFFF | sign << 31;
    }
    // A special point, a few ULP away, either sign: zeros, the subnormal and normal edges, the largest
    // value, infinity, NaN, 1, the overflow and underflow of exp and cosh, 1/2, 2.5, 2^28, and the
    // kernels' thresholds (`Konsts`: hyp_lo, hyp_hi, cw_max, tiny, erfc_max, exp_norm).
    let pts64: [u64; 20] = [
        0,
        1,
        0x000FFFFFFFFFFFFF,
        0x0010000000000000,
        0x7FEFFFFFFFFFFFFF,
        0x7FF0000000000000,
        0x7FF8000000000000,
        0x3FF0000000000000,
        0x40862E42FEFA39EF,
        0x408633CE8FB9F87D,
        0xC0874910D52D3051,
        0x3FE0000000000000,
        0x4003FFFFFFFFFFFF,
        0x41D0000000000000,
        0x21D0000000000000,
        0x5FD0000000000000,
        0x4120000000000000,
        0x3E30000000000000,
        0x403B800000000000,
        0xC086232BDD7ABCD2,
    ];
    let pts32: [u64; 20] = [
        0,
        1,
        0x007FFFFF,
        0x00800000,
        0x7F7FFFFF,
        0x7F800000,
        0x7FC00000,
        0x3F800000,
        0x42B17217,
        0x42B2D4FC,
        0xC2CFF1B5,
        0x3F000000,
        0x401FFFFF,
        0x4E800000,
        0x27800000,
        0x5E800000,
        0x43800000,
        0x39000000,
        0x41280000,
        0xC2AEAC4F,
    ];
    let p = unsafe pts64[rng.below(20) as usize];
    let q = unsafe pts32[rng.below(20) as usize];
    let d = rng.below(7) as i64 - 3;
    let sign = rng.below(2);
    if t64 {
        return (p as i64 + d) as u64 | sign << 63;
    }
    return (q as i64 + d) as u64 & 0x7FFFFFFF | sign << 31;
}

fn bits64(v: f64) u64 {
    return Simd::<f64, 2>::splat(v).to_bits()[0];
}

fn bits32(v: f32) u64 {
    return Simd::<f32, 2>::splat(v).to_bits()[0];
}

fn lanes(t64: bool) usize {
    return if t64 {
        2;
    } else {
        4;
    };
}

extend MathCase {
    // `Simd::<T, N>::from_bits(Simd::<U, N>::from_array([opq::<U>(..), ..]))` (or `opr`, a run-time
    // copy) for argument `ys` or `xs`.
    fn arg(self: &MathCase, second: bool, op: str, out: &mut String) {
        let n = lanes(self.t64);
        let v = if second {
            &self.ys;
        } else {
            &self.xs;
        };
        if second && self.f == 26 {
            out.format_into("Simd::<i32, {}>::from_array([", n);
            for k in 0..n {
                out.format_into(
                    "{}{}::<i32>({})",
                    if k > 0 {
                        ", ";
                    } else {
                        "";
                    },
                    op,
                    (v[k] as u32) as i32,
                );
            }
            out.push_str("])");
            return;
        }
        let (ft, ut) = if self.t64 {
            ("f64", "u64");
        } else {
            ("f32", "u32");
        };
        out.format_into("Simd::<{}, {}>::from_bits(Simd::<{}, {}>::from_array([", ft, n, ut, n);
        for k in 0..n {
            out.format_into(
                "{}{}::<{}>({})",
                if k > 0 {
                    ", ";
                } else {
                    "";
                },
                op,
                ut,
                v[k],
            );
        }
        out.push_str("]))");
    }

    // The call `m::f(args)`.
    fn call(self: &MathCase, op: str, out: &mut String) {
        out.format_into("{}::{}(", unsafe MODS[self.m], unsafe FUNS[self.f]);
        self.arg(false, op, out);
        if self.f >= ONE_ARG {
            out.push_str(", ");
            self.arg(true, op, out);
        }
        out.push_str(")");
    }
}

const DECLS: str<'static> = "import std::simd::math as mp;\nimport std::simd::math::balanced as mb;\nimport std::simd::math::fast as mf;\n";

extend MathModel {
    fn parity(self: &MathModel, exprs: &mut Vector<String>, tys: &mut Vector<String>) {
        for i in 0..self.cases.len() {
            let c = self.cases.at(i);
            for k in 0..lanes(c.t64) {
                let mut e = String::new();
                c.call("opq", &mut e);
                e.format_into("[{}]", k);
                exprs.push(e);
                tys.push(
                    String::from_str(
                        if c.t64 {
                            "f64";
                        } else {
                            "f32";
                        },
                    ),
                );
            }
        }
    }

    // The program of oracle 1: each result's bits (NaN as one pattern), and a line for a lane that
    // differs from the same function on that lane's input alone.
    fn program(self: &MathModel) String {
        let mut s = String::from_str(DECLS);
        s.push_str(
            "static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\n",
        );
        s.push_str(
            "fn b64(v: f64) u64 {\n    return if v != v { 1; } else { Simd::<f64, 2>::splat(v).to_bits()[0]; };\n}\n",
        );
        s.push_str(
            "fn b32(v: f32) u64 {\n    return if v != v { 1; } else { Simd::<f32, 2>::splat(v).to_bits()[0] as u64; };\n}\n",
        );
        s.push_str("fn main() i32 {\n");
        for i in 0..self.cases.len() {
            let c = self.cases.at(i);
            let n = lanes(c.t64);
            let b = if c.t64 {
                "b64";
            } else {
                "b32";
            };
            s.format_into("    let r{} = ", i);
            c.call("opr", &mut s);
            s.push_str(";\n");
            for k in 0..n {
                // Lane k alone: every lane of the arguments set to lane k's input.
                let mut one = c.clone();
                for j in 0..n {
                    one.xs[j] = c.xs[k];
                    if c.f >= ONE_ARG {
                        one.ys[j] = c.ys[k];
                    }
                }
                s.format_into("    println(\"{} {} {{}}\", {}(r{}[{}]));\n", i, k, b, i, k);
                s.format_into("    if {}(", b);
                one.call("opr", &mut s);
                s.format_into(
                    "[{}]) != {}(r{}[{}]) {{\n        println(\"lane {} of case {} depends on its neighbors\");\n    }}\n",
                    k,
                    b,
                    i,
                    k,
                    k,
                    i,
                );
            }
        }
        s.push_str("    return 0;\n}\n");
        return s;
    }
}

extend MathModel as Model {
    pub fn name(self: &Self) str<'static> {
        return "math";
    }

    pub fn generate(self: &mut Self, rng: &mut Rng) {
        self.cases.clear();
        let count = 1 + rng.below(self.cases_max);
        for _ in 0..count {
            let mut c = MathCase {
                m: rng.below(3) as usize,
                f: rng.below(27) as usize,
                t64: rng.one_in(2),
                xs: Vector::<u64>::new(),
                ys: Vector::<u64>::new(),
            };
            // erf is precise only, erfc precise and balanced.
            if c.f == 21 {
                c.m = 0;
            } else if c.f == 22 && c.m == 2 {
                c.m = 1;
            }
            for _ in 0..lanes(c.t64) {
                c.xs.push(draw(rng, c.t64));
                if c.f == 26 {
                    let ns: [u64; 6] = [0, 1, 3, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000];
                    c.ys.push(
                        if rng.one_in(2) {
                            unsafe ns[rng.below(6) as usize];
                        } else {
                            rng.below(80);
                        },
                    );
                } else {
                    c.ys.push(draw(rng, c.t64));
                }
            }
            self.cases.push(c);
        }
    }

    pub fn oracles(self: &Self) usize {
        return 2;
    }

    pub fn check(self: &Self, k: usize) String {
        if k == 0 {
            let mut exprs = Vector::<String>::new();
            let mut tys = Vector::<String>::new();
            self.parity(&mut exprs, &mut tys);
            let mut ev = Vector::<str>::new();
            let mut tv = Vector::<str>::new();
            for i in 0..exprs.len() {
                ev.push(exprs[i].as_str());
                tv.push(tys[i].as_str());
            }
            return h::const_runtime_parity(DECLS, ev[0..ev.len()], tv[0..tv.len()], ["--jobs=1"]);
        }
        let src = self.program();
        let a = h::diff_build(src.as_str(), ["--jobs=1"]);
        let b = h::diff_build(src.as_str(), ["--jobs=1", "SC_SIMD_SCALAR=1"]);
        if !a.built || !b.built {
            return String::from_str("the program does not build");
        }
        let ra = h::diff_run(&a, "");
        let rb = h::diff_run(&b, "");
        if !ra.out.equals(&rb.out) {
            return format("the scalar lowering prints other bits:\n{}\n{}", ra.out.as_str(), rb.out.as_str());
        }
        if ra.out.as_str().contains("depends on its neighbors") {
            return ra.out.clone();
        }
        return String::new();
    }

    pub fn render(self: &Self, k: usize) String {
        if k == 0 {
            let mut exprs = Vector::<String>::new();
            let mut tys = Vector::<String>::new();
            self.parity(&mut exprs, &mut tys);
            let mut ev = Vector::<str>::new();
            let mut tv = Vector::<str>::new();
            for i in 0..exprs.len() {
                ev.push(exprs[i].as_str());
                tv.push(tys[i].as_str());
            }
            return h::parity_program(DECLS, ev[0..ev.len()], tv[0..tv.len()]);
        }
        return self.program();
    }

    // Keep only case j, drop case j, then per case: every lane its first input.
    pub fn candidates(self: &Self) usize {
        return 3 * self.cases.len();
    }

    pub fn reduce(self: &mut Self, i: usize) bool {
        let n = self.cases.len();
        if i < 2 * n {
            if n == 1 {
                return false;
            }
            if i < n {
                let keep = self.cases.at(i).clone();
                self.cases.clear();
                self.cases.push(keep);
            } else {
                let _ = self.cases.remove(i - n);
            }
            return true;
        }
        let j = i - 2 * n;
        let mut c = self.cases.at(j).clone();
        let mut changed = false;
        for k in 1..c.xs.len() {
            if c.xs[k] != c.xs[0] || c.ys[k] != c.ys[0] {
                c.xs[k] = c.xs[0];
                c.ys[k] = c.ys[0];
                changed = true;
            }
        }
        self.cases[j] = c;
        return changed;
    }
}
