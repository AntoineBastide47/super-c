// The differential oracles of tests/harness.spc: one program under two option lists, constant against
// run-time evaluation, and instruction checks on one function's assembly.
import tests::harness as h;
import tests::cli_harness as cli;
import stdlib;

// The run-time identity the oracles' programs use for inputs the compiler must not fold.
const OPR: str = "static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\n";

@test
fn same_output_agrees_across_profiles() {
    let mut src = String::from_str(OPR);
    src.push_str(
        "fn main() i32 {\n    let a = opr::<i32>(i32::MAX);\n    println(\"{}\", a.wrapping_add(opr::<i32>(1)));\n    println(\"{}\", a / opr::<i32>(0));\n    return 0;\n}\n",
    );
    h::expect_same_output("a division trap and a wrapping add", src.as_str(), ["--profile=dev"], ["--profile=release"]);
}

@test
fn same_output_reports_profile_dependent_overflow() {
    let mut src = String::from_str(OPR);
    src.push_str("fn main() i32 {\n    println(\"{}\", opr::<i32>(i32::MAX) + opr::<i32>(1));\n    return 0;\n}\n");
    let d = h::same_output(src.as_str(), ["--profile=dev"], ["--profile=release"], [""]);
    assert(d.contains("differs"), "an overflow traps under dev and wraps under release");
    assert(d.contains("super-c: attempt to add with overflow"), "the trap text is part of the report");
    assert(d.contains("-2147483648"), "the release stdout is part of the report");
}

@test
fn same_output_with_bounds_checks_forced() {
    let mut src = String::from_str(OPR);
    src.push_str(
        "fn main() i32 {\n    let mut v = Vector::<i64>::new();\n    for k in 0..opr::<usize>(9) {\n        v.push(k as i64);\n    }\n    let mut acc: i64 = 0;\n    for i in 0..v.len() {\n        acc += v[i];\n    }\n    println(\"{}\", acc);\n    let mut i: usize = 0;\n    while i < 12 {\n        acc += v[i];\n        i += 4;\n    }\n    println(\"{}\", acc);\n    return 0;\n}\n",
    );
    h::expect_same_output("a strided loop past the end traps with and without BCE", src.as_str(), [], ["SC_BCE=0"]);
    let d = h::same_output(src.as_str(), [], ["SC_BCE=0"], [""]);
    assert(d.len() == 0, "same_output agrees with expect_same_output");
}

@test
fn parity_values() {
    h::expect_const_runtime_parity("i32 add", "", "opq::<i32>(40) + opq::<i32>(2)", "i32");
    h::expect_const_runtime_parity("u8 wrap", "", "opq::<u8>(200).wrapping_add(opq::<u8>(100))", "u8");
    h::expect_const_runtime_parity("signed shift", "", "opq::<i64>(-1) << opq::<i64>(63)", "i64");
    h::expect_const_runtime_parity("float division", "", "opq::<f64>(1.0) / opq::<f64>(3.0)", "f64");
    h::expect_const_runtime_parity("saturating cast", "", "opq::<f64>(-1e300) as i32", "i32");
    h::expect_const_runtime_parity(
        "const fn",
        "const fn sq(x: i64) i64 {\n    return x * x;\n}\n",
        "sq(opq::<i64>(-7))",
        "i64",
    );
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

// An unsuffixed float literal in an f64 context is spelled as a C double, never an `f` float.
@test
fn f64_literal_contexts_spell_doubles() {
    let c = h::compile_c(
        "fn g(x: f64) f64 {\n    return x;\n}\nstruct S { pub a: f64, pub b: [f64; 2] }\nfn main() i32 {\n  let w: [f64; 2] = [0.1, 0.2];\n  let r: [f64; 3] = [0.3; 3];\n  let s = S { a: 0.4, b: [0.5, 0.6] };\n  return (g(0.7) + w[1] + r[0] + s.a + s.b[0] + -0.8) as i32;\n}\n",
    );
    assert(c.ok());
    for lit in ["0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8"] {
        assert(c.code_has(lit), lit);
        let mut f = String::from_str(lit);
        f.push_byte(b'f');
        assert(!c.code_has(f.as_str()), f.as_str());
    }
}

@test
fn parity_traps() {
    h::expect_const_runtime_parity("add overflow", "", "opq::<i32>(i32::MAX) + opq::<i32>(1)", "i32");
    h::expect_const_runtime_parity("negation of MIN", "", "-opq::<i8>(i8::MIN)", "i8");
    h::expect_const_runtime_parity("division by zero", "", "opq::<u16>(7) / opq::<u16>(0)", "u16");
    h::expect_const_runtime_parity("remainder overflow", "", "opq::<i64>(i64::MIN) % opq::<i64>(-1)", "i64");
    h::expect_const_runtime_parity("shift past the width", "", "opq::<u32>(1) << opq::<u32>(32)", "u32");
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

// A runtime without its overflow checks (SC_ARITH_WRAP in a checking profile) is the defect the oracle
// exists to find: the constant traps, the run time wraps.
@test
fn parity_reports_missing_runtime_check() {
    let mut cstd = String::from_str("--cstd=");
    cstd.push_str(str::from_cstr(cli::cstd()));
    cstd.push_str(" -DSC_ARITH_WRAP");
    let d = h::const_runtime_parity(
        "",
        ["opq::<i32>(i32::MAX) * opq::<i32>(2)", "opq::<i32>(5) * opq::<i32>(2)"],
        ["i32", "i32"],
        [cstd.as_str()],
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

const MULW: str = "@c.noinline\nfn mulw(a: u64, b: u64) u64 {\n    return a.wrapping_mul(b);\n}\nfn main(args: Vector<str>) i32 {\n    return mulw(args.len() as u64, 3) as i32;\n}\n";

@test
fn asm_host_function() {
    if ARCH == Arch::AArch64 {
        h::expect_asm("aarch64 multiply", MULW, ["--profile=release"], "mulw", ["mul"], ["bl", "x0"]);
    } else {
        h::expect_asm("x86_64 multiply", MULW, ["--profile=release"], "mulw", ["imul"], ["call", "rax"]);
    }
    let d = h::asm_check(MULW, ["--profile=release"], "mulw", ["div"], []);
    assert(d.contains("contains 'div'"), "a missing instruction is reported");
    let n = h::asm_check(MULW, ["--profile=release"], "no_such_fn", [], []);
    assert(n.contains("no translation unit defines"), "an unknown function is reported");
}

// The other Mach-O architecture through clang's target flag: the macOS SDK serves both.
@test
fn asm_cross_architecture() {
    if PLATFORM != Platform::MacOS {
        return;
    }
    if ARCH == Arch::AArch64 {
        h::expect_asm(
            "x86_64 multiply",
            MULW,
            ["--profile=release", "--arch=x86_64", "--cc=cc -target x86_64-apple-macos11"],
            "mulw",
            ["imul"],
            ["call"],
        );
    } else {
        h::expect_asm(
            "aarch64 multiply",
            MULW,
            ["--profile=release", "--arch=aarch64", "--cc=cc -target arm64-apple-macos11"],
            "mulw",
            ["mul"],
            ["bl"],
        );
    }
}

// wasm32 needs a wasi sysroot: the wasm lane names one in WASI_SDK_PATH.
@test
fn asm_wasm32() {
    let sdk = stdlib::getenv("WASI_SDK_PATH");
    if sdk == null || unsafe *sdk == 0 as char {
        return;
    }
    h::expect_asm("wasm32 multiply", MULW, ["--profile=release", "--target=wasm"], "mulw", ["i64.mul"], ["call"]);
}
