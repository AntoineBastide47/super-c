// Self-hosted port of tests/cli_test.c: drives $SUPERC as a subprocess over on-disk source trees, dogfooding
// the self-hosted driver's CLI surface (usage/argc/missing-file/error-exit/retired-flag) AND the end-to-end
// multi-file build pipeline (cross-module, generics, dyn, ffi, imports, extern-C, defaults, CTFE, --test).
// Each @test writes a source tree with cli::Proj, builds it natively (`native_build`) and runs it; a test of
// the emitted C compiles its tree (`compile`) with the C compiler (`cc_build`, only with `SC_TEST_CC`).
// Source trees are embedded verbatim as multi-line matchertext literals.
import tests::cli_harness as cli;
import tests::harness as h;
import stdio;
import stdlib;
import module::loader as loader;
import build_system::build as bsys;
import driver::util as du;
import driver_shim as shim;
import std::platform::fs;
import std::platform::process;
import std::parallel::runtime as prt;
import std::parallel::sync as psync;

struct Cmd {
    pub b: [char; 2048],
}

// A method a plain extend defines in one module and an overlapping plain extend of the same type
// defines again in another is a duplicate definition, reported once every module is checked, at the
// module that extends another module's type (a std definition comes first), naming the other.
// Disjoint extends in two modules each define the name.
@test
fn duplicate_items_across_modules() {
    let p = cli::proj_new();
    let root = p.dir();
    p.mkfile(
        "lib.spc",
        "pub struct P {\n    pub a: i32,\n}\n\nextend P {\n    pub fn get(self: &P) i32 {\n        return self.a;\n    }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import lib;\n\nextend lib::P {\n    pub fn get(self: &lib::P) i32 {\n        return 2;\n    }\n}\n\nfn main() i32 {\n    let p = lib::P { a: 1 };\n    return p.get();\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "a duplicate across modules fails");
    assert(
        r.out_shows(
            format(
                "error: duplicate definition of 'get' for 'lib::P': module 'lib' also defines it\n--> {}/main.spc:4:12",
                root,
            ).as_str(),
        ),
    );
    assert(r.out_shows(format("= note: the other definition is here\n--> {}/lib.spc:6:12", root).as_str()));
    p.mkfile(
        "sdup.spc",
        "extend String {\n    pub fn len(self: &String) usize {\n        return 7;\n    }\n}\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    let s = p.compile("sdup.spc");
    assert(s.exit != 0, "a duplicate of a std method fails");
    assert(
        s.out_shows(
            format(
                "error: duplicate definition of 'len' for 'String': module '__std::string' also defines it\n--> {}/sdup.spc:2:12",
                root,
            ).as_str(),
        ),
    );
    p.mkfile(
        "gen.spc",
        "pub struct W<T> {\n    pub v: T,\n}\n\nextend W<u8> {\n    pub fn get(self: &Self) i32 {\n        return 1;\n    }\n}\n",
    );
    p.mkfile(
        "use.spc",
        "import gen;\n\nextend gen::W<i32> {\n    pub fn get(self: &Self) i32 {\n        return 2;\n    }\n}\n\nfn main() i32 {\n    let a = gen::W::<u8> { v: 1 };\n    let b = gen::W::<i32> { v: 1 };\n    return a.get() * 10 + b.get() - 12;\n}\n",
    );
    let u = p.native_build("", "use.spc");
    assert(u.ok());
    assert_eq(p.run_bin(), 0);
}

// The readable language tour is also a broad end-to-end emission fixture. It must survive the full
// frontend, strict pedantic C11 with all warnings as errors, execution, and the native leak checker
// (ZST storage elision removed the last GNU empty-struct dependency).
@test
fn language_demo_emits_valid_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    assert(p.copyfile("main.spc", "examples/language_demo.spc"), "language demo is present");
    let compile = p.compile("main.spc");
    assert(compile.ok());
    let cc = p.cc_build("-pedantic-errors ");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Zero-length arrays emit strict ISO C: a local, a member, a pointer to one, a subscript of one, an
// Array<T, 0> and a loop over one in a const-generic instance compile under -pedantic-errors and
// -Wtype-limits (no `i < 0` loop header, no unsigned `i >= 0` bounds test) and run leak-free. A
// zero-length array of an owning element holds nothing: its drop emits no loop over absent storage
// (tests/ir/zst_test.spc has the semantics).
@test
fn zero_length_arrays_emit_valid_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct S { pub a: [u32; 0], pub b: u8 }
struct H { pub a: [String; 0], pub n: i32 }
fn sum<const N: usize>(a: [i32; N]) i32 { let mut s = 0; for x in a { s += x; } return s; }
fn count<const N: usize>(_a: [String; N]) usize { return N; }
fn main() i32 {
    let e: [i32; 0] = [];
    let s = S { a: [], b: 1 };
    let ps: *const [u32; 0] = &s.a;
    let q = unsafe (ps + 1);
    let mut a = Array::<u64, 0>::new();
    a.reverse();
    let h = H { a: [], n: 2 };
    let es: [String; 0] = [];
    let nested: [[String; 0]; 3] = [[], [], []];
    let mut v = Vector::<H>::new();
    v.push(H { a: [], n: 5 });
    let k = count(es) as i32 + count([String::from_str("x")]) as i32 + sizeof(nested) as i32;
    return sum(e) + s.b as i32 - 1 + (q != ps) as i32 + h.n - 2 + v.len() as i32 - 1 + k - 1;
}
)",
    );
    assert(p.compile("main.spc").ok());
    assert(p.cc_build("-pedantic-errors -Wtype-limits ").ok());
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// A comparison the range of an operand's C type decides is its constant: range patterns at both
// extremes of every width, unsigned and const-generic bounds at zero and at the type's maximum in
// either operand order, hex bounds, widening casts, a folded `~0usize`, the isize and i64 limits and
// constant C expressions (a shift, a mask, a truncating cast) at a limit. The emitted C compiles
// under the harness C compiler with -Wall -Wextra -Wtype-limits -pedantic-errors (gcc rejects an
// always-true `x >= 0` there), compile time and run time agree, and an operand with an effect
// (a call) still runs.
const LIMIT_CMPS: str = M"(const LO: i8 = -128;
static mut CALLS: i32 = 0;
fn bump() u32 {
    unsafe CALLS += 1;
    return 7;
}
fn p8(x: i8) i32 { return switch x { -128.. => 1, _ => 3, }; }
fn p8b(x: i8) i32 { return switch x { -128..=-1 => 1, 0..=127 => 2, _ => 3, }; }
fn p16(x: i16) i32 { return switch x { -32768..0 => 1, 0..=32767 => 2, _ => 3, }; }
fn p32(x: i32) i32 { return switch x { -2147483648..0 => 1, 0..=2147483647 => 2, _ => 3, }; }
fn p64(x: i64) i32 { return switch x { -9223372036854775808..0 => 1, 0..=9223372036854775807 => 2, _ => 3, }; }
fn pis(x: isize) i32 { return switch x { -9223372036854775808..0 => 1, 0.. => 2, _ => 3, }; }
fn pu8(x: u8) i32 { return switch x { 0..=9 => 1, 10..=255 => 2, _ => 3, }; }
fn pu16(x: u16) i32 { return switch x { 0..10 => 1, 10..=65535 => 2, _ => 3, }; }
fn pu32(x: u32) i32 { return switch x { 0..10 => 1, 10..=4294967295 => 2, _ => 3, }; }
fn pu64(x: u64) i32 { return switch x { 0..10 => 1, 10..=18446744073709551615 => 2, _ => 3, }; }
fn pus(x: usize) i32 { return switch x { 0..10 => 1, 10.. => 2, _ => 3, }; }
fn pch(x: char) i32 { return switch x { '\0'..='a' => 1, 'b'..='\xff' => 2, _ => 3, }; }
fn pref(x: &u8) i32 {
    if let 0..=255 = x {
        return 1;
    }
    return 0;
}
fn cmps<const N: usize>(i: usize) i32 {
    return (i < N) as i32 + (i <= N) as i32 * 2 + (i > N) as i32 * 4 + (i >= N) as i32 * 8 + (N > i) as i32 * 16 + (N <= i) as i32 * 32 + (i == N) as i32 * 64 + (N != i) as i32 * 128;
}
fn top<const M: u8>(x: u8) i32 {
    assert(x <= M);
    return (x > M) as i32 + (M >= x) as i32 * 2 + (x != M) as i32 * 4;
}
fn low<const L: i8>(x: i8) i32 {
    assert(x >= L);
    return (x < L) as i32 + (L <= x) as i32 * 2;
}
fn hex(b: u8) i32 {
    return (b >= 0xC0) as i32 + (b <= 0xDF) as i32 * 2 + (b < 0x80u8) as i32 * 4;
}
fn wide(a: u8, b: u32, c: u64) i32 {
    return ((a as i32) < 300) as i32 + ((b as u64) <= 4294967295) as i32 * 2 + ((a as u16) >= 0) as i32 * 4 + (c <= usize::MAX as u64) as i32 * 8;
}
fn lims(x: isize, y: i64, u: usize, b: u8) i32 {
    let named = (x <= isize::MAX) as i32 + (x >= isize::MIN) as i32 * 2 + (y >= i64::MIN) as i32 * 4 + (i64::MIN < y) as i32 * 8;
    let top = (x <= (~0usize >> 1) as isize) as i32 * 16 + ((~0usize >> 1) as isize >= x) as i32 * 32;
    return named + top + (b <= (~0u32) as u8) as i32 * 64 + (u <= (~0usize | 0)) as i32 * 128 + (b > (0xFFFFu32 & 0xFF) as u8) as i32 * 256;
}
fn loops<const N: usize>(a: [i32; N]) i32 {
    let mut s = 0;
    for x in a {
        s += x;
    }
    let mut i: usize = 0;
    while i < N {
        i += 1;
    }
    return s + i as i32;
}
static_assert(p8(-128) == 1 && p8b(-128) == 1 && p8b(127) == 2 && p16(-32768) == 1 && p16(32767) == 2);
static_assert(p32(-2147483648) == 1 && p64(-9223372036854775808) == 1 && p64(9223372036854775807) == 2);
static_assert(pu8(255) == 2 && pu16(65535) == 2 && pu32(4294967295) == 2 && pu64(18446744073709551615) == 2);
static_assert(pus(18446744073709551615) == 2 && pch('\xff') == 2 && pref(&255) == 1);
static_assert(cmps::<0>(0) == 106 && cmps::<0>(5) == 172 && cmps::<18446744073709551615>(5) == 147);
static_assert(top::<255>(255) == 2 && top::<255>(3) == 6 && low::<LO>(-128) == 2 && low::<LO>(5) == 2);
static_assert(hex(0xC5) == 3 && hex(0x10) == 6 && wide(200, 9, 1) == 15);
static_assert(lims(3, -4, 5, 7) == 255 && lims(isize::MIN, i64::MIN, 0, 255) == 247);
fn main() i32 {
    let z: [i32; 0] = [];
    let r = p8(-128) + p8b(-1) + p16(-32768) + p32(-2147483648) + p64(-9223372036854775808) + pis(-3);
    let u = pu8(255) + pu16(65535) + pu32(4294967295) + pu64(18446744073709551615) + pus(0) + pch('\xff') + pref(&0);
    let c = cmps::<0>(0) + cmps::<0>(5) + cmps::<18446744073709551615>(5);
    let t = top::<255>(255) + top::<255>(3) + low::<LO>(-128) + low::<LO>(5);
    let h = hex(0xC5) + hex(0x10) + wide(200, 9, 1) + loops(z) + loops([1, 2]);
    let e = (bump() >= 0) as i32 + (0 > bump()) as i32 + unsafe CALLS;
    let l = lims(3, -4, 5, 7) + lims(isize::MIN, i64::MIN, 0, 255);
    print("{} {} {} {} {} {} {}\n", r, u, c, t, h, e, l);
    return 0;
}
)";

@test
fn type_limit_comparisons_emit_valid_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", LIMIT_CMPS);
    assert(p.compile("main.spc").ok());
    assert(p.cc_build("-pedantic-errors -Wtype-limits ").ok());
    let r = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(r.ok() && r.out_shows("6 12 425 12 29 3 502\n"));
}

// A program whose `@X@` markers long_string_constants_emit_valid_c replaces with long string bodies.
const LONG_STRS: str = M"(import string as cstring;
const CP: str = "@P@";
const CM: str = M"(@M@)";
const CA: [str; 2] = ["@P@", "y"];
const CS: [str; 2] = ["\u{e9}\x41\t", M[]"(a<b)"];
fn rep(unit: str, n: usize) String {
    let mut s = String::new();
    for _ in 0..n {
        s.push_str(unit);
    }
    return s;
}
fn main() i32 {
    let p = rep("ab\x41\u{e9}\n\"\\", 600);
    let m = rep(M"(x(y)"z\n)", 700);
    let mut fe = rep("{a}", 1400);
    fe.push_str("7");
    let s: str = "@P@";
    let t = M"(@M@)";
    let bs: []u8 = b"@B@";
    let cp: *const u8 = "@P@";
    let n = unsafe cstring::strlen("@P@");
    let f = format("@F@{}", 7);
    let e: str = "@A@";
    let e1: str = "@A@a";
    let mut okb = bs.len() == 4200;
    for i in 0..bs.len() {
        okb = okb && bs[i] == if i % 2 == 0 {
            b'q';
        } else {
            0xff;
        };
    }
    let okp = unsafe cstring::strlen(cp as *const char) == 4800 && unsafe *(cp + 3) == 0xc3;
    assert(s == "@P@");
    assert(t == M"(@M@)", "long matchertext");
    assert_eq(e1.len(), "@A@a".len());
    print("{} {} {} {} {} ", CP == p.as_str(), CM == m.as_str(), CA[0] == p.as_str(), s == p.as_str(), t == m.as_str());
    print("{} {} {} {} ", okb, okp, n == 4800, f.as_str() == fe.as_str());
    print("{} {} ", CS[0] == "\u{e9}\x41\t" && CS[0].len() == 4, CS[1] == "a<b" && M[]"(a<b)" == "a<b");
    print("{} {} {}\n", s.len() + t.len() + bs.len(), e.len(), e1.len());
    print("@F@|{}\n", CA[1]);
    return 0;
}
)";

// C11 guarantees string literals of 4095 bytes only (-pedantic-errors rejects a longer one): a string
// constant past that length spells as a static array of its bytes, with the length and the
// terminating 0 a literal has. Plain (with escapes), matchertext and byte strings, file-scope
// constants and a constant array element, `str` views, C-string pointers and format segments of a
// long string all compile under -pedantic-errors and hold their exact bytes; 4095 bytes stay a
// literal. An assertion message spells at most 1000 bytes of an expression's source. Short
// file-scope constants decode their escapes and matchertext delimiter chains like body constants.
@test
fn long_string_constants_emit_valid_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    // Each marker's unit source text, repeated past 4095 decoded bytes.
    let mut big = String::new();
    rep(&mut big, M"(ab\x41\u{e9}\n\"\\)", 600);
    let mut bigm = String::new();
    rep(&mut bigm, M"(x(y)"z\n)", 700);
    let mut bytes = String::new();
    rep(&mut bytes, M"(q\xff)", 2100);
    let mut bigf = String::new();
    rep(&mut bigf, "{{a}}", 1400);
    let mut a4095 = String::new();
    rep(&mut a4095, "a", 4095);
    let src = String::from_str(LONG_STRS).replace("@P@", big.as_str()).replace("@M@", bigm.as_str()).replace(
        "@B@",
        bytes.as_str(),
    ).replace("@F@", bigf.as_str()).replace("@A@", a4095.as_str());
    let p = cli::proj_new();
    p.mkfile("main.spc", src.as_str());
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "sizeof(\"aaa") && p.gen_has("main.c", "static const uint8_t __sc_lit"));
    assert(p.cc_build("-pedantic-errors ").ok());
    let r = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    let mut out = String::from_str("true true true true true true true true true true true 14600 4095 4096\n");
    rep(&mut out, "{a}", 1400);
    out.push_str("|y\n");
    assert(r.ok() && r.out_shows(out.as_str()));
}

// Append `unit` to `dst` `n` times.
fn rep(dst: &mut String, unit: str, n: usize) {
    for _ in 0..n {
        dst.push_str(unit);
    }
}

// C11 has no `0o` or `0b` integer prefix (gcc 13 rejects `0o`, -pedantic both): octal and binary
// literals reach C in hex with the same value, underscores and u64::MAX included.
@test
fn octal_and_binary_literals_emit_c11() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn main() i32 {\n    let a: u32 = 0o1_7;\n    let b: u32 = 0b101;\n    let c: u64 = 0o1777777777777777777777;\n    let d: u64 = 0b1111_1111;\n    return (a + b + (c - 18446744073709551615) as u32 + d as u32 - 275) as i32;\n}\n",
    );
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "0xf") && p.gen_has("main.c", "0xffffffffffffffff"), "hex spellings");
    assert(!p.gen_has("main.c", "0o") && !p.gen_has("main.c", "0b1"), "no C2y prefix survives");
    assert(p.cc_build("-pedantic-errors ").ok());
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// A constant shift count or divisor is read by its value, whatever its spelling: a hex count past the
// width is an error at the operation, a run-time count past it reaches the checked helper (C leaves
// `x >> 64` undefined) and traps, and a hex divisor stays a C operator.
@test
fn hex_shift_counts_reach_the_checked_helper() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("hex.spc", "fn f(x: u64) u64 {\n    return x >> 0x40;\n}\nfn main() i32 {\n    return f(1) as i32;\n}\n");
    p.expect_fail("hex.spc", "error: this operation is undefined behavior when executed: shift out of range\n--> ");
    p.mkfile(
        "main.spc",
        "static mut K: u64 = 200;\n@noinline\nfn f(x: u64, n: u64) u64 {\n    return x / 0x10 + (x >> n);\n}\nfn main() i32 {\n    print(\"{}\\n\", f(unsafe K, unsafe K - 0x88));\n    return 0;\n}\n",
    );
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "__sc_shr_u64(x, n)") && p.gen_has("main.c", "(x / 0x10ULL)"));
    assert(p.cc_build("-pedantic-errors ").ok());
    let r = p.run_bin_env("");
    assert(r.exit != 0 && r.out_shows("attempt to shift right with overflow"));
}

// An inlined call that passes one integer for two parameters compares it with itself: the comparison
// folds where it is spelled, so C never sees `x > x` (a -Wtautological-compare warning).
@test
fn inlined_self_comparison_folds() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile(
        "main.spc",
        "@noinline\nfn tail(s: str, end: usize) str {\n    return s.slice(end, end);\n}\nfn main() i32 {\n    return tail(\"abc\", 2).len() as i32;\n}\n",
    );
    assert(cli::superc_in(p.dir(), "build --profile=release --emit-c").ok());
    let c = loader::read_file(format("{}/build/release/raw/main.c", p.dir()).as_str()).unwrap();
    assert(!c.as_str().contains("(end > end)") && c.as_str().contains("((void)(end), false)"));
}

// A single-file build takes every option of its profile: the release profile strips the binary, at
// the link or with `strip` after it, as a manifest build does.
@test
fn a_single_file_release_build_is_stripped() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "@noinline\nfn zz_strip_probe_fn(x: i32) i32 {\n    return x * 3 + 1;\n}\nfn main(args: Vector<str>) i32 {\n    return zz_strip_probe_fn(args.len() as i32) - 4;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_in(root, "build --profile=release main.spc -o bin");
    r.show();
    assert(r.ok(), "the program builds at the release profile");
    assert_eq(p.run_bin(), 0);
    let bin = loader::read_file(format("{}/bin{}", root, unsafe str::from_cstr(cli::binext())).as_str()).unwrap();
    assert(!bin.as_str().contains("zz_strip_probe_fn"), "the binary holds no symbol names");
}

// A `&mut` parameter is exclusive for the call, so its C parameter is `restrict`; a `&` one is not. The
// success test of `?` reaches C as a likely branch, at run time and in constant evaluation alike.
@test
fn mut_refs_restrict_and_question_success_is_likely() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "@noinline\nfn bump(n: &mut i32, by: &i32) { *n = *n + *by; }\nconst fn half(x: i32) Option<i32> {\n    if x % 2 == 0 {\n        return Option::<i32>::Some(x / 2);\n    }\n    return Option::<i32>::None;\n}\nconst fn quarter(x: i32) Option<i32> {\n    let h = half(x)?;\n    return half(h);\n}\nconst Q: i32 = quarter(8).unwrap_or(0);\nfn main() i32 {\n    let mut n = 1;\n    let k = 2;\n    bump(&mut n, &k);\n    return switch quarter(4 * n) {\n        Some(q) => q - 3 + Q - 2,\n        None => 1,\n    };\n}\n",
    );
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "int32_t *restrict n, const int32_t *by"), "only the &mut parameter is restrict");
    assert(p.gen_has("main.c", "__builtin_expect("), "the success test of `?` is likely");
    assert(p.cc_build("-pedantic-errors ").ok());
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// A `[]mut T` parameter is exclusive for the call like a `&mut`: `f__r` receives it as a `restrict`
// element pointer and a length, every direct call splits the view, and `f` keeps the struct ABI for
// function values and `@export`. Recursion, methods, generics and a call result argument agree.
const SPLIT_VIEWS: str = M"(fn axpy(y: []mut f64, x: []f64, a: f64) {
    for i in 0..y.len() {
        y.set(i, *y.at(i) + a * *x.at(i));
    }
}
fn fill<T: Copy>(d: []mut T, v: T) {
    for i in 0..d.len() {
        d.set(i, v);
    }
}
struct Acc { pub n: i64 }
extend Acc {
    fn take(self: &mut Acc, d: []mut i64) {
        for i in 0..d.len() {
            self.n += *d.at(i);
            d.set(i, 0);
        }
    }
}
fn rec(d: []mut i32, k: usize) i32 {
    if k == 0 {
        return *d.at(0);
    }
    d.set(0, *d.at(0) + 1);
    // Not a tail call (the addition runs after it), so the recursive call stays a call.
    let v = rec(d, k - 1);
    return v + 0;
}
fn pick(x: []mut i32) []mut i32 {
    return x;
}
@export("sc_scale")
fn scale(d: []mut f32, s: f32) {
    for i in 0..d.len() {
        d.set(i, *d.at(i) * s);
    }
}
fn main(args: Vector<str>) i32 {
    let mut y: [f64; 8] = [1.0; 8];
    let x: [f64; 8] = [2.0; 8];
    axpy(y, x, args.len() as f64);
    let mut a: [i64; 4] = [0; 4];
    fill(a, 3i64);
    let mut acc = Acc { n: 0 };
    acc.take(a);
    let mut r: [i32; 2] = [0; 2];
    let v = rec(pick(r), 5);
    let fp = rec;
    let w = fp(r, 2);
    let mut f: [f32; 3] = [1.0; 3];
    scale(f, 2.0);
    return (y[7] as i64 + acc.n + v as i64 + w as i64 + f[0] as i64 + a[0]) as i32 - 29;
}
)";

@test
fn mut_views_split_into_restrict_pointers() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", SPLIT_VIEWS);
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.gen_has("main.c", "void axpy__r(double *restrict __sc_sp"), "the definition splits the view");
    assert(
        p.gen_has("main.c", "void axpy(SliceMut__f64 __sc_a0, Slice__f64 __sc_a1, double __sc_a2) {"),
        "the entry keeps the struct ABI",
    );
    assert(
        p.gen_has("main.c", "void (sc_scale)(SliceMut__f32 __sc_a0, float __sc_a1) {"),
        "an export keeps the struct ABI",
    );
    assert(p.gen_has("main.c", "rec__r(d.ptr, d.len, "), "a direct call passes the pointer and the length");
    assert(p.cc_build("-pedantic-errors ").ok(), "the emitted C compiles under -pedantic-errors");
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok(), "the program runs clean");
}

// A literal pattern and both ends of a range pattern take the matched value's type, read through a
// reference, at every width: the emitted C spells each in that type (a u64 bound past i64::MAX is no
// signed literal) and compiles under -Werror, and compile time and run time agree. A literal the type
// cannot hold is an error.
const PAT_LITS: str = M"(fn wide(x: u64) i32 {
    return switch x {
        9223372036854775808..=18446744073709551613 => 1,
        18446744073709551614 => 2,
        18446744073709551615 => 3,
        _ => 4,
    };
}
fn narrow(a: u8, b: u16, c: u32, d: usize) i32 {
    return switch (a, b, c, d) {
        (200..=254, 60000..65535, 4000000000..=4294967294, 18446744073709551615) => 1,
        (7, 9, 11, 13) => 2,
        _ => 3,
    };
}
fn signed(a: i8, b: i16, c: i32, d: i64) i32 {
    return switch (a, b, c, d) {
        (-127..=-100, -32767..-30000, -2147483647..=-2000000000, -9223372036854775807..=-9000000000000000000) => 1,
        (-7, 9, -11, 13) => 2,
        _ => 3,
    };
}
fn by_ref(x: &u64) i32 {
    if let 9223372036854775809..=18446744073709551615 = x {
        return 1;
    }
    return 0;
}
static_assert(wide(9223372036854775808) == 1 && wide(18446744073709551614) == 2 && wide(18446744073709551615) == 3);
static_assert(wide(5) == 4 && by_ref(&18446744073709551615) == 1 && by_ref(&9223372036854775808) == 0);
static_assert(narrow(254, 65534, 4294967294, 18446744073709551615) == 1 && narrow(7, 9, 11, 13) == 2);
static_assert(signed(-127, -32767, -2147483647, -9223372036854775807) == 1 && signed(-7, 9, -11, 13) == 2);
static_assert(signed(-128, -30000, -2000000000, -9000000000000000000) == 3);
static mut TOP: u64 = 18446744073709551615;
fn main() i32 {
    let t = unsafe TOP;
    let n: usize = 18446744073709551615;
    print("{} {} {} {} ", wide(t), wide(t - 1), wide(t / 2 + 1), wide(t / 2));
    print("{} {} {}\n", by_ref(&t), narrow(254, 65534, 4294967294, n), signed(-100, -30001, -2000000000, -9000000000000000000));
    return 0;
}
)";

@test
fn pattern_literals_take_the_scrutinee_type() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", PAT_LITS);
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.cc_build("-pedantic-errors ").ok(), "the emitted C compiles under -pedantic-errors");
    let r = p.run_bin_env("");
    assert(r.ok(), "the program runs clean");
    assert(r.out_shows("3 2 1 4 1 1 1"), "each pattern matches in its type");
    h::expect_err_msg(
        "a range bound out of range",
        "fn f(x: u8) i32 {\n    return switch x {\n        0..=300 => 1,\n        _ => 0,\n    };\n}\n",
        "error: integer literal is out of range for 'u8'",
    );
    h::expect_err_msg(
        "a literal out of range through a reference",
        "fn f(x: &i8) i32 {\n    if let -129 = x {\n        return 1;\n    }\n    return 0;\n}\n",
        "error: integer literal is out of range for 'i8'",
    );
    h::expect_err_msg(
        "a negative literal of an unsigned type",
        "fn f(x: u32) i32 {\n    return switch x {\n        -1 => 1,\n        _ => 0,\n    };\n}\n",
        "error: cannot apply unary operator '-' to type 'u32'",
    );
    h::expect_err_msg(
        "a string literal of an integer",
        "fn f(x: i32) i32 {\n    return switch x {\n        \"a\" => 1,\n        _ => 0,\n    };\n}\n",
        "error: mismatched types: expected 'i32', found 'str'",
    );
}

// A second module's enums used across the boundary: value return, payload-less match, payload construction
// and match. Drives the multi-file build/ tree (subdirs) through cc + run.
@test
fn cross_module_enum() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        M"(pub enum Color { Red, Green = 5, Blue }
pub enum Box { Empty, Filled(i32) }
pub fn red() Color { return Color::Red; }
)",
    );
    p.mkfile(
        "xm.spc",
        M"(import lib::lib;
extern "C" { fn exit(code: i32) void; }
fn color_code(c: lib::lib::Color) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }
fn box_amt(b: lib::lib::Box) i32 { return switch b { Filled(n) => n, Empty => -1, }; }
fn main() i32 { let c = lib::lib::red(); let b = lib::lib::Box::Filled(20);
  unsafe exit(color_code(c) + box_amt(b)); return 0; }
)",
    );
    let r = p.native_build("", "xm.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 21);
}

// --const-eval end to end: folded static_assert (true passes / false errors at Super-C level), folded
// designated indices, folded sizeof over the computed layout, [T; N] as a generic arg, and the layout
// _Static_asserts landing in the C and PASSING under -Werror.
@test
fn const_eval_flag() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(extern "C" { fn exit(code: i32) void; }
const K: i32 = 2;
struct Pt { pub x: i32, pub y: u8 }
struct Wrap<T> { pub v: T }
static_assert(sizeof(Pt) == 8, "padded to 8");
static_assert(K * 2 == 4, "folds");
static_assert(sizeof(Wrap<[i32; 4]>) == 16, "array arg layout");
fn main() i32 {
  let a: [i32; 2 + 2] = [[K] = 30, [K + 1] = 10, [1 - 1] = 2];
  let w = Wrap::<[i32; 4]> { v: [1, 2, 3, 4] };
  unsafe exit(a[2] + a[3] + a[0] + w.v[3] + (sizeof((i32, bool)) as i32)); return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("main.c", "[2] = 30"), "const designator index folded into the C output");
    assert(
        p.gen_has("__sc_t/Pt.h", "_Static_assert(sizeof(Pt) == 8"),
        "layout verification assert in the definition header",
    );
    let cc = p.native_build("", "main.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 54);

    // A folded-FALSE static_assert is a SUPER-C error (with our span), not a downstream C error.
    p.mkfile("main.spc", "static_assert(1 + 1 == 3, \"nope\");\nfn main() i32 { return 0; }\n");
    let e = p.compile("main.spc");
    assert(e.exit != 0, "folded-false static_assert fails the build");
    assert(e.out_has("static assertion failed"), "and names the failure");
    // A module without items checks its top-level asserts too, once every item is typed.
    p.mkfile("only.spc", "static_assert(1 + 1 == 3, \"in a module without items\");\n");
    p.mkfile("main.spc", "import only;\n\nfn main() i32 {\n    return 0;\n}\n");
    let oe = p.compile("main.spc");
    assert(oe.exit != 0, "a false assert in a module without items fails the build");
    assert(oe.out_has("static assertion failed"), "a false assert in a module without items is reported");
    assert(oe.out_has("only.spc:1:15"), "at the assert");
    p.mkfile("main.spc", "static_assert(1 + 1 == 3, \"nope\");\nfn main() i32 { return 0; }\n");
    // Tiny budgets keep plain scalar folding working.
    let b = p.compile_flags("--const-eval-steps=4096 --const-eval-memory=1M", "main.spc");
    assert(b.exit != 0, "tiny budgets still fold scalar asserts");
    assert(b.out_has("static assertion failed"), "same failure under tiny budgets");
    // The retired --const-eval flag is rejected with usage.
    let rt = p.compile_flags("--const-eval", "main.spc");
    assert(rt.exit != 0, "the retired --const-eval flag is rejected");
    assert(rt.out_has("USAGE:"), "and prints usage");
}

@test
fn inline_for_and_parallel_for() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::atomics as atom;
import std::parallel::runtime as rt;
fn sum_upto<const N: usize>() usize {
  let mut t: usize = 0;
  inline for i in 0..N { t += i; }
  return t;
}
struct Pt { pub x: i32, pub y: u8, }
fn field_names<T>() usize {
  let ti = type_info::<T>();
  let mut seen: usize = 0;
  inline for i in 0..type_info::<T>().fields.len {
    print("field {}\n", ti.fields.get(i).name);
    seen += 1;
  }
  return seen;
}
fn main() i32 {
  let mut s = 0;
  inline for i in 0..4 { s += i; }
  if s != 6 { return 1; }
  if sum_upto::<10>() != 45 { return 3; }
  if field_names::<Pt>() != 2 { return 4; }
  if field_names::<i64>() != 0 { return 5; }
  let sum = atom::Atomic::<i64>::new(0);
  let sp = &sum;
  parallel for i in 0..100 {
    let _ = sp.fetch_add(i as i64, atom::MemoryOrder::Relaxed);
  }
  if sum.load(atom::MemoryOrder::SeqCst) != 4950 { return 2; }
  print("ok\n");
  rt::shutdown();
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "(s, 2LL);"), "the inline for physically unrolled");
    assert(!p.gen_has("main.c", "__sc_inline_for"), "constant bounds folded");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "the parallel for summed through the atomic");
    assert(rr.out_shows("field y"), "a generic body unrolled over type_info fields");
}

@test
fn reflection_tail() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(enum Shape { Dot, Pair(i32, i64), Tri { a: u8, b: i32, c: i64 }, }
struct PP { pub x: i32, pub y: i32, }
fn width<V>(x: &V) usize { let _ = x; return sizeof(V); }
fn payload_widths<T>(e: &T) usize {
  let mut s: usize = 0;
  inline for v in variants(e) {
    if v.is_active { inline for p in payloads(v) { s += width(&p.value); } }
  }
  return s;
}
const fn reset<V: Default>(v: &mut V) { *v = V::default(); }
const fn cmut() i32 {
  let mut p = PP { x: 5, y: 6 };
  inline for f in fields(&mut p) { if f.index == 1 { reset(&mut f.value); } }
  return p.x * 10 + p.y;
}
static_assert(cmut() == 50, "ctfe mut projection");
const fn cvars() i64 {
  let s = Shape::Pair(3, 4);
  let mut t: i64 = 0;
  inline for v in variants(&s) { if v.is_active && v.payload == 2 { t += v.tag as i64 + 100; } }
  return t;
}
static_assert(cvars() == 101, "ctfe variants");
fn main() i32 {
  let s1 = Shape::Dot;
  let s2 = Shape::Pair(1, 2);
  let s3 = Shape::Tri { a: 1, b: 2, c: 3 };
  if payload_widths(&s1) != 0 { return 1; }
  if payload_widths(&s2) != 12 { return 2; }
  if payload_widths(&s3) != 13 { return 3; }
  let p2 = PP { x: 3, y: 4 };
  let ti = type_info::<PP>();
  let mut n: usize = 0;
  inline for i in 0..ti.fields.len { n += 1; }
  if n != 2 { return 4; }
  let mut off1: usize = 99;
  inline for f in fields(&p2) { if f.index == 1 { off1 = f.offset; } let _ = f.kind; let _ = f.size; }
  if off1 != 4 { return 5; }
  print("tail ok\n");
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("tail ok"), "payloads, CTFE mutation, and binder metadata all hold");
    // Three-module obligation chain: the diagnostic lands at the binding call, two hops out.
    let p2 = cli::proj_new();
    p2.mkfile(
        "hop.spc",
        M"(pub interface Pretty { fn m(self: &Self) i64; }
extend i32 as Pretty { pub fn m(self: &i32) i64 { return (*self) as i64 + 0; } }
pub fn render<V: Pretty>(v: &V) i64 { return v.m(); }
pub fn dump_all<T>(v: &T) i64 { let mut s: i64 = 0; inline for f in fields(v) { s += render(&f.value); } return s; }
)",
    );
    p2.mkfile("hop2.spc", M"(import hop;
pub fn wrap<T>(v: &T) i64 { return hop::dump_all(v); }
)");
    p2.mkfile(
        "main.spc",
        M"(import hop2;
struct Bad { pub a: i32, pub b: bool, }
fn main() i32 { let b = Bad { a: 1, b: true }; let _ = hop2::wrap(&b); return 0; }
)",
    );
    p2.expect_fail("main.spc", "does not satisfy a bound the callee's reflection loop requires");
}

// An 18-module recursive call cycle hands the bound up one module per discharge pass, so the
// diagnostic needs more passes than a fixed pass cap of 16 allowed; the cycle offers the same
// bounds again on every pass, and the passes still end.
@test
fn reflect_bound_chain_past_sixteen_hops() {
    let p = cli::proj_new();
    p.mkfile(
        "m18.spc",
        M"(import m1;
pub interface Pretty { fn m(self: &Self) i64; }
extend i32 as Pretty { pub fn m(self: &i32) i64 { return *self; } }
pub fn render<V: Pretty>(v: &V) i64 { return v.m(); }
pub fn w18<T>(v: &T, n: i32) i64 { if n > 0 { return m1::w1(v, n - 1); } let mut s: i64 = 0; inline for f in fields(v) { s += render(&f.value); } return s; }
)",
    );
    for k in 1..18 {
        let name = format("m{}.spc", k);
        let text = format(
            "import m{};\npub fn w{}<T>(v: &T, n: i32) i64 {{ return m{}::w{}(v, n); }}\n",
            k + 1,
            k,
            k + 1,
            k + 1,
        );
        p.mkfile(name.as_str(), text.as_str());
    }
    p.mkfile(
        "main.spc",
        M"(import m1;
struct Bad { pub a: i32, pub b: bool, }
fn main() i32 { let b = Bad { a: 1, b: true }; let _ = m1::w1(&b, 1); return 0; }
)",
    );
    p.expect_fail("main.spc", "does not satisfy a bound the callee's reflection loop requires");
    // A cycle that wraps the type argument once per turn hands up a new bound on every pass: the
    // limit on a module's bounds ends the passes with an error.
    let p2 = cli::proj_new();
    p2.mkfile(
        "m1.spc",
        M"(import m2;
pub struct W<T> { pub a: i32, }
pub fn w1<T>(v: &T, n: i32) i64 { let _ = v; if n > 0 { let w = W::<T> { a: 1 }; return m2::w2(&w, n - 1); } return 0; }
)",
    );
    p2.mkfile(
        "m2.spc",
        M"(import m1;
pub interface Pretty { fn m(self: &Self) i64; }
extend i32 as Pretty { pub fn m(self: &i32) i64 { return *self; } }
pub fn render<V: Pretty>(v: &V) i64 { return v.m(); }
pub fn w2<T>(v: &T, n: i32) i64 { let mut s: i64 = m1::w1(v, n); inline for f in fields(v) { s += render(&f.value); } return s; }
)",
    );
    p2.mkfile(
        "main.spc",
        M"(import m1;
struct Good { pub a: i32, }
fn main() i32 { let g = Good { a: 1 }; let _ = m1::w1(&g, 1); return 0; }
)",
    );
    p2.expect_fail("main.spc", "a generic function reaches itself with a growing type argument");
}

@test
fn growing_instantiation_is_reported() {
    // Without reflection: a generic function or type that reaches itself with a growing type
    // argument is refused once the instantiations nest past the bound, never by exhausting the stack.
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct W<T> { pub v: T }
fn f<T>(x: T, n: i32) i32 { if n > 0 { return f::<W<T>>(W::<T> { v: x }, n - 1); } return n; }
fn main() i32 { return f::<i32>(1, 3); }
)",
    );
    p.expect_fail("main.spc", "generic instantiation nests deeper than 256 levels");
    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        M"(struct W<T> { pub v: T, pub n: Option<Box<W<W<T>>>> }
fn main() i32 { let w = W::<i32> { v: 1, n: Option::<Box<W<W<i32>>>>::None }; return w.v - 1; }
)",
    );
    // The chain is refused inside std's Option/Box bodies, but the error names the user's type.
    let rq = q.compile("main.spc");
    assert(rq.exit != 0, "the growing type fails the build");
    assert(rq.out_has("generic instantiation nests deeper than 256 levels"), "the depth error is reported");
    assert(rq.out_has("main.spc:1:10"), "the error is located at the user's type parameter");
    assert(!rq.out_has("option.spc"), "the error is not located in std");
}

@test
fn reflect_enum_variants() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(enum Shape { Dot, Line(i64), Label(str), Pair(i32, i32), }
fn main() i32 {
  let a = Shape::Dot;
  let b = Shape::Line(42);
  let c = Shape::Label("hi");
  let d = Shape::Pair(1, 2);
  let sa = reflect_variant_string(&a);
  let sb = reflect_variant_string(&b);
  let sc = reflect_variant_string(&c);
  let sd = reflect_variant_string(&d);
  print("{} {} {} {}\n", sa.as_str(), sb.as_str(), sc.as_str(), sd.as_str());
  let ok = sa.as_str() == "Dot" && sb.as_str() == "Line(42)" && sc.as_str() == "Label(hi)" && sd.as_str() == "Pair(1, 2)";

  if !ok { return 1; }
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("Dot Line(42) Label(hi) Pair(1, 2)"), "active-variant reflection across payload shapes");
}

@test
fn reflect_derives() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Point { pub x: i32, pub y: u8, }
struct Nested { pub p: Point, pub n: i64, }
extend Point as Format { pub fn fmt(self: &Point) String { return reflect_string(self); } }
extend Point as Hash {}
extend Nested as Hash {}
fn main() i32 {
  let p = Point { x: 7, y: 3 };
  let s = reflect_string(&p);
  let ok = s.as_str() == "Point { x: 7, y: 3 }";
  s.free();
  if !ok { return 1; }
  let nv = Nested { p: Point { x: 1, y: 2 }, n: 9 };
  let s2 = reflect_string(&nv);
  print("{}\n", s2.as_str());
  let ok2 = s2.as_str() == "Nested { p: Point { x: 1, y: 2 }, n: 9 }";
  s2.free();
  if !ok2 { return 2; }
  let q = Point { x: 7, y: 3 };
  let r = Point { x: 7, y: 4 };
  if hash(&p) != hash(&q) { return 3; }
  if hash(&p) == hash(&r) { return 4; }
  if hash(&nv) == 0 { return 5; }
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("Nested { p: Point { x: 1, y: 2 }, n: 9 }"), "derives compose through conformances");
}

@test
fn derive_and_interface_defaults() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        M"(pub interface Pretty {
  fn pp(self: &Self) String { return reflect_string(self); }
}
@derive(Format, Hash)
pub struct Point { pub x: i32, pub y: i32, }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import lib;
@derive(Format, Hash)
enum Shape { Dot, Line(i32), Pair(i32, i64), }
@derive(Format, lib::Pretty)
struct Duo<A: Format, B: Format> { pub a: A, pub b: B, }
fn main() i32 {
  let p = lib::Point { x: 1, y: 2 };
  let s = p.fmt();
  let ok = s.as_str() == "Point { x: 1, y: 2 }";
  s.free();
  if !ok { return 1; }
  let d = Shape::Dot;
  let l = Shape::Line(42);
  let l2 = Shape::Line(42);
  let l3 = Shape::Line(43);
  let pr = Shape::Pair(3, 4);
  let sv = pr.fmt();
  let ok2 = sv.as_str() == "Pair(3, 4)";
  sv.free();
  if !ok2 { return 2; }
  let sd = d.fmt();
  let ok3 = sd.as_str() == "Dot";
  sd.free();
  if !ok3 { return 3; }
  if hash(&l) != hash(&l2) { return 4; }
  if hash(&l) == hash(&l3) { return 5; }
  if hash(&d) == hash(&pr) { return 6; }
  let q = Duo::<i32, str> { a: 7, b: "hi" };
  let qs = q.fmt();
  let qp = q.pp();
  let ok4 = qs.as_str() == "Duo { a: 7, b: hi }" && qp.as_str() == qs.as_str();
  qs.free();
  qp.free();
  if !ok4 { return 7; }
  let p2 = lib::Point { x: 1, y: 2 };
  if hash(&p) != hash(&p2) { return 8; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "@derive conformances inherit the reflection defaults across modules");

    // A field that lacks the required bound names itself at the conformance, not in the emitted C.
    let bad = cli::proj_new();
    bad.mkfile(
        "main.spc",
        M"(struct NoFmt { pub p: *const u8, }
@derive(Format)
struct Bad { pub a: i32, pub b: NoFmt, }
fn main() i32 { let b = Bad { a: 1, b: NoFmt { p: null } }; let s = b.fmt(); s.free(); return 0; }
)",
    );
    let br = bad.compile("main.spc");
    assert(br.exit != 0, "unsatisfied derived bound rejects the build");
    assert(br.out_has("does not satisfy a bound required by the interface's default method 'fmt'"));
    assert(br.out_has("field 'b' of 'Bad' is 'NoFmt'"), "the offending field names itself");
}

// The per-field bound check reads a tuple struct's member types in the struct's own module: a
// conformance declared in another module still sees the member that lacks the bound.
@test
fn derived_bound_checks_foreign_tuple_members() {
    let p = cli::proj_new();
    p.mkfile("lib.spc", "pub struct NoFmt {\n    pub p: *const u8,\n}\n\npub struct Pair(i32, NoFmt);\n");
    p.mkfile("main.spc", "import lib;\n\nextend lib::Pair as Format {}\n\nfn main() i32 {\n    return 0;\n}\n");
    let r = p.compile("main.spc");
    assert(r.exit != 0, "the unsatisfied bound rejects the build");
    assert(r.out_has("does not satisfy a bound required by the interface's default method 'fmt'"));
    assert(r.out_has("field 1 of 'Pair' is 'NoFmt'"), "the offending member names itself");
}

// A generic alias of another module expands in the importer's positions, and an importer's alias over
// it nests one level deeper.
@test
fn generic_alias_across_modules() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        M"(pub struct Pair<A, B> { pub a: A, pub b: B }
pub type Q1<T> = Pair<T, T>;
pub type Q2<T> = Q1<Q1<T>>;
pub fn mk(x: i32) Q2<i32> {
    return Pair::<Q1<i32>, Q1<i32>> { a: Pair::<i32, i32> { a: x, b: 2 }, b: Pair::<i32, i32> { a: 3, b: 4 } };
}
pub fn mk2() Q2<Q1<u8>> {
    let p = Pair::<u8, u8> { a: 1u8, b: 2u8 };
    let q = Pair::<Q1<u8>, Q1<u8>> { a: p, b: p };
    return Pair::<Q2<u8>, Q2<u8>> { a: q, b: q };
}
)",
    );
    p.mkfile(
        "main.spc",
        M"(import lib;
extern "C" { fn exit(code: i32) void; }
type Q3<T> = lib::Q2<lib::Q1<T>>;
struct W { pub q: lib::Q2<i64> }
fn get<U: Copy>(q: lib::Q2<U>) U { return q.b.a; }
fn main() i32 {
    let q: lib::Q2<i32> = lib::mk(1);
    let w = W { q: lib::Pair::<lib::Q1<i64>, lib::Q1<i64>> { a: lib::Pair::<i64, i64> { a: 5, b: 6 }, b: lib::Pair::<i64, i64> { a: 7, b: 8 } } };
    let z: Q3<u8> = lib::mk2();
    unsafe exit(q.a.a + get(q) + w.q.b.a as i32 + get(w.q) as i32 + z.b.a.b as i32); return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.cc_build("").ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 1 + 3 + 7 + 7 + 2);
}

@test
fn format_args_via_conformance() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("lib.spc", M"(@derive(Format, Hash)
pub struct Point { pub x: i32, pub y: i32, }
)");
    p.mkfile(
        "main.spc",
        M"(import lib;
@derive(Format)
enum Shape { Dot, Pair(i32, i64), }
@derive(Format)
struct Duo<A: Format, B: Format> { pub a: A, pub b: B, }
fn mk() lib::Point { return lib::Point { x: 9, y: 8 }; }
fn show(v: &dyn Format) String { return v.fmt(); }
const fn ph() u64 { let p = lib::Point { x: 1, y: 2 }; return hash(&p); }
static_assert(ph() != 0, "derived hash folds at compile time");
fn main() i32 {
  let p = lib::Point { x: 1, y: 2 };
  print("{}\n", p);
  let r = &p;
  print("ref {}\n", r);
  print("rv {}\n", mk());
  let s = Shape::Pair(3, 4);
  print("{} {}\n", s, Shape::Dot);
  let d = Duo::<i32, str> { a: 7, b: "hi" };
  print("{}\n", d);
  let m = format("in format: {}", p);
  print("{}\n", m.as_str());
  m.free();
  print("{:>24}\n", p);
  let ds = show(&p);
  print("dyn {}\n", ds.as_str());
  ds.free();
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("Point { x: 1, y: 2 }"), "a conforming value formats through its own fmt");
    assert(rr.out_shows("ref Point { x: 1, y: 2 }"), "references format as their pointee");
    assert(rr.out_shows("rv Point { x: 9, y: 8 }"), "an rvalue is materialized and freed");
    assert(rr.out_shows("Pair(3, 4) Dot"), "derived enums format directly");
    assert(rr.out_shows("Duo { a: 7, b: hi }"), "generic instances format directly");
    assert(rr.out_shows("in format: Point { x: 1, y: 2 }"), "format() takes conforming values too");
    assert(rr.out_shows("    Point { x: 1, y: 2 }"), "width padding applies to the rendered form");
    assert(rr.out_shows("dyn Point { x: 1, y: 2 }"), "dyn dispatch reaches the inherited default");
}

@test
fn reflect_metadata() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    // Instance-symbol assertions pin the NON-inlined emission.
    let _env1 = cli::set_env("SC_INLINE", "0");
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@reflect(entity, version = 3)
struct Player {
  @reflect(render, label = "Speed", max = 100)
  pub speed: i32,
  pub internal: i64,
  @reflect(render)
  pub hp: u8,
}
@reflect(entity)
enum Mode { Off, @reflect(hidden)
On, }
fn touch<V>(x: &V) usize { let _ = x; return sizeof(V); }
fn render_all<T>(v: &T) i64 {
  let mut acc: i64 = 0;
  inline for f in fields(v) {
    if f.has_meta("render") {
      acc = acc + f.meta_int("max") + f.meta_str("label").len() as i64 + touch(&f.value) as i64;
    }
  }
  return acc;
}
const fn cfold() i64 {
  let p = Player { speed: 1, internal: 2, hp: 3 };
  return render_all(&p);
}
static_assert(cfold() == 110, "meta binder reads fold in CTFE");
const fn cmeta() bool {
  let ti = type_info::<Player>();
  if !ti.has_meta("entity") { return false; }
  switch ti.fields.get(0).meta("label") {
    Some(m) => { return m.kind == MetaKind::Str && m.s == "Speed"; },
    None => { return false; },
  };
}
static_assert(cmeta(), "descriptor metadata folds in CTFE");
extern "C" {
    fn __sc_reflect_types(n: *mut usize) *const *const void;
}
fn main() i32 {
  let p = Player { speed: 1, internal: 2, hp: 3 };
  if render_all(&p) != 110 { return 1; }
  let ti = type_info::<Player>();
  switch ti.fields.get(0).meta("max") {
    Some(m) => { if m.kind != MetaKind::Int || m.i != 100 { return 2; } },
    None => { return 3; },
  };
  if ti.fields.get(1).has_meta("render") { return 4; }
  let tm = type_info::<Mode>();
  switch tm.variant("On") {
    Some(v) => { if !v.has_meta("hidden") { return 5; } },
    None => { return 6; },
  };
  let mut n: usize = 0;
  let arr = unsafe __sc_reflect_types(&mut n);
  if n != 2 { return 7; }
  let mut entities: usize = 0;
  for i in 0..n {
    let t = unsafe &*((unsafe arr[i]) as *const TypeInfo);
    if t.has_meta("entity") { entities = entities + 1; }
  }
  if entities != 2 { return 8; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main__inst.c", "touch__i32("), "the tagged copies call their callee");
    assert(!p.gen_has("main__inst.c", "touch__i64("), "the untagged copy's call is never emitted");
    assert(p.gen_has("main__inst.c", "sc_typeinfo_Player"), "the tagged type exports its descriptor");
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "metadata reads, folding, and the registry all agree");
}

@test
fn std_reflection_defaults() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("lib.spc", M"(@derive(Eq, Hash, Format)
pub struct Key { pub a: i32, pub b: u8, }
)");
    p.mkfile(
        "main.spc",
        M"(import lib;
@derive(Eq, Ord, Clone, Default)
struct Point { pub x: i32, pub y: i32, }
@derive(Eq, Ord)
enum Shape { Dot, Line(i32), Pair(i32, i64), }
@derive(Eq, Clone, Default)
struct Bag { pub v: Vector<i32>, pub n: i32, }
fn main() i32 {
  let a = Point { x: 1, y: 2 };
  let b = Point { x: 1, y: 2 };
  let c = Point { x: 1, y: 3 };
  if !a.eq(&b) || a.eq(&c) || !a.ne(&c) { return 1; }
  if a == c || !(a == b) || !(a < c) || c < a { return 2; }
  if a.cmp(&b) != 0 || a.cmp(&c) >= 0 || c.cmp(&a) <= 0 { return 3; }
  let d = Point::default();
  if d.x != 0 || d.y != 0 { return 4; }
  let e = a.clone();
  if !e.eq(&a) { return 5; }
  let s1 = Shape::Line(42);
  let s2 = Shape::Line(42);
  let s3 = Shape::Line(43);
  let s4 = Shape::Pair(1, 2);
  if !s1.eq(&s2) || s1.eq(&s3) || s1.eq(&s4) { return 6; }
  if !(s1 == s2) || s1 == s3 { return 7; }
  if s1.cmp(&s2) != 0 || s1.cmp(&s3) >= 0 || s4.cmp(&s1) <= 0 { return 8; }
  let mut bag = Bag::default();
  bag.v.push(9);
  bag.n = 5;
  let bag2 = bag.clone();
  if !bag2.eq(&bag) || bag2.v.len() != 1 { return 9; }
  let mut m = Map::<lib::Key, i64>::new();
  m.insert(lib::Key { a: 1, b: 2 }, 10);
  let hit = lib::Key { a: 1, b: 2 };
  let miss = lib::Key { a: 1, b: 9 };
  switch m.get(&hit) {
    Some(v) => { if *v != 10 { return 10; } },
    None => { return 11; },
  };
  if m.get(&miss).is_some() { return 12; }
  print("{}\n", hit);
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("Key { a: 1, b: 2 }"), "a derived cross-module key formats through {}");
    assert(rr.out_shows("ok"), "Eq/Ord/Clone/Default derive through the std interface defaults");
}

@test
fn paired_reflection_and_construction() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct P { pub x: i32, pub v: Vector<i32>, }
enum E { A, B(i32), C(i32, i64), }
enum Color { Red = 3, Green = 7, }
fn eqf<V: Eq>(a: &V, b: &V) bool { return a.eq(b); }
fn cmpf<V: Ord>(a: &V, b: &V) i32 { return a.cmp(b); }
fn setc<V: Clone>(dst: &mut V, src: &V) { *dst = src.clone(); }
fn setd<V: Default>(dst: &mut V) { *dst = V::default(); }
fn req<T>(a: &T, b: &T) bool {
  inline for f in fields(a, b) { if !eqf(&f.value, &f.other) { return false; } }
  return true;
}
fn rcmp<T>(a: &T, b: &T) i32 {
  inline for f in fields(a, b) { let c = cmpf(&f.value, &f.other); if c != 0 { return c; } }
  return 0;
}
fn rclone<T>(src: &T) T {
  let mut out = unsafe zeroed::<T>();
  inline for f in fields(&mut out, src) { setc(&mut f.value, &f.other); }
  return out;
}
fn rdefault<T>() T {
  let mut out = unsafe zeroed::<T>();
  inline for f in fields(&mut out) { setd(&mut f.value); }
  return out;
}
fn veq<T>(a: &T, b: &T) bool {
  let mut r = true;
  inline for v in variants(a, b) {
    if v.is_active {
      if !v.other_active { r = false; }
      else { inline for pp in payloads(v) { if !eqf(&pp.value, &pp.other) { r = false; } } }
    }
  }
  return r;
}
fn vtag<T>(e: &T) i32 {
  let mut t: i32 = 0;
  inline for v in variants(e) { if v.is_active { t = v.tag; } }
  return t;
}
const fn creq() bool {
  let a = P2 { x: 4, y: 5 };
  let b = P2 { x: 4, y: 5 };
  return req(&a, &b);
}
struct P2 { pub x: i32, pub y: i64, }
static_assert(creq(), "paired fields fold at compile time");
fn main() i32 {
  let mut va = Vector::<i32>::new();
  va.push(1);
  let mut vb = Vector::<i32>::new();
  vb.push(1);
  let a = P { x: 9, v: va };
  let b = P { x: 9, v: vb };
  if !req(&a, &b) { return 1; }
  let c = rclone(&a);
  if !req(&c, &a) { return 2; }
  if c.v.len() != 1 { return 3; }
  let d = rdefault::<P>();
  if d.x != 0 || d.v.len() != 0 { return 4; }
  let p1 = P2 { x: 1, y: 2 };
  let p2 = P2 { x: 1, y: 3 };
  if rcmp(&p1, &p2) >= 0 { return 5; }
  if rcmp(&p2, &p1) <= 0 { return 6; }
  if rcmp(&p1, &p1) != 0 { return 7; }
  let ea = E::C(1, 2);
  let eb = E::C(1, 2);
  let ec = E::C(1, 3);
  let ed = E::B(1);
  if !veq(&ea, &eb) { return 8; }
  if veq(&ea, &ec) { return 9; }
  if veq(&ea, &ed) { return 10; }
  let ca = Color::Red;
  let cb = Color::Red;
  let cc = Color::Green;
  if !veq(&ca, &cb) { return 11; }
  if veq(&ca, &cc) { return 12; }
  if vtag(&cc) != 7 { return 13; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "paired binders, zeroed construction, and tagless enums all behave");
}

@test
fn fields_projection_extended() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        M"(pub interface Pretty { fn pretty(self: &Self) i64; }
extend i32 as Pretty { pub fn pretty(self: &i32) i64 { return (*self) as i64 + 0; } }
pub fn render<V: Pretty>(v: &V) i64 { return v.pretty(); }
pub fn dump_all<T>(v: &T) i64 {
  let mut s: i64 = 0;
  inline for f in fields(v) { s += render(&f.value); }
  return s;
}
)",
    );
    p.mkfile(
        "main.spc",
        M"(import lib;
import string as cstr;
struct A { pub x: i32, pub y: u8, }
struct B { pub s: i64, pub t: bool, }
fn zero_into<V>(dst: &mut V) { unsafe cstr::memset(dst as *mut V, 0, sizeof(V)); }
fn clear_all<T>(v: &mut T) {
  inline for f in fields(v) { zero_into(&mut f.value); }
}
fn pairw<U, V>(u: &U, v: &V) usize { let _ = u; let _ = v; return sizeof(U) * 100 + sizeof(V); }
fn cross<T1, T2>(a: &T1, b: &T2) usize {
  let mut s: usize = 0;
  inline for f in fields(a) { inline for g in fields(b) { s += pairw(&f.value, &g.value); } }
  return s;
}
const fn cfields() usize {
  let a = A { x: 1, y: 2 };
  let mut n: usize = 0;
  inline for f in fields(&a) { n += f.name.len(); }
  return n;
}
static_assert(cfields() == 2, "ctfe fields");
struct OnlyInt { pub v: i32, }
fn main() i32 {
  let mut a = A { x: 7, y: 3 };
  clear_all(&mut a);
  if a.x != 0 || a.y != 0 { return 1; }
  let a2 = A { x: 1, y: 2 };
  let b = B { s: 3, t: true };
  if cross(&a2, &b) != 1018 { return 2; }
  let oi = OnlyInt { v: 9 };
  if lib::dump_all(&oi) != 9 { return 3; }
  print("extended ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("extended ok"), "mut projections, cross product, CTFE, and cross-module all hold");
}

@test
fn fields_projection_serializer() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let _env2 = cli::set_env("SC_INLINE", "0");
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Inner { pub a: u16, }
struct Mixed { pub p: Inner, pub q: i64, pub r: bool, }
fn width<V>(v: &V) usize { let _ = v; return sizeof(V); }
fn dump<T>(v: &T) usize {
  let mut s: usize = 0;
  inline for f in fields(v) {
    print("[{}]{}:{} ", f.index, f.name, width(&f.value));
    s += width(&f.value);
  }
  print("\n");
  return s;
}
fn main() i32 {
  let m = Mixed { p: Inner { a: 1 }, q: 2, r: true };
  if dump(&m) != sizeof(Inner) + 9 { return 1; }
  let i = Inner { a: 3 };
  if dump(&i) != 2 { return 2; }
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main__inst.c", "width__i64"), "the projection fanned out to each field type");
    assert(p.gen_has("main__inst.c", "width__bool"), "including the last field");
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("[1]q:8"), "names, indices, and per-field types line up");
}

@test
fn type_info_reflection() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Point { pub x: i32, pub y: u8, }
enum Color { Red, Green, Blue = 7, }
fn kindof<T>() TypeTag { return type_info::<T>().kind; }
const TI: TypeInfo = type_info::<Point>();
static_assert(TI.size == 8, "point size");
fn main() i32 {
  if TI.fields.len != 2 { return 1; }
  let f1 = TI.fields.get(1);
  if f1.offset != 4 || f1.size != 1 { return 2; }
  print("{}.{}\n", TI.name, f1.name);
  let ci = type_info::<Color>();
  if ci.variants.len != 3 || ci.variants.get(2).tag != 7 { return 3; }
  print("{}={}\n", ci.variants.get(2).name, ci.variants.get(2).tag);
  if kindof::<Color>() != TypeTag::Enum { return 4; }
  if kindof::<[]u8>() != TypeTag::Slice { return 5; }
  if kindof::<*const i32>() != TypeTag::Pointer { return 6; }
  if kindof::<str>() != TypeTag::Str { return 7; }
  if kindof::<(i32, bool)>() != TypeTag::Tuple { return 8; }
  switch TI.field("x") {
    Some(f) => { if f.kind != TypeTag::Int { return 9; } },
    None => { return 10; },
  };
  switch type_info::<Shape>().variant("Line") {
    Some(v) => { if v.payload != 2 { return 11; } },
    None => { return 12; },
  };
  switch ci.variant_by_tag(7) {
    Some(v) => { print("tag7={}\n", v.name); },
    None => { return 13; },
  };
  let ai = type_info::<[u16; 4]>();
  if ai.len != 4 || ai.elem != TypeTag::Uint { return 14; }
  return 0;
}
enum Shape { Dot, Line(i32, i32), }
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main__inst.c", "TypeInfo TI"), "the const descriptor materialized as static data");
    assert(p.gen_has("main.c", "__sc_ti"), "a runtime call site emitted its block-scope descriptor");
    let cc = p.cc_build("");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("Point.y"), "struct and field names are readable at runtime");
    assert(rr.out_shows("Blue=7"), "variant names carry their declared tag");
    assert(rr.out_shows("tag7=Blue"), "variant_by_tag reverses a declared value");
}

// A `const fn` call whose arguments are constant runs at compile time and its value replaces it: an
// integer, a `bool`, a float, a `str`, a bare enum, or a struct, tuple struct or array of them
// (nested calls and a method of a literal too); a call whose evaluation fails stays a run-time call,
// and a folded call still may not move an owning constant.
const CONST_FOLD: str = M"(const fn square(x: i64) i64 { return x * x; }
const fn greet(n: u32) str<'static> { return if n > 1 { "many\t\u{e9}"; } else { "one"; }; }
const fn half(x: f64) f64 { return x / 2.0; }
const fn third(x: f32) f32 { return x / 3.0; }
const fn tri(n: u64) u64 { let mut s: u64 = 0; for i in 0..n + 1 { s += i; } return s; }
const fn even(n: u32) bool { return n % 2 == 0; }
const fn div(a: i32, b: i32) i32 { return a / b; }
fn add(a: i64, b: i64) i64 { return a + b; }
struct P { pub x: i32, pub y: f64, pub name: str<'static> }
struct Pair(u8, bool);
enum Color { Red = 3, Green = 7, Blue }
struct Wrap<T> { pub v: T, pub n: [u16; 3] }
const fn make(k: i32) P { return P { x: k * 2, y: 0.5, name: "pt" }; }
const fn pair() Pair { return Pair(9, true); }
const fn color(n: i32) Color { return if n > 0 { Color::Green; } else { Color::Blue; }; }
const fn table() [u32; 4] { let mut t: [u32; 4] = [0; 4]; for i in 0..4 { unsafe t[i] = (i * i) as u32; } return t; }
const fn wrap() Wrap<i64> { return Wrap::<i64> { v: -5, n: [1, 2, 3] }; }
fn main(argv: Vector<str>) i32 {
    let p = make(21);
    let q = pair();
    let c = color(1);
    let tb = table();
    let wr = wrap();
    if p.x != 42 || p.y != 0.5 || p.name.len() != 2 || q.0 != 9 || !q.1 || c != Color::Green || color(-1) != Color::Blue || tb[3] != 9 || wr.v != -5 || wr.n[2] != 3 {
        return 3;
    }
    let x = square(12);
    let g = greet(3);
    let h = half(5.0);
    let t = tri(100);
    let w = add(square(3), 4);
    let n = "abcd".len();
    if x != 144 || g.len() != 7 || h != 2.5 || third(1.0) != 1.0f32 / 3.0f32 || t != 5050 || w != 13 || n != 4 || !even(10) {
        return 1;
    }
    // Run-time arguments keep the call; a trapping evaluation keeps it too.
    if square(argv.len() as i64) != 1 {
        return 2;
    }
    if argv.len() > 5 {
        return div(1, 0);
    }
    return 0;
}
)";

@test
fn const_fn_calls_fold() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let _env = cli::set_env("SC_INLINE", "0");
    let p = cli::proj_new();
    p.mkfile("main.spc", CONST_FOLD);
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("main.c", "int64_t x = 144LL;"), "an integer result folds");
    assert(p.gen_has("main.c", M"("many\t\303\251")"), "a str result folds to its bytes");
    assert(p.gen_has("main.c", "double h = (0x1.4000000000000p1);"), "a float result folds to its exact bits");
    assert(p.gen_has("main.c", "uint64_t t = 5050ULL;"), "a loop folds");
    assert(p.gen_has("main.c", "add(9LL, 4LL)"), "an argument folds inside a run-time call");
    assert(p.gen_has("main.c", "size_t n = 4ULL;"), "a method of a literal folds");
    assert(p.gen_has("main.c", "square("), "a run-time argument keeps the call");
    assert(p.gen_has("main.c", "div_(1LL, 0LL)"), "a trapping evaluation keeps the call");
    assert(
        p.gen_has("main.c", "P p = (P){ .x = 42LL, .y = (0x1.0000000000000p-1), .name = (str){ (const uint8_t *)\"pt\""),
        "a struct result folds",
    );
    assert(p.gen_has("main.c", "Pair q = (Pair){ ._0 = 9U, ._1 = true };"), "a tuple struct result folds");
    assert(p.gen_has("main.c", "Color c = Color_Green;"), "an enum result folds to its variant");
    assert(p.gen_has("main.c", "uint32_t tb[4] = { 0U, 1U, 4U, 9U };"), "an array result folds");
    assert(p.gen_has("main.c", "(Wrap__i64){ .v = -5LL }"), "a generic struct result folds");
    assert(p.cc_build("").ok(), "the C compiler builds it");
    assert_eq(p.run_bin(), 0);
    // The native backend folds the same calls.
    let nb = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(nb.ok(), "the native build");
    assert_eq(p.run_bin(), 0);
    // A signaling NaN result keeps its bits, in C and natively.
    p.mkfile(
        "main.spc",
        "import std::mem::ptr;\nconst fn snan32() f32 { return ptr::bit_cast::<f32, u32>(0x7F800123); }\nconst fn snan64() f64 { return ptr::bit_cast::<f64, u64>(0x7FF0000000000123); }\nfn main() i32 {\n    let s32 = snan32();\n    let s64 = snan64();\n    return (ptr::bit_cast::<u32, f32>(s32) != 0x7F800123 || ptr::bit_cast::<u64, f64>(s64) != 0x7FF0000000000123) as i32;\n}\n",
    );
    assert(p.compile("main.spc").ok() && p.gen_has("main.c", "__builtin_nans"), "a signaling NaN in C");
    assert(p.cc_build("").ok(), "the C compiler builds it");
    assert_eq(p.run_bin(), 0);
    assert(cli::superc_in(p.dir(), "build main.spc -o bin").ok(), "the native build");
    assert_eq(p.run_bin(), 0);
    // A folded call's argument is still consumed: an owning constant moves into none.
    p.mkfile(
        "main.spc",
        "const S: String = String::from_str(\"ab\");\nconst fn size(s: String) usize { return s.len(); }\nfn main() i32 { return size(S) as i32; }\n",
    );
    let m = p.compile("main.spc");
    assert(
        m.exit != 0 && m.out_has("cannot move a value out of a 'const' binding"),
        "the move out of the constant is an error",
    );
}

// Compile-time evaluation in constant contexts (recursion, loops, switch, floats), run-time calls of
// plain functions outside them, and the step budget.
@test
fn ctfe() {
    let _env3 = cli::set_env("SC_INLINE", "0");
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(extern "C" { fn rand() i32; }
fn fib(n: i32) i32 {
  if n < 2 { return n; }
  return fib(n - 1) + fib(n - 2);
}
fn collatz(mut n: u64) i32 {
  let mut c = 0;
  while n != 1 { n = switch n % 2 { 0 => n / 2, _ => 3 * n + 1 }; c += 1; }
  return c;
}
fn half(x: f64) f64 { return x / 2.0; }
fn late() i32 { return unsafe rand(); }
static_assert(fib(20) == 6_765, "ctfe");
static_assert(collatz(27) == 111, "loops fold");
static_assert(half(3.0) == 1.5, "floats fold");
fn main() i32 {
  fib(9);
  let x = fib(10) - 47;
  if late() < 0 { return 1; }
  return x;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", M"(_Static_assert(true, "ctfe"))"), "fib(20) ran at compile time");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "loops fold"))"), "collatz(27) ran at compile time");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "floats fold"))"), "float CTFE ran at compile time");
    assert(p.gen_has("main.c", "fib(10"), "a plain function's call outside a constant context runs at run time");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 8);

    // --const-eval-steps starves a loop-driven assert -> reports the budget.
    p.mkfile(
        "main.spc",
        M"(fn burn() i32 { let mut i = 0; while i < 1_000_000 { i += 1; } return i; }
static_assert(burn() == 1_000_000, "needs execution");
fn main() i32 { return 0; }
)",
    );
    let b = p.compile_flags("--const-eval-steps=4096", "main.spc");
    assert(b.exit != 0, "a starved assert fails the build");
    assert(b.out_has("step budget exceeded"), "and blames the budget");

    // The (fn, args) call memo folds fib(40) comfortably inside a 100k-step budget.
    p.mkfile(
        "main.spc",
        M"(fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }
static_assert(fib(40) == 102_334_155, "memoized");
fn main() i32 { return 0; }
)",
    );
    let m = p.compile_flags("--const-eval-steps=100000", "main.spc");
    assert(m.ok());
    assert(p.gen_has("main.c", M"(_Static_assert(true, "memoized"))"), "the call cache collapsed the recursion");

    // Matchertext literals are CTFE-visible (verbatim content with an interior quote folds like any literal).
    p.mkfile(
        "main.spc",
        M"(const G: str = M"[say "hi"]";
static_assert(G.len() == 8, "raw folds");
fn main() i32 { return 0; }
)",
    );
    let rw = p.compile("main.spc");
    assert(rw.ok(), "the program compiles");
    assert(
        p.gen_has("main.c", M"(_Static_assert(true, "raw folds"))"),
        "matchertext literal len folded at compile time",
    );
}

// A call's frame, its temporaries and every freed heap block return to the memory budget, so the
// budget, not a count of calls or objects, limits an evaluation.
@test
fn ctfe_memory_budget_is_the_only_limit() {
    let p = cli::proj_new();
    let calls = M"(const fn inc(x: u64) u64 { return x + 1; }
const fn count(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s = inc(s); i += 1; }
    return s;
}
const A: u64 = count(100000);
fn main() i32 { return (A % 7) as i32; }
)";
    h::expect_ok("100000 calls fold", calls);
    p.mkfile("calls.spc", calls);
    let cs = p.compile_flags("--const-eval-memory=16K", "calls.spc");
    assert(cs.ok(), "the frames of returned calls leave a 16 KiB budget");
    h::expect_ok(
        "70000 live objects fold inside the budget",
        M"(struct Pair { pub a: u32, pub b: u32 }
const fn pairs() u32 {
    let ps: [Pair; 70000] = [Pair { a: 1, b: 2 }; 70000];
    return ps[69999].a + ps[3].b;
}
const N: u32 = pairs();
fn main() i32 { return N as i32; }
)",
    );
    p.mkfile(
        "heap.spc",
        M"(extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
const fn block(n: usize) u64 {
    let p = unsafe malloc(n * 8) as *mut u64;
    unsafe p[n - 1] = 5;
    let v = unsafe p[n - 1];
    unsafe free(p);
    return v;
}
const fn blocks() u64 {
    let mut s: u64 = 0;
    for i in 0..20usize { s += block(100000 + i); }
    return s;
}
const H: u64 = blocks();
fn main() i32 { return (H % 7) as i32; }
)",
    );
    let h = p.compile_flags("--const-eval-memory=4M", "heap.spc");
    assert(h.ok(), "freed heap blocks return to the budget");
    p.mkfile(
        "big.spc",
        M"(extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
const fn block(n: usize) u64 {
    let p = unsafe malloc(n * 8) as *mut u64;
    unsafe p[n - 1] = 5;
    let v = unsafe p[n - 1];
    unsafe free(p);
    return v;
}
const B: u64 = block(4000000);
fn main() i32 { return B as i32; }
)",
    );
    // A slot holds one 24-byte value: 96 MiB holds the 4000000 elements, 72 MiB does not.
    let b96 = p.compile_flags("--const-eval-memory=96M", "big.spc");
    assert(b96.ok(), "--const-eval-memory=96M is 96 MiB");
    let b72 = p.compile_flags("--const-eval-memory=72M", "big.spc");
    assert(b72.exit != 0, "a block past the budget fails");
    assert(
        b72.out_shows("constant 'B' cannot be evaluated at compile time: const-eval memory budget exceeded"),
        "and names the budget",
    );
}

// A constant's result does not depend on the constants evaluated before it: the call memo lives for
// one evaluation, and a referenced constant evaluates under its own budget.
@test
fn ctfe_constant_result_is_independent_of_order() {
    let p = cli::proj_new();
    let spins = M"(const fn spin(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s += i; i += 1; }
    return s;
}
const fn spin2(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s += i; i += 1; }
    return s;
}
fn main() i32 { return 0; }
)";
    let q = "const Q: u64 = spin(5000) + spin2(5000);\n";
    let pc = "const P: u64 = spin(5000);\n";
    let why = "constant 'Q' cannot be evaluated at compile time: const-eval step budget exceeded (call stack: spin2; steps: 50001/50000)";
    p.mkfile("alone.spc", format("{}{}", spins, q).as_str());
    p.mkfile("after.spc", format("{}{}{}", spins, pc, q).as_str());
    p.mkfile("before.spc", format("{}{}{}", spins, q, pc).as_str());
    let alone = p.compile_flags("--const-eval-steps=50000", "alone.spc");
    assert(alone.exit != 0, "Q alone fails the build");
    assert(alone.out_shows(why), "Q alone exceeds the step budget");
    let after = p.compile_flags("--const-eval-steps=50000", "after.spc");
    assert(after.exit != 0, "Q after P fails the build");
    assert(after.out_shows(why), "Q after P fails as alone");
    let before = p.compile_flags("--const-eval-steps=50000", "before.spc");
    assert(before.exit != 0, "Q before P fails the build");
    assert(before.out_shows(why), "Q before P fails as alone");
    assert(!after.out_has("constant 'P'"), "P before Q folds");
    assert(!before.out_has("constant 'P'"), "P after Q folds");
    // A referenced constant's steps are its own: B passes before and after A.
    let a = "const A: u64 = spin(5000);\n";
    let b = "const B: u64 = A + spin2(5001);\n";
    p.mkfile("ref_first.spc", format("{}{}{}", spins, b, a).as_str());
    p.mkfile("ref_last.spc", format("{}{}{}", spins, a, b).as_str());
    let rf = p.compile_flags("--const-eval-steps=50000", "ref_first.spc");
    assert(rf.ok(), "B before A folds");
    let rl = p.compile_flags("--const-eval-steps=50000", "ref_last.spc");
    assert(rl.ok(), "B after A folds");
}

// A pointer into a returned call's local is dangling: reading it in a constant is an error.
@test
fn ctfe_pointer_into_a_returned_call_traps() {
    h::expect_err_msg(
        "the dangling read fails the build",
        M"(struct Holder { pub p: *const i32 }
fn keep(h: &mut Holder, x: i32) {
    let v = x + 1;
    h.p = &v;
}
const fn read() i32 {
    let mut h = Holder { p: null };
    keep(&mut h, 4);
    return unsafe *h.p;
}
const D: i32 = read();
fn main() i32 { return D; }
)",
        "constant 'D' cannot be evaluated at compile time: use after return",
    );
}

// CTFE over aggregates and the abstract heap: structs + methods + extend dispatch, local arrays, generics,
// intercepted malloc/free, payload enums through switch, and a std Vector round trip: all interpreted.
// Also: an assert may precede its callee (deferred re-check) and a would-be trap reports its reason.
@test
fn ctfe_memory() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(static_assert(vec_sum() == 44, "deferred: asserts may precede their callee");
struct Pt { x: i32, y: i32 }
extend Pt {
  pub fn mag2(self: &Pt) i32 { return self.x * self.x + self.y * self.y; }
  pub fn shift(self: &mut Pt, dx: i32) { self.x += dx; }
  pub fn make(x: i32, y: i32) Pt { return Pt { x: x, y: y }; }
}
extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
fn structs() i32 {
  let mut p = Pt::make(3, 4);
  p.shift(1);
  let a: [i32; 4] = [[1] = p.mag2(), 1];
  let mut s = 0;
  for v in a { s += v; }
  return s;
}
static_assert(structs() == 33, "aggregates fold");
fn heap() i32 {
  let p = unsafe malloc(2 * sizeof(i64)) as *mut i64;
  unsafe p[0] = 40;
  unsafe p[1] = unsafe p[0] + 2;
  let r = unsafe p[1];
  unsafe free(p);
  return (r as i32);
}
static_assert(heap() == 42, "the abstract heap folds");
fn opt(k: i32) i32 {
  let o = if k > 0 { Option::<i32>::Some(k); } else { Option::<i32>::None; };
  return switch o { Some(v) => v + 1, None => -1, };
}
static_assert(opt(4) == 5 && opt(-4) == -1, "payload enums fold");
fn vec_sum() i32 {
  let mut x = Vector::<i32>::with_capacity(2);
  x.push(7);
  x.push(35);
  let s = x[0] + x[1] + (x.len() as i32);
  return s;
}
fn main() i32 { return structs() + heap() - 75 + vec_sum() - 44; }
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(
        p.gen_has("main.c", M"(_Static_assert(true, "deferred: asserts may precede their callee"))"),
        "assert above its callee folds",
    );
    assert(p.gen_has("main.c", M"(_Static_assert(true, "aggregates fold"))"), "structs/arrays/methods fold");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "the abstract heap folds"))"), "malloc/free fold");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "payload enums fold"))"), "Option + switch folds");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);

    // A would-be runtime trap in a required-const context reports its reason.
    h::expect_err_msg(
        "a trapping assert fails the build",
        M"(fn div0(n: i32) i32 { return 10 / n; }
static_assert(div0(0) == 1, "traps");
fn main() i32 { return 0; }
)",
        "division by zero",
    );

    // Use-after-free is caught by the abstract heap.
    h::expect_err_msg(
        "use-after-free fails the build",
        M"(extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
fn uaf() i32 {
  let p = unsafe malloc(sizeof(i32)) as *mut i32;
  unsafe p[0] = 1;
  unsafe free(p);
  return unsafe p[0];
}
static_assert(uaf() == 1, "uaf");
fn main() i32 { return 0; }
)",
        "use after free",
    );
}

// The last CTFE surface: `?` early return, array->slice coercion, range indexing into a Vector, struct-
// payload variants + struct patterns, &CONST, interface DEFAULT bodies, and Map/Set.
@test
fn ctfe_gaps() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(const K: i32 = 40;
fn check(k: i32) Result<i32, i32> {
  if k < 0 { return Result::<i32, i32>::Err(-1); }
  return Result::<i32, i32>::Ok(k + 1);
}
fn step1(k: i32) Result<i32, i32> {
  let v = check(k)?;
  return Result::<i32, i32>::Ok(v * 2);
}
fn g1(k: i32) i32 { return switch step1(k) { Ok(v) => v, Err(e) => e, }; }
static_assert(g1(20) == 42 && g1(-5) == -1, "try both paths");
fn g2() i32 {
  let a: [i32; 5] = [1, 2, 3, 4, 5];
  let s: []i32 = a;
  let mut x = Vector::<i32>::with_capacity(4);
  x.push(10); x.push(20); x.push(30);
  let w = x[1..3];
  let r = (s.len() as i32) + *s.get(4) + *w.get(0) + *w.get(1) + (w.len() as i32);
  return r;
}
static_assert(g2() == 62, "slices + range indexing");
enum Shape { Dot, Rect { w: i32, h: i32 }, }
fn g3(w: i32, h: i32) i32 {
  let s = Shape::Rect { w: w, h: h };
  let p = &K;
  return switch s { Dot => 0, Rect { w, h } => w * h + *p, };
}
static_assert(g3(6, 7) == 82, "struct patterns + &const");
interface Doubler {
  fn base(self: &Self) i32;
  fn twice(self: &Self) i32 { return self.base() * 2; }
}
struct G { pub v: i32 }
extend G as Doubler { pub fn base(self: &G) i32 { return self.v; } }
fn g4() i32 { let g = G { v: 21 }; return g.twice(); }
static_assert(g4() == 42, "interface default body");
fn g5() i32 {
  let mut m = Map::<i32, i32>::new();
  m.insert(1, 40);
  m.insert(2, 60);
  let v = switch m.get(&1) { Some(x) => *x, None => -1, };
  let mut s = Set::<i32>::new();
  s.insert(7);
  s.insert(7);
  let r = v + (m.len() as i32) + (s.len() as i32);
  return r;
}
static_assert(g5() == 43, "Map and Set fold");
fn main() i32 { return g1(20) - 42 + g2() - 62 + g3(6, 7) - 82 + g4() - 42 + g5() - 43; }
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", M"(_Static_assert(true, "try both paths"))"), "? folds both ways");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "slices + range indexing"))"), "slices fold");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "struct patterns + &const"))"), "struct patterns fold");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "interface default body"))"), "interface defaults fold");
    assert(p.gen_has("main.c", M"(_Static_assert(true, "Map and Set fold"))"), "Map/Set fold");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);
}

// RAII lowering of a reassignment to a binding whose move sits under control flow (a call argument
// inside a loop): the free-before-assign must be guarded by the binding's runtime move flag and the
// flag reset after: an unguarded free double-frees the moved-out buffer (miscompile, not a
// borrow-check error: the source is legal).
@test
fn raii_cond_move_reassign() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn consume(s: String) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    let mut buf = String::from_str(\"seed\");\n    let mut total: usize = 0;\n    for _i in 0..3 {\n        total = total + consume(buf);\n        buf = String::from_str(\"abcd\");\n    }\n    return (total + buf.len()) as i32 - 16;\n}\n",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let lk0 = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(lk0.ok(), "reassign after a loop-conditional move neither leaks nor double-frees");
    assert_eq(p.run_bin(), 0);
}

// Drop-on-assign: `place = v` frees the place's old value for fields and indexes too, not only
// locals: overwriting a live Free field neither leaks nor needs manual glue. The owner-swap idiom
// (`let a = s.f; s.f = fresh;`) still lowers to a bare store (the previous statement moved the
// place out), so no double-free.
@test
fn raii_drop_on_field_assign() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Holder {\n    pub name: String,\n}\n\nextend Holder as Free {\n    pub fn free(self: &mut Holder) {\n        self.name.free();\n    }\n}\n\nfn take_name(h: &mut Holder) String {\n    return replace(&mut h.name, String::new());\n}\n\nfn main() i32 {\n    let mut h = Holder { name: String::from_str(\"first\") };\n    let mut n: usize = 0;\n    for _i in 0..3 {\n        h.name = String::from_str(\"abcdefgh\");\n        n = n + h.name.len();\n    }\n    let taken = take_name(&mut h);\n    n = n + taken.len();\n    return n as i32 - 32;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    // The free is in `main` itself (Holder's own `free` also calls it), and the run passes the
    // harness's fatal leak gate.
    assert(p.gen_fn_has("main.c", "__sc_user_main", "String__free("), "field overwrite frees the old value");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);

    // A field moved out ANYWHERE in the body (even conditionally) guards the assign-free for that
    // place: the take goes through an `unsafe` ref-take (the safe form is rejected: E0507).
    p.mkfile(
        "cond.spc",
        "struct H {\n    pub name: String,\n}\n\nextend H as Free {\n    pub fn free(self: &mut H) {\n        self.name.free();\n    }\n}\n\nfn sink(s: String) usize {\n    return s.len();\n}\n\nfn shuffle(h: &mut H) usize {\n    let mut n: usize = 0;\n    if h.name.len() > 3 {\n        let a = unsafe h.name;\n        n = n + sink(a);\n    }\n    h.name = String::from_str(\"next\");\n    return n + h.name.len();\n}\n\nfn main() i32 {\n    let mut h = H { name: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\") };\n    let n = shuffle(&mut h);\n    return n as i32 - 36;\n}\n",
    );
    let c2 = p.compile("cond.spc");
    assert(c2.ok());
    assert(p.gen_has("cond.c", "{ String__free"), "conditionally-moved field assign-free is flag-guarded");
    let cc2 = p.native_build("", "cond.spc");
    assert(cc2.ok());
    assert_eq(p.run_bin(), 0);

    // Moving a field out of a value implementing Free is REJECTED (Rust's rule): the free body
    // cannot run on a partial value: `replace` is the sanctioned way.
    p.mkfile(
        "condfree.spc",
        "struct G {\n    pub name: String,\n}\n\nextend G as Free {\n    pub fn free(self: &mut G) {\n        self.name.free();\n    }\n}\n\nfn sink(s: String) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    let g = G { name: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\") };\n    let mut n: usize = 0;\n    if g.name.len() > 3 {\n        let a = g.name;\n        n = n + sink(a);\n    }\n    return n as i32 - 32;\n}\n",
    );
    let c3 = p.compile("condfree.spc");
    assert(c3.exit != 0, "field move out of a Free-implementing value is rejected");
    assert(c3.out_has("cannot move a field out of a value implementing Free"));
}

// Validation (SC_BC_VALIDATE) verifies the drop elaboration of the bodies the checker accepts: a
// rejected body has no correct schedule (a field moved out of a `Free` value cannot be released), so
// its diagnostic is reported and nothing aborts.
@test
fn validation_skips_rejected_bodies() {
    let _env4 = cli::set_env("SC_BC_VALIDATE", "1");
    let p = cli::proj_new();
    p.mkfile(
        "condfree.spc",
        "struct G {\n    pub name: String,\n}\n\nextend G as Free {\n    pub fn free(self: &mut G) {\n        self.name.free();\n    }\n}\n\nfn sink(s: String) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    let g = G { name: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\") };\n    let mut n: usize = 0;\n    if g.name.len() > 3 {\n        let a = g.name;\n        n = n + sink(a);\n    }\n    return n as i32 - 32;\n}\n",
    );
    let c = p.compile("condfree.spc");
    assert(c.exit == 1, "the rejected program fails with its diagnostic");
    assert(c.out_has("cannot move a field out of a value implementing Free"));
    assert(!c.out_has("SC_BC_VALIDATE"), "no elaborated body fails verification");
}

// Transpiler-inserted auto-free of untouched fields: a Free impl's body runs, then every owning
// Free-typed field it never referenced is freed by generated glue (early returns covered by the
// A tuple struct's untouched owning members get the same wrapper glue, spelled positionally `_i`.
@test
fn raii_free_glue_tuple_fields() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Pair(String, String);\n\nextend Pair as Free {\n    pub fn free(self: &mut Pair) {\n        self.0.free();\n    }\n}\n\nfn main() i32 {\n    let mut q = Pair(String::from_str(\"abcdefghijklmnopqrstuvwxyz\"), String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\"));\n    return q.0.len() as i32 + q.1.len() as i32 - 58;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "Pair__free__fb("), "partial tuple impl gets the wrapper");
    assert(p.gen_has("main.c", "String__free(&self->_1);"), "untouched tuple member is glue-freed by position");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    // _1 is freed by the glue: no leak under the fatal gate.
    assert(lk.ok());
}

// Wrapper form). Complete impls emit without a wrapper; raw-pointer fields are borrows and exempt.
@test
fn raii_free_glue_untouched_fields() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Pair {\n    pub a: String,\n    pub b: String,\n    pub n: i32,\n    pub peek: *const String,\n}\n\nextend Pair as Free {\n    pub fn free(self: &mut Pair) {\n        self.a.free();\n    }\n}\n\nstruct Whole {\n    pub s: String,\n}\n\nextend Whole as Free {\n    pub fn free(self: &mut Whole) {\n        self.s.free();\n    }\n}\n\nfn main() i32 {\n    let mut q = Pair {\n        a: String::from_str(\"abcdefghijklmnopqrstuvwxyz\"),\n        b: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\"),\n        n: 0,\n        peek: null,\n    };\n    q.n = q.a.len() as i32 + q.b.len() as i32;\n    let w = Whole { s: String::from_str(\"zz\") };\n    return q.n + w.s.len() as i32 - 60;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "Pair__free__fb("), "incomplete impl gets the wrapper");
    assert(p.gen_has("main.c", "String__free(&self->b);"), "untouched field is glue-freed");
    assert(!p.gen_has("main.c", "Whole__free__fb"), "complete impl emits no wrapper");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);
}

// A local const is a compile-time value whatever its initializer calls: an owning one is
// materialized into static data like a global one and never freed, a value one folds to static
// data instead of a call, and moving an owning one out is rejected.
@test
fn local_const_lifecycle() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct P {\n    pub x: i32,\n    pub y: i32,\n}\n\nconst fn mk() P {\n    return P { x: 3, y: 4 };\n}\n\nfn build() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(5u32);\n    v.push(9u32);\n    return v;\n}\n\nfn main() i32 {\n    const A: P = mk();\n    const L: Vector<u32> = build();\n    return A.x + A.y + L.len() as i32 + *L.at(0) as i32 - 14;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(!p.gen_has("main.c", "build()"), "owning local const is not computed at run time");
    assert(p.gen_has("main__inst.c", "static const uint32_t "), "its buffer is static data");
    assert(!p.gen_has("main.c", "Vector__u32__free(&"), "a materialized const is never freed");
    assert(!p.gen_has("main.c", "mk()"), "value const folds to static data instead of a call");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    // Runs with no leak under the fatal gate: static data is not a heap allocation.
    assert(lk.ok());

    // A GLOBAL owning const is materialized the same way (buffer included) and never freed: its own
    // project, built and run under the fatal gate. A non-const function reads it (`V.len()` folds).
    let q = cli::proj_new();
    q.mkfile(
        "g.spc",
        "fn mk() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(1u32);\n    return v;\n}\n\nconst V: Vector<u32> = mk();\n\nfn first(v: &Vector<u32>) u32 {\n    return *v.at(0);\n}\n\nfn main() i32 {\n    return (first(&V) - 1) as i32;\n}\n",
    );
    let g = q.compile("g.spc");
    assert(g.ok());
    assert(q.gen_has("g__inst.c", "static const uint32_t "), "the buffer is static data");
    assert(q.gen_has("g__inst.c", ".ptr = (void *)"), "the const points at it");
    assert(!q.gen_has("g.c", "Vector__u32__free(&V)"), "a materialized const is never freed");
    assert(q.native_build("", "g.spc").ok());
    let gr = q.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(gr.ok());
    // Moving an owning const out is rejected.
    p.mkfile(
        "m.spc",
        "fn eat(v: Vector<u32>) usize {\n    return v.len();\n}\n\nfn build() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(1u32);\n    return v;\n}\n\nfn main() i32 {\n    const L: Vector<u32> = build();\n    return (eat(L) - 1) as i32;\n}\n",
    );
    p.expect_fail("m.spc", "cannot move a value out of a 'const' binding");
}

// A boxed `dyn fn` (an owning capturing closure moved to the heap) is allocated and freed through
// the default Global allocator by generated glue. A module that uses no container still needs
// `interfaces.h` for those Global references: exercised here by a `Box<dyn fn>` returned, called,
// and freed, with nothing else pulling the allocator in.
@test
fn dyn_fn_box_roundtrip() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn make_adder(k: i32) Box<dyn fn(i32) i32> {\n    return |x: i32| x + k;\n}\n\nfn main() i32 {\n    let f = make_adder(10);\n    return f(5) - 15;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "#include \"__sc_fwd.h\""), "owned dyn compiles against the package forward header");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    // The boxed closure env is freed: no leak under the fatal gate.
    assert(lk.ok());
}

// The self-hosted leak tracker: the emitter spells the program's malloc/realloc/free calls as the entries
// of std/rt/base.spc's registry, gated at runtime by SC_LEAK_CHECK. A survivor (here a String
// buffer abandoned through `forget`) is reported at exit with its byte count; leak-free runs and
// disabled runs print nothing.
@test
fn leak_tracker() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn main() i32 {\n    forget(String::from_str(\"deliberately abandoned, past the inline budget\"));\n    return 0;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_exists("std/rt/base.c") && !p.gen_exists("super_rt.c"), "the tracker is the runtime module");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let lk = p.run_bin_env("SC_LEAK_CHECK=1 ");
    assert(lk.ok());
    assert(lk.out_has("super-c leaks: 1 allocation"), "survivor reported at exit");
    let off = p.run_bin_env("SC_LEAK_CHECK=0 "); // =0 disables even when the suite itself runs traced
    assert(off.ok());
    assert(!off.out_has("super-c leaks"), "inert when disabled");

    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        "fn main() i32 {\n    let mut v = Vector::<String>::new();\n    v.push(String::from_str(\"owned and freed\"));\n    v.push(String::from_str(\"also freed\"));\n    return (v.len() - 2) as i32;\n}\n",
    );
    let r2 = q.compile("main.spc");
    assert(r2.ok());
    let cc2 = q.native_build("", "main.spc");
    assert(cc2.ok());
    let ok = q.run_bin_env("SC_LEAK_CHECK=1 ");
    assert(ok.ok());
    assert(!ok.out_has("super-c leaks"), "leak-free run reports nothing");

    // Fatal mode: survivors turn the exit code nonzero (23), so CI can gate on leak-freedom.
    let ft = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(ft.exit, 23);
    assert(ft.out_has("super-c leaks: 1 allocation"), "fatal mode still prints the report");
    let ftc = q.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(ftc.ok());

    let t = cli::proj_new();
    t.mkfile(
        "main.spc",
        "@test\nfn leaks_in_child() {\n    forget(String::from_str(\"deliberate test child leak past the inline budget\"));\n}\n\nfn main() i32 { return 0; }\n",
    );
    let child = t.compile_flags_env("--test --quiet", "main.spc", "SC_LEAK_CHECK=fatal ");
    assert_eq(child.exit, 1);
    assert(child.out_has("test main::leaks_in_child ... FAILED"), "child leak fails the test");
    assert(child.out_has("super-c leaks: 1 allocation"), "child leak report is captured");

    // Double frees are detected via the freed-entry history: both sites report, exit 0 in
    // report mode, abort in fatal mode.
    let d = cli::proj_new();
    d.mkfile(
        "main.spc",
        "extern \"C\" {\n    fn malloc(n: usize) *mut void;\n    fn free(pt: *mut void) void;\n}\n\nfn main(args: Vector<str>) i32 {\n    let pt = unsafe malloc(64 + args.len());\n    unsafe free(pt);\n    unsafe free(pt);\n    return 0;\n}\n",
    );
    let rd = d.compile("main.spc");
    assert(rd.ok());
    let ccd = d.native_build("", "main.spc");
    assert(ccd.ok());
    let dbl = d.run_bin_env("SC_LEAK_CHECK=1 ");
    assert(dbl.ok());
    assert(dbl.out_has("super-c double free:"), "double free detected");
    assert(dbl.out_has("freed again at:"), "both sites reported");
    let dblf = d.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(dblf.exit != 0, "fatal mode aborts on double free");
}

// A leak's site is the function that asked for the block, in every profile: the tracker's entry
// points never inline into their caller (whose return address would name the caller's caller), and
// `Global`'s methods inline into the container that calls them. Only macOS prints a site by name:
// `backtrace_symbols` elsewhere prints an offset for a function the binary does not export. The
// release build keeps its symbols (`strip = false`): a stripped binary names no function.
@test
fn leak_sites_name_the_allocating_function() {
    if PLATFORM != Platform::MacOS {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "extern \"C\" { fn malloc(n: usize) *mut void; }\n@noinline\nfn leak_site(n: usize) usize {\n    let pt = unsafe malloc(48 + n);\n    return (pt != null) as usize + n;\n}\nfn main(args: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    forget(v);\n    return (leak_site(args.len()) - 2) as i32;\n}\n",
    );
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n\n[profile.release]\nstrip = false\n");
    let root = p.dir();
    for prof in ["debug", "release"] {
        let mut args = String::new();
        args.format_into("build --profile={}", prof);
        assert(cli::superc_in(root, args.as_str()).ok(), "the program builds");
        let lk = p.run_bin_env("SC_LEAK_CHECK=1 ");
        assert(lk.ok(), "the program runs");
        assert(lk.out_has(" leak_site + "), "the raw block names its function");
        assert(lk.out_has(" Vector__i32__grow"), "the vector's block names the vector's growth");
    }
}

// The reflection registry TU: `@reflect` roots that no body names still get their descriptor
// aggregates defined, land in `__sc_registry.c` sorted by symbol, register through one entry
// point, and a removed root leaves the table (runtime lookup counts the survivors).
@test
fn reflect_registry_add_remove() {
    let p = cli::proj_new();
    let two = "@reflect(entity)\nstruct Zeta { pub a: i32 }\n@reflect(entity)\nstruct Alpha { pub b: i32 }\nextern \"C\" {\n    fn __sc_reflect_types(n: *mut usize) *const *const void;\n}\nfn main() i32 {\n    let mut n: usize = 0;\n    let _ = unsafe __sc_reflect_types(&mut n);\n    let z = Zeta { a: 1 };\n    let al = Alpha { b: 2 };\n    return n as i32 + z.a + al.b - 5;\n}\n";
    p.mkfile("main.spc", two);
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(
        p.gen_has("__sc_registry.c", "{ &sc_typeinfo_Alpha, &sc_typeinfo_Zeta }"),
        "the registry table lists the roots sorted by symbol",
    );
    assert(p.gen_has("main__inst.c", "sc_typeinfo_Zeta"), "a root is defined in its owner's instance shard");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);
    p.mkfile(
        "main.spc",
        "struct Zeta { pub a: i32 }\n@reflect(entity)\nstruct Alpha { pub b: i32 }\nextern \"C\" {\n    fn __sc_reflect_types(n: *mut usize) *const *const void;\n}\nfn main() i32 {\n    let mut n: usize = 0;\n    let _ = unsafe __sc_reflect_types(&mut n);\n    let z = Zeta { a: 1 };\n    let al = Alpha { b: 2 };\n    return n as i32 + z.a + al.b - 4;\n}\n",
    );
    let r2 = p.compile("main.spc");
    assert(r2.ok());
    assert(p.gen_has("__sc_registry.c", "{ &sc_typeinfo_Alpha }"), "a removed root leaves the table");
    let cc2 = p.native_build("", "main.spc");
    assert(cc2.ok());
    assert_eq(p.run_bin(), 0);
}

// Auto-derived Free: structs and enums whose members own memory get a SYNTHESIZED per-TU free
// (`<T>__free__d`): fields, nested aggregates, enum payloads and container elements all free
// without an impl being written; partial moves out of derived values are rejected exactly like
// explicit Free types (replace() is the take idiom).
@test
fn auto_derive_free() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Plain {\n    pub s: String,\n    pub n: i32,\n}\n\nstruct Nested {\n    pub p: Plain,\n    pub tag: String,\n}\n\nenum Ev {\n    None,\n    Named(String),\n}\n\nfn main() i32 {\n    let a = Plain { s: String::from_str(\"plain owning field, long past the sso budget\"), n: 1 };\n    let b = Nested {\n        p: Plain { s: String::from_str(\"nested owning field, long past the sso\"), n: 2 },\n        tag: String::from_str(\"nested tag string, also long past the sso\"),\n    };\n    let e = Ev::Named(String::from_str(\"enum payload string, long past the sso\"));\n    let mut v = Vector::<Plain>::new();\n    v.push(Plain { s: String::from_str(\"vector element string, long past sso\"), n: 3 });\n    let k = a.n + b.p.n + v.len() as i32;\n    let ok = switch &e {\n        Named(sx) => sx.len() > 0,\n        _ => false,\n    };\n    return k + (ok as i32) - 5;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main__inst.c", "void Plain__free__d(Plain *const self)"), "struct free synthesized");
    assert(p.gen_has("main__inst.c", "Plain__free__d(&self->p);"), "nested derive composes");
    assert(p.gen_has("main__inst.c", "String__free(&self->payload.Named._0);"), "enum payload freed per variant");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(lk.ok());
    assert(!lk.out_has("super-c leaks"), "derived aggregates are leak-free");

    // Partial moves out of a derived value are rejected (same rule as explicit Free impls).
    p.mkfile(
        "take.spc",
        "struct Plain {\n    pub s: String,\n}\n\nfn main() i32 {\n    let a = Plain { s: String::from_str(\"x\") };\n    let t = a.s;\n    return (t.len() - t.len()) as i32;\n}\n",
    );
    let r2 = p.compile("take.spc");
    assert(r2.exit != 0, "partial move out of a derived value is rejected");
    assert(r2.out_has("cannot move a field out of a value implementing Free"));
}

@test
fn auto_derive_free_in_generic_drop() {
    let p = cli::proj_new();
    p.mkfile(
        "owned.spc",
        M"(extern "C" { fn putchar(c: i32) i32; }
pub struct Trace { pub text: String, pub tag: i32 }
extend Trace as Free {
    pub fn free(self: &mut Trace) {
        unsafe putchar(self.tag);
        self.text.free();
    }
}
pub fn trace(tag: i32) Trace {
    return Trace { text: String::from_str("heap allocation beyond the small string capacity"), tag: tag };
}
pub struct Record { pub trace: Trace }
pub enum Event { Empty, Live(Trace) }
pub struct Wrapper<T> { pub value: T }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import owned;
fn main() i32 {
    {
        let _value = Option::<owned::Record>::Some(owned::Record { trace: owned::trace(83) });
    }
    {
        let _value = Option::<owned::Event>::Some(owned::Event::Live(owned::trace(69)));
    }
    {
        let _value = Option::<owned::Wrapper<owned::Trace>>::Some(
            owned::Wrapper::<owned::Trace> { value: owned::trace(71) });
    }
    return 0;
}
)",
    );
    let compiled = p.native_build("", "main.spc");
    assert(compiled.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
    assert(run.out_shows("SEG"));
}

// Cross-module language features: a public const, a public type alias used as a type, qualified struct
// construction, and a local extension method on an imported type.
@test
fn module_features() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        M"(pub struct Vec2 { pub x: i32, pub y: i32 }
pub type V = Vec2;
pub const BASE: i32 = 100;
pub fn mk(a: i32, b: i32) Vec2 { return Vec2 { x: a, y: b }; }
)",
    );
    p.mkfile(
        "feat.spc",
        M"(import lib::lib;
extern "C" { fn exit(code: i32) void; }
extend lib::lib::Vec2 { fn sum(self: &lib::lib::Vec2) i32 { return self.x + self.y; } }
fn main() i32 {
  let v: lib::lib::V = lib::lib::Vec2 { x: 5, y: 7 };
  let w = lib::lib::mk(1, 2);
  unsafe exit(v.sum() + w.sum() + lib::lib::BASE); return 0; }
)",
    );
    let r = p.native_build("", "feat.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 115);
}

// A public `static mut` global: extern-declared in its header, defined once, readable/assignable across
// modules (both through the owning module's functions and directly by path).
@test
fn cross_module_static_mut() {
    let p = cli::proj_new();
    p.mkfile("state.spc", M"(pub static mut hits: i64 = 0;
pub fn record() { unsafe hits += 1; }
)");
    p.mkfile(
        "main.spc",
        M"(import state;
fn main() i32 {
  state::record();
  state::record();
  unsafe state::hits += 3;
  return (unsafe state::hits - 5) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// A constant addressing another module's constant: the owner defines it and its header declares it
// to the addressing module's constant data.
@test
fn cross_module_constant_reference() {
    let p = cli::proj_new();
    p.mkfile("tbl.spc", M"(pub const T: [i32; 3] = [4, 5, 6];
pub const U: i32 = 9;
)");
    p.mkfile(
        "main.spc",
        M"(import tbl;
const PT: &i32 = &tbl::T[2];
const PU: &&i32 = &&tbl::U;
fn main() i32 {
  return *PT + **PU - 15;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// Test timeouts: a test that runs past the run's `--test-timeout` fails as timed out, `@test(timeout = N)`
// overrides it either way (and combines with should_panic), and on POSIX the timed-out test's replayed
// output holds the reactor's state and the stack of every thread.
@test
fn test_timeouts() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::io as io;
import std::net as net;
import std::time as time;
@test
fn stuck() { time::sleep(time::Duration::from_secs(60)); }
@test(timeout = 30)
fn slow_but_allowed() { time::sleep(time::Duration::from_millis(1500)); }
@test(should_panic, timeout = 30)
fn panics() { panic("on purpose"); }
@test(timeout = 1)
fn waits_on_a_socket() {
  let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
  let a = net::TcpStream::connect("127.0.0.1", l.port()).unwrap();
  let b = l.accept().unwrap();
  let fd = b.fd;
  launch || { let _ = io::wait_until(fd, false, 0); };
  let mut buf: [u8; 1] = [0u8];
  let _ = a.read(buf);
}
fn main() i32 { return 0; }
)",
    );
    let r = p.compile_flags("--test --quiet --test-timeout=1", "main.spc");
    assert_eq(r.exit, 2);
    assert(r.out_has("test main::stuck ... FAILED (timed out)"), "the global timeout fails a stuck test");
    assert(r.out_has("test main::waits_on_a_socket ... FAILED (timed out)"), "its own timeout fails it");
    assert(r.out_shows("timed out after 1 s"), "the failure says how long it ran");
    assert(r.out_has("2 passed, 2 failed"), "the longer own timeout and should_panic pass");
    assert(r.out_has("slowest tests:") && r.out_has(" s  main::slow_but_allowed"), "the run lists its slowest tests");
    if !cli::on_windows() {
        assert(r.out_shows("--- the test ran past its timeout (1 s): the state of each of its processes"), "the dump");
        assert(r.out_shows(": the stack of every thread"), "the test's process names itself");
        assert(r.out_shows("--- thread"), "each thread prints its stack");
        assert(r.out_shows("--- reactor: state 2"), "the reactor's state follows the stacks");
        assert(r.out_shows(": read waiters 1"), "the waiting descriptor is listed");
    }
    // --test-timeout=0 turns the global timeout off; a test's own still applies.
    let off = p.compile_flags("--test --quiet --test-timeout=0 --filter=waits", "main.spc");
    assert(off.out_has("test main::waits_on_a_socket ... FAILED (timed out)"), "its own timeout without a global one");
    let bad = p.compile_flags("--test --test-timeout=soon", "main.spc");
    assert(!bad.ok(), "a malformed timeout is rejected");
}

// A timed-out test's dump reaches the processes it started: a compiled child program hung in a sleep, run
// through a shell, prints its own threads' stacks into the test's report (the shell, not a Super-C program,
// ignores the request), and the whole tree is killed. POSIX only: Windows has no dump.
@test
fn test_timeout_dumps_child_processes() {
    if cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    let root = p.dir();
    p.mkfile(
        "sleeper.spc",
        "import stdlib;\nimport std::time as time;\nfn main() i32 {\n  if stdlib::get_env(\"SLEEPER_NOW\").is_some() {\n    return 0;\n  }\n  time::sleep(time::Duration::from_secs(60));\n  return 0;\n}\n",
    );
    let mut out = String::from_str("build -o ");
    out.push_str(root);
    out.push_str("/sleeper");
    assert(p.compile_flags(out.as_str(), "sleeper.spc").ok(), "the child program builds");
    // The first exec of a fresh binary pays the OS launch assessment (macOS: 50-200 ms idle, seconds under
    // a loaded suite). Pay it here, so the hung test's 2 s window holds the hang alone: a child still
    // starting at the deadline has no handler yet and prints nothing.
    let mut warm = format("{}/sleeper", root);
    assert(cli::run_with(warm.cstr(), null, null, null, "SLEEPER_NOW=1") == 0, "the child program runs");
    let mut main = String::from_str(
        "import stdlib;\n@test(timeout = 2)\nfn runs_a_hung_child() {\n  let _ = stdlib::system(\"",
    );
    main.push_str(root);
    main.push_str("/sleeper\");\n}\nfn main() i32 { return 0; }\n");
    p.mkfile("main.spc", main.as_str());
    let r = p.compile_flags("--test --quiet", "main.spc");
    assert(r.out_has("test main::runs_a_hung_child ... FAILED (timed out)"), "the test times out");
    assert(r.out_shows(" sleeper: the stack of every thread"), "the child program prints its stacks");
    if PLATFORM == Platform::Linux {
        assert(r.out_shows("--- kernel: process"), "the kernel's view of each process follows");
    }
}

// The --test pipeline end to end: @test collection across modules, per-module and global fixtures, method
// suites (fixture-as-self), should_panic, fork isolation, filtering, sharding, and --test-no-fork.
@test
fn test_pipeline() {
    let claimed = unsafe shim::sc_jobserver_claim(1000000);
    assert(claimed >= 1, "a test process keeps its implicit worker slot");
    assert(claimed < 1000000, "the inherited process-tree budget bounds a nested claim");
    assert_eq(unsafe shim::sc_jobserver_claim(1000000), claimed);
    unsafe shim::sc_jobserver_release_claim();

    let p = cli::proj_new();
    p.mkfile(
        "env.spc",
        M"(pub struct Env { pub tag: String }
extend Env as Free {
  pub fn free(self: &mut Env) { self.tag.free(); }
}
@test_init(global)
fn suite() Env { return Env { tag: String::from_str("suite") }; }
@test_free(global)
fn suite_down(env: &mut Env) { eprintln("teardown {}", env.tag.as_str()); }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import env;
struct Fx { pub v: Vector<i32> }
extend Fx as Free {
  pub fn free(self: &mut Fx) { self.v.free(); }
}
@test_init
fn setup() Fx { let mut v = Vector::<i32>::new(); v.push(1); v.push(2); return Fx { v: v }; }
@test
fn drains(fx: &mut Fx, e: &env::Env) {
  println("drain trace");
  let mut s = 0;
  while let Some(x) = fx.v.pop() { s += x; }
  assert_eq(s, 3);
  assert_eq(e.tag.len(), 5);
}
@test
fn fails() { println("fail trace"); assert_eq(2 * 3, 7); }
@test(should_panic)
fn boom() { panic("boom"); }
struct Counter { pub n: i32 }
extend Counter {
  @test_init
  fn setup() Counter { return Counter { n: 0 }; }
  @test_free
  fn teardown(self: &mut Counter) { assert(self.n >= 0, "non-negative"); }
  pub fn bump(self: &mut Counter) { self.n += 1; }
  @test
  fn bumps(self: &mut Counter, e: &env::Env) {
    self.bump();
    assert_eq(self.n * e.tag.len() as i32, 5);
  }
}
fn main() i32 { return 0; }
)",
    );
    let r = p.compile_flags("--test", "main.spc");
    assert_eq(r.exit, 1);
    assert(r.out_has("running 4 tests"), "collected 4 tests");
    assert(r.out_has("test main::drains ... ok"), "drains passed");
    assert(r.out_has("test main::Counter::bumps ... ok"), "method suite: fixture-as-self + global env");
    assert(r.out_has("test main::boom ... ok (panicked as expected)"), "should_panic recognized");
    assert(r.out_has("test main::fails ... FAILED"), "failing test reported");
    assert(r.out_shows("assertion failed: `2 * 3 == 7`"), "assert message carries the expression");
    assert(r.out_shows("left:  6"), "assert shows left value");
    assert(r.out_shows("right: 7"), "assert shows right value");
    assert(r.out_has("teardown suite"), "global @test_free ran");
    assert(r.out_has("3 passed, 1 failed"), "final tally");
    // A failed test's output is replayed under its own header after the run, then the names are listed
    // again; a passing test's output is captured and never shown.
    assert(r.out_shows("---- main::fails ----"), "failure section has a header per failed test");
    assert(r.out_shows("fail trace"), "failure section replays the failed test's output");
    assert(r.out_shows("    main::fails"), "failures listed again at the end");
    assert(!r.out_has("drain trace"), "a passing test's output is captured");
    // --quiet drops the per-test `ok` lines and keeps the failures and the tally.
    let q = p.compile_flags("--test --quiet", "main.spc");
    assert_eq(q.exit, 1);
    assert(q.out_has("running 4 tests"), "quiet keeps the header");
    assert(!q.out_has("... ok"), "quiet drops the ok lines");
    assert(q.out_has("test main::fails ... FAILED"), "quiet keeps the FAILED line");
    assert(q.out_shows("---- main::fails ----"), "quiet keeps the failure section");
    assert(q.out_has("3 passed, 1 failed"), "quiet keeps the tally");
    // Shards partition the filtered test order without overlap; each adjacent pair is split.
    let s1 = p.compile_flags("--test --filter=main:: --test-shard=1/2 --test-jobs=2", "main.spc");
    assert(s1.ok());
    assert(s1.out_has("running 2 tests (shard 1/2)"), "first shard selected two tests");
    assert(s1.out_has("test main::drains ... ok"), "first shard contains test zero");
    assert(s1.out_has("test main::boom ... ok"), "first shard contains test two");
    assert(!s1.out_has("main::fails"), "first shard excludes test one");
    let s2 = p.compile_flags("--test --test-shard=2/2", "main.spc");
    assert_eq(s2.exit, 1);
    assert(s2.out_has("running 2 tests (shard 2/2)"), "second shard selected two tests");
    assert(s2.out_has("test main::fails ... FAILED"), "second shard contains test one");
    assert(s2.out_has("test main::Counter::bumps ... ok"), "second shard contains test three");
    assert(!s2.out_has("main::drains"), "second shard excludes test zero");
    // --test-no-fork runs in-process and skips should_panic tests.
    let nf = p.compile_flags("--test --test-no-fork --filter=boom", "main.spc");
    assert(nf.ok());
    assert(nf.out_has("skipped (should_panic needs fork)"), "no-fork skips should_panic");
    // The runner rejects an argument it does not know (a driver flag given to it directly) instead of
    // running the whole suite.
    let mut runner = String::new();
    runner.format_into("{}/build/debug/raw/__tests{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let ua = cli::exe_env_in(runner.as_str(), p.dir(), "SC_UNUSED", "1", "--test-jobs=2");
    assert_eq(ua.exit, 2);
    assert(ua.out_has("unknown test runner argument '--test-jobs=2'"), "the runner names the argument");
    assert(!ua.out_has("running"), "the runner runs nothing");
    // A normal (non---test) build still compiles and runs its own main (tests not emitted).
    let nb = p.compile("main.spc");
    assert(nb.ok());
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);
}

// A runner started without an inherited jobserver makes its own of `--jobs` slots, one implicit, as
// `super-c test` does: its tests and the processes they start share that budget.
@test
fn a_runner_run_directly_makes_its_own_jobserver() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import stdlib;\n@test\nfn names_the_jobserver() {\n    let v = stdlib::getenv(\"SC_JOBSERVER\");\n    if v != null {\n        println(\"jobserver {}\", unsafe str::from_cstr(v));\n    }\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    assert(p.compile_flags("--test --quiet", "main.spc").ok(), "the runner builds and passes");
    let mut runner = String::new();
    runner.format_into("{}/build/debug/raw/__tests{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    // An empty SC_JOBSERVER names no jobserver, as an unset one does. `--no-fork` shows the test's output.
    let r = cli::exe_env_in(runner.as_str(), p.dir(), "SC_JOBSERVER", "", "--jobs=3 --no-fork");
    assert(r.ok(), "the runner passes");
    assert(r.out_shows("jobserver 2,"), "the runner's jobserver has two slots beside the implicit one");
}

// A should_panic test passes only on a panic: a crash, or a nonzero exit such as a leak report's 23, fails it.
@test
fn should_panic_needs_a_panic() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import stdlib;
@test(should_panic)
fn crashes() {
  let p = stdlib::getenv("SC_NO_SUCH_VARIABLE");
  if unsafe *p == 'x' as char { println("x"); }
}
@test(should_panic)
fn exits() { unsafe stdlib::exit(23); }
@test(should_panic)
fn panics() { panic("boom"); }
fn main() i32 { return 0; }
)",
    );
    let r = p.compile_flags("--test", "main.spc");
    assert_eq(r.exit, 2);
    assert(r.out_shows("test main::crashes ... FAILED (expected a panic)"), "a crash is not a panic");
    assert(r.out_shows("test main::exits ... FAILED (expected a panic)"), "a nonzero exit is not a panic");
    assert(r.out_shows("exited with code 23"), "the report names the exit code");
    assert(r.out_shows("test main::panics ... ok (panicked as expected)"), "a panic passes");
    assert(r.out_shows("1 passed, 2 failed"), "tally");
}

// A variable a test sets through `cli::set_env` holds until the guard drops, then takes back its previous
// value, or goes when it had none.
@test
fn env_guards_restore_the_environment() {
    {
        let _a = cli::set_env("SC_GUARD_PROBE", "1");
        assert(stdlib::env_is("SC_GUARD_PROBE", "1"), "set");
        {
            let _b = cli::set_env("SC_GUARD_PROBE", "2");
            assert(stdlib::env_is("SC_GUARD_PROBE", "2"), "set over");
        }
        assert(stdlib::env_is("SC_GUARD_PROBE", "1"), "the previous value is back");
    }
    assert(stdlib::getenv("SC_GUARD_PROBE") == null, "a variable that had no value goes");
}

// A child runs with every assignment its caller gives it or not at all: an environment list that does not
// apply whole (more than 8 with the harness's SC_LEAK_CHECK, one without `=`, an unclosed quote) starts
// nothing. A value in double quotes holds spaces.
@test
fn an_env_that_does_not_apply_whole_starts_nothing() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let mut cmd = format("{} --version", unsafe str::from_cstr(cli::cc_name()));
    assert_eq(cli::run_with(cmd.cstr(), null, null, null, "SC_P1=1 SC_P2=2 SC_P3=3 SC_P4=4 SC_P5=5 SC_P6=6 SC_P7=7"), 0);
    assert_eq(
        cli::run_with(cmd.cstr(), null, null, null, "SC_P1=1 SC_P2=2 SC_P3=3 SC_P4=4 SC_P5=5 SC_P6=6 SC_P7=7 SC_P8=8"),
        -1,
    );
    assert_eq(cli::run_with(cmd.cstr(), null, null, null, "SC_P1"), -1);
    assert_eq(cli::run_with(cmd.cstr(), null, null, null, "SC_P1=\"a b\" SC_P2=2"), 0);
    assert_eq(cli::run_with(cmd.cstr(), null, null, null, "SC_P1=\"a b"), -1);
}

// A generic defined in one module, instantiated over a user struct held BY VALUE in another: the instance is
// re-homed to the user module and full-monomorphized there. -Werror is the placement proof.
// A zero-sized fixture, suite receiver or global env has no storage: the wrappers pass its address as the
// zero-sized sentinel, and the init and teardown still run.
@test
fn test_zero_sized_fixtures() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct S {}
extend S {
  @test_init
  fn init() S { println("suite init"); return S {}; }
  @test_free
  fn fin(self: &mut S) { panic("suite free ran"); }
  @test
  fn method(self: &mut S) { println("method ran"); }
}
struct M {}
@test_init
fn module_fx() M { return M {}; }
struct G {}
@test_init(global)
fn genv() G { return G {}; }
@test
fn uses_both(m: &mut M, g: &G) { panic("uses_both ran"); }
fn main() i32 { return 0; }
)",
    );
    let r = p.compile_flags("--test --quiet", "main.spc");
    assert_eq(r.exit, 2);
    assert(r.out_shows("suite init"), "the suite init ran");
    assert(r.out_shows("method ran"), "the suite test ran with its receiver");
    assert(r.out_shows("suite free ran"), "the suite teardown ran");
    assert(r.out_shows("uses_both ran"), "the module fixture and global env test ran");
}

@test
fn cross_module_generic_by_value() {
    let p = cli::proj_new();
    p.mkfile(
        "opt/opt.spc",
        M"(pub enum Opt<T> { Some(T), None }
extend<T: Copy> Opt<T> {
  pub fn unwrap_or(self: &Opt<T>, d: T) T { return switch self { Some(v) => *v, None => d, }; }
  pub fn map<U>(self: &Opt<T>, f: fn(T) U) Opt<U> {
    return switch self { Some(v) => Opt::<U>::Some(f(*v)), None => Opt::<U>::None, }; }
}
)",
    );
    p.mkfile(
        "genbv.spc",
        M"(import opt::opt;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
fn bx(b: Bar) i32 { return b.x; }
fn main() i32 {
  let o = opt::opt::Opt::<Bar>::Some(Bar { x: 30 });
  let a = o.unwrap_or(Bar { x: 0 }).x;
  let m = o.map(bx).unwrap_or(0);
  unsafe exit(a + m); return 0; }
)",
    );
    let r = p.compile("genbv.spc");
    assert(r.ok(), "the program compiles");
    assert(
        p.gen_has("__sc_t/opt__Opt__genbv__Bar.h", "struct opt__Opt__genbv__Bar {"),
        "instance full-monomorphized in its own definition header",
    );
    let cc = p.native_build("", "genbv.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 60);
}

// A cross-module generic instance whose bounded extend calls a BOUND METHOD on the element; the bound call
// dispatches through the subst (T -> Bar) to the concrete Bar__clone.
@test
fn cross_module_generic_bound_dispatch() {
    let p = cli::proj_new();
    p.mkfile(
        "bx/bx.spc",
        M"(pub interface Clone { fn clone(self: &Self) Self; }
pub struct Bx<T> { pub v: T }
extend<T: Clone> Bx<T> {
  pub fn dup(self: &Bx<T>) Bx<T> { return Bx::<T> { v: self.v.clone() }; }
}
)",
    );
    p.mkfile(
        "genbd.spc",
        M"(import bx::bx;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
extend Bar as bx::bx::Clone { fn clone(self: &Self) Bar { return Bar { x: self.x }; } }
fn main() i32 {
  let b = bx::bx::Bx::<Bar> { v: Bar { x: 21 } };
  let d = b.dup();
  unsafe exit(d.v.x + b.v.x); return 0; }
)",
    );
    let r = p.native_build("", "genbd.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 42);
}

// @emit_macro on a generic type emits reusable C DECLARE/DEFINE templates into its header; Super-C's own
// instances stay full-monomorphized; a plain-C consumer can instantiate the template; rejected on non-generics.
@test
fn emit_macro_export() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "emac.spc",
        M"(extern "C" { fn exit(code: i32) void; }
@emit_macro
pub struct Pair<T> { pub a: T, pub b: T }
extend<T: Copy> Pair<T> { pub fn pick(self: &Pair<T>, second: bool) T { if second { return self.b; } return self.a; } }
fn main() i32 { let p = Pair::<i32> { a: 3, b: 4 }; unsafe exit(p.pick(true) + p.a); return 0; }
)",
    );
    let r = p.compile("emac.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("__sc_fwd.h", "PAIR_DECLARE("), "@emit_macro emits DECLARE template");
    assert(p.gen_has("__sc_fwd.h", "PAIR_DEFINE("), "@emit_macro emits DEFINE template");
    let cc = p.native_build("", "emac.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 7);

    // A plain-C consumer instantiates the template over its own C type (no Super-C compiler involved).
    p.mkfile(
        "cuser.c",
        M"(#include "emac.h"
typedef struct { int n; } CT;
PAIR_DECLARE(CT, CT, Pair__CT)
PAIR_DEFINE(CT, CT, Pair__CT)
_Noreturn void __sc_panic(const char *__m) { (void)__m; abort(); }
int main(void) { Pair__CT p = { .a = { 5 }, .b = { 9 } };
  return Pair__CT__pick(&p, 1).n == 9 ? 0 : 1; }
)",
    );
    let mut cc2 = Cmd {};
    unsafe stdio::snprintf(
        &mut cc2.b[0],
        2048,
        // The consumer defines the runtime trap the header's checks call, which a Super-C program takes from
        // std/rt/base.spc.
        "%s -std=c11 -Wall -Wextra -Werror -funsigned-char -ffp-contract=off -I\"%s/build/debug/raw\" \"%s/cuser.c\" -o \"%s/cbin%s\"".ptr() as *const char,
        cli::cc_name(),
        p.rootp(),
        p.rootp(),
        p.rootp(),
        cli::binext(),
    );
    assert_eq(cli::run_quiet(&cc2.b[0]), 0);
    let mut cr = Cmd {};
    unsafe stdio::snprintf(&mut cr.b[0], 2048, "\"%s/cbin%s\"".ptr() as *const char, p.rootp(), cli::binext());
    assert_eq(cli::run_quiet(&cr.b[0]), 0);

    // The attribute is rejected on a non-generic type.
    p.mkfile("bad.spc", "@emit_macro\npub struct Plain { pub a: i32 }\nfn main() i32 { return 0; }\n");
    let bad = p.compile("bad.spc");
    assert(bad.exit != 0, "@emit_macro on a non-generic is rejected");
    assert(bad.out_has("generic struct or enum"), "the rejection names the constraint");
}

// Per-extend bound filtering: a bounded extension block instantiated over a type that does NOT satisfy the
// bound must not be specialized (its body would call an unprovided method); only the unbounded block emits.
@test
fn per_extend_bound_filtering() {
    let p = cli::proj_new();
    p.mkfile(
        "pibf.spc",
        M"(extern "C" { fn exit(code: i32) void; }
pub interface Marker { fn mark(self: &Self) i32; }
pub struct Wrap<T> { pub v: T }
extend<T> Wrap<T> { pub fn raw(self: &Wrap<T>) i32 { return 7; } }
extend<T: Marker> Wrap<T> { pub fn marked(self: &Wrap<T>) i32 { return self.v.mark(); } }
struct Plain { pub n: i32 }
fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 5 } }; unsafe exit(w.raw()); return 0; }
)",
    );
    let r = p.native_build("", "pibf.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 7);
}

// A non-Default allocator must still get all String<A> methods/conformances that only need an explicit or
// stored allocator (a multi-file regression: warning-clean without a sentinel `RawAlloc: Default`).
@test
fn string_non_default_allocator() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(extern "C" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; fn exit(code: i32) void; }
struct RawAlloc {}
extend RawAlloc as Allocator {
  unsafe fn alloc(self: &mut RawAlloc, n: usize, align: usize) *mut void { return unsafe malloc(n); }
  unsafe fn realloc(self: &mut RawAlloc, p: *mut void, old_n: usize, n: usize, align: usize) *mut void { return unsafe realloc(p, n); }
  unsafe fn dealloc(self: &mut RawAlloc, p: *mut void, n: usize, align: usize) { unsafe free(p); }
}
fn main() i32 {
  let a = RawAlloc {};
  let mut s = String::<RawAlloc>::from_str_in(a, "abcdefghijklmnopqrstuvwxyz");
  s.push_str("0123456789");
  let mut c = s.clone();
  let mut f = s.fmt();
  let ok = s.eq_str("abcdefghijklmnopqrstuvwxyz0123456789") && s.cmp(&c) == 0 && hash(&s) == hash(&c) && f.len() == s.len();
  if ok { return 42; }
  return 1;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 42);
}

// Eager emission must stay warning-clean under -Wunused-function: generic methods, inherited defaults and
// private functions may be omitted or explicitly marked unused.
@test
fn warning_clean_unused_emission() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(extern "C" { fn exit(code: i32) void; }
fn unused_private() i32 { return 99; }
interface I { fn value(self: &Self) i32; fn unused_default(self: &Self) i32 { return 123; } }
struct S { pub x: i32 }
extend S as I { fn value(self: &Self) i32 { return self.x; } }
struct Wrap<T> { pub v: T }
extend<T: Copy> Wrap<T> {
  fn get(self: &Self) T { return self.v; }
  fn unused_method(self: &Self) T { return self.v; }
}
fn main() i32 { let s = S { x: 20 }; let w = Wrap::<i32> { v: 22 }; unsafe exit(s.value() + w.get()); return 0; }
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    let cc = p.cc_build("");
    assert(cc.ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 42);
}

// OS threads (std/parallel): an owning closure (a moved-in String) returns its value through the
// JoinHandle, and four threads share one Atomic<i64> through an Arc: the Send-safe way, and race on
// fetch_add, so the total is exact. Leak-checked, so the String, the Arc block and every payload/slot are
// accounted for.
@test
fn threads_and_atomics() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::thread as thread;
import std::parallel::atomics as atom;
import std::parallel::arc as arc;

fn main() i32 {
    let msg = String::from_str("payload");
    let owned = thread::spawn(fn() usize { return msg.len(); });

    let counter = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let mut handles = Vector::<thread::JoinHandle<i32>>::new();
    for _t in 0..4 {
        let c = counter.clone();
        handles.push(thread::spawn(fn() i32 {
            for _i in 0..1000 {
                let _ = c.get().fetch_add(1, atom::MemoryOrder::Relaxed);
            }
            return 0;
        }));
    }
    while handles.len() > 0 {
        let _ = handles.pop().unwrap().join();
    }

    let n = owned.join();
    let total = counter.get().load(atom::MemoryOrder::SeqCst);
    return (n as i32 - 7) + (total - 4000) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Spawn requires F: Send, and a raw pointer is not Send (nor is a closure that captures one), so sending a
// stack borrow to another thread is rejected at compile time: the single-threaded escape hatch is closed.
@test
fn thread_send_rejects_raw_pointer() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::thread as thread;
fn main() i32 {
    let mut x: i32 = 5;
    let ptr = &mut x as *mut i32;
    let h = thread::spawn(fn() i32 { return unsafe { ptr[0]; }; });
    return h.join();
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "capturing a raw pointer into a spawned thread is rejected");
    assert(r.out_has("Send"), "the rejection cites the Send bound");
}

// A detached task may outlive the call that launched it, so it may not borrow the launcher's frame: the
// escape rule of the design. `Send` does not catch this (a `&T` IS Send when `T` is Sync), so `launch` and
// `thread::spawn` require `F: 'static`, and that bound looks THROUGH the closure at its captures, which its
// type erases. Both spellings of a borrowed capture are rejected: an explicit `&local`, and a mutated
// capture (which the capture analysis turns into an implicit `&mut` into the launcher's frame).
@test
fn launch_rejects_borrowed_capture() {
    // The programs import std::parallel, which the in-process compile does not load: a build.
    let mut b = cli::Batch::new("", "");
    b.add(
        "launching a closure that captures a borrow is rejected, citing the 'static bound",
        M"(import std::parallel::runtime as rt;
import std::parallel::atomics as atom;

fn main() i32 {
    let counter = atom::Atomic::<i64>::new(0);
    let cp = &counter;
    launch fn() {
        let _ = cp.fetch_add(1, atom::MemoryOrder::Relaxed);
    };
    rt::shutdown();
    return 0;
}
)",
        "'static",
    );
    b.add(
        "spawning a closure that mutates a capture is rejected, naming the mutated capture",
        M"(import std::parallel::thread as thread;

fn main() i32 {
    let mut total: i64 = 0;
    let h = thread::spawn(fn() i64 {
        total = total + 1; // a mutated capture is an implicit `&mut` into this frame
        return total;
    });
    return h.join() as i32;
}
)",
        "or mutates a capture, which captures `&mut`",
    );
    let p = cli::proj_new();
    p.expect_batch(b);
}

// usize/isize literal ranges follow the SELECTED target's pointer width, not the host's: a 64-bit
// usize literal is legal for 64-bit targets and rejected for wasm32.
@test
fn usize_literal_range_follows_target() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn main() i32 {
    let sentinel: usize = 0xFFFFFFFFFFFFFFFFusize;
    let big: usize = 4294967296;
    return ((sentinel & 1) + (big & 1) - 1) as i32;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "a 64-bit host target accepts usize MAX literals");
    let r2 = p.compile_flags("--target=wasm", "main.spc");
    assert(r2.exit != 0, "wasm32 rejects 64-bit usize literals");
    assert(r2.out_has("does not fit in its suffixed type"), "the suffixed literal names its diagnostic");
    assert(r2.out_has("out of range"), "the expected-type literal names its diagnostic");
}

// Compile-time evaluation wraps usize/isize at the SELECTED target's pointer width, as the emitted C
// does: on wasm32, 0.wrapping_sub(1) is 2^32 - 1 and a zero usize has 32 trailing zeros.
@test
fn usize_const_eval_follows_target() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(const fn m1() usize {
    let z: usize = 0;
    return z.wrapping_sub(1);
}
const W: u64 = sizeof(usize) as u64 * 8;
static_assert(m1() as u64 == (1u64 << W - 1) - 1 + (1u64 << W - 1), "usize wraps at the target width");
static_assert(-1 as isize as usize == m1(), "isize converts at the target width");
static_assert(m1().count_ones() as u64 == W && (0 as usize).trailing_zeros() as u64 == W, "bit counts");
fn main() i32 {
    return 0;
}
)",
    );
    assert(p.compile("main.spc").ok(), "the host target");
    assert(p.compile_flags("--target=wasm", "main.spc").exit == 0, "wasm32");
}

// A `@platform`-gated @test exists only for the targets it names: on every other target the item is
// filtered out, so the runner must not register it (else it calls a function the emitter never wrote).
// Two tests gated to disjoint platform sets: exactly one exists on any host.
@test
fn platform_gates_tests() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@test
fn always() {
    assert(1 == 1);
}

@platform(windows)
@test
fn only_windows() {
    assert(1 == 1);
}

@platform(macos | linux)
@test
fn only_posix() {
    assert(1 == 1);
}

fn main() i32 {
    return 0;
}
)",
    );
    let r = p.compile_flags("--test --quiet", "main.spc");
    assert(r.ok(), "the gated-out test is not registered");
    assert(r.out_has("running 2 tests"), "one gated test exists on this host, the other does not");
    assert(r.out_has("2 passed, 0 failed"), "tally");
}

@test
fn platform_gates_ext_c() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@platform(windows)
@link("scrt_win_only_lib")
extern "C" "scrt_no_such_header.h" {
    pub fn scrt_win_only() i32;
}

@link("m")
extern "C" {
    fn scrt_needs_m() f64;
}

fn main() i32 {
    return 0;
}
)",
    );
    // Builds on the host even though the windows block names a header that does not exist: it is gated out.
    let r = p.compile("main.spc");
    assert(r.ok());
    // The always-on link is present; the windows-only one only when windows is what we are building for.
    assert(p.gen_has("__ldflags", "-lm"), "ungated @link lands in __ldflags");
    if cli::on_windows() {
        assert(p.gen_has("__ldflags", "scrt_win_only_lib"), "the windows @link is kept on windows");
    } else {
        assert(!p.gen_has("__ldflags", "scrt_win_only_lib"), "windows @link is filtered out on the host");
    }
}

// Preemption: the scheduler is cooperative, so a task that never blocks would own its worker
// forever. Codegen emits a `__sc_spc` countdown at every loop backedge, but ONLY in a program that uses the
// coroutine runtime, and the scheduler installs a hook that yields when the worker has other work queued.
// Proven here with one worker and a task that spins on a flag only a SECOND task can set: without
// preemption the first task never yields, the second never runs, and the flag never flips.
@test
fn preemption_yields_a_spinning_task() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let fa = flag.clone();
    let wa = wg.clone();
    launch fn() {
        // A pure compute loop: it blocks on nothing, so only a safepoint can take the worker back.
        let mut spins: i64 = 0;
        while fa.get().load(atom::MemoryOrder::Relaxed) == 0 {
            spins = spins + 1;
        }
        wa.done();
    };
    let fb = flag.clone();
    let wb = wg.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    let ok = wg.wait_timeout(time::Duration::from_secs(30));
    rt::shutdown();
    if !ok {
        return 1;
    }
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(
        p.gen_has("main.c", "if (__builtin_expect(--__sc_spc == 0, 0)) __sc_spc = __sc_preempt_check();"),
        "a loop in a program that never cancels gets the plain safepoint",
    );
    assert(!p.gen_has("main.c", "__sc_cancel_tick"), "no cancellation tick without a cancellation requester");
    assert(p.gen_has("main.c", "int32_t __sc_spc = "), "the function-local preemption tick is declared");
    // The substrate's spin, park and signal-handler loops hold locks a preemption must not cross.
    assert(!p.gen_has("sc_runtime.c", "__sc_spc"), "the runtime substrate never ticks");
    if !cli::on_wasm() {
        // The context switch names its trampoline as a value: the extern still gets its declaration.
        assert(p.gen_has("__sc_fwd.h", "extern void sc_ctx_entry(void);"), "a header-less extern named as a value");
    }
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());

    // ... and a program that never launches pays nothing: no safepoint is emitted at all.
    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        M"(fn main() i32 {
    let mut t: i64 = 0;
    for i in 0..10 {
        t = t + i as i64;
    }
    return (t - 45) as i32;
}
)",
    );
    let r2 = q.compile("main.spc");
    assert(r2.ok());
    assert(!q.gen_has("main.c", "__sc_spc"), "a program that never launches gets no safepoints");
}

// The coroutine-reachability scan pins every call inside a launched body to a declaration; a call to a
// fn value it cannot trace reaches every fn value of the program. An explicit `x.free()` on a value
// whose destructor is synthesized resolves to no declaration: it is a drop, not a fn-value call.
@test
fn explicit_drop_in_a_task_keeps_safepoints_scoped() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;

struct Bag {
    pub items: Vector<i64>,
}

fn main() i32 {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        let mut bag = Bag { items: Vector::<i64>::new() };
        bag.items.push(1);
        bag.free();
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    let mut t: i64 = 0;
    for i in 0..10 {
        t = t + i as i64;
    }
    return (t - 45) as i32;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(!p.gen_has("main.c", "__sc_spc"), "a loop outside every launched body gets no safepoint");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// A user module whose name merely begins with `std` is user code, not std: its loops reached from a
// launched body get their safepoints.
@test
fn std_prefixed_user_module_keeps_safepoints() {
    let p = cli::proj_new();
    p.mkfile(
        "stdx.spc",
        M"(pub fn spin(n: i64) i64 {
    let mut t: i64 = 0;
    for i in 0..n {
        t = t + i;
    }
    return t;
}
)",
    );
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import stdx;

fn main() i32 {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        let _ = stdx::spin(10);
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("stdx.c", "__sc_spc"), "a launched body's loop in a std-prefixed user module is marked");
}

// The per-TU cache replays a module's emitted C while its own import closure is unchanged, but the
// safepoints in that C follow coroutine reachability, which any module in the package can change: a
// launched body added in main must reach the loop of a module main imports on the next build.
@test
fn tu_cache_follows_coroutine_reachability() {
    let p = cli::proj_new();
    p.mkfile(
        "work.spc",
        M"(pub fn spin(n: i64) i64 {
    let mut t: i64 = 0;
    for i in 0..n {
        t = t + i;
    }
    return t;
}
)",
    );
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import work;

fn main() i32 {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return (work::spin(10) - 45) as i32;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(!p.gen_has("work.c", "__sc_spc"), "a loop no launched body reaches gets no safepoint");
    // The same module set and the same import closure for work.spc: only main's launched body changes.
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import work;

fn main() i32 {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        let _ = work::spin(10);
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return (work::spin(10) - 45) as i32;
}
)",
    );
    let r2 = p.compile("main.spc");
    assert(r2.ok());
    assert(p.gen_has("work.c", "__sc_spc"), "the rebuilt program reaches the loop from a launched body");
}

// Build `src` as main.spc and run it under the leak gate. The programs below run a task that never
// blocks on the only worker, and exit 1 when its loop never reaches a safepoint (it neither yields
// nor stops on cancellation).
fn run_preempted(src: str) {
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Every coroutine entry API seeds the reachability scan, not only `launch`: a `TaskGroup::spawn`
// child is preempted like a launched task.
@test
fn task_group_child_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    let mut g = task::TaskGroup::new();
    g.spawn(fn() {
        // A group child that never blocks: only its safepoint gives the worker back.
        while !raised() {}
        wa.done();
    });
    let fb = flag.clone();
    g.spawn(fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    });
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: the group's join would wait for it forever.
        unsafe stdlib::exit(1);
    }
    let r = g.join();
    rt::shutdown();
    return r.completed as i32 - 2;
}
)",
    );
}

// ... and a compute-bound group child stops at its combined safepoint when the group cancels.
@test
fn task_group_cancel_stops_a_compute_bound_child() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

fn main() i32 {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    let mut g = task::TaskGroup::new();
    g.spawn(fn() {
        defer wa.done();
        // A compute loop with no wait and no explicit cancellation point: only the combined loop
        // safepoint can stop it. The xorshift state never reaches zero from a nonzero seed.
        let mut x: u64 = 88172645463325252;
        loop {
            x = x ^ x << 13;
            x = x ^ x >> 7;
            x = x ^ x << 17;
            if x == 0 {
                break;
            }
        }
    });
    g.cancel();
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The child never reached a cancellation point: the group's join would wait forever.
        unsafe stdlib::exit(1);
    }
    let r = g.join();
    rt::shutdown();
    return r.cancelled as i32 - 1;
}
)",
    );
}

// Reachability continues through std: a named function std calls back as a fn value is reached from
// the launched body that passes it.
@test
fn std_callback_by_name_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

fn body(x: &i32) {
    let _ = x;
    while !raised() {}
}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    launch fn() {
        let mut v = Vector::<i32>::new();
        v.push(1);
        iter::for_each(v.iter(), body);
        wa.done();
    };
    let fb = flag.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: shutdown would wait for it forever.
        unsafe stdlib::exit(1);
    }
    rt::shutdown();
    return 0;
}
)",
    );
}

// A user conformance method std dispatches through a bound is reached (every conformance method of
// the interface method's name).
@test
fn bound_dispatched_next_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

struct Slow {
    pub n: i32,
}

extend Slow as Iterator<i32> {
    pub fn next(self: &mut Slow) Option<i32> {
        if self.n == 0 {
            return Option::<i32>::None;
        }
        self.n = self.n - 1;
        while !raised() {}
        return Option::<i32>::Some(self.n);
    }
}

fn ignore(_x: i32) {}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    launch fn() {
        iter::for_each(Slow { n: 2 }, ignore);
        wa.done();
    };
    let fb = flag.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: shutdown would wait for it forever.
        unsafe stdlib::exit(1);
    }
    rt::shutdown();
    return 0;
}
)",
    );
}

// A std loop that drives user code gets its tick: this iterator yields until the flag rises and has
// no loop of its own, so the loop in `iter::for_each` is the only place the task can yield.
@test
fn std_loop_driving_user_code_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

struct Slow {
    pub n: i32,
}

extend Slow as Iterator<i32> {
    // No loop here: only the std loop driving it can yield.
    pub fn next(self: &mut Slow) Option<i32> {
        if raised() {
            return Option::<i32>::None;
        }
        self.n = self.n + 1;
        return Option::<i32>::Some(self.n);
    }
}

fn ignore(_x: i32) {}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    launch fn() {
        iter::for_each(Slow { n: 0 }, ignore);
        wa.done();
    };
    let fb = flag.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: shutdown would wait for it forever.
        unsafe stdlib::exit(1);
    }
    rt::shutdown();
    return 0;
}
)",
    );
}

// A std body that runs user code only through bound dispatch ticks only in the instances binding a
// type whose methods can be user code: `Map<u64, u64>` probes are bounded by the table and stay
// tick-free, a map keyed by a user type and a `for_each` over a user function tick.
@test
fn std_instance_ticks_follow_its_type_arguments() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;

struct Key {
    pub k: u64,
}

extend Key as Hash {
    pub fn hash_into<H: Hasher>(self: &Key, h: &mut H) {
        h.write_u64(self.k);
    }
}

extend Key as Eq {
    pub fn eq(self: &Key, other: &Key) bool {
        return self.k == other.k;
    }
}

fn keep(_x: &i32) {}

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        let mut m = Map::<u64, u64>::new();
        m.insert(1, 2);
        let mut u = Map::<Key, u64>::new();
        u.insert(Key { k: 1 }, 2);
        let mut v = Vector::<i32>::new();
        v.push(1);
        iter::for_each(v.iter(), keep);
        let _ = m.get(&1);
        let _ = u.get(&Key { k: 1 });
        let mut w = Vector::<u64>::new();
        w.push(1);
        let mut kw = Vector::<Key>::new();
        kw.push(Key { k: 1 });
        let _ = w.contains(&1);
        let _ = kw.contains(&Key { k: 1 });
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(
        p.gen_fn_has("__std/map__inst.c", "Map__u64__u64__slot", "Map__u64__u64__slot"),
        "the std-typed probe is emitted",
    );
    assert(!p.gen_fn_has("__std/map__inst.c", "Map__u64__u64__slot", "__sc_spc"), "a std-typed probe loop has no tick");
    assert(p.gen_fn_has("__std/map__inst.c", "Map__main__Key__u64__slot", "__sc_spc"), "a user-keyed probe loop ticks");
    assert(
        p.gen_fn_has("__std/iter__inst.c", "for_each__VecIter__i32__ptr_i32__main__keep", "__sc_spc"),
        "a std loop over a user function ticks",
    );
    // `==` on a type parameter dispatches to `eq` at emission: the instance binding a user type
    // ticks once per chunk of its counted loop; the instance that prints no tick ends its only
    // chunk at the loop's end. Without inlining, so each instance keeps its own function.
    let r2 = p.compile_flags_env("", "main.spc", "SC_INLINE=0");
    assert(r2.ok());
    assert(
        p.gen_fn_has("__std/vector__inst.c", "Vector__main__Key__contains", "__sc_chunk_end(&__sc_spc, "),
        "a user-typed == ticks",
    );
    assert(!p.gen_fn_has("__std/vector__inst.c", "Vector__u64__contains", "__sc_spc"), "a std-typed == has no tick");
    assert(
        p.gen_fn_has("__std/vector__inst.c", "Vector__u64__contains", "Vector__u64__contains"),
        "the std-typed instance is emitted",
    );
}

// A fn value handed to std::parallel from a task is reached even when it was built outside every
// task, and so is one stored in a field and called later: the only loop of each program is in that
// closure.
@test
fn fn_values_handed_to_std_parallel_or_stored_are_reached() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::data as data;

fn main() i32 {
    rt::set_worker_count(1);
    // Built outside any task: only its hand-off to std::parallel inside the task reaches it.
    let body = |i: usize| {
        let mut k: usize = 0;
        while k < i {
            k = k + 1;
        }
    };
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        data::range(0..4, body);
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "__sc_spc"), "the closure handed to data::range ticks");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;

struct Job {
    pub f: fn(usize) usize,
}

fn count(n: usize) usize {
    let mut k: usize = 0;
    while k < n {
        k = k + 1;
    }
    return k;
}

fn main() i32 {
    let job = Job { f: count };
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wa = wg.clone();
    launch fn() {
        let _ = (job.f)(4);
        wa.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r2 = q.compile("main.spc");
    assert(r2.ok());
    assert(q.gen_fn_has("main.c", "main__count", "__sc_spc"), "a stored fn value called in a task ticks");
}

// A user `free` that std's drop of a container runs is reached.
@test
fn free_run_by_std_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

struct Spin {
    pub k: i32,
}

extend Spin as Free {
    pub fn free(self: &mut Spin) {
        let _ = self.k;
        while !raised() {}
    }
}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    launch fn() {
        let mut v = Vector::<Spin>::new();
        v.push(Spin { k: 1 });
        v.clear();
        wa.done();
    };
    let fb = flag.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: shutdown would wait for it forever.
        unsafe stdlib::exit(1);
    }
    rt::shutdown();
    return 0;
}
)",
    );
}

// A loop in value position gets its tick like a statement loop.
@test
fn value_loop_is_preempted() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    run_preempted(
        M"(import stdlib;
import std::iter as iter;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

static mut G_FLAG: *const atom::Atomic<i64> = null;

fn raised() bool {
    return unsafe (*G_FLAG).load(atom::MemoryOrder::Relaxed) != 0;
}

fn main() i32 {
    rt::set_worker_count(1);
    let flag = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    unsafe G_FLAG = flag.get() as *const atom::Atomic<i64>;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let wa = wg.clone();
    let wb = wg.clone();
    launch fn() {
        let n = loop {
            if raised() {
                break 1;
            }
        };
        let _ = n;
        wa.done();
    };
    let fb = flag.clone();
    launch fn() {
        fb.get().store(1, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        // The spinner never yielded: shutdown would wait for it forever.
        unsafe stdlib::exit(1);
    }
    rt::shutdown();
    return 0;
}
)",
    );
}
// Whether generated file `rel` of `p` holds `a` with `b` next after it, whitespace aside.
fn gen_followed_by(p: &cli::Proj, rel: str, a: str, b: str) bool {
    let text = cli::read_text(format("{}/build/debug/raw/{}", p.dir(), rel).as_str());
    let t = text.as_str();
    let k = t.find(a);
    if k < 0 {
        return false;
    }
    let mut at = k as usize + a.len();
    while at < t.len() && (t.byte_at(at) == b' ' || t.byte_at(at) == b'\n' || t.byte_at(at) == b'\t') {
        at += 1;
    }
    return t.slice(at, t.len()).starts_with(b);
}

// A counted loop (a range over a builtin integer, a slice) whose body runs no call is strip-mined:
// one safepoint per chunk of at most the tick budget left, then a chunk loop with no tick. The
// spinner below holds the only worker in such a loop: the second task runs only if a chunk top
// yields, and the group's cancellation lands only at a chunk top. `break`, `continue` and labels
// inside such loops, across many chunk ends, give what the same loops written with `while` (a
// tick per iteration) give. A body with a call, and a `for mut` binding the body can assign, keep
// the tick per iteration.
@test
fn counted_loop_ticks_once_per_chunk() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import stdlib;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::task as task;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

fn flow(n: i64) i64 {
    let mut s: i64 = 0;
    'outer: for i in 0 - n..n {
        if i % 1000 == 999 {
            continue;
        }
        for j in 0..3000i64 {
            if j == 2500 {
                continue 'outer;
            }
            if i == n - 7 && j == 11 {
                break 'outer;
            }
            if j % 7 != 0 {
                continue;
            }
            s = s + (j ^ i);
        }
    }
    return s;
}

fn flow_while(n: i64) i64 {
    let mut s: i64 = 0;
    let mut i = 0 - n;
    'outer: while i < n {
        let ci = i;
        i = i + 1;
        if ci % 1000 == 999 {
            continue;
        }
        let mut j: i64 = 0;
        while j < 3000 {
            let cj = j;
            j = j + 1;
            if cj == 2500 {
                continue 'outer;
            }
            if ci == n - 7 && cj == 11 {
                break 'outer;
            }
            if cj % 7 != 0 {
                continue;
            }
            s = s + (cj ^ ci);
        }
    }
    return s;
}

fn picks(v: []u32) u64 {
    let mut s: u64 = 0;
    for x in v {
        if x % 3 == 0 {
            continue;
        }
        if x == 9001 {
            break;
        }
        s = s + x as u64;
    }
    return s;
}

fn picks_while(v: []u32) u64 {
    let mut s: u64 = 0;
    let mut k: usize = 0;
    while k < v.len() {
        let x = v[k];
        k = k + 1;
        if x % 3 == 0 {
            continue;
        }
        if x == 9001 {
            break;
        }
        s = s + x as u64;
    }
    return s;
}

fn narrow() i64 {
    let mut c: i64 = 0;
    for b in 0..255u8 {
        c = c + b as i64;
    }
    let lo: i8 = -127;
    for i in lo - 1..127i8 {
        c = c + i as i64;
    }
    return c;
}

fn twice(x: i32) i32 {
    return x * 2;
}

fn calls(n: i32) i32 {
    let mut c: i32 = 0;
    for i in 0..n {
        c = c + twice(i);
    }
    return c;
}

fn stride(n: i32) i32 {
    let mut c: i32 = 0;
    for mut i in 0..n {
        i = i + 1;
        c = c + i;
    }
    return c;
}

fn main() i32 {
    rt::set_worker_count(1);
    let mut g = task::TaskGroup::new();
    g.spawn(fn() {
        // Ends only by cancellation; holds the only worker unless a chunk top yields.
        let mut x: u64 = 88172645463325252;
        for i in 0..0x7FFFFFFFFFFFFFFFu64 {
            x = x ^ (x << 13);
            x = x ^ (x >> 7);
            x = x ^ (x << 17) ^ i;
            if x == 0 {
                break;
            }
        }
    });
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let wb = wg.clone();
    launch fn() {
        wb.done();
    };
    if !wg.wait_timeout(time::Duration::from_secs(30)) {
        unsafe stdlib::exit(1);
    }
    g.cancel();
    let r = g.join();
    if r.cancelled != 1 {
        unsafe stdlib::exit(2);
    }
    let res = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let rc = res.clone();
    let wd = sync::WaitGroup::new();
    wd.add(1);
    let wc = wd.clone();
    launch fn() {
        let mut v = Vector::<u32>::new();
        for k in 0..10000u32 {
            v.push(k);
        }
        let sl = v.index_range(0..v.len());
        let mut bad: i64 = 0;
        if flow(5000) != flow_while(5000) {
            bad = bad | 4;
        }
        if picks(sl) != picks_while(sl) {
            bad = bad | 8;
        }
        if narrow() != 32385 - 255 {
            bad = bad | 16;
        }
        if calls(100) != 9900 {
            bad = bad | 32;
        }
        if stride(10) != 25 {
            bad = bad | 64;
        }
        rc.get().store(bad, atom::MemoryOrder::Relaxed);
        wc.done();
    };
    wd.wait();
    rt::shutdown();
    return res.get().load(atom::MemoryOrder::Relaxed) as i32;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(
        gen_followed_by(&p, "main.c", "(uint64_t)__sc_chunk_end(&__sc_spc, i, 0x7FFFFFFFFFFFFFFFULL);", "for (; i < _"),
        "the spinner's chunk loop follows its chunk end with no tick",
    );
    assert(p.gen_has("main.c", " = __sc_cancel_tick(); }\n"), "the chunk top carries the combined safepoint");
    assert(
        p.gen_fn_has("main.c", "main__flow", "(int64_t)__sc_chunk_end(&__sc_spc, (uint64_t)j, (uint64_t)"),
        "a signed index counts through 64-bit two's complement",
    );
    assert_eq(p.gen_fn_count("main.c", "main__flow", "__sc_chunk_end"), 1);
    assert(p.gen_fn_has("main.c", "main__picks", "__sc_chunk_end(&__sc_spc, "), "a slice loop is strip-mined");
    assert(!p.gen_fn_has("main.c", "main__flow_while", "__sc_chunk_end"), "a while loop ticks per iteration");
    assert(!p.gen_fn_has("main.c", "main__calls", "__sc_chunk_end"), "a loop with a call ticks per iteration");
    assert(p.gen_fn_has("main.c", "main__calls", "__sc_preempt_check()"), "a loop with a call still ticks");
    assert(!p.gen_fn_has("main.c", "main__stride", "__sc_chunk_end"), "an assignable index ticks per iteration");
    assert(p.gen_fn_has("main.c", "main__stride", "__sc_preempt_check()"), "an assignable index still ticks");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Blocking FFI: a worker thread belongs to the scheduler, so a call that blocks it; a
// legacy library, a slow syscall: must move off the pool. `blocking::call` runs the closure on a separate
// pool of plain threads and PARKS the calling coroutine until it returns. Proven by ORDER rather than by the
// clock, which is what makes it reliable under a loaded machine: with ONE worker, four tasks each make a
// 50ms blocking call and a fifth does no blocking at all. If the calls held the worker, that fifth task
// could only run after all of them; because they park, it goes first. Leak-checked, so both pools tear down
// clean.
@test
fn blocking_call_frees_the_worker() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::blocking as blocking;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

fn main() i32 {
    rt::set_worker_count(1);
    let order = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let plain_at = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(-1));
    let sum = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(5);
    for _i in 0..4 {
        let w = wg.clone();
        let o = order.clone();
        let s = sum.clone();
        launch fn() {
            let got = blocking::call(fn() i64 {
                time::sleep(time::Duration::from_millis(50)); // off a coroutine: blocks this thread
                return 7;
            });
            let _ = s.get().fetch_add(got, atom::MemoryOrder::Relaxed);
            let _ = o.get().fetch_add(1, atom::MemoryOrder::SeqCst);
            w.done();
        };
    }
    let w2 = wg.clone();
    let o2 = order.clone();
    let p2 = plain_at.clone();
    launch fn() {
        // Whatever this reads is how many blocking calls had already finished when it ran.
        p2.get().store(o2.get().load(atom::MemoryOrder::SeqCst), atom::MemoryOrder::SeqCst);
        w2.done();
    };
    let ok = wg.wait_timeout(time::Duration::from_secs(60));
    let n = sum.get().load(atom::MemoryOrder::SeqCst);
    let at = plain_at.get().load(atom::MemoryOrder::SeqCst);
    blocking::shutdown();
    rt::shutdown();
    if !ok || n != 28 {
        return 1;
    }
    if at != 0 {
        return 2; // the worker was held: the non-blocking task had to queue behind the blocking ones
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// A coroutine stack that runs out must SAY so. The guard page turns an overflow into a fault, and without
// a handler that is a bare SIGSEGV/SIGBUS with no message: the failure mode this test exists to prevent.
// The other half matters as much: a wild pointer is NOT a stack overflow and must still crash as one,
// or the diagnosis would be a lie that hides real bugs. `set_stack_size` is what makes the first program
// pass rather than die, so all three are checked against the same recursion.
@test
fn stack_overflow_is_reported() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::platform as platform;

fn deep(n: i64) i64 {
    let mut pad = Array::<i64, 512>::new(); // 4 KiB per frame
    pad[0] = n;
    if n <= 0 {
        return pad[0];
    }
    return deep(n - 1) + pad[0];
}

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch fn() {
        let depth = 190 + platform::ncpu() as i64; // ~800 KiB of frames, and not const-foldable
        let _ = deep(depth);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let over = p.run_bin();
    assert(over != 0, "a 256 KiB stack cannot hold 800 KiB of frames");
    assert(p.run_bin_env("").out_has("stack overflow"), "and it says so instead of dying silently");

    // The same recursion fits once the task is given room for it.
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::platform as platform;

fn deep(n: i64) i64 {
    let mut pad = Array::<i64, 512>::new();
    pad[0] = n;
    if n <= 0 {
        return pad[0];
    }
    return deep(n - 1) + pad[0];
}

fn main() i32 {
    rt::set_stack_size(4194304); // 4 MiB, and the pages behind it still arrive only as they are used
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch fn() {
        let depth = 190 + platform::ncpu() as i64;
        let _ = deep(depth);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r2 = p.native_build("", "main.spc");
    assert(r2.ok());
    // 4 MiB is enough.
    assert_eq(p.run_bin(), 0);

    // A wild pointer is a crash, not a stack overflow: the message must not appear.
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::platform as platform;

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch fn() {
        let bad = (4096 + platform::ncpu()) as *mut i64;
        unsafe *bad = 1;
        w.done();
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r3 = p.native_build("", "main.spc");
    assert(r3.ok(), "the program compiles");
    let wild = p.run_bin_env("");
    assert(wild.exit != 0, "a wild write still crashes");
    assert(!wild.out_has("stack overflow"), "and is NOT reported as a stack overflow");
}

// A thread's own stack reports its overflow too, the main thread's (armed before main) and a spawned
// one's (armed by the runtime): the message names the stack and the exit status is 134, which the test
// runner reads as a panic. A null write on the main thread and a wild write on a spawned thread are
// crashes, not overflows, and must not say otherwise.
@test
fn thread_stack_overflow_is_reported() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import stdlib;
import std::parallel::thread as thread;
import std::parallel::platform as platform;

fn deep(n: i64) i64 {
    let mut pad = Array::<i64, 512>::new(); // 4 KiB per frame
    pad[0] = n;
    if n <= 0 {
        return pad[0];
    }
    return deep(n - 1) + pad[0];
}

@arch(aarch64)
fn illegal() {
    unsafe { asm("udf #0"); }
}

@arch(x86_64)
fn illegal() {
    unsafe { asm("ud2"); }
}

@arch(wasm32)
fn illegal() {}

fn mode() str<'static> {
    let m = stdlib::getenv("SO_MODE");
    if m == null {
        return "";
    }
    return unsafe str::from_cstr(m);
}

fn main() i32 {
    let depth = 100000 + platform::ncpu() as i64; // 400 MiB of frames, and not const-foldable
    if mode() == "main" {
        return deep(depth) as i32;
    }
    if mode() == "thread" {
        let h = thread::spawn(
            fn() i64 {
                return deep(depth);
            },
        );
        return h.join() as i32;
    }
    if mode() == "ill" {
        illegal();
        return 0;
    }
    if mode() == "null" {
        let bad = (platform::ncpu() - platform::ncpu()) as *mut i64;
        unsafe *bad = 1;
        return 0;
    }
    if mode() == "wild" {
        let h = thread::spawn(
            fn() i64 {
                let bad = (4096 + platform::ncpu()) as *mut i64;
                unsafe *bad = 1;
                return 0;
            },
        );
        return h.join() as i32;
    }
    return 3;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    let main_over = p.run_bin_env("SO_MODE=main ");
    assert_eq(main_over.exit, 134);
    assert(main_over.out_shows("stack overflow in the main thread"), "the main thread's overflow says so");
    let thread_over = p.run_bin_env("SO_MODE=thread ");
    assert_eq(thread_over.exit, 134);
    assert(thread_over.out_shows("stack overflow in a thread"), "a spawned thread's overflow says so");
    let null_write = p.run_bin_env("SO_MODE=null ");
    assert(null_write.exit != 0, "a null write still crashes");
    assert(null_write.exit != 134, "with its own status");
    assert(!null_write.out_has("stack overflow"), "and is NOT reported as a stack overflow");
    let wild = p.run_bin_env("SO_MODE=wild ");
    assert(wild.exit != 0, "a wild write on a thread still crashes");
    assert(wild.exit != 134, "with its own status");
    assert(!wild.out_has("stack overflow"), "and is NOT reported as a stack overflow");
    if !cli::on_windows() && !cli::on_wasm() {
        let ill = p.run_bin_env("SO_MODE=ill ");
        assert(ill.exit != 0, "an illegal instruction still ends the process");
        assert(ill.exit != 134, "by its signal, not as an overflow");
        assert(ill.out_shows("super-c: illegal instruction at 0x"), "and names the address");
    }
}

// Diagnostics: every task carries a process-unique id, the runtime accounts for tasks created
// versus finished, and a panic inside a task names it instead of only saying the process died.
@test
fn task_diagnostics() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    if rt::current_id() != 0 {
        return 1; // the main thread is not a task
    }
    let ids = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(3);
    for _i in 0..3 {
        let w = wg.clone();
        let d = ids.clone();
        launch fn() {
            if rt::current_id() != 0 {
                let _ = d.get().fetch_add(1, atom::MemoryOrder::Relaxed);
            }
            w.done();
        };
    }
    wg.wait();
    let named = ids.get().load(atom::MemoryOrder::SeqCst);
    if rt::spawned_tasks() < 3 || named != 3 {
        return 2;
    }
    rt::shutdown();
    if rt::live_tasks() != 0 {
        return 3; // every task was awaited, so none may be left parked
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());

    // A panic inside a coroutine is attributed to it.
    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;

fn main() i32 {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch fn() {
        w.done();
        panic("from inside a task");
    };
    wg.wait();
    rt::shutdown();
    return 0;
}
)",
    );
    let r2 = q.native_build("", "main.spc");
    assert(r2.ok());
    let run2 = q.run_bin_env("");
    assert(run2.exit != 0, "the panic takes the process down");
    assert(run2.out_has("[task "), "the panic names the task it happened in");

    // Tracing is off unless asked for, and then reports the scheduler's events.
    let quiet = p.run_bin_env("");
    assert(!quiet.out_has("[task "), "no trace output without SC_TASK_TRACE");
    let zero = p.run_bin_env("SC_TASK_TRACE=0 ");
    assert(!zero.out_has("[task "), "SC_TASK_TRACE=0 leaves tracing off");
    let traced = p.run_bin_env("SC_TASK_TRACE=1 ");
    assert(traced.out_has("spawn coroutine"), "SC_TASK_TRACE reports spawns");
    assert(traced.out_has("complete"), "SC_TASK_TRACE reports completions");
}

// UDP and typed failures. Every operation that can fail returns `Result<T, IoError>`, so the caller can
// say WHICH failure it was: a connect to a dead port is `Refused`, a second bind of the same port is
// `AddressInUse`, and the raw errno is kept alongside the kind. The datagram half is exercised end to end,
// both sides parking on the reactor.
@test
fn reactor_udp_and_typed_errors() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::net;
import std::parallel::io;
import std::parallel::sync;
import std::parallel::arc;
import std::parallel::atomics as atom;

fn main() i32 {
    let server = net::UdpSocket::bind("127.0.0.1", 0).unwrap();
    let port = server.port();
    let got = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(2);

    let gs = got.clone();
    let ws = wg.clone();
    launch fn() {
        let mut buf = Vector::<u8>::new();
        buf.resize_default(32);
        let cap: usize = 32;
        switch server.recv(buf.index_range_mut(0..cap)) {
            Ok(n) => {
                let _ = gs.get().fetch_add(n as i64, atom::MemoryOrder::Relaxed);
            },
            Err(_) => {},
        };
        ws.done();
    };

    let gc = got.clone();
    let wc = wg.clone();
    launch fn() {
        switch net::UdpSocket::bind("127.0.0.1", 0) {
            Ok(c) => {
                let msg: [u8; 5] = [1u8; 5];
                switch c.send_to(msg, "127.0.0.1", port) {
                    Ok(n) => {
                        let _ = gc.get().fetch_add(100 * n as i64, atom::MemoryOrder::Relaxed);
                    },
                    Err(_) => {},
                };
            },
            Err(_) => {},
        };
        wc.done();
    };

    wg.wait();
    let total = got.get().load(atom::MemoryOrder::SeqCst);
    io::shutdown();
    rt::shutdown();
    return (total - 505) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());

    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::net;
import std::parallel::io;

fn main() i32 {
    // Nothing is listening on this port: the failure should say so, not just fail.
    let mut score = 0;
    switch net::TcpStream::connect("127.0.0.1", 9) {
        Ok(c) => {
            c.free();
        },
        Err(e) => {
            switch e.kind() {
                Refused => {
                    score = score + 1;
                },
                Unreachable => {
                    score = score + 1;
                },
                _ => {},
            };
            if e.code == 0 {
                score = score - 10;
            }
        },
    };
    // Binding a port twice: the second one is in use.
    let a = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = a.port();
    switch net::TcpListener::bind("127.0.0.1", p) {
        Ok(b) => {
            b.free();
        },
        Err(e) => {
            switch e.kind() {
                AddressInUse => {
                    score = score + 1;
                },
                _ => {},
            };
        },
    };
    a.free();
    io::shutdown();
    rt::shutdown();
    return score - 2;
}
)",
    );
    let r2 = q.native_build("", "main.spc");
    assert(r2.ok());
    let run2 = q.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run2.ok());
}

// What the reactor is FOR: a hundred simultaneous connections served by two workers and one poller thread,
// each connection its own task. `blocking::call` would need a hundred threads for the same shape; here they
// are a hundred parked coroutines and a registration each. Exact counts on both ends, leak-checked.
@test
fn reactor_many_connections() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::net as net;
import std::parallel::io as io;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

const CONNS: i64 = 100;

fn main() i32 {
    rt::set_worker_count(2); // 200 connections on two workers and one reactor thread
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let port = l.port();
    let served = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let echoed = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(1);

    let ls = served.clone();
    let lw = wg.clone();
    launch fn() {
        // One acceptor task; every connection gets its own task, all parked on the reactor.
        let inner = sync::WaitGroup::new();
        for _i in 0..CONNS {
            switch l.accept() {
                Ok(s) => {
                    let cs = ls.clone();
                    let iw = inner.clone();
                    inner.add(1);
                    launch fn() {
                        let mut buf = Vector::<u8>::new();
                        for _k in 0..8 {
                            buf.push(0u8);
                        }
                        let cap: usize = 8;
                        let n = s.read(buf.index_range_mut(0..cap));
                        if n > 0 {
                            let _ = s.write(buf[0..n as usize]);
                            let _ = cs.get().fetch_add(1, atom::MemoryOrder::Relaxed);
                        }
                        iw.done();
                    };
                },
                Err(_) => {},
            };
        }
        inner.wait();
        lw.done();
    };

    let cwg = sync::WaitGroup::new();
    cwg.add(CONNS);
    for _c in 0..CONNS {
        let ce = echoed.clone();
        let cw = cwg.clone();
        launch fn() {
            switch net::TcpStream::connect("127.0.0.1", port) {
                Ok(c) => {
                    let msg: [u8; 4] = [112u8, 105u8, 110u8, 103u8];
                    let _ = c.write(msg);
                    let mut back = Vector::<u8>::new();
                    for _k in 0..8 {
                        back.push(0u8);
                    }
                    let cap: usize = 8;
                    let n = c.read(back.index_range_mut(0..cap));
                    if n == 4 && *back.at(3) == 103u8 {
                        let _ = ce.get().fetch_add(1, atom::MemoryOrder::Relaxed);
                    }
                },
                Err(_) => {},
            };
            cw.done();
        };
    }
    cwg.wait();
    wg.wait();
    let s = served.get().load(atom::MemoryOrder::SeqCst);
    let e = echoed.get().load(atom::MemoryOrder::SeqCst);
    io::shutdown();
    rt::shutdown();
    if s != CONNS || e != CONNS {
        return 1;
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// `@blocking`: the attribute makes a call to an extern function go through a generated
// wrapper that hands it to the blocking pool, so the call site is unchanged but the coroutine parks instead
// of holding its worker. Two blocking calls on ONE worker return only once a third task has opened their
// gate: that task runs only on the worker, so the calls return the open gate only if they did not hold
// it (a held worker keeps the gate shut until the C side gives up, and the calls report that). The
// emitted C is checked for the wrapper too.
@test
fn blocking_attribute() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("gate.h", "int gate_wait(void);\nvoid gate_open(void);\n");
    p.mkfile(
        "gate.c",
        M"(#include "gate.h"
#include <stdatomic.h>
#if defined(_WIN32)
#include <windows.h>
static void nap(void) { Sleep(1); }
#else
#include <time.h>
static void nap(void) {
  struct timespec t = {0, 1000000};
  nanosleep(&t, 0);
}
#endif
static atomic_int gate;
/* 1 once the gate opens; 0 when it stays shut for twenty seconds (the hang guard). */
int gate_wait(void) {
  for (int i = 0; i < 20000; i++) {
    if (atomic_load(&gate))
      return 1;
    nap();
  }
  return 0;
}
void gate_open(void) { atomic_store(&gate, 1); }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::blocking as blocking;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;
import std::time as time;

extern "C" "gate.h" {
    @blocking
    pub fn gate_wait() i32;
    pub fn gate_open();
}

fn main() i32 {
    rt::set_worker_count(1);
    let done = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(3);
    for _i in 0..2 {
        let d = done.clone();
        let w = wg.clone();
        launch fn() {
            // a blocking call that returns once the task below has run: it must not hold the only worker
            let _ = d.get().fetch_add(unsafe gate_wait() as i64, atom::MemoryOrder::Relaxed);
            w.done();
        };
    }
    let d2 = done.clone();
    let w2 = wg.clone();
    launch fn() {
        let _ = d2.get().fetch_add(100, atom::MemoryOrder::Relaxed);
        unsafe gate_open();
        w2.done();
    };
    let ok = wg.wait_timeout(time::Duration::from_secs(60));
    let n = done.get().load(atom::MemoryOrder::SeqCst);
    blocking::shutdown();
    rt::shutdown();
    if !ok || n != 102 {
        return 1;
    }
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main.c", "__sc_blk_main__gate_wait("), "the call goes through the generated wrapper");
    let cc = p.cc_build_with("", "gate.c");
    assert(cc.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// A plain program that calls through the blocking pool and never shuts it down: the pool is
// released at normal exit, so the leak gate finds nothing (a `@blocking` extern and `call`).
@test
fn blocking_pool_released_at_exit() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::blocking as blocking;

@platform(macos | linux)
extern "C" "unistd.h" {
    @blocking
    pub fn sleep(s: u32) u32;
}

fn main() i32 {
    let v = blocking::call(fn() i64 {
        return 4;
    });
    if PLATFORM == Platform::MacOS || PLATFORM == Platform::Linux {
        let _ = unsafe sleep(0);
    }
    return (v - 4) as i32;
}
)",
    );
    assert(p.native_build("", "main.spc").ok());
    if cli::on_wasm() {
        return;
    }
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// A small program's C tree compiles its module, instance and registry units as one unit: `__sc_unity.c`
// includes them, and `__units` names it alone (no member of it).
@test
fn small_program_compiles_as_one_unit() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", "@noinline\npub fn three() i32 {\n    return 3;\n}\n");
    p.mkfile(
        "src/main.spc",
        "import util;\n\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(util::three());\n    return v[0];\n}\n",
    );
    let root = p.dir();
    assert(cli::superc_in(root, "build --emit-c").ok());
    let unity = cli::read_text(format("{}/build/debug/raw/__sc_unity.c", root).as_str());
    assert(
        unity.contains("#include \"main.c\"") && unity.contains("#include \"util.c\""),
        "the unit includes the modules",
    );
    let units = cli::read_text(format("{}/build/debug/raw/__units", root).as_str());
    assert(units.contains("__sc_unity.c\n") && !units.contains("main.c"), "only the unit compiles");
    if cli::has_cc() {
        assert(p.cc_build_plain("").ok(), "the C compiler builds the tree");
        assert_eq(p.run_bin(), 3);
    }
}

// A program over the one-unit limit compiles its small units in packs: `__sc_pack<k>.c` includes them,
// `__units` names the pack (no member of it), and `__sc_shards` records the pack count.
@test
fn small_units_compile_in_packs() {
    let _unit = cli::set_env("SC_UNITY_MAX", "1"); // over the limit: no `__sc_unity.c`
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", "@noinline\npub fn three() i32 {\n    return 3;\n}\n");
    p.mkfile("src/main.spc", "import util;\n\nfn main() i32 {\n    return util::three();\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build --emit-c").ok());
    let pack = cli::read_text(format("{}/build/debug/raw/__sc_pack0.c", root).as_str());
    assert(
        pack.contains("#include \"main.c\"") && pack.contains("#include \"util.c\""),
        "the pack includes the modules",
    );
    assert(cli::read_text(format("{}/build/debug/raw/__sc_shards", root).as_str()).contains("\npacks\t1\n"));
    let units = cli::read_text(format("{}/build/debug/raw/__units", root).as_str());
    assert(units.contains("__sc_pack0.c\n") && !units.contains("main.c"), "only the pack compiles");
}

// Two modules that bind one C function as `@blocking` get a wrapper each: the wrappers are named by
// their module, so the program links (one name for both was a duplicate symbol).
@test
fn blocking_wrappers_of_one_function_in_two_modules() {
    let p = cli::proj_new();
    p.mkfile(
        "other.spc",
        M"(@platform(macos | linux)
extern "C" "unistd.h" {
    @blocking
    pub fn sleep(s: u32) u32;
}

pub fn nap() u32 {
    if PLATFORM == Platform::MacOS || PLATFORM == Platform::Linux {
        return unsafe sleep(0);
    }
    return 0;
}
)",
    );
    p.mkfile(
        "main.spc",
        M"(import other;

@platform(macos | linux)
extern "C" "unistd.h" {
    @blocking
    pub fn sleep(s: u32) u32;
}

fn main() i32 {
    let mut r: u32 = other::nap();
    if PLATFORM == Platform::MacOS || PLATFORM == Platform::Linux {
        r += unsafe sleep(0);
    }
    return r as i32;
}
)",
    );
    assert(p.native_build("", "main.spc").ok());
    if cli::on_wasm() {
        return;
    }
    assert(p.run_bin_env("").ok());
}

// A pointer to an array of aggregates names the array's wrapper struct, an array's address converts
// to it as a value, and a pointer to an array spells its element with no qualifier (C11 rejects
// `&a` as a pointer to an array of const elements): the emitted C passes a pedantic C11 compile with
// the most aggressive strict-aliasing diagnostics.
@test
fn array_pointers_are_strict_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Node { pub kids: *mut [Node; 2], pub v: i32 }
struct A { pub bs: *const [B; 2], pub x: i32 }
struct B { pub a: *mut [A; 3], pub y: i32 }
struct F { pub f: fn(*mut [F; 2]) i32, pub v: i32 }
struct P { pub x: i32, pub y: i32 }

fn sum(n: *const Node) i32 {
    let k = unsafe (*n).kids;
    if k == null {
        return unsafe (*n).v;
    }
    return unsafe (*n).v + sum(unsafe &(*k)[0]) + sum(unsafe &(*k)[1]);
}

fn first(p: *mut [F; 2]) i32 {
    return unsafe (*p)[0].v;
}

fn cread(q: *const [i32; 2]) i32 {
    return unsafe (*q)[1];
}

fn total(s: [][P; 2]) i32 {
    let mut t = 0;
    for pr in s {
        t += pr[0].x + pr[1].y;
    }
    return t;
}

fn main() i32 {
    let mut leaves: [Node; 2] = [Node { kids: null, v: 1 }, Node { kids: null, v: 2 }];
    let mut two: [[Node; 2]; 2] = [leaves, leaves];
    let p0: *mut [Node; 2] = &mut two[0];
    let root = Node { kids: &mut leaves, v: 100 };
    let r3 = Node { kids: unsafe (p0 + 1), v: 0 };
    if sum(&root) != 103 || unsafe (*(r3.kids - 1))[1].v != 2 {
        return 1;
    }
    let mut as3: [A; 3] = [A { bs: null, x: 1 }, A { bs: null, x: 2 }, A { bs: null, x: 3 }];
    let bs: [B; 2] = [B { a: &mut as3, y: 5 }, B { a: null, y: 6 }];
    as3[2].bs = &bs;
    if unsafe (*as3[2].bs)[1].y != 6 {
        return 2;
    }
    let mut fs: [F; 2] = [F { f: first, v: 3 }, F { f: first, v: 4 }];
    if (fs[1].f)(&mut fs) != 3 {
        return 3;
    }
    let mut xs: [i32; 2] = [7, 8];
    let cq: *const [i32; 2] = &xs;
    let mq: *mut [i32; 2] = &mut xs;
    if cread(cq) + cread(mq) != 16 {
        return 4;
    }
    let mut v = Vector::<[P; 2]>::new();
    v.push([P { x: 1, y: 2 }, P { x: 3, y: 4 }]);
    v.push([P { x: 5, y: 6 }, P { x: 7, y: 8 }]);
    let grid: [[P; 2]; 2] = [[P { x: 1, y: 1 }, P { x: 2, y: 2 }], [P { x: 3, y: 3 }, P { x: 4, y: 4 }]];
    return total(v[0..2]) + total(grid) - 28;
}
)",
    );
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("__sc_t/Node.h", "Node__a2 *kids;"), "the member points at the wrapper");
    if cli::on_wasm() {
        return;
    }
    assert(p.cc_build("-pedantic-errors -Wstrict-aliasing=1 -fstrict-aliasing -O2 ").ok());
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// Guided scheduling: each claim takes a share of what REMAINS rather than a fixed grain, so early claims
// are large (few trips to the shared cursor) and late ones small (no worker left holding a long tail).
// Over a deliberately uneven per-index cost, every index must still be visited exactly once.
@test
fn data_parallel_guided_schedule() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::data as parallel;
import std::parallel::atomics as atom;

fn main() i32 {
    let n: usize = 4000;
    let hits = atom::Atomic::<i64>::new(0);
    let hp = &hits;
    parallel::range_with(0..n, parallel::Options { schedule: parallel::Schedule::Guided, grain_size: 8 }, fn(i: usize) {
        let mut acc: i64 = 0;
        for k in 0..(i % 23) {
            acc = acc + k as i64;
        }
        let _ = hp.fetch_add(1 + acc * 0, atom::MemoryOrder::Relaxed);
    });
    let got = hits.load(atom::MemoryOrder::SeqCst);
    rt::shutdown();
    return (got - n as i64) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// `@blocking` packs a call's arguments into a frame for the pool thread to run from, which a variadic call
// has no fixed shape for. Saying so beats codegen quietly emitting an ordinary worker-blocking call.
@test
fn blocking_attribute_rejects_variadic() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(extern "C" "fcntl.h" {
    @blocking
    pub fn open(path: *const char, flags: i32, ...) i32;
}

fn main() i32 {
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "@blocking on a variadic is rejected");
    assert(r.out_has("variadic"), "the message says why");
}

// Deterministic replay (std/parallel/runtime): `SC_SCHED_SEED` pins the pool to one worker and hands every
// preemption decision to the seed, so the SAME binary run twice with the same seed takes the same
// interleaving. Proven by the interleaving itself, not by a summary: four tasks compete for one mutex and
// each append their id, so the logged order IS the schedule. Two runs at one seed must match byte for byte,
// and the same must hold at a second seed: one matching pair could be a program with only one possible
// order. Not asserted: that two DIFFERENT seeds disagree; nothing promises a given seed pair diverges.
@test
fn deterministic_replay() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;

fn main() i32 {
    let log = arc::Arc::<sync::Mutex<String>>::new(sync::Mutex::<String>::new(String::new()));
    let wg = sync::WaitGroup::new();
    wg.add(4);
    for t in 0..4 {
        let l = log.clone();
        let w = wg.clone();
        launch fn() {
            for _r in 0..15 {
                // Real backedges, because a safepoint is what gives the seed somewhere to preempt.
                let mut spin: i64 = 0;
                for k in 0..20000 {
                    spin = spin + k;
                }
                let mut g = l.get().lock();
                g.get_mut().push_i64(t + spin - spin);
            }
            w.done();
        };
    }
    wg.wait();
    let g = log.get().lock();
    println("order={}", g.get().as_str());
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    for s in 0..2 {
        let env = if s == 0 {
            "SC_SCHED_SEED=7 ";
        } else {
            "SC_SCHED_SEED=1234567 ";
        };
        let a = p.run_bin_env(env);
        assert(a.ok());
        let b = p.run_bin_env(env);
        assert(b.ok());
        let sa = unsafe str::from_cstr(a.out);
        let sb = unsafe str::from_cstr(b.out);
        assert(sa.len() > 60, "the fixture logged an order");
        assert(sa == sb, "the same seed replays the same interleaving");
    }
}

// Lock-order tracking (`SC_LOCK_ORDER`): a deadlock is reported the first time two locks are taken in
// OPPOSITE orders, not the first time the program hangs. That is what makes it testable at all: this
// program takes A then B, releases both, then takes B then A, and never blocks for a moment. Off by
// default (silent, exit 0), reporting at `=1`, aborting at `=fatal`.
@test
fn lock_order_inversion() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::sync as sync;

fn main() i32 {
    let a = sync::Mutex::<i64>::new(0);
    let b = sync::Mutex::<i64>::new(0);
    {
        let ga = a.lock();
        let gb = b.lock();
    }
    {
        let gb = b.lock();
        let ga = a.lock();
    }
    return 0;
}
)",
    );
    // The profile's `lockdep` (the build constant LOCKDEP) is what compiles the hooks in at all: they sit
    // on a lock fast path of one CAS, so an ungated call to check an env flag tripled `mutex_uncontended`.
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n\n[profile.debug]\nlockdep = true\n");
    assert(cli::superc_in(p.dir(), "build -o bin").ok(), "the build with `lockdep`");
    // Compiled in but not switched on: an inversion costs nothing and says nothing.
    let quiet = p.run_bin();
    assert_eq(quiet, 0);
    let on = p.run_bin_env("SC_LOCK_ORDER=1 ");
    assert(on.ok());
    assert(on.out_has("lock order inversion"), "expected the inversion to be reported");
}

// Batched channel traffic (`send_batch` / `recv_batch`): 100 items through a bounded(8) ring, so the batch
// send fills the buffer, blocks, and resumes mid-batch several times while the batched receiver drains it:
// the interleaving the per-item path never exercises. Three properties are checked: every item arrives
// exactly once (count and sum), a batch the channel refuses outright leaves its items in the caller's vector
// IN THE ORIGINAL ORDER (the method reverses internally to pop in O(1), and must reverse back), and nothing
// leaks: neither the un-sent remainder nor the payloads still buffered when the channel is freed.
@test
fn channel_batch_send_recv() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;

fn main() i32 {
    let ch = chan::Channel::<i64>::bounded(8);
    let rx = ch.receiver();
    let tx = ch.sender();
    launch fn() {
        let mut v = Vector::<i64>::new();
        for i in 0..100 {
            v.push(i);
        }
        // A short send leaves items in `v`, and the count and sum below both fall short of the total.
        let _ = tx.send_batch(&mut v);
        tx.close();
    };
    let mut got = Vector::<i64>::new();
    let mut total: i64 = 0;
    let mut n: i64 = 0;
    loop {
        let k = rx.recv_batch(&mut got, 16);
        if k == 0 {
            break;
        }
        n = n + k as i64;
        for i in 0..got.len() {
            total = total + got[i];
        }
        got.clear();
    }

    // A closed channel sends nothing and hands the whole batch back, unreordered.
    let c2 = chan::Channel::<i64>::bounded(4);
    let r2 = c2.receiver();
    let t2 = c2.sender();
    t2.close();
    let mut rest = Vector::<i64>::new();
    for i in 0..5 {
        rest.push(i);
    }
    let kept = t2.send_batch(&mut rest);
    let mut ordered = 0;
    for i in 0..rest.len() {
        if rest[i] != i as i64 {
            ordered = 1;
        }
    }
    let bad = kept as i32 + (rest.len() - 5) as i32 + ordered;

    rt::shutdown();
    return (n - 100) as i32 + (total - 4950) as i32 + bad;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Task-aware parking: 50 coroutines (30 producers + 20 consumers) share a bounded(2) channel; MORE
// coroutines than worker threads. When a coroutine blocks on send/recv it PARKS (via the dual-mode
// `Condvar`), freeing its worker to run others; under the old block-the-OS-thread model this would deadlock
// (every worker stuck inside a blocked coroutine, none left to make progress). All 300 items are delivered
// exactly once. Every handle is created before any coroutine launches, so no send is rejected for want of a
// receiver. Leak-checked.
@test
fn channel_parking_oversubscribed() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    let ch = chan::Channel::<i64>::bounded(2);
    let cnt = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(50);
    let mut senders = Vector::<chan::Sender<i64>>::new();
    for _p in 0..30 {
        senders.push(ch.sender());
    }
    let mut recvs = Vector::<chan::Receiver<i64>>::new();
    for _c in 0..20 {
        recvs.push(ch.receiver());
    }
    while senders.len() > 0 {
        let s = senders.pop().unwrap();
        let w = wg.clone();
        launch fn() {
            for _i in 0..10 {
                let _ = s.send(7);
            }
            w.done();
        };
    }
    while recvs.len() > 0 {
        let r = recvs.pop().unwrap();
        let ct = cnt.clone();
        let w = wg.clone();
        launch fn() {
            loop {
                switch r.recv() {
                    Some(_) => {
                        let _ = ct.get().fetch_add(1, atom::MemoryOrder::Relaxed);
                    },
                    None => {
                        break;
                    },
                };
            }
            w.done();
        };
    }
    wg.wait();
    let n = cnt.get().load(atom::MemoryOrder::SeqCst);
    rt::shutdown();
    return (n - 300) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// `sleep` and the scheduler's timer list: a sleeping coroutine parks on its deadline instead of holding its
// worker. Proven structurally, not by timing: with exactly ONE worker, a task that sleeps 50ms and a task
// that sleeps not at all race to claim an atomic; only a parking sleep lets the second one win. The elapsed
// time then confirms the sleep really slept, and the plain-thread path (no coroutine) sleeps outright.
@test
fn coroutine_sleep_and_timers() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::time as time;
import std::parallel::platform as platform;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    rt::set_worker_count(1); // one worker: a blocking sleep would serialize the two tasks below

    let t0 = platform::now_ns();
    time::sleep(time::Duration::from_millis(5)); // off a coroutine: sleeps the thread
    if platform::now_ns() - t0 < 4000000 {
        return 1;
    }

    let order = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let oa = order.clone();
    let wa = wg.clone();
    launch fn() {
        time::sleep(time::Duration::from_millis(50));
        let _ = oa.get().compare_exchange(0, 1, atom::MemoryOrder::SeqCst, atom::MemoryOrder::Relaxed);
        wa.done();
    };
    let ob = order.clone();
    let wb = wg.clone();
    launch fn() {
        let _ = ob.get().compare_exchange(0, 2, atom::MemoryOrder::SeqCst, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    let t1 = platform::now_ns();
    wg.wait();
    let waited = platform::now_ns() - t1;
    let first = order.get().load(atom::MemoryOrder::SeqCst);
    rt::shutdown();
    if first != 2 {
        return 2; // the sleeper kept the only worker: sleep did not park
    }
    if waited < 40000000 {
        return 3; // the sleep did not actually wait
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Task-aware `Mutex` / `RwLock` acquisition. On ONE worker: task A takes the mutex and then blocks on a
// semaphore (parking while HOLDING the lock), task B tries to take that mutex (it must park, not sit on the
// worker), and task C sleeps, releases the semaphore and lets both finish. Under an OS-blocking acquire, B
// would occupy the only worker and C could never run: the run deadlocks instead of returning. Also covers
// read/write guards taken from coroutines and a timed acquire that expires and then succeeds. Leak-checked.
@test
fn task_aware_locks() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::time as time;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    rt::set_worker_count(1);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let rw = arc::Arc::<sync::RwLock<i64>>::new(sync::RwLock::<i64>::new(0));
    let sem = sync::Semaphore::new(0);
    let wg = sync::WaitGroup::new();
    wg.add(3);

    let ma = m.clone();
    let sa = sem.clone();
    let wa = wg.clone();
    launch fn() {
        let mut g = ma.get().lock();
        sa.acquire(); // parks while holding the lock
        let v = g.get_mut();
        *v = *v + 1;
        wa.done();
    };
    let mb = m.clone();
    let rb = rw.clone();
    let wb = wg.clone();
    launch fn() {
        let mut g = mb.get().lock(); // contended: must park
        let v = g.get_mut();
        *v = *v + 10;
        let mut w = rb.get().write();
        let n = w.get_mut();
        *n = *n + 5;
        wb.done();
    };
    let sc = sem.clone();
    let rc = rw.clone();
    let wc = wg.clone();
    launch fn() {
        {
            let g = rc.get().read();
            let _ = *g.get();
        }
        time::sleep(time::Duration::from_millis(10));
        sc.release();
        wc.done();
    };
    wg.wait();

    let lg = m.get().lock();
    let total = *lg.get();
    lg.free();
    let rg = rw.get().read();
    let written = *rg.get();
    rg.free();

    // A timed acquire on an exhausted semaphore expires; once a permit is back it succeeds.
    let flags = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg2 = sync::WaitGroup::new();
    wg2.add(1);
    let s2 = sem.clone();
    let fl = flags.clone();
    let w2 = wg2.clone();
    launch fn() {
        if !s2.acquire_timeout(time::Duration::from_millis(10)) {
            let _ = fl.get().fetch_add(1, atom::MemoryOrder::Relaxed);
        }
        s2.release();
        if s2.acquire_timeout(time::Duration::from_millis(2000)) {
            let _ = fl.get().fetch_add(10, atom::MemoryOrder::Relaxed);
        }
        w2.done();
    };
    wg2.wait();
    let f = flags.get().load(atom::MemoryOrder::SeqCst);

    rt::shutdown();
    if total != 11 {
        return 1;
    }
    if written != 5 {
        return 2;
    }
    if f != 11 {
        return 3;
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Unbounded channels and channel timeouts: 100 sends with nobody draining must all be accepted (the ring
// grows, no sender ever waits), a timed `recv` on an empty channel expires after its deadline and then takes
// a value that arrives, and a timed `send` into a full bounded(1) channel hands the value back instead of
// waiting forever. Leak-checked, so the grown slot array and every payload are accounted for.
@test
fn channel_unbounded_and_timeouts() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::time as time;
import std::parallel::platform as platform;

fn main() i32 {
    let ch = chan::Channel::<i64>::unbounded();
    let rx = ch.receiver();
    let tx = ch.sender();
    let mut sum: i64 = 0;
    for i in 0..100 {
        switch tx.send(i) {
            Sent => {},
            Rejected(_) => {
                return 1;
            },
        };
    }
    for _i in 0..100 {
        switch rx.recv() {
            Some(v) => {
                sum = sum + v;
            },
            None => {
                return 2;
            },
        };
    }

    let t0 = platform::now_ns();
    switch rx.recv_timeout(time::Duration::from_millis(10)) {
        Some(_) => {
            return 3;
        },
        None => {},
    };
    if platform::now_ns() - t0 < 9000000 {
        return 4;
    }
    let _ = tx.send(41);
    switch rx.recv_timeout(time::Duration::from_millis(2000)) {
        Some(v) => {
            sum = sum + v;
        },
        None => {
            return 5;
        },
    };

    let b = chan::Channel::<i64>::bounded(1);
    let brx = b.receiver();
    let btx = b.sender();
    let _ = btx.send(1);
    switch btx.send_timeout(2, time::Duration::from_millis(10)) {
        Sent => {
            return 6;
        },
        Rejected(v) => {
            sum = sum + v;
        },
    };
    rt::shutdown();
    return (sum - 4993) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Every timed wait racing its own deadline, on purpose: with one-nanosecond timeouts the timer fires while
// the parking worker is still handing the coroutine off, so a wakeup must be claimed by exactly ONE waker
// (notify or deadline) and the hand-off must not read fields the resumed coroutine has already reused. Both
// were real bugs: a stale wait node resuming a later park, and a double release through a cleared commit
// argument (`pthread_mutex_unlock(NULL)`). 40 tasks x 25 rounds over a semaphore, a bounded channel, sleeps,
// yields and a shared mutex; the exact counter proves no wakeup was lost or double-spent. Leak-checked.
@test
fn timed_wait_deadline_races() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::time as time;
import std::parallel::arc as arc;

fn main() i32 {
    let sem = sync::Semaphore::new(0);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    let ch = chan::Channel::<i64>::bounded(1);
    let rxs = ch.receiver();
    let txs = ch.sender();
    wg.add(40);
    for _i in 0..40 {
        let s = sem.clone();
        let w = wg.clone();
        let mm = m.clone();
        let tx = txs.clone();
        let rx = rxs.clone();
        launch fn() {
            for _k in 0..25 {
                let _ = s.acquire_timeout(time::Duration::from_nanos(1));
                let _ = rx.recv_timeout(time::Duration::from_nanos(1));
                let _ = tx.send_timeout(1, time::Duration::from_nanos(1));
                time::sleep(time::Duration::from_nanos(1));
                rt::yield_now();
                {
                    let mut g = mm.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
            }
            w.done();
        };
    }
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 9;
    }
    let lg = m.get().lock();
    let locked = *lg.get();
    lg.free();
    loop {
        switch rxs.try_recv() {
            Some(_) => {},
            None => {
                break;
            },
        };
    }
    rt::shutdown();
    return (locked - 1000) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Multi-way waiting (std/parallel/select): one consumer coroutine waits on TWO channels at once while two
// producers feed them 100 items each through single-slot buffers. It parks on both queues under one wake
// token, so every wake comes from whichever channel moved first; the exact total proves no item was lost
// and no wakeup was double-spent. The second half checks that a selector really parks rather than spinning:
// the value is sent only once the runtime shows the task parked in its select. Leak-checked.
@test
fn select_waits_on_several_channels() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::selector as selector;
import std::parallel::sync as sync;
import std::time as time;
import std::parallel::platform as platform;
import std::parallel::arc as arc;

fn main() i32 {
    let a = chan::Channel::<i64>::bounded(1);
    let arx = a.receiver();
    let atx = a.sender();
    let b = chan::Channel::<i64>::bounded(1);
    let brx = b.receiver();
    let btx = b.sender();
    let total = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();

    wg.add(1);
    {
        let rx1 = arx.clone();
        let rx2 = brx.clone();
        let w = wg.clone();
        let acc = total.clone();
        launch fn() {
            let mut s = selector::Selector::new();
            let i1 = s.arm_recv(&rx1);
            let _ = s.arm_recv(&rx2);
            let mut sum: i64 = 0;
            let mut n = 0;
            while n < 200 {
                switch s.wait_timeout(time::Duration::from_secs(60)) {
                    Ready(i) => {
                        let v = if i == i1 {
                            rx1.try_recv();
                        } else {
                            rx2.try_recv();
                        };
                        switch v {
                            Some(x) => {
                                sum = sum + x;
                                n = n + 1;
                            },
                            None => {},
                        };
                    },
                    TimedOut => {
                        n = 1000; // give up: the wait must not time out
                    },
                };
            }
            {
                let mut g = acc.get().lock();
                let p = g.get_mut();
                *p = sum;
            }
            w.done();
        };
    }
    wg.add(2);
    {
        let tx = atx.clone();
        let w = wg.clone();
        launch fn() {
            for i in 0..100 {
                let _ = tx.send(i);
            }
            w.done();
        };
    }
    {
        let tx = btx.clone();
        let w = wg.clone();
        launch fn() {
            for i in 0..100 {
                let _ = tx.send(1000 + i);
            }
            w.done();
        };
    }
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 1;
    }
    let mut sum: i64 = 0;
    {
        let g = total.get().lock();
        sum = *g.get();
    }
    if sum != 109900 {
        return 2; // 2 x (0+..+99) + 100 x 1000
    }

    // A selector inside a coroutine must PARK, not spin: nothing is ready until it is parked.
    let res = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(-1));
    wg.add(1);
    {
        let rx1 = arx.clone();
        let rx2 = brx.clone();
        let w = wg.clone();
        let out = res.clone();
        launch fn() {
            let mut s = selector::Selector::new();
            let _ = s.arm_recv(&rx1);
            let i2 = s.arm_recv(&rx2);
            let mut r: i64 = -2;
            switch s.wait_timeout(time::Duration::from_secs(60)) {
                Ready(i) => {
                    if i == i2 {
                        r = rx2.try_recv().unwrap_or(-3);
                    } else {
                        r = -4;
                    }
                },
                TimedOut => {
                    r = -5;
                },
            };
            {
                let mut g = out.get().lock();
                let p = g.get_mut();
                *p = r;
            }
            w.done();
        };
    }
    let deadline = platform::now_ns() + 10000000000;
    while rt::tasks_waiting(rt::WK_SELECT) < 1 {
        if platform::now_ns() > deadline {
            return 6;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    let _ = btx.send(42);
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 3;
    }
    let mut got: i64 = 0;
    {
        let g = res.get().lock();
        got = *g.get();
    }
    rt::shutdown();
    if got != 42 {
        return 4;
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// The rest of the selector's surface. A send arm on a FULL channel is not ready until a drainer makes room
// 60ms later, and the wait must have blocked for it. A closed, drained receive arm is ready at once (its
// `try_recv` reports `None`), which is what stops a select from hanging on a dead channel. And with two
// arms permanently ready, 200 waits must pick BOTH: the uniform pick among ready arms is what keeps a
// busy channel from starving a quiet one (declaration order would return arm 0 every time). Leak-checked.
@test
fn select_arms_and_fairness() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::selector as selector;
import std::parallel::sync as sync;
import std::time as time;
import std::parallel::platform as platform;

fn main() i32 {
    let a = chan::Channel::<i64>::bounded(1);
    let arx = a.receiver();
    let atx = a.sender();
    let _ = atx.send(1); // full: the send arm cannot proceed
    let wg = sync::WaitGroup::new();
    wg.add(1);
    {
        let rx = arx.clone();
        let w = wg.clone();
        launch fn() {
            time::sleep(time::Duration::from_millis(60));
            let _ = rx.try_recv();
            w.done();
        };
    }
    let mut s = selector::Selector::new();
    let si = s.arm_send(&atx);
    let t0 = platform::now_ns();
    switch s.wait_timeout(time::Duration::from_secs(60)) {
        Ready(i) => {
            if i != si {
                return 1;
            }
        },
        TimedOut => {
            return 2;
        },
    };
    if platform::now_ns() - t0 < 50000000 {
        return 3; // it must have waited for the drain
    }
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 4;
    }

    let c = chan::Channel::<i64>::bounded(1);
    let crx = c.receiver();
    let ctx = c.sender();
    ctx.close();
    let mut s2 = selector::Selector::new();
    let _ = s2.arm_recv(&crx);
    switch s2.wait_timeout(time::Duration::from_millis(10)) {
        Ready(_) => {
            switch crx.try_recv() {
                Some(_) => {
                    return 5;
                },
                None => {},
            };
        },
        TimedOut => {
            return 6; // a closed channel is ready, not a timeout
        },
    };

    let d = chan::Channel::<i64>::unbounded();
    let drx = d.receiver();
    let dtx = d.sender();
    let e = chan::Channel::<i64>::unbounded();
    let erx = e.receiver();
    let etx = e.sender();
    for _i in 0..200 {
        let _ = dtx.send(1);
        let _ = etx.send(2);
    }
    let mut s3 = selector::Selector::new();
    let di = s3.arm_recv(&drx);
    let ei = s3.arm_recv(&erx);
    let mut hits_d = 0;
    let mut hits_e = 0;
    for _i in 0..200 {
        switch s3.poll() {
            Ready(i) => {
                if i == di {
                    hits_d = hits_d + 1;
                    let _ = drx.try_recv();
                } else if i == ei {
                    hits_e = hits_e + 1;
                    let _ = erx.try_recv();
                }
            },
            TimedOut => {
                return 7;
            },
        };
    }
    if hits_d == 0 || hits_e == 0 {
        return 8; // one arm never won: the pick is not fair
    }
    loop {
        switch drx.try_recv() {
            Some(_) => {},
            None => {
                break;
            },
        };
    }
    loop {
        switch erx.try_recv() {
            Some(_) => {},
            None => {
                break;
            },
        };
    }
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// The `select` keyword end to end: it lowers (src/hir) to the same `Selector` the test above drives by
// hand, so what is checked here is the LOWERING: an arm binds exactly what its operation returns, only the
// winning arm's body runs, a `timeout` arm bounds the wait, a `default` arm makes it never wait at all, the
// sent value is evaluated only in the branch that won, and a select nested inside an arm body works (the
// desugar lowers inner markers first). Also covers a field-path channel and a select that PARKS inside a
// coroutine. Leak-checked.
@test
fn select_keyword() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::sync as sync;
import std::time as time;
import std::parallel::arc as arc;

struct Pair {
    pub rx: chan::Receiver<i64>,
    pub tx: chan::Sender<i64>,
}

fn main() i32 {
    let a = chan::Channel::<i64>::bounded(4);
    let pair = Pair { rx: a.receiver(), tx: a.sender() };
    let b = chan::Channel::<i64>::bounded(1);
    let brx = b.receiver();
    let btx = b.sender();
    let c = chan::Channel::<i64>::bounded(4);
    let crx = c.receiver();
    let ctx = c.sender();
    let _ = btx.send(1); // b is now FULL: its send arm cannot proceed, its recv arm can

    // Exactly one arm is ever ready, so the winner is not a coin flip: `c` stays empty throughout.
    let _ = pair.tx.send(7);
    let mut got: i64 = -1;
    select {
        v = pair.rx.recv() => {
            got = v.unwrap_or(-2);
            // a select nested in an arm body: the desugar lowers the inner marker first
            select {
                w = brx.recv() => {
                    got = got + 10 * w.unwrap_or(0);
                }
                timeout(time::Duration::from_secs(60)) => {
                    got = -3;
                }
            }
        }
        crx.recv() => {
            got = -4;
        }
        timeout(time::Duration::from_secs(60)) => {
            got = -5;
        }
    }
    if got != 17 {
        return 1;
    }

    // A send arm: the nested recv above drained `b`, so there is room and the send wins.
    select {
        crx.recv() => {
            got = -6;
        }
        r = btx.send(9) => {
            got = switch r {
                Sent => 42i64,
                Rejected(_) => -7i64,
            };
        }
    }
    if got != 42 {
        return 2;
    }
    switch brx.try_recv() {
        Some(x) => {
            if x != 9 {
                return 3;
            }
        },
        None => {
            return 4;
        },
    };

    // A `default` arm: nothing is ready, so it fires at once instead of waiting.
    select {
        crx.recv() => {
            got = -8;
        }
        default => {
            got = 99;
        }
    }
    if got != 99 {
        return 5;
    }

    // A select that PARKS: nothing arrives for 60ms.
    let out = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(-1));
    let wg = sync::WaitGroup::new();
    wg.add(1);
    {
        let rx = pair.rx.clone();
        let rx2 = crx.clone();
        let w = wg.clone();
        let o = out.clone();
        launch fn() {
            let mut r: i64 = -9;
            select {
                v = rx.recv() => {
                    r = v.unwrap_or(-10);
                }
                v = rx2.recv() => {
                    r = 1000 + v.unwrap_or(0);
                }
                timeout(time::Duration::from_secs(60)) => {
                    r = -11;
                }
            }
            {
                let mut g = o.get().lock();
                let p = g.get_mut();
                *p = r;
            }
            w.done();
        };
    }
    time::sleep(time::Duration::from_millis(60));
    let _ = pair.tx.send(77);
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 6;
    }
    let mut parked: i64 = 0;
    {
        let g = out.get().lock();
        parked = *g.get();
    }
    rt::shutdown();
    if parked != 77 {
        return 7;
    }
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// A `select` whose arms are malformed. Each one is reported on its own: a bad arm still consumes its
// `=> { .. }`, so one mistake does not cascade into the rest of the function, and the whole-statement
// rules (at least one channel arm; `timeout` and `default` are mutually exclusive) are checked too.
@test
fn select_keyword_diagnostics() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::channel as chan;

fn make() chan::Receiver<i64> {
    let a = chan::Channel::<i64>::bounded(1);
    let r = a.receiver();
    return r;
}

fn main() i32 {
    let rx = make();
    select {
        v = rx.poll() => {}
        v = rx.recv() => {}
    }
    select {
        timeout(1) => {}
    }
    select {
        v = make().recv() => {}
    }
    select {
        v = rx.recv() => {}
        timeout(1) => {}
        default => {}
    }
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "a malformed select is an error");
    assert(r.out_has("a 'select' arm operation is"), "the bad operation is named");
    assert(r.out_has("needs at least one"), "a select with no channel arm is rejected");
    assert(r.out_has("must be a name or a field path"), "a computed channel is rejected");
    assert(r.out_has("cannot have both a 'timeout' and a 'default'"), "the conflicting arms are rejected");
}

// A module whose functions are only PARTLY used. Codegen expands nested instantiations by borrowing the
// defining module's ast and truncating the instances it added back off it, but the types interned during
// that pass survive, so a leftover type can name an instance that is gone. Reading it crashed the compiler
// (`Vector::at: index out of bounds`) rather than emitting anything. `std::parallel::selector` reaches that
// shape whenever a program touches only part of it, which a plain `Selector::new()` does.
@test
fn partial_module_use_after_foreign_expansion() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::selector as selector;

fn main() i32 {
    let s = selector::Selector::new();
    return s.len() as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("");
    assert(run.ok());
}

// The data-parallel API (std/parallel/data): the whole surface over 5000 elements; `each` reading every
// element, `each_mut` mutating disjoint partitions in place, `chunks_mut` handing out whole `[]mut T`
// windows, `reduce` folding per-chunk accumulators and combining them, `range_with` under Dynamic
// scheduling, and `sections` running unrelated one-shot tasks. Chunks run as stackless jobs, so no
// per-chunk stack is allocated. Exact totals prove every index is visited exactly once; empty inputs are
// no-ops. Leak-checked.
@test
fn data_parallel_api() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::data as parallel;
import std::parallel::atomics as atom;

fn main() i32 {
    let n: usize = 5000;
    let mut v = Vector::<i64>::new();
    for i in 0..n {
        v.push(i as i64);
    }

    let sum = atom::Atomic::<i64>::new(0);
    let sp = &sum; // captures are by copy, so shared state is reached through a borrow
    parallel::each(v[0..n], fn(x: &i64) {
        let _ = sp.fetch_add(*x, atom::MemoryOrder::Relaxed);
    });
    if sum.load(atom::MemoryOrder::SeqCst) != 12497500 {
        return 1;
    }

    parallel::each_mut(v.index_range_mut(0..n), fn(x: &mut i64) {
        *x = *x + 1;
    });
    if *v.at(0) != 1 || *v.at(n - 1) != n as i64 {
        return 2;
    }

    let seen = atom::Atomic::<i64>::new(0);
    let cp = &seen;
    parallel::chunks_mut(v.index_range_mut(0..n), 64, fn(c: []mut i64) {
        let _ = cp.fetch_add(c.len() as i64, atom::MemoryOrder::Relaxed);
        for i in 0..c.len() {
            c.set(i, *c.get(i) + 1);
        }
    });
    if seen.load(atom::MemoryOrder::SeqCst) != n as i64 || *v.at(0) != 2 {
        return 3;
    }

    let total = parallel::reduce(v[0..n], fn() i64 {
        return 0;
    }, fn(a: i64, x: &i64) i64 {
        return a + *x;
    }, fn(a: i64, b: i64) i64 {
        return a + b;
    });
    if total != 12497500 + 2 * n as i64 {
        return 4;
    }

    let hits = atom::Atomic::<i64>::new(0);
    let hp = &hits;
    parallel::range_with(0..n, parallel::Options { schedule: parallel::Schedule::Dynamic, grain_size: 32 }, fn(i: usize) {
        let mut acc: i64 = 0;
        for k in 0..(i % 17) {
            acc = acc + k as i64;
        }
        let _ = hp.fetch_add(1 + acc * 0, atom::MemoryOrder::Relaxed);
    });
    if hits.load(atom::MemoryOrder::SeqCst) != n as i64 {
        return 5;
    }

    let marks = atom::Atomic::<i64>::new(0);
    let mp = &marks;
    parallel::sections(fn(s: &mut parallel::Sections) {
        s.add(fn() {
            let _ = mp.fetch_add(1, atom::MemoryOrder::Relaxed);
        });
        s.add(fn() {
            let _ = mp.fetch_add(10, atom::MemoryOrder::Relaxed);
        });
        s.add(fn() {
            let _ = mp.fetch_add(100, atom::MemoryOrder::Relaxed);
        });
    });
    if marks.load(atom::MemoryOrder::SeqCst) != 111 {
        return 6;
    }

    parallel::range(0..0usize, fn(_i: usize) {});
    let empty = parallel::reduce(v[0..0], fn() i64 {
        return 7;
    }, fn(a: i64, x: &i64) i64 {
        return a + *x;
    }, fn(a: i64, b: i64) i64 {
        return a + b;
    });
    if empty != 7 {
        return 7;
    }

    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// A closure stored in an aggregate (`chunks_mut` keeps its body in `ChunksShared`) has its env defined by
// the declaration pass; a capture the body borrows (a Vector it indexes) is a pointer there too, as in
// the body, so the env, its initializer and the body agree.
@test
fn data_parallel_borrowed_capture_in_stored_closure() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::data as parallel;

struct Slot {
    pub i: usize,
    pub v: i32,
}

fn main() i32 {
    let mut src = Vector::<i32>::new();
    src.push(5);
    src.push(7);
    let mut out = Vector::<Slot>::new();
    out.push(Slot { i: 0, v: 0 });
    out.push(Slot { i: 1, v: 0 });
    parallel::chunks_mut(out.index_range_mut(0..2), 1, fn(slot: []mut Slot) {
        slot[0].v = src[slot[0].i] + src.len() as i32;
    });
    return out[0].v + out[1].v;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 16);
}

// A closure stored in a generic struct is its env by value: captures of 16 bytes (a struct, a vector
// whose C type is a vector register) size and align it as C does.
@test
fn data_parallel_closure_with_wide_captures() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::data as parallel;

struct P {
    pub a: i64,
    pub b: i64,
}

fn main() i32 {
    let k = P { a: 3, b: 4 };
    let v = f32x4::from_array([1.0, 2.0, 3.0, 4.0]);
    let mut out = Vector::<i64>::new();
    out.push(0);
    out.push(0);
    parallel::chunks_mut(out.index_range_mut(0..2), 1, fn(s: []mut i64) {
        s[0] = k.a + k.b + v.get(2) as i64;
    });
    return (out[0] + out[1]) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 20);
}

// Two chunks (grain 1) that each wait (bounded, spinning: a job cannot park) until both run: a batch
// submitted from off the pool wakes a parked worker per job, so the second chunk starts while the first
// waits. Each round first lets the workers park (the window the missed wake needed). Then the same
// through `sections`, whose two sections are two chunks (one per claim), not one inline run.
@test
fn data_parallel_wakes_a_second_worker() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::runtime as rt;
import std::parallel::data as parallel;
import std::parallel::atomics as atom;
import std::parallel::platform as platform;
import std::time as time;

// Count in, then wait up to five seconds for `want` arrivals; whether they came.
fn meet(c: &atom::Atomic<i64>, want: i64) bool {
    let _ = c.fetch_add(1, atom::MemoryOrder::AcqRel);
    let deadline = platform::now_ns() + 5000000000;
    while c.load(atom::MemoryOrder::Acquire) < want {
        if platform::now_ns() > deadline {
            return false;
        }
    }
    return true;
}

fn main() i32 {
    if rt::worker_count() < 2 {
        rt::shutdown();
        return 0;
    }
    for round in 0..4 {
        time::sleep(time::Duration::from_millis(20));
        let arrived = atom::Atomic::<i64>::new(0);
        let ap = &arrived;
        let mut met = Vector::<bool>::new();
        met.push(false);
        met.push(false);
        // grain 1: two chunks (the default floor of 16 units would make it one inline run).
        let one = parallel::Options { schedule: parallel::Schedule::Dynamic, grain_size: 1 };
        parallel::chunks_mut_with(met.index_range_mut(0..2), 1, one, fn(m: []mut bool) {
            m[0] = meet(ap, 2);
        });
        if !met[0] || !met[1] {
            rt::shutdown();
            return 1 + round;
        }
    }
    time::sleep(time::Duration::from_millis(20));
    let both = atom::Atomic::<i64>::new(0);
    let bp = &both;
    let ok = atom::Atomic::<i64>::new(0);
    let op = &ok;
    parallel::sections(fn(s: &mut parallel::Sections) {
        s.add(fn() {
            if meet(bp, 2) {
                let _ = op.fetch_add(1, atom::MemoryOrder::Relaxed);
            }
        });
        s.add(fn() {
            if meet(bp, 2) {
                let _ = op.fetch_add(1, atom::MemoryOrder::Relaxed);
            }
        });
    });
    rt::shutdown();
    return if ok.load(atom::MemoryOrder::SeqCst) == 2 {
        0;
    } else {
        9;
    };
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// A parallel body is copied to every worker and run from several at once, so it may not mutate a capture. The
// plain `fn(..)` bound makes the body borrow what it captures; a mutated capture is a `&mut` borrow, and a
// closure holding one is not `Sync`, so the classic data race (`|i| values.set(i, ..)`, a `&mut` capture
// shared across workers) is a compile error rather than a documented hazard.
@test
fn data_parallel_rejects_mutating_body() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::data as parallel;

fn main() i32 {
    let mut v = Vector::<i64>::new();
    v.push(0);
    parallel::range(0..1usize, fn(i: usize) {
        v.set(i, 1);
    });
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "a body that mutates a capture is rejected");
    assert(r.out_has("does not satisfy bound 'Sync'"), "the rejection cites the Sync bound");
}

// Interior mutability is gated: casting an immutable `&T` to `*mut T` is a hard error (it launders the
// shared-borrow guarantee), so mutation through a shared reference must go through `UnsafeCell`, whose
// contents are stored non-`const` and mutated soundly: exercised here by an `UnsafeCell<i32>` in an
// IMMUTABLE binding whose value is still changed through `get()`.
@test
fn interior_mutability_via_unsafe_cell() {
    let bad = cli::proj_new();
    bad.mkfile(
        "main.spc",
        "fn main() i32 {\n    let x: i32 = 5;\n    let q = (&x) as *mut i32;\n    return unsafe {\n        q[0];\n    };\n}\n",
    );
    let rb = bad.compile("main.spc");
    assert(rb.exit != 0, "casting an immutable &T to *mut T is rejected");
    assert(rb.out_has("immutable reference"), "the diagnostic names the laundering");

    let ok = cli::proj_new();
    ok.mkfile(
        "main.spc",
        "fn main() i32 {\n    let cell = UnsafeCell::<i32>::new(7);\n    unsafe {\n        cell.get()[0] = 42;\n    }\n    return unsafe {\n        cell.get()[0];\n    } - 42;\n}\n",
    );
    let ro = ok.native_build("", "main.spc");
    assert(ro.ok());
    assert_eq(ok.run_bin(), 0);
}

// A trivial app should not dump the whole std prelude tree (Vector/Map/String not written).
@test
fn prelude_output_is_demand_driven() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(42); return 0; }\n");
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(!p.gen_exists("__std/vector.c"), "trivial output should not emit unused std vector.c");
    assert(!p.gen_exists("__std/map.c"), "trivial output should not emit unused std map.c");
    assert(!p.gen_exists("__std/string.c"), "trivial output should not emit unused std string.c");
    let cc = p.cc_build("");
    assert(cc.ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 42);
}

// Cross-module re-homed generic instances must discover by-value nested generic fields before emission:
// Outer<Bar> contains Inner<Bar> by value; both must be re-homed and emitted in dependency order.
@test
fn cross_module_nested_rehomed_instance() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        M"(pub struct Inner<T> { pub value: T }
pub struct Outer<T> { pub inner: Inner<T> }
extend<T: Copy> Outer<T> { pub fn get(self: &Self) T { return self.inner.value; } }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import lib::lib;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
fn main() i32 {
  let o = lib::lib::Outer::<Bar> { inner: lib::lib::Inner::<Bar> { value: Bar { x: 42 } } };
  unsafe exit(o.get().x); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 42);
}

// A pub interface in one module, implemented over a local type and consumed by a bounded generic in another:
// the bound resolves across the import, the extend satisfies it, and the bounded call dispatches.
@test
fn cross_module_interface() {
    let p = cli::proj_new();
    p.mkfile("shapes.spc", "pub interface Area { fn area(self: *mut Self) i32; }\n");
    p.mkfile(
        "main.spc",
        M"(import shapes;
extern "C" { fn exit(code: i32) void; }
struct Sq { pub s: i32 }
extend Sq as shapes::Area { fn area(self: *mut Self) i32 { return unsafe ((*self).s * (*self).s); } }
fn total<T: shapes::Area>(x: &mut T) i32 { return x.area(); }
fn main() i32 { let mut q = Sq { s: 6 }; unsafe exit(total(&mut q)); return 0; }
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 36);
}

// Cross-module trait objects: a pub interface (with a default) erased over a foreign type AND a local type
// in another module; both modules erase; the foreign default's synthesized tag exports for the user TU.
@test
fn cross_module_dyn() {
    let p = cli::proj_new();
    p.mkfile(
        "shapes.spc",
        M"(pub interface Shape {
    fn area(self: &Self) i32;
    fn tag(self: &Self) i32 { return 7; }
}
pub struct Circle { pub r: i32 }
extend Circle as Shape {
    pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; }
}
pub fn local_view(s: &dyn Shape) i32 { return s.area(); }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import shapes;
extern "C" { fn exit(code: i32) void; }
struct Sq { pub s: i32 }
extend Sq as shapes::Shape {
    pub fn area(self: &Sq) i32 { return self.s * self.s; }
    pub fn tag(self: &Sq) i32 { return 4; }
}
fn total(a: &dyn shapes::Shape, b: &dyn shapes::Shape) i32 { return a.area() + b.area(); }
fn main() i32 {
    let c = shapes::Circle { r: 1 };
    let q = Sq { s: 2 };
    let d: &dyn shapes::Shape = &c;
    let t = total(&c, &q);
    let u = shapes::local_view(&q);
    let w = d.tag() + q.tag();
    unsafe exit(t + u + w + d.area()); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 25);
}

// The bundled ffi/ bindings, imported by a C header's bare name (import math; -> ffi/math.spc): a raw pub
// extern binding with its real unmangled C symbol, and a thin wrapper: compiled -Werror + linked -lm.
@test
fn ffi_bindings() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import math;
import ctype;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let s = unsafe math::sqrt(144.0) as i32;
  let mut acc = 0;
  if ctype::is_digit(53) { acc = acc + 1; }
  if ctype::is_alpha(53) { acc = acc + 10; }
  unsafe exit(s + acc); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program builds");
    assert_eq(p.run_bin(), 13);
}

// A constant argument past a variadic callee's parameters is read as its promoted C type, so it is
// spelled with exactly that type: a folded `i32` or a `u8` is cast to its type (promoting to `int`), a
// `u32` is `unsigned`. The build compiles under -Werror, where a `long long` spelling of an `i32` fails
// -Wformat, and where the i64 minimum spelled as a negated literal is an unsigned literal.
@test
fn variadic_constants_match_their_promoted_type() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        M"(import stdio;
const fn next(x: i32) i32 { return x + 1; }
const fn triple(x: u8) u8 { return x * 3; }
const fn lo() i64 { return -9223372036854775807i64 - 1; }
fn above(a: i64) i32 { if a > lo() { return 1; } return 0; }
fn main() i32 {
    let _ = unsafe stdio::printf("%d %d %u %d %d %d\n", next(1), 7u8, 4000000000u32, 5, triple(2), above(5));
    return 0;
}
)",
    );
    let root = p.dir();
    let r = cli::superc_in(root, "run");
    assert(r.ok(), "the program runs");
    assert(r.out_shows("2 7 4000000000 5 6 1"), "every constant reads back as its value");
    if !cli::has_cc() {
        return; // the C compiler builds the C tree
    }
    assert(cli::superc_in(root, "build --emit-c").ok(), "the C tree");
    assert(p.cc_build_plain("-Wformat -Werror").ok(), "the C tree compiles under -Werror");
    let c = p.run_bin_env("");
    assert(c.ok() && c.out_shows("2 7 4000000000 5 6 1"), "the C program reads every constant back");
}

// An array length an instance folds out of range is an error at the instance: the length as written, the
// bindings it folded with, and the site that demanded the instance. A concrete type that holds such a
// length is reported where it is used. No C is emitted for it and no internal refusal follows. `f` takes
// a run-time argument: a constant call would evaluate `N - 5` and report its usize overflow first.
@test
fn instance_array_length_out_of_range() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct S<const N: usize> { pub d: [u8; N - 5], pub x: i32 }
struct W<const N: usize> { pub d: [u8; N * 2] }
fn f<const N: usize>(k: i32) [i32; N - 5] { let r: [i32; N - 5] = [k; N - 5]; return r; }
fn inner<const N: usize>() usize { return sizeof([u8; N - 5]); }
fn outer<const M: usize>() usize { return inner::<{M + 1}>(); }
fn big<const K: usize>() usize { return sizeof(W<K>); }
fn main(args: Vector<str>) i32 {
    let a = f::<3>(args.len() as i32);
    let n = sizeof(S<3>) + sizeof(W<3000000000>) + outer::<1>() + big::<5000000000>();
    return n as i32;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "the build fails");
    // The concrete use, then each instance's length and demand site.
    assert(r.out_shows("error: array length -2 is negative"), "the concrete use");
    assert(r.out_shows("main.spc:8:5\n"), "at the binding in main");
    assert(r.out_shows("error: array length N - 5 is negative (-2) for N = 3"), "the field and the binding");
    assert(r.out_shows("main.spc:1:35\n"), "at the field");
    assert(r.out_shows("= note: in the instantiation of 'S' demanded here"), "the aggregate's note");
    assert(r.out_shows("main.spc:9:13\n"), "at its sizeof");
    assert(
        r.out_shows(
            "error: array length 2 * N is 6000000000 for N = 3000000000, past the maximum array length 4294967295",
        ),
        "an overflowing length",
    );
    assert(r.out_shows("main.spc:3:45\n"), "at the generic binding");
    assert(r.out_shows("= note: in the instantiation of 'f' demanded here"), "the function's note");
    assert(r.out_shows("main.spc:8:13\n"), "at its call");
    assert(r.out_shows("error: array length N - 5 is negative (-3) for N = 2"), "a nested instance");
    assert(r.out_shows("main.spc:4:43\n"), "at its sizeof");
    assert(r.out_shows("= note: in the instantiation of 'inner' demanded here"), "the nested note");
    assert(r.out_shows("main.spc:5:43\n"), "at the call in the generic caller");
    // A generic caller's argument past 2^32 folds too.
    assert(
        r.out_shows(
            "error: array length 2 * N is 10000000000 for N = 5000000000, past the maximum array length 4294967295",
        ),
        "a length past 2^32 through a generic caller",
    );
    assert(!r.out_has("internal"), "no internal refusal");
}

// The POSIX bindings (unistd, fcntl, filesystem) declare a BACKING HEADER, and this is what proves they
// need to: none of `<unistd.h>`, `<sys/stat.h>` or `<dirent.h>` is among the standard headers the runtime
// prologue carries, so an unnamed extern block leaves every one of these calls an implicit declaration:
// an error under C99, which is exactly how `unistd` and `filesystem` shipped unusable. Compiled -Werror and
// run: create a directory, open + write + close a file in it, walk it with opendir/readdir, then
// unlink and rmdir.
@test
fn ffi_posix_bindings() {
    if PLATFORM == Platform::Windows {
        return; // no dirent.h
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import unistd;
import fcntl;
import filesystem;

fn main() i32 {
    let mut dir = String::from_str("sc_ffi_probe_dir");
    let _ = unsafe filesystem::mkdir(dir.cstr(), 493);
    let mut file = String::from_str("sc_ffi_probe_dir/f");
    let fd = unsafe fcntl::open(file.cstr(), fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC, 420);
    if fd < 0 {
        return 1;
    }
    let mut msg = String::from_str("hello");
    let n = unsafe unistd::write(fd, msg.cstr(), 5);
    let _ = unsafe unistd::close(fd);
    let d = unsafe filesystem::opendir(dir.cstr());
    if d == null {
        return 2;
    }
    let mut entries = 0;
    while unsafe filesystem::readdir(d) != null {
        entries = entries + 1;
    }
    let _ = unsafe filesystem::closedir(d);
    let _ = unsafe filesystem::unlink(file.cstr());
    let _ = unsafe filesystem::rmdir(dir.cstr());
    if n != 5 || entries < 3 || unsafe unistd::getpid() <= 0 {
        return 3;
    }
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.xhdr_has("#include <unistd.h>"), "the unistd block pulls in its header");
    assert(p.xhdr_has("#include <dirent.h>"), "the filesystem blocks pull in theirs");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    // The program makes its probe directory in its working directory: the scratch project, never the
    // repository (the runner restores the working directory after the test).
    assert(process::set_current_dir(p.dir()).is_ok(), "into the scratch project");
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(run.ok());
}

// Import forms + mangling: an alias import, a glob import, two modules with a same-named public function
// (module mangling keeps them distinct), and a module named like a C stdlib header (string).
@test
fn module_imports() {
    let p = cli::proj_new();
    p.mkfile("string.spc", "pub fn tag() i32 { return 10; }\n");
    p.mkfile("math.spc", "pub fn tag() i32 { return 20; }\n");
    p.mkfile("deep.spc", "pub fn dtag() i32 { return 100; }\npub struct D { pub v: i32 }\n");
    p.mkfile("facade.spc", "import deep;\n");
    p.mkfile(
        "main.spc",
        M"(import string as s;
import math as *;
import facade as *;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let d = D { v: deep::dtag() / 10 };
  unsafe exit(s::tag() + tag() + dtag() + d.v); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 140);
}

// `--jobs=N` bounds the task pool the frontend runs on: the load's job count is the pool's worker
// count, set before its first task.
@platform(!wasm)
@test
fn load_jobs_bound_the_worker_pool() {
    loader::set_load_jobs(3);
    let wg = psync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        w.done();
    };
    wg.wait();
    assert_eq(prt::worker_count(), 3usize);
    loader::set_load_jobs(1);
    prt::shutdown();
}

@platform(!windows)
extern "C" "sys/stat.h" {
    fn chmod(path: *const char, mode: stdlib::mode_t) i32;
}

// An import resolves to a module in a directory that exists but does not list (search permission
// without read permission): the import lookup opens the file instead of taking the directory for
// missing. A root user lists every directory, so the test cannot fail there.
@platform(!windows)
@test
fn import_resolves_under_an_unlistable_directory() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("lib/lib.spc", "pub fn seven() i32 {\n    return 7;\n}\n");
    p.mkfile("main.spc", "import lib;\n\nfn main() i32 {\n    return lib::seven() - 7;\n}\n");
    let mut d = format("{}/lib", p.dir());
    assert(unsafe chmod(d.cstr(), 0o111) == 0, "the directory loses its read permission");
    let r = p.compile("main.spc");
    // The scratch cleanup lists the directory.
    let _ = unsafe chmod(d.cstr(), 0o755);
    assert(r.ok(), "the import resolves");
}

// Only the root module's `main` is the program entry. A `main` in another module, of any signature,
// and a method named `main` are ordinary functions with their module's symbols: the modules link,
// and the root calls each.
@test
fn non_root_main_is_ordinary() {
    let p = cli::proj_new();
    p.mkfile(
        "other.spc",
        "pub fn main() i32 {\n    return 41;\n}\n\npub fn twice(k: i32) i32 {\n    return main() - 41 + 2 * k;\n}\n\npub struct A {\n    pub v: i32,\n}\n\nextend A {\n    pub fn main(self: &A, k: i32) i32 {\n        return self.v + k;\n    }\n}\n",
    );
    p.mkfile("third.spc", "pub fn main(k: i32) i32 {\n    return k;\n}\n");
    p.mkfile(
        "main.spc",
        "import other;\nimport third;\n\nfn main() i32 {\n    let a = other::A { v: 3 };\n    return other::main() + other::twice(3) + a.main(-3) + third::main(-47);\n}\n",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 0);
}

// A module's prefix never spells a prelude C symbol: module `str`, whose `len` would be the prelude's
// `str__len`, and module `Vector::i32`, whose `push` would be `Vector__i32__push` once another `i32`
// module keeps its full path, take one more `_` after the prefix's first segment.
@test
fn module_prefixes_stay_apart_from_prelude_symbols() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("str.spc", "@noinline\npub fn len(x: i32) i32 {\n    return x;\n}\n");
    p.mkfile("Vector/i32.spc", "@noinline\npub fn push(x: i32) i32 {\n    return x + 1;\n}\n");
    p.mkfile("other/i32.spc", "@noinline\npub fn push(x: i32) i32 {\n    return x + 2;\n}\n");
    p.mkfile(
        "main.spc",
        "import str as su;\nimport Vector::i32 as vi;\nimport other::i32 as oi;\nfn main(args: Vector<str>) i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(args[0].len() as i32);\n    return su::len(v[0]) + vi::push(0) + oi::push(0) - args[0].len() as i32 - 3;\n}\n",
    );
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.gen_has("Vector/i32.c", "Vector___i32__push("), "the full prefix takes the escape");
    assert(p.cc_build("").ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 0);
}

// A constant evaluated during the type check calls another module's operators: their by-reference
// parameter types are provisional ids of THAT module's pool, which the lowering must read there.
@test
fn constant_calls_another_modules_by_reference_operators() {
    let p = cli::proj_new();
    p.mkfile(
        "y.spc",
        "pub struct W { pub v: i64 }\nextend W {\n    pub fn add(self: &W, other: &W) W { return W { v: self.v + other.v }; }\n    pub fn mul(self: &W, other: &i64) W { return W { v: self.v * *other }; }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import y;\nconst X: i32 = -3;\nconst K: y::W = y::W { v: 1 } + y::W { v: 2 };\nconst M: y::W = y::W { v: 5 } * 3;\nconst N: y::W = y::W { v: 2 } * X;\nfn main() i32 {\n    let x: i32 = 4;\n    return (K.v + M.v + N.v + (y::W { v: 1 } * x).v) as i32;\n}\n",
    );
    assert(p.native_build("", "main.spc").ok(), "the program compiles");
    assert_eq(p.run_bin(), 16);
}

// A glob-imported name shadows a prelude name, as a declaration does: `dot` (a std::simd function) and
// `String` (a prelude type) come from the imported module.
@test
fn glob_import_shadows_prelude() {
    let p = cli::proj_new();
    p.mkfile("geom.spc", "pub struct String { pub n: i32 }\npub fn dot(a: i32, b: i32) i32 { return a * b; }\n");
    p.mkfile(
        "main.spc",
        M"(import geom as *;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let s = String { n: 2 };
  unsafe exit(dot(3, 4) + s.n);
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 14);
}

// A type in scope wins over a module qualifier the import did not name: `import m::qq as *;` brings the
// alias `qq`, so `qq::one()` calls the aliased type's function, not an item of module `qq`; an explicit
// `as` alias still names the module.
@test
fn glob_imported_type_wins_over_module_qualifier() {
    let p = cli::proj_new();
    p.mkfile(
        "m/qq.spc",
        "pub struct Q { pub w: i32 }\npub type qq = Q;\nextend Q { pub fn one() Q { return Q { w: 1 }; } }\npub fn two() i32 { return 2; }\n",
    );
    p.mkfile(
        "main.spc",
        M"(import m::qq as *;
import m::qq as mq;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let q = qq::one();
  unsafe exit(q.w + mq::two() * 10);
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 21);
}

// Glob imports search each imported module's transitive imports before the next glob import: `pick`
// comes from `c`, which `a` imports, not from `b`; `c` sits in both closures, and `only_b` is found
// past it.
@test
fn glob_import_searches_each_closure_in_order() {
    let p = cli::proj_new();
    p.mkfile("c.spc", "pub fn pick() i32 { return 3; }\n");
    p.mkfile("a.spc", "import c;\npub fn from_a() i32 { return c::pick(); }\n");
    p.mkfile("b.spc", "import c;\npub fn pick() i32 { return 2; }\npub fn only_b() i32 { return c::pick() * 10; }\n");
    p.mkfile(
        "main.spc",
        M"(import a as *;
import b as *;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  unsafe exit(pick() + only_b());
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 33);
}

// External C code: a backing header's same-stem `.c` file is no part of the build (C comes prebuilt,
// through `@link`); @link lands in build/__ldflags; removing the block prunes its flag;
@test
fn external_c_sources() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("helper.h", "int helper_add(int a, int b);\n");
    p.mkfile("helper.c", "#include \"helper.h\"\nint helper_add(int a, int b) { return a + b; }\n");
    p.mkfile("extra.h", "int extra_mul(int a, int b);\n");
    p.mkfile("extra.c", "#include \"extra.h\"\nint extra_mul(int a, int b) { return a * b; }\n");
    // The block's library has to exist on this platform (mingw ships no libc.a) AND differ from what the
    // driver seeds by itself, or phase two below cannot tell the block's flag from the prelude's: libm is
    // seeded on POSIX only, libc exists on POSIX only, so the two swap roles by target.
    let lib = if cli::on_windows() {
        "m";
    } else {
        "c";
    };
    let mut src = String::from_str("extern \"C\" \"helper.h\" {\n  fn helper_add(a: i32, b: i32) i32;\n}\n@link(\"");
    src.push_str(lib);
    src.push_str(
        "\")\nextern \"C\" \"extra.h\" {\n  fn extra_mul(a: i32, b: i32) i32;\n}\nextern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(helper_add(20, 22) + extra_mul(2, 3)); return 0; }\n",
    );
    p.mkfile("main.spc", src.as_str());
    let mut flag = String::from_str("-l");
    flag.push_str(lib);
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.gen_count("__ext"), 0);
    assert(p.gen_has("__ldflags", flag.as_str()), "@link lands in build/__ldflags");
    let cc = p.cc_build_with("", "helper.c extra.c");
    assert(cc.ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 48);

    // Drop the extern blocks: the flag they contributed goes. `-lm` stays;
    // the prelude's float methods are emitted into every program, so libm is on every POSIX link line.
    p.mkfile("main.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(0); return 0; }\n");
    let r2 = p.compile("main.spc");
    assert(r2.ok(), "the program compiles");
    assert(!p.gen_has("__ldflags", flag.as_str()), "a dropped extern block takes its link flag with it");
    if !cli::on_windows() {
        assert(p.gen_has("__ldflags", "-lm"), "the prelude's own libm flag stays: every program emits float methods");
    }

    p.mkfile(
        "main.spc",
        "@c.source(\"extra.c\")\nextern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(0); return 0; }\n",
    );
    let gone = p.compile("main.spc");
    assert(gone.exit != 0 && gone.out_has("unknown attribute '@c.source'"), "@c.source is an unknown attribute");
}

// Shim prototypes (`sc_` externs) and block-wrapper prototypes live in the forward header, which
// includes no definition header: one whose array declarator has an aggregate element (`[S; 2]`)
// is a declaration of the unit that calls it, after the definition it needs. By-value `S`
// parameters and returns stay (a declaration may name an incomplete type), and so does a pointer to
// an array of `S`, which names the array's wrapper struct. The C side calls the `@export` functions back; the tree compiles
// -Wall -Wextra -Werror. A result pointer to an array of `S` converts at the call (`(void *)`), and a
// local named like that extern, declared before the call, takes another C name.
@test
fn extern_prototypes_see_complete_types() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    // A header-declared C function that takes `int a[4]` and writes through it: a `[i32; 4]` argument is a
    // value, so the call hands it a copy (also when the function is named as a value), and an array read
    // through `&T`, a `const` object in C, passes.
    p.mkfile("bump.h", "int arr_bump(int a[4]);\n");
    p.mkfile("bump.c", "#include \"bump.h\"\nint arr_bump(int a[4]) { a[0] = 100; return a[0] + a[3]; }\n");
    p.mkfile("side.h", "");
    p.mkfile(
        "side.c",
        M"(#include <stdint.h>
typedef struct S { int32_t a; int32_t b; } S;
S sc_twice(S s);
int32_t sc_arr(S a[2]);
int32_t sc_parr(const S (*p)[2]);
int32_t sc_sum2(const S (*p)[2]) { return (*p)[0].a + (*p)[1].b + sc_parr(p); }
int32_t sc_arrx(S a[2]) { return sc_arr(a) * 10; }
int32_t sc_val(S s) { return sc_twice(s).b + s.a; }
S sc_mk(int32_t a) { S s = { a, a + 1 }; return s; }
S sc_bval(S s) { S r = { s.b, s.a }; return r; }
int32_t sc_bptr(const S (*p)[2]) { return (*p)[1].b * 100; }
static const S sc_pair[2] = { { 7, 8 }, { 9, 10 } };
const S (*sc_rows(void))[2] { return &sc_pair; }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import std::parallel::blocking as blocking;
import std::parallel::runtime as rt;

pub struct S { pub a: i32, pub b: i32 }

// side.c, linked beside the program, brings the definitions the header-less block below declares.
extern "C" "side.h" {}

extern "C" {
    fn sc_sum2(p: *const [S; 2]) i32;
    fn sc_arrx(a: [S; 2]) i32;
    fn sc_val(s: S) i32;
    fn sc_mk(a: i32) S;
    @blocking
    fn sc_bval(s: S) S;
    @blocking
    fn sc_bptr(p: *const [S; 2]) i32;
    fn sc_rows() *const [S; 2];
}

extern "C" "bump.h" {
    fn arr_bump(a: [i32; 4]) i32;
}

pub struct Row { pub l: [i32; 4] }

fn bump_row(r: &Row) i32 {
    return unsafe arr_bump(r.l);
}

fn rows(k: i32) i32 {
    let mut t: i32 = 0;
    {
        let mut sc_rows: i32 = k;
        if k > 2 {
            sc_rows = k * 2;
        }
        t += sc_rows;
    }
    let p = unsafe sc_rows();
    return t + unsafe (*p)[1].a;
}

@export("sc_twice")
pub fn twice(s: S) S {
    return S { a: s.a * 2, b: s.b * 2 };
}

@export("sc_arr")
pub fn arr(a: [S; 2]) i32 {
    return a[0].a + a[1].b;
}

@export("sc_parr")
pub fn parr(p: *const [S; 2]) i32 {
    return unsafe (*p)[1].a;
}

fn main() i32 {
    let v: [S; 2] = [S { a: 1, b: 2 }, S { a: 3, b: 4 }];
    if unsafe sc_sum2(&v) != 8 || unsafe sc_arrx(v) != 50 || unsafe sc_val(v[0]) != 5 {
        return 1;
    }
    if unsafe sc_mk(5).b != 6 || unsafe sc_bval(v[1]).a != 4 || unsafe sc_bptr(&v) != 400 {
        return 2;
    }
    if rows(v[0].a) != 10 {
        return 3;
    }
    let row = Row { l: [1, 2, 3, 4] };
    let mut m: [i32; 4] = [5, 6, 7, 8];
    let bump: fn([i32; 4]) i32 = unsafe arr_bump;
    if bump_row(&row) != 104 || unsafe arr_bump(m) != 108 || bump(m) != 108 || row.l[0] != 1 || m[0] != 5 {
        return 4;
    }
    m[1] = 0;
    // The block wrappers ran on the pool: release it and the runtime.
    let _ = blocking::try_shutdown(5000000000);
    rt::shutdown();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(!p.gen_has("__sc_fwd.h", "sc_arrx("), "an array-of-aggregate shim prototype leaves the forward header");
    assert(p.gen_has("main.c", "int32_t __sc_blk_main__sc_arrx("), "the unit that calls it declares its wrapper");
    assert(
        p.gen_has("__sc_fwd.h", "__sc_blk_main__sc_bptr(const main__S__a2 *a0)"),
        "a block wrapper taking a pointer to an array of S stays",
    );
    assert(p.gen_has("__sc_fwd.h", "sc_val("), "a by-value aggregate parameter stays in the forward header");
    let cc = p.cc_build_with("", "bump.c side.c");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);
}

// Cross-module interface DEFAULT methods: the interface (with bodied defaults) lives in its own module,
// conformances elsewhere (type's home, a local extension of an imported type, and a builtin target `i32`).
@test
fn cross_module_defaults() {
    let p = cli::proj_new();
    p.mkfile(
        "shapes.spc",
        M"(pub interface Shape {
  fn area(self: &Self) i32;
  fn double_area(self: &Self) i32 { return self.area() * 2; }
  fn describe(self: &Self) i32 { return self.double_area() + 1; }
}
)",
    );
    p.mkfile(
        "circle.spc",
        M"(import shapes;
pub struct Circle { pub r: i32 }
extend Circle as shapes::Shape {
  pub fn area(self: &Circle) i32 { return self.r * self.r * 3; }
}
)",
    );
    p.mkfile("point.spc", "pub struct Point { pub x: i32 }\n");
    p.mkfile(
        "main.spc",
        M"(import circle;
import shapes;
import point;
extend point::Point as shapes::Shape {
  pub fn area(self: &point::Point) i32 { return self.x; }
}
extend i32 as shapes::Shape {
  pub fn area(self: &i32) i32 { return *self; }
}
fn dyn_describe(sh: &dyn shapes::Shape) i32 { return sh.describe(); }
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let c = circle::Circle { r: 2 };
  let p = point::Point { x: 5 };
  let n: i32 = 4;
  unsafe exit(c.describe() + dyn_describe(&c) + p.describe() + n.describe()); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 70);
}

// Format conformances across the prelude, built multi-file: String/Vector/Option/Result render to a String.
// A value type conforming to a prelude interface must NOT pull the interface module's header (no cycle).
@test
fn format_conformances() {
    let p = cli::proj_new();
    p.mkfile(
        "fmt.spc",
        M"(fn main() i32 {
  let mut v = Vector::<String>::new();
  v.push(String::from_str("a")); v.push(String::from_str("b"));
  let vs = v.fmt();
  let o = Option::<String>::Some(String::from_str("x"));
  let os = o.fmt();
  let r = Result::<String, String>::Ok(String::from_str("y"));
  let rs = r.fmt();
  return vs.len() as i32 + os.len() as i32 + rs.len() as i32;
}
)",
    );
    let r = p.native_build("", "fmt.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 18);
}

// Mutually-recursive modules: import cycles are legal; mutual fn calls and mutual POINTER-linked types work;
// a mutual BY-VALUE embedding is the one impossible shape (infinite size) and gets its own diagnostic.
@test
fn module_cycles() {
    let p = cli::proj_new();
    p.mkfile(
        "a.spc",
        M"(import b;
pub struct AN { pub v: i32, pub link: *mut b::BN }
pub fn even(n: i32) i32 { if n == 0 { return 1; } return b::odd(n - 1); }
)",
    );
    p.mkfile(
        "b.spc",
        M"(import a;
pub struct BN { pub v: i32, pub link: *mut a::AN }
pub fn odd(n: i32) i32 { if n == 0 { return 0; } return a::even(n - 1); }
)",
    );
    p.mkfile(
        "main.spc",
        M"(import a;
import b;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let mut an = a::AN { v: 30, link: null };
  let mut bn = b::BN { v: 2, link: (&mut an) as *mut a::AN };
  let linked = unsafe (*bn.link).v + bn.v;
  unsafe exit(linked + a::even(10) * 10); return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program compiles");
    assert_eq(p.run_bin(), 42);

    // A mutual by-value embedding is infinite size.
    let bad = cli::proj_new();
    bad.mkfile("main.spc", "import a;\nfn main() i32 { return 0; }\n");
    bad.mkfile("a.spc", "import b;\npub struct A { pub x: b::B }\n");
    bad.mkfile("b.spc", "import a;\npub struct B { pub y: a::A }\n");
    bad.expect_fail("main.spc", "infinite size");
}

// Module-layer negative paths: missing modules and using a non-public type/const/field across modules.
@test
fn module_errors() {
    // A missing module stops the compile before any located error: alone.
    let miss = cli::proj_new();
    miss.mkfile("main.spc", "import nope::nope;\nfn main() i32 { return 0; }\n");
    miss.expect_fail("main.spc", "main.spc:1: error: cannot open module 'nope::nope'");
    // The error names the importing file and the line of its import, also below the root.
    miss.mkfile("main.spc", "import util;\nfn main() i32 { return util::u(); }\n");
    miss.mkfile("util.spc", "// util\n\nimport gone;\npub fn u() i32 { return 0; }\n");
    miss.expect_fail("main.spc", "util.spc:3: error: cannot open module 'gone'");

    // Each case imports its own library directory.
    let p = cli::proj_new();
    p.mkfile("l1/lib.spc", "enum Secret { A, B }\npub fn ok() i32 { return 1; }\n");
    p.mkfile("l2/lib.spc", "const K: i32 = 9;\n");
    p.mkfile("l3/lib.spc", "pub struct P { x: i32 }\npub fn mk() P { return P { x: 5 }; }\n");
    let mut b = cli::Batch::new("", "");
    b.add(
        "a private type",
        "import l1::lib;\nfn use_it(p: l1::lib::Secret) i32 { return 0; }\nfn main() i32 { return 0; }\n",
        "no visible type",
    );
    b.add("a private constant", "import l2::lib;\nfn main() i32 { return l2::lib::K; }\n", "no visible");
    b.add("a private field", "import l3::lib;\nfn main() i32 { let p = l3::lib::mk(); return p.x; }\n", "is private");
    p.expect_batch(b);
}

// The module every module-qualified path test imports: public and private constants, a type with a
// public and a private associated constant, an enum, an enum constant and an alias of a builtin.
const QUAL_MOD: str = M"(pub const B: u64 = 3;
const P: u64 = 4;
pub const S8: u8 = 2;
pub struct Foo { pub a: i32 }
extend Foo {
    pub const K: u64 = 5;
    const Q: u64 = 6;
}
pub enum D { X, Y = 7 }
pub const DK: D = D::Y;
pub type U = u64;
)";

// The declarations ahead of `main` in every module-qualified path test.
const QUAL_PRE: str = M"(import m;
struct W<const N: u64> { pub x: i32 }
extend<const N: u64> W<N> { pub fn n(self: &Self) u64 { return N; } }
struct F<const E: m::D> { pub x: i32 }
extend<const E: m::D> F<E> { pub fn n(self: &Self) i32 { return E as i32; } }
fn g<const N: u64>() u64 { return N; }
fn g8<const N: u8>() u8 { return N; }
)";

// Add to `b` (whose programs start with QUAL_PRE) the case of `main` running `body` (line 9) with
// exactly one error, `want`, at main.spc:`at`.
fn qual_fails(b: &mut cli::Batch, body: str, want: str, at: str) {
    let src = format("fn main() i32 {{\n    {}\n    return 0;\n}}\n", body);
    b.add_at(body, src.as_str(), format("error: {}\n--> ", want).as_str(), at);
}

// A constant a module qualifies is a const argument exactly as its unqualified spelling: a public
// constant (`W<m::B>`, `W<{m::B}>`), an associated constant (`W<m::Foo::K>`), a builtin limit through
// an alias (`W<m::U::MAX>`), a variant and an enum constant for an enum parameter, in a type and in a
// turbofish, typed by the parameter, folded by the constant evaluator, and one instance with its
// literal spelling. A private constant, a missing or private associated constant and a type past its
// segment are errors at the segment; a module-qualified path in a type position names a type.
@test
fn module_qualified_const_arguments() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("m.spc", QUAL_MOD);
    p.mkfile(
        "main.spc",
        format(
            "{}{}",
            QUAL_PRE,
            M"(fn same(a: W<3>, b: W<5>, c: W<18446744073709551615>) u64 { return a.n() + b.n() + c.n() / 1000000000000; }
static_assert(g::<m::B>() == 3 && g::<m::Foo::K>() == 5 && g::<{m::B + m::Foo::K}>() == 8 && g::<m::U::MAX>() == 18446744073709551615);
fn main() i32 {
    let a: W<m::B> = W::<{m::B}> { x: 1 };
    let b: W<m::Foo::K> = W::<{m::Foo::K}> { x: 2 };
    let c: W<m::U::MAX> = W::<18446744073709551615> { x: 3 };
    let f: F<m::D::Y> = F::<{m::D::Y}> { x: 4 };
    let k: F<m::DK> = f;
    print("{} {} {} {} {} {}\n", same(a, b, c), k.n(), g8::<m::S8>(), g::<m::Foo::K>() + g::<m::B>(), g::<{m::U::MAX}>(), a.x + b.x + c.x + k.x);
    return 0;
}
)",
        ).as_str(),
    );
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.cc_build("-pedantic-errors ").ok(), "the emitted C compiles and links");
    let r = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(r.ok(), "the program runs clean");
    assert(r.out_shows("18446752 7 2 8 18446744073709551615 10\n"), "each qualified constant has its value");

    let mut b = cli::Batch::new(QUAL_PRE, "");
    b.one = true;
    qual_fails(&mut b, "let w: W<m::P> = W { x: 1 };", "no visible type or constant 'P' in the imported module", "9:17");
    qual_fails(&mut b, "let w = g::<m::P>();", "no visible type or constant 'P' in the imported module", "9:20");
    qual_fails(&mut b, "let w: W<{m::P}> = W { x: 1 };", "no visible item 'P' in module 'm'", "9:18");
    qual_fails(&mut b, "let w: W<m::Foo::Q> = W { x: 1 };", "no associated constant 'Q' on 'm::Foo'", "9:22");
    qual_fails(&mut b, "let w = g::<m::Foo::Z>();", "no associated constant 'Z' on 'm::Foo'", "9:25");
    qual_fails(&mut b, "let w = g::<{m::Foo::Q}>();", "no associated constant 'Q' on 'm::Foo'", "9:26");
    qual_fails(&mut b, "let w = F::<m::D::Q> { x: 1 };", "no variant or associated constant 'Q' on 'm::D'", "9:23");
    qual_fails(&mut b, "let w = g8::<m::B>();", "mismatched types: expected 'u8', found 'u64'", "9:18");
    qual_fails(
        &mut b,
        "let w = g8::<m::U::MAX>();",
        "const generic argument 18446744073709551615 is out of range for 'u8'",
        "9:18",
    );
    qual_fails(&mut b, "let w: W<m::Foo>;", "expected a constant for const parameter 'N', found type 'Foo'", "9:14");
    qual_fails(
        &mut b,
        "let w: *const Vector<m::B>;",
        "expected a type for generic parameter 'T', found a constant",
        "9:26",
    );
    qual_fails(&mut b, "let w: W<m::D::Y>;", "mismatched types: expected 'u64', found 'D'", "9:14");
    qual_fails(&mut b, "let z: m::Foo::U = m::Foo { a: 1 };", "no type 'U' in 'm::Foo'", "9:20");
    qual_fails(&mut b, "let z: m::Foo::K = 5;", "expected a type, found constant 'm::Foo::K'", "9:12");
    qual_fails(&mut b, "let z: m::U::MAX = 5;", "expected a type, found constant 'm::U::MAX'", "9:12");
    qual_fails(&mut b, "let z: m::D::Y = m::D::Y;", "expected a type, found variant 'm::D::Y'", "9:12");
    qual_fails(&mut b, "let z = 3 as m::U::MAX;", "expected a type, found constant 'm::U::MAX'", "9:18");
    p.expect_batch(b);
}

// An extensionless input still produces build/<stem>.c.
@test
fn extensionless_appends() {
    let p = cli::proj_new();
    p.mkfile("noext", "fn main() i32 { return 0; }\n");
    let mut _r = p.compile("noext"); // result held for RAII only
    assert(p.gen_exists("noext.c"), "an extensionless input still produces build/<stem>.c");
}

// A missing input file is a nonzero exit and the path is named.
@test
fn missing_file() {
    let p = cli::proj_new();
    let r = p.compile("does_not_exist.spc");
    assert(r.exit != 0, "a missing input file is a nonzero exit");
    assert(r.out_has("does_not_exist.spc"), "the error names the path");
}

// Argc > 2 exits 1 with usage.
@test
fn usage() {
    let p = cli::proj_new();
    let r = p.run_raw("a b");
    assert_eq(r.exit, 1);
    assert(r.out_has("USAGE:"), "usage is printed");
}

// `--help` and `-h`, in any position, print the usage on stdout and succeed. The usage states what
// `--jobs` sets and what `--emit-c` writes.
@test
fn help_flag() {
    let p = cli::proj_new();
    let out = format("{}/help.out", p.dir());
    let err = format("{}/help.err", p.dir());
    for a in ["--help", "-h", "build --help"] {
        let mut cmd = format("\"{}\" {}", cli::superc_path(), a);
        let mut op = out.clone();
        let mut ep = err.clone();
        assert_eq(cli::run_with(cmd.cstr(), null, op.cstr(), ep.cstr(), ""), 0);
        let text = cli::read_text(out.as_str());
        assert(text.as_str().contains("USAGE:"), "the usage is on stdout");
        assert(text.as_str().contains("the compiler's own threads"), "--jobs names every worker it sets");
        assert(
            text.as_str().contains("their compile and link in `__cflags` and `__ldflags`"),
            "--emit-c names its files",
        );
    }
    // A flag the command does not take is named before the usage.
    p.mkfile("app.spc", "fn main() i32 {\n    return 0;\n}\n");
    for a in ["--jobs=1", "--bogus"] {
        let mut cmd = format("\"{}\" \"{}/app.spc\" {}", cli::superc_path(), p.dir(), a);
        let mut op = out.clone();
        let mut ep = err.clone();
        assert_eq(cli::run_with(cmd.cstr(), null, op.cstr(), ep.cstr(), ""), 1);
        let text = cli::read_text(err.as_str());
        assert(
            text.as_str().starts_with(format("error: unexpected argument '{}'\n", a).as_str()),
            "the argument is named",
        );
    }
}

// A file build has no build.toml targets: `--bin` and `--lib` are errors, never ignored; the removed C
// compile options are unknown.
@test
fn file_build_flags() {
    let p = cli::proj_new();
    p.mkfile("app.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    for f in ["--cstd=-std=c11", "--cc=cc", "--sanitizers"] {
        let r = p.run_raw(format("build \"{}/app.spc\" -o \"{}/app\" {}", root, root, f).as_str());
        assert(r.exit == 1 && r.out_has("unexpected argument"), "a C compile option is unknown");
    }
    for f in ["--bin=x", "--lib"] {
        let r = p.run_raw(format("build \"{}/app.spc\" -o \"{}/app\" {}", root, root, f).as_str());
        assert_eq(r.exit, 1);
        assert(r.out_has("need build.toml"), "a target selector without build.toml is an error");
    }
}

// A script's `--test-record-durations` names its file: the script has no suite directory for the
// default `durations.tsv`.
@test
fn script_record_durations_needs_a_file() {
    let p = cli::proj_new();
    p.mkfile("a.spc", "@test\nfn t() {}\n\nfn main() i32 {\n    return 0;\n}\n");
    let r = p.compile_flags("--test --test-record-durations", "a.spc");
    assert_eq(r.exit, 1);
    assert(r.out_has("--test-record-durations needs a file"), "the run says what is missing");
}

// A type error: no output file is written, the diagnostic is reported, and the exit is nonzero.
@test
fn error_exit_code() {
    let p = cli::proj_new();
    p.mkfile("bad.spc", "fn main() i32 { let x: bool = 1; }\n");
    let r = p.compile("bad.spc");
    assert(!p.gen_exists("bad.c"), "no output file is written when compilation fails");
    assert(r.out_has("mismatched types"), "the diagnostic is reported");
    assert(r.exit != 0, "CLI exits nonzero on a compile error");
}

// CTFE hardening: const-dependency cycles are diagnosed (not budget-burned), proven UB in an
// emitted expression fails the build with call-stack detail, a short-circuited RHS never
// false-positives, an unfoldable array length is a hard error, and a provable panic in a plain
// function keeps its defined runtime behavior.
@test
fn ctfe_reinterpret_is_not_folded() {
    // A pointer-cast type pun (`*((&x) as *const f64 as *const u64)`) has no compile-time byte
    // representation to read through: the evaluator must LEAVE it to runtime, not substitute the
    // unconverted value. The literal also carries its context's type, so the fold that does happen
    // (none here) would be at the right precision.
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import stdio;
fn bits(v: f64) u64 {
    let x = v;
    return unsafe *((&x) as *const f64 as *const u64);
}
fn main() i32 {
    // 0.1 at f64 precision has bit pattern 0x3FB999999999999A; an f32-precision or value-substituted
    // fold produces something else.
    return (bits(0.1) != 0x3FB999999999999A) as i32;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let run = p.run_bin_env("");
    assert(run.ok());
}

@test
fn ctfe_hardening() {
    h::expect_err_msg(
        "a constant cycle",
        M"(const A: i32 = B;
const B: i32 = A;
static_assert(A == 0);
fn main() i32 { return 0; }
)",
        "cyclic constant dependency",
    );
    h::expect_err_msg(
        "a division by a zero constant",
        M"(const Z: i32 = 0;
fn scale(x: i32) i32 { return x * 2 / Z; }
fn main() i32 { return scale(4); }
)",
        "undefined behavior",
    );
    h::expect_err_msg(
        "a run-time array length",
        M"(fn main() i32 { let n = 4; let a: [i32; n] = [1, 2, 3, 4]; return a[0] - 1; }
)",
        "array length must be a constant expression",
    );
}

fn ctfe_hardening_runs(b: &mut h::ExitBatch) {
    b.add(
        "a short-circuit guards the division by a zero constant",
        M"(const Z: i32 = 0;
fn main() i32 { if Z != 0 && 10 / Z > 1 { return 1; } return 0; }
)",
        0,
    );
    // A provable panic in a NON-const fn stays runtime behavior (build ok, binary aborts).
    b.add_trap(
        "the panic still aborts at runtime",
        M"(fn boom() i32 { panic("boom"); }
fn main() i32 { return boom(); }
)",
        "boom",
    );
}

// A cycle and a failing constant at the far end of a 5000-constant chain report their own
// diagnostics: the evaluation reaches them without nesting per constant.
@test
fn deep_constant_chain_failures() {
    let mut cyc = String::new();
    for i in 0..5000 {
        cyc.push_str(format("const C{}: i32 = C{} + 1;\n", i, (i + 1) % 5000).as_str());
    }
    cyc.push_str("static_assert(C0 == 0);\nfn main() i32 { return 0; }\n");
    h::expect_err_msg("a 5000-constant cycle", cyc.as_str(), "cyclic constant dependency");

    let mut ub = String::from_str("const C0: i32 = 1 / 0;\n");
    for i in 1..5000 {
        ub.push_str(format("const C{}: i32 = C{} % 7 + 1;\n", i, i - 1).as_str());
    }
    ub.push_str("fn main() i32 { return C4999; }\n");
    h::expect_err_msg(
        "a trap at the far end of a 5000-constant chain",
        ub.as_str(),
        "error: constant 'C0' cannot be evaluated at compile time: division by zero",
    );
}

// A call-free constant used only by a function body that cannot fold reports at the constant before
// emission: a cycle at every constant on it, a refusal once the flush finds it still undecided.
@test
fn call_free_constant_failures() {
    // The cycle's program is two cases: one per constant on it. The build reports the second
    // constant and the flush's refusal, which the in-process check does not reach.
    let cyc = "const A: i32 = B + 1;\nconst B: i32 = A + 1;\nfn main() i32 { return A; }\n";
    let mut b = cli::Batch::new("", "");
    b.forbid("internal");
    b.add("the cycle at A", cyc, "error: constant 'A' cannot be evaluated at compile time: cyclic constant dependency");
    b.add("the cycle at B", cyc, "error: constant 'B' cannot be evaluated at compile time: cyclic constant dependency");
    b.add(
        "a constant that reads a static",
        "static mut S: i32 = 1;\nconst C: i32 = unsafe S;\nfn main() i32 { return C; }\n",
        "error: constant cannot be evaluated at compile time: the initializer does not fold to a constant",
    );
    let p = cli::proj_new();
    p.expect_batch(b);
}

// A chain of aggregate constants evaluates each once: a reference thaws the memoized value
// instead of evaluating the chain behind it again.
@test
fn deep_aggregate_constant_chain() {
    let mut src = String::from_str("struct S { pub x: i64 }\nconst S0: S = S { x: 0 };\n");
    for i in 1..3000 {
        src.push_str(format("const S{}: S = S {{ x: S{}.x + 1 }};\n", i, i - 1).as_str());
    }
    src.push_str("fn main() i32 { return (S2999.x % 256) as i32; }\n");
    let p = cli::proj_new();
    p.mkfile("agg.spc", src.as_str());
    let r = p.native_build("", "agg.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 2999 % 256);
}

// A discriminant naming a variant of an enum in another module folds to its value there.
@test
fn enum_discriminant_across_modules() {
    let p = cli::proj_new();
    p.mkfile("lib/codes.spc", "pub const BASE: i32 = 40;\npub enum Code { Low = BASE, High }\n");
    p.mkfile(
        "use.spc",
        M"(import lib::codes;
enum Mine { First = lib::codes::Code::High as i32 + 1, Second }
static_assert(Mine::Second as i32 == 43);
fn main() i32 { let m = Mine::Second; return m as i32; }
)",
    );
    let r = p.native_build("", "use.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 43);
}

// Under --bootstrap-tags an unknown attribute has no kind, so its repeat is caught by name: the
// one-occurrence rule holds for tags this compiler does not know yet.
@test
fn duplicate_unknown_attribute_under_bootstrap_tags() {
    let p = cli::proj_new();
    p.mkfile("dup.spc", "@zz.newtag\n@zz.newtag(1)\nfn f() i32 { return 1; }\nfn main() i32 { return f() - 1; }\n");
    let r = p.compile_flags("--bootstrap-tags", "dup.spc");
    assert(r.exit != 0, "repeated unknown attribute rejected");
    assert(r.out_has("duplicate attribute '@zz.newtag'"), "duplicate diagnostic");
    let p2 = cli::proj_new();
    p2.mkfile("two.spc", "@zz.a\n@zz.b\nfn f() i32 { return 1; }\nfn main() i32 { return f() - 1; }\n");
    assert(p2.compile_flags("--bootstrap-tags", "two.spc").exit == 0, "distinct unknown attributes accepted");
}

// const fn: definition-site validation (direct and transitive disqualifiers), a call with known
// arguments folds, and legal recursion between const fns.
@test
fn const_fn_semantics() {
    // The programs import stdlib, which the in-process compile does not load: a build.
    let mut b = cli::Batch::new("", "");
    b.add(
        "a const fn that calls an extern function",
        M"(import stdlib;
const fn bad() i32 { return unsafe stdlib::rand(); }
fn main() i32 { return 0; }
)",
        "declared 'const fn' but calls an extern function",
    );

    b.add(
        "a const fn that calls a function that cannot be evaluated",
        M"(import stdlib;
fn helper() i32 { return unsafe stdlib::rand(); }
const fn outer() i32 { return helper(); }
fn main() i32 { return 0; }
)",
        "calls a function that cannot be evaluated at compile time",
    );
    let bp = cli::proj_new();
    bp.expect_batch(b);
}

fn const_fn_semantics_runs(b: &mut h::ExitBatch) {
    // A dangling-sentinel pointer (`alignof(T) as *mut T`) folds: the shape every ZST buffer in
    // std relies on, and a `const fn` caller with known arguments must evaluate through it.
    b.add(
        "a dangling-sentinel pointer folds",
        M"(extern "C" { fn exit(c: i32) void; }
const fn dang<T>() *mut T { return alignof(T) as *mut T; }
const fn probe() i32 {
    let a = dang::<u64>();
    if a == null { return 1; }
    return 0;
}
fn main() i32 { unsafe exit(probe()); return 0; }
)",
        0,
    );
    // A `const fn` call with known arguments outside a constant context folds to its value.
    b.add(
        "a const fn call with known arguments folds",
        M"(const fn spin(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s = s + i; i = i + 1; }
    return s;
}
fn main() i32 { let x = spin(1000u64); if x != 499500u64 { return 1; } return 0; }
)",
        0,
    );
    // Mutually recursive const fns are legal; const fn also runs as a normal function at runtime.
    b.add(
        "mutually recursive const fns fold and run",
        M"(const fn is_even(n: u32) bool { if n == 0 { return true; } return is_odd(n - 1); }
const fn is_odd(n: u32) bool { if n == 0 { return false; } return is_even(n - 1); }
static_assert(is_even(10));
fn main(argv: Vector<str>) i32 { if is_even(argv.len() as u32 * 2) { return 0; } return 1; }
)",
        0,
    );
}

// Mandatory evaluation of call-bearing const initializers: a non-evaluable initializer is a hard
// error (even when the failure is silent, via the flush pass), a trapping one carries the trap,
// and cross-module const-fn initializers work.
@test
fn mandatory_consts() {
    let p = cli::proj_new();
    // Two programs import stdlib, which the in-process compile does not load: one build for the three.
    let mut b = cli::Batch::new("", "");
    b.add(
        "a silent failure of an initializer",
        M"(import stdlib;
fn noisy() i32 { return unsafe stdlib::rand(); }
const X: i32 = noisy() + 1;
fn main() i32 { return X * 0; }
)",
        "constant cannot be evaluated at compile time",
    );

    b.add(
        "a trapping initializer",
        M"(fn div(a: i32, b: i32) i32 { return a / b; }
const D: i32 = div(1, 0);
fn main() i32 { return D; }
)",
        "division by zero",
    );

    let p3 = cli::proj_new();
    p3.mkfile("lib/cf.spc", "pub const fn triple(x: i32) i32 { return x * 3; }\n");
    p3.mkfile(
        "use.spc",
        M"(import lib::cf;
const T: i32 = lib::cf::triple(9);
static_assert(T == 27);
fn main() i32 { return T - 27; }
)",
    );
    let r3 = p3.native_build("", "use.spc");
    assert(r3.ok(), "the program compiles");
    assert_eq(p3.run_bin(), 0);

    // A const pointing at freed compile-time memory is rejected.
    b.add(
        "a constant that points at freed compile-time memory",
        M"(import stdlib;
pub struct Holder { pub p: *mut i32 }
fn mk() Holder {
    let q = unsafe stdlib::malloc(4) as *mut i32;
    unsafe stdlib::free(q as *mut void);
    return Holder { p: q };
}
const H: Holder = mk();
fn main() i32 { return 0; }
)",
        "freed compile-time memory",
    );
    p.expect_batch(b);
}

// A local constant is a compile-time value like an item constant, whatever its initializer calls:
// a plain function call folds to static data, a silent failure is an error, a read of a variable is
// an error, and a per-instance constant's failure names the constant.
@test
fn local_consts_are_compile_time() {
    let c = h::compile_c(LOCAL_FOLD);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("LOC__"), "the local constant is static data");
    assert(c.code_has(" = 36;"), "its value is computed at compile time");

    // The silent failure imports stdlib, which the in-process compile does not load, and the
    // instance's constant fails when the build lowers the instance: one build for the two.
    let mut b = cli::Batch::new("", "");
    b.add(
        "a silent failure of a local constant",
        M"(import stdlib;
fn noisy() i32 { return unsafe stdlib::rand(); }
fn main() i32 {
    const X: i32 = noisy();
    return X * 0;
}
)",
        "constant cannot be evaluated at compile time",
    );
    b.add(
        "a per-instance constant's failure names the constant",
        M"(fn bad<T>(x: usize) usize {
    if x > 3 {
        const B: usize = 10 / (sizeof(T) - sizeof(T));
        return B;
    }
    return x;
}
fn main(argv: Vector<str>) i32 { return bad::<u8>(argv.len()) as i32 - 1; }
)",
        "constant 'B' cannot be evaluated at compile time for an instance: division by zero",
    );
    let bp = cli::proj_new();
    bp.expect_batch(b);
    h::expect_err_msg(
        "a local constant cannot read a variable",
        M"(fn sq(x: i32) i32 { return x * x; }
fn main(argv: Vector<str>) i32 {
    let y = argv.len() as i32;
    const Z: i32 = sq(y);
    return Z - 1;
}
)",
        "a constant cannot read the variable 'y'",
    );
}

const LOCAL_FOLD: str = M"(fn sq(x: i32) i32 { return x * x; }
fn main() i32 {
    const LOC: i32 = sq(6);
    return LOC - 36;
}
)";

fn local_consts_run(b: &mut h::ExitBatch) {
    b.add("a local constant folds", LOCAL_FOLD, 0);
}

// `@unsafe(...)` lists claims about an extern function, in any order: `safe` makes it callable without
// `unsafe`; `const` gives it a body that compile-time evaluation runs while run-time calls go to the C
// symbol. It applies only to a function in an extern block, once, and the compiler rejects the claims it
// can disprove.
@test
fn unsafe_extern_attributes() {
    let p = cli::proj_new();
    p.mkfile(
        "ok.spc",
        M"(extern "C" {
    @unsafe(safe) fn toupper(c: i32) i32;
    @unsafe(safe, const) fn llabs(x: i64) i64 {
        if x < 0 { return -x; }
        return x;
    }
    @unsafe(const) fn imaxabs(x: i64) i64 { return llabs(x); }
    @unsafe(const, safe) fn abs(x: i32) i32 { return llabs(x as i64) as i32; }
}
const A: i64 = llabs(-7);
static_assert(A == 7, "a modeled extern folds");
static_assert(unsafe imaxabs(-2) == 2, "an unsafe modeled extern folds");
const fn twice(x: i64) i64 { return llabs(x) * 2; }
static_assert(twice(-4) == 8, "a const fn calls a modeled extern");
static_assert(abs(-3) == 3, "the claims list in any order");
fn main(argv: Vector<str>) i32 {
    let n = argv.len() as i32;
    return toupper(97) - 65 + abs(-n) + llabs(-(n as i64)) as i32 + unsafe imaxabs(-1) as i32 - 3;
}
)",
    );
    let r = p.compile("ok.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("ok.c", "llabs(_"), "a run-time call goes to the C symbol");
    assert(!p.gen_has("ok.c", "int64_t llabs("), "the model body is never emitted");
    let cc = p.native_build("", "ok.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);

    // Each program fails to compile with a diagnostic containing its text.
    h::expect_err_msg(
        "safe outside an extern block",
        "@unsafe(safe)\nfn f() i32 { return 1; }\nfn main() i32 { return f() - 1; }\n",
        "may only be applied to a function in an 'extern \"C\"' block",
    );
    h::expect_err_msg(
        "an unknown claim",
        "extern \"C\" {\n    @unsafe(fast) fn abs(x: i32) i32;\n}\nfn main() i32 { return 0; }\n",
        "attribute '@unsafe' takes a list of the claims 'safe', 'const', 'naked' and 'link_section = \"name\"'",
    );
    h::expect_err_msg(
        "a duplicate attribute",
        "extern \"C\" {\n    @unsafe(safe) @unsafe(const) fn llabs(x: i64) i64 { return x; }\n}\nfn main() i32 { return 0; }\n",
        "duplicate attribute '@unsafe'",
    );
    h::expect_err_msg(
        "a claim listed twice",
        "extern \"C\" {\n    @unsafe(safe, safe) fn abs(x: i32) i32;\n}\nfn main() i32 { return 0; }\n",
        "claim 'safe' is listed twice in '@unsafe(...)'",
    );
    h::expect_err_msg(
        "a safe function that takes a raw pointer",
        "extern \"C\" {\n    @unsafe(safe) fn strlen(s: *const u8) usize;\n}\nfn main() i32 { return 0; }\n",
        "cannot take a raw pointer",
    );
    h::expect_err_msg(
        "a safe variadic function",
        "extern \"C\" {\n    @unsafe(safe) fn printf(f: i32, ...) i32;\n}\nfn main() i32 { return 0; }\n",
        "cannot be variadic",
    );
    h::expect_err_msg(
        "a safe function that returns a borrow",
        "extern \"C\" {\n    @unsafe(safe) fn get(x: &i32) &i32;\n}\nfn main() i32 { return 0; }\n",
        "cannot return a borrow",
    );
    h::expect_err_msg(
        "an extern body without the const claim",
        "extern \"C\" {\n    fn abs(x: i32) i32 { return x; }\n}\nfn main() i32 { return 0; }\n",
        "extern function declarations cannot have a body",
    );
    h::expect_err_msg(
        "a const claim without a body",
        "extern \"C\" {\n    @unsafe(const) fn abs(x: i32) i32;\n}\nfn main() i32 { return 0; }\n",
        "an '@unsafe(const)' extern function needs a body",
    );
    h::expect_err_msg(
        "a call of a const extern function needs unsafe",
        "extern \"C\" {\n    @unsafe(const) fn llabs(x: i64) i64 { return x; }\n}\nfn main() i32 { return llabs(0) as i32; }\n",
        "calling an extern \"C\" function requires an 'unsafe' block",
    );
    // These import stdlib, which the in-process compile does not load: a build.
    let mut b = cli::Batch::new("", "");
    b.file = String::from_str("bad.spc");
    b.add(
        "a const extern body that calls an extern function",
        "import stdlib;\nextern \"C\" {\n    @unsafe(const) fn r() i32 { return unsafe stdlib::rand(); }\n}\nfn main() i32 { return 0; }\n",
        "is declared '@unsafe(const)' but calls an extern function",
    );
    b.add(
        "an extern function named as a value needs unsafe",
        "import stdlib;\nfn main() i32 {\n    let f: fn(i32) void = stdlib::exit;\n    f(0);\n    return 0;\n}\n",
        "naming an extern \"C\" function as a value requires an 'unsafe' block",
    );
    p.expect_batch(b);
}

// The ffi/ bindings carry the claims: libm and the pointer-free queries are callable without `unsafe`, and
// the fully specified string and integer functions fold through their models. A string literal reads as a
// C string at compile time as at run time: its storage ends in a NUL and `char` views its bytes.
@test
fn ffi_bindings_carry_unsafe_claims() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import math;
import stdlib;
import string as cstring;
import unistd;
const fn clen(s: str) usize { return unsafe cstring::strlen(s.ptr() as *const char); }
const fn tail(p: *mut char) usize { return unsafe cstring::strlen(p); }
const L: usize = clen("hello");
static_assert(L == 5, "strlen folds over a literal");
static_assert(tail(unsafe cstring::strchr("a/b/c".ptr() as *const char, 47)) == 4, "strchr");
static_assert(tail(unsafe cstring::strrchr("a/b/c".ptr() as *const char, 47)) == 2, "strrchr");
static_assert(tail(unsafe cstring::strstr("abcdef".ptr() as *const char, "cd".ptr() as *const char)) == 4, "strstr");
static_assert(unsafe cstring::strstr("abc".ptr() as *const char, "x".ptr() as *const char) == null, "strstr miss");
static_assert(tail(unsafe cstring::memchr("hello".ptr() as *const void, 108, 5) as *mut char) == 3, "memchr");
static_assert(unsafe stdlib::abs(-4) == 4 && unsafe stdlib::llabs(-9) == 9, "abs and llabs");
fn main() i32 {
    if unistd::getpid() <= 0 {
        return 1;
    }
    return math::sqrt(16.0) as i32 - 4 + (unsafe cstring::strlen("hello".ptr() as *const char) - L) as i32;
}
)",
    );
    assert(p.native_build("", "main.spc").ok());
    assert(p.run_bin_env("SC_LEAK_CHECK=fatal ").ok());
}

// Aggregate materialization: compile-time-computed structs, Vectors, strings, shared pointers, and
// cyclic heap graphs land as deterministic static C data (with relocations) and behave at runtime.
@test
fn materialized_consts() {
    let p = cli::proj_new();
    p.mkfile(
        "mat.spc",
        M"(import stdlib;
pub struct Pt { pub x: i32, pub y: i32 }
pub struct Node { pub v: i32, pub next: *mut Node }
pub struct Pair { pub a: *mut Node, pub b: *mut Node }
fn mid(a: Pt, b: Pt) Pt { return Pt { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; }
fn evens(n: u32) Vector<u32> {
    let mut v = Vector::<u32>::new();
    for i in 0..n { v.push(i * 2); }
    return v;
}
fn evens_arr() Array<u32, 5> {
    let src = evens(5);
    let mut a = Array::<u32, 5>::new();
    for i in 0..a.len() { a.set(i, *src.at(i)); }
    return a;
}
fn greet() str<'static> { return "hello"; }
fn ring() Pair {
    let a = unsafe stdlib::malloc(sizeof(Node)) as *mut Node;
    let b = unsafe stdlib::malloc(sizeof(Node)) as *mut Node;
    unsafe {
        *a = Node { v: 1, next: b };
        *b = Node { v: 2, next: a };
    }
    return Pair { a: a, b: b };
}
const M: Pt = mid(Pt { x: 2, y: 10 }, Pt { x: 6, y: 30 });
const V: Array<u32, 5> = evens_arr();
const S: str = greet();
const P: Pair = ring();
fn main() i32 {
    if M.x != 4 || M.y != 20 { return 1; }
    if V.len() != 5 || *V.at(4) != 8u32 { return 2; }
    if S.len() != 5 { return 3; }
    unsafe {
        if (*(*P.a).next).v != 2 { return 4; }
        if (*(*P.b).next).v != 1 { return 5; }
    }
    let lv = evens(3); // a LOCAL owning value is fine: real scope exit, real ownership
    if lv.len() != 3 { return 6; }
    return 0;
}
)",
    );
    let r = p.compile("mat.spc");
    assert(r.ok());
    assert(p.gen_has("mat__inst.c", "__ct0"), "auxiliary statics are emitted");
    assert(p.gen_has("mat__inst.c", ".next = (void *)"), "pointer relocations are emitted");
    let cc = p.native_build("", "mat.spc");
    assert(cc.ok());
    assert_eq(p.run_bin(), 0);

    // An owning (Free) type materializes too: buffer and all. What keeps it sound is that no copy
    // can exist to free it: the value is immutable and cannot be moved out of the constant.
    let p2 = cli::proj_new();
    p2.mkfile(
        "own.spc",
        M"(fn evens(n: u32) Vector<u32> {
    let mut v = Vector::<u32>::new();
    for i in 0..n { v.push(i * 2); }
    return v;
}
const V: Vector<u32> = evens(5);
fn main() i32 {
    let mut t: u32 = 0;
    for i in 0..V.len() { t = t + *V.at(i); }
    if t != 20u32 { return 1; }
    return 0;
}
)",
    );
    let r2 = p2.compile("own.spc");
    assert(r2.ok(), "the program compiles");
    assert(p2.gen_has("own__inst.c", "static const uint32_t V__ct0[8]"), "the Vector's buffer is static data");
    assert(!p2.gen_has("own__inst.c", "Vector__u32__free(&V)"), "a materialized const is never freed");
    let cc2 = p2.native_build("", "own.spc");
    assert(cc2.ok(), "the program builds");
    // Bind it: run_bin_env hands the captured output to the caller, and dropping it leaks the buffer.
    let lk2 = p2.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(lk2.ok(), "the program runs without a leak");

    // And nothing can obtain a copy to free, or mutate it in place.
    h::expect_err_msg(
        "a copy of an owning constant",
        "const V: Vector<u32> = [1u32, 2u32].into();\nfn main() i32 {\n    let c = V;\n    return (c.len()) as i32;\n}\n",
        "cannot move a value out of a 'const' binding",
    );
    h::expect_err_msg(
        "a mutation of an owning constant",
        "const V: Vector<u32> = [1u32, 2u32].into();\nfn main() i32 {\n    V.push(3u32);\n    return 0;\n}\n",
        "cannot call a '&mut self' method on an immutable binding",
    );
    // An owning constant has no runtime construction to fall back on: it folds, or it is an error.
    // The flush before emission reports the two below, which the in-process check does not reach.
    let mut b = cli::Batch::new("", "");
    b.add(
        "an owning constant built from a run-time value",
        "extern \"C\" { fn rand() i32; }\nfn mk() Vector<i32> {\n    let mut v = Vector::<i32>::new();\n    v.push(unsafe rand());\n    return v;\n}\nconst V: Vector<i32> = mk();\nfn main() i32 { return 0; }\n",
        "cannot be evaluated at compile time",
    );
    // Inline assembly has no compile-time meaning either: a constant cannot be built from it.
    b.add(
        "a constant built from inline assembly",
        "fn mk() i64 {\n    let mut o: i64 = 0;\n    unsafe { asm(\"mov %0, #1\" : \"=r\"(o)); }\n    return o;\n}\nconst V: i64 = mk();\nfn main() i32 { return V as i32; }\n",
        "cannot be evaluated at compile time",
    );
    let bp = cli::proj_new();
    bp.expect_batch(b);
}

// Differential: a const fn produces the same value at compile time (const initializer) and at
// runtime (plain call), for arithmetic- and branch-heavy bodies.
@test
fn ctfe_differential() {
    let p = cli::proj_new();
    p.mkfile(
        "diff.spc",
        M"(const fn mix(n: u32) u64 {
    let mut h: u64 = 1469598103934665603u64;
    let mut i: u32 = 0;
    while i < n {
        h = (h ^ i as u64).wrapping_mul(1099511628211u64);
        if (h & 1u64) == 0u64 { h = h >> 1; } else { h = h.wrapping_mul(3u64).wrapping_add(1u64); }
        i = i + 1;
    }
    return h;
}
const CT: u64 = mix(500);
fn main(argv: Vector<str>) i32 {
    let rt = mix(499 + argv.len() as u32);
    if rt == CT { return 0; }
    return 1;
}
)",
    );
    let r = p.native_build("", "diff.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// `import std::core;` loads the very file the prelude auto-loads, so the loader flags it in place instead
// of loading a second copy under `__std::core`. The builtin seeder recognised only the `__std::core` PATH,
// so an explicit import left `i8`/`i32`/... without their synthetic nominal decls and every
// `extend i8 as Ord` in that same file then failed its `Eq` superinterface. Any std module may be named
// explicitly; core is the one whose own body depends on the seeding.
@test
fn explicit_std_module_import() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::core as core;\nimport std::vector as vec;\n\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(3);\n    let ok = v.at(0) == 3;\n    v.free();\n    if ok { return 0; }\n    return 1;\n}\n",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// A generic body is emitted in whichever TU instantiates it, so everything it names has to be reachable
// from there. Its module's PRIVATE items are not: a const is `static` in its own TU (folded at the use
// site now) and so is a plain function (given external linkage and a header prototype now). A `str` value
// it passes (`panic("..")`) needs that type's LAYOUT, which this TU's header only forward-declares
// unless the include set follows the owner's.
@test
fn generic_body_reaches_its_own_module() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        "fn helper(x: i32) i32 {\n    return x + 1;\n}\n\nconst BUMP: i32 = 2;\n\npub fn pick<T>(v: T, n: i32, take: bool) i32 {\n    if !take {\n        panic(\"nope\");\n    }\n    return helper(n) + BUMP;\n}\n",
    );
    p.mkfile("main.spc", "import lib as lib;\n\nfn main() i32 {\n    return lib::pick(0, 1, true) - 4;\n}\n");
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// A const-sized array in an imported module: lowering that type to learn its layout happens while the
// IMPORTING module is checked, before the owner is, so a length that names a const has nothing to fold to
// yet. That is not the program's fault, and the diagnostic belonged to the owner's file anyway.
@test
fn imported_const_sized_array() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        "pub struct Head {\n    pub p: *mut u8,\n    pub n: usize,\n}\n\nconst CAP: usize = sizeof(Head) - 1;\n\npub struct Small {\n    pub d: [u8; CAP],\n    pub n: u8,\n}\n\npub union Repr {\n    pub big: Head,\n    pub small: Small,\n}\n\npub struct Val {\n    pub r: Repr,\n}\n\nextend Val {\n    pub const fn make(k: u8) Val {\n        return Val { r: Repr { small: Small { d: [0; CAP], n: k } } };\n    }\n    pub const fn get(self: &Val) u8 {\n        return self.r.small.n;\n    }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import lib as lib;\n\nconst V: lib::Val = lib::Val::make(7);\n\nfn main() i32 {\n    return V.get() as i32 - 7 + (sizeof(lib::Val) as i32) - (sizeof(usize) as i32) * 2;\n}\n",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    assert_eq(p.run_bin(), 0);
}

// `bindgen` reads a C header through its own preprocessor and writes the `extern "C"` module for it.
// Checked end to end, because the only claim worth making is that the generated bindings COMPILE and CALL
// the library: the test links a real implementation, compiled beside the program, and reads its answer
// back.
@test
fn bindgen_generates_callable_bindings() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#include <stddef.h>\ntypedef struct lib_ctx lib_ctx;\ntypedef int (*lib_cb)(const char *s, void *user);\nlib_ctx *lib_open(int seed);\nsize_t lib_len(const lib_ctx *c, const char *s, unsigned long bump);\nvoid lib_each(lib_ctx *c, lib_cb cb, void *user);\nvoid lib_close(lib_ctx *c);\nstatic inline int lib_inline(int x) { return x; }\n#endif\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\n#include <stdlib.h>\n#include <string.h>\nstruct lib_ctx { int seed; };\nlib_ctx *lib_open(int seed) { lib_ctx *c = malloc(sizeof *c); if (c) c->seed = seed; return c; }\nsize_t lib_len(const lib_ctx *c, const char *s, unsigned long bump) { return strlen(s) + (size_t)c->seed + bump; }\nvoid lib_each(lib_ctx *c, lib_cb cb, void *user) { (void)c; cb(\"x\", user); }\nvoid lib_close(lib_ctx *c) { free(c); }\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    let gen = p.run_raw(args.as_str());
    assert(gen.ok(), "bindgen succeeds");

    let mut path = String::new();
    path.format_into("{}/lib.spc", root);
    let mut spc = String::new();
    switch loader::read_file(path.as_str()) {
        Some(t) => {
            spc.push_string(&t);
        },
        None => {},
    };
    // The shapes the mapper has to get right, and the one it must leave out.
    assert(spc.as_str().contains("pub type lib_ctx;"));
    assert(spc.as_str().contains("pub fn lib_open(seed: i32) *mut lib_ctx;"));
    assert(spc.as_str().contains("c: *const lib_ctx"));
    assert(spc.as_str().contains("s: *const char"));
    assert(spc.as_str().contains("bump: u64") || spc.as_str().contains("bump: u32"));
    assert(spc.as_str().contains("usize"));
    assert(spc.as_str().contains("cb: fn(*const char, *mut void) i32"));
    // A static inline has no symbol to bind.
    assert(!spc.as_str().contains("lib_inline"));

    p.mkfile(
        "main.spc",
        "@link(\"-L. -llib\")\nextern \"C\" {}\nimport lib;\n\nfn main() i32 {\n    let c = unsafe lib::lib_open(3);\n    let n = unsafe lib::lib_len(c, \"abcd\".ptr() as *const char, 2);\n    unsafe lib::lib_close(c);\n    if n == 9 { return 0; }\n    return 1;\n}\n",
    );
    assert(p.c_lib("lib", "lib.c"), "the C library builds");
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// The bindings a C library needs: its records, its enums and its constants, not just its
// functions. A record declared inside the extern block IS the header's type: the emitted C uses the
// header's own definition and checks each field against it, so the test passes a struct BY POINTER
// and BY VALUE, reads an enumerator back through C, and compares a generated const.
@test
fn bindgen_generates_records_enums_and_consts() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#include <stddef.h>\n#define LIB_VERSION 7\n#define LIB_NAME \"lib\"\n#define LIB_SCALE 0.5\n#define LIB_EXPR (LIB_VERSION + 1)\n#define LIB_MODE 0170000\n#define LIB_MASK 0b101u\n#define LIB_ZERO 0\nenum lib_mode { LIB_FAST, LIB_SLOW = 10, LIB_LAST };\nenum { LIB_FLAG_A = 1, LIB_FLAG_B = 2 };\ntypedef struct lib_pt { int x; int y; } lib_pt;\nstruct lib_cfg { const char *name; size_t len; lib_pt origin; char tag[8]; enum lib_mode mode; };\nstruct lib_bits { unsigned a : 3; };\nstruct lib_wrap { struct lib_bits b; int n; };\nint lib_wrap_n(const struct lib_wrap *w);\nint lib_wrap_by_value(struct lib_wrap w);\nint lib_sum(const struct lib_cfg *c);\nlib_pt lib_origin(const struct lib_cfg *c);\nint lib_mode_of(enum lib_mode m);\n#endif\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\n#include <string.h>\nint lib_sum(const struct lib_cfg *c) { return (int)c->len + c->origin.x + c->origin.y + (int)c->mode + c->tag[0]; }\nlib_pt lib_origin(const struct lib_cfg *c) { return c->origin; }\nint lib_mode_of(enum lib_mode m) { return (int)m; }\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);

    let mut path = String::new();
    path.format_into("{}/lib.spc", root);
    let mut spc = String::new();
    switch loader::read_file(path.as_str()) {
        Some(t) => {
            spc.push_string(&t);
        },
        None => {},
    };
    // An integer constant sits in the extern block, whose C compile checks it; the others do not.
    assert(spc.as_str().contains("    pub const LIB_VERSION: i32 = 7;"));
    assert(spc.as_str().contains("\npub const LIB_NAME: str<'static> = \"lib\";"));
    assert(spc.as_str().contains("\npub const LIB_SCALE: f64 = 0.5;"));
    // An anonymous enum is a const block.
    assert(spc.as_str().contains("pub const LIB_FLAG_B: i32 = 2;"));
    // Folded from LIB_VERSION + 1.
    assert(spc.as_str().contains("pub const LIB_EXPR: i32 = 8;"));
    // C's octal and binary literals.
    assert(spc.as_str().contains("pub const LIB_MODE: i32 = 61440;"));
    assert(spc.as_str().contains("pub const LIB_MASK: u32 = 5;"));
    assert(spc.as_str().contains("pub const LIB_ZERO: i32 = 0;"));
    assert(spc.as_str().contains("LIB_SLOW = 10"));
    // A tag C never typedef'd spells as its tag, with no pin.
    assert(spc.as_str().contains("    pub enum lib_mode {"));
    assert(!spc.as_str().contains("@import(\"enum lib_mode\")"));
    // C's auto-increment continues from the explicit value.
    assert(spc.as_str().contains("LIB_LAST = 11"));
    // A record spells as its tag: no pin, whether C typedef'd it (`lib_pt`) or not (`lib_cfg`).
    assert(spc.as_str().contains("    pub struct lib_cfg {"));
    assert(!spc.as_str().contains("@import(\"struct lib_cfg\")"));
    assert(!spc.as_str().contains("@import(\"lib_pt\")"));
    // An array field keeps its extent.
    assert(spc.as_str().contains("pub tag: [char; 8]"));
    // A bitfield has no field-list form, and a record that holds one by value has no layout either.
    assert(!spc.as_str().contains("lib_bits"));
    assert(spc.as_str().contains("    pub type lib_wrap;"));
    assert(!spc.as_str().contains("pub struct lib_wrap"));
    // A function that takes it by value is skipped: Super-C holds no value of a type without a layout.
    assert(!spc.as_str().contains("lib_wrap_by_value"));

    p.mkfile(
        "main.spc",
        "@link(\"-L. -llib\")\nextern \"C\" {}\nimport lib;\n\nfn main() i32 {\n    let mut cfg = lib::lib_cfg {\n        name: \"c\".ptr() as *const char,\n        len: 5,\n        origin: lib::lib_pt { x: 2, y: 3 },\n        tag: [0 as char; 8],\n        mode: lib::lib_mode::LIB_SLOW,\n    };\n    cfg.tag[0] = 'A' as char;\n    let n = unsafe lib::lib_sum(&cfg);\n    let o = unsafe lib::lib_origin(&cfg);\n    let m = unsafe lib::lib_mode_of(lib::lib_mode::LIB_LAST);\n    if n == 85 && o.x == 2 && o.y == 3 && m == 11 && lib::LIB_VERSION == 7 { return 0; }\n    return 1;\n}\n",
    );
    assert(p.c_lib("lib", "lib.c"), "the C library builds");
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// `bindgen` takes a list of paths like `fmt` and `lint` do, and a directory recurses. The output tree
// MIRRORS the headers', which is also where each module's `#include` spelling comes from: name the include
// root and `net/http/http.h` is what the generated module writes, exactly as C code would.
@test
fn bindgen_walks_paths_recursively() {
    let p = cli::proj_new();
    p.mkfile("inc/a.h", "#ifndef A_H\n#define A_H\nint a_go(int x);\n#endif\n");
    p.mkfile("inc/net/http/http.h", "#ifndef H_H\n#define H_H\nint http_get(const char *url);\n#endif\n");
    p.mkfile("inc/README.md", "not a header\n");
    p.mkfile("other/z-lib.h", "#ifndef Z_H\n#define Z_H\nint z_run(void);\n#endif\n");
    let root = p.dir();

    let mut args = String::new();
    args.format_into("bindgen \"{}/inc\" \"{}/other/z-lib.h\" -o \"{}/gen\"", root, root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);

    let mut hp = String::new();
    hp.format_into("{}/gen/net/http/http.spc", root);
    let mut got = String::new();
    switch loader::read_file(hp.as_str()) {
        Some(t) => {
            got.push_string(&t);
        },
        None => {},
    };
    assert(got.as_str().contains("extern \"C\" \"net/http/http.h\""));
    assert(got.as_str().contains("pub fn http_get(url: *const char) i32;"));

    let mut ap = String::new();
    ap.format_into("{}/gen/a.spc", root);
    let mut top = String::new();
    switch loader::read_file(ap.as_str()) {
        Some(t) => {
            top.push_string(&t);
        },
        None => {},
    };
    assert(top.as_str().contains("extern \"C\" \"a.h\""));

    // A file name that is not an identifier cannot be imported, so the module is renamed (the `#include`
    // spelling is not).
    let mut zp = String::new();
    zp.format_into("{}/gen/z_lib.spc", root);
    let mut z = String::new();
    switch loader::read_file(zp.as_str()) {
        Some(t) => {
            z.push_string(&t);
        },
        None => {},
    };
    assert(z.as_str().contains("pub fn z_run() i32;"));

    // A directory has many outputs, so it needs somewhere to put them.
    let mut bad = String::new();
    bad.format_into("bindgen \"{}/inc\"", root);
    let r = p.run_raw(bad.as_str());
    assert_eq(r.exit, 1);
    assert(r.out_has("needs '-o <dir>'"));
}

// Constants outside i64 are left out instead of aborting bindgen; a function-pointer type with an
// unmodelled parameter is refused like a function with one; and a tag reached only through a record
// field or a global still gets its opaque declaration.
@test
fn bindgen_overflow_fnptr_params_and_field_opaques() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#define LIB_ALL 0xFFFFFFFFFFFFFFFF\n#define LIB_TOP 0x8000000000000000\n#define LIB_WIDE 99999999999999999999\n#define LIB_MUL (4611686018427387904 * 4)\n#define LIB_SUB (-9223372036854775807 - 2)\n#define LIB_SHL (3 << 62)\n#define LIB_HALF 0x4000000000000000\nenum lib_e { LIB_E_MAX = 0x7FFFFFFFFFFFFFFF, LIB_E_NEXT };\ntypedef int (*lib_cb)(struct { int x; } s);\nint lib_use_cb(lib_cb cb);\nstruct lib_holder { struct lib_hidden *h; int n; };\nextern struct lib_other *lib_global;\nint lib_get(struct lib_holder *h);\n#endif\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);

    let mut path = String::new();
    path.format_into("{}/lib.spc", root);
    let mut spc = String::new();
    switch loader::read_file(path.as_str()) {
        Some(t) => {
            spc.push_string(&t);
        },
        None => {},
    };
    assert(!spc.as_str().contains("LIB_ALL"));
    assert(!spc.as_str().contains("LIB_TOP"));
    assert(!spc.as_str().contains("LIB_WIDE"));
    assert(!spc.as_str().contains("LIB_MUL"));
    assert(!spc.as_str().contains("LIB_SUB"));
    assert(!spc.as_str().contains("LIB_SHL"));
    assert(spc.as_str().contains("pub const LIB_HALF: i64 = 4611686018427387904;"));
    assert(!spc.as_str().contains("fn(?"));
    assert(!spc.as_str().contains("lib_use_cb"));
    assert(spc.as_str().contains("pub type lib_hidden;"));
    assert(spc.as_str().contains("pub type lib_other;"));

    // The generated module resolves: every type it names is declared.
    p.mkfile("main.spc", "import lib;\n\nfn main() i32 {\n    return 0;\n}\n");
    assert(p.compile("main.spc").ok());
}

// Constants take C's types: a literal the type its base and suffix give it, operands the usual arithmetic
// conversions, an unsigned result wraps, a cast converts; a result C leaves undefined is left out.
@test
fn bindgen_constants_follow_c_types() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "typedef unsigned short lib_u16;\n#define LIB_CAST ((unsigned)-1)\n#define LIB_TOP (((unsigned long long)1 << 63) - 1)\n#define LIB_SIGN (1 << 31)\n#define LIB_CONV (-1 + 0u)\n#define LIB_WIDE (-1L + 0u)\n#define LIB_USHR (0xFFFFFFF0u >> 4)\n#define LIB_NOT (~0u)\n#define LIB_HEX 0xFFFFFFFF\n#define LIB_UDIV (-7 / 2u)\n#define LIB_TD ((lib_u16)70000)\n#define LIB_LOST (2 << 31)\n#define LIB_SCHAR ((signed char)200)\n#define LIB_CHAR ((char)1)\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);
    let spc = loader::read_file(format("{}/lib.spc", root).as_str()).unwrap();
    let t = spc.as_str();
    assert(t.contains("pub const LIB_CAST: u32 = 4294967295;"));
    assert(t.contains("pub const LIB_TOP: u64 = 9223372036854775807;"));
    assert(t.contains("pub const LIB_SIGN: i32 = -2147483648;"));
    assert(t.contains("pub const LIB_CONV: u32 = 4294967295;"));
    // `long` is 64 bits under LP64, so `-1L + 0u` stays a signed -1; 32 bits under LLP64 (Windows),
    // where the sum converts to `unsigned long`.
    if cli::on_windows() {
        assert(t.contains("pub const LIB_WIDE: u32 = 4294967295;"));
    } else {
        assert(t.contains("pub const LIB_WIDE: i32 = -1;"));
    }
    assert(t.contains("pub const LIB_USHR: u32 = 268435455;"));
    assert(t.contains("pub const LIB_NOT: u32 = 4294967295;"));
    assert(t.contains("pub const LIB_HEX: u32 = 4294967295;"));
    assert(t.contains("pub const LIB_UDIV: u32 = 2147483644;"));
    assert(t.contains("pub const LIB_TD: i32 = 4464;"));
    assert(!t.contains("LIB_LOST"));
    assert(!t.contains("LIB_SCHAR"));
    assert(!t.contains("LIB_CHAR"));
}

// The shapes a real C library uses that a literals-only reader loses: constants written as expressions
// (`(1 << 3)`, or one macro in terms of another), types declared as `typedef struct { .. } Name;` with no
// tag at all, and the globals a library exports. curl.h alone defines 91 of its constants as shift
// expressions, so refusing them was refusing most of the library's surface.
@test
fn bindgen_expressions_anonymous_types_and_globals() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#define LIB_BASE 4\n#define LIB_SHIFT (1 << 3)\n#define LIB_SUM (LIB_BASE + LIB_SHIFT)\n#define LIB_MIX ((LIB_BASE | 1) & 7)\n#define LIB_CALL(x) ((x) + 1)\ntypedef struct { int x; int y; } lib_pt;\ntypedef enum { LIB_A = 0, LIB_B = 1 << 3, LIB_C } lib_mode;\ntypedef union { int i; float f; } lib_val;\nextern int lib_counter;\nint lib_use(const lib_pt *p, lib_mode m);\n#endif\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\nint lib_counter = 41;\nint lib_use(const lib_pt *p, lib_mode m) { return p->x + p->y + (int)m; }\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);

    let mut path = String::new();
    path.format_into("{}/lib.spc", root);
    let mut spc = String::new();
    switch loader::read_file(path.as_str()) {
        Some(t) => {
            spc.push_string(&t);
        },
        None => {},
    };
    assert(spc.as_str().contains("pub const LIB_SHIFT: i32 = 8;"));
    // One macro in terms of others.
    assert(spc.as_str().contains("pub const LIB_SUM: i32 = 12;"));
    assert(spc.as_str().contains("pub const LIB_MIX: i32 = 5;"));
    // Function-like macros have no const form.
    assert(!spc.as_str().contains("LIB_CALL"));
    // Named by its typedef, having no tag: the pin is the typedef name.
    assert(spc.as_str().contains("@import(\"lib_pt\")\n    pub struct lib_pt"));
    assert(spc.as_str().contains("@import(\"lib_val\")\n    pub union lib_val"));
    assert(spc.as_str().contains("@import(\"lib_mode\")\n    pub enum lib_mode"));
    // An enumerator written as an expression.
    assert(spc.as_str().contains("LIB_B = 8"));
    // And C's auto-increment continues from it.
    assert(spc.as_str().contains("LIB_C = 9"));
    // An exported WRITABLE global.
    assert(spc.as_str().contains("pub static mut lib_counter: i32;"));

    p.mkfile(
        "main.spc",
        "@link(\"-L. -llib\")\nextern \"C\" {}\nimport lib;\n\nfn main() i32 {\n    let pt = lib::lib_pt { x: 2, y: 3 };\n    let n = unsafe lib::lib_use(&pt, lib::lib_mode::LIB_B);\n    let c = unsafe lib::lib_counter;\n    if n == 13 && c == 41 && lib::LIB_SUM == 12 { return 0; }\n    return 1;\n}\n",
    );
    assert(p.c_lib("lib", "lib.c"), "the C library builds");
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// `super-c vendor` copies a dependency into vendor/<name>, where the loader's project-root-relative
// import resolution already finds it: no manifest entry, no search path. A git source is recognized
// by a scheme, a `git@` remote, or a `.git` suffix and is cloned; anything else must be a local
// directory and is copied. The vendored modules then import as `vendor::<name>::<module>`, which is
// checked end to end by running a program through two of them.
@test
fn vendor_copies_and_imports_resolve() {
    let p = cli::proj_new();
    p.mkfile("dep/geo.spc", "pub fn area(w: i32, h: i32) i32 { return w * h; }\n");
    p.mkfile("dep/util/more.spc", "pub fn twice(x: i32) i32 { return x * 2; }\n");
    let root = p.dir();
    let mut args = String::new();
    args.format_into("vendor \"{}/dep\" --dir=\"{}\"", root, root);
    let r = p.run_raw(args.as_str());
    assert(r.ok());
    assert(r.out_has("import vendor::dep::"), "the success line teaches the import spelling");
    let mut nested = String::new();
    nested.format_into("{}/vendor/dep/util/more.spc", root);
    assert(loader::read_file(nested.as_str()).is_some(), "nested files arrive");
    nested.free();
    // The same name again is refused, not overwritten.
    let r2 = p.run_raw(args.as_str());
    assert(r2.exit != 0);
    assert(r2.out_has("already exists"));
    args.free();
    // A missing source is an error, not an empty vendor directory.
    let mut bad = String::new();
    bad.format_into("vendor \"{}/nope\" --dir=\"{}\"", root, root);
    let rb = p.run_raw(bad.as_str());
    assert(rb.exit != 0);
    assert(rb.out_has("not a directory"));
    bad.free();
    // The vendored modules resolve through ordinary imports and run.
    p.mkfile(
        "main.spc",
        "import vendor::dep::geo;\nimport vendor::dep::util::more;\nfn main() i32 { return geo::area(6, 7) + more::twice(0) - 42; }\n",
    );
    let c = p.native_build("", "main.spc");
    assert(c.ok());
    assert_eq(p.run_bin(), 0);
}

// The clone path, against a local bare repository (offline), with the `.git` suffix as the trigger.
// What matters beyond arrival: the clone's own `.git` is gone; vendored source belongs to the
// project's history, and a nested repository would shadow it from the outer one.
@test
fn vendor_clones_git_and_strips_the_repository() {
    let p = cli::proj_new();
    p.mkfile("srcrepo/lib.spc", "pub fn seven() i32 { return 7; }\n");
    let root = p.dir();
    let mut g = String::new();
    g.format_into("git -C \"{}/srcrepo\" init -q", root);
    if cli::run_quiet(g.cstr()) != 0 {
        g.free();
        // No git on this machine: the clone path cannot be exercised.
        return;
    }
    g.free();
    let mut ga = String::new();
    ga.format_into("git -C \"{}/srcrepo\" add lib.spc", root);
    assert_eq(cli::run_quiet(ga.cstr()), 0);
    ga.free();
    let mut gc = String::new();
    gc.format_into(
        "git -C \"{}/srcrepo\" -c user.email=v@e -c user.name=v -c commit.gpgsign=false commit -q -m x",
        root,
    );
    assert_eq(cli::run_quiet(gc.cstr()), 0);
    gc.free();
    // Tag the first state, then move the tip past it: --ref must be able to reach back.
    let mut gt = String::new();
    gt.format_into("git -C \"{}/srcrepo\" tag v1", root);
    assert_eq(cli::run_quiet(gt.cstr()), 0);
    gt.free();
    p.mkfile("srcrepo/lib.spc", "pub fn seven() i32 { return 8; }\n");
    let mut g2 = String::new();
    g2.format_into(
        "git -C \"{}/srcrepo\" -c user.email=v@e -c user.name=v -c commit.gpgsign=false commit -q -am y",
        root,
    );
    assert_eq(cli::run_quiet(g2.cstr()), 0);
    g2.free();
    let mut gb = String::new();
    gb.format_into("git clone -q --bare \"{}/srcrepo\" \"{}/dep.git\"", root, root);
    assert_eq(cli::run_quiet(gb.cstr()), 0);
    gb.free();
    // Pinned to the tag: the vendored tree is the FIRST state, not the tip.
    let mut args = String::new();
    args.format_into("vendor \"{}/dep.git\" mylib --ref=v1 --dir=\"{}\"", root, root);
    let r = p.run_raw(args.as_str());
    args.free();
    assert(r.ok());
    let mut lib = String::new();
    lib.format_into("{}/vendor/mylib/lib.spc", root);
    switch loader::read_file(lib.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "return 7"), "--ref=v1 vendors the tagged state");
            t.free();
        },
        None => {
            assert(false, "the clone arrived under the given name");
        },
    };
    let mut head = String::new();
    head.format_into("{}/vendor/mylib/.git/HEAD", root);
    assert(loader::read_file(head.as_str()).is_none(), "no .git survives vendoring");
    head.free();
    // provenance: the stamp names the source and the exact commit the repository cannot answer for.
    let mut st = String::new();
    st.format_into("{}/vendor/mylib/.vendor", root);
    switch loader::read_file(st.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "source = "), "the stamp names the source");
            assert(cli::contains_str(t.cstr(), "commit = "), "and the commit");
            t.free();
        },
        None => {
            assert(false, "a git vendor writes a .vendor stamp");
        },
    };
    st.free();
    // --force re-vendors in place; without a ref that lands the tip, proving the replace really happened.
    let mut fargs = String::new();
    fargs.format_into("vendor \"{}/dep.git\" mylib --force --dir=\"{}\"", root, root);
    assert_eq(p.run_raw(fargs.as_str()).exit, 0);
    fargs.free();
    switch loader::read_file(lib.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "return 8"), "--force replaced the pinned state with the tip");
            t.free();
        },
        None => {
            assert(false, "the re-vendor arrived");
        },
    };
    lib.free();
    // A ref the repository does not have is an error, and leaves nothing behind.
    let mut bargs = String::new();
    bargs.format_into("vendor \"{}/dep.git\" other --ref=nope --dir=\"{}\"", root, root);
    assert(p.run_raw(bargs.as_str()).exit != 0);
    bargs.free();
    let mut op = String::new();
    op.format_into("{}/vendor/other/lib.spc", root);
    assert(loader::read_file(op.as_str()).is_none(), "a failed ref checkout is cleaned up");
    op.free();
    p.mkfile("main.spc", "import vendor::mylib::lib;\nfn main() i32 { return lib::seven() - 8; }\n");
    let c = p.native_build("", "main.spc");
    assert(c.ok());
    assert_eq(p.run_bin(), 0);
}

// A git dependency with a submodule, vendored at an older tag: the submodule holds the tag's commit,
// and no `.git` survives at any level (a submodule's `.git` file would point at the deleted
// `.git/modules`). Local submodule clones need `protocol.file.allow`, passed through the environment.
@test
fn vendor_strips_submodule_git_and_follows_the_ref() {
    let p = cli::proj_new();
    p.mkfile("subrepo/s.spc", "pub fn s() i32 { return 1; }\n");
    p.mkfile("srcrepo/lib.spc", "pub fn seven() i32 { return 7; }\n");
    let root = p.dir();
    let gc = "-c user.email=v@e -c user.name=v -c commit.gpgsign=false -c protocol.file.allow=always";
    if git_ok(root, "subrepo", "init -q") != 0 {
        // No git on this machine: the clone path cannot be exercised.
        return;
    }
    assert_eq(git_ok(root, "subrepo", "add s.spc"), 0);
    let mut c1 = String::new();
    c1.format_into("{} commit -q -m a", gc);
    assert_eq(git_ok(root, "subrepo", c1.as_str()), 0);
    assert_eq(git_ok(root, "srcrepo", "init -q"), 0);
    let mut sa = String::new();
    sa.format_into("{} submodule add -q \"{}/subrepo\" sub", gc, root);
    assert_eq(git_ok(root, "srcrepo", sa.as_str()), 0);
    assert_eq(git_ok(root, "srcrepo", "add lib.spc"), 0);
    assert_eq(git_ok(root, "srcrepo", c1.as_str()), 0);
    assert_eq(git_ok(root, "srcrepo", "tag v1"), 0);
    // Move the submodule past the tag and record it in the superproject.
    p.mkfile("subrepo/s.spc", "pub fn s() i32 { return 2; }\n");
    let mut c2 = String::new();
    c2.format_into("{} commit -q -am b", gc);
    assert_eq(git_ok(root, "subrepo", c2.as_str()), 0);
    assert_eq(git_ok(root, "srcrepo/sub", "pull -q"), 0);
    assert_eq(git_ok(root, "srcrepo", c2.as_str()), 0);
    let mut gb = String::new();
    gb.format_into("git clone -q --bare \"{}/srcrepo\" \"{}/dep.git\"", root, root);
    assert_eq(cli::run_quiet(gb.cstr()), 0);
    let mut args = String::new();
    args.format_into("vendor \"{}/dep.git\" mylib --ref=v1", root);
    let r = cli::superc_env_in(
        root,
        "GIT_CONFIG_COUNT",
        "1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always",
        args.as_str(),
    );
    assert(r.ok(), "the vendor succeeds");
    let mut s = String::new();
    s.format_into("{}/vendor/mylib/sub/s.spc", root);
    switch loader::read_file(s.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "return 1"), "the submodule holds the tag's commit");
            t.free();
        },
        None => {
            assert(false, "the submodule arrived");
        },
    };
    let mut sg = String::new();
    sg.format_into("{}/vendor/mylib/sub/.git", root);
    assert(du::file_mtime(sg.as_str()) == 0, "no submodule .git survives");
    let mut tg = String::new();
    tg.format_into("{}/vendor/mylib/.git", root);
    assert(du::file_mtime(tg.as_str()) == 0, "no top .git survives");
}

// `git -C <root>/<dir> <args>`, its exit status.
fn git_ok(root: str, dir: str, args: str) i32 {
    let mut g = String::new();
    g.format_into("git -C \"{}/{}\" {}", root, dir, args);
    return cli::run_quiet(g.cstr());
}

// A writable C global: `static mut` inside an extern block DECLARES what the C side defines. The
// access carries static mut's unsafe rule across the FFI, codegen emits no definition and no mangled
// name: the emitted C reads and writes the library's own symbol.
@test
fn extern_static_mut_binds_a_writable_global() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile("g.h", "extern int counter;\n");
    p.mkfile("g.c", "#include \"g.h\"\nint counter = 1;\n");
    p.mkfile(
        "main.spc",
        "@link(\"-L. -lg\")\nextern \"C\" \"g.h\" {\n    pub static mut counter: i32;\n}\nfn main() i32 {\n    unsafe {\n        counter = counter + 41;\n    }\n    return unsafe counter - 42;\n}\n",
    );
    assert(p.c_lib("g", "g.c"), "the C library builds");
    let r = p.native_build("", "main.spc");
    assert(r.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
    // The write is guarded exactly like any static mut.
    h::expect_err_msg(
        "a write without unsafe",
        "extern \"C\" \"g.h\" {\n    pub static mut counter: i32;\n}\nfn main() i32 {\n    counter = 5;\n    return 0;\n}\n",
        "requires an 'unsafe' block",
    );
    // And the C side owns the storage: an initializer here is refused.
    h::expect_err_msg(
        "an initializer",
        "extern \"C\" \"g.h\" {\n    pub static mut counter: i32 = 3;\n}\nfn main() i32 { return 0; }\n",
        "the C side defines it",
    );
}

// A `static mut` of a header-less extern block (a thread-local one too) has no header to declare it: the
// units that use it declare it, as a header-less function gets its prototype.
@test
fn headerless_extern_static_mut_is_declared() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    // def.c, linked beside the program, defines the statics; the header declares nothing.
    p.mkfile("def.h", "");
    p.mkfile("def.c", "int hl_counter = 41;\n_Thread_local int hl_tls = 1;\n");
    p.mkfile(
        "main.spc",
        "extern \"C\" \"def.h\" {}\nextern \"C\" {\n    static mut hl_counter: i32;\n    @thread_local\n    static mut hl_tls: i32;\n}\nfn main() i32 {\n    unsafe hl_counter = unsafe hl_counter + 1;\n    unsafe hl_tls = unsafe hl_tls + 2;\n    return unsafe hl_counter + unsafe hl_tls - 45;\n}\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("main.c", "extern int32_t hl_counter;"), "the unit declares the static");
    let cc = p.cc_build_with("", "def.c");
    assert(cc.ok(), "the emitted C compiles and links");
    assert_eq(p.run_bin(), 0);
}

// Bindgen binds globals by what C itself declares: writable ones as `static mut`, const-qualified
// ones as `const`, and --cflag reaches the preprocessor, so a feature-gated declaration appears
// exactly when the flag says so. The generated module is then used end to end: lib.c, linked beside the
// program, supplies the definitions, and the program mutates the bound global through it.
@test
fn bindgen_globals_and_cflag() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "extern int counter;\nextern const int limit;\n#ifdef FEATURE_ON\nint gated_fn(int x);\n#endif\nint bump(int by);\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\nint counter = 2;\nconst int limit = 40;\nint bump(int by) { counter += by; return counter; }\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);
    args.free();
    let mut gp = String::new();
    gp.format_into("{}/lib.spc", root);
    switch loader::read_file(gp.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "pub static mut counter: i32;"), "a writable global binds as static mut");
            assert(cli::contains_str(t.cstr(), "pub const limit: i32;"), "a const-qualified one stays const");
            assert(!cli::contains_str(t.cstr(), "gated_fn"), "the gated declaration is absent without the flag");
            t.free();
        },
        None => {
            assert(false, "bindgen wrote the module");
        },
    };
    // --cflag reaches the preprocessor: the gate opens.
    let mut args2 = String::new();
    args2.format_into("bindgen \"{}/lib.h\" --header=lib.h --cflag=-DFEATURE_ON -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args2.as_str()).exit, 0);
    args2.free();
    switch loader::read_file(gp.as_str()) {
        Some(mut t) => {
            assert(cli::contains_str(t.cstr(), "pub fn gated_fn(x: i32) i32;"), "--cflag turned the declaration on");
            t.free();
        },
        None => {
            assert(false, "bindgen wrote the module again");
        },
    };
    gp.free();
    // The generated module works: read the const, mutate the global directly and through the library.
    p.mkfile(
        "main.spc",
        "@link(\"-L. -llib\")\nextern \"C\" {}\nimport lib;\nfn main() i32 {\n    unsafe {\n        lib::counter = lib::counter + 1;\n    }\n    let n = unsafe lib::bump(2);\n    return n + lib::limit - 45;\n}\n",
    );
    assert(p.c_lib("lib", "lib.c"), "the C library builds");
    let c = p.native_build("", "main.spc");
    assert(c.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// A C name that is a Super-C keyword binds under its escaped spelling: a function or global keeps
// its C symbol through `@import`, and a field or constant just gains the underscore. The module
// must parse and link.
@test
fn bindgen_escapes_keyword_names() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "struct pair { int select; int n; };\nint select(int a, int b);\nint pair_n(struct pair *p);\nextern int launch;\nextern const int move;\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\nint select(int a, int b) { return a + b; }\nint pair_n(struct pair *p) { return p->n; }\nint launch = 5;\nconst int move = 6;\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("bindgen \"{}/lib.h\" --header=lib.h -o \"{}/lib.spc\"", root, root);
    assert_eq(p.run_raw(args.as_str()).exit, 0);
    let mut gp = String::new();
    gp.format_into("{}/lib.spc", root);
    let spc = loader::read_file(gp.as_str()).unwrap();
    // A record member is the C member it pins: the escaped field reads `select` through C.
    assert(spc.as_str().contains("@import(\"select\")\n        pub select_: i32,"));
    assert(spc.as_str().contains("@import(\"select\")\n    pub fn select_(a: i32, b: i32) i32;"));
    assert(spc.as_str().contains("@import(\"launch\")\n    pub static mut launch_: i32;"));
    assert(spc.as_str().contains("@import(\"move\")\n    pub const move_: i32;"));
    p.mkfile(
        "main.spc",
        "@link(\"-L. -llib\")\nextern \"C\" {}\nimport lib;\n\nfn main() i32 {\n    let mut q = lib::pair { select_: 4, n: 1 };\n    q.select_ = q.select_ + unsafe lib::pair_n(&mut q);\n    let a = unsafe lib::select_(2, 3);\n    return a + unsafe lib::launch_ + lib::move_ + q.select_ - 21;\n}\n",
    );
    assert(p.c_lib("lib", "lib.c"), "the C library builds");
    assert(p.native_build("", "main.spc").ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// `bindgen` reads headers under the C environment of `--target`, with no C compiler: the same header binds
// `long` as 8 bytes for Linux and 4 for Windows, and the built-in `<stddef.h>` serves `size_t`. A C flag
// the environment does not model fails.
@test
fn bindgen_follows_the_target() {
    let p = cli::proj_new();
    // The build's C environment gates the last two: its POSIX level and unsigned char, and on Windows its
    // API level, which no toolchain default decides.
    p.mkfile(
        "lib.h",
        "#include <stddef.h>\n#include <sysonly.h>\nlong lw(long x);\nsize_t sz(size_t n);\n#if _POSIX_C_SOURCE == 200809L && defined(__CHAR_UNSIGNED__)\nint build_env(int);\n#endif\n#if _WIN32_WINNT == 0x0A00\nint win10(int);\n#endif\n",
    );
    p.mkfile("linux/usr/include/sysonly.h", "int from_linux(int);\n");
    p.mkfile("mingw/include/_mingw.h", "");
    p.mkfile("mingw/include/sysonly.h", "int from_mingw(int);\n");
    let root = p.dir();
    let mut args = String::new();
    args.format_into(
        "bindgen \"{}/lib.h\" --header=lib.h --target=linux --arch=x86_64 --sysroot=\"{}/linux\" -o \"{}/l.spc\"",
        root,
        root,
        root,
    );
    assert(p.run_raw(args.as_str()).ok(), "bindgen for linux");
    let l = loader::read_file(format("{}/l.spc", root).as_str()).unwrap();
    assert(l.as_str().contains("pub fn lw(x: i64) i64;"), "linux long is 8 bytes");
    assert(l.as_str().contains("pub fn sz(n: usize) usize;"), "size_t from the built-in stddef.h");
    assert(l.as_str().contains("pub fn build_env(") && !l.as_str().contains("win10"), "the build's linux environment");
    args.clear();
    args.format_into(
        "bindgen \"{}/lib.h\" --header=lib.h --target=windows --arch=x86_64 --sysroot=\"{}/mingw\" -o \"{}/w.spc\"",
        root,
        root,
        root,
    );
    assert(p.run_raw(args.as_str()).ok(), "bindgen for windows");
    let w = loader::read_file(format("{}/w.spc", root).as_str()).unwrap();
    assert(w.as_str().contains("pub fn lw(x: i32) i32;"), "windows long is 4 bytes");
    assert(w.as_str().contains("pub fn sz(n: usize) usize;"), "size_t from the built-in stddef.h");
    assert(
        w.as_str().contains("pub fn build_env(") && w.as_str().contains("pub fn win10("),
        "the build's windows environment",
    );
    args.clear();
    args.format_into(
        "bindgen \"{}/lib.h\" --target=linux --arch=x86_64 --sysroot=\"{}/linux\" --cflag=-O2 -o \"{}/x.spc\"",
        root,
        root,
        root,
    );
    let r = p.run_raw(args.as_str());
    assert(r.exit != 0 && r.out_shows("the C flag '-O2' is not modelled"), "an unmodelled C flag fails");
}

// Date `path` and everything below it back to 2020 (`find` + `touch -t`, one process).
fn age_tree(path: str) {
    let mut cmd = String::from_str("find \"");
    cmd.push_str(path);
    cmd.push_str("\" -exec touch -t 202001010000 {} +");
    assert_eq(cli::run_quiet(cmd.cstr()), 0);
}

// Version `v` of a small project.
fn cache_version(p: &cli::Proj, v: i32) {
    let mut src = String::new();
    src.format_into(
        "struct Ver{} {{\n    pub n: i32,\n}}\n\nfn main() i32 {{\n    let v = Ver{} {{ n: {} }};\n    println(\"{{}}\", v.n);\n    return 0;\n}}\n",
        v,
        v,
        v,
    );
    p.mkfile("src/main.spc", src.as_str());
}

// The project sweep (every 30 minutes, after a successful build): an out-dir entry with nothing written
// for 30 days goes (a build tree, a link record), unless a build holds the lock of a tree in it; the
// build's own tree stays. A fresh stamp skips the sweep.
@test
fn project_sweep_removes_idle_outputs() {
    if cli::on_windows() || cli::on_wasm() {
        return; // `find` and `touch -t` need a POSIX host
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    cache_version(&p, 0);
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "the first build");
    p.mkfile("build/old/raw/x.o", "x");
    p.mkfile("build/old/.lock", "");
    p.mkfile("build/__link-gone.cmd", "x");
    p.mkfile("build/locked/bench/.lock", "");
    let old = format("{}/build/old", root);
    let rec = format("{}/build/__link-gone.cmd", root);
    let locked = format("{}/build/locked", root);
    age_tree(old.as_str());
    age_tree(rec.as_str());
    age_tree(locked.as_str());
    let lk = format("{}/bench/.lock", locked.as_str());
    let h = bsys::lock_file(lk.as_str(), 0);
    assert(h.held(), "the test holds the nested tree's lock");
    assert(cli::superc_in(root, "build").ok(), "a build under a fresh stamp");
    let oldf = format("{}/raw/x.o", old.as_str());
    assert(du::file_mtime(oldf.as_str()) != 0, "a fresh stamp skips the sweep");
    age_tree(format("{}/build/.sweep", root).as_str());
    assert(cli::superc_in(root, "build").ok(), "a build under an old stamp");
    drop_lock(h);
    let own = format("{}/build/debug/raw/main.o", root);
    assert(du::file_mtime(old.as_str()) == 0, "the idle tree goes");
    assert(du::file_mtime(rec.as_str()) == 0, "the idle link record goes");
    assert(du::file_mtime(locked.as_str()) != 0, "a tree whose lock a build holds stays");
    assert(du::file_mtime(own.as_str()) != 0, "the build's own tree stays");
}

// A root beside the manifest (`root = "main.spc"`) puts the default out-dir where that root's bare build
// trees would be (`build/<profile>`): the project sweep keeps the engine's own tree there, whose emitted
// files a build under a fresh emit stamp leaves as old as they are.
@test
fn project_sweep_keeps_the_tree_of_a_root_beside_the_manifest() {
    if cli::on_windows() || cli::on_wasm() {
        return; // `find` and `touch -t` need a POSIX host
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "the first build");
    age_tree(format("{}/build/debug/raw", root).as_str());
    age_tree(format("{}/build/.sweep", root).as_str());
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "-", "build");
    assert(r.ok() && r.out_has("\"skip_emit\":true"), "a build under a fresh emit stamp and an old sweep stamp");
    let rt = format("{}/build/debug/raw/super_rt.h", root);
    let obj = format("{}/build/debug/raw/main.o", root);
    assert(du::file_mtime(rt.as_str()) != 0, "the sweep keeps the engine's tree");
    assert(du::file_mtime(obj.as_str()) != 0, "and its objects");
}

// `super-c clean` runs the project sweep now, whatever its stamp: the idle out-dir entries go, the fresh
// tree stays. `--full` removes the out-dir instead; `--cache` is no longer a flag.
@test
fn clean_sweeps_and_full_removes() {
    if cli::on_windows() || cli::on_wasm() {
        return; // `find` and `touch -t` need a POSIX host
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    cache_version(&p, 0);
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "the build");
    p.mkfile("build/old/raw/x.o", "x");
    let old = format("{}/build/old", root);
    age_tree(old.as_str());
    assert(cli::superc_in(root, "clean").ok(), "clean sweeps");
    let own = format("{}/build/debug/raw/main.o", root);
    assert(du::file_mtime(old.as_str()) == 0, "clean removes the idle tree");
    assert(du::file_mtime(own.as_str()) != 0, "the fresh tree stays");
    assert(cli::superc_in(root, "clean --cache").exit != 0, "--cache is rejected");
    assert(cli::superc_in(root, "clean --full").ok(), "clean --full");
    assert(du::file_mtime(format("{}/build", root).as_str()) == 0, "--full removes the out-dir");
}

// An object an emission replays from its cache relinks the binary like a new one: its mtime need not be
// newer than the binary's (the same second, or a binary dated ahead), so the link cannot rest on mtimes.
@test
fn cache_restored_object_relinks() {
    if cli::on_windows() || cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 3;\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "the first version builds");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 5;\n}\n");
    assert(cli::superc_in(root, "build").ok(), "the second version builds");
    let mut touch = String::new();
    touch.format_into("touch -t 203001010000 \"{}/build/debug/app\"", root);
    assert_eq(cli::run_quiet(touch.cstr()), 0);
    // Back to the first version: its object comes from the cache.
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 3;\n}\n");
    assert_eq(cli::superc_in(root, "run").exit, 3);
}

// `super-c bench --filter=S` selects benchmarks by substring at build time: a miss is an error, and the
// tally counts only what ran. A benchmark the target gates out is not discovered.
@test
fn bench_filter_selects_by_substring() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "bench/micro.spc",
        M"(import std::testing::bench as bench;
@bench
pub fn add_loop(b: &mut bench::Bencher) {
    b.set_rounds(2);
    while b.running() { let mut s = 0; for i in 0..100 { s = s + i; } assert(s > 0); }
}
@bench
pub fn mul_loop(b: &mut bench::Bencher) {
    b.set_rounds(2);
    while b.running() { let mut s = 1; for i in 1..50 { s = s * i % 1000003; } assert(s > 0); }
}
@arch(wasm32)
@bench
pub fn wasm_loop(b: &mut bench::Bencher) {
    while b.running() {}
}
)",
    );
    let root = p.dir();
    let all = cli::superc_in(root, "bench --profile=debug");
    assert(all.ok());
    assert(all.out_shows("micro::add_loop"), "unfiltered run reports the first benchmark");
    assert(all.out_shows("micro::mul_loop"), "unfiltered run reports the second benchmark");
    assert(all.out_has("2 benchmark(s)"), "unfiltered tally");
    let one = cli::superc_in(root, "bench --profile=debug --filter=mul");
    assert(one.ok());
    assert(!one.out_has("micro::add_loop"), "filter excludes a non-matching benchmark");
    assert(one.out_shows("micro::mul_loop"), "filter keeps the matching benchmark");
    assert(one.out_has("1 benchmark(s)"), "tally counts only what ran");
    let none = cli::superc_in(root, "bench --profile=debug --filter=zzz");
    assert_eq(none.exit, 1);
    assert(none.out_shows("bench: no benchmark name contains 'zzz'"), "a filter that selects nothing is an error");
}

// The allocation line counts the benchmark's calls alone, as a mean over the diagnostic rounds: one
// 64-byte call in the first of three rounds is 0.33 calls and 21 B per round. The runner's own sample
// storage and the leak tracker's tables are not counted, and a fraction of a call keeps its digits.
@test
fn bench_alloc_line_counts_the_benchmark_alone() {
    if PLATFORM != Platform::MacOS && PLATFORM != Platform::Linux {
        return; // no allocation accounting elsewhere
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "bench/once.spc",
        M"(import std::testing::bench as bench;
extern "C" {
    fn malloc(n: usize) *mut void;
    fn free(p: *mut void);
}
@bench
pub fn one_call(b: &mut bench::Bencher) {
    b.set_rounds(2);
    let mut k = 0;
    while b.running() {
        k += 1;
        if k == 4 {
            let p = unsafe malloc(64);
            assert(p != null);
            unsafe free(p);
        }
    }
}
)",
    );
    // The harness's SC_LEAK_CHECK=fatal holds: the leak tracker's own tables are not malloc calls.
    let r = cli::superc_in(p.dir(), "bench --profile=debug");
    assert(r.ok(), "the benchmark runs");
    assert(r.out_shows("0.33 calls, 21 B per round"), "the mean of one call over three rounds");
}

// The generated bench runner calls each benchmark directly. The coroutine and cancellation reachability
// is package-wide: a benchmark held as a fn value, which here reaches a cancellable wait, made every
// fn-value call in task-reachable code a cancellation edge, so `apply` carried a probe after `f(x)` that
// no other program built from it has.
@test
fn bench_runner_names_no_benchmark_as_a_fn_value() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "bench/lane.spc",
        M"(import std::testing::bench as bench;
import std::parallel::sync as sync;
fn twice(x: i32) i32 {
    return x * 2;
}
fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x);
}
@bench
pub fn lane(b: &mut bench::Bencher) {
    while b.running() {
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        launch || {
            assert(apply(twice, 3) == 6);
            w.done();
        };
        wg.wait();
    }
}
)",
    );
    let root = p.dir();
    let r = cli::superc_in(root, "bench --profile=debug --no-run");
    assert(r.ok(), "the runner builds");
    // The module's object names every function it defines or calls.
    let o = loader::read_file(format("{}/build/bench/debug/raw/bench/lane.o", root).as_str()).unwrap();
    assert(o.as_str().contains("lane__apply"), "the task calls apply");
    assert(!o.as_str().contains("cancel_probe"), "no fn-value call of the benchmark carries a cancellation probe");
}

// `super-c test --filter=S` builds only the test files with a test whose name contains S: a file without
// one is not compiled, a test taking a suite fixture matches by `<module>::<Type>::<fn>`, and a miss is an
// error.
@test
fn test_filter_builds_only_matching_files() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile("tests/a.spc", "@test\nfn alpha() {}\n@test\nfn alpha_two() {}\n");
    p.mkfile(
        "tests/b.spc",
        "struct S {}\nextend S {\n    @test_init\n    fn init() S {\n        return S {};\n    }\n    @test\n    fn beta(self: &mut S) {}\n    @test\n    fn delta() {}\n}\n",
    );
    p.mkfile("tests/c.spc", "@test\nfn gamma() { let x: i32 = \"no\"; }\n");
    let root = p.dir();
    let all = cli::superc_in(root, "test --quiet");
    assert(!all.ok(), "the unfiltered suite builds the file that does not compile");
    let a = cli::superc_in(root, "test --quiet --filter=a::alpha_");
    assert(a.ok());
    assert(a.out_has("1 passed, 0 failed"), "the runner selects among the built file's tests");
    let b = cli::superc_in(root, "test --quiet --filter=b::S::be");
    assert(b.ok());
    assert(b.out_has("1 passed, 0 failed"), "a fixture test matches by its suite type's name");
    let d = cli::superc_in(root, "test --quiet --filter=b::delta");
    assert(d.ok());
    assert(d.out_has("1 passed, 0 failed"), "a method without the fixture matches without the type's name");
    let none = cli::superc_in(root, "test --quiet --filter=zzz");
    assert_eq(none.exit, 1);
    assert(none.out_shows("test: no test name contains 'zzz'"), "a filter that selects nothing is an error");
}

// `format` is rewritten at typecheck into `sugar_fmt_*` shim calls, so it folds under CTFE like
// ordinary code and its template diagnostics are compile errors of the checker, not of codegen.
@test
fn format_desugar_and_fold() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@derive(Format)
pub struct P { pub x: i32, pub y: i32, }
const fn cf() usize {
  let s = format("x = {} y = {}", 42, "hi");
  return s.len();
}
const CL: usize = cf();
fn main() i32 {
  static_assert(cf() == 13, "format folds in a const fn");
  static_assert(CL == 13, "and in a const initializer");
  let a = format("{:x}|{:>4}|{:.2}|{}", 255, 7, 1.5, P { x: 1, y: 2 });
  println("{}", a.as_str());
  let n: usize = 3;
  let b = format("{{{}}}", n);
  println("{}", b.as_str());
  a.free();
  b.free();
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(!p.gen_has("main.c", "= cf()"), "the const initializer folded to its value");
    // The empty-string shim inlines; the value shims stay calls.
    assert(p.gen_has("main.c", "sugar_fmt_hex_i"), "runtime sites thread the desugar shims");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ff|   7|1.50|P { x: 1, y: 2 }"), "hex, width, precision, and Format dispatch");
    assert(rr.out_shows("{3}"), "escaped braces around a placeholder");
    p.mkfile("main.spc", "fn main() i32 { let s = format(\"{} {}\", 1); s.free(); return 0; }\n");
    let e = p.compile("main.spc");
    assert(e.exit != 0, "placeholder/argument mismatch rejects the build");
    assert(e.out_has("more `{}` placeholders than arguments"), "and says which way");
}

// `TypeInfo.methods` enumerates the `extend` functions declared for a type: across modules, for
// builtins and generic instances too, and carries `@reflect` entries on methods. Enumeration
// only: a descriptor cannot invoke.
@test
fn method_reflection() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(pub struct Robot { pub id: i32, }
extend Robot {
  @reflect(doc = "primary accessor")
  pub fn ident(self: &Robot) i32 { return self.id; }
  fn helper(self: &Robot, _k: i32, _j: bool) {}
  pub fn make(v: i32) Robot { return Robot { id: v }; }
}
const fn nmeth() usize { return type_info::<Robot>().methods.len; }
fn main() i32 {
  static_assert(nmeth() == 3, "extend fns enumerate in CTFE");
  let ti = type_info::<Robot>();
  let m = ti.method("ident").unwrap();
  if m.arity != 0 || !m.is_pub || m.ret != TypeTag::Int { return 1; }
  if !m.has_meta("doc") || m.meta("doc").unwrap().s != "primary accessor" { return 2; }
  let h = ti.method("helper").unwrap();
  if h.arity != 2 || h.is_pub || h.ret != TypeTag::Void { return 3; }
  let mk = ti.method("make").unwrap();
  if mk.arity != 1 || mk.ret != TypeTag::Struct { return 4; }
  if type_info::<i32>().method("fmt").is_none() { return 5; }
  if type_info::<Vector<i32>>().method("push").is_none() { return 6; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "method names, arities, visibility, return tags, and metadata agree");
}

// `zeroed::<T>()` folds recursively (so a derived `Default` folds through it), and `static_assert`
// runs INSIDE fn bodies: per instantiation for a generic fn, where a violated guard is a
// compile error naming the offending type argument.
@test
fn ctfe_zeroed_and_body_asserts() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Inner { pub p: *const u8, pub n: i64, }
struct P { pub x: i32, pub f: f64, pub inner: Inner, pub ok: bool, }
const fn cz() bool {
  let z = unsafe zeroed::<P>();
  return z.x == 0 && z.f == 0.0 && z.inner.n == 0 && z.inner.p == null && !z.ok;
}
static_assert(cz(), "zeroed folds recursively");
@derive(Default)
struct Point2 { pub a: i32, pub b: i32, }
const fn cd() i32 {
  let d = Point2::default();
  return d.a + d.b;
}
static_assert(cd() == 0, "derived default folds through zeroed");
struct S { pub x: i32, }
fn only_structs<T>(v: &T) usize {
  static_assert(type_info::<T>().kind == TypeTag::Struct, "only_structs takes a struct");
  let _ = v;
  return sizeof(T);
}
const fn cguard() usize {
  let s = S { x: 1 };
  static_assert(1 + 1 == 2, "arithmetic still works");
  return only_structs(&s);
}
static_assert(cguard() == 4, "const fn body asserts evaluate");
fn main() i32 {
  let s = S { x: 1 };
  if only_structs(&s) != 4 { return 1; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.native_build("", "main.spc");
    assert(r.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "zeroed, derived default, and body asserts all fold");
    p.mkfile(
        "main.spc",
        M"(enum E { A, B, }
fn only_structs<T>(v: &T) usize {
  static_assert(type_info::<T>().kind == TypeTag::Struct, "only_structs takes a struct");
  let _ = v;
  return sizeof(T);
}
fn main() i32 {
  let e = E::A;
  let _ = only_structs(&e);
  return 0;
}
)",
    );
    let e = p.compile("main.spc");
    assert(e.exit != 0, "a violated per-instantiation guard rejects the build");
    assert(e.out_has("static assertion failed: only_structs takes a struct"), "with the guard's message");
    assert(e.out_has("in the instantiation where T = E"), "naming the type argument");
}

// Payload-less enums project through `variants` in CTFE (tags are the declared constants),
// `payloads` folds, and a binder `meta_str` comparison in a binder-const `if` elides the untaken
// copies, so a generic touched only under an untaken guard is never instantiated.
@test
fn tagless_variants_and_meta_elision() {
    let _env5 = cli::set_env("SC_INLINE", "0");
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(enum Color { Red = 3, Green = 7, }
const fn ctag() i32 {
  let c = Color::Green;
  let mut t: i32 = 0;
  inline for v in variants(&c) {
    if v.is_active { t = v.tag; }
  }
  return t;
}
static_assert(ctag() == 7, "tagless variants fold with declared constants");
const fn ceq() bool {
  let a = Color::Red;
  let b = Color::Red;
  let c = Color::Green;
  return reflect_variant_eq(&a, &b) && !reflect_variant_eq(&a, &c);
}
static_assert(ceq(), "tagless paired variants fold");
enum Sh { Dot, Pair(i32, i64), }
const fn psum() i64 {
  let s = Sh::Pair(3, 4);
  let mut acc: i64 = 0;
  inline for v in variants(&s) {
    if v.is_active {
      inline for q in payloads(v) { acc = acc + q.value as i64; }
    }
  }
  return acc;
}
static_assert(psum() == 7, "payload projection folds");
struct P {
  @reflect(group = "physics")
  pub a: i32,
  @reflect(group = "render")
  pub b: i64,
  pub c: u8,
}
fn touch<V>(x: &V) usize { let _ = x; return sizeof(V); }
fn phys<T>(v: &T) i64 {
  let mut acc: i64 = 0;
  inline for f in fields(v) {
    if f.meta_str("group") == "physics" { acc = acc + touch(&f.value) as i64; }
    if f.meta_str("group") != "render" { acc = acc + 1; }
  }
  return acc;
}
fn main() i32 {
  if ctag() != 7 || !ceq() || psum() != 7 { return 1; }
  let pv = P { a: 1, b: 2, c: 3 };
  if phys(&pv) != 6 { return 2; }
  print("ok\n");
  return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.ok());
    assert(p.gen_has("main__inst.c", "touch__i32("), "the taken guard calls its callee");
    assert(!p.gen_has("main__inst.c", "touch__i64("), "an untaken meta_str guard's call is never emitted");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok());
    let rr = p.run_bin_env("");
    assert(rr.ok());
    assert(rr.out_shows("ok"), "tagless tags, payload folds, and guard elision agree at runtime");
}

// Build-engine hardening gates: shell-free process spawning (paths pass through verbatim), no-change
// builds rewriting nothing.
fn p13_mtime(path: str) i64 {
    return bsys::file_mtime_ns(path);
}

// The link reaches the files without a shell, so a project living under a
// directory with spaces (and non-ASCII bytes off Windows, where the engine's *A APIs are
// codepage-bound) builds, links a binary whose own name carries a space, and runs.
@test
fn build_paths_with_spaces() {
    let p = cli::proj_new();
    let sub = if cli::on_windows() {
        "sp ace";
    } else {
        "sp ace-ä";
    };
    let mut toml = String::new();
    toml.format_into("{}/build.toml", sub);
    let mut mainf = String::new();
    mainf.format_into("{}/src/main.spc", sub);
    p.mkfile(toml.as_str(), "bin = \"my app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(mainf.as_str(), "fn main() i32 {\n    println(\"weird ok\");\n    return 0;\n}\n");
    let root = p.dir();
    let mut dir = String::new();
    dir.format_into("{}/{}", root, sub);
    let r = cli::superc_in(dir.as_str(), "build");
    assert(r.ok(), "a project under a directory with spaces builds without shell escaping errors");
    let mut bin = String::new();
    bin.format_into("{}/my app{}", dir.as_str(), unsafe str::from_cstr(cli::binext()));
    assert(p13_mtime(bin.as_str()) != 0, "the space-named binary linked");
    let mut run = String::new();
    run.format_into("\"{}\"", bin.as_str());
    let mut rc = String::from_str(run.as_str());
    assert(cli::run_quiet(rc.cstr()) == 0, "the space-named binary runs");
}

// Staleness gates, end to end: a no-change build rewrites no object and does not relink; a struct
// rename and a new public function in util reach no object of a module that does not use them, so
// main.o keeps its bytes and its mtime.
@test
fn build_staleness_gates() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import util;\n\nfn main(argv: Vector<str>) i32 {\n    return util::v(argv.len() as i32 - 1);\n}\n",
    );
    // `v` stays a real call (a runtime argument, not inlined), so main spells nothing of util's types.
    p.mkfile(
        "src/util.spc",
        "pub struct S {\n    pub a: i32,\n}\n\n@noinline\npub fn v(x: i32) i32 {\n    let s = S { a: x };\n    return s.a;\n}\n",
    );
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "initial build");
    let mut objo = String::new();
    objo.format_into("{}/build/debug/raw/main.o", root);
    let mut bin = String::new();
    bin.format_into("{}/app{}", root, unsafe str::from_cstr(cli::binext()));
    let o1 = p13_mtime(objo.as_str());
    let b1 = p13_mtime(bin.as_str());
    assert(o1 != 0 && b1 != 0, "the build produced an object and a binary");
    assert(cli::superc_in(root, "build").ok(), "no-change build");
    assert(p13_mtime(objo.as_str()) == o1, "a no-change build does not rewrite objects");
    assert(p13_mtime(bin.as_str()) == b1, "a no-change build does not relink");
    // Rename the struct field: main spells no util type, so main.o stays.
    p.mkfile(
        "src/util.spc",
        "pub struct S {\n    pub b: i32,\n}\n\n@noinline\npub fn v(x: i32) i32 {\n    let s = S { b: x };\n    return s.b;\n}\n",
    );
    assert(cli::superc_in(root, "build").ok(), "layout-change build");
    assert(p13_mtime(objo.as_str()) == o1, "a layout edit main never embeds rebuilds no dependent object");
    // Add a public function: main, which calls only `v`, does not change.
    p.mkfile(
        "src/util.spc",
        "pub struct S {\n    pub b: i32,\n}\n\n@noinline\npub fn v(x: i32) i32 {\n    let s = S { b: x };\n    return s.b;\n}\n\npub fn w() i32 {\n    return 1;\n}\n",
    );
    assert(cli::superc_in(root, "build").ok(), "header-change build");
    assert(p13_mtime(objo.as_str()) == o1, "a function main does not call rebuilds nothing of it");
}

// Forward declarations follow use: adding a struct, an enum or renaming a type in one module
// rewrites that module's own C files only (`--emit-c`). A unit that spells none of its types keeps its C
// text, and the shared forward header carries no type declaration.
@test
fn build_type_edit_stays_local() {
    let _unit = cli::set_env("SC_UNITY_MAX", "0"); // per-unit files
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import util;\nimport other;\n\nfn main(argv: Vector<str>) i32 {\n    let n = argv.len() as i32 - 1;\n    return util::v(n) + other::f(n);\n}\n",
    );
    let util0 = "pub struct S {\n    pub a: i32,\n}\n\n@noinline\npub fn v(x: i32) i32 {\n    let s = S { a: x };\n    return s.a;\n}\n";
    p.mkfile("src/util.spc", util0);
    p.mkfile(
        "src/other.spc",
        "pub struct T {\n    pub b: i64,\n}\n\n@noinline\npub fn f(x: i32) i32 {\n    let t = T { b: x as i64 };\n    return t.b as i32;\n}\n",
    );
    let root = p.dir();
    assert(cli::superc_in(root, "build --emit-c").ok(), "initial build");
    let mut fwd = String::new();
    fwd.format_into("{}/build/debug/raw/__sc_fwd.h", root);
    let fwd_text = loader::read_file(fwd.as_str()).unwrap();
    assert(fwd_text.as_str().find("util__S") < 0, "the forward header declares no type");
    let mut paths = Vector::<String>::new();
    for rel in "raw/__sc_fwd.h raw/other.c raw/main.c".split(" ") {
        let mut s = String::new();
        s.format_into("{}/build/debug/{}", root, rel);
        paths.push(s);
    }
    let mut t0 = Vector::<i64>::new();
    for i in 0..paths.len() {
        t0.push(p13_mtime(paths[i].as_str()));
        assert(t0[i] != 0, "the build wrote every recorded file");
    }
    let mut edits = Vector::<str>::new();
    edits.push("pub struct Added {\n    pub z: i64,\n}\n");
    edits.push("pub struct Added {\n    pub z: i64,\n}\n\npub enum Mode {\n    A,\n    B,\n}\n");
    edits.push("pub struct Renamed {\n    pub z: i64,\n}\n\npub enum Mode {\n    A,\n    B,\n}\n");
    for k in 0..edits.len() {
        let mut src = String::from_str(util0);
        src.push_str("\n");
        src.push_str(edits[k]);
        p.mkfile("src/util.spc", src.as_str());
        assert(cli::superc_in(root, "build --emit-c").ok(), "type-edit build");
        for i in 0..paths.len() {
            assert(
                p13_mtime(paths[i].as_str()) == t0[i],
                "a type edit in util leaves units without util types untouched",
            );
        }
    }
}

// One definition header per type: a new type in a module whose other type every unit spells rewrites
// no unit (`--emit-c`; the new type gets its own header, which no unit includes), and removing it again
// prunes that header and drops it from the manifest.
@test
fn build_new_type_rewrites_no_user() {
    let _unit = cli::set_env("SC_UNITY_MAX", "0"); // per-unit files
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import util;\nimport other;\n\nfn main(argv: Vector<str>) i32 {\n    let s = util::S { a: argv.len() as i32 - 1 };\n    return util::v(s) + other::f(s);\n}\n",
    );
    let util0 = "pub struct S {\n    pub a: i32,\n}\n\n@noinline\npub fn v(s: S) i32 {\n    return s.a;\n}\n";
    p.mkfile("src/util.spc", util0);
    p.mkfile("src/other.spc", "import util;\n\n@noinline\npub fn f(s: util::S) i32 {\n    return s.a * 2;\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build --emit-c").ok(), "initial build");
    let mut paths = Vector::<String>::new();
    for rel in "raw/main.c raw/other.c raw/util.c raw/util.h".split(" ") {
        let mut s = String::new();
        s.format_into("{}/build/debug/{}", root, rel);
        paths.push(s);
    }
    let mut t0 = Vector::<i64>::new();
    for i in 0..paths.len() {
        t0.push(p13_mtime(paths[i].as_str()));
        assert(t0[i] != 0, "the build wrote every recorded file");
    }
    let mut hdr = String::new();
    hdr.format_into("{}/build/debug/raw/__sc_t/util__Added.h", root);
    let mut man = String::new();
    man.format_into("{}/build/debug/raw/__sc_manifest", root);
    let mut src = String::from_str(util0);
    src.push_str("\npub struct Added {\n    pub z: i64,\n}\n");
    p.mkfile("src/util.spc", src.as_str());
    assert(cli::superc_in(root, "build --emit-c").ok(), "added-type build");
    for i in 0..paths.len() {
        assert(p13_mtime(paths[i].as_str()) == t0[i], "a new type leaves every unit untouched");
    }
    assert(p13_mtime(hdr.as_str()) != 0, "the new type has its own definition header");
    assert(
        loader::read_file(man.as_str()).unwrap().as_str().find("__sc_t/util__Added.h") >= 0,
        "the manifest lists the new definition header",
    );
    p.mkfile("src/util.spc", util0);
    assert(cli::superc_in(root, "build --emit-c").ok(), "removed-type build");
    assert(p13_mtime(hdr.as_str()) == 0, "the definition header of a removed type is pruned");
    assert(loader::read_file(man.as_str()).unwrap().as_str().find("util__Added") < 0, "the manifest no longer lists it");
}

// C needs the element of every array declarator complete, also below a pointer and in a
// function-pointer parameter: a prototype header, a definition header and a unit that spells a
// type only there include its definition header. The same modules name struct-payload variants
// of another module's enums, qualified and through a glob import.
@test
fn build_array_elements_include_definitions() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/tk.spc",
        "pub struct Tk { pub x: i32, pub y: i32 }\npub enum Sh { Pt { pub x: i32, pub y: i32 }, No }\npub enum G<T> { Pt { pub x: T, pub y: T }, No }\n",
    );
    p.mkfile(
        "src/user.spc",
        "import tk as *;\npub struct Holder<'a> { pub p: &'a [Tk; 2], pub n: i32 }\npub struct Cb { pub f: fn(&[Tk; 2]) i32, pub n: i32 }\npub fn by_val(p: [[Tk; 2]; 1]) i32 { let _ = p; return 3; }\npub fn by_ref(q: &&[Tk; 2]) i32 { let _ = q; return 1; }\n",
    );
    p.mkfile(
        "src/get.spc",
        "import user as *;\npub fn get(h: &Holder) i32 { return h.n; }\npub fn cbn(c: &Cb) i32 { return c.n; }\n",
    );
    p.mkfile(
        "src/main.spc",
        "import tk;\nimport tk as *;\nimport user;\nimport get;\nfn one(p: &[tk::Tk; 2]) i32 { return p[1].y; }\nfn main() i32 {\n    let a = [Tk { x: 1, y: 2 }, Tk { x: 3, y: 4 }];\n    let h = user::Holder { p: &a, n: 6 };\n    let c = user::Cb { f: one, n: 1 };\n    let s = Sh::Pt { x: 1, y: 2 };\n    let g = tk::G::<u8>::Pt { x: 3, y: 4 };\n    let q: G<u16> = tk::G::Pt { x: 5, y: 6 };\n    let mut t = get::get(&h) + get::cbn(&c) + user::by_val([a]) + user::by_ref(&&a);\n    t += switch s { Pt { x, y } => x + y, No => 0 };\n    t += switch g { Pt { x, y } => x + y, No => 0 };\n    t += switch q { Pt { x, y } => x + y, No => 0 };\n    return t - 32;\n}\n",
    );
    let root = p.dir();
    assert(cli::superc_in(root, "run").ok(), "every header compiles and the program runs");
}

// A type spelled only inside a symbol name (the `util__K` segment of a generic instance's symbol)
// is no C use of the type: the unit includes the instance's prototype header, not the type's
// header, so a type edit in util leaves the unit untouched (`--emit-c`).
@test
fn build_symbol_segment_includes_no_type() {
    let _unit = cli::set_env("SC_UNITY_MAX", "0"); // per-unit files
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import util;\nimport gen;\n\nfn main() i32 {\n    return gen::size::<util::K>() - 8;\n}\n",
    );
    let util0 = "pub struct K {\n    pub a: i64,\n}\n";
    p.mkfile("src/util.spc", util0);
    p.mkfile("src/gen.spc", "@noinline\npub fn size<T>() i32 {\n    return sizeof(T) as i32;\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build --emit-c").ok(), "initial build");
    let mut genc = String::new();
    genc.format_into("{}/build/debug/raw/main.c", root);
    let text = loader::read_file(genc.as_str()).unwrap();
    assert(text.as_str().find("gen__size__util__K") >= 0, "main.c spells the type in the instance symbol");
    assert(text.as_str().find("__sc_t/util__K.h") < 0, "main.c does not include the type's header");
    let g0 = p13_mtime(genc.as_str());
    assert(g0 != 0, "the build wrote main.c");
    let mut src = String::from_str(util0);
    src.push_str("\npub struct Added {}\n");
    p.mkfile("src/util.spc", src.as_str());
    assert(cli::superc_in(root, "build --emit-c").ok(), "type-edit build");
    assert(p13_mtime(genc.as_str()) == g0, "main.c is byte-identical");
}

// The build record carries the instance re-lowering counts by reason: a zero-size element type re-lowers
// the templates it instantiates, and nothing here re-lowers for reflection.
@test
fn build_stats_report_relowering_census() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "struct Z {}\n\nfn main() i32 {\n    let mut a = Vector::<u8>::new();\n    a.push(1u8);\n    let mut b = Vector::<Z>::new();\n    b.push(Z {});\n    return a.len() as i32 + b.len() as i32 - 2;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "-", "build");
    assert(r.ok(), "the build succeeds");
    let out = unsafe str::from_cstr(r.out);
    let head = "\"relower\":{\"reflect\":0,\"zst\":";
    let k = out.find(head);
    assert(k >= 0, "the record carries the counts and no reflection re-lowering");
    let zst = out.slice(k as usize + head.len(), out.len());
    assert(zst.byte_at(0) >= b'1' && zst.byte_at(0) <= b'9', "the zero-size element type re-lowers its templates");
}

// A failed link publishes nothing: the previous binary and its link record stay, and the next
// successful build relinks.
@test
fn build_link_failure_keeps_artifact() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    let r0 = cli::superc_in(root, "build");
    assert(r0.ok(), "initial build");
    let mut bin = String::new();
    bin.format_into("{}/build/debug/app{}", root, unsafe str::from_cstr(cli::binext()));
    let mut cmdp = bsys::link_record(
        format("{}/build", root).as_str(),
        format("build/debug/app{}", unsafe str::from_cstr(cli::binext())).as_str(),
    );
    cmdp.push_str(".cmd");
    let b1 = p13_mtime(bin.as_str());
    let l1 = switch loader::read_file(cmdp.as_str()) {
        Some(v) => v,
        None => {
            r0.show();
            panic("the initial build left no link record");
        },
    };
    // A source edit recompiles its object, then the link fails: nothing is published.
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\nldflags = [\"-lsc_no_such_library_p15\"]\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    let x = 1;\n    return x - 1;\n}\n");
    let r = cli::superc_in(root, "build");
    assert(!r.ok() && r.out_has("link failed"), "the link fails");
    assert(p13_mtime(bin.as_str()) == b1, "the previous binary stays in place");
    let l2 = switch loader::read_file(cmdp.as_str()) {
        Some(v) => v,
        None => {
            r.show();
            panic("the failed link removed the link record");
        },
    };
    assert(l2.as_str() == l1.as_str(), "the previous link record stays");
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    assert(cli::superc_in(root, "build").ok(), "the next build succeeds");
    assert(p13_mtime(bin.as_str()) > b1, "and links the newer object over the stale binary");
}

// A failed link is redone by the next build even when the binary, the objects and the generated tree
// all carry one mtime second: the pending link record, not the mtime order, forces the link.
@test
fn build_relinks_after_failed_link_in_same_second() {
    if cli::on_windows() {
        return; // find, touch
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    assert(cli::superc_in(root, "build").ok(), "initial build");
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\nldflags = [\"-lsc_no_such_library_p15\"]\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    let x = 1;\n    return x - 1;\n}\n");
    let r = cli::superc_in(root, "build");
    assert(!r.ok() && r.out_has("link failed"), "the link fails");
    let mut same = String::new();
    same.format_into("find {}/build -type f -exec touch -t 209901010000 {{}} +", root);
    assert_eq(cli::run_quiet(same.cstr()), 0);
    let mut bin = String::new();
    bin.format_into("{}/build/debug/app", root);
    let b1 = p13_mtime(bin.as_str());
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    assert(cli::superc_in(root, "build").ok(), "the next build succeeds");
    assert(p13_mtime(bin.as_str()) != b1, "and relinks over the binary the failed link left");
}

// A generated file that cannot be published fails the build at the publication boundary: the previous
// binary stays, no emit stamp records the failed emission, and the next build over the same edit
// publishes and links it once the file is writable again.
@test
fn build_publication_failure_keeps_artifact() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 3;\n}\n");
    let root = p.dir();
    assert_eq(cli::superc_in(root, "run").exit, 3);
    let mut bin = String::new();
    bin.format_into("{}/build/debug/app{}", root, unsafe str::from_cstr(cli::binext()));
    let b1 = p13_mtime(bin.as_str());
    // A directory where the generated file goes refuses the write for every user (root ignores a
    // read-only mode).
    let mut gen = String::new();
    gen.format_into("{}/build/debug/raw/main.o", root);
    assert(fs::remove_all(gen.as_str()).is_ok() && fs::mkdir_all(gen.as_str()).is_ok(), "the lock is in place");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 4;\n}\n");
    let r = cli::superc_in(root, "build");
    assert(!r.ok() && r.out_has("raw/main.o: "), "the publication failure fails the build and names the file");
    assert(p13_mtime(bin.as_str()) == b1, "the previous binary stays in place");
    assert(fs::remove_all(gen.as_str()).is_ok(), "the lock is gone");
    assert_eq(cli::superc_in(root, "run").exit, 4);
}

// A public function whose body never returns (it exits or panics), called only from another module,
// keeps its declared result type in C: the checker records every function's declared results.
@test
fn diverging_function_called_from_another_module() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/c1.spc",
        "extern \"C\" {\n    @noreturn\n    fn exit(code: i32) void;\n}\n\npub fn f() i32 {\n    unsafe exit(5);\n}\n",
    );
    p.mkfile("src/main.spc", "import c1;\n\nfn main() i32 {\n    let v = c1::f();\n    return v;\n}\n");
    assert_eq(cli::superc_in(p.dir(), "run").exit, 5);
}

const TT_SHAPES: str = M"(pub struct Pair<T> {
    pub a: T,
    pub b: T,
}
pub enum Shape {
    Dot,
    Line(i32, i32),
}
pub interface Area {
    fn area(self: &Self) i64;
}
pub struct Sq {
    pub s: i64,
}
extend Sq as Area {
    pub fn area(self: &Self) i64 {
        return self.s * self.s;
    }
}
pub fn swap(p: &mut Pair<i32>) {
    let t = p.a;
    p.a = p.b;
    p.b = t;
}
pub fn total(v: &Vector<Sq>, d: &dyn Area) i64 {
    let mut n: i64 = d.area();
    for i in 0..v.len() {
        n = n + v[i].area();
    }
    return n;
}
pub fn last(xs: [u16; 4]) u16 {
    return xs[3];
}
)";

const TT_MAIN: str = M"(import shapes;
extern "C" { fn exit(code: i32) void; }
fn count(s: shapes::Shape) i32 {
    return switch s {
        Dot => 1,
        Line(a, b) => a + b,
    };
}
fn main() i32 {
    let mut p = shapes::Pair::<i32> { a: 1, b: 2 };
    shapes::swap(&mut p);
    let mut v = Vector::<shapes::Sq>::new();
    v.push(shapes::Sq { s: 2 });
    let q = shapes::Sq { s: 3 };
    let w: [u16; 4] = [1, 2, 3, 4];
    let f = fn(x: i32) i32 { return x + p.a; };
    unsafe exit(count(shapes::Shape::Line(p.a, p.b)) + shapes::total(&v, &q) as i32 + shapes::last(w) as i32 + f(0));
    return 0;
}
)";

// One `super-c build` with the type table written to `<root>/tt<tag>.txt`; the table text.
fn tt_build(root: str, tag: str, env: str, flags: str) String {
    let mut path = String::new();
    path.format_into("{}/tt{}.txt", root, tag);
    let mut val = String::new();
    val.format_into("{} SC_NO_EMIT_CACHE=1 {}", path.as_str(), env);
    let mut args = String::new();
    args.format_into("build {} --out-dir={}/o{} -o {}/o{}/app", flags, root, tag, root, tag);
    let r = cli::superc_env_in(root, "SC_TYPE_TABLE", val.as_str(), args.as_str());
    assert(r.ok(), "the build succeeds");
    let t = cli::read_text(path.as_str());
    assert(t.len() > 0, "the type table was written");
    return t;
}

// The lines of `t` whose class column reads `cls` (`id class kind ...`).
fn tt_class(t: &String, cls: str) String {
    let mut out = String::new();
    for line in t.as_str().lines() {
        let sp = line.find_byte(b' ');
        assert(sp > 0, "a table line starts with the id");
        let rest = line.slice((sp + 1) as usize, line.len());
        let sp2 = rest.find_byte(b' ');
        assert(sp2 > 0, "then the class");
        if rest.slice(0, sp2 as usize) == cls {
            out.push_str(line);
            out.push_str("\n");
        }
    }
    return out;
}

// The package type table is one deterministic identity per structural type: a fully colliding hash
// publishes the same table; no two records read the same; and a body-only edit at the end of a module
// keeps every signature-class id and record (only body-class and instance-graph ids move). One worker
// against every worker under skewed schedules is the gate's worker-identity step (ci/gate.sh).
@test
fn type_table_is_deterministic() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/shapes.spc", TT_SHAPES);
    p.mkfile("src/main.spc", TT_MAIN);
    let root = p.dir();
    let t1 = tt_build(root, "1", "SC_TYPE_VALIDATE=1", "--jobs=1");
    let t3 = tt_build(root, "3", "SC_TYPE_VALIDATE=1 SC_TYPE_COLLIDE=1", "--jobs=4");
    assert(t1.equals(&t3), "a colliding hash publishes the same table");
    let mut seen = Set::<String>::new();
    let mut n: usize = 0;
    for line in t1.as_str().lines() {
        let sp = line.find_byte(b' ');
        let rec = String::from_str(line.slice((sp + 1) as usize, line.len()));
        assert(!seen.contains(&rec), "no two records read the same");
        seen.insert(rec);
        n = n + 1;
    }
    assert(n > 100, "the table holds the prelude and the program");
    let sig1 = tt_class(&t1, "0");
    assert(sig1.len() > 0, "signature-class records exist");
    assert(tt_class(&t1, "1").len() > 0, "body-class records exist");
    let mut edited = String::from_str(TT_SHAPES);
    edited.push_str(
        "pub fn tail(xs: [u16; 4]) u16 {\n    let deeper: *const *const *const *const u8 = null;\n    let _ = deeper;\n    return xs[3];\n}\n",
    );
    p.mkfile("src/shapes.spc", edited.as_str());
    let t4 = tt_build(root, "4", "SC_TYPE_VALIDATE=1", "--jobs=1");
    assert(!t1.equals(&t4), "the edit adds body records");
    let sig4 = tt_class(&t4, "0");
    assert(sig1.equals(&sig4), "every signature-class id and record survives a body edit");
}

// The item scheduler publishes diagnostics by declaration position, not by the order its jobs
// finished: one worker and four delayed workers print the same text, with a module-level
// `static_assert` reported between the items around it.
@test
fn item_jobs_publish_diagnostics_in_declaration_order() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "import lib;\n\nfn main() i32 {\n    return lib::one() + lib::two() + lib::three();\n}\n");
    p.mkfile(
        "src/lib.spc",
        "pub fn one() i32 {\n    let s: str = 1;\n    return 1;\n}\n\nstatic_assert(1 + 1 == 3, \"arithmetic\");\n\npub fn two() i32 {\n    let b: bool = \"no\";\n    return 2;\n}\n\npub fn three() i32 {\n    return \"three\";\n}\n",
    );
    let root = p.dir();
    let r1 = cli::superc_in(root, "build --jobs=1");
    assert(!r1.ok(), "the build fails");
    let t1 = String::from_str(unsafe str::from_cstr(r1.out));
    let r4 = cli::superc_env_in(root, "SC_TASK_DELAY", "1", "build --jobs=4");
    assert(!r4.ok(), "the build fails");
    let t4 = String::from_str(unsafe str::from_cstr(r4.out));
    assert(t1.equals(&t4), "one worker and four delayed workers print the same diagnostics");
    let a = t1.as_str().find("expected 'str', found 'i32'");
    let b = t1.as_str().find("static assertion failed");
    let c = t1.as_str().find("expected 'bool', found 'str'");
    let d = t1.as_str().find("expected 'i32', found 'str'");
    assert(a >= 0 && b > a && c > b && d > c, "diagnostics follow the declaration order");
}

// A constant fold reaches every item its own item depends on, in either direction of an
// import cycle: `a::N` calls `b::size` while `b` reads `a::N` back, and the array length folds.
@test
fn item_jobs_fold_across_an_import_cycle() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import a;\nimport b;\n\nfn main() i32 {\n    return a::buf_len() as i32 + b::back() as i32 - 16;\n}\n",
    );
    p.mkfile(
        "src/a.spc",
        "import b;\n\npub const N: usize = b::size();\n\npub fn buf_len() usize {\n    let x: [u8; N] = [[0] = 0u8];\n    return sizeof(x);\n}\n",
    );
    p.mkfile(
        "src/b.spc",
        "import a;\n\npub const fn size() usize {\n    return 8;\n}\n\npub fn back() usize {\n    return a::N;\n}\n",
    );
    let root = p.dir();
    let r4 = cli::superc_env_in(root, "SC_TASK_DELAY", "1", "build --jobs=4 --out-dir=o4 -o o4/app");
    assert(r4.ok(), "the fold across the cycle succeeds under four delayed workers");
    let r = cli::superc_in(root, "build --jobs=1 -o bin");
    assert(r.ok(), "and under one worker");
    assert_eq(p.run_bin(), 0);
}

// One build of the project at `root` with `jobs` workers into `<root>/o<tag>`, the emit stamp and the
// per-TU cache off.
fn jobs_build(root: str, tag: str, jobs: str) {
    let mut args = String::new();
    args.format_into("build --jobs={} --out-dir=o{} --emit-c", jobs, tag);
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1 SC_NO_TU_CACHE=1", args.as_str());
    assert(r.ok(), "the build succeeds");
}

// Emitted file `rel` of build `<root>/o<tag>`.
fn jobs_file(root: str, tag: str, rel: str) String {
    let mut path = String::new();
    path.format_into("{}/o{}/debug/raw/{}", root, tag, rel);
    return cli::read_text(path.as_str());
}

// The emitted tree does not depend on the worker count. A query that only asks whether a type has
// a `free` method (the destructor glue's destructibility test) spelled the method's C name and so
// recorded a use of the type's module: one worker answered it from a memo an earlier module filled,
// every core asked it again in the instance shard, and the shard included headers it never used.
@test
fn worker_count_keeps_instance_shard_includes() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/stats.spc",
        "pub struct Stats {\n    pub name: String,\n    pub t: Array<u64, 4>,\n}\n\npub fn make() Stats {\n    let mut s = Stats { name: String::from_str(\"s\"), t: Array::<u64, 4>::new() };\n    s.t.set(1, 2);\n    return s;\n}\n",
    );
    p.mkfile(
        "src/early.spc",
        "pub fn sum() u64 {\n    let mut a = Array::<u64, 4>::new();\n    a.set(0, 5);\n    return a[0];\n}\n",
    );
    p.mkfile(
        "src/main.spc",
        "import early;\nimport stats;\n\nfn main() i32 {\n    let s = stats::make();\n    return s.t[1] as i32 + early::sum() as i32 - 7;\n}\n",
    );
    let root = p.dir();
    jobs_build(root, "1", "1");
    jobs_build(root, "4", "4");
    let files = ["stats__inst.c", "stats.c", "early.c", "main.c", "__sc_manifest"];
    for f in files {
        let a = jobs_file(root, "1", f);
        assert(a.len() > 0, "the build emits the file");
        let b = jobs_file(root, "4", f);
        assert(a.equals(&b), "one worker and four workers emit the same file");
    }
    let inst = jobs_file(root, "1", "stats__inst.c");
    assert(inst.as_str().find("String__free") >= 0, "the shard holds the destructor glue");
    assert(inst.as_str().find("array") < 0, "the glue spells nothing of Array, so the shard includes none of it");
}

// SC_NO_TU_CACHE=1 leaves no per-TU cache image in the tree, also after a cached build wrote one.
@test
fn no_tu_cache_removes_the_image() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    assert(p.compile("main.spc").ok());
    assert(p.gen_exists(".tu_cache"), "a cached build writes the image");
    assert(p.compile_flags_env("", "main.spc", "SC_NO_TU_CACHE=1 SC_NO_EMIT_CACHE=1").ok());
    assert(!p.gen_exists(".tu_cache"), "a build without the cache removes it");
}

@platform(!windows)
extern "C" "unistd.h" {
    fn symlink(target: *const char, link: *const char) i32;
}

// `sc_rm_rf` removes a link to a directory and leaves the linked directory's contents in place.
@platform(!windows)
@test
fn rm_rf_does_not_follow_a_directory_link() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("target/keep.txt", "kept\n");
    p.mkfile("tree/other.txt", "gone\n");
    let root = p.dir();
    let mut target = root.to_string();
    target.push_str("/target");
    let mut link = root.to_string();
    link.push_str("/tree/link");
    let mut tree = root.to_string();
    tree.push_str("/tree");
    let mut keep = root.to_string();
    keep.push_str("/target/keep.txt");
    assert_eq(unsafe symlink(target.cstr(), link.cstr()), 0);
    assert(fs::remove_all(tree.as_str()).is_ok());
    assert(fs::lstat(tree.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::lstat(keep.as_str()).unwrap().kind == fs::FileKind::File);
}

// A left-associative chain at the parser's limit (4096 operands) nests as deep on its left operand.
// The resolver, the checker, the lowering and the formatter walk the chain without a stack frame per
// operator.
@test
fn operator_chain_at_the_parser_limit_compiles() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    let mut src = String::from_str("fn f(x: i32, b: bool) i32 {\n    let s = x");
    for _ in 1..4096 {
        src.push_str(" + x");
    }
    src.push_str(";\n    let c = b");
    for _ in 1..4096 {
        src.push_str(" && b");
    }
    src.push_str(
        ";\n    if c {\n        return s - 4090;\n    }\n    return 0;\n}\n\nfn main() i32 {\n    return f(1, true);\n}\n",
    );
    p.mkfile("main.spc", src.as_str());
    let r = p.compile("main.spc");
    assert(r.ok());
    let cc = p.cc_build("");
    assert(cc.ok());
    assert_eq(p.run_bin(), 6);
    let mut args = String::from_str("fmt --check \"");
    args.push_str(p.dir());
    args.push_str("/main.spc\"");
    let fr = p.run_raw(args.as_str());
    assert(fr.ok());
}

const BC_PRUNE: str = M"(@platform(windows)
fn win_only() i32 {
    return 10;
}

@platform(linux)
fn lin_only() i32 {
    return 20;
}

@platform(macos)
fn mac_only() i32 {
    return 30;
}

fn pick() i32 {
    if PLATFORM == Platform::Windows {
        return win_only();
    } else if PLATFORM == Platform::Linux {
        return lin_only();
    } else if (PLATFORM == Platform::MacOS) && !TEST {
        return mac_only();
    }
    return 40;
}

fn arch() i32 {
    return switch ARCH {
        X86_64 => 1,
        AArch64 | Wasm32 => 2,
    };
}

fn main() i32 {
    let base = switch PLATFORM {
        Windows | Linux | MacOS => 0,
        _ => 100,
    };
    return base + pick() + arch();
}
)";

// The platform filter decides an `if` chain or a `switch` over the build constants before name
// resolution: the removed branches call `@platform` items of other targets, which do not exist there.
@test
fn build_constants_prune_other_platforms() {
    let p = cli::proj_new();
    p.mkfile("main.spc", BC_PRUNE);
    assert(p.compile_flags("--target=windows", "main.spc").ok(), "windows transpiles");
    assert(!p.gen_has("main.c", "lin_only") && !p.gen_has("main.c", "mac_only"));
    assert(p.compile_flags("--target=linux", "main.spc").ok(), "linux transpiles");
    assert(!p.gen_has("main.c", "win_only") && !p.gen_has("main.c", "mac_only"));
    if cli::on_wasm() {
        return;
    }
    assert(p.compile("main.spc").ok());
    assert(p.native_build("", "main.spc").ok());
    let hp = unsafe shim::sc_host_platform();
    let want = if hp == 0 {
        10;
    } else if hp == 2 {
        20;
    } else {
        30;
    };
    let wa = if unsafe shim::sc_host_arch() == 0 {
        1;
    } else {
        2;
    };
    assert_eq(p.run_bin(), want + wa);
}

// TEST is true only in a `--test` build.
@test
fn build_constant_test_follows_the_test_flag() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn main() i32 {
    if TEST {
        return 1;
    }
    return 0;
}

@test
fn sees_test() {
    assert(TEST);
}
)",
    );
    let t = p.compile_flags("--test --quiet", "main.spc");
    assert(t.ok(), "the test sees TEST");
    assert(t.out_has("1 passed"));
    if cli::on_wasm() {
        return;
    }
    assert(p.native_build("", "main.spc").ok());
    assert_eq(p.run_bin(), 0);
}

// POINTER_WIDTH and ENDIAN follow the target: the untaken branch is not emitted.
@test
fn build_constants_follow_the_target() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn width() i32 {
    if POINTER_WIDTH == 32 {
        return 3232;
    }
    return 6464;
}

fn order() i32 {
    return if ENDIAN == Endian::Little {
        1111;
    } else {
        2222;
    };
}

fn main() i32 {
    return width() + order();
}
)",
    );
    assert(p.compile_flags("--target=wasm", "main.spc").ok(), "wasm transpiles");
    assert(p.gen_has("main.c", "3232") && !p.gen_has("main.c", "6464"));
    assert(p.gen_has("main.c", "1111") && !p.gen_has("main.c", "2222"));
    if cli::on_wasm() {
        return;
    }
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "6464") && !p.gen_has("main.c", "3232"));
}

const BC_PROFILE: str = M"(fn level() i32 {
    if PROFILE == "release" {
        return 7003;
    }
    return 7001;
}

fn tag() i32 {
    return switch PROFILE {
        "debug" => 7110,
        "release" => 7130,
        _ => 7150,
    };
}

fn main() i32 {
    return level() - 7000 + tag() - 7100;
}
)";

// PROFILE folds after type checking: each profile emits only its branch, into its own tree.
@test
fn build_constant_profile_selects_the_branch() {
    let p = cli::proj_new();
    p.mkfile("main.spc", BC_PROFILE);
    let root = p.dir();
    if !cli::on_wasm() {
        for (prof, code) in [("debug", 11), ("release", 33)] {
            let args = format("build --profile={} \"{}/main.spc\" -o \"{}/bin\"", prof, root, root);
            assert(p.run_raw(args.as_str()).ok());
            assert_eq(p.run_bin(), code);
        }
    }
    assert(p.compile("main.spc").ok());
    assert(p.gen_has("main.c", "7001") && p.gen_has("main.c", "7110"));
    assert(!p.gen_has("main.c", "7003") && !p.gen_has("main.c", "7130") && !p.gen_has("main.c", "7150"));
    assert(p.run_raw(format("build --profile=release \"{}/main.spc\" --emit-c", root).as_str()).ok());
    let mut rel = String::from_str(root);
    rel.push_str("/build/release/raw/main.c");
    let rc = cli::read_text(rel.as_str());
    assert(rc.as_str().contains("7003") && rc.as_str().contains("7130"));
    assert(!rc.as_str().contains("7001") && !rc.as_str().contains("7110") && !rc.as_str().contains("7150"));
    // The debug tree is untouched by the release build.
    assert(p.gen_has("main.c", "7001"));
}

const BC_CONFIG: str = M"(fn main() i32 {
    let mut n = 0;
    if LOCKDEP {
        n += 8303;
    }
    if !OVERFLOW_CHECKS {
        n += 8404;
    }
    return n % 7;
}
)";

// LOCKDEP and OVERFLOW_CHECKS follow the profile (`lockdep`, and the wrapping `release`). Each build emits
// only its branches (`--emit-c`).
@test
fn build_constants_follow_the_profile() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n\n[profile.ld]\nlockdep = true\n");
    p.mkfile("main.spc", BC_CONFIG);
    let root = p.dir();
    let cases: [](str, str) = [("debug", ""), ("ld", "8303"), ("release", "8404")];
    let all: []str = ["8303", "8404"];
    for i in 0..cases.len() {
        let (prof, want) = cases[i];
        let label = format("the build of profile '{}'", prof);
        assert(
            cli::superc_in(root, format("build --no-lint --profile={} --emit-c", prof).as_str()).ok(),
            label.as_str(),
        );
        let c = cli::read_text(format("{}/build/{}/raw/main.c", root, prof).as_str());
        for k in 0..all.len() {
            let branch = format("profile '{}' emits the branch {} exactly when it sets its constant", prof, all[k]);
            assert(c.as_str().contains(all[k]) == want.contains(all[k]), branch.as_str());
        }
    }
}

// The run-time arithmetic rules (types.md "Arithmetic Semantics"), with the constant evaluator's answers
// asserted in the same program: the narrow wrapping methods and `<<` `~` truncate at the width, a widened
// operand computes at the result's width, a float `%` keeps the dividend's sign, a float-to-integer cast
// saturates, `char` is unsigned. Signed overflow (cases 1
// to 8, the last a `+=` loop step) and unsigned overflow (cases 16 to 22: each width, `-=` and a `+=` loop
// step) trap with overflow checks (a build without a profile) and wrap under `release`; division by zero,
// MIN / -1 and out-of-range shifts (cases 9 to 15) trap under both.
const ARITH_RULES: str = M"(import stdlib;
static mut I32: i32 = i32::MAX;
static mut I32MIN: i32 = i32::MIN;
static mut I64MIN: i64 = i64::MIN;
static mut I8V: i8 = i8::MAX;
static mut I16V: i16 = i16::MIN;
static mut ZERO: i32 = 0;
static mut NEG1: i32 = -1;
static mut U32V: u32 = 1;
static mut C40: u32 = 40;
static mut B0: u8 = 0;
static mut B1: u8 = 1;
static mut B2: u8 = 2;
static mut B3: u8 = 3;
static mut H0: u16 = 0;
static mut H2: u16 = 2;
static mut BIG: f64 = 1e20;
static mut F: f64 = -7.5;
static mut C200: i32 = 200;
static mut P399: f64 = 3.99;
static mut B255: u8 = 255;
static mut H1: u16 = 1;
static mut U32M: u32 = 4294967295;
static mut U64M: u64 = 18446744073709551615;
static mut UZ: usize = 0;

// The narrow wrapping methods, `<<` and `~` truncate at the width, at compile time and at run time.
fn nsub(b: u16) u16 { return b.wrapping_sub(1) / 2; }
fn nadd(b: u8) u8 { return b.wrapping_add(255) / 2; }
fn nmul(b: u16) u16 { return b.wrapping_mul(65535) >> 1; }
fn nshl(b: u8) u8 { return (b << 7) >> 1; }
fn nneg(b: u8) u8 { return b.wrapping_neg() / 2; }
fn nnot(b: u8) u8 { return ~b / 2; }
static_assert(nsub(0) == 32767 && nadd(1) == 0 && nmul(2) == 32767, "narrow wrapping + - * truncate at the width");
static_assert(nshl(3) == 64 && nneg(2) == 127 && nnot(0) == 127, "narrow << wrapping_neg ~ truncate at the width");
// A narrower operand widens to the result's type: `u8 + u64` and `u8 | u64` compute at u64.
fn wadd(b: u8) u64 { return b + 1000u64; }
fn wor(b: u8) u64 { return b | 1u64 << 8; }
static_assert(wadd(255) == 1255 && wor(0) == 256, "a widened operand computes at the result's width");
static_assert(-7.5 % 2.0 == -1.5 && 7.5 % -2.0 == 1.5, "a float remainder has the dividend's sign");
static_assert(1e20 as i32 == i32::MAX && (0.0 - 1e20) as i64 == i64::MIN, "casts saturate");
static_assert((0.0 - 1e20) as u32 == 0 && 1e20 as u8 == 255 && (0.0 / 0.0) as i32 == 0, "casts saturate");
static_assert((1.0 / 0.0) as i16 == 32767 && 3.99 as u8 == 3 && (0.0 - 3.99) as i8 == -3, "casts truncate");
static_assert(200 as char as i32 == 200 && type_info::<char>().kind == TypeTag::Uint, "char is unsigned");

fn main() i32 {
    let c = unsafe stdlib::atoi(stdlib::getenv("CASE"));
    if c == 0 {
        print("{} {} {} ", nsub(unsafe H0), nadd(unsafe B1), nmul(unsafe H2));
        print("{} {} {}\n", nshl(unsafe B3), nneg(unsafe B2), nnot(unsafe B0));
        print("{} {}\n", unsafe F % 2.0, (0.0 - unsafe F) % -2.0);
        let big = unsafe BIG;
        print("{} {} {} {}\n", big as i32, (0.0 - big) as i64, (0.0 - big) as u32, big as u8);
        let p = unsafe P399;
        print("{} {} {} {}\n", ((big - big) / (big - big)) as i32, (big / 0.0) as i16, p as u8, (0.0 - p) as i8);
        print("{}\n", unsafe C200 as u8 as char as i32);
        print("{} {}\n", wadd(unsafe B255), wor(unsafe B0));
    } else if c == 1 {
        print("{}\n", unsafe I32 + 1);
    } else if c == 2 {
        print("{}\n", unsafe I32MIN - 1);
    } else if c == 3 {
        print("{}\n", unsafe I32 * 2);
    } else if c == 4 {
        print("{}\n", -unsafe I64MIN);
    } else if c == 5 {
        print("{}\n", unsafe I8V + 1);
    } else if c == 6 {
        let mut x = unsafe I16V;
        x -= 1;
        print("{}\n", x);
    } else if c == 7 {
        print("{}\n", (unsafe I32MIN).abs());
    } else if c == 8 {
        let mut i = unsafe I32 - 1;
        while i > 0 {
            i += 1;
        }
        print("{}\n", i);
    } else if c == 9 {
        print("{}\n", 7 / unsafe ZERO);
    } else if c == 10 {
        print("{}\n", 7 % unsafe ZERO);
    } else if c == 11 {
        print("{}\n", unsafe I32MIN / unsafe NEG1);
    } else if c == 12 {
        print("{}\n", unsafe I32MIN % unsafe NEG1);
    } else if c == 13 {
        print("{}\n", unsafe U32V << unsafe C40);
    } else if c == 14 {
        print("{}\n", unsafe U32V >> unsafe C40);
    } else if c == 15 {
        print("{}\n", unsafe NEG1 << unsafe NEG1);
    } else if c == 16 {
        print("{}\n", unsafe B255 + 1);
    } else if c == 17 {
        print("{}\n", unsafe H0 - unsafe H1);
    } else if c == 18 {
        print("{}\n", unsafe U32M * 2);
    } else if c == 19 {
        print("{}\n", unsafe U64M + 1);
    } else if c == 20 {
        let mut z = unsafe UZ;
        z -= 1;
        print("{}\n", z);
    } else if c == 21 {
        let mut i: u8 = unsafe B255 - 5;
        while i > 0 {
            i += 1;
        }
        print("{}\n", i);
    } else if c == 22 {
        print("{}\n", unsafe B3 * 100);
    }
    return 0;
}
)";

@test
fn runtime_arithmetic_follows_the_profile() {
    let p = cli::proj_new();
    p.mkfile("main.spc", ARITH_RULES);
    // Off the wasm lane the two builds below compile the program.
    if cli::on_wasm() {
        assert(p.compile("main.spc").ok(), "the program compiles");
    }
    // Negating MIN overflows at compile time too.
    h::expect_err_msg(
        "negating MIN in a constant",
        "const M: i8 = -128;\nconst N: i8 = -M;\nfn main() i32 {\n    return N as i32;\n}\n",
        "error: constant 'N' cannot be evaluated at compile time: arithmetic overflow",
    );
    // Unsigned overflow in a constant expression is an error too, at every width.
    h::expect_err_msg(
        "a u8 constant past its range",
        "const C: u8 = 255 + 1;\nfn main() i32 {\n    return C as i32;\n}\n",
        "error: constant 'C' cannot be evaluated at compile time: arithmetic overflow",
    );
    h::expect_err_msg(
        "an unsigned subtraction below zero",
        "fn main() i32 {\n    let x: u32 = 0 - 231;\n    return x as i32;\n}\n",
        "error: this operation is undefined behavior when executed: arithmetic overflow",
    );
    h::expect_err_msg(
        "a u64 constant product past its range",
        "const fn twice(x: u64) u64 {\n    return x * 2;\n}\nconst C: u64 = twice(u64::MAX);\nfn main() i32 {\n    return C as i32;\n}\n",
        "error: constant 'C' cannot be evaluated at compile time: arithmetic overflow",
    );
    h::expect_err_msg(
        "a u32 addition past its range",
        "fn main() i32 {\n    let x: u32 = u32::MAX + 1;\n    let z: usize = 0;\n    return (x + (z - 1) as u32) as i32;\n}\n",
        "error: this operation is undefined behavior when executed: arithmetic overflow",
    );
    if cli::on_wasm() {
        return;
    }
    let root = p.dir();
    let checked: []str = [
        "",
        "add",
        "subtract",
        "multiply",
        "negate",
        "add",
        "subtract",
        "negate",
        "add",
        "add",
        "subtract",
        "multiply",
        "add",
        "subtract",
        "add",
        "multiply",
    ];
    let wrapped: []str = [
        "",
        "-2147483648",
        "2147483647",
        "-2",
        "-9223372036854775808",
        "-128",
        "32767",
        "-2147483648",
        "-2147483648",
        "0",
        "65535",
        "4294967294",
        "0",
        "18446744073709551615",
        "0",
        "44",
    ];
    let always: []str = [
        "divide by zero",
        "calculate the remainder with a divisor of zero",
        "divide with overflow",
        "calculate the remainder with overflow",
        "shift left with overflow",
        "shift right with overflow",
        "shift left with overflow",
    ];
    for release in [false, true] {
        let mut args = String::new();
        args.format_into(
            "build {}\"{}/main.spc\" -o \"{}/bin\"",
            if release {
                "--profile=release ";
            } else {
                "";
            },
            root,
            root,
        );
        assert(p.run_raw(args.as_str()).ok(), args.as_str());
        let r0 = p.run_bin_env("CASE=0 ");
        assert(r0.ok(), "case 0 runs");
        assert(r0.out_shows("32767 0 32767 64 127 127"), "case 0's output");
        assert(r0.out_shows("-1.5 1.5"), "case 0's output");
        assert(r0.out_shows("2147483647 -9223372036854775808 0 255"), "case 0's output");
        assert(r0.out_shows("0 32767 3 -3"), "case 0's output");
        assert(r0.out_shows("200"), "case 0's output");
        assert(r0.out_shows("1255 256"), "case 0's output");
        for c in 1usize..23 {
            let mut env = String::new();
            env.format_into("CASE={} ", c);
            let r = p.run_bin_env(env.as_str());
            let mut want = String::new();
            // Cases 16 to 22 follow 1 to 8 in the tables.
            let k = if c >= 16 {
                c - 7;
            } else {
                c;
            };
            if (c < 9 || c >= 16) && release {
                want.push_str(wrapped[k]);
                assert(r.ok(), env.as_str());
            } else if c < 9 || c >= 16 {
                want.format_into("attempt to {} with overflow", checked[k]);
                assert(r.exit != 0, env.as_str());
            } else {
                want.format_into("attempt to {}", always[c - 9]);
                assert(r.exit != 0, env.as_str());
            }
            assert(r.out_shows(want.as_str()), env.as_str());
        }
    }
}

// The C compiler never fuses a float multiply and subtract, also under `release`: a fused `a * a - c` keeps
// the 2^-60 that the rounded product drops. The operands come from argv, so the C compiler cannot fold them.
@test
fn release_float_has_no_contraction() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn main(argv: Vector<str>) i32 {\n    let one = argv.len() as f64;\n    let a = 1.0 + one / 1073741824.0;\n    let c = 1.0 + one / 536870912.0;\n    if a * a - c == 0.0 {\n        return 0;\n    }\n    return 1;\n}\n",
    );
    let root = p.dir();
    let mut args = String::new();
    args.format_into("build --profile=release \"{}/main.spc\" -o \"{}/bin\"", root, root);
    assert(p.run_raw(args.as_str()).ok());
    assert_eq(p.run_bin(), 0);
}

// std's library integers follow the profile as the built-in ones do: `Int<N>` and `UInt<N>` overflow in
// `+ - *` and `pow` (cases 1 to 6 and 11 to 16, the last a `+=` at a width that is not a multiple of 64),
// and `Int<N>`'s `abs`, traps with overflow checks and wraps under `release`; MIN / -1 and a zero divisor
// trap under both; the `wrapping_*`, `overflowing_*` and `saturating_*` methods (case 0) never trap; and at
// compile time the overflow is the built-in operators' "arithmetic overflow" error.
const INT_RULES: str = M"(import stdlib;
const PROD: i128 = i128::from_i64(-5) * i128::from_i64(3);
static_assert(PROD.to_i64() == -15, "i128 arithmetic evaluates at compile time");
const UDIFF: u128 = u128::max() - u128::one();
static_assert(UDIFF.limb(0) == 18446744073709551614 && UDIFF.limb(1) == 18446744073709551615, "u128 at compile time");

fn methods() String {
    let mx = u128::max();
    let one = u128::one();
    let two = u128::from_u64(2);
    let (s, so) = mx.overflowing_add(&two);
    return format(
        "{} {} {} {} {} {}",
        mx.wrapping_add(&one),
        u128::zero().wrapping_sub(&one),
        mx.saturating_mul(&two) == mx,
        two.wrapping_pow(129),
        s,
        so,
    );
}
fn methods_hold() bool {
    let mx = u128::max();
    let one = u128::one();
    let two = u128::from_u64(2);
    let (s, so) = mx.overflowing_add(&two);
    let (d, dO) = u128::zero().overflowing_sub(&one);
    return mx.wrapping_add(&one).is_zero() && mx.saturating_mul(&two).eq(&mx) && two.wrapping_pow(129).is_zero() && s.eq(&one) && so && d.eq(&mx) && dO;
}
static_assert(methods_hold(), "the methods never trap");

fn main() i32 {
    let c = unsafe stdlib::atoi(stdlib::getenv("CASE"));
    let one = i128::one();
    let uone = u128::one();
    if c == 0 {
        print("{} {}\n", methods(), methods_hold());
    } else if c == 1 {
        print("{}\n", i128::max() + one);
    } else if c == 2 {
        print("{}\n", i128::min() - one);
    } else if c == 3 {
        print("{}\n", i128::max() * i128::from_i64(2));
    } else if c == 4 {
        print("{}\n", i128::min().abs());
    } else if c == 5 {
        print("{}\n", i128::max().pow(2));
    } else if c == 6 {
        print("{}\n", i256::max() + i256::one());
    } else if c == 7 {
        print("{}\n", i128::min() / i128::from_i64(-1));
    } else if c == 8 {
        print("{}\n", i128::min() % i128::from_i64(-1));
    } else if c == 9 {
        print("{}\n", i128::one() / i128::zero());
    } else if c == 10 {
        print("{}\n", u128::one() % u128::zero());
    } else if c == 11 {
        print("{}\n", u128::max() + uone);
    } else if c == 12 {
        print("{}\n", u128::zero() - uone);
    } else if c == 13 {
        print("{}\n", u128::max() * u128::from_u64(2));
    } else if c == 14 {
        print("{}\n", u128::from_u64(2).pow(128));
    } else if c == 15 {
        print("{}\n", u256::zero() - u256::one());
    } else if c == 16 {
        let mut x = UInt::<100>::max();
        x += UInt::<100>::one();
        print("{}\n", x);
    }
    return 0;
}
)";

@test
fn library_int_overflow_follows_the_profile() {
    let p = cli::proj_new();
    p.mkfile("main.spc", INT_RULES);
    // Off the wasm lane the two builds below compile the program.
    if cli::on_wasm() {
        assert(p.compile("main.spc").ok(), "the program compiles");
    }
    h::expect_err_msg(
        "i128 MAX + 1 in a constant",
        "fn f() i128 {\n    return i128::max() + i128::one();\n}\n\nconst F: i128 = f();\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'F' cannot be evaluated at compile time: arithmetic overflow",
    );
    h::expect_err_msg(
        "u128 0 - 1 in a constant",
        "fn f() u128 {\n    return u128::zero() - u128::one();\n}\n\nconst F: u128 = f();\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'F' cannot be evaluated at compile time: arithmetic overflow",
    );
    h::expect_err_msg(
        "u256 two to the 256 in a constant",
        "const F: u256 = u256::from_u64(2).pow(256);\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'F' cannot be evaluated at compile time: arithmetic overflow",
    );
    // Division traps as the built-in `/` does at compile time: MIN / -1 overflows, a zero divisor
    // divides by zero.
    h::expect_err_msg(
        "i128 MIN / -1 in a constant",
        "fn f() i128 {\n    return i128::min() / i128::from_i64(-1);\n}\n\nconst F: i128 = f();\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'F' cannot be evaluated at compile time: arithmetic overflow",
    );
    h::expect_err_msg(
        "an i128 remainder by zero in a constant",
        "fn f() i128 {\n    return i128::one() % i128::zero();\n}\n\nconst F: i128 = f();\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: constant 'F' cannot be evaluated at compile time: division by zero",
    );
    if cli::on_wasm() {
        return;
    }
    let root = p.dir();
    // Cases 11 to 16 follow 1 to 6 in the tables.
    let checked: []str = [
        "",
        "add",
        "subtract",
        "multiply",
        "negate",
        "multiply",
        "add",
        "add",
        "subtract",
        "multiply",
        "multiply",
        "subtract",
        "add",
    ];
    let wrapped: []str = [
        "",
        "-170141183460469231731687303715884105728",
        "170141183460469231731687303715884105727",
        "-2",
        "-170141183460469231731687303715884105728",
        "1",
        "-57896044618658097711785492504343953926634992332820282019728792003956564819968",
        "0",
        "340282366920938463463374607431768211455",
        "340282366920938463463374607431768211454",
        "0",
        "115792089237316195423570985008687907853269984665640564039457584007913129639935",
        "0",
    ];
    for release in [false, true] {
        let mut args = String::new();
        args.format_into(
            "build {}\"{}/main.spc\" -o \"{}/bin\"",
            if release {
                "--profile=release ";
            } else {
                "";
            },
            root,
            root,
        );
        assert(p.run_raw(args.as_str()).ok(), args.as_str());
        // Division traps in every profile, with the built-in messages.
        let traps: []str = [
            "attempt to divide with overflow",
            "attempt to calculate the remainder with overflow",
            "attempt to divide by zero",
            "attempt to calculate the remainder with a divisor of zero",
        ];
        let r0 = p.run_bin_env("CASE=0 ");
        assert(r0.ok(), "case 0 runs");
        assert(r0.out_shows("0 340282366920938463463374607431768211455 true 0 1 true true"), "case 0's output");
        for c in 1usize..17 {
            let mut env = String::new();
            env.format_into("CASE={} ", c);
            let r = p.run_bin_env(env.as_str());
            let mut want = String::new();
            let k = if c >= 11 {
                c - 4;
            } else {
                c;
            };
            if c >= 7 && c < 11 {
                want.push_str(traps[c - 7]);
                assert(r.exit != 0, env.as_str());
            } else if release {
                want.push_str(wrapped[k]);
                assert(r.ok(), env.as_str());
            } else {
                want.format_into("attempt to {} with overflow", checked[k]);
                assert(r.exit != 0, env.as_str());
            }
            assert(r.out_shows(want.as_str()), env.as_str());
        }
    }
}

// Literal-only arithmetic (types.md "Numeric Literals"): with a declared type it is computed in that type;
// without one, in the first of i32, i64 and u64 where no step overflows (f32, then f64, for a float
// expression). Compile time and run time agree.
const LIT_RULES: str = M"(static mut Y64: i64 = 3;
const DECL: i64 = 2000000000 * 2;
const MIN64: i64 = -9223372036854775807 - 1;
const NEG_MIN: i64 = -9223372036854775808;
const TOP: u64 = 1 << 63;
const WIDE_F: f64 = 1e30 * 1e10;
const FLT: f32 = 1.5 * 2.0;
static_assert(DECL == 4000000000 && MIN64 == NEG_MIN && TOP == 9223372036854775808, "declared types");
static_assert(2000000000 * 2 == 4000000000 && 2147483647 + 1 == 2147483648, "undeclared widening");
static_assert(-9223372036854775807 - 1 == MIN64 && FLT == 3.0, "i64 minimum and float operands");

fn main() i32 {
    let z: i64 = 2000000000 * 2;
    let w = 2000000000 * 2;
    let i = 2147483647 + 1;
    let im = i32::MAX + 1;
    let u = 9223372036854775807 + 1;
    let s = 1 << 40;
    let m = 1 << 31;
    let n: i64 = -(2000000000 * 2);
    let b: u8 = 2 + 3;
    let big = 1e39;
    let bigx = 1e30 * 1e10;
    let small = 1.5 * 2.0;
    let t = 2000000000 * 2 + unsafe Y64;
    static_assert(sizeof(w) == 8 && sizeof(i) == 8 && sizeof(im) == 8 && sizeof(u) == 8 && sizeof(s) == 8, "widened to 64 bits");
    static_assert(sizeof(m) == 4 && sizeof(b) == 1, "i32 and the declared u8");
    static_assert(sizeof(big) == 8 && sizeof(bigx) == 8 && sizeof(small) == 4, "f64 past the f32 range");
    print("{} {} {} {} {} {} {} {} {}\n", z, w, i, u, s, m, n, b, im);
    print("{} {} {} {} {} {}\n", big, bigx, small, t, DECL, MIN64);
    print("{} {} {}\n", TOP, WIDE_F, FLT);
    return 0;
}
)";

@test
fn literal_arithmetic_is_computed_in_its_type() {
    let p = cli::proj_new();
    p.mkfile("main.spc", LIT_RULES);
    // The build compiles the program the script compile would: the guest only compiles.
    if cli::on_wasm() {
        assert(p.compile("main.spc").ok(), "the program compiles");
    } else {
        let root = p.dir();
        let mut args = String::new();
        args.format_into("build \"{}/main.spc\" -o \"{}/bin\"", root, root);
        assert(p.run_raw(args.as_str()).ok(), "the program builds");
        let r = p.run_bin_env("");
        assert(r.ok(), "the program runs");
        assert(
            r.out_shows(
                "4000000000 4000000000 2147483648 9223372036854775808 1099511627776 -2147483648 -4000000000 5 2147483648",
            ),
        );
        assert(r.out_shows("1e+39 1e+40 3 4000000003 4000000000 -9223372036854775808"));
        assert(r.out_shows("9223372036854775808 1e+40 3"));
    }
    // A declared or suffixed type that overflows is an error, at run time and at compile time.
    h::expect_err_msg(
        "a declared i32 that overflows",
        "fn main() i32 {\n    let i: i32 = i32::MAX + 1;\n    return i;\n}\n",
        "error: this operation is undefined behavior when executed: arithmetic overflow",
    );
    h::expect_err_msg(
        "a suffixed i32 that overflows",
        "fn main() i32 {\n    let i = 2000000000i32 * 2;\n    return i;\n}\n",
        "error: this operation is undefined behavior when executed: arithmetic overflow",
    );
    h::expect_err_msg(
        "an i32 constant that overflows",
        "const C: i32 = i32::MAX + 1;\n\nfn main() i32 {\n    return C;\n}\n",
        "error: constant 'C' cannot be evaluated at compile time: arithmetic overflow",
    );
    // A literal past 64 bits that no wide expectation takes is the checker's error, also in a constant
    // initializer the evaluator runs.
    h::expect_err_msg(
        "a literal past 64 bits in a constant initializer",
        "fn f(x: u256) u256 {\n    return x;\n}\n\nconst C: u256 = f(123456789012345678901234567890123);\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: integer literal is too large to fit in a 64-bit integer\n--> ",
    );
    // An integer literal never becomes a float: mixing the two kinds is a type error, in literal-only
    // arithmetic, beside a float value and against a declared float type.
    h::expect_err_msg(
        "integer literal arithmetic times a float literal",
        "fn main() i32 {\n    let x = (1 / 2) * 2.0;\n    return 0;\n}\n",
        "error: mismatched types: expected 'i32', found 'f32'",
    );
    h::expect_err_msg(
        "a float constant times an integer literal",
        "const F: f32 = 1.5 * 2;\n\nfn main() i32 {\n    return 0;\n}\n",
        "error: mismatched types: expected 'f32', found 'i32'",
    );
    h::expect_err_msg(
        "a float value times an integer literal",
        "fn main() i32 {\n    let y: f64 = 2.0;\n    let x = y * 2;\n    return 0;\n}\n",
        "error: mismatched types: expected 'f64', found 'i32'",
    );
    h::expect_err_msg(
        "an integer literal for a declared float",
        "fn main() i32 {\n    let f: f32 = 1 + 2;\n    let g: f32 = 1;\n    return 0;\n}\n",
        "error: mismatched types: expected 'f32', found 'i32'",
    );
}

// The builtin numeric types' MIN and MAX: Rust's values (a float's are the finite extremes), usable in
// constants, static_assert, const generics and array lengths; isize and usize follow the target's
// pointer width, at compile time too. In literal-only arithmetic they are literals of their value.
@test
fn builtin_numeric_limits() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct B<const N: i64> { pub x: i32 }
extend<const N: i64> B<N> { fn n(self: &Self) i64 { return N; } }
const WIDE: i64 = i32::MAX + 1;
static_assert(i8::MIN == -128 && i8::MAX == 127 && i16::MIN == -32768 && i16::MAX == 32767);
static_assert(i32::MIN == -2147483648 && i32::MAX == 2147483647 && WIDE == 2147483648);
static_assert(i64::MIN == -9223372036854775807 - 1 && i64::MAX == 9223372036854775807);
static_assert(u8::MIN == 0 && u8::MAX == 255 && u16::MAX == 65535 && u32::MAX == 4294967295);
static_assert(u64::MAX == 18446744073709551615 && usize::MAX == 18446744073709551615);
static_assert(isize::MIN == -9223372036854775807 - 1 && isize::MAX == 9223372036854775807);
static_assert(f32::MAX == 3.40282347e38 && f32::MIN == -3.40282347e38);
static_assert(f64::MAX == 1.7976931348623157e308 && f64::MIN == -1.7976931348623157e308);
fn main() i32 {
    let i = i32::MAX + 1;
    static_assert(sizeof(i) == 8);
    let a: [u8; u8::MAX as usize] = [0; u8::MAX as usize];
    let b = B::<{i32::MAX}> { x: 1 };
    let m = i32::MIN;
    print("{} {} {} {} {} {}\n", i, sizeof(a), b.n(), m, u64::MAX, i16::MIN);
    return 0;
}
)",
    );
    // Off the wasm lane the build below compiles the program.
    if cli::on_wasm() {
        assert(p.compile("main.spc").ok(), "the program compiles");
    }
    // wasm32: 32-bit isize and usize, checked by the constant evaluator.
    p.mkfile(
        "wasm.spc",
        "static_assert(usize::MAX == 4294967295 && isize::MIN == -2147483648 && isize::MAX == 2147483647);\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    let root = p.dir();
    let mut wargs = String::new();
    wargs.format_into("\"{}/wasm.spc\" --target=wasm", root);
    assert(p.run_raw(wargs.as_str()).ok(), "the wasm32 limits check");
    // A declared type rejects the widened value.
    h::expect_err_msg(
        "a declared type rejects the widened value",
        "fn main() i32 {\n    let i: i32 = i32::MAX + 1;\n    return i;\n}\n",
        "error: this operation is undefined behavior when executed: arithmetic overflow",
    );
    if cli::on_wasm() {
        return;
    }
    let mut args = String::new();
    args.format_into("build \"{}/main.spc\" -o \"{}/bin\"", root, root);
    assert(p.run_raw(args.as_str()).ok(), "the program builds");
    let r = p.run_bin_env("");
    assert(r.ok(), "the program runs");
    assert(r.out_shows("2147483648 255 2147483647 -2147483648 18446744073709551615 -32768"), "the limits print");
}

// Builtin limits and associated constants as const-generic arguments and as patterns emit strict ISO C:
// the instances spell their values, a limit a pattern reads in a wider type is that type's literal,
// integer ranges that cover their type need no catch-all (one after them is an unreachable arm), and
// overlapping ranges match in arm order. The C compiles under -pedantic-errors and -Wtype-limits.
@test
fn qualified_constants_emit_valid_c() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct Lim { pub a: i32 }
extend Lim {
    pub const LO: u8 = 10;
    pub const K: i64 = 7;
}
struct U<const N: u64> { pub x: i32 }
extend<const N: u64> U<N> { pub fn n(self: &Self) u64 { return N; } }
fn off<const N: isize>(x: isize) isize { return x + N; }
fn lo<const N: i64>() i64 { return N; }
fn sign(x: i64) i32 { return switch x { i64::MIN..=-1 => 1, 0 => 2, 1..=i64::MAX => 3 }; }
fn half(x: u64) i32 { return switch x { 0..=i64::MAX => 1, 9223372036854775808..=u64::MAX => 2 }; }
fn all(x: u64) i32 { return switch x { 0..=u64::MAX => 1 }; }
fn byte(x: u8) i32 { return switch x { 0..Lim::LO => 1, Lim::LO..=u8::MAX => 2, _ => 3 }; }
fn pair(x: i32, b: bool) i32 { return switch (x, b) { (0..=5, true) => 1, (3..=10, _) => 2, _ => 3 }; }
fn main() i32 {
    let u = U::<u64::MAX> { x: 0 };
    let a = off::<isize::MAX>(0);
    print("{} {} {} {} {} {} {} {} {} {}\n", a, lo::<Lim::K>(), u.n(), sign(i64::MIN), sign(i64::MAX), half(9223372036854775808), all(0), byte(9), byte(255), pair(4, false));
    return u.x;
}
)",
    );
    let c = p.compile("main.spc");
    assert(c.ok());
    assert(c.out_has("unreachable arm: a previous arm matches every value"));
    assert(p.cc_build("-pedantic-errors -Wtype-limits ").ok());
    let r = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(r.ok() && r.out_shows("9223372036854775807 7 18446744073709551615 1 3 2 1 1 2 2\n"));
}

// A const-generic expression whose value leaves its type under an instantiation is a located error at the
// expression, naming the bindings, not a backend failure.
@test
fn const_generic_overflow_is_an_error() {
    let p = cli::proj_new();
    let mut b = cli::Batch::new("", "");
    // No case is a backend failure.
    b.forbid("internal");
    b.add(
        "an i64 product through a call",
        "fn g<const M: i64>() i64 {\n    return M;\n}\n\nfn f<const N: i64>() i64 {\n    return g::<{N * 2}>();\n}\n\nfn main() i32 {\n    return f::<5000000000000000000>() as i32;\n}\n",
        "error: const expression {2 * N} overflows i64 for N = 5000000000000000000",
    );
    // The written `N * 2` overflows before the `+ 1`: the step is the error, at its own span.
    b.add(
        "the step of a type argument",
        "struct B<const M: i64> {\n    pub x: i32,\n}\n\nfn f<const N: i64>() i32 {\n    let b = B::<{N * 2 + 1}> { x: 1 };\n    return b.x;\n}\n\nfn main() i32 {\n    return f::<5000000000000000000>();\n}\n",
        "error: const expression {N * 2} overflows i64 for N = 5000000000000000000",
    );
    // A form computes exactly: a constant past i64 is legal where written (a negative K brings the
    // value back into i64) and the instance whose value leaves i64 is the error.
    b.add(
        "a form whose constant leaves i64",
        "fn f<const N: i64>() i64 {\n    return N;\n}\n\nfn h<const K: i64>() i64 {\n    return f::<{K + 9000000000000000000 + 9000000000000000000}>();\n}\n\nfn main() i32 {\n    return h::<1>() as i32;\n}\n",
        "error: const expression {K + 18000000000000000000} overflows i64 for K = 1",
    );
    // Division by -1 of a form whose constant is i64::MIN: the negated constant is 2^63.
    b.add(
        "a division by -1 of i64 MIN",
        "fn f<const N: i64>() i64 {\n    return N;\n}\n\nfn h<const K: i64>() i64 {\n    return f::<{(K - 9223372036854775807 - 1) / -1}>();\n}\n\nfn main() i32 {\n    return h::<0>() as i32;\n}\n",
        "error: const expression {-K + 9223372036854775808} overflows i64 for K = 0",
    );
    b.add(
        "a negation of i64 MIN",
        "fn f<const N: i64>() i64 {\n    return N;\n}\n\nfn h<const K: i64>() i64 {\n    return f::<{K / -1}>();\n}\n\nfn main() i32 {\n    return h::<{0 - 9223372036854775807 - 1}>() as i32;\n}\n",
        "error: const expression {-K} overflows i64 for K = -9223372036854775808",
    );
    b.add(
        "a signature's form",
        "struct B<const M: i64> {\n    pub x: i32,\n}\n\nfn g<const M: i64>() B<{M + 9000000000000000000}> {\n    return B::<{M + 9000000000000000000}> { x: 1 };\n}\n\nfn h<const K: i64>() i32 {\n    let b = g::<{K + 9000000000000000000}>();\n    return b.x;\n}\n\nfn main() i32 {\n    return h::<1>();\n}\n",
        "error: const expression {M + 9000000000000000000} overflows i64 for M = 9000000000000000001",
    );
    // A form computes in its parameters' type: a u8 form and a u64 one leave theirs, and a u8
    // parameter that inference binds through a u64 position takes the value only when it fits.
    b.add(
        "a u8 form",
        "fn g<const M: u8>() u8 {\n    return M;\n}\n\nfn f<const N: u8>() u8 {\n    return g::<{N + 1}>();\n}\n\nfn main() i32 {\n    return f::<255>() as i32;\n}\n",
        "error: const expression {N + 1} overflows u8 for N = 255",
    );
    b.add(
        "a u64 form",
        "fn g<const M: u64>() u64 {\n    return M;\n}\n\nfn f<const N: u64>() u64 {\n    return g::<{N - 1}>();\n}\n\nfn main() i32 {\n    return f::<0>() as i32;\n}\n",
        "error: const expression {N - 1} overflows u64 for N = 0",
    );
    b.add(
        "a u8 parameter bound through a u64 position",
        "struct B<const M: u64> {\n    pub x: i32,\n}\n\nfn g<const K: u8>(b: B<K>) i32 {\n    return b.x;\n}\n\nfn h<const Q: u64>() i32 {\n    let b = B::<Q> { x: 0 };\n    return g(b);\n}\n\nfn main() i32 {\n    return h::<300>();\n}\n",
        "error: const expression {Q} overflows u8 for Q = 300",
    );
    p.expect_batch(b);
}

// A const-generic expression computes step by step in its type, as the written expression does at
// run time: an instantiation under which a step overflows is an error at that step, although the
// canonical form (`{N * 2 - N}` is `N`) would fit. A division the form floors must truncate to the
// same value, a shift that loses bits overflows, and an alias's steps belong to its user.
@test
fn const_generic_steps_follow_the_written_expression() {
    let p = cli::proj_new();
    p.mkfile(
        "steps.spc",
        "struct F<const N: u64> {\n    pub v: i32,\n}\n\nextend<const N: u64> F<N> {\n    fn n(self: &Self) u64 {\n        return N;\n    }\n}\n\nfn g<const N: u64>() u64 {\n    let x = F::<{N * 2 - N}> { v: 1 };\n    return x.n();\n}\n\nfn main() i32 {\n    return g::<18446744073709551615>() as i32;\n}\n",
    );
    let r = p.compile("steps.spc");
    assert(r.exit != 0, "the step overflows");
    assert(
        r.out_has("error: const expression {N * 2} overflows u64 for N = 18446744073709551615\n--> "),
        "the step names its expression and binding",
    );
    assert(r.out_has("steps.spc:12:18"), "at the step");
    assert(r.out_has("in the instantiation of 'g' demanded here\n--> "), "the note names the demand");
    assert(r.out_has("steps.spc:17:12"), "at the demand");
    let mut b = cli::Batch::new("", "");
    b.add_at(
        "a field's array length",
        "struct S<const N: u8> {\n    pub a: [u8; N * 2 - N],\n}\n\nfn main() i32 {\n    let s = S::<200> { a: [0; 200] };\n    return s.a[0];\n}\n",
        "error: const expression {N * 2} overflows u8 for N = 200\n--> ",
        "2:17",
    );
    // A method's steps are its own instantiation's: F<u64::MAX> is fine until `bad` is called.
    const METHODS: str = "struct F<const N: u64> {\n    pub v: i32,\n}\n\nextend<const N: u64> F<N> {\n    fn good(self: &Self) u64 {\n        return N;\n    }\n\n    fn bad(self: &Self) u64 {\n        let y = F::<{N * 2 - N}> { v: 2 };\n        return y.good();\n    }\n}\n\nfn main() i32 {\n    let f = F::<18446744073709551615> { v: 1 };\n    return (f.good() - 18446744073709551615) as i32;\n}\n";
    p.mkfile("good.spc", METHODS);
    assert(p.compile("good.spc").ok(), "an instance whose failing method is never called");
    let mut bad = String::from_str(METHODS);
    bad.push_str("\nfn use_bad() u64 {\n    let b = F::<18446744073709551615> { v: 1 };\n    return b.bad();\n}\n");
    bad = bad.replace("return (f.good() - 18446744073709551615)", "return (use_bad() - f.good())");
    b.add_at(
        "a called method's own instantiation",
        bad.as_str(),
        "error: const expression {N * 2} overflows u64 for N = 18446744073709551615\n--> ",
        "11:22",
    );
    b.add_at(
        "a negative quotient",
        "struct G<const N: i64> {\n    pub v: i32,\n}\n\nfn q<const N: i64>() G<{(N - 10) / 4 + 100}> {\n    return G::<{(N - 10) / 4 + 100}> { v: 3 };\n}\n\nfn main() i32 {\n    return q::<1>().v;\n}\n",
        "error: const expression {(N - 10) / 4} truncates the negative quotient -9 / 4 for N = 1: a const-generic division needs a dividend that is not negative or a divisor that divides it\n--> ",
        "5:25",
    );
    b.add_at(
        "a shift",
        "struct F<const N: u64> {\n    pub v: i32,\n}\n\nfn s<const N: u64>() i32 {\n    let z = F::<{(N << 1) >> 1}> { v: 4 };\n    return z.v;\n}\n\nfn main() i32 {\n    return s::<18446744073709551615>();\n}\n",
        "error: const expression {N << 1} overflows u64 for N = 18446744073709551615\n--> ",
        "6:19",
    );
    b.add_at(
        "an alias's argument",
        "struct F<const N: u64> {\n    pub v: i32,\n}\n\ntype A<const M: u64> = F<{M * 2 - M}>;\n\nfn f<const N: u64>() i32 {\n    let x = A::<N> { v: 1 };\n    return x.v;\n}\n\nfn main() i32 {\n    return f::<18446744073709551615>();\n}\n",
        "error: const expression {M * 2} overflows u64 for N = 18446744073709551615\n--> ",
        "5:27",
    );
    b.add_at(
        "a nested alias",
        "struct F<const N: u64> {\n    pub v: i32,\n}\n\ntype A<const M: u64> = F<{M - 5}>;\n\ntype B<const K: u64> = A<{K + 10}>;\n\nfn f<const N: u64>() i32 {\n    let x = B::<N> { v: 1 };\n    return x.v;\n}\n\nfn main() i32 {\n    return f::<18446744073709551610>();\n}\n",
        "error: const expression {K + 10} overflows u64 for N = 18446744073709551610\n--> ",
        "7:27",
    );
    // The constant evaluator runs an instantiation only when its steps hold, and a layout needs the
    // written member types to compute.
    p.mkfile(
        "ctfe.spc",
        "struct F<const N: u64> {\n    pub v: i32,\n}\n\nextend<const N: u64> F<N> {\n    fn n(self: &Self) u64 {\n        return N;\n    }\n}\n\nfn h<const N: u64>() u64 {\n    let y = F::<{N * 2 - N}> { v: 1 };\n    return y.n();\n}\n\nstatic_assert(h::<9>() == 9);\nstatic_assert(h::<18446744073709551615>() == 18446744073709551615);\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    let rc = p.compile("ctfe.spc");
    assert(rc.exit != 0, "expected nonzero exit on a bad program");
    assert(
        rc.out_has(
            "error: static assertion cannot be evaluated: arithmetic overflow in a const-generic expression\n--> ",
        ),
        "diagnostic missing expected text",
    );
    assert(rc.out_has("ctfe.spc:17:15"), "diagnostic at the expected location");
    assert(!rc.out_has("ctfe.spc:16:"), "the valid instantiation evaluates");
    p.mkfile(
        "layout.spc",
        "struct T<const N: u8> {\n    pub a: [u8; N + 1],\n}\n\nstatic_assert(sizeof(T<254>) == 255);\nstatic_assert(sizeof(T<255>) == 256);\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    let rl = p.compile("layout.spc");
    assert(
        rl.out_has("error: static assertion cannot be evaluated: the condition does not fold to a constant\n--> "),
        "the overflowing layout does not fold",
    );
    assert(rl.out_has("layout.spc:6:15"), "at the overflowing instance");
    assert(!rl.out_has("layout.spc:5:"), "the fitting instance lays out");
    p.expect_batch(b);
}

// Every instance checks what its generic body asserts about it: a constant index into a symbolic
// length stays below the instance's length, and an interface default body's steps hold under the
// arguments of the conformance that supplies it, the conformance's own arguments included.
@test
fn instances_check_indexes_and_default_bodies() {
    let p = cli::proj_new();
    let mut b = cli::Batch::new("", "");
    b.add(
        "a constant index past a symbolic array",
        "struct S<const N: usize> {\n    pub a: [u8; N],\n}\n\nextend<const N: usize> S<N> {\n    fn third(self: &Self) u8 {\n        return self.a[2];\n    }\n}\n\nfn main() i32 {\n    let s = S::<2> { a: [1, 2] };\n    return s.third() as i32;\n}\n",
        "error: index 2 is out of bounds for an array of length 2 for N = 2",
    );
    b.add(
        "an index past a const-generic array in a constant",
        "fn g<const N: usize>(a: [u8; N]) u8 {\n    return a[2];\n}\n\nconst C: u8 = g::<2>([1, 2]);\n\nfn main() i32 {\n    return C as i32;\n}\n",
        "error: constant 'C' cannot be evaluated at compile time: an index past the end of a const-generic array",
    );
    b.add(
        "an interface default body's step",
        "struct U<const M: u64> {\n    pub v: u64,\n}\n\ninterface I<const K: u64> {\n    fn d(self: &Self) u64 {\n        let u = U::<{K - 1}> { v: 3 };\n        return u.v + K;\n    }\n}\n\nstruct F {\n    pub x: u64,\n}\n\nextend F as I<0> {}\n\nfn main() i32 {\n    let f = F { x: 0 };\n    return f.d() as i32;\n}\n",
        "error: const expression {K - 1} overflows u64 for K = 0",
    );
    b.add(
        "a conformance's arguments",
        "struct U<const M: u64> {\n    pub v: u64,\n}\n\ninterface I<const K: u64> {\n    fn d(self: &Self) u64 {\n        let u = U::<{K - 1}> { v: 3 };\n        return u.v + K;\n    }\n}\n\nstruct G<const N: u64> {\n    pub x: u64,\n}\n\nextend<const N: u64> G<{N + 1}> as I<{N * 2}> {}\n\nfn main() i32 {\n    let g = G::<18446744073709551615> { x: 0 };\n    return g.d() as i32;\n}\n",
        "error: const expression {2 * N} overflows u64 for N = 18446744073709551614",
    );
    p.expect_batch(b);
}

// A variant the build constants do not have is an error even in a removed branch, and so is a
// profile name no profile has; the build-constant names are reserved. An unknown platform or
// instruction set is no error: it names no target of the compiler, so it equals no setting.
@test
fn build_constant_mistakes_are_errors() {
    h::expect_exit(
        "an unknown Platform variant equals no platform",
        "fn main() i32 {\n    if PLATFORM == Platform::Haiku {\n        return 1;\n    }\n    if ARCH != Arch::Sparc64 {\n        return 0;\n    }\n    return 2;\n}\n",
        0,
    );
    h::expect_err_msg(
        "an unknown Endian variant in a switch arm",
        "fn main() i32 {\n    return switch ENDIAN {\n        Little => 0,\n        Large => 1,\n    };\n}\n",
        "unknown Endian variant 'Large'; expected Little or Big",
    );
    h::expect_err_msg(
        "a local named TEST",
        "fn main() i32 {\n    let TEST = 1;\n    return TEST;\n}\n",
        "'TEST' is a reserved build constant name",
    );
    h::expect_err_msg(
        "an item named PLATFORM",
        "fn PLATFORM() i32 {\n    return 0;\n}\n\nfn main() i32 {\n    return 0;\n}\n",
        "'PLATFORM' is a reserved build constant name",
    );
    h::expect_err_msg(
        "a parameter named POINTER_WIDTH",
        "fn f(POINTER_WIDTH: i32) i32 {\n    return POINTER_WIDTH;\n}\n\nfn main() i32 {\n    return f(0);\n}\n",
        "'POINTER_WIDTH' is a reserved build constant name",
    );
    // The enums' names are reserved too: a `Platform` of the program's own would make the filter
    // decide `PLATFORM == Platform::Windows` against std's `Platform` without a type check.
    h::expect_err_msg(
        "an enum named Platform",
        "enum Platform { Windows, Other }\n\nfn main() i32 {\n    if PLATFORM == Platform::Windows {\n        return 1;\n    }\n    return 0;\n}\n",
        "'Platform' is a reserved build constant type name",
    );
    h::expect_err_msg(
        "a struct named Arch",
        "struct Arch { pub w: i32 }\n\nfn main() i32 {\n    return 0;\n}\n",
        "'Arch' is a reserved build constant type name",
    );
    h::expect_err_msg(
        "a type parameter named Endian",
        "fn f<Endian>(x: Endian) Endian {\n    return x;\n}\n\nfn main() i32 {\n    return f(0);\n}\n",
        "'Endian' is a reserved build constant type name",
    );
    // The profile names are the build's: a build checks them.
    let p = cli::proj_new();
    let mut b = cli::Batch::new("", "");
    b.add(
        "an unknown profile in a comparison",
        "fn main() i32 {\n    if PROFILE == \"relase\" {\n        return 1;\n    }\n    return 0;\n}\n",
        "unknown profile 'relase'; this build knows",
    );
    b.add(
        "an unknown profile in a switch arm",
        "fn main() i32 {\n    return switch PROFILE {\n        \"debug\" => 0,\n        \"bogus\" => 1,\n        _ => 2,\n    };\n}\n",
        "unknown profile 'bogus'",
    );
    p.expect_batch(b);
}

// Build script `main.spc` of directory `dir` to `prog` with `jobs` workers; whether it built.
fn script_build(dir: str, jobs: i32) bool {
    return cli::superc_in(
        dir,
        format("build --jobs={} main.spc -o prog{}", jobs, unsafe str::from_cstr(cli::binext())).as_str(),
    ).ok();
}

// Run `<dir>/prog`; its exit code.
fn script_run(dir: str) i32 {
    let mut cmd = format("\"{}/prog{}\"", dir, unsafe str::from_cstr(cli::binext()));
    return cli::run_quiet(cmd.cstr());
}

// Modules with one file name in two directories (a user module `lib/string` beside the std `string`)
// compile apart, serially and in parallel.
@test
fn script_build_same_file_names() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    let lib = "pub fn seven() i32 {\n    return 7;\n}\n";
    let main = "import lib::string as s;\n\nfn main() i32 {\n    let t = String::from_str(\"abc\");\n    println(\"{}\", t.as_str());\n    return s::seven() - 2;\n}\n";
    p.mkfile("a/lib/string.spc", lib);
    p.mkfile("a/main.spc", main);
    p.mkfile("b/lib/string.spc", lib);
    p.mkfile("b/main.spc", main);
    let root = p.dir();
    let ta = format("{}/a", root);
    let tb = format("{}/b", root);
    assert(script_build(ta.as_str(), 1), "the serial build");
    assert_eq(script_run(ta.as_str()), 5);
    assert(script_build(tb.as_str(), 4), "the parallel build");
    assert_eq(script_run(tb.as_str()), 5);
}

import std::time as ptime;

// One process builds a tree at a time: a build whose tree another process holds says it waits,
// waits, and finishes once the holder releases the tree. Two builds of one tree would otherwise
// rewrite the units each other compiles and cache objects under the wrong keys.
// Start `argv` in directory `dir` with its stdout and stderr in file `log`.
@platform(!wasm)
fn spawn_logged(argv: []str, log: str, dir: str) process::Child {
    let mut cmd = process::Command::new(argv);
    cmd.cwd = Option::<str>::Some(dir);
    cmd.stdout = process::Redirect::Path(log);
    cmd.stderr = process::Redirect::Stdout;
    return process::spawn(cmd).unwrap();
}

// Release lock `h` here: the scope's end would release it only after the asserts that follow.
const fn drop_lock(_h: bsys::Lock) {}

// A test binary for WASI has no processes, and a WASI compiler takes no file lock.
@platform(!wasm)
@test
fn a_build_waits_for_the_holder_of_its_tree() {
    if cli::on_wasm() {
        return; // the compiler under test runs on WASI: no file locks
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    assert(p.compile("main.spc").ok());
    let root = p.dir();
    let lock = format("{}/build/debug/.lock", root);
    let h = bsys::lock_file(lock.as_str(), 0);
    assert(h.held(), "the test takes the tree's lock");
    let log = format("{}/second.log", root);
    let argv: [str; 2] = [cli::superc_path(), "main.spc"];
    let mut child = spawn_logged(argv, log.as_str(), root);
    let mut told = false;
    for _ in 0..600 {
        if cli::read_text(log.as_str()).as_str().find("waiting for another build") >= 0 {
            told = true;
            break;
        }
        ptime::sleep(ptime::Duration::from_millis(50));
    }
    let still = child.try_wait().unwrap().is_none();
    drop_lock(h);
    assert(told, "the second build says it waits for the tree");
    assert(still, "the second build waits while the tree is held");
    assert(child.wait().unwrap() == process::ExitStatus::Code(0), "the second build finishes once the tree is free");
}

// A process killed while it holds jobserver slots gives them back: the system drops its slot locks at
// any end, a kill included. A build of a tree this test holds claims every free slot of the test's own
// four-slot jobserver, then waits; killed there, its slots are free for the next claim. (Under
// --test-no-fork the process keeps this jobserver for the later tests: a smaller budget, never a wrong
// result.)
// A test binary for WASI has no processes, and a WASI compiler takes no file lock and no jobserver slot.
@platform(!wasm)
@test
fn a_killed_build_gives_its_jobserver_slots_back() {
    if cli::on_wasm() {
        return; // the compiler under test runs on WASI: no file locks and no jobserver
    }
    let _js = cli::set_env("SC_JOBSERVER", "");
    assert(unsafe shim::sc_jobserver_init(4) == 1, "the test makes a jobserver of its own");
    // A manifest build takes its tree's lock with every slot it claimed (a serial script build hands
    // its slots back first).
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    assert(cli::superc_env_in(root, "SC_LEAK_CHECK", "fatal", "build").ok(), "the tree builds");
    let lock = format("{}/build/debug/.lock", root);
    let h = bsys::lock_file(lock.as_str(), 0);
    assert(h.held(), "the test takes the tree's lock");
    let log = format("{}/build.log", root);
    let argv: [str; 3] = [cli::superc_path(), "build", "--jobs=4"];
    let mut child = spawn_logged(argv, log.as_str(), root);
    let mut told = false;
    for _ in 0..600 {
        if cli::read_text(log.as_str()).as_str().find("waiting for another build") >= 0 {
            told = true;
            break;
        }
        ptime::sleep(ptime::Duration::from_millis(50));
    }
    assert(told, "the build waits for the tree");
    assert_eq(unsafe shim::sc_jobserver_claim(4), 1);
    unsafe shim::sc_jobserver_release_claim();
    assert(child.kill().is_ok(), "the build is killed");
    let _ = child.wait();
    drop_lock(h);
    assert_eq(unsafe shim::sc_jobserver_claim(4), 4);
    unsafe shim::sc_jobserver_release_claim();
}

// The exit-code and trap cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    ctfe_hardening_runs(&mut b);
    const_fn_semantics_runs(&mut b);
    local_consts_run(&mut b);
    b.run();
}
