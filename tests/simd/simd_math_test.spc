// The vector math classes (`std::simd::math`, `balanced`, `fast`): the special values of every
// function, evaluated at compile time and at run time, agree bit for bit; every lowering gives the same
// results (hashed: the planned build, the scalar lowering, and a fixed hash every target must give).
// The tools' tests (generator, reduced accuracy check) are in `tests/cli/vector_math_tools_test.spc`. Each build
// runs one compile job (`--jobs=1`): a test of the parallel suite takes one CPU, so its large programs
// do not slow the tests that run beside it.
import tests::harness as h;

const DECLS: str<'static> = "import std::simd::math as mp;\nimport std::simd::math::balanced as mb;\nimport std::simd::math::fast as mf;\nimport std::simd::math::lane as ln;\nfn sc_s_mp<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (s, _) = mp::sincos(x);\n    return s;\n}\nfn sc_c_mp<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (_, c) = mp::sincos(x);\n    return c;\n}\nfn sc_s_mb<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (s, _) = mb::sincos(x);\n    return s;\n}\nfn sc_c_mb<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (_, c) = mb::sincos(x);\n    return c;\n}\nfn sc_s_mf<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (s, _) = mf::sincos(x);\n    return s;\n}\nfn sc_c_mf<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {\n    let (_, c) = mf::sincos(x);\n    return c;\n}\n";

// The functions of one argument; `sincos` is `sc_s_<module>` and `sc_c_<module>`.
const ONE: [str<'static>; 23] = [
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
];

// Special arguments: both zeros, both infinities, NaN, the smallest subnormal, the largest finite
// value, 1, -2.5, a large one (the bit reduction of the trigonometric functions), and the domain edges
// -1, 1/2, -1/2 and -3 (an odd negative power).
const NS: usize = 14;
const S64: [u64; NS] = [
    0,
    0x8000000000000000,
    0x7FF0000000000000,
    0xFFF0000000000000,
    0x7FF8000000000000,
    1,
    0x7FEFFFFFFFFFFFFF,
    0x3FF0000000000000,
    0xC004000000000000,
    0x4330000000000001,
    0xBFF0000000000000,
    0x3FE0000000000000,
    0xBFE0000000000000,
    0xC008000000000000,
];
const S32: [u32; NS] = [
    0,
    0x80000000,
    0x7F800000,
    0xFF800000,
    0x7FC00000,
    1,
    0x7F7FFFFF,
    0x3F800000,
    0xC0200000,
    0x4B000001,
    0xBF800000,
    0x3F000000,
    0xBF000000,
    0xC0400000,
];

// Pairs of the functions of two arguments, by index into the specials: with pow's Annex F cases (-0 to
// an odd negative power, -1 to +-inf, a negative x to a fraction, +-0 to -inf).
const PAIRS: [[usize; 2]; 14] = [
    [0, 8],
    [1, 9],
    [2, 7],
    [3, 8],
    [4, 0],
    [7, 4],
    [8, 9],
    [6, 7],
    [1, 13],
    [10, 2],
    [10, 3],
    [8, 11],
    [0, 3],
    [1, 3],
];
const POWI_N: [i32; 5] = [0, -1, 3, 2147483647, -2147483648];

// The special-value cases of class module `m` ("mp", "mb", "mf") in one lane type: each function at
// each special argument as `m::f(splat(x))[lane]`.
// Whether class module `m` lacks function `f`: erf is precise only, erfc precise and balanced.
const fn absent(m: str, f: str) bool {
    return m == "mf" && f.starts_with("erf") || m == "mb" && f == "erf";
}

// `w_<name>(params)`, a wrapper of `call` into `decls`, for lanes `ty` x `n`.
fn wrap(decls: &mut String, ty: str, n: usize, name: str, params: str, call: str) {
    decls.format_into("@noinline\nfn w_{}({}) Simd<{}, {}> {{\n    return {};\n}}\n", name, params, ty, n, call);
}

// The cases call each function through a wrapper (`w_<f>`, into `decls`): the kernel inlines once into
// it, not into the run-time copy of every case, which keeps the program's C small enough to build
// quickly at opt-level 0.
fn special_cases(m: str, f64_lanes: bool, decls: &mut String, exprs: &mut Vector<String>, tys: &mut Vector<String>) {
    let ty = if f64_lanes {
        "f64";
    } else {
        "f32";
    };
    let n: usize = if f64_lanes {
        2;
    } else {
        4;
    };
    let mut args = Vector::<String>::new();
    for i in 0usize..NS {
        let mut a = String::new();
        // The lane bit cast: it folds at compile time (a union pun does not).
        if f64_lanes {
            a.format_into("Simd::<f64, 2>::from_bits(Simd::<u64, 2>::splat(opq::<u64>({})))", unsafe S64[i]);
        } else {
            a.format_into("Simd::<f32, 4>::from_bits(Simd::<u32, 4>::splat(opq::<u32>({})))", unsafe S32[i]);
        }
        args.push(a);
    }
    let lane = if f64_lanes {
        1;
    } else {
        3;
    };
    let x = format("x: Simd<{}, {}>", ty, n);
    for f in ONE {
        if absent(m, f) {
            continue;
        }
        wrap(decls, ty, n, f, x.as_str(), format("{}::{}(x)", m, f).as_str());
        for i in 0usize..NS {
            exprs.push(format("w_{}({})[{}]", f, args[i].as_str(), lane));
            tys.push(String::from_str(ty));
        }
    }
    for sc in ["s", "c"] {
        wrap(decls, ty, n, format("sc_{}", sc).as_str(), x.as_str(), format("sc_{}_{}(x)", sc, m).as_str());
    }
    for i in 0usize..NS {
        exprs.push(format("w_sc_s({})[{}]", args[i].as_str(), lane));
        tys.push(String::from_str(ty));
        exprs.push(format("w_sc_c({})[{}]", args[i].as_str(), lane));
        tys.push(String::from_str(ty));
    }
    let xy = format("x: Simd<{}, {}>, y: Simd<{}, {}>", ty, n, ty, n);
    for f in ["pow", "atan2", "hypot"] {
        wrap(decls, ty, n, f, xy.as_str(), format("{}::{}(x, y)", m, f).as_str());
        for p in PAIRS {
            exprs.push(format("w_{}({}, {})[{}]", f, args[p[0]].as_str(), args[p[1]].as_str(), lane));
            tys.push(String::from_str(ty));
        }
    }
    wrap(
        decls,
        ty,
        n,
        "powi",
        format("x: Simd<{}, {}>, k: Simd<i32, {}>", ty, n, n).as_str(),
        format("{}::powi(x, k)", m).as_str(),
    );
    for i in [0usize, 2, 4, 8] {
        for k in POWI_N {
            exprs.push(format("w_powi({}, Simd::<i32, {}>::splat(opq::<i32>({})))[{}]", args[i].as_str(), n, k, lane));
            tys.push(String::from_str(ty));
        }
    }
}

fn expect_specials(m: str, f64_lanes: bool) {
    let mut decls = String::from_str(DECLS);
    let mut exprs = Vector::<String>::new();
    let mut tys = Vector::<String>::new();
    special_cases(m, f64_lanes, &mut decls, &mut exprs, &mut tys);
    let mut ev = Vector::<str>::new();
    let mut tv = Vector::<str>::new();
    for i in 0..exprs.len() {
        ev.push(exprs[i].as_str());
        tv.push(tys[i].as_str());
    }
    let d = h::const_runtime_parity(decls.as_str(), ev[0..ev.len()], tv[0..tv.len()], ["--jobs=1"]);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "a special value differs between compile time and run time");
}

@test(timeout = 300)
fn simd_math_specials_precise_f32() {
    expect_specials("mp", false);
}

@test(timeout = 300)
fn simd_math_specials_precise_f64() {
    expect_specials("mp", true);
}

@test(timeout = 300)
fn simd_math_specials_balanced_f32() {
    expect_specials("mb", false);
}

@test(timeout = 300)
fn simd_math_specials_balanced_f64() {
    expect_specials("mb", true);
}

@test(timeout = 300)
fn simd_math_specials_fast_f32() {
    expect_specials("mf", false);
}

@test(timeout = 300)
fn simd_math_specials_fast_f64() {
    expect_specials("mf", true);
}

// 10^5 inputs per function, class and lane type (random bit patterns and values of every binade),
// hashed: FNV-1a over the result bits, NaN as one pattern (its payload and sign are the hardware's).
// The lanes of one call do not depend on each other: on the first 10^4 inputs, each lane of a call at
// the other lane count equals the call on that lane's inputs alone. The program prints each hash and
// their combination.
const HASH_SRC: str<'static> = "import std::simd::math as mp;\nimport std::simd::math::balanced as mb;\nimport std::simd::math::fast as mf;\nimport std::simd::math::lane as ln;\nimport std::float as fl;\nconst INPUTS: usize = 100000;\nconst LANE_CHECK: usize = 10000;\nstatic mut ALL: u64 = 0xcbf29ce484222325;\nfn mix(h: u64, b: u64) u64 {\n    return (h ^ b).wrapping_mul(0x100000001b3);\n}\nfn bits64(v: f64) u64 {\n    return if v != v { 0x7FF8000000000000; } else { fl::f64_bits(v); };\n}\nfn bits32(v: f32) u64 {\n    return if v != v { 0x7FC00000; } else { fl::f32_bits(v) as u64; };\n}\nfn input(i: usize) u64 {\n    let mut z = (i as u64).wrapping_add(0x9E3779B97F4A7C15).wrapping_mul(0xBF58476D1CE4E5B9);\n    z = (z ^ z >> 31).wrapping_mul(0x94D049BB133111EB);\n    return z ^ z >> 29;\n}\nfn x64(i: usize) f64 {\n    let r = input(i);\n    if r % 3 == 0 {\n        return fl::f64_from_bits(r);\n    }\n    let e = (r >> 8) % 120;\n    let m = 1.0 + ((r >> 12) % 4503599627370496) as f64 * 0x1p-52;\n    let v = m * fl::f64_from_bits((1023 + e - 60) << 52);\n    return if (r >> 7 & 1) == 0 { v; } else { -v; };\n}\nfn x32(i: usize) f32 {\n    let r = input(i);\n    if r % 3 == 0 {\n        return fl::f32_from_bits((r >> 32) as u32);\n    }\n    return x64(i) as f32;\n}\nfn y64(i: usize) f64 {\n    return x64(i + 7777777);\n}\nfn y32(i: usize) f32 {\n    return x32(i + 7777777);\n}\nfn ni(i: usize) i32 {\n    return (input(i) >> 40) as i32 % 300;\n}\nfn xv64<const N: usize>(i: usize) Simd<f64, N> {\n    let mut a: [f64; N] = [0.0; N];\n    for k in 0usize..N {\n        unsafe a[k] = x64(i + k);\n    }\n    return Simd::from_array(a);\n}\nfn xv32<const N: usize>(i: usize) Simd<f32, N> {\n    let mut a: [f32; N] = [0.0; N];\n    for k in 0usize..N {\n        unsafe a[k] = x32(i + k);\n    }\n    return Simd::from_array(a);\n}\nfn yv64<const N: usize>(i: usize) Simd<f64, N> {\n    return xv64::<N>(i + 7777777);\n}\nfn yv32<const N: usize>(i: usize) Simd<f32, N> {\n    return xv32::<N>(i + 7777777);\n}\nfn nv<const N: usize>(i: usize) Simd<i32, N> {\n    let mut a: [i32; N] = [0; N];\n    for k in 0usize..N {\n        unsafe a[k] = ni(i + k);\n    }\n    return Simd::from_array(a);\n}\nfn xs64<const N: usize>(i: usize) Simd<f64, N> {\n    return Simd::splat(x64(i));\n}\nfn xs32<const N: usize>(i: usize) Simd<f32, N> {\n    return Simd::splat(x32(i));\n}\nfn ys64<const N: usize>(i: usize) Simd<f64, N> {\n    return Simd::splat(y64(i));\n}\nfn ys32<const N: usize>(i: usize) Simd<f32, N> {\n    return Simd::splat(y32(i));\n}\nfn ns<const N: usize>(i: usize) Simd<i32, N> {\n    return Simd::splat(ni(i));\n}\nfn report(name: str, m: str, h: u64, d: u64) {\n    unsafe ALL = mix(unsafe ALL, h);\n    print(\"{} {} {}\\n\", m, name, h);\n    if d != 0 {\n        print(\"LANES DIFFER {} {}\\n\", m, name);\n    }\n}\n";

// The functions the hash program runs beyond those of `ONE`: their argument kinds ("x": the float
// inputs, "y": a second float input, "n": powi's integers).
const MORE: [[str<'static>; 2]; 6] = [
    ["pow", "xy"],
    ["atan2", "xy"],
    ["hypot", "xy"],
    ["powi", "xn"],
    ["sincos_s", "x"],
    ["sincos_c", "x"],
];

// The call of `m::f` at lane count `n` on the inputs from index `at`, through its wrapper (`kernel`):
// `form` "v" a lane per input, "s" input `at` in every lane.
fn hash_call(m: str, f: str, kinds: str, t: str, n: usize, form: str, at: str) String {
    let mut c = String::new();
    c.format_into("k_{}_{}_{}_{}(", m, f, t, n);
    for b in kinds.bytes() {
        if b != b'x' {
            c.push_str(", ");
        }
        if b == b'n' {
            c.format_into("n{}::<{}>({})", form, n, at);
        } else {
            c.format_into("{}{}{}::<{}>({})", b as char, form, t, n, at);
        }
    }
    c.push_str(")");
    return c;
}

// The wrapper of `m::f` at lane count `n`: the kernel inlines once into it, not into each call of the
// hash loops, which keeps the program's C small enough to build quickly at opt-level 0.
fn kernel(s: &mut String, m: str, f: str, kinds: str, t: str, n: usize) {
    s.format_into("@noinline\nfn k_{}_{}_{}_{}(", m, f, t, n);
    let mut args = String::new();
    for b in kinds.bytes() {
        if b != b'x' {
            s.push_str(", ");
            args.push_str(", ");
        }
        if b == b'n' {
            s.format_into("an: Simd<i32, {}>", n);
        } else {
            s.format_into("a{}: Simd<f{}, {}>", b as char, t, n);
        }
        args.format_into("a{}", b as char);
    }
    s.format_into(") Simd<f{}, {}> {{\n    return ", t, n);
    if f.starts_with("sincos") {
        s.format_into("{}_{}", f, m);
    } else {
        s.format_into("{}::{}", m, f);
    }
    s.format_into("({});\n}}\n", args.as_str());
}

// The hash program of class `m` ("mp", "mb" or "mf") and lane type `t` ("32" or "64").
fn hash_program(m: str, t: str) String {
    let mut s = String::from_str(HASH_SRC);
    let mut calls = String::from_str("fn main() i32 {\n");
    for sc in ["s", "c"] {
        s.format_into(
            "fn sincos_{}_{}<T: ln::Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {{\n    let {} = {}::sincos(x);\n    return v;\n}}\n",
            sc,
            m,
            if sc == "s" {
                "(v, _)";
            } else {
                "(_, v)";
            },
            m,
        );
    }
    let (n1, n2) = if t == "32" {
        (4usize, 8usize);
    } else {
        (2usize, 4usize);
    };
    let mut fs = Vector::<[str<'static>; 2]>::new();
    for f in ONE {
        if !absent(m, f) {
            fs.push([f, "x"]);
        }
    }
    for f in MORE {
        fs.push(f);
    }
    for q in 0..fs.len() {
        let (name, kinds) = (fs[q][0], fs[q][1]);
        kernel(&mut s, m, name, kinds, t, n1);
        kernel(&mut s, m, name, kinds, t, n2);
        s.format_into(
            "fn h_{}_{}_{}() {{\n    let mut h: u64 = 0xcbf29ce484222325;\n    let mut i: usize = 0;\n    while i < INPUTS {{\n        let r = {};\n        for k in 0usize..{} {{\n            h = mix(h, bits{}(r[k]));\n        }}\n        i += {};\n    }}\n    let mut d: u64 = 0;\n    let mut j: usize = 0;\n    while j < LANE_CHECK {{\n        let w = {};\n        for k in 0usize..{} {{\n            if bits{}(w[k]) != bits{}({}[0]) {{\n                d += 1;\n            }}\n        }}\n        j += {};\n    }}\n    report(\"{}{}\", \"{}\", h, d);\n}}\n",
            m,
            name,
            t,
            hash_call(m, name, kinds, t, n1, "v", "i").as_str(),
            n1,
            t,
            n1,
            hash_call(m, name, kinds, t, n2, "v", "j").as_str(),
            n2,
            t,
            t,
            hash_call(m, name, kinds, t, n1, "s", "j + k").as_str(),
            n2,
            name,
            t,
            m,
        );
        calls.format_into("    h_{}_{}_{}();\n", m, name, t);
    }
    s.push_string(&calls);
    s.push_str("    print(\"all {}\\n\", unsafe ALL);\n    return 0;\n}\n");
    return s;
}

// The combined hash per class and lane type every lowering of every target must give, one test each (a
// program per class keeps each build short at opt-level 0). A kernel or coefficient change moves it:
// the new value is the `all` line `super-c test --filter=simd_math_lowerings` prints.
const ALL_PRECISE_32: str<'static> = "all 10722911270300409994";
const ALL_PRECISE_64: str<'static> = "all 10181024995896958418";
const ALL_BALANCED_32: str<'static> = "all 8602238845782334407";
const ALL_BALANCED_64: str<'static> = "all 14186468018445188190";
const ALL_FAST_32: str<'static> = "all 2925347291482854181";
const ALL_FAST_64: str<'static> = "all 5143227870906677884";

@test(timeout = 300)
fn simd_math_lowerings_precise_f32() {
    lowerings_agree("mp", "32", ALL_PRECISE_32);
}

@test(timeout = 300)
fn simd_math_lowerings_precise_f64() {
    lowerings_agree("mp", "64", ALL_PRECISE_64);
}

@test(timeout = 300)
fn simd_math_lowerings_balanced_f32() {
    lowerings_agree("mb", "32", ALL_BALANCED_32);
}

@test(timeout = 300)
fn simd_math_lowerings_balanced_f64() {
    lowerings_agree("mb", "64", ALL_BALANCED_64);
}

@test(timeout = 300)
fn simd_math_lowerings_fast_f32() {
    lowerings_agree("mf", "32", ALL_FAST_32);
}

@test(timeout = 300)
fn simd_math_lowerings_fast_f64() {
    lowerings_agree("mf", "64", ALL_FAST_64);
}

// The hash program of class `m` and lane type `t` gives `all` under the native and the scalar lowering.
fn lowerings_agree(m: str, t: str, all: str) {
    let src = hash_program(m, t);
    let a = h::diff_build(src.as_str(), ["--jobs=1"]);
    let b = h::diff_build(src.as_str(), ["--jobs=1", "SC_SIMD_SCALAR=1"]);
    if !a.built || !b.built {
        eprintln("{}{}", a.diag.as_str(), b.diag.as_str());
    }
    assert(a.built && b.built, "the hash program builds");
    let ra = h::diff_run(&a, "");
    let rb = h::diff_run(&b, "");
    assert_eq(ra.exit, 0);
    let out = ra.out.as_str();
    assert(out == rb.out.as_str(), "the scalar lowering gives other results");
    assert(!out.contains("LANES DIFFER"), "a lane depends on its neighbors");
    if !out.contains(all) {
        eprintln("{}", out);
    }
    assert(out.contains(all), "the results differ from the fixed hash");
}
