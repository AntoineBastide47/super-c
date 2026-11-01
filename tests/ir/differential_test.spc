// The differential oracles of tests/harness.spc: one program under two option lists, constant against
// run-time evaluation, and instruction checks on one function's assembly.
import tests::harness as h;
import tests::cli_harness as cli;
import stdlib;

// The run-time identity the oracles' programs use for inputs the compiler must not fold.
const OPR: str = "static mut SINK: usize = 0;\n@noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\n";

@test
fn same_output_agrees_across_profiles() {
    let mut src = String::from_str(OPR);
    src.push_str(
        "fn main() i32 {\n    let a = opr::<i32>(i32::MAX);\n    println(\"{}\", a.wrapping_add(opr::<i32>(1)));\n    println(\"{}\", a / opr::<i32>(0));\n    return 0;\n}\n",
    );
    h::expect_same_output("a division trap and a wrapping add", &src, ["--profile=debug"], ["--profile=release"]);
}

// Each libm call runs as written under every profile: release's optimizer neither merges `sin(x)` and
// `cos(x)` into one `sincos` nor folds or rewrites a transcendental call, so both profiles print one
// count (and its f32 twin).
@test
fn libm_calls_agree_across_profiles() {
    h::expect_same_output(
        "sin and cos of one value, f64 and f32",
        "fn main() i32 {\n    let mut count = 0;\n    let mut x: f64 = 0.001;\n    let mut y: f32 = 0.001;\n    for _ in 0..200000 {\n        let s = x.sin();\n        let c = x.cos();\n        if s * s + c * c != 1.0 { count += 1; }\n        let sf = y.sin();\n        let cf = y.cos();\n        if sf * sf + cf * cf != 1.0 { count += 1; }\n        if 2.0f64.powf(x) != x.exp2() { count += 1; }\n        x = x * 1.0001 + 0.0001;\n        y = y * 1.0001 + 0.0001;\n    }\n    println(\"{}\", count);\n    return 0;\n}\n",
        ["--profile=debug"],
        ["--profile=release"],
    );
}

@test
fn same_output_reports_profile_dependent_overflow() {
    let mut src = String::from_str(OPR);
    src.push_str("fn main() i32 {\n    println(\"{}\", opr::<i32>(i32::MAX) + opr::<i32>(1));\n    return 0;\n}\n");
    let d = h::same_output(&src, ["--profile=debug"], ["--profile=release"], [""]);
    assert(d.contains("differs"), "an overflow traps under debug and wraps under release");
    assert(d.contains("super-c: attempt to add with overflow"), "the trap text is part of the report");
    assert(d.contains("-2147483648"), "the release stdout is part of the report");
}

@test
fn same_output_with_bounds_checks_forced() {
    let mut src = String::from_str(OPR);
    src.push_str(
        "fn main() i32 {\n    let mut v = Vector::<i64>::new();\n    for k in 0..opr::<usize>(9) {\n        v.push(k as i64);\n    }\n    let mut acc: i64 = 0;\n    for i in 0..v.len() {\n        acc += v[i];\n    }\n    println(\"{}\", acc);\n    let mut i: usize = 0;\n    while i < 13 {\n        acc += v[i];\n        i += 4;\n    }\n    println(\"{}\", acc);\n    return 0;\n}\n",
    );
    let b = h::diff_build(&src, []);
    let z = h::diff_build(&src, ["SC_BCE=0"]);
    if !b.built || !z.built {
        eprintln("{}{}", b.diag.as_str(), z.diag.as_str());
    }
    assert(b.built, "the program builds with BCE");
    assert(z.built, "the program builds without BCE");
    let d = h::same_runs(&b, &z, [""]);
    assert(d.len() == 0, d.as_str());
    // The strided loop reads v[12] of 9: the run prints the full loop's sum, then traps.
    let r = h::diff_run(&b, "");
    assert(r.out.as_str() == "36\n", "the full loop's sum prints");
    // A Vector's element check is its `index` method's guard: std's panic names the type.
    assert(r.err.contains("panic: Vector<") && r.err.contains("[i]: index out of bounds"), "the strided loop traps");
}

// An add, a wrapping add, a signed shift, a float division, a saturating cast and a const fn call: one
// program, one build.
@test
fn parity_values() {
    let d = h::const_runtime_parity(
        "const fn sq(x: i64) i64 {\n    return x * x;\n}\n",
        [
            "opq::<i32>(40) + opq::<i32>(2)",
            "opq::<u8>(200).wrapping_add(opq::<u8>(100))",
            "opq::<i64>(-1) << opq::<i64>(63)",
            "opq::<f64>(1.0) / opq::<f64>(3.0)",
            "opq::<f64>(-1e300) as i32",
            "sq(opq::<i64>(-7))",
        ],
        ["i32", "u8", "i64", "f64", "i32", "i64"],
        [],
    );
    assert(d.len() == 0, d.as_str());
}

// Float literals round once, at their context's type: f32 arguments and operands, f64 arguments,
// subnormal and tie-breaking hex forms, `_` separators, suffixes; an integer converts to f32 directly.
@test
fn parity_float_literals() {
    let d = h::const_runtime_parity(
        "const A: [f64; 2] = [0.1, 0x0.0000000000001p-1022];\n",
        [
            "opq::<f32>(1.0) % opq::<f32>(3.97878633e-16)",
            "opq::<f32>(8.0472104771567678e-43) * opq::<f32>(3.4028234663852886e38)",
            "opq::<f64>(0.1)",
            "opq::<f64>(0x0.0000000000001p-1022)",
            "opq::<f32>(0x1.000001p0)",
            "opq::<f32>(0x1.000003p0)",
            "opq::<f64>(1_000.25e1_0)",
            "1.5f32 * opq::<f32>(3.0)",
            "opq::<u64>(9007199791611905) as f32",
            "opq::<f64>(A[0]) + A[1]",
        ],
        ["f32", "f32", "f64", "f64", "f32", "f32", "f64", "f32", "f32", "f64"],
        [],
    );
    assert(d.len() == 0, d.as_str());
}

// An f32 libm method folds through the f32 function the program calls: each input's f64 result
// narrowed to f32 is one step off the f32 function's on the macOS libm.
@test
fn parity_f32_libm() {
    f32_libm_parity([]);
}

// A wasm32 build folds through the function it links, `std::rt::libm`, not the compiler's own libm, whose
// results differ from it by a step for most of these inputs. The lanes check it on their own.
@test
fn parity_f32_libm_on_wasm() {
    let sdk = stdlib::getenv("WASI_SDK_PATH");
    if sdk == null || unsafe *sdk == 0 as char || h::simd_lane() || cli::on_wasm() {
        return;
    }
    f32_libm_parity(["--target=wasm"]);
}

// `parity_f32_libm` built with `opts`.
fn f32_libm_parity(opts: []str) {
    let d = h::const_runtime_parity(
        "",
        [
            "opq::<f32>(-1.0).acos()",
            "opq::<f32>(0.00177229999).acos()",
            "opq::<f32>(0.100591898).asin()",
            "opq::<f32>(0.00680430001).atan()",
            "opq::<f32>(0.0300069991).sin()",
            "opq::<f32>(0.0587967001).cos()",
            "opq::<f32>(0.0403188989).tan()",
            "opq::<f32>(0.0912678987).sinh()",
            "opq::<f32>(0.448358595).cosh()",
            "opq::<f32>(0.00680430001).tanh()",
            "opq::<f32>(0.0504420996).asinh()",
            "opq::<f32>(1.03554964).acosh()",
            "opq::<f32>(0.0360416993).atanh()",
            "opq::<f32>(0.000654899981).exp()",
            "opq::<f32>(0.00103229994).exp2()",
            "opq::<f32>(0.0023236).exp_m1()",
            "opq::<f32>(0.170695797).ln()",
            "opq::<f32>(0.985698521).log2()",
            "opq::<f32>(0.0288637001).log10()",
            "opq::<f32>(0.000636400015).ln_1p()",
            "opq::<f32>(2.0).cbrt()",
            "opq::<f32>(1.00061619).powf(opq::<f32>(0.503365397))",
            "opq::<f32>(1.00003386).atan2(opq::<f32>(0.500184596))",
            "opq::<f32>(3.0).hypot(opq::<f32>(4.5))",
            "opq::<f32>(1.1).mul_add(opq::<f32>(1.3), opq::<f32>(-1.43))",
        ],
        [
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
            "f32",
        ],
        opts,
    );
    assert(d.len() == 0, d.as_str());
}

// An unsuffixed float literal in an f64 context keeps double precision in every context: an argument,
// an array literal, a repeat, a struct field, a nested array field, a negation. A literal rounded to
// a C `float` on its way would change the bits.
@test
fn f64_literal_contexts_keep_double_precision() {
    h::expect_exit(
        "f64 literal contexts",
        "fn bits(x: f64) u64 {\n    return unsafe *((&x) as *const f64 as *const u64);\n}\nfn g(x: f64) f64 {\n    return x;\n}\nstruct S { pub a: f64, pub b: [f64; 2] }\nfn main() i32 {\n    let w: [f64; 2] = [0.1, 0.2];\n    let r: [f64; 3] = [0.3; 3];\n    let s = S { a: 0.4, b: [0.5, 0.6] };\n    let ok = bits(g(0.7)) == 0x3FE6666666666666 && bits(w[0]) == 0x3FB999999999999A && bits(w[1]) == 0x3FC999999999999A && bits(r[2]) == 0x3FD3333333333333 && bits(s.a) == 0x3FD999999999999A && bits(s.b[0]) == 0x3FE0000000000000 && bits(s.b[1]) == 0x3FE3333333333333 && bits(-0.8) == 0xBFE999999999999A;\n    return if ok { 0 } else { 1 };\n}\n",
        0,
    );
}

@test
fn parity_traps() {
    let d = h::const_runtime_parity(
        "",
        [
            "opq::<i32>(i32::MAX) + opq::<i32>(1)",
            "-opq::<i8>(i8::MIN)",
            "opq::<u16>(7) / opq::<u16>(0)",
            "opq::<i64>(i64::MIN) % opq::<i64>(-1)",
            "opq::<u32>(1) << opq::<u32>(32)",
        ],
        ["i32", "i8", "u16", "i64", "u32"],
        [],
    );
    assert(d.len() == 0, d.as_str());
}

// Several cases in one program: the trapping constants leave the program, the rest keep their values.
@test
fn parity_mixed_cases() {
    let d = h::const_runtime_parity(
        "",
        [
            "opq::<i16>(i16::MIN) - opq::<i16>(1)",
            "opq::<u64>(u64::MAX) / opq::<u64>(3)",
            "opq::<i32>(-9) >> opq::<i32>(-1)",
            "opq::<f32>(0.1) * opq::<f32>(3.0)",
        ],
        ["i16", "u64", "i32", "f32"],
        [],
    );
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "four cases agree");
}

// A run time without overflow checks is the difference the oracle exists to find: the constant traps,
// the run time wraps. The release profile wraps (no `overflow-checks`, `opt-level` 3).
@test
fn parity_reports_missing_runtime_check() {
    let d = h::const_runtime_parity(
        "",
        ["opq::<i32>(i32::MAX) * opq::<i32>(2)", "opq::<i32>(5) * opq::<i32>(2)"],
        ["i32", "i32"],
        ["--profile=release"],
    );
    assert(d.contains("case 0"), "the overflowing case is reported");
    assert(d.contains("const:    trap: arithmetic overflow"), "the constant traps");
    assert(d.contains("run time: value -2"), "the run time wraps");
    assert(!d.contains("case 1"), "the agreeing case is not reported");
}

@test
fn parity_reports_unbuildable_program() {
    let d = h::const_runtime_parity("", ["missing_name"], ["i32"], []);
    assert(d.contains("does not build"), "an error that is no constant trap is a failure");
}

@test
fn asm_mnemonics_skip_labels_directives_and_registers() {
    let macho = "_f:                                     ; @f\n\t.cfi_startproc\n; %bb.0:\n\tmul\tx0, x1, x0\n\tret\n\t.cfi_endproc\n_g:\n\tbl\t_f\n";
    let names = h::asm_mnemonics(macho, "f");
    assert_eq(names.len(), 2);
    assert(names.at(0).eq_str("mul"), "the first instruction");
    assert(names.at(1).eq_str("ret"), "the body ends at .cfi_endproc");
    let elf = "f:\n.LBB0_1:\n\timulq\t%rsi, %rdi\n\tmovq\t%rdi, %rax\n\tretq\n.Lfunc_end0:\n";
    let e = h::asm_mnemonics(elf, "f");
    assert_eq(e.len(), 3);
    assert(e.at(0).eq_str("imulq"), "a local label is no instruction");
    let wasm = "\t.functype\tf (i64, i64) -> (i64)\nf:\n\tlocal.get\t1\n\ti64.mul\n\tend_function\n";
    let w = h::asm_mnemonics(wasm, "f");
    assert_eq(w.len(), 2);
    assert(w.at(1).eq_str("i64.mul"), "wasm instruction names keep their type prefix");
    assert_eq(h::asm_mnemonics(elf, "fg").len(), 0);
}

const MULW: str = "@noinline\nfn mulw(a: u64, b: u64) u64 {\n    return a.wrapping_mul(b);\n}\nfn main(args: Vector<str>) i32 {\n    return mulw(args.len() as u64, 3) as i32;\n}\n";

@test
fn asm_host_function() {
    if !cli::has_cc() {
        return; // it reads the C compiler's assembly
    }
    // One build serves the three checks (`asm_check` is `diff_build`, `asm_text` and `asm_match`).
    let b = h::diff_build(MULW, ["--profile=release", "--emit-c"]);
    assert(b.built, b.diag.as_str());
    let mut code = String::new();
    let t = h::asm_text(&b, ["--profile=release"], "mulw", &mut code);
    assert(t.len() == 0, t.as_str());
    // The lane builds every program for wasm32: a host instruction check does not apply.
    if !h::simd_lane() {
        let m = if ARCH == Arch::AArch64 {
            h::asm_match(&code, "mulw", ["mul"], ["bl", "x0"])
        } else {
            h::asm_match(&code, "mulw", ["imul"], ["call", "rax"])
        };
        assert(m.len() == 0, m.as_str());
    }
    let d = h::asm_match(&code, "mulw", ["div"], []);
    assert(d.contains("contains 'div'"), "a missing instruction is reported");
    let mut none = String::new();
    let n = h::asm_text(&b, ["--profile=release"], "no_such_fn", &mut none);
    assert(n.contains("no translation unit defines"), "an unknown function is reported");
}

// The other Mach-O architecture through clang's `-arch` (the tree's `__cflags`): the macOS SDK serves both.
@test
fn asm_cross_architecture() {
    if PLATFORM != Platform::MacOS || !cli::has_cc() {
        return;
    }
    if ARCH == Arch::AArch64 {
        h::expect_asm("x86_64 multiply", MULW, ["--profile=release", "--arch=x86_64"], "mulw", ["imul"], ["call"]);
    } else {
        h::expect_asm("aarch64 multiply", MULW, ["--profile=release", "--arch=aarch64"], "mulw", ["mul"], ["bl"]);
    }
}

// wasm32 needs a wasi sysroot: the wasm lane names one in WASI_SDK_PATH.
@test
fn asm_wasm32() {
    let sdk = stdlib::getenv("WASI_SDK_PATH");
    if sdk == null || unsafe *sdk == 0 as char || !cli::has_cc() {
        return;
    }
    h::expect_asm("wasm32 multiply", MULW, ["--profile=release", "--target=wasm"], "mulw", ["i64.mul"], ["call"]);
}

// Loops of `abs`, `floor`, `ceil`, `trunc` and `mul_add`, which the loop vectorizer widens to vector
// operations where the target computes them in registers: each lane as the C function gives it, on values
// that round both ways, halves, both zeros, the infinities and a NaN, past a vector and with a remainder.
const FLOAT_LOOPS: str = M"(@noinline fn fl(d: []mut f32, s: []f32) { for i in 0..s.len() { d[i] = s[i].floor(); } }
@noinline fn ce(d: []mut f32, s: []f32) { for i in 0..s.len() { d[i] = s[i].ceil(); } }
@noinline fn tr(d: []mut f32, s: []f32) { for i in 0..s.len() { d[i] = s[i].trunc(); } }
@noinline fn ab(d: []mut f32, s: []f32) { for i in 0..s.len() { d[i] = s[i].abs(); } }
@noinline fn ma(d: []mut f32, s: []f32, k: f32) { for i in 0..s.len() { d[i] = s[i].mul_add(k, s[i]); } }
@noinline fn fl64(d: []mut f64, s: []f64) { for i in 0..s.len() { d[i] = s[i].floor(); } }
@noinline fn ma64(d: []mut f64, s: []f64, k: f64) { for i in 0..s.len() { d[i] = s[i].mul_add(k, s[i]); } }
fn show(name: str, d: []f32) { for i in 0..d.len() { println("{} {} {}", name, i, d[i].to_bits()); } }
fn main() i32 {
    let base: [f32; 12] = [0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.75, -2.75, 1.0e30, -3.0e-30, 1.0 / 0.0, -1.0 / 0.0];
    let mut s = Vector::<f32>::new();
    let mut s64 = Vector::<f64>::new();
    let mut d = Vector::<f32>::new();
    let mut d64 = Vector::<f64>::new();
    for i in 0..37usize {
        let x = if i == 36 { 0.0 / 0.0 } else { base[i % 12] * (1 + i / 12) as f32 };
        s.push(x);
        s64.push(x as f64 + 0.25);
        d.push(0.0);
        d64.push(0.0);
    }
    fl(&mut d, &s);
    show("floor", &d);
    ce(&mut d, &s);
    show("ceil", &d);
    tr(&mut d, &s);
    show("trunc", &d);
    ab(&mut d, &s);
    show("abs", &d);
    ma(&mut d, &s, 3.0e-8);
    show("mul_add", &d);
    fl64(&mut d64, &s64);
    for i in 0..37usize { println("floor64 {} {}", i, d64[i].to_bits()); }
    ma64(&mut d64, &s64, 1.0e-17);
    for i in 0..37usize { println("mul_add64 {} {}", i, d64[i].to_bits()); }
    return 0;
}
)";

@test
fn float_function_loops_match_their_scalar_calls() {
    h::expect_same_output("float function loops", FLOAT_LOOPS, ["--profile=debug"], ["--profile=release"]);
}

// Conditional sums and counts, which the loop vectorizer widens as reductions of a select (`cond_step`):
// wrapping sums of signed and unsigned elements, a sum of the other side, and a count, past a vector and
// with a remainder.
const COND_SUMS: str = M"(@noinline fn pos(s: []i32) i32 { let mut t: i32 = 0; for i in 0..s.len() { if s[i] > 0 { t = t.wrapping_add(s[i]); } } return t; }
@noinline fn neg(s: []i32) i32 { let mut t: i32 = 0; for i in 0..s.len() { if s[i] > 0 { } else { t = t.wrapping_sub(s[i]); } } return t; }
@noinline fn big(s: []u32, k: u32) u32 { let mut t: u32 = 0; for i in 0..s.len() { if s[i] >= k { t = t.wrapping_add(s[i]); } } return t; }
@noinline fn odd(s: []u32) u32 { let mut t: u32 = 0; for i in 0..s.len() { if (s[i] & 1) != 0 { t ^= s[i]; } } return t; }
fn main() i32 {
    let mut s = Vector::<i32>::new();
    let mut u = Vector::<u32>::new();
    let mut x: u32 = 12345;
    for _ in 0..77 {
        x = x.wrapping_mul(1103515245).wrapping_add(12345);
        s.push(x as i32);
        u.push(x >> 3);
    }
    for n in [0usize, 3, 16, 31, 77] {
        println("{} {} {} {} {}", n, pos(s[0..n]), neg(s[0..n]), big(u[0..n], 0x08000000), odd(u[0..n]));
    }
    return 0;
}
)";

@test
fn conditional_sums_match_across_profiles() {
    h::expect_same_output("conditional sums", COND_SUMS, ["--profile=debug"], ["--profile=release"]);
}

// Loops whose test is `i + c < n` (`opt::offset_test` makes it `i < n - min(n, c)`, then a counted loop the
// vectorizer widens after a guard proves its slice checks): sums of neighbours from 0 and from 2, a wider
// window, and a byte loop, on every length from 0 past a vector with remainders; then a bound past the
// slice, whose check fails in the last iteration.
const OFFSET_LOOPS: str = M"(@noinline fn pair(s: []u32) u32 { let mut t: u32 = 0; let mut i: usize = 0; while i + 1 < s.len() { t = t.wrapping_add(s[i].wrapping_mul(s[i + 1])); i += 1; } return t; }
@noinline fn quad(s: []u32) u32 { let mut t: u32 = 0; let mut i: usize = 2; while i + 3 < s.len() { t = t.wrapping_add(s[i] ^ s[i + 3]); i += 1; } return t; }
@noinline fn bytes(s: []u8) u32 { let mut t: u32 = 0; let mut i: usize = 0; while i + 1 < s.len() { t += (s[i] as u32) * (s[i + 1] as u32); i += 1; } return t; }
@noinline fn over(s: []u32, n: usize) u32 { let mut t: u32 = 0; let mut i: usize = 0; while i + 1 < n { t = t.wrapping_add(s[i] ^ s[i + 1]); i += 1; } return t; }
fn main() i32 {
    let mut s = Vector::<u32>::new();
    let mut u = Vector::<u8>::new();
    let mut x: u32 = 7;
    for _ in 0..40 {
        x = x.wrapping_mul(1103515245).wrapping_add(12345);
        s.push(x);
        u.push((x >> 24) as u8);
    }
    for n in 0..41usize {
        println("{} {} {} {}", n, pair(s[0..n]), quad(s[0..n]), bytes(u[0..n]));
    }
    // A bound past the slice: the last pair's check fails.
    println("{}", over(s[0..33], 34));
    return 0;
}
)";

@test
fn offset_loop_tests_match_across_profiles() {
    h::expect_same_output("offset loop tests", OFFSET_LOOPS, ["--profile=debug"], ["--profile=release"]);
}

// A loop that reads from the end (`d[k] = s[n - 1 - k]` while `k < n`), and one indexed by a `u32` counter,
// check once, before them (`mirrored`, `affine`'s extension): every length, a source of exactly `n`; then a
// source one short, a read from the end of a longer count, and a `u32` count past the source, whose checks
// fail.
const MIRRORED: str = M"(@noinline fn rev(d: []mut u32, s: []u32) { let n = d.len(); for k in 0..n { d[k] = s[n - 1 - k]; } }
@noinline fn far(d: []mut u32, s: []u32, m: usize) { let n = d.len(); for k in 0..n { d[k] = s[m - 1 - k]; } }
@noinline fn narrow(s: []u32, n: u32) u32 { let mut t: u32 = 0; let mut i: u32 = 0; while i < n { t = t.wrapping_add(s[i as usize]); i += 1; } return t; }
fn main(args: Vector<str>) i32 {
    let mut s = Vector::<u32>::new();
    let mut d = Vector::<u32>::new();
    for i in 0..40u32 {
        s.push(i * 7 + 1);
        d.push(0);
    }
    for n in 0..41usize {
        rev(d.index_range_mut(0..n), s[0..n]);
        let mut h: u32 = 0;
        for i in 0..n {
            h = h.wrapping_mul(31).wrapping_add(d[i]);
        }
        println("{} {} {}", n, h, narrow(s[0..n], n as u32));
    }
    if args.len() > 2 {
        println("{}", narrow(s[0..30], 31));
    } else if args.len() > 1 {
        far(d.index_range_mut(0..8), s[0..20], 21);
    } else {
        rev(d.index_range_mut(0..9), s[0..8]);
    }
    return 0;
}
)";

@test
fn mirrored_indexes_match_across_profiles() {
    let d = h::same_output(MIRRORED, ["--profile=debug"], ["--profile=release"], ["", "far", "far narrow"]);
    assert(d.len() == 0, d.as_str());
}

// Quotients and remainders by constants that the loop vectorizer computes by lane high products, and a count
// of matching bytes whose 8-byte lanes take several registers per vector: in place over slices past a vector
// and with a remainder, the lanes' extremes included.
const LANE_DIVISIONS: str = M"(@noinline fn sdiv7(s: []mut i32) { for i in 0..s.len() { s[i] = s[i] / 7; } }
@noinline fn sdivm3(s: []mut i16) { for i in 0..s.len() { s[i] = s[i] / -3; } }
@noinline fn udiv7(s: []mut u32) { for i in 0..s.len() { s[i] = s[i] / 7; } }
@noinline fn urem10(s: []mut u32) { for i in 0..s.len() { s[i] = s[i] % 10; } }
@noinline fn udiv3(s: []mut u16) { for i in 0..s.len() { s[i] = s[i] / 3; } }
@noinline fn count(s: []u8, c: u8) usize { let mut n: usize = 0; for k in 0..s.len() { if s[k] == c { n += 1; } } return n; }
fn main() i32 {
    let edges: [u32; 6] = [0, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 7, 0xFFFFFFF9];
    let mut x: u32 = 2463534242;
    for n in [0usize, 5, 37, 100] {
        let mut a = Vector::<i32>::new();
        let mut h = Vector::<i16>::new();
        let mut u = Vector::<u32>::new();
        let mut r = Vector::<u32>::new();
        let mut w = Vector::<u16>::new();
        let mut b = Vector::<u8>::new();
        for k in 0..n {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            let v = if k % 9 == 0 { edges[k / 9 % 6] } else { x };
            a.push(v as i32);
            h.push(v as i16);
            u.push(v);
            r.push(v);
            w.push(v as u16);
            b.push((v % 5) as u8);
        }
        sdiv7(&mut a);
        sdivm3(&mut h);
        udiv7(&mut u);
        urem10(&mut r);
        udiv3(&mut w);
        let mut t: u64 = 0;
        for k in 0..n {
            t = t.wrapping_mul(31).wrapping_add(a[k] as u32).wrapping_mul(31).wrapping_add(h[k] as u16);
            t = t.wrapping_mul(31).wrapping_add(u[k]).wrapping_mul(31).wrapping_add(r[k]);
            t = t.wrapping_mul(31).wrapping_add(w[k]);
        }
        println("{} {} {}", n, t, count(&b, 3));
    }
    return 0;
}
)";

@test
fn lane_divisions_by_constants_match_across_profiles() {
    h::expect_same_output("lane divisions by constants", LANE_DIVISIONS, ["--profile=debug"], ["--profile=release"]);
}

// Loops that update every field of a struct array alike, which run as one loop over the fields
// (`lir::loops` `reroll`), then vectorize: three `f32` fields plus an operand, four `u32` fields by a
// product and a shift, every count from 0 past a vector; and loops that do not qualify: one field left
// out (inside the element, or at its end), two fields updated differently.
const FIELD_LOOPS: str = M"(struct V { x: f32, y: f32, z: f32 }
struct Q { a: u32, b: u32, c: u32, d: u32 }
struct W { x: f32, y: f32, z: f32, w: f32 }
@noinline fn three(v: []mut W, d: f32) { for k in 0..v.len() { v[k].x += d; v[k].y += d; v[k].z += d; } }
@noinline fn shift(v: []mut V, d: f32) { for k in 0..v.len() { v[k].x += d; v[k].y += d; v[k].z += d; } }
@noinline fn scale(v: []mut Q, m: u32) { for k in 0..v.len() { v[k].a = v[k].a.wrapping_mul(m) >> 1; v[k].b = v[k].b.wrapping_mul(m) >> 1; v[k].c = v[k].c.wrapping_mul(m) >> 1; v[k].d = v[k].d.wrapping_mul(m) >> 1; } }
@noinline fn part(v: []mut V, d: f32) { for k in 0..v.len() { v[k].x += d; v[k].z += d; } }
@noinline fn mixed(v: []mut V, d: f32) { for k in 0..v.len() { v[k].x += d; v[k].y -= d; v[k].z += d; } }
fn main() i32 {
    for n in 0..20usize {
        let mut v = Vector::<V>::new();
        let mut q = Vector::<Q>::new();
        let mut w = Vector::<W>::new();
        for i in 0..n {
            let f = i as f32;
            v.push(V { x: f, y: f * 0.5, z: -f });
            w.push(W { x: f, y: -f, z: f * 2.0, w: f * 3.0 });
            q.push(Q { a: i as u32, b: 3 * i as u32, c: 7 * i as u32, d: 0xFFFF0000 + i as u32 });
        }
        shift(v.as_mut_slice(), 1.25);
        part(v.as_mut_slice(), 2.5);
        mixed(v.as_mut_slice(), 0.75);
        scale(q.as_mut_slice(), 3);
        three(w.as_mut_slice(), 0.5);
        let mut h: u32 = 0;
        for i in 0..n {
            h = h.wrapping_mul(31).wrapping_add(v[i].x.to_bits()).wrapping_mul(31).wrapping_add(v[i].y.to_bits());
            h = h.wrapping_mul(31).wrapping_add(v[i].z.to_bits()).wrapping_mul(31).wrapping_add(q[i].a ^ q[i].b ^ q[i].c ^ q[i].d);
            h = h.wrapping_mul(31).wrapping_add(w[i].x.to_bits() ^ w[i].y.to_bits() ^ w[i].z.to_bits() ^ w[i].w.to_bits());
        }
        println("{} {}", n, h);
    }
    return 0;
}
)";

@test
fn field_loops_match_across_profiles() {
    h::expect_same_output("field loops", FIELD_LOOPS, ["--profile=debug"], ["--profile=release"]);
}

// Calls whose arguments and results go without a copy under release: a slice parameter passed on in its
// registers (also after another argument), a read-only reference's referent passed by value, a result
// made in an exclusive reference's referent, an immutable local lent to a call that only reads it, a store
// into an exclusive referent that a later store overwrites across a call, and stack arguments.
const IN_PLACE: str = M"(struct Big { a: u64, b: u64, c: u64, d: u64, e: u64 }
static mut G: u64 = 0;
@noinline fn tick() { unsafe { G += 1; } }
@noinline fn sum(s: []u32, k: u32) u32 { let mut t = k; for i in 0..s.len() { t = t.wrapping_mul(31).wrapping_add(s[i]); } return t; }
@noinline fn fwd(s: []u32, k: u32) u32 { return sum(s, k); }
@noinline fn fwd_swap(k: u32, s: []u32) u32 { return sum(s, k + 1); }
@noinline fn take(b: Big) u64 { return b.a * 3 + b.e; }
@noinline fn by_ref(b: &Big) u64 { return take(*b); }
@noinline fn mk(a: u64) Big { return Big { a: a, b: a + 1, c: a + 2, d: a + 3, e: a + 4 }; }
@noinline fn into(out: &mut Big, a: u64) { *out = mk(a); }
@noinline fn look(x: &u64) u64 { return *x + 1; }
@noinline fn lent(a: u64) u64 { let x = a * 3; let y = look(&x); tick(); return x + y; }
@noinline fn over(p: &mut u64) u64 { *p = 1; tick(); *p += 1; return *p; }
@noinline fn many(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64, g: u64, h: u64, i: u64, j: u64) u64 { return a + b * 2 + c + d + e + f + g + h + i * 3 + j; }
@noinline fn sibling(x: u64, y: u64) u64 { return many(y, x, 0, 0, 0, 0, 0, 0, 1, 2); }
fn main() i32 {
    let v: [u32; 5] = [3, 1, 4, 1, 5];
    println("{} {}", fwd(v[0..5], 9), fwd_swap(9, v[1..4]));
    let mut b = Big { a: 0, b: 0, c: 0, d: 0, e: 0 };
    into(&mut b, 7);
    println("{} {} {}", b.a, b.e, by_ref(&b));
    let mut p: u64 = 5;
    println("{} {} {}", lent(4), over(&mut p), p);
    println("{} {}", sibling(10, 20), unsafe G);
    return 0;
}
)";

@test
fn in_place_calls_match_across_profiles() {
    h::expect_same_output(
        "calls passing arguments and results in place",
        IN_PLACE,
        ["--profile=debug"],
        ["--profile=release"],
    );
}

// Vector loads of two slices in a loop while `i + 16 <= x.len() && i + 16 <= y.len()`, by steps of 16
// (`lir::loops` versions it on the least bound, which a guard also keeps 16 below the maximum, and the
// copy without the range checks runs); every pair of lengths around a step; then a bound past the slice,
// whose last load's check fails.
const OFFSET_VECTORS: str = M"(import std::simd;
@noinline fn dot(x: []f32, y: []f32) f32 {
    let z = f32x4::splat(0.0);
    let mut a0 = z; let mut a1 = z; let mut a2 = z; let mut a3 = z;
    let mut i: usize = 0;
    while i + 16 <= x.len() && i + 16 <= y.len() {
        a0 += simd::load::<f32, 4>(x, i) * simd::load::<f32, 4>(y, i);
        a1 += simd::load::<f32, 4>(x, i + 4) * simd::load::<f32, 4>(y, i + 4);
        a2 += simd::load::<f32, 4>(x, i + 8) * simd::load::<f32, 4>(y, i + 8);
        a3 += simd::load::<f32, 4>(x, i + 12) * simd::load::<f32, 4>(y, i + 12);
        i += 16;
    }
    return simd::reduce_add_tree((a0 + a1) + (a2 + a3));
}
@noinline fn sum8(s: []u32, n: usize) u32x4 {
    let mut t = u32x4::splat(0);
    let mut i: usize = 0;
    while i + 8 <= n {
        t = t ^ simd::load::<u32, 4>(s, i) ^ (simd::load::<u32, 4>(s, i + 4) >> 1);
        i += 8;
    }
    return t;
}
fn main() i32 {
    let mut x = Vector::<f32>::new();
    let mut u = Vector::<u32>::new();
    let mut r: u32 = 11;
    for _ in 0..50 {
        r = r.wrapping_mul(1103515245).wrapping_add(12345);
        x.push((r >> 20) as f32);
        u.push(r);
    }
    for n in [0usize, 15, 16, 17, 31, 32, 47, 50] {
        for m in [0usize, 16, 33, 50] {
            println("{} {} {}", n, m, dot(x[0..n], x[50 - m..50]));
        }
        let v = sum8(u[0..n], n);
        println("{} {} {} {}", v[0], v[1], v[2], v[3]);
    }
    // A bound past the slice: the last load's check fails.
    let v = sum8(u[0..30], 32);
    println("{}", v[0]);
    return 0;
}
)";

@test
fn offset_vector_loops_match_across_profiles() {
    h::expect_same_output("offset vector loops", OFFSET_VECTORS, ["--profile=debug"], ["--profile=release"]);
}

// Loops that count down to 0 and read the element below the counter, checked (`lir::loops` versions
// them on `i0 <= len`): from the length, from a shorter start, and from past the end, which traps in both
// profiles.
const DOWN_LOOPS: str = M"(@noinline fn down(s: []u32, from: usize) u32 {
    let mut t: u32 = 0;
    let mut i = from;
    while i != 0 { i -= 1; t = t.wrapping_mul(31).wrapping_add(s[i]); }
    return t;
}
@noinline fn down_gt(s: []u64, from: usize) u64 {
    let mut t: u64 = 0;
    let mut i = from;
    while i > 0 { i -= 1; t ^= s[i] << (i & 7) as u64; }
    return t;
}
fn main() i32 {
    let mut v = Vector::<u32>::new();
    let mut w = Vector::<u64>::new();
    for n in 0..20usize {
        println("{} {} {}", n, down(&v, n), down_gt(&w, n / 2));
        v.push(n as u32 * 7 + 1);
        w.push(n as u64 * 0x9E3779B9);
    }
    println("{}", down(&v, v.len() + 1));
    return 0;
}
)";

@test
fn loops_counting_down_match_across_profiles() {
    h::expect_same_output("loops counting down", DOWN_LOOPS, ["--profile=debug"], ["--profile=release"]);
}

// Byte idioms the loop vectorizer computes at the narrow lanes, and a row's elements whose bounds check one
// test before the row's loop proves: saturating sums of bytes (by a value, a constant, of two slices, the
// test either way) and of 16-bit lanes, absolute differences of zero- and sign-extended bytes summed into
// 32 bits or stored as bytes, and widening sums of bytes and 16-bit lanes, every length from 0 past two
// vectors; rows of every shape within the matrix. Then rows past the matrix and a sum's second slice one
// short, whose checks fail.
const BYTE_IDIOMS: str = M"(@noinline fn sat_by(s: []mut u8, k: u8) { for i in 0..s.len() { let v = s[i] as u16 + k as u16; s[i] = if v > 255 { 255 } else { v as u8 }; } }
@noinline fn sat_const(s: []mut u8) { for i in 0..s.len() { let v = s[i] as u32 + 200; s[i] = if v < 256 { v as u8 } else { 255 }; } }
@noinline fn sat_two(d: []mut u8, a: []u8, b: []u8) { for i in 0..d.len() { let v = a[i] as u16 + b[i] as u16; d[i] = if v >= 256 { 255 } else { v as u8 }; } }
@noinline fn sat16(s: []mut u16, k: u16) { for i in 0..s.len() { let v = s[i] as u32 + k as u32; s[i] = if v > 65535 { 65535 } else { v as u16 }; } }
@noinline fn sad(a: []u8, b: []u8) u32 { let mut t: u32 = 0; for i in 0..a.len() { let x = a[i] as i32 - b[i] as i32; t += (if x < 0 { -x } else { x }) as u32; } return t; }
@noinline fn sads(a: []i8, b: []i8) u32 { let mut t: u32 = 0; for i in 0..a.len() { let x = a[i] as i32 - b[i] as i32; t += (if x >= 0 { x } else { -x }) as u32; } return t; }
@noinline fn adiff(d: []mut u8, a: []u8, b: []u8) { for i in 0..d.len() { let x = a[i] as i16 - b[i] as i16; d[i] = (if x < 0 { -x } else { x }) as u8; } }
@noinline fn bsum(s: []u8) u32 { let mut t: u32 = 0; for i in 0..s.len() { t += s[i] as u32; } return t; }
@noinline fn wsum(s: []u16) u64 { let mut t: u64 = 0; for i in 0..s.len() { t += s[i] as u64; } return t; }
@noinline fn rows(m: []u32, w: usize, h: usize) u32 { let mut t: u32 = 0; for y in 0..h { for x in 0..w { t = t.wrapping_add(m[y * w + x]); } } return t; }
fn hash(s: []u8) u32 { let mut h: u32 = 0; for i in 0..s.len() { h = h.wrapping_mul(31).wrapping_add(s[i] as u32); } return h; }
fn main(args: Vector<str>) i32 {
    let edges: [u32; 6] = [0, 255, 128, 127, 1, 254];
    let mut x: u32 = 2463534242;
    let mut m = Vector::<u32>::new();
    for k in 0..96u32 {
        m.push(k.wrapping_mul(2654435761));
    }
    for n in 0..70usize {
        let mut a = Vector::<u8>::new();
        let mut b = Vector::<u8>::new();
        let mut c = Vector::<i8>::new();
        let mut e = Vector::<i8>::new();
        let mut w = Vector::<u16>::new();
        for k in 0..n {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            let v = if k % 7 == 0 { edges[k / 7 % 6] } else { x };
            a.push(v as u8);
            b.push((v >> 8) as u8);
            c.push(v as i8);
            e.push((v >> 16) as i8);
            w.push((v >> 3) as u16);
        }
        let mut d = Vector::<u8>::new();
        for _ in 0..n {
            d.push(0);
        }
        let s1 = sad(&a, &b);
        let s2 = sads(&c, &e);
        let s3 = bsum(&a);
        let s4 = wsum(&w);
        sat_two(&mut d, &a, &b);
        let h1 = hash(&d);
        adiff(&mut d, &a, &b);
        let h2 = hash(&d);
        sat_by(&mut a, (n * 37) as u8);
        let h3 = hash(&a);
        sat_const(&mut b);
        let h4 = hash(&b);
        sat16(&mut w, (n * 1931) as u16);
        let mut h5: u32 = 0;
        for i in 0..n {
            h5 = h5.wrapping_mul(31).wrapping_add(w[i] as u32);
        }
        println("{} {} {} {} {} {} {} {} {} {}", n, s1, s2, s3, s4, h1, h2, h3, h4, h5);
        println("{} {} {}", rows(&m, n % 13, 96 / (n % 13 + 1)), rows(&m, 96 / (n % 9 + 1), n % 9), rows(&m, 0, n));
    }
    if args.len() > 2 {
        let mut a = Vector::<u8>::new();
        for k in 0..40u8 {
            a.push(k * 5);
        }
        println("{}", sad(&a, a[0..39]));
    } else if args.len() > 1 {
        println("{}", rows(&m, 10, 10));
    } else {
        println("{}", rows(&m, 7, 13) + rows(&m, 97, 1));
    }
    return 0;
}
)";

@test
fn byte_idioms_and_rows_match_across_profiles() {
    let d = h::same_output(BYTE_IDIOMS, ["--profile=debug"], ["--profile=release"], ["", "rows", "rows short"]);
    assert(d.len() == 0, d.as_str());
}
