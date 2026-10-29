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

const NOREG: u8 = 0xFF;
const V0: u8 = 16; // register number of xmm0: general registers are 0..15

// Scratch registers; the vector ones are the ABI's (`Gen.vs0`, `Gen.vs1`).
const S0: u8 = 10; // r10
const S1: u8 = 11; // r11

// Homes.
const H_NONE: u8 = 0; // only a register
const H_SLOT: u8 = 1; // a stack slot at rsp + off
const H_ARG: u8 = 2; // an incoming stack argument at rbp + off (read-only)
const H_FIXED: u8 = 3; // `reg` for its whole range
const H_REMAT: u8 = 4; // a constant or an address, recomputed at each use
const H_SPADDR: u8 = 5; // the address rsp + off
const H_FPADDR: u8 = 6; // the address rbp + off

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
// The argument registers: what the entry block's parameters arrive in.
const ARGS_SYSV: u64 = 0xFF03C6; // rdi rsi rdx rcx r8 r9, xmm0..xmm7
const ARGS_WIN: u64 = 0xF0306; // rcx rdx r8 r9, xmm0..xmm3

// `Gen::fix_class`: no fixed register, a callee-saved one, a caller-saved one.
const FIX_NONE: u8 = 0;
const FIX_CALLEE: u8 = 1;
const FIX_SCRATCH: u8 = 2;
const XFIX_WIN: u64 = 0xF0C8; // rbx rsi rdi r12 r13 r14 r15
const VALLOC_WIN: u64 = 0x3FCF0000; // xmm0..xmm3, xmm6..xmm13
const VSAVE_WIN: u64 = 0xFFC00000; // xmm6..xmm15
// The callee-saved xmm registers a value may hold for its whole range (Microsoft x64), in the order taken:
// xmm14 and xmm15 (no temporary's), then xmm8..xmm13 (no intrinsic's template names xmm8 and up).
const VFIX_WIN: [u8; 8] = [30, 31, 24, 25, 26, 27, 28, 29];

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
            fp;
        } else {
            0u8;
        },
    );
    for q in 0..codes.len() {
        out.push(codes[q]);
    }
    if n % 2 != 0 {
        out.push(0);
        out.push(0);
    }
}

// The layout of signature `sig` of body `b` into `out`, by Microsoft x64 (`win`) or System V.
fn classify(win: bool, b: &Body, sig: u32, ptr: u32, vregs: u32, out: &mut ab::CallLayout) {
    if win {
        w64::classify(b, sig, ptr, out);
    } else {
        cc::classify(b, sig, ptr, vregs, out);
    }
}

/// Per value: where it is.
struct Va {
    pub(package) reg: u8, // NOREG or the register holding it
    pub(package) home: u8,
    pub(package) dirty: bool, // the register holds it and the home does not
    pub(package) clean: bool, // its register's bits above its width are zero (an i8 compare result, say)
    pub(package) off: i32,
}

extend Va as Copy {}

// A relocation of the body's code: at byte `at` (before the prologue), of kind `kind` against object
// symbol `sym` plus `addend`.
struct CRel {
    pub(package) at: u32,
    pub(package) kind: u8,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

extend CRel as Copy {}

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
    vscr: u64,
    vfix: u64, // the callee-saved xmm registers a value may hold for its whole range (Microsoft x64)
    vs0: u8, // the vector scratch registers
    vs1: u8,
    // ---- per body ----
    bp: *const Body,
    lv: lv::Live,
    va: Vector<Va>,
    c: x::Code,
    owner: Vector<u32>, // per register number, the value index it holds, NONE
    held: u64, // a bit per register whose `owner` is a value
    clob: u64, // the caller-saved registers the current call writes: all, or an intrinsic's
    lock: u64, // registers the current instruction reads or writes
    tmps: u64, // registers the current instruction took as temporaries
    fixed_busy: u64,
    csr: u64, // callee-saved registers the body uses
    rows: Vector<u64>, // with debug information, per change of location: its code byte << 32 | its `lines` index
    rstore: Vector<u32>, // per instruction, 1 + the result part a store moves into its register (`ret_stores`), else 0
    rr: u32, // the eviction cursor
    pos: u32, // the layout position of the block being compiled
    cur: u32, // the instruction being compiled
    called: bool, // the body's code calls
    taken: Vector<u64>, // the loads of a register-passed aggregate that take its registers (`parts_taken`): part << 32 | load
    csave: Vector<(u8, i64)>, // the scratch homes saved around a rare call (`save_scratch`)
    fused: u32, // the last instruction an earlier one did (`rmw`), NONE
    cmp_at: u32, // the code byte the last compare starts at (`reflag`), NONE
    // Shrink-wrapping (System V): the frame is set up on the edges into the rare blocks and taken down on
    // the edges out (`shrinkable`); the warm code, which calls nothing, keeps no value in memory and no
    // callee-saved register, has none. Whether the body is compiled so, and whether that try failed (the
    // warm code used the stack: the body is compiled again without).
    shrink: bool,
    no_shrink: bool,
    rarec: Vector<bool>, // per instruction, a call that returns in a rare block (`call_tables`)
    shared: Vector<u32>, // the block parameters that share a header parameter's slot (`back_share`)
    dying: Vector<u32>, // values whose register frees after the current instruction
    wparams: Vector<u32>, // the parameters the current terminator's edges write
    want: Vector<u8>, // per value, its request to `Live::plan`
    lconst: Vector<bool>, // per instruction, a constant a loop keeps in a register (`Live::loop_consts`)
    vmem: Vector<bool>, // per value, a vector some instruction reads or writes in memory (`vec_homes`)
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
    canary: i64, // the stack canary's slot above the LIR slots, -1 when none
    save_off: i64, // a variadic body's register save area, -1 when none
    // Labels.
    blk_at: Vector<u32>, // per block, its first byte, NONE before it is compiled
    fix: Vector<u64>, // displacement field << 32 | block: a branch to patch
    epi: Vector<u32>, // jumps to the epilogue (their displacement fields)
    // The sibling calls (`sibling`): each one's jump's displacement field << 32 | its callee's object
    // symbol (NONE: the callee in r11); whether the body may make them; the return they replace.
    tails: Vector<u64>,
    tail_ok: bool,
    tail_ret: u32,
    rels: Vector<CRel>,
    osym: Vector<u32>, // per body symbol, its object symbol (NONE until used)
    // Calls.
    lay: ab::CallLayout,
    self_lay: ab::CallLayout,
    uses: Vector<Value>,
    mv: Vector<Mv>,
    cstr_n: u32,
    local: bool, // the function compiling is a local copy
    msg_sym: Map<String, u32>, // per C string text, its object symbol
}

// A move of the parallel-move resolver: `src` to `dst` (locations), `bytes` wide in register file `v`.
struct Mv {
    pub(package) src: Lc,
    pub(package) dst: Lc,
    pub(package) v: bool,
    pub(package) bytes: u32,
    pub(package) done: bool,
}

extend Mv as Copy {}

// A location: a register, memory at base + off, or a value to rematerialize.
struct Lc {
    pub(package) kind: u8, // LC_REG, LC_MEM, LC_VAL
    pub(package) reg: u8, // the register, or the base register of memory
    pub(package) off: i32,
    pub(package) val: u32, // LC_VAL: the value index
}

extend Lc as Copy {}

const LC_REG: u8 = 0;
const LC_MEM: u8 = 1;
const LC_VAL: u8 = 2;

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
            avx: pkg.vector >= 32,
            z512: pkg.vector == 64,
            ymm: false,
            yblk: Vector::<bool>::new(),
            yvals: Vector::<u32>::new(),
            xalloc: if win {
                XALLOC_WIN;
            } else {
                XALLOC_SYSV;
            },
            xfix: if win {
                XFIX_WIN;
            } else {
                XFIX_SYSV;
            },
            valloc: if win {
                VALLOC_WIN;
            } else {
                VALLOC_SYSV;
            },
            xscr: if win {
                XSCR_WIN;
            } else {
                XSCR_SYSV;
            },
            xscr_cap: if win {
                1;
            } else {
                2;
            },
            vscr: if win {
                0;
            } else {
                VSCR_SYSV;
            },
            vfix: if win {
                0xFF000000;
            } else {
                0;
            },
            vs0: if win {
                V0 + 4;
            } else {
                V0 + 14;
            },
            vs1: if win {
                V0 + 5;
            } else {
                V0 + 15;
            },
            bp: null,
            lv: lv::Live::new(),
            va: Vector::<Va>::new(),
            c: x::Code::new(),
            owner: owner,
            held: 0,
            clob: ~0u64,
            lock: 0,
            tmps: 0,
            fixed_busy: 0,
            csr: 0,
            rows: Vector::<u64>::new(),
            rstore: Vector::<u32>::new(),
            rr: 0,
            pos: 0,
            cur: 0,
            called: false,
            taken: Vector::<u64>::new(),
            csave: Vector::<(u8, i64)>::new(),
            fused: NONE,
            cmp_at: NONE,
            shrink: false,
            no_shrink: false,
            rarec: Vector::<bool>::new(),
            shared: Vector::<u32>::new(),
            dying: Vector::<u32>::new(),
            wparams: Vector::<u32>::new(),
            want: Vector::<u8>::new(),
            lconst: Vector::<bool>::new(),
            vmem: Vector::<bool>::new(),
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
            canary: -1,
            save_off: -1,
            blk_at: Vector::<u32>::new(),
            fix: Vector::<u64>::new(),
            epi: Vector::<u32>::new(),
            tails: Vector::<u64>::new(),
            tail_ok: false,
            tail_ret: NONE,
            rels: Vector::<CRel>::new(),
            osym: Vector::<u32>::new(),
            lay: ab::CallLayout::new(),
            self_lay: ab::CallLayout::new(),
            uses: Vector::<Value>::new(),
            mv: Vector::<Mv>::new(),
            cstr_n: 0,
            local: false,
            msg_sym: Map::<String, u32>::new(),
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

    // The register file of type `t`: false for general, true for xmm. Memory types are neither.
    const fn is_v(t: u8) bool {
        return is_float(t);
    }

    const fn in_mem(t: u8) bool {
        return t == T_I128 || is_vec(t);
    }

    // Whether memory value type `t` may also be in an xmm register: a vector of 8 or 16 bytes.
    const fn in_vreg(t: u8) bool {
        return is_vec(t) && (type_bytes(t, 8) == 8 || type_bytes(t, 8) == 16);
    }

    // Whether memory value type `t` may be in a vector register: `in_vreg`, or with AVX2 a vector of 32
    // bytes in a ymm register, with AVX-512 one of 64 in a zmm register. Only the instructions with 256-
    // and 512-bit forms read this; the others take such a vector from its home.
    const fn in_reg(self: &Self, t: u8) bool {
        return Gen::in_vreg(t) || is_vec(t) && (self.avx && type_bytes(t, 8) == 32 || self.z512 && type_bytes(t, 8) == 64);
    }

    // Whether `v` is an instruction value the generator recomputes at each use.
    const fn remat_inst(self: &Self, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = self.b().insts[v as usize];
        return t.op == O_ICONST || t.op == O_FCONST || t.op == O_SLOTADDR || t.op == O_SYMADDR && !self.tls_sym(t.a);
    }

    // Whether body symbol `s` is a thread-local variable.
    const fn tls_sym(self: &Self, s: u32) bool {
        let p = unsafe &*self.pkg;
        return p.syms[self.b().syms[s as usize] as usize].kind == SK_TLS;
    }

    // Whether `v` is an integer constant; its bits in `out`.
    const fn const_of(self: &Self, v: Value, out: &mut u64) bool {
        if (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = self.b().insts[v as usize];
        if t.op != O_ICONST {
            return false;
        }
        *out = t.b as u64 << 32 | t.a as u64;
        return true;
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
            self.valloc;
        } else {
            self.xalloc;
        };
        let open = set & ~(self.lock | self.tmps | self.fixed_busy) & 0xFFFFFFFFu64;
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
        // Evict round-robin: the next unlocked register that holds a value.
        let busy = open & self.held;
        if busy != 0 {
            let s = self.rr % 32;
            let r = if busy >> s as u64 != 0 {
                s + (busy >> s as u64).trailing_zeros() as u32;
            } else {
                busy.trailing_zeros() as u32;
            };
            self.rr = r + 1;
            self.evict(r as u8);
            return self.taken(r as u8);
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
        let b = self.b();
        let ni = b.insts.len() as u32;
        if x < ni {
            return b.insts[x as usize].ty;
        }
        if x < ni + b.params.len() as u32 {
            return b.params[(x - ni) as usize];
        }
        return T_I8;
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
        let vr = Gen::is_v(self.vt(v)) || self.in_reg(self.vt(v));
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

    // A register for the result of value `v` that holds operand `a`'s bits (in `ra`) for a two-operand
    // instruction: `ra` itself when `a` dies here and `v` takes no fixed home, else a copy of it.
    fn def_from(self: &mut Self, v: Value, a: Value, ra: u8) u8 {
        let x = self.vx(v);
        let xa = self.vx(a);
        let t = self.vt(v);
        let sr = self.def_shared(v, a);
        if sr != NOREG {
            self.move_reg(t, sr, ra);
            return sr;
        }
        let fixed = self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE;
        if !fixed && ((self.xalloc | self.valloc) & bit(ra)) != 0 && Gen::is_v(t) == ra >= V0 {
            let own = self.owner[ra as usize];
            let temp = own == NONE && (self.tmps & bit(ra)) != 0;
            let dies = own == xa && self.va[xa as usize].home != H_FIXED && self.lv.uses[xa as usize] == 0 && self.lv.end[xa as usize] == self.pos;
            if temp || dies {
                if dies {
                    self.va.index_mut(xa as usize).reg = NOREG;
                    self.va.index_mut(xa as usize).dirty = false;
                }
                self.tmps &= ~bit(ra);
                self.bind(x, ra);
                return ra;
            }
        }
        let rd = self.def(v);
        self.move_reg(t, rd, ra);
        return rd;
    }

    // The register `step_reg` or `fwd_reg` gives value `v`, which reads `a` before it writes, taken for
    // `v`: the edge's move vanishes. NOREG when neither gives one.
    fn def_shared(self: &mut Self, v: Value, a: Value) u8 {
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
            self.def(v);
        } else {
            r;
        };
    }

    // The register the instruction after instruction `v` in its block takes `v` in, when that is `v`'s
    // only use: a call's scalar register argument, or the result; so `v` is there for it. NOREG when not,
    // or when a value or the current instruction holds that register.
    fn next_reg(self: &mut Self, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 {
            return NOREG;
        }
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[v as usize] as usize];
        let bits = type_bits(self.vt(v), self.ptr);
        if v + 1 >= bk.start + bk.len || self.lv.uses[v as usize] != 1 || self.lv.end[v as usize] != self.pos || !is_int(
            self.vt(v),
        ) && self.vt(v) != T_PTR || bits < 32 || bits > 64 || self.va[v as usize].home != H_NONE {
            return NOREG;
        }
        let t = b.insts[v as usize + 1];
        let mut r = NOREG;
        if t.op == O_RET {
            let rl = self.self_lay.ret;
            if t.a == v && rl.kind == ab::L_REG && rl.n == 1 && !self.self_lay.parts[rl.p0 as usize].v {
                r = self.self_lay.parts[rl.p0 as usize].reg;
            }
        } else if t.op == O_CALL && self.intrinsic(t.a).len() == 0 || t.op == O_CALLIND && t.a != v {
            self.call_layout(t);
            let np = b.pool[t.b as usize];
            let nops = np + ((b.pool[t.b as usize + 2] & AGG) != 0) as u32;
            for k in 0..nops {
                if b.pool[(t.c + k) as usize] != v {
                    continue;
                }
                if r != NOREG || k == np || self.lay.locs[k as usize].kind != ab::L_REG || self.lay.locs[k as usize].n != 1 || (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 {
                    return NOREG;
                }
                let pa = self.lay.parts[self.lay.locs[k as usize].p0 as usize];
                if pa.v {
                    return NOREG;
                }
                r = pa.reg;
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
        if r == NOREG || ((self.held | self.lock | self.tmps | self.fixed_busy) & bit(r)) != 0 || (self.xalloc & bit(r)) == 0 {
            return NOREG;
        }
        return r;
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
            Gen::is_v(self.vt(v)),
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
        // A field that is no operand may equal the parameter only by chance: then no hint, still correct.
        let t = b.insts[v as usize];
        let other = (t.a == pv || t.b == pv || t.c == pv) && a != pv;
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
        ) != FIX_NONE || self.crosses_call(v, Gen::is_v(self.vt(v))) {
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
        if x == NONE || self.xty(x) != self.vt(v) || Gen::in_mem(self.xty(x)) {
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
            let t = b.insts[v as usize];
            if (t.a == pv || t.b == pv || t.c == pv) && a != pv || self.lv.reads_after(b, k, v, pv) {
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
        return self.lv.home[x as usize];
    }

    // Plan the homes (`Live::plan`) over each value's request: none in memory or rematerialized; an integer a call that
    // returns runs in the range of, a callee-saved register; one that lives past its block or a block
    // parameter, either (a flag: callee-saved only); a float that lives past its block or a block
    // parameter, an xmm register: under Microsoft x64 a callee-saved one (`vfix`), under System V, which
    // keeps no xmm register across a call, a caller-saved one when no call that returns runs in its
    // range; none for the others, which temporaries hold (an entry parameter that dies in the entry
    // block stays in the register it arrives in). A vector of 16 bytes that lives past its block or is a
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
        self.vec_homes();
        self.want.truncate(0);
        // An xmm home: Microsoft x64's callee-saved ones, System V's caller-saved ones.
        let vw = lv::WANT_V | if self.win {
            lv::WANT_CALLEE;
        } else {
            lv::WANT_SCRATCH;
        };
        for x in 0..n {
            let t = self.xty(x as u32);
            let d = self.lv.def_blk[x];
            let mut w: u8 = 0;
            // A ymm register keeps only its low 16 bytes across a call (Microsoft x64's xmm6..xmm15).
            if self.in_reg(t) && type_bytes(t, 8) >= 16 && x < nv && !self.vmem[x] && d != NONE && self.lv.pos[d as usize] != NONE && (self.lv.end[x] > self.lv.pos[d as usize] || x >= ni) && (self.win && type_bytes(
                t,
                8,
            ) == 16 || !self.crosses_call(x as u32, true)) {
                w = vw;
            }
            if !Gen::in_mem(t) && d != NONE && self.lv.pos[d as usize] != NONE && !(x < ni && self.remat_inst(x as u32) && !self.lconst[x]) {
                let past = self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && x < nv && d != 0;
                let cross = x < nv && self.crosses_call(x as u32, Gen::is_v(t));
                if Gen::is_v(t) {
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
        for x in 0..ni {
            nd = nd.max(self.need(b.insts[x]));
        }
        let most = self.xfix.count_ones() as u32 + self.xalloc.count_ones() as u32 - nd;
        // A body that calls nothing that returns (no instruction `clobbers` but one before a trap or in a
        // rare block, no thread-local address's getter) and runs no system operation or variadic access:
        // every register of `xscr` may be a home at once.
        let mut leaf = true;
        for x in 0..ni {
            let t = b.insts[x];
            leaf = leaf && !(Gen::clobbers(b, t) && !self.dead_end(x) && !self.rarec[x]) && t.op != O_SYS && t.op != O_VASTART && t.op != O_VAARG && !(t.op == O_SYMADDR && !self.remat_inst(
                x as u32,
            ));
        }
        let xs = if leaf {
            self.xscr.count_ones() as u32;
        } else {
            self.xscr_cap;
        };
        // Six of Microsoft x64's callee-saved xmm homes (xmm0..xmm3, xmm6, xmm7 and two of xmm8..xmm13 stay
        // for temporaries), or four of System V's caller-saved ones.
        let (vc, vs) = if self.win {
            (6u32, 0u32);
        } else {
            (0u32, 4u32);
        };
        self.lv.plan(
            b,
            &self.want,
            lv::Caps {
                xc: if self.shrink {
                    0;
                } else {
                    self.xfix.count_ones() as u32;
                },
                xs: xs,
                xj: most,
                vc: vc,
                vs: vs,
                vj: vc + vs,
            },
        );
        for x in 0..ni {
            if self.lconst[x] && self.fix_class(x as u32) != FIX_NONE {
                self.va.index_mut(x).home = H_NONE;
            }
        }
    }

    // The integer registers instruction `t` holds at once besides the homes: its operands outside a
    // home, its temporaries and its result (`end_inst` checks it). 8 for one that reads or writes a
    // vector or an i128 (a masked store reads 8), a vector operation, inline assembly and a system
    // operation; 8 for an unsigned 64-bit multiplication with overflow (rax and rdx, the values moved out
    // of them, the operands, the flag and the result); 7 for a division and a high multiplication (the
    // same but the flag); 6 for an atomic operation; 5 for a shift and a select; 4 for the others.
    fn need(self: &mut Self, t: Inst) u32 {
        if Gen::in_mem(t.ty) || t.op == O_VOP || t.op == O_ASM || t.op == O_SYS {
            return 8;
        }
        lv::each_use(self.b(), t, &mut self.uses);
        for k in 0..self.uses.len() {
            if Gen::in_mem(self.vt(self.uses[k])) {
                return 8;
            }
        }
        if t.op == O_MULO && t.aux != OV_SIGNED && type_bits(t.ty, self.ptr) == 64 {
            return 8;
        }
        if t.op >= O_SDIV && t.op <= O_UREM || t.op == O_MULHU {
            return 7;
        }
        if t.op == O_ARMW || t.op == O_ACAS {
            return 6;
        }
        if t.op >= O_SHL && t.op <= O_ASHR || t.op == O_SELECT {
            return 5;
        }
        return 4;
    }

    // `vmem`: per value, whether it is a vector some instruction defines or reads in memory: any but a
    // vector load, a lane-wise operation with an SSE form (its operands too), a store of it, and an edge
    // argument (a return reads its vector in memory).
    fn vec_homes(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        self.vmem.truncate(0);
        self.vmem.resize_default(self.lv.end.len());
        for i in 0..ni {
            let t = b.insts[i];
            let mut un = false;
            let reg_op = is_vec(t.ty) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT) && sse_of_op(
                t.op,
                lane_type(t.ty),
                &mut un,
            ) != NONE || (t.op == O_SPLAT || t.op == O_VSEL || t.op == O_WCONST) && self.in_reg(t.ty) || self.conv_reg(
                t,
            ) || self.shift_reg(t) || (t.op == O_VEXTRACT || t.op == O_VINSERT) && self.lane_reg(t) || (t.op == O_VZIPLO || t.op == O_VZIPHI) && type_bytes(
                t.ty,
                8,
            ) <= 32 && self.in_reg(t.ty) || t.op == O_VUNZIP && type_bytes(t.ty, 8) >= 16 && self.in_reg(t.ty) || t.op == O_VCMP && self.in_reg(
                self.vt(t.a),
            ) && (is_float(lane_type(self.vt(t.a))) || type_bytes(lane_type(t.ty), 8) < 8 || self.avx) || self.avx && is_vec(
                t.ty,
            ) && type_bytes(t.ty, 8) == 32 && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT) && avx_of_op(
                t.op,
                lane_type(t.ty),
            ) != NONE || self.z512 && is_vec(t.ty) && type_bytes(t.ty, 8) == 64 && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT) && evex_of_op(
                t.op,
                lane_type(t.ty),
            ) != NONE;
            if is_vec(t.ty) && !reg_op && t.op != O_LOAD {
                self.vmem[i] = true;
            }
            if t.op == O_RET && t.a != VNONE && is_vec(self.vt(t.a)) {
                self.vmem[self.vx(t.a) as usize] = true;
            }
            if reg_op || is_terminator(t.op) {
                continue;
            }
            lv::each_use(b, t, &mut self.uses);
            for k in 0..self.uses.len() {
                let u = self.uses[k];
                if t.op == O_STORE && u == t.b {
                    continue;
                }
                let x = self.vx(u);
                if x != NONE && is_vec(self.xty(x)) {
                    self.vmem[x as usize] = true;
                }
            }
        }
    }

    // Whether a call that returns (`clobbers`) runs while value index `x` (an instruction's or a
    // parameter's) lives: after its definition and before its last use in its own block, or in a block
    // of its range after its own.
    const fn crosses_call(self: &Self, x: u32, v: bool) bool {
        let pre = if v {
            &self.vpre;
        } else {
            &self.cpre;
        };
        let pos = if v {
            &self.vpos;
        } else {
            &self.cpos;
        };
        let b = self.b();
        let ni = b.insts.len() as u32;
        let d = self.lv.def_blk[x as usize];
        let dp = self.lv.pos[d as usize];
        let e = self.lv.end[x as usize];
        let bk = b.blocks[d as usize];
        let from = if x < ni {
            x + 1;
        } else {
            bk.start;
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
            ".text$u";
        } else {
            ".text.unlikely";
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

    // Whether no value outlives call `i` for a use: its block ends in `unreachable` and no later instruction
    // of it reads a value but one recomputed at each use (a panic's message, then `abort`).
    fn dead_end(self: &mut Self, i: usize) bool {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i] as usize];
        let end = (bk.start + bk.len - 1) as usize;
        if b.insts[end].op != O_UNREACHABLE {
            return false;
        }
        for j in i + 1..end {
            lv::each_use(b, b.insts[j], &mut self.uses);
            for u in 0..self.uses.len() {
                if !self.remat_inst(self.uses[u]) {
                    return false;
                }
            }
        }
        return true;
    }

    // `cpre` and `cpos`: the calls that return to a use (`clobbers`, not `dead_end`)
    // before each instruction index, and the blocks holding one before each layout position; `vpre` and
    // `vpos` the same without the intrinsics, whose templates write xmm0 to xmm3 and their arguments'
    // registers, no vector scratch home.
    fn call_tables(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill32(&mut self.cpre, ni + 1, 0);
        fill32(&mut self.vpre, ni + 1, 0);
        self.rarec.truncate(0);
        self.rarec.resize_default(ni);
        for i in 0..ni {
            let t = b.insts[i];
            if Gen::clobbers(b, t) && !self.dead_end(i) && self.rare(i as u32) {
                self.rarec[i] = true;
            } else if Gen::clobbers(b, t) && !self.dead_end(i) {
                self.cpre[i + 1] = 1;
                self.vpre[i + 1] = (!(t.op == O_CALL && self.intrinsic(t.a).len() != 0)) as u32;
            }
        }
        let nq = self.lv.order.len();
        fill32(&mut self.cpos, nq + 1, 0);
        fill32(&mut self.vpos, nq + 1, 0);
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

    // Give value index `x` a caller-saved register of file `vr` (`xscr`, `vscr`) as its home, the value
    // there evicted: `prefer` when it is one (the register `x` arrives in), else one the current
    // instruction does not use; NOREG when none is.
    fn take_scratch(self: &mut Self, x: u32, vr: bool, prefer: u8) u8 {
        let set = if vr {
            self.vscr;
        } else {
            self.xscr;
        } & ~self.fixed_busy;
        let open = set & ~(self.lock | self.tmps);
        let r = if prefer != NOREG && (set & bit(prefer)) != 0 {
            prefer;
        } else if (open & ~self.held) != 0 {
            (open & ~self.held).trailing_zeros() as u8;
        } else if open != 0 {
            open.trailing_zeros() as u8;
        } else {
            NOREG;
        };
        if r == NOREG {
            return NOREG;
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
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.reg != NOREG {
            self.lock |= bit(va.reg);
            return va.reg;
        }
        let t = self.vt(v);
        if va.home == H_REMAT || va.home == H_SPADDR || va.home == H_FPADDR {
            let r = self.tmp(Gen::is_v(t));
            self.materialize(v, r);
            return r;
        }
        let r = self.alloc(Gen::is_v(t));
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
                        x::RSP;
                    } else {
                        self.fb;
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
                        x::RSP;
                    } else {
                        self.fb;
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
                    lo | 0xFFFFFFFF << bits as u64 & 0xFFFFFFFF;
                } else {
                    lo;
                },
                4,
            );
            return;
        }
        let x = self.vx(v);
        let va = self.va[x as usize];
        // A narrow load zero-extends.
        let clean = va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG);
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
        self.lv.uses_at(self.b(), i, &mut self.uses);
        for k in 0..self.uses.len() {
            let x = self.vx(self.uses[k]);
            self.use_once(x);
        }
        // Code that may branch past a lane reads a vector from its home: a vector in a register reaches
        // it first, but for the instructions with register forms (`vop` and `vec_arith` sync their others)
        // and calls (a vector passed in memory goes through `mloc`).
        let reg_form = t.op == O_STORE || t.op == O_VOP || t.op == O_CALL || t.op == O_CALLIND || is_vec(t.ty) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT || t.op == O_VCMP || t.op == O_VSEL || t.op == O_VUNZIP || t.op == O_VZIPLO || t.op == O_VZIPHI) || t.op == O_VEXTRACT || t.op == O_VINSERT || self.conv_reg(
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
        // `plan_homes` leaves `need` integer registers to each instruction.
        let used = ((self.lock | self.tmps) & ~self.fixed_busy & (self.xalloc | self.xfix)).count_ones() as u32;
        assert(
            used <= self.need(self.b().insts[self.cur as usize]),
            "x64gen: an instruction takes more registers than `need`",
        );
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
            self.set_owner(va.reg, NONE);
            if va.home == H_FIXED {
                self.fixed_busy &= ~bit(va.reg);
            }
        }
        if va.home == H_SLOT && !self.is_shared(x) {
            let n = if Gen::in_mem(self.xty(x)) {
                type_bytes(self.xty(x), self.ptr);
            } else {
                8;
            };
            self.free_slots.push(n as u64 << 32 | (va.off as u32) as u64);
        }
        let w = self.va.index_mut(x as usize);
        w.reg = NOREG;
        w.home = H_NONE;
        w.dirty = false;
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
            8u32;
        } else {
            size0;
        };
        let al = if al0 < 8 {
            8u32;
        } else if al0 > 16 {
            16u32;
        } else {
            al0;
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
            v & 0xFFFFFFFF;
        } else {
            v;
        };
        if k == 0 && !self.keep_flags {
            self.c.alu_rr(x::XOR, 4, rd, rd);
            return;
        }
        self.c.mov_ri(rd, k);
    }

    // xmm register `r` = the float of bits `bits` (`d` double).
    fn fconst(self: &mut Self, r: u8, d: bool, bits: u64) {
        if bits == 0 {
            self.c.sse_rr(0, 0x0F57, r - V0, r - V0);
            return;
        }
        self.c.mov_ri(S1, bits);
        self.c.movd_to_x(
            if d {
                8u32;
            } else {
                4u32;
            },
            r - V0,
            S1,
        );
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
        let k = o.sym(nm.as_str());
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
        // lea r, [r + disp32], the displacement the variable's section offset
        self.c.byte(0x48 | r >> 3 << 2 | r >> 3);
        self.c.byte(0x8D);
        self.c.byte(0x80 | (r & 7) << 3 | r & 7);
        if (r & 7) == 4 {
            self.c.byte(0x24);
        }
        let at = self.c.len();
        self.c.d32(0);
        self.rels.push(CRel { at: at, kind: x::R_SECREL, sym: os, addend: addend });
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
            S0;
        } else {
            S1;
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
        let b = self.b();
        let mut from = false;
        let mut es = Vector::<u32>::new();
        for j in 0..b.blocks.len() {
            if !self.yblk[j] || self.lv.pos[j] == NONE {
                continue;
            }
            b.succ_edges(b.insts[(b.blocks[j].start + b.blocks[j].len - 1) as usize], &mut es);
            for e in 0..es.len() {
                from = from || b.edge_target(es[e]) == k;
            }
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
        if self.osym[s as usize] == NONE {
            let p = unsafe &*self.pkg;
            let ps = p.syms[self.b().syms[s as usize] as usize];
            let nm0 = p.spell(ps.name);
            // `__sc_x_<name>` is a C library name's alias (a macro of a scoped extern header).
            let nm = if ps.def == NONE && nm0.starts_with("__sc_x_") {
                nm0.slice(7, nm0.len());
            } else {
                nm0;
            };
            let k = self.obj().sym(nm);
            self.osym[s as usize] = k;
        }
        return self.osym[s as usize];
    }
}

const fn bref(p: *const Body) &'static Body {
    return unsafe &*p;
}

const fn oref(p: *mut ob::Obj) &'static mut ob::Obj {
    return unsafe &mut *p;
}

// `x`'s low `bits` bits sign-extended.
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

// `v` as `n` copies of `x`, its buffer reused.
fn fill32(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

// The size and alignment of signature type `pt` of `b`.
fn sig_size(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return b.pool[l], 1u32 << b.pool[l + 1];
    }
    return type_bytes(pt as u8, ptr), type_align(pt as u8, ptr);
}

// ---- Functions ----

extend Gen {
    /// Compile the body of package function symbol `s` into the object. False (with `err`) when the
    /// body uses what the generator does not compile.
    pub(package) fn func(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        self.bp = &p.bodies[ps.def as usize];
        let b = self.b();
        self.lv.fold_max = 8;
        self.lv.fold_ops = lv::FOLD_CMP | lv::FOLD_TST;
        self.arg_relays();
        self.lv.after.truncate(0);
        self.lv.run(b);
        self.shrink = !self.no_shrink && self.shrinkable();
        if self.shrink {
            self.lv.run(b);
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
        fill32(&mut self.osym, b.syms.len(), NONE);
        fill32(&mut self.owner, 32, NONE);
        self.held = 0;
        fill32(&mut self.blk_at, b.blocks.len(), NONE);
        self.c.clear();
        self.zf.at = NONE;
        self.fused = NONE;
        self.cmp_at = NONE;
        self.fix.truncate(0);
        self.epi.truncate(0);
        self.tails.truncate(0);
        self.tail_ret = NONE;
        self.rels.truncate(0);
        self.free_slots.truncate(0);
        self.taken.truncate(0);
        self.shared.truncate(0);
        self.called = false;
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
        self.rr = 0;
        self.cond = Cond { inst: NONE, cc: 0 };
        if b.naked {
            return self.naked(s);
        }
        self.frame_layout();
        // Without a frame pointer rbp holds values; a frame aligned past 16 bytes or inline assembly, which
        // may name rbp, keeps it.
        let mut omit = p.omit_fp && self.max_align <= 16;
        let mut va = false;
        for k in 0..b.insts.len() {
            omit = omit && b.insts[k].op != O_ASM;
            va = va || b.insts[k].op == O_VASTART;
        }
        // Sibling calls leave the frame first: none with a canary to check, variadic arguments in it, or a
        // slot's address that may outlive it.
        self.tail_ok = p.tail && self.canary < 0 && !va && !lver::frame_escapes(b);
        self.fb = ast_pick(omit, x::IN, x::RBP);
        self.xfix = if self.win {
            XFIX_WIN;
        } else {
            XFIX_SYSV;
        } | if omit {
            bit(x::RBP);
        } else {
            0;
        };
        self.bucket_ends();
        self.call_tables();
        self.plan_homes();
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
        if self.shrink && (self.c.stack_at < self.rare_at() || self.csr != 0) {
            return self.unshrunk(s, local);
        }
        return self.finish(s);
    }

    // The warm code of shrink-wrapped function `s` needs the frame: once more, with the frame set up at the
    // entry.
    fn unshrunk(self: &mut Self, s: u32, local: bool) bool {
        self.no_shrink = true;
        let ok = self.func(s, local);
        self.no_shrink = false;
        return ok;
    }

    // Whether the body may set its frame up in its rare blocks alone (`shrink`): every call (one that does
    // not return too: it needs the frame's alignment) is in a rare block (`Live::rare`), there is one, and
    // the body reads no return address, variadic argument or inline assembly, runs no system operation,
    // aligns no slot past 16 bytes and has no canary. The rare blocks connected to one with a call by edges
    // between rare blocks set the frame up: `Live::after`, which the layout puts after the others. Under
    // Microsoft x64 no edge leaves them for the warm code: its unwinder reads an epilogue only where it
    // ends in `ret` or a jump out of the function.
    fn shrinkable(self: &mut Self) bool {
        let b = self.b();
        if lver::protected(unsafe (*self.pkg).protect, b) {
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
            if t.op == O_RETADDR || t.op == O_VASTART || t.op == O_ASM || t.op == O_SYS {
                return false;
            }
            let d = self.lv.def_blk[i];
            if d == NONE || self.lv.pos[d as usize] == NONE || !Gen::clobbers(b, t) {
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
        fill32(&mut self.slot_off, b.slots.len(), 0);
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
        if lver::protected(unsafe (*self.pkg).protect, b) {
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
        fill32(&mut self.ends_at, np + 1, 0);
        for x in 0..self.lv.end.len() {
            if self.lv.def_blk[x] != NONE && self.lv.pos[self.lv.def_blk[x] as usize] != NONE {
                self.ends_at[self.lv.end[x] as usize + 1] += 1;
            }
        }
        for q in 0..np {
            self.ends_at[q + 1] += self.ends_at[q];
        }
        fill32(&mut self.ends, self.ends_at[np] as usize, 0);
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
        classify(self.win, b, b.sig, self.ptr, self.vregs, &mut self.self_lay);
        if self.self_lay.unknown {
            let _ = self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        self.ret_stores();
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
        if self.self_lay.ret.kind == ab::L_SRET && (rt & AGG) == 0 {
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
                    H_FPADDR;
                } else {
                    H_ARG;
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
                } else {
                    let sz = type_bytes(t, self.ptr);
                    let off = self.slot_alloc(sz, 16);
                    self.copy_mem(x::RSP, off, r, 0, sz);
                    self.va.index_mut(x as usize).home = H_SLOT;
                    self.va.index_mut(x as usize).off = off as i32;
                }
            } else if agg && self.parts_taken(x, loc) {
                continue;
            } else if agg || Gen::in_mem(t) {
                // Register parts into a slot: the aggregate's memory, or the memory value.
                let (size, _) = sig_size(b, pt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                for q in 0..loc.n as u32 {
                    let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                    self.store_part(pa, x::RSP, off as i64 + pa.off as i64);
                }
                self.va.index_mut(x as usize).home = if agg {
                    H_SPADDR;
                } else {
                    H_SLOT;
                };
                self.va.index_mut(x as usize).off = off as i32;
            } else {
                let pa = self.self_lay.parts[loc.p0 as usize];
                self.entry_reg(
                    x,
                    pa.reg + if pa.v {
                        V0;
                    } else {
                        0;
                    },
                );
            }
        }
        if (rt & AGG) != 0 {
            let x = ni + e0 + np;
            if self.self_lay.ret.kind == ab::L_SRET {
                self.entry_reg(x, self.arg(0));
            } else {
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
        let b = self.b();
        let e = b.blocks[0];
        let v = VPARAM | x - b.insts.len() as u32;
        let mut n: u32 = 0;
        let mark = self.taken.len();
        for i in e.start..e.start + e.len {
            let t = b.insts[i as usize];
            self.lv.uses_at(b, i, &mut self.uses);
            let mut reads: u32 = 0;
            for q in 0..self.uses.len() {
                reads += (self.uses[q] == v) as u32;
            }
            if reads == 0 {
                // A call before a load would take its register.
                if Gen::clobbers(b, t) {
                    break;
                }
                continue;
            }
            if t.op != O_LOAD || reads != 1 || (t.aux & MEM_VOLATILE) != 0 || self.lv.fold[i as usize] || is_vec(t.ty) || t.ty == T_I128 {
                self.taken.truncate(mark);
                return false;
            }
            let mut part = NONE;
            for q in 0..loc.n as u32 {
                let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                if pa.off == t.c && pa.size as u32 == type_bytes(t.ty, self.ptr) && pa.v == Gen::is_v(t.ty) && type_bytes(
                    t.ty,
                    self.ptr,
                ) >= 4 {
                    part = q;
                }
            }
            for q in mark..self.taken.len() {
                if self.taken[q] >> 32 == part as u64 {
                    part = NONE;
                }
            }
            if part == NONE {
                self.taken.truncate(mark);
                return false;
            }
            self.taken.push(part as u64 << 32 | i as u64);
            n += 1;
        }
        if n != self.lv.uses[x as usize] {
            self.taken.truncate(mark);
            return false;
        }
        for q in mark..self.taken.len() {
            let i = self.taken[q] as u32;
            let pa = self.self_lay.parts[(loc.p0 + (self.taken[q] >> 32) as u32) as usize];
            self.entry_reg(
                i,
                pa.reg + if pa.v {
                    V0;
                } else {
                    0;
                },
            );
        }
        return true;
    }

    // Parameter value index `x` arrives in register `r`.
    fn entry_reg(self: &mut Self, x: u32, r: u8) {
        if self.lv.uses[x as usize] == 0 {
            return;
        }
        let t = self.xty(x);
        let f = self.take_home(x, Gen::is_v(t), r);
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
        self.pos = q;
        let k = self.lv.order[q as usize];
        let b = self.b();
        self.blk_at[k as usize] = self.c.len();
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
                self.row(b.locs[i as usize]);
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

    // A line row at the next code byte for location `loc` (a `lines` index) when it differs from the last.
    fn row(self: &mut Self, loc: u32) {
        let n = self.rows.len();
        if loc == 0 || n != 0 && (self.rows[n - 1] & 0xFFFFFFFF) as u32 == loc {
            return;
        }
        let at = self.c.len() as u64 << 32;
        if n != 0 && self.rows[n - 1] >> 32 == at >> 32 {
            self.rows[n - 1] = at | loc as u64;
            return;
        }
        self.rows.push(at | loc as u64);
    }

    // Whether the block at position `q` keeps the register state: its only predecessor is the block
    // before it in the layout.
    const fn continues(self: &Self, q: u32) bool {
        if q == 0 {
            return true;
        }
        let b = self.b();
        let k = self.lv.order[q as usize];
        if self.lv.npred[k as usize] != 1 {
            return false;
        }
        let pk = self.lv.order[q as usize - 1];
        let pb = b.blocks[pk as usize];
        let t = b.insts[(pb.start + pb.len - 1) as usize];
        let ne = nedges(t);
        for e in 0..ne {
            if b.edge_target(lv::edge_of(b, t, e)) == k {
                return true;
            }
        }
        return false;
    }

    // Before a block's branch: every value live into a successor that does not keep the register state
    // is in its home. A value is live into the block at position `s` when its range holds `s` and starts
    // before it.
    fn spill_live_out(self: &mut Self) {
        let b = self.b();
        let k = self.lv.order[self.pos as usize];
        let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
        let ne = nedges(t);
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

    // The homes of the parameters terminator `t`'s edges write, chosen before its branch: what a home's
    // register held moves to its own home on every path.
    fn edge_homes(self: &mut Self, t: Inst) {
        let b = self.b();
        let ni = b.insts.len() as u32;
        let ne: u32 = if t.op == O_JMP {
            1;
        } else if t.op == O_BR {
            2;
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1;
        } else {
            0;
        };
        for e in 0..ne {
            let ed = lv::edge_of(b, t, e);
            let tb = b.blocks[b.edge_target(ed) as usize];
            for q in 0..tb.param_len as u32 {
                let x = ni + tb.param_start + q;
                let r = self.ret_reg(b, x);
                self.param_home(
                    x,
                    if r != NOREG {
                        r;
                    } else {
                        self.dying_reg(b.edge_arg(ed, q));
                    },
                );
            }
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
            va.reg;
        } else {
            NOREG;
        };
    }

    // The home of block parameter value index `x`, chosen at the first edge into its block: register
    // `prefer` when it may take it (`dying_reg`).
    fn param_home(self: &mut Self, x: u32, prefer: u8) {
        if self.va[x as usize].home != H_NONE {
            return;
        }
        let t = self.xty(x);
        let px = self.back_share(x);
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
        if self.take_home(x, Gen::is_v(t) || self.in_reg(t), prefer) != NOREG {
            // The register holds nothing until the edge moves write it, or the dying argument it takes.
            self.set_owner(self.va[x as usize].reg, x);
            return;
        }
        let n = type_bytes(t, self.ptr);
        let off = self.slot_alloc(n, type_align(t, self.ptr));
        self.va.index_mut(x as usize).home = H_SLOT;
        self.va.index_mut(x as usize).off = off as i32;
    }

    // The loop header parameter (a value index) that block parameter `x`'s block passes it to, when that
    // block ends in its jump there and reads that parameter nowhere, and the parameter has a register or
    // slot home: its value is dead from the block's start (the jump writes it), so `x` shares its home
    // and the jump's move vanishes. NONE when not.
    fn back_share(self: &Self, x: u32) u32 {
        let b = self.b();
        let ni = b.insts.len() as u32;
        let p = x - ni;
        let j = self.lv.def_blk[x as usize];
        let jb = b.blocks[j as usize];
        let t = b.insts[(jb.start + jb.len - 1) as usize];
        if t.op != O_JMP {
            return NONE;
        }
        let h = b.edge_target(t.a);
        let hb = b.blocks[h as usize];
        if self.lv.pos[h as usize] == NONE || self.lv.pos[h as usize] > self.lv.pos[j as usize] {
            return NONE;
        }
        let mut px = NONE;
        for q in 0..b.edge_nargs(t.a) {
            if b.edge_arg(t.a, q) == (VPARAM | p) {
                if px != NONE {
                    return NONE;
                }
                px = ni + hb.param_start + q;
            }
        }
        if px == NONE || self.va[px as usize].home != H_FIXED && self.va[px as usize].home != H_SLOT || self.xty(px) != self.xty(
            x,
        ) {
            return NONE;
        }
        // No instruction of the block, nor its jump, reads the header parameter.
        let pv = VPARAM | px - ni;
        let mut us = Vector::<Value>::new();
        for i in jb.start..jb.start + jb.len - 1 {
            lv::each_use(b, b.insts[i as usize], &mut us);
            for u in 0..us.len() {
                if us[u] == pv {
                    return NONE;
                }
            }
        }
        for q in 0..b.edge_nargs(t.a) {
            if b.edge_arg(t.a, q) == pv {
                return NONE;
            }
        }
        return px;
    }

    // The location value index `x` is read from now.
    const fn loc_of(self: &Self, x: u32) Lc {
        let va = self.va[x as usize];
        if va.reg != NOREG {
            return Lc { kind: LC_REG, reg: va.reg, off: 0, val: x };
        }
        if va.home == H_SLOT {
            return Lc { kind: LC_MEM, reg: x::RSP, off: va.off, val: x };
        }
        if va.home == H_ARG {
            return Lc { kind: LC_MEM, reg: self.fb, off: va.off, val: x };
        }
        return Lc { kind: LC_VAL, reg: 0, off: 0, val: x };
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
                Lc { kind: LC_REG, reg: pva.reg, off: 0, val: px };
            } else {
                Lc { kind: LC_MEM, reg: x::RSP, off: pva.off, val: px };
            };
            // A home the argument shares (`back_share`) already holds it.
            let src = self.loc_of(ax);
            if src.kind == dst.kind && src.reg == dst.reg && src.off == dst.off && src.kind != LC_VAL {
                continue;
            }
            self.mv.push(
                Mv {
                    src: src,
                    dst: dst,
                    v: Gen::is_v(t) || Gen::in_mem(t),
                    bytes: type_bytes(t, self.ptr),
                    done: false,
                },
            );
        }
        self.resolve_moves();
    }

    // Perform the pending moves `mv` as one parallel move: a move waits while its destination is a pending
    // move's source; a cycle breaks through a scratch slot.
    fn resolve_moves(self: &mut Self) {
        let n = self.mv.len();
        let mut left = n;
        // Each round performs a move or breaks a cycle (which frees one): at most 2n rounds.
        for _ in 0..2 * n + 1 {
            if left == 0 {
                return;
            }
            let mut progress = false;
            for i in 0..n {
                if self.mv[i].done || self.blocked(i) {
                    continue;
                }
                let m = self.mv[i];
                self.do_move(m.src, m.dst, m.v, m.bytes);
                self.mv.index_mut(i).done = true;
                left -= 1;
                progress = true;
            }
            if !progress {
                for i in 0..n {
                    if !self.mv[i].done {
                        let m = self.mv[i];
                        let s = self.slot_alloc(64, 16) as i32;
                        let tmp = Lc { kind: LC_MEM, reg: x::RSP, off: s, val: NONE };
                        self.do_move(m.src, tmp, m.v, m.bytes);
                        self.mv.index_mut(i).src = tmp;
                        break;
                    }
                }
            }
        }
        assert(left == 0, "x64gen: a parallel move did not finish");
    }

    // Whether move `i`'s destination is another pending move's source.
    const fn blocked(self: &Self, i: usize) bool {
        let d = self.mv[i].dst;
        for j in 0..self.mv.len() {
            if j == i || self.mv[j].done {
                continue;
            }
            let s = self.mv[j].src;
            if s.kind == LC_REG && d.kind == LC_REG && s.reg == d.reg {
                return true;
            }
            if s.kind == LC_MEM && d.kind == LC_MEM && s.reg == d.reg {
                let a0 = d.off as i64;
                let a1 = a0 + self.mv[i].bytes as i64;
                let b0 = s.off as i64;
                let b1 = b0 + self.mv[j].bytes as i64;
                if a0 < b1 && b0 < a1 {
                    return true;
                }
            }
        }
        return false;
    }

    // One move of `bytes` bytes (`v`: a float or memory value) from `src` to `dst`.
    fn do_move(self: &mut Self, src: Lc, dst: Lc, v: bool, bytes: u32) {
        if src.kind == LC_MEM && dst.kind == LC_MEM {
            self.copy_mem(dst.reg, dst.off, src.reg, src.off, bytes);
            return;
        }
        // A vector register's 16 bytes move as an i128's.
        let t = if v && bytes == 4 {
            T_F32;
        } else if v && bytes == 8 {
            T_F64;
        } else if v && bytes == 16 {
            T_I128;
        } else if v && bytes == 32 {
            vec_type(T_I64, 4);
        } else if v && bytes == 64 {
            vec_type(T_I64, 8);
        } else {
            int_type(bytes);
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
            self.vs0;
        } else {
            S0;
        };
        let r = if src.kind == LC_REG {
            src.reg;
        } else {
            self.materialize(self.xval(src.val), s);
            s;
        };
        self.st(t, r, x::at(dst.reg, dst.off));
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
                S0;
            } else {
                S1;
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
                16u32;
            } else if left >= 8 {
                8u32;
            } else if left >= 4 {
                4u32;
            } else if left >= 2 {
                2u32;
            } else {
                1u32;
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
                4u32;
            } else if left >= 2 {
                2u32;
            } else {
                1u32;
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
                4u32;
            } else if left >= 2 {
                2u32;
            } else {
                1u32;
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
        if op == O_SYMADDR && self.win {
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
        if op >= O_ADD && op <= O_NOT {
            return self.int_op(i, t);
        }
        if op >= O_ADDO && op <= O_MULO {
            return self.ovf_op(i, t);
        }
        if op >= O_CLZ && op <= O_POPCNT {
            self.bit_count(i, t);
            return true;
        }
        if op == O_ICMP {
            return self.icmp(i, t);
        }
        if op == O_FCMP {
            assert(!is_vec(self.vt(t.a)), "x64gen: a vector comparison the verifier rejects");
            self.fcmp(i, t);
            return true;
        }
        if op == O_MULHU {
            let bits = type_bits(t.ty, self.ptr);
            if bits == 64 {
                // MUL: rdx:rax = rax * the operand.
                self.vacate(x::RAX);
                self.vacate(x::RDX);
                let ra = self.reg(t.a);
                let rb = self.reg(t.b);
                self.c.mov_rr(8, x::RAX, ra);
                self.c.unary(x::MUL, 8, rb);
                self.result_in(i, x::RDX);
                return true;
            }
            // Fewer bits: the operands zero-extended (a 32-bit move clears the upper half), their 64-bit
            // product, shifted down.
            let ra = self.ext(t.a, false, bits);
            let rb = self.ext(t.b, false, bits);
            let s = self.tmp(false);
            self.c.mov_rr(4, s, rb);
            let rd = self.def(i);
            self.c.mov_rr(4, rd, ra);
            self.c.imul_rr(8, rd, s);
            self.c.shift_ri(x::SHR, 8, rd, bits);
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
            return self.fb, va.off;
        }
        assert(va.home == H_SLOT, "x64gen: a memory value without a slot");
        return x::RSP, va.off;
    }

    // The address `v` + `off` as a base register and an offset: a slot or frame address folds in.
    fn addr(self: &mut Self, v: Value, off: i64) (u8, i64) {
        let (fr, base, at) = self.frame_addr(v);
        if fr {
            return base, at + off;
        }
        return self.reg(v), off;
    }

    // Whether address `v` is a slot or frame address no register holds (`addr`'s folds), with the frame's
    // register and the offset; else false, r11 and 0 (the caller puts `v` there).
    const fn frame_addr(self: &Self, v: Value) (bool, u8, i64) {
        let va = self.va[self.vx(v) as usize];
        if va.home == H_SPADDR {
            return true, x::RSP, va.off;
        }
        if va.home == H_FPADDR {
            return true, self.fb, va.off;
        }
        if va.home == H_REMAT && va.reg == NOREG && (v & (VPARAM | VFLAG)) == 0 {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return true, x::RSP, self.slot_off[it.a as usize];
            }
        }
        return false, S1, 0;
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
            return x::ix(rb, ri, (p.aux as u32).trailing_zeros() as u8, off as i32);
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
        let rd = self.def(i);
        self.c.setcc(cc, rd);
        if cc2 != NONE {
            self.c.setcc(cc2, S1);
            self.c.alu_rr(
                if and2 {
                    x::AND;
                } else {
                    x::OR;
                },
                1,
                rd,
                S1,
            );
        }
        self.c.ext(1, 4, false, rd, rd);
        self.va.index_mut(i as usize).clean = true;
        if cc2 == NONE && self.next_reads(i, i) {
            // The value has other uses; the branch or select after reads the flags all the same.
            self.cond = Cond { inst: self.vx(i), cc: cc };
        }
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
        let cc = self.compare(t);
        self.cond_value(i, cc, NONE, false);
        return true;
    }

    // The flags of the comparison condition value `v` folds into its select or branch (`lv::FOLD_CMP`),
    // set here and kept; NONE when it does not fold.
    fn folded_cmp(self: &mut Self, v: Value) u32 {
        if (v & (VPARAM | VFLAG)) != 0 || !self.lv.pfold[v as usize] {
            return NONE;
        }
        let cc = self.compare(self.b().insts[v as usize]);
        self.keep_flags = true;
        return cc;
    }

    // Comparison `t` of integers of at most 64 bits into the flags: its condition. A folded `and` compared
    // with 0 is a test (`lv::FOLD_TST`; a narrow one's mask is within its width, so 32 bits test it).
    fn compare(self: &mut Self, t: Inst) u32 {
        let ty = self.vt(t.a);
        let bits = type_bits(ty, self.ptr);
        let sz = bits / 8;
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            let n = self.b().insts[t.a as usize];
            let ra = self.reg(n.a);
            let tz = if bits < 32 {
                4u32;
            } else {
                sz;
            };
            let mut k: i32 = 0;
            let imm = self.imm32_of(n.b, bits.max(32), &mut k);
            let rb = if imm {
                NOREG;
            } else {
                self.reg(n.b);
            };
            let s0 = self.c.len();
            if imm {
                self.c.test_ri(tz, ra, k as u32);
            } else {
                self.c.test_rr(tz, ra, rb);
            }
            self.reflag(s0);
            return icond(t.aux);
        }
        let ra = self.reg(t.a);
        let mut k: i32 = 0;
        let imm = self.imm32_of(t.b, bits, &mut k);
        let rb = if imm {
            NOREG;
        } else {
            self.reg(t.b);
        };
        // The `add`, `sub`, `and`, `or` or `xor` just emitted set ZF from this register.
        let z = self.zf;
        if imm && k == 0 && (t.aux == C_EQ || t.aux == C_NE) && z.at == self.c.len() && z.pos == self.pos && z.reg == ra && z.sz == sz {
            return icond(t.aux);
        }
        let s0 = self.c.len();
        if imm && k == 0 {
            self.c.test_rr(sz, ra, ra);
        } else if imm {
            self.c.alu_ri(x::CMP, sz, ra, k);
        } else {
            self.c.alu_rr(x::CMP, sz, ra, rb);
        }
        self.reflag(s0);
        return icond(t.aux);
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
            (rb, ra);
        } else {
            (ra, rb);
        };
        self.c.sse_rr(
            if d {
                0x66u32;
            } else {
                0u32;
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
            x::CC_L;
        } else if c == C_SGE || c == C_SLE {
            x::CC_GE;
        } else if c == C_ULT || c == C_UGT {
            x::CC_B;
        } else {
            x::CC_AE;
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
        return lo, hi;
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
        let bits = type_bits(t.ty, self.ptr);
        let sz = wsz(bits);
        let r = if bits < 32 {
            self.ext(t.a, false, bits);
        } else {
            self.reg(t.a);
        };
        let rd = self.def(i);
        if t.op == O_POPCNT {
            self.popcount(rd, r, sz);
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
        // clz = (width - 1) - bsr, with bsr taken as -1 for 0.
        let w = if bits < 32 {
            32u32;
        } else {
            bits;
        };
        self.c.bsx(true, sz, rd, r);
        self.c.mov_ri(S1, 0xFFFFFFFFFFFFFFFF);
        self.c.cmov(x::CC_E, 8, rd, S1);
        self.c.unary(x::NEG, 8, rd);
        self.c.alu_ri(x::ADD, 4, rd, (w - 1 - (w - bits)) as i32);
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
        if self.lv.pfold[i as usize] {
            return true; // its use computes it (`lv::FOLD_*`)
        }
        if ty == T_I128 {
            return self.int128(i, t);
        }
        let bits = type_bits(ty, self.ptr);
        let sz = wsz(bits);
        let small = bits < 32;
        if op == O_NEG || op == O_NOT {
            let ra = self.reg(t.a);
            let rd = self.def_from(i, t.a, ra);
            self.c.unary(
                if op == O_NEG {
                    x::NEG;
                } else {
                    x::NOT;
                },
                sz,
                rd,
            );
            return true;
        }
        let alu = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR;
        let mut k: i32 = 0;
        let kc = self.imm32_of(t.b, bits, &mut k);
        if alu {
            let aop = alu_of(op);
            let ra = self.reg(t.a);
            if kc {
                let rd = self.def_from(i, t.a, ra);
                self.c.alu_ri(aop, sz, rd, k);
                self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def_from(i, t.a, ra);
            self.c.alu_rr(aop, sz, rd, rb);
            self.zf = Zf { reg: rd, sz: sz, at: self.c.len(), pos: self.pos };
            return true;
        }
        if op == O_MUL {
            let ra = self.reg(t.a);
            // A product by 3, 5 or 9 is an address: `lea` (one cycle against `imul`'s three); by one of them
            // times 2^s, `lea` then a shift; by 2^s - 1, a shift and a subtraction.
            let kw = k as i64;
            let tz = if kw > 0 {
                kw.trailing_zeros() as u32;
            } else {
                0u32;
            };
            let odd = kw >> tz as i64;
            if kc && kw > 0 && (odd == 3 || odd == 5 || odd == 9) {
                let rd = self.def(i);
                self.c.rm(0, 0x8D, sz == 8, rd, x::ix(ra, ra, (odd - 1).trailing_zeros() as u8, 0), false);
                if tz != 0 {
                    self.c.shift_ri(x::SHL, sz, rd, tz);
                }
                return true;
            }
            if kc && kw >= 7 && (kw & kw + 1) == 0 {
                let rd = self.def(i);
                if rd != ra {
                    self.c.mov_rr(sz, rd, ra);
                    self.c.shift_ri(x::SHL, sz, rd, (kw + 1).trailing_zeros() as u32);
                    self.c.alu_rr(x::SUB, sz, rd, ra);
                    return true;
                }
                self.c.imul_ri(sz, rd, ra, k);
                return true;
            }
            if kc {
                let rd = self.def(i);
                self.c.imul_ri(sz, rd, ra, k);
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def_from(i, t.a, ra);
            self.c.imul_rr(sz, rd, rb);
            return true;
        }
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            let sop = if op == O_SHL {
                x::SHL;
            } else if op == O_LSHR {
                x::SHR;
            } else {
                x::SAR;
            };
            let mut kk: u64 = 0;
            if self.const_of(t.b, &mut kk) && kk < bits as u64 {
                let ra = self.reg(t.a);
                let rd = if small && op != O_SHL {
                    let r = self.def(i);
                    self.c.ext(bits / 8, 4, op == O_ASHR, r, ra);
                    r;
                } else {
                    self.def_from(i, t.a, ra);
                };
                self.c.shift_ri(sop, sz, rd, kk as u32);
                return true;
            }
            self.vacate(x::RCX);
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            self.c.mov_rr(4, x::RCX, rb);
            let rd = if small && op != O_SHL {
                let r = self.def(i);
                self.c.ext(bits / 8, 4, op == O_ASHR, r, ra);
                r;
            } else {
                self.def_from(i, t.a, ra);
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
                x::IDIV;
            } else {
                x::DIV;
            },
            sz,
            rb,
        );
        self.result_in(
            i,
            if op == O_SDIV || op == O_UDIV {
                x::RAX;
            } else {
                x::RDX;
            },
        );
        return true;
    }

    // i128 arithmetic on two-word memory values; division and remainder call compiler-rt.
    fn int128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op >= O_SDIV && op <= O_UREM {
            let name = if op == O_SDIV {
                "__divti3";
            } else if op == O_UDIV {
                "__udivti3";
            } else if op == O_SREM {
                "__modti3";
            } else {
                "__umodti3";
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
            (x::ADD, x::ADC);
        } else if op == O_SUB {
            (x::SUB, x::SBB);
        } else {
            let a = alu_of(op);
            (a, a);
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
                x::SAR;
            } else {
                x::SHR;
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
                NOREG;
            } else {
                self.reg(t.b);
            };
            let rd = self.def_from(i, t.a, ra);
            if op == O_MULO {
                self.c.imul_rr(sz, rd, rb);
                cc = x::CC_O;
            } else {
                let a = if op == O_ADDO {
                    x::ADD;
                } else {
                    x::SUB;
                };
                if imm {
                    self.c.alu_ri(a, sz, rd, k);
                } else {
                    self.c.alu_rr(a, sz, rd, rb);
                }
                cc = if signed {
                    x::CC_O;
                } else {
                    x::CC_B;
                };
            }
        }
        self.flag_of(i, cc);
        return true;
    }

    // The overflow flag of instruction `i` is condition `cc`: for the branch right after, or set into its
    // own register.
    fn flag_of(self: &mut Self, i: u32, cc: u32) {
        if let Some(fx) = self.lv.flag_of.get(&i) {
            let f = *fx;
            if self.fusable(i, VFLAG | i) {
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

    // `r` (an xmm register) with its sign bit cleared (`abs`) or flipped, through r11 and xmm15.
    fn fsign(self: &mut Self, d: bool, abs: bool, r: u8) {
        let sb = if d {
            0x8000000000000000u64;
        } else {
            0x80000000u64;
        };
        self.c.mov_ri(
            S1,
            if abs {
                ~sb & ast_mask(d);
            } else {
                sb;
            },
        );
        self.c.movd_to_x(
            if d {
                8u32;
            } else {
                4u32;
            },
            self.vs1 - V0,
            S1,
        );
        self.c.sse_rr(
            0,
            if abs {
                0x0F54u32;
            } else {
                0x0F57u32;
            },
            r - V0,
            self.vs1 - V0,
        );
    }

    fn convert(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if is_vec(from) || is_vec(to) {
            if self.conv_reg(t) {
                self.vconv_reg(i, t);
                return true;
            }
            if op == O_BITCAST && Gen::in_mem(from) && Gen::in_mem(to) {
                let (base, off) = self.mloc(t.a);
                let d = self.mdef(i);
                self.copy_mem(x::RSP, d, base, off, type_bytes(to, self.ptr));
                return true;
            }
            if op == O_BITCAST {
                // A vector and a scalar of one size: through memory.
                if Gen::in_mem(from) {
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
            let rd = self.def(i);
            if op == O_SEXT {
                self.c.ext(fb / 8, wsz(tb), true, rd, ra);
            } else {
                self.c.ext(fb / 8, 4, false, rd, ra);
            }
            self.va.index_mut(i as usize).clean = op == O_ZEXT;
            return true;
        }
        if op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST && !Gen::is_v(from) && !Gen::is_v(
            to,
        ) {
            let ra = self.reg(t.a);
            let _ = self.def_from(i, t.a, ra);
            return true;
        }
        if op == O_BITCAST {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if Gen::is_v(from) {
                self.c.movd_from_x(fb / 8, rd, ra - V0);
            } else {
                self.c.movd_to_x(tb / 8, rd - V0, ra);
            }
            return true;
        }
        if op == O_FPEXT || op == O_FPTRUNC {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            self.c.sse_rr(
                if op == O_FPEXT {
                    0xF3u32;
                } else {
                    0xF2u32;
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
                        4u32;
                    } else {
                        fb / 8;
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
                ((1u64 << (tb - 1) as u64).wrapping_neg(), (1u64 << (tb - 1) as u64) - 1);
            } else {
                (0u64, trunc64(~0u64, tb));
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
            0x43E0000000000000u64;
        } else {
            0x5F000000u64;
        };
        self.fconst(self.vs1, d, two63);
        self.c.sse_rr(
            if d {
                0x66u32;
            } else {
                0u32;
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
                0x66u32;
            } else {
                0u32;
            },
            0x0F2E,
            ra - V0,
            ra - V0,
        );
        let nan = self.c.jcc32(x::CC_P);
        // The sign of the float: negative keeps the lowest value, positive takes the highest.
        self.c.rr(
            if d {
                0x66u32;
            } else {
                0u32;
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
            "__floattidf";
        } else if op == O_SITOFP {
            "__floattisf";
        } else if op == O_UITOFP && d {
            "__floatuntidf";
        } else if op == O_UITOFP {
            "__floatuntisf";
        } else if op == O_FPTOSI && fd {
            "__fixdfti";
        } else if op == O_FPTOSI {
            "__fixsfti";
        } else if fd {
            "__fixunsdfti";
        } else {
            "__fixunssfti";
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
        let scale = t.aux as u32;
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
        if Gen::in_mem(ty) && !self.in_reg(ty) {
            let (base, off) = self.addr(t.a, t.c as i32);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, base, off, type_bytes(ty, self.ptr));
            return true;
        }
        let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
        let rd = if self.in_reg(ty) {
            self.vec_def(i);
        } else {
            self.def_pass(i, t.a);
        };
        self.ld(ty, rd, m);
        self.mem_rel(rs, radd);
        self.va.index_mut(i as usize).clean = !Gen::is_v(ty) && type_bits(ty, self.ptr) < 64;
        return true;
    }

    // `rstore`: when the result (an aggregate in registers) is written only by stores that end blocks
    // which return, each a whole part and only such stores between it and the `ret`, 1 + each one's part:
    // the first of each run moves the run's values into the part registers (`ret_moves`), and the return
    // reads no memory. All 0 when not.
    fn ret_stores(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill32(&mut self.rstore, ni, 0);
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
                    fill32(&mut self.rstore, ni, 0);
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
            if pa.off == t.c && pa.size as u32 == type_bytes(ty, self.ptr) && pa.v == Gen::is_v(ty) && !Gen::in_mem(ty) {
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
                V0;
            } else {
                0;
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
        self.resolve_moves();
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
            o.a;
        } else {
            o.b;
        };
        if !alu || o.ty != t.ty || !swap && (o.a != i || o.b == i) || self.lv.pfold[i as usize + 1] {
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
            NOREG;
        } else {
            self.reg(k);
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
        if Gen::in_mem(ty) {
            let (base, off) = self.addr(t.a, t.c as i32);
            let (sb, so) = self.mloc(t.b);
            self.copy_mem(base, off, sb, so, type_bytes(ty, self.ptr));
            return true;
        }
        let n = type_bytes(ty, self.ptr);
        let mut k: i32 = 0;
        if !Gen::is_v(ty) && self.imm32_of(t.b, n * 8, &mut k) {
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

    // `memcpy` and `memset`: inline for a constant size up to 128 bytes (an overlapping copy loads every
    // chunk before storing one, up to 64 bytes), else a call of the C library's routine.
    fn mem_block(self: &mut Self, i: u32, t: Inst) bool {
        let mut n: u64 = 0;
        let known = self.const_of(t.c, &mut n);
        let overlap = t.op == O_MEMCPY && t.aux == MEM_OVERLAP;
        let lim: u64 = if overlap {
            64;
        } else {
            128;
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
                        8u32;
                    } else if left >= 4 {
                        4u32;
                    } else if left >= 2 {
                        2u32;
                    } else {
                        1u32;
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
            "memset";
        } else if overlap {
            "memmove";
        } else {
            "memcpy";
        };
        let vs: [Value; 3] = [t.a, t.b, t.c];
        self.rt_call(name, vs);
        let _ = i;
        return true;
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
        let cx = self.vx(t.a);
        // The condition first: a folded comparison loads its operands, which the values' registers survive.
        let cc = self.cond_of(cx, t.a);
        if Gen::in_mem(ty) {
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
        if Gen::is_v(ty) {
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let rd = self.def(i);
            self.c.vmov(rd - V0, rb - V0);
            let skip = self.c.jcc32(cc);
            self.c.vmov(rd - V0, rc - V0);
            self.c.land(skip, self.c.len());
            return true;
        }
        // The false side straight into the result's register: a constant or a spilled value takes no
        // register of its own.
        let rb = self.reg(t.b);
        let rd = self.def(i);
        self.materialize(t.c, rd);
        self.c.cmov(cc, 8, rd, rb);
        return true;
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
            if Gen::in_mem(ty) {
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
                (0i32, 48 - 8 * ngp as i32, 8 * ngp as i32);
            } else {
                (4i32, 176 - 16 * nvr as i32, 16 * nvr as i32);
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
        if Gen::in_mem(ty) {
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
            t.ty;
        } else {
            self.vt(t.b);
        };
        assert(!Gen::in_mem(ty) && !Gen::is_v(ty), "x64gen: an atomic access of a type the verifier rejects");
        let sz = type_bytes(ty, self.ptr);
        let ord = t.aux & 7;
        let rmw_or = op == O_ARMW && (t.aux >> 4 == RMW_AND || t.aux >> 4 == RMW_OR || t.aux >> 4 == RMW_XOR);
        if op == O_ACAS || rmw_or {
            self.vacate(x::RAX);
        }
        let (base, off) = self.addr(
            t.a,
            if op == O_ACAS {
                0;
            } else {
                t.c as i32;
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
                    x::AND;
                } else if r == RMW_OR {
                    x::OR;
                } else {
                    x::XOR;
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

    // The argument and result locations of call `t` (`lay`): an intrinsic's (`abi::intrinsic_layout`, the
    // System V registers its instructions name), else the convention's.
    // `lv.relay`: the stores whose value a call takes in place of a register-passed aggregate argument's
    // memory. The argument is a slot's address; the stores into the slot before the call in its block (back
    // to another use of the slot's addresses) each write a whole part (its offset, size and register file),
    // and every part has one. When every use of the slot's addresses is such a store or such an argument,
    // no other access reads the bytes: the stores write nothing, and each call moves the last store's
    // value of each part into the part's register.
    fn arg_relays(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        self.lv.relay.truncate(0);
        self.lv.relayed.truncate(0);
        // Each slot's address uses: operands, call arguments and edge arguments.
        let mut uses = Vector::<u32>::new();
        uses.resize_default(b.slots.len());
        let mut calls = false;
        let mut us = Vector::<Value>::new();
        let mut es = Vector::<u32>::new();
        for i in 0..ni {
            let t = b.insts[i];
            calls = calls || t.op == O_CALL || t.op == O_CALLIND;
            lv::each_use(b, t, &mut us);
            b.succ_edges(t, &mut es);
            for e in 0..es.len() {
                for q in 0..b.edge_nargs(es[e]) {
                    us.push(b.edge_arg(es[e], q));
                }
            }
            for q in 0..us.len() {
                let v = us[q];
                if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR {
                    uses[b.insts[v as usize].a as usize] += 1;
                }
            }
        }
        if !calls {
            return;
        }
        let mut stores = Vector::<u32>::new();
        // The groups: per argument, its slot << 32 | its call; per store, its group << 32 | the store
        // (bit 31: a part's value). `covered`: per slot, the uses its groups account for.
        let mut groups = Vector::<u64>::new();
        let mut gst = Vector::<u64>::new();
        let mut covered = Vector::<u32>::new();
        covered.resize_default(b.slots.len());
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for c in bk.start..bk.start + bk.len {
                let t = b.insts[c as usize];
                if t.op != O_CALL && t.op != O_CALLIND || t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
                    continue;
                }
                self.call_layout(t);
                let np = b.pool[t.b as usize];
                for q in 0..np {
                    let v = b.pool[(t.c + q) as usize];
                    let loc = self.lay.locs[q as usize];
                    if loc.kind != ab::L_REG || (b.pool[(t.b + 3 + q) as usize] & AGG) == 0 || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SLOTADDR {
                        continue;
                    }
                    let s = b.insts[v as usize].a;
                    // The stores into the slot before the call, nearest first; each part's first is its value.
                    stores.truncate(0);
                    let mut seen: u32 = 0;
                    let mut whole = true;
                    let mut j = c;
                    while j > bk.start {
                        j -= 1;
                        let u = b.insts[j as usize];
                        if u.op != O_STORE || (u.a & (VPARAM | VFLAG)) != 0 || b.insts[u.a as usize].op != O_SLOTADDR || b.insts[u.a as usize].a != s {
                            // Another use of the slot's addresses (an earlier call's argument) ends the run.
                            if lv::reads_slot(b, u, s, &mut us, &mut es) {
                                break;
                            }
                            continue;
                        }
                        let pq = self.arg_part(loc, u);
                        if pq == NONE {
                            whole = false;
                            break;
                        }
                        if (seen >> pq & 1) == 0 {
                            stores.push(j);
                        }
                        seen |= 1u32 << pq;
                        stores.push(j | 0x80000000);
                    }
                    if !whole || seen != (1u32 << loc.n as u32) - 1 {
                        continue;
                    }
                    let g = groups.len() as u64;
                    groups.push(s as u64 << 32 | c as u64);
                    // The argument, and each store once.
                    covered[s as usize] += 1;
                    for z in 0..stores.len() {
                        gst.push(g << 32 | stores[z] as u64);
                        covered[s as usize] += ((stores[z] & 0x80000000) != 0) as u32;
                    }
                }
            }
        }
        // A slot whose every address use its groups account for: their stores relay.
        for z in 0..gst.len() {
            let gr = groups[(gst[z] >> 32) as usize];
            let s = (gr >> 32) as usize;
            if covered[s] != uses[s] {
                continue;
            }
            if self.lv.relay.len() == 0 {
                fill32(&mut self.lv.relay, ni, NONE);
            }
            let c = gr as u32;
            let st = gst[z] as u32 & 0x7FFFFFFF;
            if (gst[z] & 0x80000000) != 0 {
                self.lv.relay[st as usize] = c;
            } else {
                self.lv.relayed.push(c as u64 << 32 | st as u64);
            }
        }
    }

    // The part (0 ..) of register-passed argument `loc` that store `u` writes whole, else NONE.
    fn arg_part(self: &Self, loc: ab::ALoc, u: Inst) u32 {
        if (u.aux & MEM_VOLATILE) != 0 || (u.b & VFLAG) != 0 {
            return NONE;
        }
        let ty = self.vt(u.b);
        for q in 0..loc.n as u32 {
            let pa = self.lay.parts[(loc.p0 + q) as usize];
            if pa.off == u.c && pa.size as u32 == type_bytes(ty, self.ptr) && pa.v == Gen::is_v(ty) && !Gen::in_mem(ty) {
                return q;
            }
        }
        return NONE;
    }

    // Aggregate argument `v` (`loc`) of call `i` taken from its relayed stores' values (`arg_relays`): into
    // the parallel move (`mv`) for those in a register or a home, else into `vals` (part register << 32 |
    // value) for after it; whether it is.
    fn relay_parts(self: &mut Self, i: u32, v: Value, loc: ab::ALoc, vals: &mut Vector<u64>) bool {
        let b = self.b();
        if self.lv.relay.len() == 0 || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SLOTADDR {
            return false;
        }
        let s = b.insts[v as usize].a;
        let mut any = false;
        for q in 0..self.lv.relayed.len() {
            if (self.lv.relayed[q] >> 32) as u32 != i {
                continue;
            }
            let st = b.insts[(self.lv.relayed[q] & 0xFFFFFFFF) as usize];
            if b.insts[st.a as usize].a != s {
                continue;
            }
            any = true;
            let pa = self.lay.parts[(loc.p0 + self.arg_part(loc, st)) as usize];
            let r = pa.reg + if pa.v {
                V0;
            } else {
                0;
            };
            let src = self.loc_of(self.vx(st.b));
            if src.kind == LC_VAL {
                vals.push(r as u64 << 32 | st.b as u64);
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
        return any;
    }

    fn call_layout(self: &mut Self, t: Inst) {
        let b = self.b();
        if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
            let gp: [u8; 8] = [x::RDI, x::RSI, x::RDX, x::RCX, x::R8, x::R9, x::R10, x::R11];
            ab::intrinsic_layout(b, t.b, self.ptr, gp[0..8], x::RAX, &mut self.lay);
            return;
        }
        classify(self.win, b, t.b, self.ptr, self.vregs, &mut self.lay);
    }

    // The instructions of the intrinsic body symbol `s` names (`target::intrin`); empty for another
    // function.
    const fn intrinsic(self: &Self, s: u32) str<'static> {
        let p = unsafe &*self.pkg;
        let ps = p.syms[self.b().syms[s as usize] as usize];
        if ps.def != NONE {
            return "";
        }
        let nm = p.spell(ps.name);
        return intrin::find(
            "x86_64",
            if nm.starts_with("__sc_x_") {
                nm.slice(7, nm.len());
            } else {
                nm;
            },
        );
    }

    // Whether call `t`, instruction `i`, is a sibling call (`Package.tail`, `tail_ok`): its block returns
    // its result (or nothing) right after it, its result's code is the body's, it passes every argument in
    // registers and none an aggregate (a copy in this frame), and it is no variadic call (System V's al),
    // no intrinsic and no call through the address slot (`-fno-plt`); then its return is not emitted
    // (`tail_ret`).
    fn sibling(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        if !self.tail_ok || i + 2 != bk.start + bk.len || self.lay.ret.kind == ab::L_SRET || (b.pool[t.b as usize + 1] & SIG_VARIADIC) != 0 {
            return false;
        }
        let r = b.insts[i as usize + 1];
        let rt = b.pool[t.b as usize + 2];
        if r.op != O_RET || !(r.a == i && t.ty != T_NONE || r.a == VNONE && t.ty == T_NONE) || rt != b.pool[b.sig as usize + 2] || (rt & AGG) != 0 {
            return false;
        }
        let p = unsafe &*self.pkg;
        if t.op == O_CALL && (self.intrinsic(t.a).len() != 0 || p.no_plt && !self.win && p.syms[b.syms[t.a as usize] as usize].ext) {
            return false;
        }
        for k in 0..b.pool[t.b as usize] {
            if (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 || self.lay.locs[k as usize].kind != ab::L_REG {
                return false;
            }
        }
        // The epilogue's `vzeroupper` would clear a 32-byte argument's upper half.
        if self.ymm && ymm_parts(&self.lay) {
            return false;
        }
        self.tail_ret = i + 1;
        return true;
    }

    fn call(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let sig = t.b;
        let np = b.pool[sig as usize];
        let rt = b.pool[sig as usize + 2];
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a);
        } else {
            "";
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
            self.clob = 0;
            for q in 0..self.lay.parts.len() {
                let pa = self.lay.parts[q];
                self.clob |= bit(
                    pa.reg + if pa.v {
                        V0;
                    } else {
                        0;
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
                    self.clob |= bit(r);
                }
            }
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
            let mut ok = tpl.len() != 0 && self.vec_in_reg(loc, self.vt(v)) && vr != NOREG && vr >= V0;
            ok = ok && ((self.clob & bit(vr)) == 0 || vr == V0 + self.lay.parts[loc.p0 as usize].reg);
            for j in 0..to.len() {
                ok = ok && to[j] != (vr - V0) as u32;
            }
            let pr = if ok {
                self.lay.parts[loc.p0 as usize].reg as u32;
            } else {
                0u32;
            };
            if ok && intrin::vwrites(false, tx, pr) {
                let rl = self.lay.ret;
                ok = rres == NOREG && self.vec_in_reg(rl, t.ty);
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
        if tpl.len() != 0 && rres == NOREG && self.vec_in_reg(rl, t.ty) && self.live_on(self.vx(i)) {
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
            if k == np || self.lay.locs[k as usize].kind != ab::L_REG || (b.pool[(sig + 3 + k) as usize] & AGG) != 0 {
                other.push(self.vx(v));
            }
        }
        if t.op == O_CALLIND {
            other.push(self.vx(t.a));
        }
        let mut keep = Vector::<u32>::new();
        for k in 0..np {
            let v = b.pool[(t.c + k) as usize];
            let x = self.vx(v);
            let mut shared = false;
            for q in 0..other.len() {
                shared = shared || other[q] == x;
            }
            let vty = self.vt(v);
            let loc = self.lay.locs[k as usize];
            if !shared && loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!Gen::in_mem(vty) || self.vec_in_reg(
                loc,
                vty,
            )) && self.va[x as usize].reg != NOREG {
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
                self.lay.ret.p0 as usize;
            } else {
                self.lay.parts.len();
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
                let at = self.ref_copy(b.pool[(t.c + k) as usize], b.pool[(sig + 3 + k) as usize]);
                self.c.lea(S0, x::at(x::RSP, at));
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
                self.materialize(v, S1);
                self.copy_mem(x::RSP, loc.off, S1, 0, loc.size);
            } else if Gen::in_mem(vty) {
                let (base, off) = self.mloc(v);
                self.copy_mem(x::RSP, loc.off, base, off, loc.size);
            } else {
                let r = if Gen::is_v(vty) {
                    self.vs0;
                } else {
                    S0;
                };
                self.materialize(v, r);
                self.st(vty, r, x::at(x::RSP, loc.off as i32));
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
            relayed.push(
                loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) != 0 && self.relay_parts(
                    i,
                    v,
                    loc,
                    &mut rvals,
                ),
            );
            if loc.kind != ab::L_REG || (b.pool[(sig + 3 + k) as usize] & AGG) != 0 || Gen::in_mem(vty) && !self.vec_in_reg(
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
                rres;
            } else if pa.v {
                pa.reg + V0;
            } else {
                pa.reg;
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
                loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!Gen::in_mem(vty) || self.vec_in_reg(
                    loc,
                    vty,
                )) && self.loc_of(x).kind != LC_VAL || ren[k as usize] || relayed[k as usize],
            );
            clean.push(va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG));
        }
        self.resolve_moves();
        // The moved values' registers now hold arguments.
        self.forget_caller_saved();
        // The relayed aggregate parts' constants and addresses (`relay_parts`).
        for q in 0..rvals.len() {
            self.materialize(rvals[q] as u32, (rvals[q] >> 32) as u8);
        }
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            if relayed[k as usize] {
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
            } else if Gen::in_mem(vty) {
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
                    rres;
                } else if pa.v {
                    pa.reg + V0;
                } else {
                    pa.reg;
                };
                if loc.ext != 0 {
                    self.materialize_ext(v, r, loc.ext == 2, type_bits(vty, self.ptr));
                } else {
                    self.materialize(v, r);
                }
            }
        }
        if self.lay.ret.kind == ab::L_SRET {
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
            if !asmr::Asm::inline_x64(text.as_str(), &mut self.c.b, &mut rels, &mut e) {
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
                self.osym_of(t.a);
            } else {
                NONE;
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
        self.called = true;
        if rl.kind != ab::L_REG {
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
        if self.vec_in_reg(rl, t.ty) {
            self.result_in(
                i,
                if rres != NOREG {
                    rres;
                } else {
                    self.lay.parts[rl.p0 as usize].reg + V0;
                },
            );
            return true;
        }
        if Gen::in_mem(t.ty) {
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
                V0;
            } else {
                0;
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

    // Whether argument or result location `loc` (`lay`) takes vector type `t` whole in one vector register.
    const fn vec_in_reg(self: &Self, loc: ab::ALoc, t: u8) bool {
        if loc.kind != ab::L_REG || loc.n != 1 || !Gen::in_vreg(t) {
            return false;
        }
        let pa = self.lay.parts[loc.p0 as usize];
        return pa.v && pa.size as u32 == type_bytes(t, 8);
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

    // A call of C function `name` with the integer or pointer values `vs` in the argument registers and
    // no result.
    fn rt_call(self: &mut Self, name: str, vs: []Value) {
        // The operands in registers stay there for the parallel move, as a call's arguments do; one that
        // lives on is in its home too.
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
        self.call_sym(name);
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
        self.resolve_moves();
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
                xa;
            } else {
                ya;
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
                    if Gen::is_v(ty) {
                        V0;
                    } else {
                        cc::gp_arg(gr as u32);
                    },
                );
                gr += (!Gen::is_v(ty)) as usize;
            }
        }
        self.args_to(vs[0..vs.len()], rs[0..rs.len()]);
        gr = 0;
        for k in 0..2 {
            let v = if k == 0 {
                xa;
            } else {
                ya;
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
            } else if !Gen::is_v(ty) {
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
                if Gen::is_v(ty) {
                    V0;
                } else {
                    x::RAX;
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
            1;
        } else {
            0;
        };
        for q in 0..2 {
            let v = if q == 0 {
                xa;
            } else {
                ya;
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
            } else if Gen::is_v(ty) {
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
                if Gen::is_v(ty) {
                    V0;
                } else {
                    x::RAX;
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

    // A two-way branch: condition `cc` takes edge `et`, else `ef`; each edge's moves on its own path.
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

    fn branch2(self: &mut Self, cc: u32, et: u32, ef: u32) {
        let b = self.b();
        let mt = self.moves_needed(et);
        let mf = self.moves_needed(ef);
        let tt = b.edge_target(et);
        let tf = b.edge_target(ef);
        let q = self.pos as usize + 1;
        let next = if q < self.lv.order.len() && !self.crosses(self.lv.order[q]) {
            self.lv.order[q];
        } else {
            NONE;
        };
        if !mt && !mf {
            if tt == next {
                self.cbranch(x::invert(cc), tf);
            } else {
                self.cbranch(cc, tt);
                self.goto(tf, false);
            }
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
            self.edge_moves(t.a);
            self.goto(b.edge_target(t.a), false);
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
            return true;
        }
        if op == O_UNREACHABLE {
            self.c.ud2();
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
                self.c.vmov(pa.reg, self.va[self.vx(t.a) as usize].reg - V0);
            } else if Gen::in_mem(self.vt(t.a)) {
                let (base, off) = self.mloc(t.a);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else {
                let pa = self.self_lay.parts[rl.p0 as usize];
                let r = pa.reg + if pa.v {
                    V0;
                } else {
                    0;
                };
                let ty = self.vt(t.a);
                if ty == T_I8 || ty == T_I16 {
                    self.materialize_ext(t.a, r, (rt & SIG_SEXT) != 0, type_bits(ty, self.ptr));
                } else {
                    self.materialize(t.a, r);
                }
            }
        } else if rl.kind == ab::L_SRET {
            // rax: the memory's pointer, the value copied there first for a memory value.
            if (rt & AGG) != 0 {
                self.materialize(VPARAM | b.blocks[0].param_start + np, x::RAX);
            } else {
                self.c.load(8, false, x::RAX, x::at(x::RSP, self.sret_off as i32));
                let (base, off) = self.mloc(t.a);
                self.copy_mem(x::RAX, 0, base, off, type_bytes(self.vt(t.a), self.ptr));
            }
        }
        let at = self.c.jmp32();
        self.epi.push(at);
    }

    // The object symbol of C string `text`, one per text.
    fn cstr(self: &mut Self, text: str) u32 {
        let key = String::from_str(text);
        if let Some(k) = self.msg_sym.get(&key) {
            return *k;
        }
        let name = format("__sc_msg.{}", self.cstr_n);
        self.cstr_n += 1;
        let o = self.obj();
        let k = o.sym(name.as_str());
        let _ = o.define(k, ob::S_CSTR, 0, text.len() as u64 + 1, 0);
        for j in 0..text.len() {
            let one: [u8; 1] = [text.byte_at(j)];
            o.put(ob::S_CSTR, one);
        }
        let z: [u8; 1] = [0];
        o.put(ob::S_CSTR, z);
        self.msg_sym.insert(key, k);
        return k;
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
        self.cstr_addr(self.arg(0), text);
        self.call_sym("__sc_panic");
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

    fn finish(self: &mut Self, s: u32) bool {
        let sw = self.shrink;
        let ra = if sw {
            self.rare_at();
        } else {
            0;
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
        let b = self.b();
        let mut leaf = !self.win && !self.called && self.canary < 0;
        for k in 0..b.slots.len() {
            leaf = leaf && b.slots[k].align_log2 <= 3;
        }
        for k in 0..b.insts.len() {
            leaf = leaf && b.insts[k].op != O_ASM;
        }
        let mut local = if leaf {
            self.spill_base + self.spill_top + 7 & ~7u32;
        } else {
            self.spill_base + self.spill_top + 15 & ~15u32;
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
            0;
        } else {
            pl;
        };
        let body_n = self.c.len();
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
                        self.c.b[(body_n + k) as usize];
                    } else if k == n {
                        0xC3;
                    } else {
                        0xCC;
                    };
                }
                self.drop_jump(at);
            }
            self.epi = keep;
        }
        for q in 0..self.tails.len() {
            let at = (self.tails[q] >> 32) as u32;
            let os = self.tails[q] as u32;
            if sw && at < ra {
                // From the warm code, which has no frame: the callee's jump in the jump's place.
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
                self.c.byte(self.c.b[k as usize]);
            }
            self.tail_jump(os);
        }
        // An epilogue no longer than a jump (no canary check) takes each jump's place, the bytes left over
        // traps after its `ret`.
        let en = epi_end - body_n;
        if en <= 5 && self.canary < 0 && self.epi.len() != 0 {
            let mut keep = Vector::<u32>::with_capacity(self.c.jumps.len());
            let mut q: usize = 0;
            for j in 0..self.c.jumps.len() {
                let at = self.c.jumps[j];
                if q < self.epi.len() && self.epi[q] == at {
                    for k in 0..5u32 {
                        self.c.b[(at - 1 + k) as usize] = if k < en {
                            self.c.b[(body_n + k) as usize];
                        } else {
                            0xCC;
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
                };
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
                        self.c.byte(self.c.b[k as usize]);
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
                        e;
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
                            self.c.byte(self.c.b[k as usize]);
                        }
                        let j = self.c.jmp32();
                        self.c.land(j, to);
                        leave.insert(to, e);
                        e;
                    },
                });
            }
            self.c.land(at, to);
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
        for q in 0..stubs.len() {
            ats.push(stubs[q]);
        }
        ats.push(tails_end);
        ats.push(ra);
        ats.push(body_n);
        self.c.relax(&mut ats);
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
        let k2 = o.sym(p.spell(ps.name));
        let size = lead + self.c.len();
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true);
        } else if ps.cold {
            o.named(self.cold_text(), true);
        } else {
            ob::S_TEXT;
        };
        if sec == ob::NOSEC {
            return self.refuse("too many sections");
        }
        let mut fl = ob::SF_FUNC | if ps.linkage == SL_GLOBAL && !self.local {
            ob::SF_GLOBAL;
        } else {
            0;
        };
        if ps.used {
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
            self.obj().named(p.spell(ps.sect), false);
        } else if tls && zero {
            ob::S_TBSS;
        } else if tls {
            ob::S_TDATA;
        } else if zero && !d.readonly {
            ob::S_BSS;
        } else if d.readonly && d.nrelocs == 0 {
            ob::S_RODATA;
        } else if d.readonly {
            ob::S_RELRO;
        } else {
            ob::S_DATA;
        };
        let o = self.obj();
        let k = o.sym(p.spell(ps.name));
        let mut fl = if ps.linkage == SL_GLOBAL && !local {
            ob::SF_GLOBAL;
        } else {
            0;
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
        0x660000;
    } else {
        0;
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
        unsafe f[k];
    } else if sg {
        unsafe s[k];
    } else {
        unsafe u[k];
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
        0x660000;
    } else {
        0;
    };
    if is_float(lt) {
        return if op == O_FADD {
            pd | 0x158;
        } else if op == O_FSUB {
            pd | 0x15C;
        } else if op == O_FMUL {
            pd | 0x159;
        } else if op == O_FDIV {
            pd | 0x15E;
        } else if op == O_FNEG {
            pd | 0x157;
        } else if op == O_FSQRT {
            pd | 0x151;
        } else {
            NONE;
        };
    }
    return if op == O_ADD {
        0x660100 | padd(eb) & 0xFF;
    } else if op == O_SUB || op == O_NEG {
        0x660100 | psub(eb) & 0xFF;
    } else if op == O_MUL && eb == 2 {
        0x6601D5;
    } else if op == O_MUL && eb == 4 {
        0x660240;
    } else if op == O_AND {
        0x6601DB;
    } else if op == O_OR {
        0x6601EB;
    } else if op == O_XOR || op == O_NOT {
        0x6601EF;
    } else {
        NONE;
    };
}

// The AVX-512 form of vector operation `op` on lanes of `lt` (64 bytes): EVEX.W << 24 | its legacy prefix
// << 16 | opcode map << 8 | opcode, NONE when it has none (a product of bytes). `neg` is a subtraction
// from 0, `not` a `vpternlogd` (`zmm_reg`), `fneg` an xor of the sign bits (`vxorps`/`vxorpd`, DQ).
const fn evex_of_op(op: u8, lt: u8) u32 {
    let eb = type_bytes(lt, 8);
    if is_float(lt) {
        let pd: u32 = if lt == T_F64 {
            0x1660000;
        } else {
            0;
        };
        return if op == O_FADD {
            pd | 0x158;
        } else if op == O_FSUB {
            pd | 0x15C;
        } else if op == O_FMUL {
            pd | 0x159;
        } else if op == O_FDIV {
            pd | 0x15E;
        } else if op == O_FNEG {
            pd | 0x157;
        } else if op == O_FSQRT {
            pd | 0x151;
        } else {
            NONE;
        };
    }
    let w: u32 = if eb == 8 {
        0x1000000;
    } else {
        0;
    };
    return if op == O_ADD {
        w | 0x660100 | padd(eb) & 0xFF;
    } else if op == O_SUB || op == O_NEG {
        w | 0x660100 | psub(eb) & 0xFF;
    } else if op == O_MUL && eb == 2 {
        0x6601D5;
    } else if op == O_MUL && eb >= 4 {
        w | 0x660240;
    } else if op == O_AND {
        0x6601DB;
    } else if op == O_OR {
        0x6601EB;
    } else if op == O_XOR {
        0x6601EF;
    } else if op == O_NOT {
        0x660325;
    } else {
        NONE;
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
            x::CC_L;
        } else {
            x::CC_B;
        };
    }
    if c == core::SIMD_CMP_LE {
        return if sg {
            x::CC_LE;
        } else {
            x::CC_BE;
        };
    }
    if c == core::SIMD_CMP_GT {
        return if sg {
            x::CC_G;
        } else {
            x::CC_A;
        };
    }
    return if sg {
        x::CC_GE;
    } else {
        x::CC_AE;
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
            16;
        } else {
            8;
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
                        0x8000000000000000u64;
                    } else {
                        0x8000000080000000u64;
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
                        0x8000000000000000u64;
                    } else {
                        0x8000000080000000u64;
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
    // for 64 bytes), one 8-byte word repeated through r11 and a broadcast, else its words through a slot of
    // the frame.
    fn wconst_reg(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let mut zero = true;
        let mut ones = true;
        let mut same = true;
        for k in 0..t.b {
            let w = b.words[(t.a + k) as usize];
            zero = zero && w == 0;
            ones = ones && w == ~0u64;
            same = same && w == b.words[t.a as usize];
        }
        let nb = type_bytes(t.ty, 8);
        let rd = self.vec_def(i) - V0;
        if nb == 64 {
            if zero {
                self.c.evex_rr(0x66, 1, 0xEF, false, rd, rd, rd);
            } else if ones {
                self.c.evex_rr(0x66, 3, 0x25, false, rd, rd, rd);
                self.c.byte(0xFF);
            } else if same {
                self.zmm_splat64(rd, b.words[t.a as usize]);
            } else {
                let s = self.slot_alloc(64, 16) as i32;
                for k in 0..8u32 {
                    self.c.mov_ri(S1, b.words[(t.a + k) as usize]);
                    self.c.store(8, S1, x::at(x::RSP, s + 8 * k as i32));
                }
                self.c.vload(64, rd, x::at(x::RSP, s));
            }
            return;
        }
        if nb == 32 {
            if zero || ones {
                self.c.vex_rr(
                    0x66,
                    1,
                    if zero {
                        0xEFu32;
                    } else {
                        0x76u32;
                    },
                    false,
                    true,
                    rd,
                    rd,
                    rd,
                );
            } else if same {
                self.ymm_splat64(rd, b.words[t.a as usize]);
            } else {
                let s = self.slot_alloc(32, 16) as i32;
                for k in 0..4u32 {
                    self.c.mov_ri(S1, b.words[(t.a + k) as usize]);
                    self.c.store(8, S1, x::at(x::RSP, s + 8 * k as i32));
                }
                self.c.vload(32, rd, x::at(x::RSP, s));
            }
            return;
        }
        if zero || ones {
            self.c.sse_rr(
                0x66,
                if zero {
                    0x0FEFu32;
                } else {
                    0x0F76u32;
                },
                rd,
                rd,
            );
            return;
        }
        self.c.mov_ri(S1, b.words[t.a as usize]);
        self.c.movd_to_x(8, rd, S1);
        if nb == 16 {
            let hi = b.words[t.a as usize + 1];
            if same {
                self.c.sse_rr(0x66, 0x0F6C, rd, rd);
            } else {
                let s = self.vs1 - V0;
                self.c.mov_ri(S1, hi);
                self.c.movd_to_x(8, s, S1);
                self.c.sse_rr(0x66, 0x0F6C, rd, s);
            }
        }
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
            self.vec_use(yv, self.vs1);
        } else {
            NOREG;
        };
        let rd = self.def_pass(i, xv);
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
        let rl = self.self_lay.ret;
        if rl.kind != ab::L_REG || rl.n != 1 || self.va[self.vx(v) as usize].reg == NOREG || !Gen::in_vreg(self.vt(v)) {
            return false;
        }
        let pa = self.self_lay.parts[rl.p0 as usize];
        return pa.v && pa.size as u32 == type_bytes(self.vt(v), 8);
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
        if !Gen::in_vreg(t.ty) {
            let r = self.reg(t.a);
            let d = self.mdef(i);
            for k in 0..lanes(t.ty) {
                self.st_lane(r, d, k, lt, false);
            }
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
                8u32;
            } else {
                4u32;
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
            0;
        } else if c == C_OLT || c == C_OGT {
            1;
        } else if c == C_OLE || c == C_OGE {
            2;
        } else {
            4;
        };
        if self.in_reg(vt) && type_bytes(vt, 8) == 64 {
            self.zmm_cmp(i, t, vt);
            return;
        }
        if self.in_reg(vt) && self.avx && (type_bytes(vt, 8) == 32 || !fl && eb == 8) {
            self.avx_cmp(i, t, vt);
            return;
        }
        if Gen::in_vreg(vt) && (fl || eb < 8) {
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
                (t.b, t.a);
            } else {
                (t.a, t.b);
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
            0;
        } else if c == C_OLT || c == C_OGT {
            1;
        } else if c == C_OLE || c == C_OGE {
            2;
        } else {
            4;
        };
        let swap = if fl {
            fswap;
        } else {
            c == C_SLT || c == C_SGE || c == C_ULT || c == C_UGE;
        };
        let (xv, yv) = if swap {
            (b, a);
        } else {
            (a, b);
        };
        let rx = self.vec_use(xv, self.vs0);
        let ry = self.vec_use(yv, self.vs1);
        let rd = if i == NONE {
            self.tmp(true);
        } else {
            self.vec_def(i);
        };
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
                0x8080808080808080u64;
            } else if eb == 2 {
                0x8000800080008000u64;
            } else {
                0x8000000080000000u64;
            };
            self.c.mov_ri(S1, sb);
            self.c.movd_to_x(8, s - V0, S1);
            self.c.sse_rr(0x66, 0x0F6C, s - V0, s - V0);
            self.c.vmov(rd - V0, s - V0);
            self.c.sse_rr(0x66, 0x0FEF, rd - V0, rx - V0);
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
            self.sse_mask(NONE, simd_cond(c, sg, fl), ops[0], ops[1]);
        } else if c == core::SIMD_IS_SIGN_NEG {
            self.vec_use(ops[0], self.vs0);
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
                    (0x7FFFFFFFFFFFFFFFu64, 0x7FF0000000000000u64);
                } else {
                    (0x7FFFFFFF7FFFFFFFu64, 0x7F8000007F800000u64);
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
                        1u32;
                    } else {
                        0u32;
                    },
                );
            }
            m;
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
                    0x66u32;
                } else {
                    0u32;
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
            8u32;
        } else {
            16 / eb;
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
            (1u64, 2u64);
        } else if eb == 4 {
            (0x0000000200000001u64, 0x0000000800000004u64);
        } else if eb == 2 {
            (0x0008000400020001u64, 0x0080004000200010u64);
        } else {
            (0x8040201008040201u64, 0x8040201008040201u64);
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
            2u32;
        } else {
            eb.trailing_zeros() as u32;
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
                1u32;
            } else {
                8u32;
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
        if nb == 16 && Gen::in_vreg(t.ty) {
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
            n / 2;
        } else {
            0;
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
            return Gen::in_vreg(self.vt(t.a)) && type_bytes(t.ty, 8) >= 2;
        }
        let lt = lane_type(t.ty);
        return Gen::in_vreg(t.ty) && (lt == T_F32 && t.aux == 0 || lt == T_F64 || type_bytes(lt, 8) == 2);
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
                2 * k | 2 * k + 1 << 2;
            } else {
                k;
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

    fn vunzip(self: &mut Self, i: u32, t: Inst) {
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        let n = lanes(t.ty);
        if type_bytes(t.ty, 8) == 64 && self.in_reg(t.ty) {
            // AVX-512: as AVX2 in each 16-byte block, which leaves the 8-byte quarters of the result's
            // first operand and second operand alternating; `vpermq` 0xD8 pairs them in each 32-byte half,
            // and `vshufi64x2` 0xD8 puts the blocks in the order 0, 2, 1, 3.
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            if eb == 4 {
                self.c.evex_rr(0, 1, 0xC6, false, rd, rx, ry);
                self.c.byte(0x88);
            } else if eb == 8 {
                self.c.evex_rr(0x66, 1, 0x6C, true, rd, rx, ry);
            } else {
                let s = self.tmp(true) - V0;
                let sh: u32 = if eb == 1 {
                    0x71;
                } else {
                    0x72;
                };
                for (r, a) in [(rd, rx), (s, ry)] {
                    self.c.evex_rr(0x66, 1, sh, false, 6, r, a);
                    self.c.byte(eb * 8);
                    self.c.evex_rr(0x66, 1, sh, false, 4, r, r);
                    self.c.byte(eb * 8);
                }
                self.c.evex_rr(
                    0x66,
                    1,
                    if eb == 1 {
                        0x63u32;
                    } else {
                        0x6Bu32;
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
                self.c.byte(0x88);
            } else if eb == 8 {
                self.c.vex_rr(0x66, 1, 0x6C, false, true, rd, rx, ry);
            } else {
                let s = self.tmp(true) - V0;
                let sh: u32 = if eb == 1 {
                    0x71;
                } else {
                    0x72;
                };
                self.c.vex_rr(0x66, 1, sh, false, true, 6, rd, rx);
                self.c.byte(eb * 8);
                self.c.vex_rr(0x66, 1, sh, false, true, 4, rd, rd);
                self.c.byte(eb * 8);
                self.c.vex_rr(0x66, 1, sh, false, true, 6, s, ry);
                self.c.byte(eb * 8);
                self.c.vex_rr(0x66, 1, sh, false, true, 4, s, s);
                self.c.byte(eb * 8);
                self.c.vex_rr(
                    0x66,
                    1,
                    if eb == 1 {
                        0x63u32;
                    } else {
                        0x6Bu32;
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
        if Gen::in_vreg(t.ty) && type_bytes(t.ty, 8) == 16 {
            let rx = self.vec_use(t.a, self.vs0);
            let ry = self.vec_use(t.b, self.vs1);
            let rd = self.vec_def(i);
            if eb >= 4 {
                self.c.vmov(rd - V0, rx - V0);
                if eb == 4 {
                    self.c.sse_rr(0, 0x0FC6, rd - V0, ry - V0);
                    self.c.byte(0x88);
                } else {
                    self.c.sse_rr(0x66, 0x0F6C, rd - V0, ry - V0);
                }
                return;
            }
            // psllw/pslld and psraw/psrad by the lane's bits (66 0F 71/72 /6 and /4 ib), then the pack.
            let s = self.tmp(true);
            let sh: u32 = if eb == 1 {
                0x0F71;
            } else {
                0x0F72;
            };
            self.c.vmov(rd - V0, rx - V0);
            self.c.vmov(s - V0, ry - V0);
            for r in [rd, s] {
                self.c.sse_rr(0x66, sh, 6, r - V0);
                self.c.byte(eb * 8);
                self.c.sse_rr(0x66, sh, 4, r - V0);
                self.c.byte(eb * 8);
            }
            self.c.sse_rr(
                0x66,
                if eb == 1 {
                    0x0F63u32;
                } else {
                    0x0F6Bu32;
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
            if 2 * k < n {
                self.ld_lane(xr, t.a, 2 * k, lt, false, true);
            } else {
                self.ld_lane(xr, t.b, 2 * k - n, lt, false, true);
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
                0;
            } else if c == C_OLT {
                1;
            } else if c == C_OLE {
                2;
            } else if c == C_OGT {
                0x0E;
            } else if c == C_OGE {
                0x0D;
            } else {
                4;
            };
            let d = lt == T_F64;
            self.c.evex_rr(d as u32 * 0x66, 1, 0xC2, d, 1, rx, ry);
            self.c.byte(imm);
        } else {
            // EQ, LT, LE, NE, NLT, NLE.
            let imm: u32 = if c == C_EQ {
                0;
            } else if c == C_NE {
                4;
            } else if c == C_SLT || c == C_ULT {
                1;
            } else if c == C_SLE || c == C_ULE {
                2;
            } else if c == C_SGE || c == C_UGE {
                5;
            } else {
                6;
            };
            let opc = if eb <= 2 {
                0x3Fu32;
            } else {
                0x1Fu32;
            } - (c >= C_ULT) as u32;
            self.c.evex_rr(0x66, 3, opc, eb == 2 || eb == 8, 1, rx, ry);
            self.c.byte(imm);
        }
        let m = if eb <= 2 {
            0x28u32;
        } else {
            0x38u32;
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
            c == C_OGT || c == C_OGE;
        } else {
            c == C_SLT || c == C_SGE || c == C_ULT || c == C_UGE;
        };
        let (xv, yv) = if swap {
            (t.b, t.a);
        } else {
            (t.a, t.b);
        };
        let rx = self.vec_use(xv, self.vs0) - V0;
        let ry = self.vec_use(yv, self.vs1) - V0;
        let rd = self.vec_def(i) - V0;
        if fl {
            let imm: u32 = if c == C_OEQ {
                0;
            } else if c == C_OLT || c == C_OGT {
                1;
            } else if c == C_OLE || c == C_OGE {
                2;
            } else {
                4;
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
                    0x29u32;
                } else {
                    0x37u32;
                }
            );
        } else {
            (
                1u32,
                if eq {
                    0x74u32;
                } else {
                    0x64u32;
                } + eb.trailing_zeros() as u32
            );
        };
        if c >= C_ULT {
            // The sign bits flipped: an unsigned order is the signed one.
            let s = self.tmp(true) - V0;
            let sb = if eb == 1 {
                0x8080808080808080u64;
            } else if eb == 2 {
                0x8000800080008000u64;
            } else if eb == 4 {
                0x8000000080000000u64;
            } else {
                0x8000000000000000u64;
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

    // Lane select `t` into vector `i`: `c ^ ((b ^ c) & mask)` (SSE2); a vector outside an xmm register
    // selects each lane's bits the same way.
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
        if type_bytes(t.ty, 8) == 32 && self.in_reg(t.ty) {
            let rm = self.vec_use(t.a, self.vs0) - V0;
            let rx = self.vec_use(t.b, self.vs1) - V0;
            let s = self.tmp(true);
            let ry = self.vec_use(t.c, s) - V0;
            let rd = self.vec_def(i) - V0;
            self.c.vex_rr(0x66, 1, 0xEF, false, true, rd, rx, ry);
            self.c.vex_rr(0x66, 1, 0xDB, false, true, rd, rd, rm);
            self.c.vex_rr(0x66, 1, 0xEF, false, true, rd, rd, ry);
            return;
        }
        if Gen::in_vreg(t.ty) {
            let rm = self.vec_use(t.a, self.vs0);
            let rx = self.vec_use(t.b, self.vs1);
            let s = self.tmp(true);
            let ry = self.vec_use(t.c, s);
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
            0x8000000000000000u64;
        } else {
            0x8000000080000000u64;
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
            VNONE;
        } else {
            t.b;
        };
        let div = op >= O_SDIV && op <= O_UREM;
        let sh = op == O_SHL || op == O_LSHR || op == O_ASHR;
        if div {
            self.vacate(x::RAX);
            self.vacate(x::RDX);
        }
        if self.shift_reg(t) {
            // AVX2: `vpsllv`, `vpsrlv`, `vpsrav` (VEX.66.0F38 47, 45, 46) shift each lane by its own amount.
            let rx = self.vec_use(t.a, self.vs0) - V0;
            let ry = self.vec_use(t.b, self.vs1) - V0;
            let rd = self.vec_def(i) - V0;
            let opc: u32 = if op == O_SHL {
                0x47;
            } else if op == O_LSHR {
                0x45;
            } else {
                0x46;
            };
            self.c.vex_rr(0x66, 2, opc, type_bytes(lt, 8) == 8, nb == 32, rd, rx, ry);
            return true;
        }
        if sh {
            self.vacate(x::RCX);
        }
        if w != NONE && Gen::in_vreg(t.ty) {
            self.sse_reg(w, op, lt, i, t.a, y);
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
        let sg = op == O_ASHR || op == O_SDIV || op == O_SREM;
        let xr = self.tmp(false);
        let yr = if sh {
            x::RCX;
        } else {
            self.tmp(false);
        };
        for k in 0..n {
            self.ld_lane(xr, t.a, k, lt, sg, false);
            if !un {
                self.ld_lane(yr, t.b, k, lt, sg, false);
            }
            self.int_lane(op, xr, yr);
            self.st_lane(xr, d, k, lt, false);
        }
        return true;
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
                    x::IDIV;
                } else {
                    x::DIV;
                },
                8,
                yr,
            );
            self.c.mov_rr(
                8,
                xr,
                if op == O_SDIV || op == O_UDIV {
                    x::RAX;
                } else {
                    x::RDX;
                },
            );
        } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
            assert(yr == x::RCX, "x64gen: a lane shift count outside rcx");
            self.c.shift_cl(
                if op == O_SHL {
                    x::SHL;
                } else if op == O_LSHR {
                    x::SHR;
                } else {
                    x::SAR;
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
                            0xF3u32;
                        } else {
                            0xF2u32;
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
        if !(Gen::in_vreg(t.ty) && Gen::in_vreg(ft)) && !wide {
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
        if op == O_SEXT || op == O_ZEXT {
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
                0x0F71;
            } else {
                0x0F72;
            };
            self.c.vmov(rd, rx);
            self.c.sse_rr(0x66, sh, 6, rd);
            self.c.byte(tb * 8);
            self.c.sse_rr(0x66, sh, 4, rd);
            self.c.byte(tb * 8);
            self.c.sse_rr(
                0x66,
                if fb == 2 {
                    0x0F63u32;
                } else {
                    0x0F6Bu32;
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
                0x10;
            } else {
                0;
            };
            // bw, wd, dq: 20, 23, 25.
            let w: u32 = if fb == 1 {
                0x20;
            } else if fb == 2 {
                0x23;
            } else {
                0x25;
            };
            self.c.vex_rr(0x66, 2, w + z, false, true, rd, 0, rx);
        } else if op == O_TRUNC {
            if fb == 8 {
                self.c.vex_rr(0x66, 1, 0x70, false, true, rd, 0, rx);
                self.c.byte(0x08);
            } else {
                let sh: u32 = if fb == 2 {
                    0x71;
                } else {
                    0x72;
                };
                self.c.vex_rr(0x66, 1, sh, false, true, 6, rd, rx);
                self.c.byte(tb * 8);
                self.c.vex_rr(0x66, 1, sh, false, true, 4, rd, rd);
                self.c.byte(tb * 8);
                self.c.vex_rr(
                    0x66,
                    1,
                    if fb == 2 {
                        0x63u32;
                    } else {
                        0x6Bu32;
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
        // `vlanes` and `vmem` sync their operands past their register forms; every other form here first.
        let simd = code >= core::OP_SIMD && code < core::OP_CMP_LANES;
        let rule = if simd {
            core::simd_op((code - core::OP_SIMD) as u8).rule;
        } else {
            0u8;
        };
        if !simd || rule == core::SR_MLOAD || rule == core::SR_MSTORE || rule == core::SR_REDUCE || rule == core::SR_DOT || rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED {
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
                x::SHL;
            } else if sg {
                x::SAR;
            } else {
                x::SHR;
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
            format("{}f", name);
        } else {
            String::from_str(name);
        };
        for k in 0..n {
            self.ld_lane(V0, xv, k, lt, false, false);
            self.ld_lane(V0 + 1, yv, k, lt, false, false);
            if zv != VNONE {
                self.ld_lane(V0 + 2, zv, k, lt, false, false);
            }
            self.call_sym(fname.as_str());
            self.st_lane(V0, d, k, lt, false);
        }
    }

    // The lane rules (`SR_VEC`, `SR_MASK`, `SR_CHOOSE`, `SR_LANES`, `SR_CHANGED`, `SR_BITCAST`, `SR_HALF`,
    // `SR_CONCAT`, `SR_ANY`) of `SIMD_*` code `c`, as the evaluator's `vlanes`.
    fn vlanes(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, dsg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let rule = core::simd_op(c).rule;
        let vt = if rule == core::SR_CHOOSE {
            tys[1];
        } else if rule == core::SR_ANY {
            t.ty;
        } else {
            tys[0];
        };
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let lb = eb * 8;
        let n = lanes(vt);
        let nb = n * eb;
        let fl = is_float(lt);
        // A mask (`Mask<N>`, one bit per lane) of vectors in xmm registers, and a choice by one: lane masks.
        let lane_test = c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE && (fl || eb < 8) || fl && (c == core::SIMD_IS_NAN || c == core::SIMD_IS_INF || c == core::SIMD_IS_FINITE || c == core::SIMD_IS_SIGN_NEG);
        if n >= 2 && Gen::in_vreg(vt) && (rule == core::SR_MASK && lane_test || rule == core::SR_CHOOSE) {
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
        let mask = rule == core::SR_MASK || rule == core::SR_CHANGED;
        let mut un = false;
        let w = if mask || rule != core::SR_VEC || nb < 8 {
            NONE;
        } else {
            sse_of_simd(c, lt, sg, &mut un);
        };
        let o = if un && c == core::SIMD_WRAP_NEG {
            O_NEG;
        } else if un {
            O_FADD;
        } else {
            O_ADD;
        };
        let y = if un {
            VNONE;
        } else {
            ops[1];
        };
        if w != NONE && Gen::in_vreg(t.ty) {
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
            lt;
        } else {
            lane_type(t.ty);
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
            self.reg(ops[1]);
        } else {
            NOREG;
        };
        let cm = if rule == core::SR_CHOOSE {
            self.reg(ops[0]);
        } else {
            NOREG;
        };
        let xr = self.tmp(false);
        let yr = if shifts {
            x::RCX;
        } else {
            self.tmp(false);
        };
        let traps = !fl && sg && c == core::SIMD_ABS || c == core::SIMD_NARROW_CHECKED;
        // The bit rules read a lane's own bits: zero-extended whatever its sign.
        let xsg = sg && c != core::SIMD_CLZ && c != core::SIMD_POPCNT && c != core::SIMD_ROTL && c != core::SIMD_ROTR;
        let fr = if traps {
            self.tmp(false);
        } else {
            NOREG;
        };
        if traps {
            self.c.alu_rr(x::XOR, 4, fr, fr);
        }
        let mut fails = Vector::<u64>::new();
        let (fa, fb, fc) = if fl || c == core::SIMD_CAST_CHANGED {
            (self.tmp(true), self.tmp(true), self.tmp(true));
        } else {
            (NOREG, NOREG, NOREG);
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
                        x::ADD;
                    } else {
                        x::SUB;
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
                O_ADD;
            } else if c == core::SIMD_WRAP_SUB {
                O_SUB;
            } else {
                O_MUL;
            };
            self.int_lane(op, xr, yr);
        } else if c == core::SIMD_WRAP_NEG {
            self.c.unary(x::NEG, 8, xr);
        } else if c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR {
            self.c.alu_ri(x::AND, 4, x::RCX, (lb - 1) as i32);
            self.c.shift_cl(
                if c == core::SIMD_WRAP_SHL {
                    x::SHL;
                } else if sg {
                    x::SAR;
                } else {
                    x::SHR;
                },
                8,
                xr,
            );
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit in r10, before the operation: a signed overflow goes the way of the operand's sign
            // (MAX ^ (y >> 63) for a sum, its complement for a difference), an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1;
            } else {
                trunc64(~0u64, lb);
            };
            if sg {
                self.c.mov_rr(8, S0, yr);
                self.c.shift_ri(x::SAR, 8, S0, 63);
                self.c.mov_ri(
                    S1,
                    if add {
                        max;
                    } else {
                        ~max;
                    },
                );
                self.c.alu_rr(x::XOR, 8, S0, S1);
            } else {
                self.mov_imm(
                    S0,
                    if add {
                        max;
                    } else {
                        0;
                    },
                    8,
                );
            }
            let cc = self.ovf_lane(c, lb, sg, xr, yr);
            self.c.cmov(cc, 8, xr, S0);
        } else if c == core::SIMD_MIN || c == core::SIMD_MAX {
            self.c.alu_rr(x::CMP, 8, xr, yr);
            let lt_c = if sg {
                x::CC_L;
            } else {
                x::CC_B;
            };
            self.c.cmov(
                if c == core::SIMD_MIN {
                    x::invert(lt_c);
                } else {
                    lt_c;
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
                    x::CC_G;
                } else {
                    x::CC_A;
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
                        x::ROL;
                    } else {
                        x::ROR;
                    },
                    8,
                    xr,
                );
            } else {
                // (u << k | u >> (lb - k) % lb), or the reverse: the store keeps the lane's bits.
                let (s0, s1) = if c == core::SIMD_ROTL {
                    (x::SHL, x::SHR);
                } else {
                    (x::SHR, x::SHL);
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
            (1u64 << (rw - 1) as u64) - 1;
        } else {
            trunc64(~0u64, rw);
        };
        let rmin = if rsg {
            (1u64 << (rw - 1) as u64).wrapping_neg();
        } else {
            0u64;
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
                x::CC_G;
            } else {
                x::CC_A;
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
            0x66u32;
        } else {
            0u32;
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
                (fb, fa);
            } else {
                (fa, fb);
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
                        x::CC_A;
                    } else {
                        x::CC_AE;
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
                0x0010000000000000u64;
            } else {
                0x00800000u64;
            };
            let maxf = if dd {
                0x7FEFFFFFFFFFFFFFu64;
            } else {
                0x7F7FFFFFu64;
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
            0x4330000000000000u64;
        } else {
            0x4B000000u64;
        };
        let one = if dd {
            0x3FF0000000000000u64;
        } else {
            0x3F800000u64;
        };
        let ucom = if dd {
            0x66u32;
        } else {
            0u32;
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
                    0x7FFFFFFFFFFFFFFFu64;
                } else {
                    0x7FFFFFFFu64;
                },
            );
            self.c.movd_to_x(
                if dd {
                    8u32;
                } else {
                    4u32;
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
            0x8000000000000000u64;
        } else {
            0x80000000u64;
        };
        self.c.mov_ri(S1, sb);
        self.c.movd_to_x(
            if dd {
                8u32;
            } else {
                4u32;
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
                    0x0F5Cu32;
                } else {
                    0x0F58u32;
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
            0x66u32;
        } else {
            0u32;
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
                    x::CC_NE;
                } else {
                    x::CC_E;
                },
            ),
        );
        to_b.push(self.c.jmp32());
        self.c.land(differ, self.c.len());
        to_a.push(
            self.c.jcc32(
                if lo {
                    x::CC_B;
                } else {
                    x::CC_A;
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
                    0x0008000000000000u64;
                } else {
                    0x00400000u64;
                };
                self.c.mov_ri(S1, qb);
                self.c.movd_to_x(
                    if dd {
                        8u32;
                    } else {
                        4u32;
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
            rt;
        } else {
            bt;
        };
        let isg = if ff {
            rs;
        } else {
            bs;
        };
        let iw = type_bits(ib, 8) - isg as u32;
        let hi = 1023u64 + iw as u64 << 52;
        let lo = if isg {
            hi | 1u64 << 63;
        } else {
            0u64;
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
            t.ty;
        } else if raw {
            tys[1];
        } else {
            tys[2];
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
            ops[1];
        } else {
            ops[2];
        };
        if load && Gen::in_vreg(vt) {
            let rd = self.vec_def(i);
            self.ld(vt, rd, x::at(p, 0));
        } else if load {
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, p, 0, nb);
        } else if Gen::in_vreg(vt) {
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
            self.reg(ops[1]);
        } else {
            NOREG;
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
                x::at(ix, 0);
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
                x::ix(p, ix, s, 0);
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
        let xr = self.tmp(false);
        let yr = self.tmp(false);
        let acc = self.tmp(false);
        if dot {
            self.c.alu_rr(x::XOR, 4, acc, acc);
        } else {
            self.ld_lane(acc, ops[0], 0, lt, sg, false);
        }
        let from: u32 = if dot {
            0;
        } else {
            1;
        };
        let lt_c = if sg {
            x::CC_L;
        } else {
            x::CC_B;
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
                        x::AND;
                    } else if c == core::SIMD_REDUCE_OR {
                        x::OR;
                    } else {
                        x::XOR;
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
                        lt_c;
                    } else {
                        x::invert(lt_c);
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
            O_FADD;
        } else {
            O_FMUL;
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
            0x8000000000000000u64;
        } else {
            0x80000000u64;
        };
        if fold {
            self.fconst(
                acc,
                dd,
                if add {
                    neg0;
                } else {
                    float_bits(at, 1);
                },
            );
        } else {
            self.ld_lane(acc, ops[0], 0, lt, false, false);
        }
        let from: u32 = if fold {
            0;
        } else {
            1;
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
            1u64 << (lb - 1) as u64;
        } else {
            trunc64(~0u64, lb);
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
                x::CC_L;
            } else if min {
                x::CC_B;
            } else if sg {
                x::CC_G;
            } else {
                x::CC_A;
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
            0x66u32;
        } else {
            0u32;
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
                            x::CC_AE;
                        } else {
                            x::CC_B;
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
            tys[1];
        } else {
            tys[0];
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
            self.b().pool[t.c as usize];
        } else {
            lanes(tys[1]);
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
            let s = self.obj().sym(rels[k].name.as_str());
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
                self.msg_text(asm_out_con(b, r, k));
            } else {
                self.msg_text(asm_in_con(b, r, k - no));
            };
            let v = b.pool[(t.a + k) as usize];
            let ty = if k < no {
                asm_out_ty(b, r, k);
            } else {
                self.vt(v);
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
                fp_pool;
            } else {
                gp_pool;
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
                        self.vs0;
                    } else {
                        S0;
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
        if !self.asm_text(text.as_str()) {
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
            VSAVE_WIN;
        } else {
            0u64;
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
            if !self.asm_text(tpl.as_str()) {
                return false;
            }
        }
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true);
        } else if ps.cold {
            o.named(self.cold_text(), true);
        } else {
            ob::S_TEXT;
        };
        if sec == ob::NOSEC {
            return self.refuse("too many sections");
        }
        let mut fl = ob::SF_FUNC | if ps.linkage == SL_GLOBAL && !self.local {
            ob::SF_GLOBAL;
        } else {
            0;
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
    };
}

// The register a clobber names (`rax`, `eax`, `ax`, `al`, `r12`, `r12d`, `xmm6`), NOREG for none
// (`memory`, `cc`, `dirflag`, `fpsr`, `flags`).
fn x64_clobber(s0: str) u8 {
    let s = if s0.starts_with("%") {
        s0.slice(1, s0.len());
    } else {
        s0;
    };
    if s.starts_with("xmm") || s.starts_with("ymm") || s.starts_with("zmm") {
        return switch s.slice(3, s.len()).parse_u32() {
            Some(n) => if n < 16 {
                V0 + n as u8;
            } else {
                NOREG;
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
