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

const fn bit(r: u8) u64 {
    return 1u64 << r as u64;
}

// The Microsoft x64 UNWIND_INFO of a prologue of `pl` bytes into `out`: `push rbp` (1 byte; the `mov rbp,
// rsp` after it changes nothing the unwinder restores), the pushes of `regs` ending at `push_at`, the
// allocation of `local` bytes ending at `alloc_end`, and the saves of xmm `xregs` at rsp + `xsave` +
// 16 j ending at `xsave_at`; with frame register `fp` (NOREG: none), its copy of rsp ending at `fp_at`,
// after which the prologue aligns rsp. The codes run backwards through the prologue.
fn win_unwind(
    out: &mut Vector<u8>,
    pl: u32,
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
    codes.push(1);
    codes.push(5 << 4);
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
    xalloc: u64,
    xfix: u64,
    valloc: u64,
    xscr: u64,
    xscr_cap: u32, // the values `xscr` may hold at a time
    vscr: u64,
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
    rr: u32, // the eviction cursor
    pos: u32, // the layout position of the block being compiled
    cur: u32, // the instruction being compiled
    dying: Vector<u32>, // values whose register frees after the current instruction
    wparams: Vector<u32>, // the parameters the current terminator's edges write
    want: Vector<u8>, // per value, its request to `Live::plan`
    ends: Vector<u32>, // values by the position their range ends at (CSR, `ends_at`)
    ends_at: Vector<u32>,
    cpre: Vector<u32>, // per instruction index, the calls that return before it (`call_tables`)
    cpos: Vector<u32>, // per layout position, the blocks before it that hold one
    vpre: Vector<u32>, // `cpre` and `cpos` without the intrinsics, which write no vector scratch home
    vpos: Vector<u32>,
    cond: Cond, // the flags the instruction just compiled left for the next one
    pend: Cond, // the flags the instruction being compiled may read
    keep_flags: bool, // the flags hold a condition the current instruction reads later: no xor zeroing
    // Frame.
    out_size: u32,
    slot_off: Vector<u32>,
    spill_base: u32,
    spill_top: u32,
    free_slots: Vector<u64>, // size << 32 | offset of a released spill slot
    max_align: u32,
    sret_off: i64, // the slot of rdi for a result in memory, -1 when none
    save_off: i64, // a variadic body's register save area, -1 when none
    // Labels.
    blk_at: Vector<u32>, // per block, its first byte, NONE before it is compiled
    fix: Vector<u64>, // displacement field << 32 | block: a branch to patch
    epi: Vector<u32>, // jumps to the epilogue (their displacement fields)
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
            rr: 0,
            pos: 0,
            cur: 0,
            dying: Vector::<u32>::new(),
            wparams: Vector::<u32>::new(),
            want: Vector::<u8>::new(),
            ends: Vector::<u32>::new(),
            ends_at: Vector::<u32>::new(),
            cpre: Vector::<u32>::new(),
            cpos: Vector::<u32>::new(),
            vpre: Vector::<u32>::new(),
            vpos: Vector::<u32>::new(),
            cond: Cond { inst: NONE, cc: 0 },
            pend: Cond { inst: NONE, cc: 0 },
            keep_flags: false,
            out_size: 0,
            slot_off: Vector::<u32>::new(),
            spill_base: 0,
            spill_top: 0,
            free_slots: Vector::<u64>::new(),
            max_align: 16,
            sret_off: -1,
            save_off: -1,
            blk_at: Vector::<u32>::new(),
            fix: Vector::<u64>::new(),
            epi: Vector::<u32>::new(),
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
            let off = self.slot_alloc(n, n);
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

    // A register for the result of value `v`: its fixed register when it has one, else a free one.
    fn def(self: &mut Self, v: Value) u8 {
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.home == H_FIXED {
            self.lock |= bit(va.reg);
            self.va.index_mut(x as usize).clean = false;
            return va.reg;
        }
        let vr = Gen::is_v(self.vt(v));
        let r = self.take_home(x, vr, NOREG);
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let r2 = self.alloc(vr);
        self.bind(x, r2);
        return r2;
    }

    // A register for the result of value `v` that holds operand `a`'s bits (in `ra`) for a two-operand
    // instruction: `ra` itself when `a` dies here and `v` takes no fixed home, else a copy of it.
    fn def_from(self: &mut Self, v: Value, a: Value, ra: u8) u8 {
        let x = self.vx(v);
        let xa = self.vx(a);
        let t = self.vt(v);
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
    // parameter and no call that returns runs in the range of, a caller-saved one (System V keeps no xmm
    // register across a call); none for the others, which temporaries hold. The homes leave 8 integer
    // registers to one instruction (a masked store reads 8).
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
        self.want.truncate(0);
        for x in 0..n {
            let t = self.xty(x as u32);
            let d = self.lv.def_blk[x];
            let mut w: u8 = 0;
            if !Gen::in_mem(t) && d != NONE && self.lv.pos[d as usize] != NONE && !(x < ni && self.remat_inst(x as u32)) {
                let past = self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && x < nv;
                let cross = x < nv && self.crosses_call(x as u32, Gen::is_v(t));
                if Gen::is_v(t) {
                    if x < nv && past && !cross {
                        w = lv::WANT_SCRATCH | lv::WANT_V;
                    }
                } else if cross || x >= nv && self.lv.end[x] > self.lv.pos[d as usize] {
                    w = lv::WANT_CALLEE;
                } else if past && x < nv && late[x] {
                    w = lv::WANT_CALLEE;
                } else if past && x < nv {
                    w = lv::WANT_CALLEE | lv::WANT_SCRATCH;
                }
            }
            self.want.push(w);
        }
        let most = self.xfix.count_ones() + self.xalloc.count_ones() - 8;
        self.lv.plan(
            b,
            &self.want,
            lv::Caps { xc: self.xfix.count_ones() as u32, xs: self.xscr_cap, xj: most as u32, vc: 0, vs: 4, vj: 4 },
        );
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

    // `cpre` and `cpos`: the calls that return (`clobbers`, not followed by `unreachable`)
    // before each instruction index, and the blocks holding one before each layout position; `vpre` and
    // `vpos` the same without the intrinsics, whose templates write xmm0 to xmm3 and their arguments'
    // registers, no vector scratch home.
    fn call_tables(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill32(&mut self.cpre, ni + 1, 0);
        fill32(&mut self.vpre, ni + 1, 0);
        for i in 0..ni {
            let t = b.insts[i];
            if Gen::clobbers(b, t) && b.insts[i + 1].op != O_UNREACHABLE {
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
        if op == O_CALL || op == O_CALLIND || op == O_ASM || op == O_VOP || op == O_MEMCPY || op == O_MEMSET {
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

    // Give value index `x` a free callee-saved register as its home, the value there (from `alloc`'s
    // fallback) evicted; NOREG when none is free.
    fn take_fixed(self: &mut Self, x: u32, vr: bool) u8 {
        if vr {
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
            self.ld(t, r, x::at(x::RBP, va.off));
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
                        x::RBP;
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
                        x::RBP;
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
        if dst >= V0 {
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
        let reg_form = t.op == O_STORE || t.op == O_VOP || t.op == O_CALL || t.op == O_CALLIND || is_vec(t.ty) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG);
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
        if va.home == H_SLOT {
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

    // A call of C function `name`.
    fn call_sym(self: &mut Self, name: str) {
        let at = self.c.call32();
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
        self.lv.run(b);
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
        self.fix.truncate(0);
        self.epi.truncate(0);
        self.rels.truncate(0);
        self.free_slots.truncate(0);
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
        self.bucket_ends();
        self.call_tables();
        self.plan_homes();
        self.entry();
        if self.err.len() != 0 {
            return false;
        }
        for q in 0..self.lv.order.len() {
            if !self.block(q as u32) {
                return false;
            }
        }
        return self.finish(s);
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
            let sl = b.slots[k];
            let al = 1u32 << sl.align_log2 as u32;
            if al > self.max_align {
                self.max_align = al;
            }
            at = at + al - 1 & ~(al - 1);
            self.slot_off[k] = at;
            at += sl.size;
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
        classify(self.win, b, b.sig, self.ptr, self.vregs, &mut self.self_lay);
        if self.self_lay.unknown {
            let _ = self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        let np = b.pool[b.sig as usize];
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        if (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 && self.win {
            // The four argument registers into their home area, which the stack arguments continue.
            for k in 0..4u32 {
                self.c.store(8, w64::gp_arg(k), x::at(x::RBP, 16 + 8 * k as i32));
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
        // No parameter's home takes a register another one arrives in.
        self.lock |= if self.win {
            ARGS_WIN;
        } else {
            ARGS_SYSV;
        };
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
                    self.c.load(8, false, S1, x::at(x::RBP, 16 + loc.off as i32));
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
        let dbg = unsafe (*self.pkg).debug;
        for i in bk.start..bk.start + bk.len {
            if dbg {
                self.row(b.locs[i as usize]);
            }
            self.begin_inst(i);
            if !self.inst(i) {
                return false;
            }
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
            let tb = b.blocks[b.edge_target(lv::edge_of(b, t, e)) as usize];
            for q in 0..tb.param_len as u32 {
                self.param_home(ni + tb.param_start + q);
            }
        }
    }

    // The home of block parameter value index `x`, chosen at the first edge into its block.
    fn param_home(self: &mut Self, x: u32) {
        if self.va[x as usize].home != H_NONE {
            return;
        }
        let t = self.xty(x);
        if self.take_home(x, Gen::is_v(t), NOREG) != NOREG {
            // The register holds nothing until the edge moves write it.
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
        let va = self.va[x as usize];
        if va.reg != NOREG {
            return Lc { kind: LC_REG, reg: va.reg, off: 0, val: x };
        }
        if va.home == H_SLOT {
            return Lc { kind: LC_MEM, reg: x::RSP, off: va.off, val: x };
        }
        if va.home == H_ARG {
            return Lc { kind: LC_MEM, reg: x::RBP, off: va.off, val: x };
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
            self.param_home(px);
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
            self.mv.push(
                Mv {
                    src: self.loc_of(ax),
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
        if op == O_WCONST {
            let off = self.mdef(i) as i32;
            for k in 0..t.b {
                self.c.mov_ri(S0, self.b().words[(t.a + k) as usize]);
                self.c.store(8, S0, x::at(x::RSP, off + 8 * k as i32));
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
        if op >= O_FADD && op <= O_FNEG {
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
            self.c.load(8, false, rd, x::at(x::RBP, 8));
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
        if Gen::in_vreg(self.vt(v)) {
            self.spill(self.vx(v));
        }
    }

    // Where memory value `v` is: a base register and offset; a vector whose register holds what its home
    // lacks is stored there first.
    fn mloc(self: &mut Self, v: Value) (u8, i64) {
        self.spill(self.vx(v));
        let va = self.va[self.vx(v) as usize];
        if va.home == H_ARG {
            return x::RBP, va.off;
        }
        assert(va.home == H_SLOT, "x64gen: a memory value without a slot");
        return x::RSP, va.off;
    }

    // The address `v` + `off` as a base register and an offset: a slot or frame address folds in.
    fn addr(self: &mut Self, v: Value, off: i64) (u8, i64) {
        let xv = self.vx(v);
        let va = self.va[xv as usize];
        if va.home == H_SPADDR {
            return x::RSP, va.off as i64 + off;
        }
        if va.home == H_FPADDR {
            return x::RBP, va.off as i64 + off;
        }
        if va.home == H_REMAT && va.reg == NOREG {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return x::RSP, self.slot_off[it.a as usize] as i64 + off;
            }
        }
        return self.reg(v), off;
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
        let ty = self.vt(t.a);
        assert(!is_vec(ty), "x64gen: a vector comparison the verifier rejects");
        if ty == T_I128 {
            return self.icmp128(i, t);
        }
        let bits = type_bits(ty, self.ptr);
        let sz = bits / 8;
        let ra = self.reg(t.a);
        let mut k: i32 = 0;
        if self.imm32_of(t.b, bits, &mut k) {
            if k == 0 {
                self.c.test_rr(sz, ra, ra);
            } else {
                self.c.alu_ri(x::CMP, sz, ra, k);
            }
        } else {
            let rb = self.reg(t.b);
            self.c.alu_rr(x::CMP, sz, ra, rb);
        }
        self.cond_value(i, icond(t.aux), NONE, false);
        return true;
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
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def_from(i, t.a, ra);
            self.c.alu_rr(aop, sz, rd, rb);
            return true;
        }
        if op == O_MUL {
            let ra = self.reg(t.a);
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
        // Division and remainder: rdx:rax by a register.
        let sgn = op == O_SDIV || op == O_SREM;
        self.vacate(x::RAX);
        self.vacate(x::RDX);
        let ra = if small {
            self.ext(t.a, sgn, bits);
        } else {
            self.reg(t.a);
        };
        let rb = if small {
            self.ext(t.b, sgn, bits);
        } else {
            self.reg(t.b);
        };
        self.c.mov_rr(sz, x::RAX, ra);
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
            let ra = self.ext(t.a, signed, bits);
            let rb = self.ext(t.b, signed, bits);
            let rd = self.def(i);
            self.c.mov_rr(4, rd, ra);
            if op == O_ADDO {
                self.c.alu_rr(x::ADD, 4, rd, rb);
            } else if op == O_SUBO {
                self.c.alu_rr(x::SUB, 4, rd, rb);
            } else {
                self.c.imul_rr(4, rd, rb);
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
                let rd = self.def(i);
                self.sym_addr(rd, it.a, (it.b as i32) as i64 + off);
                return true;
            }
        }
        let (base, boff) = self.addr(t.a, 0);
        if t.b == VNONE {
            let rd = self.def(i);
            self.add_off(rd, base, boff + off);
            return true;
        }
        let ity = self.vt(t.b);
        let ib = type_bits(ity, self.ptr);
        let ri = self.reg(t.b);
        let scale = t.aux as u32;
        let rd = self.def(i);
        // The index sign-extended to 64 bits, scaled.
        let mut idx = ri;
        if ib < 64 {
            self.c.ext(ib / 8, 8, true, S0, ri);
            idx = S0;
        }
        let mut sc: u8 = 0;
        if scale == 1 || scale == 2 || scale == 4 || scale == 8 {
            sc = scale.trailing_zeros() as u8;
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
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        if Gen::in_mem(ty) && !Gen::in_vreg(ty) {
            let (base, off) = self.addr(t.a, t.c as i32);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, base, off, type_bytes(ty, self.ptr));
            return true;
        }
        let m = self.mem_at(t.a, t.c as i32, &mut rs, &mut radd);
        let rd = if Gen::in_vreg(ty) {
            self.vec_def(i);
        } else {
            self.def(i);
        };
        self.ld(ty, rd, m);
        self.mem_rel(rs, radd);
        self.va.index_mut(i as usize).clean = !Gen::is_v(ty) && type_bits(ty, self.ptr) < 64;
        return true;
    }

    fn store(self: &mut Self, t: Inst) bool {
        let ty = self.vt(t.b);
        let mut rs: u32 = NONE;
        let mut radd: i64 = 0;
        if Gen::in_vreg(ty) {
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
        if Gen::in_mem(ty) {
            // The chosen value's address, then a copy.
            let (b1, o1) = self.mloc(t.b);
            let (b2, o2) = self.mloc(t.c);
            let ra = self.tmp(false);
            let rb = self.tmp(false);
            self.c.lea(ra, x::at(b1, o1 as i32));
            self.c.lea(rb, x::at(b2, o2 as i32));
            let cc = self.cond_of(cx, t.a);
            self.c.cmov(cc, 8, rb, ra);
            let d = self.mdef(i);
            self.copy_mem(x::RSP, d, rb, 0, type_bytes(ty, self.ptr));
            return true;
        }
        if Gen::is_v(ty) {
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let cc = self.cond_of(cx, t.a);
            let rd = self.def(i);
            self.c.vmov(rd - V0, rb - V0);
            let skip = self.c.jcc32(cc);
            self.c.vmov(rd - V0, rc - V0);
            self.c.land(skip, self.c.len());
            return true;
        }
        let rb = self.reg(t.b);
        let rc = self.reg(t.c);
        let cc = self.cond_of(cx, t.a);
        let rd = self.def(i);
        self.c.mov_rr(8, rd, rc);
        self.c.cmov(cc, 8, rd, rb);
        return true;
    }

    // `va_start`: the `va_list` at `t.a` takes the offsets of the first variadic register in the save area
    // (integer, then vector), the first stack one's address and the save area's address.
    fn va_start(self: &mut Self, t: Inst) {
        let ra = self.reg(t.a);
        if self.win {
            // The address of the first variadic argument's position.
            self.c.lea(S0, x::at(x::RBP, 16 + self.self_lay.named_bytes as i32));
            self.c.store(8, S0, x::at(ra, 0));
            return;
        }
        let gp = 8 * self.self_lay.named_gp as i32;
        let fp = 48 + 16 * self.self_lay.named_vr as i32;
        let ov = 16 + (self.self_lay.named_bytes + 7 & ~7u32) as i32;
        self.c.store_i(4, gp, x::at(ra, 0));
        self.c.store_i(4, fp, x::at(ra, 4));
        self.c.lea(S0, x::at(x::RBP, ov));
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
        self.spill_around_call(&keep);
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
        // The scalars from registers and homes as one parallel move; a narrow one then extends in place.
        self.mv.truncate(0);
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let vty = self.vt(v);
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
                )) && self.loc_of(x).kind != LC_VAL || ren[k as usize],
            );
            clean.push(va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG));
        }
        self.resolve_moves();
        // The moved values' registers now hold arguments.
        self.forget_caller_saved();
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
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
                self.materialize(v, S1);
                for q in 0..loc.n as u32 {
                    let pa = self.lay.parts[(loc.p0 + q) as usize];
                    self.load_part(pa, S1, pa.off);
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
        } else if t.op == O_CALL {
            let os = self.osym_of(t.a);
            let at = self.c.call32();
            self.rels.push(CRel { at: at, kind: x::R_PLT32, sym: os, addend: -4 });
        } else {
            self.c.call_r(S1);
        }
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
                base = ast_pick(va.home == H_SPADDR, x::RSP, x::RBP);
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
        self.spill_for_call();
        let mut rs = Vector::<u8>::with_capacity(vs.len());
        for k in 0..vs.len() {
            rs.push(self.arg(k as u32));
        }
        self.args_to(vs, rs[0..rs.len()]);
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

    // Jump to block `k` (nothing when it follows, unless `force`).
    fn goto(self: &mut Self, k: u32, force: bool) {
        let q = self.pos as usize + 1;
        if !force && q < self.lv.order.len() && self.lv.order[q] == k {
            return;
        }
        let at = self.c.jmp32();
        self.fix.push(at as u64 << 32 | k as u64);
    }

    // A two-way branch: condition `cc` takes edge `et`, else `ef`; each edge's moves on its own path.
    fn branch2(self: &mut Self, cc: u32, et: u32, ef: u32) {
        let b = self.b();
        let mt = b.edge_nargs(et) != 0;
        let mf = b.edge_nargs(ef) != 0;
        let tt = b.edge_target(et);
        let tf = b.edge_target(ef);
        let q = self.pos as usize + 1;
        let next = if q < self.lv.order.len() {
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
            self.cbranch(x::invert(cc), tf);
            self.edge_moves(et);
            self.goto(tt, false);
        } else if !mt && mf {
            self.cbranch(cc, tt);
            self.edge_moves(ef);
            self.goto(tf, false);
        } else {
            let at = self.c.jcc32(cc);
            self.edge_moves(ef);
            self.goto(tf, true);
            self.c.land(at, self.c.len());
            self.edge_moves(et);
            self.goto(tt, false);
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
            for k in 0..n {
                let c = b.words[(t.b + k) as usize];
                let sv = lp_sext(c, bits);
                if sv >= -2147483648 && sv <= 2147483647 {
                    self.c.alu_ri(x::CMP, sz, r, sv as i32);
                } else {
                    self.c.mov_ri(S1, c);
                    self.c.alu_rr(x::CMP, sz, r, S1);
                }
                let e = b.switch_edge(t, k);
                if b.edge_nargs(e) == 0 {
                    self.cbranch(x::CC_E, b.edge_target(e));
                } else {
                    stubs.push(self.c.jcc32(x::CC_E) as u64 << 32 | e as u64);
                }
            }
            let d = b.switch_edge(t, n);
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
            self.ret(t);
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
            if (rt & AGG) != 0 {
                let pv = VPARAM | b.blocks[0].param_start + np;
                self.materialize(pv, S1);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, S1, pa.off);
                }
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

    // Frame the body's code and define function symbol `s` with it, with its unwind rules.
    fn finish(self: &mut Self, s: u32) bool {
        // A last jump to the epilogue falls through instead.
        let nc = self.c.len();
        if self.epi.len() != 0 && self.epi[self.epi.len() - 1] == nc - 4 {
            let _ = self.epi.pop();
            let _ = self.c.jumps.pop();
            self.c.b.truncate(nc as usize - 5);
        }
        if self.err.len() != 0 {
            return false;
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
        // rsp is 16-aligned after `push rbp`; the pushes and the locals keep it so. The vector registers'
        // save area tops the locals, 16-aligned.
        let mut local = self.spill_base + self.spill_top + 15 & ~15u32;
        let xsave = local;
        local += 16 * xregs.len() as u32;
        if npush % 2 != 0 {
            local += 8;
        }
        let mut pro = x::Code::new();
        pro.push(x::RBP);
        pro.mov_rr(8, x::RBP, x::RSP);
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
        let body_n = self.c.len();
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
            self.c.pop(x::RBP);
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
        self.c.ret();
        // Branches.
        for q in 0..self.fix.len() {
            let at = (self.fix[q] >> 32) as u32;
            let blk = self.fix[q] as u32;
            self.c.land(at, self.blk_at[blk as usize]);
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
        // Into the object.
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let size = pl + self.c.len();
        let sec = if ps.sect != NONE {
            o.named(p.spell(ps.sect), true);
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
        o.put(sec, pro.b[0..pro.b.len()]);
        o.put(sec, self.c.b[0..self.c.b.len()]);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + pl + r.at, r.sym, r.addend);
        }
        if p.debug {
            dw::rows(o, self.b(), k2, size, pl, &self.rows, body_end, 1);
        }
        let c0 = o.cfi.len() as u32;
        if self.win {
            win_unwind(&mut o.cfi, pl, &push_at, &regs, alloc_end, local, &xsave_at, &xregs, xsave, fp, fp_at);
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
    *un = op == O_NOT || op == O_NEG || op == O_FNEG;
    if op == O_FADD {
        return pd | 0x0F58;
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
        let rd = self.vec_def(i);
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

    // An xmm register for vector result `i`, which holds it (its home, a slot, comes when it spills).
    fn vec_def(self: &mut Self, i: u32) u8 {
        let r = self.alloc(true);
        self.bind(self.vx(i), r);
        return r;
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

    // Vector arithmetic: O_ADD .. O_NOT and O_FADD .. O_FNEG on vectors.
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
        if sh {
            self.vacate(x::RCX);
        }
        if w != NONE && Gen::in_vreg(t.ty) {
            self.sse_reg(w, op, lt, i, t.a, y);
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
