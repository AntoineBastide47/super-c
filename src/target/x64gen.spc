// The x86-64 code generator: LIR bodies to machine code in one pass per body (after TPDE, Schwarz, Kamm
// and Engelke 2025), into an object (`codegen::obj`), under the System V calling convention, with the
// SSE2 baseline every x86-64 processor has.
//
// Values: an integer up to 64 bits or a pointer lives in a general register, a float in an xmm register;
// an i128 or a vector lives in its stack slot. A register's upper bits beyond an i8, i16 or i32 value
// are undefined: an operation that reads them extends first. Registers are allocated greedily as the
// instructions encode; a value dies at its last use in the block that ends its live range, a value live
// past its block is in its home (a stack slot, or a callee-saved register held for its whole range when it
// is defined in a loop) before the block's branch, and a block whose only predecessor falls through to it
// keeps the register state. Constants and symbol and slot addresses rematerialize at each use. A
// two-operand instruction writes its first operand's register when that operand dies there.
//
// Registers: rax, rcx, rdx, rsi, rdi, r8, r9 and xmm0..xmm13 are allocated; rbx, r12..r15 hold loop values
// (SysV keeps no xmm register across a call); r10, r11, xmm14 and xmm15 are scratch; rbp is the frame
// pointer. An instruction that needs a fixed register (a shift count in cl, a division in rdx:rax) moves
// that register's value elsewhere first. Frame (from rsp up): the outgoing stack arguments, the LIR slots,
// the spills and memory values; then the callee-saved registers and rbp, which rbp points at.
import lir::ir as *;
import codegen::live as lv;
import lir::switches as sws;
import codegen::place;
import codegen::place as *;
import lir::verify as lver;
import codegen::obj as ob;
import codegen::dwarf as dw;
import codegen::abi as ab;
import target::x64 as x;
import target::sysv as cc;
import target::win64 as w64;
import ir::core as core;
import std::float as fl;
import target::assembler as asmr;
import target::intrin as intrin;

const V0: u8 = 16; // register number of xmm0: general registers are 0..15

// The in-place operations `Gen::chain_ret` follows to a return.
const CHAIN_STEPS: u32 = 4;
// Scratch registers; the vector ones are the ABI's (`Gen.vs0`, `Gen.vs1`).
const S0: u8 = 10; // r10
const S1: u8 = 11; // r11
// A division looks this many instructions ahead for its remainder (`int_op`).
const DIV_REACH: u32 = 8;
// `zero_run` takes runs of ZERO_RUN to ZERO_RUN_MAX stores.
const ZERO_RUN: u32 = 4;
const ZERO_RUN_MAX: u32 = 32;

// Register sets (bit `r` for register number `r`) and vector scratch registers, per ABI: System V
// saves no vector register; Microsoft x64 saves rsi, rdi and xmm6..xmm15, so its scratch ones are xmm4
// and xmm5, and a body that takes one of xmm6..xmm13 saves it.
const XALLOC_SYSV: u64 = 0x3C7; // rax rcx rdx rsi rdi r8 r9
const XFIX_SYSV: u64 = 0xF008; // rbx r12 r13 r14 r15
const VALLOC_SYSV: u64 = 0x3FFF0000; // xmm0..xmm13
const XALLOC_WIN: u64 = 0x307; // rax rcx rdx r8 r9
// The caller-saved registers a value may hold for its whole range (`Gen::fix_class`): no register an
// instruction takes for itself (rax, rcx, rdx).
const XSCR_SYSV: u64 = 0x3C0; // rsi rdi r8 r9
const XSCR_WIN: u64 = 0x300; // r8 r9
const VSCR_SYSV: u64 = 0x3F000000; // xmm8..xmm13
// System V's xmm homes in a body that calls nothing that returns (`plan_homes`): no call's arguments and no
// intrinsic's template take xmm4..xmm7 there.
const VSCR_SYSV_BARE: u64 = 0x3FF00000; // xmm4..xmm13
// The argument registers: what the entry block's parameters arrive in.
const ARGS_SYSV: u64 = 0xFF03C6; // rdi rsi rdx rcx r8 r9, xmm0..xmm7
const ARGS_WIN: u64 = 0xF0306; // rcx rdx r8 r9, xmm0..xmm3

// `Gen::fix_class`: no fixed register, a callee-saved one, a caller-saved one.
const FIX_NONE: u8 = 0;
const FIX_CALLEE: u8 = 1;
const FIX_SCRATCH: u8 = 2;
const XFIX_WIN: u64 = 0xF0C8; // rbx rsi rdi r12 r13 r14 r15
const VALLOC_WIN: u64 = 0x3FCF0000; // xmm0..xmm3, xmm6..xmm13
// The caller-saved xmm homes of a body that calls nothing that returns (`plan_homes`).
const VSCR_WIN_BARE: u64 = 0xF0000; // xmm0..xmm3
const VSAVE_WIN: u64 = 0xFFC00000; // xmm6..xmm15
// The callee-saved xmm registers a value may hold for its whole range (Microsoft x64), in the order taken:
// xmm14 and xmm15 (no temporary's), then xmm8..xmm13 (no intrinsic's template names xmm8 and up).
const VFIX_WIN: [u8; 8] = [30, 31, 24, 25, 26, 27, 28, 29];

// `Gen::bytes_only` follows at most this many logic operations.
const BYTES_DEPTH: u32 = 3;

const fn bit(r: u8) u64 {
    return 1u64 << r as u64;
}

// The DWARF numbers of the general registers: rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, then r8..r15.
const DWARF_REG: [u8; 16] = [0, 2, 1, 3, 7, 6, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15];

// DW_CFA_advance_loc by `d` code bytes, in the shortest form.
fn cfa_advance(out: &mut Vector<u8>, d: u32) {
    if d < 64 {
        out.push((0x40 | d) as u8);
    } else if d < 256 {
        out.push(0x02);
        out.push(d as u8);
    } else {
        out.push(0x03);
        out.push(d as u8);
        out.push((d >> 8) as u8);
    }
}

// The Microsoft x64 UNWIND_INFO of a prologue of `pl` bytes into `out`: `push rbp` (1 byte; the `mov rbp,
// rsp` after it changes nothing the unwinder restores) when `fpush`, the pushes of `regs` ending at `push_at`, the
// allocation of `local` bytes ending at `alloc_end`, and the saves of xmm `xregs` at rsp + `xsave` +
// 16 j ending at `xsave_at`; with frame register `fp` (NOREG: none), its copy of rsp ending at `fp_at`,
// after which the prologue aligns rsp. The codes run backwards through the prologue.
fn win_unwind(
    out: &mut Vector<u8>,
    pl: u32,
    fpush: bool,
    push_at: &Vector<u32>,
    regs: &Vector<u8>,
    alloc_end: u32,
    local: u32,
    xsave_at: &Vector<u32>,
    xregs: &Vector<u8>,
    xsave: u32,
    fp: u8,
    fp_at: u32,
) {
    let mut codes = Vector::<u8>::new();
    // The frame register (NOREG: none) holds rsp after the allocation: UWOP_SET_FPREG, offset 0.
    if fp != NOREG {
        codes.push(fp_at as u8);
        codes.push(3);
    }
    let mut j = xregs.len();
    while j > 0 {
        j -= 1;
        let off = (xsave + 16 * j as u32) / 16;
        codes.push(xsave_at[j] as u8);
        if off <= 0xFFFF {
            codes.push(xregs[j] << 4 | 8);
            codes.push(off as u8);
            codes.push((off >> 8) as u8);
        } else {
            let b = off * 16;
            codes.push(xregs[j] << 4 | 9);
            for q in 0..4u32 {
                codes.push((b >> 8 * q) as u8);
            }
        }
    }
    if local != 0 {
        codes.push(alloc_end as u8);
        if local <= 128 {
            codes.push((local / 8 - 1 << 4 | 2) as u8);
        } else if local <= 524280 {
            codes.push(1);
            codes.push((local / 8) as u8);
            codes.push((local / 8 >> 8) as u8);
        } else {
            codes.push(1 << 4 | 1);
            for q in 0..4u32 {
                codes.push((local >> 8 * q) as u8);
            }
        }
    }
    let mut k = regs.len();
    while k > 0 {
        k -= 1;
        codes.push(push_at[k] as u8);
        codes.push(regs[k] << 4);
    }
    if fpush {
        codes.push(1);
        codes.push(5 << 4);
    }
    let n = codes.len() / 2;
    out.push(1);
    out.push(pl as u8);
    out.push(n as u8);
    out.push(
        if fp != NOREG {
            fp
        } else {
            0u8
        },
    );
    out.extend_from_slice(&codes);
    if n % 2 != 0 {
        out.push(0);
        out.push(0);
    }
}

// The layout of signature `sig` of body `b` into `out`, by Microsoft x64 (`win`; Super-C's own variant
// when `sc`) or System V.
fn classify(win: bool, sc: bool, b: &Body, sig: u32, ptr: u32, vregs: u32, out: &mut ab::CallLayout) {
    if win {
        w64::classify(b, sig, ptr, sc, out);
    } else {
        cc::classify(b, sig, ptr, vregs, out);
    }
}

// The register an `add`, `sub`, `and`, `or` or `xor` of `sz` bytes wrote last, ending at code byte `at`
// of the block at layout position `pos`: ZF tells whether it is 0 while no other instruction follows.
struct Zf {
    pub(package) reg: u8,
    pub(package) sz: u32,
    pub(package) at: u32,
    pub(package) pos: u32,
}

extend Zf as Copy {}

// A pending condition: the flags hold the result of the instruction before, which a branch or select
// right after reads instead of a value.
struct Cond {
    pub(package) inst: u32, // the instruction whose value (or flag) it stands for, NONE without one
    pub(package) cc: u32,
}

extend Cond as Copy {}

/// The x86-64 generator of one object.
pub(package) struct Gen {
    pub(package) err: String, // the first refusal, empty when every body compiled
    pkg: *const Package,
    o: *mut ob::Obj,
    ptr: u32,
    vregs: u32, // the package's `vec_regs`
    win: bool, // Microsoft x64 and COFF, else System V and ELF
    sc_self: bool, // the body takes Super-C's own convention (`sc_conv`)
    avx: bool, // AVX2: 32-byte vectors in ymm registers (`Package.vector`)
    z512: bool, // AVX-512 (F, BW, DQ, VL): 64-byte vectors in zmm registers too
    ymm: bool, // the body holds a 32-byte vector in a register: `vzeroupper` before each call and return
    yblk: Vector<bool>, // per block, whether it defines or reads a 32-byte vector (`ymm`)
    yvals: Vector<u32>, // the 32-byte vector values (indices)
    xalloc: u64,
    xfix: u64,
    valloc: u64,
    xscr: u64,
    xscr_cap: u32, // the values `xscr` may hold at a time
    xhome: u64, // the body's caller-saved homes: `xscr`, with rax, rcx and rdx in a leaf that allows them
    vscr: u64,
    vfix: u64, // the callee-saved xmm registers a value may hold for its whole range (Microsoft x64)
    vs0: u8, // the vector scratch registers
    vs1: u8,
    // ---- per body ----
    bp: *const Body,
    lv: lv::Live,
    va: Vector<Va>,
    split_at: usize,
    split_off: Vector<i32>, // per split value, its stack home, reserved before emission
    c: x::Code,
    owner: Vector<u32>, // per register number, the value index it holds, NONE
    /// Per register number, the parameter of a block after a loop that shares it with the loop's parameter
    /// (`lv::Live::share`): it holds the register on when the value that holds it now (the loop's
    /// parameter, or the step `def_step` defines in its register) is released. NONE else.
    heir: Vector<u32>,
    held: u64, // a bit per register whose `owner` is a value
    clob: u64, // the caller-saved registers the current call writes: all, or an intrinsic's
    lock: u64, // registers the current instruction reads or writes
    tmps: u64, // registers the current instruction took as temporaries
    fixed_busy: u64,
    // The registers of the aggregate parameters a call takes as they arrive (`pass_parts`), held until it;
    // per part of the body's layout, the register that holds it then (`vacate` may move one), NOREG else.
    pin: u64,
    pin_reg: Vector<u8>,
    csr: u64, // callee-saved registers the body uses
    rows: Vector<u64>, // with debug information, per change of location: its code byte << 32 | its `lines` index
    rstore: Vector<u32>, // per instruction, 1 + the result part a store moves into its register (`ret_stores`), else 0
    rload: Vector<u32>, // per call, the loads after it its result's registers give (`res_relays`)
    suse: Vector<u32>, // per slot, the uses of its addresses (`place::slot_uses`)
    pos: u32, // the layout position of the block being compiled
    cur: u32, // the instruction being compiled
    called: bool, // the body's code calls
    taken: Vector<u64>, // the loads of a register-passed aggregate that take its registers (`parts_taken`): part << 32 | load
    csave: Vector<(u8, i64)>, // the scratch homes saved around a rare call (`save_scratch`)
    fused: u32, // the last instruction an earlier one did (`rmw`), NONE
    cmp_at: u32, // the code byte the last compare starts at (`reflag`), NONE
    // The operands of the last plain compare and the code length up to which its flags hold (past only a
    // `setcc` and `movzx` of its value), NONE: a compare of the same values there sets nothing.
    held_a: Value,
    held_b: Value,
    held_end: u32,
    // The register `compare` defined for the value it sets (NOREG: none), and whether it zeroed it before
    // the compare (not an operand's), so `setcc` needs no extension after.
    zeroed: u8,
    zx: bool,
    raw: bool, // the next `cond_value` sets its byte alone (`bytes_only`)
    // Shrink-wrapping (System V): the frame is set up on the edges into the rare blocks and taken down on
    // the edges out (`shrinkable`); the warm code, which calls nothing, keeps no value in memory and no
    // callee-saved register, has none. Whether the body is compiled so, and whether that try failed (the
    // warm code used the stack: the body is compiled again without).
    shrink: bool,
    no_shrink: bool,
    again: bool, // the next `func` compiles the body it compiled last again (`unshrunk`, `far`)
    /// The run-time copies the body's CPU-level check chooses (`dispatch_of`): per copy, its level << 32 |
    /// its body symbol, the highest first. Empty: no check.
    disp: Vector<u64>,
    disp_lv: u32, // the check's body symbol of the level byte
    disp_body: Body, // the body without the check (`func`)
    base: bool, // `func_body` compiles `disp_body`, under the local name `<name>.base`
    prot: bool, // the body has a stack canary (`lver::protected`)
    opf: u8, // the body's `lv::op_flags`
    rarec: Vector<bool>, // per instruction, a call that returns in a rare block (`call_tables`)
    cret: Vector<bool>, // per instruction, a call that returns (`clobbers`, not `dead_end`; `call_tables`)
    shared: Vector<u32>, // the block parameters that share a header parameter's slot (`back_share`)
    dying: Vector<u32>, // values whose register frees after the current instruction
    wparams: Vector<u32>, // the parameters the current terminator's edges write
    want: Vector<u8>, // per value, its request to `Live::plan`
    lconst: Vector<bool>, // per instruction, a constant a loop keeps in a register (`Live::loop_consts`)
    pheld: Vector<bool>, // per entry parameter, an aggregate whose memory the frame holds (`frame_escapes`)
    vmem: Vector<bool>, // per value, a vector some instruction reads or writes in memory (`vec_homes`)
    vreg: Vector<bool>, // per instruction, one on vectors in xmm registers alone (`vec_homes`)
    ends: Vector<u32>, // values by the position their range ends at (CSR, `ends_at`)
    ends_at: Vector<u32>,
    cpre: Vector<u32>, // per instruction index, the calls that return before it (`call_tables`)
    cpos: Vector<u32>, // per layout position, the blocks before it that hold one
    vpre: Vector<u32>, // `cpre` and `cpos` without the intrinsics, which write no vector scratch home
    vpos: Vector<u32>,
    cond: Cond, // the flags the instruction just compiled left for the next one
    pend: Cond, // the flags the instruction being compiled may read
    keep_flags: bool, // the flags hold a condition the current instruction reads later: no xor zeroing
    zf: Zf,
    // Frame.
    out_size: u32,
    slot_off: Vector<u32>,
    spill_base: u32,
    spill_top: u32,
    free_slots: Vector<u64>, // size << 32 | offset of a released spill slot
    max_align: u32,
    // The base of the incoming frame (the stack arguments, the return address): rbp, or without a frame
    // pointer `x::IN`, rsp plus the frame's size.
    fb: u8,
    sret_off: i64, // the slot of rdi for a result in memory, -1 when none
    /// The result's pointer stays in the register it arrives in (`kept_sret`), which no value takes
    /// (`resv`): a body that calls nothing. `sret_lost`: an instruction needed that register.
    sret_keep: bool,
    sret_lost: bool,
    no_keep: bool, // `kept_sret` failed: the pointer in its slot
    resv: u64, // registers no value nor temporary takes
    canary: i64, // the stack canary's slot above the LIR slots, -1 when none
    save_off: i64, // a variadic body's register save area, -1 when none
    // Labels.
    /// The parameters of the late edges' targets with their homes as each target starts: value index, home
    /// (`lv::Live::late`); their stubs move into those homes after the ranges ended.
    late_va: Vector<(u32, Va)>,
    stubs_out: bool, // the late edges' stubs are in the code
    blk_at: Vector<u32>, // per block, its first byte, NONE before it is compiled
    fix: Vector<u64>, // displacement field << 32 | block: a branch to patch
    epi: Vector<u32>, // jumps to the epilogue (their displacement fields)
    stop: u32, // the end of the last terminator that does not fall through (a panic, a trap), NONE before one
    // The sibling calls (`sibling`): each one's jump's displacement field << 32 | its callee's object
    // symbol (NONE: the callee in r11); whether the body may make them; the return they replace.
    tails: Vector<u64>,
    tail_ok: bool,
    tail_ret: u32,
    // The remainder the division before it computed (`int_op`) and the product it reads, NONE for none.
    div_pair: u32,
    div_mul: u32,
    // The half of a 64-bit product whose other half's `mul` gave it (`twin_product`), NONE for none.
    mul_twin: u32,
    // The stores `zero_run` wrote with the first of their run: instructions `zero_from` to `zero_end` (the
    // layout need not visit blocks in instruction order).
    zero_from: u32,
    zero_end: u32,
    rels: Vector<CRel>,
    kcon: Vector<(u32, u32, u32)>, // the body's read-only constants: first word in `kwords`, words, symbol
    kwords: Vector<u64>, // the words of `kcon`'s constants (`const_sym`)
    osym: Vector<u32>, // per package symbol, its object symbol in this generator's object (NONE until used)
    // Calls.
    lay: ab::CallLayout,
    // Per symbol of the body at hand, its intrinsic's instructions (`intrin::of_symbols`); per signature
    // and convention a call of it takes, its layout (`call_layout`: `lays[q]` for `lay_sig[q]`, the
    // signature | `sc_conv` << 32, the first `nlay`).
    itpl: Vector<str<'static>>,
    lays: Vector<ab::CallLayout>,
    lay_sig: Vector<u64>,
    self_lay: ab::CallLayout,
    uses: Vector<Value>,
    mv: Vector<Mv>,
    local: bool, // the function compiling is a local copy
    cs: ob::CStrs, // the object's C strings
}

extend Gen {
    pub(package) fn new(pkg: &Package, o: &mut ob::Obj, win: bool) Gen {
        let mut owner = Vector::<u32>::with_capacity(32);
        for _ in 0..32 {
            owner.push(NONE);
        }
        return Gen {
            err: String::new(),
            pkg: pkg,
            o: o,
            ptr: pkg.ptr_bytes,
            vregs: pkg.vec_regs,
            win: win,
            sc_self: false,
            avx: pkg.vector >= 32,
            z512: pkg.vector == 64,
            ymm: false,
            yblk: Vector::<bool>::new(),
            yvals: Vector::<u32>::new(),
            xalloc: if win {
                XALLOC_WIN
            } else {
                XALLOC_SYSV
            },
            xfix: if win {
                XFIX_WIN
            } else {
                XFIX_SYSV
            },
            valloc: if win {
                VALLOC_WIN
            } else {
                VALLOC_SYSV
            },
            xscr: if win {
                XSCR_WIN
            } else {
                XSCR_SYSV
            },
            xscr_cap: if win {
                1
            } else {
                2
            },
            xhome: 0,
            vscr: if win {
                0
            } else {
                VSCR_SYSV
            },
            vfix: if win {
                0xFF000000
            } else {
                0
            },
            vs0: if win {
                V0 + 4
            } else {
                V0 + 14
            },
            vs1: if win {
                V0 + 5
            } else {
                V0 + 15
            },
            bp: null,
            lv: lv::Live::new(),
            va: Vector::<Va>::new(),
            split_at: 0,
            split_off: Vector::<i32>::new(),
            c: x::Code::new(),
            owner: owner,
            heir: Vector::<u32>::new(),
            held: 0,
            clob: ~0u64,
            lock: 0,
            tmps: 0,
            fixed_busy: 0,
            pin: 0,
            pin_reg: Vector::<u8>::new(),
            csr: 0,
            rows: Vector::<u64>::new(),
            rstore: Vector::<u32>::new(),
            rload: Vector::<u32>::new(),
            suse: Vector::<u32>::new(),
            pos: 0,
            cur: 0,
            called: false,
            taken: Vector::<u64>::new(),
            csave: Vector::<(u8, i64)>::new(),
            fused: NONE,
            cmp_at: NONE,
            held_a: VNONE,
            held_b: VNONE,
            held_end: NONE,
            zeroed: NOREG,
            zx: false,
            raw: false,
            shrink: false,
            no_shrink: false,
            again: false,
            disp: Vector::<u64>::new(),
            disp_lv: 0,
            disp_body: Body::new(),
            base: false,
            prot: false,
            opf: 0,
            rarec: Vector::<bool>::new(),
            cret: Vector::<bool>::new(),
            shared: Vector::<u32>::new(),
            dying: Vector::<u32>::new(),
            wparams: Vector::<u32>::new(),
            want: Vector::<u8>::new(),
            lconst: Vector::<bool>::new(),
            pheld: Vector::<bool>::new(),
            vmem: Vector::<bool>::new(),
            vreg: Vector::<bool>::new(),
            ends: Vector::<u32>::new(),
            ends_at: Vector::<u32>::new(),
            cpre: Vector::<u32>::new(),
            cpos: Vector::<u32>::new(),
            vpre: Vector::<u32>::new(),
            vpos: Vector::<u32>::new(),
            cond: Cond { inst: NONE, cc: 0 },
            pend: Cond { inst: NONE, cc: 0 },
            keep_flags: false,
            zf: Zf { reg: NOREG, sz: 0, at: NONE, pos: NONE },
            out_size: 0,
            slot_off: Vector::<u32>::new(),
            spill_base: 0,
            spill_top: 0,
            free_slots: Vector::<u64>::new(),
            max_align: 16,
            fb: x::RBP,
            sret_off: -1,
            sret_keep: false,
            sret_lost: false,
            no_keep: false,
            resv: 0,
            canary: -1,
            save_off: -1,
            late_va: Vector::<(u32, Va)>::new(),
            stubs_out: false,
            blk_at: Vector::<u32>::new(),
            fix: Vector::<u64>::new(),
            epi: Vector::<u32>::new(),
            stop: NONE,
            tails: Vector::<u64>::new(),
            tail_ok: false,
            tail_ret: NONE,
            div_pair: NONE,
            div_mul: NONE,
            mul_twin: NONE,
            zero_from: 0,
            zero_end: 0,
            rels: Vector::<CRel>::new(),
            kcon: Vector::<(u32, u32, u32)>::new(),
            kwords: Vector::<u64>::new(),
            osym: Vector::<u32>::new(),
            lay: ab::CallLayout::new(),
            itpl: Vector::<str<'static>>::new(),
            lays: Vector::<ab::CallLayout>::new(),
            lay_sig: Vector::<u64>::new(),
            self_lay: ab::CallLayout::new(),
            uses: Vector::<Value>::new(),
            mv: Vector::<Mv>::new(),
            local: false,
            cs: ob::CStrs::new(),
        };
    }

    // The body being compiled and the object: both outlive the generator's borrows.
    const fn b(self: &Self) &'static Body {
        return bref(self.bp);
    }

    const fn obj(self: &Self) &'static mut ob::Obj {
        return oref(self.o);
    }

    fn refuse(self: &mut Self, why: str) bool {
        if self.err.len() == 0 {
            self.err.push_str(why);
        }
        return false;
    }

    // ---- Values ----

    // The value index of `v`.
    const fn vx(self: &Self, v: Value) u32 {
        return self.lv.vix(self.b(), v);
    }

    // The type of value `v`.
    const fn vt(self: &Self, v: Value) u8 {
        return self.b().type_of(v);
    }

    // Whether memory value type `t` may be in a vector register: `in_vreg`, or with AVX2 a vector of 32
    // bytes in a ymm register, with AVX-512 one of 64 in a zmm register. Only the instructions with 256-
    // and 512-bit forms read this; the others take such a vector from its home.
    const fn in_reg(self: &Self, t: u8) bool {
        return in_vreg(t) || is_vec(t) && (self.avx && type_bytes(t, 8) == 32 || self.z512 && type_bytes(t, 8) == 64);
    }

    // Whether `v` is an instruction value the generator recomputes at each use.
    // A local-exec thread-local address (`tls_local`) too: two instructions from the thread pointer, no
    // call, so no register or slot holds it.
    const fn remat_inst(self: &Self, v: Value) bool {
        if lv::remat_inst(unsafe &*self.pkg, self.b(), v) {
            return true;
        }
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE {
            return false;
        }
        let t = self.b().insts[v as usize];
        return t.op == O_SYMADDR && self.tls_sym(t.a) && !self.win && self.tls_local(t.a);
    }

    // Whether body symbol `s` is a thread-local variable.
    const fn tls_sym(self: &Self, s: u32) bool {
        return lv::tls_sym(unsafe &*self.pkg, self.b(), s);
    }

    // Whether instruction `t` is the address of a thread-local variable that calls `__tls_get_addr`
    // (`tls_addr`): one of a shared library or another object's, on Linux.
    const fn tls_call(self: &Self, t: Inst) bool {
        return t.op == O_SYMADDR && self.tls_sym(t.a) && !self.win && !self.tls_local(t.a);
    }

    // Whether thread-local body symbol `s` is at a fixed offset from the thread pointer the link sets
    // (local-exec): one the package defines, in an executable.
    const fn tls_local(self: &Self, s: u32) bool {
        let p = unsafe &*self.pkg;
        return !p.pic && !p.syms[self.b().syms[s as usize] as usize].ext;
    }

    // Whether `v` is an integer constant; its bits in `out`.
    const fn const_of(self: &Self, v: Value, out: &mut u64) bool {
        return lv::const_of(self.b(), v, out);
    }

    // Whether `v` is an integer constant that a sign-extended 32-bit immediate holds at `bits` bits;
    // the immediate in `out`.
    const fn imm32_of(self: &Self, v: Value, bits: u32, out: &mut i32) bool {
        let mut k: u64 = 0;
        if !self.const_of(v, &mut k) {
            return false;
        }
        let s = lp_sext(k, bits);
        if s < -2147483648 || s > 2147483647 {
            return false;
        }
        *out = s as i32;
        return true;
    }

    // ---- Registers ----

    // A free register of file `vreg`, evicting another value's when none is.
    fn alloc(self: &mut Self, vreg: bool) u8 {
        let set = if vreg {
            self.valloc
        } else {
            self.xalloc
        };
        let open = set & ~(self.lock | self.tmps | self.fixed_busy | self.resv) & 0xFFFFFFFFu64;
        // A vector value takes xmm8 and up first under System V: no argument and no intrinsic's template
        // uses them (under Microsoft x64 they are callee-saved).
        let high = open & ~self.held & ~(0xFFu64 << V0 as u64);
        if vreg && !self.win && high != 0 {
            return high.trailing_zeros() as u8;
        }
        if (open & ~self.held) != 0 {
            let r = (open & ~self.held).trailing_zeros() as u32;
            return self.taken(r as u8);
        }
        // In a loop, a callee-saved register that holds nothing, which the prologue saves once, before an
        // eviction, which may store and reload at each iteration.
        let blk = self.lv.order[self.pos as usize] as usize;
        if !vreg && self.lv.inner[blk] != NONE && !self.lv.rare[blk] {
            for r in 0..16u32 {
                if self.fixed_free(r as u8) && (self.held & bit(r as u8)) == 0 {
                    self.csr |= bit(r as u8);
                    return r as u8;
                }
            }
        }
        let busy = open & self.held;
        if busy != 0 {
            let r = self.cheapest(busy);
            self.evict(r);
            return self.taken(r);
        }
        // Past the caller-saved ones: a callee-saved register no loop value holds, which the prologue
        // then saves (an operation that reads 8 registers, a masked store's).
        for r in 0..16u32 {
            if !vreg && self.fixed_free(r as u8) {
                self.evict(r as u8);
                self.csr |= bit(r as u8);
                return r as u8;
            }
        }
        assert(false, "x64gen: every register is locked");
        return 0;
    }

    // Register `r`, which `alloc` takes: a callee-saved vector register (Microsoft x64) the prologue
    // then saves.
    const fn taken(self: &mut Self, r: u8) u8 {
        if self.win {
            self.csr |= VSAVE_WIN & bit(r);
        }
        return r;
    }

    // Integer argument register `k` of the calling convention.
    const fn arg(self: &Self, k: u32) u8 {
        if self.win {
            return w64::gp_arg(k);
        }
        return cc::gp_arg(k);
    }

    // Free register `r`: its value moves to its home first when the home lacks it.
    fn evict(self: &mut Self, r: u8) {
        let x = self.owner[r as usize];
        if x == NONE {
            return;
        }
        let va = self.va[x as usize];
        if va.home == H_FIXED {
            return;
        }
        if va.dirty && (self.live_on(x) || self.read_now(x)) {
            self.spill(x);
        }
        self.va.index_mut(x as usize).reg = NOREG;
        self.va.index_mut(x as usize).dirty = false;
        self.set_owner(r, NONE);
    }

    // Whether evicting register `r`'s value stores it (`evict`).
    fn stores(self: &Self, r: u8) bool {
        let x = self.owner[r as usize];
        return x != NONE && self.va[x as usize].home != H_FIXED && self.va[x as usize].dirty && (self.live_on(x) || self.read_now(
            x,
        ));
    }

    // Prefer no store, then the value whose next use is farthest away.
    fn cheapest(self: &Self, set: u64) u8 {
        let mut best = NOREG;
        let mut score: u64 = 0;
        let mut left = set;
        while left != 0 {
            let r = left.trailing_zeros() as u8;
            left &= left - 1;
            let x = self.owner[r as usize];
            let cost = (!self.stores(r)) as u64 << 32 | self.lv.next[x as usize] as u64;
            if best == NOREG || cost > score {
                best = r;
                score = cost;
            }
        }
        return best;
    }

    // Whether instruction `i` reads value `v`, through the operands that fold into it too (`lv::uses_of`).
    fn reads(self: &Self, i: u32, v: Value) bool {
        let us = self.lv.uses_of(i);
        for k in 0..us.len() {
            if us[k] == v {
                return true;
            }
        }
        return false;
    }

    // Whether the current instruction reads value index `x`.
    const fn read_now(self: &Self, x: u32) bool {
        for k in 0..self.uses.len() {
            if self.vx(self.uses[k]) == x {
                return true;
            }
        }
        return false;
    }

    // Free register `r` for the current instruction's own use (a shift count, a division): a value there
    // that lives on or that the instruction reads moves to another register, and `r` is locked.
    fn vacate(self: &mut Self, r: u8) {
        self.lock |= bit(r);
        self.sret_lost = self.sret_lost || (self.resv & bit(r)) != 0;
        if (self.pin & bit(r)) != 0 {
            // A parameter's part a call takes as it arrived (`pass_parts`) moves to another held register.
            let r2 = self.alloc(r >= V0);
            self.c.mov_rr(8, r2, r);
            self.pin = self.pin & ~bit(r) | bit(r2);
            self.fixed_busy = self.fixed_busy & ~bit(r) | bit(r2);
            for p in 0..self.pin_reg.len() {
                if self.pin_reg[p] == r {
                    self.pin_reg[p] = r2;
                }
            }
            return;
        }
        let x = self.owner[r as usize];
        if x == NONE {
            return;
        }
        assert(self.va[x as usize].home != H_FIXED, "x64gen: a fixed home in a caller-saved register");
        if self.live_on(x) || self.read_now(x) {
            let r2 = self.alloc(r >= V0);
            self.move_reg(self.xty(x), r2, r);
            self.set_owner(r2, x);
            self.va.index_mut(x as usize).reg = r2;
            self.lock |= bit(r2);
        } else {
            self.va.index_mut(x as usize).reg = NOREG;
            self.va.index_mut(x as usize).dirty = false;
        }
        self.set_owner(r, NONE);
    }

    // Whether value index `x` is used after the current instruction.
    const fn live_on(self: &Self, x: u32) bool {
        return self.lv.uses[x as usize] != 0 || self.lv.end[x as usize] > self.pos;
    }
    // Register `r` holds value `x` from now on (NONE: no value).
    const fn set_owner(self: &mut Self, r: u8, x: u32) {
        self.owner[r as usize] = x;
        if x == NONE {
            self.held &= ~bit(r);
        } else {
            self.held |= bit(r);
        }
    }

    // Store value index `x`'s register to its home, giving it a stack slot first.
    fn spill(self: &mut Self, x: u32) {
        let va = self.va[x as usize];
        if va.reg == NOREG || !va.dirty {
            return;
        }
        let t = self.xty(x);
        let n = type_bytes(t, self.ptr);
        if va.home == H_NONE {
            let off = self.slot_alloc(n, type_align(t, self.ptr));
            self.va.index_mut(x as usize).home = H_SLOT;
            self.va.index_mut(x as usize).off = off as i32;
        }
        let off = self.va[x as usize].off;
        self.st(t, va.reg, x::at(x::RSP, off));
        self.va.index_mut(x as usize).dirty = false;
    }

    // The type of value index `x`.
    const fn xty(self: &Self, x: u32) u8 {
        return lv::xty(self.b(), x);
    }

    // A temporary register of file `vreg` for the current instruction.
    fn tmp(self: &mut Self, vreg: bool) u8 {
        let r = self.alloc(vreg);
        self.tmps |= bit(r);
        return r;
    }

    // Bind register `r` to value index `x` as its newest copy.
    fn bind(self: &mut Self, x: u32, r: u8) {
        self.set_owner(r, x);
        self.lock |= bit(r);
        let va = self.va.index_mut(x as usize);
        va.reg = r;
        va.dirty = va.home != H_FIXED;
        va.clean = false;
    }

    // A register for the result of value `v`: its fixed register when it has one, else the one the next
    // instruction reads it in (`next_reg`), else a free one.
    fn def(self: &mut Self, v: Value) u8 {
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.home == H_FIXED {
            self.lock |= bit(va.reg);
            self.va.index_mut(x as usize).clean = false;
            return va.reg;
        }
        let vr = is_v(self.vt(v)) || self.in_reg(self.vt(v));
        let r = self.take_home(x, vr, NOREG);
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let n = self.next_reg(v);
        if n != NOREG && (self.fixed_busy & bit(n)) != 0 {
            // A jump's parameter home (`jump_reg`): `v` holds it until the jump, which moves nothing; the
            // parameter keeps the register's ownership.
            self.lock |= bit(n);
            let va = self.va.index_mut(x as usize);
            va.reg = n;
            va.dirty = true;
            va.clean = false;
            return n;
        }
        if n != NOREG {
            self.bind(x, n);
            return n;
        }
        let r2 = self.alloc(vr);
        self.bind(x, r2);
        return r2;
    }

    // The register of the result part that the run of result stores before the `ret` of value `v`'s block
    // moves `v` into (`rstore`), when that store is `v`'s only use: `v` is there for it. NOREG else.
    fn ret_part(self: &Self, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 || self.rstore.len() == 0 || self.lv.uses[v as usize] != 1 {
            return NOREG;
        }
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[v as usize] as usize];
        let end = bk.start + bk.len - 1;
        if b.insts[end as usize].op != O_RET {
            return NOREG;
        }
        // The run, back from the `ret`: at most the block's instructions.
        let mut j = end;
        while j > v + 1 && self.rstore[j as usize - 1] != 0 {
            j -= 1;
            if b.insts[j as usize].b == v {
                let pa = self.self_lay.parts[(self.self_lay.ret.p0 + self.rstore[j as usize] - 1) as usize];
                return pa.reg + if pa.v {
                    V0
                } else {
                    0
                };
            }
        }
        return NOREG;
    }

    // The home register of the parameter jump `t` passes `v` to (once), when the jump is no back edge, so
    // nothing reads that parameter's earlier value here (`def_step` takes the back edges): `v` defined
    // there needs no move. NOREG else.
    fn jump_reg(self: &Self, b: &Body, t: Inst, v: Value) u8 {
        let tg = b.edge_target(t.a);
        let mut h = self.lv.inner[self.lv.def_blk[v as usize] as usize];
        // Each step leaves one loop: at most one per block.
        for _ in 0..b.blocks.len() {
            if h == NONE {
                break;
            }
            if h == tg {
                return NOREG;
            }
            h = self.lv.parent[h as usize];
        }
        let tb = b.blocks[tg as usize];
        let mut r = NOREG;
        for k in 0..b.edge_nargs(t.a) {
            if b.edge_arg(t.a, k) != v {
                continue;
            }
            let pva = self.va[b.insts.len() + (tb.param_start + k) as usize];
            if r != NOREG || pva.home != H_FIXED {
                return NOREG;
            }
            r = pva.reg;
        }
        if r == NOREG || ((self.lock | self.tmps) & bit(r)) != 0 {
            return NOREG;
        }
        return r;
    }

    // Whether commutative instruction `i` should write over its second operand `b` (in `rb`), not its first
    // (in `ra`): `b` dies here, and the return or call after, or the result part the stores before the
    // return move it into (`ret_part`), or the return after a chain of in-place operations (`chain_ret`),
    // takes `i` in `rb` (`next_reg`, `ret_want`; a jump's would place a parameter's home, which may take
    // `rb`).
    fn swaps(self: &mut Self, i: u32, b: Value, ra: u8, rb: u8) bool {
        let xb = self.vx(b);
        let bd = self.b();
        let bk = bd.blocks[self.lv.def_blk[i as usize] as usize];
        let nx = if i + 1 < bk.start + bk.len {
            bd.insts[i as usize + 1].op
        } else {
            O_JMP
        };
        if nx != O_RET && nx != O_CALL && nx != O_CALLIND && self.ret_part(i) == NOREG && !self.chain_ret(bd, bk, i) || ra == rb || self.owner[rb as usize] != xb || self.lv.uses[xb as usize] != 0 || self.lv.end[xb as usize] != self.pos || self.va[xb as usize].home == H_FIXED {
            return false;
        }
        // `b` holds `rb` until the instruction writes it.
        let (held, lock) = (self.held, self.lock);
        self.held &= ~bit(rb);
        self.lock &= ~bit(rb);
        let n = self.next_reg(i);
        self.held = held;
        self.lock = lock;
        return n == rb || self.ret_want(i) == rb;
    }

    // A register for the result of value `v` that holds operand `a`'s bits (in `ra`) for a two-operand
    // instruction: `ra` itself when `a` dies here and `v` takes no fixed home, else a copy of it.
    fn def_from(self: &mut Self, v: Value, a: Value, ra: u8) u8 {
        let rd = self.def_over(v, a, ra);
        if rd != ra {
            self.move_reg(self.vt(v), rd, ra);
        }
        return rd;
    }

    // Product `i` of operand `a` (in `ra`) by constant `k` in one-cycle instructions where they take less
    // time than `imul`'s three cycles (LLVM's x86 lowering): an address (`lea`) by c of 3, 5 or 9; one then
    // a shift by c * 2^s; two by c * d (d also of 3, 5 or 9) and by 1 + c * 2^j (j of 1 to 3); a shift and
    // a sum or difference by 2^s + 1 and 2^s - 1; a negation after the first by -c and after a shift by
    // -2^s. Whether it did.
    fn mul_const(self: &mut Self, i: u32, a: Value, sz: u32, ra: u8, k: i64) bool {
        let tz = if k > 0 {
            k.trailing_zeros() as u32
        } else {
            0u32
        };
        let odd = k >> tz as i64;
        if k > 0 && lea_factor(odd) {
            let rd = self.def(i);
            self.lea_to(sz, rd, x::ix(ra, ra, (odd - 1).trailing_zeros() as u8, 0));
            if tz != 0 {
                self.c.shift_ri(x::SHL, sz, rd, tz);
            }
            return true;
        }
        if k > 0 {
            for q in 0..3u32 {
                let c: i64 = if q == 0 {
                    3
                } else if q == 1 {
                    5
                } else {
                    9
                };
                let sc = (c - 1).trailing_zeros() as u8;
                if k % c == 0 && lea_factor(k / c) {
                    let rd = self.def(i);
                    self.lea_to(sz, rd, x::ix(ra, ra, sc, 0));
                    self.lea_to(sz, rd, x::ix(rd, rd, (k / c - 1).trailing_zeros() as u8, 0));
                    return true;
                }
                for j in 1..4u8 {
                    if k == 1 + (c << j as i64) {
                        // c times the operand in the result's register, unless that is the operand's.
                        let rd = self.def(i);
                        let s = if rd == ra {
                            self.tmp(false)
                        } else {
                            rd
                        };
                        self.lea_to(sz, s, x::ix(ra, ra, sc, 0));
                        self.lea_to(sz, rd, x::ix(ra, s, j, 0));
                        return true;
                    }
                }
            }
        }
        // 2^s + 1 past 9, 2^s - 1 from 7: the operand shifted, then it added or subtracted.
        let plus = k > 9 && (k - 1 & k - 2) == 0;
        if plus || k >= 7 && (k & k + 1) == 0 {
            let sh = if plus {
                (k - 1).trailing_zeros() as u32
            } else {
                (k + 1).trailing_zeros() as u32
            };
            let op = if plus {
                x::ADD
            } else {
                x::SUB
            };
            let rd = self.def(i);
            let src = if rd == ra {
                let s = self.tmp(false);
                self.c.mov_rr(sz, s, ra);
                s
            } else {
                self.c.mov_rr(sz, rd, ra);
                ra
            };
            self.c.shift_ri(x::SHL, sz, rd, sh);
            self.c.alu_rr(op, sz, rd, src);
            return true;
        }
        if k < 0 && k > -2147483648 {
            let n = -k;
            if lea_factor(n) {
                let rd = self.def(i);
                self.lea_to(sz, rd, x::ix(ra, ra, (n - 1).trailing_zeros() as u8, 0));
                self.c.unary(x::NEG, sz, rd);
                return true;
            }
            if n >= 2 && (n & n - 1) == 0 {
                let rd = self.def_from(i, a, ra);
                self.c.shift_ri(x::SHL, sz, rd, n.trailing_zeros() as u32);
                self.c.unary(x::NEG, sz, rd);
                return true;
            }
        }
        return false;
    }

    // Whether value `v` is an instruction that folds into its use (`lv::FOLD_*`).
    const fn folded(self: &Self, v: Value) bool {
        return v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize];
    }

    // `rd` = the address `m` computes (`lea`); 32 bits of it for a value narrower than 64 (`sz`), whose
    // upper bits nothing reads.
    fn lea_to(self: &mut Self, sz: u32, rd: u8, m: x::Mem) {
        self.c.rm(0, 0x8D, sz == 8, rd, m, false);
    }

    // Sum `i` as one `lea` of address `f` (`lv::lea_of`; an index alone shifted by at most 1).
    fn lea_sum(self: &mut Self, i: u32, sz: u32, f: lv::Lea) {
        let rb = if f.base == VNONE {
            NOREG
        } else {
            self.reg(f.base)
        };
        let ri = if f.index == VNONE {
            NOREG
        } else {
            self.reg(f.index)
        };
        // The register a return right after wants, when an operand dying here holds it: the `lea` reads
        // it before it writes.
        let want = self.ret_want(i);
        let rd = if want != NOREG && want == rb && self.dies_here(f.base) {
            self.def_over(i, f.base, rb)
        } else if want != NOREG && want == ri && self.dies_here(f.index) {
            self.def_over(i, f.index, ri)
        } else {
            self.def(i)
        };
        let d = f.disp as i32;
        let m = if ri == NOREG {
            x::at(rb, d)
        } else if rb == NOREG && f.sh == 0 {
            x::at(ri, d)
        } else if rb == NOREG {
            x::ix(ri, ri, 0, d)
        } else {
            x::ix(rb, ri, f.sh as u8, d)
        };
        self.lea_to(sz, rd, m);
    }

    // The register `def_from` gives value `v` over operand `a` (in `ra`), without the copy of `a` into it:
    // `ra` when `v` may take it.
    fn def_over(self: &mut Self, v: Value, a: Value, ra: u8) u8 {
        let x = self.vx(v);
        let xa = self.vx(a);
        let t = self.vt(v);
        let sr = self.def_shared(v, a);
        if sr != NOREG {
            return sr;
        }
        let fixed = self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE;
        // A callee-saved register `alloc` gave a loop's temporary (saved, no home) counts as a caller-saved one.
        let temps = self.xalloc | self.valloc | self.xfix & self.csr & ~self.fixed_busy;
        if !fixed && (temps & bit(ra)) != 0 && (is_v(t) || is_vec(t)) == ra >= V0 {
            let own = self.owner[ra as usize];
            let temp = own == NONE && (self.tmps & bit(ra)) != 0;
            let dies = own == xa && self.lv.uses[xa as usize] == 0 && self.lv.end[xa as usize] == self.pos;
            if temp || dies {
                if dies {
                    // A register home (a caller-saved one, which `take_scratch` would evict a value from)
                    // frees too.
                    if self.va[xa as usize].home == H_FIXED {
                        self.fixed_busy &= ~bit(ra);
                    }
                    self.va.index_mut(xa as usize).reg = NOREG;
                    self.va.index_mut(xa as usize).dirty = false;
                }
                self.tmps &= ~bit(ra);
                self.bind(x, ra);
                return ra;
            }
        }
        return self.def(v);
    }

    // The register `step_reg` or `fwd_reg` gives value `v`, which reads `a` before it writes, taken for
    // `v`: the edge's move vanishes. NOREG when neither gives one.
    fn def_shared(self: &mut Self, v: Value, a: Value) u8 {
        // A vector an instruction reads in memory (`vec_homes`) takes a slot, not the register.
        if self.vmem[self.vx(v) as usize] {
            return NOREG;
        }
        let mut sr = self.step_reg(v, a);
        if sr == NOREG {
            sr = self.fwd_reg(v, a);
        }
        if sr == NOREG {
            return NOREG;
        }
        // The parameter keeps the register, which its release frees; a `v` that outlives its block takes
        // it over as its home.
        let x = self.vx(v);
        let past = self.lv.end[x as usize] != self.pos;
        self.lock |= bit(sr);
        if past {
            self.set_owner(sr, x);
        }
        let w = self.va.index_mut(x as usize);
        w.reg = sr;
        w.dirty = false;
        w.clean = false;
        if past {
            w.home = H_FIXED;
        }
        return sr;
    }

    // `def` of value `v`, which reads `a` before it writes: `def_shared`'s register when it gives one.
    fn def_pass(self: &mut Self, v: Value, a: Value) u8 {
        let r = self.def_shared(v, a);
        return if r == NOREG {
            self.def(v)
        } else {
            r
        };
    }

    // The register the instruction after instruction `v` in its block takes `v` in, when that is `v`'s
    // only use: a call's scalar register argument, or the result; or the result part a store before the
    // return moves it into (`ret_part`); so `v` is there for it. NOREG when not, or when a value or the
    // current instruction holds that register.
    fn next_reg(self: &mut Self, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 {
            return NOREG;
        }
        // A result part the return takes it in.
        let rp = self.ret_part(v);
        if rp != NOREG {
            return if ((self.held | self.lock | self.tmps | self.fixed_busy) & bit(rp)) == 0 && ((self.xalloc | self.valloc) & bit(
                rp,
            )) != 0 {
                rp
            } else {
                NOREG
            };
        }
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[v as usize] as usize];
        let bits = type_bits(self.vt(v), self.ptr);
        // A scalar float takes an xmm register, and a vector one whole (`whole_vreg`).
        let vv = in_vreg(self.vt(v));
        let fv = self.vt(v) == T_F32 || self.vt(v) == T_F64 || vv;
        let fb: u8 = if fv {
            V0
        } else {
            0
        };
        // A zero extension of `v` alone that the block returns next extends it in the return's register; a
        // narrow value returned next goes there as it is (the caller extends it).
        let ext = zext_returned(b, bk, v);
        let ret = v + 1 < bk.start + bk.len && b.insts[v as usize + 1].op == O_RET;
        if v + 1 >= bk.start + bk.len || self.lv.uses[v as usize] != 1 || self.lv.end[v as usize] != self.pos || !is_int(
            self.vt(v),
        ) && self.vt(v) != T_PTR && !fv || bits < 32 && !ext && !ret || bits > 64 && !vv || self.va[v as usize].home != H_NONE {
            return NOREG;
        }
        let t = b.insts[v as usize + 1 + ext as usize];
        let mut r = NOREG;
        // The first of a chain of in-place operations the return takes the last of (`chain_ret`): the
        // return's register.
        let chain = !ext && !fv && self.chain_ret(b, bk, v);
        if t.op == O_RET || chain {
            let rl = self.self_lay.ret;
            if (t.a == v + ext as u32 || chain) && rl.kind == ab::L_REG && rl.n == 1 && self.self_lay.parts[rl.p0 as usize].v == fv && (!vv || self.self_lay.whole_vreg(
                rl,
                self.vt(v),
            )) {
                r = self.self_lay.parts[rl.p0 as usize].reg + fb;
            }
        } else if t.op == O_CALL && self.intrinsic(t.a).len() == 0 || t.op == O_CALLIND && t.a != v {
            // Not `call_layout`: a call being compiled may define `v` (`relay_result`) and still read `lay`.
            let lay = &self.lays[self.lay_index(t)];
            let np = b.pool[t.b as usize];
            let nops = np + ((b.pool[t.b as usize + 2] & AGG) != 0) as u32;
            for k in 0..nops {
                if b.pool[(t.c + k) as usize] != v {
                    continue;
                }
                if r != NOREG || k == np || lay.locs[k as usize].kind != ab::L_REG || lay.locs[k as usize].n != 1 || (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 {
                    return NOREG;
                }
                let pa = lay.parts[lay.locs[k as usize].p0 as usize];
                if pa.v != fv || vv && !lay.whole_vreg(lay.locs[k as usize], self.vt(v)) {
                    return NOREG;
                }
                r = pa.reg + fb;
            }
        } else if t.op == O_JMP {
            // A later block's parameter takes its home here, at the first edge into it, so `v` is defined
            // there (`def_fwd` does the same).
            let tg = b.edge_target(t.a);
            if self.lv.pos[tg as usize] != NONE && self.lv.pos[tg as usize] > self.pos {
                let tb = b.blocks[tg as usize];
                for q in 0..b.edge_nargs(t.a) {
                    if b.edge_arg(t.a, q) == v {
                        self.param_home(b.insts.len() as u32 + tb.param_start + q, NOREG);
                    }
                }
            }
            return self.jump_reg(b, t, v);
        }
        if r == NOREG || ((self.held | self.lock | self.tmps | self.fixed_busy) & bit(r)) != 0 || ((self.xalloc | self.valloc) & bit(
            r,
        )) == 0 {
            return NOREG;
        }
        return r;
    }

    // Whether the instructions after `v` in block `bk`, at most CHAIN_STEPS, each read the one before as
    // their first operand alone and write over it (a 32- or 64-bit integer `add`, `sub`, `and`, `or`, `xor`,
    // or shift by a constant; or a select of it as its false side, which a `cmov` writes over), past
    // folded instructions, up to a return of the last.
    const fn chain_ret(self: &Self, b: &Body, bk: Block, v: Value) bool {
        let mut w = v;
        let end = bk.start + bk.len;
        for _ in 0..CHAIN_STEPS {
            if self.lv.count[w as usize] != 1 {
                return false;
            }
            // The next instruction that emits code here: a folded one (a select's comparison) comes later.
            let mut j = w + 1;
            while j < end && self.lv.pfold[j as usize] {
                j += 1;
            }
            if j >= end {
                return false;
            }
            let t = b.insts[j as usize];
            if t.op == O_RET {
                return w != v && t.a == w;
            }
            let mut k: u64 = 0;
            let alu = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
            let shift = (t.op == O_SHL || t.op == O_LSHR || t.op == O_ASHR) && self.const_of(t.b, &mut k);
            let bits = type_bits(t.ty, self.ptr);
            let sel = t.op == O_SELECT && t.c == w && t.b != w && t.a != w;
            if !sel && (!alu && !shift || t.a != w || t.b == w) || !is_int(t.ty) || bits != 32 && bits != 64 {
                return false;
            }
            w = j;
        }
        return false;
    }

    // The fixed register of a parameter the back edge ending instruction `v`'s block passes `v` to
    // (`Live::back_param`), when nothing in the block reads that parameter after `v`, and `v` reads it as
    // `a` alone, the operand `def_from` moves into the result first (a loop counter's step, an
    // accumulator): `v` defined there makes the edge's move vanish. The parameter's old value is dead
    // from `v` on, and the register is the parameter's over the whole loop. A `v` that outlives its block
    // (a rotated loop's exit reads it) needs the parameter's range to end in this block: it takes the
    // register over (`def_from`). Not for a `v` with a home of its own or that lives across a call (the
    // register may be caller-saved: the parameter's range need not hold the call). NOREG when not.
    fn step_reg(self: &mut Self, v: Value, a: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 {
            return NOREG;
        }
        let past = self.lv.end[v as usize] != self.pos;
        if self.va[v as usize].home != H_NONE || !past && self.fix_class(v) != FIX_NONE || self.crosses_call(
            v,
            is_v(self.vt(v)),
        ) {
            return NOREG;
        }
        let b = self.b();
        let k = self.lv.def_blk[v as usize];
        let bk = b.blocks[k as usize];
        let tm = b.insts[(bk.start + bk.len - 1) as usize];
        if self.lv.pos[k as usize] != self.pos {
            return NOREG;
        }
        let px = self.lv.back_param(b, tm, v, self.pos);
        if px == NONE {
            return NOREG;
        }
        let pv = VPARAM | px - b.insts.len() as u32;
        // `v` reads the parameter other than as `a`, maybe through an operand that folds into it.
        let other = self.reads(v, pv) && a != pv;
        if self.va[px as usize].home != H_FIXED || self.lv.end[px as usize] < self.pos || past && self.lv.end[px as usize] != self.pos || other || self.lv.reads_after(
            b,
            k,
            v,
            pv,
        ) {
            return NOREG;
        }
        return self.va[px as usize].reg;
    }

    // `step_reg` for instruction `v`, which dies in its block, whose block ends in a jump to a later block
    // passing `v` once: the register home of the parameter it passes `v` to (taken now when this is the
    // first edge into that block), when that register holds nothing, or holds the header parameter
    // `back_share` gave it, which `v` reads as `a` alone if at all and nothing after `v` reads, so the
    // jump's move vanishes. NOREG when not.
    fn fwd_reg(self: &mut Self, v: Value, a: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 || self.lv.end[v as usize] != self.pos || self.va[v as usize].home != H_NONE || self.fix_class(
            v,
        ) != FIX_NONE || self.crosses_call(v, is_v(self.vt(v))) {
            return NOREG;
        }
        let b = self.b();
        let k = self.lv.def_blk[v as usize];
        let bk = b.blocks[k as usize];
        let tm = b.insts[(bk.start + bk.len - 1) as usize];
        if self.lv.pos[k as usize] != self.pos || tm.op != O_JMP {
            return NOREG;
        }
        let j = b.edge_target(tm.a);
        if self.lv.pos[j as usize] == NONE || self.lv.pos[j as usize] <= self.pos {
            return NOREG;
        }
        let ni = b.insts.len() as u32;
        let mut x = NONE;
        for q in 0..b.edge_nargs(tm.a) {
            if b.edge_arg(tm.a, q) == v {
                if x != NONE {
                    return NOREG;
                }
                x = ni + b.blocks[j as usize].param_start + q;
            }
        }
        if x == NONE || self.xty(x) != self.vt(v) || in_mem(self.xty(x)) {
            return NOREG;
        }
        self.param_home(x, NOREG);
        let va = self.va[x as usize];
        if va.home != H_FIXED || va.reg == NOREG || (self.tmps & bit(va.reg)) != 0 {
            return NOREG;
        }
        let r = va.reg;
        let ov = self.owner[r as usize];
        if ov != x {
            if ov == NONE || ov < ni {
                return NOREG;
            }
            let pv = VPARAM | ov - ni;
            if self.reads(v, pv) && a != pv || self.lv.reads_after(b, k, v, pv) {
                return NOREG;
            }
            for q in 0..b.edge_nargs(tm.a) {
                if b.edge_arg(tm.a, q) == pv {
                    return NOREG;
                }
            }
        }
        return r;
    }

    // The register home `fix_class` gives value index `x` of file `vr`, taken (`prefer`, a register `x`
    // arrives in, when it may be its home); NOREG for none.
    fn take_home(self: &mut Self, x: u32, vr: bool, prefer: u8) u8 {
        let fc = self.fix_class(x);
        if fc == FIX_CALLEE {
            return self.take_fixed(x, vr);
        }
        if fc == FIX_SCRATCH {
            return self.take_scratch(x, vr, prefer);
        }
        return NOREG;
    }

    // Which register value index `x` holds for its whole range (`plan_homes`).
    const fn fix_class(self: &Self, x: u32) u8 {
        return self.lv.home_at(x, self.pos);
    }

    // Plan the homes (`Live::plan`) over each value's request: none in memory or rematerialized; an integer a call that
    // returns runs in the range of, a callee-saved register; one that lives past its block or a block
    // parameter, either (a flag: callee-saved only); a float that lives past its block or a block
    // parameter, an xmm register: under Microsoft x64 a callee-saved one (`vfix`), under System V, which
    // keeps no xmm register across a call, a caller-saved one when no call that returns runs in its
    // range; none for the others, which temporaries hold (an entry parameter that dies in the entry
    // block stays in the register it arrives in). A vector of 8 or 16 bytes that lives past its block or is a
    // block parameter and no instruction reads or writes in memory (`vec_homes`: a loop's accumulator, a
    // value splat before the loop) asks an xmm register the same way. The homes leave 8 integer registers
    // to one instruction (a masked store reads 8).
    fn plan_homes(self: &mut Self) {
        let b = self.b();
        let n = self.lv.end.len();
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        // The values a call reads after its argument moves (`call`: the callee of an indirect call, an
        // aggregate's address, the result's): the scratch homes are argument registers, which the moves
        // take.
        let mut late = Vector::<bool>::with_capacity(n);
        late.resize_default(n);
        for i in 0..ni {
            let t = b.insts[i];
            if t.op != O_CALL && t.op != O_CALLIND {
                continue;
            }
            if t.op == O_CALLIND {
                late[self.vx(t.a) as usize] = true;
            }
            let np = b.pool[t.b as usize];
            let rt = b.pool[t.b as usize + 2];
            for k in 0..np + ((rt & AGG) != 0) as u32 {
                if k == np || (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 {
                    late[self.vx(b.pool[(t.c + k) as usize]) as usize] = true;
                }
            }
        }
        self.lv.loop_consts(b, &mut self.lconst);
        // An integer a sign-extended 32-bit immediate holds stays an immediate.
        for x in 0..ni {
            let mut imm: i32 = 0;
            if self.lconst[x] && b.insts[x].op == O_ICONST && self.imm32_of(
                x as u32,
                type_bits(b.insts[x].ty, 8),
                &mut imm,
            ) {
                self.lconst[x] = false;
            }
        }
        // A body that calls nothing that returns (no instruction `clobbers` but one before a trap or in a
        // rare block, no thread-local address's getter: `tls_call`) and runs no system operation or
        // variadic access: every register of `xscr` may be a home at once. `bare`: not even in a rare block,
        // and no intrinsic (`calls` skips one that writes vector registers alone, but its template writes
        // xmm0..xmm3 and its arguments' registers, the bare xmm homes).
        let mut leaf = true;
        let mut bare = true;
        for x in 0..ni {
            let t = b.insts[x];
            leaf = leaf && !(self.cret[x] && !self.rarec[x]) && t.op != O_SYS && t.op != O_VASTART && t.op != O_VAARG && !self.tls_call(
                t,
            );
            bare = bare && !self.cret[x] && !(t.op == O_CALL && self.intrinsic(t.a).len() != 0);
        }
        bare = bare && leaf;
        // The registers the body's intrinsics write (`intrin_clob`): an intrinsic that writes vector
        // registers alone is no call (`calls`), so a body of them alone is bare.
        let mut iclob: u64 = 0;
        for x in 0..ni {
            let t = b.insts[x];
            if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
                iclob |= self.intrin_clob(t, self.intrinsic(t.a));
            }
        }
        // An xmm home: Microsoft x64's callee-saved ones, but in a body that calls nothing that returns
        // its caller-saved xmm0..xmm3 first (`vscr`); System V's caller-saved ones, xmm4..xmm7 too in such a
        // body. None that an intrinsic writes.
        self.vscr = if self.win && bare {
            VSCR_WIN_BARE
        } else if self.win {
            0
        } else if bare {
            VSCR_SYSV_BARE
        } else {
            VSCR_SYSV
        } & ~iclob;
        self.vec_homes();
        self.want.truncate(0);
        let vw = lv::WANT_V | if !self.win {
            lv::WANT_SCRATCH
        } else if bare {
            lv::WANT_SCRATCH | lv::WANT_CALLEE
        } else {
            lv::WANT_CALLEE
        };
        for x in 0..n {
            let t = self.xty(x as u32);
            let d = self.lv.def_blk[x];
            let mut w: u8 = 0;
            // A ymm register keeps only its low 16 bytes across a call (Microsoft x64's xmm6..xmm15).
            if self.in_reg(t) && type_bytes(t, 8) >= 8 && x < nv && !self.vmem[x] && d != NONE && self.lv.pos[d as usize] != NONE && (self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && d != 0) && (self.win && type_bytes(
                t,
                8,
            ) == 16 || !self.crosses_call(x as u32, true)) {
                w = vw;
            }
            if !in_mem(t) && d != NONE && self.lv.pos[d as usize] != NONE && !(x < ni && self.remat_inst(x as u32) && !self.lconst[x]) {
                let past = self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && x < nv && d != 0;
                let cross = x < nv && self.crosses_call(x as u32, is_v(t));
                if is_v(t) {
                    if x < nv && past && (self.win || !cross) {
                        w = vw;
                    }
                } else if cross || x >= nv && self.lv.end[x] > self.lv.pos[d as usize] {
                    w = lv::WANT_CALLEE;
                } else if past && x < nv && late[x] {
                    w = lv::WANT_CALLEE;
                } else if past && x < nv {
                    w = lv::WANT_CALLEE | lv::WANT_SCRATCH;
                }
            }
            // Shrink-wrapped, the warm code saves no callee-saved register: every home is a scratch one, which
            // the rare calls save around them, but for a value a call reads after its argument moves (none).
            if self.shrink && late[x] {
                w = 0;
            } else if self.shrink && (w & lv::WANT_CALLEE) != 0 {
                w = w & ~lv::WANT_CALLEE | lv::WANT_SCRATCH;
            }
            self.want.push(w);
        }
        let mut nd: u32 = 4;
        let mut vd: u32 = 3;
        for x in 0..ni {
            nd = nd.max(self.need(x as u32));
            vd = vd.max(self.vneed(x as u32));
        }
        // The registers held for a call that takes parameters' parts as they arrive (`pass_parts`) are not
        // there for the instructions up to it, the first that calls.
        let pins = (self.pin & self.xalloc).count_ones() as u32;
        let e = b.blocks[0];
        for i in e.start..e.start + e.len {
            if pins == 0 {
                break;
            }
            nd = nd.max(self.need(i) + pins);
            if Gen::clobbers(b, b.insts[i as usize]) {
                break;
            }
        }
        let most = self.xfix.count_ones() as u32 + self.xalloc.count_ones() as u32 - nd;
        self.xhome = self.xscr;
        if leaf {
            self.xhome |= self.homes_free(b);
        }
        let xs = if leaf {
            self.xhome.count_ones() as u32
        } else {
            self.xscr_cap
        };
        // Candidate xmm homes: Microsoft x64's callee-saved xmm8..xmm15 (`vfix`) and, calling nothing,
        // xmm0..xmm3 (`vscr`), or System V's caller-saved xmm8..xmm13, calling nothing xmm4..xmm13.
        // The joint cap leaves `vneed` registers for operands, temporaries and a separate result.
        let (vc, vs) = if self.win {
            (self.vfix.count_ones() as u32, self.vscr.count_ones() as u32)
        } else {
            (0u32, self.vscr.count_ones() as u32)
        };
        self.lv.plan(
            b,
            &self.want,
            lv::Caps {
                xc: if self.shrink {
                    0
                } else {
                    self.xfix.count_ones() as u32
                },
                xs: xs,
                xj: most,
                vc: vc,
                vs: vs,
                vj: (vc + vs).min((self.valloc | self.vfix).count_ones() as u32 - vd),
            },
        );
        for x in 0..ni {
            if self.lconst[x] && self.fix_class(x as u32) != FIX_NONE {
                self.va.index_mut(x).home = H_NONE;
            }
        }
    }

    // The integer registers instruction `i` holds at once besides the homes: its operands outside a
    // home, its temporaries and its result (`end_inst` checks it). 8 for one that reads or writes a
    // vector or an i128 (a masked store reads 8), a vector operation, inline assembly and a system
    // operation, but an operation on vectors in xmm registers alone (`vreg`); 8 for an unsigned 64-bit
    // multiplication with overflow (rax and rdx, the values moved out of them, the operands, the flag and
    // the result); 7 for a division and a high multiplication (the same but the flag); 6 for an atomic
    // operation; 5 for a shift and a select; a branch on two folded comparisons by `conj_need`; 4 for the
    // others.
    fn need(self: &mut Self, i: u32) u32 {
        let t = self.b().insts[i as usize];
        if t.op == O_BR && self.folded(t.a) && (self.b().insts[t.a as usize].op == O_AND || self.b().insts[t.a as usize].op == O_OR) {
            return self.conj_need(t);
        }
        if !self.vreg[i as usize] {
            if in_mem(t.ty) || t.op == O_VOP || t.op == O_ASM || t.op == O_SYS {
                return 8;
            }
            lv::each_use(self.b(), t, &mut self.uses);
            for k in 0..self.uses.len() {
                if in_mem(self.vt(self.uses[k])) {
                    return 8;
                }
            }
        }
        if t.op == O_MULO && t.aux != OV_SIGNED && type_bits(t.ty, self.ptr) == 64 {
            return 8;
        }
        if t.op >= O_SDIV && t.op <= O_UREM {
            return 7;
        }
        // rdx:rax, the registers the values they held move to (`vacate`) and the two operands; a product with
        // its high half after it takes that half's `mul` (`twin_product`).
        if t.op == O_MULHU || t.op == O_MULHS || t.op == O_MUL && t.ty == T_I64 && self.twin_product(i, t, true) != NONE {
            return 6;
        }
        if t.op == O_ARMW || t.op == O_ACAS {
            return 6;
        }
        if t.op >= O_SHL && t.op <= O_ASHR || t.op == O_SELECT || self.folds_both(t) {
            return 5;
        }
        // A branch on two comparisons (`lv::FOLD_BRCONJ`) holds their four operands and a constant.
        if t.op == O_BR && (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && (self.b().insts[t.a as usize].op == O_AND || self.b().insts[t.a as usize].op == O_OR) {
            return 6;
        }
        return 4;
    }

    // The xmm registers instruction `i` holds at once besides the homes (`end_inst` checks it): 6 for a
    // vector result, a vector operation and a float select (a high product's two operands, three
    // temporaries and result; a folded comparison's four operands, result and temporary); 4 for an FMA
    // and a `memcpy` (an overlapping copy of 64 bytes, in four registers); 3 for the others (two
    // operands and a separate result).
    const fn vneed(self: &Self, i: u32) u32 {
        let t = self.b().insts[i as usize];
        if is_vec(t.ty) || t.op == O_VOP || t.op == O_SELECT && is_v(t.ty) {
            return 6;
        }
        return if t.op == O_FMA || t.op == O_MEMCPY {
            4
        } else {
            3
        };
    }

    // The integer registers branch `t` on two folded comparisons holds at once (`branch_conj`, which locks
    // the registers of the values it reads): each comparison operand and edge argument but a constant, and
    // one a comparison loads an operand into; 4 to 8.
    fn conj_need(self: &mut Self, t: Inst) u32 {
        let b = self.b();
        let c = b.insts[t.a as usize];
        let ops: [Value; 4] = [
            b.insts[c.a as usize].a,
            b.insts[c.a as usize].b,
            b.insts[c.b as usize].a,
            b.insts[c.b as usize].b,
        ];
        lv::each_use(b, t, &mut self.uses);
        let mut n: u32 = 1;
        let mut k: u64 = 0;
        for q in 0..self.uses.len() {
            if self.uses[q] != t.a && !self.const_of(self.uses[q], &mut k) {
                n += 1;
            }
        }
        for q in 0..4usize {
            if !self.const_of(ops[q], &mut k) {
                n += 1;
            }
        }
        return n.max(4).min(8);
    }

    // Whether both operands of `t` fold into it: a rotation (`lv::FOLD_ROT`), which may take its amount in
    // cl as a shift does.
    const fn folds_both(self: &Self, t: Inst) bool {
        return (t.op == O_OR || t.op == O_XOR || t.op == O_ADD) && (t.a & (VPARAM | VFLAG)) == 0 && (t.b & (VPARAM | VFLAG)) == 0 && t.a != VNONE && t.b != VNONE && self.lv.pfold[t.a as usize] && self.lv.pfold[t.b as usize];
    }

    // `vmem`: per value, whether it is a vector some instruction defines or reads in memory: any but a
    // vector load, a lane-wise operation with an SSE form (its operands too; a product or high product of
    // 32-bit lanes, `mul_lanes32`, `mulh_lanes32`; an integer minimum or maximum, `ext_reg`; a float lane
    // operation, `float_reg`), a bitcast
    // between register vectors, a reduction in registers (`reduce_reg`), a store of it, and an edge argument
    // (a return reads its vector in memory).
    fn vec_homes(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        self.vmem.truncate(0);
        self.vmem.resize_default(self.lv.end.len());
        fill(&mut self.vreg, ni, false);
        for i in 0..ni {
            let t = b.insts[i];
            let mut un = false;
            let arith = t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT || t.op == O_MULHS || t.op == O_MULHU;
            let reg_op = is_vec(t.ty) && arith && sse_of_op(t.op, lane_type(t.ty), &mut un) != NONE || (t.op == O_SPLAT || t.op == O_VSEL || t.op == O_WCONST) && self.in_reg(
                t.ty,
            ) || self.conv_reg(t) || self.shift_reg(t) || self.lv.vshimm(self.b(), t) != NONE || (t.op == O_VEXTRACT || t.op == O_VINSERT) && self.lane_reg(
                t,
            ) || (t.op == O_VZIPLO || t.op == O_VZIPHI) && type_bytes(t.ty, 8) <= 32 && self.in_reg(t.ty) || t.op == O_VUNZIP && type_bytes(
                t.ty,
                8,
            ) >= 16 && self.in_reg(t.ty) || t.op == O_VCMP && self.in_reg(self.vt(t.a)) && (is_float(
                lane_type(self.vt(t.a)),
            ) || type_bytes(lane_type(t.ty), 8) < 8 || self.avx) || self.avx && is_vec(t.ty) && type_bytes(t.ty, 8) == 32 && arith && avx_of_op(
                t.op,
                lane_type(t.ty),
            ) != NONE || self.z512 && is_vec(t.ty) && type_bytes(t.ty, 8) == 64 && arith && evex_of_op(
                t.op,
                lane_type(t.ty),
            ) != NONE || t.op == O_BITCAST && self.in_reg(t.ty) && self.in_reg(self.vt(t.a)) || self.reduce_reg(t) || self.ext_reg(
                t,
            ) || t.op == O_VOP && (self.lv.pfold[i] || self.idiom_reg(t) || self.float_reg(t)) || self.sumw_reg(t) || t.op == O_MUL && is_vec(
                t.ty,
            ) && type_bytes(lane_type(t.ty), 8) == 4 && type_bytes(t.ty, 8) == 16 && in_vreg(t.ty) || (t.op == O_MULHS || t.op == O_MULHU) && is_vec(
                t.ty,
            ) && type_bytes(lane_type(t.ty), 8) == 4 && self.in_reg(t.ty);
            if is_vec(t.ty) && !reg_op && t.op != O_LOAD {
                self.vmem[i] = true;
            }
            self.vreg[i] = reg_op && is_vec(t.ty) || self.reduce_reg(t) || t.op == O_VOP && self.lv.pfold[i];
            // A return reads in memory a vector it neither returns in one register nor stores whole.
            let rl = self.self_lay.ret;
            if t.op == O_RET && t.a != VNONE && is_vec(self.vt(t.a)) && !self.self_lay.whole_vreg(rl, self.vt(t.a)) && !(rl.kind == ab::L_SRET && self.in_reg(
                self.vt(t.a),
            )) {
                self.vmem[self.vx(t.a) as usize] = true;
            }
            if reg_op || is_terminator(t.op) || lv::lane0_op(b, &self.lv.pfold, t) {
                continue;
            }
            // A call takes a vector argument it passes whole in a register from that register.
            let call = t.op == O_CALL && self.intrinsic(t.a).len() == 0 || t.op == O_CALLIND;
            if call {
                self.call_layout(t);
            }
            lv::each_use(b, t, &mut self.uses);
            for k in 0..self.uses.len() {
                let u = self.uses[k];
                if t.op == O_STORE && u == t.b || call && self.whole_arg(t, u) {
                    continue;
                }
                let x = self.vx(u);
                if x != NONE && is_vec(self.xty(x)) {
                    self.vmem[x as usize] = true;
                }
            }
        }
        // A vector load into a register, a store of a vector from one, and a jump or branch that passes vectors
        // in registers alone (`vmem` is final now).
        for i in 0..ni {
            let t = b.insts[i];
            let mut reg = t.op == O_LOAD && is_vec(t.ty) && self.in_reg(t.ty) && !self.vmem[i] || t.op == O_STORE && is_vec(
                self.vt(t.b),
            ) && self.in_reg(self.vt(t.b)) && !self.vmem[self.vx(t.b) as usize];
            if t.op == O_JMP || t.op == O_BR {
                lv::each_use(b, t, &mut self.uses);
                reg = true;
                for k in 0..self.uses.len() {
                    let vt = self.vt(self.uses[k]);
                    reg = reg && (!in_mem(vt) || is_vec(vt) && self.in_reg(vt) && !self.vmem[self.vx(self.uses[k]) as usize]);
                }
            }
            if reg {
                self.vreg[i] = true;
            }
        }
    }

    // Whether call `t` (its layout in `lay`) reads vector `u` only as arguments it passes whole in one
    // register (`whole_vreg`), not in memory.
    fn whole_arg(self: &Self, t: Inst, u: Value) bool {
        let b = self.b();
        if !is_vec(self.vt(u)) || t.op == O_CALLIND && t.a == u {
            return false;
        }
        let np = b.pool[t.b as usize];
        let nops = np + ((b.pool[t.b as usize + 2] & AGG) != 0) as u32;
        let mut any = false;
        for k in 0..nops {
            if b.pool[(t.c + k) as usize] != u {
                continue;
            }
            if k == np || (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 || !self.lay.whole_vreg(
                self.lay.locs[k as usize],
                self.vt(u),
            ) {
                return false;
            }
            any = true;
        }
        return any;
    }

    // Whether a call that returns (`clobbers`) runs while value index `x` (an instruction's or a
    // parameter's) lives: after its definition and before its last use in its own block, or in a block
    // of its range after its own.
    const fn crosses_call(self: &Self, x: u32, v: bool) bool {
        let pre = if v {
            &self.vpre
        } else {
            &self.cpre
        };
        let pos = if v {
            &self.vpos
        } else {
            &self.cpos
        };
        let b = self.b();
        let ni = b.insts.len() as u32;
        let d = self.lv.def_blk[x as usize];
        let dp = self.lv.pos[d as usize];
        let e = self.lv.end[x as usize];
        let bk = b.blocks[d as usize];
        let from = if x < ni {
            x + 1
        } else {
            bk.start
        };
        if e <= dp {
            return pre[self.lv.last[x as usize] as usize] > pre[from as usize];
        }
        return pre[(bk.start + bk.len) as usize] > pre[from as usize] || pos[e as usize + 1] > pos[dp as usize + 1];
    }

    // The code section of a `@cold` function (`Sym.cold`): apart from the other functions', which the
    // linker lays out together (COFF: after `.text`, grouped by the name past `$`).
    const fn cold_text(self: &Self) str<'static> {
        return if self.win {
            ".text$u"
        } else {
            ".text.unlikely"
        };
    }

    // Whether instruction `i` is in a rare block (`Live::rare`): when it calls, the scratch homes that live past
    // it are saved around it (`save_scratch`), so it counts as no call for the homes.
    const fn rare(self: &Self, i: u32) bool {
        return self.lv.rare[self.lv.def_blk[i as usize] as usize];
    }

    // Before instruction `i` of a rare block that calls and returns: each scratch home whose value lives
    // past it into a slot of its own (`csave`). The count saved.
    fn save_scratch(self: &mut Self, i: u32) usize {
        if !self.rarec[i as usize] {
            return 0;
        }
        let mut m = self.held & self.fixed_busy & ~self.xfix & ~self.vsave();
        // Each step clears one register's bit: at most 32 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            if !self.live_on(self.owner[r as usize]) {
                continue;
            }
            let off = self.slot_alloc(16, 16) as i64;
            self.save_reg(r, off, true);
            self.csave.push((r, off));
        }
        return self.csave.len();
    }

    // After the instruction `save_scratch` saved `n` registers around: those registers back.
    fn restore_scratch(self: &mut Self, n: usize) {
        for k in 0..n {
            let (r, off) = self.csave[k];
            self.save_reg(r, off, false);
            self.free_slots.push(16u64 << 32 | (off as u32) as u64);
        }
        self.csave.truncate(0);
    }

    // `cpre` and `cpos`: the calls that return to a use (`clobbers`, not `dead_end`)
    // before each instruction index, and the blocks holding one before each layout position; `vpre` and
    // `vpos` the same without the intrinsics, whose templates write xmm0 to xmm3 and their arguments'
    // registers, no vector scratch home.
    fn call_tables(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill(&mut self.cpre, ni + 1, 0);
        fill(&mut self.vpre, ni + 1, 0);
        self.rarec.truncate(0);
        self.rarec.resize_default(ni);
        fill(&mut self.cret, ni, false);
        for i in 0..ni {
            let t = b.insts[i];
            // A sibling call does not come back: the body around it may be a leaf.
            let c = self.calls(t) && !lv::dead_end(unsafe &*self.pkg, b, &self.lv, i, &mut self.uses) && !(t.op == O_CALL && self.sib_shape(
                i as u32,
                t,
            )) && !self.mem_tail(i as u32, t);
            self.cret[i] = c;
            if c && self.rare(i as u32) {
                self.rarec[i] = true;
            } else if c {
                self.cpre[i + 1] = 1;
                self.vpre[i + 1] = (!(t.op == O_CALL && self.intrinsic(t.a).len() != 0)) as u32;
            }
        }
        let nq = self.lv.order.len();
        fill(&mut self.cpos, nq + 1, 0);
        fill(&mut self.vpos, nq + 1, 0);
        for q in 0..nq {
            let bk = b.blocks[self.lv.order[q] as usize];
            let mut c: u32 = 0;
            let mut v: u32 = 0;
            for i in bk.start..bk.start + bk.len {
                c |= self.cpre[i as usize + 1];
                v |= self.vpre[i as usize + 1];
            }
            self.cpos[q + 1] = self.cpos[q] + c;
            self.vpos[q + 1] = self.vpos[q] + v;
        }
        for i in 0..ni {
            self.cpre[i + 1] += self.cpre[i];
            self.vpre[i + 1] += self.vpre[i];
        }
    }

    // `clobbers` of `t` but a vector operation the body computes in registers (`ext_reg`, `idiom_reg`,
    // `float_reg`) and an intrinsic that writes vector registers alone (`intrin_clob`), and a
    // thread-local address that calls `__tls_get_addr` (`tls_call`).
    fn calls(self: &Self, t: Inst) bool {
        let vec_intrin = t.op == O_CALL && self.intrinsic(t.a).len() != 0 && (self.intrin_clob(t, self.intrinsic(t.a)) & 0xFFFF) == 0;
        return Gen::clobbers(self.b(), t) && !self.ext_reg(t) && !self.idiom_reg(t) && !self.float_reg(t) && !vec_intrin || self.tls_call(
            t,
        );
    }

    const fn clobbers(b: &Body, t: Inst) bool {
        let op = t.op;
        if op == O_CALL || op == O_CALLIND || op == O_ASM || op == O_VOP && !lv::reduces(t) || op == O_MEMCPY || op == O_MEMSET {
            return true;
        }
        if op >= O_SDIV && op <= O_UREM {
            return t.ty == T_I128;
        }
        if op >= O_FPTOSI && op <= O_UITOFP {
            return t.ty == T_I128 || b.type_of(t.a) == T_I128;
        }
        return false;
    }

    // Select `i` (`t`) of scalar floats on a folded float comparison (`lv::FOLD_FSEL`): `mins`/`maxs` when it
    // picks the lesser or greater of the compared values by `<` or `>` (their unordered and equal cases
    // give the second operand, as the select does); else the comparison's mask (`cmps`: equal, less, less
    // or equal, unordered, not equal; greater ones swapped), the true side under it and the false side
    // under its complement. The result takes the register of the operand it starts from when that dies
    // here (`def_over`).
    fn fsel(self: &mut Self, i: u32, t: Inst) {
        let c = self.b().insts[t.a as usize];
        let pf: u32 = if t.ty == T_F64 {
            0xF2
        } else {
            0xF3
        };
        // olt(x, 0) ? -x : x = max(-x, x): maxs gives its second operand for equal zeros and for a NaN, as
        // the select gives x (LLVM's lowering of a float absolute value that keeps -0).
        let k = c.b;
        let zero = (k & (VPARAM | VFLAG)) == 0 && self.b().insts[k as usize].op == O_FCONST && self.b().insts[k as usize].a == 0 && (self.b().insts[k as usize].b & 0x7FFFFFFF) == 0;
        let nb = t.b;
        if c.aux == C_OLT && zero && t.c == c.a && (nb & (VPARAM | VFLAG)) == 0 && self.b().insts[nb as usize].op == O_FNEG && self.b().insts[nb as usize].a == c.a {
            let rn = self.reg(nb);
            let ra = self.reg(c.a);
            let rd = self.def_over(i, nb, rn);
            let m = if rd == ra {
                self.tmp(true)
            } else {
                rd
            };
            if m != rn {
                self.c.vmov(m - V0, rn - V0);
            }
            self.c.sse_rr(pf, 0x0F5F, m - V0, ra - V0);
            if m != rd {
                self.c.vmov(rd - V0, m - V0);
            }
            return;
        }
        let ra = self.reg(c.a);
        let rb = self.reg(c.b);
        let ext = c.aux == C_OLT || c.aux == C_OGT;
        if ext && (t.b == c.a && t.c == c.b || t.b == c.b && t.c == c.a) {
            // olt(a, b) ? a : b = min(a, b), ? b : a = max(b, a); ogt the other way.
            let first = t.b == c.a;
            let (x, y) = if first {
                (ra, rb)
            } else {
                (rb, ra)
            };
            let op: u32 = if c.aux == C_OLT == first {
                0x0F5D
            } else {
                0x0F5F
            };
            let rd = self.def_over(i, t.b, x);
            let m = if rd == y {
                self.tmp(true)
            } else {
                rd
            };
            if m != x {
                self.c.vmov(m - V0, x - V0);
            }
            self.c.sse_rr(pf, op, m - V0, y - V0);
            if m != rd {
                self.c.vmov(rd - V0, m - V0);
            }
            return;
        }
        let (p, q, imm) = if c.aux == C_OGT {
            (rb, ra, 1u32)
        } else if c.aux == C_OGE {
            (rb, ra, 2u32)
        } else if c.aux == C_OEQ {
            (ra, rb, 0u32)
        } else if c.aux == C_OLT {
            (ra, rb, 1u32)
        } else if c.aux == C_OLE {
            (ra, rb, 2u32)
        } else if c.aux == C_UNO {
            (ra, rb, 3u32)
        } else {
            (ra, rb, 4u32)
        };
        // A side of +0.0 is the mask's other half alone: `andnps` (the true side) or `andps` (the false side).
        let zt = self.pos_zero(t.b);
        if zt != self.pos_zero(t.c) {
            let ro = self.reg(
                if zt {
                    t.c
                } else {
                    t.b
                },
            );
            let rd = self.def_over(
                i,
                if p == ra {
                    c.a
                } else {
                    c.b
                },
                p,
            );
            let m = if rd == q || rd == ro {
                self.tmp(true)
            } else {
                rd
            };
            if m != p {
                self.c.vmov(m - V0, p - V0);
            }
            self.c.sse_rr(pf, 0x0FC2, m - V0, q - V0);
            self.c.byte(imm);
            self.c.sse_rr(
                0,
                if zt {
                    0x0F55
                } else {
                    0x0F54
                },
                m - V0,
                ro - V0,
            );
            if m != rd {
                self.c.vmov(rd - V0, m - V0);
            }
            return;
        }
        let rt = self.reg(t.b);
        let rf = self.reg(t.c);
        let rd = self.def_over(
            i,
            if p == ra {
                c.a
            } else {
                c.b
            },
            p,
        );
        let m = if rd == q || rd == rt || rd == rf {
            self.tmp(true)
        } else {
            rd
        };
        let s = self.tmp(true);
        if m != p {
            self.c.vmov(m - V0, p - V0);
        }
        self.c.sse_rr(pf, 0x0FC2, m - V0, q - V0);
        self.c.byte(imm);
        self.c.vmov(s - V0, m - V0);
        self.c.sse_rr(0, 0x0F54, s - V0, rt - V0);
        self.c.sse_rr(0, 0x0F55, m - V0, rf - V0);
        self.c.sse_rr(0, 0x0F56, m - V0, s - V0);
        if m != rd {
            self.c.vmov(rd - V0, m - V0);
        }
    }

    // Whether value `v` is the float constant +0.0 (every bit clear).
    const fn pos_zero(self: &Self, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let k = self.b().insts[v as usize];
        return k.op == O_FCONST && k.a == 0 && k.b == 0;
    }

    // Select `i` (`t`) of a value and that value plus 1 on an integer comparison, the side folded
    // (`lv::FOLD_CARRY`): an unsigned order comparison of 32 or 64 bits as `p <u q` sets CF, then the
    // value plus CF (`adc`), or plus 1 less CF (`sbb -1`) when the side is taken on `!(p <u q)`; another
    // sets the side's condition into a zeroed register the value adds (clang's `setcc`, `add`).
    fn carry_select(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let inc_b = (t.b & (VPARAM | VFLAG)) == 0 && t.b != VNONE && self.lv.pfold[t.b as usize];
        let other = if inc_b {
            t.c
        } else {
            t.b
        };
        let c = b.insts[t.a as usize];
        let dz = type_bits(t.ty, self.ptr) / 8;
        let cb = type_bits(b.type_of(c.a), self.ptr);
        // `p == 0` is `p <u 1` (CF after `cmp p, 1`), `p != 0` its inverse (`p` in a register: not folded into
        // the comparison).
        let mut kz: u64 = 0;
        let zb = self.const_of(c.b, &mut kz) && kz == 0;
        let za = !zb && self.const_of(c.a, &mut kz) && kz == 0;
        let p0 = if zb {
            c.a
        } else {
            c.b
        };
        let folded = (p0 & (VPARAM | VFLAG)) == 0 && self.lv.pfold[p0 as usize];
        if (c.aux == C_EQ || c.aux == C_NE) && (zb || za) && (cb == 32 || cb == 64) && !self.const_of(p0, &mut kz) && !folded {
            let rp = self.reg(p0);
            let ro = self.reg(other);
            let rd = self.def_over(i, other, ro);
            self.c.alu_ri(x::CMP, cb / 8, rp, 1);
            if rd != ro {
                self.c.mov_rr(dz, rd, ro);
            }
            if c.aux == C_EQ == inc_b {
                self.c.alu_ri(x::ADC, dz, rd, 0);
            } else {
                self.c.alu_ri(x::SBB, dz, rd, -1);
            }
            self.va.index_mut(i as usize).clean = dz == 4;
            return;
        }
        if c.aux != C_ULT && c.aux != C_UGT && c.aux != C_ULE && c.aux != C_UGE || cb != 32 && cb != 64 {
            let ro = self.reg(other);
            let rz = self.tmp(false);
            self.c.alu_rr(x::XOR, 4, rz, rz);
            let cc = self.compare(c, NONE);
            self.c.setcc(
                if inc_b {
                    cc
                } else {
                    x::invert(cc)
                },
                rz,
            );
            let rd = self.def_over(i, other, ro);
            if rd != ro {
                self.c.mov_rr(dz, rd, ro);
            }
            self.c.alu_rr(x::ADD, dz, rd, rz);
            self.va.index_mut(i as usize).clean = dz == 4;
            return;
        }
        // ult(a, b): a < b; ugt(a, b): b < a; uge(a, b): !(a < b); ule(a, b): !(b < a).
        let swap = c.aux == C_UGT || c.aux == C_ULE;
        let lt = (c.aux == C_ULT || c.aux == C_UGT) == inc_b;
        let (p, q) = if swap {
            (c.b, c.a)
        } else {
            (c.a, c.b)
        };
        let sz = type_bits(b.type_of(p), self.ptr) / 8;
        let mut k: i32 = 0;
        let imm = self.imm32_of(q, sz * 8, &mut k);
        let rq = if imm {
            NOREG
        } else {
            self.reg(q)
        };
        let mut kp: i32 = 0;
        let rp = if self.imm32_of(p, sz * 8, &mut kp) {
            self.c.mov_ri(S0, (kp as i64) as u64);
            S0
        } else {
            self.reg(p)
        };
        let ro = self.reg(other);
        let rd = self.def(i);
        if imm {
            self.c.alu_ri(x::CMP, sz, rp, k);
        } else {
            self.c.alu_rr(x::CMP, sz, rp, rq);
        }
        if rd != ro {
            self.c.mov_rr(dz, rd, ro);
        }
        if lt {
            self.c.alu_ri(x::ADC, dz, rd, 0);
        } else {
            self.c.alu_ri(x::SBB, dz, rd, -1);
        }
        self.va.index_mut(i as usize).clean = dz == 4;
    }

    // Which of rax, rcx and rdx body `b` lets be homes (`xhome`): those no instruction takes for itself. A
    // scalar division, product's high half or 64-bit unsigned product with overflow takes rax and rdx, a
    // scalar shift by a register rcx; a signed or narrow overflow check, an atomic, a system operation, inline assembly, a call that comes back (`cret`: not
    // a sibling call or one before a trap), a thread-local address, a 128-bit value, a lane-wise operation
    // but one in xmm registers (`reduce_reg`, `ext_reg`, `idiom_reg`, `float_reg`, `FOLD_ANY`), a vector shift by no immediate
    // (`Live::vshimm`) take all three, as does an aggregate or second register return.
    fn homes_free(self: &Self, b: &Body) u64 {
        let all = bit(x::RAX) | bit(x::RCX) | bit(x::RDX);
        let rl = self.self_lay.ret;
        if (b.pool[b.sig as usize + 2] & AGG) != 0 || rl.kind == ab::L_SRET || rl.kind == ab::L_REG && rl.n > 1 {
            return 0;
        }
        // The entry's parameters: the other blocks' take what instructions define.
        let e = b.blocks[0];
        for q in e.param_start..e.param_start + e.param_len as u32 {
            if b.params[q as usize] == T_I128 || is_vec(b.params[q as usize]) {
                return 0;
            }
        }
        let mut free = all;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let op = t.op;
            let mut k: u64 = 0;
            let shift = op == O_SHL || op == O_LSHR || op == O_ASHR;
            if t.ty == T_I128 || (op == O_CALL || op == O_CALLIND) && self.cret[i] || op == O_ASM || op == O_SYS || op == O_VOP && !self.reduce_reg(
                t,
            ) && !self.ext_reg(t) && !self.idiom_reg(t) && !self.float_reg(t) && !self.lv.pfold[i] || op == O_VASTART || op == O_VAARG || op == O_MEMCPY || op == O_MEMSET || is_vec(
                t.ty,
            ) && (op == O_MULHU || op == O_MULHS || op >= O_SDIV && op <= O_UREM) || op >= O_ADDO && op <= O_MULO && (t.aux == OV_SIGNED || type_bits(
                t.ty,
                8,
            ) < 32) || op >= O_ALOAD && op <= O_FENCE || self.tls_call(t) || shift && is_vec(t.ty) && self.lv.vshimm(
                b,
                t,
            ) == NONE {
                return 0;
            }
            if op == O_MULHU || op == O_MULHS || op >= O_SDIV && op <= O_UREM || op == O_MULO && type_bits(t.ty, 8) == 64 {
                free &= ~(bit(x::RAX) | bit(x::RDX));
            } else if shift && !is_vec(t.ty) && !self.const_of(t.b, &mut k) {
                free &= ~bit(x::RCX);
            }
        }
        return free;
    }

    // Give value index `x` a caller-saved register of file `vr` (`xhome`, `vscr`) as its home, the value
    // there evicted: `prefer` when it is one (the register `x` arrives in), else one the current
    // instruction does not use; NOREG when none is.
    fn take_scratch(self: &mut Self, x: u32, vr: bool, prefer: u8) u8 {
        let set = if vr {
            self.vscr
        } else {
            self.xhome
        } & ~self.fixed_busy & ~self.resv;
        let open = set & ~(self.lock | self.tmps);
        let r = if prefer != NOREG && (set & bit(prefer)) != 0 {
            prefer
        } else if (open & ~self.held) != 0 {
            (open & ~self.held).trailing_zeros() as u8
        } else if open != 0 {
            self.cheapest(open)
        } else {
            NOREG
        };
        // None free (a home the plan saw end in this block holds on to its end): a callee-saved one, which a
        // later home may not take over.
        if r == NOREG {
            return self.take_fixed(x, vr);
        }
        if r != prefer {
            self.evict(r);
        }
        self.fixed_busy |= bit(r);
        self.set_owner(r, x);
        let va = self.va.index_mut(x as usize);
        va.reg = r;
        va.home = H_FIXED;
        va.dirty = false;
        return r;
    }

    // Whether callee-saved register `r` holds no loop value and the current instruction does not use it.
    const fn fixed_free(self: &Self, r: u8) bool {
        return (self.xfix & ~self.fixed_busy & ~self.lock & ~self.tmps & bit(r)) != 0;
    }

    // Give value index `x` a free callee-saved register of file `vr` as its home (an xmm one under
    // Microsoft x64 only), the value there (from `alloc`'s fallback) evicted; NOREG when none is free.
    fn take_fixed(self: &mut Self, x: u32, vr: bool) u8 {
        if vr {
            let open = self.vfix & ~self.fixed_busy & ~self.lock & ~self.tmps;
            for r in VFIX_WIN {
                if (open & bit(r)) != 0 {
                    self.evict(r);
                    self.fixed_busy |= bit(r);
                    self.csr |= bit(r);
                    self.set_owner(r, x);
                    let va = self.va.index_mut(x as usize);
                    va.reg = r;
                    va.home = H_FIXED;
                    va.dirty = false;
                    return r;
                }
            }
            return NOREG;
        }
        for r in 0..16u32 {
            if self.fixed_free(r as u8) {
                self.evict(r as u8);
                self.fixed_busy |= bit(r as u8);
                self.csr |= bit(r as u8);
                self.set_owner(r as u8, x);
                let va = self.va.index_mut(x as usize);
                va.reg = r as u8;
                va.home = H_FIXED;
                va.dirty = false;
                return r as u8;
            }
        }
        return NOREG;
    }

    // Value `v` in a register of its file, locked for the current instruction.
    fn reg(self: &mut Self, v: Value) u8 {
        // Lane 0 of a vector its user reads in the vector's register (`lv::FOLD_LANE0`), a spilled one
        // loaded into a vector temporary.
        if (v & (VPARAM | VFLAG)) == 0 && v != VNONE && self.lv.pfold[v as usize] {
            let w = lv::lane0_of(self.b(), v);
            if w != VNONE {
                let s = if self.va[self.vx(w) as usize].reg != NOREG {
                    NOREG
                } else {
                    self.tmp(true)
                };
                return self.vec_use(w, s);
            }
        }
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.reg != NOREG {
            self.lock |= bit(va.reg);
            return va.reg;
        }
        let t = self.vt(v);
        if va.home == H_REMAT || va.home == H_SPADDR || va.home == H_FPADDR {
            let r = self.tmp(is_v(t));
            self.materialize(v, r);
            return r;
        }
        let r = self.alloc(is_v(t));
        if va.home == H_SLOT {
            self.ld(t, r, x::at(x::RSP, va.off));
        } else if va.home == H_ARG {
            self.ld(t, r, x::at(self.fb, va.off));
        } else {
            assert(false, "x64gen: a value with no register and no home");
        }
        self.bind(x, r);
        self.va.index_mut(x as usize).dirty = false;
        return r;
    }

    // Value `v`'s bits into register `r` (of its file), without binding `r` to it.
    fn materialize(self: &mut Self, v: Value, r: u8) {
        let x = self.vx(v);
        let va = self.va[x as usize];
        let t = self.vt(v);
        if va.home == H_SPADDR || va.home == H_FPADDR {
            self.c.lea(
                r,
                x::at(
                    if va.home == H_SPADDR {
                        x::RSP
                    } else {
                        self.fb
                    },
                    va.off,
                ),
            );
            return;
        }
        if va.reg != NOREG {
            self.move_reg(t, r, va.reg);
            return;
        }
        if va.home == H_SLOT || va.home == H_ARG {
            self.ld(
                t,
                r,
                x::at(
                    if va.home == H_SLOT {
                        x::RSP
                    } else {
                        self.fb
                    },
                    va.off,
                ),
            );
            return;
        }
        let i = self.b().insts[v as usize];
        if i.op == O_ICONST {
            self.mov_imm(r, i.b as u64 << 32 | i.a as u64, type_bytes(t, self.ptr));
        } else if i.op == O_FCONST {
            self.fconst(r, t == T_F64, i.b as u64 << 32 | i.a as u64);
        } else if i.op == O_SLOTADDR {
            self.c.lea(r, x::at(x::RSP, self.slot_off[i.a as usize] as i32));
        } else {
            self.sym_addr(r, i.a, i.b as i32);
        }
    }

    // Value `v` (an integer `bits` wide, 8 or 16) into register `r`, extended to 32 bits: a constant as
    // its extension, a value whose upper bits are zero as it is when `signed` is off.
    fn materialize_ext(self: &mut Self, v: Value, r: u8, signed: bool, bits: u32) {
        let mut k: u64 = 0;
        if self.const_of(v, &mut k) {
            let lo = k & (1u64 << bits as u64) - 1;
            let neg = signed && (lo >> (bits - 1) as u64 & 1) != 0;
            self.mov_imm(
                r,
                if neg {
                    lo | 0xFFFFFFFF << bits as u64 & 0xFFFFFFFF
                } else {
                    lo
                },
                4,
            );
            return;
        }
        let x = self.vx(v);
        let va = self.va[x as usize];
        // A narrow load zero-extends.
        let clean = va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG) || self.lv.zero_param(
            self.b(),
            v,
        );
        // In a register: extended from there, not copied first.
        if va.reg != NOREG && va.reg < V0 && (signed || !clean) {
            self.c.ext(bits / 8, 4, signed, r, va.reg);
            return;
        }
        self.materialize(v, r);
        if signed {
            self.c.ext(bits / 8, 4, true, r, r);
        } else if !clean {
            self.c.ext(bits / 8, 4, false, r, r);
        }
    }

    // Copy register `src` to `dst` (type `t`'s file).
    fn move_reg(self: &mut Self, t: u8, dst: u8, src: u8) {
        if dst == src {
            return;
        }
        if dst >= V0 && type_bytes(t, self.ptr) == 64 {
            // vmovdqa64 zmm (EVEX.512.66.0F.W1 6F).
            self.c.evex_rr(0x66, 1, 0x6F, true, dst - V0, 0, src - V0);
        } else if dst >= V0 && type_bytes(t, self.ptr) == 32 {
            // vmovaps ymm (VEX.256 0F 28).
            self.c.vex_rr(0, 1, 0x28, false, true, dst - V0, 0, src - V0);
        } else if dst >= V0 {
            assert(src >= V0, "x64gen: a move between register files");
            self.c.vmov(dst - V0, src - V0);
        } else {
            let _ = t;
            self.c.mov_rr(8, dst, src);
        }
    }

    // ---- Memory access ----

    // Load a value of type `t` (a scalar) from `m` into `r`: an integer below 64 bits zero-extended.
    fn ld(self: &mut Self, t: u8, r: u8, m: x::Mem) {
        let n = type_bytes(t, self.ptr);
        if r >= V0 {
            self.c.vload(n, r - V0, m);
        } else {
            self.c.load(n, false, r, m);
        }
    }

    // Store the value of type `t` in `r` to `m`.
    fn st(self: &mut Self, t: u8, r: u8, m: x::Mem) {
        let n = type_bytes(t, self.ptr);
        if r >= V0 {
            self.c.vstore(n, r - V0, m);
        } else {
            self.c.store(n, r, m);
        }
    }

    // ---- Instruction bookkeeping ----

    // Count the uses of instruction `i` and note the values that die at it.
    fn begin_inst(self: &mut Self, i: u32) {
        self.cur = i;
        self.pend = self.cond;
        self.cond = Cond { inst: NONE, cc: 0 };
        // A pending condition is this instruction's to read: nothing may clobber the flags before.
        self.keep_flags = self.pend.inst != NONE;
        let t = self.b().insts[i as usize];
        self.uses.truncate(0);
        self.uses.extend_from_slice(self.lv.uses_of(i));
        for k in 0..self.uses.len() {
            let x = self.vx(self.uses[k]);
            self.use_once(x);
        }
        // Code that may branch past a lane reads a vector from its home: a vector in a register reaches
        // it first, but for the instructions with register forms (`vop` and `vec_arith` sync their others;
        // a splat of a lane, `lv::FOLD_LANE`) and calls (a vector passed in memory goes through `mloc`).
        let reg_form = t.op == O_STORE || t.op == O_SPLAT || t.op == O_VOP || t.op == O_CALL || t.op == O_CALLIND || is_vec(
            t.ty,
        ) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT || t.op == O_MULHS || t.op == O_MULHU || t.op == O_VCMP || t.op == O_VSEL || t.op == O_VUNZIP || t.op == O_VZIPLO || t.op == O_VZIPHI || t.op == O_VSUMW) || t.op == O_VEXTRACT || t.op == O_VINSERT || self.conv_reg(
            t,
        ) || t.op == O_BITCAST && self.in_reg(t.ty) && self.in_reg(self.vt(t.a)) || lv::lane0_op(
            self.b(),
            &self.lv.pfold,
            t,
        );
        if !reg_form && !is_terminator(t.op) {
            for k in 0..self.uses.len() {
                self.sync(self.uses[k]);
            }
        }
        if is_terminator(t.op) {
            // Its edges write their targets' parameters, which free after the moves when that was the last.
            lv::each_edge_param(self.b(), t, &mut self.wparams);
            for k in 0..self.wparams.len() {
                self.use_once(self.wparams[k]);
            }
        }
    }

    // One use of value index `x` done: it frees after the current instruction when that was its last.
    fn use_once(self: &mut Self, x: u32) {
        self.lv.uses[x as usize] -= 1;
        if self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            self.dying.push(x);
        }
    }

    // End the current instruction: its locks and temporaries end and its dead values free.
    fn end_inst(self: &mut Self) {
        self.lv.advance(self.b(), self.cur);
        // `plan_homes` leaves `need` integer and `vneed` xmm registers to each instruction.
        let used = ((self.lock | self.tmps) & ~self.fixed_busy & (self.xalloc | self.xfix)).count_ones() as u32;
        assert(used <= self.need(self.cur), "x64gen: an instruction takes more registers than `need`");
        let vused = ((self.lock | self.tmps) & ~self.fixed_busy & self.valloc).count_ones() as u32;
        assert(vused <= self.vneed(self.cur), "x64gen: an instruction takes more xmm registers than `vneed`");
        self.lock = 0;
        self.tmps = 0;
        self.keep_flags = false;
        for k in 0..self.dying.len() {
            self.release(self.dying[k]);
        }
        self.dying.truncate(0);
    }

    // Free value index `x`'s register and slot.
    fn release(self: &mut Self, x: u32) {
        let va = self.va[x as usize];
        if va.reg != NOREG && self.owner[va.reg as usize] == x {
            // A later block's parameter that shares the register (`param_home`) holds it on.
            let to = self.heir[va.reg as usize];
            if to == x {
                self.heir[va.reg as usize] = NONE;
            }
            if va.home == H_FIXED && to != NONE && to != x && self.va[to as usize].home == H_FIXED && self.va[to as usize].reg == va.reg {
                self.set_owner(va.reg, to);
            } else {
                self.set_owner(va.reg, NONE);
                if va.home == H_FIXED {
                    self.fixed_busy &= ~bit(va.reg);
                }
            }
        }
        if va.home == H_SLOT && !self.is_shared(x) {
            let n = if in_mem(self.xty(x)) {
                type_bytes(self.xty(x), self.ptr)
            } else {
                8
            };
            self.free_slots.push(n as u64 << 32 | (va.off as u32) as u64);
        }
        let w = self.va.index_mut(x as usize);
        w.reg = NOREG;
        w.home = H_NONE;
        w.dirty = false;
    }

    // Whether the code so far ends with a `jmp` (a return's to the epilogue too): nothing falls past it.
    const fn ends_jump(self: &Self) bool {
        let n = self.c.len();
        let nj = self.c.jumps.len();
        return nj != 0 && self.c.jumps[nj - 1] + 4 == n && self.c.b[(n - 5) as usize] == 0xE9;
    }

    // Whether every late edge's target lies before layout position `q` (`lv::Live::late`).
    fn late_ready(self: &Self, q: u32) bool {
        let b = self.b();
        for j in 0..self.lv.late.len() {
            if self.lv.pos[b.edge_target(self.lv.late[j] as u32) as usize] >= q {
                return false;
            }
        }
        return true;
    }

    // The late edges' stubs (`lv::Live::late`): each edge's moves into its target's parameter homes as the
    // target started (`late_va`), then a jump to the target. The parameters' state comes back after.
    fn late_stubs(self: &mut Self) {
        self.stubs_out = true;
        let nb = self.b().blocks.len();
        let mut cur = Vector::<Va>::with_capacity(self.late_va.len());
        for j in 0..self.late_va.len() {
            let (x, va) = self.late_va[j];
            cur.push(self.va[x as usize]);
            let w = self.va.index_mut(x as usize);
            *w = va;
            w.dirty = false;
            if va.home != H_FIXED {
                w.reg = NOREG;
            }
        }
        for q in 0..self.lv.late.len() {
            let e = self.lv.late[q] as u32;
            // An earlier stub of an edge alike (one target, the same arguments) serves: each is entered with
            // the late homes.
            let mut same = NONE;
            for p in 0..q {
                if same == NONE && lv::same_edge(self.b(), self.lv.late[p] as u32, e) {
                    same = p as u32;
                }
            }
            if same != NONE {
                self.blk_at[nb + q] = self.blk_at[nb + same as usize];
                continue;
            }
            self.blk_at[nb + q] = self.c.len();
            self.edge_moves(e);
            self.goto(self.b().edge_target(e), true);
        }
        for j in 0..self.late_va.len() {
            self.va.set(self.late_va[j].0 as usize, cur[j]);
        }
    }

    // Whether block parameter `x` shares a header parameter's slot (`back_share`).
    fn is_shared(self: &Self, x: u32) bool {
        for k in 0..self.shared.len() {
            if self.shared[k] == x {
                return true;
            }
        }
        return false;
    }

    // ---- Frame ----

    // A stack slot of `size` bytes aligned to `al` (memory values and spills); its rsp offset.
    const fn slot_alloc(self: &mut Self, size0: u32, al0: u32) u32 {
        let size = if size0 < 8 {
            8u32
        } else {
            size0
        };
        let al = if al0 < 8 {
            8u32
        } else if al0 > 16 {
            16u32
        } else {
            al0
        };
        for k in 0..self.free_slots.len() {
            let e = self.free_slots[k];
            if (e >> 32) as u32 == size && e as u32 % al == 0 {
                let _ = self.free_slots.swap_remove(k);
                return e as u32;
            }
        }
        let at = self.spill_base + self.spill_top + al - 1 & ~(al - 1);
        self.spill_top = at + size - self.spill_base;
        return at;
    }

    // ---- Encoding helpers ----

    // `rd` = `v` in the fewest bytes; `n` the value's bytes (4 or less: 32 bits). The flags stay when
    // `keep_flags` is set (a pending condition is read after).
    fn mov_imm(self: &mut Self, rd: u8, v: u64, n: u32) {
        let k = if n < 8 {
            v & 0xFFFFFFFF
        } else {
            v
        };
        if k == 0 && !self.keep_flags {
            self.c.alu_rr(x::XOR, 4, rd, rd);
            return;
        }
        self.c.mov_ri(rd, k);
    }

    // xmm register `r` = the float of bits `bits` (`d` double): 0 by `xorps`, else a load of the constant
    // (`const_sym`).
    fn fconst(self: &mut Self, r: u8, d: bool, bits: u64) {
        if bits == 0 {
            self.c.sse_rr(0, 0x0F57, r - V0, r - V0);
            return;
        }
        let n: u32 = if d {
            8
        } else {
            4
        };
        let k = self.const_sym([bits]);
        self.c.vload(n, r - V0, x::rip());
        self.reloc_rip(x::R_PC32, k, 0);
    }

    // Register `r` = the address of body symbol `s` plus `addend`.
    fn sym_addr(self: &mut Self, r: u8, s: u32, addend: i64) {
        let os = self.osym_of(s);
        let p = unsafe &*self.pkg;
        let ps = p.syms[self.b().syms[s as usize] as usize];
        if ps.kind == SK_TLS && self.win {
            self.win_tls_addr(r, os, addend);
            return;
        }
        if ps.kind == SK_TLS && self.tls_local(s) {
            // mov r, fs:[0]; lea r, [r + x@tpoff]
            self.obj().syms.index_mut(os as usize).flags |= ob::SF_TLS;
            self.c.byte(0x64);
            self.c.byte(0x48 | r >> 3 << 2);
            self.c.byte(0x8B);
            self.c.byte((r & 7) << 3 | 4);
            self.c.byte(0x25);
            self.c.d32(0);
            self.lea_rel(r, x::R_TPOFF32, os, addend);
            return;
        }
        if ps.kind == SK_TLS {
            self.tls_addr(os);
            if r != x::RAX {
                self.c.mov_rr(8, r, x::RAX);
            }
            self.add_any(r, addend);
            return;
        }
        if ps.ext && self.win {
            // Maybe in a DLL: through the object's address slot, which the linker's import fills.
            let rp = self.refptr(os);
            self.c.rm(0, 0x8B, true, r, x::rip(), false);
            self.reloc_rip(x::R_PC32, rp, 0);
            self.add_any(r, addend);
            return;
        }
        if ps.ext || p.pic && ps.linkage == SL_GLOBAL {
            // Maybe in another shared object: through its address slot.
            self.c.rm(0, 0x8B, true, r, x::rip(), false);
            self.reloc_rip(x::R_REX_GOTPCRELX, os, 0);
            self.add_any(r, addend);
            return;
        }
        self.c.lea(r, x::rip());
        self.reloc_rip(x::R_PC32, os, addend);
    }

    // The object's address slot of external symbol `os` (`.refptr.<name>`, as mingw-w64 gcc names it): a
    // local 8-byte read-only cell the linker fills, defined at the first use.
    fn refptr(self: &mut Self, os: u32) u32 {
        let o = self.obj();
        let nm = format(".refptr.{}", o.name_of(os));
        let k = o.sym(&nm);
        if o.syms[k as usize].sec == ob::NOSEC {
            let at = o.define(k, ob::S_RELRO, 3, 8, 0);
            o.pad_to(ob::S_RELRO, at + 8);
            o.reloc(ob::S_RELRO, x::R_ABS64, at as u32, os, 0);
        }
        return k;
    }

    // `r` (not S0) = the address of thread-local variable `os` plus `addend` on Windows (native TLS, as
    // clang emits it): the thread's block from the TEB's TLS array at the module's `_tls_index`, then
    // the variable's offset in `.tls`. S0 is the scratch.
    fn win_tls_addr(self: &mut Self, r: u8, os: u32, addend: i64) {
        self.obj().syms.index_mut(os as usize).flags |= ob::SF_TLS;
        let ti = self.obj().sym("_tls_index");
        self.c.rm(0, 0x8B, false, S0, x::rip(), false);
        self.reloc_rip(x::R_PC32, ti, 0);
        // mov r, gs:[0x58]
        self.c.byte(0x65);
        self.c.byte(0x48 | r >> 3 << 2);
        self.c.byte(0x8B);
        self.c.byte((r & 7) << 3 | 4);
        self.c.byte(0x25);
        self.c.d32(0x58);
        self.c.rm(0, 0x8B, true, r, x::ix(r, S0, 3, 0), false);
        // The displacement: the variable's section offset.
        self.lea_rel(r, x::R_SECREL, os, addend);
    }

    // lea r, [r + disp32], the displacement relocation `kind` of object symbol `os` plus `addend`.
    fn lea_rel(self: &mut Self, r: u8, kind: u8, os: u32, addend: i64) {
        self.c.byte(0x48 | r >> 3 << 2 | r >> 3);
        self.c.byte(0x8D);
        self.c.byte(0x80 | (r & 7) << 3 | r & 7);
        if (r & 7) == 4 {
            self.c.byte(0x24);
        }
        let at = self.c.len();
        self.c.d32(0);
        self.rels.push(CRel { at: at, kind: kind, sym: os, addend: addend });
    }

    // rax = the address of thread-local variable `os` (general dynamic, which the linker relaxes): the
    // sequence calls `__tls_get_addr`, so the caller-saved registers are free first.
    fn tls_addr(self: &mut Self, os: u32) {
        // The reference is thread-local too, also to a variable another object defines.
        self.obj().syms.index_mut(os as usize).flags |= ob::SF_TLS;
        // data16 lea rdi, x@tlsgd(%rip); data16 data16 rex.W call __tls_get_addr@PLT
        self.c.byte(0x66);
        self.c.lea(x::RDI, x::rip());
        self.reloc_rip(x::R_TLSGD, os, 0);
        self.c.byte(0x66);
        self.c.byte(0x66);
        self.c.byte(0x48);
        let at = self.c.call32();
        self.called = true;
        let g = self.obj().sym("__tls_get_addr");
        self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: g, addend: -4 });
    }

    // `r` += `k` (any constant), the flags kept.
    fn add_any(self: &mut Self, r: u8, k: i64) {
        if k == 0 {
            return;
        }
        if k >= -2147483648 && k <= 2147483647 {
            self.c.lea(r, x::at(r, k as i32));
            return;
        }
        let t = if r == S1 {
            S0
        } else {
            S1
        };
        self.c.mov_ri(t, k as u64);
        self.c.lea(r, x::ix(r, t, 0, 0));
    }

    // `r` = `base` + `off`.
    fn add_off(self: &mut Self, r: u8, base: u8, off: i64) {
        if off >= -2147483648 && off <= 2147483647 {
            self.c.lea(r, x::at(base, off as i32));
            return;
        }
        self.c.mov_ri(S1, off as u64);
        self.c.lea(r, x::ix(base, S1, 0, 0));
    }

    // A relocation of kind `kind` at the last RIP-relative operand, which ends the instruction just
    // written: the field counts from the instruction's end.
    fn reloc_rip(self: &mut Self, kind: u8, sym: u32, addend: i64) {
        let at = self.c.rip_at;
        let end = self.c.len();
        self.rels.push(CRel { at: at, kind: kind, sym: sym, addend: addend - (end - at) as i64 });
    }

    // Whether block `k` (layout position `q`) starts with `vzeroupper`: it holds no 32-byte vector, a block
    // that does enters it, and no 32-byte vector's range (from its block's position to its last one)
    // covers it, so the upper halves hold nothing: the code of the legacy SSE encoding after a vector
    // loop runs without their state.
    fn upper_entry(self: &mut Self, q: u32, k: u32) bool {
        if !self.ymm || self.yblk[k as usize] {
            return false;
        }
        let mut from = false;
        for j in self.lv.pat[k as usize]..self.lv.pat[k as usize + 1] {
            let pj = self.lv.preds[j as usize] as usize;
            from = from || self.yblk[pj] && self.lv.pos[pj] != NONE;
        }
        if !from {
            return false;
        }
        for y in 0..self.yvals.len() {
            let x = self.yvals[y];
            let d = self.lv.def_blk[x as usize];
            if d != NONE && self.lv.pos[d as usize] != NONE && self.lv.pos[d as usize] < q && self.lv.end[x as usize] >= q {
                return false;
            }
        }
        return true;
    }

    // `vzeroupper` when the body holds a 32-byte vector in a register (`ymm`): before a call or a return,
    // so code of the legacy SSE encoding runs without the upper halves' state.
    fn upper_clear(self: &mut Self) {
        if self.ymm {
            self.c.vzeroupper();
        }
    }

    // `upper_clear` before the call `lay` lays out, unless it passes or returns a 32-byte vector in a ymm
    // register (its upper half an argument's; the callee runs the AVX encoding).
    fn call_clear(self: &mut Self) {
        if !ymm_parts(&self.lay) {
            self.upper_clear();
        }
    }

    // A call of C function `name`.
    fn call_sym(self: &mut Self, name: str) {
        self.upper_clear();
        let at = self.c.call32();
        self.called = true;
        let s = self.obj().sym(name);
        self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: s, addend: -4 });
    }

    // The object symbol of body symbol `s`.
    fn osym_of(self: &mut Self, s: u32) u32 {
        return place::osym_of(unsafe &*self.pkg, self.b(), self.obj(), &mut self.osym, s);
    }
}

extend Gen as Mover {
    fn moves(self: &mut Self) &mut Vector<Mv> {
        return &mut self.mv;
    }

    // One move of `bytes` bytes (`v`: a float or memory value) from `src` to `dst`.
    fn do_move(self: &mut Self, src: Lc, dst: Lc, v: bool, bytes: u32) {
        if src.kind == LC_MEM && dst.kind == LC_MEM {
            self.copy_mem(dst.reg, dst.off, src.reg, src.off, bytes);
            return;
        }
        // A vector register's 16 bytes move as an i128's.
        let t = if v && bytes == 4 {
            T_F32
        } else if v && bytes == 8 {
            T_F64
        } else if v && bytes == 16 {
            T_I128
        } else if v && bytes == 32 {
            vec_type(T_I64, 4)
        } else if v && bytes == 64 {
            vec_type(T_I64, 8)
        } else {
            int_type(bytes)
        };
        if dst.kind == LC_REG {
            if src.kind == LC_REG {
                self.move_reg(t, dst.reg, src.reg);
            } else if src.kind == LC_MEM {
                self.ld(t, dst.reg, x::at(src.reg, src.off));
            } else {
                self.materialize(self.xval(src.val), dst.reg);
            }
            return;
        }
        // A constant a 32-bit immediate holds goes into memory as it is.
        let mut k: i32 = 0;
        if src.kind == LC_VAL && !v && bytes <= 8 && self.imm32_of(self.xval(src.val), 8 * bytes, &mut k) {
            self.c.mov_mi(bytes, x::at(dst.reg, dst.off), k);
            return;
        }
        // Into memory through a scratch register.
        let s = if v {
            self.vs0
        } else {
            S0
        };
        let r = if src.kind == LC_REG {
            src.reg
        } else {
            self.materialize(self.xval(src.val), s);
            s
        };
        self.st(t, r, x::at(dst.reg, dst.off));
    }

    fn scratch(self: &mut Self, m: Mv) Lc {
        // Every allocatable integer register is an argument or result register, which a call may have set
        // outside the moves; the scratch registers are the moves' own. rax, which no argument takes, when
        // it holds nothing, no pending move names it and none rematerializes a value (a thread-local
        // address's comes in rax).
        let mut vals = false;
        for q in 0..self.mv.len() {
            vals = vals || !self.mv[q].done && self.mv[q].src.kind == LC_VAL;
        }
        if !m.v && !vals && ((self.held | self.lock | self.tmps | self.fixed_busy | move_regs(&self.mv)) & bit(x::RAX)) == 0 {
            return Lc { kind: LC_REG, reg: x::RAX, off: 0, val: NONE };
        }
        let s = self.slot_alloc(64, 16) as i32;
        return Lc { kind: LC_MEM, reg: x::RSP, off: s, val: NONE };
    }
}

extend Gen as Relays {
    fn body(self: &Self) &'static Body {
        return self.b();
    }

    fn live(self: &mut Self) &mut lv::Live {
        return &mut self.lv;
    }

    fn lay_call(self: &mut Self, t: Inst) bool {
        if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
            return false;
        }
        self.call_layout(t);
        return true;
    }

    fn layout(self: &Self) &ab::CallLayout {
        return &self.lay;
    }

    fn ptr(self: &Self) u32 {
        return self.ptr;
    }

    fn source(self: &Self, x: u32) Lc {
        return self.loc_of(x);
    }

    fn vreg0(self: &Self) u8 {
        return V0;
    }
}

const fn bref(p: *const Body) &'static Body {
    return unsafe &*p;
}

const fn oref(p: *mut ob::Obj) &'static mut ob::Obj {
    return unsafe &mut *p;
}

// `x`'s low `bits` bits sign-extended.
// Whether `c` is 3, 5 or 9: an address scales an index by `c - 1` and adds it to itself (`mul_const`).
const fn lea_factor(c: i64) bool {
    return c == 3 || c == 5 || c == 9;
}

const fn lp_sext(x: u64, bits: u32) i64 {
    if bits >= 64 {
        return x as i64;
    }
    let s = 64 - bits;
    return (x << s as u64) as i64 >> s as i64;
}

// The low `n` bits of `x` (n up to 64).
const fn trunc64(x: u64, n: u32) u64 {
    if n >= 64 {
        return x;
    }
    return x & (1u64 << n as u64) - 1;
}

// The size and alignment of signature type `pt` of `b`.
fn sig_size(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return (b.pool[l], 1u32 << b.pool[l + 1]);
    }
    return (type_bytes(pt as u8, ptr), type_align(pt as u8, ptr));
}

// ---- Functions ----

// The run-time copies that body `b` of `p` chooses before its own code (`lir::lower`'s CPU-level check:
// the level byte `__sc_simd_lv` read in the entry block, then per copy, the highest first, `level >= k`
// to a block that only calls the copy with the entry's parameters and returns its result): per copy, `k <<
// 32 | its body symbol` into `out`; the level byte's body symbol. `out` empty: no such check.
fn dispatch_of(p: &Package, b: &Body, out: &mut Vector<u64>) u32 {
    out.truncate(0);
    let b0 = b.blocks[0];
    let mut lvl = VNONE;
    let mut sym: u32 = 0;
    for i in b0.start..b0.start + b0.len {
        let t = b.insts[i as usize];
        if t.op == O_ALOAD && t.ty == T_I8 && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_SYMADDR && b.insts[t.a as usize].b == 0 {
            let a = b.insts[t.a as usize].a;
            if p.spell(p.syms[b.syms[a as usize] as usize].name) == "__sc_simd_lv" {
                lvl = i;
                sym = a;
            }
        }
    }
    if lvl == VNONE {
        return 0;
    }
    let np = b0.param_len as u32;
    let mut k: u32 = 0;
    // One check per step.
    for _ in 0..b.blocks.len() {
        let bk = b.blocks[k as usize];
        let tm = b.insts[(bk.start + bk.len - 1) as usize];
        if tm.op != O_BR || (tm.a & (VPARAM | VFLAG)) != 0 || b.edge_nargs(tm.b) != 0 || b.edge_nargs(tm.c) != 0 {
            break;
        }
        let c = b.insts[tm.a as usize];
        let mut lev: u64 = 0;
        if c.op != O_ICMP || c.aux != C_UGE || c.a != lvl || !lv::const_of(b, c.b, &mut lev) || lev == 0 || lev > 255 {
            break;
        }
        let tb = b.blocks[b.edge_target(tm.b) as usize];
        let call = b.insts[tb.start as usize];
        let r = b.insts[(tb.start + 1) as usize];
        if tb.len != 2 || call.op != O_CALL || r.op != O_RET || !(r.a == tb.start && call.ty != T_NONE || r.a == VNONE && call.ty == T_NONE) {
            break;
        }
        // The body's own signature and parameters, in order (the result's address with them).
        let mut same = b.pool[call.b as usize] + 3 == b.pool[b.sig as usize] + 3;
        for q in 0..b.pool[b.sig as usize] + 3 {
            same = same && b.pool[(call.b + q) as usize] == b.pool[(b.sig + q) as usize];
        }
        let nops = b.pool[call.b as usize] + ((b.pool[call.b as usize + 2] & AGG) != 0) as u32;
        same = same && nops == np;
        for q in 0..np {
            same = same && b.pool[(call.c + q) as usize] == (VPARAM | b0.param_start + q);
        }
        if !same {
            break;
        }
        out.push(lev << 32 | call.a as u64);
        k = b.edge_target(tm.c);
    }
    return sym;
}

// Body `b` without the first `n` steps of its CPU-level check (`dispatch_of`): each one's branch jumps to
// its other side, the level byte's read and the comparisons dead constants.
fn strip_dispatch(b: &mut Body, n: usize) {
    let mut k: u32 = 0;
    for _ in 0..n {
        let bk = b.blocks[k as usize];
        let at = bk.start + bk.len - 1;
        let tm = b.insts[at as usize];
        if tm.op != O_BR || (tm.a & (VPARAM | VFLAG)) != 0 || b.insts[tm.a as usize].op != O_ICMP {
            break;
        }
        let c = b.insts[tm.a as usize];
        if (c.a & (VPARAM | VFLAG)) == 0 && b.insts[c.a as usize].op == O_ALOAD {
            b.insts[c.a as usize] = Inst { op: O_ICONST, ty: T_I8, aux: 0, a: 0, b: 0, c: 0 };
        }
        b.insts[tm.a as usize] = Inst { op: O_ICONST, ty: T_I8, aux: 0, a: 0, b: 0, c: 0 };
        b.insts[at as usize] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: tm.c, b: 0, c: 0 };
        k = b.edge_target(tm.c);
    }
}

extend Gen {
    /// Compile the body of package function symbol `s` into the object. False (with `err`) when the
    /// body uses what the generator does not compile. A body that opens with its run-time copies'
    /// CPU-level check (`dispatch_of`) compiles without it under the local name `<name>.base`, and its
    /// symbol is the check that jumps to each copy with the arguments as they arrived (`dispatcher`).
    pub(package) fn func(self: &mut Self, s: u32, local: bool) bool {
        let p = unsafe &*self.pkg;
        let b = &p.bodies[p.syms[s as usize].def as usize];
        self.disp_lv = dispatch_of(p, b, &mut self.disp);
        if self.disp.len() == 0 {
            return self.func_body(s, local);
        }
        self.disp_body = b.compact();
        strip_dispatch(&mut self.disp_body, self.disp.len());
        self.base = true;
        let ok = self.func_body(s, local);
        self.base = false;
        return ok && self.dispatcher(s, local);
    }

    // `cmp byte ptr [level], k; jae copy` per run-time copy, the highest first (`disp`), then `jmp` the body
    // without the check (`<name>.base`), as function symbol `s`: no frame, no argument moved; on Microsoft
    // x64 a leaf, which needs no unwind information.
    fn dispatcher(self: &mut Self, s: u32, local: bool) bool {
        self.c.clear();
        self.rels.truncate(0);
        let p = unsafe &*self.pkg;
        let ly = p.syms[self.b().syms[self.disp_lv as usize] as usize];
        // The byte's own address (`sym_addr`'s direct case): read RIP-relative; else through r11.
        let direct = !ly.ext && !(p.pic && ly.linkage == SL_GLOBAL);
        if !direct {
            self.sym_addr(S1, self.disp_lv, 0);
        }
        for q in 0..self.disp.len() {
            // cmp byte ptr [rip + level] or [r11], k; jae rel32
            let d = self.disp[q];
            if direct {
                self.c.byte(0x80);
                self.c.byte(0x3D);
                let at = self.c.len();
                self.c.d32(0);
                let os = self.osym_of(self.disp_lv);
                self.rels.push(CRel { at: at, kind: x::R_PC32, sym: os, addend: -5 });
            } else {
                self.c.byte(0x41);
                self.c.byte(0x80);
                self.c.byte(0x3B);
            }
            self.c.byte((d >> 32) as u8);
            self.c.byte(0x0F);
            self.c.byte(0x83);
            let at = self.c.len();
            self.c.d32(0);
            let os = self.osym_of(d as u32);
            self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: os, addend: -4 });
        }
        let ps = p.syms[s as usize];
        let base = format("{}.base", p.spell(ps.name));
        let bs = self.obj().sym(&base);
        self.tail_jump(bs);
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true)
        } else if ps.cold {
            o.named(self.cold_text(), true)
        } else {
            ob::S_TEXT
        };
        if sec == ob::NOSEC {
            return self.refuse("too many sections");
        }
        let mut fl = ob::SF_FUNC | if ps.linkage == SL_GLOBAL && !local {
            ob::SF_GLOBAL
        } else {
            0
        };
        if ps.used {
            fl |= ob::SF_USED;
        }
        let size = self.c.len();
        let at = o.define(k2, sec, 4, size, fl);
        o.put(sec, self.c.b[0..self.c.b.len()]);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + r.at, r.sym, r.addend);
        }
        if !self.win {
            // A leaf's rule: the CFA rsp + 8.
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: o.cfi.len() as u32, cfi_len: 0 });
        }
        return true;
    }

    fn func_body(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        self.sc_self = self.sc_conv(s);
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        self.bp = if self.base {
            &self.disp_body
        } else {
            &p.bodies[ps.def as usize]
        };
        let b = self.b();
        self.lv.fold_max = 8;
        self.lv.fold_ops = lv::FOLD_CMP | lv::FOLD_TST | lv::FOLD_UBFX | lv::FOLD_RMW | lv::FOLD_ROT | lv::FOLD_ROT_NARROW | lv::FOLD_LEA | lv::FOLD_SHAMT | lv::FOLD_SHAMT_EXT | lv::FOLD_BLEN | lv::FOLD_CARRY | lv::FOLD_FSEL | lv::FOLD_LDOP | lv::FOLD_ANY | lv::FOLD_VSHIMM | lv::FOLD_XADDR | lv::FOLD_BRCONJ | lv::FOLD_TRUNC | lv::FOLD_ADC | lv::FOLD_LANE | lv::FOLD_LANE0 | lv::FOLD_ZSHL | lv::FOLD_VSAD | if self.avx {
            lv::FOLD_ANY_WIDE | lv::FOLD_VSHIMM_WIDE
        } else {
            0
        };
        // A compilation again (`again`: without shrink-wrapping, or with far branches) keeps the relays, the
        // canary and the analysis of the body but its layout.
        if self.again {
            self.again = false;
            self.lv.after.truncate(0);
            self.lv.relayout(b);
        } else {
            intrin::of_symbols(unsafe &*self.pkg, b, "x86_64", &mut self.itpl);
            if unsafe (*self.pkg).sse41 {
                intrin::x64_sse41(unsafe &*self.pkg, b, &mut self.itpl);
            }
            self.lay_sig.truncate(0);
            arg_relays(self);
            self.prot = lver::protected(unsafe (*self.pkg).protect, b);
            self.opf = lv::op_flags(b);
            self.lv.after.truncate(0);
            self.lv.run(b);
        }
        self.shrink = !self.no_shrink && self.shrinkable();
        if self.shrink {
            self.lv.relayout(b);
            // A shrink-wrapped body places no code past its blocks: each late edge moves in place.
            self.lv.late.truncate(0);
        }
        let n = self.lv.end.len();
        self.va.truncate(0);
        self.va.reserve(n);
        for _ in 0..n {
            self.va.push(Va { reg: NOREG, home: H_NONE, dirty: false, clean: false, off: 0 });
        }
        for k in 0..b.insts.len() {
            if self.remat_inst(k as u32) {
                self.va.index_mut(k).home = H_REMAT;
            }
        }
        fill(&mut self.owner, 32, NONE);
        fill(&mut self.heir, 32, NONE);
        self.held = 0;
        // Past the blocks, one per late edge: its stub (`lv::Live::late`).
        fill(&mut self.blk_at, b.blocks.len() + self.lv.late.len(), NONE);
        self.late_va.truncate(0);
        self.stubs_out = self.lv.late.len() == 0;
        self.c.clear();
        self.zf.at = NONE;
        self.fused = NONE;
        self.cmp_at = NONE;
        self.held_end = NONE;
        self.fix.truncate(0);
        self.epi.truncate(0);
        self.stop = NONE;
        self.tails.truncate(0);
        self.tail_ret = NONE;
        self.div_pair = NONE;
        self.div_mul = NONE;
        self.mul_twin = NONE;
        self.zero_from = 0;
        self.zero_end = 0;
        self.rels.truncate(0);
        self.kcon.truncate(0);
        self.kwords.truncate(0);
        self.free_slots.truncate(0);
        self.taken.truncate(0);
        self.shared.truncate(0);
        self.called = false;
        self.sret_lost = false;
        self.resv = if self.sret_keep {
            bit(self.arg(0))
        } else {
            0
        };
        self.ymm = false;
        self.yvals.truncate(0);
        self.yblk.truncate(0);
        if self.avx {
            self.yblk.resize_default(b.blocks.len());
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                for i in bk.start..bk.start + bk.len {
                    if is_vec(b.insts[i as usize].ty) && type_bytes(b.insts[i as usize].ty, 8) >= 32 {
                        self.yvals.push(i);
                        self.yblk[k] = true;
                    }
                }
                for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                    if is_vec(b.params[q as usize]) && type_bytes(b.params[q as usize], 8) >= 32 {
                        self.yvals.push(b.insts.len() as u32 + q);
                        self.yblk[k] = true;
                    }
                }
            }
            // A block that reads one in a register defines none, as a store or a reduction.
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                for i in bk.start..bk.start + bk.len {
                    lv::each_use(b, b.insts[i as usize], &mut self.uses);
                    for u in 0..self.uses.len() {
                        let v = self.uses[u];
                        self.yblk[k] = self.yblk[k] || v != VNONE && is_vec(b.type_of(v)) && type_bytes(b.type_of(v), 8) >= 32;
                    }
                }
            }
            self.ymm = self.yvals.len() != 0;
        }
        self.dying.truncate(0);
        self.lock = 0;
        self.tmps = 0;
        self.fixed_busy = 0;
        self.csr = 0;
        self.rows.truncate(0);
        self.cond = Cond { inst: NONE, cc: 0 };
        if b.naked {
            return self.naked(s);
        }
        self.frame_layout();
        // Without a frame pointer rbp holds values; a frame aligned past 16 bytes or inline assembly, which
        // may name rbp, keeps it.
        let omit = p.omit_fp && self.max_align <= 16 && (self.opf & lv::OP_ASM) == 0;
        let va = (self.opf & lv::OP_VASTART) != 0;
        self.fb = ast_pick(omit, x::IN, x::RBP);
        self.xfix = if self.win {
            XFIX_WIN
        } else {
            XFIX_SYSV
        } | if omit {
            bit(x::RBP)
        } else {
            0
        };
        classify(self.win, self.sc_self, b, b.sig, self.ptr, self.vregs, &mut self.self_lay);
        if self.self_lay.unknown {
            return self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        // Sibling calls leave the frame first: none with a canary to check, variadic arguments in it, or the
        // address of a slot or of an aggregate parameter that arrives in registers that may outlive it.
        place::held_params(b, &self.self_lay, &mut self.pheld);
        self.tail_ok = p.tail && self.canary < 0 && !va && !lver::frame_escapes(b, &self.pheld);
        self.pass_parts();
        self.bucket_ends();
        self.call_tables();
        self.lv.split = !self.shrink;
        self.plan_homes();
        self.split_at = 0;
        fill(&mut self.split_off, n, -1);
        for j in 0..self.lv.splits.len() {
            let x = self.lv.splits[j] as u32;
            let sz = type_bytes(self.xty(x), self.ptr);
            self.split_off[x as usize] = self.slot_alloc(sz.max(8), sz.min(16)) as i32;
        }
        if self.shrink && self.lv.homeless(&self.want) {
            return self.unshrunk(s, local);
        }
        self.entry();
        if self.err.len() != 0 {
            return false;
        }
        for q in 0..self.lv.order.len() {
            if !self.block(q as u32) {
                return false;
            }
        }
        assert(self.fixed_busy == 0, "x64gen: a register home outlives its value");
        if !self.stubs_out {
            self.late_stubs();
        }
        if self.shrink && (self.c.stack_at < self.rare_at() || self.csr != 0) {
            return self.unshrunk(s, local);
        }
        let rt = b.pool[b.sig as usize + 2];
        if self.sret_keep && self.sret_lost {
            return false;
        }
        // No call in the blocks the code lays out (an intrinsic's moves its arguments into their registers too),
        // system call or assembly.
        let mut calls = false;
        for q in 0..self.lv.order.len() {
            let bk = b.blocks[self.lv.order[q] as usize];
            for i in bk.start..bk.start + bk.len {
                calls = calls || b.insts[i as usize].op == O_CALL || b.insts[i as usize].op == O_CALLIND;
            }
        }
        if !self.sret_keep && !self.no_keep && self.self_lay.ret.kind == ab::L_SRET && (rt & AGG) == 0 && !calls && (self.opf & (lv::OP_ASM | lv::OP_SYS)) == 0 {
            return self.kept_sret(s, local);
        }
        return self.finish(s);
    }

    // The body again with its result's pointer kept in the register it arrives in, which no value takes
    // (`sret_keep`); when an instruction needs that register (`sret_lost`), again with the pointer in its slot.
    fn kept_sret(self: &mut Self, s: u32, local: bool) bool {
        self.sret_keep = true;
        self.again = true;
        let ok = self.func_body(s, local);
        self.sret_keep = false;
        if ok || !self.sret_lost {
            return ok;
        }
        self.err.truncate(0);
        self.no_keep = true;
        self.again = true;
        let ok2 = self.func_body(s, local);
        self.no_keep = false;
        return ok2;
    }

    // The warm code of shrink-wrapped function `s` needs the frame: once more, with the frame set up at the
    // entry.
    fn unshrunk(self: &mut Self, s: u32, local: bool) bool {
        self.no_shrink = true;
        self.again = true;
        let ok = self.func_body(s, local);
        self.no_shrink = false;
        return ok;
    }

    // Whether the body may set its frame up in its rare blocks alone (`shrink`): every call (one that does
    // not return too, a panic's: it needs the frame's alignment) is in a rare block (`Live::rare`), there is one, and
    // the body reads no return address, variadic argument or inline assembly, runs no system operation,
    // aligns no slot past 16 bytes and has no canary. The rare blocks connected to one with a call by edges
    // between rare blocks set the frame up: `Live::after`, which the layout puts after the others. Under
    // Microsoft x64 no edge leaves them for the warm code: its unwinder reads an epilogue only where it
    // ends in `ret` or a jump out of the function.
    fn shrinkable(self: &mut Self) bool {
        let b = self.b();
        if self.prot || self.opf != 0 {
            return false;
        }
        for k in 0..b.slots.len() {
            if b.slots[k].align_log2 > 4 {
                return false;
            }
        }
        let mut framed = Vector::<bool>::new();
        framed.resize_default(b.blocks.len());
        let mut any = false;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let d = self.lv.def_blk[i];
            // A copy that may be a sibling call needs no frame (`mem_tail_shape`).
            if d == NONE || self.lv.pos[d as usize] == NONE || !self.calls(t) && t.op != O_PANIC || self.mem_tail_shape(
                i as u32,
                t,
            ) {
                continue;
            }
            if !self.lv.rare[d as usize] {
                return false;
            }
            framed[d as usize] = true;
            any = true;
        }
        if !any {
            return false;
        }
        self.lv.set_after(b, &framed);
        if self.win {
            let mut es = Vector::<u32>::new();
            for k in 0..b.blocks.len() {
                if !self.lv.after[k] || self.lv.pos[k] == NONE {
                    continue;
                }
                b.succ_edges(b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize], &mut es);
                for e in 0..es.len() {
                    if !self.lv.after[b.edge_target(es[e]) as usize] {
                        self.lv.after.truncate(0);
                        return false;
                    }
                }
            }
        }
        return true;
    }

    // The first code byte of the blocks that set the frame up, which the layout puts last (`Live::after`);
    // the code's length when there is none.
    const fn rare_at(self: &Self) u32 {
        for q in 0..self.lv.order.len() {
            let k = self.lv.order[q] as usize;
            if self.lv.after[k] && self.blk_at[k] != NONE {
                return self.blk_at[k];
            }
        }
        return self.c.len();
    }

    // Whether block `k` is on the other side of the frame's edge from the current one (`shrink`).
    const fn crosses(self: &Self, k: u32) bool {
        return self.shrink && self.lv.after[k as usize] != self.lv.after[self.lv.order[self.pos as usize] as usize];
    }

    // The outgoing argument area (the largest call's stack arguments), then the LIR slots; spills follow.
    fn frame_layout(self: &mut Self) {
        let b = self.b();
        let mut out: u32 = 0;
        for k in 0..b.insts.len() {
            let t = b.insts[k];
            if t.op == O_CALL || t.op == O_CALLIND {
                self.call_layout(t);
                if self.lay.unknown {
                    let _ = self.refuse("a call passes an aggregate whose C class is unknown");
                }
                if self.lay.stack_bytes > out {
                    out = self.lay.stack_bytes;
                }
            }
        }
        if self.win && out < 32 {
            // The callee's home area for every call, the runtime's too.
            out = 32;
        }
        self.out_size = out;
        self.max_align = 16;
        self.sret_off = -1;
        self.save_off = -1;
        fill(&mut self.slot_off, b.slots.len(), 0);
        let mut at = out;
        for k in 0..b.slots.len() {
            // A slot whose stores relay (`arg_relays`) has no memory access.
            if self.lv.relays_slot(b, k as u32) {
                continue;
            }
            let sl = b.slots[k];
            let al = 1u32 << sl.align_log2 as u32;
            if al > self.max_align {
                self.max_align = al;
            }
            at = at + al - 1 & ~(al - 1);
            self.slot_off[k] = at;
            at += sl.size;
        }
        // The canary between the slots and the spills and saved registers above them.
        self.canary = -1;
        if self.prot {
            at = at + 7 & ~7u32;
            self.canary = at;
            at += 8;
        }
        self.spill_base = at + 15 & ~15u32;
        self.spill_top = 0;
    }

    // `ends`: the values grouped by the position their range ends at.
    fn bucket_ends(self: &mut Self) {
        let np = self.lv.order.len();
        fill(&mut self.ends_at, np + 1, 0);
        for x in 0..self.lv.end.len() {
            if self.lv.def_blk[x] != NONE && self.lv.pos[self.lv.def_blk[x] as usize] != NONE {
                self.ends_at[self.lv.end[x] as usize + 1] += 1;
            }
        }
        for q in 0..np {
            self.ends_at[q + 1] += self.ends_at[q];
        }
        fill(&mut self.ends, self.ends_at[np] as usize, 0);
        let mut fillp = Vector::<u32>::with_capacity(np + 1);
        fillp.extend_copy(&self.ends_at);
        for x in 0..self.lv.end.len() {
            if self.lv.def_blk[x] != NONE && self.lv.pos[self.lv.def_blk[x] as usize] != NONE {
                let e = self.lv.end[x] as usize;
                self.ends[fillp[e] as usize] = x as u32;
                fillp[e] += 1;
            }
        }
    }

    // The entry block's parameters where the calling convention passes them.
    fn entry(self: &mut Self) {
        let b = self.b();
        if self.canary >= 0 {
            self.guard(S1);
            self.c.store(8, S1, x::at(x::RSP, self.canary as i32));
        }
        self.ret_stores();
        self.res_relays();
        let np = b.pool[b.sig as usize];
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        if (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 && self.win {
            // The four argument registers into their home area, which the stack arguments continue.
            for k in 0..4u32 {
                self.c.store(8, w64::gp_arg(k), x::at(self.fb, 16 + 8 * k as i32));
            }
        } else if (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 {
            // The register save area `va_arg` reads: the six integer argument registers, then xmm0..xmm7.
            let off = self.slot_alloc(176, 16) as i32;
            self.save_off = off;
            for k in 0..6 {
                self.c.store(8, cc::gp_arg(k as u32), x::at(x::RSP, off + 8 * k));
            }
            for k in 0..8u32 {
                self.c.vstore(16, k as u8, x::at(x::RSP, off + 48 + 16 * k as i32));
            }
        }
        // A result in memory: the first argument register's pointer, which the return gives back in rax.
        let rt = b.pool[b.sig as usize + 2];
        if self.self_lay.ret.kind == ab::L_SRET && (rt & AGG) == 0 && !self.sret_keep {
            self.sret_off = self.slot_alloc(8, 8);
            self.c.store(8, self.arg(0), x::at(x::RSP, self.sret_off as i32));
        }
        // No parameter's home takes a register another one arrives in; the argument registers no
        // parameter arrives in may be homes.
        if self.self_lay.ret.kind == ab::L_SRET {
            self.lock |= bit(self.arg(0));
        }
        for k in 0..np {
            let loc = self.self_lay.locs[k as usize];
            if loc.kind == ab::L_REG || loc.kind == ab::L_REF_REG {
                for q in 0..loc.n as u32 {
                    let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                    self.lock |= bit(pa.reg + ast_pick(pa.v, V0, 0));
                }
            }
        }
        for k in 0..np {
            let x = ni + e0 + k;
            let pt = b.pool[(b.sig + 3 + k) as usize];
            let loc = self.self_lay.locs[k as usize];
            let t = self.xty(x);
            let agg = (pt & AGG) != 0;
            if loc.kind == ab::L_STACK {
                // An aggregate's address, or the value (a memory value in place) in the caller's memory.
                let home = if agg {
                    H_FPADDR
                } else {
                    H_ARG
                };
                self.va.index_mut(x as usize).home = home;
                self.va.index_mut(x as usize).off = (16 + loc.off) as i32;
            } else if loc.kind == ab::L_REF_STACK || loc.kind == ab::L_REF_REG {
                // A pointer to the caller's copy: an aggregate's address, or a memory value copied into
                // its slot (through r11 when the pointer is on the stack).
                let mut r = S1;
                if loc.kind == ab::L_REF_REG {
                    r = self.self_lay.parts[loc.p0 as usize].reg;
                } else if agg {
                    self.va.index_mut(x as usize).home = H_ARG;
                    self.va.index_mut(x as usize).off = (16 + loc.off) as i32;
                    continue;
                } else {
                    self.c.load(8, false, S1, x::at(self.fb, 16 + loc.off as i32));
                }
                if agg {
                    self.entry_reg(x, r);
                } else if self.in_reg(t) {
                    // A vector loaded into its home, else a register it spills from.
                    if self.lv.uses[x as usize] != 0 {
                        let mut f = self.take_home(x, true, NOREG);
                        if f == NOREG {
                            f = self.alloc(true);
                            self.set_owner(f, x);
                            self.va.index_mut(x as usize).reg = f;
                            self.va.index_mut(x as usize).dirty = true;
                        }
                        self.lock |= bit(f);
                        self.c.vload(type_bytes(t, self.ptr), f - V0, x::at(r, 0));
                    }
                } else {
                    let sz = type_bytes(t, self.ptr);
                    let off = self.slot_alloc(sz, 16);
                    self.copy_mem(x::RSP, off, r, 0, sz);
                    self.va.index_mut(x as usize).home = H_SLOT;
                    self.va.index_mut(x as usize).off = off as i32;
                }
            } else if agg && (self.va[x as usize].home == H_PASSED || self.parts_taken(x, loc)) {
                continue;
            } else if agg || in_mem(t) && !self.self_lay.whole_vreg(loc, t) {
                // Register parts into a slot: the aggregate's memory, or the memory value.
                let (size, _) = sig_size(b, pt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                for q in 0..loc.n as u32 {
                    let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                    self.store_part(pa, x::RSP, off as i64 + pa.off as i64);
                }
                self.va.index_mut(x as usize).home = if agg {
                    H_SPADDR
                } else {
                    H_SLOT
                };
                self.va.index_mut(x as usize).off = off as i32;
            } else {
                let pa = self.self_lay.parts[loc.p0 as usize];
                self.entry_reg(
                    x,
                    pa.reg + if pa.v {
                        V0
                    } else {
                        0
                    },
                );
            }
        }
        if (rt & AGG) != 0 {
            let x = ni + e0 + np;
            if self.self_lay.ret.kind == ab::L_SRET {
                self.entry_reg(x, self.arg(0));
            } else if !self.ret_moved() {
                let (size, _) = sig_size(b, rt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                self.va.index_mut(x as usize).home = H_SPADDR;
                self.va.index_mut(x as usize).off = off as i32;
            }
        }
        self.lock = 0;
    }

    // Whether the aggregate parameter `x`, passed in registers (`loc`), is read only by loads of the entry
    // block that each read one part whole, before any instruction that may call (which writes the argument
    // registers): each load then takes its part's register (`taken`), and the aggregate needs no memory.
    fn parts_taken(self: &mut Self, x: u32, loc: ab::ALoc) bool {
        let mark = self.taken.len();
        if !place::parts_taken(
            self.b(),
            &self.lv,
            &self.self_lay,
            self.ptr,
            Gen::clobbers,
            x,
            loc,
            &mut self.taken,
            &mut self.uses,
        ) {
            return false;
        }
        for q in mark..self.taken.len() {
            let i = self.taken[q] as u32;
            let pa = self.self_lay.parts[(loc.p0 + (self.taken[q] >> 32) as u32) as usize];
            self.entry_reg(
                i,
                pa.reg + if pa.v {
                    V0
                } else {
                    0
                },
            );
        }
        return true;
    }

    // The aggregate parameters whose one use is an argument of a call (no intrinsic) that takes it by
    // value in registers of the same parts (`place::parts_passed`): that call takes the parts from the
    // registers they arrive in, held until it (`pin`, in `fixed_busy`; `plan_homes` leaves the
    // instructions before it room), and the parameter (`H_PASSED`) takes no memory.
    fn pass_parts(self: &mut Self) {
        let b = self.b();
        self.pin = 0;
        fill(&mut self.pin_reg, self.self_lay.parts.len(), NOREG);
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        for k in 0..b.pool[b.sig as usize] {
            let pl = self.self_lay.locs[k as usize];
            let x = ni + e0 + k;
            if (b.pool[(b.sig + 3 + k) as usize] & AGG) == 0 || pl.kind != ab::L_REG {
                continue;
            }
            let i = place::parts_passed(b, &self.lv, Gen::clobbers, x, &mut self.uses);
            if i == NONE {
                continue;
            }
            let t = b.insts[i as usize];
            if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
                continue;
            }
            // A thread-local address before it that calls `__tls_get_addr` (`tls_call`) takes the registers too.
            let mut gd = false;
            for q in b.blocks[0].start..i {
                gd = gd || self.tls_call(b.insts[q as usize]);
            }
            if gd {
                continue;
            }
            self.call_layout(t);
            let mut same = false;
            for j in 0..b.pool[t.b as usize] {
                let cl = self.lay.locs[j as usize];
                if b.pool[(t.c + j) as usize] != (VPARAM | e0 + k) || (b.pool[(t.b + 3 + j) as usize] & AGG) == 0 || cl.kind != ab::L_REG || cl.n != pl.n {
                    continue;
                }
                same = true;
                for p in 0..pl.n as u32 {
                    let pa = self.lay.parts[(cl.p0 + p) as usize];
                    let ps = self.self_lay.parts[(pl.p0 + p) as usize];
                    same = same && pa.off == ps.off && pa.size == ps.size && pa.v == ps.v;
                }
            }
            // At most 4 general registers held: an instruction before the call may need 8 of the 12 (`need`).
            let mut gp = (self.pin & self.xalloc).count_ones() as u32;
            for p in pl.p0..pl.p0 + pl.n as u32 {
                gp += (!self.self_lay.parts[p as usize].v) as u32;
            }
            if !same || gp > 4 {
                continue;
            }
            for p in pl.p0..pl.p0 + pl.n as u32 {
                let ps = self.self_lay.parts[p as usize];
                let r = ps.reg + ast_pick(ps.v, V0, 0);
                self.pin_reg[p as usize] = r;
                self.pin |= bit(r);
            }
            self.va.index_mut(x as usize).home = H_PASSED;
            self.va.index_mut(x as usize).off = k as i32;
        }
        self.fixed_busy |= self.pin;
    }

    // Parameter value index `x` arrives in register `r`.
    fn entry_reg(self: &mut Self, x: u32, r: u8) {
        if self.lv.uses[x as usize] == 0 {
            return;
        }
        let t = self.xty(x);
        let f = self.take_home(x, is_v(t) || is_vec(t), r);
        if f != NOREG {
            self.move_reg(t, f, r);
            return;
        }
        self.set_owner(r, x);
        let va = self.va.index_mut(x as usize);
        va.reg = r;
        va.dirty = true;
    }

    // Compile the block at layout position `q`.
    fn block(self: &mut Self, q: u32) bool {
        // The late edges' stubs at the first place no block falls into, once their targets are compiled.
        if !self.stubs_out && self.ends_jump() && self.late_ready(q) {
            self.late_stubs();
        }
        self.pos = q;
        while self.split_at < self.lv.splits.len() && (self.lv.splits[self.split_at] >> 32) as u32 == q {
            let x = self.lv.splits[self.split_at] as u32;
            let va = self.va[x as usize];
            if va.reg != NOREG && self.owner[va.reg as usize] == x {
                self.set_owner(va.reg, NONE);
                self.fixed_busy &= ~bit(va.reg);
            }
            let w = self.va.index_mut(x as usize);
            w.home = H_SLOT;
            w.reg = NOREG;
            w.off = self.split_off[x as usize];
            w.dirty = false;
            self.split_at += 1;
        }
        let k = self.lv.order[q as usize];
        let b = self.b();
        self.blk_at[k as usize] = self.c.len();
        // A late edge's target: its parameters' homes, for its stub.
        for j in 0..self.lv.late.len() {
            if b.edge_target(self.lv.late[j] as u32) == k {
                let bk = b.blocks[k as usize];
                for p in bk.param_start..bk.param_start + bk.param_len as u32 {
                    let x = b.insts.len() as u32 + p;
                    self.late_va.push((x, self.va[x as usize]));
                }
                break;
            }
        }
        if !self.continues(q) {
            let mut m = self.held;
            // Each step clears one register's bit: at most 64 steps.
            while m != 0 {
                let r = m.trailing_zeros() as u8;
                m &= m - 1;
                let x = self.owner[r as usize];
                if self.va[x as usize].home != H_FIXED {
                    self.va.index_mut(x as usize).reg = NOREG;
                    self.va.index_mut(x as usize).dirty = false;
                    self.set_owner(r, NONE);
                }
            }
        }
        let bk = b.blocks[k as usize];
        if self.upper_entry(q, k) {
            self.c.vzeroupper();
        }
        let dbg = unsafe (*self.pkg).debug;
        for i in bk.start..bk.start + bk.len {
            if dbg {
                place::row(&mut self.rows, self.c.len(), b.locs[i as usize]);
            }
            self.begin_inst(i);
            if self.fused != NONE {
                if i == self.fused {
                    self.fused = NONE;
                }
                self.end_inst();
                continue;
            }
            let saved = self.save_scratch(i);
            if !self.inst(i) {
                return false;
            }
            self.restore_scratch(saved);
            self.end_inst();
        }
        // The values whose range ends here.
        for j in self.ends_at[q as usize]..self.ends_at[q as usize + 1] {
            let x = self.ends[j as usize];
            if self.va[x as usize].reg != NOREG || self.va[x as usize].home == H_SLOT || self.va[x as usize].home == H_FIXED {
                self.release(x);
            }
        }
        return true;
    }

    // Whether the block at position `q` keeps the register state: its only predecessor is the block
    // before it in the layout.
    const fn continues(self: &Self, q: u32) bool {
        return self.lv.continues(self.b(), q);
    }

    // Before a block's branch: every value live into a successor that does not keep the register state
    // is in its home. A value is live into the block at position `s` when its range holds `s` and starts
    // before it.
    fn spill_live_out(self: &mut Self) {
        let b = self.b();
        let k = self.lv.order[self.pos as usize];
        let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
        let ne = nedges(t);
        self.save_splits(t, ne);
        let mut m = self.held;
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            let x = self.owner[r as usize];
            if !self.va[x as usize].dirty || self.lv.end[x as usize] <= self.pos {
                continue;
            }
            let dp = self.lv.pos[self.lv.def_blk[x as usize] as usize];
            let mut need = false;
            for e in 0..ne {
                let sb = b.edge_target(lv::edge_of(b, t, e));
                let sp = self.lv.pos[sb as usize];
                if sp == self.pos + 1 && self.continues(sp) {
                    continue;
                }
                need = need || dp < sp && sp <= self.lv.end[x as usize];
            }
            if need {
                self.spill(x);
            }
        }
    }

    // Every edge leaving a register prefix writes the suffix's stack home, including edges that
    // skip the cut's block. No edge can return from the suffix to the prefix.
    fn save_splits(self: &mut Self, t: Inst, ne: u32) {
        let b = self.b();
        let mut end = self.pos;
        for e in 0..ne {
            end = end.max(self.lv.pos[b.edge_target(lv::edge_of(b, t, e)) as usize]);
        }
        for j in self.split_at..self.lv.splits.len() {
            let entry = self.lv.splits[j];
            if (entry >> 32) as u32 > end {
                break;
            }
            let x = entry as u32;
            if self.lv.pos[self.lv.def_blk[x as usize] as usize] > self.pos {
                continue;
            }
            let ty = self.xty(x);
            let va = self.va[x as usize];
            let r = if va.reg != NOREG {
                va.reg
            } else {
                let scratch = if is_v(ty) || is_vec(ty) {
                    self.vs0
                } else {
                    S0
                };
                self.materialize(self.xval(x), scratch);
                scratch
            };
            self.st(ty, r, x::at(x::RSP, self.split_off[x as usize]));
        }
    }

    // The homes of the parameters terminator `t`'s edges write, chosen before its branch: what a home's
    // register held moves to its own home on every path.
    fn edge_homes(self: &mut Self, t: Inst) {
        let b = self.b();
        let ni = b.insts.len() as u32;
        let ne: u32 = if t.op == O_JMP {
            1
        } else if t.op == O_BR {
            2
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1
        } else {
            0
        };
        for e in 0..ne {
            let ed = lv::edge_of(b, t, e);
            // A late edge's target takes its homes at an edge after the loop.
            if self.lv.late_index(self.lv.order[self.pos as usize], ed) != NONE {
                continue;
            }
            let tb = b.blocks[b.edge_target(ed) as usize];
            for q in 0..tb.param_len as u32 {
                let x = ni + tb.param_start + q;
                // The return register when no home holds it, else the register home of an argument that dies
                // here, given up: kept busy again when the parameter does not take it (its class is another),
                // as the argument holds it until the edge moves.
                let mut r = self.ret_reg(b, x);
                if r != NOREG && (self.fixed_busy & bit(r)) != 0 {
                    r = NOREG;
                }
                let hd = r == NOREG;
                if hd {
                    r = self.home_dying(b.edge_arg(ed, q));
                }
                if r != NOREG {
                    self.free_home(b.edge_arg(ed, q), r);
                }
                self.param_home(
                    x,
                    if r != NOREG {
                        r
                    } else {
                        self.dying_reg(b.edge_arg(ed, q))
                    },
                );
                if hd && r != NOREG && self.va[x as usize].reg != r {
                    self.fixed_busy |= bit(r);
                }
            }
        }
    }

    // Edge argument `v`, when register `r` is its home and it dies at this terminator, gives `r` up: the
    // parameter that takes `r` then holds it, and the edge moves nothing.
    fn free_home(self: &mut Self, v: Value, r: u8) {
        let x = self.vx(v);
        if x == NONE {
            return;
        }
        let va = self.va[x as usize];
        if va.home == H_FIXED && va.reg == r && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            self.fixed_busy &= ~bit(r);
        }
    }

    // The return register when block parameter value index `x` is an integer whose one use returns it from
    // its block: there it needs no move. NOREG else.
    fn ret_reg(self: &Self, b: &Body, x: u32) u8 {
        let d = self.lv.def_blk[x as usize];
        let bk = b.blocks[d as usize];
        let t = b.insts[(bk.start + bk.len - 1) as usize];
        let rl = self.self_lay.ret;
        if self.lv.uses[x as usize] != 1 || t.op != O_RET || t.a != (VPARAM | x - b.insts.len() as u32) || rl.kind != ab::L_REG || rl.n != 1 || self.self_lay.parts[rl.p0 as usize].v {
            return NOREG;
        }
        return self.self_lay.parts[rl.p0 as usize].reg;
    }

    // The register home of edge argument `v` when `v` dies at this terminator, NOREG else.
    fn home_dying(self: &Self, v: Value) u8 {
        if v == VNONE {
            return NOREG;
        }
        let x = self.vx(v);
        if x == NONE {
            return NOREG;
        }
        let va = self.va[x as usize];
        // Not one a later parameter shares (`heir`, unless the parameter is `x`, which took the register
        // over), nor one that shares another's (`back_share`: the owner keeps it).
        return if va.home == H_FIXED && va.reg != NOREG && self.owner[va.reg as usize] == x && (self.heir[va.reg as usize] == NONE || self.heir[va.reg as usize] == x) && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            va.reg
        } else {
            NOREG
        };
    }

    // The register of edge argument `v` when it holds `v` without being its home and `v` dies at this
    // terminator: the parameter that takes it may keep it, and the edge then moves nothing. NOREG else.
    fn dying_reg(self: &Self, v: Value) u8 {
        if v == VNONE {
            return NOREG;
        }
        let x = self.vx(v);
        if x == NONE {
            return NOREG;
        }
        let va = self.va[x as usize];
        return if va.reg != NOREG && va.home != H_FIXED && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            va.reg
        } else {
            NOREG
        };
    }

    // The home of block parameter value index `x`, chosen at the first edge into its block: register
    // `prefer` when it may take it (`dying_reg`).
    fn param_home(self: &mut Self, x: u32, prefer: u8) {
        if self.va[x as usize].home != H_NONE {
            return;
        }
        let t = self.xty(x);
        // The register of the loop parameter it continues (`lv::Live::share`), which passes to it when that
        // parameter's range ends (`release`).
        let sp = self.lv.share[x as usize];
        if sp != NONE {
            self.param_home(sp, NOREG);
            let spa = self.va[sp as usize];
            if spa.home == H_FIXED {
                let va = self.va.index_mut(x as usize);
                va.home = H_FIXED;
                va.reg = spa.reg;
                va.dirty = false;
                self.heir[spa.reg as usize] = x;
                return;
            }
        }
        let px = back_share(self.b(), &self.lv, &self.va, x);
        if px != NONE {
            // The header parameter keeps the register's ownership and the slot: its range holds this
            // block's.
            let pva = self.va[px as usize];
            let va = self.va.index_mut(x as usize);
            va.home = pva.home;
            va.dirty = false;
            if pva.home == H_FIXED {
                va.reg = pva.reg;
            } else {
                va.off = pva.off;
                self.shared.push(x);
            }
            return;
        }
        if self.take_home(x, is_v(t) || self.in_reg(t), prefer) != NOREG {
            // The register holds nothing until the edge moves write it, or the dying argument it takes.
            self.set_owner(self.va[x as usize].reg, x);
            return;
        }
        let n = type_bytes(t, self.ptr);
        let off = self.slot_alloc(n, type_align(t, self.ptr));
        self.va.index_mut(x as usize).home = H_SLOT;
        self.va.index_mut(x as usize).off = off as i32;
    }

    // The location value index `x` is read from now.
    const fn loc_of(self: &Self, x: u32) Lc {
        return place::loc_of(&self.va, x, x::RSP, self.fb);
    }

    // Move edge `e`'s arguments into its target's parameter homes.
    fn edge_moves(self: &mut Self, e: u32) {
        let b = self.b();
        let n = b.edge_nargs(e);
        if n == 0 {
            return;
        }
        let tb = b.blocks[b.edge_target(e) as usize];
        let ni = b.insts.len() as u32;
        self.mv.truncate(0);
        for q in 0..n {
            let px = ni + tb.param_start + q;
            self.param_home(px, NOREG);
            let av = b.edge_arg(e, q);
            let ax = self.vx(av);
            if ax == px {
                continue;
            }
            let t = self.xty(px);
            let pva = self.va[px as usize];
            let dst = if pva.home == H_FIXED {
                Lc { kind: LC_REG, reg: pva.reg, off: 0, val: px }
            } else {
                Lc { kind: LC_MEM, reg: x::RSP, off: pva.off, val: px }
            };
            // A home the argument shares (`back_share`) already holds it.
            let src = self.loc_of(ax);
            if src.kind == dst.kind && src.reg == dst.reg && src.off == dst.off && src.kind != LC_VAL {
                continue;
            }
            self.mv.push(
                Mv { src: src, dst: dst, v: is_v(t) || in_mem(t), bytes: type_bytes(t, self.ptr), done: false },
            );
        }
        resolve_moves(self);
    }

    // The value of value index `x` (an instruction or a parameter).
    const fn xval(self: &Self, x: u32) Value {
        let ni = self.b().insts.len() as u32;
        if x < ni {
            return x;
        }
        return VPARAM | x - ni;
    }

    // Copy `n` bytes from `sb` + `so` to `db` + `do` through r10 and xmm14.
    fn copy_mem(self: &mut Self, db: u8, do0: i64, sb: u8, so0: i64, n: u32) {
        let mut at: u32 = 0;
        if n > 128 && !self.keep_flags {
            // Past 128 bytes a loop over 16-byte chunks, its index in a scratch register counting up to 0,
            // then the rest.
            let ix = if db == S1 || sb == S1 {
                S0
            } else {
                S1
            };
            assert(ix != db && ix != sb, "x64gen: a copy between the two scratch registers");
            at = n & ~15u32;
            self.c.mov_ri(ix, (at as u64).wrapping_neg());
            let top = self.c.len();
            self.c.vload(16, self.vs0 - V0, x::ix(sb, ix, 0, (so0 + at as i64) as i32));
            self.c.vstore(16, self.vs0 - V0, x::ix(db, ix, 0, (do0 + at as i64) as i32));
            self.c.alu_ri(x::ADD, 8, ix, 16);
            self.c.jcc_back(x::CC_NE, top);
        }
        // Chunks of 16, 8, 4, 2 and 1 bytes: at most 128 / 16 + 4 steps.
        while at < n {
            let left = n - at;
            let step = if left >= 16 {
                16u32
            } else if left >= 8 {
                8u32
            } else if left >= 4 {
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
            };
            let sm = x::at(sb, (so0 + at as i64) as i32);
            let dm = x::at(db, (do0 + at as i64) as i32);
            if step == 16 {
                self.c.vload(16, self.vs0 - V0, sm);
                self.c.vstore(16, self.vs0 - V0, dm);
            } else {
                self.c.load(step, false, S0, sm);
                self.c.store(step, S0, dm);
            }
            at += step;
        }
    }

    // Store register part `pa` (an argument or result register) to memory at `base` + `off`.
    fn store_part(self: &mut Self, pa: ab::Part, base: u8, off: i64) {
        let m = x::at(base, off as i32);
        if pa.v {
            if pa.size == 32 {
                self.c.ymov(false, pa.reg, m);
            } else if pa.size == 64 {
                self.c.zmov(false, pa.reg, m);
            } else if pa.size <= 4 {
                self.c.vstore(4, pa.reg, m);
            } else if pa.size <= 8 {
                self.c.vstore(8, pa.reg, m);
            } else {
                self.c.vstore(16, pa.reg, m);
            }
            return;
        }
        self.store_bytes(pa.reg, base, off, pa.size);
    }

    // Load register part `pa` from memory at `base` + `off`.
    fn load_part(self: &mut Self, pa: ab::Part, base: u8, off: i64) {
        let m = x::at(base, off as i32);
        if pa.v {
            if pa.size == 32 {
                self.c.ymov(true, pa.reg, m);
            } else if pa.size == 64 {
                self.c.zmov(true, pa.reg, m);
            } else if pa.size <= 4 {
                self.c.vload(4, pa.reg, m);
            } else if pa.size <= 8 {
                self.c.vload(8, pa.reg, m);
            } else {
                self.c.vload(16, pa.reg, m);
            }
            return;
        }
        self.load_bytes(pa.reg, base, off, pa.size);
    }

    // Store the low `n` (1 to 8) bytes of register `r`; r10 holds the shifted pieces of an odd size.
    fn store_bytes(self: &mut Self, r: u8, base: u8, off: i64, n: u32) {
        if n == 1 || n == 2 || n == 4 || n == 8 {
            self.c.store(n, r, x::at(base, off as i32));
            return;
        }
        let mut at: u32 = 0;
        let mut src = r;
        // Pieces of 4, 2, then 1 bytes.
        for _ in 0..3 {
            let left = n - at;
            if left == 0 {
                break;
            }
            let step = if left >= 4 {
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
            };
            self.c.store(step, src, x::at(base, (off + at as i64) as i32));
            at += step;
            if at < n {
                if src != S0 {
                    self.c.mov_rr(8, S0, src);
                    src = S0;
                }
                self.c.shift_ri(x::SHR, 8, S0, 8 * step);
            }
        }
    }

    // Load `n` (1 to 8) bytes into register `r`, zero-extended; r10 holds the upper pieces of an odd size.
    fn load_bytes(self: &mut Self, r: u8, base: u8, off: i64, n: u32) {
        if n == 1 || n == 2 || n == 4 || n == 8 {
            self.c.load(n, false, r, x::at(base, off as i32));
            return;
        }
        let mut at: u32 = 0;
        // Pieces of 4, 2, then 1 bytes.
        for _ in 0..3 {
            let left = n - at;
            if left == 0 {
                break;
            }
            let step = if left >= 4 {
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
            };
            if at == 0 {
                self.c.load(step, false, r, x::at(base, off as i32));
            } else {
                self.c.load(step, false, S0, x::at(base, (off + at as i64) as i32));
                self.c.shift_ri(x::SHL, 8, S0, 8 * at);
                self.c.alu_rr(x::OR, 8, r, S0);
            }
            at += step;
        }
    }
}

// The edge count of terminator `t`.
const fn nedges(t: Inst) u32 {
    if t.op == O_JMP {
        return 1;
    }
    if t.op == O_BR {
        return 2;
    }
    if t.op == O_SWITCH {
        return t.aux as u32 + 1;
    }
    return 0;
}

// The integer type of `n` bytes (1, 2, 4 or 8).
const fn int_type(n: u32) u8 {
    if n == 1 {
        return T_I8;
    }
    if n == 2 {
        return T_I16;
    }
    if n == 4 {
        return T_I32;
    }
    return T_I64;
}

// ---- Instructions ----

// The condition of integer comparison `c`.
const fn icond(c: u16) u32 {
    if c == C_EQ {
        return x::CC_E;
    }
    if c == C_NE {
        return x::CC_NE;
    }
    if c == C_SLT {
        return x::CC_L;
    }
    if c == C_SLE {
        return x::CC_LE;
    }
    if c == C_SGT {
        return x::CC_G;
    }
    if c == C_SGE {
        return x::CC_GE;
    }
    if c == C_ULT {
        return x::CC_B;
    }
    if c == C_ULE {
        return x::CC_BE;
    }
    if c == C_UGT {
        return x::CC_A;
    }
    return x::CC_AE;
}

// The width in bytes of an integer operation on `bits`-bit values: 4 below 64 bits.
const fn wsz(bits: u32) u32 {
    if bits == 64 {
        return 8;
    }
    return 4;
}

extend Gen {
    // Compile instruction `i`. False (with `err`) when it is outside what the generator compiles.
    fn inst(self: &mut Self, i: u32) bool {
        let t = self.b().insts[i as usize];
        let op = t.op;
        if self.va[i as usize].home == H_REMAT {
            return true;
        }
        if op == O_FCONST {
            let r = self.def(i);
            self.fconst(r, t.ty == T_F64, t.b as u64 << 32 | t.a as u64);
            return true;
        }
        if op == O_ICONST {
            let r = self.def(i);
            self.mov_imm(r, t.b as u64 << 32 | t.a as u64, type_bytes(t.ty, 8));
            return true;
        }
        if (op == O_SPLAT || op == O_WCONST) && self.lv.pfold[i as usize] {
            return true; // its shifts take it as an immediate (`lv::FOLD_VSHIMM`)
        }
        if op == O_VEXTRACT && self.lv.pfold[i as usize] {
            return true; // its splat reads the lane (`lv::FOLD_LANE`)
        }
        if op == O_WCONST && self.in_reg(t.ty) {
            self.wconst_reg(i, t);
            return true;
        }
        if op == O_WCONST {
            let off = self.mdef(i) as i32;
            // A word a sign-extended 32-bit immediate holds goes into memory as it is.
            for k in 0..t.b {
                let w = self.b().words[(t.a + k) as usize];
                if w as i64 >= -0x80000000 && w as i64 <= 0x7FFFFFFF {
                    self.c.mov_mi(8, x::at(x::RSP, off + 8 * k as i32), w as i32);
                } else {
                    self.c.mov_ri(S0, w);
                    self.c.store(8, S0, x::at(x::RSP, off + 8 * k as i32));
                }
            }
            return true;
        }
        if op == O_SYMADDR && (self.win || self.tls_local(t.a)) {
            // A thread-local variable's address: from the thread's block.
            let rd = self.def(i);
            self.sym_addr(rd, t.a, t.b as i32);
            return true;
        }
        if op == O_SYMADDR {
            // A thread-local variable's address: through a call.
            self.spill_for_call();
            self.sym_addr(x::RAX, t.a, t.b as i32);
            self.result_in(i, x::RAX);
            return true;
        }
        if op == O_SPLAT {
            self.splat(i, t);
            return true;
        }
        if op == O_VCMP {
            self.vcmp(i, t);
            return true;
        }
        if op == O_VSEL {
            self.vsel(i, t);
            return true;
        }
        if op == O_VUNZIP {
            self.vunzip(i, t);
            return true;
        }
        if op == O_VZIPLO || op == O_VZIPHI {
            self.vzip(i, t);
            return true;
        }
        if op == O_VEXTRACT || op == O_VINSERT {
            self.vlane(i, t);
            return true;
        }
        if op == O_HTOF || op == O_FTOH {
            self.half_conv(i, t);
            return true;
        }
        // A sum with a carry (`lv::FOLD_ADC`): its folded sum computes nothing; it adds with the carry.
        if self.lv.carry[i as usize] == lv::CARRY_PART {
            return true;
        }
        if self.lv.carry[i as usize] == lv::CARRY_ADC {
            self.adc(i, t);
            return true;
        }
        if op >= O_ADD && op <= O_NOT {
            let done = self.int_op(i, t);
            // A 32-bit operation clears the bits above.
            if t.ty == T_I32 && !self.lv.pfold[i as usize] {
                self.va.index_mut(i as usize).clean = true;
            }
            return done;
        }
        if op >= O_ADDO && op <= O_MULO {
            return self.ovf_op(i, t);
        }
        if op >= O_CLZ && op <= O_POPCNT {
            self.bit_count(i, t);
            return true;
        }
        if op == O_BSWAP {
            // 16 bits: the 32-bit reversal moves them to the top half.
            let bits = type_bits(t.ty, self.ptr);
            let sz = wsz(bits.max(32));
            let r = self.reg(t.a);
            let rd = self.def_over(i, t.a, r);
            if rd != r {
                self.c.mov_rr(sz, rd, r);
            }
            self.c.bswap(sz, rd);
            if bits == 16 {
                self.c.shift_ri(x::SHR, 4, rd, 16);
            }
            return true;
        }
        if op == O_ICMP {
            return self.icmp(i, t);
        }
        if op == O_FCMP && self.lv.pfold[i as usize] {
            return true; // each select on it compares (`fsel`)
        }
        if op == O_FCMP {
            assert(!is_vec(self.vt(t.a)), "x64gen: a vector comparison the verifier rejects");
            self.fcmp(i, t);
            return true;
        }
        if op == O_MULHU || op == O_MULHS {
            if is_vec(t.ty) {
                return self.vec_arith(i, t);
            }
            if i == self.mul_twin {
                return true; // the low half's `mul` gave it
            }
            let bits = type_bits(t.ty, self.ptr);
            let sgn = op == O_MULHS;
            // The product commutes: a constant operand second.
            let mut kv: u64 = 0;
            let (va, vb) = if self.const_of(t.a, &mut kv) {
                (t.b, t.a)
            } else {
                (t.a, t.b)
            };
            if bits == 64 {
                self.wide_mul(i, t, va, vb, NONE);
                let m = self.twin_product(i, t, false);
                if m != NONE {
                    self.result_in(m, x::RAX);
                    self.mul_twin = m;
                }
                return true;
            }
            // Fewer bits: the operands extended to 64 bits, their 64-bit product, shifted down; a constant
            // that a sign-extended 32-bit immediate holds as the immediate.
            let ra = self.reg(va);
            let kc = self.const_of(vb, &mut kv);
            let k = if sgn {
                lp_sext(kv, bits) as u64
            } else {
                kv & (1u64 << bits as u64) - 1
            };
            let imm = kc && k as i64 >= -2147483648 && k as i64 <= 2147483647;
            let mut s: u8 = 0;
            if kc && !imm {
                // An unsigned constant from 2^31: a 32-bit move zero-extends it.
                s = self.tmp(false);
                self.mov_imm(s, k, 4);
            } else if !kc {
                let rb = self.reg(vb);
                s = self.tmp(false);
                self.c.ext(bits / 8, 8, sgn, s, rb);
            }
            let rd = self.def(i);
            self.c.ext(bits / 8, 8, sgn, rd, ra);
            if imm {
                self.c.imul_ri(8, rd, rd, k as i32);
            } else {
                self.c.imul_rr(8, rd, s);
            }
            self.c.shift_ri(
                if sgn {
                    x::SAR
                } else {
                    x::SHR
                },
                8,
                rd,
                bits,
            );
            return true;
        }
        if op == O_FMA {
            // The addend in the result's register, then `a * b` added (vfmadd231, FMA3): the one instruction
            // reads its operands before it writes.
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let rd = self.def_from(i, t.c, rc);
            self.c.vfma231(t.ty == T_F64, rd - V0, ra - V0, rb - V0);
            return true;
        }
        if op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            if is_vec(t.ty) {
                return self.vec_arith(i, t);
            }
            let d = t.ty == T_F64;
            let ra = self.reg(t.a);
            if op == O_FNEG {
                let rd = self.def_from(i, t.a, ra);
                self.fsign(d, false, rd);
                return true;
            }
            if op == O_FSQRT {
                let rd = self.def_from(i, t.a, ra);
                self.c.sse_rr(fpfx(d), 0x0F51, rd - V0, rd - V0);
                return true;
            }
            if self.ld_folded(t.b) {
                let lt = self.b().insts[t.b as usize];
                let mut rs = NONE;
                let mut add: i64 = 0;
                let m = self.mem_at(lt.a, lt.c as i32, &mut rs, &mut add);
                let rd = self.def_from(i, t.a, ra);
                self.c.rm(fpfx(d), fop(op), false, rd - V0, m, false);
                self.mem_rel(rs, add);
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def_from(i, t.a, ra);
            self.c.sse_rr(fpfx(d), fop(op), rd - V0, rb - V0);
            return true;
        }
        if op >= O_SEXT && op <= O_INTTOPTR {
            return self.convert(i, t);
        }
        if op == O_PTRADD {
            return self.ptradd(i, t);
        }
        if op == O_LOAD {
            return self.load(i, t);
        }
        if op == O_STORE {
            return self.store(t);
        }
        if op == O_MEMCPY || op == O_MEMSET {
            return self.mem_block(i, t);
        }
        if op >= O_ALOAD && op <= O_FENCE {
            return self.atomic(i, t);
        }
        if op == O_SELECT {
            return self.select_op(i, t);
        }
        if op == O_RETADDR {
            let rd = self.def(i);
            self.c.load(8, false, rd, x::at(self.fb, 8));
            return true;
        }
        if op == O_CALL || op == O_CALLIND {
            return self.call(i, t);
        }
        if op == O_VOP {
            return self.vop(i, t);
        }
        if op == O_VSUMW {
            self.vsumw(i, t);
            return true;
        }
        if op == O_VASTART {
            self.va_start(t);
            return true;
        }
        if op == O_VAARG {
            return self.va_arg(i, t);
        }
        if op == O_SYS {
            return self.sys(i, t);
        }
        if op == O_ASM {
            return self.asm_inst(i, t);
        }
        if op == O_VAEND {
            return true;
        }
        return self.terminator(i, t);
    }

    // Instruction `i`'s result arrives in register `r` (after a call or a fixed-register instruction): it
    // binds there, or moves to its callee-saved home.
    fn result_in(self: &mut Self, i: u32, r: u8) {
        let x = self.vx(i);
        if !self.live_on(x) {
            return;
        }
        if self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE {
            let rd = self.def(i);
            self.move_reg(self.vt(i), rd, r);
            return;
        }
        self.bind(x, r);
    }

    // The memory value instruction `i` defines: a slot; its rsp offset.
    fn mdef(self: &mut Self, i: u32) i64 {
        let x = self.vx(i);
        let t = self.xty(x);
        let off = self.slot_alloc(type_bytes(t, self.ptr), 16);
        self.va.index_mut(x as usize).home = H_SLOT;
        self.va.index_mut(x as usize).off = off as i32;
        return off;
    }

    // Store vector `v` to its home when its register holds what the home lacks.
    fn sync(self: &mut Self, v: Value) {
        if self.in_reg(self.vt(v)) {
            self.spill(self.vx(v));
        }
    }

    // Where memory value `v` is: a base register and offset; a vector whose register holds what its home
    // lacks is stored there first.
    fn mloc(self: &mut Self, v: Value) (u8, i64) {
        self.spill(self.vx(v));
        let va = self.va[self.vx(v) as usize];
        if va.home == H_ARG {
            return (self.fb, va.off);
        }
        assert(va.home == H_SLOT, "x64gen: a memory value without a slot");
        return (x::RSP, va.off);
    }

    // The address `v` + `off` as a base register and an offset: a slot or frame address folds in.
    fn addr(self: &mut Self, v: Value, off: i64) (u8, i64) {
        let (fr, base, at) = self.frame_addr(v);
        if fr {
            return (base, at + off);
        }
        return (self.reg(v), off);
    }

    // Whether address `v` is a slot or frame address no register holds (`addr`'s folds), with the frame's
    // register and the offset; else false, r11 and 0 (the caller puts `v` there).
    const fn frame_addr(self: &Self, v: Value) (bool, u8, i64) {
        let va = self.va[self.vx(v) as usize];
        if va.home == H_SPADDR {
            return (true, x::RSP, va.off);
        }
        if va.home == H_FPADDR {
            return (true, self.fb, va.off);
        }
        if va.home == H_REMAT && va.reg == NOREG && (v & (VPARAM | VFLAG)) == 0 {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return (true, x::RSP, self.slot_off[it.a as usize]);
            }
        }
        return (false, S1, 0);
    }

    // The memory operand of a `bytes`-byte access at `v` + `off`: RIP-relative for a defined data
    // symbol whose address is recomputed at each use (its relocation's symbol and addend in `rs`, `radd`,
    // NONE otherwise), else a base and a displacement.
    fn mem_at(self: &mut Self, v: Value, off: i64, rs: &mut u32, radd: &mut i64) x::Mem {
        *rs = NONE;
        if (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize] {
            // A folded address (`Live::fold`): its base, and its index scaled by 1 or the access's size.
            let p = self.b().insts[v as usize];
            let rb = self.reg(p.a);
            let ri = self.reg(p.b);
            return x::ix(rb, ri, scale_of(p).trailing_zeros() as u8, off as i32);
        }
        if (v & (VPARAM | VFLAG)) == 0 && self.va[v as usize].home == H_REMAT && self.va[v as usize].reg == NOREG {
            let it = self.b().insts[v as usize];
            if it.op == O_SYMADDR {
                let p = unsafe &*self.pkg;
                let ps = p.syms[self.b().syms[it.a as usize] as usize];
                if ps.kind == SK_DATA && !ps.ext && ps.def != NONE && !(p.pic && ps.linkage == SL_GLOBAL) {
                    *rs = self.osym_of(it.a);
                    *radd = (it.b as i32) as i64 + off;
                    return x::rip();
                }
            }
        }
        let (base, o) = self.addr(v, off);
        return x::at(base, o as i32);
    }

    // The relocation a RIP-relative access (`mem_at`) needs, once its instruction is written.
    fn mem_rel(self: &mut Self, rs: u32, radd: i64) {
        if rs != NONE {
            self.reloc_rip(x::R_PC32, rs, radd);
        }
    }

    // Value `v` (an integer of `bits` bits, 8 or 16) in a register extended to 32 bits.
    fn ext(self: &mut Self, v: Value, signed: bool, bits: u32) u8 {
        let r = self.reg(v);
        let xv = self.vx(v);
        if !signed && self.va[xv as usize].clean {
            return r;
        }
        let d = self.tmp(false);
        self.c.ext(bits / 8, 4, signed, d, r);
        return d;
    }

    // Whether the next instruction of the block reads value `v` (its only use) as a condition: a `br` or
    // a `select`.
    const fn fusable(self: &Self, i: u32, v: Value) bool {
        let xv = self.vx(v);
        if self.lv.uses[xv as usize] != 1 {
            return false;
        }
        return self.next_reads(i, v);
    }

    // Whether the instruction after `i` is a branch or a select on value `v`.
    const fn next_reads(self: &Self, i: u32, v: Value) bool {
        let b = self.b();
        let k = self.lv.def_blk[i as usize];
        let bk = b.blocks[k as usize];
        if i + 1 >= bk.start + bk.len {
            return false;
        }
        let n = b.insts[i as usize + 1];
        return (n.op == O_BR || n.op == O_SELECT) && n.a == v;
    }

    // The result of comparison instruction `i` is condition `cc` (with `cc2` NONE), or `cc` and (`and2`)
    // or `cc2`: left in the flags for the next instruction, or set into the value's register.
    fn cond_value(self: &mut Self, i: u32, cc: u32, cc2: u32, and2: bool) {
        if cc2 == NONE && self.fusable(i, i) {
            self.cond = Cond { inst: self.vx(i), cc: cc };
            return;
        }
        self.keep_flags = true;
        let raw = self.raw;
        self.raw = false;
        let z = self.zeroed;
        self.zeroed = NOREG;
        let rd = if z != NOREG {
            z
        } else {
            self.def_cmp(i)
        };
        let held = self.held_end == self.c.len();
        self.c.setcc(cc, rd);
        if cc2 != NONE {
            self.c.setcc(cc2, S1);
            self.c.alu_rr(
                if and2 {
                    x::AND
                } else {
                    x::OR
                },
                1,
                rd,
                S1,
            );
        }
        if !raw && (z == NOREG || !self.zx) {
            self.c.ext(1, 4, false, rd, rd);
        }
        self.va.index_mut(i as usize).clean = !raw;
        if held && cc2 == NONE {
            self.held_end = self.c.len();
        }
        if cc2 == NONE && self.next_reads(i, i) {
            // The value has other uses; the branch or select after reads the flags all the same.
            self.cond = Cond { inst: self.vx(i), cc: cc };
        }
    }

    // The register for comparison `i`'s result when none was zeroed before it: the one the next instruction
    // takes it in (`next_reg`, through `def`), else its first operand's, which the comparison read, when
    // that dies here (`def_over`), else `def`'s.
    fn def_cmp(self: &mut Self, i: u32) u8 {
        let t = self.b().insts[i as usize];
        if t.op == O_ICMP && t.a != VNONE && (t.a & VFLAG) == 0 && self.next_reg(i) == NOREG {
            let ra = self.va[self.vx(t.a) as usize].reg;
            if ra != NOREG {
                return self.def_over(i, t.a, ra);
            }
        }
        return self.def(i);
    }

    fn icmp(self: &mut Self, i: u32, t: Inst) bool {
        if self.lv.pfold[i as usize] {
            return true; // each select or branch on it compares (`folded_cmp`)
        }
        let ty = self.vt(t.a);
        assert(!is_vec(ty), "x64gen: a vector comparison the verifier rejects");
        if ty == T_I128 {
            return self.icmp128(i, t);
        }
        // Read as a byte alone (`bytes_only`): `setcc` with no register zeroed nor extension after.
        let raw = !self.fusable(i, i) && self.bytes_only(i, BYTES_DEPTH);
        let zi = if self.fusable(i, i) || raw {
            NONE
        } else {
            i
        };
        let cc = self.compare(t, zi);
        self.raw = raw;
        self.cond_value(i, cc, NONE, false);
        return true;
    }

    // Whether every read of value `i` is in its block and takes the low byte alone: an 8-bit `and`, `or`
    // or `xor` with a comparison (two zeroings for at most one extension of the result) or whose own reads
    // do so (within `depth` of them), a return, a branch on it, a select's condition, a byte store of it.
    fn bytes_only(self: &Self, i: u32, depth: u32) bool {
        let b = self.b();
        let k = self.lv.def_blk[i as usize];
        if self.lv.end[i as usize] != self.lv.pos[k as usize] {
            return false;
        }
        let bk = b.blocks[k as usize];
        for j in i + 1..bk.start + bk.len {
            let t = b.insts[j as usize];
            let us = self.lv.uses_of(j);
            let mut reads = false;
            for q in 0..us.len() {
                reads = reads || us[q] == i;
            }
            if !reads {
                continue;
            }
            let other = if t.a == i {
                t.b
            } else {
                t.a
            };
            let logic = (t.op == O_AND || t.op == O_OR || t.op == O_XOR) && t.ty == T_I8;
            let ok = logic && other != i && ((other & (VPARAM | VFLAG)) == 0 && b.insts[other as usize].op == O_ICMP || depth != 0 && self.bytes_only(
                j,
                depth - 1,
            )) || t.op == O_RET || t.op == O_BR && t.a == i && !self.edge_reads(t, i) || t.op == O_SELECT && t.a == i && t.b != i && t.c != i || t.op == O_STORE && t.b == i && t.a != i;
            if !ok {
                return false;
            }
        }
        return true;
    }

    // Whether an edge of branch `t` passes value `v`.
    fn edge_reads(self: &Self, t: Inst, v: u32) bool {
        let b = self.b();
        for e in [t.b, t.c] {
            for q in 0..b.edge_nargs(e) {
                if b.edge_arg(e, q) == v {
                    return true;
                }
            }
        }
        return false;
    }

    // The flags of the comparison condition value `v` folds into its select or branch (`lv::FOLD_CMP`),
    // set here and kept; NONE when it does not fold.
    fn folded_cmp(self: &mut Self, v: Value) u32 {
        if (v & (VPARAM | VFLAG)) != 0 || !self.lv.pfold[v as usize] {
            return NONE;
        }
        let cc = self.compare(self.b().insts[v as usize], NONE);
        self.keep_flags = true;
        return cc;
    }

    // The value whose low bits value `v` is: the source of a folded truncation (`lv::FOLD_TRUNC`), else `v`.
    const fn narrow_src(self: &Self, v: Value) Value {
        return if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize] && self.b().insts[v as usize].op == O_TRUNC {
            self.b().insts[v as usize].a
        } else {
            v
        };
    }

    // Comparison `t` of integers of at most 64 bits into the flags: its condition. A folded `and` compared
    // with 0 is a test (`lv::FOLD_TST`; a narrow one's mask is within its width, so 32 bits test it). For
    // value `zi` (NONE: none) the register it is set in is zeroed before the compare (`zeroed`): `setcc`
    // then writes its low byte with no extension after.
    fn compare(self: &mut Self, t: Inst, zi: u32) u32 {
        self.zeroed = NOREG;
        if self.ld_folded(t.a) || self.ld_folded(t.b) {
            return self.compare_mem(t, zi);
        }
        let ty = self.vt(t.a);
        let bits = type_bits(ty, self.ptr);
        let sz = bits / 8;
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && self.b().insts[t.a as usize].op == O_VOP {
            // The `or` of a lane mask's lanes is 0 when no byte's sign bit is set: `pmovmskb`, `test`.
            let n = self.b().insts[t.a as usize];
            let v = self.b().pool[n.a as usize];
            let rv = self.vec_use(v, self.vs0) - V0;
            self.zero_for(zi, S0, NOREG);
            if type_bytes(self.vt(v), 8) == 32 {
                self.c.vex_rr(0x66, 1, 0xD7, false, true, S0, 0, rv);
            } else {
                self.c.rr(0x66, 0x0FD7, false, S0, rv, false);
            }
            self.c.test_rr(4, S0, S0);
            return icond(t.aux);
        }
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && self.b().insts[t.a as usize].op == O_AND {
            let n = self.b().insts[t.a as usize];
            let ra = self.reg(n.a);
            let tz = if bits < 32 {
                4u32
            } else {
                sz
            };
            let mut k: i32 = 0;
            let imm = self.imm32_of(n.b, bits.max(32), &mut k);
            let rb = if imm {
                NOREG
            } else {
                self.reg(n.b)
            };
            self.zero_for(zi, ra, rb);
            let s0 = self.c.len();
            if imm {
                self.c.test_ri(tz, ra, k as u32);
            } else {
                self.c.test_rr(tz, ra, rb);
            }
            self.reflag(s0);
            return icond(t.aux);
        }
        // A folded truncation's low bits are its source's (`lv::FOLD_TRUNC`), which the sized compare reads.
        let ra = self.reg(self.narrow_src(t.a));
        let mut k: i32 = 0;
        let imm = self.imm32_of(t.b, bits, &mut k);
        let rb = if imm {
            NOREG
        } else {
            self.reg(self.narrow_src(t.b))
        };
        // The `add`, `sub`, `and`, `or` or `xor` just emitted set ZF from this register.
        let z = self.zf;
        if imm && k == 0 && (t.aux == C_EQ || t.aux == C_NE) && z.at == self.c.len() && z.pos == self.pos && z.reg == ra && z.sz == sz {
            return icond(t.aux);
        }
        if self.held_end == self.c.len() && self.blk_at[self.lv.order[self.pos as usize] as usize] < self.held_end {
            if self.held_a == t.a && self.held_b == t.b {
                return icond(t.aux);
            }
            // The flags of the operands the other way.
            if self.held_a == t.b && self.held_b == t.a {
                return icond(mirror(t.aux));
            }
        }
        self.zero_for(zi, ra, rb);
        let s0 = self.c.len();
        if imm && k == 0 {
            self.c.test_rr(sz, ra, ra);
        } else if imm {
            self.c.alu_ri(x::CMP, sz, ra, k);
        } else {
            self.c.alu_rr(x::CMP, sz, ra, rb);
        }
        self.reflag(s0);
        self.held_a = t.a;
        self.held_b = t.b;
        self.held_end = self.c.len();
        return icond(t.aux);
    }

    // Whether only its home in memory holds scalar integer value `v`: a stack parameter or a spilled value.
    const fn mem_home(self: &Self, v: Value) bool {
        if (v & VFLAG) != 0 || v == VNONE {
            return false;
        }
        let va = self.va[self.vx(v) as usize];
        return va.reg == NOREG && (va.home == H_ARG || va.home == H_SLOT) && is_int(self.vt(v)) && !in_mem(self.vt(v));
    }

    // Whether `v` is a load its use reads in memory (`lv::FOLD_LDOP`).
    const fn ld_folded(self: &Self, v: Value) bool {
        return (v & (VPARAM | VFLAG)) == 0 && v != VNONE && self.lv.pfold[v as usize] && self.b().insts[v as usize].op == O_LOAD;
    }

    // `compare` of `t` with an operand load folded (`lv::FOLD_LDOP`): the memory against the other operand
    // (an immediate or a register), or a register against the memory.
    fn compare_mem(self: &mut Self, t: Inst, zi: u32) u32 {
        let bits = type_bits(self.vt(t.a), self.ptr);
        let sz = bits / 8;
        let fa = self.ld_folded(t.a);
        let (l, o) = if fa {
            (t.a, t.b)
        } else {
            (t.b, t.a)
        };
        let lt = self.b().insts[l as usize];
        let mut k: i32 = 0;
        let imm = fa && self.imm32_of(o, bits, &mut k);
        let ro = if imm {
            NOREG
        } else {
            self.reg(o)
        };
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        let m = self.mem_at(lt.a, lt.c as i32, &mut rs, &mut radd);
        self.zero_for(zi, m.base, ro);
        if imm {
            self.c.alu_mi(x::CMP, sz, m, k);
        } else if fa {
            self.c.alu_mr(x::CMP, sz, m, ro);
        } else {
            self.c.alu_rm(x::CMP, sz, ro, m);
        }
        self.mem_rel(rs, radd);
        // No later compare reuses these flags by its bytes (`reflag`): a relocation may differ.
        self.cmp_at = NONE;
        self.held_end = NONE;
        return icond(t.aux);
    }

    // Value `zi`'s register (NONE: none), defined before the compare that sets it, its operands in `ra`
    // and `rb` already: zeroed when it holds neither (`zeroed`, `zx`).
    fn zero_for(self: &mut Self, zi: u32, ra: u8, rb: u8) {
        if zi != NONE {
            let rd = self.def(zi);
            self.zx = rd != ra && rd != rb;
            if self.zx {
                self.c.alu_rr(x::XOR, 4, rd, rd);
            }
            self.zeroed = rd;
        }
    }

    // The compare just written from code byte `s0` on, at the start of a block whose one predecessor ends
    // with the same compare and a conditional jump (to elsewhere, falling through here): the flags hold its
    // result already, so it goes.
    fn reflag(self: &mut Self, s0: u32) {
        let k = self.lv.order[self.pos as usize];
        let n = self.c.len() - s0;
        let nf = self.fix.len();
        let last = self.cmp_at;
        self.cmp_at = s0;
        if self.blk_at[k as usize] != s0 || self.lv.npred[k as usize] != 1 || nf == 0 || (self.fix[nf - 1] >> 32) as u32 + 4 != s0 || last == NONE || last + n + 6 != s0 {
            return;
        }
        if self.c.b[s0 as usize - 6] != 0x0F || (self.c.b[s0 as usize - 5] & 0xF0) != 0x80 {
            return;
        }
        for q in 0..n {
            if self.c.b[(s0 - 6 - n + q) as usize] != self.c.b[(s0 + q) as usize] {
                return;
            }
        }
        self.c.b.truncate(s0 as usize);
    }

    // A float comparison: `ucomis` sets ZF, PF and CF; `<` and `<=` compare the operands swapped.
    fn fcmp(self: &mut Self, i: u32, t: Inst) {
        let d = self.vt(t.a) == T_F64;
        let ra = self.reg(t.a);
        let rb = self.reg(t.b);
        let c = t.aux;
        let swap = c == C_OLT || c == C_OLE;
        let (p, q) = if swap {
            (rb, ra)
        } else {
            (ra, rb)
        };
        self.c.sse_rr(
            if d {
                0x66u32
            } else {
                0u32
            },
            0x0F2E,
            p - V0,
            q - V0,
        );
        if c == C_OEQ {
            self.cond_value(i, x::CC_E, x::CC_NP, true);
        } else if c == C_UNE {
            self.cond_value(i, x::CC_NE, x::CC_P, false);
        } else if c == C_OGT || c == C_OLT {
            self.cond_value(i, x::CC_A, NONE, false);
        } else if c == C_OGE || c == C_OLE {
            self.cond_value(i, x::CC_AE, NONE, false);
        } else if c == C_UNO {
            self.cond_value(i, x::CC_P, NONE, false);
        } else if c == C_ONE {
            self.cond_value(i, x::CC_NE, NONE, false);
        } else {
            self.cond_value(i, x::CC_E, NONE, false);
        }
    }

    // An i128 comparison: equality by XOR, order by a 128-bit subtraction (operands swapped for `>` and
    // `<=`).
    fn icmp128(self: &mut Self, i: u32, t: Inst) bool {
        let c = t.aux;
        let (lo_a, hi_a) = self.load128(t.a);
        let (bb, bo) = self.mloc(t.b);
        if c == C_EQ || c == C_NE {
            self.c.alu_rm(x::XOR, 8, lo_a, x::at(bb, bo as i32));
            self.c.alu_rm(x::XOR, 8, hi_a, x::at(bb, bo as i32 + 8));
            self.c.alu_rr(x::OR, 8, lo_a, hi_a);
            self.cond_value(i, icond(c), NONE, false);
            return true;
        }
        let swap = c == C_SGT || c == C_SLE || c == C_UGT || c == C_ULE;
        if swap {
            let (lo_b, hi_b) = self.load128(t.b);
            let (ab, ao) = self.mloc(t.a);
            self.c.alu_rm(x::CMP, 8, lo_b, x::at(ab, ao as i32));
            self.c.alu_rm(x::SBB, 8, hi_b, x::at(ab, ao as i32 + 8));
        } else {
            self.c.alu_rm(x::CMP, 8, lo_a, x::at(bb, bo as i32));
            self.c.alu_rm(x::SBB, 8, hi_a, x::at(bb, bo as i32 + 8));
        }
        let cc = if c == C_SLT || c == C_SGT {
            x::CC_L
        } else if c == C_SGE || c == C_SLE {
            x::CC_GE
        } else if c == C_ULT || c == C_UGT {
            x::CC_B
        } else {
            x::CC_AE
        };
        self.cond_value(i, cc, NONE, false);
        return true;
    }

    // Memory value `v` (an i128) into two temporaries: its low and high words.
    fn load128(self: &mut Self, v: Value) (u8, u8) {
        let lo = self.tmp(false);
        let hi = self.tmp(false);
        let (base, off) = self.mloc(v);
        self.c.load(8, false, lo, x::at(base, off as i32));
        self.c.load(8, false, hi, x::at(base, off as i32 + 8));
        return (lo, hi);
    }

    // Store two words as i128 instruction `i`'s value.
    fn store128(self: &mut Self, i: u32, lo: u8, hi: u8) {
        let off = self.mdef(i) as i32;
        self.c.store(8, lo, x::at(x::RSP, off));
        self.c.store(8, hi, x::at(x::RSP, off + 8));
    }

    // clz: the highest set bit's index (bsr), 0 counting the width; ctz: bsf, a bit set at the width
    // making 0 count it; popcnt: the bits summed in parallel (SSE2 has no POPCNT).
    fn bit_count(self: &mut Self, i: u32, t: Inst) {
        if self.lv.pfold[i as usize] {
            return; // the bit length or top bit's index that reads it computes it (`lv::FOLD_BLEN`)
        }
        let bits = type_bits(t.ty, self.ptr);
        let sz = wsz(bits);
        // ctz's bit set at the width hides the bits above it: no extension.
        let r = if bits < 32 && t.op != O_CTZ {
            self.ext(t.a, false, bits)
        } else {
            self.reg(t.a)
        };
        // A clz or popcnt reads its operand before it writes: the result may take a dying operand's register,
        // unless the next instruction takes it in one (`next_reg`). ctz's `tzcnt` presets a register of its
        // own.
        let rd = if t.op == O_CTZ || self.next_reg(i) != NOREG {
            self.def(i)
        } else {
            self.def_over(i, t.a, r)
        };
        // The count, at most the width, is `clean`.
        self.va.index_mut(i as usize).clean = true;
        if t.op == O_POPCNT && unsafe (*self.pkg).popcnt {
            self.c.rr(0xF3, 0x0FB8, sz == 8, rd, r, false);
            return;
        }
        if t.op == O_POPCNT {
            self.popcount(rd, r, sz);
            return;
        }
        // An operand not 0 (`CNT_NONZERO`): bsf, or bsr and the flip to a count of zeros.
        if t.aux == CNT_NONZERO {
            self.c.bsx(t.op == O_CLZ, sz, rd, r);
            if t.op == O_CLZ {
                self.c.alu_ri(x::XOR, 4, rd, (bits - 1) as i32);
            }
            return;
        }
        // `tzcnt` (bsf with F3) into the width preset: the count where the processor has it, else bsf,
        // which every x86-64 processor makes keep the destination for 0 (as clang relies on).
        if t.op == O_CTZ && bits >= 32 && rd != r {
            self.c.mov_ri(rd, bits);
            self.c.rr(0xF3, 0x0FBC, sz == 8, rd, r, false);
            return;
        }
        if t.op == O_CTZ {
            let mut src = r;
            if bits < 32 {
                self.c.mov_rr(4, S0, r);
                self.c.alu_ri(x::OR, 4, S0, (1u32 << bits) as i32);
                src = S0;
            }
            self.c.bsx(false, sz, rd, src);
            if bits >= 32 {
                self.c.mov_ri(S1, bits);
                self.c.cmov(x::CC_E, sz, rd, S1);
            }
            return;
        }
        // clz = (w - 1) ^ bsr for width w (a narrow operand zero-extended, its bsr below w), with bsr taken
        // as 2w - 1 for 0 (giving w).
        self.c.bsx(true, sz, rd, r);
        self.c.mov_ri(S1, 2 * bits - 1);
        self.c.cmov(x::CC_E, sz, rd, S1);
        self.c.alu_ri(x::XOR, 4, rd, (bits - 1) as i32);
    }

    // `rd` = the set bits of `r` (its low `sz` bytes, the upper zero for 4), through r10 and r11.
    fn popcount(self: &mut Self, rd: u8, r: u8, sz: u32) {
        self.c.mov_rr(sz, rd, r);
        self.c.mov_rr(8, S0, rd);
        self.c.shift_ri(x::SHR, 8, S0, 1);
        self.c.mov_ri(S1, 0x5555555555555555);
        self.c.alu_rr(x::AND, 8, S0, S1);
        self.c.alu_rr(x::SUB, 8, rd, S0);
        self.c.mov_ri(S1, 0x3333333333333333);
        self.c.mov_rr(8, S0, rd);
        self.c.alu_rr(x::AND, 8, S0, S1);
        self.c.shift_ri(x::SHR, 8, rd, 2);
        self.c.alu_rr(x::AND, 8, rd, S1);
        self.c.alu_rr(x::ADD, 8, rd, S0);
        self.c.mov_rr(8, S0, rd);
        self.c.shift_ri(x::SHR, 8, S0, 4);
        self.c.alu_rr(x::ADD, 8, rd, S0);
        self.c.mov_ri(S1, 0x0F0F0F0F0F0F0F0F);
        self.c.alu_rr(x::AND, 8, rd, S1);
        self.c.mov_ri(S1, 0x0101010101010101);
        self.c.imul_rr(8, rd, S1);
        self.c.shift_ri(x::SHR, 8, rd, 56);
    }

    fn int_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let op = t.op;
        if is_vec(ty) {
            return self.vec_arith(i, t);
        }
        if i == self.div_pair || i == self.div_mul || i == self.mul_twin {
            return true; // the division before it gave the remainder; the high half's `mul`, the product
        }
        // A 64-bit product whose high half comes later in the block: one `mul` gives both (rax, rdx).
        if op == O_MUL && ty == T_I64 && !self.lv.pfold[i as usize] {
            let h = self.twin_product(i, t, true);
            if h != NONE {
                self.wide_mul(h, self.b().insts[h as usize], t.a, t.b, i);
                self.result_in(i, x::RAX);
                self.mul_twin = h;
                return true;
            }
        }
        if self.lv.pfold[i as usize] {
            return true; // its use computes it (`lv::FOLD_*`)
        }
        if ty == T_I128 {
            return self.int128(i, t);
        }
        let bits = type_bits(ty, self.ptr);
        let sz = wsz(bits);
        let small = bits < 32;
        // The bit length, `width - clz(x)` with the count folded (`lv::FOLD_BLEN`): bsr + 1, or 0 for 0.
        if op == O_SUB && (t.b & (VPARAM | VFLAG)) == 0 && t.b != VNONE && self.lv.pfold[t.b as usize] && self.b().insts[t.b as usize].op == O_CLZ {
            let rx = self.reg(self.b().insts[t.b as usize].a);
            let rd = self.def(i);
            if self.b().insts[t.b as usize].aux == CNT_NONZERO {
                self.c.bsx(true, sz, rd, rx);
                self.c.alu_ri(x::ADD, 4, rd, 1);
                self.va.index_mut(i as usize).clean = true;
                return true;
            }
            let src = if rd == rx {
                self.c.mov_rr(sz, S0, rx);
                S0
            } else {
                rx
            };
            self.c.bsx(true, sz, rd, src);
            self.c.alu_ri(x::ADD, 4, rd, 1);
            self.c.test_rr(sz, src, src);
            self.c.cmov(x::CC_E, sz, rd, src);
            self.va.index_mut(i as usize).clean = true;
            return true;
        }
        // The top bit's index, `clz(x) ^ (width - 1)` with the count folded (`lv::FOLD_BLEN`): bsr, or
        // 2 * width - 1 for 0 (`bit_count`'s count of 0 xor `width - 1`).
        if op == O_XOR && (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE && self.lv.pfold[t.a as usize] && self.b().insts[t.a as usize].op == O_CLZ {
            let rx = self.reg(self.b().insts[t.a as usize].a);
            let rd = self.def(i);
            self.c.bsx(true, sz, rd, rx);
            if self.b().insts[t.a as usize].aux != CNT_NONZERO {
                self.c.mov_ri(S1, 2 * bits - 1);
                self.c.cmov(x::CC_E, sz, rd, S1);
            }
            self.va.index_mut(i as usize).clean = true;
            return true;
        }
        if op == O_NEG || op == O_NOT {
            let ra = self.reg(t.a);
            let rd = self.def_from(i, t.a, ra);
            self.c.unary(
                if op == O_NEG {
                    x::NEG
                } else {
                    x::NOT
                },
                sz,
                rd,
            );
            if op == O_NEG {
                self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
            }
            return true;
        }
        // A rotation whose shifts fold into it (`lv::FOLD_ROT`): ROL or ROR by an immediate or by cl, at the
        // type's own width (a narrow rotation reads the low bits alone).
        let rot = if self.folds_both(t) {
            lv::rotate_of(self.b(), i)
        } else {
            lv::Rotation { x: VNONE, y: VNONE, amt: VNONE, src: VNONE, k: 0, right: false }
        };
        if rot.x != VNONE {
            let xv = rot.x;
            let amt = rot.amt;
            let kr = rot.k;
            let right = rot.right;
            if amt == VNONE && rot.y != xv {
                // A funnel shift: SHLD of `x` by `y`'s high bits.
                let ry = self.reg(rot.y);
                let ra = self.reg(xv);
                let rd = self.def_from(i, xv, ra);
                let src = if rd == ry {
                    self.c.mov_rr(bits / 8, S0, ry);
                    S0
                } else {
                    ry
                };
                self.c.shld_ri(bits / 8, rd, src, kr);
                return true;
            }
            if amt == VNONE {
                let ra = self.reg(xv);
                let rd = self.def_from(i, xv, ra);
                self.c.shift_ri(x::ROL, bits / 8, rd, kr);
                return true;
            }
            let n = lv::rot_amount(self.b(), &self.lv.pfold, rot);
            self.vacate(x::RCX);
            let ra = self.reg(xv);
            let rn = self.reg(n);
            self.c.mov_rr(4, x::RCX, rn);
            let rd = self.def_from(i, xv, ra);
            self.c.shift_cl(
                if right {
                    x::ROR
                } else {
                    x::ROL
                },
                bits / 8,
                rd,
            );
            return true;
        }
        // An operand load that folds into the operation (`lv::FOLD_LDOP`): the operation reads the memory
        // (the load second for a `sub`).
        if self.ld_folded(t.a) || self.ld_folded(t.b) {
            let (l, o) = if self.ld_folded(t.b) {
                (t.b, t.a)
            } else {
                (t.a, t.b)
            };
            let lt = self.b().insts[l as usize];
            let ro = self.reg(o);
            let mut rs: u32 = NONE;
            let mut radd: i64 = 0;
            let m = self.mem_at(lt.a, lt.c as i32, &mut rs, &mut radd);
            let rd = self.def_over(i, o, ro);
            if rd != ro {
                self.move_reg(t.ty, rd, ro);
            }
            if op == O_MUL {
                self.c.imul_rm(sz, rd, m);
                self.mem_rel(rs, radd);
                return true;
            }
            self.c.alu_rm(alu_of(op), sz, rd, m);
            self.mem_rel(rs, radd);
            self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
            return true;
        }
        // A sum (an `or` of disjoint bits too) whose shifted index or inner sum folds into it
        // (`lv::FOLD_LEA`): one `lea`.
        if (op == O_ADD || op == O_SUB || lv::is_sum_or(self.b(), t)) && (self.folded(t.a) || self.folded(t.b)) {
            let f = lv::lea_of(self.b(), &self.lv.pfold, i);
            self.lea_sum(i, sz, f);
            return true;
        }
        // A field of a folded right shift (`lv::FOLD_UBFX`): bits 8 to 15 of rax..rbx by `movzx` of the
        // high byte register (no REX prefix, so into one of the first 8 registers); else a copy shifted
        // down, masked by `and` (a 32-bit immediate) or by a shift up and down. Before the memory operand
        // forms below: the shift has no register.
        if op == O_AND && (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && self.b().insts[t.a as usize].op == O_LSHR {
            let s = self.b().insts[t.a as usize];
            let mut sh: u64 = 0;
            let _ = self.const_of(s.b, &mut sh);
            let mut km: u64 = 0;
            let _ = self.const_of(t.b, &mut km);
            let m = if bits >= 64 {
                km
            } else {
                km & (1u64 << bits as u64) - 1
            };
            let w = (m + 1).trailing_zeros() as u32;
            let fz = bits.max(32) / 8;
            let rs = self.reg(s.a);
            if sh == 8 && w == 8 && rs < 4 {
                let rd = self.def(i);
                if rd < 8 {
                    self.c.byte(0x0F);
                    self.c.byte(0xB6);
                    self.c.byte(0xC0 | rd as u32 << 3 | rs as u32 + 4);
                    self.va.index_mut(i as usize).clean = true;
                    return true;
                }
                self.move_reg(t.ty, rd, rs);
                self.c.shift_ri(x::SHR, fz, rd, 8);
                self.c.ext(1, 4, false, rd, rd);
                self.va.index_mut(i as usize).clean = true;
                return true;
            }
            let rd = self.def_from(i, s.a, rs);
            if w < 32 {
                self.c.shift_ri(x::SHR, fz, rd, sh as u32);
                self.c.alu_ri(x::AND, 4, rd, m as i32);
            } else {
                self.c.shift_ri(x::SHL, fz, rd, fz * 8 - sh as u32 - w);
                self.c.shift_ri(x::SHR, fz, rd, fz * 8 - w);
            }
            self.va.index_mut(i as usize).clean = true;
            return true;
        }
        let alu = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR;
        let mut k: i32 = 0;
        let kc = self.imm32_of(t.b, bits, &mut k);
        let mut z: u64 = 0;
        if op == O_SUB && self.const_of(t.a, &mut z) && z == 0 {
            // 0 - x: a negation.
            let rx = self.reg(t.b);
            let rd = self.def_from(i, t.b, rx);
            self.c.unary(x::NEG, sz, rd);
            self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
            return true;
        }
        if alu {
            let aop = alu_of(op);
            // An operand that only memory holds (a stack parameter, a spilled value): the operation reads it
            // there (the second one of a `sub`).
            let mb = !kc && !small && self.mem_home(t.b);
            if mb || !kc && !small && op != O_SUB && self.mem_home(t.a) {
                let (m, o) = if mb {
                    (t.b, t.a)
                } else {
                    (t.a, t.b)
                };
                let ro = self.reg(o);
                let rd = self.def_over(i, o, ro);
                if rd != ro {
                    self.move_reg(t.ty, rd, ro);
                }
                let mv = self.va[self.vx(m) as usize];
                self.c.alu_rm(aop, sz, rd, x::at(ast_pick(mv.home == H_SLOT, x::RSP, self.fb), mv.off));
                self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
                return true;
            }
            let mut ra = self.reg(t.a);
            // A sum whose first operand stays live, or whose result the next instruction wants in another
            // register (a return's, an argument's, a jump's parameter's, `next_reg`): `lea` writes that
            // register, where `add` would take a copy first or after.
            if kc {
                let sum = op == O_ADD || op == O_SUB && k != -2147483648;
                let n = if sum {
                    self.next_reg(i)
                } else {
                    NOREG
                };
                let rd = if n != NOREG && n != ra {
                    self.def(i)
                } else {
                    self.def_over(i, t.a, ra)
                };
                if rd != ra && sum {
                    self.lea_to(
                        sz,
                        rd,
                        x::at(
                            ra,
                            if op == O_SUB {
                                -k
                            } else {
                                k
                            },
                        ),
                    );
                    return true;
                }
                if rd != ra {
                    self.move_reg(t.ty, rd, ra);
                }
                self.c.alu_ri(aop, sz, rd, k);
                self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
                return true;
            }
            let mut rb = self.reg(t.b);
            // An `and` of a value whose bits above the type are 0, an `or` or `xor` of two: so are the
            // result's.
            let ca = self.va[self.vx(t.a) as usize].clean;
            let cb = self.va[self.vx(t.b) as usize].clean;
            let mut a = t.a;
            if op != O_SUB && self.swaps(i, t.b, ra, rb) {
                a = t.b;
                rb = ra;
                ra = self.reg(t.b);
            }
            // A sum the next instruction wants in a register of neither operand (`next_reg`): `lea` there.
            let n = if op == O_ADD {
                self.next_reg(i)
            } else {
                NOREG
            };
            let rd = if n != NOREG && n != ra && n != rb {
                self.def(i)
            } else {
                self.def_over(i, a, ra)
            };
            if rd != ra && op == O_ADD {
                self.lea_to(sz, rd, x::ix(ra, rb, 0, 0));
                return true;
            }
            if rd != ra {
                self.move_reg(t.ty, rd, ra);
            }
            self.c.alu_rr(aop, sz, rd, rb);
            self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
            if op == O_SUB && !small {
                // Its flags are a compare's of its operands (`compare`).
                self.held_a = t.a;
                self.held_b = t.b;
                self.held_end = self.c.len();
            }
            if small && (op == O_AND && (ca || cb) || (op == O_OR || op == O_XOR) && ca && cb) {
                self.va.index_mut(i as usize).clean = true;
            }
            return true;
        }
        if op == O_MUL {
            let mut ra = self.reg(t.a);
            if kc && self.mul_const(i, t.a, sz, ra, k) {
                return true;
            }
            if kc {
                let rd = self.def(i);
                self.c.imul_ri(sz, rd, ra, k);
                return true;
            }
            let mut rb = self.reg(t.b);
            let mut a = t.a;
            if self.swaps(i, t.b, ra, rb) {
                a = t.b;
                rb = ra;
                ra = self.reg(t.b);
            }
            let rd = self.def_from(i, a, ra);
            self.c.imul_rr(sz, rd, rb);
            return true;
        }
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            let sop = if op == O_SHL {
                x::SHL
            } else if op == O_LSHR {
                x::SHR
            } else {
                x::SAR
            };
            let mut kk: u64 = 0;
            if self.const_of(t.b, &mut kk) && kk < bits as u64 {
                let src = lv::shl_source(self.b(), &self.lv.pfold, t.a);
                let ra = self.reg(src);
                let rd = if small && op != O_SHL {
                    let r = self.def(i);
                    self.c.ext(bits / 8, 4, op == O_ASHR, r, ra);
                    r
                } else {
                    self.def_from(i, src, ra)
                };
                self.c.shift_ri(sop, sz, rd, kk as u32);
                return true;
            }
            // A count in rcx already stays there.
            let amt = lv::shift_amount(self.b(), &self.lv.pfold, t.b);
            if self.owner[x::RCX as usize] == self.vx(amt) {
                self.lock |= bit(x::RCX);
            } else {
                self.vacate(x::RCX);
            }
            let ra = self.reg(t.a);
            let rb = self.reg(amt);
            if rb != x::RCX {
                self.c.mov_rr(4, x::RCX, rb);
            }
            let rd = if small && op != O_SHL {
                let r = self.def(i);
                self.c.ext(bits / 8, 4, op == O_ASHR, r, ra);
                r
            } else {
                self.def_from(i, t.a, ra)
            };
            self.c.shift_cl(sop, sz, rd);
            return true;
        }
        // Division and remainder: rdx:rax by a register; a narrow dividend extends into rax, a narrow
        // divisor into S1.
        let sgn = op == O_SDIV || op == O_SREM;
        self.vacate(x::RAX);
        self.vacate(x::RDX);
        let ra = self.reg(t.a);
        let mut rb = self.reg(t.b);
        if small {
            self.c.ext(bits / 8, 4, sgn, x::RAX, ra);
            self.c.ext(bits / 8, 4, sgn, S1, rb);
            rb = S1;
        } else {
            self.c.mov_rr(sz, x::RAX, ra);
        }
        if sgn {
            self.c.cqo(sz);
        } else {
            self.c.alu_rr(x::XOR, 4, x::RDX, x::RDX);
        }
        self.c.unary(
            if sgn {
                x::IDIV
            } else {
                x::DIV
            },
            sz,
            rb,
        );
        let quot = op == O_SDIV || op == O_UDIV;
        self.result_in(
            i,
            if quot {
                x::RAX
            } else {
                x::RDX
            },
        );
        // The remainder `a - q * b` (`lir::opt`'s form of `a % b` beside `a / b`) later in the block, its
        // product read by the difference alone: rdx, which the division gave (its product is no code).
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        let end = (bk.start + bk.len - 1).min(i + 1 + DIV_REACH);
        if quot {
            for m in i + 1..end {
                let u = b.insts[m as usize];
                if u.op != O_MUL || u.ty != t.ty || !(u.a == i && u.b == t.b || u.b == i && u.a == t.b) || self.lv.uses[self.vx(
                    m,
                ) as usize] != 1 || self.lv.pfold[m as usize] {
                    continue;
                }
                for s in m + 1..end {
                    let w = b.insts[s as usize];
                    if w.op == O_SUB && w.a == t.a && w.b == m && !self.lv.pfold[s as usize] {
                        self.result_in(s, x::RDX);
                        self.div_mul = m;
                        self.div_pair = s;
                        break;
                    }
                }
                break;
            }
        }
        return true;
    }

    // rdx:rax = the 128-bit product of `va0` and `vb0` (`t`: signed for O_MULHS), its high half instruction
    // `i`'s, in rdx, at the low half `lo` when not NONE (`twin_product`: `i` comes later, no code).
    fn wide_mul(self: &mut Self, i: u32, t: Inst, va0: Value, vb0: Value, lo: u32) {
        let sgn = t.op == O_MULHS;
        // MUL or IMUL: rdx:rax = rax * the operand, the second operand put in rax; an operand rax
        // holds is that one, and stays there when it dies here (at `lo`: `i`'s reads alone are left).
        let (va, vb) = if self.va[self.vx(va0) as usize].reg == x::RAX {
            (vb0, va0)
        } else {
            (va0, vb0)
        };
        let xb = self.vx(vb);
        let left = (t.a == vb) as u32 + (t.b == vb) as u32;
        let stays = self.va[xb as usize].reg == x::RAX && (!self.live_on(xb) || lo != NONE && self.lv.uses[xb as usize] == left);
        if stays {
            self.lock |= bit(x::RAX);
        } else {
            self.vacate(x::RAX);
        }
        self.vacate(x::RDX);
        let ra = self.reg(va);
        if !stays {
            self.materialize(vb, x::RAX);
        }
        self.c.unary(
            if sgn {
                x::IMUL1
            } else {
                x::MUL
            },
            8,
            ra,
        );
        if stays {
            self.va.index_mut(xb as usize).reg = NOREG;
            self.va.index_mut(xb as usize).dirty = false;
            self.set_owner(x::RAX, NONE);
        }
        self.result_in(i, x::RDX);
    }

    // The other half of 64-bit product `i` (`t`) later in its block, within DIV_REACH instructions: its high
    // half (`O_MULHU` or `O_MULHS`) when `high`, else its low half (`O_MUL`), of the same operands, computed
    // on its own (no fold) and read. NONE for none.
    fn twin_product(self: &Self, i: u32, t: Inst, high: bool) u32 {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        let end = (bk.start + bk.len - 1).min(i + 1 + DIV_REACH);
        for m in i + 1..end {
            let u = b.insts[m as usize];
            let kind = if high {
                u.op == O_MULHU || u.op == O_MULHS
            } else {
                u.op == O_MUL
            };
            if kind && u.ty == T_I64 && (u.a == t.a && u.b == t.b || u.a == t.b && u.b == t.a) && !self.lv.pfold[m as usize] && self.lv.uses[self.vx(
                m,
            ) as usize] != 0 {
                return m;
            }
        }
        return NONE;
    }

    // i128 arithmetic on two-word memory values; division and remainder call compiler-rt.
    fn int128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op >= O_SDIV && op <= O_UREM {
            let name = if op == O_SDIV {
                "__divti3"
            } else if op == O_UDIV {
                "__udivti3"
            } else if op == O_SREM {
                "__modti3"
            } else {
                "__umodti3"
            };
            return self.rt_call128(i, name, t.a, t.b);
        }
        if op == O_MUL {
            // lo = low(al * bl); hi = high(al * bl) + al * bh + ah * bl.
            self.vacate(x::RAX);
            self.vacate(x::RDX);
            let (ab, ao) = self.mloc(t.a);
            let (bb, bo) = self.mloc(t.b);
            let h = self.tmp(false);
            self.c.load(8, false, x::RAX, x::at(ab, ao as i32));
            self.c.load(8, false, h, x::at(bb, bo as i32 + 8));
            self.c.imul_rr(8, h, x::RAX);
            self.c.load(8, false, S0, x::at(ab, ao as i32 + 8));
            self.c.rm(0, 0x0FAF, true, S0, x::at(bb, bo as i32), false);
            self.c.alu_rr(x::ADD, 8, h, S0);
            self.c.rm(0, 0xF7, true, x::MUL as u8, x::at(bb, bo as i32), false);
            self.c.alu_rr(x::ADD, 8, x::RDX, h);
            self.store128(i, x::RAX, x::RDX);
            return true;
        }
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            self.vacate(x::RCX);
            let (al, ah) = self.load128(t.a);
            let (nb, no) = self.mloc(t.b);
            self.c.load(4, false, x::RCX, x::at(nb, no as i32));
            self.shift128(op, al, ah);
            self.store128(i, al, ah);
            return true;
        }
        let (al, ah) = self.load128(t.a);
        if op == O_NEG {
            self.c.unary(x::NEG, 8, al);
            self.c.alu_ri(x::ADC, 8, ah, 0);
            self.c.unary(x::NEG, 8, ah);
            self.store128(i, al, ah);
            return true;
        }
        if op == O_NOT {
            self.c.unary(x::NOT, 8, al);
            self.c.unary(x::NOT, 8, ah);
            self.store128(i, al, ah);
            return true;
        }
        let (bb, bo) = self.mloc(t.b);
        let (lo_op, hi_op) = if op == O_ADD {
            (x::ADD, x::ADC)
        } else if op == O_SUB {
            (x::SUB, x::SBB)
        } else {
            let a = alu_of(op);
            (a, a)
        };
        self.c.alu_rm(lo_op, 8, al, x::at(bb, bo as i32));
        self.c.alu_rm(hi_op, 8, ah, x::at(bb, bo as i32 + 8));
        self.store128(i, al, ah);
        return true;
    }

    // Shift the i128 in `lo`, `hi` by cl (below 128) in place; r10 holds the fill of a count past 63.
    fn shift128(self: &mut Self, op: u8, lo: u8, hi: u8) {
        if op == O_SHL {
            // hi = hi << n | lo >> (64 - n); lo <<= n; past 64 the low word moves up.
            self.c.shd_cl(true, hi, lo);
            self.c.shift_cl(x::SHL, 8, lo);
            self.c.alu_rr(x::XOR, 4, S0, S0);
            self.c.test_ri(1, x::RCX, 64);
            self.c.cmov(x::CC_NE, 8, hi, lo);
            self.c.cmov(x::CC_NE, 8, lo, S0);
            return;
        }
        // lo = lo >> n | hi << (64 - n); hi >>= n; past 64 the high word moves down and the fill is the
        // sign (an arithmetic shift) or 0.
        self.c.shd_cl(false, lo, hi);
        self.c.shift_cl(
            if op == O_ASHR {
                x::SAR
            } else {
                x::SHR
            },
            8,
            hi,
        );
        if op == O_ASHR {
            self.c.mov_rr(8, S0, hi);
            self.c.shift_ri(x::SAR, 8, S0, 63);
        } else {
            self.c.alu_rr(x::XOR, 4, S0, S0);
        }
        self.c.test_ri(1, x::RCX, 64);
        self.c.cmov(x::CC_NE, 8, lo, hi);
        self.c.cmov(x::CC_NE, 8, hi, S0);
    }

    fn ovf_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let op = t.op;
        let signed = t.aux == OV_SIGNED;
        let bits = type_bits(ty, self.ptr);
        let sz = wsz(bits);
        let mut cc = x::CC_NE;
        if bits < 32 {
            // The operands extended to 32 bits: `a` into the result, `b` into S1.
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            let rd = self.def(i);
            self.c.ext(bits / 8, 4, signed, rd, ra);
            self.c.ext(bits / 8, 4, signed, S1, rb);
            if op == O_ADDO {
                self.c.alu_rr(x::ADD, 4, rd, S1);
            } else if op == O_SUBO {
                self.c.alu_rr(x::SUB, 4, rd, S1);
            } else {
                self.c.imul_rr(4, rd, S1);
            }
            // Overflow: the 32-bit result differs from its own extension of the low bits.
            self.c.ext(bits / 8, 4, signed, S1, rd);
            self.c.alu_rr(x::CMP, 4, S1, rd);
        } else if op == O_MULO && !signed && sz == 8 {
            self.vacate(x::RAX);
            self.vacate(x::RDX);
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            self.c.mov_rr(8, x::RAX, ra);
            self.c.unary(x::MUL, 8, rb);
            cc = x::CC_O;
            self.flag_of(i, cc);
            self.result_in(i, x::RAX);
            return true;
        } else if op == O_MULO && !signed {
            // 32 bits: the product of the zero-extended operands, its high half not 0.
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            let rd = self.def(i);
            self.c.mov_rr(4, rd, ra);
            self.c.mov_rr(4, S1, rb);
            self.c.imul_rr(8, rd, S1);
            self.c.mov_rr(8, S1, rd);
            self.c.shift_ri(x::SHR, 8, S1, 32);
        } else {
            let ra = self.reg(t.a);
            let mut k: i32 = 0;
            let imm = op != O_MULO && self.imm32_of(t.b, bits, &mut k);
            let rb = if imm {
                NOREG
            } else {
                self.reg(t.b)
            };
            let rd = self.def_from(i, t.a, ra);
            if op == O_MULO {
                self.c.imul_rr(sz, rd, rb);
                cc = x::CC_O;
            } else {
                let a = if op == O_ADDO {
                    x::ADD
                } else {
                    x::SUB
                };
                if imm {
                    self.c.alu_ri(a, sz, rd, k);
                } else {
                    self.c.alu_rr(a, sz, rd, rb);
                }
                cc = if signed {
                    x::CC_O
                } else {
                    x::CC_B
                };
            }
        }
        self.flag_of(i, cc);
        return true;
    }

    // Sum or difference `i` (`t`) with the carry or borrow of the `addo` or `subo` before it, which the
    // flags hold (`lv::FOLD_ADC`): `adc` or `sbb` of its folded sum's or difference's operands; nothing before
    // it may zero a register by `xor`.
    fn adc(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let sub = t.op == O_SUB || t.op == O_SUBO;
        let h = if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.carry[t.a as usize] == lv::CARRY_PART && b.insts[t.a as usize].op != O_ZEXT {
            t.a
        } else {
            t.b
        };
        let s = b.insts[h as usize];
        let bits = type_bits(t.ty, self.ptr);
        self.keep_flags = true;
        let ra = self.reg(s.a);
        let mut k: i32 = 0;
        let imm = self.imm32_of(s.b, bits, &mut k);
        let rb = if imm {
            NOREG
        } else {
            self.reg(s.b)
        };
        let rd = self.def_from(i, s.a, ra);
        let op = if sub {
            x::SBB
        } else {
            x::ADC
        };
        if imm {
            self.c.alu_ri(op, wsz(bits), rd, k);
        } else {
            self.c.alu_rr(op, wsz(bits), rd, rb);
        }
    }

    // The overflow flag of instruction `i` is condition `cc`: for the branch right after, or set into its
    // own register.
    fn flag_of(self: &mut Self, i: u32, cc: u32) {
        if let Some(fx) = self.lv.flag_of.get(&i) {
            let f = *fx;
            if self.lv.carry[i as usize] == lv::CARRY_LO {
                // The flags keep it for the sum with it (`lv::FOLD_ADC`).
            } else if self.fusable(i, VFLAG | i) {
                self.cond = Cond { inst: f, cc: cc };
            } else if self.lv.uses[f as usize] != 0 {
                self.keep_flags = true;
                let r = self.alloc(false);
                self.bind(f, r);
                self.c.setcc(cc, r);
                self.c.ext(1, 4, false, r, r);
                self.va.index_mut(f as usize).clean = true;
            }
        }
    }

    // `r` (an xmm register) with its sign bit cleared (`abs`) or flipped.
    fn fsign(self: &mut Self, d: bool, abs: bool, r: u8) {
        let sb = if d {
            0x8000000000000000u64
        } else {
            0x80000000u64
        };
        // `andps` or `xorps` with the mask in every lane (`const_sym`).
        let m = if abs {
            ~sb & ast_mask(d)
        } else {
            sb
        };
        let w = if d {
            m
        } else {
            m | m << 32
        };
        let k = self.const_sym([w, w]);
        self.c.rm(
            0,
            if abs {
                0x0F54u32
            } else {
                0x0F57u32
            },
            false,
            r - V0,
            x::rip(),
            false,
        );
        self.reloc_rip(x::R_PC32, k, 0);
    }

    fn convert(self: &mut Self, i: u32, t: Inst) bool {
        if self.lv.pfold[i as usize] {
            return true; // its use computes it (`lv::FOLD_ROT`: a rotation's amount)
        }
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if is_vec(from) || is_vec(to) {
            if self.conv_reg(t) {
                self.vconv_reg(i, t);
                return true;
            }
            // Vectors of one size in registers: the bits stay in the register.
            if op == O_BITCAST && self.in_reg(from) && self.in_reg(to) {
                let ra = self.vec_use(t.a, self.vs0);
                let rd = self.def_over(i, t.a, ra);
                if rd != ra {
                    self.c.vmov(rd - V0, ra - V0);
                }
                return true;
            }
            if op == O_BITCAST && in_mem(from) && in_mem(to) {
                let (base, off) = self.mloc(t.a);
                let d = self.mdef(i);
                self.copy_mem(x::RSP, d, base, off, type_bytes(to, self.ptr));
                return true;
            }
            if op == O_BITCAST {
                // A vector and a scalar of one size: through memory.
                if in_mem(from) {
                    let (base, off) = self.mloc(t.a);
                    let rd = self.def(i);
                    self.ld(to, rd, x::at(base, off as i32));
                } else {
                    let ra = self.reg(t.a);
                    let d = self.mdef(i);
                    self.st(from, ra, x::at(x::RSP, d as i32));
                }
                return true;
            }
            self.vec_convert(i, t);
            return true;
        }
        if from == T_I128 || to == T_I128 {
            return self.convert128(i, t);
        }
        let fb = type_bits(from, self.ptr);
        let tb = type_bits(to, self.ptr);
        if op == O_SEXT || op == O_ZEXT {
            let ra = self.reg(t.a);
            // A zero extension of a value whose register holds nothing above its bits (a byte load's, say)
            // gives it another type.
            if op == O_ZEXT && self.va[self.vx(t.a) as usize].clean {
                let _ = self.def_from(i, t.a, ra);
                self.va.index_mut(i as usize).clean = true;
                return true;
            }
            let rd = self.def_over(i, t.a, ra);
            if op == O_SEXT {
                self.c.ext(fb / 8, wsz(tb), true, rd, ra);
            } else {
                self.c.ext(fb / 8, 4, false, rd, ra);
            }
            self.va.index_mut(i as usize).clean = op == O_ZEXT;
            return true;
        }
        if op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST && !is_v(from) && !is_v(to) {
            let ra = self.reg(t.a);
            let _ = self.def_from(i, t.a, ra);
            return true;
        }
        if op == O_BITCAST {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if is_v(from) {
                self.c.movd_from_x(fb / 8, rd, ra - V0);
            } else {
                self.c.movd_to_x(tb / 8, rd - V0, ra);
            }
            return true;
        }
        if op == O_FPEXT || op == O_FPTRUNC {
            let ra = self.reg(t.a);
            let rd = self.def_over(i, t.a, ra);
            self.c.sse_rr(
                if op == O_FPEXT {
                    0xF3u32
                } else {
                    0xF2u32
                },
                0x0F5A,
                rd - V0,
                ra - V0,
            );
            return true;
        }
        if op == O_SITOFP || op == O_UITOFP {
            let d = to == T_F64;
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if op == O_SITOFP {
                let mut r = ra;
                if fb < 32 {
                    self.c.ext(fb / 8, 4, true, S1, ra);
                    r = S1;
                }
                self.c.cvtsi2f(d, wsz(fb), rd - V0, r);
                return true;
            }
            if fb < 64 {
                // Zero-extended to 64 bits, it converts exactly as a signed value.
                self.c.ext(
                    if fb == 32 {
                        4u32
                    } else {
                        fb / 8
                    },
                    4,
                    false,
                    S1,
                    ra,
                );
                self.c.cvtsi2f(d, 8, rd - V0, S1);
                return true;
            }
            self.u2f(d, rd, ra);
            return true;
        }
        let ra = self.reg(t.a);
        let rd = self.def(i);
        self.f2i(from == T_F64, op == O_FPTOSI, tb, t.aux != CV_UNCHECKED, rd, ra);
        return true;
    }

    // xmm `rd` = the unsigned 64-bit integer in `ra` as a float (`d` double), through r10 and r11: above
    // 2^63, half of it with its low bit kept for the rounding, converted and doubled.
    fn u2f(self: &mut Self, d: bool, rd: u8, ra: u8) {
        self.c.test_rr(8, ra, ra);
        let neg = self.c.jcc32(x::CC_S);
        self.c.cvtsi2f(d, 8, rd - V0, ra);
        let done = self.c.jmp32();
        self.c.land(neg, self.c.len());
        self.c.mov_rr(8, S1, ra);
        self.c.shift_ri(x::SHR, 8, S1, 1);
        self.c.mov_rr(4, S0, ra);
        self.c.alu_ri(x::AND, 4, S0, 1);
        self.c.alu_rr(x::OR, 8, S1, S0);
        self.c.cvtsi2f(d, 8, rd - V0, S1);
        self.c.sse_rr(fpfx(d), 0x0F58, rd - V0, rd - V0);
        self.c.land(done, self.c.len());
    }

    // `rd` = float `ra` (`d` double) as an integer of `tb` bits (signed `signed`): truncated, saturating
    // (NaN is 0) when `checked`, as the evaluator's `scalar_convert`; through r11 and xmm14, xmm15.
    fn f2i(self: &mut Self, d: bool, signed: bool, tb: u32, checked: bool, rd: u8, ra: u8) {
        if signed && tb >= 32 {
            self.c.cvtf2si(d, tb / 8, rd, ra - V0);
            if checked {
                self.saturate_indefinite(d, tb / 8, rd, ra);
            }
            return;
        }
        if signed || tb < 64 {
            // Through the 64-bit conversion, exact for the range, then clamped.
            self.c.cvtf2si(d, 8, rd, ra - V0);
            if !checked {
                return;
            }
            self.saturate_indefinite(d, 8, rd, ra);
            let (lo, hi) = if signed {
                ((1u64 << (tb - 1) as u64).wrapping_neg(), (1u64 << (tb - 1) as u64) - 1)
            } else {
                (0u64, trunc64(~0u64, tb))
            };
            self.c.mov_ri(S1, hi);
            self.c.alu_rr(x::CMP, 8, rd, S1);
            self.c.cmov(x::CC_G, 8, rd, S1);
            self.c.mov_ri(S1, lo);
            self.c.alu_rr(x::CMP, 8, rd, S1);
            self.c.cmov(x::CC_L, 8, rd, S1);
            return;
        }
        // To u64: below 2^63 directly; at and above it, 2^63 less, then the top bit set.
        let two63 = if d {
            0x43E0000000000000u64
        } else {
            0x5F000000u64
        };
        self.fconst(self.vs1, d, two63);
        self.c.sse_rr(
            if d {
                0x66u32
            } else {
                0u32
            },
            0x0F2E,
            ra - V0,
            self.vs1 - V0,
        );
        let big = self.c.jcc32(x::CC_AE);
        // Below 2^63 or NaN: a negative result (NaN, or at most -1) is 0.
        self.c.cvtf2si(d, 8, rd, ra - V0);
        if checked {
            self.c.alu_rr(x::XOR, 4, S1, S1);
            self.c.test_rr(8, rd, rd);
            self.c.cmov(x::CC_S, 8, rd, S1);
        }
        let done = self.c.jmp32();
        self.c.land(big, self.c.len());
        self.c.vmov(self.vs0 - V0, ra - V0);
        self.c.sse_rr(fpfx(d), 0x0F5C, self.vs0 - V0, self.vs1 - V0);
        self.c.cvtf2si(d, 8, rd, self.vs0 - V0);
        if checked {
            // At or past 2^64 the conversion is indefinite: all ones.
            self.c.alu_ri(x::CMP, 8, rd, 1);
            let ok = self.c.jcc32(x::CC_NO);
            self.c.mov_ri(rd, 0xFFFFFFFFFFFFFFFF);
            let out = self.c.jmp32();
            self.c.land(ok, self.c.len());
            self.c.mov_ri(S1, 0x8000000000000000);
            self.c.alu_rr(x::XOR, 8, rd, S1);
            self.c.land(out, self.c.len());
        } else {
            self.c.mov_ri(S1, 0x8000000000000000);
            self.c.alu_rr(x::XOR, 8, rd, S1);
        }
        self.c.land(done, self.c.len());
    }

    // After a truncating conversion of float `ra` into `rd` (`sz` bytes): the indefinite result (the
    // lowest value) of a NaN becomes 0 and of a positive value past the range the highest.
    fn saturate_indefinite(self: &mut Self, d: bool, sz: u32, rd: u8, ra: u8) {
        // The lowest value less 1 overflows; no other does.
        self.c.alu_ri(x::CMP, sz, rd, 1);
        let ok = self.c.jcc32(x::CC_NO);
        self.c.sse_rr(
            if d {
                0x66u32
            } else {
                0u32
            },
            0x0F2E,
            ra - V0,
            ra - V0,
        );
        let nan = self.c.jcc32(x::CC_P);
        // The sign of the float: negative keeps the lowest value, positive takes the highest.
        self.c.rr(
            if d {
                0x66u32
            } else {
                0u32
            },
            0x0F50,
            false,
            S1,
            ra - V0,
            false,
        );
        self.c.test_ri(1, S1, 1);
        let neg = self.c.jcc32(x::CC_NE);
        self.c.alu_ri(x::SUB, sz, rd, 1);
        let out = self.c.jmp32();
        self.c.land(nan, self.c.len());
        self.c.alu_rr(x::XOR, 4, rd, rd);
        self.c.land(ok, self.c.len());
        self.c.land(neg, self.c.len());
        self.c.land(out, self.c.len());
    }

    // Conversions to and from i128: extensions and truncation inline, floats through compiler-rt.
    fn convert128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if op == O_SEXT || op == O_ZEXT {
            let fb = type_bits(from, self.ptr);
            let ra = self.reg(t.a);
            let lo = self.tmp(false);
            let hi = self.tmp(false);
            if op == O_SEXT {
                if fb == 64 {
                    self.c.mov_rr(8, lo, ra);
                } else {
                    self.c.ext(fb / 8, 8, true, lo, ra);
                }
                self.c.mov_rr(8, hi, lo);
                self.c.shift_ri(x::SAR, 8, hi, 63);
            } else {
                if fb == 64 {
                    self.c.mov_rr(8, lo, ra);
                } else {
                    self.c.ext(fb / 8, 4, false, lo, ra);
                }
                self.c.alu_rr(x::XOR, 4, hi, hi);
            }
            self.store128(i, lo, hi);
            return true;
        }
        if op == O_TRUNC {
            let (base, off) = self.mloc(t.a);
            let rd = self.def(i);
            self.c.load(8, false, rd, x::at(base, off as i32));
            return true;
        }
        if op == O_BITCAST {
            let (base, off) = self.mloc(t.a);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, base, off, 16);
            return true;
        }
        let d = to == T_F64;
        let fd = from == T_F64;
        let name = if op == O_SITOFP && d {
            "__floattidf"
        } else if op == O_SITOFP {
            "__floattisf"
        } else if op == O_UITOFP && d {
            "__floatuntidf"
        } else if op == O_UITOFP {
            "__floatuntisf"
        } else if op == O_FPTOSI && fd {
            "__fixdfti"
        } else if op == O_FPTOSI {
            "__fixsfti"
        } else if fd {
            "__fixunsdfti"
        } else {
            "__fixunssfti"
        };
        return self.rt_call128(i, name, t.a, VNONE);
    }

    fn ptradd(self: &mut Self, i: u32, t: Inst) bool {
        if self.lv.pfold[i as usize] {
            return true; // its one load or store addresses through its operands
        }
        let off = (t.c as i32) as i64;
        if t.b == VNONE && (t.a & (VPARAM | VFLAG)) == 0 && self.va[t.a as usize].home == H_REMAT && self.va[t.a as usize].reg == NOREG {
            let it = self.b().insts[t.a as usize];
            let p = unsafe &*self.pkg;
            if it.op == O_SYMADDR && !self.tls_sym(it.a) && !p.syms[self.b().syms[it.a as usize] as usize].ext {
                // The offset joins the symbol's in its relocation.
                let rd = self.def_pass(i, t.a);
                self.sym_addr(rd, it.a, (it.b as i32) as i64 + off);
                return true;
            }
        }
        let (base, boff) = self.addr(t.a, 0);
        if t.b == VNONE {
            let rd = self.def_pass(i, t.a);
            self.add_off(rd, base, boff + off);
            return true;
        }
        let ity = self.vt(t.b);
        let ib = type_bits(ity, self.ptr);
        let ri = self.reg(t.b);
        let scale = scale_of(t);
        let rd = self.def_pass(i, t.a);
        // The index sign-extended to 64 bits, scaled.
        let mut idx = ri;
        if ib < 64 {
            self.c.ext(ib / 8, 8, true, S0, ri);
            idx = S0;
        }
        let mut sc: u8 = 0;
        if scale == 1 || scale == 2 || scale == 4 || scale == 8 {
            sc = scale.trailing_zeros() as u8;
        } else if (scale & scale - 1) == 0 {
            // A power of two past 8: the index shifted by the rest, scaled by 8.
            if idx != S0 {
                self.c.mov_rr(8, S0, idx);
            }
            self.c.shift_ri(x::SHL, 8, S0, scale.trailing_zeros() as u32 - 3);
            idx = S0;
            sc = 3;
        } else {
            self.c.imul_ri(8, S0, idx, scale as i32);
            idx = S0;
        }
        let disp = boff + off;
        if disp >= -2147483648 && disp <= 2147483647 {
            self.c.lea(rd, x::ix(base, idx, sc, disp as i32));
        } else {
            self.c.lea(rd, x::ix(base, idx, sc, 0));
            self.add_any(rd, disp);
        }
        return true;
    }

    fn load(self: &mut Self, i: u32, t: Inst) bool {
        if self.lv.pfold[i as usize] {
            return true; // its use reads the memory (`lv::FOLD_LDOP`)
        }
        let ty = t.ty;
        // A part of a register-passed aggregate: its register already.
        for q in 0..self.taken.len() {
            if self.taken[q] as u32 == i {
                return true;
            }
        }
        if self.rmw(i, t) {
            return true;
        }
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        if in_mem(ty) && !self.in_reg(ty) {
            let (base, off) = self.addr(t.a, t.c as i32);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, base, off, type_bytes(ty, self.ptr));
            return true;
        }
        // The register the next instruction takes the value in stays out of the address's temporaries.
        let nr = if self.in_reg(ty) {
            NOREG
        } else {
            self.next_reg(i)
        };
        let saved = self.lock;
        if nr != NOREG {
            self.lock |= bit(nr);
        }
        let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
        self.lock = saved;
        // A scalar over its address when the address dies here (`mov r8, [r8 + 8]`), unless the next
        // instruction takes it in another register (a return's).
        let ra = self.va[self.vx(t.a) as usize].reg;
        let rd = if self.in_reg(ty) {
            self.vec_def(i)
        } else if ra != NOREG && ra < V0 && !is_v(ty) && (nr == NOREG || nr == ra) {
            self.def_over(i, t.a, ra)
        } else {
            self.def_pass(i, t.a)
        };
        self.ld(ty, rd, m);
        self.mem_rel(rs, radd);
        self.va.index_mut(i as usize).clean = !is_v(ty) && type_bits(ty, self.ptr) < 64;
        return true;
    }

    // Whether every return of the body takes the result from a run of part stores (`rstore`): then nothing
    // reads the result's memory, which needs no slot.
    fn ret_moved(self: &Self) bool {
        let b = self.b();
        let mut any = false;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            let end = bk.start + bk.len - 1;
            if bk.len == 0 || b.insts[end as usize].op != O_RET {
                continue;
            }
            if end == bk.start || self.rstore[end as usize - 1] == 0 {
                return false;
            }
            any = true;
        }
        return any;
    }

    // `rload`: per call of an aggregate result in registers, the loads right after it that its parts
    // give (`place::result_loads`), else 0.
    fn res_relays(self: &mut Self) {
        let b = self.b();
        fill(&mut self.rload, b.insts.len(), 0);
        if b.slots.len() == 0 {
            return;
        }
        place::slot_uses(b, &self.lv, &mut self.suse);
        for i in 0..b.insts.len() as u32 {
            let t = b.insts[i as usize];
            if (t.op == O_CALL || t.op == O_CALLIND) && (b.pool[t.b as usize + 2] & AGG) != 0 {
                self.call_layout(t);
                self.rload[i as usize] = place::result_loads(b, &self.lv, &self.lay, self.ptr, &self.suse, i);
            }
        }
    }

    // Call `i` (`lay` its layout) of an aggregate result whose parts the loads after it read (`rload`):
    // each load's value in its part's register, which the result's memory never holds; the loads emit
    // nothing (`taken`). A load with a fixed home moves there; one without takes its part's register, or a
    // free one when a fixed home or another load of that part has it (`rdx`, say); the moves are one
    // parallel move.
    fn relay_result(self: &mut Self, i: u32) {
        let b = self.b();
        let rl = self.lay.ret;
        for q in 0..rl.n as u32 {
            let pa = self.lay.parts[(rl.p0 + q) as usize];
            self.lock |= bit(
                pa.reg + if pa.v {
                    V0
                } else {
                    0
                },
            );
        }
        self.mv.truncate(0);
        let mut homes: u64 = 0;
        // The part registers a load took; a second load of that part takes a register of its own.
        let mut bound: u64 = 0;
        for pass in 0..2u32 {
            for k in 1..self.rload[i as usize] + 1 {
                let j = i + k;
                let pa = self.lay.parts[(rl.p0 + place::result_part(&self.lay, self.ptr, b.insts[j as usize])) as usize];
                let r = pa.reg + if pa.v {
                    V0
                } else {
                    0
                };
                let x = self.vx(j);
                if pass == 0 {
                    self.taken.push(j);
                }
                if !self.live_on(x) {
                    continue;
                }
                let fixed = self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE;
                if fixed != (pass == 0) {
                    continue;
                }
                if !fixed && ((homes | bound) & bit(r)) == 0 {
                    self.bind(x, r);
                    bound |= bit(r);
                    continue;
                }
                let rd = self.def(j);
                homes |= bit(rd);
                self.mv.push(
                    Mv {
                        src: Lc { kind: LC_REG, reg: r, off: 0, val: NONE },
                        dst: Lc { kind: LC_REG, reg: rd, off: 0, val: NONE },
                        v: pa.v,
                        bytes: 8,
                        done: false,
                    },
                );
            }
        }
        resolve_moves(self);
    }

    // `rstore`: when the result (an aggregate in registers) is written only by stores that end blocks
    // which return, each a whole part and only such stores between it and the `ret`, 1 + each one's part:
    // the first of each run moves the run's values into the part registers (`ret_moves`), and the return
    // reads no memory. All 0 when not.
    fn ret_stores(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill(&mut self.rstore, ni, 0);
        let rt = b.pool[b.sig as usize + 2];
        if self.self_lay.ret.kind != ab::L_REG || (rt & AGG) == 0 {
            return;
        }
        let pv = VPARAM | b.blocks[0].param_start + b.pool[b.sig as usize];
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            let end = bk.start + bk.len - 1;
            // The run of result stores right before a `ret`.
            let mut run = end;
            if b.insts[end as usize].op == O_RET {
                while run > bk.start && self.part_store(b.insts[run as usize - 1], pv) != NONE {
                    run -= 1;
                }
            }
            for i in bk.start..end + 1 {
                let t = b.insts[i as usize];
                lv::each_use(b, t, &mut self.uses);
                let mut reads = false;
                for q in 0..self.uses.len() {
                    reads = reads || self.uses[q] == pv;
                }
                if !reads {
                    continue;
                }
                // The `ret` reads the result's memory: the stores before it, which become its moves.
                if i == end && t.op == O_RET {
                    continue;
                }
                if i < run || i == end {
                    fill(&mut self.rstore, ni, 0);
                    return;
                }
                self.rstore[i as usize] = self.part_store(t, pv) + 1;
            }
        }
    }

    // The result part store `t` writes whole through the result's address `pv`, else NONE.
    fn part_store(self: &Self, t: Inst, pv: Value) u32 {
        if t.op != O_STORE || t.a != pv || t.b == pv || (t.aux & MEM_VOLATILE) != 0 {
            return NONE;
        }
        let ty = self.vt(t.b);
        let rl = self.self_lay.ret;
        for q in 0..rl.n as u32 {
            let pa = self.self_lay.parts[(rl.p0 + q) as usize];
            if pa.off == t.c && pa.size as u32 == type_bytes(ty, self.ptr) && pa.v == is_v(ty) && !in_mem(ty) {
                return q;
            }
        }
        return NONE;
    }

    // Result store `i`, the first of its run (`ret_stores`): the values of the run's stores into their
    // parts' registers as one parallel move (the last store of a part wins), constants after.
    fn ret_moves(self: &mut Self, i: u32) {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        let end = bk.start + bk.len - 1;
        let rl = self.self_lay.ret;
        self.mv.truncate(0);
        let mut seen: u32 = 0;
        let mut vals = Vector::<u64>::new();
        // Each step goes back one store of the run.
        let mut j = end;
        while j > i {
            j -= 1;
            let q = self.rstore[j as usize] - 1;
            if (seen >> q & 1) != 0 {
                continue;
            }
            seen |= 1u32 << q;
            let pa = self.self_lay.parts[(rl.p0 + q) as usize];
            let r = pa.reg + if pa.v {
                V0
            } else {
                0
            };
            let v = b.insts[j as usize].b;
            let src = self.loc_of(self.vx(v));
            if src.kind == LC_VAL {
                vals.push(r as u64 << 32 | v as u64);
                continue;
            }
            self.mv.push(
                Mv {
                    src: src,
                    dst: Lc { kind: LC_REG, reg: r, off: 0, val: NONE },
                    v: pa.v,
                    bytes: pa.size,
                    done: false,
                },
            );
        }
        resolve_moves(self);
        for k in 0..vals.len() {
            self.materialize(vals[k] as u32, (vals[k] >> 32) as u8);
        }
    }

    // Load `i`, then an `add`, `sub`, `and`, `or` or `xor` of its value alone, then a store of the result
    // to the same place, each value read once: one operation on memory (`add [m], k`), the next two
    // instructions done (`fused`). Whether it was.
    fn rmw(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        if i + 2 >= bk.start + bk.len - 1 || (t.aux & MEM_VOLATILE) != 0 || !is_int(t.ty) || t.ty == T_I128 || self.lv.fold[i as usize] {
            return false;
        }
        let o = b.insts[i as usize + 1];
        let st = b.insts[i as usize + 2];
        let alu = o.op == O_ADD || o.op == O_SUB || o.op == O_AND || o.op == O_OR || o.op == O_XOR;
        let swap = o.op != O_SUB && o.b == i && o.a != i;
        let k = if swap {
            o.a
        } else {
            o.b
        };
        // An operand folded into the operation (`lv::FOLD_LEA`, `lv::FOLD_ROT`) has no register.
        if !alu || o.ty != t.ty || !swap && (o.a != i || o.b == i) || self.lv.pfold[i as usize + 1] || self.folded(k) {
            return false;
        }
        if st.op != O_STORE || st.b != i + 1 || st.a != t.a || st.c != t.c || (st.aux & MEM_VOLATILE) != 0 || self.lv.fold[i as usize + 2] {
            return false;
        }
        if self.lv.uses[i as usize] != 1 || self.lv.uses[i as usize + 1] != 1 || self.lv.end[i as usize] != self.pos || self.lv.end[i as usize + 1] != self.pos {
            return false;
        }
        let sz = type_bytes(t.ty, self.ptr);
        let mut imm: i32 = 0;
        let kc = self.imm32_of(k, type_bits(t.ty, self.ptr), &mut imm);
        let rk = if kc {
            NOREG
        } else {
            self.reg(k)
        };
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
        if kc {
            self.c.alu_mi(alu_of(o.op), sz, m, imm);
        } else {
            self.c.alu_mr(alu_of(o.op), sz, m, rk);
        }
        self.mem_rel(rs, radd);
        self.fused = i + 2;
        return true;
    }

    fn store(self: &mut Self, t: Inst) bool {
        if self.cur >= self.zero_from && self.cur < self.zero_end {
            return true; // the run of zero stores before it wrote its bytes (`zero_run`)
        }
        let ty = self.vt(t.b);
        // A store a call takes the value of (`arg_relays`) writes nothing.
        if self.lv.relay.len() != 0 && self.lv.relay[self.cur as usize] != NONE {
            return true;
        }
        // A store of the result's part: its run's first moves the run into the part registers.
        let c = self.cur;
        if self.rstore[c as usize] != 0 {
            if c == self.b().blocks[self.lv.def_blk[c as usize] as usize].start || self.rstore[c as usize - 1] == 0 {
                self.ret_moves(c);
            }
            return true;
        }
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        if self.in_reg(ty) {
            let r = self.vec_use(t.b, self.vs0);
            let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
            self.st(ty, r, m);
            self.mem_rel(rs, radd);
            return true;
        }
        if in_mem(ty) {
            let (base, off) = self.addr(t.a, t.c as i32);
            let (sb, so) = self.mloc(t.b);
            self.copy_mem(base, off, sb, so, type_bytes(ty, self.ptr));
            return true;
        }
        let n = type_bytes(ty, self.ptr);
        let mut k: i32 = 0;
        // A folded read-modify-write (`lv::FOLD_RMW`): the operation on the memory.
        if (t.b & (VPARAM | VFLAG)) == 0 && t.b != VNONE && self.lv.pfold[t.b as usize] && lv::rmw_load(
            self.b(),
            &self.lv.pfold,
            t,
        ) != VNONE {
            let o = self.b().insts[t.b as usize];
            let l = lv::rmw_load(self.b(), &self.lv.pfold, t);
            let other = if o.a == l {
                o.b
            } else {
                o.a
            };
            let imm = self.imm32_of(other, n * 8, &mut k);
            let r = if imm {
                NOREG
            } else {
                self.reg(other)
            };
            let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
            if imm {
                self.c.alu_mi(alu_of(o.op), n, m, k);
            } else {
                self.c.alu_mr(alu_of(o.op), n, m, r);
            }
            self.mem_rel(rs, radd);
            return true;
        }
        if !is_v(ty) && self.imm32_of(t.b, n * 8, &mut k) {
            if n == 8 && k == 0 && (t.aux & MEM_VOLATILE) == 0 && self.zero_run(t) {
                return true;
            }
            let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
            self.c.store_i(n, k, m);
            self.mem_rel(rs, radd);
            return true;
        }
        let r = self.reg(t.b);
        let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
        self.st(ty, r, m);
        self.mem_rel(rs, radd);
        return true;
    }

    // A run of at least ZERO_RUN 8-byte stores of 0 from store `t` (the current instruction) on, one after
    // another at consecutive offsets of one address: a zeroed xmm register stored 16 bytes at a time (clang's
    // `xorps` and `movups`), the odd last 8 bytes as a store of 0. The run's other stores then write
    // nothing (`zero_from`, `zero_end`). Whether it was one.
    fn zero_run(self: &mut Self, t: Inst) bool {
        let b = self.b();
        let c = self.cur;
        let bk = b.blocks[self.lv.def_blk[c as usize] as usize];
        let last = (bk.start + bk.len - 1).min(c + ZERO_RUN_MAX);
        let mut j = c + 1;
        while j < last {
            let u = b.insts[j as usize];
            let mut k: i32 = 0;
            if u.op != O_STORE || u.a != t.a || u.c as i32 != t.c as i32 + 8 * (j - c) as i32 || (u.aux & MEM_VOLATILE) != 0 || self.vt(
                u.b,
            ) != self.vt(t.b) || !self.imm32_of(u.b, 64, &mut k) || k != 0 || self.rstore[j as usize] != 0 || self.lv.relay.len() != 0 && self.lv.relay[j as usize] != NONE {
                break;
            }
            j += 1;
        }
        let len = j - c;
        if len < ZERO_RUN {
            return false;
        }
        let z = self.tmp(true);
        self.c.sse_rr(0, 0x0F57, z - V0, z - V0);
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        for p in 0..len / 2 {
            let m = self.mem_at(t.a, t.c as i32 + 16 * p as i32, &mut rs, &mut radd);
            self.c.vstore(16, z - V0, m);
            self.mem_rel(rs, radd);
        }
        if len % 2 != 0 {
            let m = self.mem_at(t.a, t.c as i32 + 8 * (len - 1) as i32, &mut rs, &mut radd);
            self.c.store_i(8, 0, m);
            self.mem_rel(rs, radd);
        }
        self.zero_from = c + 1;
        self.zero_end = j;
        return true;
    }

    // `memcpy` and `memset`: inline for a constant size up to 128 bytes (an overlapping copy loads every
    // chunk before storing one, up to 64 bytes), else a call of the C library's routine.
    fn mem_block(self: &mut Self, i: u32, t: Inst) bool {
        let mut n: u64 = 0;
        let known = self.const_of(t.c, &mut n);
        let overlap = t.op == O_MEMCPY && t.aux == MEM_OVERLAP;
        let lim: u64 = if overlap {
            64
        } else {
            128
        };
        if known && n == 0 {
            return true; // no byte to write
        }
        if known && n <= lim {
            let (db, doff) = self.addr(t.a, 0);
            if t.op == O_MEMSET {
                let mut k: u64 = 0;
                if self.const_of(t.b, &mut k) {
                    self.c.mov_ri(S1, (k & 0xFF) * 0x0101010101010101);
                } else {
                    // Replicate the byte into every byte of r11.
                    let rb = self.reg(t.b);
                    self.c.ext(1, 4, false, S1, rb);
                    self.c.mov_ri(S0, 0x0101010101010101);
                    self.c.imul_rr(8, S1, S0);
                }
                let mut at: u32 = 0;
                // Chunks of 8, 4, 2, 1 bytes.
                while at as u64 < n {
                    let left = n as u32 - at;
                    let step = if left >= 8 {
                        8u32
                    } else if left >= 4 {
                        4u32
                    } else if left >= 2 {
                        2u32
                    } else {
                        1u32
                    };
                    self.c.store(step, S1, x::at(db, (doff + at as i64) as i32));
                    at += step;
                }
                return true;
            }
            let (sb, soff) = self.addr(t.b, 0);
            if !overlap || n <= 16 && (n & n - 1) == 0 {
                self.copy_mem(db, doff, sb, soff, n as u32);
                return true;
            }
            // Every chunk into a register first.
            let mut regs = Vector::<u8>::new();
            let mut at: u32 = 0;
            while at as u64 < n {
                let left = n as u32 - at;
                let step = chunk(left);
                let r = self.tmp(step == 16);
                if step == 16 {
                    self.c.vload(16, r - V0, x::at(sb, (soff + at as i64) as i32));
                } else {
                    self.c.load(step, false, r, x::at(sb, (soff + at as i64) as i32));
                }
                regs.push(r);
                at += step;
            }
            at = 0;
            for q in 0..regs.len() {
                let left = n as u32 - at;
                let step = chunk(left);
                if step == 16 {
                    self.c.vstore(16, regs[q] - V0, x::at(db, (doff + at as i64) as i32));
                } else {
                    self.c.store(step, regs[q], x::at(db, (doff + at as i64) as i32));
                }
                at += step;
            }
            return true;
        }
        let name = if t.op == O_MEMSET {
            "memset"
        } else if overlap {
            "memmove"
        } else {
            "memcpy"
        };
        let vs: [Value; 3] = [t.a, t.b, t.c];
        if self.mem_tail(i, t) {
            // Through a copy of the epilogue (`finish`): a jump to the routine.
            self.rt_args(vs);
            let at = self.c.jmp32();
            let os = self.obj().sym(name);
            self.tails.push(at as u64 << 32 | os as u64);
            self.tail_ret = i + 1;
            return true;
        }
        self.rt_call(name, vs);
        return true;
    }

    // Whether copy or fill `t`, instruction `i`, calls its C routine as a sibling call (`tail_ok`): of that
    // shape (`mem_tail_shape`), neither address may point into this frame (`place::frame_based`). Its return
    // is not emitted (`tail_ret`).
    fn mem_tail(self: &Self, i: u32, t: Inst) bool {
        let b = self.b();
        return self.tail_ok && self.mem_tail_shape(i, t) && !place::frame_based(b, &self.pheld, t.a, place::FRAME_DEPTH) && (t.op == O_MEMSET || !place::frame_based(
            b,
            &self.pheld,
            t.b,
            place::FRAME_DEPTH,
        ));
    }

    // Whether copy or fill `t`, instruction `i`, calls its C routine (no constant size it does inline) right
    // before the body returns nothing: a sibling call where `mem_tail` holds, which `shrinkable` reads before
    // `tail_ok` is known (when it fails, the warm code calls, and the body is compiled again unshrunk).
    fn mem_tail_shape(self: &Self, i: u32, t: Inst) bool {
        let b = self.b();
        if t.op != O_MEMCPY && t.op != O_MEMSET || b.pool[b.sig as usize + 2] != T_NONE as u32 {
            return false;
        }
        let mut n: u64 = 0;
        let lim: u64 = if t.op == O_MEMCPY && t.aux == MEM_OVERLAP {
            64
        } else {
            128
        };
        if self.const_of(t.c, &mut n) && n <= lim {
            return false;
        }
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        let r = b.insts[i as usize + 1];
        return i + 2 == bk.start + bk.len && r.op == O_RET && r.a == VNONE;
    }

    // The condition a `br` or `select` reads from boolean `v` (index `cx`): the flags an instruction left,
    // else its low byte tested.
    fn cond_of(self: &mut Self, cx: u32, v: Value) u32 {
        let fc = self.folded_cmp(v);
        if fc != NONE {
            return fc;
        }
        if self.pend.inst == cx && self.pend.inst != NONE {
            self.keep_flags = true;
            return self.pend.cc;
        }
        let r = self.reg(v);
        self.c.test_ri(1, r, 0xFF);
        self.keep_flags = true;
        return x::CC_NE;
    }

    fn select_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        if (t.b & (VPARAM | VFLAG)) == 0 && t.b != VNONE && self.lv.pfold[t.b as usize] && lv::cs_kind(
            self.b(),
            t.b,
            t.c,
        ) == lv::CS_INC || (t.c & (VPARAM | VFLAG)) == 0 && t.c != VNONE && self.lv.pfold[t.c as usize] && lv::cs_kind(
            self.b(),
            t.c,
            t.b,
        ) == lv::CS_INC {
            self.carry_select(i, t);
            return true;
        }
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && self.b().insts[t.a as usize].op == O_FCMP {
            self.fsel(i, t);
            return true;
        }
        if self.abs_select(i, t) {
            return true;
        }
        let cx = self.vx(t.a);
        // The condition first: a folded comparison loads its operands, which the values' registers survive.
        let cc = self.cond_of(cx, t.a);
        if in_mem(ty) {
            // The chosen value's address, then a copy.
            let (b1, o1) = self.mloc(t.b);
            let (b2, o2) = self.mloc(t.c);
            let ra = self.tmp(false);
            let rb = self.tmp(false);
            self.c.lea(ra, x::at(b1, o1 as i32));
            self.c.lea(rb, x::at(b2, o2 as i32));
            self.c.cmov(cc, 8, rb, ra);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, rb, 0, type_bytes(ty, self.ptr));
            return true;
        }
        if is_v(ty) {
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let rd = self.def(i);
            self.c.vmov(rd - V0, rb - V0);
            let skip = self.c.jcc32(cc);
            self.c.vmov(rd - V0, rc - V0);
            self.c.land(skip, self.c.len());
            return true;
        }
        // A constant true side (the false side not one, nor dying here in the register a return right after
        // wants): the constant into the result's register, the false side moved in with the condition inverted.
        let mut kc: u64 = 0;
        let rcw = self.va[self.vx(t.c) as usize].reg;
        if t.b != t.c && self.const_of(t.b, &mut kc) && !self.const_of(t.c, &mut kc) && rcw != NOREG && !(self.dies_here(
            t.c,
        ) && self.ret_want(i) == rcw) {
            let rc = self.reg(t.c);
            let rd = self.def(i);
            self.materialize(t.b, rd);
            self.c.cmov(x::invert(cc), 8, rd, rc);
            return true;
        }
        // The false side straight into the result's register: a constant or a spilled value takes no
        // register of its own.
        let rb = self.reg(t.b);
        // A constant false side when the return right after wants the true side's register, which dies
        // here: the result takes it, and the constant moves in with the condition inverted.
        if t.b != t.c && self.const_of(t.c, &mut kc) && self.dies_here(t.b) && self.ret_want(i) == rb {
            let rk = self.tmp(false);
            self.materialize(t.c, rk);
            let rd = self.def_over(i, t.b, rb);
            if rd != rb {
                self.c.mov_rr(8, rd, rb);
            }
            self.c.cmov(x::invert(cc), 8, rd, rk);
            return true;
        }
        if t.b == t.c || self.const_of(t.c, &mut kc) || self.va[self.vx(t.c) as usize].reg == NOREG {
            let rd = self.def(i);
            self.materialize(t.c, rd);
            self.c.cmov(cc, 8, rd, rb);
            return true;
        }
        // Both in registers: the result takes the register of a side that dies here when a return right
        // after wants that one, or wants none and the result has no home (the true side's with the
        // condition inverted).
        let rc = self.reg(t.c);
        let want = self.ret_want(i);
        let free = want == NOREG && self.fix_class(self.vx(i)) == FIX_NONE;
        let dc = self.dies_here(t.c);
        let db = self.dies_here(t.b);
        let tb = db && (want == rb || free && !dc);
        if !tb && !(dc && (want == rc || free)) {
            let rd = self.def(i);
            self.materialize(t.c, rd);
            self.c.cmov(cc, 8, rd, rb);
            return true;
        }
        let (s, rs, ro, c1) = if tb {
            (t.b, rb, rc, x::invert(cc))
        } else {
            (t.c, rc, rb, cc)
        };
        let rd = self.def_over(i, s, rs);
        if rd != rs {
            self.c.mov_rr(8, rd, rs);
        }
        self.c.cmov(c1, 8, rd, ro);
        return true;
    }

    // Select `i` (`t`) on a folded signed comparison of `x` with 0 between `x` and its negation, which the
    // instruction just emitted computed: the sign that negation set picks `x` (`cmovs` for the absolute
    // value, `cmovns` for its negation), with no comparison. Whether it did.
    fn abs_select(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        if (t.a & (VPARAM | VFLAG)) != 0 || !self.lv.pfold[t.a as usize] || b.insts[t.a as usize].op != O_ICMP {
            return false;
        }
        let (n, x, neg_true) = if lv::cs_kind(b, t.b, t.c) == lv::CS_NEG {
            (t.b, t.c, true)
        } else if lv::cs_kind(b, t.c, t.b) == lv::CS_NEG {
            (t.c, t.b, false)
        } else {
            return false;
        };
        let c = b.insts[t.a as usize];
        let mut k: u64 = 0;
        let zb = c.a == x && self.const_of(c.b, &mut k) && k == 0;
        if !zb && !(c.b == x && self.const_of(c.a, &mut k) && k == 0) {
            return false;
        }
        let cc = if zb {
            c.aux
        } else {
            mirror(c.aux)
        };
        let below = cc == C_SLT || cc == C_SLE;
        if !below && cc != C_SGT && cc != C_SGE {
            return false;
        }
        let z = self.zf;
        let rn = self.va[self.vx(n) as usize].reg;
        if z.at != self.c.len() || z.pos != self.pos || rn == NOREG || z.reg != rn || z.sz != type_bytes(
            self.vt(x),
            self.ptr,
        ) || self.const_of(x, &mut k) {
            return false;
        }
        let rx = self.reg(x);
        let rd = self.def_over(i, n, rn);
        if rd != rn {
            self.c.mov_rr(8, rd, rn);
        }
        self.c.cmov(
            if below == neg_true {
                x::CC_S
            } else {
                x::CC_NS
            },
            8,
            rd,
            rx,
        );
        return true;
    }

    // The register a return right after value `v` takes it in; NOREG when no such return follows.
    fn ret_want(self: &Self, v: Value) u8 {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[v as usize] as usize];
        let rl = self.self_lay.ret;
        if v + 1 >= bk.start + bk.len || b.insts[v as usize + 1].op != O_RET || b.insts[v as usize + 1].a != v || rl.kind != ab::L_REG || rl.n != 1 || self.self_lay.parts[rl.p0 as usize].v {
            return NOREG;
        }
        return self.self_lay.parts[rl.p0 as usize].reg;
    }

    // Whether value `v`, in a register it owns, dies at this instruction (`def_over` may take that
    // register).
    fn dies_here(self: &Self, v: Value) bool {
        let x = self.vx(v);
        let r = self.va[x as usize].reg;
        return r != NOREG && self.owner[r as usize] == x && ((self.xalloc | self.valloc) & bit(r)) != 0 && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos;
    }

    // `va_start`: the `va_list` at `t.a` takes the offsets of the first variadic register in the save area
    // (integer, then vector), the first stack one's address and the save area's address.
    fn va_start(self: &mut Self, t: Inst) {
        let ra = self.reg(t.a);
        if self.win {
            // The address of the first variadic argument's position.
            self.c.lea(S0, x::at(self.fb, 16 + self.self_lay.named_bytes as i32));
            self.c.store(8, S0, x::at(ra, 0));
            return;
        }
        let gp = 8 * self.self_lay.named_gp as i32;
        let fp = 48 + 16 * self.self_lay.named_vr as i32;
        let ov = 16 + (self.self_lay.named_bytes + 7 & ~7u32) as i32;
        self.c.store_i(4, gp, x::at(ra, 0));
        self.c.store_i(4, fp, x::at(ra, 4));
        self.c.lea(S0, x::at(self.fb, ov));
        self.c.store(8, S0, x::at(ra, 8));
        self.c.lea(S0, x::at(x::RSP, self.save_off as i32));
        self.c.store(8, S0, x::at(ra, 16));
    }

    // `va_arg`: the next variadic argument from the `va_list` at `t.a`: from the save area while its
    // registers last (integer ones up to 48 bytes, vector ones up to 176), else from the stack.
    fn va_arg(self: &mut Self, i: u32, t: Inst) bool {
        let ra = self.reg(t.a);
        let ty = t.ty;
        let sz = type_bytes(ty, self.ptr);
        if self.win {
            // r10 = the position's address; a value past 8 bytes (or of another size) is behind a pointer.
            self.c.load(8, false, S0, x::at(ra, 0));
            self.c.lea(S1, x::at(S0, 8));
            self.c.store(8, S1, x::at(ra, 0));
            if ty == T_I128 || is_vec(ty) && sz != 1 && sz != 2 && sz != 4 && sz != 8 {
                self.c.load(8, false, S0, x::at(S0, 0));
            }
            if in_mem(ty) {
                let d = self.mdef(i);
                self.copy_mem(x::RSP, d, S0, 0, sz);
            } else {
                let rd = self.def(i);
                self.ld(ty, rd, x::at(S0, 0));
            }
            return true;
        }
        let mut ngp: u32 = 0;
        let mut nvr: u32 = 0;
        let regs = cc::va_regs(ty, self.ptr, self.vregs, &mut ngp, &mut nvr);
        // r10 = the argument's address.
        let mut out: u32 = NONE;
        if regs {
            let (field, lim, step) = if ngp != 0 {
                (0i32, 48 - 8 * ngp as i32, 8 * ngp as i32)
            } else {
                (4i32, 176 - 16 * nvr as i32, 16 * nvr as i32)
            };
            self.c.load(4, false, S1, x::at(ra, field));
            self.c.alu_ri(x::CMP, 4, S1, lim);
            let over = self.c.jcc32(x::CC_A);
            self.c.load(8, false, S0, x::at(ra, 16));
            self.c.alu_rr(x::ADD, 8, S0, S1);
            self.c.alu_ri(x::ADD, 4, S1, step);
            self.c.store(4, S1, x::at(ra, field));
            out = self.c.jmp32();
            self.c.land(over, self.c.len());
        }
        self.c.load(8, false, S0, x::at(ra, 8));
        if type_align(ty, self.ptr) == 16 {
            self.c.alu_ri(x::ADD, 8, S0, 15);
            self.c.alu_ri(x::AND, 8, S0, -16);
        }
        self.c.lea(S1, x::at(S0, (sz + 7 & ~7u32) as i32));
        self.c.store(8, S1, x::at(ra, 8));
        if out != NONE {
            self.c.land(out, self.c.len());
        }
        if in_mem(ty) {
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, S0, 0, sz);
        } else {
            let rd = self.def(i);
            self.ld(ty, rd, x::at(S0, 0));
        }
        return true;
    }

    // Atomic loads, stores, read-modify-writes, compare-and-swaps and fences: x86-64 orders plain loads and
    // stores as acquire and release; a sequentially consistent store and every read-modify-write are
    // locked.
    fn atomic(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op == O_FENCE {
            if (t.aux & 7) == MO_SEQ_CST {
                self.c.mfence();
            }
            return true;
        }
        let ty = if op == O_ALOAD || op == O_ARMW {
            t.ty
        } else {
            self.vt(t.b)
        };
        assert(!in_mem(ty) && !is_v(ty), "x64gen: an atomic access of a type the verifier rejects");
        let sz = type_bytes(ty, self.ptr);
        let ord = t.aux & 7;
        let rmw_or = op == O_ARMW && (t.aux >> 4 == RMW_AND || t.aux >> 4 == RMW_OR || t.aux >> 4 == RMW_XOR);
        if op == O_ACAS || rmw_or {
            self.vacate(x::RAX);
        }
        let (base, off) = self.addr(
            t.a,
            if op == O_ACAS {
                0
            } else {
                t.c as i32
            },
        );
        let m = x::at(base, off as i32);
        if op == O_ALOAD {
            let rd = self.def(i);
            self.c.load(sz, false, rd, m);
            self.va.index_mut(i as usize).clean = sz < 8;
            return true;
        }
        if op == O_ASTORE {
            let rv = self.reg(t.b);
            if ord == MO_SEQ_CST {
                self.c.mov_rr(8, S1, rv);
                self.c.xchg_m(sz, S1, m);
            } else {
                self.c.store(sz, rv, m);
            }
            return true;
        }
        if op == O_ARMW {
            let r = t.aux >> 4;
            // A sum, difference, and, or or xor whose old value nothing reads: one locked operation on the
            // memory (`lock or [m], 4`), every order's (a locked instruction is a full barrier).
            if r != RMW_XCHG && !self.live_on(self.vx(i)) {
                let alu = if r == RMW_ADD {
                    x::ADD
                } else if r == RMW_SUB {
                    x::SUB
                } else if r == RMW_AND {
                    x::AND
                } else if r == RMW_OR {
                    x::OR
                } else {
                    x::XOR
                };
                let mut k: i32 = 0;
                if self.imm32_of(t.b, sz * 8, &mut k) {
                    self.c.byte(0xF0);
                    self.c.alu_mi(alu, sz, m, k);
                } else {
                    let rv = self.reg(t.b);
                    self.c.byte(0xF0);
                    self.c.alu_mr(alu, sz, m, rv);
                }
                return true;
            }
            let rv = self.reg(t.b);
            if r == RMW_XCHG || r == RMW_ADD || r == RMW_SUB {
                let rd = self.def(i);
                self.c.mov_rr(8, rd, rv);
                if r == RMW_XCHG {
                    self.c.xchg_m(sz, rd, m);
                } else {
                    if r == RMW_SUB {
                        self.c.unary(x::NEG, 8, rd);
                    }
                    self.c.lock_xadd(sz, rd, m);
                }
                return true;
            }
            // and, or, xor: a compare-and-swap loop from the current value.
            self.c.load(sz, false, x::RAX, m);
            let top = self.c.len();
            self.c.mov_rr(8, S1, x::RAX);
            self.c.alu_rr(
                if r == RMW_AND {
                    x::AND
                } else if r == RMW_OR {
                    x::OR
                } else {
                    x::XOR
                },
                8,
                S1,
                rv,
            );
            self.c.lock_cmpxchg(sz, S1, m);
            self.c.jcc_back(x::CC_NE, top);
            self.result_in(i, x::RAX);
            return true;
        }
        // Compare and swap: rax takes the expected value; ZF tells the success.
        let re = self.reg(t.b);
        let rn = self.reg(t.c);
        self.c.mov_rr(8, x::RAX, re);
        self.c.lock_cmpxchg(sz, rn, m);
        self.cond_value(i, x::CC_E, NONE, false);
        return true;
    }
}

// The ALU operation of integer LIR operation `op`.
const fn alu_of(op: u8) u32 {
    if op == O_ADD {
        return x::ADD;
    }
    if op == O_SUB {
        return x::SUB;
    }
    if op == O_AND {
        return x::AND;
    }
    if op == O_OR {
        return x::OR;
    }
    return x::XOR;
}

// The scalar SSE prefix of a double (`d`) or single operation.
const fn fpfx(d: bool) u32 {
    if d {
        return 0xF2;
    }
    return 0xF3;
}

// The SSE opcode of float operation `op` (O_FADD .. O_FDIV).
const fn fop(op: u8) u32 {
    if op == O_FADD {
        return 0x0F58;
    }
    if op == O_FSUB {
        return 0x0F5C;
    }
    if op == O_FMUL {
        return 0x0F59;
    }
    return 0x0F5E;
}

// The bits of a double (`d`) or single.
const fn ast_mask(d: bool) u64 {
    if d {
        return 0xFFFFFFFFFFFFFFFF;
    }
    return 0xFFFFFFFF;
}

// The chunk of a copy with `left` bytes to go: 16, 8, 4, 2 or 1.
const fn chunk(left: u32) u32 {
    if left >= 16 {
        return 16;
    }
    if left >= 8 {
        return 8;
    }
    if left >= 4 {
        return 4;
    }
    if left >= 2 {
        return 2;
    }
    return 1;
}

// ---- Calls and control flow ----

extend Gen {
    // Before a call: every value in a caller-saved register that lives on or that the call reads goes to
    // its home, and those registers hold nothing after.
    fn spill_for_call(self: &mut Self) {
        let none = Vector::<u32>::new();
        self.clob = ~0u64;
        self.spill_around_call(&none);
        self.forget_caller_saved();
    }

    // Before a call: every value in a caller-saved register that lives past the call or that the call
    // reads is in its home, and only the values `keep` (the register arguments' sources) keep their
    // registers, until `forget_caller_saved`.
    fn spill_around_call(self: &mut Self, keep: &Vector<u32>) {
        let mut m = self.held & ~self.xfix & self.clob;
        // Each step clears one register's bit: at most 32 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            let xv = self.owner[r as usize];
            if self.va[xv as usize].home == H_FIXED {
                continue;
            }
            let mut kept = false;
            for k in 0..keep.len() {
                kept = kept || keep[k] == xv;
            }
            if self.live_on(xv) || self.read_now(xv) && !kept {
                self.spill(xv);
            }
            if !kept {
                self.va.index_mut(xv as usize).reg = NOREG;
                self.va.index_mut(xv as usize).dirty = false;
                self.set_owner(r, NONE);
            }
        }
        self.lock = 0;
        self.tmps = 0;
    }

    // After a call: the caller-saved registers hold no value.
    fn forget_caller_saved(self: &mut Self) {
        let mut m = self.held & ~self.xfix & self.clob;
        // Each step clears one register's bit: at most 32 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            let xv = self.owner[r as usize];
            if self.va[xv as usize].home == H_FIXED {
                continue;
            }
            self.va.index_mut(xv as usize).reg = NOREG;
            self.va.index_mut(xv as usize).dirty = false;
            self.set_owner(r, NONE);
        }
    }

    // The registers intrinsic call `t` writes when its instructions are `tx`: its arguments' and result's
    // (`ab::intrinsic_layout`) and those `tx` names.
    fn intrin_clob(self: &Self, t: Inst, tx: str) u64 {
        let gp: [u8; 8] = [x::RDI, x::RSI, x::RDX, x::RCX, x::R8, x::R9, x::R10, x::R11];
        let mut lay = ab::CallLayout::new();
        ab::intrinsic_layout(self.b(), t.b, self.ptr, gp[0..8], x::RAX, &mut lay);
        let mut m: u64 = 0;
        for q in 0..lay.parts.len() {
            let pa = lay.parts[q];
            m |= bit(
                pa.reg + if pa.v {
                    V0
                } else {
                    0
                },
            );
        }
        let mut j: usize = 0;
        while j < tx.len() {
            if tx.byte_at(j) != b'%' {
                j += 1;
                continue;
            }
            let st = j + 1;
            j = st;
            while j < tx.len() {
                let ch = tx.byte_at(j);
                if !(ch >= b'a' && ch <= b'z' || ch >= b'0' && ch <= b'9') {
                    break;
                }
                j += 1;
            }
            let r = x64_clobber(tx.slice(st, j));
            if r != NOREG {
                m |= bit(r);
            }
        }
        return m;
    }

    fn call_layout(self: &mut Self, t: Inst) {
        let b = self.b();
        if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
            let gp: [u8; 8] = [x::RDI, x::RSI, x::RDX, x::RCX, x::R8, x::R9, x::R10, x::R11];
            ab::intrinsic_layout(b, t.b, self.ptr, gp[0..8], x::RAX, &mut self.lay);
            return;
        }
        let q = self.lay_index(t);
        self.lay.copy_from(&self.lays[q]);
    }

    // The index in `lays` of the layout of call `t` (no intrinsic), `self.lay` unchanged: once per
    // signature and convention in the body, which give the layout.
    fn lay_index(self: &mut Self, t: Inst) usize {
        let b = self.b();
        let sc = t.op == O_CALL && self.sc_conv(b.syms[t.a as usize]);
        let key = t.b as u64 | sc as u64 << 32;
        for q in 0..self.lay_sig.len() {
            if self.lay_sig[q] == key {
                return q;
            }
        }
        let q = self.lay_sig.len();
        self.lay_sig.push(key);
        if q == self.lays.len() {
            self.lays.push(ab::CallLayout::new());
        }
        classify(self.win, sc, b, t.b, self.ptr, self.vregs, self.lays.index_mut(q));
        return q;
    }

    // Whether a call of package function symbol `s` takes Super-C's own convention (`w64::classify`'s
    // `sc`): under Microsoft x64, a function of the program no C code reaches by name (not an extern
    // binding, not `@export` or `@used`). C reaches the others through `w64::thunks`.
    const fn sc_conv(self: &Self, s: u32) bool {
        let y = unsafe (*self.pkg).syms[s as usize];
        return self.win && y.kind == SK_FUNC && !y.ext && !y.used;
    }

    // The instructions of the intrinsic body symbol `s` names (`target::intrin`, `itpl`); empty for another
    // function.
    const fn intrinsic(self: &Self, s: u32) str<'static> {
        return self.itpl[s as usize];
    }

    // Whether call `t`, instruction `i`, is a sibling call (`Package.tail`, `tail_ok`): its block returns
    // its result (or nothing) right after it, its result's code is the body's, it passes every argument in
    // registers and no aggregate but one in the registers it arrived in (`pass_parts`; else a copy in this
    // frame), its aggregate result, from a body that returns nothing, in memory outside this frame, and it
    // is no variadic call (System V's al),
    // no intrinsic and no call through the address slot (`-fno-plt`); then its return is not emitted
    // (`tail_ret`).
    fn sibling(self: &mut Self, i: u32, t: Inst) bool {
        if !self.sib_shape(i, t) {
            return false;
        }
        self.tail_ret = i + 1;
        return true;
    }

    // `sibling`'s test, without marking the return: the call's shape, then its layout (`call_layout`).
    fn sib_shape(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        if !self.tail_ok || i + 2 != bk.start + bk.len || (b.pool[t.b as usize + 1] & SIG_VARIADIC) != 0 {
            return false;
        }
        let r = b.insts[i as usize + 1];
        let rt = b.pool[t.b as usize + 2];
        // An aggregate result into memory its address operand names, from a body that returns nothing.
        let into = (rt & AGG) != 0 && b.pool[b.sig as usize + 2] == T_NONE as u32 && t.ty == T_NONE;
        if r.op != O_RET || !(r.a == i && t.ty != T_NONE || r.a == VNONE && t.ty == T_NONE) || (rt != b.pool[b.sig as usize + 2] || (rt & AGG) != 0) && !into {
            return false;
        }
        self.call_layout(t);
        if self.lay.ret.kind == ab::L_SRET != into {
            return false;
        }
        // That memory is not an aggregate parameter's that arrives in registers, which this frame holds.
        let v = if into {
            b.pool[(t.c + b.pool[t.b as usize]) as usize]
        } else {
            VNONE
        };
        let e0 = b.blocks[0].param_start;
        if into && (v & VPARAM) != 0 && (v & ~VPARAM) >= e0 && (v & ~VPARAM) - e0 < b.pool[b.sig as usize] {
            let p = (v & ~VPARAM) - e0;
            if (b.pool[(b.sig + 3 + p) as usize] & AGG) != 0 && self.self_lay.locs[p as usize].kind == ab::L_REG {
                return false;
            }
        }
        let p = unsafe &*self.pkg;
        if t.op == O_CALL && (self.intrinsic(t.a).len() != 0 || p.no_plt && !self.win && p.syms[b.syms[t.a as usize] as usize].ext) {
            return false;
        }
        for k in 0..b.pool[t.b as usize] {
            let a = b.pool[(t.c + k) as usize];
            let passed = self.va[self.vx(a) as usize].home == H_PASSED;
            // An aggregate passed by reference whose address is the caller's (an entry parameter but an
            // aggregate that arrives in registers, which this frame holds) outlives the frame.
            let q = if (a & VPARAM) != 0 && (a & ~VPARAM) >= e0 && (a & ~VPARAM) - e0 < b.pool[b.sig as usize] {
                (a & ~VPARAM) - e0
            } else {
                NONE
            };
            let theirs = q != NONE && !((b.pool[(b.sig + 3 + q) as usize] & AGG) != 0 && self.self_lay.locs[q as usize].kind == ab::L_REG);
            if self.lay.locs[k as usize].kind == ab::L_REF_REG && self.by_address(t.b, k) && theirs {
                continue;
            }
            if (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 && !passed || self.lay.locs[k as usize].kind != ab::L_REG {
                return false;
            }
        }
        // The epilogue's `vzeroupper` would clear a 32-byte argument's upper half.
        if self.ymm && ymm_parts(&self.lay) {
            return false;
        }
        return true;
    }

    fn call(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let sig = t.b;
        let np = b.pool[sig as usize];
        let rt = b.pool[sig as usize + 2];
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a)
        } else {
            ""
        };
        self.call_layout(t);
        self.clob = ~0u64;
        // An intrinsic's instructions, its constant arguments in place.
        let mut text = String::new();
        if tpl.len() != 0 {
            let mut imm = Vector::<i64>::with_capacity(np as usize);
            let mut known = Vector::<bool>::with_capacity(np as usize);
            for k in 0..np {
                let mut u: u64 = 0;
                known.push(self.const_of(b.pool[(t.c + k) as usize], &mut u));
                imm.push(u as i64);
            }
            if !intrin::expand(tpl, imm[0..imm.len()], known[0..known.len()], &mut text) {
                return self.refuse("an intrinsic's immediate argument of no constant value");
            }
        }
        let tx = text.as_str();
        if tpl.len() != 0 {
            // An intrinsic writes the registers it names and its arguments' and result's: the others
            // keep their values.
            self.clob = self.intrin_clob(t, tx);
        }
        // A vector argument a register holds whole stays there: the template reads it under that
        // register's name in place of its argument register (`ren`), which it must not write and no part
        // or other name may be. A written one is renamed only when it is the result's and the argument
        // dies here: the result is then in the argument's register (`rres`).
        let mut ren = Vector::<bool>::with_capacity(np as usize);
        let mut from = Vector::<u32>::new();
        let mut to = Vector::<u32>::new();
        let mut rres = NOREG;
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let x = self.vx(v);
            let vr = self.va[x as usize].reg;
            // Free of the template, or already in its own argument register.
            let mut ok = tpl.len() != 0 && self.lay.whole_vreg(loc, self.vt(v)) && vr != NOREG && vr >= V0;
            ok = ok && ((self.clob & bit(vr)) == 0 || vr == V0 + self.lay.parts[loc.p0 as usize].reg);
            for j in 0..to.len() {
                ok = ok && to[j] != (vr - V0) as u32;
            }
            let pr = if ok {
                self.lay.parts[loc.p0 as usize].reg as u32
            } else {
                0u32
            };
            if ok && intrin::vwrites(false, tx, pr) {
                let rl = self.lay.ret;
                ok = rres == NOREG && self.lay.whole_vreg(rl, t.ty);
                ok = ok && self.lay.parts[rl.p0 as usize].reg as u32 == pr && self.dies(x);
                if ok {
                    rres = vr;
                }
            }
            ren.push(ok);
            if ok {
                from.push(pr);
                to.push(vr - V0);
                self.clob &= ~bit(V0 + pr as u8);
            }
        }
        // A result that lives on gets a register no later template names, when none is renamed yet: the
        // template's result register takes its name, and an argument there moves to it instead.
        let mut rmov = NONE;
        let rl = self.lay.ret;
        if tpl.len() != 0 && rres == NOREG && self.lay.whole_vreg(rl, t.ty) && self.live_on(self.vx(i)) {
            let mut taken = self.clob | self.lock | self.tmps;
            for j in 0..to.len() {
                taken |= bit(V0 + to[j] as u8);
            }
            // A register no value holds: a scratch home may live across the template.
            let free = self.valloc & ~taken & ~self.held;
            if free != 0 {
                let f = free.trailing_zeros() as u8;
                let pr = self.lay.parts[rl.p0 as usize].reg as u32;
                rmov = pr;
                rres = f;
                from.push(pr);
                to.push(f - V0);
                self.clob &= ~bit(V0 + pr as u8);
                self.clob |= bit(f);
            }
        }
        if from.len() != 0 {
            let mut renamed = String::new();
            intrin::vrename(false, tx, from[0..from.len()], to[0..to.len()], &mut renamed);
            text = renamed;
            if rres != NOREG {
                self.clob |= bit(rres);
            }
        }
        // The scalar register arguments in registers stay there: one parallel move takes them to the
        // argument registers.
        // A value the call also reads otherwise (an aggregate's address, the callee, the result's address)
        // is read from its home after the move, which may take its register.
        let mut other = Vector::<u32>::new();
        let nops = np + ((rt & AGG) != 0) as u32;
        for k in 0..nops {
            let v = b.pool[(t.c + k) as usize];
            let ref_agg = k < np && self.lay.locs[k as usize].kind == ab::L_REF_REG && self.by_address(sig, k);
            if !ref_agg && (k == np || self.lay.locs[k as usize].kind != ab::L_REG || (b.pool[(sig + 3 + k) as usize] & AGG) != 0) {
                other.push(self.vx(v));
            }
        }
        if t.op == O_CALLIND {
            other.push(self.vx(t.a));
        }
        // The values read after the move: a memory value passed by reference, the callee, the result's
        // address. (An aggregate's address passed by reference moves with the scalars.)
        let mut late = Vector::<u32>::new();
        for k in 0..nops {
            if k == np || self.lay.locs[k as usize].kind == ab::L_REF_REG && !self.by_address(sig, k) {
                late.push(self.vx(b.pool[(t.c + k) as usize]));
            }
        }
        if t.op == O_CALLIND {
            late.push(self.vx(t.a));
        }
        let mut keep = Vector::<u32>::new();
        // The result's address that a register holds and no other operand is moves with the scalars.
        let mut resmv = false;
        if tpl.len() == 0 && nops > np && self.lay.ret.kind == ab::L_SRET {
            let x = self.vx(b.pool[(t.c + np) as usize]);
            let mut n = (t.op == O_CALLIND && self.vx(t.a) == x) as u32;
            for q in 0..nops {
                n += (self.vx(b.pool[(t.c + q) as usize]) == x) as u32;
            }
            resmv = n == 1 && self.va[x as usize].reg != NOREG;
            if resmv {
                keep.push(x);
            }
        }
        for k in 0..np {
            let v = b.pool[(t.c + k) as usize];
            let x = self.vx(v);
            let mut shared = false;
            for q in 0..other.len() {
                shared = shared || other[q] == x;
            }
            let vty = self.vt(v);
            let loc = self.lay.locs[k as usize];
            // A stack argument reads its register before the move, which may write it (so not when the call
            // reads the value after the move too).
            let mut after = false;
            for q in 0..late.len() {
                after = after || late[q] == x;
            }
            if tpl.len() == 0 && (b.pool[(sig + 3 + k) as usize] & AGG) != 0 && self.parts_moved(v, loc, &late) || loc.kind == ab::L_STACK && !after && self.va[x as usize].reg != NOREG {
                keep.push(x);
                continue;
            }
            let ref_agg = loc.kind == ab::L_REF_REG && self.by_address(sig, k);
            if !shared && (ref_agg || loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!in_mem(
                vty,
            ) || self.lay.whole_vreg(loc, vty))) && self.va[x as usize].reg != NOREG {
                keep.push(x);
            }
        }
        // The values of the stores this call takes in place of its aggregates' memory (`arg_relays`).
        for q in 0..self.lv.relayed.len() {
            if (self.lv.relayed[q] >> 32) as u32 == i {
                let x = self.vx(b.insts[(self.lv.relayed[q] & 0xFFFFFFFF) as usize].b);
                if self.va[x as usize].reg != NOREG {
                    keep.push(x);
                }
            }
        }
        self.spill_around_call(&keep);
        let mut rvals = Vector::<u64>::new();
        // The registers the template reads in place of its argument registers hold no temporary.
        for j in 0..to.len() {
            self.lock |= bit(V0 + to[j] as u8);
        }
        // An intrinsic's arguments in rdi and rsi, which Microsoft x64 saves: the values there go to
        // slots of their own around it. The scratch registers r10 and r11 take arguments of integer
        // intrinsics only: no argument's materializing needs them.
        let mut saved = Vector::<(u8, i64)>::new();
        if tpl.len() != 0 {
            let na = if self.lay.ret.kind == ab::L_REG {
                self.lay.ret.p0 as usize
            } else {
                self.lay.parts.len()
            };
            let mut args: u64 = 0;
            let mut vec = false;
            for q in 0..na {
                let pa = self.lay.parts[q];
                if pa.v {
                    vec = true;
                } else {
                    args |= bit(pa.reg);
                }
            }
            assert(
                !vec || (args & (bit(S0) | bit(S1))) == 0,
                "x64: an intrinsic with arguments in r10 or r11 takes integers alone",
            );
            let keep_cs = args & (bit(x::RDI) | bit(x::RSI)) & self.xfix;
            self.csr |= keep_cs;
            let mut m = keep_cs & self.held;
            // Each step clears one register's bit: at most 2 steps.
            while m != 0 {
                let cr = m.trailing_zeros() as u8;
                m &= m - 1;
                let off = self.slot_alloc(16, 16) as i64;
                self.save_reg(cr, off, true);
                saved.push((cr, off));
            }
        }
        // Stack arguments first, through the scratch registers.
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            if loc.kind == ab::L_REF_STACK {
                if self.by_address(sig, k) {
                    // An aggregate's address as it is (`L_REF_REG`'s rule).
                    self.materialize(b.pool[(t.c + k) as usize], S0);
                } else {
                    let at = self.ref_copy(b.pool[(t.c + k) as usize], b.pool[(sig + 3 + k) as usize]);
                    self.c.lea(S0, x::at(x::RSP, at));
                }
                self.c.store(8, S0, x::at(x::RSP, loc.off as i32));
                continue;
            }
            if loc.kind != ab::L_STACK {
                continue;
            }
            let v = b.pool[(t.c + k) as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            let vty = self.vt(v);
            if (pt & AGG) != 0 {
                // From the address's register when one holds it.
                let rv = self.va[self.vx(v) as usize].reg;
                if rv == NOREG {
                    self.materialize(v, S1);
                }
                self.copy_mem(x::RSP, loc.off, ast_pick(rv == NOREG, S1, rv), 0, loc.size);
            } else if in_mem(vty) {
                let (base, off) = self.mloc(v);
                self.copy_mem(x::RSP, loc.off, base, off, loc.size);
            } else {
                // A constant a 32-bit immediate holds goes into memory as it is, a value in a register from
                // there.
                let mut k: i32 = 0;
                let rv = self.va[self.vx(v) as usize].reg;
                if rv != NOREG {
                    self.st(vty, rv, x::at(x::RSP, loc.off as i32));
                } else if !is_v(vty) && self.imm32_of(v, type_bits(vty, self.ptr), &mut k) {
                    self.c.mov_mi(type_bytes(vty, self.ptr), x::at(x::RSP, loc.off as i32), k);
                } else {
                    let r = if is_v(vty) {
                        self.vs0
                    } else {
                        S0
                    };
                    self.materialize(v, r);
                    self.st(vty, r, x::at(x::RSP, loc.off as i32));
                }
            }
        }
        // The scalars from registers and homes as one parallel move; a narrow one then extends in place. An
        // aggregate whose stores relay (`arg_relays`) takes their values.
        self.mv.truncate(0);
        let mut relayed = Vector::<bool>::with_capacity(np as usize);
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let vty = self.vt(v);
            let va = self.va[self.vx(v) as usize];
            if va.home == H_PASSED {
                // Each part from the register it arrived in (`pass_parts`), whole.
                let pl = self.self_lay.locs[va.off as usize];
                for q in 0..loc.n as u32 {
                    let pa = self.lay.parts[(loc.p0 + q) as usize];
                    self.mv.push(
                        Mv {
                            src: Lc { kind: LC_REG, reg: self.pin_reg[(pl.p0 + q) as usize], off: 0, val: NONE },
                            dst: Lc { kind: LC_REG, reg: pa.reg + ast_pick(pa.v, V0, 0), off: 0, val: NONE },
                            v: pa.v,
                            bytes: if pa.v && pa.size > 8 {
                                16
                            } else {
                                8
                            },
                            done: false,
                        },
                    );
                }
                relayed.push(true);
                continue;
            }
            relayed.push(
                loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) != 0 && relay_parts(
                    self,
                    i,
                    v,
                    loc,
                    &mut rvals,
                ),
            );
            if tpl.len() == 0 && !relayed[k as usize] && (b.pool[(sig + 3 + k) as usize] & AGG) != 0 && self.parts_moved(
                v,
                loc,
                &late,
            ) {
                // Each part loads through the address's register in the parallel move.
                let ar = self.va[self.vx(v) as usize].reg;
                for q in 0..loc.n as u32 {
                    let pa = self.lay.parts[(loc.p0 + q) as usize];
                    self.mv.push(
                        Mv {
                            src: Lc { kind: LC_MEM, reg: ar, off: pa.off as i32, val: NONE },
                            dst: Lc {
                                kind: LC_REG,
                                reg: if pa.v {
                                    pa.reg + V0
                                } else {
                                    pa.reg
                                },
                                off: 0,
                                val: NONE,
                            },
                            v: pa.v,
                            bytes: pa.size,
                            done: false,
                        },
                    );
                }
                relayed[k as usize] = true;
                continue;
            }
            if loc.kind == ab::L_REF_REG && self.by_address(sig, k) {
                // An aggregate's address passed by reference: a scalar of the move, but a frame address,
                // which the argument loop makes.
                let src = self.loc_of(self.vx(v));
                if src.kind != LC_VAL {
                    let pa = self.lay.parts[loc.p0 as usize];
                    self.mv.push(
                        Mv {
                            src: src,
                            dst: Lc { kind: LC_REG, reg: pa.reg, off: 0, val: NONE },
                            v: false,
                            bytes: 8,
                            done: false,
                        },
                    );
                    relayed[k as usize] = true;
                }
                continue;
            }
            if loc.kind != ab::L_REG || (b.pool[(sig + 3 + k) as usize] & AGG) != 0 || in_mem(vty) && !self.lay.whole_vreg(
                loc,
                vty,
            ) || ren[k as usize] {
                continue;
            }
            let src = self.loc_of(self.vx(v));
            if src.kind == LC_VAL {
                continue;
            }
            let pa = self.lay.parts[loc.p0 as usize];
            let r = if pa.v && pa.reg as u32 == rmov {
                rres
            } else if pa.v {
                pa.reg + V0
            } else {
                pa.reg
            };
            self.mv.push(
                Mv {
                    src: src,
                    dst: Lc { kind: LC_REG, reg: r, off: 0, val: NONE },
                    v: pa.v,
                    bytes: type_bytes(vty, self.ptr),
                    done: false,
                },
            );
        }
        if resmv {
            let src = self.loc_of(self.vx(b.pool[(t.c + np) as usize]));
            self.mv.push(
                Mv {
                    src: src,
                    dst: Lc { kind: LC_REG, reg: self.arg(0), off: 0, val: NONE },
                    v: false,
                    bytes: 8,
                    done: false,
                },
            );
        }
        // Per argument: whether the move took it, and whether its register then holds it zero-extended.
        let mut moved = Vector::<bool>::with_capacity(np as usize);
        let mut clean = Vector::<bool>::with_capacity(np as usize);
        for k in 0..np {
            let v = b.pool[(t.c + k) as usize];
            let x = self.vx(v);
            let va = self.va[x as usize];
            let vty = self.vt(v);
            let loc = self.lay.locs[k as usize];
            // A renamed argument is read where it is.
            moved.push(
                loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!in_mem(vty) || self.lay.whole_vreg(
                    loc,
                    vty,
                )) && self.loc_of(x).kind != LC_VAL || ren[k as usize] || relayed[k as usize],
            );
            clean.push(va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG));
        }
        resolve_moves(self);
        // The moved values' registers now hold arguments; the parts passed on are in theirs.
        self.forget_caller_saved();
        self.fixed_busy &= ~self.pin;
        self.pin = 0;
        // The relayed aggregate parts' constants and addresses (`relay_parts`).
        for q in 0..rvals.len() {
            self.materialize(rvals[q] as u32, (rvals[q] >> 32) as u8);
        }
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            if relayed[k as usize] {
                continue;
            }
            if loc.kind == ab::L_REF_REG && self.by_address(sig, k) {
                // An aggregate's address passes as it is: the LIR copies a by-value argument that the callee
                // may write (as `a64gen::ref_arg`).
                self.materialize(b.pool[(t.c + k) as usize], self.lay.parts[loc.p0 as usize].reg);
                continue;
            }
            if loc.kind == ab::L_REF_REG {
                let at = self.ref_copy(b.pool[(t.c + k) as usize], b.pool[(sig + 3 + k) as usize]);
                self.c.lea(self.lay.parts[loc.p0 as usize].reg, x::at(x::RSP, at));
                continue;
            }
            if loc.kind != ab::L_REG {
                continue;
            }
            let v = b.pool[(t.c + k) as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            let vty = self.vt(v);
            if (pt & AGG) == 0 && loc.n == 2 && !self.lay.parts[loc.p0 as usize + 1].v && self.lay.parts[loc.p0 as usize].v {
                // A variadic float (Microsoft x64): its vector register, then its bits in the integer one. (An
                // aggregate's float and integer halves under System V are two parts too.)
                let pv = self.lay.parts[loc.p0 as usize];
                if !moved[k as usize] {
                    self.materialize(v, V0 + pv.reg);
                }
                self.c.movd_from_x(8, self.lay.parts[loc.p0 as usize + 1].reg, pv.reg);
                continue;
            }
            if moved[k as usize] {
                // Moved: only a narrow integer's extension is left.
                let pa = self.lay.parts[loc.p0 as usize];
                if loc.ext == 2 {
                    self.c.ext(type_bits(vty, self.ptr) / 8, 4, true, pa.reg, pa.reg);
                } else if loc.ext != 0 && !clean[k as usize] {
                    self.c.ext(type_bits(vty, self.ptr) / 8, 4, false, pa.reg, pa.reg);
                }
                continue;
            }
            if (pt & AGG) != 0 {
                // A frame address loads its parts through the frame's register.
                let (fr, base, off) = self.frame_addr(v);
                if !fr {
                    self.materialize(v, S1);
                }
                for q in 0..loc.n as u32 {
                    let pa = self.lay.parts[(loc.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else if in_mem(vty) {
                let (base, off) = self.mloc(v);
                for q in 0..loc.n as u32 {
                    let mut pa = self.lay.parts[(loc.p0 + q) as usize];
                    // The template's result register renamed (`rmov`): its argument goes to the new name.
                    if pa.v && pa.reg as u32 == rmov {
                        pa.reg = rres - V0;
                    }
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else {
                let pa = self.lay.parts[loc.p0 as usize];
                let r = if pa.v && pa.reg as u32 == rmov {
                    rres
                } else if pa.v {
                    pa.reg + V0
                } else {
                    pa.reg
                };
                if loc.ext != 0 {
                    self.materialize_ext(v, r, loc.ext == 2, type_bits(vty, self.ptr));
                } else {
                    self.materialize(v, r);
                }
            }
        }
        if self.lay.ret.kind == ab::L_SRET && !resmv {
            if (rt & AGG) != 0 {
                self.materialize(b.pool[(t.c + np) as usize], self.arg(0));
            } else {
                let d = self.mdef(i);
                self.c.lea(self.arg(0), x::at(x::RSP, d as i32));
            }
        }
        if t.op == O_CALLIND {
            self.materialize(t.a, S1);
        }
        if (b.pool[sig as usize + 1] & SIG_VARIADIC) != 0 && !self.win {
            // al: an upper bound of the vector registers the arguments take.
            self.c.mov_ri(x::RAX, self.lay.vr_used);
        }
        if tpl.len() != 0 {
            // An intrinsic: its instructions in place of the call, over the same registers.
            let mut rels = Vector::<asmr::InlRel>::new();
            let mut e = String::new();
            if !asmr::Asm::inline_x64(&text, &mut self.c.b, &mut rels, &mut e) {
                self.err.format_into("intrinsic: {}", e.as_str());
                return false;
            }
            assert(rels.len() == 0, "x64: an intrinsic's instructions name no symbol");
            for k in 0..saved.len() {
                let (cr, off) = saved[k];
                self.save_reg(cr, off, false);
                self.free_slots.push(16u64 << 32 | (off as u32) as u64);
            }
        } else if (t.op == O_CALL || !self.win) && self.sibling(i, t) {
            // Through a copy of the epilogue (`finish`): a jump to the callee, or to the address in r11.
            let at = self.c.jmp32();
            let os = if t.op == O_CALL {
                self.osym_of(t.a)
            } else {
                NONE
            };
            self.tails.push(at as u64 << 32 | os as u64);
            return true;
        } else if t.op == O_CALL {
            let os = self.osym_of(t.a);
            let p = unsafe &*self.pkg;
            if p.no_plt && !self.win && p.syms[b.syms[t.a as usize] as usize].ext {
                // `call *x@GOTPCREL(%rip)`: through the address slot (`-fno-plt`).
                self.call_clear();
                self.c.rm(0, 0xFF, false, 2, x::rip(), false);
                self.reloc_rip(x::R_GOTPCRELX, os, 0);
            } else {
                self.call_clear();
                let at = self.c.call32();
                self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: os, addend: -4 });
            }
        } else {
            self.call_clear();
            self.c.call_r(S1);
        }
        // An intrinsic's instructions call nothing: the frame stays a leaf's.
        self.called = self.called || tpl.len() == 0;
        if rl.kind != ab::L_REG {
            return true;
        }
        if (rt & AGG) != 0 && self.rload[i as usize] != 0 {
            self.relay_result(i);
            return true;
        }
        if (rt & AGG) != 0 {
            self.materialize(b.pool[(t.c + np) as usize], S1);
            for q in 0..rl.n as u32 {
                let pa = self.lay.parts[(rl.p0 + q) as usize];
                self.store_part(pa, S1, pa.off);
            }
            return true;
        }
        if self.lay.whole_vreg(rl, t.ty) {
            self.result_in(
                i,
                if rres != NOREG {
                    rres
                } else {
                    self.lay.parts[rl.p0 as usize].reg + V0
                },
            );
            return true;
        }
        if in_mem(t.ty) {
            let d = self.mdef(i);
            for q in 0..rl.n as u32 {
                let pa = self.lay.parts[(rl.p0 + q) as usize];
                self.store_part(pa, x::RSP, d + pa.off as i64);
            }
            return true;
        }
        let pa = self.lay.parts[rl.p0 as usize];
        self.result_in(
            i,
            pa.reg + if pa.v {
                V0
            } else {
                0
            },
        );
        return true;
    }

    // Whether value index `x` has its last use in the current instruction.
    const fn dies(self: &Self, x: u32) bool {
        for k in 0..self.dying.len() {
            if self.dying[k] == x {
                return true;
            }
        }
        return false;
    }

    // A copy of argument `v` of signature type `pt` (an aggregate's address, or a memory value) that a
    // by-reference argument points to: its slot's offset from rsp. Through r11 and the copy's scratch
    // registers.
    fn ref_copy(self: &mut Self, v: Value, pt: u32) i32 {
        let mut sz = type_bytes(self.vt(v), self.ptr);
        let mut base = S1;
        let mut off: i64 = 0;
        if (pt & AGG) != 0 {
            // A frame address in place, any other through r11: once the argument registers hold
            // arguments, no register may be allocated.
            let va = self.va[self.vx(v) as usize];
            sz = self.b().pool[(pt & ~AGG) as usize];
            if va.home == H_SPADDR || va.home == H_FPADDR {
                base = ast_pick(va.home == H_SPADDR, x::RSP, self.fb);
                off = va.off;
            } else if va.home == H_REMAT && va.reg == NOREG && self.b().insts[v as usize].op == O_SLOTADDR {
                base = x::RSP;
                off = self.slot_off[self.b().insts[v as usize].a as usize];
            } else {
                self.materialize(v, S1);
            }
        } else {
            let (b0, o0) = self.mloc(v);
            base = b0;
            off = o0;
        }
        let at = self.slot_alloc(sz, 16);
        self.copy_mem(x::RSP, at, base, off, sz);
        return at as i32;
    }

    // Whether argument `k` of a call of signature `sig` passes as an aggregate's address as it is: one
    // larger than the backend copies (`Package.arg_copy`), which the LIR copies when the callee may write
    // it, and Microsoft x64 passes by reference.
    const fn by_address(self: &Self, sig: u32, k: u32) bool {
        let b = self.b();
        let pt = b.pool[(sig + 3 + k) as usize];
        let kd = self.lay.locs[k as usize].kind;
        return (pt & AGG) != 0 && (kd == ab::L_REF_REG || kd == ab::L_REF_STACK) && b.pool[(pt & ~AGG) as usize] > unsafe (*self.pkg).arg_copy;
    }

    // A call of C function `name` with the integer or pointer values `vs` in the argument registers and
    // no result.
    fn rt_call(self: &mut Self, name: str, vs: []Value) {
        self.rt_args(vs);
        self.call_sym(name);
    }

    // The arguments `vs` of a call of a C routine in its argument registers (`rt_call`): the operands in
    // registers stay there for the parallel move, as a call's arguments do; one that lives on is in its
    // home too.
    fn rt_args(self: &mut Self, vs: []Value) {
        let mut keep = Vector::<u32>::with_capacity(vs.len());
        let mut rs = Vector::<u8>::with_capacity(vs.len());
        for k in 0..vs.len() {
            let x = self.vx(vs[k]);
            if self.va[x as usize].reg != NOREG {
                keep.push(x);
            }
            rs.push(self.arg(k as u32));
        }
        self.clob = ~0u64;
        self.spill_around_call(&keep);
        self.args_to(vs, rs[0..rs.len()]);
        // A narrow integer (a 32-bit size, a fill byte) extends to the register's width, as C reads it.
        for k in 0..vs.len() {
            let n = type_bytes(self.vt(vs[k]), self.ptr);
            if n < 8 {
                self.c.ext(n, 8, false, rs[k], rs[k]);
            }
        }
        self.forget_caller_saved();
    }

    // Values `vs` into registers `rs`: the ones in a register or a home as one parallel move (a scratch
    // home is an argument register another value may go to), then the others.
    fn args_to(self: &mut Self, vs: []Value, rs: []u8) {
        self.mv.truncate(0);
        for k in 0..vs.len() {
            let src = self.loc_of(self.vx(vs[k]));
            if src.kind != LC_VAL {
                self.mv.push(
                    Mv {
                        src: src,
                        dst: Lc { kind: LC_REG, reg: rs[k], off: 0, val: NONE },
                        v: rs[k] >= V0,
                        bytes: type_bytes(self.vt(vs[k]), self.ptr),
                        done: false,
                    },
                );
            }
        }
        resolve_moves(self);
        for k in 0..vs.len() {
            if self.loc_of(self.vx(vs[k])).kind == LC_VAL {
                self.materialize(vs[k], rs[k]);
            }
        }
    }

    // A call of compiler-rt routine `name` for instruction `i`: the i128 or float values `xa` and `ya`
    // (VNONE: none) in the integer argument registers or xmm0; an i128 result from rax and rdx into its
    // slot, a float one from xmm0.
    fn rt_call128(self: &mut Self, i: u32, name: str, xa: Value, ya: Value) bool {
        self.spill_for_call();
        if self.win {
            return self.rt_call128_win(i, name, xa, ya);
        }
        // The registers first (`args_to`), then the i128 halves from memory: a scalar's home may be an
        // argument register a half goes to.
        let mut gr: usize = 0;
        let mut vs = Vector::<Value>::with_capacity(2);
        let mut rs = Vector::<u8>::with_capacity(2);
        for k in 0..2 {
            let v = if k == 0 {
                xa
            } else {
                ya
            };
            if v == VNONE {
                continue;
            }
            let ty = self.vt(v);
            if ty == T_I128 {
                gr += 2;
            } else {
                vs.push(v);
                rs.push(
                    if is_v(ty) {
                        V0
                    } else {
                        cc::gp_arg(gr as u32)
                    },
                );
                gr += (!is_v(ty)) as usize;
            }
        }
        self.args_to(vs[0..vs.len()], rs[0..rs.len()]);
        gr = 0;
        for k in 0..2 {
            let v = if k == 0 {
                xa
            } else {
                ya
            };
            if v == VNONE {
                continue;
            }
            let ty = self.vt(v);
            if ty == T_I128 {
                let (base, off) = self.mloc(v);
                self.c.load(8, false, cc::gp_arg(gr as u32), x::at(base, off as i32));
                self.c.load(8, false, cc::gp_arg(gr as u32 + 1), x::at(base, off as i32 + 8));
                gr += 2;
            } else if !is_v(ty) {
                gr += 1;
            }
        }
        self.call_sym(name);
        let ty = self.b().insts[i as usize].ty;
        if ty == T_I128 {
            let d = self.mdef(i) as i32;
            self.c.store(8, x::RAX, x::at(x::RSP, d));
            self.c.store(8, x::RDX, x::at(x::RSP, d + 8));
        } else {
            self.result_in(
                i,
                if is_v(ty) {
                    V0
                } else {
                    x::RAX
                },
            );
        }
        return true;
    }

    // `rt_call128` under Microsoft x64: an i128 passes as a pointer to a copy; a float takes the vector
    // register of its position, any other value the integer one. An i128 result comes back through a
    // pointer in the first position, from the runtime's `__sc_<name>` (`std::rt::builtins`): compiler-rt's
    // own returns it in xmm0, which no Super-C function can.
    fn rt_call128_win(self: &mut Self, i: u32, name: str, xa: Value, ya: Value) bool {
        let wide = self.b().insts[i as usize].ty == T_I128;
        let mut k: u32 = if wide {
            1
        } else {
            0
        };
        for q in 0..2 {
            let v = if q == 0 {
                xa
            } else {
                ya
            };
            if v == VNONE {
                continue;
            }
            let ty = self.vt(v);
            if ty == T_I128 {
                let (base, off) = self.mloc(v);
                let at = self.slot_alloc(16, 16);
                self.copy_mem(x::RSP, at, base, off, 16);
                self.c.lea(w64::gp_arg(k), x::at(x::RSP, at as i32));
            } else if is_v(ty) {
                self.materialize(v, V0 + k as u8);
            } else {
                self.materialize(v, w64::gp_arg(k));
            }
            k += 1;
        }
        let ty = self.b().insts[i as usize].ty;
        if wide {
            let d = self.mdef(i) as i32;
            self.c.lea(w64::gp_arg(0), x::at(x::RSP, d));
            self.call_sym(format("__sc_{}", name.slice(2, name.len())).as_str());
        } else {
            self.call_sym(name);
            self.result_in(
                i,
                if is_v(ty) {
                    V0
                } else {
                    x::RAX
                },
            );
        }
        return true;
    }

    // The condition of a branch on boolean `v` (index `cx`): the flags an instruction left for it, else
    // its low byte tested.
    fn cond_test(self: &mut Self, cx: u32, v: Value) u32 {
        let fc = self.folded_cmp(v);
        if fc != NONE {
            return fc;
        }
        if self.pend.inst == cx && self.pend.inst != NONE {
            return self.pend.cc;
        }
        let r = self.reg(v);
        self.c.test_rr(1, r, r);
        self.keep_flags = true;
        return x::CC_NE;
    }

    // A conditional jump on condition `cc` to block `k`.
    fn cbranch(self: &mut Self, cc: u32, k: u32) {
        let at = self.c.jcc32(cc);
        self.fix.push(at as u64 << 32 | k as u64);
    }

    // Whether block `k` follows the current one.
    const fn next_is(self: &Self, k: u32) bool {
        let q = self.pos as usize + 1;
        return q < self.lv.order.len() && self.lv.order[q] == k && !self.crosses(k);
    }

    // Jump to block `k` (nothing when it follows, unless `force`).
    fn goto(self: &mut Self, k: u32, force: bool) {
        let q = self.pos as usize + 1;
        if !force && q < self.lv.order.len() && self.lv.order[q] == k && !self.crosses(k) {
            return;
        }
        let at = self.c.jmp32();
        self.fix.push(at as u64 << 32 | k as u64);
    }

    // S0 = switch value `r` (`sz` bytes) minus `min`, wrapped at its width (when the `span` entries from `min`
    // pass it) and zero-extended.
    fn switch_index(self: &mut Self, r: u8, sz: u32, min: u64, span: u32) {
        if sz == 8 {
            self.c.mov_rr(8, S0, r);
            let s = min as i64;
            if s >= -2147483648 && s <= 2147483647 {
                if s != 0 {
                    self.c.alu_ri(x::SUB, 8, S0, s as i32);
                }
            } else {
                self.c.mov_ri(S1, min);
                self.c.alu_rr(x::SUB, 8, S0, S1);
            }
            return;
        }
        self.c.ext(sz, 4, false, S0, r);
        if min != 0 {
            self.c.alu_ri(x::SUB, 4, S0, (min as u32) as i32);
            if sz < 4 && min + span as u64 > 1u64 << 8 * sz as u64 {
                self.c.alu_ri(x::AND, 4, S0, ((1u32 << 8 * sz) - 1) as i32);
            }
        }
    }

    // A branch on condition `cc` to the default edge `d` of a switch: to its block, or to its moves past
    // the switch (`stubs`, the displacements to land) when it has some.
    fn to_default(self: &mut Self, cc: u32, d: u32, stubs: &mut Vector<u32>) {
        if self.moves_needed(d) {
            stubs.push(self.c.jcc32(cc));
        } else {
            self.cbranch(cc, self.b().edge_target(d));
        }
    }

    // A switch whose cases all pass constants to one block (`sws::switch_lookup`): the bound and hole tests
    // to the default, then each parameter from its column of a read-only table (memory homes first: a
    // narrow one goes through S0, which the value then gives again). Whether it did.
    fn lookup(self: &mut Self, t: Inst, r: u8, sz: u32) bool {
        let b = self.b();
        let mut lk = sws::Lookup::new();
        if !sws::switch_lookup(b, t, 8 * sz, self.ptr, false, &mut lk) {
            return false;
        }
        let d = b.switch_edge(t, t.aux);
        let to = b.edge_target(b.switch_edge(t, 0));
        self.switch_index(r, sz, lk.min, lk.span);
        let mut stubs = Vector::<u32>::new();
        self.c.alu_ri(
            x::CMP,
            if sz == 8 {
                8
            } else {
                4
            },
            S0,
            (lk.span - 1) as i32,
        );
        self.to_default(x::CC_A, d, &mut stubs);
        if lk.holes != 0 {
            // bt S1, S0 (0F A3): a hole's bit sets the carry.
            self.c.mov_ri(S1, lk.holes);
            self.c.rr(0, 0x0FA3, true, S0, S1, false);
            self.to_default(x::CC_B, d, &mut stubs);
        }
        let k = self.table_sym(&lk);
        self.c.lea(S1, x::rip());
        self.reloc_rip(x::R_PC32, k, 0);
        let tb = b.blocks[to as usize];
        let ni = b.insts.len() as u32;
        for pass in 0..2u32 {
            for q in 0..tb.param_len as u32 {
                let px = ni + tb.param_start + q;
                self.param_home(px, NOREG);
                let ty = self.xty(px);
                let e = type_bytes(ty, self.ptr);
                let m = x::ix(S1, S0, e.trailing_zeros() as u8, lk.off[q as usize] as i32);
                let pva = self.va[px as usize];
                if pva.home == H_FIXED {
                    if pass == 1 {
                        self.ld(ty, pva.reg, m);
                    }
                } else if pass == 0 {
                    let dst = x::at(x::RSP, pva.off);
                    if e >= 4 {
                        self.ld(ty, self.vs0, m);
                        self.st(ty, self.vs0, dst);
                    } else {
                        self.ld(ty, S0, m);
                        self.st(ty, S0, dst);
                        self.switch_index(r, sz, lk.min, lk.span);
                        self.c.lea(S1, x::rip());
                        self.reloc_rip(x::R_PC32, k, 0);
                    }
                }
            }
        }
        self.goto(to, stubs.len() != 0);
        if stubs.len() != 0 {
            for q in 0..stubs.len() {
                self.c.land(stubs[q], self.c.len());
            }
            self.edge_moves(d);
            self.goto(b.edge_target(d), false);
        }
        return true;
    }

    // A dense switch (`sws::switch_span`) of at least TABLE_MIN cases that go elsewhere than the default: the
    // bound test to the default, then a jump through a table of jumps, one per entry, each 8 bytes (`jmp
    // rel32`, kept long, then `int3`s): to its case's block, or its moves past the table; an entry no case
    // takes to the default's. Whether it did.
    fn jump_table(self: &mut Self, t: Inst, r: u8, sz: u32) bool {
        let b = self.b();
        let n = t.aux as u32;
        let d = b.switch_edge(t, n);
        let mut own: u32 = 0;
        for k in 0..n {
            let e = b.switch_edge(t, k);
            if b.edge_nargs(e) != 0 || b.edge_target(e) != b.edge_target(d) || b.edge_nargs(d) != 0 {
                own += 1;
            }
        }
        let mut min: u64 = 0;
        let mut span: u32 = 0;
        if own < sws::TABLE_MIN || !sws::switch_span(b, t, 8 * sz, &mut min, &mut span) {
            return false;
        }
        // A table that holds every value the switched one takes needs no bound test.
        let cover = sws::covering_span(b, t, 8 * sz, 8, min, span);
        if cover != 0 {
            span = cover;
        }
        let m = if sz == 8 {
            ~0u64
        } else {
            (1u64 << 8 * sz as u64) - 1
        };
        // The edge of each entry.
        let mut es = Vector::<u32>::with_capacity(span as usize);
        for _ in 0..span {
            es.push(d);
        }
        for k in 0..n {
            es[(b.words[(t.b + k) as usize].wrapping_sub(min) & m) as usize] = b.switch_edge(t, k);
        }
        self.switch_index(r, sz, min, span);
        // Per edge with moves (the default first), the jumps to land at them.
        let mut ds = Vector::<u32>::new();
        if cover == 0 {
            self.c.alu_ri(
                x::CMP,
                if sz == 8 {
                    8
                } else {
                    4
                },
                S0,
                (span - 1) as i32,
            );
            self.to_default(x::CC_A, d, &mut ds);
        }
        self.c.lea(S1, x::rip());
        let disp = self.c.rip_at;
        self.c.lea(S1, x::ix(S1, S0, 3, 0));
        // jmp r11
        self.c.byte(0x41);
        self.c.byte(0xFF);
        self.c.byte(0xE3);
        self.c.patch32(disp, self.c.len() - (disp + 4));
        let mut cs = Vector::<u64>::new();
        for x in 0..span {
            let e = es[x as usize];
            let j = self.c.jmp32_long();
            for _ in 0..3 {
                self.c.byte(0xCC);
            }
            if !self.moves_needed(e) {
                self.fix.push(j as u64 << 32 | b.edge_target(e) as u64);
            } else if e == d {
                ds.push(j);
            } else {
                cs.push(j as u64 << 32 | e as u64);
            }
        }
        let total = cs.len() + if ds.len() != 0 {
            1
        } else {
            0
        };
        let mut done: usize = 0;
        if ds.len() != 0 {
            for q in 0..ds.len() {
                self.c.land(ds[q], self.c.len());
            }
            self.edge_moves(d);
            done += 1;
            self.goto(b.edge_target(d), done < total);
        }
        for q in 0..cs.len() {
            self.c.land((cs[q] >> 32) as u32, self.c.len());
            let e = cs[q] as u32;
            self.edge_moves(e);
            done += 1;
            self.goto(b.edge_target(e), done < total);
        }
        return true;
    }

    // A local read-only symbol of the object holding table `lk`'s bytes.
    fn table_sym(self: &mut Self, lk: &sws::Lookup) u32 {
        return self.rodata_sym(lk.bytes[0..lk.bytes.len()], lk.align_log2);
    }

    // A local read-only symbol of the object holding `bytes`, aligned to `1 << align_log2`.
    fn rodata_sym(self: &mut Self, bytes: []u8, align_log2: u8) u32 {
        let o = self.obj();
        let nm = format("__sc_tab.{}", o.syms.len());
        let k = o.sym(&nm);
        let n = bytes.len() as u64;
        let at = o.define(k, ob::S_RODATA, align_log2, n, 0);
        o.put(ob::S_RODATA, bytes);
        o.pad_to(ob::S_RODATA, at + n);
        return k;
    }

    // The read-only symbol holding words `ws` (little-endian), aligned to their size up to 64 bytes: one per
    // contents in a body (`kcon`), as clang's constant pool.
    fn const_sym(self: &mut Self, ws: []u64) u32 {
        for q in 0..self.kcon.len() {
            let (at, n, ks) = self.kcon[q];
            if n as usize == ws.len() && self.kwords[at as usize..(at + n) as usize] == ws {
                return ks;
            }
        }
        let mut bs = Vector::<u8>::with_capacity(8 * ws.len());
        for q in 0..ws.len() {
            for k in 0..8u64 {
                bs.push((ws[q] >> 8 * k) as u8);
            }
        }
        let k = self.rodata_sym(&bs, (8 * ws.len() as u32).min(64).trailing_zeros() as u8);
        self.kcon.push((self.kwords.len() as u32, ws.len() as u32, k));
        self.kwords.extend_from_slice(ws);
        return k;
    }

    // Whether an argument of edge `e` is not in its parameter's home yet (the homes chosen).
    fn moves_needed(self: &Self, e: u32) bool {
        let b = self.b();
        let tb = b.blocks[b.edge_target(e) as usize];
        let ni = b.insts.len() as u32;
        for q in 0..b.edge_nargs(e) {
            let px = ni + tb.param_start + q;
            let ax = self.vx(b.edge_arg(e, q));
            let pva = self.va[px as usize];
            if ax != px && !(pva.home == H_FIXED && self.va[ax as usize].reg == pva.reg) {
                return true;
            }
        }
        return false;
    }

    // Whether edge `e`'s moves may run before the branch whose other edge is `o`: every parameter of `e`'s
    // target (a loop header, its back edge) ends its range in this block and no argument of `o` is in a
    // register they write, so the other path reads none of the homes they write. The moves keep the flags
    // (`keep_flags`). One branch then takes the edge.
    fn early_moves(self: &Self, e: u32, o: u32) bool {
        let b = self.b();
        let tb = b.blocks[b.edge_target(e) as usize];
        let ni = b.insts.len() as u32;
        for q in 0..tb.param_len as u32 {
            if self.lv.end[(ni + tb.param_start + q) as usize] > self.pos {
                return false;
            }
        }
        // No argument of `o` is in a register home the moves write.
        for q in 0..b.edge_nargs(e) {
            let px = ni + tb.param_start + q;
            let ax = self.vx(b.edge_arg(e, q));
            let pva = self.va[px as usize];
            if ax == px || pva.home != H_FIXED || self.va[ax as usize].reg == pva.reg {
                continue;
            }
            for j in 0..b.edge_nargs(o) {
                let l = self.loc_of(self.vx(b.edge_arg(o, j)));
                if l.kind == LC_REG && l.reg == pva.reg {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether edge `e`'s moves may run before the branch whose other edge is `o`: `early_moves`, or each
    // writes a register home that no argument of `o` is in and that holds its parameter of a later block
    // (`edge_homes`), a value that dies in this block, or a copy (its home elsewhere) that `o`'s target
    // does not keep.
    fn early_ok(self: &Self, e: u32, o: u32) bool {
        return self.early_moves(e, o) || self.moves_free(e, o, false);
    }

    // Whether the register homes edge `e`'s moves write hold no value the path of edge `o` reads: each holds
    // `e`'s parameter of a later block (`edge_homes`), a value that dies in this block, or a copy (its home
    // elsewhere) that `o`'s target does not keep; and, unless `o`'s moves are among `e`'s (`within`: those
    // moves then serve `o` too), no argument of `o` is in one.
    fn moves_free(self: &Self, e: u32, o: u32, within: bool) bool {
        let b = self.b();
        let sp = self.lv.pos[b.edge_target(o) as usize];
        let kept = sp == self.pos + 1 && self.continues(sp);
        // A later target's parameters are not live yet: their homes are only reserved (`edge_homes`).
        let fwd = self.lv.pos[b.edge_target(e) as usize] > self.pos;
        let tb = b.blocks[b.edge_target(e) as usize];
        let ni = b.insts.len() as u32;
        for q in 0..b.edge_nargs(e) {
            let px = ni + tb.param_start + q;
            let ax = self.vx(b.edge_arg(e, q));
            let pva = self.va[px as usize];
            if ax == px || pva.home == H_FIXED && self.va[ax as usize].reg == pva.reg {
                continue;
            }
            if pva.home != H_FIXED {
                return false;
            }
            let r = pva.reg;
            if (self.held & bit(r)) != 0 {
                let y = self.owner[r as usize];
                if !(fwd && y == px) && self.lv.end[y as usize] > self.pos && (kept || self.va[y as usize].home == H_FIXED) {
                    return false;
                }
            }
            for j in 0..b.edge_nargs(o) {
                let l = self.loc_of(self.vx(b.edge_arg(o, j)));
                if !within && l.kind == LC_REG && l.reg == r {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether edges `e` and `o` need the same moves: each argument either passes into a register home
    // the other edge fills with the same value (a loop's parameter and the one after the loop that shares
    // its register, `lv::Live::share`); and each such register holds no other value that lives on. The
    // moves then run once, before the branch.
    fn same_moves(self: &Self, e: u32, o: u32) bool {
        return self.moves_within(e, o) && self.moves_within(o, e);
    }

    // `same_moves` one way: each move of edge `e` is one of edge `o`'s.
    fn moves_within(self: &Self, e: u32, o: u32) bool {
        let b = self.b();
        let ni = b.insts.len() as u32;
        let tb = b.blocks[b.edge_target(e) as usize];
        let ob = b.blocks[b.edge_target(o) as usize];
        for q in 0..b.edge_nargs(e) {
            let px = ni + tb.param_start + q;
            let a = b.edge_arg(e, q);
            let ax = self.vx(a);
            let pva = self.va[px as usize];
            if ax == px || pva.home == H_FIXED && self.va[ax as usize].reg == pva.reg {
                continue;
            }
            if pva.home != H_FIXED {
                return false;
            }
            let mut found = false;
            for j in 0..b.edge_nargs(o) {
                let oy = ni + ob.param_start + j;
                found = found || b.edge_arg(o, j) == a && self.va[oy as usize].home == H_FIXED && self.va[oy as usize].reg == pva.reg;
            }
            let y = self.owner[pva.reg as usize];
            let mine = y == NONE || y == px || self.lv.share[px as usize] == y || self.lv.end[y as usize] <= self.pos;
            if !found || !mine {
                return false;
            }
        }
        return true;
    }

    // Whether register aggregate argument `v` (layout `loc`), at an address in a register that no value read
    // after the call's parallel move is (`late`), loads its parts in that move: each of 1, 2, 4 or 8 bytes
    // (a vector one of 4, 8 or 16). The register stays live until the move reads it.
    fn parts_moved(self: &Self, v: Value, loc: ab::ALoc, late: &Vector<u32>) bool {
        let x = self.vx(v);
        if loc.kind != ab::L_REG || self.va[x as usize].reg == NOREG || self.va[x as usize].reg >= V0 || self.frame_addr(
            v,
        ).0 {
            return false;
        }
        for q in 0..late.len() {
            if late[q] == x {
                return false;
            }
        }
        for q in 0..loc.n as u32 {
            let n = self.lay.parts[(loc.p0 + q) as usize].size as u32;
            let ok = if self.lay.parts[(loc.p0 + q) as usize].v {
                n == 4 || n == 8 || n == 16
            } else {
                n == 1 || n == 2 || n == 4 || n == 8
            };
            if !ok {
                return false;
            }
        }
        return true;
    }

    // Edge `e`'s moves before a branch: the flags stay.
    fn flag_moves(self: &mut Self, e: u32) {
        let kf = self.keep_flags;
        self.keep_flags = true;
        self.edge_moves(e);
        self.keep_flags = kf;
    }

    // Branch `t` on an `and` or `or` of two comparisons (`lv::FOLD_BRCONJ`): the first compared, then a jump
    // to the edge it settles (the false one of an `and`, the true one of an `or`), then the second and
    // `branch2`. When that edge moves values or is late: both conditions set in bytes and combined, then
    // `branch2` on the result.
    fn branch_conj(self: &mut Self, t: Inst) {
        let b = self.b();
        let c = b.insts[t.a as usize];
        let (c1, c2) = (b.insts[c.a as usize], b.insts[c.b as usize]);
        let and = c.op == O_AND;
        let e = if and {
            t.c
        } else {
            t.b
        };
        // The second comparison's operands stay in their registers while the first one compares: their
        // uses are counted at the branch already, so nothing else keeps them.
        for k in 0..self.uses.len() {
            let r = self.va[self.vx(self.uses[k]) as usize].reg;
            if r != NOREG {
                self.lock |= bit(r);
            }
        }
        let cc1 = self.compare(c1, NONE);
        self.keep_flags = true;
        // After the first comparison, which may have taken a register an argument of `e` was in. Not into
        // the next block when it continues this one: it takes the registers as the second comparison
        // leaves them.
        let sp = self.lv.pos[b.edge_target(e) as usize];
        let early = self.lv.late_index(self.lv.order[self.pos as usize], e) == NONE && !self.moves_needed(e) && !(sp == self.pos + 1 && self.continues(
            sp,
        ));
        if early {
            self.spill_live_out();
            self.cbranch(
                if and {
                    x::invert(cc1)
                } else {
                    cc1
                },
                b.edge_target(e),
            );
            let cc2 = self.compare(c2, NONE);
            self.keep_flags = true;
            self.branch2(cc2, t.b, t.c);
            return;
        }
        self.c.setcc(cc1, S0);
        let cc2 = self.compare(c2, NONE);
        self.c.setcc(cc2, S1);
        self.c.alu_rr(
            if and {
                x::AND
            } else {
                x::OR
            },
            1,
            S0,
            S1,
        );
        self.keep_flags = true;
        self.spill_live_out();
        self.branch2(x::CC_NE, t.b, t.c);
    }

    // A two-way branch: condition `cc` takes edge `et`, else `ef`; each edge's moves on its own path, or
    // before the branch (`early_moves`).
    fn branch2(self: &mut Self, cc: u32, et: u32, ef: u32) {
        let b = self.b();
        // A late edge goes to its stub past the blocks, which moves (`lv::Live::late`).
        let lt = self.lv.late_index(self.lv.order[self.pos as usize], et);
        let lf = self.lv.late_index(self.lv.order[self.pos as usize], ef);
        let mt = lt == NONE && self.moves_needed(et);
        let mf = lf == NONE && self.moves_needed(ef);
        let tt = if lt != NONE {
            b.blocks.len() as u32 + lt
        } else {
            b.edge_target(et)
        };
        let tf = if lf != NONE {
            b.blocks.len() as u32 + lf
        } else {
            b.edge_target(ef)
        };
        let q = self.pos as usize + 1;
        let next = if q < self.lv.order.len() && !self.crosses(self.lv.order[q]) {
            self.lv.order[q]
        } else {
            NONE
        };
        if !mt && !mf {
            if tt == next {
                self.cbranch(x::invert(cc), tf);
            } else {
                self.cbranch(cc, tt);
                self.goto(tf, false);
            }
        } else if mt && mf && self.same_moves(et, ef) {
            self.flag_moves(et);
            if tt == next {
                self.cbranch(x::invert(cc), tf);
            } else {
                self.cbranch(cc, tt);
                self.goto(tf, false);
            }
        } else if mt && mf && (self.moves_within(et, ef) && self.moves_free(ef, et, true) || self.moves_within(ef, et) && self.moves_free(
            et,
            ef,
            true,
        )) {
            // One edge's moves are among the other's: those before the branch serve both (a loop's exit that
            // takes a value its back edge also passes on).
            self.flag_moves(
                if self.moves_within(et, ef) {
                    ef
                } else {
                    et
                },
            );
            if tt == next {
                self.cbranch(x::invert(cc), tf);
            } else {
                self.cbranch(cc, tt);
                self.goto(tf, false);
            }
        } else if mt && !mf && (tt != next && self.early_ok(et, ef) || self.early_moves(et, ef)) {
            self.flag_moves(et);
            self.cbranch(cc, tt);
            self.goto(tf, false);
        } else if !mt && mf && (tf != next && self.early_ok(ef, et) || self.early_moves(ef, et)) {
            self.flag_moves(ef);
            self.cbranch(x::invert(cc), tf);
            self.goto(tt, false);
        } else if mt && mf && tt != next && self.early_ok(et, ef) {
            // The edge to the block that does not follow first: the other's moves fall through.
            self.flag_moves(et);
            self.branch_over(cc, tt, ef);
        } else if mt && mf && tf != next && self.early_ok(ef, et) {
            self.flag_moves(ef);
            self.branch_over(x::invert(cc), tf, et);
        } else if mt && !mf {
            self.branch_over(x::invert(cc), tf, et);
        } else if !mt && mf {
            self.branch_over(cc, tt, ef);
        } else {
            let at = self.c.jcc32(cc);
            self.edge_moves(ef);
            // No move of `ef` left code (its arguments were in place): its jump alone, inverted.
            if self.c.len() == at + 4 {
                let _ = self.c.jumps.pop();
                self.c.b.truncate(at as usize - 2);
                self.cbranch(x::invert(cc), tf);
            } else {
                self.goto(tf, true);
                self.c.land(at, self.c.len());
            }
            self.edge_moves(et);
            self.goto(tt, false);
        }
    }

    // A branch on `cc` to block `k`, then the moves of edge `e` and a jump to its target. When the moves
    // leave no code (their arguments were in place), the branch inverted to that target alone.
    fn branch_over(self: &mut Self, cc: u32, k: u32, e: u32) {
        let at = self.c.jcc32(cc);
        self.edge_moves(e);
        let te = self.b().edge_target(e);
        if self.c.len() == at + 4 {
            let _ = self.c.jumps.pop();
            self.c.b.truncate(at as usize - 2);
            self.cbranch(x::invert(cc), te);
            self.goto(k, false);
        } else {
            self.fix.push(at as u64 << 32 | k as u64);
            self.goto(te, false);
        }
    }

    fn terminator(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let b = self.b();
        self.edge_homes(t);
        if op == O_JMP {
            self.spill_live_out();
            let li = self.lv.late_index(self.lv.order[self.pos as usize], t.a);
            if li != NONE {
                // Its moves wait in its stub past the blocks (`lv::Live::late`).
                self.goto(b.blocks.len() as u32 + li, true);
                return true;
            }
            self.edge_moves(t.a);
            self.goto(b.edge_target(t.a), false);
            return true;
        }
        if op == O_BR && (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] && (b.insts[t.a as usize].op == O_AND || b.insts[t.a as usize].op == O_OR) {
            self.branch_conj(t);
            return true;
        }
        if op == O_BR {
            let cx = self.vx(t.a);
            let cc = self.cond_test(cx, t.a);
            self.spill_live_out();
            self.branch2(cc, t.b, t.c);
            return true;
        }
        if op == O_SWITCH {
            let ty = self.vt(t.a);
            let bits = type_bits(ty, self.ptr);
            let sz = bits / 8;
            let r = self.reg(t.a);
            self.spill_live_out();
            if self.lookup(t, r, sz) || self.jump_table(t, r, sz) {
                return true;
            }
            let n = t.aux as u32;
            let mut stubs = Vector::<u64>::new();
            // A case that goes where the default goes, neither passing arguments, needs no test.
            let d = b.switch_edge(t, n);
            let mut last = NONE;
            for k in 0..n {
                let e = b.switch_edge(t, k);
                if b.edge_nargs(e) == 0 && b.edge_nargs(d) == 0 && b.edge_target(e) == b.edge_target(d) {
                    continue;
                }
                last = e;
                let c = b.words[(t.b + k) as usize];
                let sv = lp_sext(c, bits);
                if sv >= -2147483648 && sv <= 2147483647 {
                    self.c.alu_ri(x::CMP, sz, r, sv as i32);
                } else {
                    self.c.mov_ri(S1, c);
                    self.c.alu_rr(x::CMP, sz, r, S1);
                }
                if b.edge_nargs(e) == 0 {
                    self.cbranch(x::CC_E, b.edge_target(e));
                } else {
                    stubs.push(self.c.jcc32(x::CC_E) as u64 << 32 | e as u64);
                }
            }
            if last != NONE && stubs.len() == 0 && self.next_is(b.edge_target(last)) && b.edge_nargs(last) == 0 && !self.moves_needed(
                d,
            ) {
                // The last case's block follows: its branch inverted to the default.
                let _ = self.fix.pop();
                let _ = self.c.jumps.pop();
                let nc = self.c.len();
                self.c.b.truncate(nc as usize - 6);
                self.cbranch(x::CC_NE, b.edge_target(d));
                return true;
            }
            self.edge_moves(d);
            self.goto(b.edge_target(d), stubs.len() != 0);
            for k in 0..stubs.len() {
                self.c.land((stubs[k] >> 32) as u32, self.c.len());
                let e = stubs[k] as u32;
                self.edge_moves(e);
                self.goto(b.edge_target(e), k + 1 < stubs.len());
            }
            return true;
        }
        if op == O_RET {
            if i != self.tail_ret {
                self.ret(t);
            }
            return true;
        }
        if op == O_PANIC {
            let p = unsafe &*self.pkg;
            let m = p.spell(p.msgs[b.msgs[t.a as usize] as usize]);
            if t.b == VNONE {
                self.panic_text(m);
            } else {
                // The lowest set lane of the mask.
                let r = self.reg(t.b);
                self.c.bsx(false, 8, self.arg(0), r);
                self.lane_panic_call(m);
            }
            self.stop = self.c.len();
            return true;
        }
        if op == O_UNREACHABLE {
            self.c.ud2();
            self.stop = self.c.len();
            return true;
        }
        let _ = i;
        assert(false, "x64gen: a terminator the verifier rejects");
        return false;
    }

    // Return: the result into its registers, then the epilogue.
    fn ret(self: &mut Self, t: Inst) {
        let b = self.b();
        let rl = self.self_lay.ret;
        let rt = b.pool[b.sig as usize + 2];
        let np = b.pool[b.sig as usize];
        if rl.kind == ab::L_REG {
            let i = self.cur;
            if (rt & AGG) != 0 && i > b.blocks[self.lv.def_blk[i as usize] as usize].start && self.rstore[i as usize - 1] != 0 {
                // In the part registers already (`ret_moves`).
            } else if (rt & AGG) != 0 {
                let pv = VPARAM | b.blocks[0].param_start + np;
                let (base, off) = self.addr(pv, 0);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else if self.ret_in_vreg(t.a) {
                // A vector a register holds, returned whole in one xmm register.
                let pa = self.self_lay.parts[rl.p0 as usize];
                let ra = self.va[self.vx(t.a) as usize].reg;
                if ra != V0 + pa.reg {
                    self.c.vmov(pa.reg, ra - V0);
                }
            } else if in_mem(self.vt(t.a)) {
                let (base, off) = self.mloc(t.a);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else {
                let pa = self.self_lay.parts[rl.p0 as usize];
                let r = pa.reg + if pa.v {
                    V0
                } else {
                    0
                };
                // A narrow result's bits above it are the caller's to extend (as clang's callers do).
                self.materialize(t.a, r);
            }
        } else if rl.kind == ab::L_SRET {
            // rax: the memory's pointer, the value copied there first for a memory value.
            if (rt & AGG) != 0 {
                self.materialize(VPARAM | b.blocks[0].param_start + np, x::RAX);
            } else if self.va[self.vx(t.a) as usize].reg != NOREG && self.in_reg(self.vt(t.a)) {
                // A vector a register holds, stored there.
                self.sret_rax();
                let ra = self.va[self.vx(t.a) as usize].reg;
                self.c.vstore(type_bytes(self.vt(t.a), self.ptr), ra - V0, x::at(x::RAX, 0));
            } else {
                self.sret_rax();
                let (base, off) = self.mloc(t.a);
                self.copy_mem(x::RAX, 0, base, off, type_bytes(self.vt(t.a), self.ptr));
            }
        }
        let at = self.c.jmp32();
        self.epi.push(at);
    }

    // rax = the result's pointer: from the register it arrived in (`sret_keep`), else from its slot.
    fn sret_rax(self: &mut Self) {
        if self.sret_keep {
            self.c.mov_rr(8, x::RAX, self.arg(0));
        } else {
            self.c.load(8, false, x::RAX, x::at(x::RSP, self.sret_off as i32));
        }
    }

    // The object symbol of C string `text`, one per text.
    fn cstr(self: &mut Self, text: str) u32 {
        return self.cs.sym(self.obj(), text);
    }

    // Register `r` = the address of C string `text`.
    fn cstr_addr(self: &mut Self, r: u8, text: str) {
        let os = self.cstr(text);
        self.c.lea(r, x::rip());
        self.reloc_rip(x::R_PC32, os, 0);
    }

    // The stack guard's value into `r`: System V's in the thread block at %fs:0x28, Microsoft x64's (mingw-w64)
    // in `__stack_chk_guard` through the object's address slot.
    fn guard(self: &mut Self, r: u8) {
        if !self.win {
            // mov r, qword fs:[0x28]: an absolute 32-bit address in the fs segment.
            self.c.byte(0x64);
            self.c.byte(0x48 | (r as u32 >> 3 & 1) << 2);
            self.c.byte(0x8B);
            self.c.byte((r as u32 & 7) << 3 | 4);
            self.c.byte(0x25);
            self.c.d32(0x28);
            return;
        }
        let os = self.obj().sym("__stack_chk_guard");
        let rp = self.refptr(os);
        self.c.rm(0, 0x8B, true, r, x::rip(), false);
        self.reloc_rip(x::R_PC32, rp, 0);
        self.c.load(8, false, r, x::at(r, 0));
    }

    // A call of `__sc_panic` with C string `text`.
    fn panic_text(self: &mut Self, text: str) {
        let th = self.panic_thunk(text);
        self.upper_clear();
        let at = self.c.call32();
        self.called = true;
        self.rels.push(CRel { at: at, kind: x::R_PC32, sym: th, addend: -4 });
    }

    // The object's thunk of the panic with `text` (`__sc_pk.<the message's symbol>`, local, in the cold
    // text), made on its first use: the first argument register = the message (`lea`), then a jump to
    // `__sc_panic`. Its sites call it, 5 bytes each: the jump keeps their return address on the stack, so
    // `__sc_panic`'s caller is the panicking site itself, as with a direct call.
    fn panic_thunk(self: &mut Self, text: str) u32 {
        let os = self.cstr(text);
        let nm = format("__sc_pk.{}", os);
        let cold = self.cold_text();
        let r = self.arg(0);
        let o = self.obj();
        let k = o.sym(&nm);
        if o.syms[k as usize].sec != ob::NOSEC {
            return k;
        }
        let named = o.named(cold, true);
        let sec = if named == ob::NOSEC {
            ob::S_TEXT
        } else {
            named
        };
        let at = o.define(k, sec, 4, 12, ob::SF_FUNC);
        let ps = o.sym("__sc_panic");
        // lea r, [rip + disp32]; jmp rel32.
        let bs: [u8; 12] = [0x48 | (r >> 3 & 1) << 2, 0x8D, (r & 7) << 3 | 5, 0, 0, 0, 0, 0xE9, 0, 0, 0, 0];
        o.put(sec, bs);
        o.reloc(sec, x::R_PC32, at as u32 + 3, os, -4);
        o.reloc(sec, x::R_PLT32, at as u32 + 8, ps, -4);
        return k;
    }

    // The call of `__sc_lane_panic(rdi, msg)`: `lane <rdi>: <msg>`.
    fn lane_panic_call(self: &mut Self, msg: str) {
        self.cstr_addr(self.arg(1), msg);
        self.call_sym("__sc_lane_panic");
    }

    // ---- Prologue, epilogue and output ----

    // A sibling call's jump to object symbol `os` (`jmp rel32`, a relocation), or to r11 for NONE.
    fn tail_jump(self: &mut Self, os: u32) {
        if os == NONE {
            self.c.byte(0x41);
            self.c.byte(0xFF);
            self.c.byte(0xE3);
            return;
        }
        self.c.byte(0xE9);
        let at = self.c.len();
        self.c.d32(0);
        self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: os, addend: -4 });
    }

    // Frame the body's code and define function symbol `s` with it, with its unwind rules. Shrink-wrapped
    // (`shrink`), the prologue runs on each edge into the code past `ra` (its bytes before a jump, once per
    // target) and the epilogue on each edge out; the warm code returns with `ret` and its sibling calls jump
    // straight to the callee.
    // Remove the jump whose displacement is at `at` from the jumps `relax` shortens.
    fn drop_jump(self: &mut Self, at: u32) {
        for k in 0..self.c.jumps.len() {
            if self.c.jumps[k] == at {
                let _ = self.c.jumps.remove(k);
                return;
            }
        }
        assert(false, "x64gen: a dropped jump is a jump");
    }

    // Whether a jump reaches the epilogue at `body_n` once `finish` placed its copies (`sw`: shrink-wrapped,
    // the warm code before `ra`; `short`: the epilogue fits a jump's place): a jump to it the warm code's `ret`
    // or the epilogue's copy does not take, or a branch of the framed code to it or past the blocks, through
    // blocks that are one jump alone (at most 8 steps, as `finish`).
    fn epi_reached(self: &Self, sw: bool, ra: u32, body_n: u32, short: bool) bool {
        for q in 0..self.epi.len() {
            if !(sw && self.epi[q] < ra) && !short {
                return true;
            }
        }
        let mut thru = Map::<u32, u32>::new();
        for q in 0..self.fix.len() {
            let at = (self.fix[q] >> 32) as u32;
            if self.c.b[at as usize - 1] == 0xE9 {
                thru.insert(at - 1, self.blk_at[(self.fix[q] as u32) as usize]);
            }
        }
        for q in 0..self.fix.len() {
            let at = (self.fix[q] >> 32) as u32;
            if sw && at < ra {
                continue;
            }
            let mut to = self.blk_at[(self.fix[q] as u32) as usize];
            for _ in 0..8 {
                switch thru.get(&to) {
                    Some(x) => {
                        to = *x;
                    },
                    None => {
                        break;
                    },
                }
            }
            if to >= body_n {
                return true;
            }
        }
        return false;
    }

    fn finish(self: &mut Self, s: u32) bool {
        let sw = self.shrink;
        let ra = if sw {
            self.rare_at()
        } else {
            0
        };
        // A last jump to the epilogue falls through instead, and so does the one before it when the block
        // between held only that jump: one step per jump.
        while self.epi.len() != 0 && self.epi[self.epi.len() - 1] + 4 == self.c.len() {
            let _ = self.epi.pop();
            let _ = self.c.jumps.pop();
            let nc = self.c.len();
            self.c.b.truncate(nc as usize - 5);
        }
        if self.err.len() != 0 {
            return false;
        }
        // The body ends with a sibling call's jump, and nothing jumps to the epilogue nor to a block at the
        // body's end (one whose jump to the epilogue went): nothing reaches the epilogue but that call, whose
        // jump goes and whose jump to the callee ends the epilogue instead of its `ret`.
        let mut last = NONE;
        let mut ends = false;
        let nt = self.tails.len();
        let mut reached = false;
        for q in 0..self.fix.len() {
            reached = reached || self.blk_at[(self.fix[q] as u32) as usize] >= self.c.len();
        }
        if !sw && nt != 0 && !reached && self.epi.len() == 0 && self.canary < 0 && (self.tails[nt - 1] >> 32) as u32 + 4 == self.c.len() {
            ends = true;
            last = self.tails[nt - 1] as u32;
            let _ = self.tails.pop();
            let _ = self.c.jumps.pop();
            let nc = self.c.len();
            self.c.b.truncate(nc as usize - 5);
        }
        // Microsoft x64 unwinds an rsp the prologue moves by constants only, or one a frame register gives
        // back: an over-aligned frame keeps the allocated frame's bottom in a callee-saved register the body
        // leaves alone (the unwind information's frame register), then aligns rsp.
        let mut fp: u8 = NOREG;
        if self.win && self.max_align > 16 {
            let free: [u8; 7] = [3, 6, 7, 12, 13, 14, 15];
            for r in free {
                if fp == NOREG && (self.csr & bit(r)) == 0 {
                    fp = r;
                }
            }
            if fp == NOREG {
                return self.refuse("a frame aligned past 16 bytes on Windows that uses every callee-saved register");
            }
            self.csr |= bit(fp);
        }
        let mut regs = Vector::<u8>::new();
        for r in 0..16u32 {
            if (self.csr & bit(r as u8)) != 0 {
                regs.push(r as u8);
            }
        }
        // The vector registers to save (Microsoft x64), as xmm numbers.
        let mut xregs = Vector::<u8>::new();
        for r in V0 as u32..32u32 {
            if (self.csr & bit(r as u8)) != 0 {
                xregs.push(r as u8 - V0);
            }
        }
        let npush = regs.len() as u32;
        let omit = self.fb == x::IN;
        // The call left rsp 8 past a multiple of 16; `push rbp` (with a frame pointer), the pushes and the
        // locals end on one. The vector registers' save area tops the locals, 16-aligned.
        // A System V body that calls nothing (no canary check either) and keeps nothing 16-aligned for
        // other code (no slot aligned past 8, no inline assembly) leaves rsp where it falls.
        // A Microsoft x64 body that calls nothing and keeps nothing on the stack but saved registers (no slot,
        // spill or frame register) needs neither the callees' home area nor an aligned frame.
        let bare = self.win && !self.called && self.canary < 0 && (self.opf & lv::OP_ASM) == 0 && omit && fp == NOREG && self.spill_base == self.out_size && self.spill_top == 0 && self.max_align <= 16;
        let b = self.b();
        let mut leaf = !self.win && !self.called && self.canary < 0 && (self.opf & lv::OP_ASM) == 0 || bare;
        for k in 0..b.slots.len() {
            leaf = leaf && b.slots[k].align_log2 <= 3;
        }
        let mut local = if bare {
            0
        } else if leaf {
            self.spill_base + self.spill_top + 7 & ~7u32
        } else {
            self.spill_base + self.spill_top + 15 & ~15u32
        };
        let xsave = local;
        local += 16 * xregs.len() as u32;
        if npush % 2 != 0 != omit && !leaf {
            local += 8;
        }
        if omit {
            // The incoming frame's operands from rsp: rbp would sit 8 below the return address.
            self.c.rebase((8 * npush + local) as i32 - 8);
        }
        let mut pro = x::Code::new();
        if !omit {
            pro.push(x::RBP);
            pro.mov_rr(8, x::RBP, x::RSP);
        }
        let mut push_at = Vector::<u32>::with_capacity(regs.len());
        for k in 0..regs.len() {
            pro.push(regs[k]);
            push_at.push(pro.len());
        }
        let push_end = pro.len();
        // The locals, a page at a time past 4 KiB so each guard page is touched: in a loop through r11
        // past 4 pages.
        let mut left = local;
        if left >= 4 * 4096 {
            pro.mov_ri(S1, left / 4096);
            let top = pro.len();
            pro.alu_ri(x::SUB, 8, x::RSP, 4096);
            pro.alu_mi(x::OR, 8, x::at(x::RSP, 0), 0);
            pro.alu_ri(x::SUB, 4, S1, 1);
            pro.jcc_back(x::CC_NE, top);
            left = left % 4096;
        }
        while left >= 4096 {
            pro.alu_ri(x::SUB, 8, x::RSP, 4096);
            pro.alu_mi(x::OR, 8, x::at(x::RSP, 0), 0);
            left -= 4096;
        }
        if left != 0 {
            pro.alu_ri(x::SUB, 8, x::RSP, left as i32);
        }
        let alloc_end = pro.len();
        let mut xsave_at = Vector::<u32>::with_capacity(xregs.len());
        for j in 0..xregs.len() {
            pro.vstore(16, xregs[j], x::at(x::RSP, (xsave + 16 * j as u32) as i32));
            xsave_at.push(pro.len());
        }
        let mut fp_at: u32 = 0;
        if fp != NOREG {
            pro.mov_rr(8, fp, x::RSP);
            fp_at = pro.len();
        }
        if self.max_align > 16 {
            pro.alu_ri(x::AND, 8, x::RSP, -(self.max_align as i32));
        }
        let pl = pro.len();
        if self.win && pl > 255 {
            return self.refuse("a prologue past 255 bytes on Windows");
        }
        // The bytes before the body: the prologue, none when shrink-wrapped.
        let lead = if sw {
            0
        } else {
            pl
        };
        let body_n = self.c.len();
        // Whether the body's last code falls into the epilogue: not a panic, a trap or a jump.
        let nj = self.c.jumps.len();
        let falls = body_n == 0 || self.stop != body_n && !(nj != 0 && self.c.jumps[nj - 1] + 4 == body_n && self.c.b[body_n as usize - 5] == 0xE9);
        // Before the epilogue proper, which Microsoft x64's unwinder reads instruction by instruction; not
        // when the result is a 32-byte vector in ymm0.
        if !ymm_parts(&self.self_lay) {
            self.upper_clear();
        }
        let core_at = self.c.len();
        // The canary's check: on a mismatch `__stack_chk_fail`, which does not return.
        if self.canary >= 0 {
            self.guard(S0);
            self.c.rm(0, 0x33, true, S0, x::at(x::RSP, self.canary as i32), false);
            self.c.byte(0x74);
            self.c.byte(5);
            self.call_sym("__stack_chk_fail");
        }
        // The epilogue: under Microsoft x64 the vector registers back, then the form its unwinder knows
        // (`add rsp`, or `lea rsp` from the frame register, the pops, `ret`).
        if self.win {
            let base = ast_pick(fp != NOREG, fp, x::RSP);
            for j in 0..xregs.len() {
                self.c.vload(16, xregs[j], x::at(base, (xsave + 16 * j as u32) as i32));
            }
            if fp != NOREG {
                self.c.lea(x::RSP, x::at(fp, local as i32));
            } else if local != 0 {
                self.c.alu_ri(x::ADD, 8, x::RSP, local as i32);
            }
            let mut k = regs.len();
            while k > 0 {
                k -= 1;
                self.c.pop(regs[k]);
            }
            if !omit {
                self.c.pop(x::RBP);
            }
        } else if omit {
            if local != 0 {
                self.c.alu_ri(x::ADD, 8, x::RSP, local as i32);
            }
            let mut k = regs.len();
            while k > 0 {
                k -= 1;
                self.c.pop(regs[k]);
            }
        } else if npush != 0 {
            self.c.lea(x::RSP, x::at(x::RBP, -8 * npush as i32));
            let mut k = regs.len();
            while k > 0 {
                k -= 1;
                self.c.pop(regs[k]);
            }
            self.c.pop(x::RBP);
        } else {
            self.c.byte(0xC9);
        }
        // The epilogue's bytes but its last instruction, which a sibling call's copy replaces by its jump.
        let core_end = self.c.len();
        if ends {
            self.tail_jump(last);
        } else {
            self.c.ret();
        }
        let epi_end = self.c.len();
        // The epilogue's bytes, which its copies (the warm code's `ret`, the sibling calls, the exit stubs, the
        // jumps it replaces) take; it stays at `body_n` only when code reaches it there (`epi_reached`).
        let mut tpl = Vector::<u8>::with_capacity((epi_end - body_n) as usize);
        tpl.extend_from_slice(self.c.b[body_n as usize..epi_end as usize]);
        let en = epi_end - body_n;
        if !(falls || ends || self.canary >= 0 || self.epi_reached(sw, ra, body_n, en <= 5)) {
            self.c.b.truncate(body_n as usize);
            // Microsoft x64's unwinder looks a frame's return address up as it is: after a last call that does
            // not return, a trap keeps it in the function's code.
            if self.win && self.stop == body_n {
                self.c.byte(0xCC);
            }
        }
        if sw {
            // The warm code's jumps to the epilogue become its `ret`, with the upper halves' clear before.
            let mut keep = Vector::<u32>::with_capacity(self.epi.len());
            for q in 0..self.epi.len() {
                let at = self.epi[q];
                if at >= ra {
                    keep.push(at);
                    continue;
                }
                let n = core_at - body_n;
                for k in 0..5u32 {
                    self.c.b[(at - 1 + k) as usize] = if k < n {
                        tpl[k as usize]
                    } else if k == n {
                        0xC3
                    } else {
                        0xCC
                    };
                }
                self.drop_jump(at);
            }
            self.epi = keep;
        }
        for q in 0..self.tails.len() {
            let at = (self.tails[q] >> 32) as u32;
            let os = self.tails[q] as u32;
            if sw && at < ra || core_end == body_n {
                // From the warm code, which has no frame, or with an epilogue of `ret` alone: the callee's
                // jump in the jump's place.
                self.drop_jump(at);
                if os == NONE {
                    let jr: []u8 = [0x41, 0xFF, 0xE3, 0xCC, 0xCC];
                    for k in 0..5u32 {
                        self.c.b[(at - 1 + k) as usize] = jr[k as usize];
                    }
                } else {
                    self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: os, addend: -4 });
                }
                continue;
            }
            let to = self.c.len();
            self.c.land(at, to);
            for k in body_n..core_end {
                self.c.byte(tpl[(k - body_n) as usize]);
            }
            self.tail_jump(os);
        }
        // An epilogue no longer than a jump (no canary check) takes each jump's place, the bytes left over
        // traps after its `ret`.
        if en <= 5 && self.canary < 0 && self.epi.len() != 0 {
            let mut keep = Vector::<u32>::with_capacity(self.c.jumps.len());
            let mut q: usize = 0;
            for j in 0..self.c.jumps.len() {
                let at = self.c.jumps[j];
                if q < self.epi.len() && self.epi[q] == at {
                    for k in 0..5u32 {
                        self.c.b[(at - 1 + k) as usize] = if k < en {
                            tpl[k as usize]
                        } else {
                            0xCC
                        };
                    }
                    q += 1;
                } else {
                    keep.push(at);
                }
            }
            assert(q == self.epi.len(), "x64gen: every jump to the epilogue is a jump");
            self.c.jumps = keep;
            self.epi.truncate(0);
        }
        // Branches: through a block that is one jump alone, to that jump's target (at most 8 steps; a
        // jump to the epilogue's start).
        let mut thru = Map::<u32, u32>::new();
        for q in 0..self.fix.len() {
            let at = (self.fix[q] >> 32) as u32;
            if self.c.b[at as usize - 1] == 0xE9 {
                thru.insert(at - 1, self.blk_at[(self.fix[q] as u32) as usize]);
            }
        }
        for q in 0..self.epi.len() {
            thru.insert(self.epi[q] - 1, body_n);
        }
        // Shrink-wrapped: per target, its entry or exit stub; the warm code's `ret`. The framed code's
        // epilogue and sibling calls end here; each entry stub's start and end (Microsoft x64's unwind
        // information covers them apart).
        let tails_end = self.c.len();
        let mut stubs = Vector::<u32>::new();
        let mut enter = Map::<u32, u32>::new();
        let mut leave = Map::<u32, u32>::new();
        let mut wret = NONE;
        // The jumps that became `ret`s.
        let mut rets = Vector::<u32>::new();
        for q in 0..self.fix.len() {
            let at = (self.fix[q] >> 32) as u32;
            let mut to = self.blk_at[(self.fix[q] as u32) as usize];
            for _ in 0..8 {
                switch thru.get(&to) {
                    Some(x) => {
                        to = *x;
                    },
                    None => {
                        break;
                    },
                }
            }
            // A block past the end held only branches to the epilogue, which the start of `finish` dropped:
            // the epilogue.
            if to > body_n {
                to = body_n;
            }
            if sw && at < ra && to == body_n {
                // From the warm code to the epilogue: a `ret`.
                if wret == NONE {
                    wret = self.c.len();
                    for k in body_n..core_at {
                        self.c.byte(tpl[(k - body_n) as usize]);
                    }
                    self.c.ret();
                }
                to = wret;
            } else if sw && at < ra && to >= ra {
                to = (switch enter.get(&to) {
                    Some(e) => *e,
                    None => {
                        // Into the framed code: the prologue, then the jump.
                        let e = self.c.len();
                        for k in 0..pl {
                            self.c.byte(pro.b[k as usize]);
                        }
                        let j = self.c.jmp32();
                        self.c.land(j, to);
                        enter.insert(to, e);
                        stubs.push(e);
                        stubs.push(self.c.len());
                        e
                    },
                });
            } else if sw && at >= ra && to < ra {
                to = (switch leave.get(&to) {
                    Some(e) => *e,
                    None => {
                        // Out of the framed code: the epilogue but the upper halves' clear and the `ret`,
                        // then the jump.
                        let e = self.c.len();
                        for k in core_at..core_end {
                            self.c.byte(tpl[(k - body_n) as usize]);
                        }
                        let j = self.c.jmp32();
                        self.c.land(j, to);
                        leave.insert(to, e);
                        e
                    },
                });
            }
            if !sw && self.c.b[at as usize - 1] == 0xE9 && to < self.c.len() && self.c.b[to as usize] == 0xC3 {
                // A jump to a `ret`: that `ret`, the bytes after it traps.
                self.c.b[at as usize - 1] = 0xC3;
                for k in 0..4u32 {
                    self.c.b[(at + k) as usize] = 0xCC;
                }
                rets.push(at);
                continue;
            }
            self.c.land(at, to);
        }
        if rets.len() != 0 {
            rets.sort();
            let mut keep = Vector::<u32>::with_capacity(self.c.jumps.len());
            let mut q: usize = 0;
            for j in 0..self.c.jumps.len() {
                let at = self.c.jumps[j];
                while q < rets.len() && rets[q] < at {
                    q += 1;
                }
                if q < rets.len() && rets[q] == at {
                    continue;
                }
                keep.push(at);
            }
            self.c.jumps = keep;
        }
        for q in 0..self.epi.len() {
            self.c.land(self.epi[q], body_n);
        }
        // Every jump that reaches in 2 bytes takes them; the relocations move with the code.
        // The line rows and the epilogue's start move with them.
        let mut ats = Vector::<u32>::with_capacity(self.rels.len() + self.rows.len() + 1);
        for q in 0..self.rels.len() {
            ats.push(self.rels[q].at);
        }
        for q in 0..self.rows.len() {
            ats.push(ast_min((self.rows[q] >> 32) as u32, body_n));
        }
        ats.extend_from_slice(&stubs);
        ats.push(tails_end);
        ats.push(ra);
        ats.push(body_n);
        // The loops' first blocks, but rare ones, start at 16-byte boundaries (`Package.align_loops`).
        let mut heads = Vector::<u32>::new();
        if unsafe (*self.pkg).align_loops {
            for q in 1..self.lv.order.len() {
                let k = self.lv.order[q] as usize;
                if self.lv.inner[k] == k as u32 && !self.lv.rare[k] && self.blk_at[k] != NONE && self.blk_at[k] < body_n {
                    heads.push(self.blk_at[k]);
                }
            }
            heads.sort();
        }
        self.c.relax(&mut ats, &heads, lead);
        for q in 0..self.rels.len() {
            self.rels.index_mut(q).at = ats[q];
        }
        let nr = self.rels.len();
        for q in 0..self.rows.len() {
            self.rows[q] = ats[nr + q] as u64 << 32 | self.rows[q] & 0xFFFFFFFF;
        }
        let body_end = ats[ats.len() - 1];
        let framed_at = ats[ats.len() - 2];
        let framed_end = ats[ats.len() - 3];
        let ns = stubs.len();
        for q in 0..ns {
            stubs[q] = ats[ats.len() - 3 - ns + q];
        }
        // Into the object.
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let bn = if self.base {
            format("{}.base", p.spell(ps.name))
        } else {
            String::new()
        };
        let k2 = o.sym(
            if self.base {
                bn.as_str()
            } else {
                p.spell(ps.name)
            },
        );
        let size = lead + self.c.len();
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true)
        } else if ps.cold {
            o.named(self.cold_text(), true)
        } else {
            ob::S_TEXT
        };
        if sec == ob::NOSEC {
            return self.refuse("too many sections");
        }
        let mut fl = ob::SF_FUNC | if ps.linkage == SL_GLOBAL && !self.local && !self.base {
            ob::SF_GLOBAL
        } else {
            0
        };
        if ps.used && !self.base {
            fl |= ob::SF_USED;
        }
        let at = o.define(k2, sec, 4, size, fl);
        o.put(sec, pro.b[0..lead as usize]);
        o.put(sec, self.c.b[0..self.c.b.len()]);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + lead + r.at, r.sym, r.addend);
        }
        if p.debug {
            dw::rows(o, self.b(), k2, size, lead, &self.rows, body_end, 1);
        }
        let c0 = o.cfi.len() as u32;
        if self.win && sw {
            // Shrink-wrapped: the warm code, no entry (a leaf's rule: rsp at the return address); the framed
            // code with its epilogue and sibling calls, its prologue done (0 bytes); each entry stub with
            // its prologue.
            let mut zs = Vector::<u32>::new();
            zs.resize_default(regs.len());
            let mut zx = Vector::<u32>::new();
            zx.resize_default(xregs.len());
            win_unwind(&mut o.cfi, 0, !omit, &zs, &regs, 0, local, &zx, &xregs, xsave, fp, 0);
            o.frames.push(
                ob::OFrame {
                    sym: k2,
                    size: framed_end - framed_at,
                    cfi_at: c0,
                    cfi_len: o.cfi.len() as u32 - c0,
                    off: framed_at,
                },
            );
            for q in 0..ns / 2 {
                let c1 = o.cfi.len() as u32;
                win_unwind(
                    &mut o.cfi,
                    pl,
                    !omit,
                    &push_at,
                    &regs,
                    alloc_end,
                    local,
                    &xsave_at,
                    &xregs,
                    xsave,
                    fp,
                    fp_at,
                );
                let s0 = stubs[2 * q];
                o.frames.push(
                    ob::OFrame {
                        sym: k2,
                        size: stubs[2 * q + 1] - s0,
                        cfi_at: c1,
                        cfi_len: o.cfi.len() as u32 - c1,
                        off: s0,
                    },
                );
            }
            return true;
        }
        if self.win {
            win_unwind(&mut o.cfi, pl, !omit, &push_at, &regs, alloc_end, local, &xsave_at, &xregs, xsave, fp, fp_at);
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0 });
            return true;
        }
        if sw {
            // Shrink-wrapped: the entry's rule (the CFA rsp + 8) up to the framed code, then the frame's (no
            // register pushed).
            cfa_advance(&mut o.cfi, framed_at);
            if !omit {
                o.cfi.push(0x0E);
                o.cfi.push(16);
                o.cfi.push(0x80 | 6);
                o.cfi.push(2);
                o.cfi.push(0x0D);
                o.cfi.push(6);
            } else if local != 0 {
                o.cfi.push(0x0E);
                dw::uleb(&mut o.cfi, 8 + local);
            }
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0 });
            return true;
        }
        if omit {
            // The CFA from rsp: 8 more past each push, with the register at its new bottom, then past the
            // allocation.
            let dr: []u8 = DWARF_REG;
            let mut was: u32 = 0;
            for k in 0..regs.len() {
                cfa_advance(&mut o.cfi, push_at[k] - was);
                was = push_at[k];
                o.cfi.push(0x0E);
                o.cfi.push((16 + 8 * k) as u8);
                o.cfi.push(0x80 | dr[regs[k] as usize]);
                o.cfi.push((2 + k) as u8);
            }
            if local != 0 {
                cfa_advance(&mut o.cfi, alloc_end - was);
                o.cfi.push(0x0E);
                dw::uleb(&mut o.cfi, 8 + 8 * npush + local);
            }
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0 });
            return true;
        }
        // The unwind rules: after `push rbp` the CFA is rsp + 16 with rbp at CFA - 16; after `mov rbp, rsp`
        // it is rbp + 16; each pushed register then sits below.
        o.cfi.push(0x40 | 1);
        o.cfi.push(0x0E);
        o.cfi.push(16);
        o.cfi.push(0x80 | 6);
        o.cfi.push(2);
        o.cfi.push(0x40 | 3);
        o.cfi.push(0x0D);
        o.cfi.push(6);
        if npush != 0 {
            o.cfi.push(0x40 | (push_end - 4) as u8);
            for k in 0..regs.len() {
                o.cfi.push(0x80 | regs[k]);
                o.cfi.push((3 + k) as u8);
            }
        }
        o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0 });
        return true;
    }

    /// Define package data symbol `s` in the object.
    pub(package) fn data(self: &mut Self, s: u32, local: bool) bool {
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let d = p.data[ps.def as usize];
        let tls = ps.kind == SK_TLS;
        let mut zero = d.nrelocs == 0;
        for j in 0..d.nbytes {
            zero = zero && p.bytes[(d.bytes + j) as usize] == 0;
        }
        // COFF has no zero-filled thread-local section: `.tls$` holds every byte.
        zero = zero && !(tls && self.win);
        let sec = if ps.sect != NONE {
            // Its own section: every byte written.
            self.obj().named(p.spell(ps.sect), false)
        } else if tls && zero {
            ob::S_TBSS
        } else if tls {
            ob::S_TDATA
        } else if zero && !d.readonly {
            ob::S_BSS
        } else if d.readonly && d.nrelocs == 0 {
            ob::S_RODATA
        } else if d.readonly {
            ob::S_RELRO
        } else {
            ob::S_DATA
        };
        let o = self.obj();
        let k = o.sym(p.spell(ps.name));
        let mut fl = if local {
            ob::copy_flags(p.split)
        } else if ps.linkage == SL_GLOBAL {
            ob::SF_GLOBAL
        } else {
            0
        };
        if tls {
            fl |= ob::SF_TLS;
        }
        if ps.used {
            fl |= ob::SF_USED;
        }
        if sec == ob::NOSEC {
            self.err = String::from_str("too many sections");
            return false;
        }
        let at = o.define(k, sec, d.align_log2, d.size, fl);
        if sec == ob::S_BSS || sec == ob::S_TBSS {
            return true;
        }
        let bs = p.data_bytes(&d);
        o.put(sec, bs[0..bs.len()]);
        o.pad_to(sec, at + d.size as u64);
        for j in 0..d.nrelocs {
            let r = p.relocs[(d.relocs + j) as usize];
            let ks = o.sym(p.spell(p.syms[r.sym as usize].name));
            o.reloc(sec, x::R_ABS64, (at + r.offset as u64) as u32, ks, r.addend);
        }
        return true;
    }
}

// ---- Vectors ----
//
// A vector lives in its slot. An element-wise operation SSE2 has runs 16 bytes at a time (8 for a vector
// of 8 bytes) in xmm14 and xmm15; any other runs lane by lane on temporaries: an integer lane
// zero-extended, or sign-extended for a signed rule, to 64 bits, a float lane in an xmm register. Mask
// results gather one bit per lane; a lane that traps sets a failure register tested after the lane.

// The SSE2 operation (prefix << 16 | `0F xx`) of element-wise LIR operation `op` on lanes of `lt`, NONE
// without one; `un` set for one operand (`neg`, `not`, `fneg` through a constant).
const fn sse_of_op(op: u8, lt: u8, un: &mut bool) u32 {
    let eb = type_bytes(lt, 8);
    let f = is_float(lt);
    let pd: u32 = if lt == T_F64 {
        0x660000
    } else {
        0
    };
    *un = op == O_NOT || op == O_NEG || op == O_FNEG || op == O_FSQRT;
    if op == O_FADD {
        return pd | 0x0F58;
    }
    if op == O_FSQRT {
        return pd | 0x0F51;
    }
    if op == O_FSUB {
        return pd | 0x0F5C;
    }
    if op == O_FMUL {
        return pd | 0x0F59;
    }
    if op == O_FDIV {
        return pd | 0x0F5E;
    }
    if op == O_FNEG {
        return pd | 0x0F57;
    }
    if f {
        return NONE;
    }
    if op == O_ADD {
        return 0x660000 | padd(eb);
    }
    if op == O_SUB || op == O_NEG {
        return 0x660000 | psub(eb);
    }
    if op == O_MUL && eb == 2 {
        return 0x66_0FD5;
    }
    if (op == O_MULHS || op == O_MULHU) && eb == 2 {
        return if op == O_MULHS {
            0x66_0FE5
        } else {
            0x66_0FE4
        };
    }
    if op == O_AND {
        return 0x66_0FDB;
    }
    if op == O_OR {
        return 0x66_0FEB;
    }
    if op == O_XOR || op == O_NOT {
        return 0x66_0FEF;
    }
    return NONE;
}

// The LIR condition (`C_*`) of lane comparison `c` (`SIMD_CMP_*`) of lanes signed `sg` or of floats `fl`:
// the float ones ordered but `ne`.
const fn simd_cond(c: u8, sg: bool, fl: bool) u16 {
    let k = (c - core::SIMD_CMP_EQ) as usize;
    let f: [u16; 6] = [C_OEQ, C_UNE, C_OLT, C_OLE, C_OGT, C_OGE];
    let s: [u16; 6] = [C_EQ, C_NE, C_SLT, C_SLE, C_SGT, C_SGE];
    let u: [u16; 6] = [C_EQ, C_NE, C_ULT, C_ULE, C_UGT, C_UGE];
    return if fl {
        unsafe f[k]
    } else if sg {
        unsafe s[k]
    } else {
        unsafe u[k]
    };
}

// Whether call layout `lay` passes an argument or the result in a ymm or zmm register: a 32- or 64-byte
// vector part.
fn ymm_parts(lay: &ab::CallLayout) bool {
    for k in 0..lay.parts.len() {
        if lay.parts[k].v && lay.parts[k].size >= 32 {
            return true;
        }
    }
    return false;
}

// The AVX2 form of vector operation `op` on lanes of `lt` (32 bytes): its legacy prefix << 16 | opcode map
// << 8 | opcode, as `sse_of_op`'s plus `vpmulld` (map 0F38); NONE without one.
const fn avx_of_op(op: u8, lt: u8) u32 {
    let eb = type_bytes(lt, 8);
    let pd: u32 = if lt == T_F64 {
        0x660000
    } else {
        0
    };
    if is_float(lt) {
        return if op == O_FADD {
            pd | 0x158
        } else if op == O_FSUB {
            pd | 0x15C
        } else if op == O_FMUL {
            pd | 0x159
        } else if op == O_FDIV {
            pd | 0x15E
        } else if op == O_FNEG {
            pd | 0x157
        } else if op == O_FSQRT {
            pd | 0x151
        } else {
            NONE
        };
    }
    return if op == O_ADD {
        0x660100 | padd(eb) & 0xFF
    } else if op == O_SUB || op == O_NEG {
        0x660100 | psub(eb) & 0xFF
    } else if op == O_MUL && eb == 2 {
        0x6601D5
    } else if op == O_MUL && eb == 4 {
        0x660240
    } else if (op == O_MULHS || op == O_MULHU) && eb == 2 {
        if op == O_MULHS {
            0x6601E5
        } else {
            0x6601E4
        }
    } else if op == O_AND {
        0x6601DB
    } else if op == O_OR {
        0x6601EB
    } else if op == O_XOR || op == O_NOT {
        0x6601EF
    } else {
        NONE
    };
}

// The AVX-512 form of vector operation `op` on lanes of `lt` (64 bytes): EVEX.W << 24 | its legacy prefix
// << 16 | opcode map << 8 | opcode, NONE when it has none (a product of bytes). `neg` is a subtraction
// from 0, `not` a `vpternlogd` (`zmm_reg`), `fneg` an xor of the sign bits (`vxorps`/`vxorpd`, DQ).
const fn evex_of_op(op: u8, lt: u8) u32 {
    let eb = type_bytes(lt, 8);
    if is_float(lt) {
        let pd: u32 = if lt == T_F64 {
            0x1660000
        } else {
            0
        };
        return if op == O_FADD {
            pd | 0x158
        } else if op == O_FSUB {
            pd | 0x15C
        } else if op == O_FMUL {
            pd | 0x159
        } else if op == O_FDIV {
            pd | 0x15E
        } else if op == O_FNEG {
            pd | 0x157
        } else if op == O_FSQRT {
            pd | 0x151
        } else {
            NONE
        };
    }
    let w: u32 = if eb == 8 {
        0x1000000
    } else {
        0
    };
    return if op == O_ADD {
        w | 0x660100 | padd(eb) & 0xFF
    } else if op == O_SUB || op == O_NEG {
        w | 0x660100 | psub(eb) & 0xFF
    } else if op == O_MUL && eb == 2 {
        0x6601D5
    } else if op == O_MUL && eb >= 4 {
        w | 0x660240
    } else if (op == O_MULHS || op == O_MULHU) && eb == 2 {
        if op == O_MULHS {
            0x6601E5
        } else {
            0x6601E4
        }
    } else if op == O_AND {
        0x6601DB
    } else if op == O_OR {
        0x6601EB
    } else if op == O_XOR {
        0x6601EF
    } else if op == O_NOT {
        0x660325
    } else {
        NONE
    };
}

// padd of lanes of `eb` bytes.
const fn padd(eb: u32) u32 {
    if eb == 1 {
        return 0x0FFC;
    }
    if eb == 2 {
        return 0x0FFD;
    }
    if eb == 4 {
        return 0x0FFE;
    }
    return 0x0FD4;
}

// psub of lanes of `eb` bytes.
const fn psub(eb: u32) u32 {
    if eb == 1 {
        return 0x0FF8;
    }
    if eb == 2 {
        return 0x0FF9;
    }
    if eb == 4 {
        return 0x0FFA;
    }
    return 0x0FFB;
}

// The SSE2 operation (as `sse_of_op`) of lane rule `c` (a `SIMD_*` code) on lanes of `lt`, signed `sg`;
// `un` set for one operand. Float min and max keep a NaN's bits, which the packed instructions do not.
const fn sse_of_simd(c: u8, lt: u8, sg: bool, un: &mut bool) u32 {
    let eb = type_bytes(lt, 8);
    *un = false;
    if is_float(lt) {
        if c == core::SIMD_SQRT {
            *un = true;
            if lt == T_F64 {
                return 0x66_0F51;
            }
            return 0x0F51;
        }
        return NONE;
    }
    if c == core::SIMD_WRAP_ADD {
        return 0x660000 | padd(eb);
    }
    if c == core::SIMD_WRAP_SUB {
        return 0x660000 | psub(eb);
    }
    if c == core::SIMD_WRAP_MUL && eb == 2 {
        return 0x66_0FD5;
    }
    if c == core::SIMD_MIN && eb == 2 && sg {
        return 0x66_0FEA;
    }
    if c == core::SIMD_MAX && eb == 2 && sg {
        return 0x66_0FEE;
    }
    if c == core::SIMD_MIN && eb == 1 && !sg {
        return 0x66_0FDA;
    }
    if c == core::SIMD_MAX && eb == 1 && !sg {
        return 0x66_0FDE;
    }
    if c == core::SIMD_WRAP_NEG {
        *un = true;
        return 0x660000 | psub(eb);
    }
    return NONE;
}

// The condition of integer comparison rule `c` (SIMD_CMP_EQ .. SIMD_CMP_GE) after `cmp`.
const fn int_cond(c: u8, sg: bool) u32 {
    if c == core::SIMD_CMP_EQ {
        return x::CC_E;
    }
    if c == core::SIMD_CMP_NE {
        return x::CC_NE;
    }
    if c == core::SIMD_CMP_LT {
        return if sg {
            x::CC_L
        } else {
            x::CC_B
        };
    }
    if c == core::SIMD_CMP_LE {
        return if sg {
            x::CC_LE
        } else {
            x::CC_BE
        };
    }
    if c == core::SIMD_CMP_GT {
        return if sg {
            x::CC_G
        } else {
            x::CC_A
        };
    }
    return if sg {
        x::CC_GE
    } else {
        x::CC_AE
    };
}

// The bits of lane type `lt` (a float) holding the integer `k`.
const fn float_bits(lt: u8, k: u32) u64 {
    if lt == T_F32 {
        return fl::f32_bits(k as f32);
    }
    return fl::f64_bits(k as f64);
}

const fn ast_pick(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

const fn ast_min(a: u32, b: u32) u32 {
    if a < b {
        return a;
    }
    return b;
}

extend Gen {
    // Vector value `v`'s lane `k` of `eb` bytes as a memory operand.
    fn lane(self: &mut Self, v: Value, k: u32, eb: u32) x::Mem {
        let (b, o) = self.mloc(v);
        return x::at(b, (o + (k * eb) as i64) as i32);
    }

    // Load lane `k` of vector `v` (lanes of `lt`) into `r`: a float into an xmm register; an integer
    // zero-extended, or sign-extended (`sg`), to 64 bits; with `raw` any lane's bits into a general one.
    fn ld_lane(self: &mut Self, r: u8, v: Value, k: u32, lt: u8, sg: bool, raw: bool) {
        let eb = type_bytes(lt, 8);
        let m = self.lane(v, k, eb);
        if is_float(lt) && !raw {
            self.c.vload(eb, r - V0, m);
        } else {
            self.c.load(eb, sg && !raw, r, m);
        }
    }

    // Store `r` as lane `k` (lanes of `lt`) of the vector in the slot at rsp + `d`.
    fn st_lane(self: &mut Self, r: u8, d: i64, k: u32, lt: u8, raw: bool) {
        let eb = type_bytes(lt, 8);
        let m = x::at(x::RSP, (d + (k * eb) as i64) as i32);
        if is_float(lt) && !raw {
            self.c.vstore(eb, r - V0, m);
        } else {
            self.c.store(eb, r, m);
        }
    }

    // SSE2 operation `w` over the `nb` bytes (8, or a multiple of 16) of vectors `xv` and `yv` (VNONE for one
    // operand: `neg` subtracts from 0, `not` and `fneg` xor a constant) into the slot at rsp + `d`.
    fn sse(self: &mut Self, w: u32, op: u8, lt: u8, d: i64, xv: Value, yv: Value, nb: u32) {
        let step: u32 = if nb >= 16 {
            16
        } else {
            8
        };
        let pfx = w >> 16;
        let opc = w & 0xFFFF;
        let a = self.vs0 - V0;
        let b = self.vs1 - V0;
        let mut at: u32 = 0;
        // Chunks of 16 bytes: at most 4.
        while at < nb {
            if op == O_NEG {
                self.c.sse_rr(0x66, 0x0FEF, a, a);
                self.c.vload(step, b, self.lane(xv, at, 1));
                self.c.sse_rr(pfx, opc, a, b);
            } else if op == O_NOT || op == O_FNEG {
                self.c.vload(step, a, self.lane(xv, at, 1));
                self.splat_const(b, op, lt);
                self.c.sse_rr(pfx, opc, a, b);
            } else {
                self.c.vload(step, a, self.lane(xv, at, 1));
                if yv != VNONE {
                    self.c.vload(step, b, self.lane(yv, at, 1));
                    self.c.sse_rr(pfx, opc, a, b);
                } else {
                    self.c.sse_rr(pfx, opc, a, a);
                }
            }
            self.c.vstore(step, a, x::at(x::RSP, (d + at as i64) as i32));
            at += step;
        }
    }

    // AVX2 operation `w` (`avx_of_op`) of 32-byte vectors `xv` and `yv` (VNONE for one operand: `neg`
    // subtracts from 0, `not` xors all ones, `fneg` the sign bits) into `i`: the three-operand VEX.256
    // form.
    fn avx_reg(self: &mut Self, w: u32, op: u8, lt: u8, i: u32, xv: Value, yv: Value) {
        let pfx = w >> 16;
        let mm = w >> 8 & 0xFF;
        let opc = w & 0xFF;
        let rx = self.vec_use(xv, self.vs0) - V0;
        if yv == VNONE {
            let rd = self.vec_def(i) - V0;
            let s = self.vs1 - V0;
            if op == O_NEG {
                self.c.vex_rr(0x66, 1, 0xEF, false, true, s, s, s);
                self.c.vex_rr(pfx, mm, opc, false, true, rd, s, rx);
            } else if op == O_NOT {
                self.c.vex_rr(0x66, 1, 0x76, false, true, s, s, s);
                self.c.vex_rr(pfx, mm, opc, false, true, rd, rx, s);
            } else if op == O_FSQRT {
                self.c.vex_rr(pfx, mm, opc, false, true, rd, 0, rx);
            } else {
                self.ymm_splat64(
                    s,
                    if lt == T_F64 {
                        0x8000000000000000u64
                    } else {
                        0x8000000080000000u64
                    },
                );
                self.c.vex_rr(pfx, mm, opc, false, true, rd, rx, s);
            }
            return;
        }
        let ry = self.vec_use(yv, self.vs1) - V0;
        // A loop's accumulator: the result takes the back edge's parameter register (three operands: it
        // may be either source's).
        let mut r = self.def_shared(i, xv);
        if r == NOREG {
            r = self.def_shared(i, yv);
        }
        if r == NOREG {
            r = self.vec_def(i);
        }
        self.c.vex_rr(pfx, mm, opc, false, true, r - V0, rx, ry);
    }

    // AVX-512 operation `w` (`evex_of_op`) of 64-byte vectors `xv` and `yv` (VNONE for one operand: `neg`
    // subtracts from 0, `not` is `vpternlogd` of the operand alone, `fneg` xors the sign bits) into `i`: the
    // three-operand EVEX.512 form.
    fn zmm_reg(self: &mut Self, w: u32, op: u8, lt: u8, i: u32, xv: Value, yv: Value) {
        let ew = w >> 24 != 0;
        let pfx = w >> 16 & 0xFF;
        let mm = w >> 8 & 0xFF;
        let opc = w & 0xFF;
        let rx = self.vec_use(xv, self.vs0) - V0;
        if yv == VNONE {
            let rd = self.vec_def(i) - V0;
            let s = self.vs1 - V0;
            if op == O_NEG {
                self.c.evex_rr(0x66, 1, 0xEF, false, s, s, s);
                self.c.evex_rr(pfx, mm, opc, ew, rd, s, rx);
            } else if op == O_NOT {
                // vpternlogd 0x33: NOT of the second operand.
                self.c.evex_rr(0x66, 3, 0x25, false, rd, rx, rx);
                self.c.byte(0x33);
            } else if op == O_FSQRT {
                self.c.evex_rr(pfx, mm, opc, ew, rd, 0, rx);
            } else {
                self.zmm_splat64(
                    s,
                    if lt == T_F64 {
                        0x8000000000000000u64
                    } else {
                        0x8000000080000000u64
                    },
                );
                self.c.evex_rr(pfx, mm, opc, ew, rd, rx, s);
            }
            return;
        }
        let ry = self.vec_use(yv, self.vs1) - V0;
        // A loop's accumulator: the result takes the back edge's parameter register (`avx_reg`).
        let mut r = self.def_shared(i, xv);
        if r == NOREG {
            r = self.def_shared(i, yv);
        }
        if r == NOREG {
            r = self.vec_def(i);
        }
        self.c.evex_rr(pfx, mm, opc, ew, r - V0, rx, ry);
    }

    // zmm `r` = every 8-byte lane `x`: through r11, then `vpbroadcastq` (EVEX.512.66.0F38.W1 7C).
    fn zmm_splat64(self: &mut Self, r: u8, x: u64) {
        self.c.mov_ri(S1, x);
        self.c.evex_rr(0x66, 2, 0x7C, true, r, 0, S1);
    }

    // Vector constant `t` into a register for `i`: 0 by `pxor`, all ones by `pcmpeqd` (`vpternlogd` 0xFF
    // for 64 bytes), else a load of its words (`wconst_load`).
    fn wconst_reg(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let mut zero = true;
        let mut ones = true;
        for k in 0..t.b {
            let w = b.words[(t.a + k) as usize];
            zero = zero && w == 0;
            ones = ones && w == ~0u64;
        }
        let nb = type_bytes(t.ty, 8);
        let rd = self.vec_def(i) - V0;
        if nb == 64 {
            if zero {
                self.c.evex_rr(0x66, 1, 0xEF, false, rd, rd, rd);
            } else if ones {
                self.c.evex_rr(0x66, 3, 0x25, false, rd, rd, rd);
                self.c.byte(0xFF);
            } else {
                self.wconst_load(rd, t);
            }
            return;
        }
        if nb == 32 {
            if zero || ones {
                self.c.vex_rr(
                    0x66,
                    1,
                    if zero {
                        0xEFu32
                    } else {
                        0x76u32
                    },
                    false,
                    true,
                    rd,
                    rd,
                    rd,
                );
            } else {
                self.wconst_load(rd, t);
            }
            return;
        }
        if zero || ones {
            self.c.sse_rr(
                0x66,
                if zero {
                    0x0FEFu32
                } else {
                    0x0F76u32
                },
                rd,
                rd,
            );
            return;
        }
        self.wconst_load(rd, t);
    }

    // xmm, ymm or zmm `rd` (its number in the file) = wide constant `t`, loaded from the body's constants
    // (`const_sym`).
    fn wconst_load(self: &mut Self, rd: u8, t: Inst) {
        let b = self.b();
        let k = self.const_sym(b.words[t.a as usize..(t.a + t.b) as usize]);
        self.c.vload(type_bytes(t.ty, 8), rd, x::rip());
        self.reloc_rip(x::R_PC32, k, 0);
    }

    // ymm `r` = every 8-byte lane `x`: through r11 (`vmovq`), then `vpbroadcastq`.
    fn ymm_splat64(self: &mut Self, r: u8, x: u64) {
        self.c.mov_ri(S1, x);
        self.c.vex_rr(0x66, 1, 0x6E, true, false, r, 0, S1);
        self.c.vex_rr(0x66, 2, 0x59, false, true, r, 0, r);
    }

    // `vpermq` 0xD8 of ymm `r`: its 8-byte quarters in the order 0, 2, 1, 3, which puts the even lanes of
    // two in-lane unzips first.
    fn ymm_quarters(self: &mut Self, r: u8) {
        self.c.vex_rr(0x66, 3, 0x00, true, true, r, 0, r);
        self.c.byte(0xD8);
    }

    // `sse` of one register's width on `xv` and `yv` into a register that holds result `i`.
    fn sse_reg(self: &mut Self, w: u32, op: u8, lt: u8, i: u32, xv: Value, yv: Value) {
        let pfx = w >> 16;
        let opc = w & 0xFFFF;
        if op == O_NEG {
            let rb = self.vec_use(xv, self.vs1);
            let rd = self.vec_def(i);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, rd - V0);
            self.c.sse_rr(pfx, opc, rd - V0, rb - V0);
            return;
        }
        let rx = self.vec_use(xv, self.vs0);
        let ry = if yv != VNONE {
            self.vec_use(yv, self.vs1)
        } else {
            NOREG
        };
        // The result over the register the first operand shares with it (`def_shared`) or frees
        // (`def_over`); of a commutative integer operation, over the second's when it alone dies here.
        let comm = op == O_ADD || op == O_MUL || op == O_AND || op == O_OR || op == O_XOR;
        let mut rd = self.def_shared(i, xv);
        if rd == NOREG {
            rd = if comm && yv != VNONE && !self.dies_here(xv) && self.dies_here(yv) {
                self.def_over(i, yv, ry)
            } else {
                self.def_over(i, xv, rx)
            };
        }
        if yv != VNONE && rd == ry && rd != rx {
            // The result's register holds the second operand.
            if comm {
                self.c.sse_rr(pfx, opc, rd - V0, rx - V0);
            } else {
                let s = self.tmp(true);
                self.c.vmov(s - V0, ry - V0);
                self.c.vmov(rd - V0, rx - V0);
                self.c.sse_rr(pfx, opc, rd - V0, s - V0);
            }
            return;
        }
        self.c.vmov(rd - V0, rx - V0);
        if op == O_NOT || op == O_FNEG {
            self.splat_const(self.vs1 - V0, op, lt);
            self.c.sse_rr(pfx, opc, rd - V0, self.vs1 - V0);
        } else if yv != VNONE {
            self.c.sse_rr(pfx, opc, rd - V0, ry - V0);
        } else {
            self.c.sse_rr(pfx, opc, rd - V0, rd - V0);
        }
    }

    // An xmm register for vector result `i`, which holds it: its home register (`plan_homes`), else a
    // free one (its home, a slot, comes when it spills).
    fn vec_def(self: &mut Self, i: u32) u8 {
        return self.def(i);
    }

    // Whether the body returns vector `v` whole in one xmm register and an xmm register holds it.
    const fn ret_in_vreg(self: &Self, v: Value) bool {
        return self.va[self.vx(v) as usize].reg != NOREG && self.self_lay.whole_vreg(self.self_lay.ret, self.vt(v));
    }

    // A binary16 conversion (`O_HTOF`, `O_FTOH`, F16C: `Package.half`): the encoding moved into the low
    // word of an xmm register, `vcvtph2ps`; or `vcvtps2ph` rounding to nearest even (immediate 0) into the
    // vector scratch register, then moved out.
    fn half_conv(self: &mut Self, i: u32, t: Inst) {
        if t.op == O_HTOF {
            let ra = self.reg(t.a);
            let rd = self.def(i) - V0;
            self.c.movd_to_x(4, rd, ra);
            self.c.vex_rr(0x66, 2, 0x13, false, false, rd, 0, rd);
            return;
        }
        let ra = self.reg(t.a) - V0;
        let rd = self.def(i);
        let s = self.vs0 - V0;
        self.c.vex_rr(0x66, 3, 0x1D, false, false, ra, 0, s);
        self.c.byte(0);
        self.c.movd_from_x(4, rd, s);
    }

    // Scalar `t.a` into every lane of vector `i` (SSE2): a float's register copied, then `unpcklpd` or
    // `shufps`; an integer moved in by `movd`/`movq`, then `punpcklqdq`, or for narrower lanes `punpcklbw`
    // (bytes) and `pshuflw` (halves) to fill the low dword, which `pshufd` copies. A vector wider than an
    // xmm register stores each lane.
    fn splat(self: &mut Self, i: u32, t: Inst) {
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        if type_bytes(t.ty, 8) == 64 && self.in_reg(t.ty) {
            // AVX-512: `vbroadcastss`/`vbroadcastsd` of a float's register; `vpbroadcastb`/`w`/`d`/`q` of
            // an integer's general register (EVEX.512.66.0F38 18/19 and 7A/7B/7C).
            let rs = self.reg(t.a);
            let rd = self.vec_def(i) - V0;
            if is_float(lt) {
                self.c.evex_rr(0x66, 2, 0x18 + (lt == T_F64) as u32, lt == T_F64, rd, 0, rs - V0);
                return;
            }
            let ops: [u32; 4] = [0x7A, 0x7B, 0x7C, 0x7C];
            self.c.evex_rr(0x66, 2, unsafe ops[eb.trailing_zeros()], eb == 8, rd, 0, rs);
            return;
        }
        if type_bytes(t.ty, 8) == 32 && self.in_reg(t.ty) {
            // AVX2: `vbroadcastss`/`vbroadcastsd` of a float's register; an integer moved in (`vmovd`/
            // `vmovq`), then `vpbroadcastb`/`w`/`d`/`q`.
            let rs = self.reg(t.a);
            let rd = self.vec_def(i) - V0;
            if is_float(lt) {
                self.c.vex_rr(0x66, 2, 0x18 + (lt == T_F64) as u32, false, true, rd, 0, rs - V0);
                return;
            }
            let ops: [u32; 4] = [0x78, 0x79, 0x58, 0x59];
            self.c.vex_rr(0x66, 1, 0x6E, eb == 8, false, rd, 0, rs);
            self.c.vex_rr(0x66, 2, unsafe ops[eb.trailing_zeros()], false, true, rd, 0, rd);
            return;
        }
        if !in_vreg(t.ty) {
            let r = self.reg(t.a);
            let d = self.mdef(i);
            for k in 0..lanes(t.ty) {
                self.st_lane(r, d, k, lt, false);
            }
            return;
        }
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            // A lane of a vector in a register (`lv::FOLD_LANE`): `pshufd` of its dwords, a 4-byte lane's
            // 4 times, an 8-byte lane's pair twice.
            let e = self.b().insts[t.a as usize];
            let rv = self.vec_use(e.a, self.vs0);
            let rd = self.vec_def(i);
            let k = e.aux as u32;
            self.c.sse_rr(0x66, 0x0F70, rd - V0, rv - V0);
            self.c.byte(
                if eb == 4 {
                    (k * 0x55) as u8
                } else {
                    (k * 0xAA + 0x44) as u8
                },
            );
            return;
        }
        let rs = self.reg(t.a);
        let rd = self.vec_def(i);
        let x = rd - V0;
        if is_float(lt) {
            self.c.vmov(x, rs - V0);
            if eb == 8 {
                self.c.sse_rr(0x66, 0x0F14, x, x);
            } else {
                self.c.sse_rr(0, 0x0FC6, x, x);
                self.c.byte(0);
            }
            return;
        }
        self.c.movd_to_x(
            if eb == 8 {
                8u32
            } else {
                4u32
            },
            x,
            rs,
        );
        if eb == 8 {
            self.c.sse_rr(0x66, 0x0F6C, x, x);
            return;
        }
        if eb == 1 {
            self.c.sse_rr(0x66, 0x0F60, x, x);
        }
        if eb <= 2 {
            self.c.sse_rr(0xF2, 0x0F70, x, x);
            self.c.byte(0);
        }
        self.c.sse_rr(0x66, 0x0F70, x, x);
        self.c.byte(0);
    }

    // Vector `v` in an xmm register: its own, else loaded into `scratch`.
    fn vec_use(self: &mut Self, v: Value, scratch: u8) u8 {
        let r = self.va[self.vx(v) as usize].reg;
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let (base, off) = self.mloc(v);
        self.ld(self.vt(v), scratch, x::at(base, off as i32));
        return scratch;
    }

    // `sync` of each operand in `ops` (VNONE: none).
    fn sync_ops(self: &mut Self, ops: &[Value; 4]) {
        for k in 0..4 {
            let v = unsafe ops[k];
            if v != VNONE {
                self.sync(v);
            }
        }
    }

    // Lane-wise comparison `t` into mask `i` (SSE2): `cmpps`/`cmppd`, its operands swapped for `ogt` and
    // `oge`; for integer lanes up to 4 bytes `pcmpeq` or `pcmpgt` (operands swapped for the less-than
    // conditions, an unsigned one over operands whose sign bits are flipped), then NOT for the conditions
    // whose negation it computes. 8-byte integer lanes and a vector outside an xmm register compare each
    // lane.
    fn vcmp(self: &mut Self, i: u32, t: Inst) {
        let vt = self.vt(t.a);
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let c = t.aux;
        let fl = is_float(lt);
        let fswap = c == C_OGT || c == C_OGE;
        let imm: u32 = if c == C_OEQ {
            0
        } else if c == C_OLT || c == C_OGT {
            1
        } else if c == C_OLE || c == C_OGE {
            2
        } else {
            4
        };
        if self.in_reg(vt) && type_bytes(vt, 8) == 64 {
            self.zmm_cmp(i, t, vt);
            return;
        }
        if self.in_reg(vt) && self.avx && (type_bytes(vt, 8) == 32 || !fl && eb == 8) {
            self.avx_cmp(i, t, vt);
            return;
        }
        if in_vreg(vt) && (fl || eb < 8) {
            let _ = self.sse_mask(i, c, t.a, t.b);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let n = lanes(vt);
        if fl {
            let fa = self.tmp(true);
            let fb = self.tmp(true);
            let (xv, yv) = if fswap {
                (t.b, t.a)
            } else {
                (t.a, t.b)
            };
            for k in 0..n {
                self.ld_lane(fa, xv, k, lt, false, false);
                self.ld_lane(fb, yv, k, lt, false, false);
                self.c.sse_rr(0xF3 - (lt == T_F64) as u32, 0x0FC2, fa - V0, fb - V0);
                self.c.byte(imm);
                self.st_lane(fa, d, k, lt, false);
            }
            return;
        }
        let ml = lane_type(mask_type(vt));
        let sg = c >= C_SLT && c <= C_SGE;
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        for k in 0..n {
            self.ld_lane(xr, t.a, k, lt, sg, false);
            self.ld_lane(yr, t.b, k, lt, sg, false);
            self.c.alu_rr(x::CMP, 8, xr, yr);
            self.c.setcc(icond(c), S1);
            self.c.ext(1, 4, false, S1, S1);
            self.c.unary(x::NEG, 8, S1);
            self.st_lane(S1, d, k, ml, false);
        }
    }

    // Lane comparison `c` (a `C_*` condition) of vectors `a` and `b` in xmm registers (float lanes, or
    // integer ones below 8 bytes) into the lane masks of vector `i`, else (`i` NONE) of a temporary register:
    // `cmpps`/`cmppd` (`gt` and `ge` swapped), `pcmpeq`/`pcmpgt` (an unsigned order with the sign bits
    // flipped; `ne`, `ge` and `le` inverted). The register.
    fn sse_mask(self: &mut Self, i: u32, c: u16, a: Value, b: Value) u8 {
        let vt = self.vt(a);
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let fl = is_float(lt);
        let fswap = c == C_OGT || c == C_OGE;
        let imm: u32 = if c == C_OEQ {
            0
        } else if c == C_OLT || c == C_OGT {
            1
        } else if c == C_OLE || c == C_OGE {
            2
        } else {
            4
        };
        let swap = if fl {
            fswap
        } else {
            c == C_SLT || c == C_SGE || c == C_ULT || c == C_UGE
        };
        let (xv, yv) = if swap {
            (b, a)
        } else {
            (a, b)
        };
        let rx = self.vec_use(xv, self.vs0);
        let mut ry = self.vec_use(yv, self.vs1);
        let rd = if i == NONE {
            self.tmp(true)
        } else {
            self.def_over(i, xv, rx)
        };
        if rd == ry && rd != rx {
            // The result's register holds the second operand, which the code reads after it writes it.
            let s = self.tmp(true);
            self.c.vmov(s - V0, ry - V0);
            ry = s;
        }
        if fl {
            self.c.vmov(rd - V0, rx - V0);
            self.c.sse_rr((lt == T_F64) as u32 * 0x66, 0x0FC2, rd - V0, ry - V0);
            self.c.byte(imm);
            return rd;
        }
        let eq = c == C_EQ || c == C_NE;
        let opc = 0x0F64 + eq as u32 * 0x10 + eb.trailing_zeros() as u32;
        if c >= C_ULT {
            // The sign bits flipped: an unsigned order is the signed one.
            let s = self.tmp(true);
            let sb = if eb == 1 {
                0x8080808080808080u64
            } else if eb == 2 {
                0x8000800080008000u64
            } else {
                0x8000000080000000u64
            };
            self.c.mov_ri(S1, sb);
            self.c.movd_to_x(8, s - V0, S1);
            self.c.sse_rr(0x66, 0x0F6C, s - V0, s - V0);
            self.c.vmov(rd - V0, rx - V0);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, s - V0);
            self.c.sse_rr(0x66, 0x0FEF, s - V0, ry - V0);
            self.c.sse_rr(0x66, opc, rd - V0, s - V0);
        } else {
            self.c.vmov(rd - V0, rx - V0);
            self.c.sse_rr(0x66, opc, rd - V0, ry - V0);
        }
        if c == C_NE || c == C_SGE || c == C_SLE || c == C_UGE || c == C_ULE {
            self.c.sse_rr(0x66, 0x0F76, self.vs1 - V0, self.vs1 - V0);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, self.vs1 - V0);
        }
        return rd;
    }

    // Lane test `c` (a comparison, or a float class test: NaN, infinite, finite, sign) of the vectors `ops`
    // in xmm registers (`nb` bytes of lanes of `lt`, signed `sg`) into bitmask `i` (bit k for lane k): the
    // lane masks (`sse_mask`; `nan` as unordered with itself, the magnitude against infinity), then
    // `movmskps`/`movmskpd`/`pmovmskb` (2-byte lanes packed to bytes first; the sign test reads the lanes'
    // sign bits alone), the bits past the lanes cleared.
    fn mask_reg(self: &mut Self, i: u32, c: u8, sg: bool, lt: u8, nb: u32, ops: &[Value; 4]) {
        let eb = type_bytes(lt, 8);
        let fl = is_float(lt);
        let pd = (lt == T_F64) as u32 * 0x66;
        let m = if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
            self.sse_mask(NONE, simd_cond(c, sg, fl), ops[0], ops[1])
        } else if c == core::SIMD_IS_SIGN_NEG {
            self.vec_use(ops[0], self.vs0)
        } else {
            let rx = self.vec_use(ops[0], self.vs0);
            let m = self.tmp(true);
            self.c.vmov(m - V0, rx - V0);
            if c == core::SIMD_IS_NAN {
                // cmpunordps x, x.
                self.c.sse_rr(pd, 0x0FC2, m - V0, rx - V0);
                self.c.byte(3);
            } else {
                // |x| (andps with every bit but the sign), then against infinity: `cmpltps` for finite,
                // `cmpeqps` for infinite.
                let s = self.vs1;
                let (ab, ib) = if pd != 0 {
                    (0x7FFFFFFFFFFFFFFFu64, 0x7FF0000000000000u64)
                } else {
                    (0x7FFFFFFF7FFFFFFFu64, 0x7F8000007F800000u64)
                };
                self.c.mov_ri(S1, ab);
                self.c.movd_to_x(8, s - V0, S1);
                self.c.sse_rr(0x66, 0x0F6C, s - V0, s - V0);
                self.c.sse_rr(0, 0x0F54, m - V0, s - V0);
                self.c.mov_ri(S1, ib);
                self.c.movd_to_x(8, s - V0, S1);
                self.c.sse_rr(0x66, 0x0F6C, s - V0, s - V0);
                self.c.sse_rr(pd, 0x0FC2, m - V0, s - V0);
                self.c.byte(
                    if c == core::SIMD_IS_FINITE {
                        1u32
                    } else {
                        0u32
                    },
                );
            }
            m
        };
        let rd = self.def(i);
        if eb == 2 {
            // packsswb: each lane's mask to a byte.
            let s = self.vs1;
            self.c.vmov(s - V0, m - V0);
            self.c.sse_rr(0x66, 0x0F63, s - V0, s - V0);
            self.c.rr(0x66, 0x0FD7, false, rd, s - V0, false);
        } else if eb == 1 {
            self.c.rr(0x66, 0x0FD7, false, rd, m - V0, false);
        } else {
            self.c.rr(
                if eb == 8 {
                    0x66u32
                } else {
                    0u32
                },
                0x0F50,
                false,
                rd,
                m - V0,
                false,
            );
        }
        let n = nb / eb;
        let all = if eb == 2 {
            8u32
        } else {
            16 / eb
        };
        if n < all {
            self.c.alu_ri(x::AND, 4, rd, ((1u32 << n) - 1) as i32);
        }
    }

    // Lane choice `ops[1]` where bitmask `ops[0]` has the lane's bit, else `ops[2]` (vectors in xmm
    // registers, lanes of `lt`): the bitmask in every lane (bytes: its low byte in the low half, its high
    // byte in the high one), ANDed with each lane's bit and compared equal to it (`pcmpeq`; 8-byte lanes
    // compare their low dwords, copied to the high ones), then `y ^ ((x ^ y) & mask)`.
    fn choose_reg(self: &mut Self, i: u32, ops: &[Value; 4], lt: u8) {
        let eb = type_bytes(lt, 8);
        let rx = self.vec_use(ops[1], self.vs0);
        let ry = self.vec_use(ops[2], self.vs1);
        let rm = self.reg(ops[0]);
        let m = self.tmp(true);
        let w = self.tmp(true);
        let mv = m - V0;
        let wv = w - V0;
        self.c.movd_to_x(4, mv, rm);
        if eb == 1 {
            // punpcklbw, punpcklwd: each byte four times; pshufd 0x50: the low one in the low half.
            self.c.sse_rr(0x66, 0x0F60, mv, mv);
            self.c.sse_rr(0x66, 0x0F61, mv, mv);
            self.c.sse_rr(0x66, 0x0F70, mv, mv);
            self.c.byte(0x50);
        } else if eb == 2 {
            // pshuflw 0, then pshufd 0.
            self.c.sse_rr(0xF2, 0x0F70, mv, mv);
            self.c.byte(0);
            self.c.sse_rr(0x66, 0x0F70, mv, mv);
            self.c.byte(0);
        } else {
            self.c.sse_rr(0x66, 0x0F70, mv, mv);
            self.c.byte(0);
        }
        let (w0, w1) = if eb == 8 {
            (1u64, 2u64)
        } else if eb == 4 {
            (0x0000000200000001u64, 0x0000000800000004u64)
        } else if eb == 2 {
            (0x0008000400020001u64, 0x0080004000200010u64)
        } else {
            (0x8040201008040201u64, 0x8040201008040201u64)
        };
        // Each lane's bit: w0 low, w1 high (punpcklqdq of the two).
        self.c.mov_ri(S1, w0);
        self.c.movd_to_x(8, wv, S1);
        let s = self.tmp(true);
        self.c.mov_ri(S1, w1);
        self.c.movd_to_x(8, s - V0, S1);
        self.c.sse_rr(0x66, 0x0F6C, wv, s - V0);
        // pand, then pcmpeqb/w/d (8-byte lanes: pcmpeqd, then each low dword's result to its high one).
        self.c.sse_rr(0x66, 0x0FDB, mv, wv);
        let k = if eb == 8 {
            2u32
        } else {
            eb.trailing_zeros() as u32
        };
        self.c.sse_rr(0x66, 0x0F74 + k, mv, wv);
        if eb == 8 {
            self.c.sse_rr(0x66, 0x0F70, mv, mv);
            self.c.byte(0xA0);
        }
        let rd = self.vec_def(i);
        // rd = y ^ ((x ^ y) & mask).
        self.c.vmov(rd - V0, rx - V0);
        self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
        self.c.sse_rr(0x66, 0x0FDB, rd - V0, mv);
        self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
    }

    // The even lanes of `t.a ++ t.b` into vector `i` (SSE2, 16 bytes): `shufps` 0x88 of 4-byte lanes,
    // `punpcklqdq` of 8-byte ones; 2- and 1-byte lanes shifted to the low half of their pair, sign-extended,
    // then packed (`packssdw`, `packsswb`), which never saturates. An 8-byte vector or one outside an xmm
    // register moves each lane.
    // Lane interleave `t` (`O_VZIPLO`, `O_VZIPHI`) into vector `i`: the unpack of the lanes' width (`punpckl*`,
    // `punpckh*`) on 16 bytes; on 32 (AVX2) the unpack within each 16-byte half after `vpermq` 0xD8 put the
    // operands' quarters 0, 2, 1, 3; a vector outside a register moves each lane.
    fn vzip(self: &mut Self, i: u32, t: Inst) {
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        let nb = type_bytes(t.ty, 8);
        let hi = t.op == O_VZIPHI;
        // punpckl{bw,wd,dq,qdq}: 60, 61, 62, 6C; the high forms 68, 69, 6A, 6D.
        let mut opc: u32 = 0x6C;
        if eb < 8 {
            opc = 0x60 + eb.trailing_zeros() as u32;
        }
        if hi {
            opc += if eb == 8 {
                1u32
            } else {
                8u32
            };
        }
        if nb == 32 && self.in_reg(t.ty) {
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            let s = self.tmp(true) - V0;
            // `b` first: the result's register may be its.
            self.c.vex_rr(0x66, 3, 0x00, true, true, s, 0, ry);
            self.c.byte(0xD8);
            self.c.vex_rr(0x66, 3, 0x00, true, true, rd, 0, rx);
            self.c.byte(0xD8);
            self.c.vex_rr(0x66, 1, opc, false, true, rd, rd, s);
            return;
        }
        if nb == 16 && in_vreg(t.ty) {
            let rx = self.vec_use(t.a, self.vs0);
            let ry = self.vec_use(t.b, self.vs1);
            let rd = self.vec_def(i);
            self.c.vmov(rd - V0, rx - V0);
            self.c.sse_rr(0x66, 0x0F00 | opc, rd - V0, ry - V0);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let n = lanes(t.ty);
        let h = if hi {
            n / 2
        } else {
            0
        };
        let x = self.tmp(false);
        for k in 0..n / 2 {
            self.ld_lane(x, t.a, h + k, lt, false, true);
            self.st_lane(x, d, 2 * k, lt, true);
            self.ld_lane(x, t.b, h + k, lt, false, true);
            self.st_lane(x, d, 2 * k + 1, lt, true);
        }
    }

    // Whether lane access `t` (`O_VEXTRACT`, `O_VINSERT`) has an SSE2 register form (`vlane`): a lane out
    // of an xmm register but a byte; an f32 into lane 0, an f64 into either lane, a 16-bit lane.
    fn lane_reg(self: &Self, t: Inst) bool {
        if t.op == O_VEXTRACT {
            return in_vreg(self.vt(t.a)) && type_bytes(t.ty, 8) >= 2;
        }
        let lt = lane_type(t.ty);
        return in_vreg(t.ty) && (lt == T_F32 && t.aux == 0 || lt == T_F64 || type_bytes(lt, 8) == 2);
    }

    // Lane access `t` (lane `t.aux`) into `i`. Out of an xmm register (`lane_reg`): the lane moved to lane 0
    // by `pshufd`, then a float as it is, an integer by `movd`, `movq` or `pextrw`. Into one: the vector's
    // copy, then `movss` or `movsd` (lane 0), `unpcklpd` (lane 1 of two), `pinsrw`. Else through memory:
    // the lane's load, or the vector's bytes copied and the lane stored.
    fn vlane(self: &mut Self, i: u32, t: Inst) {
        let k = t.aux as u32;
        let reg = self.lane_reg(t);
        if t.op == O_VEXTRACT {
            let lt = t.ty;
            let eb = type_bytes(lt, 8);
            if !reg {
                let rd = self.def(i);
                self.ld_lane(rd, t.a, k, lt, false, false);
                return;
            }
            let rv = self.vec_use(t.a, self.vs0) - V0;
            if eb == 2 {
                let rd = self.def(i);
                self.c.sse_rr(0x66, 0x0FC5, rd, rv);
                self.c.byte(k);
                return;
            }
            // pshufd: lane k (of 4 bytes, or the two of an 8-byte lane) to lane 0.
            let imm = if eb == 8 {
                2 * k | 2 * k + 1 << 2
            } else {
                k
            };
            if is_float(lt) {
                let rd = self.def(i) - V0;
                if k == 0 {
                    self.c.vmov(rd, rv);
                } else {
                    self.c.sse_rr(0x66, 0x0F70, rd, rv);
                    self.c.byte(imm);
                }
                return;
            }
            let mut s = rv;
            if k != 0 {
                s = self.vs1 - V0;
                self.c.sse_rr(0x66, 0x0F70, s, rv);
                self.c.byte(imm);
            }
            let rd = self.def(i);
            self.c.movd_from_x(eb, rd, s);
            return;
        }
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        if !reg {
            let (sb, so) = self.mloc(t.a);
            let rs = self.reg(t.b);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, sb, so, type_bytes(t.ty, 8));
            self.st_lane(rs, d, k, lt, false);
            return;
        }
        let mut rs = self.reg(t.b);
        let ra = self.vec_use(t.a, self.vs0) - V0;
        let rd = self.vec_def(i) - V0;
        if is_float(lt) && rs - V0 == rd {
            // The scalar shares the result's register: kept in the second scratch across the copy.
            self.c.vmov(self.vs1 - V0, rd);
            rs = self.vs1;
        }
        self.c.vmov(rd, ra);
        if eb == 2 {
            self.c.sse_rr(0x66, 0x0FC4, rd, rs);
            self.c.byte(k);
        } else if lt == T_F32 {
            self.c.sse_rr(0xF3, 0x0F10, rd, rs - V0);
        } else if k == 0 {
            self.c.sse_rr(0xF2, 0x0F10, rd, rs - V0);
        } else {
            self.c.sse_rr(0x66, 0x0F14, rd, rs - V0);
        }
    }

    // The even lanes of `t.a ++ t.b` into vector `i` (the odd ones for `aux` 1): SHUFPS 0x88 (0xDD),
    // PUNPCKLQDQ (PUNPCKHQDQ); 1- and 2-byte lanes shifted into place, sign-extended and packed (the odd
    // ones only shifted down); a vector outside a register moves each lane.
    fn vunzip(self: &mut Self, i: u32, t: Inst) {
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        let n = lanes(t.ty);
        let odd = t.aux != 0;
        let sel: u32 = if odd {
            0xDD
        } else {
            0x88
        };
        if type_bytes(t.ty, 8) == 64 && self.in_reg(t.ty) {
            // AVX-512: as AVX2 in each 16-byte block, which leaves the 8-byte quarters of the result's
            // first operand and second operand alternating; `vpermq` 0xD8 pairs them in each 32-byte half,
            // and `vshufi64x2` 0xD8 puts the blocks in the order 0, 2, 1, 3.
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            if eb == 4 {
                self.c.evex_rr(0, 1, 0xC6, false, rd, rx, ry);
                self.c.byte(sel);
            } else if eb == 8 {
                self.c.evex_rr(0x66, 1, 0x6C + odd as u32, true, rd, rx, ry);
            } else {
                let s = self.tmp(true) - V0;
                let sh: u32 = if eb == 1 {
                    0x71
                } else {
                    0x72
                };
                for (r, a) in [(rd, rx), (s, ry)] {
                    if odd {
                        self.c.evex_rr(0x66, 1, sh, false, 4, r, a);
                    } else {
                        self.c.evex_rr(0x66, 1, sh, false, 6, r, a);
                        self.c.byte(eb * 8);
                        self.c.evex_rr(0x66, 1, sh, false, 4, r, r);
                    }
                    self.c.byte(eb * 8);
                }
                self.c.evex_rr(
                    0x66,
                    1,
                    if eb == 1 {
                        0x63u32
                    } else {
                        0x6Bu32
                    },
                    false,
                    rd,
                    rd,
                    s,
                );
            }
            self.c.evex_rr(0x66, 3, 0x00, true, rd, 0, rd);
            self.c.byte(0xD8);
            self.c.evex_rr(0x66, 3, 0x43, true, rd, rd, rd);
            self.c.byte(0xD8);
            return;
        }
        if type_bytes(t.ty, 8) == 32 && self.in_reg(t.ty) {
            // AVX2: the in-lane forms (`vshufps`, `vpunpcklqdq`, shifts and packs) unzip each 16-byte half;
            // `vpermq` then puts the halves' even lanes in order.
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            if eb == 4 {
                self.c.vex_rr(0, 1, 0xC6, false, true, rd, rx, ry);
                self.c.byte(sel);
            } else if eb == 8 {
                self.c.vex_rr(0x66, 1, 0x6C + odd as u32, false, true, rd, rx, ry);
            } else {
                let s = self.tmp(true) - V0;
                let sh: u32 = if eb == 1 {
                    0x71
                } else {
                    0x72
                };
                for (r, a) in [(rd, rx), (s, ry)] {
                    if odd {
                        self.c.vex_rr(0x66, 1, sh, false, true, 4, r, a);
                    } else {
                        self.c.vex_rr(0x66, 1, sh, false, true, 6, r, a);
                        self.c.byte(eb * 8);
                        self.c.vex_rr(0x66, 1, sh, false, true, 4, r, r);
                    }
                    self.c.byte(eb * 8);
                }
                self.c.vex_rr(
                    0x66,
                    1,
                    if eb == 1 {
                        0x63u32
                    } else {
                        0x6Bu32
                    },
                    false,
                    true,
                    rd,
                    rd,
                    s,
                );
            }
            self.ymm_quarters(rd);
            return;
        }
        if in_vreg(t.ty) && type_bytes(t.ty, 8) == 16 {
            let rx = self.vec_use(t.a, self.vs0);
            let ry = self.vec_use(t.b, self.vs1);
            let rd = self.vec_def(i);
            if eb >= 4 {
                self.c.vmov(rd - V0, rx - V0);
                if eb == 4 {
                    self.c.sse_rr(0, 0x0FC6, rd - V0, ry - V0);
                    self.c.byte(sel);
                } else {
                    self.c.sse_rr(0x66, 0x0F6C + odd as u32, rd - V0, ry - V0);
                }
                return;
            }
            // psllw/pslld and psraw/psrad by the lane's bits (66 0F 71/72 /6 and /4 ib), then the pack.
            let s = self.tmp(true);
            let sh: u32 = if eb == 1 {
                0x0F71
            } else {
                0x0F72
            };
            self.c.vmov(rd - V0, rx - V0);
            self.c.vmov(s - V0, ry - V0);
            for r in [rd, s] {
                if !odd {
                    self.c.sse_rr(0x66, sh, 6, r - V0);
                    self.c.byte(eb * 8);
                }
                self.c.sse_rr(0x66, sh, 4, r - V0);
                self.c.byte(eb * 8);
            }
            self.c.sse_rr(
                0x66,
                if eb == 1 {
                    0x0F63u32
                } else {
                    0x0F6Bu32
                },
                rd - V0,
                s - V0,
            );
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let xr = self.tmp(false);
        for k in 0..n {
            let j = 2 * k + t.aux as u32;
            if j < n {
                self.ld_lane(xr, t.a, j, lt, false, true);
            } else {
                self.ld_lane(xr, t.b, j - n, lt, false, true);
            }
            self.st_lane(xr, d, k, lt, true);
        }
    }

    // `vcmp` with AVX-512 of 64-byte vectors: `vcmpps`/`vcmppd` or `vpcmp[u]b`/`w`/`d`/`q` into k1, whose
    // bits `vpmovm2b`/`w`/`d`/`q` turn into lanes of all ones or zeros.
    fn zmm_cmp(self: &mut Self, i: u32, t: Inst, vt: u8) {
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let c = t.aux;
        let rx = self.vec_use(t.a, self.vs0) - V0;
        let ry = self.vec_use(t.b, self.vs1) - V0;
        let rd = self.vec_def(i) - V0;
        if is_float(lt) {
            // EQ_OQ, LT_OS, LE_OS, GT_OS, GE_OS, NEQ_UQ.
            let imm: u32 = if c == C_OEQ {
                0
            } else if c == C_OLT {
                1
            } else if c == C_OLE {
                2
            } else if c == C_OGT {
                0x0E
            } else if c == C_OGE {
                0x0D
            } else {
                4
            };
            let d = lt == T_F64;
            self.c.evex_rr(d as u32 * 0x66, 1, 0xC2, d, 1, rx, ry);
            self.c.byte(imm);
        } else {
            // EQ, LT, LE, NE, NLT, NLE.
            let imm: u32 = if c == C_EQ {
                0
            } else if c == C_NE {
                4
            } else if c == C_SLT || c == C_ULT {
                1
            } else if c == C_SLE || c == C_ULE {
                2
            } else if c == C_SGE || c == C_UGE {
                5
            } else {
                6
            };
            let opc = if eb <= 2 {
                0x3Fu32
            } else {
                0x1Fu32
            } - (c >= C_ULT) as u32;
            self.c.evex_rr(0x66, 3, opc, eb == 2 || eb == 8, 1, rx, ry);
            self.c.byte(imm);
        }
        let m = if eb <= 2 {
            0x28u32
        } else {
            0x38u32
        };
        self.c.evex_rr(0xF3, 2, m, eb == 2 || eb == 8, rd, 0, 1);
    }

    // `vcmp` with AVX2 (VEX.128 or VEX.256): as the SSE2 form, `vpcmpeqq`/`vpcmpgtq` for 8-byte lanes.
    fn avx_cmp(self: &mut Self, i: u32, t: Inst, vt: u8) {
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let l = type_bytes(vt, 8) == 32;
        let c = t.aux;
        let fl = is_float(lt);
        let swap = if fl {
            c == C_OGT || c == C_OGE
        } else {
            c == C_SLT || c == C_SGE || c == C_ULT || c == C_UGE
        };
        let (xv, yv) = if swap {
            (t.b, t.a)
        } else {
            (t.a, t.b)
        };
        let rx = self.vec_use(xv, self.vs0) - V0;
        let ry = self.vec_use(yv, self.vs1) - V0;
        let rd = self.vec_def(i) - V0;
        if fl {
            let imm: u32 = if c == C_OEQ {
                0
            } else if c == C_OLT || c == C_OGT {
                1
            } else if c == C_OLE || c == C_OGE {
                2
            } else {
                4
            };
            self.c.vex_rr((lt == T_F64) as u32 * 0x66, 1, 0xC2, false, l, rd, rx, ry);
            self.c.byte(imm);
            return;
        }
        let eq = c == C_EQ || c == C_NE;
        let (mm, opc) = if eb == 8 {
            (
                2u32,
                if eq {
                    0x29u32
                } else {
                    0x37u32
                }
            )
        } else {
            (
                1u32,
                if eq {
                    0x74u32
                } else {
                    0x64u32
                } + eb.trailing_zeros() as u32
            )
        };
        if c >= C_ULT {
            // The sign bits flipped: an unsigned order is the signed one.
            let s = self.tmp(true) - V0;
            let sb = if eb == 1 {
                0x8080808080808080u64
            } else if eb == 2 {
                0x8000800080008000u64
            } else if eb == 4 {
                0x8000000080000000u64
            } else {
                0x8000000000000000u64
            };
            self.ymm_splat64(s, sb);
            self.c.vex_rr(0x66, 1, 0xEF, false, l, rd, s, rx);
            self.c.vex_rr(0x66, 1, 0xEF, false, l, s, s, ry);
            self.c.vex_rr(0x66, mm, opc, false, l, rd, rd, s);
        } else {
            self.c.vex_rr(0x66, mm, opc, false, l, rd, rx, ry);
        }
        if c == C_NE || c == C_SGE || c == C_SLE || c == C_UGE || c == C_ULE {
            let o = self.vs1 - V0;
            self.c.vex_rr(0x66, 1, 0x76, false, l, o, o, o);
            self.c.vex_rr(0x66, 1, 0xEF, false, l, rd, rd, o);
        }
    }

    // Lane select `t` into vector `i`: `c ^ ((b ^ c) & mask)` (SSE2), the inner part in a temporary when
    // `c` is in a register, so the result may take `c`'s (a loop's accumulator: `def_over`); a vector
    // outside an xmm register selects each lane's bits the same way.
    fn vsel(self: &mut Self, i: u32, t: Inst) {
        if type_bytes(t.ty, 8) == 64 && self.in_reg(t.ty) {
            // AVX-512: the mask copied into the result, then `vpternlogq` 0xCA (the first operand's bit
            // chooses the second's or the third's).
            let rm = self.vec_use(t.a, self.vs0);
            let rx = self.vec_use(t.b, self.vs1) - V0;
            let s = self.tmp(true);
            let ry = self.vec_use(t.c, s) - V0;
            let rd = self.vec_def(i);
            self.move_reg(t.ty, rd, rm);
            self.c.evex_rr(0x66, 3, 0x25, true, rd - V0, rx, ry);
            self.c.byte(0xCA);
            return;
        }
        // A zero side: the other side under the mask (`pand`) or under its complement (`pandn`).
        let zc = self.zero_vec(t.c);
        if (zc || self.zero_vec(t.b)) && (in_vreg(t.ty) || type_bytes(t.ty, 8) == 32 && self.in_reg(t.ty)) {
            let ymm = type_bytes(t.ty, 8) == 32;
            let rm = self.vec_use(t.a, self.vs0) - V0;
            let ro = self.vec_use(
                if zc {
                    t.b
                } else {
                    t.c
                },
                self.vs1,
            ) - V0;
            let rd = self.vec_def(i) - V0;
            let opc: u32 = if zc {
                0xDB
            } else {
                0xDF
            };
            if ymm || self.avx {
                self.c.vex_rr(0x66, 1, opc, false, ymm, rd, rm, ro);
            } else if rd == ro && !zc {
                let s = self.tmp(true) - V0;
                self.c.vmov(s, rm);
                self.c.sse_rr(0x66, 0x0F00 | opc, s, ro);
                self.c.vmov(rd, s);
            } else if rd == ro {
                self.c.sse_rr(0x66, 0x0FDB, rd, rm);
            } else {
                self.c.vmov(rd, rm);
                self.c.sse_rr(0x66, 0x0F00 | opc, rd, ro);
            }
            return;
        }
        if type_bytes(t.ty, 8) == 32 && self.in_reg(t.ty) {
            let rm = self.vec_use(t.a, self.vs0) - V0;
            let rx = self.vec_use(t.b, self.vs1) - V0;
            let s = self.tmp(true);
            let ry = self.vec_use(t.c, s) - V0;
            if ry != s - V0 {
                let rd = self.def_over(i, t.c, ry + V0) - V0;
                self.c.vex_rr(0x66, 1, 0xEF, false, true, s - V0, rx, ry);
                self.c.vex_rr(0x66, 1, 0xDB, false, true, s - V0, s - V0, rm);
                self.c.vex_rr(0x66, 1, 0xEF, false, true, rd, ry, s - V0);
                return;
            }
            let rd = self.vec_def(i) - V0;
            self.c.vex_rr(0x66, 1, 0xEF, false, true, rd, rx, ry);
            self.c.vex_rr(0x66, 1, 0xDB, false, true, rd, rd, rm);
            self.c.vex_rr(0x66, 1, 0xEF, false, true, rd, rd, ry);
            return;
        }
        if in_vreg(t.ty) {
            let rm = self.vec_use(t.a, self.vs0);
            let rx = self.vec_use(t.b, self.vs1);
            let s = self.tmp(true);
            let ry = self.vec_use(t.c, s);
            if ry != s {
                let rd = self.def_over(i, t.c, ry);
                if rd == ry {
                    self.c.vmov(s - V0, rx - V0);
                    self.c.sse_rr(0x66, 0x0FEF, s - V0, ry - V0);
                    self.c.sse_rr(0x66, 0x0FDB, s - V0, rm - V0);
                    self.c.sse_rr(0x66, 0x0FEF, rd - V0, s - V0);
                    return;
                }
                self.c.vmov(rd - V0, rx - V0);
                self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
                self.c.sse_rr(0x66, 0x0FDB, rd - V0, rm - V0);
                self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
                return;
            }
            let rd = self.vec_def(i);
            self.c.vmov(rd - V0, rx - V0);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
            self.c.sse_rr(0x66, 0x0FDB, rd - V0, rm - V0);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, ry - V0);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        self.sync(t.c);
        let d = self.mdef(i);
        let lt = lane_type(t.ty);
        let m = self.tmp(false);
        let xr = self.tmp(false);
        for k in 0..lanes(t.ty) {
            self.ld_lane(m, t.a, k, lt, false, true);
            self.ld_lane(xr, t.b, k, lt, false, true);
            self.ld_lane(S1, t.c, k, lt, false, true);
            self.c.alu_rr(x::XOR, 8, xr, S1);
            self.c.alu_rr(x::AND, 8, xr, m);
            self.c.alu_rr(x::XOR, 8, xr, S1);
            self.st_lane(xr, d, k, lt, true);
        }
    }

    // xmm `r` = every lane of `lt` holding the constant of `op`: all ones for `not`, the sign bit for
    // `fneg`.
    fn splat_const(self: &mut Self, r: u8, op: u8, lt: u8) {
        if op == O_NOT {
            self.c.sse_rr(0x66, 0x0F76, r, r);
            return;
        }
        let sb = if lt == T_F64 {
            0x8000000000000000u64
        } else {
            0x8000000080000000u64
        };
        self.c.mov_ri(S1, sb);
        self.c.movd_to_x(8, r, S1);
        self.c.sse_rr(0x66, 0x0F6C, r, r);
    }

    // `mk` |= 1 << `k` when condition `cc` holds, through r11.
    fn mask_bit(self: &mut Self, mk: u8, cc: u32, k: u32) {
        self.c.setcc(cc, S1);
        self.c.ext(1, 4, false, S1, S1);
        if k != 0 {
            self.c.shift_ri(x::SHL, 8, S1, k);
        }
        self.c.alu_rr(x::OR, 8, mk, S1);
    }

    // `fr` |= 1 when condition `cc` holds, through r11 (a lane's failure).
    fn fail_if(self: &mut Self, fr: u8, cc: u32) {
        self.c.setcc(cc, S1);
        self.c.ext(1, 4, false, S1, S1);
        self.c.alu_rr(x::OR, 4, fr, S1);
    }

    // Vector arithmetic: O_ADD .. O_NOT, O_FADD .. O_FNEG and O_FSQRT on vectors.
    fn vec_arith(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let nb = type_bytes(t.ty, 8);
        let mut un = false;
        let w = sse_of_op(op, lt, &mut un);
        let y = if un {
            VNONE
        } else {
            t.b
        };
        let div = op >= O_SDIV && op <= O_UREM;
        let sh = op == O_SHL || op == O_LSHR || op == O_ASHR;
        if div {
            self.vacate(x::RAX);
            self.vacate(x::RDX);
        }
        let k = self.lv.vshimm(self.b(), t);
        if k != NONE {
            // `psll`, `psrl`, `psra` by an immediate (66 0F 71, 72, 73 by the lanes' bytes; /6, /2, /4).
            let eb = type_bytes(lt, 8);
            let opc: u32 = if eb == 2 {
                0x71
            } else if eb == 4 {
                0x72
            } else {
                0x73
            };
            let dg: u8 = if op == O_SHL {
                6
            } else if op == O_LSHR {
                2
            } else {
                4
            };
            let rx = self.vec_use(t.a, self.vs0);
            if self.avx {
                let rd = self.vec_def(i) - V0;
                self.c.vex_rr(0x66, 1, opc, false, nb == 32, dg, rd, rx - V0);
            } else {
                let rd = self.def_over(i, t.a, rx) - V0;
                self.c.vmov(rd, rx - V0);
                self.c.sse_rr(0x66, 0x0F00 | opc, dg, rd);
            }
            self.c.byte(k);
            return true;
        }
        if self.shift_reg(t) {
            // AVX2: `vpsllv`, `vpsrlv`, `vpsrav` (VEX.66.0F38 47, 45, 46) shift each lane by its own amount.
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            let opc: u32 = if op == O_SHL {
                0x47
            } else if op == O_LSHR {
                0x45
            } else {
                0x46
            };
            self.c.vex_rr(0x66, 2, opc, type_bytes(lt, 8) == 8, nb == 32, rd, rx, ry);
            return true;
        }
        if sh {
            self.vacate(x::RCX);
        }
        if w != NONE && in_vreg(t.ty) {
            self.sse_reg(w, op, lt, i, t.a, y);
            return true;
        }
        if op == O_MUL && type_bytes(lt, 8) == 4 && nb == 16 && in_vreg(t.ty) {
            self.mul_lanes32(i, t);
            return true;
        }
        if (op == O_MULHS || op == O_MULHU) && type_bytes(lt, 8) == 4 && self.in_reg(t.ty) {
            self.mulh_lanes32(i, t, nb);
            return true;
        }
        if nb == 32 && self.in_reg(t.ty) && avx_of_op(op, lt) != NONE {
            self.avx_reg(avx_of_op(op, lt), op, lt, i, t.a, y);
            return true;
        }
        if nb == 64 && self.in_reg(t.ty) && evex_of_op(op, lt) != NONE {
            self.zmm_reg(evex_of_op(op, lt), op, lt, i, t.a, y);
            return true;
        }
        self.sync(t.a);
        if y != VNONE {
            self.sync(y);
        }
        let d = self.mdef(i);
        if w != NONE && nb >= 8 {
            self.sse(w, op, lt, d, t.a, y, nb);
            return true;
        }
        if is_float(lt) {
            let dd = lt == T_F64;
            let fa = self.tmp(true);
            let fb = self.tmp(true);
            for k in 0..n {
                self.ld_lane(fa, t.a, k, lt, false, false);
                if op == O_FNEG {
                    self.fsign(dd, false, fa);
                } else if op == O_FSQRT {
                    self.c.sse_rr(fpfx(dd), 0x0F51, fa - V0, fa - V0);
                } else {
                    self.ld_lane(fb, t.b, k, lt, false, false);
                    self.c.sse_rr(fpfx(dd), fop(op), fa - V0, fb - V0);
                }
                self.st_lane(fa, d, k, lt, false);
            }
            return true;
        }
        let sg = op == O_ASHR || op == O_SDIV || op == O_SREM || op == O_MULHS;
        let xr = self.tmp(false);
        let yr = if sh {
            x::RCX
        } else {
            self.tmp(false)
        };
        for k in 0..n {
            self.ld_lane(xr, t.a, k, lt, sg, false);
            if !un {
                self.ld_lane(yr, t.b, k, lt, sg, false);
            }
            if op == O_MULHS || op == O_MULHU {
                // The extended lanes' 64-bit product, shifted down by the lane's bits.
                self.c.imul_rr(8, xr, yr);
                self.c.shift_ri(
                    if sg {
                        x::SAR
                    } else {
                        x::SHR
                    },
                    8,
                    xr,
                    type_bits(lt, 8),
                );
            } else {
                self.int_lane(op, xr, yr);
            }
            self.st_lane(xr, d, k, lt, false);
        }
        return true;
    }

    // The high halves of the products of the 32-bit lanes of vectors `t.a` and `t.b` (`O_MULHS`,
    // `O_MULHU`, `nb` bytes in registers) into `i`: the even lanes' 64-bit products (`pmuludq`, signed
    // `pmuldq` from SSE4.1) and the odd lanes' (both operands' odd lanes moved down first; `t.b`'s own when
    // its lanes are all one value, a splat), merged: the even products shifted down 32 and `vpblendd` (AVX2),
    // or under SSE `pshufd` of the even products' high halves and `pblendw` of the odd ones' (SSE4.1), else
    // both `pshufd` to the low lanes and `punpckldq`. Signed without SSE4.1: the unsigned high product less
    // each operand where the other is negative.
    fn mulh_lanes32(self: &mut Self, i: u32, t: Inst, nb: u32) {
        let sg = t.op == O_MULHS;
        let b = self.b();
        let same = (t.b & (VPARAM | VFLAG)) == 0 && b.insts[t.b as usize].op == O_SPLAT || splat_of(b, t.b).is_some();
        let rx = self.vec_use(t.a, self.vs0) - V0;
        let ry = self.vec_use(t.b, self.vs1) - V0;
        let e = self.tmp(true) - V0;
        let ao = self.tmp(true) - V0;
        let bo = if same && nb != 64 {
            ry
        } else {
            self.tmp(true) - V0
        };
        if nb == 64 {
            // EVEX.512.66: `vpmuldq` (0F38.W1 28), `vpmuludq` (0F.W1 F4), `vpsrlq` (0F.W1 73 /2), `vpandq`,
            // `vporq` (0F.W1 DB, EB).
            let (mm, opc) = if sg {
                (2u32, 0x28u32)
            } else {
                (1u32, 0xF4u32)
            };
            self.c.evex_rr(0x66, mm, opc, true, e, rx, ry);
            self.c.evex_rr(0x66, 1, 0x73, true, 2, e, e);
            self.c.byte(32);
            self.c.evex_rr(0x66, 1, 0x73, true, 2, ao, rx);
            self.c.byte(32);
            let yo = if same {
                ry
            } else {
                self.c.evex_rr(0x66, 1, 0x73, true, 2, bo, ry);
                self.c.byte(32);
                bo
            };
            self.c.evex_rr(0x66, mm, opc, true, ao, ao, yo);
            self.zmm_splat64(bo, 0xFFFFFFFF00000000);
            self.c.evex_rr(0x66, 1, 0xDB, true, ao, ao, bo);
            let rd = self.vec_def(i) - V0;
            self.c.evex_rr(0x66, 1, 0xEB, true, rd, ao, e);
            return;
        }
        if self.avx {
            // VEX: `vpmuldq` (66.0F38 28) or `vpmuludq` (66.0F F4), `vpsrlq` (66.0F 73 /2), `vpblendd`
            // (66.0F3A.W0 02) of the odd lanes.
            let l = nb == 32;
            let (mm, opc) = if sg {
                (2u32, 0x28u32)
            } else {
                (1u32, 0xF4u32)
            };
            self.c.vex_rr(0x66, mm, opc, false, l, e, rx, ry);
            self.c.vex_rr(0x66, 1, 0x73, false, l, 2, e, e);
            self.c.byte(32);
            self.c.vex_rr(0x66, 1, 0x73, false, l, 2, ao, rx);
            self.c.byte(32);
            if !same {
                self.c.vex_rr(0x66, 1, 0x73, false, l, 2, bo, ry);
                self.c.byte(32);
            }
            self.c.vex_rr(0x66, mm, opc, false, l, ao, ao, bo);
            let rd = self.vec_def(i) - V0;
            self.c.vex_rr(0x66, 3, 0x02, false, l, rd, e, ao);
            self.c.byte(0xAA);
            return;
        }
        // SSE: `pshufd` (66 0F 70) [1, 1, 3, 3] moves the odd lanes down, `pmuldq` (66 0F 38 28) or `pmuludq`
        // (66 0F F4) multiplies, `pblendw` (66 0F 3A 0E) or `pshufd` [1, 3, 2, 3] and `punpckldq` (66 0F 62)
        // merge.
        let sse41 = unsafe (*self.pkg).sse41;
        let smul = sg && sse41;
        let mo = if smul {
            0x0F3828u32
        } else {
            0x0FF4
        };
        self.c.sse_rr(0x66, 0x0F70, ao, rx);
        self.c.byte(0xF5);
        if !same {
            self.c.sse_rr(0x66, 0x0F70, bo, ry);
            self.c.byte(0xF5);
        }
        self.c.sse_rr(0x66, mo, ao, bo);
        // Over `t.a` when it dies here and no correction reads it after.
        let rd = if sg && !smul {
            self.vec_def(i)
        } else {
            self.def_over(i, t.a, rx + V0)
        } - V0;
        self.c.vmov(rd, rx);
        self.c.sse_rr(0x66, mo, rd, ry);
        if sse41 {
            self.c.sse_rr(0x66, 0x0F70, rd, rd);
            self.c.byte(0xF5);
            self.c.sse_rr(0x66, 0x0F3A0E, rd, ao);
            self.c.byte(0xCC);
        } else {
            self.c.sse_rr(0x66, 0x0F70, rd, rd);
            self.c.byte(0xED);
            self.c.sse_rr(0x66, 0x0F70, ao, ao);
            self.c.byte(0xED);
            self.c.sse_rr(0x66, 0x0F62, rd, ao);
        }
        if sg && !smul {
            // Less `b` where `a` is negative (`psrad` 66 0F 72 /4 by 31, `pand`, `psubd` 66 0F FA), and
            // `a` where `b` is.
            self.c.vmov(e, rx);
            self.c.sse_rr(0x66, 0x0F72, 4, e);
            self.c.byte(31);
            self.c.sse_rr(0x66, 0x0FDB, e, ry);
            self.c.sse_rr(0x66, 0x0FFA, rd, e);
            self.c.vmov(e, ry);
            self.c.sse_rr(0x66, 0x0F72, 4, e);
            self.c.byte(31);
            self.c.sse_rr(0x66, 0x0FDB, e, rx);
            self.c.sse_rr(0x66, 0x0FFA, rd, e);
        }
    }

    // Product `i` (`t`) of two 16-byte vectors of 32-bit lanes in xmm registers: `vpmulld` with AVX2,
    // `pmulld` with SSE4.1; else (SSE2 has no such product) the even lanes' 64-bit products (`pmuludq`),
    // the odd lanes' after `pshufd` moves them down, and the low halves of both interleaved (`pshufd`,
    // `punpckldq`; clang's lowering).
    // The odd lanes take the vector scratch registers the operands leave (a register of its own only when
    // both hold operands): `ta` from the start, `tb` once the operands are read but `y` (which it may
    // overwrite in its scratch register, its last read).
    fn mul_lanes32(self: &mut Self, i: u32, t: Inst) {
        let rx = self.vec_use(t.a, self.vs0) - V0;
        let ry = self.vec_use(t.b, self.vs1) - V0;
        if self.avx {
            let rd = self.vec_def(i) - V0;
            self.c.vex_rr(0x66, 2, 0x40, false, false, rd, rx, ry);
            return;
        }
        if unsafe (*self.pkg).sse41 {
            // `pmulld` (66 0F 38 40), over `t.a` when it dies here.
            let rd = self.def_over(i, t.a, rx + V0) - V0;
            self.c.vmov(rd, rx);
            self.c.sse_rr(0x66, 0x0F3840, rd, ry);
            return;
        }
        let (s0, s1) = (self.vs0 - V0, self.vs1 - V0);
        let ta = if rx != s0 && ry != s0 {
            s0
        } else if rx != s1 && ry != s1 {
            s1
        } else {
            self.tmp(true) - V0
        };
        let tb = if ry == s0 || ry == s1 {
            ry
        } else if ta != s0 {
            s0
        } else {
            s1
        };
        self.c.sse_rr(0x66, 0x0F70, ta, rx);
        self.c.byte(0xF5);
        let rd = self.def_pass(i, t.a) - V0;
        self.c.vmov(rd, rx);
        self.c.sse_rr(0x66, 0x0FF4, rd, ry);
        // A multiplier of one value in every lane (a splat) has its odd lanes in its even ones already.
        let b = self.b();
        let splat = (t.b & (VPARAM | VFLAG)) == 0 && (b.insts[t.b as usize].op == O_SPLAT || splat_of(b, t.b).is_some());
        if splat {
            self.c.sse_rr(0x66, 0x0FF4, ta, ry);
        } else {
            self.c.sse_rr(0x66, 0x0F70, tb, ry);
            self.c.byte(0xF5);
            self.c.sse_rr(0x66, 0x0FF4, ta, tb);
        }
        self.c.sse_rr(0x66, 0x0F70, rd, rd);
        self.c.byte(0xE8);
        self.c.sse_rr(0x66, 0x0F70, ta, ta);
        self.c.byte(0xE8);
        self.c.sse_rr(0x66, 0x0F62, rd, ta);
    }

    // `xr` = `xr` op `yr` on 64-bit registers (integer LIR operation `op`): a division through rdx:rax and
    // a shift by cl (`yr` is rcx), which the caller vacated.
    fn int_lane(self: &mut Self, op: u8, xr: u8, yr: u8) {
        if op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR {
            self.c.alu_rr(alu_of(op), 8, xr, yr);
        } else if op == O_MUL {
            self.c.imul_rr(8, xr, yr);
        } else if op >= O_SDIV && op <= O_UREM {
            let sgn = op == O_SDIV || op == O_SREM;
            self.c.mov_rr(8, x::RAX, xr);
            if sgn {
                self.c.cqo(8);
            } else {
                self.c.alu_rr(x::XOR, 4, x::RDX, x::RDX);
            }
            self.c.unary(
                if sgn {
                    x::IDIV
                } else {
                    x::DIV
                },
                8,
                yr,
            );
            self.c.mov_rr(
                8,
                xr,
                if op == O_SDIV || op == O_UDIV {
                    x::RAX
                } else {
                    x::RDX
                },
            );
        } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
            assert(yr == x::RCX, "x64gen: a lane shift count outside rcx");
            self.c.shift_cl(
                if op == O_SHL {
                    x::SHL
                } else if op == O_LSHR {
                    x::SHR
                } else {
                    x::SAR
                },
                8,
                xr,
            );
        } else if op == O_NEG {
            self.c.unary(x::NEG, 8, xr);
        } else {
            self.c.unary(x::NOT, 8, xr);
        }
    }

    // A lane-wise conversion of vector `v` (lanes of `fl`, signed `fs`) to the lanes of `tl` (signed `ts`)
    // into the slot of instruction `i`; a float to an integer saturates unless `unchecked`.
    fn vec_conv(self: &mut Self, i: u32, v: Value, fl: u8, fs: bool, tl: u8, ts: bool, unchecked: bool) {
        let n = lanes(self.vt(v));
        let d = self.mdef(i);
        let fa = self.tmp(true);
        let xr = self.tmp(false);
        let tb = type_bits(tl, 8);
        for k in 0..n {
            if is_float(fl) {
                self.ld_lane(fa, v, k, fl, false, false);
            } else {
                self.ld_lane(xr, v, k, fl, fs, false);
            }
            if is_float(fl) && is_float(tl) {
                if fl != tl {
                    self.c.sse_rr(
                        if fl == T_F32 {
                            0xF3u32
                        } else {
                            0xF2u32
                        },
                        0x0F5A,
                        fa - V0,
                        fa - V0,
                    );
                }
                self.st_lane(fa, d, k, tl, false);
            } else if is_float(tl) {
                if !fs && type_bits(fl, 8) == 64 {
                    self.u2f(tl == T_F64, fa, xr);
                } else {
                    self.c.cvtsi2f(tl == T_F64, 8, fa - V0, xr);
                }
                self.st_lane(fa, d, k, tl, false);
            } else if is_float(fl) {
                self.f2i(fl == T_F64, ts, tb, !unchecked, xr, fa);
                self.st_lane(xr, d, k, tl, false);
            } else {
                self.st_lane(xr, d, k, tl, false);
            }
        }
    }

    // Whether vector shift `t` has an AVX2 form in registers (`vec_arith`): lanes of 4 or 8 bytes, but an
    // arithmetic shift of 8-byte lanes.
    fn shift_reg(self: &Self, t: Inst) bool {
        let eb = type_bytes(lane_type(t.ty), 8);
        return self.avx && is_vec(t.ty) && (t.op == O_SHL || t.op == O_LSHR || t.op == O_ASHR && eb == 4) && (eb == 4 || eb == 8) && type_bytes(
            t.ty,
            8,
        ) <= 32 && self.in_reg(t.ty);
    }

    // Whether vector conversion `t` has a form in vector registers (`vconv_reg`): an integer to twice or
    // half its width, i32 to f32 and back, f32 to f64 and back; SSE2 for vectors of 8 or 16 bytes, AVX2
    // when one is of 32.
    fn conv_reg(self: &Self, t: Inst) bool {
        let op = t.op;
        if !is_vec(t.ty) || op < O_SEXT || op > O_UITOFP {
            return false;
        }
        let ft = self.vt(t.a);
        let wide = self.avx && type_bytes(t.ty, 8) <= 32 && type_bytes(ft, 8) <= 32 && type_bytes(t.ty, 8) + type_bytes(
            ft,
            8,
        ) >= 48;
        if !(in_vreg(t.ty) && in_vreg(ft)) && !wide {
            return false;
        }
        let fl = lane_type(self.vt(t.a));
        let tl = lane_type(t.ty);
        let fb = type_bytes(fl, 8);
        let tb = type_bytes(tl, 8);
        return (op == O_SEXT || op == O_ZEXT) && is_int(fl) && tb == 2 * fb || op == O_TRUNC && is_int(fl) && fb == 2 * tb || op == O_SITOFP && fl == T_I32 && tl == T_F32 || op == O_FPTOSI && fl == T_F32 && tl == T_I32 || op == O_FPEXT && fl == T_F32 && tl == T_F64 || op == O_FPTRUNC && fl == T_F64 && tl == T_F32;
    }

    // Vector conversion `t` (`conv_reg`) in xmm registers. An integer widens from its low half through
    // `punpckl` with zeros or its sign (`pcmpgt` against 0), and narrows through `pshufd` (64-bit lanes) or
    // a shift of each lane's low half to its top and back with its sign, then a signed pack, which is then
    // exact; i32 and f32 through `cvtdq2ps` and `cvttps2dq`, f32 and f64 through `cvtps2pd` and `cvtpd2ps`.
    // A float to an integer saturates unless unchecked: a lane at or above 2^31 (`cmpleps`) flips the
    // indefinite 0x80000000 to 0x7FFFFFFF, a NaN lane (`cmpordps`) is 0.
    fn vconv_reg(self: &mut Self, i: u32, t: Inst) {
        let op = t.op;
        let fb = type_bytes(lane_type(self.vt(t.a)), 8);
        let tb = type_bytes(lane_type(t.ty), 8);
        let rx = self.vec_use(t.a, self.vs0) - V0;
        let rd = self.vec_def(i) - V0;
        let lg = fb.trailing_zeros() as u32;
        if type_bytes(t.ty, 8) == 32 || type_bytes(self.vt(t.a), 8) == 32 {
            self.vconv_ymm(t, fb, tb, rd, rx);
            return;
        }
        if op == O_SEXT && lane_mask(self.b(), t.a, lv::MASK_DEPTH) {
            // A mask's lanes are all ones or 0: each lane beside itself (`punpckl`).
            self.c.vmov(rd, rx);
            self.c.sse_rr(0x66, 0x0F60 + lg, rd, rd);
        } else if (op == O_SEXT || op == O_ZEXT) && unsafe (*self.pkg).sse41 {
            // SSE4.1 `pmovsx`, `pmovzx` (66 0F38 20 bw, 21 bd, 22 bq, 23 wd, 24 wq, 25 dq; + 0x10 for zeros).
            let base: u32 = if fb == 1 {
                0x20 + tb.trailing_zeros() as u32 - 1
            } else if fb == 2 {
                0x23 + tb.trailing_zeros() as u32 - 2
            } else {
                0x25
            };
            let z: u32 = if op == O_ZEXT {
                0x10
            } else {
                0
            };
            self.c.sse_rr(0x66, 0x0F3800 + base + z, rd, rx);
        } else if op == O_SEXT || op == O_ZEXT {
            let s = self.tmp(true) - V0;
            self.c.sse_rr(0x66, 0x0FEF, s, s);
            if op == O_SEXT {
                self.c.sse_rr(0x66, 0x0F64 + lg, s, rx);
            }
            self.c.vmov(rd, rx);
            self.c.sse_rr(0x66, 0x0F60 + lg, rd, s);
        } else if op == O_TRUNC && fb == 8 {
            self.c.sse_rr(0x66, 0x0F70, rd, rx);
            self.c.byte(0x08);
        } else if op == O_TRUNC {
            let sh: u32 = if fb == 2 {
                0x0F71
            } else {
                0x0F72
            };
            self.c.vmov(rd, rx);
            self.c.sse_rr(0x66, sh, 6, rd);
            self.c.byte(tb * 8);
            self.c.sse_rr(0x66, sh, 4, rd);
            self.c.byte(tb * 8);
            self.c.sse_rr(
                0x66,
                if fb == 2 {
                    0x0F63u32
                } else {
                    0x0F6Bu32
                },
                rd,
                rd,
            );
        } else if op == O_SITOFP {
            self.c.sse_rr(0, 0x0F5B, rd, rx);
        } else if op == O_FPEXT {
            self.c.sse_rr(0, 0x0F5A, rd, rx);
        } else if op == O_FPTRUNC {
            self.c.sse_rr(0x66, 0x0F5A, rd, rx);
        } else {
            self.c.sse_rr(0xF3, 0x0F5B, rd, rx);
            if t.aux != CV_UNCHECKED {
                let s = self.tmp(true) - V0;
                self.c.mov_ri(S1, 0x4F000000);
                self.c.movd_to_x(4, s, S1);
                self.c.sse_rr(0x66, 0x0F70, s, s);
                self.c.byte(0);
                self.c.sse_rr(0, 0x0FC2, s, rx);
                self.c.byte(2);
                self.c.sse_rr(0x66, 0x0FEF, rd, s);
                self.c.vmov(s, rx);
                self.c.sse_rr(0, 0x0FC2, s, s);
                self.c.byte(7);
                self.c.sse_rr(0x66, 0x0FDB, rd, s);
            }
        }
    }

    // `vconv_reg` with AVX2, a vector of 32 bytes in ymm register `rx` or `rd`: an integer widens through
    // `vpmovsx` or `vpmovzx` (VEX.66.0F38 20, 23 or 25 by its bytes, + 0x10 for zeros), narrows as with
    // SSE2 in each 16-byte half, then `vpermq` 0x08 joins the halves' low quarters; the float forms as with
    // SSE2 on ymm registers (`vpbroadcastd` splats 2^31).
    fn vconv_ymm(self: &mut Self, t: Inst, fb: u32, tb: u32, rd: u8, rx: u8) {
        let op = t.op;
        if op == O_SEXT || op == O_ZEXT {
            let z: u32 = if op == O_ZEXT {
                0x10
            } else {
                0
            };
            // bw, wd, dq: 20, 23, 25.
            let w: u32 = if fb == 1 {
                0x20
            } else if fb == 2 {
                0x23
            } else {
                0x25
            };
            self.c.vex_rr(0x66, 2, w + z, false, true, rd, 0, rx);
        } else if op == O_TRUNC {
            if fb == 8 {
                self.c.vex_rr(0x66, 1, 0x70, false, true, rd, 0, rx);
                self.c.byte(0x08);
            } else {
                let sh: u32 = if fb == 2 {
                    0x71
                } else {
                    0x72
                };
                self.c.vex_rr(0x66, 1, sh, false, true, 6, rd, rx);
                self.c.byte(tb * 8);
                self.c.vex_rr(0x66, 1, sh, false, true, 4, rd, rd);
                self.c.byte(tb * 8);
                self.c.vex_rr(
                    0x66,
                    1,
                    if fb == 2 {
                        0x63u32
                    } else {
                        0x6Bu32
                    },
                    false,
                    true,
                    rd,
                    rd,
                    rd,
                );
            }
            self.c.vex_rr(0x66, 3, 0x00, true, true, rd, 0, rd);
            self.c.byte(0x08);
        } else if op == O_SITOFP {
            self.c.vex_rr(0, 1, 0x5B, false, true, rd, 0, rx);
        } else if op == O_FPEXT {
            self.c.vex_rr(0, 1, 0x5A, false, true, rd, 0, rx);
        } else if op == O_FPTRUNC {
            self.c.vex_rr(0x66, 1, 0x5A, false, true, rd, 0, rx);
        } else {
            self.c.vex_rr(0xF3, 1, 0x5B, false, true, rd, 0, rx);
            if t.aux != CV_UNCHECKED {
                let s = self.tmp(true) - V0;
                self.c.mov_ri(S1, 0x4F000000);
                self.c.movd_to_x(4, s, S1);
                self.c.vex_rr(0x66, 2, 0x58, false, true, s, 0, s);
                self.c.vex_rr(0, 1, 0xC2, false, true, s, s, rx);
                self.c.byte(2);
                self.c.vex_rr(0, 1, 0x57, false, true, rd, rd, s);
                self.c.vex_rr(0, 1, 0xC2, false, true, s, rx, rx);
                self.c.byte(7);
                self.c.vex_rr(0, 1, 0x54, false, true, rd, rd, s);
            }
        }
    }

    // A vector conversion of LIR (O_SEXT .. O_UITOFP on vectors).
    fn vec_convert(self: &mut Self, i: u32, t: Inst) {
        let op = t.op;
        let fl = lane_type(self.vt(t.a));
        let tl = lane_type(t.ty);
        let fs = op == O_SEXT || op == O_SITOFP;
        let ts = op == O_FPTOSI;
        self.vec_conv(i, t.a, fl, fs, tl, ts, t.aux == CV_UNCHECKED);
    }

    // A portable vector operation (`O_VOP`).
    fn vop(self: &mut Self, i: u32, t: Inst) bool {
        if self.lv.pfold[i as usize] {
            return true; // each equality with 0 tests the mask's sign bits (`lv::FOLD_ANY`, `compare`)
        }
        let code = (t.aux & VOP_CODE) as u32;
        let sg = (t.aux & VOP_SIGNED) != 0;
        let dsg = (t.aux & VOP_DSIGNED) != 0;
        let mut ops: [Value; 4] = [VNONE, VNONE, VNONE, VNONE];
        let mut tys: [u8; 4] = [T_NONE, T_NONE, T_NONE, T_NONE];
        for k in 0..ast_min(t.b, 4) {
            let v = self.b().pool[(t.a + k) as usize];
            unsafe ops[k as usize] = v;
            unsafe tys[k as usize] = self.vt(v);
        }
        if lv::lane_perm(self.b(), t) != 0 && self.idiom_reg(t) {
            self.reverse_lanes(i, t, ops[0]);
            return true;
        }
        // `vlanes` and `vmem` sync their operands past their register forms; every other form here first.
        let simd = code >= core::OP_SIMD && code < core::OP_CMP_LANES;
        let rule = if simd {
            core::simd_op((code - core::OP_SIMD) as u8).rule
        } else {
            0u8
        };
        if (!simd || rule == core::SR_MLOAD || rule == core::SR_MSTORE || rule == core::SR_REDUCE || rule == core::SR_DOT || rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED) && !self.reduce_reg(
            t,
        ) {
            self.sync_ops(&ops);
        }
        if code == core::OP_CAST {
            let fl = lane_type(tys[0]);
            let tl = lane_type(t.ty);
            let fb = type_bits(fl, 8);
            let tb = type_bits(tl, 8);
            // An integer widens by its source's sign; every other integer change keeps the low bits.
            let ext = is_float(fl) || is_float(tl) || fb < tb && sg;
            self.vec_conv(i, ops[0], fl, sg && ext, tl, dsg, (t.aux & VOP_UNCHECKED) != 0);
            return true;
        }
        if code == core::OP_REM {
            self.vec_call2(i, ops[0], ops[1], VNONE, "fmod");
            return true;
        }
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            let lt = lane_type(tys[0]);
            let n = lanes(tys[0]);
            let lb = type_bits(lt, 8);
            self.vacate(x::RCX);
            let cnt = self.reg(ops[1]);
            self.c.mov_rr(4, x::RCX, cnt);
            self.c.alu_ri(x::AND, 4, x::RCX, (lb - 1) as i32);
            let xr = self.tmp(false);
            let d = self.mdef(i);
            let sop = if code == core::OP_SHL_SCALAR {
                x::SHL
            } else if sg {
                x::SAR
            } else {
                x::SHR
            };
            for k in 0..n {
                self.ld_lane(xr, ops[0], k, lt, sg, false);
                self.c.shift_cl(sop, 8, xr);
                self.st_lane(xr, d, k, lt, false);
            }
            return true;
        }
        assert(code >= core::OP_SIMD && code < core::OP_CMP_LANES, "x64gen: a vector operation the verifier rejects");
        let c = (code - core::OP_SIMD) as u8;
        if rule == core::SR_LOAD || rule == core::SR_STORE {
            self.vmem(i, t, c, &ops, &tys);
            return true;
        }
        if rule == core::SR_MLOAD || rule == core::SR_MSTORE {
            self.vmem_masked(i, t, c, &ops, &tys);
            return true;
        }
        if rule == core::SR_REDUCE || rule == core::SR_DOT {
            self.vreduce(i, t, c, sg, &ops, &tys);
            return true;
        }
        if rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED {
            self.vrearrange(i, t, c, &ops, &tys);
            return true;
        }
        if self.float_reg(t) {
            self.float_lanes(i, t, c, &ops);
            return true;
        }
        if c == core::SIMD_FMA && is_float(lane_type(tys[0])) {
            self.vec_call2(i, ops[0], ops[1], ops[2], "fma");
            return true;
        }
        self.vlanes(i, t, c, sg, dsg, &ops, &tys);
        return true;
    }

    // Float vectors through C's `<name>` (`fmod`, `fma`; the `f`-suffixed form for f32) lane by lane, the
    // operands `xv`, `yv` and `zv` (VNONE: none) in xmm0..xmm2.
    fn vec_call2(self: &mut Self, i: u32, xv: Value, yv: Value, zv: Value, name: str) {
        let lt = lane_type(self.vt(xv));
        let n = lanes(self.vt(xv));
        let d = self.mdef(i);
        self.spill_for_call();
        let fname = if lt == T_F32 {
            format("{}f", name)
        } else {
            String::from_str(name)
        };
        for k in 0..n {
            self.ld_lane(V0, xv, k, lt, false, false);
            self.ld_lane(V0 + 1, yv, k, lt, false, false);
            if zv != VNONE {
                self.ld_lane(V0 + 2, zv, k, lt, false, false);
            }
            self.call_sym(&fname);
            self.st_lane(V0, d, k, lt, false);
        }
    }

    // The lane rules (`SR_VEC`, `SR_MASK`, `SR_CHOOSE`, `SR_LANES`, `SR_CHANGED`, `SR_BITCAST`, `SR_HALF`,
    // `SR_CONCAT`, `SR_ANY`) of `SIMD_*` code `c`, as the evaluator's `vlanes`.
    fn vlanes(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, dsg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let rule = core::simd_op(c).rule;
        let vt = if rule == core::SR_CHOOSE {
            tys[1]
        } else if rule == core::SR_ANY {
            t.ty
        } else {
            tys[0]
        };
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let lb = eb * 8;
        let n = lanes(vt);
        let nb = n * eb;
        let fl = is_float(lt);
        // A mask (`Mask<N>`, one bit per lane) of vectors in xmm registers, and a choice by one: lane masks.
        let lane_test = c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE && (fl || eb < 8) || fl && (c == core::SIMD_IS_NAN || c == core::SIMD_IS_INF || c == core::SIMD_IS_FINITE || c == core::SIMD_IS_SIGN_NEG);
        if n >= 2 && in_vreg(vt) && (rule == core::SR_MASK && lane_test || rule == core::SR_CHOOSE) {
            if rule == core::SR_CHOOSE {
                self.choose_reg(i, ops, lt);
            } else {
                self.mask_reg(i, c, sg, lt, nb, ops);
            }
            return;
        }
        if rule == core::SR_BITCAST || rule == core::SR_HALF || rule == core::SR_CONCAT {
            let d = self.mdef(i);
            let rb = type_bytes(t.ty, 8);
            let (b0, o0) = self.mloc(ops[0]);
            if rule == core::SR_CONCAT {
                let (b1, o1) = self.mloc(ops[1]);
                self.copy_mem(x::RSP, d, b0, o0, nb);
                self.copy_mem(x::RSP, d + nb as i64, b1, o1, nb);
            } else if c == core::SIMD_HIGH_HALF {
                self.copy_mem(x::RSP, d, b0, o0 + rb as i64, rb);
            } else {
                self.copy_mem(x::RSP, d, b0, o0, rb);
            }
            return;
        }
        if self.idiom_reg(t) {
            self.idiom_lanes(i, t, c, sg, ops);
            return;
        }
        if self.ext_reg(t) {
            let lo = c == core::SIMD_MIN;
            let rx = self.vec_use(ops[0], self.vs0) - V0;
            let ry = self.vec_use(ops[1], self.vs1) - V0;
            let zx = self.zero_vec(ops[0]);
            if nb == 16 && sg && (lb == 8 || lb == 32) && !self.avx && !unsafe (*self.pkg).sse41 && (zx || self.zero_vec(
                ops[1],
            )) {
                // Signed, against zero (no `pmaxsd` or `pmaxsb` before SSE4.1): the other operand's lanes
                // under the mask of those that win, `x > 0` for the maximum, `0 > x` for the minimum.
                let (z, x, xv) = if zx {
                    (rx, ry, ops[1])
                } else {
                    (ry, rx, ops[0])
                };
                let gt: u32 = if lb == 8 {
                    0x0F64
                } else {
                    0x0F66
                };
                let m = self.tmp(true) - V0;
                let rd = self.def_over(i, xv, x + V0) - V0;
                if lo {
                    self.c.vmov(m, z);
                    self.c.sse_rr(0x66, gt, m, x);
                } else {
                    self.c.vmov(m, x);
                    self.c.sse_rr(0x66, gt, m, z);
                }
                if rd != x {
                    self.c.vmov(rd, x);
                }
                self.c.sse_rr(0x66, 0x0FDB, rd, m);
                return;
            }
            if nb == 32 {
                let r = self.vec_def(i) - V0;
                self.lane_ext(lo, sg, lb, true, r, rx, ry);
            } else {
                // The operation commutes: the result may take the register either operand shares with it
                // (a loop's accumulator, `def_shared`) or that dies here, which then holds that operand.
                let mut r = self.def_shared(i, ops[0]);
                if r == NOREG {
                    r = self.def_shared(i, ops[1]);
                }
                if r == NOREG {
                    r = if self.dies_here(ops[1]) && !self.dies_here(ops[0]) {
                        self.def_over(i, ops[1], ry + V0)
                    } else {
                        self.def_over(i, ops[0], rx + V0)
                    };
                }
                let rd = r - V0;
                if rd == ry {
                    self.lane_ext(lo, sg, lb, false, rd, rd, rx);
                } else {
                    self.c.vmov(rd, rx);
                    self.lane_ext(lo, sg, lb, false, rd, rd, ry);
                }
            }
            return;
        }
        let mask = rule == core::SR_MASK || rule == core::SR_CHANGED;
        let mut un = false;
        let w = if mask || rule != core::SR_VEC || nb < 8 {
            NONE
        } else {
            sse_of_simd(c, lt, sg, &mut un)
        };
        // The operation `sse_reg` sees: a negation, a unary one, a difference (which does not commute), or
        // another binary one (which does).
        let o = if un && c == core::SIMD_WRAP_NEG {
            O_NEG
        } else if un {
            O_FADD
        } else if c == core::SIMD_WRAP_SUB {
            O_SUB
        } else {
            O_ADD
        };
        let y = if un {
            VNONE
        } else {
            ops[1]
        };
        if w != NONE && in_vreg(t.ty) {
            self.sse_reg(w, o, lt, i, ops[0], y);
            return;
        }
        self.sync_ops(ops);
        if w != NONE {
            let d = self.mdef(i);
            self.sse(w, o, lt, d, ops[0], y, nb);
            return;
        }
        if !mask && rule == core::SR_VEC && !fl && !sg && (c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS) {
            // The absolute value of an unsigned lane is the lane.
            let d = self.mdef(i);
            let (b0, o0) = self.mloc(ops[0]);
            self.copy_mem(x::RSP, d, b0, o0, nb);
            return;
        }
        let rlt = if mask || !is_vec(t.ty) {
            lt
        } else {
            lane_type(t.ty)
        };
        // The rules that need a fixed register: a shift or rotate count in cl, a 64-bit unsigned product's
        // high half in rdx.
        let shifts = c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR || c == core::SIMD_ROTL || c == core::SIMD_ROTR;
        let mulhi = c == core::SIMD_OVF_MUL && lb == 64 && !sg;
        if shifts {
            self.vacate(x::RCX);
        }
        if mulhi {
            self.vacate(x::RAX);
            self.vacate(x::RDX);
        }
        // Results: the mask register, or the vector's slot.
        let mut mk: u8 = NOREG;
        let mut d: i64 = 0;
        if mask {
            mk = self.def(i);
            self.c.alu_rr(x::XOR, 4, mk, mk);
        } else {
            d = self.mdef(i);
        }
        // Operand 1 as one scalar for every lane: a register read once.
        let scalar1 = rule != core::SR_CHOOSE && tys[1] != T_NONE && !is_vec(tys[1]);
        let s1 = if scalar1 {
            self.reg(ops[1])
        } else {
            NOREG
        };
        let cm = if rule == core::SR_CHOOSE {
            self.reg(ops[0])
        } else {
            NOREG
        };
        let xr = self.tmp(false);
        let yr = if shifts {
            x::RCX
        } else {
            self.tmp(false)
        };
        let traps = !fl && sg && c == core::SIMD_ABS || c == core::SIMD_NARROW_CHECKED;
        // The bit rules read a lane's own bits: zero-extended whatever its sign.
        let xsg = sg && c != core::SIMD_CLZ && c != core::SIMD_POPCNT && c != core::SIMD_ROTL && c != core::SIMD_ROTR;
        let fr = if traps {
            self.tmp(false)
        } else {
            NOREG
        };
        if traps {
            self.c.alu_rr(x::XOR, 4, fr, fr);
        }
        let mut fails = Vector::<u64>::new();
        let (fa, fb, fc) = if fl || c == core::SIMD_CAST_CHANGED {
            (self.tmp(true), self.tmp(true), self.tmp(true))
        } else {
            (NOREG, NOREG, NOREG)
        };
        for k in 0..n {
            if c == core::SIMD_IOTA {
                if fl {
                    self.fconst(fa, lt == T_F64, float_bits(lt, k));
                    self.st_lane(fa, d, k, lt, false);
                } else {
                    self.mov_imm(xr, k, 8);
                    self.st_lane(xr, d, k, lt, false);
                }
                continue;
            }
            if rule == core::SR_CHOOSE {
                self.ld_lane(xr, ops[1], k, lt, false, true);
                self.ld_lane(yr, ops[2], k, lt, false, true);
                self.c.bt_ri(cm, k);
                self.c.cmov(x::CC_AE, 8, xr, yr);
                self.st_lane(xr, d, k, lt, true);
                continue;
            }
            if c == core::SIMD_CAST_CHANGED {
                self.lane_changed(mk, k, ops, tys, sg, dsg, xr, yr, fa, fb);
                continue;
            }
            if fl {
                self.float_rule(c, k, ops, lt, mk, d, xr, yr, fa, fb, fc);
                continue;
            }
            self.ld_lane(xr, ops[0], k, lt, xsg, false);
            if scalar1 {
                self.c.mov_rr(8, yr, s1);
            } else if tys[1] != T_NONE {
                self.ld_lane(yr, ops[1], k, lane_type(tys[1]), sg, false);
            }
            if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
                self.c.alu_rr(x::CMP, 8, xr, yr);
                self.mask_bit(mk, int_cond(c, sg), k);
                continue;
            }
            if c >= core::SIMD_OVF_ADD && c <= core::SIMD_OVF_MUL {
                let cc = self.ovf_lane(c, lb, sg, xr, yr);
                self.mask_bit(mk, cc, k);
                continue;
            }
            self.int_rule(c, lb, sg, rlt, dsg, xr, yr, fr);
            if traps {
                // The first failing lane leaves for its stub.
                self.c.test_rr(4, fr, fr);
                fails.push(self.c.jcc32(x::CC_NE) as u64 << 32 | k as u64);
            }
            self.st_lane(xr, d, k, rlt, false);
        }
        if traps {
            // Past the stubs: each sets its lane and joins the trap.
            let wb = self.c.jmp32();
            let mut joins = Vector::<u32>::with_capacity(fails.len());
            for q in 0..fails.len() {
                self.c.land((fails[q] >> 32) as u32, self.c.len());
                self.c.mov_ri(self.arg(0), fails[q] & 0xFFFFFFFF);
                joins.push(self.c.jmp32());
            }
            for q in 0..joins.len() {
                self.c.land(joins[q], self.c.len());
            }
            self.lane_panic_call(core::lane_trap_msg(core::RV_SIMD, c, false));
            self.c.land(wb, self.c.len());
        }
    }

    // Lane `xr` op `yr` of rule `c` (OVF_ADD .. OVF_MUL, SAT_ADD, SAT_SUB) of `lb`-bit lanes (signed `sg`,
    // extended to 64 bits): the condition that holds when the exact result does not fit the lane; `xr`
    // keeps the wrapped result (the exact one below 64 bits); r11 is spent.
    fn ovf_lane(self: &mut Self, c: u8, lb: u32, sg: bool, xr: u8, yr: u8) u32 {
        let add = c == core::SIMD_OVF_ADD || c == core::SIMD_SAT_ADD;
        let sub = c == core::SIMD_OVF_SUB || c == core::SIMD_SAT_SUB;
        if lb == 64 {
            if add || sub {
                self.c.alu_rr(
                    if add {
                        x::ADD
                    } else {
                        x::SUB
                    },
                    8,
                    xr,
                    yr,
                );
                if sg {
                    return x::CC_O;
                }
                return x::CC_B;
            }
            if sg {
                self.c.imul_rr(8, xr, yr);
                return x::CC_O;
            }
            // rdx:rax, vacated by the caller.
            self.c.mov_rr(8, x::RAX, xr);
            self.c.unary(x::MUL, 8, yr);
            self.c.mov_rr(8, xr, x::RAX);
            return x::CC_O;
        }
        // Narrower lanes: the exact result in 64 bits, compared with its lane's extension.
        if add {
            self.c.alu_rr(x::ADD, 8, xr, yr);
        } else if sub {
            self.c.alu_rr(x::SUB, 8, xr, yr);
        } else {
            self.c.imul_rr(8, xr, yr);
        }
        if sg {
            self.c.ext(lb / 8, 8, true, S1, xr);
            self.c.alu_rr(x::CMP, 8, S1, xr);
        } else {
            self.c.mov_rr(8, S1, xr);
            self.c.shift_ri(x::SHR, 8, S1, lb);
        }
        return x::CC_NE;
    }

    // Integer lane rule `c` on `xr` (and `yr`) of `lb`-bit lanes (signed `sg`, extended to 64 bits): the
    // result lane (of `rlt`, signed `rsg`) in `xr`; a lane that traps sets `fr`. r10 and r11 are spent.
    fn int_rule(self: &mut Self, c: u8, lb: u32, sg: bool, rlt: u8, rsg: bool, xr: u8, yr: u8, fr: u8) {
        if c == core::SIMD_WRAP_ADD || c == core::SIMD_WRAP_SUB || c == core::SIMD_WRAP_MUL {
            let op = if c == core::SIMD_WRAP_ADD {
                O_ADD
            } else if c == core::SIMD_WRAP_SUB {
                O_SUB
            } else {
                O_MUL
            };
            self.int_lane(op, xr, yr);
        } else if c == core::SIMD_WRAP_NEG {
            self.c.unary(x::NEG, 8, xr);
        } else if c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR {
            self.c.alu_ri(x::AND, 4, x::RCX, (lb - 1) as i32);
            self.c.shift_cl(
                if c == core::SIMD_WRAP_SHL {
                    x::SHL
                } else if sg {
                    x::SAR
                } else {
                    x::SHR
                },
                8,
                xr,
            );
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit in r10, before the operation: a signed overflow goes the way of the operand's sign
            // (MAX ^ (y >> 63) for a sum, its complement for a difference), an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1
            } else {
                trunc64(~0u64, lb)
            };
            if sg {
                self.c.mov_rr(8, S0, yr);
                self.c.shift_ri(x::SAR, 8, S0, 63);
                self.c.mov_ri(
                    S1,
                    if add {
                        max
                    } else {
                        ~max
                    },
                );
                self.c.alu_rr(x::XOR, 8, S0, S1);
            } else {
                self.mov_imm(
                    S0,
                    if add {
                        max
                    } else {
                        0
                    },
                    8,
                );
            }
            let cc = self.ovf_lane(c, lb, sg, xr, yr);
            self.c.cmov(cc, 8, xr, S0);
        } else if c == core::SIMD_MIN || c == core::SIMD_MAX {
            self.c.alu_rr(x::CMP, 8, xr, yr);
            let lt_c = if sg {
                x::CC_L
            } else {
                x::CC_B
            };
            self.c.cmov(
                if c == core::SIMD_MIN {
                    x::invert(lt_c)
                } else {
                    lt_c
                },
                8,
                xr,
                yr,
            );
        } else if c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS {
            if c == core::SIMD_ABS {
                // The lowest value has no absolute value in its lane.
                self.c.mov_ri(S0, (1u64 << (lb - 1) as u64).wrapping_neg());
                self.c.alu_rr(x::CMP, 8, xr, S0);
                self.fail_if(fr, x::CC_E);
            }
            self.c.mov_rr(8, S0, xr);
            self.c.unary(x::NEG, 8, S0);
            self.c.cmov(x::CC_NS, 8, xr, S0);
        } else if c == core::SIMD_ABS_DIFF {
            self.c.mov_rr(8, S0, xr);
            self.c.alu_rr(x::SUB, 8, S0, yr);
            self.c.mov_rr(8, S1, yr);
            self.c.alu_rr(x::SUB, 8, S1, xr);
            self.c.alu_rr(x::CMP, 8, xr, yr);
            self.c.mov_rr(8, xr, S1);
            self.c.cmov(
                if sg {
                    x::CC_G
                } else {
                    x::CC_A
                },
                8,
                xr,
                S0,
            );
        } else if c == core::SIMD_CLZ {
            // 64 - lb fewer than the 64-bit count: (lb - 1) - bsr, bsr taken as -1 for 0.
            self.c.bsx(true, 8, xr, xr);
            self.c.mov_ri(S1, 0xFFFFFFFFFFFFFFFF);
            self.c.cmov(x::CC_E, 8, xr, S1);
            self.c.unary(x::NEG, 8, xr);
            self.c.alu_ri(x::ADD, 8, xr, (lb - 1) as i32);
        } else if c == core::SIMD_CTZ {
            if lb < 64 {
                self.c.mov_ri(S1, 1u64 << lb as u64);
                self.c.alu_rr(x::OR, 8, xr, S1);
                self.c.bsx(false, 8, xr, xr);
            } else {
                self.c.bsx(false, 8, xr, xr);
                self.c.mov_ri(S1, 64);
                self.c.cmov(x::CC_E, 8, xr, S1);
            }
        } else if c == core::SIMD_POPCNT {
            self.c.mov_rr(8, yr, xr);
            self.popcount(xr, yr, 8);
        } else if c == core::SIMD_ROTL || c == core::SIMD_ROTR {
            if lb == 64 {
                self.c.shift_cl(
                    if c == core::SIMD_ROTL {
                        x::ROL
                    } else {
                        x::ROR
                    },
                    8,
                    xr,
                );
            } else {
                // (u << k | u >> (lb - k) % lb), or the reverse: the store keeps the lane's bits.
                let (s0, s1) = if c == core::SIMD_ROTL {
                    (x::SHL, x::SHR)
                } else {
                    (x::SHR, x::SHL)
                };
                self.c.alu_ri(x::AND, 4, x::RCX, (lb - 1) as i32);
                self.c.mov_rr(8, S0, xr);
                self.c.shift_cl(s0, 8, S0);
                self.c.unary(x::NEG, 4, x::RCX);
                self.c.alu_ri(x::AND, 4, x::RCX, (lb - 1) as i32);
                self.c.shift_cl(s1, 8, xr);
                self.c.alu_rr(x::OR, 8, xr, S0);
            }
        } else if c == core::SIMD_BITREV {
            self.bitrev(xr);
            if lb < 64 {
                self.c.shift_ri(x::SHR, 8, xr, 64 - lb);
            }
        } else if c == core::SIMD_BSWAP {
            if lb > 8 {
                self.c.bswap(8, xr);
                self.c.shift_ri(x::SHR, 8, xr, 64 - lb);
            }
        } else if c == core::SIMD_NARROW_CHECKED || c == core::SIMD_NARROW_SAT {
            self.narrow_lane(c == core::SIMD_NARROW_SAT, lb, sg, type_bits(rlt, 8), rsg, xr, fr);
        }
    }

    // Reverse the 64 bits of `r`: the bits of each byte swapped in pairs, nibbles and halves, then the
    // bytes (through r10 and r11).
    fn bitrev(self: &mut Self, r: u8) {
        let steps: [(u32, u64); 3] = [(1, 0x5555555555555555), (2, 0x3333333333333333), (4, 0x0F0F0F0F0F0F0F0F)];
        for q in 0..3 {
            let (sh, m) = unsafe steps[q];
            self.c.mov_rr(8, S0, r);
            self.c.shift_ri(x::SHR, 8, S0, sh);
            self.c.mov_ri(S1, m);
            self.c.alu_rr(x::AND, 8, S0, S1);
            self.c.alu_rr(x::AND, 8, r, S1);
            self.c.shift_ri(x::SHL, 8, r, sh);
            self.c.alu_rr(x::OR, 8, r, S0);
        }
        self.c.bswap(8, r);
    }

    // A lane `xr` of `lb` bits (signed `sg`, extended) to `rw` bits (signed `rsg`): saturated (`sat`), else
    // kept when it fits and failing `fr` when not. r10 and r11 are spent.
    fn narrow_lane(self: &mut Self, sat: bool, lb: u32, sg: bool, rw: u32, rsg: bool, xr: u8, fr: u8) {
        let rmax = if rsg {
            (1u64 << (rw - 1) as u64) - 1
        } else {
            trunc64(~0u64, rw)
        };
        let rmin = if rsg {
            (1u64 << (rw - 1) as u64).wrapping_neg()
        } else {
            0u64
        };
        // `xr` above 2^63 only for an unsigned 64-bit lane: its top bit, taken as a value, is positive.
        let huge_u = !sg && lb == 64;
        if !sat {
            // Fits: the range test in 64 bits, a value above 2^63 only into an unsigned 64-bit lane.
            if rsg {
                if rw < 64 {
                    self.c.ext(rw / 8, 8, true, S0, xr);
                    self.c.alu_rr(x::CMP, 8, S0, xr);
                    self.fail_if(fr, x::CC_NE);
                }
                if huge_u {
                    self.c.test_rr(8, xr, xr);
                    self.fail_if(fr, x::CC_S);
                }
            } else {
                if sg {
                    self.c.test_rr(8, xr, xr);
                    self.fail_if(fr, x::CC_S);
                }
                if rw < 64 {
                    self.c.mov_rr(8, S0, xr);
                    self.c.shift_ri(x::SHR, 8, S0, rw);
                    self.fail_if(fr, x::CC_NE);
                }
            }
            return;
        }
        // Saturate: a negative signed value into an unsigned lane is 0, then the range clamps.
        if sg && !rsg {
            self.c.alu_rr(x::XOR, 4, S0, S0);
            self.c.test_rr(8, xr, xr);
            self.c.cmov(x::CC_S, 8, xr, S0);
        }
        self.c.mov_ri(S0, rmax);
        self.c.alu_rr(x::CMP, 8, xr, S0);
        self.c.cmov(
            if sg {
                x::CC_G
            } else {
                x::CC_A
            },
            8,
            xr,
            S0,
        );
        if sg && rsg {
            self.c.mov_ri(S0, rmin);
            self.c.alu_rr(x::CMP, 8, xr, S0);
            self.c.cmov(x::CC_L, 8, xr, S0);
        }
    }

    // Float lane rule `c` on lane `k` (lanes of `lt`): the result lane stored at rsp + `d`, or a mask bit
    // into `mk`.
    fn float_rule(
        self: &mut Self,
        c: u8,
        k: u32,
        ops: &[Value; 4],
        lt: u8,
        mk: u8,
        d: i64,
        xr: u8,
        yr: u8,
        fa: u8,
        fb: u8,
        fc: u8,
    ) {
        let dd = lt == T_F64;
        let lb = type_bits(lt, 8);
        let sb = 1u64 << (lb - 1) as u64;
        let ucom = if dd {
            0x66u32
        } else {
            0u32
        };
        if c == core::SIMD_COPYSIGN || c == core::SIMD_IS_SIGN_NEG {
            self.ld_lane(xr, ops[0], k, lt, false, true);
            if c == core::SIMD_IS_SIGN_NEG {
                self.c.bt_ri(xr, lb - 1);
                self.mask_bit(mk, x::CC_B, k);
                return;
            }
            self.ld_lane(yr, ops[1], k, lt, false, true);
            self.c.mov_ri(S1, sb - 1);
            self.c.alu_rr(x::AND, 8, xr, S1);
            self.c.mov_ri(S1, sb);
            self.c.alu_rr(x::AND, 8, yr, S1);
            self.c.alu_rr(x::OR, 8, xr, yr);
            self.st_lane(xr, d, k, lt, true);
            return;
        }
        self.ld_lane(fa, ops[0], k, lt, false, false);
        if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
            // Ordered, but `!=` holds for a NaN; `<` and `<=` compare swapped.
            self.ld_lane(fb, ops[1], k, lt, false, false);
            let swap = c == core::SIMD_CMP_LT || c == core::SIMD_CMP_LE;
            let (p, q) = if swap {
                (fb, fa)
            } else {
                (fa, fb)
            };
            self.c.sse_rr(ucom, 0x0F2E, p - V0, q - V0);
            if c == core::SIMD_CMP_EQ {
                self.c.setcc(x::CC_E, S1);
                self.c.setcc(x::CC_NP, S0);
                self.c.alu_rr(x::AND, 1, S1, S0);
            } else if c == core::SIMD_CMP_NE {
                self.c.setcc(x::CC_NE, S1);
                self.c.setcc(x::CC_P, S0);
                self.c.alu_rr(x::OR, 1, S1, S0);
            } else {
                self.c.setcc(
                    if c == core::SIMD_CMP_LT || c == core::SIMD_CMP_GT {
                        x::CC_A
                    } else {
                        x::CC_AE
                    },
                    S1,
                );
            }
            self.c.ext(1, 4, false, S1, S1);
            if k != 0 {
                self.c.shift_ri(x::SHL, 8, S1, k);
            }
            self.c.alu_rr(x::OR, 8, mk, S1);
            return;
        }
        if c >= core::SIMD_IS_NAN && c <= core::SIMD_IS_SUBNORMAL {
            let minn = if dd {
                0x0010000000000000u64
            } else {
                0x00800000u64
            };
            let maxf = if dd {
                0x7FEFFFFFFFFFFFFFu64
            } else {
                0x7F7FFFFFu64
            };
            if c == core::SIMD_IS_NAN {
                self.c.sse_rr(ucom, 0x0F2E, fa - V0, fa - V0);
                self.mask_bit(mk, x::CC_P, k);
                return;
            }
            self.fsign(dd, true, fa);
            if c == core::SIMD_IS_SUBNORMAL {
                // Not 0 and below the least normal (a NaN compares unordered: neither).
                self.fconst(fb, dd, minn);
                self.c.sse_rr(ucom, 0x0F2E, fb - V0, fa - V0);
                self.c.setcc(x::CC_A, S0);
                self.c.sse_rr(0, 0x0F57, fb - V0, fb - V0);
                self.c.sse_rr(ucom, 0x0F2E, fa - V0, fb - V0);
                self.c.setcc(x::CC_NE, S1);
                self.c.alu_rr(x::AND, 1, S1, S0);
                self.c.ext(1, 4, false, S1, S1);
                if k != 0 {
                    self.c.shift_ri(x::SHL, 8, S1, k);
                }
                self.c.alu_rr(x::OR, 8, mk, S1);
                return;
            }
            self.fconst(fb, dd, maxf);
            if c == core::SIMD_IS_INF {
                self.c.sse_rr(ucom, 0x0F2E, fa - V0, fb - V0);
                self.mask_bit(mk, x::CC_A, k);
                return;
            }
            self.c.sse_rr(ucom, 0x0F2E, fb - V0, fa - V0);
            if c == core::SIMD_IS_FINITE {
                self.mask_bit(mk, x::CC_AE, k);
                return;
            }
            // Normal: at most the greatest finite and at least the least normal.
            self.c.setcc(x::CC_AE, S0);
            self.fconst(fb, dd, minn);
            self.c.sse_rr(ucom, 0x0F2E, fa - V0, fb - V0);
            self.c.setcc(x::CC_AE, S1);
            self.c.alu_rr(x::AND, 1, S1, S0);
            self.c.ext(1, 4, false, S1, S1);
            if k != 0 {
                self.c.shift_ri(x::SHL, 8, S1, k);
            }
            self.c.alu_rr(x::OR, 8, mk, S1);
            return;
        }
        if c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM {
            self.ld_lane(fb, ops[1], k, lt, false, false);
            let lo = c == core::SIMD_MIN || c == core::SIMD_MINIMUM;
            self.fminmax(dd, lo, c >= core::SIMD_MINIMUM, true, fa, fa, fb);
        } else if c == core::SIMD_ABS {
            self.fsign(dd, true, fa);
        } else if c == core::SIMD_SQRT {
            self.c.sse_rr(fpfx(dd), 0x0F51, fa - V0, fa - V0);
        } else if c == core::SIMD_CEIL || c == core::SIMD_FLOOR || c == core::SIMD_TRUNC || c == core::SIMD_ROUND_EVEN {
            self.round_lane(c, dd, fa);
        } else {
            self.fsign(dd, false, fa);
        }
        let _ = fc;
        self.st_lane(fa, d, k, lt, false);
    }

    // xmm `r` rounded by rule `c` (CEIL, FLOOR, TRUNC, ROUND_EVEN) without SSE4.1: below 2^52 (2^23 for
    // f32) adding and taking away that power rounds to an integer in the default mode (to nearest, ties
    // to even), the sign copied back so a result of 0 keeps it; at or past it a value is integral already.
    // A NaN goes through the arithmetic and comes out quiet. Through r11, xmm14 and xmm15.
    fn round_lane(self: &mut Self, c: u8, dd: bool, r: u8) {
        let big = if dd {
            0x4330000000000000u64
        } else {
            0x4B000000u64
        };
        let one = if dd {
            0x3FF0000000000000u64
        } else {
            0x3F800000u64
        };
        let ucom = if dd {
            0x66u32
        } else {
            0u32
        };
        let a = self.vs0 - V0;
        let t = self.vs1 - V0;
        let rv = r - V0;
        // a = |r|.
        self.c.vmov(a, rv);
        self.fsign(dd, true, self.vs0);
        self.fconst(self.vs1, dd, big);
        self.c.sse_rr(ucom, 0x0F2E, a, t);
        let keep = self.c.jcc32(x::CC_AE);
        self.c.sse_rr(fpfx(dd), 0x0F58, a, t);
        self.c.sse_rr(fpfx(dd), 0x0F5C, a, t);
        if c == core::SIMD_TRUNC {
            // Rounded up past |r|: one less (t = |r|: the mask, and r).
            self.c.mov_ri(
                S1,
                if dd {
                    0x7FFFFFFFFFFFFFFFu64
                } else {
                    0x7FFFFFFFu64
                },
            );
            self.c.movd_to_x(
                if dd {
                    8u32
                } else {
                    4u32
                },
                t,
                S1,
            );
            self.c.sse_rr(0, 0x0F54, t, rv);
            self.c.sse_rr(ucom, 0x0F2E, a, t);
            let ok = self.c.jcc32(x::CC_BE);
            self.fconst(self.vs1, dd, one);
            self.c.sse_rr(fpfx(dd), 0x0F5C, a, t);
            self.c.land(ok, self.c.len());
        }
        // The sign back: a | (r & sign).
        let sb = if dd {
            0x8000000000000000u64
        } else {
            0x80000000u64
        };
        self.c.mov_ri(S1, sb);
        self.c.movd_to_x(
            if dd {
                8u32
            } else {
                4u32
            },
            t,
            S1,
        );
        self.c.sse_rr(0, 0x0F54, t, rv);
        self.c.sse_rr(0, 0x0F56, a, t);
        if c == core::SIMD_FLOOR || c == core::SIMD_CEIL {
            // floor: past r, one less; ceil: below r, one more.
            if c == core::SIMD_FLOOR {
                self.c.sse_rr(ucom, 0x0F2E, a, rv);
            } else {
                self.c.sse_rr(ucom, 0x0F2E, rv, a);
            }
            let ok = self.c.jcc32(x::CC_BE);
            self.fconst(self.vs1, dd, one);
            self.c.sse_rr(
                fpfx(dd),
                if c == core::SIMD_FLOOR {
                    0x0F5Cu32
                } else {
                    0x0F58u32
                },
                a,
                t,
            );
            self.c.land(ok, self.c.len());
        }
        self.c.vmov(rv, a);
        self.c.land(keep, self.c.len());
    }

    // The float min (`lo`) or max of xmm registers `a` and `b` into `d` (which may be `a`), by the
    // evaluator's `fminmax`, the operands' bits kept: with `nan` a NaN operand is the result (`a` first);
    // else a NaN gives the other operand, and two give `a`, quieted when `quiet`. Through r11 and xmm15.
    fn fminmax(self: &mut Self, dd: bool, lo: bool, nan: bool, quiet: bool, d: u8, a: u8, b: u8) {
        let ucom = if dd {
            0x66u32
        } else {
            0u32
        };
        let (av, bv) = (a - V0, b - V0);
        let mut to_a = Vector::<u32>::new();
        let mut to_b = Vector::<u32>::new();
        let mut to_end = Vector::<u32>::new();
        self.c.sse_rr(ucom, 0x0F2E, av, bv);
        let unord = self.c.jcc32(x::CC_P);
        let differ = self.c.jcc32(x::CC_NE);
        // Equal (two zeros of any sign, or one number): the min keeps a negative `a`, the max a positive one.
        self.c.rr(ucom, 0x0F50, false, S1, av, false);
        self.c.test_ri(1, S1, 1);
        to_a.push(
            self.c.jcc32(
                if lo {
                    x::CC_NE
                } else {
                    x::CC_E
                },
            ),
        );
        to_b.push(self.c.jmp32());
        self.c.land(differ, self.c.len());
        to_a.push(
            self.c.jcc32(
                if lo {
                    x::CC_B
                } else {
                    x::CC_A
                },
            ),
        );
        to_b.push(self.c.jmp32());
        self.c.land(unord, self.c.len());
        if nan {
            // A NaN operand is the result: `a` when it is one.
            self.c.sse_rr(ucom, 0x0F2E, av, av);
            to_a.push(self.c.jcc32(x::CC_P));
            to_b.push(self.c.jmp32());
        } else {
            // The other operand: `a` unless it is the NaN; two NaNs give `a`, quieted when `quiet`.
            self.c.sse_rr(ucom, 0x0F2E, av, av);
            to_a.push(self.c.jcc32(x::CC_NP));
            self.c.sse_rr(ucom, 0x0F2E, bv, bv);
            to_b.push(self.c.jcc32(x::CC_NP));
            if quiet {
                self.c.vmov(d - V0, av);
                let qb = if dd {
                    0x0008000000000000u64
                } else {
                    0x00400000u64
                };
                self.c.mov_ri(S1, qb);
                self.c.movd_to_x(
                    if dd {
                        8u32
                    } else {
                        4u32
                    },
                    self.vs1 - V0,
                    S1,
                );
                self.c.sse_rr(0, 0x0F56, d - V0, self.vs1 - V0);
                to_end.push(self.c.jmp32());
            } else {
                to_a.push(self.c.jmp32());
            }
        }
        // b:
        let at_b = self.c.len();
        self.c.vmov(d - V0, bv);
        let out = self.c.jmp32();
        let at_a = self.c.len();
        self.c.vmov(d - V0, av);
        let end = self.c.len();
        self.c.land(out, end);
        for q in 0..to_end.len() {
            self.c.land(to_end[q], end);
        }
        for q in 0..to_b.len() {
            self.c.land(to_b[q], at_b);
        }
        for q in 0..to_a.len() {
            self.c.land(to_a[q], at_a);
        }
    }
}

extend Gen {
    // `cast_changed` lane `k`: whether casting lane `a` of operand 0 (signed `bs`) to lane `d` of operand 1
    // (signed `rs`) changed its value, or `a` is a NaN, as a bit of `mk` (the evaluator's `lane_changed`).
    fn lane_changed(
        self: &mut Self,
        mk: u8,
        k: u32,
        ops: &[Value; 4],
        tys: &[u8; 4],
        bs: bool,
        rs: bool,
        xr: u8,
        yr: u8,
        fa: u8,
        fb: u8,
    ) {
        let bt = lane_type(tys[0]);
        let rt = lane_type(tys[1]);
        let ff = is_float(bt);
        let tf = is_float(rt);
        if ff && tf {
            // Both in f64: unordered or not equal.
            self.ld_lane(fa, ops[0], k, bt, false, false);
            self.ld_lane(fb, ops[1], k, rt, false, false);
            if bt == T_F32 {
                self.c.sse_rr(0xF3, 0x0F5A, fa - V0, fa - V0);
            }
            if rt == T_F32 {
                self.c.sse_rr(0xF3, 0x0F5A, fb - V0, fb - V0);
            }
            self.c.sse_rr(0x66, 0x0F2E, fa - V0, fb - V0);
            self.c.setcc(x::CC_NE, yr);
            self.c.setcc(x::CC_P, S1);
            self.c.alu_rr(x::OR, 1, S1, yr);
            self.mask_lane(mk, k);
            return;
        }
        if !ff && !tf {
            // Integers: the source value does not fit the result lane.
            self.ld_lane(xr, ops[0], k, bt, bs, false);
            self.c.alu_rr(x::XOR, 4, yr, yr);
            self.narrow_lane(false, type_bits(bt, 8), bs, type_bits(rt, 8), rs, xr, yr);
            self.c.test_rr(4, yr, yr);
            self.mask_bit(mk, x::CC_NE, k);
            return;
        }
        // A float and an integer: the integer side's range [lo, hi) as f64 bounds.
        let ib = if ff {
            rt
        } else {
            bt
        };
        let isg = if ff {
            rs
        } else {
            bs
        };
        let iw = type_bits(ib, 8) - isg as u32;
        let hi = 1023u64 + iw as u64 << 52;
        let lo = if isg {
            hi | 1u64 << 63
        } else {
            0u64
        };
        if ff {
            self.ld_lane(fa, ops[0], k, bt, false, false);
            if bt == T_F32 {
                self.c.sse_rr(0xF3, 0x0F5A, fa - V0, fa - V0);
            }
        } else {
            self.ld_lane(fa, ops[1], k, rt, false, false);
            if rt == T_F32 {
                self.c.sse_rr(0xF3, 0x0F5A, fa - V0, fa - V0);
            }
        }
        // yr = fa >= lo && fa < hi (false for a NaN).
        self.fconst(fb, true, lo);
        self.c.sse_rr(0x66, 0x0F2E, fa - V0, fb - V0);
        self.c.setcc(x::CC_AE, yr);
        self.fconst(fb, true, hi);
        self.c.sse_rr(0x66, 0x0F2E, fb - V0, fa - V0);
        self.c.setcc(x::CC_A, S1);
        self.c.alu_rr(x::AND, 1, yr, S1);
        if ff {
            // And integral: trunc(x) == x.
            self.c.vmov(fb - V0, fa - V0);
            self.round_lane(core::SIMD_TRUNC, true, fb);
            self.c.sse_rr(0x66, 0x0F2E, fa - V0, fb - V0);
            self.c.setcc(x::CC_E, S1);
        } else {
            // And the integer back equals the source.
            self.ld_lane(xr, ops[0], k, bt, bs, false);
            self.f2i(true, bs, 64, true, S0, fa);
            self.c.alu_rr(x::CMP, 8, S0, xr);
            self.c.setcc(x::CC_E, S1);
        }
        self.c.alu_rr(x::AND, 1, yr, S1);
        // Changed when not (in range and exact).
        self.c.alu_ri(x::XOR, 1, yr, 1);
        self.c.mov_rr(4, S1, yr);
        self.mask_lane(mk, k);
    }

    // `mk` |= (r11's low byte) << `k`.
    fn mask_lane(self: &mut Self, mk: u8, k: u32) {
        self.c.ext(1, 4, false, S1, S1);
        if k != 0 {
            self.c.shift_ri(x::SHL, 8, S1, k);
        }
        self.c.alu_rr(x::OR, 8, mk, S1);
    }

    // `load`, `store` and their raw forms: the vector's bytes from or to the slice's pointer at the
    // checked start, or the pointer.
    fn vmem(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let raw = c == core::SIMD_LOAD_RAW || c == core::SIMD_STORE_RAW;
        let load = c == core::SIMD_LOAD || c == core::SIMD_LOAD_RAW;
        let vt = if load {
            t.ty
        } else if raw {
            tys[1]
        } else {
            tys[2]
        };
        let eb = type_bytes(lane_type(vt), 8);
        let nb = type_bytes(vt, 8);
        let p = self.tmp(false);
        if raw {
            let r0 = self.reg(ops[0]);
            self.c.mov_rr(8, p, r0);
        } else {
            let mut rs: u32 = NONE;
            let mut radd: i64 = 0;
            let m = self.mem_at(ops[0], 0, &mut rs, &mut radd);
            self.c.load(8, false, p, m);
            self.mem_rel(rs, radd);
            let st = self.reg(ops[1]);
            self.c.lea(p, x::ix(p, st, eb.trailing_zeros() as u8, 0));
        }
        let vv = if raw {
            ops[1]
        } else {
            ops[2]
        };
        if load && in_vreg(vt) {
            let rd = self.vec_def(i);
            self.ld(vt, rd, x::at(p, 0));
        } else if load {
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, p, 0, nb);
        } else if in_vreg(vt) {
            let r = self.vec_use(vv, self.vs0);
            self.st(vt, r, x::at(p, 0));
        } else {
            let (bv, ov) = self.mloc(vv);
            self.copy_mem(p, 0, bv, ov, nb);
        }
    }

    // The masked, partial and gather forms (the evaluator's `vmem_masked`): every active lane is checked
    // before the first access, the lowest failing one traps; an inactive lane never touches its element.
    // r10 is the element index.
    fn vmem_masked(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let op = core::simd_op(c);
        let ar = op.arity as usize;
        let store = op.rule == core::SR_MSTORE;
        let vt = unsafe tys[ar - 1];
        let vv = unsafe ops[ar - 1];
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let n = lanes(vt);
        let ptrs = c == core::SIMD_GATHER_PTR || c == core::SIMD_SCATTER_PTR;
        let gat = c == core::SIMD_GATHER || c == core::SIMD_SCATTER || c == core::SIMD_GATHER_UNCHECKED;
        let sl = c < core::SIMD_GATHER_PTR;
        let cs = c == core::SIMD_COMPRESS_STORE;
        let ix = S0;
        let p = self.tmp(false);
        let len = self.tmp(false);
        let act = self.tmp(false);
        let xr = self.tmp(false);
        let r0 = self.reg(ops[0]);
        if sl {
            self.c.load(8, false, p, x::at(r0, 0));
            self.c.load(8, false, len, x::at(r0, 8));
        } else {
            self.c.mov_rr(8, p, r0);
        }
        let st = if sl && !gat {
            self.reg(ops[1])
        } else {
            NOREG
        };
        let all = trunc64(~0u64, n);
        if c == core::SIMD_LOAD_OR {
            // The lanes below len - start, none when start is past len.
            self.c.alu_rr(x::XOR, 4, act, act);
            self.c.mov_rr(8, xr, len);
            self.c.alu_rr(x::SUB, 8, xr, st);
            let none = self.c.jcc32(x::CC_B);
            self.c.mov_ri(act, all);
            self.c.alu_ri(x::CMP, 8, xr, n as i32);
            let full = self.c.jcc32(x::CC_AE);
            self.c.alu_rr(x::XOR, 4, act, act);
            // bts act, xr; then one less: the lanes below.
            self.c.rr(0, 0x0FAB, true, xr, act, false);
            self.c.alu_ri(x::SUB, 8, act, 1);
            self.c.land(none, self.c.len());
            self.c.land(full, self.c.len());
        } else {
            let m = self.reg(unsafe ops[ar - 2]);
            self.c.mov_rr(8, act, m);
            if n < 64 {
                self.c.mov_ri(S1, all);
                self.c.alu_rr(x::AND, 8, act, S1);
            }
        }
        if cs {
            // The packed lanes must fit from start.
            self.popcount(xr, act, 8);
            self.c.mov_rr(8, ix, len);
            self.c.alu_rr(x::SUB, 8, ix, st);
            let fail = self.c.jcc32(x::CC_B);
            self.c.alu_rr(x::CMP, 8, ix, xr);
            let ok = self.c.jcc32(x::CC_AE);
            self.c.land(fail, self.c.len());
            self.c.mov_rr(8, S0, xr);
            self.c.mov_rr(8, S1, st);
            self.c.mov_rr(8, self.arg(2), len);
            self.c.mov_rr(8, self.arg(0), S0);
            self.c.mov_rr(8, self.arg(1), S1);
            self.call_sym("__sc_vec_bounds");
            self.c.land(ok, self.c.len());
        }
        let unchecked = c == core::SIMD_GATHER_UNCHECKED;
        if sl && !cs && !unchecked {
            for k in 0..n {
                self.c.bt_ri(act, k);
                let skip = self.c.jcc32(x::CC_AE);
                if gat {
                    self.ld_lane(ix, ops[1], k, lane_type(tys[1]), false, false);
                    self.c.alu_rr(x::CMP, 8, ix, len);
                    let ok = self.c.jcc32(x::CC_B);
                    self.lane_oob(k, ix, len, false);
                    self.c.land(ok, self.c.len());
                } else {
                    // start + k < len, without overflow: start <= len and k < len - start.
                    self.c.mov_rr(8, ix, len);
                    self.c.alu_rr(x::SUB, 8, ix, st);
                    let fail = self.c.jcc32(x::CC_B);
                    self.c.alu_ri(x::CMP, 8, ix, k as i32);
                    let ok = self.c.jcc32(x::CC_A);
                    self.c.land(fail, self.c.len());
                    self.lane_oob(k, st, len, true);
                    self.c.land(ok, self.c.len());
                }
                self.c.land(skip, self.c.len());
            }
        }
        // A load starts from the fallback lanes.
        let mut d: i64 = 0;
        if !store {
            d = self.mdef(i);
            let (bf, of) = self.mloc(vv);
            self.copy_mem(x::RSP, d, bf, of, type_bytes(vt, 8));
        }
        let s = eb.trailing_zeros() as u8;
        if cs {
            self.c.mov_rr(8, ix, st);
        }
        for k in 0..n {
            self.c.bt_ri(act, k);
            let skip = self.c.jcc32(x::CC_AE);
            // The element's address: p + ix * eb, or for the pointer forms lane k's pointer.
            let m = if ptrs {
                self.c.load(8, false, ix, x::at(p, 8 * k as i32));
                x::at(ix, 0)
            } else {
                if gat {
                    self.ld_lane(ix, ops[1], k, lane_type(tys[1]), false, false);
                } else if !cs {
                    if sl {
                        self.c.lea(ix, x::at(st, k as i32));
                    } else {
                        self.c.mov_ri(ix, k);
                    }
                }
                x::ix(p, ix, s, 0)
            };
            if store {
                self.ld_lane(xr, vv, k, lt, false, true);
                self.c.store(eb, xr, m);
            } else {
                self.c.load(eb, false, xr, m);
                self.st_lane(xr, d, k, lt, true);
            }
            if cs {
                self.c.alu_ri(x::ADD, 8, ix, 1);
            }
            self.c.land(skip, self.c.len());
        }
        if cs && t.ty != T_NONE {
            // The active lane count.
            let rd = self.def(i);
            self.c.mov_rr(8, rd, ix);
            self.c.alu_rr(x::SUB, 8, rd, st);
        }
    }

    // The bounds trap of lane `k`: element `xv` (+ k from start when `start`) of `len`.
    fn lane_oob(self: &mut Self, k: u32, xv: u8, len: u8, start: bool) {
        self.c.mov_rr(8, S1, len);
        if xv != S0 {
            self.c.mov_rr(8, S0, xv);
        }
        self.c.mov_ri(self.arg(0), k);
        self.c.mov_rr(8, self.arg(1), S0);
        self.c.mov_rr(8, self.arg(2), S1);
        self.c.mov_ri(self.arg(3), start as u64);
        self.call_sym("__sc_lane_bounds");
    }

    // The reductions and `dot` (the evaluator's `vreduce`): a left-to-right fold, the halving tree, the
    // lowest extreme lane, or the exact-result test; the result into instruction `i`'s register.
    fn vreduce(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let vt = tys[0];
        let lt = lane_type(vt);
        let n = lanes(vt);
        if c == core::SIMD_REDUCE_ADD_OVF || c == core::SIMD_REDUCE_MUL_OVF {
            self.reduce_ovf(i, c == core::SIMD_REDUCE_ADD_OVF, ops[0], lt, sg);
            return;
        }
        if c >= core::SIMD_ARG_MIN && c <= core::SIMD_ARG_MAX_NUM {
            self.reduce_arg(i, c == core::SIMD_ARG_MIN || c == core::SIMD_ARG_MIN_NUM, ops[0], lt, sg);
            return;
        }
        // The accumulator's type: the result's (`dot` widens each product to it).
        let at = t.ty;
        let add = c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_ORD || c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_DOT;
        let mul = c == core::SIMD_REDUCE_MUL || c == core::SIMD_REDUCE_MUL_ORD || c == core::SIMD_REDUCE_MUL_TREE;
        let dot = c == core::SIMD_DOT;
        if is_float(lt) {
            self.reduce_float(i, c, add, mul, dot, at, ops, lt, n);
            return;
        }
        if self.reduce_reg(t) {
            self.reduce_halves(i, c, sg, ops[0], type_bits(lt, self.ptr));
            return;
        }
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        let acc = self.tmp(false);
        if dot {
            self.c.alu_rr(x::XOR, 4, acc, acc);
        } else {
            self.ld_lane(acc, ops[0], 0, lt, sg, false);
        }
        let from: u32 = if dot {
            0
        } else {
            1
        };
        let lt_c = if sg {
            x::CC_L
        } else {
            x::CC_B
        };
        for k in from..n {
            self.ld_lane(xr, ops[0], k, lt, sg, false);
            if dot {
                self.ld_lane(yr, ops[1], k, lt, sg, false);
                self.c.imul_rr(8, xr, yr);
                self.c.alu_rr(x::ADD, 8, acc, xr);
            } else if c == core::SIMD_REDUCE_AND || c == core::SIMD_REDUCE_OR || c == core::SIMD_REDUCE_XOR {
                self.c.alu_rr(
                    if c == core::SIMD_REDUCE_AND {
                        x::AND
                    } else if c == core::SIMD_REDUCE_OR {
                        x::OR
                    } else {
                        x::XOR
                    },
                    8,
                    acc,
                    xr,
                );
            } else if add {
                self.c.alu_rr(x::ADD, 8, acc, xr);
            } else if mul {
                self.c.imul_rr(8, acc, xr);
            } else {
                // min takes a lane below the accumulator, max one not below: both stay extended.
                self.c.alu_rr(x::CMP, 8, xr, acc);
                self.c.cmov(
                    if c == core::SIMD_REDUCE_MIN {
                        lt_c
                    } else {
                        x::invert(lt_c)
                    },
                    8,
                    acc,
                    xr,
                );
            }
        }
        let rd = self.def(i);
        self.c.mov_rr(8, rd, acc);
    }

    // Whether `O_VOP` `t` is an integer reduction `reduce_halves` computes in xmm registers: a sum, `and`,
    // `or`, `xor`, minimum or maximum of a 16-byte vector in a register, at its lanes' width.
    fn reduce_reg(self: &Self, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        if t.op != O_VOP || code < core::OP_SIMD || code >= core::OP_CMP_LANES || t.b != 1 {
            return false;
        }
        let c = (code - core::OP_SIMD) as u8;
        let vt = self.vt(self.b().pool[t.a as usize]);
        let lt = lane_type(vt);
        return (c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_AND || c == core::SIMD_REDUCE_OR || c == core::SIMD_REDUCE_XOR || c == core::SIMD_REDUCE_MIN || c == core::SIMD_REDUCE_MAX) && is_vec(
            vt,
        ) && !is_float(lt) && type_bytes(vt, self.ptr) == 16 && self.in_reg(vt) && type_bits(t.ty, self.ptr) == type_bits(
            lt,
            self.ptr,
        );
    }

    // Whether `O_VOP` `t` is the lanes' minimum or maximum of two vectors of integer lanes of at most 4
    // bytes in registers: 16 bytes in xmm registers, or 32 in ymm registers under AVX2 (`lane_ext`).
    fn ext_reg(self: &Self, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        if t.op != O_VOP || code != core::OP_SIMD + core::SIMD_MIN as u32 && code != core::OP_SIMD + core::SIMD_MAX as u32 || t.b != 2 {
            return false;
        }
        let lt = lane_type(t.ty);
        let nb = type_bytes(t.ty, 8);
        return is_vec(t.ty) && is_int(lt) && type_bytes(lt, 8) <= 4 && (nb == 16 && in_vreg(t.ty) || nb == 32 && self.avx && self.in_reg(
            t.ty,
        ));
    }

    // Whether `O_VOP` `t` is a saturating sum or difference, or an absolute difference, of two vectors of
    // integer lanes of 1 or 2 bytes in registers (16 bytes; 32 and 64 with AVX2 and AVX-512), which
    // `idiom_lanes` computes there; or a move of the lanes of 2 to 8 bytes of a vector in an xmm register
    // (`lv::lane_perm`, `reverse_lanes`).
    fn idiom_reg(self: &Self, t: Inst) bool {
        if lv::lane_perm(self.b(), t) != 0 {
            return in_vreg(t.ty) && type_bytes(lane_type(t.ty), 8) >= 2;
        }
        let code = (t.aux & VOP_CODE) as u32;
        if t.op != O_VOP || t.b != 2 || !is_vec(t.ty) || code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return false;
        }
        let c = (code - core::OP_SIMD) as u8;
        if c != core::SIMD_SAT_ADD && c != core::SIMD_SAT_SUB && c != core::SIMD_ABS_DIFF {
            return false;
        }
        let lt = lane_type(t.ty);
        let nb = type_bytes(t.ty, 8);
        return is_int(lt) && type_bytes(lt, 8) <= 2 && (nb == 16 && in_vreg(t.ty) || nb > 16 && self.in_reg(t.ty));
    }

    // Whether `O_VOP` `t` is a lane operation of float vectors in registers (8 or 16 bytes; 32 and 64 with
    // AVX2 and AVX-512) that `float_lanes` computes there: the absolute value, floor, ceil and trunc
    // (SSE4.1, which AVX has), the fused multiply-add (the processor's `fma`), C's `fmin` and `fmax`
    // (VOP_NUM).
    fn float_reg(self: &Self, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        if t.op != O_VOP || !is_vec(t.ty) || !is_float(lane_type(t.ty)) || code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return false;
        }
        let c = (code - core::OP_SIMD) as u8;
        let nb = type_bytes(t.ty, 8);
        let p = unsafe &*self.pkg;
        let round = c == core::SIMD_FLOOR || c == core::SIMD_CEIL || c == core::SIMD_TRUNC;
        let num = (c == core::SIMD_MIN || c == core::SIMD_MAX) && (t.aux & VOP_NUM) != 0;
        if !(c == core::SIMD_ABS || round && (p.sse41 || nb > 16) || c == core::SIMD_FMA && p.fma || num) || !(in_vreg(
            t.ty,
        ) || nb > 16 && self.in_reg(t.ty)) {
            return false;
        }
        for k in 0..t.b {
            if self.vt(self.b().pool[(t.a + k) as usize]) != t.ty {
                return false;
            }
        }
        return true;
    }

    // Float lane operation `t` (`float_reg`: rule `c`) of `ops` into vector `i`: ANDPS of the lanes and their
    // magnitude mask; ROUNDPS (VRNDSCALEPS on 64 bytes); VFMADD213PS or VFMADD231PS; C's `fmax` and `fmin`
    // as their scalar rows' (`target::x64intrin`) packed forms, so each lane gives what the call gives.
    // The PD forms for f64 lanes.
    fn float_lanes(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4]) {
        let nb = type_bytes(t.ty, 8);
        let dd = lane_type(t.ty) == T_F64;
        let pfx = dd as u32 * 0x66;
        // SSE4.1's `blendvps` of C's `fmin` and `fmax` takes its mask in xmm0, which no operand holds then.
        let mm = c == core::SIMD_MIN || c == core::SIMD_MAX;
        let xmm0 = mm && nb == 16 && !self.avx && unsafe (*self.pkg).sse41 && !self.ordinary_lanes(ops[1]) && !self.ordinary_lanes(
            ops[0],
        );
        if xmm0 {
            self.vacate(V0);
        }
        let rx = self.vec_use(ops[0], self.vs0) - V0;
        if c == core::SIMD_ABS {
            let mut ws = Vector::<u64>::new();
            for _ in 0..(nb / 8).max(2) {
                ws.push(
                    if dd {
                        0x7FFFFFFFFFFFFFFFu64
                    } else {
                        0x7FFFFFFF7FFFFFFFu64
                    },
                );
            }
            let k = self.const_sym(&ws);
            let rd = self.def_over(i, ops[0], rx + V0) - V0;
            if nb <= 16 {
                self.c.vmov(rd, rx);
                self.c.rm(pfx, 0x0F54, false, rd, x::rip(), false);
                self.reloc_rip(x::R_PC32, k, 0);
                return;
            }
            let s = self.vs1 - V0;
            self.c.vload(nb, s, x::rip());
            self.reloc_rip(x::R_PC32, k, 0);
            self.fop(nb, dd, 0x54, rd, rx, s);
            return;
        }
        if c == core::SIMD_FLOOR || c == core::SIMD_CEIL || c == core::SIMD_TRUNC {
            let imm: u32 = if c == core::SIMD_FLOOR {
                9
            } else if c == core::SIMD_CEIL {
                10
            } else {
                11
            };
            let rd = self.def_over(i, ops[0], rx + V0) - V0;
            if nb <= 16 && !self.avx {
                self.c.sse_rr(0x66, 0x0F3A08 + dd as u32, rd, rx);
            } else if nb <= 32 {
                self.c.vex_rr(0x66, 3, 0x08 + dd as u32, false, nb == 32, rd, 0, rx);
            } else {
                self.c.evex_rr(0x66, 3, 0x08 + dd as u32, dd, rd, 0, rx);
            }
            self.c.byte(imm);
            return;
        }
        let ry = self.vec_use(ops[1], self.vs1) - V0;
        if c == core::SIMD_FMA {
            // x * y + z: VFMADD213 over a register that holds x or y, VFMADD231 over one that holds z.
            let zs = self.tmp(true);
            let rz = self.vec_use(ops[2], zs) - V0;
            let rd = self.def_over(i, ops[0], rx + V0) - V0;
            let (opc, s1, s2) = if rd == rz && rd != rx && rd != ry {
                (0xB8u32, rx, ry)
            } else if rd == ry && rd != rx {
                (0xA8u32, rx, rz)
            } else {
                (0xA8u32, ry, rz)
            };
            if rd != rx && rd != ry && rd != rz {
                self.fop(nb, dd, 0x28, rd, 0, rx);
            }
            if nb == 64 {
                self.c.evex_rr(0x66, 2, opc, dd, rd, s1, s2);
            } else {
                self.c.vex_rr(0x66, 2, opc, dd, nb == 32, rd, s1, s2);
            }
            return;
        }
        let lo = c == core::SIMD_MIN;
        // A constant operand with no NaN and no zero lane goes second to MINPS/MAXPS: a NaN lane of the
        // other gives it, as C's does, and no two zeros tie.
        let ky = self.ordinary_lanes(ops[1]);
        if ky || self.ordinary_lanes(ops[0]) {
            let (p, q, pv) = if ky {
                (rx, ry, ops[0])
            } else {
                (ry, rx, ops[1])
            };
            let rd = self.def_over(i, pv, p + V0) - V0;
            self.fop(
                nb,
                dd,
                if lo {
                    0x5Du32
                } else {
                    0x5Fu32
                },
                rd,
                p,
                q,
            );
            return;
        }
        // fmax: (y != x | y) & max(y, x), which keeps +0 over -0; fmin: (y == x & y) | min(y, x), which keeps
        // -0. Then y where x is a NaN.
        let a = self.tmp(true) - V0;
        let b = self.tmp(true) - V0;
        self.fop_cmp(
            nb,
            dd,
            if lo {
                0u32
            } else {
                4u32
            },
            a,
            ry,
            rx,
        );
        self.fop(
            nb,
            dd,
            if lo {
                0x54u32
            } else {
                0x56u32
            },
            a,
            a,
            ry,
        );
        self.fop(
            nb,
            dd,
            if lo {
                0x5Du32
            } else {
                0x5Fu32
            },
            b,
            ry,
            rx,
        );
        self.fop(
            nb,
            dd,
            if lo {
                0x56u32
            } else {
                0x54u32
            },
            b,
            b,
            a,
        );
        // The NaN lanes' mask, then y under it: `vblendvps` (AVX: VEX.66.0F3A 4A, 4B for doubles, the mask's
        // register in the immediate's high bits), `blendvps` (SSE4.1: 66 0F 38 14, 15, the mask in xmm0), else
        // `andps`, `andnps`, `orps`.
        let r = if nb <= 32 && self.avx {
            self.fop_cmp(nb, dd, 3, a, rx, rx);
            self.c.vex_rr(0x66, 3, 0x4A + dd as u32, false, nb == 32, a, b, ry);
            self.c.byte(a << 4);
            a
        } else if xmm0 {
            self.fop_cmp(nb, dd, 3, 0, rx, rx);
            self.c.sse_rr(0x66, 0x0F3814 + dd as u32, b, ry);
            b
        } else {
            let e = self.tmp(true) - V0;
            self.fop_cmp(nb, dd, 3, a, rx, rx);
            self.fop(nb, dd, 0x54, e, ry, a);
            self.fop(nb, dd, 0x55, a, a, b);
            self.fop(nb, dd, 0x56, a, a, e);
            a
        };
        // The result takes temporary `r` unless it shares a loop parameter's register.
        let rd = self.def_over(i, ops[0], r + V0) - V0;
        if rd != r {
            self.fop(nb, dd, 0x28, rd, 0, r);
        }
    }

    // Whether value `v` is a constant vector (`wconst`) of zero bits.
    fn zero_vec(self: &Self, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || self.b().insts[v as usize].op != O_WCONST {
            return false;
        }
        let t = self.b().insts[v as usize];
        for k in 0..t.b {
            if self.b().words[(t.a + k) as usize] != 0 {
                return false;
            }
        }
        return true;
    }

    // Whether value `v` is a constant float vector (`wconst`) whose lanes are neither NaN nor zero.
    fn ordinary_lanes(self: &Self, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || self.b().insts[v as usize].op != O_WCONST {
            return false;
        }
        let t = self.b().insts[v as usize];
        let dd = lane_type(t.ty) == T_F64;
        for k in 0..t.b {
            let w = self.b().words[(t.a + k) as usize];
            for h in 0..2 - dd as u32 {
                let m = if dd {
                    w & 0x7FFFFFFFFFFFFFFF
                } else {
                    w >> (32 * h) as u64 & 0x7FFFFFFF
                };
                let inf = if dd {
                    0x7FF0000000000000u64
                } else {
                    0x7F800000u64
                };
                if m == 0 || m > inf {
                    return false;
                }
            }
        }
        return true;
    }

    // `rd` = `rx` op `ry` for the float vector instruction `opc` of opcode map 0F (the PS form, PD when
    // `dd`) on `nb` bytes: VEX.256 on 32, EVEX.512 on 64; VEX.128 on 16 or fewer with AVX2, else SSE (`rx`
    // copied into `rd` first, through a temporary when `rd` holds `ry`). `opc` 0x28 (MOVAPS) copies `ry`.
    fn fop(self: &mut Self, nb: u32, dd: bool, opc: u32, rd: u8, rx: u8, ry: u8) {
        let pfx = dd as u32 * 0x66;
        if nb == 64 {
            self.c.evex_rr(pfx, 1, opc, dd, rd, rx, ry);
            return;
        }
        if nb == 32 || self.avx {
            if opc != 0x28 || rd != ry {
                self.c.vex_rr(pfx, 1, opc, false, nb == 32, rd, rx, ry);
            }
            return;
        }
        if opc == 0x28 {
            self.c.vmov(rd, ry);
            return;
        }
        if rd == ry && rd != rx {
            let s = self.tmp(true) - V0;
            self.c.vmov(s, ry);
            self.c.vmov(rd, rx);
            self.c.sse_rr(pfx, 0x0F00 | opc, rd, s);
            return;
        }
        self.c.vmov(rd, rx);
        self.c.sse_rr(pfx, 0x0F00 | opc, rd, ry);
    }

    // `rd` = the lane masks of comparison predicate `imm` (CMPPS's) of `rx` and `ry`, as `fop`; on 64 bytes
    // through mask register k1 (VPMOVM2D, VPMOVM2Q).
    fn fop_cmp(self: &mut Self, nb: u32, dd: bool, imm: u32, rd: u8, rx: u8, ry: u8) {
        if nb == 64 {
            self.c.evex_rr(dd as u32 * 0x66, 1, 0xC2, dd, 1, rx, ry);
            self.c.byte(imm);
            self.c.evex_rr(0xF3, 2, 0x38, dd, rd, 0, 1);
            return;
        }
        self.fop(nb, dd, 0xC2, rd, rx, ry);
        self.c.byte(imm);
    }

    // Vector `i`: the lanes of vector `v` moved by `lv::lane_perm` (`idiom_reg`): 2-byte lanes reversed in each
    // qword (PSHUFLW, PSHUFHW); 4-byte ones by PSHUFD of the dwords; the qwords swapped by PSHUFD.
    fn reverse_lanes(self: &mut Self, i: u32, t: Inst, v: Value) {
        let f = lv::lane_perm(self.b(), t);
        let eb = type_bytes(lane_type(t.ty), 8);
        let rx = self.vec_use(v, self.vs0) - V0;
        let rd = self.vec_def(i) - V0;
        let mut src = rx;
        if eb == 2 && (f & lv::PERM_REV8) != 0 {
            self.c.sse_rr(0xF2, 0x0F70, rd, src);
            self.c.byte(0x1B);
            self.c.sse_rr(0xF3, 0x0F70, rd, rd);
            self.c.byte(0x1B);
            if (f & lv::PERM_SWAP8) == 0 {
                return;
            }
            src = rd;
        }
        self.c.sse_rr(0x66, 0x0F70, rd, src);
        self.c.byte(
            if eb == 4 && f == lv::PERM_REV8 {
                0xB1u8
            } else if eb == 4 && f != lv::PERM_SWAP8 {
                0x1Bu8
            } else {
                0x4Eu8
            },
        );
    }

    // Idiom `t` (`idiom_reg`: rule `c`, signed `sg`) of `ops` into vector `i`: PADDUS, PADDS, PSUBUS or PSUBS;
    // an unsigned absolute difference as the `or` of the two saturating differences, a signed one as the
    // larger lane less the smaller (PMAXS, PMINS; bytes without SSE4.1 as the difference, negated where the
    // second is greater: PCMPGT, PXOR, PSUB).
    fn idiom_lanes(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, ops: &[Value; 4]) {
        let nb = type_bytes(t.ty, 8);
        let wb = (type_bytes(lane_type(t.ty), 8) == 2) as u32;
        let rx = self.vec_use(ops[0], self.vs0) - V0;
        let ry = self.vec_use(ops[1], self.vs1) - V0;
        if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let base: u32 = if c == core::SIMD_SAT_ADD && sg {
                0xEC
            } else if c == core::SIMD_SAT_ADD {
                0xDC
            } else if sg {
                0xE8
            } else {
                0xD8
            };
            // Over the first operand's register when it dies here.
            let rd = self.def_over(i, ops[0], rx + V0) - V0;
            self.op3(1, base + wb, false, nb, rd, rx, ry);
            return;
        }
        let ta = self.tmp(true) - V0;
        let tb = self.tmp(true) - V0;
        if !sg {
            self.op3(1, 0xD8 + wb, false, nb, ta, rx, ry);
            self.op3(1, 0xD8 + wb, false, nb, tb, ry, rx);
            let rd = self.vec_def(i) - V0;
            self.op3(1, 0xEB, false, nb, rd, ta, tb);
            return;
        }
        if wb == 1 || nb > 16 || unsafe (*self.pkg).sse41 {
            if wb == 1 {
                self.op3(1, 0xEE, false, nb, ta, rx, ry);
                self.op3(1, 0xEA, false, nb, tb, rx, ry);
            } else {
                self.op3(2, 0x3C, false, nb, ta, rx, ry);
                self.op3(2, 0x38, false, nb, tb, rx, ry);
            }
        } else {
            self.op3(1, 0x64, false, nb, tb, ry, rx);
            self.op3(1, 0xF8, false, nb, ta, rx, ry);
            self.op3(1, 0xEF, false, nb, ta, ta, tb);
        }
        let rd = self.vec_def(i) - V0;
        self.op3(1, 0xF8 + wb, false, nb, rd, ta, tb);
    }

    // `rd` = `rx` op `ry` of the 0x66-prefixed integer vector instruction `opc` of opcode map `mm` (1: 0F, 2:
    // 0F38) on `nb` bytes: SSE on 16 (`rx` copied into `rd` first, through a temporary when `rd` holds `ry`),
    // VEX.256 on 32, EVEX.512 (W `ew`) on 64.
    fn op3(self: &mut Self, mm: u32, opc: u32, ew: bool, nb: u32, rd: u8, rx: u8, ry: u8) {
        if nb == 64 {
            self.c.evex_rr(0x66, mm, opc, ew, rd, rx, ry);
            return;
        }
        if nb == 32 {
            self.c.vex_rr(0x66, mm, opc, false, true, rd, rx, ry);
            return;
        }
        let op = if mm == 1 {
            0x0F00 | opc
        } else {
            0x0F3800 | opc
        };
        if rd == ry && rd != rx {
            let s = self.tmp(true) - V0;
            self.c.vmov(s, rx);
            self.c.sse_rr(0x66, op, s, ry);
            self.c.vmov(rd, s);
            return;
        }
        self.c.vmov(rd, rx);
        self.c.sse_rr(0x66, op, rd, ry);
    }

    // Whether `O_VSUMW` `t` sums bytes into 8-byte lanes of a vector in registers (16 bytes; 32 and 64 with
    // AVX2 and AVX-512), which `vsumw` computes there.
    fn sumw_reg(self: &Self, t: Inst) bool {
        if t.op != O_VSUMW {
            return false;
        }
        let nb = type_bytes(t.ty, 8);
        return type_bytes(lane_type(t.ty), 8) == 8 && type_bytes(lane_type(self.vt(t.b)), 8) == 1 && (nb == 16 && in_vreg(
            t.ty,
        ) || nb > 16 && self.in_reg(t.ty));
    }

    // Widening sum `t` (`O_VSUMW`) into vector `i`: in registers (`sumw_reg`) PSADBW of the bytes and zeros, or
    // of the two vectors of an absolute difference that folds into it (`lv::FOLD_VSAD`), then PADDQ over
    // the accumulator; else lane by lane in memory.
    fn vsumw(self: &mut Self, i: u32, t: Inst) {
        let nt = self.vt(t.b);
        let nb = type_bytes(t.ty, 8);
        if self.sumw_reg(t) {
            let s = self.tmp(true) - V0;
            let p = self.lv.vsad_diff(self.b(), t);
            if p != VNONE && self.lv.pfold[p as usize] {
                let d = self.b().insts[p as usize];
                let rx = self.vec_use(self.b().pool[d.a as usize], self.vs0) - V0;
                let ry = self.vec_use(self.b().pool[(d.a + 1) as usize], self.vs1) - V0;
                self.op3(1, 0xF6, false, nb, s, rx, ry);
            } else {
                // The zeros' register takes the sums: |0 - b| is |b - 0|, no copy of the bytes.
                let rb = self.vec_use(t.b, self.vs1) - V0;
                self.op3(1, 0xEF, false, nb, s, s, s);
                self.op3(1, 0xF6, false, nb, s, s, rb);
            }
            let ra = self.vec_use(t.a, self.vs0);
            let rd = self.def_over(i, t.a, ra) - V0;
            self.op3(1, 0xD4, true, nb, rd, ra - V0, s);
            return;
        }
        // A folded absolute difference (`lv::FOLD_VSAD`) of each pair of lanes.
        let p = self.lv.vsad_diff(self.b(), t);
        let (fx, fy) = if p != VNONE && self.lv.pfold[p as usize] {
            let d = self.b().insts[p as usize];
            (self.b().pool[d.a as usize], self.b().pool[(d.a + 1) as usize])
        } else {
            (t.b, VNONE)
        };
        self.sync(t.a);
        self.sync(fx);
        if fy != VNONE {
            self.sync(fy);
        }
        let d = self.mdef(i);
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let g = lanes(nt) / n;
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        let zr = self.tmp(false);
        for k in 0..n {
            self.ld_lane(xr, t.a, k, lt, false, false);
            for j in 0..g {
                self.ld_lane(yr, fx, k * g + j, lane_type(nt), false, false);
                if fy != VNONE {
                    // |y - z| of the zero-extended lanes: the difference, negated when negative.
                    self.ld_lane(zr, fy, k * g + j, lane_type(nt), false, false);
                    self.c.alu_rr(x::SUB, 8, yr, zr);
                    self.c.mov_rr(8, zr, yr);
                    self.c.unary(x::NEG, 8, zr);
                    self.c.cmov(x::CC_G, 8, yr, zr);
                }
                self.c.alu_rr(x::ADD, 8, xr, yr);
            }
            self.st_lane(xr, d, k, lt, false);
        }
    }

    // Integer reduction `c` (a sum, `and`, `or`, `xor`, a minimum or maximum, signed with `sg`) of 16-byte
    // vector `v` (lanes of `lb` bits) into instruction `i`, at the lanes' width: the vector's halves
    // combined in xmm registers until one lane holds the result (`pshufd` across the qwords and dwords,
    // `pshuflw` across the words, `psrlw` across the bytes), then one `movd`, as LLVM's x86 lowering of
    // `vector.reduce`. The minimum or maximum of two 64-bit lanes is one `cmov` of both lanes.
    fn reduce_halves(self: &mut Self, i: u32, c: u8, sg: bool, v: Value, lb: u32) {
        let rv = self.vec_use(v, self.vs0) - V0;
        let ta = self.tmp(true) - V0;
        let ext = c == core::SIMD_REDUCE_MIN || c == core::SIMD_REDUCE_MAX;
        let lo = c == core::SIMD_REDUCE_MIN;
        if ext && lb == 64 {
            let rd = self.def(i);
            self.c.movd_from_x(8, rd, rv);
            self.shuf(0x66, ta, rv, 0x4E);
            self.c.movd_from_x(8, S0, ta);
            self.c.alu_rr(x::CMP, 8, S0, rd);
            let below = if sg {
                x::CC_L
            } else {
                x::CC_B
            };
            let above = if sg {
                x::CC_G
            } else {
                x::CC_A
            };
            self.c.cmov(
                if lo {
                    below
                } else {
                    above
                },
                8,
                rd,
                S0,
            );
            return;
        }
        let tb = self.tmp(true) - V0;
        // paddb/w/d/q, pand, por, pxor.
        let op: u32 = if c == core::SIMD_REDUCE_AND {
            0x0FDB
        } else if c == core::SIMD_REDUCE_OR {
            0x0FEB
        } else if c == core::SIMD_REDUCE_XOR {
            0x0FEF
        } else if lb == 8 {
            0x0FFC
        } else if lb == 16 {
            0x0FFD
        } else if lb == 32 {
            0x0FFE
        } else {
            0x0FD4
        };
        // ta = the qwords swapped, combined with v; each step the lanes' halves in the low half.
        self.shuf(0x66, ta, rv, 0x4E);
        if ext {
            self.lane_ext(lo, sg, lb, false, ta, ta, rv);
        } else {
            self.lane_op(op, ta, rv);
        }
        if lb <= 32 {
            self.shuf(0x66, tb, ta, 0xB1);
            if ext {
                self.lane_ext(lo, sg, lb, false, ta, ta, tb);
            } else {
                self.lane_op(op, ta, tb);
            }
        }
        if lb <= 16 {
            self.shuf(0xF2, tb, ta, 0xB1);
            if ext {
                self.lane_ext(lo, sg, lb, false, ta, ta, tb);
            } else {
                self.lane_op(op, ta, tb);
            }
        }
        if lb == 8 {
            // psrlw tb, ta, 8.
            if self.avx {
                self.c.vex_rr(0x66, 1, 0x71, false, false, 2, tb, ta);
            } else {
                self.c.vmov(tb, ta);
                self.c.sse_rr(0x66, 0x0F71, 2, tb);
            }
            self.c.byte(8);
            if ext {
                self.lane_ext(lo, sg, lb, false, ta, ta, tb);
            } else {
                self.lane_op(op, ta, tb);
            }
        }
        let rd = self.def(i);
        self.c.movd_from_x(
            if lb == 64 {
                8
            } else {
                4
            },
            rd,
            ta,
        );
    }

    // xmm `dst` = the lanes' minimum (`lo`) or maximum of xmm `a` and `src`, lanes of `lb` (8 to 32) bits,
    // signed with `sg`; ymm registers with `y` (AVX2); `src` kept, `a` too unless it is `dst`, which it is
    // without AVX. One `pmin`/`pmax` where the target has it (SSE2: signed words, unsigned bytes; SSE4.1 and
    // AVX2: all of them); unsigned words through the saturating difference; else a `pcmpgt` mask (of the lanes with
    // the sign bit flipped, unsigned) that picks each lane by `src ^ ((dst ^ src) & mask)`.
    fn lane_ext(self: &mut Self, lo: bool, sg: bool, lb: u32, y: bool, dst: u8, a: u8, src: u8) {
        if self.avx {
            // pminsw, pminub (0F EA, DA); pminsb, pminsd, pminuw, pminud (0F38 38..3B); the maximum 4 above
            // (0F EE, DE: 4 above too).
            let (mm, base): (u32, u32) = if lb == 16 && sg {
                (1, 0xEA)
            } else if lb == 8 && !sg {
                (1, 0xDA)
            } else if lb == 8 {
                (2, 0x38)
            } else if lb == 32 && sg {
                (2, 0x39)
            } else if lb == 16 {
                (2, 0x3A)
            } else {
                (2, 0x3B)
            };
            self.c.vex_rr(
                0x66,
                mm,
                base + if lo {
                    0
                } else {
                    4
                },
                false,
                y,
                dst,
                a,
                src,
            );
            return;
        }
        if unsafe (*self.pkg).sse41 && lb <= 32 && !(lb == 16 && sg || lb == 8 && !sg) {
            // SSE4.1: pminsb, pminsd, pminuw, pminud (66 0F38 38..3B); the maximum 4 above.
            let base: u32 = if lb == 8 {
                0x38
            } else if lb == 32 && sg {
                0x39
            } else if lb == 16 {
                0x3A
            } else {
                0x3B
            };
            self.c.sse_rr(0x66, 0x0F3800 + base + (!lo) as u32 * 4, dst, src);
            return;
        }
        if lb == 16 && sg || lb == 8 && !sg {
            // pminsw/pmaxsw, pminub/pmaxub.
            let op: u32 = if lb == 16 {
                if lo {
                    0x0FEA
                } else {
                    0x0FEE
                }
            } else if lo {
                0x0FDA
            } else {
                0x0FDE
            };
            self.c.sse_rr(0x66, op, dst, src);
            return;
        }
        // The temporaries end here: a reduction's later steps reuse them.
        let tmps = self.tmps;
        if lb == 16 {
            // max = (dst -sat src) + src; min = dst - (dst -sat src).
            if lo {
                let d = self.tmp(true) - V0;
                self.c.vmov(d, dst);
                self.c.sse_rr(0x66, 0x0FD9, d, src);
                self.c.sse_rr(0x66, 0x0FF9, dst, d);
                self.tmps = tmps;
            } else {
                self.c.sse_rr(0x66, 0x0FD9, dst, src);
                self.c.sse_rr(0x66, 0x0FFD, dst, src);
            }
            return;
        }
        // mask = (max ? dst : src) > (max ? src : dst): the lanes that keep `dst`.
        let (hi, other) = if lo {
            (src, dst)
        } else {
            (dst, src)
        };
        let gt: u32 = if lb == 8 {
            0x0F64
        } else {
            0x0F66
        };
        let m = self.tmp(true) - V0;
        self.c.vmov(m, hi);
        if sg {
            self.c.sse_rr(0x66, gt, m, other);
        } else {
            // Both sides with the sign bit flipped: s = 0x80000000 in each lane (pcmpeqd, pslld 31).
            let s = self.tmp(true) - V0;
            self.c.sse_rr(0x66, 0x0F76, s, s);
            self.c.sse_rr(0x66, 0x0F72, 6, s);
            self.c.byte(31);
            self.c.sse_rr(0x66, 0x0FEF, m, s);
            self.c.sse_rr(0x66, 0x0FEF, s, other);
            self.c.sse_rr(0x66, gt, m, s);
        }
        self.c.sse_rr(0x66, 0x0FEF, dst, src);
        self.c.sse_rr(0x66, 0x0FDB, dst, m);
        self.c.sse_rr(0x66, 0x0FEF, dst, src);
        self.tmps = tmps;
    }

    // xmm `dst` = xmm `src` shuffled by `imm`: `pshufd` (prefix 0x66) or `pshuflw` (0xF2), VEX-encoded
    // under AVX.
    fn shuf(self: &mut Self, pfx: u32, dst: u8, src: u8, imm: u32) {
        if self.avx {
            self.c.vex_rr(pfx, 1, 0x70, false, false, dst, 0, src);
        } else {
            self.c.sse_rr(pfx, 0x0F70, dst, src);
        }
        self.c.byte(imm);
    }

    // xmm `dst` = `dst` op `src` for the 66-prefixed lane operation `op` (`0F xx`), VEX-encoded under AVX.
    fn lane_op(self: &mut Self, op: u32, dst: u8, src: u8) {
        if self.avx {
            self.c.vex_rr(0x66, 1, op & 0xFF, false, false, dst, dst, src);
        } else {
            self.c.sse_rr(0x66, op, dst, src);
        }
    }

    // A float reduction (`vreduce`) of rule `c` into an `at` result over the `n` lanes (of `lt`) of operand 0
    // (and 1 for `dot`).
    fn reduce_float(
        self: &mut Self,
        i: u32,
        c: u8,
        add: bool,
        mul: bool,
        dot: bool,
        at: u8,
        ops: &[Value; 4],
        lt: u8,
        n: u32,
    ) {
        let dd = at == T_F64;
        let acc = self.tmp(true);
        let fa = self.tmp(true);
        let fb = self.tmp(true);
        let fo = if add {
            O_FADD
        } else {
            O_FMUL
        };
        if c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_MUL_TREE {
            // Halves in a scratch copy: lane j of the lower half with lane j of the upper, to one lane.
            let eb = type_bytes(lt, 8);
            let s = self.slot_alloc(n * eb, 16) as i64;
            let (b0, o0) = self.mloc(ops[0]);
            self.copy_mem(x::RSP, s, b0, o0, n * eb);
            let mut h = n / 2;
            while h != 0 {
                for j in 0..h {
                    self.c.vload(eb, fa - V0, x::at(x::RSP, (s + (j * eb) as i64) as i32));
                    self.c.vload(eb, fb - V0, x::at(x::RSP, (s + ((j + h) * eb) as i64) as i32));
                    self.c.sse_rr(fpfx(dd), fop(fo), fa - V0, fb - V0);
                    self.c.vstore(eb, fa - V0, x::at(x::RSP, (s + (j * eb) as i64) as i32));
                }
                h = h / 2;
            }
            let rd = self.def(i);
            self.c.vload(eb, rd - V0, x::at(x::RSP, s as i32));
            self.free_slots.push((n * eb) as u64 << 32 | (s as u32) as u64);
            return;
        }
        // A sum folds from -0.0, a product from 1.0; the extremes from lane 0.
        let fold = add || mul;
        let neg0 = if dd {
            0x8000000000000000u64
        } else {
            0x80000000u64
        };
        if fold {
            self.fconst(
                acc,
                dd,
                if add {
                    neg0
                } else {
                    float_bits(at, 1)
                },
            );
        } else {
            self.ld_lane(acc, ops[0], 0, lt, false, false);
        }
        let from: u32 = if fold {
            0
        } else {
            1
        };
        let lo = c == core::SIMD_REDUCE_MIN_NUM || c == core::SIMD_REDUCE_MINIMUM;
        for k in from..n {
            self.ld_lane(fa, ops[0], k, lt, false, false);
            if dot {
                // The product in the result's type.
                self.ld_lane(fb, ops[1], k, lt, false, false);
                if at != lt {
                    self.c.sse_rr(0xF3, 0x0F5A, fa - V0, fa - V0);
                    self.c.sse_rr(0xF3, 0x0F5A, fb - V0, fb - V0);
                }
                self.c.sse_rr(fpfx(dd), 0x0F59, fa - V0, fb - V0);
            }
            if fold {
                self.c.sse_rr(fpfx(dd), fop(fo), acc - V0, fa - V0);
            } else {
                // The kept operand itself, as the lane rule's.
                self.fminmax(dd, lo, c >= core::SIMD_REDUCE_MINIMUM, false, acc, acc, fa);
            }
        }
        let rd = self.def(i);
        self.c.vmov(rd - V0, acc - V0);
    }

    // `reduce_add_ovf` (`add`) or `reduce_mul_ovf` of vector `v` (lanes of `lt`, signed `sg`): 1 when the
    // exact sum or product does not fit the lane type (the evaluator's `exact_fits`).
    fn reduce_ovf(self: &mut Self, i: u32, add: bool, v: Value, lt: u8, sg: bool) {
        let lb = type_bits(lt, 8);
        let n = lanes(self.vt(v));
        if add {
            let xr = self.tmp(false);
            let yr = self.tmp(false);
            let lo = self.tmp(false);
            let hi = self.tmp(false);
            // The sum in 128 bits: lo, and hi taking each lane's sign and carry.
            self.c.alu_rr(x::XOR, 4, lo, lo);
            self.c.alu_rr(x::XOR, 4, hi, hi);
            for k in 0..n {
                self.ld_lane(xr, v, k, lt, sg, false);
                if sg {
                    self.c.mov_rr(8, yr, xr);
                    self.c.shift_ri(x::SAR, 8, yr, 63);
                } else {
                    self.c.alu_rr(x::XOR, 4, yr, yr);
                }
                self.c.alu_rr(x::ADD, 8, lo, xr);
                self.c.alu_rr(x::ADC, 8, hi, yr);
            }
            let rd = self.def(i);
            // Not fitting: signed, hi is not lo's sign or lo leaves the lane; unsigned, hi is not 0 or lo
            // leaves the lane.
            if sg {
                self.c.mov_rr(8, S0, lo);
                self.c.shift_ri(x::SAR, 8, S0, 63);
                self.c.alu_rr(x::CMP, 8, hi, S0);
                self.c.setcc(x::CC_NE, rd);
                if lb < 64 {
                    self.c.ext(lb / 8, 8, true, S0, lo);
                    self.c.alu_rr(x::CMP, 8, S0, lo);
                    self.c.setcc(x::CC_NE, S1);
                    self.c.alu_rr(x::OR, 1, rd, S1);
                }
            } else {
                self.c.test_rr(8, hi, hi);
                self.c.setcc(x::CC_NE, rd);
                if lb < 64 {
                    self.c.mov_rr(8, S0, lo);
                    self.c.shift_ri(x::SHR, 8, S0, lb);
                    self.c.setcc(x::CC_NE, S1);
                    self.c.alu_rr(x::OR, 1, rd, S1);
                }
            }
            self.c.ext(1, 4, false, rd, rd);
            self.va.index_mut(i as usize).clean = true;
            return;
        }
        // The product of the magnitudes in rax: `hi` gathers the bits past 64 (rdx), `yr` the sign, `zr` the
        // zero lanes.
        self.vacate(x::RAX);
        self.vacate(x::RDX);
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        let zr = self.tmp(false);
        let hi = self.tmp(false);
        self.c.mov_ri(x::RAX, 1);
        self.c.alu_rr(x::XOR, 4, hi, hi);
        self.c.alu_rr(x::XOR, 4, yr, yr);
        self.c.alu_rr(x::XOR, 4, zr, zr);
        for k in 0..n {
            self.ld_lane(xr, v, k, lt, sg, false);
            if sg {
                self.c.mov_rr(8, S0, xr);
                self.c.shift_ri(x::SAR, 8, S0, 63);
                self.c.alu_rr(x::XOR, 8, yr, S0);
                self.c.mov_rr(8, S0, xr);
                self.c.unary(x::NEG, 8, S0);
                self.c.cmov(x::CC_NS, 8, xr, S0);
            }
            self.c.test_rr(8, xr, xr);
            self.c.setcc(x::CC_E, S1);
            self.c.alu_rr(x::OR, 1, zr, S1);
            self.c.unary(x::MUL, 8, xr);
            self.c.alu_rr(x::OR, 8, hi, x::RDX);
        }
        // The lanes are read: the result may take `xr`.
        self.tmps &= ~bit(xr);
        let rd = self.def(i);
        // Not fitting: past 64 bits, or the magnitude past the limit (the negative limit one more).
        let lim = if sg {
            1u64 << (lb - 1) as u64
        } else {
            trunc64(~0u64, lb)
        };
        self.c.mov_ri(S0, lim);
        self.c.alu_rr(x::CMP, 8, x::RAX, S0);
        self.c.setcc(x::CC_A, rd);
        if sg {
            // lo == lim fits only negative (`yr` all ones).
            self.c.setcc(x::CC_E, S1);
            self.c.mov_rr(4, S0, yr);
            self.c.unary(x::NOT, 4, S0);
            self.c.alu_rr(x::AND, 1, S1, S0);
            self.c.alu_rr(x::OR, 1, rd, S1);
        }
        self.c.test_rr(8, hi, hi);
        self.c.setcc(x::CC_NE, S1);
        self.c.alu_rr(x::OR, 1, rd, S1);
        // A zero lane: the product is 0, which fits.
        self.c.test_rr(1, zr, zr);
        self.c.setcc(x::CC_E, S1);
        self.c.alu_rr(x::AND, 1, rd, S1);
        self.c.ext(1, 4, false, rd, rd);
        self.va.index_mut(i as usize).clean = true;
    }

    // `arg_min` (`min`) or `arg_max` and their `_num` forms of vector `v`: the lowest lane whose value beats
    // every lane before it; a NaN lane never does, -0.0 is below +0.0; the lane count when none.
    fn reduce_arg(self: &mut Self, i: u32, min: bool, v: Value, lt: u8, sg: bool) {
        let n = lanes(self.vt(v));
        let lb = type_bits(lt, 8);
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        let rd = self.def(i);
        if !is_float(lt) {
            // The best value in `yr`; a strictly better lane takes over.
            let cc = if min && sg {
                x::CC_L
            } else if min {
                x::CC_B
            } else if sg {
                x::CC_G
            } else {
                x::CC_A
            };
            self.c.alu_rr(x::XOR, 4, rd, rd);
            self.ld_lane(yr, v, 0, lt, sg, false);
            for k in 1..n {
                self.ld_lane(xr, v, k, lt, sg, false);
                self.c.mov_ri(S1, k);
                self.c.alu_rr(x::CMP, 8, xr, yr);
                self.c.cmov(cc, 8, yr, xr);
                self.c.cmov(cc, 8, rd, S1);
            }
            return;
        }
        let dd = lt == T_F64;
        let ucom = if dd {
            0x66u32
        } else {
            0u32
        };
        let fa = self.tmp(true);
        let fb = self.tmp(true);
        self.c.mov_ri(rd, n);
        let mut skips = Vector::<u32>::new();
        let mut takes = Vector::<u32>::new();
        for k in 0..n {
            skips.truncate(0);
            takes.truncate(0);
            self.ld_lane(fa, v, k, lt, false, false);
            self.c.sse_rr(ucom, 0x0F2E, fa - V0, fa - V0);
            skips.push(self.c.jcc32(x::CC_P));
            if k != 0 {
                // No best yet, or strictly beyond the best: take; equal with the lane's sign on the min
                // side: take; else skip.
                self.c.alu_ri(x::CMP, 8, rd, n as i32);
                takes.push(self.c.jcc32(x::CC_E));
                if min {
                    self.c.sse_rr(ucom, 0x0F2E, fb - V0, fa - V0);
                } else {
                    self.c.sse_rr(ucom, 0x0F2E, fa - V0, fb - V0);
                }
                takes.push(self.c.jcc32(x::CC_A));
                skips.push(self.c.jcc32(x::CC_NE));
                self.c.movd_from_x(lb / 8, xr, fa - V0);
                self.c.movd_from_x(lb / 8, yr, fb - V0);
                self.c.alu_rr(x::XOR, 8, yr, xr);
                // Signs that differ (the zeros) and the lane negative for the min, positive for the max.
                self.c.bt_ri(yr, lb - 1);
                skips.push(self.c.jcc32(x::CC_AE));
                self.c.bt_ri(xr, lb - 1);
                skips.push(
                    self.c.jcc32(
                        if min {
                            x::CC_AE
                        } else {
                            x::CC_B
                        },
                    ),
                );
            }
            for q in 0..takes.len() {
                self.c.land(takes[q], self.c.len());
            }
            self.c.vmov(fb - V0, fa - V0);
            self.c.mov_ri(rd, k);
            for q in 0..skips.len() {
                self.c.land(skips[q], self.c.len());
            }
        }
    }

    // The index forms (`swizzle`, `shuffle`, `swizzle_or_zero`, `swizzle_oob`) and `compress`, `expand`
    // (the evaluator's `vrearrange`): lane bits move as they are.
    fn vrearrange(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let rule = core::simd_op(c).rule;
        let vt = if rule == core::SR_MASKED {
            tys[1]
        } else {
            tys[0]
        };
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let n = lanes(vt);
        let s = eb.trailing_zeros() as u8;
        let xr = self.tmp(false);
        let ix = self.tmp(false);
        let ad = self.tmp(false);
        if rule == core::SR_MASKED {
            // From `fill`, then compress: the active lanes of v from position 0; expand: active lane j takes
            // the next packed lane.
            let d = self.mdef(i);
            let (bf, of) = self.mloc(ops[2]);
            self.copy_mem(x::RSP, d, bf, of, n * eb);
            let m = self.reg(ops[0]);
            self.c.alu_rr(x::XOR, 4, ix, ix);
            // The packed side's base address: the result for compress, v for expand.
            if c == core::SIMD_COMPRESS {
                self.c.lea(ad, x::at(x::RSP, d as i32));
            } else {
                let (bv, ov) = self.mloc(ops[1]);
                self.c.lea(ad, x::at(bv, ov as i32));
            }
            for k in 0..n {
                self.c.bt_ri(m, k);
                let skip = self.c.jcc32(x::CC_AE);
                if c == core::SIMD_COMPRESS {
                    self.ld_lane(xr, ops[1], k, lt, false, true);
                    self.c.store(eb, xr, x::ix(ad, ix, s, 0));
                } else {
                    self.c.load(eb, false, xr, x::ix(ad, ix, s, 0));
                    self.st_lane(xr, d, k, lt, true);
                }
                self.c.alu_ri(x::ADD, 8, ix, 1);
                self.c.land(skip, self.c.len());
            }
            return;
        }
        let cnt = if rule == core::SR_INDEX {
            self.b().pool[t.c as usize]
        } else {
            lanes(tys[1])
        };
        if c == core::SIMD_SWIZZLE_OOB {
            // The mask of the lanes whose index is past the lanes.
            let mk = self.def(i);
            self.c.alu_rr(x::XOR, 4, mk, mk);
            let ilt = lane_type(tys[1]);
            for k in 0..cnt {
                self.ld_lane(ix, ops[1], k, ilt, false, false);
                self.c.alu_ri(x::CMP, 8, ix, n as i32);
                self.mask_bit(mk, x::CC_AE, k);
            }
            return;
        }
        let d = self.mdef(i);
        if rule == core::SR_INDEX {
            for k in 0..cnt {
                let j = self.b().pool[(t.c + 1 + k) as usize];
                if j < n {
                    self.ld_lane(xr, ops[0], j, lt, false, true);
                } else if c == core::SIMD_SHUFFLE {
                    self.ld_lane(xr, ops[1], j - n, lt, false, true);
                } else {
                    self.c.alu_rr(x::XOR, 4, xr, xr);
                }
                self.st_lane(xr, d, k, lt, true);
            }
            return;
        }
        // `swizzle_or_zero`: lane k is v[idx[k]], or 0 past the lanes (the index clamped before the load).
        let ilt = lane_type(tys[1]);
        let (bv, ov) = self.mloc(ops[0]);
        self.c.lea(ad, x::at(bv, ov as i32));
        self.c.alu_rr(x::XOR, 4, S1, S1);
        for k in 0..cnt {
            self.ld_lane(ix, ops[1], k, ilt, false, false);
            self.c.alu_ri(x::CMP, 8, ix, n as i32);
            self.c.cmov(x::CC_AE, 8, ix, S1);
            // The flags of the comparison stay through the load.
            self.c.load(eb, false, xr, x::ix(ad, ix, s, 0));
            self.c.cmov(x::CC_AE, 8, xr, S1);
            self.st_lane(xr, d, k, lt, true);
        }
    }
}

extend Gen {
    // The text of body message `m`.
    const fn msg_text(self: &Self, m: u32) str {
        let p = unsafe &*self.pkg;
        return p.spell(p.msgs[self.b().msgs[m as usize] as usize]);
    }

    // Assemble template `text` onto the code, its symbols as relocations.
    fn asm_text(self: &mut Self, text: str) bool {
        let mut rels = Vector::<asmr::InlRel>::new();
        let mut e = String::new();
        if !asmr::Asm::inline_x64(text, &mut self.c.b, &mut rels, &mut e) {
            self.err.format_into("inline assembly: {}", e.as_str());
            return false;
        }
        for k in 0..rels.len() {
            let s = self.obj().sym(&rels[k].name);
            self.rels.push(CRel { at: rels[k].at, kind: rels[k].kind, sym: s, addend: rels[k].addend });
        }
        return true;
    }

    // System operation `t` (`i`, `O_SYS`): the instructions the inline assembly it replaces held. The
    // ones that write fixed registers take rax, rcx and rdx as a division does; CPUID's rbx, which may be
    // a callee-saved home, goes through r11.
    fn sys(self: &mut Self, i: u32, t: Inst) bool {
        let s = t.aux;
        if s == SYS_BARRIER || s == SYS_KEEP {
            return true;
        }
        if s == SYS_SPIN {
            self.c.byte(0xF3);
            self.c.byte(0x90); // pause
            return true;
        }
        if s == SYS_CYCLES || s == SYS_XGETBV {
            if s == SYS_XGETBV {
                self.vacate(x::RCX);
                let ra = self.reg(t.a);
                self.c.mov_rr(4, x::RCX, ra);
            }
            self.vacate(x::RAX);
            self.vacate(x::RDX);
            self.c.byte(0x0F);
            if s == SYS_CYCLES {
                self.c.byte(0x31); // rdtsc
            } else {
                self.c.byte(0x01);
                self.c.byte(0xD0); // xgetbv
            }
            self.c.shift_ri(x::SHL, 8, x::RDX, 32);
            self.c.alu_rr(x::OR, 8, x::RDX, x::RAX);
            self.result_in(i, x::RDX);
            return true;
        }
        if s == SYS_FPSAVE {
            let ra = self.reg(t.a);
            self.c.rm(0, 0x0FAE, false, 3, x::at(ra, 0), false); // stmxcsr (ra)
            self.c.rm(0, 0xD9, false, 7, x::at(ra, 4), false); // fnstcw 4(ra)
            return true;
        }
        if s == SYS_GSLOAD {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            self.c.rm(0x65, 0x8B, true, rd, x::at(ra, 0), false); // mov %gs:(ra), rd
            return true;
        }
        if s == SYS_GSSTORE {
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            self.c.rm(0x65, 0x89, true, rb, x::at(ra, 0), false); // mov rb, %gs:(ra)
            return true;
        }
        if s == SYS_CPUID {
            self.vacate(x::RAX);
            self.vacate(x::RCX);
            self.vacate(x::RDX);
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let mut ra = self.reg(t.a);
            if ra == x::RBX {
                self.c.mov_rr(8, S0, ra);
                ra = S0;
            }
            self.c.mov_rr(4, x::RAX, rb);
            self.c.mov_rr(4, x::RCX, rc);
            self.c.mov_rr(8, S1, x::RBX);
            self.c.byte(0x0F);
            self.c.byte(0xA2); // cpuid
            self.c.rm(0, 0x89, false, x::RAX, x::at(ra, 0), false);
            self.c.rm(0, 0x89, false, x::RBX, x::at(ra, 4), false);
            self.c.rm(0, 0x89, false, x::RCX, x::at(ra, 8), false);
            self.c.rm(0, 0x89, false, x::RDX, x::at(ra, 12), false);
            self.c.mov_rr(8, x::RBX, S1);
            return true;
        }
        return self.refuse("a system operation of another processor");
    }

    // Inline assembly (`O_ASM`), as GCC compiles it: an operand of a named register (`a`, `b`, `c`,
    // `d`, `S`, `D`) takes it, the others take the free caller-saved ones in order, past the clobbered
    // ones (a memory output the register of its address, a memory input its stack slot, a matching input
    // its output's); a value in one of those or in a clobbered register goes to its home first, the
    // others stay. The template's operand references name them, and each output goes to its address
    // after. A clobbered or named callee-saved register
    // is saved by the prologue and, when it holds a value, around the statement. The flags are
    // clobbered, as on every x86-64 asm.
    fn asm_inst(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let r = t.c;
        let no = asm_nout(b, r);
        let n = no + asm_nin(b, r);
        let mut clob: u64 = 0;
        for k in 0..asm_nclob(b, r) {
            let cr = x64_clobber(self.msg_text(asm_clob(b, r, k)));
            if cr != NOREG {
                clob |= bit(cr);
            }
        }
        // Per operand: its class (`AK_*`), register (or slot offset for a memory input), type, immediate.
        let mut cls = Vector::<u8>::new();
        let mut reg = Vector::<u8>::new();
        let mut tys = Vector::<u8>::new();
        let mut imm = Vector::<i64>::new();
        let mut plus = Vector::<bool>::new();
        let mut ties = Vector::<u32>::new();
        let mut early = Vector::<bool>::new();
        let mut taken: u64 = clob;
        let mut in_named: u64 = 0;
        // The named registers first.
        for k in 0..n {
            let con = if k < no {
                self.msg_text(asm_out_con(b, r, k))
            } else {
                self.msg_text(asm_in_con(b, r, k - no))
            };
            let v = b.pool[(t.a + k) as usize];
            let ty = if k < no {
                asm_out_ty(b, r, k)
            } else {
                self.vt(v)
            };
            let mut c: u8 = 0xFF;
            let mut rg: u8 = NOREG;
            let mut pl = false;
            let mut ec = false;
            let mut tie: u32 = NONE;
            for j in 0..con.len() {
                let ch = con.byte_at(j);
                let named = switch ch {
                    b'a' => x::RAX,
                    b'b' => x::RBX,
                    b'c' => x::RCX,
                    b'd' => x::RDX,
                    b'S' => x::RSI,
                    b'D' => x::RDI,
                    _ => NOREG,
                };
                if ch == b'+' {
                    pl = true;
                } else if ch == b'&' {
                    ec = true;
                } else if named != NOREG {
                    c = AK_GP;
                    rg = named;
                } else if ch == b'r' || ch == b'q' || ch == b'Q' || ch == b'R' || ch == b'g' {
                    c = AK_GP;
                } else if ch == b'x' || ch == b'v' {
                    c = AK_FP;
                } else if ch == b'm' || ch == b'o' {
                    c = AK_MEM;
                } else if ch == b'i' || ch == b'n' || ch == b'e' || ch >= b'I' && ch <= b'N' {
                    c = AK_IMM;
                } else if ch >= b'0' && ch <= b'9' && k >= no {
                    tie = ch - b'0';
                }
            }
            if tie != NONE {
                if tie >= no || cls[tie as usize] == AK_MEM {
                    return self.refuse("an asm input matches no register output");
                }
                c = cls[tie as usize];
                rg = reg[tie as usize];
            }
            if c == 0xFF {
                return self.refuse("an asm constraint this generator does not take");
            }
            if c == AK_FP && !is_float(ty) || k < no && c == AK_IMM || c == AK_GP && is_float(ty) {
                return self.refuse("an asm operand of the wrong class for its type");
            }
            // An input naming the register of an output that is neither early-clobber nor read shares it, as a
            // matching input does: it is read before the output is written (GCC's rule).
            if rg != NOREG && tie == NONE && k >= no && (taken & ~clob & bit(rg)) != 0 && (in_named & bit(rg)) == 0 {
                for j in 0..no {
                    if reg[j as usize] == rg && !early[j as usize] && !plus[j as usize] {
                        tie = j;
                    }
                }
            }
            if rg != NOREG && tie == NONE {
                if (taken & bit(rg)) != 0 {
                    return self.refuse("two asm operands name one register, or a clobbered one");
                }
                taken |= bit(rg);
                if k >= no {
                    in_named |= bit(rg);
                }
            }
            let mut kv: u64 = 0;
            if c == AK_IMM && !self.const_of(v, &mut kv) {
                return self.refuse("an asm immediate operand of no constant value");
            }
            cls.push(c);
            reg.push(rg);
            tys.push(ty);
            imm.push(kv as i64);
            plus.push(pl);
            ties.push(tie);
            early.push(ec);
        }
        // Then the free caller-saved ones: not the scratch registers r10, r11 and the vector two. A
        // matching input takes its output's, which comes first.
        let gp_pool: u64 = self.xalloc & ~bit(S0) & ~bit(S1);
        let fp_pool: u64 = self.valloc & ~bit(self.vs0) & ~bit(self.vs1);
        for k in 0..n as usize {
            let c = cls[k];
            if ties[k] != NONE {
                reg.set(k, reg[ties[k] as usize]);
                continue;
            }
            if reg[k] != NOREG || c == AK_IMM || c == AK_MEM && k >= no as usize {
                continue;
            }
            let free = if c == AK_FP {
                fp_pool
            } else {
                gp_pool
            } & ~taken;
            if free == 0 {
                return self.refuse("an asm with more register operands than the free registers");
            }
            let rg = free.trailing_zeros() as u8;
            taken |= bit(rg);
            reg.set(k, rg);
        }
        // The registers the statement writes: the caller-saved ones free, the callee-saved ones kept.
        let mut ev = taken & (self.xalloc | self.valloc);
        // Each step clears one register's bit: at most 64 steps.
        while ev != 0 {
            let er = ev.trailing_zeros() as u8;
            ev &= ev - 1;
            self.evict(er);
        }
        let keep = taken & (self.xfix | self.vsave());
        self.csr |= keep;
        // A callee-saved register that holds a value is saved to a slot of its own around the statement.
        let mut saved = Vector::<(u8, i64)>::new();
        let mut m = keep & self.held;
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let cr = m.trailing_zeros() as u8;
            m &= m - 1;
            let off = self.slot_alloc(16, 16) as i64;
            self.save_reg(cr, off, true);
            saved.push((cr, off));
        }
        // The operands into their registers, those in callee-saved ones last: a value another operand
        // reads may live in one.
        let mut mem_slots = Vector::<i64>::new();
        for pass in 0..2u32 {
            for k in 0..n {
                let rg = reg[k as usize];
                let late = rg != NOREG && (keep & bit(rg)) != 0;
                if late != (pass == 1) {
                    continue;
                }
                let v = b.pool[(t.a + k) as usize];
                let c = cls[k as usize];
                if k < no {
                    if c == AK_MEM {
                        self.materialize(v, rg);
                    } else if plus[k as usize] {
                        self.materialize(v, S0);
                        self.ld(tys[k as usize], rg, x::at(S0, 0));
                    }
                    continue;
                }
                if c == AK_MEM {
                    let off = self.slot_alloc(16, 16) as i64;
                    let tr = if is_float(tys[k as usize]) {
                        self.vs0
                    } else {
                        S0
                    };
                    self.materialize(v, tr);
                    self.st(tys[k as usize], tr, x::at(x::RSP, off as i32));
                    mem_slots.push(off);
                    imm.set(k as usize, off);
                } else if c != AK_IMM {
                    self.materialize(v, rg);
                }
            }
        }
        // The template with its operand references named.
        let tpl = self.msg_text(asm_template(b, r));
        let mut text = String::new();
        let mut j: usize = 0;
        while j < tpl.len() {
            let ch = tpl.byte_at(j);
            j += 1;
            if ch != b'%' || j >= tpl.len() {
                text.push_byte(ch);
                continue;
            }
            let c2 = tpl.byte_at(j);
            if c2 == b'%' {
                text.push_byte(b'%');
                j += 1;
                continue;
            }
            if c2 == b'=' {
                text.push_u64(i);
                j += 1;
                continue;
            }
            let mut md: u8 = 0;
            if c2 >= b'a' && c2 <= b'z' || c2 == b'P' {
                md = c2;
                j += 1;
            }
            let st = j;
            let mut k: u32 = 0;
            while j < tpl.len() && tpl.byte_at(j) >= b'0' && tpl.byte_at(j) <= b'9' {
                k = k * 10 + (tpl.byte_at(j) - b'0');
                j += 1;
            }
            if j == st || k >= n {
                return self.refuse("an asm template names an operand it does not have");
            }
            if !x64_operand_text(
                &mut text,
                cls[k as usize],
                reg[k as usize],
                tys[k as usize],
                imm[k as usize],
                md,
                k < no,
            ) {
                return self.refuse("an asm operand modifier this generator does not take");
            }
        }
        if !self.asm_text(&text) {
            return false;
        }
        for k in 0..mem_slots.len() {
            self.free_slots.push(16u64 << 32 | (mem_slots[k] as u32) as u64);
        }
        // The outputs in callee-saved registers to slots, those registers back, then every output to
        // its address.
        let mut out_slot = Vector::<i64>::new();
        for k in 0..no {
            let rg = reg[k as usize];
            if cls[k as usize] != AK_MEM && (keep & bit(rg)) != 0 {
                let off = self.slot_alloc(16, 16) as i64;
                self.st(tys[k as usize], rg, x::at(x::RSP, off as i32));
                out_slot.push(off);
            } else {
                out_slot.push(-1);
            }
        }
        for k in 0..saved.len() {
            let (cr, off) = saved[k];
            self.save_reg(cr, off, false);
            self.free_slots.push(16u64 << 32 | (off as u32) as u64);
        }
        for k in 0..no {
            if cls[k as usize] == AK_MEM {
                continue;
            }
            let ty = tys[k as usize];
            self.materialize(b.pool[(t.a + k) as usize], S0);
            let mut rg = reg[k as usize];
            let os = out_slot[k as usize];
            if os >= 0 {
                rg = S1;
                self.ld(ty, rg, x::at(x::RSP, os as i32));
                self.free_slots.push(16u64 << 32 | (os as u32) as u64);
            }
            self.st(ty, rg, x::at(S0, 0));
        }
        return true;
    }

    // Save (`store`) or restore callee-saved register `r` at slot `off`, all its bits.
    fn save_reg(self: &mut Self, r: u8, off: i64, store: bool) {
        let m = x::at(x::RSP, off as i32);
        if r >= V0 {
            if store {
                self.c.vstore(16, r - V0, m);
            } else {
                self.c.vload(16, r - V0, m);
            }
        } else if store {
            self.c.store(8, r, m);
        } else {
            self.c.load(8, false, r, m);
        }
    }

    // The vector registers the ABI saves.
    const fn vsave(self: &Self) u64 {
        return if self.win {
            VSAVE_WIN
        } else {
            0u64
        };
    }

    // A naked function: its templates' code alone.
    fn naked(self: &mut Self, s: u32) bool {
        let b = self.b();
        for i in 0..b.insts.len() {
            if b.insts[i].op != O_ASM {
                continue;
            }
            let tpl = String::from_str(self.msg_text(asm_template(b, b.insts[i].c)));
            if !self.asm_text(&tpl) {
                return false;
            }
        }
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true)
        } else if ps.cold {
            o.named(self.cold_text(), true)
        } else {
            ob::S_TEXT
        };
        if sec == ob::NOSEC {
            return self.refuse("too many sections");
        }
        let mut fl = ob::SF_FUNC | if ps.linkage == SL_GLOBAL && !self.local {
            ob::SF_GLOBAL
        } else {
            0
        };
        if ps.used {
            fl |= ob::SF_USED;
        }
        let at = o.define(k2, sec, 4, self.c.len(), fl);
        o.put(sec, self.c.b[0..self.c.b.len()]);
        for q in 0..self.rels.len() {
            let rl = self.rels[q];
            o.reloc(sec, rl.kind, at as u32 + rl.at, rl.sym, rl.addend);
        }
        return true;
    }
}

// Inline assembly operand classes.
const AK_GP: u8 = 0; // a general register
const AK_FP: u8 = 1; // an xmm register
const AK_MEM: u8 = 2; // memory: at the address a register holds (an output), or a stack slot (an input)
const AK_IMM: u8 = 3; // an immediate

// Name operand `k` of class `c` (register `rg`; for a memory input the slot offset `kv`; for an
// immediate its value `kv`) and type `ty` into `o`, under modifier `md` (0: none; `b`, `h`, `w`, `k`,
// `q` for a general register's width, `x`, `t`, `g` for a vector register's, `c` and `P` for a bare
// constant); false for a modifier the class does not take.
fn x64_operand_text(o: &mut String, c: u8, rg: u8, ty: u8, kv: i64, md: u8, out: bool) bool {
    if c == AK_IMM {
        if md == 0 {
            o.push_byte(b'$');
        } else if md != b'c' && md != b'P' {
            return false;
        }
        o.push_i64(kv);
        return true;
    }
    if c == AK_MEM {
        if md != 0 {
            return false;
        }
        if out {
            o.push_byte(b'(');
            gp_name(o, rg, 8);
            o.push_byte(b')');
        } else {
            o.format_into("{}(%rsp)", kv);
        }
        return true;
    }
    if c == AK_FP {
        let l = switch md {
            0 | b'x' => "xmm",
            b't' => "ymm",
            b'g' => "zmm",
            _ => "",
        };
        if l.len() == 0 {
            return false;
        }
        o.format_into("%{}{}", l, rg - V0);
        return true;
    }
    let size: u32 = switch md {
        b'b' => 1u32,
        b'h' => 0u32,
        b'w' => 2u32,
        b'k' => 4u32,
        b'q' => 8u32,
        0 => type_bytes(ty, 8),
        _ => 99u32,
    };
    if size == 99 || size == 0 && rg > x::RBX {
        return false;
    }
    if size == 0 {
        o.push_str(
            switch rg {
                0 => "%ah",
                1 => "%ch",
                2 => "%dh",
                _ => "%bh",
            },
        );
        return true;
    }
    gp_name(o, rg, size);
    return true;
}

// `%` and the name of general register `r` of `size` bytes.
fn gp_name(o: &mut String, r: u8, size: u32) {
    let n64: [str<'static>; 16] = [
        "rax",
        "rcx",
        "rdx",
        "rbx",
        "rsp",
        "rbp",
        "rsi",
        "rdi",
        "r8",
        "r9",
        "r10",
        "r11",
        "r12",
        "r13",
        "r14",
        "r15",
    ];
    let base = unsafe n64[r as usize];
    o.push_byte(b'%');
    if r >= 8 {
        o.push_str(base);
        o.push_str(
            switch size {
                1 => "b",
                2 => "w",
                4 => "d",
                _ => "",
            },
        );
        return;
    }
    switch size {
        1 => {
            // al cl dl bl spl bpl sil dil
            o.push_str(base.slice(1, base.len()));
            if r < 4 {
                o.truncate(o.len() - 1);
            }
            o.push_byte(b'l');
        },
        2 => {
            o.push_str(base.slice(1, base.len()));
        },
        4 => {
            o.push_byte(b'e');
            o.push_str(base.slice(1, base.len()));
        },
        _ => {
            o.push_str(base);
        },
    }
}

// The register a clobber names (`rax`, `eax`, `ax`, `al`, `r12`, `r12d`, `xmm6`), NOREG for none
// (`memory`, `cc`, `dirflag`, `fpsr`, `flags`).
fn x64_clobber(s0: str) u8 {
    let s = if s0.starts_with("%") {
        s0.slice(1, s0.len())
    } else {
        s0
    };
    if s.starts_with("xmm") || s.starts_with("ymm") || s.starts_with("zmm") {
        return switch s.slice(3, s.len()).parse_u32() {
            Some(n) => if n < 16 {
                V0 + n as u8
            } else {
                NOREG
            },
            None => NOREG,
        };
    }
    let mut size: u32 = 8;
    while size != 0 {
        for r in 0..16u8 {
            let mut t = String::new();
            gp_name(&mut t, r, size);
            if t.as_str().slice(1, t.len()) == s {
                return r;
            }
        }
        size /= 2;
    }
    if s == "ah" || s == "bh" || s == "ch" || s == "dh" {
        return switch s.byte_at(0) {
            b'a' => x::RAX,
            b'b' => x::RBX,
            b'c' => x::RCX,
            _ => x::RDX,
        };
    }
    return NOREG;
}
