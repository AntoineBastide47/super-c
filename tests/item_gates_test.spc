// What an attribute on an item asks of the build is applied, not dropped: a `static mut` or constant that
// is `@c.used` or `@c.export`ed is defined whether code names it or not, a `@platform`, `@arch` or `@when`
// gate on an item or a member of an extend or an extern block removes it where it fails, and a C name the
// runtime header defines as a function-like macro (the leak tracker's `malloc`, `calloc`, `realloc` and
// `free`) neither expands in an export's definition nor in a call through a member or a local.
import tests::harness as h;
import tests::cli_harness as cli;

// C code reads the exported data by its symbol: the static and the constant exist although no Super-C
// code names them, and the `@c.used` static carries C `used`.
@test
fn used_and_exported_data_is_defined() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(@c.export("sc_shared")
static mut SHARED: i32 = 40;
@c.export("sc_limit")
const LIMIT: u32 = 2;
@c.used
static mut KEPT: i32 = 5;
extern "C" "reader.h" {
    fn read_shared() i32;
}
fn main() i32 {
    return unsafe read_shared() - 42;
}
)",
    );
    p.mkfile("reader.h", "int read_shared(void);\n");
    p.mkfile(
        "reader.c",
        "#include <stdint.h>\nextern int32_t sc_shared;\nextern uint32_t sc_limit;\nint read_shared(void) { return sc_shared + (int)sc_limit; }\n",
    );
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("main__inst.c", "int32_t sc_shared = 40;"), "the exported static is defined");
    assert(p.gen_has("main__inst.c", "uint32_t sc_limit = 2;"), "the exported constant is defined");
    assert(p.gen_has("main__inst.c", "__attribute__((used)) int32_t KEPT = 5;"), "the used static is defined and kept");
    // The emit copies `reader.c`, the C file beside the extern header, into the tree.
    let cc = p.cc_build(format("-I\"{}\"", p.dir()).as_str());
    assert(cc.ok(), "the tree and the C reader compile and link");
    assert_eq(p.run_bin(), 0);
}

// Each target keeps the one member its gates allow: no duplicate definition, and the call reaches it.
fn member_gates_filter_members(b: &mut h::ExitBatch) {
    b.add(
        "gated members of an extend and an extern block",
        M"(struct S {}
extend S {
    @platform(windows)
    fn os() i32 {
        return 1;
    }
    @platform(!windows)
    fn os() i32 {
        return 1;
    }
    @arch(x86_64)
    fn isa() i32 {
        return 2;
    }
    @arch(!x86_64)
    fn isa() i32 {
        return 2;
    }
}
extern "C" {
    @arch(x86_64)
    fn abs(x: i32) i32;
    @arch(!x86_64)
    fn abs(x: i32) i32;
}
fn main() i32 {
    return S::os() + S::isa() + unsafe abs(-3) - 6;
}
)",
        0,
    );
}

@test
fn a_member_gated_out_is_absent() {
    h::expect_err_msg(
        "a member gated out is absent",
        "struct S {}\nextend S {\n    @arch(wasm32)\n    @platform(wasm)\n    fn only_wasm() i32 {\n        return 1;\n    }\n}\nfn main() i32 {\n    return S::only_wasm();\n}\n",
        "only_wasm",
    );
}

// Each build keeps the one item of a complementary pair its settings allow, whatever they are, and a
// condition that never holds removes its item.
fn build_condition_gates(b: &mut h::ExitBatch) {
    b.add(
        "@when keeps the items whose build condition holds",
        M"(@when(TEST && !TEST)
fn never() i32 {
    return 9;
}
@when(!THREAD_SANITIZER && !ADDRESS_SANITIZER || THREAD_SANITIZER || ADDRESS_SANITIZER)
fn always() i32 {
    return 0;
}
@when(LOCKDEP)
fn mode() i32 {
    return 0;
}
@when(!LOCKDEP)
fn mode() i32 {
    return 0;
}
struct S {}
extend S {
    @when(!(TEST || THREAD_SANITIZER))
    fn m() i32 {
        return 0;
    }
    @when(TEST || THREAD_SANITIZER)
    fn m() i32 {
        return 0;
    }
}
fn main() i32 {
    return always() + mode() + S::m();
}
)",
        0,
    );
}

// Calls through a member and a local named like the leak tracker's macros reach the function they hold.
fn runtime_macro_names(b: &mut h::ExitBatch) {
    b.add(
        "calls through members and locals named malloc, free and realloc",
        M"(struct Hooks {
    pub free: fn(i32) i32,
    pub malloc: fn(i32) i32,
}
fn twice(x: i32) i32 {
    return x * 2;
}
fn main() i32 {
    let h = Hooks { free: twice, malloc: twice };
    let realloc = twice;
    return (h.free)(1) + (h.malloc)(2) + realloc(3) - 12;
}
)",
        0,
    );
}

@test
fn a_failing_build_condition_removes_the_item() {
    h::expect_err_msg(
        "an item whose condition never holds is absent",
        "@when(TEST && !TEST)\nfn never() i32 {\n    return 1;\n}\nfn main() i32 {\n    return never();\n}\n",
        "never",
    );
    let msg = "'@when' takes a condition over TEST, THREAD_SANITIZER, ADDRESS_SANITIZER, LOCKDEP and OVERFLOW_CHECKS";
    h::expect_err_msg("an unknown name", "@when(FAST)\nfn f() {}\nfn main() i32 { return 0; }\n", msg);
    h::expect_err_msg("a constant that is not a bool", "@when(PLATFORM)\nfn f() {}\nfn main() i32 { return 0; }\n", msg);
    h::expect_err_msg("a missing operand", "@when(TEST &&)\nfn f() {}\nfn main() i32 { return 0; }\n", msg);
    h::expect_err_msg("a missing operator", "@when((TEST) LOCKDEP)\nfn f() {}\nfn main() i32 { return 0; }\n", msg);
    h::expect_err_msg("no condition", "@when()\nfn f() {}\nfn main() i32 { return 0; }\n", msg);
}

// An export named like a runtime macro is parenthesized where it is declared and defined, and an extern
// function without a header whose reserved name `super_rt.h` does not declare gets its prototype.
@test
fn macro_named_symbols_stay_symbols() {
    let ex = "@c.export(\"free\")\nfn release(p: *mut void) {}\nfn main() i32 { return 0; }\n";
    h::expect_c("an export named free", ex, "void (free)(void *p)");
    let rs = "extern \"C\" {\n    fn __probe_size(n: usize) usize;\n}\nfn main() i32 { return unsafe __probe_size(0) as i32; }\n";
    h::expect_c("a reserved extern name has a prototype", rs, "extern size_t __probe_size(size_t);");
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    member_gates_filter_members(&mut b);
    build_condition_gates(&mut b);
    runtime_macro_names(&mut b);
    b.run();
}
