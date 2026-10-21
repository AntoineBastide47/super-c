// A module-level `asm` is file-scope basic assembly: its template alone, in its module's unit, kept
// whenever the module loads, since only C names the symbols it defines. A matchertext template becomes
// a C string literal, in a module-level `asm` and in an `asm` statement alike.
import tests::harness as h;
import tests::cli_harness as cli;

// `sc_asm_seven` returns 7 on every native target; the module that defines it names no Super-C item.
const SEVEN_MOD: str = M"(@platform(macos | ios)
@arch(aarch64)
asm(M"(.text
.globl _sc_asm_seven
.p2align 2
_sc_asm_seven:
    mov x0, #7
    ret
)");

@platform(macos)
@arch(x86_64)
asm(".text\n.globl _sc_asm_seven\n_sc_asm_seven:\n    movl $7, %eax\n    ret\n");

@platform(linux | android)
@arch(aarch64)
asm(".text\n.globl sc_asm_seven\n.p2align 2\nsc_asm_seven:\n    mov x0, #7\n    ret\n");

@platform(linux | windows)
@arch(x86_64)
asm(".text\n.globl sc_asm_seven\nsc_asm_seven:\n    movl $7, %eax\n    ret\n");

extern "C" {
    pub fn sc_asm_seven() i64;
}
)";

const SEVEN_MAIN: str = M"(import seven;

@arch(x86_64)
fn twice() u64 {
    let mut out: u64 = 0;
    unsafe {
        asm(M"(mov %1, %0
add %1, %0)" : "=r"(out) : "r"(21u64));
    }
    return out;
}

@arch(aarch64)
fn twice() u64 {
    let mut out: u64 = 0;
    unsafe {
        asm(M"(add %0, %1, %1
nop)" : "=r"(out) : "r"(21u64));
    }
    return out;
}

fn main() i32 {
    if unsafe seven::sc_asm_seven() != 7 {
        return 1;
    }
    if twice() != 42 {
        return 2;
    }
    return 0;
}
)";

@test
fn module_level_asm_defines_symbols() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("seven.spc", SEVEN_MOD);
    p.mkfile("main.spc", SEVEN_MAIN);
    assert(p.compile("main.spc").ok(), "the program compiles");
    assert(p.cc_build("").ok(), "the emitted C and the assembly compile and link");
    assert_eq(p.run_bin(), 0);
}

@test
fn module_level_asm_errors() {
    assert(h::parse_has_error("asm(\"nop\" : : \"r\"(1));\nfn main() i32 { return 0; }\n"), "operands are rejected");
    assert(h::parse_has_error("asm(\"nop\" : : : \"memory\");\nfn main() i32 { return 0; }\n"), "clobbers are rejected");
    assert(h::parse_has_error("asm(x);\nfn main() i32 { return 0; }\n"), "a template is a string literal");
    assert(!h::parse_has_error("asm(\"nop\");\nfn main() i32 { return 0; }\n"), "a template alone parses");
}

@test
fn a_matchertext_template_is_a_c_string() {
    let c = h::compile_c_user("asm(M\"(.text\n.globl q\")\");\nfn main() i32 { return 0; }\n");
    assert(c.ok(), "the program compiles");
    assert(c.code_has("__asm__(\".text\\n.globl q\\\"\");"), "the template's bytes, escaped for C");
}
