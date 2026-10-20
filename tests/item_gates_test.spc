// What an attribute on an item asks of the build is applied, not dropped: a `static mut` or constant that
// is `@c.used` or `@c.export`ed is defined whether code names it or not, and a `@platform` or `@arch` gate on
// a member of an extend or an extern block removes the member where it fails, as it removes an item.
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

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    member_gates_filter_members(&mut b);
    b.run();
}
