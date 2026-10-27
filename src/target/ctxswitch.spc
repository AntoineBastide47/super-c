// The context switch and its entry trampoline (`O_SYS` `SYS_CTXSWAP` and `SYS_CTXENTRY`), each the
// whole of a naked function: per target, the assembly the concurrency runtime held, instruction for
// instruction, with its call-frame or Microsoft x64 unwind directives. `sc_ctx_swap(save_sp, to_sp)` pushes
// the callee-saved set onto the running stack, stores the resulting sp through its first argument, and
// pops the same layout off the second: a suspended context is that one stack pointer, and
// `sc_rt_ctx_init` starts a coroutine by forging the frame by hand. The floating-point control state
// (MXCSR and the x87 control word, FPCR) travels with the coroutine. `sc_ctx_entry` is where a forged
// frame's final `ret` lands: it moves the saved argument into the first argument register and calls the
// coroutine body, which switches away instead of returning; a return traps. Not shadow-stack safe: the
// first resume returns to a forged address.
//
// System V x86-64: 48 bytes of registers, 8 for MXCSR and the x87 control word, then the return address
// `ret` consumes; sp+64 (where the trampoline starts) is 16-aligned, as a `call` needs. AArch64: x19-x28,
// fp, lr and d8-d15 (the callee-saved set), then FPCR; 176 bytes keep sp 16-aligned; sp cannot be a store
// operand, so it goes through a caller-saved scratch register. Microsoft x64 saves more than System V:
// eight GPRs, xmm6-xmm15 and four TEB fields (StackBase, StackLimit, DeallocationStack,
// GuaranteedStackBytes): __chkstk probes and the SEH unwinder read the running thread's stack bounds from
// the TEB, and the kernel reads the stack guarantee from it when the stack overflows. Its frame: 160 bytes
// of xmm, 64 of GPRs, 24 of TEB fields, 16 of MXCSR, the x87 control word and the guarantee; sp stays
// 16-aligned (movaps needs it) and the return address `ret` consumes sits above it at +264. Its entry
// provides the 32-byte shadow space the Win64 caller owes its callee.
import target::assembler as asmr;
import target::table as tgt;
import lir::ir as ir;

const SYSV_SWAP: str<'static> = M"(  .cfi_startproc
  pushq %rbp
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbp, -16
  pushq %rbx
  .cfi_adjust_cfa_offset 8
  .cfi_offset %rbx, -24
  pushq %r12
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r12, -32
  pushq %r13
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r13, -40
  pushq %r14
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r14, -48
  pushq %r15
  .cfi_adjust_cfa_offset 8
  .cfi_offset %r15, -56
  subq  $8, %rsp
  .cfi_adjust_cfa_offset 8
  stmxcsr (%rsp)
  fnstcw  4(%rsp)
  movq  %rsp, (%rdi)
  movq  %rsi, %rsp
  ldmxcsr (%rsp)
  fldcw   4(%rsp)
  addq  $8, %rsp
  .cfi_adjust_cfa_offset -8
  popq  %r15
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r15
  popq  %r14
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r14
  popq  %r13
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r13
  popq  %r12
  .cfi_adjust_cfa_offset -8
  .cfi_restore %r12
  popq  %rbx
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbx
  popq  %rbp
  .cfi_adjust_cfa_offset -8
  .cfi_restore %rbp
  ret
  .cfi_endproc)";

const SYSV_ENTRY: str<'static> = M"(  .cfi_startproc
  .cfi_undefined %rip
  movq  %r13, %rdi
  callq *%r12
  ud2
  .cfi_endproc)";

const A64_SWAP: str<'static> = M"(  .cfi_startproc
  sub  sp, sp, #176
  .cfi_def_cfa_offset 176
  stp  x19, x20, [sp, #0]
  stp  x21, x22, [sp, #16]
  stp  x23, x24, [sp, #32]
  stp  x25, x26, [sp, #48]
  stp  x27, x28, [sp, #64]
  stp  x29, x30, [sp, #80]
  .cfi_offset x19, -176
  .cfi_offset x20, -168
  .cfi_offset x21, -160
  .cfi_offset x22, -152
  .cfi_offset x23, -144
  .cfi_offset x24, -136
  .cfi_offset x25, -128
  .cfi_offset x26, -120
  .cfi_offset x27, -112
  .cfi_offset x28, -104
  .cfi_offset x29,  -96
  .cfi_offset x30,  -88
  stp  d8,  d9,  [sp, #96]
  stp  d10, d11, [sp, #112]
  stp  d12, d13, [sp, #128]
  stp  d14, d15, [sp, #144]
  mrs  x2, fpcr
  str  x2, [sp, #160]
  mov  x2, sp
  str  x2, [x0]
  mov  sp, x1
  ldr  x2, [sp, #160]
  msr  fpcr, x2
  ldp  x19, x20, [sp, #0]
  ldp  x21, x22, [sp, #16]
  ldp  x23, x24, [sp, #32]
  ldp  x25, x26, [sp, #48]
  ldp  x27, x28, [sp, #64]
  ldp  x29, x30, [sp, #80]
  ldp  d8,  d9,  [sp, #96]
  ldp  d10, d11, [sp, #112]
  ldp  d12, d13, [sp, #128]
  ldp  d14, d15, [sp, #144]
  add  sp, sp, #176
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc)";

const A64_ENTRY: str<'static> = M"(  .cfi_startproc
  .cfi_undefined x30
  mov  x0, x20
  blr  x19
  brk  #0
  .cfi_endproc)";

const WIN_SWAP: str<'static> = M"(  subq $264, %rsp
  .seh_stackalloc 264
  movaps %xmm6,    0(%rsp)
  movaps %xmm7,   16(%rsp)
  movaps %xmm8,   32(%rsp)
  movaps %xmm9,   48(%rsp)
  movaps %xmm10,  64(%rsp)
  movaps %xmm11,  80(%rsp)
  movaps %xmm12,  96(%rsp)
  movaps %xmm13, 112(%rsp)
  movaps %xmm14, 128(%rsp)
  movaps %xmm15, 144(%rsp)
  .seh_savexmm %xmm6, 0
  .seh_savexmm %xmm7, 16
  .seh_savexmm %xmm8, 32
  .seh_savexmm %xmm9, 48
  .seh_savexmm %xmm10, 64
  .seh_savexmm %xmm11, 80
  .seh_savexmm %xmm12, 96
  .seh_savexmm %xmm13, 112
  .seh_savexmm %xmm14, 128
  .seh_savexmm %xmm15, 144
  movq %rbx, 160(%rsp)
  .seh_savereg %rbx, 160
  movq %rbp, 168(%rsp)
  .seh_savereg %rbp, 168
  movq %rdi, 176(%rsp)
  .seh_savereg %rdi, 176
  movq %rsi, 184(%rsp)
  .seh_savereg %rsi, 184
  movq %r12, 192(%rsp)
  .seh_savereg %r12, 192
  movq %r13, 200(%rsp)
  .seh_savereg %r13, 200
  movq %r14, 208(%rsp)
  .seh_savereg %r14, 208
  movq %r15, 216(%rsp)
  .seh_savereg %r15, 216
  .seh_endprologue
  movq %gs:0x08, %rax
  movq %rax, 224(%rsp)
  movq %gs:0x10, %rax
  movq %rax, 232(%rsp)
  movq %gs:0x1478, %rax
  movq %rax, 240(%rsp)
  stmxcsr 248(%rsp)
  fnstcw  252(%rsp)
  movl %gs:0x1748, %eax
  movl %eax, 256(%rsp)
  movq %rsp, (%rcx)
  movq %rdx, %rsp
  ldmxcsr 248(%rsp)
  fldcw   252(%rsp)
  movl 256(%rsp), %eax
  movl %eax, %gs:0x1748
  movq 224(%rsp), %rax
  movq %rax, %gs:0x08
  movq 232(%rsp), %rax
  movq %rax, %gs:0x10
  movq 240(%rsp), %rax
  movq %rax, %gs:0x1478
  movaps    0(%rsp), %xmm6
  movaps   16(%rsp), %xmm7
  movaps   32(%rsp), %xmm8
  movaps   48(%rsp), %xmm9
  movaps   64(%rsp), %xmm10
  movaps   80(%rsp), %xmm11
  movaps   96(%rsp), %xmm12
  movaps  112(%rsp), %xmm13
  movaps  128(%rsp), %xmm14
  movaps  144(%rsp), %xmm15
  movq 160(%rsp), %rbx
  movq 168(%rsp), %rbp
  movq 176(%rsp), %rdi
  movq 184(%rsp), %rsi
  movq 192(%rsp), %r12
  movq 200(%rsp), %r13
  movq 208(%rsp), %r14
  movq 216(%rsp), %r15
  addq $264, %rsp
  ret
  .seh_endproc)";

const WIN_ENTRY: str<'static> = M"(  movq %r13, %rcx
  subq $32, %rsp
  callq *%r12
  ud2)";

// The instructions of context operation `op` for x86-64 (`x64`; `win`: the Microsoft x64 convention) or
// arm64, with their unwind directives, after the label.
fn lines(op: u16, x64: bool, win: bool) str<'static> {
    let swap = op == ir::SYS_CTXSWAP;
    if win && x64 {
        return if swap {
            WIN_SWAP;
        } else {
            WIN_ENTRY;
        };
    }
    if x64 {
        return if swap {
            SYSV_SWAP;
        } else {
            SYSV_ENTRY;
        };
    }
    return if swap {
        A64_SWAP;
    } else {
        A64_ENTRY;
    };
}

/// The module-level assembly of naked function `name` whose body is context operation `op`, for
/// instruction set `isa` (x86-64 or arm64, `tgt::isa`) and object format `fmt` (`asmr::FMT_*`): `.text`,
/// the symbol global and hidden (`.private_extern` on Mach-O, `.hidden` on ELF; a COFF one opens its
/// unwind procedure first), aligned to 16 bytes, its label (`_name` on Mach-O), then `lines`.
pub fn text(op: u16, isa: i32, fmt: u8, name: str, out: &mut String) {
    let x64 = tgt::isa(isa).name == "x86_64";
    let lab = if fmt == asmr::FMT_MACHO {
        format("_{}", name);
    } else {
        String::from_str(name);
    };
    out.push_str(".text\n");
    let win = fmt == asmr::FMT_COFF;
    if win && op == ir::SYS_CTXSWAP {
        out.format_into(".seh_proc {}\n", lab.as_str());
    }
    out.format_into(".globl {}\n", lab.as_str());
    if fmt == asmr::FMT_MACHO {
        out.format_into(".private_extern {}\n", lab.as_str());
    } else if fmt == asmr::FMT_ELF {
        out.format_into(".hidden {}\n", lab.as_str());
    }
    out.format_into(".p2align 4\n{}:\n", lab.as_str());
    out.push_str(lines(op, x64, win));
    out.push_byte(b'\n');
}
