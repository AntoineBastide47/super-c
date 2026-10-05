// The vector and mask types of std/simd.spc: layout on the host and on wasm32, each diagnostic, alias
// identity, lane traps and bit-exact round trips with constant and run-time parity, every mask
// operation, generic code over three lane types, reflection, and the C of a program without vectors.
import tests::harness as h;
import tests::cli_harness as cli;

// One static_assert per vector and mask type: its size, its alignment and, for a vector, LANES; and a
// struct holding one of each, so the C defines every type and asserts its layout too.
fn layout_source() String {
    let lanes: [str; 10] = ["i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64"];
    let bytes: [u64; 10] = [1, 1, 2, 2, 4, 4, 8, 8, 4, 8];
    let ns: [u64; 6] = [2, 4, 8, 16, 32, 64];
    let mut s = String::new();
    let mut fields = String::from_str("struct All {\n");
    let mut init = String::from_str("    let all = All {\n");
    for k in 0..10 {
        for n in ns {
            let size = unsafe bytes[k] * n;
            if size > 64 {
                continue;
            }
            let t = unsafe lanes[k];
            fields.format_into("    pub {}x{}: Simd<{}, {}>,\n", t, n, t, n);
            init.format_into("        {}x{}: [{}; {}],\n", t, n, zero_lit(k >= 8), n);
            s.format_into(
                "static_assert(sizeof(Simd<{}, {}>) == {} && alignof(Simd<{}, {}>) == {} && Simd::<{}, {}>::LANES == {}, \"Simd<{}, {}>\");\n",
                t,
                n,
                size,
                t,
                n,
                size.min(16),
                t,
                n,
                n,
                t,
                n,
            );
        }
    }
    for n in ns {
        s.format_into(
            "static_assert(sizeof(Mask<{}>) == {} && alignof(Mask<{}>) == {}, \"Mask<{}>\");\n",
            n,
            (n / 8).max(1),
            n,
            (n / 8).max(1),
            n,
        );
        fields.format_into("    pub m{}: Mask<{}>,\n", n, n);
        init.format_into("        m{}: Mask::<{}>::splat(false),\n", n, n);
    }
    s.format_into(
        "{}}}\nfn main() i32 {{\n{}    }};\n    return all.i8x2[1] as i32 + all.m64.count() as i32;\n}}\n",
        fields.as_str(),
        init.as_str(),
    );
    return s;
}

// The zero literal of a lane type: `0.0` for a float lane.
fn zero_lit(float: bool) str<'static> {
    if float {
        return "0.0";
    }
    return "0";
}

@test
fn every_vector_and_mask_has_its_size_alignment_and_lane_count() {
    let src = layout_source();
    // The host build compiles the C, whose own static assertions check the layout model.
    let b = h::diff_build(src.as_str(), []);
    if !b.built {
        eprintln("{}", b.diag.as_str());
    }
    assert(b.built, "the host layout");
    let p = cli::proj_new();
    p.mkfile("main.spc", src.as_str());
    assert(p.compile_flags("--target=wasm", "main.spc").ok(), "the wasm32 layout, where i64 aligns to 8");
}

@test
fn invalid_vectors_and_vector_misuse_are_diagnosed() {
    let cases: [[str; 2]; 23] = [
        ["fn f(v: Simd<f64, 16>) {}", "`Simd<f64, 16>` is 1024 bits wide; the limit is 512 bits"],
        ["fn f(v: Simd<f32, 3>) {}", "`Simd<f32, 3>` needs a power-of-two lane count (2, 4, 8, 16, 32, or 64)"],
        ["fn f(v: Simd<f32, 128>) {}", "`Simd<f32, 128>` needs a power-of-two lane count"],
        ["fn f(v: Simd<usize, 4>) {}", "`usize` cannot be a SIMD lane type; use `u32` or `u64`"],
        ["fn f(v: Simd<bool, 4>) {}", "`bool` cannot be a SIMD lane type; use `Mask<N>`"],
        [
            "fn f(n: usize) { let v: Simd<f32, n> = [1.0, 2.0, 3.0, 4.0]; }",
            "const generic argument must be a constant integer",
        ],
        ["fn f(m: Mask<3>) {}", "`Mask<3>` needs a power-of-two lane count"],
        ["fn f(m: Mask<128>) {}", "`Mask<128>` needs a power-of-two lane count"],
        ["fn f() { let v: f32x4 = [1.0, 2.0, 3.0]; }", "array literal has 3 elements but the vector has 4 lanes"],
        ["fn f(v: f32x4) f32 { return v[4]; }", "index 4 is out of bounds for a vector of 4 lanes"],
        ["fn f(v: f32x4) bool { return v == v; }", "`Simd<f32, 4>` does not implement `Eq`; compare lanes"],
        ["fn f(m: mask4) { if m {} }", "a mask is not a `bool`; use `.any()` or `.all()`"],
        ["fn f(v: f32x4) [f32; 4] { return v as [f32; 4]; }", "only `std` casts"],
        ["fn f(m: mask4) bool { return m[0]; }", "a mask lane is not a place; use `get` or `set`"],
        ["fn f(v: f32x4) { let x = v.lanes; }", "has no fields"],
        ["struct S {}\nextend S as SimdElement {}", "only the SIMD lane types in `std` implement `SimdElement`"],
        ["extern \"C\" {\n    fn f(v: f32x4);\n}", "`Simd<f32, 4>` has no stable C ABI; pass `[f32; 4]`"],
        ["@c.export(\"g\")\nfn g(m: mask8) {}", "`Mask<8>` has no stable C ABI; pass `u64`"],
        ["@c.export(\"h\")\nfn h(x: i32) f32x4 {\n    return [1.0; 4];\n}", "`Simd<f32, 4>` has no stable C ABI"],
        ["extern \"C\" {\n    fn f() mask4;\n}", "`Mask<4>` has no stable C ABI"],
        ["fn f(v: f32x4) bool { return v < v; }", "`Simd<f32, 4>` does not implement `Ord`; compare lanes"],
        ["fn f(v: f32x4) f32 { return v[1.5]; }", "index must be an integer"],
        ["fn f(v: Simd<f32, 4294967300>) {}", "`Simd<f32, 4294967300>` needs a power-of-two lane count"],
    ];
    for c in cases {
        let mut src = String::from_str(c[0]);
        src.push_str("\nfn main() i32 {\n    return 0;\n}\n");
        h::expect_err_msg(c[1], src.as_str(), c[1]);
    }
    h::expect_err_msg(
        "a lane of the wrong type",
        "fn f() { let v: i32x4 = [1, 2, 3, 4.5]; }\nfn main() i32 {\n    return 0;\n}\n",
        "mismatched types",
    );
}

@test
fn instantiation_faults_name_the_instance() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn mk<const N: usize>() Simd<f32, N> {
    return Simd::<f32, N>::splat(1.0);
}
fn main() i32 {
    let v = mk::<3>();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "a generic vector with 3 lanes");
    assert(r.out_shows("`Simd<f32, 3>` needs a power-of-two lane count"), "the instance's fault");
    assert(r.out_shows("5 |     let v = mk::<3>();"), "the demanding code");
    assert(!r.out_has("simd.spc"), "one error, at the user's instance, not one per std instance it reaches");
    // Two demands of one generic: the fault names the call with its arguments.
    let p2 = cli::proj_new();
    p2.mkfile(
        "main.spc",
        M"(fn mk<const N: usize>() Simd<f32, N> {
    return Simd::<f32, N>::splat(1.0);
}
fn dbl<const N: usize>() usize {
    return sizeof(Simd<f32, {N * 2}>);
}
fn main() i32 {
    let a = mk::<4>();
    let b = mk::<8>();
    let c = mk::<6>();
    return (a[0] + b[0] + c[0]) as i32 + dbl::<9223372036854775810>() as i32;
}
)",
    );
    let r3 = p2.compile("main.spc");
    assert(r3.exit != 0 && r3.out_shows("10 |     let c = mk::<6>();"), "the call with the faulty arguments");
    assert(
        r3.out_shows("const expression {2 * N} overflows usize for N = 9223372036854775810"),
        "an overflowing lane count",
    );
    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        "fn main(args: Vector<str>) i32 {\n    let v: f32x4 = [args.len() as f32; 4];\n    return v.extract::<4>() as i32;\n}\n",
    );
    let r2 = q.compile("main.spc");
    assert(r2.exit != 0, "a lane past the vector");
    assert(r2.out_shows("extract: the lane index I must be below the lane count N"), "the extract bound");
    assert(r2.out_shows("in the instantiation where T = f32, N = 4, I = 4"), "the instance's arguments");
}

@test
fn aliases_name_the_same_types() {
    let c = h::compile(
        M"(fn f(x: Simd<f32, 4>) f32x4 {
    return x;
}
fn g(m: mask16) Mask<16> {
    return m;
}
fn main() i32 {
    let a: f32x4 = [1.0, 2.0, 3.0, 4.0];
    let b: Simd<f32, 4> = f(a);
    let c = [a, b];
    let d: [f32x4; 2] = c;
    let m: Mask<16> = g(mask16::splat(true));
    let n: mask16 = m;
    let i: u8x64 = [1; 64];
    let j: u8x16 = Simd::splat(7);
    let k = Simd::from_array([1.0f64, 2.0]);
    let l: f64x2 = k;
    return 0;
}
)",
        h::STAGE_TYPECHECK,
    );
    if !c.ok() {
        eprintln("{}", str::from_cstr(&c.first[0]));
    }
    assert(c.ok(), "alias identity");
}

// Lane accesses, bit-exact round trips and every mask operation, as constants and at run time.
const PARITY_DECLS: str = M"(const fn lane(i: usize) f32 {
    let v: f32x4 = [1.5, 2.5, 3.5, 4.5];
    return v[i];
}
const fn get_lane(i: usize) i64 {
    let v = Simd::<i64, 2>::splat(7);
    return v.get(i);
}
const fn set_lane(i: usize) u8 {
    let mut v = Simd::<u8, 16>::splat(1);
    v.set(i, 9);
    return v[15];
}
const fn store_lane(i: usize) i16 {
    let mut v = Simd::<i16, 8>::splat(1);
    v[i] = 5;
    return v[7];
}
const fn mask_get(i: usize) bool {
    return mask4::splat(true).get(i);
}
const fn mask_set(i: usize) u64 {
    let mut m = mask8::splat(false);
    m.set(i, true);
    return m.to_bits();
}
const fn f32_trip(f: f32) f32 {
    let v = Simd::<f32, 4>::from_array([f, 1.0, f, 0.0]);
    return v.to_array()[2];
}
const fn f64_trip(f: f64) f64 {
    let v = Simd::<f64, 2>::from_array([2.0, f]);
    return v.to_array()[1];
}
// The highest set bit of `p`, or 64 when `p` is zero.
const fn last_ref(p: u64) usize {
    if p == 0 {
        return 64;
    }
    return 63 - p.leading_zeros();
}
// Failures of every mask operation on pattern `p0` (`z` is zero) against u64 arithmetic.
const fn mask_one<const N: usize>(p0: u64, z: u64) u64 {
    let lanes = u64::MAX >> (64 - N) as u64;
    let p = p0 & lanes ^ z;
    let m = Mask::<N>::from_bits_truncate(p0 | ~lanes);
    let mut bad: u64 = 0;
    bad += (m.to_bits() != p) as u64;
    bad += ((!m).to_bits() != (~p & lanes)) as u64;
    bad += ((~m).to_bits() != (~p & lanes)) as u64;
    bad += (m.any() != (p != 0)) as u64;
    bad += (m.all() != (p == lanes)) as u64;
    bad += (m.none() != (p == 0)) as u64;
    bad += (m.count() as u64 != p.count_ones() as u64) as u64;
    bad += (m.first_set().unwrap_or(64) != p.trailing_zeros()) as u64;
    bad += (m.last_set().unwrap_or(64) != last_ref(p)) as u64;
    bad += (Mask::<N>::from_bits(p).unwrap_or(!m) != m) as u64;
    if N < 64 {
        bad += Mask::<N>::from_bits(p | 1u64 << N as u64).is_some() as u64;
    }
    bad += (Mask::<N>::from_array(m.to_array()) != m) as u64;
    let mut i: usize = 0;
    for b in m.to_array() {
        let bit = (p >> i as u64 & 1) != 0;
        bad += (b != bit || m.get(i) != bit) as u64;
        let mut t = m;
        t.set(i, !bit);
        bad += (t.to_bits() != (p ^ 1u64 << i as u64)) as u64;
        i += 1;
    }
    return bad;
}
// Failures of the binary operations on patterns `p` and `q`.
const fn mask_two<const N: usize>(p: u64, q: u64) u64 {
    let a = Mask::<N>::from_bits_truncate(p);
    let b = Mask::<N>::from_bits_truncate(q);
    let pa = a.to_bits();
    let pb = b.to_bits();
    let mut bad: u64 = 0;
    bad += ((a & b).to_bits() != (pa & pb)) as u64;
    bad += ((a | b).to_bits() != (pa | pb)) as u64;
    bad += ((a ^ b).to_bits() != (pa ^ pb)) as u64;
    bad += ((a == b) != (pa == pb)) as u64;
    bad += ((a != b) != (pa != pb)) as u64;
    return bad;
}
// Failures over all `2^N` patterns for `N <= 8` (all pairs for `N <= 4`), else over edge and mixed
// patterns and their pairs.
const fn mask_check<const N: usize>(z: u64) u64 {
    let mut bad: u64 = 0;
    bad += (Mask::<N>::splat(true).to_bits() != u64::MAX >> (64 - N) as u64) as u64;
    bad += (Mask::<N>::splat(false).to_bits() != 0) as u64;
    if N <= 8 {
        for p in 0..1u64 << N as u64 {
            bad += mask_one::<N>(p, z);
            if N <= 4 {
                for q in 0..1u64 << N as u64 {
                    bad += mask_two::<N>(p, q);
                }
            } else {
                bad += mask_two::<N>(p, p * 37 + 11) + mask_two::<N>(p, ~p);
            }
        }
        return bad;
    }
    let ps: [u64; 8] = [0, u64::MAX, 0x5555555555555555, 0xAAAAAAAAAAAAAAAA, 1, 1u64 << (N - 1) as u64, 0x8000000000000001, 0x0123456789ABCDEF];
    for p in ps {
        bad += mask_one::<N>(p, z);
        for q in ps {
            bad += mask_two::<N>(p, q);
        }
    }
    return bad;
}
static_assert(lane(3) == 4.5 && get_lane(1) == 7 && set_lane(15) == 9 && store_lane(7) == 5, "lane values");
static_assert(mask_get(3) && mask_set(7) == 128, "mask lanes");
static_assert(f32_trip(1.0e-45) == 1.0e-45 && f64_trip(5.0e-324) == 5.0e-324, "subnormal lanes");
static_assert(mask_check::<2>(0) + mask_check::<4>(0) + mask_check::<8>(0) == 0, "narrow masks");
static_assert(mask_check::<16>(0) + mask_check::<32>(0) + mask_check::<64>(0) == 0, "wide masks");
)";

@test
fn lanes_round_trips_and_masks_agree_as_constants_and_at_run_time() {
    let exprs: [str; 26] = [
        "lane(opq::<usize>(3))",
        "lane(opq::<usize>(4))",
        "get_lane(opq::<usize>(1))",
        "get_lane(opq::<usize>(2))",
        "set_lane(opq::<usize>(15))",
        "set_lane(opq::<usize>(16))",
        "store_lane(opq::<usize>(7))",
        "store_lane(opq::<usize>(8))",
        "mask_get(opq::<usize>(3))",
        "mask_get(opq::<usize>(4))",
        "mask_set(opq::<usize>(7))",
        "mask_set(opq::<usize>(8))",
        "f32_trip(opq::<f32>(-0.0))",
        "f32_trip(opq::<f32>(1.0e-45))",
        "f32_trip(opq::<f32>(1.0e-40))",
        "f32_trip(opq::<f32>(0.0) / opq::<f32>(0.0))",
        "f64_trip(opq::<f64>(-0.0))",
        "f64_trip(opq::<f64>(5.0e-324))",
        "f64_trip(opq::<f64>(2.0e-310))",
        "f64_trip(opq::<f64>(0.0) / opq::<f64>(0.0))",
        "mask_check::<2>(opq::<u64>(0))",
        "mask_check::<4>(opq::<u64>(0))",
        "mask_check::<8>(opq::<u64>(0))",
        "mask_check::<16>(opq::<u64>(0))",
        "mask_check::<32>(opq::<u64>(0))",
        "mask_check::<64>(opq::<u64>(0))",
    ];
    let tys: [str; 26] = [
        "f32",
        "f32",
        "i64",
        "i64",
        "u8",
        "u8",
        "i16",
        "i16",
        "bool",
        "bool",
        "u64",
        "u64",
        "f32",
        "f32",
        "f32",
        "f32",
        "f64",
        "f64",
        "f64",
        "f64",
        "u64",
        "u64",
        "u64",
        "u64",
        "u64",
        "u64",
    ];
    let d = h::const_runtime_parity(PARITY_DECLS, exprs, tys, []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "constants and run time agree");
}

// Run-time bits: a lane keeps a NaN payload, either sign of NaN, -0.0 and a subnormal.
@test
fn lanes_keep_float_bits_through_a_round_trip() {
    h::expect_exit(
        "bit-exact lanes",
        M"(@c.noinline
fn trip32(b: u32) u32 {
    let f = f32_from_bits(b);
    let v = Simd::<f32, 4>::from_array([f, 1.0, f, 0.0]);
    return f32_bits(v.to_array()[2]);
}
@c.noinline
fn trip64(b: u64) u64 {
    let f = f64_from_bits(b);
    let v = Simd::<f64, 2>::from_array([2.0, f]);
    return f64_bits(v.to_array()[1]);
}
fn main() i32 {
    let bs: [u32; 5] = [0x7FC00001, 0xFFC00123, 0x80000000, 1, 0x7F7FFFFF];
    for b in bs {
        if trip32(b) != b {
            return 1;
        }
    }
    let ds: [u64; 5] = [0x7FF8000000000ABC, 0xFFF8000000000001, 0x8000000000000000, 1, 0x000FFFFFFFFFFFFF];
    for d in ds {
        if trip64(d) != d {
            return 2;
        }
    }
    return 0;
}
)",
        0,
    );
}

@test
fn a_lane_index_past_the_lanes_traps() {
    let mut src = String::from_str(PARITY_DECLS);
    src.push_str(
        M"(@c.noinline
fn opr(x: usize) usize {
    return x;
}
fn main(args: Vector<str>) i32 {
    let k = args.at(1).parse_i64().unwrap();
    if k == 0 {
        println("{}", lane(opr(4)));
    } else if k == 1 {
        println("{}", get_lane(opr(2)));
    } else if k == 2 {
        println("{}", mask_get(opr(4)));
    } else {
        println("{}", mask_set(opr(9)));
    }
    return 0;
}
)",
    );
    let b = h::diff_build(src.as_str(), []);
    assert(b.built, "the trap program");
    let wants: [str; 4] = [
        "super-c: index out of bounds: the index is 4 but the length is 4",
        "super-c: index out of bounds: the index is 2 but the length is 2",
        "panic: Mask::get: index out of bounds",
        "panic: Mask::set: index out of bounds",
    ];
    for k in 0..4 {
        let mut arg = String::new();
        arg.push_u64(k as u64);
        let run = h::diff_run(&b, arg.as_str());
        let t = h::trap_text(run.err.as_str());
        if !t.contains(unsafe wants[k]) {
            eprintln("case {}: {}", k, run.err.as_str());
        }
        assert(run.exit != 0 && t.contains(unsafe wants[k]), "a vector's trap names the index and the lane count");
    }
    let mut csrc = String::from_str(PARITY_DECLS);
    csrc.push_str("const X: f32 = lane(6);\nfn main() i32 {\n    return 0;\n}\n");
    let c = h::diff_build(csrc.as_str(), []);
    assert(
        !c.built && c.diag.contains("index out of bounds: the index is 6 but the length is 4"),
        "the constant's trap",
    );
}

@test
fn generic_code_runs_over_three_lane_types() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn rev<T: SimdElement, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    let mut r = v;
    for i in 0..N {
        r[i] = v[N - 1 - i];
    }
    return r;
}
fn lanes<T: SimdElement, const N: usize>(v: Simd<T, N>) usize {
    return N;
}
fn main() i32 {
    let f = rev(Simd::<f32, 4>::from_array([1.0, 2.0, 3.0, 4.0]));
    let b = rev(Simd::<i8, 16>::from_array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, -14, 15]));
    let u = rev(Simd::<u64, 2>::from_array([7, 18446744073709551615]));
    println("{} {} {} {} {} {}", f[0], f[3], b[0], b[1], u[0], lanes(b));
    let t = type_info::<f32x4>();
    println("{} {} {} {} {} {}", t.name, t.kind == TypeTag::Simd, t.elem == TypeTag::Float, t.len, t.size, t.align);
    let m = type_info::<mask16>();
    println("{} {} {} {} {} {}", m.name, m.kind == TypeTag::Mask, m.elem == TypeTag::Bool, m.len, m.size, m.align);
    return 0;
}
)",
    );
    assert(p.compile("main.spc").ok(), "transpiles");
    assert(p.cc_build("").ok(), "the C compiles under the harness warnings");
    let r = p.run_bin_env("");
    assert(r.exit == 0, "runs");
    assert(
        r.out_shows("4 1 15 -14 18446744073709551615 16\nSimd true true 4 16 16\nMask true true 16 2 2\n"),
        "lanes reversed, reflection",
    );
}

@test
fn a_program_without_vectors_gets_no_vector_c() {
    h::expect_c_absent(
        "no vector types",
        "fn main() i32 {\n    let a: [u8; 4] = [1, 2, 3, 4];\n    return a[3] as i32;\n}\n",
        "__sc_v",
    );
    h::expect_c_absent(
        "no lane check",
        "fn main() i32 {\n    let a: [u8; 4] = [1, 2, 3, 4];\n    return a[3] as i32;\n}\n",
        "__sc_lane",
    );
    h::expect_c(
        "a run-time lane index checks the lanes",
        "fn at(v: f32x4, i: usize) f32 {\n    return v[i];\n}\nfn main() i32 {\n    return at([1.0, 2.0, 3.0, 4.0], 1) as i32;\n}\n",
        "__sc_lane(",
    );
}

@test
fn a_vector_constant_is_static_data() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(const V: f32x4 = [1.5, 2.5, 3.5, 4.5];
const Q: &f32 = &V[2];
struct H {
    pub v: i16x8,
    pub k: u8,
}
const HH: H = H { v: Simd::<i16, 8>::splat(-3), k: 1 };
const A: [u8x16; 2] = [Simd::<u8, 16>::splat(4), Simd::<u8, 16>::splat(5)];
const M: mask8 = Mask::<8>::from_bits_truncate(0x81);
const X: f32x4 = Simd::<f32, 4>::splat(1.5);
static mut Y: i32x4 = Simd::<i32, 4>::splat(3);
const R: f32x4 = [7.0; 4];
const L: [f32x4; 2] = [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]];
const LP: &f32 = &L[1][3];
const BIG: u64x2 = [18446744073709551615, 1];
fn pick(b: bool) f32x4 {
    let v: f32x4 = if b {
        [1.0, 2.0, 3.0, 4.0];
    } else {
        [0.0; 4];
    };
    return v;
}
fn main() i32 {
    println("{} {} {} {} {}", V[3], *Q, HH.v[7], A[1][15], M.to_bits());
    println("{} {} {} {} {} {} {}", X[3], unsafe Y[1], R[1], L[1][2], *LP, BIG[0], pick(true)[2] + pick(false)[2]);
    return 0;
}
)",
    );
    assert(p.compile("main.spc").ok(), "transpiles");
    assert(p.cc_build("").ok(), "the C compiles under the harness warnings");
    let r = p.run_bin_env("");
    assert(
        r.exit == 0 && r.out_shows("4.5 3.5 -3 5 129\n1.5 3 7 7 8 18446744073709551615 3\n"),
        "the constants' values",
    );
}

// A mask satisfies the bounds a generic body needs of it: `Option<Mask<N>>` compares through `Mask<N>: Eq`.
@test
fn a_mask_meets_interface_bounds() {
    h::expect_exit(
        "Mask<N>: Eq under a generic N",
        M"(fn none<const N: usize>(m: Mask<N>) bool {
    return Option::<Mask<N>>::Some(m) == Option::<Mask<N>>::None;
}
fn main() i32 {
    if none::<4>(mask4::splat(true)) || Option::<mask8>::Some(mask8::splat(true)) != Option::<mask8>::Some(mask8::splat(true)) {
        return 1;
    }
    return 0;
}
)",
        0,
    );
}
