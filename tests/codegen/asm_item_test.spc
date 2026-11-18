// A module-level `asm` is file-scope basic assembly: its template alone, in its module's unit, kept
// whenever the module loads, since only C names the symbols it defines. A matchertext template becomes
// a C string literal, in a module-level `asm` and in an `asm` statement alike.
import tests::harness as h;
import tests::cli_harness as cli;
import target::assembler as asmr;
import codegen::obj as ob;

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
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
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

// Two entries of one block: `two_b` sets 22 and branches into the code after `two_a`'s label.
const TWO: str = M"(@platform(macos | ios)
@arch(aarch64)
asm(".text\n.globl _two_a\n.globl _two_b\n.p2align 4\n_two_b:\n    mov x0, #22\n    b 1f\n_two_a:\n    mov x0, #11\n1:\n    ret\n");

@platform(macos)
@arch(x86_64)
asm(".text\n.globl _two_a\n.globl _two_b\n_two_b:\n    movl $22, %eax\n    jmp 1f\n_two_a:\n    movl $11, %eax\n1:\n    ret\n");

@platform(linux | android)
@arch(aarch64)
asm(".text\n.globl two_a\n.globl two_b\n.p2align 4\ntwo_b:\n    mov x0, #22\n    b 1f\ntwo_a:\n    mov x0, #11\n1:\n    ret\n");

@platform(linux | windows)
@arch(x86_64)
asm(".text\n.globl two_a\n.globl two_b\ntwo_b:\n    movl $22, %eax\n    jmp 1f\ntwo_a:\n    movl $11, %eax\n1:\n    ret\n");

extern "C" {
    fn two_b() u64;
}

fn main() i32 {
    println("{}", unsafe two_b());
    return 0;
}
)";

// A Mach-O linker splits a section at its symbols: a branch the assembler resolves in place from one
// symbol's code into the next's keeps them one part (the later symbol an alternate entry, as
// `.alt_entry` makes one), so a dead-stripping build that names only the first keeps the code it branches
// to; an ELF object needs no mark.
@test
fn a_branch_between_entries_keeps_them_together() {
    let text = ".text\n.globl _p\n.globl _q\n.globl _r\n.alt_entry _r\n_p:\n    b 1f\n_q:\n    nop\n1:\n    ret\n_r:\n    ret\n";
    let mut o = ob::Obj::new();
    let mut a = asmr::Asm::new(asmr::ISA_A64, asmr::FMT_MACHO);
    assert(a.module(&mut o, text), a.err.as_str());
    let mut got = String::new();
    for k in 0..o.syms.len() {
        got.format_into("{}:{} ", o.name_of(k as u32), (o.syms[k].flags & ob::SF_ALT) != 0);
    }
    assert_eq(got.as_str(), "p:false q:true r:true ");
    let mut e = ob::Obj::new();
    let mut b = asmr::Asm::new(asmr::ISA_A64, asmr::FMT_ELF);
    assert(b.module(&mut e, ".text\n.globl p\n.globl q\np:\n    b 1f\nq:\n    nop\n1:\n    ret\n"), b.err.as_str());
    for k in 0..e.syms.len() {
        assert((e.syms[k].flags & ob::SF_ALT) == 0, "no mark in ELF");
    }
    if cli::on_wasm() {
        return;
    }
    h::expect_same_output("two entries", TWO, ["--profile=debug"], ["--profile=release"]);
}
