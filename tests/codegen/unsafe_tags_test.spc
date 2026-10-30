// The unsafe placement claims: `@unsafe(link_section = "s")` puts a function or a `static mut` in an
// object-file section, and `@unsafe(naked)` makes a function's `asm` statements its whole machine code.
// Each is written only in the unsafe form, and the compiler rejects what it can disprove: a section
// name the target's object format cannot take, and a naked function whose body, signature or target
// needs the prologue it omits.
import tests::harness as h;
import tests::cli_harness as cli;
import driver_shim as shim;

// A Mach-O section is `segment,section`; ELF and COFF take one name, at most 8 bytes for a COFF image.
const SECTIONS: str = M"(@platform(macos | ios)
@unsafe(link_section = "__DATA,__sctag")
static mut TAGGED: u64 = 23644;

@platform(macos | ios)
@unsafe(link_section = "__DATA,__scunref")
static mut UNREF: u32 = 7;

@platform(macos | ios)
@unsafe(link_section = "__TEXT,__schot,regular,pure_instructions")
fn hot() i32 {
    return 2;
}

@platform(windows | linux | android)
@unsafe(link_section = ".sctag")
static mut TAGGED: u64 = 23644;

@platform(windows | linux | android)
@unsafe(link_section = ".scunref")
static mut UNREF: u32 = 7;

@platform(windows | linux | android)
@unsafe(link_section = ".schot")
fn hot() i32 {
    return 2;
}

fn main() i32 {
    return (unsafe TAGGED - 23644) as i32 + hot() - 2;
}
)";

// True when one line of `text` contains both `a` and `b`.
const fn line_has(text: str, a: str, b: str) bool {
    let mut start: usize = 0;
    for i in 0..text.len() + 1 {
        if i == text.len() || text.byte_at(i) == b'\n' {
            let line = text.slice(start, i);
            if line.find(a) >= 0 && line.find(b) >= 0 {
                return true;
            }
            start = i + 1;
        }
    }
    return false;
}

// The C definitions carry the section, the linked binary has each symbol in its section (the
// platform's object tool reads it), and a `static mut` no code names is defined too: a program finds
// it through the section.
@test
fn link_section_places_symbols() {
    let p = cli::proj_new();
    p.mkfile("main.spc", SECTIONS);
    let r = p.compile("main.spc");
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("main.c", "__attribute__((used, section(\""), "the function definition carries the section");
    assert(p.gen_has("main__inst.c", "__attribute__((used, section(\""), "the static definitions carry the section");
    assert(p.gen_has("main__inst.c", " UNREF = 7;"), "an unnamed static in a section is defined");
    let cc = p.native_build("", "main.spc");
    assert(cc.ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
    let plat = unsafe shim::sc_host_platform();
    let bin = format("{}/bin{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let mut cmd = if plat == 1 {
        format("nm -m \"{}\"", bin.as_str())
    } else if plat == 0 {
        format("objdump -h \"{}\"", bin.as_str())
    } else {
        format("objdump -t \"{}\"", bin.as_str())
    };
    let mut outp = format("{}/.tool", p.dir());
    if cli::run_with(cmd.cstr(), null, outp.cstr(), null, "") != 0 {
        eprintln("skipped the section half: `{}` failed (no object tool on this host)", cmd.as_str());
        return;
    }
    let out = cli::read_text(&outp);
    if plat == 1 {
        assert(out.as_str().find("(__DATA,__sctag) external _TAGGED") >= 0, "TAGGED is in its section");
        assert(out.as_str().find("(__DATA,__scunref) external _UNREF") >= 0, "UNREF is in its section");
        assert(out.as_str().find("(__TEXT,__schot) external _hot") >= 0, "hot is in its section");
    } else if plat == 0 {
        // A PE image keeps section names, not symbols' sections.
        assert(out.as_str().find(" .sctag ") >= 0, "the image has the data section");
        assert(out.as_str().find(" .scunref ") >= 0, "the image has the unnamed static's section");
        assert(out.as_str().find(" .schot ") >= 0, "the image has the code section");
    } else {
        assert(line_has(&out, " .sctag\t", " TAGGED"), "TAGGED is in its section");
        assert(line_has(&out, " .scunref\t", " UNREF"), "UNREF is in its section");
        assert(line_has(&out, " .schot\t", " hot"), "hot is in its section");
    }
}

// A `static mut` that holds a function is static data: in the init-array section of the platform it
// runs before `main`. The function is `@export` in another module, so each unit that spells its
// symbol includes that module's prototypes.
const INIT_MAIN: str = M"(import boot;

@platform(macos | ios)
@unsafe(link_section = "__DATA,__mod_init_func,mod_init_funcs")
static mut HOOK: fn() = boot::start;
@platform(linux | android)
@unsafe(link_section = ".init_array")
static mut HOOK: fn() = boot::start;
@platform(windows)
@unsafe(link_section = ".CRT$XCU")
static mut HOOK: fn() = boot::start;

fn main() i32 {
    return boot::count() - 1;
}
)";

const INIT_BOOT: str = M"(static mut N: i32 = 0;

@export("sc_boot_start")
pub fn start() {
    unsafe N += 1;
}

@export("sc_boot_count")
pub fn count() i32 {
    return unsafe N;
}
)";

@test
fn an_init_array_entry_runs_before_main() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("boot.spc", INIT_BOOT);
    p.mkfile("main.spc", INIT_MAIN);
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.gen_has("main__inst.c", "HOOK)(void) = sc_boot_start;"), "the static holds the function");
    assert(p.native_build("", "main.spc").ok(), "the program builds");
    assert_eq(p.run_bin(), 0);
}

// A section name is checked against the object format of the target, not the host.
@test
fn link_section_rejects() {
    let p = cli::proj_new();
    // The two Mach-O rejections of one target compile together.
    let mut b = cli::Batch::new("", "");
    b.flags = String::from_str("--target=macos");
    b.add(
        "a Mach-O section without its segment",
        "@unsafe(link_section = \"__DATA\")\nfn f() {}\nfn main() i32 { return 0; }\n",
        "a Mach-O section is 'segment,section', each part 1 to 16 bytes",
    );
    b.add(
        "a Mach-O section part with a space",
        "@unsafe(link_section = \"__DATA,a b\")\nfn f() {}\nfn main() i32 { return 0; }\n",
        "a part of a Mach-O section holds only letters, digits",
    );
    p.expect_batch(b);
    p.mkfile(
        "long.spc",
        "@unsafe(link_section = \"__DATA,__seventeen_bytes\")\nfn f() {}\nfn main() i32 { return 0; }\n",
    );
    let r2 = p.compile_flags("--target=ios", "long.spc");
    assert(r2.exit != 0, "a 17-byte Mach-O section part fails");
    assert(r2.out_shows("each part 1 to 16 bytes"), "and names the limit");
    p.mkfile("elf.spc", "@unsafe(link_section = \"__DATA,__x\")\nfn f() {}\nfn main() i32 { return 0; }\n");
    let r4 = p.compile_flags("--target=linux", "elf.spc");
    assert(r4.exit != 0, "a Mach-O section name fails on ELF");
    assert(
        r4.out_shows("invalid link section \"__DATA,__x\": a section name holds only letters"),
        "and names the ELF rule",
    );
    let r5 = p.compile_flags("--target=macos", "elf.spc");
    assert(r5.ok(), "the Mach-O form is valid for a Mach-O target");
    p.mkfile("empty.spc", "@unsafe(link_section = \"\")\nfn f() {}\nfn main() i32 { return 0; }\n");
    let r6 = p.compile_flags("--target=windows", "empty.spc");
    assert(r6.exit != 0, "an empty section name fails");
    assert(r6.out_shows("the name is empty"), "and says so");
    p.mkfile("wfn.spc", "@unsafe(link_section = \".x\")\nfn f() {}\nfn main() i32 { return 0; }\n");
    let r7 = p.compile_flags("--target=wasm", "wfn.spc");
    assert(r7.exit != 0, "a section on a WebAssembly function fails");
    assert(r7.out_shows("a WebAssembly function is always in the code section"), "and names the code section");
    p.mkfile("wst.spc", "@unsafe(link_section = \".x\")\nstatic mut G: i32 = 1;\nfn main() i32 { return 0; }\n");
    assert(p.compile_flags("--target=wasm", "wst.spc").ok(), "a WebAssembly data segment takes a name");

    let PLACE: str = "'@unsafe(link_section = ...)' may only be applied to a function with a body";
    h::expect_err_msg(
        "not on a const",
        "@unsafe(link_section = \".x\")\nconst C: i32 = 0;\nfn main() i32 { return C; }\n",
        PLACE,
    );
    h::expect_err_msg(
        "not on a struct",
        "@unsafe(link_section = \".x\")\nstruct S { a: i32 }\nfn main() i32 { return 0; }\n",
        PLACE,
    );
    h::expect_err_msg(
        "not on an extern function",
        "extern \"C\" {\n    @unsafe(link_section = \".x\") fn abs(x: i32) i32;\n}\nfn main() i32 { return 0; }\n",
        PLACE,
    );
    h::expect_err_msg(
        "not on an extern static",
        "extern \"C\" {\n    @unsafe(link_section = \".x\") static mut errno: i32;\n}\nfn main() i32 { return 0; }\n",
        PLACE,
    );
    h::expect_err_msg(
        "the name is a string",
        "@unsafe(link_section = 3)\nfn f() {}\nfn main() i32 { return 0; }\n",
        "takes a list of the claims 'safe', 'const', 'naked' and 'link_section = \"name\"'",
    );
    h::expect_err_msg(
        "a claim is listed once",
        "@unsafe(link_section = \"a\", link_section = \"b\")\nfn f() {}\nfn main() i32 { return 0; }\n",
        "claim 'link_section' is listed twice",
    );
    h::expect_err_msg(
        "@c.section is an unknown attribute",
        "@c.section(\"x\")\nfn f() {}\nfn main() i32 { return 0; }\n",
        "unknown attribute '@c.section'",
    );
}

// A naked function in the host's calling convention: it runs called directly and through a function
// value, its C definition has no prologue code, and a guard stops a C compiler without naked functions.
const NAKED: str = M"(@arch(aarch64)
@unsafe(naked)
fn add_one(x: i64) i64 {
    asm("add x0, x0, #1");
    asm("ret");
}

@arch(x86_64)
@platform(windows)
@unsafe(naked)
fn add_one(x: i64) i64 {
    asm("leaq 1(%rcx), %rax\n\tret");
}

@arch(x86_64)
@platform(macos | linux | android)
@unsafe(naked)
fn add_one(x: i64) i64 {
    asm("leaq 1(%rdi), %rax\n\tret");
}

@arch(aarch64)
@unsafe(naked)
fn load(p: *const u32) u32 {
    asm("ldr w0, [x0]\n\tret");
}

@arch(x86_64)
@platform(windows)
@unsafe(naked)
fn load(p: *const u32) u32 {
    asm("movl (%rcx), %eax\n\tret");
}

@arch(x86_64)
@platform(macos | linux | android)
@unsafe(naked)
fn load(p: *const u32) u32 {
    asm("movl (%rdi), %eax\n\tret");
}

fn main() i32 {
    let f: fn(i64) i64 = add_one;
    let v: u32 = 5;
    return (add_one(41) - 42) as i32 + (f(1) - 2) as i32 + load(&v) as i32 - 5;
}
)";

fn naked_function_runs(b: &mut h::ExitBatch) {
    if h::target_lane() {
        return; // the function has an aarch64 and an x86_64 form only
    }
    b.add("a naked function runs", NAKED, 0);
}

@test
fn naked_function_is_its_assembly() {
    let c = h::compile_c(NAKED);
    assert(c.ok(), "the program compiles");
    assert(
        c.code_has("__attribute__((naked, noinline)) int64_t add_one(int64_t x) {\n  __asm__ volatile ("),
        "only the assembly",
    );
    assert(c.code_has("#error \"'@unsafe(naked)' needs Clang, or GCC 8 or later on x86-64\""), "the C compiler guard");
}

// A naked function whose body is one call of a context primitive is that primitive's assembly: in C,
// file-scope assembly per object format, with no C definition.
@test
fn naked_context_primitive_is_file_scope_assembly() {
    let c = h::compile_c(
        "extern \"C\" {\n    fn sc_sys_ctx_entry();\n}\n@unsafe(naked)\nfn ent() {\n    unsafe sc_sys_ctx_entry();\n}\nfn main() i32 {\n    let f: fn() = ent;\n    if false {\n        f();\n    }\n    return 0;\n}\n",
    );
    assert(c.ok(), "the program compiles");
    assert(c.code_has("#if defined(__APPLE__)\n__asm__(\".text\\n"), "the Mach-O form");
    assert(c.code_has("#elif defined(_WIN32)\n__asm__(\".text\\n"), "the COFF form");
    assert(c.code_has(".globl _ent\\n"), "the Mach-O label");
    assert(!c.code_has("__attribute__((naked, noinline)) void ent("), "no C definition");
    assert(c.code_has("void ent(void);\n#if defined(__APPLE__)\n"), "the declaration, then the assembly");
    assert(c.code_has("#else\n__asm__(\".text\\n.globl ent\\n.hidden ent\\n"), "the ELF form");
}

// The body is assembly alone or one call of a context primitive, the signature has one C calling
// convention, and the target has naked functions.
@test
fn naked_rejects() {
    let BODY: str = "the body of a '@unsafe(naked)' function holds only 'asm(\"...\");' statements";
    h::expect_err_msg(
        "no statement but asm",
        "@unsafe(naked)\nfn f() {\n    let x = 1;\n}\nfn main() i32 { return 0; }\n",
        BODY,
    );
    h::expect_err_msg(
        "no other call",
        "extern \"C\" {\n    fn g();\n}\n@unsafe(naked)\nfn f() {\n    unsafe g();\n}\nfn main() i32 { return 0; }\n",
        BODY,
    );
    h::expect_err_msg(
        "a context primitive alone",
        "extern \"C\" {\n    fn sc_sys_ctx_entry();\n}\n@unsafe(naked)\nfn f() {\n    unsafe sc_sys_ctx_entry();\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        BODY,
    );
    h::expect_err_msg(
        "no unsafe block",
        "@unsafe(naked)\nfn f() {\n    unsafe { asm(\"ret\"); }\n}\nfn main() i32 { return 0; }\n",
        BODY,
    );
    h::expect_err_msg(
        "no operands",
        "@unsafe(naked)\nfn f(x: i32) i32 {\n    asm(\"ret\" : : \"r\"(x));\n}\nfn main() i32 { return 0; }\n",
        "an 'asm' statement in a '@unsafe(naked)' function takes no operands or clobbers",
    );
    h::expect_err_msg(
        "no clobbers",
        "@unsafe(naked)\nfn f() {\n    asm(\"ret\" : : : \"memory\");\n}\nfn main() i32 { return 0; }\n",
        "takes no operands or clobbers",
    );
    h::expect_err_msg(
        "a body",
        "@unsafe(naked)\nfn f() {\n}\nfn main() i32 { return 0; }\n",
        "a '@unsafe(naked)' function needs a body of 'asm' statements",
    );
    let GEN: str = "a '@unsafe(naked)' function cannot be generic or an interface method";
    h::expect_err_msg(
        "not generic",
        "@unsafe(naked)\nfn f<T>(x: *const T) {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        GEN,
    );
    h::expect_err_msg(
        "not in a generic extend",
        "struct B<T> { a: T }\nextend<T> B<T> {\n    @unsafe(naked)\n    fn f() {\n        asm(\"ret\");\n    }\n}\nfn main() i32 { return 0; }\n",
        GEN,
    );
    h::expect_err_msg(
        "not const",
        "@unsafe(naked)\nconst fn f() {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        "a '@unsafe(naked)' function cannot be a 'const fn'",
    );
    // The specific error alone: no generic 'const fn' verdict follows it.
    let one = h::compile(
        "@unsafe(naked)\nconst fn f() {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        h::STAGE_TYPECHECK,
    );
    assert_eq(one.errors, 1);
    h::expect_err_msg(
        "not inlined",
        "@always_inline\n@unsafe(naked)\nfn f() {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        "a '@unsafe(naked)' function cannot be inlined",
    );
    let SIG: str = "a '@unsafe(naked)' function takes and returns only integers, floats, 'bool', 'char' and raw pointers";
    h::expect_err_msg(
        "no struct parameter",
        "struct S { a: i32 }\n@unsafe(naked)\nfn f(s: S) {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        SIG,
    );
    h::expect_err_msg(
        "no reference parameter",
        "@unsafe(naked)\nfn f(s: &i32) {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        SIG,
    );
    h::expect_err_msg(
        "one result",
        "@unsafe(naked)\nfn f() (i32, i32) {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        SIG,
    );
    let PLACE: str = "'@unsafe(naked)' may only be applied to a function with a body outside an 'extern \"C\"' block";
    h::expect_err_msg(
        "not on an extern function",
        "extern \"C\" {\n    @unsafe(naked) fn abs(x: i32) i32;\n}\nfn main() i32 { return 0; }\n",
        PLACE,
    );
    h::expect_err_msg("not on a static", "@unsafe(naked)\nstatic mut G: i32 = 0;\nfn main() i32 { return 0; }\n", PLACE);
    h::expect_err_msg(
        "a claim is listed once",
        "@unsafe(naked, naked)\nfn f() {\n    asm(\"ret\");\n}\nfn main() i32 { return 0; }\n",
        "claim 'naked' is listed twice",
    );
    let p = cli::proj_new();
    p.mkfile("w.spc", "@unsafe(naked)\nfn f() {\n    asm(\"return\");\n}\nfn main() i32 { return 0; }\n");
    let r = p.compile_flags("--target=wasm", "w.spc");
    assert(r.exit != 0, "a naked function fails on wasm32");
    assert(r.out_shows("'@unsafe(naked)' is not supported on wasm32"), "and says so");
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    naked_function_runs(&mut b);
    b.run();
}
