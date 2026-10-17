// std::simd::matrix: every kernel's product equals the fused multiply-add chain over p from +0.0, bit for
// bit (NaNs as one value), and the i8 product the i32 sum modulo 2^32, over edge shapes and special
// values; the run with the detected features masked (`SC_CPU_OFF`, the portable kernel) prints what the
// run with them prints (on an SME machine, the SME kernels'); and a slice whose length is not its
// matrix's element count panics.
import tests::harness as h;
import tests::cli_harness as cli;

const PRODUCTS: str<'static> = "import std::simd::matrix;\nimport std::float as fl;\n\nfn next(r: &mut u64) u64 {\n    *r ^= *r << 13;\n    *r ^= *r >> 7;\n    *r ^= *r << 17;\n    return *r;\n}\n\n// Mixed magnitudes and signs, and zeros of both signs, subnormals, infinities and NaNs.\nfn val(r: &mut u64) f64 {\n    let x = next(r);\n    let s = x % 41;\n    if s == 0 {\n        return 0.0;\n    }\n    if s == 1 {\n        return -0.0;\n    }\n    if s == 2 {\n        return 1.0 / 0.0;\n    }\n    if s == 3 {\n        return 0.0 / 0.0;\n    }\n    if s == 4 {\n        return fl::f64_from_bits(x >> 13);\n    }\n    return ((x >> 11) as f64 / 9007199254740992.0 - 0.5) * fl::f64_from_bits(((x >> 3) % 40 + 1003) << 52);\n}\n\nfn mix(h: u64, v: u64) u64 {\n    return (h ^ v).wrapping_mul(0x100000001b3);\n}\n\nfn main() i32 {\n    let mut r: u64 = 0x9E3779B97F4A7C15;\n    let shapes: [[usize; 3]; 10] = [[1, 1, 1], [3, 5, 7], [16, 16, 16], [33, 17, 65], [64, 64, 64], [31, 100, 47], [0, 4, 4], [5, 0, 9], [129, 3, 130], [17, 129, 33]];\n    let mut bad: u64 = 0;\n    let mut hash: u64 = 0xcbf29ce484222325;\n    for s in shapes {\n        let (m, k, n) = (s[0], s[1], s[2]);\n        let mut a = Vector::<f64>::new();\n        let mut b = Vector::<f64>::new();\n        let mut a32 = Vector::<f32>::new();\n        let mut b32 = Vector::<f32>::new();\n        for _ in 0..m * k {\n            let v = val(&mut r);\n            a.push(v);\n            a32.push(v as f32);\n        }\n        for _ in 0..k * n {\n            let v = val(&mut r);\n            b.push(v);\n            b32.push(v as f32);\n        }\n        let mut c = Vector::<f64>::new();\n        let mut c32 = Vector::<f32>::new();\n        for _ in 0..m * n {\n            c.push(9.0);\n            c32.push(9.0);\n        }\n        let mut ai = Vector::<i8>::new();\n        let mut bi = Vector::<i8>::new();\n        let mut ci = Vector::<i32>::new();\n        for _ in 0..m * k {\n            ai.push(next(&mut r) as i8);\n        }\n        for _ in 0..k * n {\n            bi.push(next(&mut r) as i8);\n        }\n        for _ in 0..m * n {\n            ci.push(9);\n        }\n        matrix::mul_i8(ci.index_range_mut(0..m * n), ai[0..m * k], bi[0..k * n], m, k, n);\n        matrix::mul_f64(c.index_range_mut(0..m * n), a[0..m * k], b[0..k * n], m, k, n);\n        matrix::mul_f32(c32.index_range_mut(0..m * n), a32[0..m * k], b32[0..k * n], m, k, n);\n        for i in 0..m {\n            for j in 0..n {\n                let mut s64: f64 = 0.0;\n                let mut s32: f32 = 0.0;\n                let mut si: i32 = 0;\n                for p in 0..k {\n                    s64 = a[i * k + p].mul_add(b[p * n + j], s64);\n                    s32 = a32[i * k + p].mul_add(b32[p * n + j], s32);\n                    si = si.wrapping_add((ai[i * k + p] as i32) * (bi[p * n + j] as i32));\n                }\n                let (x, y) = (c[i * n + j], c32[i * n + j]);\n                let ok64 = x.is_nan() && s64.is_nan() || fl::f64_bits(x) == fl::f64_bits(s64);\n                let ok32 = y.is_nan() && s32.is_nan() || fl::f32_bits(y) == fl::f32_bits(s32);\n                if !ok64 || !ok32 || ci[i * n + j] != si {\n                    bad += 1;\n                }\n                hash = mix(hash, if x.is_nan() {\n                    1;\n                } else {\n                    fl::f64_bits(x);\n                });\n                hash = mix(hash, ci[i * n + j] as u32 as u64);\n                hash = mix(hash, if y.is_nan() {\n                    1;\n                } else {\n                    fl::f32_bits(y);\n                });\n            }\n        }\n    }\n    println(\"mismatches {} hash {}\", bad, hash);\n    return bad as i32;\n}\n";

// Build PRODUCTS once and run it with `env` (NAME=VALUE pairs): its output, or "fail".
fn products_run(p: &cli::Proj, env: str) String {
    let root = p.dir();
    let mut cmd = format("\"{}/app\"", root);
    let mut out = format("{}/.out", root);
    let mut err = format("{}/.err", root);
    let rc = cli::run_with(cmd.cstr(), null, out.cstr(), err.cstr(), env);
    if rc != 0 {
        eprintln("[{}]: exit {}: {}", env, rc, cli::read_text(err.as_str()).as_str());
        return String::from_str("fail");
    }
    return cli::read_text(out.as_str());
}

@test
fn every_kernel_gives_the_fma_chain() {
    let p = cli::proj_new();
    p.mkfile("main.spc", PRODUCTS);
    let root = p.dir();
    let b = p.run_raw(format("build \"{}/main.spc\" -o \"{}/app\"", root, root).as_str());
    if !b.ok() {
        b.show();
    }
    assert(b.ok(), "the program builds");
    let with = products_run(&p, "");
    let without = products_run(&p, "SC_CPU_OFF=0xFFFFFFFFFFFFFFFF");
    assert(with.starts_with("mismatches 0 "), "the products equal the fused multiply-add chain");
    assert(with == without, "the machine's kernel and the portable one agree");
}

@test
fn a_slice_of_another_length_panics() {
    h::expect_run(
        "a of another length",
        "import std::simd::matrix;\nfn main() i32 {\n    let a: [f32; 5] = [1.0; 5];\n    let b: [f32; 6] = [1.0; 6];\n    let mut c: [f32; 4] = [0.0; 4];\n    matrix::mul_f32(c, a, b, 2, 3, 2);\n    return 0;\n}\n",
        "",
        "matrix::mul_f32: a slice's length is not its matrix's element count",
    );
}
