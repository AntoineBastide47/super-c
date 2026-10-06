// The lane operations of std/simd.spc (the vector model, tests/gen/vector.spc): every operation over
// every lane type and 2, 4 and the most lanes with boundary inputs, as a constant and at run time and
// against a scalar lane loop; every conversion pair; the operators' diagnostics; vector loads and
// stores at the bounds; the borrow rules of a store; and the generator's fixed seeds.
import tests::gen::driver as gen;
import tests::gen::vector as vec;
import tests::harness as h;

// Both oracles over every case of the operations `ops` (every lane type, 2, 4 and the most lanes, and
// for a conversion every target), in programs of at most 256 cases.
fn sweep(ops: []u8) {
    let mut cases = Vector::<vec::VCase>::new();
    for op in ops {
        let mut rng = gen::Rng::new(op as u64 * 7919 + 1);
        for t in 0..10u8 {
            let most = vec::max_lanes(t);
            for n in [2u64, 4, most] {
                if n == 4 && most == 4 || !vec::op_ok(op, t, n) {
                    continue;
                }
                for u in -1..10 {
                    let mut c = vec::VCase {};
                    if u >= 0 == vec::converts(op) && vec::draw_case(&mut rng, op, t, n, u, &mut c) {
                        cases.push(c);
                    }
                }
            }
        }
    }
    let mut i: usize = 0;
    while i < cases.len() {
        let mut part = Vector::<vec::VCase>::new();
        while part.len() < 256 && i < cases.len() {
            part.push(cases.at(i).clone());
            i += 1;
        }
        let r = vec::check_cases(&part);
        if r.len() != 0 {
            eprintln("{}", r.as_str());
        }
        assert(r.len() == 0, "a vector operation differs");
    }
}

@test
fn operators_match_constants_and_scalar_loops() {
    sweep([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
}

@test
fn comparisons_and_choose_match_constants_and_scalar_loops() {
    sweep([14, 15, 16, 17, 18, 19, 20, 21]);
}

@test
fn wrapping_checked_saturating_min_max_match() {
    sweep([22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34]);
}

@test
fn integer_lane_functions_match() {
    sweep([39, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51]);
}

@test
fn float_lane_functions_match() {
    sweep([35, 36, 37, 38, 40, 42, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]);
}

@test
fn casts_of_every_lane_type_pair_match() {
    sweep([65, 66]);
}

@test
fn widen_narrow_and_bitcast_match() {
    sweep([67, 68, 69, 70, 71]);
}

@test
fn halves_concat_iota_and_bits_match() {
    sweep([72, 73, 74, 75, 76, 77]);
}

// The build of `src` fails with a diagnostic containing `needle`.
fn expect_build_err(label: str, src: str, needle: str) {
    let b = h::diff_build(src, []);
    if b.built || !b.diag.contains(needle) {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(!b.built && b.diag.contains(needle), label);
}

// The run of `src` with argument `arg` traps with `msg` (on stderr), or exits 0 when `msg` is empty.
fn expect_run(label: str, src: str, arg: str, msg: str) {
    let b = h::diff_build(src, []);
    if !b.built {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(b.built, label);
    let r = h::diff_run(&b, arg);
    let ok = if msg.len() == 0 {
        r.exit == 0;
    } else {
        r.exit != 0 && r.err.contains(msg);
    };
    if !ok {
        eprintln("{}: exit {}: {}{}", label, r.exit, r.out.as_str(), r.err.as_str());
    }
    assert(ok, label);
}

@test
fn operator_misuse_is_diagnosed() {
    let main = "\nfn main() i32 {\n    return 0;\n}\n";
    let cases: [[str; 2]; 11] = [
        ["fn f(a: i32x4, b: f32x4) { let _ = a + b; }", "mismatched types"],
        ["fn f(a: f32x4) { let _ = a + 1.0; }", "use `Simd::splat`"],
        ["fn f(a: f32x4) { let _ = 1.0 + a; }", "use `Simd::splat`"],
        ["fn f(a: i32x4) { let _ = a << 1u32; }", "a shift count is the vector type or its lane type"],
        ["fn f(a: f32x4) { let _ = a << a; }", "unsatisfied interface bounds"],
        ["fn f(a: f32x4) { let _ = a % a; }", "unsatisfied interface bounds"],
        ["fn f(a: f32x4) { let _ = ~a; }", "unsatisfied interface bounds"],
        [
            "fn f(a: u32x4) { let _ = -a; }",
            "cannot apply unary operator '-' to type 'Simd<u32, 4>' (its lanes have no sign)",
        ],
        ["fn f(a: f32x4) { let _ = a.min(a); }", "unsatisfied interface bounds"],
        [
            "@intrinsic(\"simd.add\")\nfn g(a: f32x4, b: f32x4) f32x4;",
            "'@intrinsic' is reserved for the standard library",
        ],
        ["@intrinsic(\"simd.nope\")\nfn g(a: f32x4) f32x4;", "unknown intrinsic 'simd.nope'"],
    ];
    for c in cases {
        let mut src = String::from_str(c[0]);
        src.push_str(main);
        expect_build_err(c[1], src.as_str(), c[1]);
    }
    expect_build_err(
        "widen to a narrower type",
        "fn main() i32 {\n    let v = Simd::<i32, 4>::splat(1).widen::<i16>();\n    return v[0] as i32 - 1;\n}\n",
        "widen: U must be a wider lane type of the same kind as T",
    );
    expect_build_err(
        "bitcast to another size",
        "fn main() i32 {\n    let v = Simd::<i32, 4>::splat(1).bitcast::<u8, 8>();\n    return v[0] as i32;\n}\n",
        "bitcast: the two vectors must have the same size",
    );
    expect_build_err(
        "narrow to a wider type",
        "fn main() i32 {\n    let v = Simd::<i16, 4>::splat(1).narrow::<i32>();\n    return v[0];\n}\n",
        "narrow: U must be a narrower integer type than T",
    );
    expect_build_err(
        "low half of two lanes",
        "fn main() i32 {\n    let v = Simd::<i32, 2>::splat(1).low_half();\n    return v[0];\n}\n",
        "low_half: the vector needs at least 4 lanes",
    );
}

// Vector operators through generic code over a bound (`Add`, `SimdSigned`), a free generic function as
// a value, an unqualified prelude function with a turbofish, compound assignments with a lane shift
// count, and both forms of `choose`.
@test
fn operators_dispatch_through_bounds_and_values() {
    let src = M"(import std::simd;
fn sum3<V: Add<Output = V> + Copy>(a: V, b: V, c: V) V {
    return a + b + c;
}
fn neg<T: SimdSigned, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    return -v;
}
fn main() i32 {
    let a = Simd::<f32, 4>::from_array([1.0, -2.0, 3.0, 0.5]);
    let s = sum3(a, a, a);
    let f = simd::concat::<f32, 4>;
    let r = f(s * s, s).sqrt().low_half();
    let m = r.greater_than(a);
    let c = simd::choose(m, r, a) + m.choose(a, r);
    let n = neg(Simd::<i8, 4>::splat(5));
    let mut k = iota::<u16, 8>();
    k <<= 2;
    k >>= 1u16;
    k += Simd::<u16, 8>::splat(1);
    if s[1] != -6.0 || r[1] != 6.0 || c[3] != 2.0 || n[2] != -5 || k[7] != 15 {
        return 1;
    }
    return 0;
}
)";
    expect_run("bound dispatch, a function value, an unqualified turbofish and choose", src, "", "");
}

// The free forms are the methods: `simd::f(a, ..)` is `a.f(..)`, generic code over the lanes' unsigned
// type included.
@test
fn free_forms_are_the_methods() {
    let src = M"(import std::simd;

fn ud<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T::Unsigned, N> {
    return simd::abs_diff(a, b);
}

fn main() i32 {
    let a = Simd::<i32, 4>::from_array([5, -3, 7, 0]);
    let b = Simd::<i32, 4>::splat(2);
    let (w, o) = simd::checked_add(a, b);
    let f = Simd::<f32, 4>::from_array([1.5, -2.0, 4.0, 9.0]);
    let g = simd::fma(f, f, f);
    let bits = simd::to_bits(f);
    let back = simd::from_bits::<f32, 4>(bits);
    let d = ud(a, b);
    let m = simd::less_than(a, b);
    let c = simd::clamp(a, Simd::<i32, 4>::splat(-1), b);
    if w[0] != 7 || o.any() || g[0] != 3.75 || back[3] != 9.0 || d[1] != 5 || !m.get(1) || c[0] != 2 || c[1] != -1 {
        return 1;
    }
    if simd::min(a, b)[2] != 2 || simd::abs(a)[1] != 3 || simd::sqrt(f)[3] != 3.0 || simd::count_ones(b)[0] != 1 {
        return 2;
    }
    return 0;
}
)";
    expect_run("the free forms", src, "", "");
}

// A slice access checks its lanes once: `start <= len && N <= len - start`, overflow-free, and the trap
// names the lanes, the start and the length, as a constant and at run time.
@test
fn vector_loads_and_stores_check_their_range() {
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let mut b = [0; 10];
    let start = args.at(1).parse_u64().unwrap() as usize;
    let v = simd::load::<i32, 4>(a, start);
    simd::store(b, start, v);
    let w = unsafe simd::load_unaligned::<i32, 4>(&a as *const [i32; 10] as *const i32 + start);
    unsafe simd::store_aligned::<i32, 4, 4>(&mut b as *mut [i32; 10] as *mut i32 + start, w + w);
    return unsafe b[start + 3] - 2 * unsafe a[start + 3];
}
)";
    expect_run("start = len - N", src, "6", "");
    expect_run("start = len - N + 1", src, "7", "index out of bounds: 4 lanes from 7 but the length is 10");
    expect_run("start > len", src, "11", "index out of bounds: 4 lanes from 11 but the length is 10");
    expect_run(
        "start = usize::MAX",
        src,
        "18446744073709551615",
        "index out of bounds: 4 lanes from 18446744073709551615 but the length is 10",
    );
    let decls = M"(import std::simd;
const fn ld(start: usize) i32 {
    let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let mut b = [0; 10];
    simd::store(b, start, simd::load::<i32, 4>(a, start));
    return unsafe b[start] + unsafe b[start + 3];
}
)";
    let exprs: [str; 4] = [
        "ld(opq::<usize>(6))",
        "ld(opq::<usize>(7))",
        "ld(opq::<usize>(11))",
        "ld(opq::<usize>(18446744073709551615))",
    ];
    let tys: [str; 4] = ["i32", "i32", "i32", "i32"];
    let d = h::const_runtime_parity(decls, exprs, tys, []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "vector loads and stores as constants");
}

// IEEE 754-2019 minimumNumber/maximumNumber and minimum/maximum on every pair of NaN, -0.0, +0.0 and
// 1.0, and an fma whose one rounding differs from a multiply then an add.
@test
fn float_min_max_table_and_fma_rounding() {
    let src = M"(const fn bits(v: Simd<f64, 8>) Simd<u64, 8> {
    return v.is_nan().choose(Simd::<u64, 8>::splat(1), v.to_bits());
}
const fn mix(h: u64, v: Simd<u64, 8>) u64 {
    let mut r = h;
    for l in v.to_array() {
        r = r.wrapping_mul(31).wrapping_add(l);
    }
    return r;
}
const fn table() u64 {
    let vals: [f64; 4] = [0.0 / 0.0, -0.0, 0.0, 1.0];
    let mut h: u64 = 0;
    for half in 0..2usize {
        let mut a: [f64; 8] = [0.0; 8];
        let mut b: [f64; 8] = [0.0; 8];
        for i in 0..8usize {
            unsafe {
                a[i] = vals[(half * 8 + i) / 4];
                b[i] = vals[i % 4];
            }
        }
        let x = Simd::<f64, 8>::from_array(a);
        let y = Simd::<f64, 8>::from_array(b);
        h = mix(mix(mix(mix(h, bits(x.min_num(y))), bits(x.max_num(y))), bits(x.minimum(y))), bits(x.maximum(y)));
    }
    return h;
}
const T: u64 = table();
fn main() i32 {
    // NaN, -0, +0, 1 by row (x) and column (y); 1 stands for NaN.
    let n: u64 = 1;
    let mz: u64 = 0x8000000000000000;
    let pz: u64 = 0;
    let one: u64 = 0x3FF0000000000000;
    let min_num = [n, mz, pz, one, mz, mz, mz, mz, pz, mz, pz, pz, one, mz, pz, one];
    let max_num = [n, mz, pz, one, mz, mz, pz, one, pz, pz, pz, one, one, one, one, one];
    let minimum = [n, n, n, n, n, mz, mz, mz, n, mz, pz, pz, n, mz, pz, one];
    let maximum = [n, n, n, n, n, mz, pz, one, n, pz, pz, one, n, one, one, one];
    let mut h: u64 = 0;
    for half in 0..2usize {
        for t in [min_num, max_num, minimum, maximum] {
            for i in 0..8usize {
                h = h.wrapping_mul(31).wrapping_add(unsafe t[half * 8 + i]);
            }
        }
    }
    if h != T || h != table() {
        return 1;
    }
    // 1 + 2^-27 squared needs one rounding: the product's 2^-54 term survives only in a fused add.
    let e: f64 = 1.0 + 0.0000000074505805969238281;
    let v = Simd::<f64, 2>::splat(e);
    let c = Simd::<f64, 2>::splat(-1.0 - 0.000000014901161193847656f64);
    let fused = v.fma(v, c);
    let split = v * v + c;
    if fused[0] != 0.0000000000000000555111512312578270 || split[0] != 0.0 {
        return 2;
    }
    return 0;
}
)";
    expect_run("the min/max table and fma", src, "", "");
}

// A store needs its slice mutably borrowed, a load shared: a live borrow of the other kind conflicts.
// A `[]mut` view written through (a store, a call) conflicts with a live shared borrow of it; as a
// `[]T` it is borrowed shared.
@test
fn vector_access_borrows_its_slice() {
    expect_build_err(
        "a store under a shared borrow",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let r = &a[0];\n    simd::store(a, 0, Simd::<i32, 4>::splat(0));\n    return *r;\n}\n",
        "borrow",
    );
    expect_build_err(
        "a load under a mutable borrow",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let m = &mut a[0];\n    let v = simd::load::<i32, 4>(a, 0);\n    *m = v[1];\n    return a[0];\n}\n",
        "borrow",
    );
    expect_build_err(
        "a store through a `[]mut` view under a shared borrow of it",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let s: []mut i32 = a;\n    let r = &s[0];\n    simd::store(s, 0, Simd::<i32, 4>::splat(7));\n    return *r;\n}\n",
        "borrow",
    );
    expect_build_err(
        "a `[]mut` view passed to a call under a shared borrow of it",
        "fn g(s: []mut i32) {\n    s[0] = 7;\n}\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let s: []mut i32 = a;\n    let r = &s[0];\n    g(s);\n    return *r;\n}\n",
        "borrow",
    );
    expect_build_err(
        "a write through a `[]mut` view while its `[]T` view is live",
        "fn main() i32 {\n    let mut a = [3, 4];\n    let y: []mut i32 = a;\n    let r: []i32 = y;\n    y[0] = 5;\n    return r[0];\n}\n",
        "borrow",
    );
    // A `[]mut` view is a `[]T` for a load: an update in place needs no second view.
    expect_run(
        "an update in place through one view",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4, 5, 6, 7, 8];\n    let y: []mut i32 = a;\n    let v = simd::load::<i32, 4>(y, 0);\n    simd::store(y, 4, v + simd::load::<i32, 4>(y, 4));\n    return a[7] - 12;\n}\n",
        "",
        "",
    );
}

// The C of the vector operations is plain C: no target intrinsic header, no vector extension.
@test
fn vector_c_is_portable() {
    let src = "fn main() i32 {\n    let v = Simd::<f32, 4>::splat(2.0);\n    let w = (v * v).sqrt().min_num(v);\n    return w[0] as i32 - 2;\n}\n";
    h::expect_exit("the program runs", src, 0);
    for needle in ["immintrin", "arm_neon", "wasm_simd128", "vector_size", "__m128"] {
        h::expect_c_absent(needle, src, needle);
    }
}
