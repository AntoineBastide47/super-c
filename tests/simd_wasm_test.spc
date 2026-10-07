// Vector code for wasm32 with `+simd128`: the C of a program without vectors does not depend on the
// feature; vector operations lower to the instructions of their backend entries (a wasi-sdk in
// WASI_SDK_PATH); the operations of `std::simd::wasm` match a scalar model under wasmtime (the
// vector conformance lane, `SC_SIMD_LANE=wasm`) and need their feature.
import tests::harness as h;
import tests::cli_harness as cli;

fn have_sdk() bool {
    let sdk = stdlib::getenv("WASI_SDK_PATH");
    return sdk != null && unsafe *sdk != 0 as char;
}

// The emitted tree of `src` built with `flags`: its manifest (every output file's content hash)
// and main.c.
fn emitted(src: str, flags: str) String {
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.compile_flags(flags, "main.spc");
    assert(r.ok(), flags);
    let root = str::from_cstr(p.rootp());
    let mut m = String::new();
    m.format_into("{}/build/dev/raw/__sc_manifest", root);
    let mut c = String::new();
    c.format_into("{}/build/dev/raw/main.c", root);
    let mut t = cli::read_text(m.as_str());
    t.push_str(cli::read_text(c.as_str()).as_str());
    return t;
}

@test
fn a_program_without_vectors_emits_the_same_c() {
    let src = "fn main(args: Vector<str>) i32 {\n    let v = [1, 2, 3];\n    return unsafe v[args.len() % 3] - 2;\n}\n";
    let a = emitted(src, "--target=wasm");
    assert(a.len() != 0, "a tree");
    assert(a.as_str() == emitted(src, "--target=wasm --target-feature=+simd128").as_str(), "simd128 changes nothing");
    assert(
        a.as_str() == emitted(src, "--target=wasm --target-feature=+relaxed-simd").as_str(),
        "relaxed-simd changes nothing",
    );
    let vsrc = "fn main(args: Vector<str>) i32 {\n    let v = f32x4::splat(args.len() as f32);\n    return (v + v).get(0) as i32 - 2;\n}\n";
    assert(!emitted(vsrc, "--target=wasm").contains("__sc_si_"), "no entry without the feature");
    assert(emitted(vsrc, "--target=wasm --target-feature=+simd128").contains("__sc_si_"), "an entry with it");
}

// A call of a `std::simd::wasm` operation names the feature the build lacks.
@test
fn arch_operations_need_their_feature() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::simd::wasm as w;\nfn main() i32 {\n    let a = f32x4::splat(1.0);\n    return w::relaxed_madd_f32x4(a, a, a).get(0) as i32 + w::pmin_f32x4(a, a).get(0) as i32 - 3;\n}\n",
    );
    let r = p.compile_flags("--target=wasm --target-feature=+simd128", "main.spc");
    assert(
        !r.ok() && r.out_has("`relaxed_madd_f32x4` needs `+relaxed-simd` (`--target-feature=+relaxed-simd`)"),
        "relaxed",
    );
    assert(!r.out_has("`pmin_f32x4` needs"), "simd128 is there");
    let n = p.compile_flags("--target=wasm", "main.spc");
    assert(!n.ok() && n.out_has("`pmin_f32x4` needs `+simd128` (`--target-feature=+simd128`)"), "simd128");
}

const RELEASE: [str; 3] = ["--profile=release", "--target=wasm", "--target-feature=+simd128"];

@test
fn operations_lower_to_their_instructions() {
    if !have_sdk() {
        return;
    }
    let ops: []str = RELEASE;
    h::expect_asm(
        "lane-wise add",
        "@c.noinline\nfn vadd(a: f32x4, b: f32x4) f32x4 {\n    return a + b;\n}\nfn main(args: Vector<str>) i32 {\n    let v = f32x4::splat(args.len() as f32);\n    return vadd(v, v).get(0) as i32 - 2;\n}\n",
        ops,
        "main__vadd",
        ["f32x4.add"],
        ["call", "f32.add"],
    );
    // A comparison whose one use is a choice stays in lanes: no bit mask in between.
    h::expect_asm(
        "compare and choose",
        "@c.noinline\nfn vsel(a: i8x16, b: i8x16) i8x16 {\n    let m = a.less_than(b);\n    return m.choose(a, b);\n}\nfn main(args: Vector<str>) i32 {\n    let v = i8x16::splat(args.len() as i8);\n    return vsel(v, v).get(0) as i32 - 1;\n}\n",
        ops,
        "main__vsel",
        ["i8x16.lt_s", "v128.bitselect"],
        ["call", "bitmask"],
    );
    // A mask kept as a value packs the lanes with one bitmask instruction.
    h::expect_asm(
        "compare to a mask",
        "@c.noinline\nfn veq(a: u8x16, b: u8x16) u32 {\n    return a.equal(b).count() as u32;\n}\nfn main(args: Vector<str>) i32 {\n    let v = u8x16::splat(args.len() as u8);\n    return veq(v, v) as i32 - 16;\n}\n",
        ops,
        "main__veq",
        ["i8x16.eq", "i8x16.bitmask"],
        ["call"],
    );
    // A comparison tested once by `any` or `all` reduces its lane masks: no bit mask either.
    h::expect_asm(
        "any of a comparison",
        "@c.noinline\nfn vany(a: i32x4, b: i32x4) bool {\n    return a.less_than(b).any();\n}\nfn main(args: Vector<str>) i32 {\n    let v = i32x4::splat(args.len() as i32);\n    return vany(v, v) as i32;\n}\n",
        ops,
        "main__vany",
        ["i32x4.lt_s", "v128.any_true"],
        ["call", "bitmask"],
    );
    h::expect_asm(
        "all of a comparison",
        "@c.noinline\nfn vall(a: u8x16, b: u8x16) bool {\n    let m = a.equal(b);\n    return m.all();\n}\nfn main(args: Vector<str>) i32 {\n    let v = u8x16::splat(args.len() as u8);\n    return vall(v, v) as i32 - 1;\n}\n",
        ops,
        "main__vall",
        ["i8x16.eq", "i8x16.all_true"],
        ["call", "bitmask"],
    );
    // A trapping operator checks its lanes with the overflow entry, a shift its count once: no lane
    // loop (`test`: optimized, overflow checked).
    let chk: [str; 3] = ["--profile=test", "--target=wasm", "--target-feature=+simd128"];
    h::expect_asm(
        "a checked add",
        "@c.noinline\nfn vadd(a: i32x4, b: i32x4) i32x4 {\n    return a + b;\n}\nfn main(args: Vector<str>) i32 {\n    let v = i32x4::splat(args.len() as i32);\n    return vadd(v, v).get(0) - 2;\n}\n",
        chk,
        "main__vadd",
        ["i32x4.add", "i32x4.bitmask"],
        ["extract_lane"],
    );
    h::expect_asm(
        "a checked shift",
        "@c.noinline\nfn vshl(a: i32x4, n: i32) i32x4 {\n    return a << n;\n}\nfn main(args: Vector<str>) i32 {\n    let v = i32x4::splat(args.len() as i32);\n    return vshl(v, 1).get(0) - 2;\n}\n",
        chk,
        "main__vshl",
        ["i32x4.shl"],
        ["extract_lane"],
    );
    h::expect_asm(
        "a masked load",
        "import std::simd;\n@c.noinline\nfn vlm(s: []f32, m: mask4) f32x4 {\n    return simd::load_masked(s, 0, m, f32x4::splat(0.0));\n}\nfn main(args: Vector<str>) i32 {\n    let a: [f32; 4] = [1.0, 2.0, 3.0, 4.0];\n    return vlm(a, Mask::<4>::from_bits_truncate(args.len() as u64)).get(0) as i32 - 1;\n}\n",
        ops,
        "main__vlm",
        ["v128.load32_lane"],
        [],
    );
    // A constant index list is one shuffle instruction per 16 result bytes, across chunks too.
    h::expect_asm(
        "constant shuffles",
        "import std::simd;\n@c.noinline\nfn vsh(a: f32x4, b: f32x4) f32x4 {\n    return simd::shuffle(a, b, [0, 5, 2, 7]);\n}\nfn main(args: Vector<str>) i32 {\n    let v = f32x4::splat(args.len() as f32);\n    return vsh(v, v).get(0) as i32 - 1;\n}\n",
        ops,
        "main__vsh",
        ["i8x16.shuffle"],
        ["call", "swizzle", "v128.or"],
    );
    h::expect_asm(
        "a zip across chunks",
        "import std::simd;\n@c.noinline\nfn vzip(a: u8x32, b: u8x32) u8x32 {\n    return simd::shuffle(a, b, [0, 32, 1, 33, 2, 34, 3, 35, 4, 36, 5, 37, 6, 38, 7, 39, 8, 40, 9, 41, 10, 42, 11, 43, 12, 44, 13, 45, 14, 46, 15, 47]);\n}\nfn main(args: Vector<str>) i32 {\n    let v = u8x32::splat(args.len() as u8);\n    return vzip(v, v).get(0) as i32 - 1;\n}\n",
        ops,
        "main__vzip",
        ["i8x16.shuffle"],
        ["call", "extract_lane", "load8_lane"],
    );
    h::expect_asm(
        "a tree reduction",
        "@c.noinline\nfn vsum(a: Simd<f32, 16>) f32 {\n    return reduce_add_tree(a);\n}\nfn main(args: Vector<str>) i32 {\n    return vsum(Simd::<f32, 16>::splat(args.len() as f32)) as i32 - 16;\n}\n",
        ops,
        "main__vsum",
        ["f32x4.add", "f32x4.extract_lane"],
        ["call"],
    );
}

// Every operation of `std::simd::wasm` against its scalar model, on lanes chosen at run time; a
// relaxed operation's lane may be either result the WebAssembly specification allows.
const ARCH_SRC: str = M"(import std::simd::wasm as w;
fn sel(c: bool, x: f64, y: f64) f64 {
    if c {
        return x;
    }
    return y;
}
// The same value, any NaN as one and the zeros apart.
fn same(x: f64, y: f64) bool {
    return x != x && y != y || x == y && x.is_sign_negative() == y.is_sign_negative();
}
fn fused(r: f64, x: f64, y: f64, z: f64, n: bool) bool {
    let p = if n {
        -x;
    } else {
        x;
    };
    return same(r, p.mul_add(y, z)) || same(r, (p * y) as f64 + z);
}
fn main(args: Vector<str>) i32 {
    let k = args.len() as i32;
    let mut bad = 0;
    let nan = 0.0f64 / 0.0f64 * k as f64;
    // pmin and pmax over NaNs and both zeros; the relaxed operations over numbers.
    let pa: [f64; 4] = [1.5 * k as f64, nan, -0.0, 0.0];
    let pb: [f64; 4] = [0.75, 2.0, 0.0, -0.0];
    let fa: [f32; 4] = [1.5 * k as f32, -2.0, 3.25, -0.5];
    let fb: [f32; 4] = [0.75, -2.5, 7.0, 0.25 * k as f32];
    let fc: [f32; 4] = [1.0e-7, 3.0, -1.0, 0.125];
    let mut qa: [f32; 4] = [0.0; 4];
    let mut qb: [f32; 4] = [0.0; 4];
    for i in 0usize..4 {
        unsafe { qa[i] = pa[i] as f32; }
        unsafe { qb[i] = pb[i] as f32; }
    }
    let a = f32x4::from_array(fa);
    let b = f32x4::from_array(fb);
    let c = f32x4::from_array(fc);
    let pmin = w::pmin_f32x4(f32x4::from_array(qa), f32x4::from_array(qb));
    let pmax = w::pmax_f32x4(f32x4::from_array(qa), f32x4::from_array(qb));
    let madd = w::relaxed_madd_f32x4(a, b, c);
    let nmadd = w::relaxed_nmadd_f32x4(a, b, c);
    let rmin = w::relaxed_min_f32x4(a, b);
    let rmax = w::relaxed_max_f32x4(a, b);
    for i in 0usize..4 {
        let (x, y, z) = unsafe (fa[i], fb[i], fc[i]);
        let (u, v) = unsafe (qa[i] as f64, qb[i] as f64);
        bad += (!same(pmin.get(i) as f64, sel(v < u, v, u))) as i32;
        bad += (!same(pmax.get(i) as f64, sel(u < v, v, u))) as i32;
        let (mf, nf) = (madd.get(i) as f64, nmadd.get(i) as f64);
        bad += (!same(mf, x.mul_add(y, z) as f64) && !same(mf, (x * y + z) as f64)) as i32;
        bad += (!same(nf, (-x).mul_add(y, z) as f64) && !same(nf, (-(x * y) + z) as f64)) as i32;
        bad += (!same(rmin.get(i) as f64, x.min(y) as f64)) as i32;
        bad += (!same(rmax.get(i) as f64, x.max(y) as f64)) as i32;
    }
    let d0 = f64x2::from_array([pa[0], pa[1]]);
    let d1 = f64x2::from_array([pb[0], pb[1]]);
    let e0 = f64x2::from_array([pa[2], pa[3]]);
    let e1 = f64x2::from_array([pb[2], pb[3]]);
    let r = [w::pmin_f64x2(d0, d1), w::pmin_f64x2(e0, e1), w::pmax_f64x2(d0, d1), w::pmax_f64x2(e0, e1)];
    for i in 0usize..4 {
        let (u, v) = unsafe (pa[i], pb[i]);
        bad += (!same(unsafe r[i / 2].get(i % 2), sel(v < u, v, u))) as i32;
        bad += (!same(unsafe r[2 + i / 2].get(i % 2), sel(u < v, v, u))) as i32;
    }
    let ga = f64x2::from_array([1.5 * k as f64, -2.25]);
    let gb = f64x2::from_array([3.0, 0.5]);
    let gc = f64x2::from_array([1.0e-17, -4.0]);
    let gm = w::relaxed_madd_f64x2(ga, gb, gc);
    let gn = w::relaxed_nmadd_f64x2(ga, gb, gc);
    let gl = w::relaxed_min_f64x2(ga, gb);
    let gh = w::relaxed_max_f64x2(ga, gb);
    for i in 0usize..2 {
        let (x, y, z) = (ga.get(i), gb.get(i), gc.get(i));
        bad += (!fused(gm.get(i), x, y, z, false) || !fused(gn.get(i), x, y, z, true)) as i32;
        bad += (!same(gl.get(i), x.min(y)) || !same(gh.get(i), x.max(y))) as i32;
    }
    // A lane past the i32 range or NaN converts to the saturated value or to i32::MIN.
    let tin: [f32; 4] = [1234.75 * k as f32, -3.0e9, 3.0e9, nan as f32];
    let tsat: [i32; 4] = [1234, -2147483648, 2147483647, 0];
    let rt = w::relaxed_trunc(f32x4::from_array(tin));
    for i in 0usize..4 {
        bad += (rt.get(i) != unsafe tsat[i] && (i == 0 || rt.get(i) != -2147483648)) as i32;
    }
    let ia: [i16; 8] = [k as i16 * 300, -32768, 32767, -5, 12345, -32768, 7, 0];
    let ib: [i16; 8] = [-200, -32768, 32767, 9, 23456, 1, -7, 32767];
    let q = w::q15mulr_sat(i16x8::from_array(ia), i16x8::from_array(ib));
    let d = w::dot_i16x8(i16x8::from_array(ia), i16x8::from_array(ib));
    for i in 0usize..8 {
        let (x, y): (i32, i32) = unsafe (ia[i], ib[i]);
        bad += (q.get(i) as i32 != ((x * y + 0x4000) >> 15).clamp(-32768, 32767)) as i32;
    }
    for i in 0usize..4 {
        let (x0, y0, x1, y1): (i32, i32, i32, i32) = unsafe (ia[2 * i], ib[2 * i], ia[2 * i + 1], ib[2 * i + 1]);
        bad += (d.get(i) != x0.wrapping_mul(y0).wrapping_add(x1.wrapping_mul(y1))) as i32;
    }
    let mut sa: [i8; 16] = [0; 16];
    let mut sb: [i8; 16] = [0; 16];
    let mut idx: [u8; 16] = [0; 16];
    for i in 0usize..16 {
        let (x, y): (i32, i32) = (i as i32 * 37 * k % 256 - 128, i as i32 * 11 % 128);
        unsafe sa[i] = x as i8;
        unsafe sb[i] = y as i8;
        unsafe idx[i] = ((i * 7 + k as usize) % 16) as u8;
    }
    let acc = i32x4::from_array([k, -1, 1 << 20, 0]);
    let dot = w::relaxed_dot_i8x16_i7x16_add(i8x16::from_array(sa), i8x16::from_array(sb), acc);
    for i in 0usize..4 {
        let mut r = acc.get(i);
        for j in 0usize..4 {
            r += unsafe (sa[4 * i + j] as i32 * sb[4 * i + j] as i32);
        }
        bad += (dot.get(i) != r) as i32;
    }
    let src = u8x16::from_array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
    let sw = w::relaxed_swizzle(src, u8x16::from_array(idx));
    for i in 0usize..16 {
        bad += (sw.get(i) != unsafe idx[i] + 1) as i32;
    }
    println("{}", bad);
    return bad;
}
)";

@test
fn arch_operations_match_their_scalar_model() {
    if !h::simd_lane() {
        return;
    }
    let b = h::diff_build(ARCH_SRC, ["--target=wasm", "--target-feature=+relaxed-simd"]);
    if !b.built {
        eprintln("{}", b.diag.as_str());
    }
    assert(b.built, "the program builds");
    let r = h::diff_run(&b, "");
    if r.exit != 0 {
        eprintln("exit {}: {}{}", r.exit, r.out.as_str(), r.err.as_str());
    }
    assert(r.exit == 0 && r.out.as_str() == "0\n", "every lane matches");
}

// A load or a store in chunks reads every operand before it writes a chunk: the pointer may overlap
// the stored vector or the loaded one's place (in the lane: with and without the feature).
@test
fn split_memory_operations_read_before_they_write() {
    if !h::simd_lane() {
        return;
    }
    h::expect_same_output(
        "overlapping split store and load",
        "import std::simd;\nfn main(args: Vector<str>) i32 {\n    let k = args.len();\n    let mut big = u8x64::splat(0);\n    for i in 0usize..64 {\n        big.set(i, i as u8);\n    }\n    let base = &mut big as *mut u8x64 as *mut u8;\n    let pv = base as *mut u8x32;\n    unsafe simd::store_unaligned::<u8, 32>(base + 8 * k, *pv);\n    unsafe {\n        *pv = simd::load_unaligned::<u8, 32>(base + 20 * k);\n    }\n    for i in 0usize..64 {\n        print(\"{} \", big.get(i));\n    }\n    println(\"\");\n    return 0;\n}\n",
        [],
        ["--target-feature=-simd128"],
    );
}
