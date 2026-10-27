// The arm64 code generator: LIR bodies to machine code in one pass per body (after TPDE, Schwarz, Kamm
// and Engelke 2025), into an object (`codegen::obj`).
//
// Values: an integer up to 64 bits or a pointer lives in an x register, a float in a v register; an i128
// or a vector lives in its stack slot. A register's upper bits beyond an i8, i16 or i32 value are
// undefined: an operation that reads them extends first. Registers are allocated greedily as the
// instructions encode; a value dies at its last use in the block that ends its live range, a value live
// past its block is in its home (a stack slot, or a callee-saved register held for its whole range
// when it is defined in a loop) before the block's branch, and a block whose only predecessor falls
// through to it keeps the register state. Constants and symbol and slot addresses rematerialize at each
// use.
//
// Registers: x0..x15 and v0..v7, v16..v29 are allocated; x19..x28 and v8..v15 hold loop values; x16
// (data) and x17 (addresses), v30 and v31 are scratch; x18 is reserved; x29 is the frame pointer, x30 the
// link register. Frame (from sp up): the outgoing stack arguments, the LIR slots, the spills and memory
// values, the callee-saved registers, then x29 and x30, which x29 points at.
import lir::ir as *;
import codegen::live as lv;
import codegen::obj as ob;
import codegen::dwarf as dw;
import target::a64 as a;
import target::aapcs64 as cc;
import codegen::abi as ab;
import ir::core as core;
import std::float as fl;
import target::assembler as asmr;
import target::intrin as intrin;

const NOREG: u8 = 0xFF;
const V0: u8 = 32; // register number of v0: x registers are 0..31

// Homes.
const H_NONE: u8 = 0; // only a register
const H_SLOT: u8 = 1; // a stack slot at sp + off
const H_ARG: u8 = 2; // an incoming stack argument at x29 + off (read-only)
const H_FIXED: u8 = 3; // `reg` for its whole range
const H_REMAT: u8 = 4; // a constant or an address, recomputed at each use
const H_SPADDR: u8 = 5; // the address sp + off
const H_FPADDR: u8 = 6; // the address x29 + off

// Register sets: bit `r` for register number `r`.
const XALLOC: u64 = 0xFFFF;
const XFIX: u64 = 0x1FF80000;
// The caller-saved x registers a value may hold for its whole range: x9..x15 (no argument register).
const XSCR: u64 = 0xFE00;

// The caller-saved v registers a value may hold for its whole range: v16..v29.
const fn vscr() u64 {
    return 0x3FFFu64 << 48;
}

// `Gen::fix_class`: no fixed register, a callee-saved one, a caller-saved one.
const FIX_NONE: u8 = 0;
const FIX_CALLEE: u8 = 1;
const FIX_SCRATCH: u8 = 2;

// The allocatable v registers: v0..v7 and v16..v29.
const fn valloc() u64 {
    return 0xFFu64 << 32 | 0x3FFFu64 << 48;
}

// The v registers for loop values: v8..v15.
const fn vfix() u64 {
    return 0xFFu64 << 40;
}

const fn bit(r: u8) u64 {
    return 1u64 << r as u64;
}

/// Per value: where it is.
struct Va {
    pub reg: u8, // NOREG or the register holding it
    pub home: u8,
    pub dirty: bool, // the register holds it and the home does not
    pub clean: bool, // its register's bits above its width are zero (an i8 compare result, say)
    pub off: i32,
}

extend Va as Copy {}

// A relocation of the body's code: word `at` (before the prologue) of kind `kind` against object symbol
// `sym` plus `addend`.
struct CRel {
    pub at: u32,
    pub kind: u8,
    pub sym: u32,
    pub addend: i64,
}

extend CRel as Copy {}

// A pending condition: the flags hold the result of the instruction before, which a branch or select
// right after reads instead of a value.
struct Cond {
    pub inst: u32, // the instruction whose value (or flag) it stands for, NONE without one
    pub cc: u32, // the condition code; `cc2` too when not NONE (a float compare of two conditions)
    pub cc2: u32,
}

extend Cond as Copy {}

/// The arm64 generator of one object.
pub struct Gen {
    pub err: String, // the first refusal, empty when every body compiled
    pkg: *const Package,
    o: *mut ob::Obj,
    apple: bool,
    // An ELF object: a shared object's global symbols through the GOT, thread-locals through TLS
    // descriptors, the frames' unwind rules for `.eh_frame`.
    elf: bool,
    ptr: u32,
    vregs: u32, // the package's `vec_regs`
    // ---- per body ----
    bp: *const Body,
    lv: lv::Live,
    va: Vector<Va>,
    code: Vector<u32>,
    owner: Vector<u32>, // per register number, the value index it holds, NONE
    held: u64, // a bit per register whose `owner` is a value
    clob: u64, // the caller-saved registers the current call writes: all, or an intrinsic's
    lock: u64, // registers the current instruction reads or writes
    tmps: u64, // registers the current instruction took as temporaries
    fixed_busy: u64,
    csr: u64, // callee-saved registers the body uses
    rows: Vector<u64>, // with debug information, per change of location: its code word << 32 | its `lines` index
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
    cond: Cond, // the flags the instruction just compiled left for the next one
    pend: Cond, // the flags the instruction being compiled may read
    // Frame.
    out_size: u32,
    slot_off: Vector<u32>,
    spill_base: u32,
    spill_top: u32,
    free_slots: Vector<u64>, // size << 32 | offset of a released spill slot
    max_align: u32,
    sret_off: i64, // the slot of x8 for a vector result in memory, -1 when none
    // The register save area of a variadic body under the standard convention (x0..x7 at its start,
    // then q0..q7), NONE when none.
    va_save: u32,
    // Labels.
    blk_at: Vector<u32>, // per block, its first word, NONE before it is compiled
    fix: Vector<u64>, // word << 32 | block: a branch to patch
    // A conditional branch to a block is an inverted one over a `B`: the function is past the 1 MiB a
    // conditional branch reaches (`func`).
    far: bool,
    epi: Vector<u32>, // branches to the epilogue
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
    pub src: Lc,
    pub dst: Lc,
    pub v: bool,
    pub bytes: u32,
    pub done: bool,
}

extend Mv as Copy {}

// A location: a register, memory at base + off, a value to rematerialize, or an aggregate's bytes at
// a register base.
struct Lc {
    pub kind: u8, // LC_REG, LC_MEM, LC_VAL
    pub reg: u8, // the register, or the base register of memory
    pub off: i32,
    pub val: u32, // LC_VAL: the value index
}

extend Lc as Copy {}

const LC_REG: u8 = 0;
const LC_MEM: u8 = 1;
const LC_VAL: u8 = 2;

extend Gen {
    pub fn new(pkg: &Package, o: &mut ob::Obj, apple: bool, elf: bool) Gen {
        let mut owner = Vector::<u32>::with_capacity(64);
        for _ in 0..64 {
            owner.push(NONE);
        }
        return Gen {
            err: String::new(),
            pkg: pkg,
            o: o,
            apple: apple,
            elf: elf,
            ptr: pkg.ptr_bytes,
            vregs: pkg.vec_regs,
            bp: null,
            lv: lv::Live::new(),
            va: Vector::<Va>::new(),
            code: Vector::<u32>::new(),
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
            cond: Cond { inst: NONE, cc: 0, cc2: NONE },
            pend: Cond { inst: NONE, cc: 0, cc2: NONE },
            out_size: 0,
            slot_off: Vector::<u32>::new(),
            spill_base: 0,
            spill_top: 0,
            free_slots: Vector::<u64>::new(),
            max_align: 16,
            sret_off: -1,
            va_save: NONE,
            blk_at: Vector::<u32>::new(),
            fix: Vector::<u64>::new(),
            far: false,
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

    fn emit(self: &mut Self, w: u32) {
        self.code.push(w);
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

    // The register file of type `t`: false for x, true for v. Memory types are neither (`in_mem`).
    const fn is_v(t: u8) bool {
        return is_float(t);
    }

    const fn in_mem(t: u8) bool {
        return t == T_I128 || is_vec(t);
    }

    // Whether memory value type `t` may also be in a v register: a vector of 8 or 16 bytes.
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

    // ---- Registers ----

    // A free register of file `vreg`, evicting another value's when none is.
    fn alloc(self: &mut Self, vreg: bool) u8 {
        let set = if vreg {
            valloc();
        } else {
            XALLOC;
        };
        let open = set & ~(self.lock | self.tmps | self.fixed_busy);
        // A vector value takes v16 to v29 first: no argument and no intrinsic's template uses them.
        let high = open & ~self.held & vscr();
        if vreg && high != 0 {
            return high.trailing_zeros() as u8;
        }
        if (open & ~self.held) != 0 {
            let r = (open & ~self.held).trailing_zeros() as u32;
            return r as u8;
        }
        // Evict round-robin: the next unlocked register that holds a value.
        let busy = open & self.held;
        if busy != 0 {
            let s = self.rr % 64;
            let r = if busy >> s as u64 != 0 {
                s + (busy >> s as u64).trailing_zeros() as u32;
            } else {
                busy.trailing_zeros() as u32;
            };
            self.rr = r + 1;
            self.evict(r as u8);
            return r as u8;
        }
        assert(false, "a64gen: every register is locked");
        return 0;
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

    // Whether the current instruction reads value `x`.
    const fn read_now(self: &Self, x: u32) bool {
        for k in 0..self.uses.len() {
            if self.vx(self.uses[k]) == x {
                return true;
            }
        }
        return false;
    }

    // Whether value `x` is used after the current instruction.
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

    // Store value `x`'s register to its home, giving it a stack slot first.
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
        self.mem(mkind(t, false), false, va.reg, a::SP, off);
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
        let r = self.take_home(x, vr);
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let r2 = self.alloc(vr);
        self.bind(x, r2);
        return r2;
    }

    // The register home `fix_class` gives value index `x` of file `vr`, taken; NOREG for none.
    fn take_home(self: &mut Self, x: u32, vr: bool) u8 {
        let fc = self.fix_class(x);
        if fc == FIX_CALLEE {
            return self.take_fixed(x, vr);
        }
        if fc == FIX_SCRATCH {
            return self.take_scratch(x, vr);
        }
        return NOREG;
    }

    // Which register value index `x` holds for its whole range (`plan_homes`).
    const fn fix_class(self: &Self, x: u32) u8 {
        return self.lv.home[x as usize];
    }

    // Plan the homes (`Live::plan`) over each value's request: none in memory or rematerialized; a callee-saved register
    // for a value a call that returns runs in the range of (v8..v15 keep only their low 8 bytes: no
    // vector asks); either for one that lives past its block or a block parameter (a flag: callee-saved
    // only); none for the others, which temporaries hold. x19..x28 and v8..v15; six of x9..x15 and eight
    // of v16..v29, the others left to temporaries.
    fn plan_homes(self: &mut Self) {
        let b = self.b();
        let n = self.lv.end.len();
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        self.want.truncate(0);
        for x in 0..n {
            let t = self.xty(x as u32);
            let d = self.lv.def_blk[x];
            let mut w: u8 = 0;
            if !Gen::in_mem(t) && d != NONE && self.lv.pos[d as usize] != NONE && !(x < ni && self.remat_inst(x as u32)) {
                if x < nv && self.crosses_call(x as u32) {
                    w = lv::WANT_CALLEE;
                } else if x >= nv && self.lv.end[x] > self.lv.pos[d as usize] {
                    w = lv::WANT_CALLEE;
                } else if self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && x < nv {
                    w = lv::WANT_CALLEE | lv::WANT_SCRATCH;
                }
                if Gen::is_v(t) {
                    w |= lv::WANT_V;
                }
            }
            self.want.push(w);
        }
        self.lv.plan(b, &self.want, lv::Caps { xc: 10, xs: 6, xj: 16, vc: 8, vs: 8, vj: 16 });
    }

    // Whether a call that returns (`clobbers`) runs while value index `x` (an instruction's or a
    // parameter's) lives: after its definition and before its last use in its own block, or in a block
    // of its range after its own.
    const fn crosses_call(self: &Self, x: u32) bool {
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
            return self.cpre[self.lv.last[x as usize] as usize] > self.cpre[from as usize];
        }
        return self.cpre[(bk.start + bk.len) as usize] > self.cpre[from as usize] || self.cpos[e as usize + 1] > self.cpos[dp as usize + 1];
    }

    // `cpre` and `cpos`: the calls that return (`clobbers`, not followed by `unreachable`)
    // before each instruction index, and the blocks holding one before each layout position.
    fn call_tables(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill32(&mut self.cpre, ni + 1, 0);
        for i in 0..ni {
            // An intrinsic's template writes x0, x1 and v0 to v4 and its arguments' registers: no
            // scratch home.
            let t = b.insts[i];
            if Gen::clobbers(b, t) && b.insts[i + 1].op != O_UNREACHABLE && !(t.op == O_CALL && self.intrinsic(t.a).len() != 0) {
                self.cpre[i + 1] = 1;
            }
        }
        let nq = self.lv.order.len();
        fill32(&mut self.cpos, nq + 1, 0);
        for q in 0..nq {
            let bk = b.blocks[self.lv.order[q] as usize];
            self.cpos[q + 1] = self.cpos[q];
            for i in bk.start..bk.start + bk.len {
                if self.cpre[i as usize + 1] != 0 {
                    self.cpos[q + 1] = self.cpos[q] + 1;
                    break;
                }
            }
        }
        for i in 0..ni {
            self.cpre[i + 1] += self.cpre[i];
        }
    }

    // Whether instruction `t` of `b` may call a function, which writes the caller-saved registers: a call,
    // inline assembly, a vector operation, a copy or a fill, an i128 division or conversion.
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

    // Give value index `x` a free callee-saved register of file `vr` as its home; NOREG when none is free.
    fn take_fixed(self: &mut Self, x: u32, vr: bool) u8 {
        let set = if vr {
            vfix();
        } else {
            XFIX;
        };
        for r in 0..64u32 {
            if (set & bit(r as u8)) != 0 && (self.fixed_busy & bit(r as u8)) == 0 {
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

    // Give value index `x` a caller-saved register of file `vr` (`XSCR`, `vscr`) as its home, the value
    // there evicted: one the current instruction does not use; NOREG when none is.
    fn take_scratch(self: &mut Self, x: u32, vr: bool) u8 {
        let set = if vr {
            vscr();
        } else {
            XSCR;
        };
        let open = set & ~(self.fixed_busy | self.lock | self.tmps);
        if open == 0 {
            return NOREG;
        }
        // A free one first.
        let r = if (open & ~self.held) != 0 {
            (open & ~self.held).trailing_zeros() as u8;
        } else {
            open.trailing_zeros() as u8;
        };
        self.evict(r);
        self.fixed_busy |= bit(r);
        self.set_owner(r, x);
        let va = self.va.index_mut(x as usize);
        va.reg = r;
        va.home = H_FIXED;
        va.dirty = false;
        return r;
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
            self.mem(mkind(t, true), true, r, a::SP, va.off);
        } else if va.home == H_ARG {
            self.mem(mkind(t, true), true, r, a::FP, va.off);
        } else {
            assert(false, "a64gen: a value with no register and no home");
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
            self.add_off(
                r,
                if va.home == H_SPADDR {
                    a::SP;
                } else {
                    a::FP;
                },
                va.off,
            );
            return;
        }
        if va.reg != NOREG {
            self.move_reg(t, r, va.reg);
            return;
        }
        if va.home == H_SLOT || va.home == H_ARG {
            self.mem(
                mkind(t, true),
                true,
                r,
                if va.home == H_SLOT {
                    a::SP;
                } else {
                    a::FP;
                },
                va.off,
            );
            return;
        }
        let i = self.b().insts[v as usize];
        if i.op == O_ICONST {
            self.mov_imm(r, i.b as u64 << 32 | i.a as u64, type_bytes(t, self.ptr) == 8);
        } else if i.op == O_FCONST {
            self.fconst(r, t == T_F64, i.b as u64 << 32 | i.a as u64);
        } else if i.op == O_SLOTADDR {
            self.add_off(r, a::SP, self.slot_off[i.a as usize]);
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
                false,
            );
            return;
        }
        let x = self.vx(v);
        let va = self.va[x as usize];
        // A narrow load zero-extends.
        let clean = va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG);
        self.materialize(v, r);
        if signed {
            self.emit(a::sxt(false, r, r, bits));
        } else if !clean {
            self.emit(a::uxt(r, r, bits));
        }
    }

    // Copy register `src` to `dst` (type `t`'s file).
    fn move_reg(self: &mut Self, t: u8, dst: u8, src: u8) {
        if dst == src {
            return;
        }
        if is_vec(t) {
            self.emit(a::vmov(type_bytes(t, 8) == 16, dst - V0, src - V0));
        } else if Gen::is_v(t) {
            self.emit(a::fmov(t == T_F64, dst - V0, src - V0));
        } else {
            self.emit(a::mov_reg(true, dst, src));
        }
    }

    // ---- Instruction bookkeeping ----

    // Count the uses of instruction `i` and note the values that die at it.
    fn begin_inst(self: &mut Self, i: u32) {
        self.cur = i;
        self.pend = self.cond;
        self.cond = Cond { inst: NONE, cc: 0, cc2: NONE };
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

    // A stack slot of `size` bytes aligned to `al` (memory values and spills); its sp offset.
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

    // `rd` = `base` + `off` (base may be sp).
    fn add_off(self: &mut Self, rd: u8, base: u32, off: i64) {
        if off >= 0 && off < 4096 {
            self.emit(a::add_imm(true, rd, base, off as u32));
        } else if off < 0 && off > -4096 {
            self.emit(a::sub_imm(true, rd, base, (-off) as u32));
        } else if off >= 0 && off < 1 << 24 && (off & 0xFFF) == 0 {
            self.emit(a::addsub_imm(true, 0, false, rd, base, (off >> 12) as u32, true));
        } else {
            self.mov_imm(a::IP1 as u8, off as u64, true);
            self.emit(a::addsub_ext(true, 0, false, rd, base, a::IP1, 3, 0));
        }
    }

    // A load (`load`) or store of access `m` between register `rt` and memory at `base` + `off`. A
    // base or offset that does not encode goes through x17.
    // The address of load or store `i` that folds its `ptradd` (`Live::fold`): its base and index
    // registers, and whether the index scales by the access's size.
    fn folded(self: &mut Self, i: u32) (u32, u32, bool) {
        let p = self.b().insts[self.b().insts[i as usize].a as usize];
        let rn = self.reg(p.a);
        let rm = self.reg(p.b);
        return rn, rm, p.aux != 1;
    }

    // An access `m` of register `rt` at `rn` + `rm`, scaled by its size when `scaled`.
    fn mem_ix(self: &mut Self, m: u32, load: bool, rt: u8, rn: u32, rm: u32, scaled: bool) {
        let r = if m >= a::M_VB {
            (rt - V0) as u32;
        } else {
            rt as u32;
        };
        self.emit(a::ldst_reg(m, load, r, rn, rm, scaled));
    }

    fn mem(self: &mut Self, m: u32, load: bool, rt: u8, base: u32, off: i64) {
        let r = if m >= a::M_VB {
            (rt - V0) as u32;
        } else {
            rt as u32;
        };
        if a::uimm_fits(m, off) {
            self.emit(a::ldst_uimm(m, load, r, base, off as u32));
        } else if off >= -256 && off < 256 {
            self.emit(a::ldst_unscaled(m, load, r, base, off as i32));
        } else {
            // The register-offset form takes sp as its base.
            self.mov_imm(a::IP1 as u8, off as u64, true);
            self.emit(a::ldst_reg(m, load, r, base, a::IP1, false));
        }
    }

    // Whether a `bytes`-byte access at value `v` + `off` reads or writes a defined data symbol aligned
    // for it, `v` its address recomputed at each use: then `s` and `add`, the symbol and the offset,
    // which the access's page offset takes (`mem_sym`).
    const fn sym_mem(self: &Self, v: Value, off: i64, bytes: u32, s: &mut u32, add: &mut i64) bool {
        if (v & (VPARAM | VFLAG)) != 0 || self.va[v as usize].home != H_REMAT || self.va[v as usize].reg != NOREG {
            return false;
        }
        let it = self.b().insts[v as usize];
        if it.op != O_SYMADDR {
            return false;
        }
        let p = unsafe &*self.pkg;
        let ps = p.syms[self.b().syms[it.a as usize] as usize];
        if ps.kind != SK_DATA || ps.ext || ps.def == NONE || self.got_global(ps) {
            return false;
        }
        let k = (it.b as i32) as i64 + off;
        if k < 0 || 1u32 << p.data[ps.def as usize].align_log2 < bytes || k % bytes as i64 != 0 {
            return false;
        }
        *s = it.a;
        *add = k;
        return true;
    }

    // A load (`load`) or store of access `m` between register `rt` and symbol `s` + `add` (`sym_mem`):
    // its page into x17, its page offset in the access.
    fn mem_sym(self: &mut Self, m: u32, load: bool, rt: u8, s: u32, add: i64) {
        let r = if m >= a::M_VB {
            (rt - V0) as u32;
        } else {
            rt as u32;
        };
        let os = self.osym_of(s);
        self.reloc(a::R_PAGE21, os, add);
        self.emit(a::adr(true, a::IP1, 0));
        self.reloc(a::R_PAGEOFF12, os, add);
        self.emit(a::ldst_uimm(m, load, r, a::IP1, 0));
    }

    // `rd` = `v` (64-bit when `sf`), in the fewest instructions.
    fn mov_imm(self: &mut Self, rd: u8, v0: u64, sf: bool) {
        let v = if sf {
            v0;
        } else {
            v0 & 0xFFFFFFFF;
        };
        let nh: u32 = if sf {
            4;
        } else {
            2;
        };
        let mut zeros: u32 = 0;
        let mut ones: u32 = 0;
        for k in 0..nh {
            let h = v >> (16 * k) as u64 & 0xFFFF;
            if h == 0 {
                zeros += 1;
            } else if h == 0xFFFF {
                ones += 1;
            }
        }
        if zeros < nh - 1 && ones < nh - 1 {
            let li = a::logical_imm(v, sf);
            if li != 0xFFFFFFFF {
                self.emit(a::logic_imm(sf, 1, rd, a::ZR, li));
                return;
            }
        }
        // MOVN when more halfwords are all ones than all zeros.
        let inv = ones > zeros;
        let skip: u64 = if inv {
            0xFFFF;
        } else {
            0;
        };
        let mut first = true;
        for k in 0..nh {
            let h = v >> (16 * k) as u64 & 0xFFFF;
            if h == skip {
                continue;
            }
            if first {
                let imm = if inv {
                    ~h & 0xFFFF;
                } else {
                    h;
                };
                self.emit(
                    a::movw(
                        sf,
                        if inv {
                            0u32;
                        } else {
                            2u32;
                        },
                        rd,
                        imm as u32,
                        k,
                    ),
                );
                first = false;
            } else {
                self.emit(a::movw(sf, 3, rd, h as u32, k));
            }
        }
        if first {
            self.emit(
                a::movw(
                    sf,
                    if inv {
                        0u32;
                    } else {
                        2u32;
                    },
                    rd,
                    0,
                    0,
                ),
            );
        }
    }

    // v register `r` = the float of bits `bits` (`d` double).
    fn fconst(self: &mut Self, r: u8, d: bool, bits: u64) {
        let i8 = a::fp_imm8(d, bits);
        if i8 != 0xFFFFFFFF {
            self.emit(a::fmov_imm(d, r - V0, i8));
            return;
        }
        if bits == 0 {
            self.emit(a::fmov_gv(d, true, r - V0, a::ZR));
            return;
        }
        self.mov_imm(a::IP0 as u8, bits, d);
        self.emit(a::fmov_gv(d, true, r - V0, a::IP0));
    }

    // Register `r` = the address of body symbol `s` plus `addend`.
    fn sym_addr(self: &mut Self, r: u8, s: u32, addend: i64) {
        let os = self.osym_of(s);
        let p = unsafe &*self.pkg;
        let ps = p.syms[self.b().syms[s as usize] as usize];
        if ps.kind == SK_TLS && self.elf {
            // The TLS descriptor's function returns the variable's offset from the thread pointer in x0
            // and keeps every other register but x30; x16 holds the function, x17 the thread pointer.
            // The reference is thread-local too, also to a variable another object defines.
            self.obj().syms.index_mut(os as usize).flags |= ob::SF_TLS;
            self.reloc(a::R_TLSDESC_PAGE21, os, 0);
            self.emit(a::adr(true, 0, 0));
            self.reloc(a::R_TLSDESC_LD64, os, 0);
            self.emit(a::ldst_uimm(a::M_X, true, a::IP0, 0, 0));
            self.reloc(a::R_TLSDESC_ADD, os, 0);
            self.emit(a::add_imm(true, 0, 0, 0));
            self.reloc(a::R_TLSDESC_CALL, os, 0);
            self.emit(a::blr(a::IP0));
            self.emit(a::mrs_tp(a::IP1));
            self.emit(a::addsub_reg(true, 0, false, r, a::IP1, 0, 0, 0));
            self.add_imm_any(r, addend);
            return;
        }
        if ps.kind == SK_TLS {
            // The descriptor's getter returns the address in x0 and keeps every other register but x16,
            // x17 and x30.
            self.reloc(a::R_TLV_PAGE21, os, 0);
            self.emit(a::adr(true, 0, 0));
            self.reloc(a::R_TLV_PAGEOFF12, os, 0);
            self.emit(a::ldst_uimm(a::M_X, true, 0, 0, 0));
            self.emit(a::ldst_uimm(a::M_X, true, a::IP0, 0, 0));
            self.emit(a::blr(a::IP0));
            if r != 0 {
                self.emit(a::mov_reg(true, r, 0));
            }
            self.add_imm_any(r, addend);
            return;
        }
        if ps.ext || self.got_global(ps) {
            // Maybe in a shared library: through its address slot.
            self.reloc(a::R_GOT_PAGE21, os, 0);
            self.emit(a::adr(true, r, 0));
            self.reloc(a::R_GOT_PAGEOFF12, os, 0);
            self.emit(a::ldst_uimm(a::M_X, true, r, r, 0));
            self.add_imm_any(r, addend);
            return;
        }
        self.reloc(a::R_PAGE21, os, addend);
        self.emit(a::adr(true, r, 0));
        self.reloc(a::R_PAGEOFF12, os, addend);
        self.emit(a::add_imm(true, r, r, 0));
    }

    // Whether package symbol `ps` is a global one an ELF shared object reaches through the GOT: another
    // object may interpose it.
    const fn got_global(self: &Self, ps: Sym) bool {
        return self.elf && unsafe (*self.pkg).pic && ps.linkage == SL_GLOBAL;
    }

    // `r` += `k` (any constant).
    fn add_imm_any(self: &mut Self, r: u8, k: i64) {
        if k != 0 {
            self.add_off(r, r, k);
        }
    }

    fn reloc(self: &mut Self, kind: u8, sym: u32, addend: i64) {
        self.rels.push(CRel { at: self.code.len() as u32, kind: kind, sym: sym, addend: addend });
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

// The memory access kind of type `t` (`load`: an integer below 64 bits loads zero-extended).
const fn mkind(t: u8, load: bool) u32 {
    let _ = load;
    if is_vec(t) {
        return if type_bytes(t, 8) == 16 {
            a::M_VQ;
        } else {
            a::M_VD;
        };
    }
    if t == T_F32 {
        return a::M_VS;
    }
    if t == T_F64 {
        return a::M_VD;
    }
    if t == T_I8 {
        return a::M_B;
    }
    if t == T_I16 {
        return a::M_H;
    }
    if t == T_I32 {
        return a::M_W;
    }
    return a::M_X;
}

// ---- Functions ----

extend Gen {
    /// Compile the body of package function symbol `s` into the object. False (with `err`) when the
    /// body uses what the generator does not compile.
    pub fn func(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        self.bp = &p.bodies[ps.def as usize];
        let b = self.b();
        self.lv.fold_max = 16;
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
        fill32(&mut self.owner, 64, NONE);
        self.held = 0;
        fill32(&mut self.blk_at, b.blocks.len(), NONE);
        self.code.truncate(0);
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
        self.cond = Cond { inst: NONE, cc: 0, cc2: NONE };
        if b.naked {
            return self.naked(s);
        }
        self.frame_layout();
        self.bucket_ends();
        self.call_tables();
        self.plan_homes();
        if self.err.len() != 0 || !self.entry() {
            return false;
        }
        for q in 0..self.lv.order.len() {
            if !self.block(q as u32) {
                return false;
            }
        }
        if self.finish(s) {
            return true;
        }
        if self.err.len() != 0 || self.far {
            return false;
        }
        // A conditional branch out of range: once more, every one of them over a `B`.
        self.far = true;
        let ok = self.func(s, local);
        self.far = false;
        return ok;
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
        self.out_size = out;
        self.max_align = 16;
        self.sret_off = -1;
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
        self.va_save = NONE;
        if !self.apple && (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 {
            // x0..x7 (64 bytes), then q0..q7 (128 bytes).
            at = at + 15 & ~15u32;
            self.va_save = at;
            at += 192;
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
    fn entry(self: &mut Self) bool {
        let b = self.b();
        cc::classify(b, b.sig, self.ptr, self.apple, self.vregs, &mut self.self_lay);
        if self.self_lay.unknown {
            return self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        if self.va_save != NONE {
            // The argument registers the fixed parameters leave, where `va_arg` reads them.
            for r in self.self_lay.named_gp as u32..8 {
                self.mem(a::M_X, false, r as u8, a::SP, self.va_save + 8 * r);
            }
            for r in self.self_lay.named_vr as u32..8 {
                self.mem(a::M_VQ, false, V0 + r as u8, a::SP, self.va_save + 64 + 16 * r);
            }
        }
        let np = b.pool[b.sig as usize];
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        for k in 0..np {
            let x = ni + e0 + k;
            let pt = b.pool[(b.sig + 3 + k) as usize];
            let loc = self.self_lay.locs[k as usize];
            let t = self.xty(x);
            let agg = (pt & AGG) != 0;
            if loc.kind == ab::L_STACK {
                let home = if agg {
                    H_FPADDR;
                } else {
                    H_ARG;
                };
                self.va.index_mut(x as usize).home = home;
                self.va.index_mut(x as usize).off = (16 + loc.off) as i32;
            } else if loc.kind == ab::L_REF_STACK {
                if !agg && Gen::in_mem(t) {
                    // A wide vector: copy the caller's bytes, through the pointer on the stack, into the
                    // value's slot (x17 holds the pointer; the copy goes through x16 and v30).
                    let sz = type_bytes(t, self.ptr);
                    let off = self.slot_alloc(sz, 16);
                    self.mem(a::M_X, true, (a::IP0 + 1) as u8, a::FP, 16 + loc.off as i64);
                    self.copy_mem(a::SP, off, a::IP0 + 1, 0, sz);
                    self.va.index_mut(x as usize).home = H_SLOT;
                    self.va.index_mut(x as usize).off = off as i32;
                    continue;
                }
                self.va.index_mut(x as usize).home = H_ARG;
                self.va.index_mut(x as usize).off = (16 + loc.off) as i32;
            } else if loc.kind == ab::L_REF_REG {
                let r = self.self_lay.parts[loc.p0 as usize].reg;
                if agg {
                    self.entry_reg(x, r);
                } else {
                    // A wide vector: copy the caller's bytes into the value's slot.
                    let sz = type_bytes(t, self.ptr);
                    let off = self.slot_alloc(sz, 16);
                    self.copy_mem(a::SP, off, r, 0, sz);
                    self.va.index_mut(x as usize).home = H_SLOT;
                    self.va.index_mut(x as usize).off = off as i32;
                }
            } else if agg || Gen::in_mem(t) {
                // Register parts into a slot: the aggregate's memory, or the memory value.
                let (size, _) = sig_size(b, pt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                for q in 0..loc.n as u32 {
                    let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                    self.store_part(pa, a::SP, off as i64 + pa.off as i64);
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
        // An aggregate result: its memory is x8's, or a slot the return reads.
        let rt = b.pool[b.sig as usize + 2];
        if (rt & AGG) == 0 && self.self_lay.ret.kind == ab::L_SRET {
            // A vector result in memory: the return copies it to x8's memory.
            self.sret_off = self.slot_alloc(8, 8);
            self.mem(a::M_X, false, 8, a::SP, self.sret_off);
        }
        if (rt & AGG) != 0 {
            let x = ni + e0 + np;
            if self.self_lay.ret.kind == ab::L_SRET {
                self.entry_reg(x, 8);
            } else {
                let (size, _) = sig_size(b, rt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                self.va.index_mut(x as usize).home = H_SPADDR;
                self.va.index_mut(x as usize).off = off as i32;
            }
        }
        return true;
    }

    // Parameter value index `x` arrives in register `r`.
    fn entry_reg(self: &mut Self, x: u32, r: u8) {
        if self.lv.uses[x as usize] == 0 {
            return;
        }
        let t = self.xty(x);
        let f = self.take_home(x, Gen::is_v(t));
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
        self.blk_at[k as usize] = self.code.len() as u32;
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

    // A line row at the next code word for location `loc` (a `lines` index) when it differs from the last.
    fn row(self: &mut Self, loc: u32) {
        let n = self.rows.len();
        if loc == 0 || n != 0 && (self.rows[n - 1] & 0xFFFFFFFF) as u32 == loc {
            return;
        }
        let at = self.code.len() as u64 << 32;
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
        let ne: u32 = if t.op == O_JMP {
            1;
        } else if t.op == O_BR {
            2;
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1;
        } else {
            0;
        };
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
        if !Gen::in_mem(t) && self.take_home(x, Gen::is_v(t)) != NOREG {
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
            return Lc { kind: LC_MEM, reg: a::SP as u8, off: va.off, val: x };
        }
        if va.home == H_ARG {
            return Lc { kind: LC_MEM, reg: a::FP as u8, off: va.off, val: x };
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
                Lc { kind: LC_MEM, reg: a::SP as u8, off: pva.off, val: px };
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
                        let tmp = Lc { kind: LC_MEM, reg: a::SP as u8, off: s, val: NONE };
                        self.do_move(m.src, tmp, m.v, m.bytes);
                        self.mv.index_mut(i).src = tmp;
                        break;
                    }
                }
            }
        }
        assert(left == 0, "a64gen: a parallel move did not finish");
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
        if v && bytes == 16 && src.kind != LC_VAL {
            // A vector register's 16 bytes.
            if dst.kind == LC_REG && src.kind == LC_REG {
                self.emit(a::vmov(true, dst.reg - V0, src.reg - V0));
            } else if dst.kind == LC_REG {
                self.mem(a::M_VQ, true, dst.reg, src.reg, src.off);
            } else {
                self.mem(a::M_VQ, false, src.reg, dst.reg, dst.off);
            }
            return;
        }
        let t = if v && bytes == 4 {
            T_F32;
        } else if v && bytes == 8 {
            T_F64;
        } else {
            int_type(bytes);
        };
        if dst.kind == LC_REG {
            if src.kind == LC_REG {
                self.move_reg(t, dst.reg, src.reg);
            } else if src.kind == LC_MEM {
                self.mem(mkind(t, true), true, dst.reg, src.reg, src.off);
            } else {
                self.materialize(self.xval(src.val), dst.reg);
            }
            return;
        }
        // Into memory through a scratch register.
        let s = if v {
            V0 + 30;
        } else {
            a::IP0 as u8;
        };
        let r = if src.kind == LC_REG {
            src.reg;
        } else {
            self.materialize(self.xval(src.val), s);
            s;
        };
        self.mem(mkind(t, false), false, r, dst.reg, dst.off);
    }

    // The value of value index `x` (an instruction or a parameter).
    const fn xval(self: &Self, x: u32) Value {
        let ni = self.b().insts.len() as u32;
        if x < ni {
            return x;
        }
        return VPARAM | x - ni;
    }

    // Copy `n` bytes from `sb` + `so` to `db` + `do` (registers or sp) through x16 and v30.
    fn copy_mem(self: &mut Self, db: u32, do0: i64, sb: u32, so0: i64, n: u32) {
        let mut at: u32 = 0;
        // Chunks of 16, 8, 4, 2 and 1 bytes: at most n / 16 + 4 steps.
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
            let m = if step == 16 {
                a::M_VQ;
            } else {
                size_kind(step);
            };
            let r = if m == a::M_VQ {
                V0 + 30;
            } else {
                a::IP0 as u8;
            };
            self.mem(m, true, r, sb, so0 + at as i64);
            self.mem(m, false, r, db, do0 + at as i64);
            at += step;
        }
    }

    // Store register part `pa` (an argument or result register) to memory at `base` + `off`.
    fn store_part(self: &mut Self, pa: ab::Part, base: u32, off: i64) {
        if pa.v {
            let m = if pa.size == 4 {
                a::M_VS;
            } else if pa.size == 8 {
                a::M_VD;
            } else {
                a::M_VQ;
            };
            self.mem(m, false, V0 + pa.reg, base, off);
            return;
        }
        self.store_bytes(pa.reg, base, off, pa.size);
    }

    // Load register part `pa` from memory at `base` + `off`.
    fn load_part(self: &mut Self, pa: ab::Part, base: u32, off: i64) {
        if pa.v {
            let m = if pa.size == 4 {
                a::M_VS;
            } else if pa.size == 8 {
                a::M_VD;
            } else {
                a::M_VQ;
            };
            self.mem(m, true, V0 + pa.reg, base, off);
            return;
        }
        self.load_bytes(pa.reg, base, off, pa.size);
    }

    // Store the low `n` (1 to 8) bytes of x register `r`; x16 holds the shifted pieces of an odd size.
    fn store_bytes(self: &mut Self, r: u8, base: u32, off: i64, n: u32) {
        if n == 1 || n == 2 || n == 4 || n == 8 {
            self.mem(size_kind(n), false, r, base, off);
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
            self.mem(size_kind(step), false, src, base, off + at as i64);
            at += step;
            if at < n {
                self.emit(a::lsr_imm(true, a::IP0, src, 8 * step));
                src = a::IP0 as u8;
            }
        }
    }

    // Load `n` (1 to 8) bytes into x register `r`, zero-extended; x16 holds the upper pieces of an odd
    // size.
    fn load_bytes(self: &mut Self, r: u8, base: u32, off: i64, n: u32) {
        if n == 1 || n == 2 || n == 4 || n == 8 {
            self.mem(size_kind(n), true, r, base, off);
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
                self.mem(size_kind(step), true, r, base, off);
            } else {
                self.mem(size_kind(step), true, a::IP0 as u8, base, off + at as i64);
                self.emit(a::logic_reg(true, 1, false, r, r, a::IP0, 0, 8 * at));
            }
            at += step;
        }
    }
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

// The access kind of an `n`-byte integer (1, 2, 4 or 8).
const fn size_kind(n: u32) u32 {
    if n == 1 {
        return a::M_B;
    }
    if n == 2 {
        return a::M_H;
    }
    if n == 4 {
        return a::M_W;
    }
    return a::M_X;
}

// The size and alignment of signature type `pt` of `b`.
fn sig_size(b: &Body, pt: u32, ptr: u32) (u32, u32) {
    if (pt & AGG) != 0 {
        let l = (pt & ~AGG) as usize;
        return b.pool[l], 1u32 << b.pool[l + 1];
    }
    return type_bytes(pt as u8, ptr), type_align(pt as u8, ptr);
}

// `v` as `n` copies of `x`, its buffer reused.
fn fill32(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

// ---- Instructions ----

// The arm64 condition of integer comparison `c`.
const fn icond(c: u16) u32 {
    if c == C_EQ {
        return a::EQ;
    }
    if c == C_NE {
        return a::NE;
    }
    if c == C_SLT {
        return a::LT;
    }
    if c == C_SLE {
        return a::LE;
    }
    if c == C_SGT {
        return a::GT;
    }
    if c == C_SGE {
        return a::GE;
    }
    if c == C_ULT {
        return a::LO;
    }
    if c == C_ULE {
        return a::LS;
    }
    if c == C_UGT {
        return a::HI;
    }
    return a::HS;
}

// The arm64 condition of float comparison `c` after FCMP; a second one ORs in (`*c2`) for `one` and
// `ueq`, else NONE.
const fn fcond(c: u16, c2: &mut u32) u32 {
    *c2 = NONE;
    if c == C_OEQ {
        return a::EQ;
    }
    if c == C_UNE {
        return a::NE;
    }
    if c == C_OLT {
        return a::MI;
    }
    if c == C_OLE {
        return a::LS;
    }
    if c == C_OGT {
        return a::GT;
    }
    if c == C_OGE {
        return a::GE;
    }
    if c == C_UNO {
        return a::VS;
    }
    if c == C_ONE {
        *c2 = a::GT;
        return a::MI;
    }
    // C_UEQ
    *c2 = a::VS;
    return a::EQ;
}

// Whether comparison `c` orders signed integers.
const fn signed_cond(c: u16) bool {
    return c >= C_SLT && c <= C_SGE;
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
            let off = self.mdef(i);
            for k in 0..t.b {
                self.mov_imm(a::IP0 as u8, self.b().words[(t.a + k) as usize], true);
                self.mem(a::M_X, false, a::IP0 as u8, a::SP, off + 8 * k as i64);
            }
            return true;
        }
        if op == O_SYMADDR {
            // A thread-local variable's address: the getter call clobbers x0.
            self.evict(0);
            self.lock |= bit(0);
            self.sym_addr(0, t.a, t.b as i32);
            let rd = self.def(i);
            self.emit(a::mov_reg(true, rd, 0));
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
            assert(!is_vec(self.vt(t.a)), "a64gen: a vector comparison the verifier rejects");
            let d = self.vt(t.a) == T_F64;
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            self.emit(a::fcmp(d, ra - V0, rb - V0));
            let mut c2: u32 = NONE;
            let c = fcond(t.aux, &mut c2);
            self.cond_value(i, c, c2);
            return true;
        }
        if op >= O_FADD && op <= O_FNEG {
            if is_vec(t.ty) {
                return self.vec_arith(i, t);
            }
            let d = t.ty == T_F64;
            let ra = self.reg(t.a);
            if op == O_FNEG {
                let rd = self.def(i);
                self.emit(a::fp1(d, a::FP_NEG, rd - V0, ra - V0));
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def(i);
            let f = if op == O_FADD {
                a::FP_ADD;
            } else if op == O_FSUB {
                a::FP_SUB;
            } else if op == O_FMUL {
                a::FP_MUL;
            } else {
                a::FP_DIV;
            };
            self.emit(a::fp2(d, f, rd - V0, ra - V0, rb - V0));
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
            self.mem(a::M_X, true, rd, a::FP, 8);
            return true;
        }
        if op == O_CALL || op == O_CALLIND {
            return self.call(i, t);
        }
        if op == O_VOP {
            return self.vop(i, t);
        }
        if op == O_VASTART {
            let ra = self.reg(t.a);
            self.add_off(a::IP0 as u8, a::FP, 16 + (self.self_lay.named_bytes + 7 & ~7u32) as i64);
            self.mem(a::M_X, false, a::IP0 as u8, ra, 0);
            if self.va_save != NONE {
                // The standard `va_list`: the stack position, the ends of the two save areas, and the
                // negative offsets of the first variadic register in each.
                self.add_off(a::IP0 as u8, a::SP, self.va_save + 64);
                self.mem(a::M_X, false, a::IP0 as u8, ra, 8);
                self.add_off(a::IP0 as u8, a::SP, self.va_save + 192);
                self.mem(a::M_X, false, a::IP0 as u8, ra, 16);
                self.mov_imm(a::IP0 as u8, (-8 * (8 - self.self_lay.named_gp as i64)) as u64, false);
                self.mem(a::M_W, false, a::IP0 as u8, ra, 24);
                self.mov_imm(a::IP0 as u8, (-16 * (8 - self.self_lay.named_vr as i64)) as u64, false);
                self.mem(a::M_W, false, a::IP0 as u8, ra, 28);
            }
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

    // The memory value instruction `i` defines: a slot; its sp offset.
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
    fn mloc(self: &mut Self, v: Value) (u32, i64) {
        self.spill(self.vx(v));
        let va = self.va[self.vx(v) as usize];
        if va.home == H_ARG {
            return a::FP, va.off;
        }
        assert(va.home == H_SLOT, "a64gen: a memory value without a slot");
        return a::SP, va.off;
    }

    // The address `v` + `off` as a base register and an offset: a slot or frame address folds in.
    fn addr(self: &mut Self, v: Value, off: i64) (u32, i64) {
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.home == H_SPADDR {
            return a::SP, va.off as i64 + off;
        }
        if va.home == H_FPADDR {
            return a::FP, va.off as i64 + off;
        }
        if va.home == H_REMAT && va.reg == NOREG {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return a::SP, self.slot_off[it.a as usize] as i64 + off;
            }
        }
        return self.reg(v), off;
    }

    // Value `v` (an integer of `bits` bits, 8 or 16) in a register extended to 32 bits.
    fn ext(self: &mut Self, v: Value, signed: bool, bits: u32) u8 {
        let r = self.reg(v);
        let x = self.vx(v);
        if !signed && self.va[x as usize].clean {
            return r;
        }
        let d = self.tmp(false);
        if signed {
            self.emit(a::sxt(false, d, r, bits));
        } else {
            self.emit(a::uxt(d, r, bits));
        }
        return d;
    }

    // Whether the next instruction of the block reads value `x` (its only use) as a condition: a `br` or
    // a `select`.
    const fn fusable(self: &Self, i: u32, v: Value) bool {
        let x = self.vx(v);
        if self.lv.uses[x as usize] != 1 {
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

    // The result of comparison instruction `i` is condition `c` (or `c2`): left in the flags for the
    // next instruction, or set into the value's register.
    fn cond_value(self: &mut Self, i: u32, c: u32, c2: u32) {
        if c2 == NONE && self.fusable(i, i) {
            self.cond = Cond { inst: self.vx(i), cc: c, cc2: NONE };
            return;
        }
        let rd = self.def(i);
        self.emit(a::cset(false, rd, c));
        if c2 != NONE {
            self.emit(a::csel(false, 0, 1, rd, rd, a::ZR, a::invert(c2)));
        } else if self.next_reads(i, i) {
            // The value has other uses; the branch or select after reads the flags all the same.
            self.cond = Cond { inst: self.vx(i), cc: c, cc2: NONE };
        }
        self.va.index_mut(i as usize).clean = true;
    }

    fn icmp(self: &mut Self, i: u32, t: Inst) bool {
        let ty = self.vt(t.a);
        assert(!is_vec(ty), "a64gen: a vector comparison the verifier rejects");
        let c = t.aux;
        if ty == T_I128 {
            return self.icmp128(i, t);
        }
        let bits = type_bits(ty, self.ptr);
        let sf = bits == 64;
        let small = bits < 32;
        let signed = signed_cond(c);
        let ra = if small {
            self.ext(t.a, signed, bits);
        } else {
            self.reg(t.a);
        };
        let mut k: u64 = 0;
        if self.const_of(t.b, &mut k) {
            let kv: i64 = if signed {
                lp_sext(k, bits);
            } else {
                k as i64;
            };
            if kv >= 0 && kv < 4096 {
                self.emit(a::cmp_imm(sf, ra, kv as u32));
                self.cond_value(i, icond(c), NONE);
                return true;
            }
            if kv < 0 && kv > -4096 {
                self.emit(a::cmn_imm(sf, ra, (-kv) as u32));
                self.cond_value(i, icond(c), NONE);
                return true;
            }
        }
        let rb = if small {
            self.ext(t.b, signed, bits);
        } else {
            self.reg(t.b);
        };
        self.emit(a::addsub_reg(sf, 1, true, a::ZR, ra, rb, 0, 0));
        self.cond_value(i, icond(c), NONE);
        return true;
    }

    // An i128 comparison: equality by XOR, order by a 128-bit subtraction (operands swapped for `>` and
    // `<=`).
    fn icmp128(self: &mut Self, i: u32, t: Inst) bool {
        let c = t.aux;
        let (lo_a, hi_a) = self.load128(t.a);
        let (lo_b, hi_b) = self.load128(t.b);
        if c == C_EQ || c == C_NE {
            self.emit(a::logic_reg(true, 2, false, lo_a, lo_a, lo_b, 0, 0));
            self.emit(a::logic_reg(true, 2, false, hi_a, hi_a, hi_b, 0, 0));
            self.emit(a::logic_reg(true, 1, false, lo_a, lo_a, hi_a, 0, 0));
            self.emit(a::cmp_imm(true, lo_a, 0));
            self.cond_value(i, icond(c), NONE);
            return true;
        }
        let swap = c == C_SGT || c == C_SLE || c == C_UGT || c == C_ULE;
        let l1 = if swap {
            lo_b;
        } else {
            lo_a;
        };
        let h1 = if swap {
            hi_b;
        } else {
            hi_a;
        };
        let l2 = if swap {
            lo_a;
        } else {
            lo_b;
        };
        let h2 = if swap {
            hi_a;
        } else {
            hi_b;
        };
        self.emit(a::addsub_reg(true, 1, true, a::ZR, l1, l2, 0, 0));
        self.emit(a::adc(true, 1, true, a::ZR, h1, h2));
        let cc = if c == C_SLT || c == C_SGT {
            a::LT;
        } else if c == C_SGE || c == C_SLE {
            a::GE;
        } else if c == C_ULT || c == C_UGT {
            a::LO;
        } else {
            a::HS;
        };
        self.cond_value(i, cc, NONE);
        return true;
    }

    // Memory value `v` (an i128) into two temporaries: its low and high words.
    fn load128(self: &mut Self, v: Value) (u8, u8) {
        let lo = self.tmp(false);
        let hi = self.tmp(false);
        let (base, off) = self.mloc(v);
        self.mem(a::M_X, true, lo, base, off);
        self.mem(a::M_X, true, hi, base, off + 8);
        return lo, hi;
    }

    // Store two words as i128 instruction `i`'s value.
    fn store128(self: &mut Self, i: u32, lo: u8, hi: u8) {
        let off = self.mdef(i);
        self.mem(a::M_X, false, lo, a::SP, off);
        self.mem(a::M_X, false, hi, a::SP, off + 8);
    }

    // clz: CLZ; ctz: RBIT then CLZ; popcnt: CNT over the bytes in v30, summed by ADDV. An operand under
    // 32 bits is zero-extended; for ctz a bit set at its width makes 0 count the width.
    fn bit_count(self: &mut Self, i: u32, t: Inst) {
        let bits = type_bits(t.ty, self.ptr);
        let sf = bits == 64;
        let mut r = if bits < 32 {
            self.ext(t.a, false, bits) as u32;
        } else {
            self.reg(t.a) as u32;
        };
        if t.op == O_CTZ && bits < 32 {
            self.emit(a::logic_imm(false, 1, a::IP0, r, a::logical_imm(1u64 << bits as u64, false)));
            r = a::IP0;
        }
        let rd = self.def(i) as u32;
        if t.op == O_POPCNT {
            self.emit(a::fmov_gv(true, true, 30, r));
            self.emit(a::cnt8b(30, 30));
            self.emit(a::addv8b(30, 30));
            self.emit(a::fmov_gv(false, false, rd, 30));
            return;
        }
        if t.op == O_CTZ {
            self.emit(a::dp1(sf, a::DP1_RBIT, rd, r));
            r = rd;
        }
        self.emit(a::dp1(sf, a::DP1_CLZ, rd, r));
        if t.op == O_CLZ && bits < 32 {
            self.emit(a::addsub_imm(false, 1, false, rd, rd, 32 - bits, false));
        }
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
        let sf = bits == 64;
        let small = bits < 32;
        if op == O_NEG || op == O_NOT {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if op == O_NEG {
                self.emit(a::addsub_reg(sf, 1, false, rd, a::ZR, ra, 0, 0));
            } else {
                self.emit(a::logic_reg(sf, 1, true, rd, a::ZR, ra, 0, 0));
            }
            return true;
        }
        let mut k: u64 = 0;
        let kc = self.const_of(t.b, &mut k);
        if kc && (op == O_ADD || op == O_SUB) {
            let kv = lp_sext(k, bits);
            let neg = op == O_SUB;
            if kv >= 0 && kv < 4096 || kv < 0 && kv > -4096 {
                let ra = self.reg(t.a);
                let rd = self.def(i);
                let sub = neg != kv < 0;
                let m = if kv < 0 {
                    -kv;
                } else {
                    kv;
                };
                self.emit(
                    a::addsub_imm(
                        sf,
                        if sub {
                            1u32;
                        } else {
                            0u32;
                        },
                        false,
                        rd,
                        ra,
                        m as u32,
                        false,
                    ),
                );
                return true;
            }
        }
        if kc && (op == O_AND || op == O_OR || op == O_XOR) {
            let li = a::logical_imm(k, sf);
            if li != 0xFFFFFFFF {
                let ra = self.reg(t.a);
                let rd = self.def(i);
                let opc = if op == O_AND {
                    0u32;
                } else if op == O_OR {
                    1u32;
                } else {
                    2u32;
                };
                self.emit(a::logic_imm(sf, opc, rd, ra, li));
                return true;
            }
        }
        if kc && (op == O_SHL || op == O_LSHR || op == O_ASHR) && k < bits as u64 {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            let s = k as u32;
            if op == O_SHL {
                self.emit(a::lsl_imm(sf, rd, ra, s));
            } else if small {
                self.emit(
                    a::bitfield(
                        false,
                        if op == O_LSHR {
                            2u32;
                        } else {
                            0u32;
                        },
                        rd,
                        ra,
                        s,
                        bits - 1,
                    ),
                );
            } else if op == O_LSHR {
                self.emit(a::lsr_imm(sf, rd, ra, s));
            } else {
                self.emit(a::asr_imm(sf, rd, ra, s));
            }
            return true;
        }
        let div = op >= O_SDIV && op <= O_UREM;
        let sgn = op == O_SDIV || op == O_SREM || op == O_ASHR;
        let ext_a = small && (div || op == O_LSHR || op == O_ASHR);
        let ra = if ext_a {
            self.ext(t.a, sgn, bits);
        } else {
            self.reg(t.a);
        };
        let rb = if small && div {
            self.ext(t.b, sgn, bits);
        } else {
            self.reg(t.b);
        };
        let rd = self.def(i);
        let xa = ra as u32;
        let xb = rb as u32;
        let xd = rd as u32;
        if op == O_ADD {
            self.emit(a::addsub_reg(sf, 0, false, xd, xa, xb, 0, 0));
        } else if op == O_SUB {
            self.emit(a::addsub_reg(sf, 1, false, xd, xa, xb, 0, 0));
        } else if op == O_MUL {
            self.emit(a::mul(sf, xd, xa, xb));
        } else if op == O_AND || op == O_OR || op == O_XOR {
            let opc = if op == O_AND {
                0u32;
            } else if op == O_OR {
                1u32;
            } else {
                2u32;
            };
            self.emit(a::logic_reg(sf, opc, false, xd, xa, xb, 0, 0));
        } else if op == O_SHL {
            self.emit(a::dp2(sf, a::DP2_LSLV, xd, xa, xb));
        } else if op == O_LSHR {
            self.emit(a::dp2(sf, a::DP2_LSRV, xd, xa, xb));
        } else if op == O_ASHR {
            self.emit(a::dp2(sf, a::DP2_ASRV, xd, xa, xb));
        } else {
            let d = if op == O_SDIV || op == O_SREM {
                a::DP2_SDIV;
            } else {
                a::DP2_UDIV;
            };
            if op == O_SDIV || op == O_UDIV {
                self.emit(a::dp2(sf, d, xd, xa, xb));
            } else {
                self.emit(a::dp2(sf, d, a::IP0, xa, xb));
                self.emit(a::madd(sf, true, xd, a::IP0, xb, xa));
            }
        }
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
        let (al, ah) = self.load128(t.a);
        if op == O_NEG {
            self.emit(a::addsub_reg(true, 1, true, al, a::ZR, al, 0, 0));
            self.emit(a::adc(true, 1, false, ah, a::ZR, ah));
            self.store128(i, al, ah);
            return true;
        }
        if op == O_NOT {
            self.emit(a::logic_reg(true, 1, true, al, a::ZR, al, 0, 0));
            self.emit(a::logic_reg(true, 1, true, ah, a::ZR, ah, 0, 0));
            self.store128(i, al, ah);
            return true;
        }
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            // The shift count: the amount's low word.
            let (base, off) = self.mloc(t.b);
            let n = self.tmp(false);
            self.mem(a::M_X, true, n, base, off);
            self.shift128(op, al, ah, n);
            self.store128(i, al, ah);
            return true;
        }
        let (bl, bh) = self.load128(t.b);
        let al32 = al as u32;
        let ah32 = ah as u32;
        let bl32 = bl as u32;
        let bh32 = bh as u32;
        if op == O_ADD {
            self.emit(a::addsub_reg(true, 0, true, al32, al32, bl32, 0, 0));
            self.emit(a::adc(true, 0, false, ah32, ah32, bh32));
        } else if op == O_SUB {
            self.emit(a::addsub_reg(true, 1, true, al32, al32, bl32, 0, 0));
            self.emit(a::adc(true, 1, false, ah32, ah32, bh32));
        } else if op == O_MUL {
            self.emit(a::mulh(false, a::IP0, al32, bl32));
            self.emit(a::madd(true, false, a::IP0, al32, bh32, a::IP0));
            self.emit(a::madd(true, false, ah32, ah32, bl32, a::IP0));
            self.emit(a::mul(true, al32, al32, bl32));
        } else {
            let opc = if op == O_AND {
                0u32;
            } else if op == O_OR {
                1u32;
            } else {
                2u32;
            };
            self.emit(a::logic_reg(true, opc, false, al32, al32, bl32, 0, 0));
            self.emit(a::logic_reg(true, opc, false, ah32, ah32, bh32, 0, 0));
        }
        self.store128(i, al, ah);
        return true;
    }

    // Shift the i128 in `lo`, `hi` by register `n` (below 128) in place.
    fn shift128(self: &mut Self, op: u8, lo: u8, hi: u8, n: u8) {
        let l = lo as u32;
        let h = hi as u32;
        let c = n as u32;
        let t = a::IP0;
        let u = a::IP1;
        if op == O_SHL {
            // hi = hi << n | lo >> (64 - n); lo <<= n; past 64 the low word moves up.
            self.emit(a::logic_reg(true, 1, true, u, a::ZR, c, 0, 0));
            self.emit(a::lsr_imm(true, t, l, 1));
            self.emit(a::dp2(true, a::DP2_LSRV, t, t, u));
            self.emit(a::dp2(true, a::DP2_LSLV, h, h, c));
            self.emit(a::logic_reg(true, 1, false, h, h, t, 0, 0));
            self.emit(a::dp2(true, a::DP2_LSLV, l, l, c));
            self.emit(a::logic_imm(true, 3, a::ZR, c, a::logical_imm(64, true)));
            self.emit(a::csel(true, 0, 0, h, l, h, a::NE));
            self.emit(a::csel(true, 0, 0, l, a::ZR, l, a::NE));
            return;
        }
        // lo = lo >> n | hi << (64 - n); hi >>= n; past 64 the high word moves down.
        self.emit(a::logic_reg(true, 1, true, u, a::ZR, c, 0, 0));
        self.emit(a::lsl_imm(true, t, h, 1));
        self.emit(a::dp2(true, a::DP2_LSLV, t, t, u));
        self.emit(a::dp2(true, a::DP2_LSRV, l, l, c));
        self.emit(a::logic_reg(true, 1, false, l, l, t, 0, 0));
        let sh = if op == O_ASHR {
            a::DP2_ASRV;
        } else {
            a::DP2_LSRV;
        };
        self.emit(a::dp2(true, sh, t, h, c));
        if op == O_ASHR {
            self.emit(a::asr_imm(true, u, h, 63));
        } else {
            self.emit(a::mov_reg(true, u, a::ZR));
        }
        self.emit(a::logic_imm(true, 3, a::ZR, c, a::logical_imm(64, true)));
        self.emit(a::csel(true, 0, 0, l, t, l, a::NE));
        self.emit(a::csel(true, 0, 0, h, u, t, a::NE));
    }

    fn ovf_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let op = t.op;
        let signed = t.aux == OV_SIGNED;
        let bits = type_bits(ty, self.ptr);
        let sf = bits == 64;
        let mut cc = a::NE;
        if bits < 32 {
            let ra = self.ext(t.a, signed, bits);
            let rb = self.ext(t.b, signed, bits);
            let rd = self.def(i) as u32;
            if op == O_ADDO {
                self.emit(a::addsub_reg(false, 0, false, rd, ra, rb, 0, 0));
            } else if op == O_SUBO {
                self.emit(a::addsub_reg(false, 1, false, rd, ra, rb, 0, 0));
            } else {
                self.emit(a::mul(false, rd, ra, rb));
            }
            // Overflow: the 32-bit result differs from its own extension of the low bits.
            let opt = if signed {
                4u32;
            } else {
                0u32;
            } + if bits == 16 {
                1u32;
            } else {
                0u32;
            };
            self.emit(a::addsub_ext(false, 1, true, a::ZR, rd, rd, opt, 0));
        } else {
            let mut k: u64 = 0;
            let imm = (op == O_ADDO || op == O_SUBO) && self.const_of(t.b, &mut k) && k < 4096;
            let ra = self.reg(t.a) as u32;
            let rb = if imm {
                a::ZR;
            } else {
                self.reg(t.b) as u32;
            };
            let rd = self.def(i) as u32;
            if op == O_ADDO || op == O_SUBO {
                let sub = op == O_SUBO;
                if imm {
                    self.emit(a::addsub_imm(sf, sub as u32, true, rd, ra, k as u32, false));
                } else {
                    self.emit(a::addsub_reg(sf, sub as u32, true, rd, ra, rb, 0, 0));
                }
                cc = if signed {
                    a::VS;
                } else if sub {
                    a::LO;
                } else {
                    a::HS;
                };
            } else if !sf {
                self.emit(a::mull(signed, rd, ra, rb));
                if signed {
                    self.emit(a::addsub_ext(true, 1, true, a::ZR, rd, rd, 6, 0));
                } else {
                    self.emit(a::logic_imm(true, 3, a::ZR, rd, a::logical_imm(0xFFFFFFFF00000000u64, true)));
                }
            } else if signed {
                self.emit(a::mulh(true, a::IP0, ra, rb));
                self.emit(a::mul(true, rd, ra, rb));
                self.emit(a::addsub_reg(true, 1, true, a::ZR, a::IP0, rd, 2, 63));
            } else {
                self.emit(a::mulh(false, a::IP0, ra, rb));
                self.emit(a::mul(true, rd, ra, rb));
                self.emit(a::cmp_imm(true, a::IP0, 0));
            }
        }
        // The flag: for the branch right after, or set into its own register.
        if let Some(fx) = self.lv.flag_of.get(&i) {
            let f = *fx;
            if self.fusable(i, VFLAG | i) {
                self.cond = Cond { inst: f, cc: cc, cc2: NONE };
            } else if self.lv.uses[f as usize] != 0 {
                let r = self.alloc(false);
                self.bind(f, r);
                self.emit(a::cset(false, r, cc));
                self.va.index_mut(f as usize).clean = true;
            }
        }
        return true;
    }

    fn convert(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if is_vec(from) || is_vec(to) {
            if op == O_BITCAST && Gen::in_mem(from) && Gen::in_mem(to) {
                let (base, off) = self.mloc(t.a);
                let d = self.mdef(i);
                self.copy_mem(a::SP, d, base, off, type_bytes(to, self.ptr));
                return true;
            }
            if op == O_BITCAST {
                // A vector and a scalar of one size: through memory.
                if Gen::in_mem(from) {
                    let (base, off) = self.mloc(t.a);
                    let rd = self.def(i);
                    self.mem(mkind(to, true), true, rd, base, off);
                } else {
                    let ra = self.reg(t.a);
                    let d = self.mdef(i);
                    self.mem(mkind(from, false), false, ra, a::SP, d);
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
            let ra = self.reg(t.a) as u32;
            let rd = self.def(i);
            if op == O_SEXT {
                self.emit(a::sxt(tb == 64, rd, ra, fb));
            } else if fb == 32 {
                self.emit(a::mov_reg(false, rd, ra));
            } else {
                self.emit(a::uxt(rd, ra, fb));
            }
            self.va.index_mut(i as usize).clean = op == O_ZEXT;
            return true;
        }
        if op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST && !Gen::is_v(from) && !Gen::is_v(
            to,
        ) {
            let ra = self.reg(t.a) as u32;
            let rd = self.def(i);
            self.emit(a::mov_reg(true, rd, ra));
            return true;
        }
        if op == O_BITCAST {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if Gen::is_v(from) {
                self.emit(a::fmov_gv(from == T_F64, false, rd, ra - V0));
            } else {
                self.emit(a::fmov_gv(to == T_F64, true, rd - V0, ra));
            }
            return true;
        }
        if op == O_FPEXT || op == O_FPTRUNC {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            self.emit(a::fcvt(op == O_FPEXT, rd - V0, ra - V0));
            return true;
        }
        if op == O_SITOFP || op == O_UITOFP {
            let signed = op == O_SITOFP;
            let ra = if fb < 32 {
                self.ext(t.a, signed, fb);
            } else {
                self.reg(t.a);
            };
            let rd = self.def(i);
            self.emit(a::cvtf(fb == 64, to == T_F64, signed, rd - V0, ra));
            return true;
        }
        // A float to an integer: FCVTZ saturates and takes NaN to 0; an i8 or i16 clamps after.
        let signed = op == O_FPTOSI;
        let ra = self.reg(t.a);
        let rd = self.def(i) as u32;
        self.emit(a::fcvtz(tb == 64, from == T_F64, signed, rd, ra - V0));
        if tb < 32 && t.aux != CV_UNCHECKED {
            let hi: u64 = if signed {
                (1u64 << (tb - 1) as u64) - 1;
            } else {
                (1u64 << tb as u64) - 1;
            };
            self.mov_imm(a::IP0 as u8, hi, false);
            self.emit(a::addsub_reg(false, 1, true, a::ZR, rd, a::IP0, 0, 0));
            self.emit(
                a::csel(
                    false,
                    0,
                    0,
                    rd,
                    a::IP0,
                    rd,
                    if signed {
                        a::GT;
                    } else {
                        a::HI;
                    },
                ),
            );
            if signed {
                self.mov_imm(a::IP0 as u8, ~hi & 0xFFFFFFFF, false);
                self.emit(a::addsub_reg(false, 1, true, a::ZR, rd, a::IP0, 0, 0));
                self.emit(a::csel(false, 0, 0, rd, a::IP0, rd, a::LT));
            }
        }
        return true;
    }

    // Conversions to and from i128: extensions and truncation inline, floats through compiler-rt.
    fn convert128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if op == O_SEXT || op == O_ZEXT {
            let fb = type_bits(from, self.ptr);
            let ra = self.reg(t.a) as u32;
            let lo = self.tmp(false);
            let hi = self.tmp(false);
            if op == O_SEXT {
                self.emit(
                    a::sxt(
                        true,
                        lo,
                        ra,
                        if fb == 64 {
                            64u32;
                        } else {
                            fb;
                        },
                    ),
                );
                self.emit(a::asr_imm(true, hi, lo, 63));
            } else {
                if fb == 64 {
                    self.emit(a::mov_reg(true, lo, ra));
                } else if fb == 32 {
                    self.emit(a::mov_reg(false, lo, ra));
                } else {
                    self.emit(a::uxt(lo, ra, fb));
                }
                self.emit(a::mov_reg(true, hi, a::ZR));
            }
            self.store128(i, lo, hi);
            return true;
        }
        if op == O_TRUNC {
            let (base, off) = self.mloc(t.a);
            let rd = self.def(i);
            self.mem(a::M_X, true, rd, base, off);
            return true;
        }
        if op == O_BITCAST {
            let (base, off) = self.mloc(t.a);
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, base, off, 16);
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
                // The offset joins the symbol's in its relocations.
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
        let ri = self.reg(t.b) as u32;
        let scale = t.aux as u32;
        let rd = self.def(i) as u32;
        // The index sign-extended to 64 bits.
        let mut idx = ri;
        if ib < 64 {
            self.emit(a::sxt(true, a::IP0, ri, ib));
            idx = a::IP0;
        }
        let rb = if base == a::SP || base == a::FP && boff != 0 {
            self.add_off(rd as u8, base, boff);
            rd;
        } else {
            base;
        };
        let roff = if base == a::SP || base == a::FP && boff != 0 {
            0;
        } else {
            boff;
        };
        if scale != 0 && (scale & scale - 1) == 0 && scale <= 16 {
            self.emit(a::addsub_reg(true, 0, false, rd, rb, idx, 0, scale.trailing_zeros() as u32));
        } else {
            self.mov_imm(a::IP1 as u8, scale, true);
            self.emit(a::madd(true, false, rd, idx, a::IP1, rb));
        }
        self.add_imm_any(rd as u8, roff + off);
        return true;
    }

    fn load(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        if self.lv.fold[i as usize] {
            let (rn, rm, sc) = self.folded(i);
            let rd = if Gen::in_vreg(ty) {
                self.vec_def(i);
            } else {
                self.def(i);
            };
            self.mem_ix(mkind(ty, true), true, rd, rn, rm, sc);
            self.va.index_mut(i as usize).clean = !Gen::is_v(ty) && type_bits(ty, self.ptr) < 64;
            return true;
        }
        let mut s: u32 = 0;
        let mut add: i64 = 0;
        if !Gen::in_mem(ty) && self.sym_mem(t.a, t.c as i32, type_bytes(ty, self.ptr), &mut s, &mut add) {
            let rd = self.def(i);
            self.mem_sym(mkind(ty, true), true, rd, s, add);
            self.va.index_mut(i as usize).clean = !Gen::is_v(ty) && type_bits(ty, self.ptr) < 64;
            return true;
        }
        let (base, off) = self.addr(t.a, t.c as i32);
        if Gen::in_vreg(ty) {
            let rd = self.vec_def(i);
            self.mem(mkind(ty, true), true, rd, base, off);
            return true;
        }
        if Gen::in_mem(ty) {
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, base, off, type_bytes(ty, self.ptr));
            return true;
        }
        let rd = self.def(i);
        self.mem(mkind(ty, true), true, rd, base, off);
        self.va.index_mut(i as usize).clean = !Gen::is_v(ty) && type_bits(ty, self.ptr) < 64;
        return true;
    }

    fn store(self: &mut Self, t: Inst) bool {
        let ty = self.vt(t.b);
        if self.lv.fold[self.cur as usize] {
            let (rn, rm, sc) = self.folded(self.cur);
            let mut k: u64 = 0;
            let r = if Gen::in_vreg(ty) {
                self.vec_use(t.b, V0 + 30);
            } else if !Gen::is_v(ty) && self.const_of(t.b, &mut k) && k == 0 {
                a::ZR as u8;
            } else {
                self.reg(t.b);
            };
            self.mem_ix(mkind(ty, false), false, r, rn, rm, sc);
            return true;
        }
        let mut s: u32 = 0;
        let mut add: i64 = 0;
        let sym = !Gen::in_mem(ty) && self.sym_mem(t.a, t.c as i32, type_bytes(ty, self.ptr), &mut s, &mut add);
        let mut base: u32 = 0;
        let mut off: i64 = 0;
        if !sym {
            let (b, o) = self.addr(t.a, t.c as i32);
            base = b;
            off = o;
        }
        if Gen::in_vreg(ty) {
            let r = self.vec_use(t.b, V0 + 30);
            self.mem(mkind(ty, false), false, r, base, off);
            return true;
        }
        if Gen::in_mem(ty) {
            let (sb, so) = self.mloc(t.b);
            self.copy_mem(base, off, sb, so, type_bytes(ty, self.ptr));
            return true;
        }
        let mut k: u64 = 0;
        let r = if !Gen::is_v(ty) && self.const_of(t.b, &mut k) && k == 0 {
            a::ZR as u8;
        } else {
            self.reg(t.b);
        };
        if sym {
            self.mem_sym(mkind(ty, false), false, r, s, add);
        } else {
            self.mem(mkind(ty, false), false, r, base, off);
        }
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
                let byte = if self.const_of(t.b, &mut k) {
                    k & 0xFF;
                } else {
                    0x100;
                };
                let src = if byte == 0 {
                    a::ZR as u8;
                } else if byte == 0x100 {
                    let rb = self.reg(t.b) as u32;
                    // Replicate the byte into every byte of x16.
                    self.emit(a::uxt(a::IP0, rb, 8));
                    self.mov_imm(a::IP1 as u8, 0x0101010101010101, true);
                    self.emit(a::mul(true, a::IP0, a::IP0, a::IP1));
                    a::IP0 as u8;
                } else {
                    self.mov_imm(a::IP0 as u8, byte * 0x0101010101010101, true);
                    a::IP0 as u8;
                };
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
                    self.mem(size_kind(step), false, src, db, doff + at as i64);
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
                let r = self.tmp(step == 16);
                self.mem(
                    if step == 16 {
                        a::M_VQ;
                    } else {
                        size_kind(step);
                    },
                    true,
                    r,
                    sb,
                    soff + at as i64,
                );
                regs.push(r);
                at += step;
            }
            at = 0;
            for q in 0..regs.len() {
                let left = n as u32 - at;
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
                self.mem(
                    if step == 16 {
                        a::M_VQ;
                    } else {
                        size_kind(step);
                    },
                    false,
                    regs[q],
                    db,
                    doff + at as i64,
                );
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
        return self.rt_call(i, name, vs, T_NONE);
    }

    fn select_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let cx = self.vx(t.a);
        let cc = if self.pend.inst == cx && self.pend.inst != NONE {
            self.pend.cc;
        } else {
            let rc = self.reg(t.a);
            self.emit(a::logic_imm(false, 3, a::ZR, rc, a::logical_imm(0xFF, false)));
            a::NE;
        };
        if Gen::in_mem(ty) {
            let (b1, o1) = self.mloc(t.b);
            let (b2, o2) = self.mloc(t.c);
            let ra = self.tmp(false);
            let rb = self.tmp(false);
            self.add_off(ra, b1, o1);
            self.add_off(rb, b2, o2);
            self.emit(a::csel(true, 0, 0, ra, ra, rb, cc));
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, ra, 0, type_bytes(ty, self.ptr));
            return true;
        }
        let rb = self.reg(t.b);
        let rc = self.reg(t.c);
        let rd = self.def(i);
        if Gen::is_v(ty) {
            self.emit(a::fcsel(ty == T_F64, rd - V0, rb - V0, rc - V0, cc));
        } else {
            self.emit(a::csel(true, 0, 0, rd, rb, rc, cc));
        }
        return true;
    }

    // `va_arg`: the next variadic argument from the `va_list` at `t.a`. Apple's is a pointer to 8-byte
    // stack slots; the standard one reads the save areas while their registers last, then the stack.
    fn va_arg(self: &mut Self, i: u32, t: Inst) bool {
        let ra = self.reg(t.a) as u32;
        let ty = t.ty;
        let ap = self.tmp(false);
        let sz = type_bytes(ty, self.ptr);
        let al16 = type_align(ty, self.ptr) == 16;
        if self.apple {
            self.mem(a::M_X, true, ap, ra, 0);
            if al16 {
                self.emit(a::add_imm(true, ap, ap, 15));
                self.emit(a::logic_imm(true, 0, ap, ap, a::logical_imm(~15u64, true)));
            }
        } else {
            self.va_std_addr(ty, ra, ap);
        }
        if Gen::in_mem(ty) {
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, ap, 0, sz);
        } else {
            let rd = self.def(i);
            self.mem(mkind(ty, true), true, rd, ap, 0);
        }
        if self.apple {
            self.emit(a::add_imm(true, ap, ap, sz + 7 & ~7u32));
            self.mem(a::M_X, false, ap, ra, 0);
        }
        return true;
    }

    // `ap` = the address of the next variadic argument of type `ty` in the standard `va_list` at `ra`
    // ({stack, gr_top, vr_top, gr_offs, vr_offs}), which moves past it.
    fn va_std_addr(self: &mut Self, ty: u8, ra: u32, ap: u8) {
        let sz = type_bytes(ty, self.ptr);
        let (vr, n, es, byref) = cc::va_place(self.b(), ty, self.ptr, self.vregs);
        let off = self.tmp(false);
        let field: u32 = if vr {
            28;
        } else {
            24;
        };
        let step = if vr {
            16 * n;
        } else {
            8 * n;
        };
        // From the save area while the offset stays at most 0 past the argument.
        self.mem(a::M_SW, true, off, ra, field);
        let w_stack = self.code.len() as u32;
        self.emit(a::tbz(false, off, 63, 0));
        if !vr && type_align(ty, self.ptr) == 16 {
            self.emit(a::add_imm(true, off, off, 15));
            self.emit(a::logic_imm(true, 0, off, off, a::logical_imm(~15u64, true)));
        }
        self.emit(a::add_imm(true, ap, off, step));
        self.mem(a::M_W, false, ap, ra, field);
        self.emit(a::cmp_imm(true, ap, 0));
        let w_over = self.code.len() as u32;
        self.emit(a::bcond(a::GT, 0));
        self.mem(
            a::M_X,
            true,
            ap,
            ra,
            if vr {
                16i64;
            } else {
                8i64;
            },
        );
        self.emit(a::addsub_reg(true, 0, false, ap, ap, off, 0, 0));
        if vr && n > 1 {
            // One element per 16-byte register slot: gather them into a slot.
            let g = self.slot_alloc(sz, 16);
            for k in 0..n {
                self.copy_mem(a::SP, g + k * es, ap, 16 * k, es);
            }
            self.add_off(ap, a::SP, g);
        }
        let w_done = self.code.len() as u32;
        self.emit(a::b(0));
        // From the stack: 8-byte slots, 16-aligned for a 16-byte alignment.
        self.here(w_stack);
        self.here(w_over);
        self.mem(a::M_X, true, ap, ra, 0);
        if type_align(ty, self.ptr) == 16 && !byref {
            self.emit(a::add_imm(true, ap, ap, 15));
            self.emit(a::logic_imm(true, 0, ap, ap, a::logical_imm(~15u64, true)));
        }
        let used = if byref {
            8;
        } else {
            sz + 7 & ~7u32;
        };
        self.emit(a::add_imm(true, off, ap, used));
        self.mem(a::M_X, false, off, ra, 0);
        self.here(w_done);
        if byref {
            self.mem(a::M_X, true, ap, ap, 0);
        }
    }

    // Atomic loads, stores, read-modify-writes, compare-and-swaps and fences (LSE).
    fn atomic(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op == O_FENCE {
            if (t.aux & 7) != MO_RELAXED {
                self.emit(a::DMB_ISH);
            }
            return true;
        }
        let ty = if op == O_ALOAD || op == O_ARMW {
            t.ty;
        } else {
            self.vt(t.b);
        };
        assert(!Gen::in_mem(ty) && !Gen::is_v(ty), "a64gen: an atomic access of a type the verifier rejects");
        let size = type_bytes(ty, self.ptr).trailing_zeros() as u32;
        let ord = t.aux & 7;
        let acq = ord == MO_ACQUIRE || ord == MO_ACQ_REL || ord == MO_SEQ_CST;
        let rel = ord == MO_RELEASE || ord == MO_ACQ_REL || ord == MO_SEQ_CST;
        // The address in a register.
        let (base, off) = self.addr(
            t.a,
            if op == O_ACAS {
                0;
            } else {
                t.c as i32;
            },
        );
        let rp = if base == a::SP || base == a::FP || off != 0 {
            self.add_off(a::IP1 as u8, base, off);
            a::IP1;
        } else {
            base;
        };
        if op == O_ALOAD {
            let rd = self.def(i) as u32;
            if acq {
                self.emit(a::ldar(size, true, rd, rp));
            } else {
                self.emit(a::ldst_uimm(size_kind(1u32 << size), true, rd, rp, 0));
            }
            return true;
        }
        if op == O_ASTORE {
            let rv = self.reg(t.b) as u32;
            if rel {
                self.emit(a::ldar(size, false, rv, rp));
            } else {
                self.emit(a::ldst_uimm(size_kind(1u32 << size), false, rv, rp, 0));
            }
            return true;
        }
        if op == O_ARMW {
            let r = t.aux >> 4;
            let rv = self.reg(t.b) as u32;
            let rd = self.def(i) as u32;
            let mut src = rv;
            let opc = if r == RMW_XCHG {
                a::LSE_SWP;
            } else if r == RMW_ADD {
                a::LSE_ADD;
            } else if r == RMW_SUB {
                self.emit(a::addsub_reg(true, 1, false, a::IP0, a::ZR, rv, 0, 0));
                src = a::IP0;
                a::LSE_ADD;
            } else if r == RMW_AND {
                self.emit(a::logic_reg(true, 1, true, a::IP0, a::ZR, rv, 0, 0));
                src = a::IP0;
                a::LSE_CLR;
            } else if r == RMW_OR {
                a::LSE_SET;
            } else {
                a::LSE_EOR;
            };
            self.emit(a::lse(size, opc, acq, rel, src, rd, rp));
            return true;
        }
        // Compare and swap: x16 takes the expected value and receives the old one.
        // A failure order stronger than the success order strengthens it, as C does.
        let fo = t.aux >> 3 & 7;
        let acq2 = acq || fo == MO_ACQUIRE || fo == MO_SEQ_CST;
        let rel2 = rel || fo == MO_SEQ_CST;
        let re = self.reg(t.b) as u32;
        let rn = self.reg(t.c) as u32;
        let rd = self.def(i) as u32;
        self.emit(a::mov_reg(true, a::IP0, re));
        self.emit(a::cas(size, acq2, rel2, a::IP0, rn, rp));
        let sf = size == 3;
        if size < 2 {
            self.emit(a::addsub_ext(false, 1, true, a::ZR, a::IP0, re, size, 0));
        } else {
            self.emit(a::addsub_reg(sf, 1, true, a::ZR, a::IP0, re, 0, 0));
        }
        self.emit(a::cset(false, rd, a::EQ));
        self.va.index_mut(i as usize).clean = true;
        return true;
    }
}

// `x`'s low `bits` bits sign-extended.
const fn lp_sext(x: u64, bits: u32) i64 {
    if bits >= 64 {
        return x as i64;
    }
    let s = 64 - bits;
    return (x << s as u64) as i64 >> s as i64;
}

// A branch condition: the flags (`cc`), or a register compared with zero (`cbz`, `cbnz`).
struct Test {
    pub kind: u8, // T_CC, T_CBZ, T_CBNZ
    pub cc: u32,
    pub reg: u32,
}

extend Test as Copy {}

const T_CC: u8 = 0;
const T_CBZ: u8 = 1;
const T_CBNZ: u8 = 2;

const fn invert_test(t: Test) Test {
    if t.kind == T_CC {
        return Test { kind: T_CC, cc: a::invert(t.cc), reg: 0 };
    }
    return Test {
        kind: if t.kind == T_CBZ {
            T_CBNZ;
        } else {
            T_CBZ;
        },
        cc: 0,
        reg: t.reg,
    };
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
        let mut m = self.held & ~(XFIX | vfix()) & self.clob;
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            let x = self.owner[r as usize];
            if self.va[x as usize].home == H_FIXED {
                continue;
            }
            let mut kept = false;
            for k in 0..keep.len() {
                kept = kept || keep[k] == x;
            }
            let mut used = self.live_on(x);
            for k in 0..self.uses.len() {
                used = used || !kept && self.vx(self.uses[k]) == x;
            }
            if used {
                self.spill(x);
            }
            if !kept {
                self.va.index_mut(x as usize).reg = NOREG;
                self.va.index_mut(x as usize).dirty = false;
                self.set_owner(r, NONE);
            }
        }
        self.lock = 0;
        self.tmps = 0;
    }

    // After a call's arguments are in place: the caller-saved registers hold no value.
    fn forget_caller_saved(self: &mut Self) {
        let mut m = self.held & ~(XFIX | vfix()) & self.clob;
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            let x = self.owner[r as usize];
            if self.va[x as usize].home == H_FIXED {
                continue;
            }
            self.va.index_mut(x as usize).reg = NOREG;
            self.va.index_mut(x as usize).dirty = false;
            self.set_owner(r, NONE);
        }
    }

    fn call(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let sig = t.b;
        let np = b.pool[sig as usize];
        let rt = b.pool[sig as usize + 2];
        self.call_layout(t);
        self.clob = ~0u64;
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a);
        } else {
            "";
        };
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
                self.clob |= 1u64 << (pa.reg + if pa.v {
                    V0;
                } else {
                    0;
                }) as u64;
            }
            let mut j: usize = 0;
            while j < tx.len() {
                let st = j;
                while j < tx.len() {
                    let ch = tx.byte_at(j);
                    if !(ch >= b'a' && ch <= b'z' || ch >= b'0' && ch <= b'9') {
                        break;
                    }
                    j += 1;
                }
                if j > st {
                    let r = clobber_reg(tx.slice(st, j));
                    if r != NOREG {
                        self.clob |= 1u64 << r as u64;
                    }
                } else {
                    j += 1;
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
            ok = ok && !intrin::vlisted(tx, pr);
            if ok && intrin::vwrites(true, tx, pr) {
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
            let free = valloc() & ~taken & ~self.held;
            let pr = self.lay.parts[rl.p0 as usize].reg as u32;
            if free != 0 && !intrin::vlisted(tx, pr) {
                let f = free.trailing_zeros() as u8;
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
            intrin::vrename(true, tx, from[0..from.len()], to[0..to.len()], &mut renamed);
            text = renamed;
            if rres != NOREG {
                self.clob |= bit(rres);
            }
        }
        // The scalar register arguments in registers stay there: one parallel move takes them to the
        // argument registers. A value the call also reads otherwise (an aggregate's address, the callee,
        // the result's address) is read from its home after the move, which may take its register.
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
        // Stack arguments first: they read registers the register arguments then overwrite.
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            let agg = (pt & AGG) != 0;
            let vty = self.vt(v);
            if loc.kind == ab::L_STACK {
                if agg {
                    let rp = self.tmp(false);
                    self.materialize(v, rp);
                    self.copy_mem(a::SP, loc.off, rp, 0, loc.size);
                } else if Gen::in_mem(vty) {
                    let (base, off) = self.mloc(v);
                    self.copy_mem(a::SP, loc.off, base, off, loc.size);
                } else {
                    let r = self.tmp(Gen::is_v(vty));
                    self.materialize(v, r);
                    self.mem(mkind(vty, false), false, r, a::SP, loc.off);
                }
            } else if loc.kind == ab::L_REF_STACK {
                let r = self.tmp(false);
                self.ref_arg(v, agg, r);
                self.mem(a::M_X, false, r, a::SP, loc.off);
            }
        }
        // The scalars from registers and homes as one parallel move; a narrow one then extends in place.
        self.mv.truncate(0);
        let mut moved = Vector::<bool>::with_capacity(np as usize);
        let mut clean = Vector::<bool>::with_capacity(np as usize);
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let vty = self.vt(v);
            let x = self.vx(v);
            let va = self.va[x as usize];
            let src = self.loc_of(x);
            let mv = loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!Gen::in_mem(vty) || self.vec_in_reg(
                loc,
                vty,
            )) && src.kind != LC_VAL;
            moved.push(mv);
            if ren[k as usize] {
                // Read where it is.
                clean.push(false);
                continue;
            }
            clean.push(va.reg != NOREG && va.clean || va.reg == NOREG && (va.home == H_SLOT || va.home == H_ARG));
            if !mv {
                continue;
            }
            let pa = self.lay.parts[loc.p0 as usize];
            self.mv.push(
                Mv {
                    src: src,
                    dst: Lc {
                        kind: LC_REG,
                        reg: if pa.v && pa.reg as u32 == rmov {
                            rres;
                        } else if pa.v {
                            pa.reg + V0;
                        } else {
                            pa.reg;
                        },
                        off: 0,
                        val: NONE,
                    },
                    v: pa.v,
                    bytes: type_bytes(vty, self.ptr),
                    done: false,
                },
            );
        }
        self.resolve_moves();
        // The moved values' registers now hold arguments.
        self.forget_caller_saved();
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            let agg = (pt & AGG) != 0;
            let vty = self.vt(v);
            if moved[k as usize] {
                // Moved: only a narrow integer's extension is left.
                let r = self.lay.parts[loc.p0 as usize].reg;
                if loc.ext == 2 {
                    self.emit(a::sxt(false, r, r, type_bits(vty, self.ptr)));
                } else if loc.ext != 0 && !clean[k as usize] {
                    self.emit(a::uxt(r, r, type_bits(vty, self.ptr)));
                }
                continue;
            }
            if loc.kind == ab::L_REF_REG {
                self.ref_arg(v, agg, self.lay.parts[loc.p0 as usize].reg);
            } else if loc.kind == ab::L_REG {
                if agg {
                    self.materialize(v, a::IP1 as u8);
                    for q in 0..loc.n as u32 {
                        let pa = self.lay.parts[(loc.p0 + q) as usize];
                        self.load_part(pa, a::IP1, pa.off);
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
        }
        if self.lay.ret.kind == ab::L_SRET {
            if (rt & AGG) != 0 {
                self.materialize(b.pool[(t.c + np) as usize], 8);
            } else {
                let d = self.mdef(i);
                self.add_off(8, a::SP, d);
            }
        }
        if t.op == O_CALL {
            if tpl.len() != 0 {
                // An intrinsic: its instructions in place of the call, over the same registers.
                let mut rels = Vector::<asmr::InlRel>::new();
                let mut e = String::new();
                if !asmr::Asm::inline_a64(text.as_str(), self.apple, &mut self.code, &mut rels, &mut e) {
                    self.err.format_into("intrinsic: {}", e.as_str());
                    return false;
                }
                assert(rels.len() == 0, "a64: an intrinsic's instructions name no symbol");
            } else {
                let os = self.osym_of(t.a);
                self.reloc(a::R_BRANCH26, os, 0);
                self.emit(a::bl(0));
            }
        } else {
            self.materialize(t.a, a::IP0 as u8);
            self.emit(a::blr(a::IP0));
        }
        if rl.kind != ab::L_REG {
            return true;
        }
        if (rt & AGG) != 0 {
            self.materialize(b.pool[(t.c + np) as usize], a::IP1 as u8);
            for q in 0..rl.n as u32 {
                let pa = self.lay.parts[(rl.p0 + q) as usize];
                self.store_part(pa, a::IP1, pa.off);
            }
            return true;
        }
        if self.vec_in_reg(rl, t.ty) {
            let x = self.vx(i);
            if self.live_on(x) {
                self.bind(
                    x,
                    if rres != NOREG {
                        rres;
                    } else {
                        self.lay.parts[rl.p0 as usize].reg + V0;
                    },
                );
            }
            return true;
        }
        if Gen::in_mem(t.ty) {
            let d = self.mdef(i);
            for q in 0..rl.n as u32 {
                let pa = self.lay.parts[(rl.p0 + q) as usize];
                self.store_part(pa, a::SP, d + pa.off as i64);
            }
            return true;
        }
        let x = self.vx(i);
        if !self.live_on(x) {
            return true;
        }
        let pa = self.lay.parts[rl.p0 as usize];
        let r = pa.reg + if pa.v {
            V0;
        } else {
            0;
        };
        if self.fix_class(x) != FIX_NONE {
            let rd = self.def(i);
            self.move_reg(t.ty, rd, r);
        } else {
            self.bind(x, r);
        }
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

    // The argument and result locations of call `t` (`lay`): an intrinsic's (`abi::intrinsic_layout`),
    // else the convention's.
    fn call_layout(self: &mut Self, t: Inst) {
        let b = self.b();
        if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
            let gp: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
            ab::intrinsic_layout(b, t.b, self.ptr, gp[0..8], 0, &mut self.lay);
            return;
        }
        cc::classify(b, t.b, self.ptr, self.apple, self.vregs, &mut self.lay);
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
            "aarch64",
            if nm.starts_with("__sc_x_") {
                nm.slice(7, nm.len());
            } else {
                nm;
            },
        );
    }

    // Register `r` = the pointer argument passing value `v` by reference: an aggregate's pointer, or the
    // address of a fresh copy of a memory value.
    fn ref_arg(self: &mut Self, v: Value, agg: bool, r: u8) {
        if agg {
            self.materialize(v, r);
            return;
        }
        let sz = type_bytes(self.vt(v), self.ptr);
        let (base, off) = self.mloc(v);
        let c = self.slot_alloc(sz, 16);
        self.copy_mem(a::SP, c, base, off, sz);
        self.add_off(r, a::SP, c);
    }

    // A call of C function `name` with the integer or pointer values `vs` in x0.. and no result.
    fn rt_call(self: &mut Self, i: u32, name: str, vs: []Value, rty: u8) bool {
        let _ = i;
        let _ = rty;
        self.spill_for_call();
        for k in 0..vs.len() {
            self.materialize(vs[k], k as u8);
        }
        let os = self.obj().sym(name);
        self.reloc(a::R_BRANCH26, os, 0);
        self.emit(a::bl(0));
        return true;
    }

    // A call of compiler-rt routine `name` for instruction `i`: the i128 or float values `x` and `y`
    // (VNONE: none) in x0..x3 or v0; an i128 result from x0 and x1 into its slot, a float one from v0.
    fn rt_call128(self: &mut Self, i: u32, name: str, x: Value, y: Value) bool {
        self.spill_for_call();
        let mut gr: u8 = 0;
        for k in 0..2 {
            let v = if k == 0 {
                x;
            } else {
                y;
            };
            if v == VNONE {
                continue;
            }
            let ty = self.vt(v);
            if ty == T_I128 {
                let (base, off) = self.mloc(v);
                self.mem(a::M_X, true, gr, base, off);
                self.mem(a::M_X, true, gr + 1, base, off + 8);
                gr += 2;
            } else {
                self.materialize(
                    v,
                    if Gen::is_v(ty) {
                        V0;
                    } else {
                        gr;
                    },
                );
                if !Gen::is_v(ty) {
                    gr += 1;
                }
            }
        }
        let os = self.obj().sym(name);
        self.reloc(a::R_BRANCH26, os, 0);
        self.emit(a::bl(0));
        let ty = self.b().insts[i as usize].ty;
        if ty == T_I128 {
            let d = self.mdef(i);
            self.mem(a::M_X, false, 0, a::SP, d);
            self.mem(a::M_X, false, 1, a::SP, d + 8);
        } else {
            let x2 = self.vx(i);
            if self.live_on(x2) {
                if self.fix_class(x2) != FIX_NONE {
                    let rd = self.def(i);
                    self.move_reg(
                        ty,
                        rd,
                        if Gen::is_v(ty) {
                            V0;
                        } else {
                            0;
                        },
                    );
                } else {
                    self.bind(
                        x2,
                        if Gen::is_v(ty) {
                            V0;
                        } else {
                            0;
                        },
                    );
                }
            }
        }
        return true;
    }

    // The test of condition value `v` (index `cx`): the flags an instruction left for it, a register
    // with clean upper bits against zero, or its low byte.
    fn cond_test(self: &mut Self, cx: u32, v: Value) Test {
        if self.pend.inst == cx && self.pend.inst != NONE {
            return Test { kind: T_CC, cc: self.pend.cc, reg: 0 };
        }
        let r = self.reg(v) as u32;
        if self.va[cx as usize].clean {
            return Test { kind: T_CBNZ, cc: 0, reg: r };
        }
        self.emit(a::logic_imm(false, 3, a::ZR, r, a::logical_imm(0xFF, false)));
        return Test { kind: T_CC, cc: a::NE, reg: 0 };
    }

    // A conditional branch on `test` to block `k`.
    fn cbranch(self: &mut Self, test: Test, k: u32) {
        if self.far {
            let w = self.code.len() as u32;
            self.emit_test(invert_test(test));
            self.fix.push(self.code.len() as u64 << 32 | k as u64);
            self.emit(a::b(0));
            self.here(w);
            return;
        }
        self.fix.push(self.code.len() as u64 << 32 | k as u64);
        self.emit_test(test);
    }

    // The branch word of `test` with no displacement yet.
    fn emit_test(self: &mut Self, test: Test) {
        if test.kind == T_CC {
            self.emit(a::bcond(test.cc, 0));
        } else {
            self.emit(a::cbz(false, test.kind == T_CBNZ, test.reg, 0));
        }
    }

    // Jump to block `k` (nothing when it follows, unless `force`).
    fn goto(self: &mut Self, k: u32, force: bool) {
        let q = self.pos as usize + 1;
        if !force && q < self.lv.order.len() && self.lv.order[q] == k {
            return;
        }
        self.fix.push(self.code.len() as u64 << 32 | k as u64);
        self.emit(a::b(0));
    }

    // Patch the local branch at word `w` to the next word.
    const fn here(self: &mut Self, w: u32) {
        let off = ((self.code.len() as u32 - w) * 4) as i32;
        self.code[w as usize] = a::repatch(self.code[w as usize], off);
    }

    // A two-way branch: `test` takes edge `et`, else `ef`; each edge's moves on its own path.
    fn branch2(self: &mut Self, test: Test, et: u32, ef: u32) {
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
                self.cbranch(invert_test(test), tf);
            } else {
                self.cbranch(test, tt);
                self.goto(tf, false);
            }
        } else if mt && !mf {
            self.cbranch(invert_test(test), tf);
            self.edge_moves(et);
            self.goto(tt, false);
        } else if !mt && mf {
            self.cbranch(test, tt);
            self.edge_moves(ef);
            self.goto(tf, false);
        } else {
            let w = self.code.len() as u32;
            self.emit_test(test);
            self.edge_moves(ef);
            self.goto(tf, true);
            self.here(w);
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
            let test = self.cond_test(cx, t.a);
            self.spill_live_out();
            self.branch2(test, t.b, t.c);
            return true;
        }
        if op == O_SWITCH {
            let ty = self.vt(t.a);
            let bits = type_bits(ty, self.ptr);
            let sf = bits == 64;
            let r = if bits < 32 {
                self.ext(t.a, false, bits);
            } else {
                self.reg(t.a);
            } as u32;
            self.spill_live_out();
            let n = t.aux as u32;
            let mut stubs = Vector::<u64>::new();
            for k in 0..n {
                let mut c = b.words[(t.b + k) as usize];
                if bits < 64 {
                    c &= (1u64 << bits as u64) - 1;
                }
                if c < 4096 {
                    self.emit(a::cmp_imm(sf, r, c as u32));
                } else {
                    self.mov_imm(a::IP0 as u8, c, sf);
                    self.emit(a::addsub_reg(sf, 1, true, a::ZR, r, a::IP0, 0, 0));
                }
                let e = b.switch_edge(t, k);
                if b.edge_nargs(e) == 0 {
                    self.cbranch(Test { kind: T_CC, cc: a::EQ, reg: 0 }, b.edge_target(e));
                } else {
                    stubs.push(self.code.len() as u64 << 32 | e as u64);
                    self.emit(a::bcond(a::EQ, 0));
                }
            }
            let d = b.switch_edge(t, n);
            self.edge_moves(d);
            self.goto(b.edge_target(d), stubs.len() != 0);
            for k in 0..stubs.len() {
                self.here((stubs[k] >> 32) as u32);
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
                // The lowest set lane of the mask: its trailing zeros.
                let r = self.reg(t.b) as u32;
                self.emit(a::dp1(true, a::DP1_RBIT, 0, r));
                self.emit(a::dp1(true, a::DP1_CLZ, 0, 0));
                self.lane_panic_call(m);
            }
            return true;
        }
        if op == O_UNREACHABLE {
            self.emit(a::brk(1));
            return true;
        }
        let _ = i;
        assert(false, "a64gen: a terminator the verifier rejects");
        return false;
    }

    // Return: the result into its registers, then the epilogue.
    fn ret(self: &mut Self, t: Inst) {
        let b = self.b();
        let rl = self.self_lay.ret;
        let rt = b.pool[b.sig as usize + 2];
        if rl.kind == ab::L_REG {
            if (rt & AGG) != 0 {
                let np = b.pool[b.sig as usize];
                let pv = VPARAM | b.blocks[0].param_start + np;
                let (base, off) = self.addr(pv, 0);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
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
        } else if self.sret_off >= 0 {
            let p = self.tmp(false);
            self.mem(a::M_X, true, p, a::SP, self.sret_off);
            let (base, off) = self.mloc(t.a);
            self.copy_mem(p, 0, base, off, type_bytes(self.vt(t.a), self.ptr));
        }
        self.epi.push(self.code.len() as u32);
        self.emit(a::b(0));
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

    // A call of `__sc_panic` with C string `text`.
    fn panic_text(self: &mut Self, text: str) {
        let os = self.cstr(text);
        self.reloc(a::R_PAGE21, os, 0);
        self.emit(a::adr(true, 0, 0));
        self.reloc(a::R_PAGEOFF12, os, 0);
        self.emit(a::add_imm(true, 0, 0, 0));
        let ps = self.obj().sym("__sc_panic");
        self.reloc(a::R_BRANCH26, ps, 0);
        self.emit(a::bl(0));
    }

    // ---- Prologue, epilogue and output ----

    // Frame the body's code and define function symbol `s` with it.
    fn finish(self: &mut Self, s: u32) bool {
        // A last branch to the epilogue falls through instead.
        let nc = self.code.len() as u32;
        if self.epi.len() != 0 && self.epi[self.epi.len() - 1] == nc - 1 {
            let _ = self.epi.pop();
            self.code.truncate(nc as usize - 1);
        }
        let mut local = self.spill_base + self.spill_top + 15 & ~15u32;
        if self.max_align > 16 {
            local = local + self.max_align - 1 & ~(self.max_align - 1);
        }
        let mut pro = Vector::<u32>::new();
        pro.push(a::ldstp(a::M_X, false, 3, a::FP, a::LR, a::SP, -16));
        pro.push(a::add_imm(true, a::FP, a::SP, 0));
        // The callee-saved registers in the pairs compact unwind names (x19/x20 to x27/x28, d8/d9 to
        // d14/d15), both of a pair when the body uses one: each pair below the last, its lower register 8
        // bytes higher (x19 at x29 - 8), as libunwind reads a frame. `xs` and `vs` hold each pair's lower
        // register.
        let mut xs = Vector::<u32>::new();
        let mut vs = Vector::<u32>::new();
        let mut enc: u32 = 0x04000000;
        for q in 0..5u32 {
            if (self.csr >> (19 + 2 * q) as u64 & 3) != 0 {
                xs.push(19 + 2 * q);
                enc |= 1u32 << q;
            }
        }
        for q in 0..4u32 {
            if (self.csr >> (40 + 2 * q) as u64 & 3) != 0 {
                vs.push(8 + 2 * q);
                enc |= 0x100u32 << q;
            }
        }
        for k in 0..xs.len() {
            pro.push(a::ldstp(a::M_X, false, 3, xs[k] + 1, xs[k], a::SP, -16));
        }
        for k in 0..vs.len() {
            pro.push(a::ldstp(a::M_VD, false, 3, vs[k] + 1, vs[k], a::SP, -16));
        }
        let csr_bytes = 16 * (xs.len() + vs.len()) as u32;
        // The locals, a page at a time past 4 KiB so each guard page is touched.
        let mut left = local;
        while left >= 4096 {
            pro.push(a::sub_imm(true, a::SP, a::SP, 4095));
            pro.push(a::sub_imm(true, a::SP, a::SP, 1));
            pro.push(a::ldst_uimm(a::M_X, false, a::ZR, a::SP, 0));
            left -= 4096;
        }
        if left != 0 {
            pro.push(a::sub_imm(true, a::SP, a::SP, left));
        }
        if self.max_align > 16 {
            pro.push(a::mov_sp(a::IP1, a::SP));
            pro.push(a::logic_imm(true, 0, a::SP, a::IP1, a::logical_imm(~(self.max_align as u64 - 1), true)));
        }
        let pl = pro.len() as u32;
        let body_n = self.code.len() as u32;
        // The epilogue.
        let mut epi = Vector::<u32>::new();
        if csr_bytes != 0 {
            epi.push(a::sub_imm(true, a::SP, a::FP, csr_bytes));
        } else {
            epi.push(a::mov_sp(a::SP, a::FP));
        }
        let mut k = vs.len();
        while k > 0 {
            k -= 1;
            epi.push(a::ldstp(a::M_VD, true, 1, vs[k] + 1, vs[k], a::SP, 16));
        }
        k = xs.len();
        while k > 0 {
            k -= 1;
            epi.push(a::ldstp(a::M_X, true, 1, xs[k] + 1, xs[k], a::SP, 16));
        }
        epi.push(a::ldstp(a::M_X, true, 1, a::FP, a::LR, a::SP, 16));
        epi.push(a::RET);
        // Branches.
        for q in 0..self.fix.len() {
            let w = (self.fix[q] >> 32) as u32;
            let blk = self.fix[q] as u32;
            let off = (self.blk_at[blk as usize] as i64 - w as i64) * 4;
            if !a::reaches(self.code[w as usize], off) {
                // A conditional one makes `func` try again with every one over a `B`.
                return self.far && self.refuse("a branch out of range");
            }
            self.code[w as usize] = a::repatch(self.code[w as usize], off as i32);
        }
        for q in 0..self.epi.len() {
            let w = self.epi[q];
            self.code[w as usize] = a::repatch(self.code[w as usize], ((body_n - w) * 4) as i32);
        }
        // Into the object.
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let size = (pl + body_n + epi.len() as u32) * 4;
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
        let at = o.define(k2, sec, 2, size, fl);
        put_words(o, sec, &pro);
        put_words(o, sec, &self.code);
        put_words(o, sec, &epi);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + (pl + r.at) * 4, r.sym, r.addend);
        }
        if self.elf {
            frame_rules(o, k2, size, &xs, &vs);
        } else {
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: 0, cfi_len: 0, compact: enc });
        }
        if p.debug {
            dw::rows(o, self.b(), k2, size, pl * 4, &self.rows, body_n, 4);
        }
        return true;
    }

    // A naked function: its templates' code alone.
    fn naked(self: &mut Self, s: u32) bool {
        let b = self.b();
        for i in 0..b.insts.len() {
            if b.insts[i].op != O_ASM {
                continue;
            }
            let mut rels = Vector::<asmr::InlRel>::new();
            let mut e = String::new();
            let tpl = String::from_str(self.msg_text(asm_template(b, b.insts[i].c)));
            if !asmr::Asm::inline_a64(tpl.as_str(), self.apple, &mut self.code, &mut rels, &mut e) {
                self.err.format_into("inline assembly: {}", e.as_str());
                return false;
            }
            for k in 0..rels.len() {
                let sym = self.obj().sym(rels[k].name.as_str());
                self.rels.push(CRel { at: rels[k].at, kind: rels[k].kind, sym: sym, addend: rels[k].addend });
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
        let at = o.define(k2, sec, 2, self.code.len() as u64 * 4, fl);
        put_words(o, sec, &self.code);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + r.at * 4, r.sym, r.addend);
        }
        return true;
    }

    /// Define package data symbol `s` in the object.
    pub fn data(self: &mut Self, s: u32, local: bool) bool {
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let d = p.data[ps.def as usize];
        let tls = ps.kind == SK_TLS;
        let mut zero = d.nrelocs == 0;
        for j in 0..d.nbytes {
            zero = zero && p.bytes[(d.bytes + j) as usize] == 0;
        }
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
        for j in 0..bs.len() {
            let one: [u8; 1] = [bs[j]];
            o.put(sec, one);
        }
        o.pad_to(sec, at + d.size as u64);
        for j in 0..d.nrelocs {
            let r = p.relocs[(d.relocs + j) as usize];
            let ks = o.sym(p.spell(p.syms[r.sym as usize].name));
            o.reloc(sec, a::R_ABS64, (at + r.offset as u64) as u32, ks, r.addend);
        }
        return true;
    }
}

// The unwind rules of function `sym` (`size` bytes) for `.eh_frame`, after the prologue's `stp x29, x30,
// [sp, #-16]!` (the CFA is sp + 16, x29 at CFA - 16, x30 at CFA - 8), `mov x29, sp` (the CFA is x29 +
// 16) and the pushes of the callee-saved pairs whose lower registers are `xs` and `vs` (16 bytes each
// below x29, the lower register 8 bytes higher). The common entry's code alignment is 4 bytes and its
// data alignment -8.
fn frame_rules(o: &mut ob::Obj, sym: u32, size: u32, xs: &Vector<u32>, vs: &Vector<u32>) {
    let c0 = o.cfi.len() as u32;
    o.cfi.push(0x40 | 1);
    o.cfi.push(0x0E);
    o.cfi.push(16);
    o.cfi.push(0x80 | a::FP as u8);
    o.cfi.push(2);
    o.cfi.push(0x80 | a::LR as u8);
    o.cfi.push(1);
    o.cfi.push(0x40 | 1);
    o.cfi.push(0x0D);
    o.cfi.push(a::FP as u8);
    let nx = xs.len() as u32;
    let npush = nx + vs.len() as u32;
    if npush != 0 {
        o.cfi.push(0x40 | npush as u8);
        // Pair q stores its lower register at CFA - 24 - 16 q, its upper one 8 bytes below.
        for k in 0..nx {
            o.cfi.push(0x80 | xs[k as usize] as u8);
            o.cfi.push((3 + 2 * k) as u8);
            o.cfi.push(0x80 | (xs[k as usize] + 1) as u8);
            o.cfi.push((4 + 2 * k) as u8);
        }
        for k in 0..vs.len() as u32 {
            // DW_CFA_offset_extended: the DWARF numbers of v0..v31 are 64..95.
            o.cfi.push(0x05);
            o.cfi.push((64 + vs[k as usize]) as u8);
            o.cfi.push((3 + 2 * (nx + k)) as u8);
            o.cfi.push(0x05);
            o.cfi.push((65 + vs[k as usize]) as u8);
            o.cfi.push((4 + 2 * (nx + k)) as u8);
        }
    }
    o.frames.push(ob::OFrame { sym: sym, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0, compact: 0 });
}

// Append `ws` to code section `sec` as little-endian words.
fn put_words(o: &mut ob::Obj, sec: u8, ws: &Vector<u32>) {
    for i in 0..ws.len() {
        let w = ws[i];
        let bs: [u8; 4] = [(w & 0xFF) as u8, (w >> 8 & 0xFF) as u8, (w >> 16 & 0xFF) as u8, (w >> 24) as u8];
        o.put(sec, bs);
    }
}

// ---- Vectors ----
//
// A vector lives in its slot. An element-wise operation NEON has runs 16 bytes at a time (8 for a vector
// of 8 bytes) in v30 and v31; any other runs lane by lane on temporaries: an integer lane zero-extended,
// or sign-extended for a signed rule, to 64 bits, a float lane in a v register. Mask results gather one
// bit per lane; a lane that traps sets a failure register tested after the lanes.

// The load kind of a lane of `lt`: a float into a v register; an integer zero-extended, or sign-extended
// (`sg`), to 64 bits; with `raw` any lane's bits into an x register.
const fn lane_ld(lt: u8, sg: bool, raw: bool) u32 {
    let n = type_bytes(lt, 8);
    if is_float(lt) && !raw {
        return mkind(lt, true);
    }
    if n == 8 {
        return a::M_X;
    }
    if sg && n == 1 {
        return a::M_SB;
    }
    if sg && n == 2 {
        return a::M_SH;
    }
    if sg {
        return a::M_SW;
    }
    return int_kind(n);
}

// The store kind of a lane of `lt`: from a v register for a float, else (or with `raw`) the low bytes of
// an x register.
const fn lane_st(lt: u8, raw: bool) u32 {
    if is_float(lt) && !raw {
        return mkind(lt, false);
    }
    return int_kind(type_bytes(lt, 8));
}

// The x register load or store kind of `n` (1, 2, 4 or 8) bytes.
const fn int_kind(n: u32) u32 {
    if n == 1 {
        return a::M_B;
    }
    if n == 2 {
        return a::M_H;
    }
    if n == 4 {
        return a::M_W;
    }
    return a::M_X;
}

// The NEON size field of integer lanes of `eb` bytes.
const fn vsize(eb: u32) u32 {
    return eb.trailing_zeros() as u32;
}

// The NEON instruction (8 bytes, registers 0) of element-wise LIR operation `op` on lanes of `lt`, NONE
// without one; `un` set for one operand.
const fn neon_of_op(op: u8, lt: u8, un: &mut bool) u32 {
    let eb = type_bytes(lt, 8);
    let s = vsize(eb);
    let sz = (lt == T_F64) as u32;
    *un = op == O_NOT || op == O_NEG || op == O_FNEG;
    if op == O_ADD {
        return a::v3op(false, a::V3_ADD, s, 0, 0, 0);
    }
    if op == O_SUB {
        return a::v3op(false, a::V3_SUB, s, 0, 0, 0);
    }
    if op == O_MUL && eb < 8 {
        return a::v3op(false, a::V3_MUL, s, 0, 0, 0);
    }
    if op == O_AND {
        return a::v3op(false, a::V3_AND, 0, 0, 0, 0);
    }
    if op == O_OR {
        return a::v3op(false, a::V3_AND, 2, 0, 0, 0);
    }
    if op == O_XOR {
        return a::v3op(false, a::V3_EOR, 0, 0, 0, 0);
    }
    if op == O_NOT {
        return a::v2op(false, a::V2_NOT, 0, 0, 0);
    }
    if op == O_NEG {
        return a::v2op(false, a::V2_NEG, s, 0, 0);
    }
    if op == O_FADD {
        return a::v3op(false, a::V3_FADD, sz, 0, 0, 0);
    }
    if op == O_FSUB {
        return a::v3op(false, a::V3_FSUB, 2 | sz, 0, 0, 0);
    }
    if op == O_FMUL {
        return a::v3op(false, a::V3_FMUL, sz, 0, 0, 0);
    }
    if op == O_FDIV {
        return a::v3op(false, a::V3_FDIV, sz, 0, 0, 0);
    }
    if op == O_FNEG {
        return a::v2op(false, a::V2_FNEG, 2 | sz, 0, 0);
    }
    return NONE;
}

// The NEON instruction (as `neon_of_op`) of lane rule `c` (a `SIMD_*` code) on lanes of `lt`, signed `sg`;
// `un` set for one operand, `fma` for an accumulation into operand 2.
const fn neon_of_simd(c: u8, lt: u8, sg: bool, un: &mut bool, fma: &mut bool) u32 {
    let eb = type_bytes(lt, 8);
    let s = vsize(eb);
    let sz = (lt == T_F64) as u32;
    *un = false;
    *fma = false;
    if is_float(lt) {
        // min and max keep a signaling NaN's bits, which the vector instructions quiet: lanes.
        if c == core::SIMD_FMA {
            *fma = true;
            return a::v3op(false, a::V3_FMLA, sz, 0, 0, 0);
        }
        *un = true;
        if c == core::SIMD_ABS {
            return a::v2op(false, a::V2_FABS, 2 | sz, 0, 0);
        }
        if c == core::SIMD_SQRT {
            return a::v2op(false, a::V2_FSQRT, 2 | sz, 0, 0);
        }
        if c == core::SIMD_CEIL {
            return a::v2op(false, a::V2_FRINTP, 2 | sz, 0, 0);
        }
        if c == core::SIMD_FLOOR {
            return a::v2op(false, a::V2_FRINTM, sz, 0, 0);
        }
        if c == core::SIMD_TRUNC {
            return a::v2op(false, a::V2_FRINTZ, 2 | sz, 0, 0);
        }
        if c == core::SIMD_ROUND_EVEN {
            return a::v2op(false, a::V2_FRINTN, sz, 0, 0);
        }
        return NONE;
    }
    if c == core::SIMD_WRAP_ADD {
        return a::v3op(false, a::V3_ADD, s, 0, 0, 0);
    }
    if c == core::SIMD_WRAP_SUB {
        return a::v3op(false, a::V3_SUB, s, 0, 0, 0);
    }
    if c == core::SIMD_WRAP_MUL && eb < 8 {
        return a::v3op(false, a::V3_MUL, s, 0, 0, 0);
    }
    if c == core::SIMD_MIN && eb < 8 {
        return a::v3op(
            false,
            if sg {
                a::V3_SMIN;
            } else {
                a::V3_UMIN;
            },
            s,
            0,
            0,
            0,
        );
    }
    if c == core::SIMD_MAX && eb < 8 {
        return a::v3op(
            false,
            if sg {
                a::V3_SMAX;
            } else {
                a::V3_UMAX;
            },
            s,
            0,
            0,
            0,
        );
    }
    *un = true;
    if c == core::SIMD_WRAP_NEG {
        return a::v2op(false, a::V2_NEG, s, 0, 0);
    }
    if c == core::SIMD_WRAP_ABS && sg {
        return a::v2op(false, a::V2_ABS, s, 0, 0);
    }
    if c == core::SIMD_POPCNT && eb == 1 {
        return a::v2op(false, a::V2_CNT, 0, 0, 0);
    }
    return NONE;
}

extend Gen {
    // Vector value `v`'s lane `k` of `eb` bytes: its base register and offset.
    fn lane(self: &mut Self, v: Value, k: u32, eb: u32) (u32, i64) {
        let (b, o) = self.mloc(v);
        return b, o + (k * eb) as i64;
    }

    // Load lane `k` of vector `v` (lanes of `lt`) into `r` (`lane_ld`'s kinds).
    fn ld_lane(self: &mut Self, r: u8, v: Value, k: u32, lt: u8, sg: bool, raw: bool) {
        let (b, o) = self.lane(v, k, type_bytes(lt, 8));
        self.mem(lane_ld(lt, sg, raw), true, r, b, o);
    }

    // Store `r` as lane `k` (lanes of `lt`) of the vector in the slot at sp + `d`.
    fn st_lane(self: &mut Self, r: u8, d: i64, k: u32, lt: u8, raw: bool) {
        self.mem(lane_st(lt, raw), false, r, a::SP, d + (k * type_bytes(lt, 8)) as i64);
    }

    // NEON instruction `w` (8 bytes, registers 0) over the `nb` bytes (8, or a multiple of 16) of vectors `x`
    // and `y` (VNONE for one operand) into the slot at sp + `d`; with `acc` (not VNONE) the result
    // accumulates into vector `acc`'s lanes.
    fn neon(self: &mut Self, w: u32, d: i64, x: Value, y: Value, acc: Value, nb: u32) {
        let q = nb >= 16;
        let step: u32 = if q {
            16;
        } else {
            8;
        };
        let m = if q {
            a::M_VQ;
        } else {
            a::M_VD;
        };
        let wq = w | a::on(q, 1u32 << 30);
        let r30 = V0 + 30;
        let r31 = V0 + 31;
        let rc = if acc != VNONE {
            self.tmp(true);
        } else {
            r30;
        };
        let mut at: u32 = 0;
        while at < nb {
            let (bx, ox) = self.lane(x, at, 1);
            self.mem(m, true, r30, bx, ox);
            if y != VNONE {
                let (by, oy) = self.lane(y, at, 1);
                self.mem(m, true, r31, by, oy);
            }
            if acc != VNONE {
                let (ba, oa) = self.lane(acc, at, 1);
                self.mem(m, true, rc, ba, oa);
            }
            let rm: u32 = if y != VNONE {
                31u32 << 16;
            } else {
                0u32;
            };
            self.emit(wq | (rc - V0) as u32 | 30u32 << 5 | rm);
            self.mem(m, false, rc, a::SP, d + at as i64);
            at += step;
        }
    }

    // Neon instruction `w` (its register fields 0) of one register's width (`nb`, 8 or 16 bytes) on `x`
    // and `y` (VNONE: none), accumulating into a copy of `acc` (VNONE: none), into a register that holds
    // result `i`.
    fn neon_reg(self: &mut Self, w: u32, i: u32, x: Value, y: Value, acc: Value, nb: u32) {
        let wq = w | a::on(nb == 16, 1u32 << 30);
        let rx = self.vec_use(x, V0 + 30);
        let ry = if y != VNONE {
            self.vec_use(y, V0 + 31);
        } else {
            0u8;
        };
        let rd = self.vec_def(i);
        if acc != VNONE {
            // The accumulator's copy, which the instruction updates.
            let xa = self.vx(acc);
            let ra = self.va[xa as usize].reg;
            if ra != NOREG {
                self.emit(a::vmov(nb == 16, rd - V0, ra - V0));
            } else {
                let (base, off) = self.mloc(acc);
                self.mem(mkind(self.vt(acc), true), true, rd, base, off);
            }
        }
        let rm: u32 = if y != VNONE {
            (ry - V0) as u32 << 16;
        } else {
            0u32;
        };
        self.emit(wq | (rd - V0) as u32 | (rx - V0) as u32 << 5 | rm);
    }

    // A v register for vector result `i`, which holds it (its home, a slot, comes when it spills).
    fn vec_def(self: &mut Self, i: u32) u8 {
        let r = self.alloc(true);
        self.bind(self.vx(i), r);
        return r;
    }

    // Vector `v` in a v register: its own, else loaded into `scratch`.
    fn vec_use(self: &mut Self, v: Value, scratch: u8) u8 {
        let x = self.vx(v);
        let r = self.va[x as usize].reg;
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let (base, off) = self.mloc(v);
        self.mem(mkind(self.vt(v), true), true, scratch, base, off);
        return scratch;
    }

    // `mk` |= 1 << `k` when condition `cond` holds (`tr` a temporary).
    fn mask_bit(self: &mut Self, mk: u8, cond: u32, k: u32, tr: u8) {
        self.emit(a::cset(true, tr, cond));
        self.emit(a::logic_reg(true, 1, false, mk, mk, tr, 0, k));
    }

    // The call of `__sc_lane_panic(x0, msg)`: `lane <x0>: <msg>`.
    fn lane_panic_call(self: &mut Self, msg: str) {
        let os = self.cstr(msg);
        self.reloc(a::R_PAGE21, os, 0);
        self.emit(a::adr(true, 1, 0));
        self.reloc(a::R_PAGEOFF12, os, 0);
        self.emit(a::add_imm(true, 1, 1, 0));
        self.call_rt("__sc_lane_panic");
    }

    // Vector arithmetic: O_ADD .. O_NOT and O_FADD .. O_FNEG on vectors.
    fn vec_arith(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let nb = type_bytes(t.ty, 8);
        let mut un = false;
        let w = neon_of_op(op, lt, &mut un);
        let y = if un {
            VNONE;
        } else {
            t.b;
        };
        if w != NONE && Gen::in_vreg(t.ty) {
            self.neon_reg(w, i, t.a, y, VNONE, nb);
            return true;
        }
        self.sync(t.a);
        if y != VNONE {
            self.sync(y);
        }
        let d = self.mdef(i);
        if w != NONE && nb >= 8 {
            self.neon(w, d, t.a, y, VNONE, nb);
            return true;
        }
        if is_float(lt) {
            let dd = lt == T_F64;
            let fa = self.tmp(true);
            let fb = self.tmp(true);
            let f = if op == O_FADD {
                a::FP_ADD;
            } else if op == O_FSUB {
                a::FP_SUB;
            } else if op == O_FMUL {
                a::FP_MUL;
            } else {
                a::FP_DIV;
            };
            for k in 0..n {
                self.ld_lane(fa, t.a, k, lt, false, false);
                if op == O_FNEG {
                    self.emit(a::fp1(dd, a::FP_NEG, fa - V0, fa - V0));
                } else {
                    self.ld_lane(fb, t.b, k, lt, false, false);
                    self.emit(a::fp2(dd, f, fa - V0, fa - V0, fb - V0));
                }
                self.st_lane(fa, d, k, lt, false);
            }
            return true;
        }
        let sg = op == O_ASHR || op == O_SDIV || op == O_SREM;
        let x = self.tmp(false);
        let yr = self.tmp(false);
        let z = self.tmp(false);
        for k in 0..n {
            self.ld_lane(x, t.a, k, lt, sg, false);
            if !un {
                self.ld_lane(yr, t.b, k, lt, sg, false);
            }
            self.int_lane(op, x, yr, z);
            self.st_lane(x, d, k, lt, false);
        }
        return true;
    }

    // `x` = `x` op `y` on 64-bit registers (integer LIR operation `op`; `z` a temporary).
    fn int_lane(self: &mut Self, op: u8, x: u8, y: u8, z: u8) {
        if op == O_ADD || op == O_SUB {
            self.emit(a::addsub_reg(true, (op == O_SUB) as u32, false, x, x, y, 0, 0));
        } else if op == O_MUL {
            self.emit(a::mul(true, x, x, y));
        } else if op == O_SDIV || op == O_UDIV {
            self.emit(
                a::dp2(
                    true,
                    if op == O_SDIV {
                        a::DP2_SDIV;
                    } else {
                        a::DP2_UDIV;
                    },
                    x,
                    x,
                    y,
                ),
            );
        } else if op == O_SREM || op == O_UREM {
            self.emit(
                a::dp2(
                    true,
                    if op == O_SREM {
                        a::DP2_SDIV;
                    } else {
                        a::DP2_UDIV;
                    },
                    z,
                    x,
                    y,
                ),
            );
            self.emit(a::madd(true, true, x, z, y, x));
        } else if op == O_AND || op == O_OR || op == O_XOR {
            self.emit(a::logic_reg(true, op - O_AND, false, x, x, y, 0, 0));
        } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
            self.emit(a::dp2(true, a::DP2_LSLV + (op - O_SHL) as u32, x, x, y));
        } else if op == O_NEG {
            self.emit(a::addsub_reg(true, 1, false, x, a::ZR, x, 0, 0));
        } else {
            self.emit(a::logic_reg(true, 1, true, x, a::ZR, x, 0, 0));
        }
    }

    // A lane-wise conversion of vector `v` (lanes of `fl`, signed `fs`) to the lanes of `tl` (signed `ts`)
    // into the slot of instruction `i`; a float to an integer saturates unless `unchecked`.
    fn vec_conv(self: &mut Self, i: u32, v: Value, fl: u8, fs: bool, tl: u8, ts: bool, unchecked: bool) {
        let n = lanes(self.vt(v));
        let d = self.mdef(i);
        let fa = self.tmp(true);
        let x = self.tmp(false);
        let tb = type_bits(tl, 8);
        for k in 0..n {
            if is_float(fl) {
                self.ld_lane(fa, v, k, fl, false, false);
            } else {
                self.ld_lane(x, v, k, fl, fs, false);
            }
            if is_float(fl) && is_float(tl) {
                if fl != tl {
                    self.emit(a::fcvt(tl == T_F64, fa - V0, fa - V0));
                }
                self.st_lane(fa, d, k, tl, false);
            } else if is_float(tl) {
                self.emit(a::cvtf(true, tl == T_F64, fs, fa - V0, x));
                self.st_lane(fa, d, k, tl, false);
            } else if is_float(fl) {
                self.emit(a::fcvtz(tb == 64, fl == T_F64, ts, x, fa - V0));
                if tb < 32 && !unchecked {
                    self.clamp_lane(x, tb, ts);
                }
                self.st_lane(x, d, k, tl, false);
            } else {
                self.st_lane(x, d, k, tl, false);
            }
        }
    }

    // Clamp the 32-bit `r` to the range of a `tb`-bit (below 32) integer, signed `signed`.
    fn clamp_lane(self: &mut Self, r: u8, tb: u32, signed: bool) {
        let hi: u64 = if signed {
            (1u64 << (tb - 1) as u64) - 1;
        } else {
            (1u64 << tb as u64) - 1;
        };
        self.mov_imm(a::IP0 as u8, hi, false);
        self.emit(a::addsub_reg(false, 1, true, a::ZR, r, a::IP0, 0, 0));
        self.emit(
            a::csel(
                false,
                0,
                0,
                r,
                a::IP0,
                r,
                if signed {
                    a::GT;
                } else {
                    a::HI;
                },
            ),
        );
        if signed {
            self.mov_imm(a::IP0 as u8, ~hi & 0xFFFFFFFF, false);
            self.emit(a::addsub_reg(false, 1, true, a::ZR, r, a::IP0, 0, 0));
            self.emit(a::csel(false, 0, 0, r, a::IP0, r, a::LT));
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
            self.vec_fmod(i, ops[0], ops[1]);
            return true;
        }
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            let lt = lane_type(tys[0]);
            let n = lanes(tys[0]);
            let lb = type_bits(lt, 8);
            let cnt = self.reg(ops[1]);
            let kr = self.tmp(false);
            self.emit(a::logic_imm(true, 0, kr, cnt, a::logical_imm(lb - 1, true)));
            let x = self.tmp(false);
            let d = self.mdef(i);
            let sop = if code == core::OP_SHL_SCALAR {
                a::DP2_LSLV;
            } else if sg {
                a::DP2_ASRV;
            } else {
                a::DP2_LSRV;
            };
            for k in 0..n {
                self.ld_lane(x, ops[0], k, lt, sg, false);
                self.emit(a::dp2(true, sop, x, x, kr));
                self.st_lane(x, d, k, lt, false);
            }
            return true;
        }
        assert(code >= core::OP_SIMD && code < core::OP_CMP_LANES, "a64gen: a vector operation the verifier rejects");
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
        self.vlanes(i, t, c, sg, dsg, &ops, &tys);
        return true;
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

    // Float vectors `x` % `y` lane by lane through C's `fmod` (`fmodf`).
    fn vec_fmod(self: &mut Self, i: u32, x: Value, y: Value) {
        let lt = lane_type(self.vt(x));
        let n = lanes(self.vt(x));
        let d = self.mdef(i);
        self.spill_for_call();
        let fs = self.obj().sym(
            if lt == T_F32 {
                "fmodf";
            } else {
                "fmod";
            },
        );
        for k in 0..n {
            self.ld_lane(V0, x, k, lt, false, false);
            self.ld_lane(V0 + 1, y, k, lt, false, false);
            self.reloc(a::R_BRANCH26, fs, 0);
            self.emit(a::bl(0));
            self.st_lane(V0, d, k, lt, false);
        }
    }
}

const fn ast_min(x: u32, y: u32) u32 {
    if x < y {
        return x;
    }
    return y;
}

extend Gen {
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
                self.copy_mem(a::SP, d, b0, o0, nb);
                self.copy_mem(a::SP, d + nb as i64, b1, o1, nb);
            } else if c == core::SIMD_HIGH_HALF {
                self.copy_mem(a::SP, d, b0, o0 + rb as i64, rb);
            } else {
                self.copy_mem(a::SP, d, b0, o0, rb);
            }
            return;
        }
        let mask = rule == core::SR_MASK || rule == core::SR_CHANGED;
        let mut un = false;
        let mut fma = false;
        let w = if mask || rule != core::SR_VEC || nb < 8 {
            NONE;
        } else {
            neon_of_simd(c, lt, sg, &mut un, &mut fma);
        };
        if w != NONE && Gen::in_vreg(t.ty) {
            if fma {
                self.neon_reg(w, i, ops[0], ops[1], ops[2], nb);
            } else if un {
                self.neon_reg(w, i, ops[0], VNONE, VNONE, nb);
            } else {
                self.neon_reg(w, i, ops[0], ops[1], VNONE, nb);
            }
            return;
        }
        self.sync_ops(ops);
        if w != NONE {
            let d = self.mdef(i);
            if fma {
                self.neon(w, d, ops[0], ops[1], ops[2], nb);
            } else if un {
                self.neon(w, d, ops[0], VNONE, VNONE, nb);
            } else {
                self.neon(w, d, ops[0], ops[1], VNONE, nb);
            }
            return;
        }
        if !mask && rule == core::SR_VEC && !fl && !sg && (c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS) {
            // The absolute value of an unsigned lane is the lane.
            let d = self.mdef(i);
            let (b0, o0) = self.mloc(ops[0]);
            self.copy_mem(a::SP, d, b0, o0, nb);
            return;
        }
        let rlt = if mask || !is_vec(t.ty) {
            lt;
        } else {
            lane_type(t.ty);
        };
        // Results: the mask register, or the vector's slot.
        let mut mk: u8 = NOREG;
        let mut d: i64 = 0;
        if mask {
            mk = self.def(i);
            self.emit(a::mov_reg(true, mk, a::ZR));
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
        let x = self.tmp(false);
        let y = self.tmp(false);
        let z = self.tmp(false);
        let wr = self.tmp(false);
        let traps = !fl && sg && c == core::SIMD_ABS || c == core::SIMD_NARROW_CHECKED;
        // The bit rules read a lane's own bits: zero-extended whatever its sign.
        let bitop = c >= core::SIMD_CLZ && c <= core::SIMD_BSWAP;
        let fr = if traps {
            self.tmp(false);
        } else {
            NOREG;
        };
        if traps {
            self.emit(a::mov_reg(true, fr, a::ZR));
        }
        let mut fails = Vector::<u64>::new();
        let (fa, fb, fc) = if fl {
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
                    self.mov_imm(x, k, true);
                    self.st_lane(x, d, k, lt, false);
                }
                continue;
            }
            if rule == core::SR_CHOOSE {
                self.ld_lane(x, ops[1], k, lt, false, true);
                self.ld_lane(y, ops[2], k, lt, false, true);
                self.emit(a::logic_imm(true, 3, a::ZR, cm, a::logical_imm(1u64 << k as u64, true)));
                self.emit(a::csel(true, 0, 0, x, x, y, a::NE));
                self.st_lane(x, d, k, lt, true);
                continue;
            }
            if c == core::SIMD_CAST_CHANGED {
                self.lane_changed(mk, k, ops, tys, sg, dsg, x, y, z, wr, fa, fb);
                continue;
            }
            if fl {
                self.float_rule(c, k, ops, tys, lt, mk, d, x, y, wr, fa, fb, fc);
                continue;
            }
            self.ld_lane(x, ops[0], k, lt, sg && !bitop, false);
            if scalar1 {
                self.emit(a::mov_reg(true, y, s1));
            } else if tys[1] != T_NONE {
                self.ld_lane(y, ops[1], k, lane_type(tys[1]), sg && !bitop, false);
            }
            if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
                self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
                self.mask_bit(mk, int_cond(c, sg), k, wr);
                continue;
            }
            if c >= core::SIMD_OVF_ADD && c <= core::SIMD_OVF_MUL {
                let cond = self.ovf_lane(c, lb, sg, x, y, z, wr);
                self.mask_bit(mk, cond, k, wr);
                continue;
            }
            self.int_rule(c, lb, sg, rlt, dsg, x, y, z, wr, fr);
            if traps {
                // The first failing lane leaves for its stub.
                fails.push(self.code.len() as u64 << 32 | k as u64);
                self.emit(a::cbz(true, true, fr, 0));
            }
            self.st_lane(x, d, k, rlt, false);
        }
        if traps {
            // Past the stubs: each sets its lane and joins the trap.
            let wb = self.code.len() as u32;
            self.emit(a::b(0));
            let mut joins = Vector::<u32>::with_capacity(fails.len());
            for q in 0..fails.len() {
                self.here((fails[q] >> 32) as u32);
                self.mov_imm(0, fails[q] & 0xFFFFFFFF, true);
                joins.push(self.code.len() as u32);
                self.emit(a::b(0));
            }
            for q in 0..joins.len() {
                self.here(joins[q]);
            }
            self.lane_panic_call(core::lane_trap_msg(core::RV_SIMD, c, false));
            self.here(wb);
        }
    }

    // Lane `x` op `y` of rule `c` (OVF_ADD .. OVF_MUL) of `lb`-bit lanes (signed `sg`, extended to 64 bits):
    // the condition that holds when the exact result does not fit the lane; `x` keeps the wrapped result.
    fn ovf_lane(self: &mut Self, c: u8, lb: u32, sg: bool, x: u8, y: u8, z: u8, wr: u8) u32 {
        let add = c == core::SIMD_OVF_ADD || c == core::SIMD_SAT_ADD;
        let sub = c == core::SIMD_OVF_SUB || c == core::SIMD_SAT_SUB;
        if lb == 64 {
            if add || sub {
                self.emit(a::addsub_reg(true, sub as u32, true, x, x, y, 0, 0));
                if sg {
                    return a::VS;
                }
                return if add {
                    a::HS;
                } else {
                    a::LO;
                };
            }
            self.emit(a::mulh(sg, z, x, y));
            self.emit(a::mul(true, x, x, y));
            if sg {
                self.emit(a::addsub_reg(true, 1, true, a::ZR, z, x, 2, 63));
            } else {
                self.emit(a::cmp_imm(true, z, 0));
            }
            return a::NE;
        }
        // Narrower lanes: the exact result in 64 bits, compared with its lane's extension.
        if add || sub {
            self.emit(a::addsub_reg(true, sub as u32, false, x, x, y, 0, 0));
        } else {
            self.emit(a::mul(true, x, x, y));
        }
        if sg {
            self.emit(a::sxt(true, wr, x, lb));
            self.emit(a::addsub_reg(true, 1, true, a::ZR, wr, x, 0, 0));
        } else {
            self.emit(a::lsr_imm(true, wr, x, lb));
            self.emit(a::cmp_imm(true, wr, 0));
        }
        return a::NE;
    }

    // Integer lane rule `c` on `x` (and `y`) of `lb`-bit lanes (signed `sg`, extended to 64 bits): the
    // result lane (of `rlt`, signed `rsg`) in `x`; a lane that traps sets `fr`.
    fn int_rule(self: &mut Self, c: u8, lb: u32, sg: bool, rlt: u8, rsg: bool, x: u8, y: u8, z: u8, wr: u8, fr: u8) {
        let lt_c = if sg {
            a::LT;
        } else {
            a::LO;
        };
        if c == core::SIMD_WRAP_ADD || c == core::SIMD_WRAP_SUB || c == core::SIMD_WRAP_MUL {
            let op = if c == core::SIMD_WRAP_ADD {
                O_ADD;
            } else if c == core::SIMD_WRAP_SUB {
                O_SUB;
            } else {
                O_MUL;
            };
            self.int_lane(op, x, y, z);
        } else if c == core::SIMD_WRAP_NEG {
            self.int_lane(O_NEG, x, y, z);
        } else if c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR {
            self.emit(a::logic_imm(true, 0, y, y, a::logical_imm(lb - 1, true)));
            let s = if c == core::SIMD_WRAP_SHL {
                a::DP2_LSLV;
            } else if sg {
                a::DP2_ASRV;
            } else {
                a::DP2_LSRV;
            };
            self.emit(a::dp2(true, s, x, x, y));
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit: a signed overflow goes the way of the operand's sign, an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1;
            } else {
                trunc64(~0u64, lb);
            };
            let min = if sg {
                (1u64 << (lb - 1) as u64).wrapping_neg();
            } else {
                0u64;
            };
            let cond = self.ovf_lane(c, lb, sg, x, y, z, wr);
            self.emit(a::cset(true, wr, cond));
            if sg {
                self.mov_imm(
                    z,
                    if add {
                        max;
                    } else {
                        min;
                    },
                    true,
                );
                self.mov_imm(
                    a::IP0 as u8,
                    if add {
                        min;
                    } else {
                        max;
                    },
                    true,
                );
                self.emit(a::cmp_imm(true, y, 0));
                self.emit(a::csel(true, 0, 0, z, a::IP0, z, a::LT));
            } else {
                self.mov_imm(
                    z,
                    if add {
                        max;
                    } else {
                        min;
                    },
                    true,
                );
            }
            self.emit(a::cmp_imm(true, wr, 0));
            self.emit(a::csel(true, 0, 0, x, z, x, a::NE));
        } else if c == core::SIMD_MIN {
            self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
            self.emit(a::csel(true, 0, 0, x, x, y, lt_c));
        } else if c == core::SIMD_MAX {
            self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
            self.emit(a::csel(true, 0, 0, x, y, x, lt_c));
        } else if c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS {
            if c == core::SIMD_ABS {
                // The lowest value has no absolute value in its lane.
                self.mov_imm(z, (1u64 << (lb - 1) as u64).wrapping_neg(), true);
                self.emit(a::addsub_reg(true, 1, true, a::ZR, x, z, 0, 0));
                self.emit(a::csel(true, 0, 1, fr, fr, fr, a::NE));
            }
            self.emit(a::cmp_imm(true, x, 0));
            self.emit(a::csel(true, 1, 1, x, x, x, a::GE));
        } else if c == core::SIMD_ABS_DIFF {
            self.emit(a::addsub_reg(true, 1, false, z, x, y, 0, 0));
            self.emit(a::addsub_reg(true, 1, false, wr, y, x, 0, 0));
            self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
            self.emit(
                a::csel(
                    true,
                    0,
                    0,
                    x,
                    z,
                    wr,
                    if sg {
                        a::GT;
                    } else {
                        a::HI;
                    },
                ),
            );
        } else if c == core::SIMD_CLZ {
            self.emit(a::dp1(true, a::DP1_CLZ, x, x));
            if lb < 64 {
                self.emit(a::sub_imm(true, x, x, 64 - lb));
            }
        } else if c == core::SIMD_CTZ {
            if lb < 64 {
                self.emit(a::logic_imm(true, 1, x, x, a::logical_imm(1u64 << lb as u64, true)));
            }
            self.emit(a::dp1(true, a::DP1_RBIT, x, x));
            self.emit(a::dp1(true, a::DP1_CLZ, x, x));
        } else if c == core::SIMD_POPCNT {
            self.emit(a::fmov_gv(true, true, 30, x));
            self.emit(a::cnt8b(30, 30));
            self.emit(a::addv8b(30, 30));
            self.emit(a::fmov_gv(false, false, x, 30));
        } else if c == core::SIMD_ROTL || c == core::SIMD_ROTR {
            // (u << k | u >> (lb - k) % lb), or the reverse: the store keeps the lane's bits.
            self.emit(a::logic_imm(true, 0, y, y, a::logical_imm(lb - 1, true)));
            self.emit(a::addsub_reg(true, 1, false, z, a::ZR, y, 0, 0));
            self.emit(a::logic_imm(true, 0, z, z, a::logical_imm(lb - 1, true)));
            let (s0, s1) = if c == core::SIMD_ROTL {
                (a::DP2_LSLV, a::DP2_LSRV);
            } else {
                (a::DP2_LSRV, a::DP2_LSLV);
            };
            self.emit(a::dp2(true, s0, wr, x, y));
            self.emit(a::dp2(true, s1, x, x, z));
            self.emit(a::logic_reg(true, 1, false, x, x, wr, 0, 0));
        } else if c == core::SIMD_BITREV {
            self.emit(a::dp1(true, a::DP1_RBIT, x, x));
            if lb < 64 {
                self.emit(a::lsr_imm(true, x, x, 64 - lb));
            }
        } else if c == core::SIMD_BSWAP {
            if lb > 8 {
                self.emit(a::dp1(true, a::DP1_REV64, x, x));
                self.emit(a::lsr_imm(true, x, x, 64 - lb));
            }
        } else if c == core::SIMD_NARROW_CHECKED || c == core::SIMD_NARROW_SAT {
            self.narrow_lane(c == core::SIMD_NARROW_SAT, lb, sg, type_bits(rlt, 8), rsg, x, z, wr, fr);
        }
    }

    // A lane `x` of `lb` bits (signed `sg`, extended) to `rw` bits (signed `rsg`): saturated (`sat`), else
    // kept when it fits and failing `fr` when not.
    fn narrow_lane(self: &mut Self, sat: bool, lb: u32, sg: bool, rw: u32, rsg: bool, x: u8, z: u8, wr: u8, fr: u8) {
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
        // `x` above 2^63 only for an unsigned 64-bit lane: its top bit, taken as a value, is positive.
        let huge_u = !sg && lb == 64;
        if !sat {
            // Fits: the range test in 64 bits, a value above 2^63 only into an unsigned 64-bit lane.
            // `csinc` counts a failure where the fitting condition is false.
            if rsg {
                if rw < 64 {
                    self.emit(a::sxt(true, wr, x, rw));
                    self.emit(a::addsub_reg(true, 1, true, a::ZR, wr, x, 0, 0));
                    self.emit(a::csel(true, 0, 1, fr, fr, fr, a::EQ));
                }
                if huge_u {
                    self.emit(a::cmp_imm(true, x, 0));
                    self.emit(a::csel(true, 0, 1, fr, fr, fr, a::GE));
                }
            } else {
                if sg {
                    self.emit(a::cmp_imm(true, x, 0));
                    self.emit(a::csel(true, 0, 1, fr, fr, fr, a::GE));
                }
                if rw < 64 {
                    self.emit(a::lsr_imm(true, wr, x, rw));
                    self.emit(a::cmp_imm(true, wr, 0));
                    self.emit(a::csel(true, 0, 1, fr, fr, fr, a::EQ));
                }
            }
            return;
        }
        // Saturate: a negative signed value into an unsigned lane is 0, then the range clamps.
        if sg && !rsg {
            self.emit(a::cmp_imm(true, x, 0));
            self.emit(a::csel(true, 0, 0, x, x, a::ZR, a::GE));
        }
        self.mov_imm(z, rmax, true);
        self.emit(a::addsub_reg(true, 1, true, a::ZR, x, z, 0, 0));
        self.emit(
            a::csel(
                true,
                0,
                0,
                x,
                z,
                x,
                if sg {
                    a::GT;
                } else {
                    a::HI;
                },
            ),
        );
        if sg && rsg {
            self.mov_imm(z, rmin, true);
            self.emit(a::addsub_reg(true, 1, true, a::ZR, x, z, 0, 0));
            self.emit(a::csel(true, 0, 0, x, z, x, a::LT));
        }
    }

    // Float lane rule `c` on lane `k` (lanes of `lt`): the result lane stored at sp + `d`, or a mask bit
    // into `mk`.
    fn float_rule(
        self: &mut Self,
        c: u8,
        k: u32,
        ops: &[Value; 4],
        tys: &[u8; 4],
        lt: u8,
        mk: u8,
        d: i64,
        x: u8,
        y: u8,
        wr: u8,
        fa: u8,
        fb: u8,
        fc: u8,
    ) {
        let dd = lt == T_F64;
        let lb = type_bits(lt, 8);
        let sb = 1u64 << (lb - 1) as u64;
        if c == core::SIMD_COPYSIGN || c == core::SIMD_IS_SIGN_NEG {
            self.ld_lane(x, ops[0], k, lt, false, true);
            if c == core::SIMD_IS_SIGN_NEG {
                self.emit(a::logic_imm(true, 3, a::ZR, x, a::logical_imm(sb, true)));
                self.mask_bit(mk, a::NE, k, wr);
                return;
            }
            self.ld_lane(y, ops[1], k, lt, false, true);
            self.emit(a::logic_imm(true, 0, x, x, a::logical_imm(sb - 1, true)));
            self.emit(a::logic_imm(true, 0, y, y, a::logical_imm(sb, true)));
            self.emit(a::logic_reg(true, 1, false, x, x, y, 0, 0));
            self.st_lane(x, d, k, lt, true);
            return;
        }
        self.ld_lane(fa, ops[0], k, lt, false, false);
        if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
            self.ld_lane(fb, ops[1], k, lt, false, false);
            self.emit(a::fcmp(dd, fa - V0, fb - V0));
            self.mask_bit(mk, float_cond(c), k, wr);
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
                self.emit(a::fcmp(dd, fa - V0, fa - V0));
                self.mask_bit(mk, a::VS, k, wr);
                return;
            }
            self.emit(a::fp1(dd, a::FP_ABS, fa - V0, fa - V0));
            if c == core::SIMD_IS_SUBNORMAL {
                // Not 0 and below the least normal (a NaN compares unordered: neither).
                self.fconst(fb, dd, minn);
                self.emit(a::fcmp(dd, fa - V0, fb - V0));
                self.emit(a::cset(true, y, a::MI));
                self.emit(a::fmov_gv(dd, true, fb - V0, a::ZR));
                self.emit(a::fcmp(dd, fa - V0, fb - V0));
                self.emit(a::csel(true, 0, 0, y, y, a::ZR, a::NE));
                self.emit(a::logic_reg(true, 1, false, mk, mk, y, 0, k));
                return;
            }
            self.fconst(fb, dd, maxf);
            self.emit(a::fcmp(dd, fa - V0, fb - V0));
            if c == core::SIMD_IS_INF {
                self.mask_bit(mk, a::GT, k, wr);
                return;
            }
            if c == core::SIMD_IS_FINITE {
                self.mask_bit(mk, a::LS, k, wr);
                return;
            }
            // Normal: at most the greatest finite and at least the least normal.
            self.emit(a::cset(true, y, a::LS));
            self.fconst(fb, dd, minn);
            self.emit(a::fcmp(dd, fa - V0, fb - V0));
            self.emit(a::csel(true, 0, 0, y, y, a::ZR, a::GE));
            self.emit(a::logic_reg(true, 1, false, mk, mk, y, 0, k));
            return;
        }
        if c == core::SIMD_FMA {
            self.ld_lane(fb, ops[1], k, lt, false, false);
            self.ld_lane(fc, ops[2], k, lt, false, false);
            self.emit(a::fmadd(dd, false, fa - V0, fa - V0, fb - V0, fc - V0));
        } else if c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM {
            self.ld_lane(fb, ops[1], k, lt, false, false);
            let lo = c == core::SIMD_MIN || c == core::SIMD_MINIMUM;
            self.fminmax(dd, lo, c >= core::SIMD_MINIMUM, true, fa, fa, fb, fc);
        } else {
            let f = if c == core::SIMD_ABS {
                a::FP_ABS;
            } else if c == core::SIMD_SQRT {
                a::FP_SQRT;
            } else if c == core::SIMD_CEIL {
                a::FP_RINTP;
            } else if c == core::SIMD_FLOOR {
                a::FP_RINTM;
            } else if c == core::SIMD_TRUNC {
                a::FP_RINTZ;
            } else if c == core::SIMD_ROUND_EVEN {
                a::FP_RINTN;
            } else {
                a::FP_NEG;
            };
            self.emit(a::fp1(dd, f, fa - V0, fa - V0));
        }
        let _ = tys;
        self.st_lane(fa, d, k, lt, false);
    }

    // The float min (`lo`) or max of registers `a` and `b` into `d` (which may be `a`), by the evaluator's
    // `fminmax`, the operands' bits kept: with `nan` a NaN operand is the result (`a` first); else a NaN
    // gives the other operand, and two give `a`, quieted when `quiet`. `t` is a scratch register.
    fn fminmax(self: &mut Self, dd: bool, lo: bool, nan: bool, quiet: bool, d: u8, a: u8, b: u8, t: u8) {
        let (dv, av, bv, tv) = ((d - V0) as u32, (a - V0) as u32, (b - V0) as u32, (t - V0) as u32);
        if nan {
            self.emit(
                a::fp2(
                    dd,
                    if lo {
                        a::FP_MIN;
                    } else {
                        a::FP_MAX;
                    },
                    tv,
                    av,
                    bv,
                ),
            );
            self.emit(a::fcmp(dd, bv, bv));
            self.emit(a::fcsel(dd, tv, bv, tv, a::VS));
            self.emit(a::fcmp(dd, av, av));
            self.emit(a::fcsel(dd, dv, av, tv, a::VS));
            return;
        }
        // y = b, or a when b is a NaN; x = a, or y when a is a NaN: one NaN leaves the other operand twice.
        let f = if lo {
            a::FP_MINNM;
        } else {
            a::FP_MAXNM;
        };
        self.emit(a::fcmp(dd, bv, bv));
        self.emit(a::fcsel(dd, tv, av, bv, a::VS));
        self.emit(a::fcmp(dd, av, av));
        self.emit(a::fcsel(dd, dv, tv, av, a::VS));
        if quiet {
            self.emit(a::fp2(dd, f, dv, dv, tv));
            return;
        }
        // Two NaNs leave x = a: kept as it is.
        self.emit(a::fp2(dd, f, tv, dv, tv));
        self.emit(a::fcmp(dd, dv, dv));
        self.emit(a::fcsel(dd, dv, dv, tv, a::VS));
    }

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
        x: u8,
        y: u8,
        z: u8,
        wr: u8,
        fa: u8,
        fb: u8,
    ) {
        let bt = lane_type(tys[0]);
        let rt = lane_type(tys[1]);
        let ff = is_float(bt);
        let tf = is_float(rt);
        // The float registers: the lanes need them even for integer lanes.
        let va = if fa == NOREG {
            V0 + 30;
        } else {
            fa;
        };
        let vb = if fb == NOREG {
            V0 + 31;
        } else {
            fb;
        };
        if ff && tf {
            // Both in f64: unordered or not equal.
            self.ld_lane(va, ops[0], k, bt, false, false);
            self.ld_lane(vb, ops[1], k, rt, false, false);
            if bt == T_F32 {
                self.emit(a::fcvt(true, va - V0, va - V0));
            }
            if rt == T_F32 {
                self.emit(a::fcvt(true, vb - V0, vb - V0));
            }
            self.emit(a::fcmp(true, va - V0, vb - V0));
            self.mask_bit(mk, a::NE, k, wr);
            return;
        }
        if !ff && !tf {
            // Integers: the source value does not fit the result lane.
            self.ld_lane(x, ops[0], k, bt, bs, false);
            self.mov_imm(wr, 0, true);
            self.narrow_lane(false, type_bits(bt, 8), bs, type_bits(rt, 8), rs, x, z, y, wr);
            self.emit(a::cmp_imm(true, wr, 0));
            self.mask_bit(mk, a::NE, k, wr);
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
        // `y` = 1 when out of range or not integral.
        if ff {
            self.ld_lane(va, ops[0], k, bt, false, false);
            if bt == T_F32 {
                self.emit(a::fcvt(true, va - V0, va - V0));
            }
        } else {
            self.ld_lane(vb, ops[1], k, rt, false, false);
            if rt == T_F32 {
                self.emit(a::fcvt(true, vb - V0, vb - V0));
            }
            self.emit(a::fmov(true, va - V0, vb - V0));
        }
        // va >= lo && va < hi (false for a NaN).
        self.fconst(vb, true, lo);
        self.emit(a::fcmp(true, va - V0, vb - V0));
        self.emit(a::cset(true, y, a::GE));
        self.fconst(vb, true, hi);
        self.emit(a::fcmp(true, va - V0, vb - V0));
        self.emit(a::csel(true, 0, 0, y, y, a::ZR, a::MI));
        if ff {
            // And integral: trunc(x) == x.
            self.emit(a::fp1(true, a::FP_RINTZ, vb - V0, va - V0));
            self.emit(a::fcmp(true, va - V0, vb - V0));
        } else {
            // And the integer back equals the source.
            self.ld_lane(x, ops[0], k, bt, bs, false);
            self.emit(a::fcvtz(true, true, bs, z, va - V0));
            self.emit(a::addsub_reg(true, 1, true, a::ZR, z, x, 0, 0));
        }
        self.emit(a::csel(true, 0, 0, y, y, a::ZR, a::EQ));
        // Changed when not (in range and exact).
        self.emit(a::logic_imm(true, 2, y, y, a::logical_imm(1, true)));
        self.emit(a::logic_reg(true, 1, false, mk, mk, y, 0, k));
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
            self.emit(a::mov_reg(true, p, r0));
        } else {
            let (base, off) = self.addr(ops[0], 0);
            self.mem(a::M_X, true, p, base, off);
            let st = self.reg(ops[1]);
            self.emit(a::addsub_reg(true, 0, false, p, p, st, 0, eb.trailing_zeros() as u32));
        }
        let vv = if raw {
            ops[1];
        } else {
            ops[2];
        };
        if load && Gen::in_vreg(vt) {
            let rd = self.vec_def(i);
            self.mem(mkind(vt, true), true, rd, p, 0);
        } else if load {
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, p, 0, nb);
        } else if Gen::in_vreg(vt) {
            let r = self.vec_use(vv, V0 + 30);
            self.mem(mkind(vt, false), false, r, p, 0);
        } else {
            let (bv, ov) = self.mloc(vv);
            self.copy_mem(p, 0, bv, ov, nb);
        }
    }

    // The masked, partial and gather forms (the evaluator's `vmem_masked`): every active lane is checked
    // before the first access, the lowest failing one traps; an inactive lane never touches its element.
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
        let p = self.tmp(false);
        let len = self.tmp(false);
        let act = self.tmp(false);
        let x = self.tmp(false);
        let ix = self.tmp(false);
        let r0 = self.reg(ops[0]);
        if sl {
            self.mem(a::M_X, true, p, r0, 0);
            self.mem(a::M_X, true, len, r0, 8);
        } else {
            self.emit(a::mov_reg(true, p, r0));
        }
        let st = if sl && !gat {
            self.reg(ops[1]);
        } else {
            NOREG;
        };
        let all = trunc64(~0u64, n);
        if c == core::SIMD_LOAD_OR {
            // The lanes below len - start, none when start is past len.
            self.emit(a::addsub_reg(true, 1, true, x, len, st, 0, 0));
            self.mov_imm(act, 1, true);
            self.emit(a::dp2(true, a::DP2_LSLV, act, act, x));
            self.emit(a::sub_imm(true, act, act, 1));
            self.mov_imm(ix, all, true);
            self.emit(a::cmp_imm(true, x, n));
            self.emit(a::csel(true, 0, 0, act, ix, act, a::HS));
            self.emit(a::addsub_reg(true, 1, true, a::ZR, len, st, 0, 0));
            self.emit(a::csel(true, 0, 0, act, act, a::ZR, a::HS));
        } else {
            let m = self.reg(unsafe ops[ar - 2]);
            if n < 64 {
                self.emit(a::logic_imm(true, 0, act, m, a::logical_imm(all, true)));
            } else {
                self.emit(a::mov_reg(true, act, m));
            }
        }
        if cs {
            // The packed lanes must fit from start.
            self.emit(a::fmov_gv(true, true, 30, act));
            self.emit(a::cnt8b(30, 30));
            self.emit(a::addv8b(30, 30));
            self.emit(a::fmov_gv(false, false, x, 30));
            let w0 = self.code.len() as u32;
            self.emit(a::addsub_reg(true, 1, true, ix, len, st, 0, 0));
            self.emit(a::bcond(a::LO, 0));
            self.emit(a::addsub_reg(true, 1, true, a::ZR, ix, x, 0, 0));
            let w1 = self.code.len() as u32;
            self.emit(a::bcond(a::HS, 0));
            self.here(w0 + 1);
            self.emit(a::mov_reg(true, a::IP0, x));
            self.emit(a::mov_reg(true, a::IP1, st));
            self.emit(a::mov_reg(true, 2, len));
            self.emit(a::mov_reg(true, 0, a::IP0));
            self.emit(a::mov_reg(true, 1, a::IP1));
            self.call_rt("__sc_vec_bounds");
            self.here(w1);
        }
        let unchecked = c == core::SIMD_GATHER_UNCHECKED;
        if sl && !cs && !unchecked {
            for k in 0..n {
                let w0 = self.code.len() as u32;
                self.emit(a::tbz(false, act, k, 0));
                if gat {
                    self.ld_lane(ix, ops[1], k, lane_type(tys[1]), false, false);
                    self.emit(a::addsub_reg(true, 1, true, a::ZR, ix, len, 0, 0));
                    let w1 = self.code.len() as u32;
                    self.emit(a::bcond(a::LO, 0));
                    self.lane_oob(k, ix, len, false);
                    self.here(w1);
                } else {
                    // start + k < len, without overflow: start <= len and k < len - start.
                    self.emit(a::addsub_reg(true, 1, true, ix, len, st, 0, 0));
                    let w1 = self.code.len() as u32;
                    self.emit(a::bcond(a::LO, 0));
                    self.emit(a::cmp_imm(true, ix, k));
                    let w2 = self.code.len() as u32;
                    self.emit(a::bcond(a::HI, 0));
                    self.here(w1);
                    self.lane_oob(k, st, len, true);
                    self.here(w2);
                }
                self.here(w0);
            }
        }
        // A load starts from the fallback lanes.
        let mut d: i64 = 0;
        if !store {
            d = self.mdef(i);
            let (bf, of) = self.mloc(vv);
            self.copy_mem(a::SP, d, bf, of, type_bytes(vt, 8));
        }
        let lk = lane_ld(lt, false, true);
        let sk = lane_st(lt, true);
        let s = eb.trailing_zeros() as u32;
        if cs {
            self.emit(a::mov_reg(true, ix, st));
        }
        for k in 0..n {
            let w0 = self.code.len() as u32;
            self.emit(a::tbz(false, act, k, 0));
            // The element's address into `ix` (with `p`), or for the pointer forms lane k's pointer.
            let base = if ptrs {
                self.mem(a::M_X, true, ix, p, k * 8);
                ix;
            } else {
                p;
            };
            if !ptrs {
                if gat {
                    self.ld_lane(ix, ops[1], k, lane_type(tys[1]), false, false);
                } else if !cs {
                    if sl {
                        self.emit(a::add_imm(true, ix, st, k));
                    } else {
                        self.mov_imm(ix, k, true);
                    }
                }
            }
            if store {
                self.ld_lane(x, vv, k, lt, false, true);
                if ptrs {
                    self.emit(a::ldst_uimm(sk, false, x, base, 0));
                } else {
                    self.emit(a::ldst_reg(sk, false, x, base, ix, s != 0));
                }
            } else {
                if ptrs {
                    self.emit(a::ldst_uimm(lk, true, x, base, 0));
                } else {
                    self.emit(a::ldst_reg(lk, true, x, base, ix, s != 0));
                }
                self.st_lane(x, d, k, lt, true);
            }
            if cs {
                self.emit(a::add_imm(true, ix, ix, 1));
            }
            self.here(w0);
        }
        if cs && t.ty != T_NONE {
            // The active lane count.
            let rd = self.def(i);
            self.emit(a::addsub_reg(true, 1, false, rd, ix, st, 0, 0));
        }
    }

    // The bounds trap of lane `k`: element `x` (+ k from start when `start`) of `len`.
    fn lane_oob(self: &mut Self, k: u32, x: u8, len: u8, start: bool) {
        self.emit(a::mov_reg(true, a::IP0, x));
        self.emit(a::mov_reg(true, a::IP1, len));
        self.mov_imm(0, k, true);
        self.emit(a::mov_reg(true, 1, a::IP0));
        self.emit(a::mov_reg(true, 2, a::IP1));
        self.mov_imm(3, start as u64, true);
        self.call_rt("__sc_lane_bounds");
    }

    // A direct call of runtime function `name` (its arguments placed).
    fn call_rt(self: &mut Self, name: str) {
        let s = self.obj().sym(name);
        self.reloc(a::R_BRANCH26, s, 0);
        self.emit(a::bl(0));
    }
}

// The bits of lane type `lt` (a float) holding the integer `k`.
const fn float_bits(lt: u8, k: u32) u64 {
    if lt == T_F32 {
        return fl::f32_bits(k as f32);
    }
    return fl::f64_bits(k as f64);
}

// The low `n` bits of `x` (n up to 64).
const fn trunc64(x: u64, n: u32) u64 {
    if n >= 64 {
        return x;
    }
    return x & (1u64 << n as u64) - 1;
}

// The condition of integer comparison rule `c` (SIMD_CMP_EQ .. SIMD_CMP_GE) after `cmp`.
const fn int_cond(c: u8, sg: bool) u32 {
    if c == core::SIMD_CMP_EQ {
        return a::EQ;
    }
    if c == core::SIMD_CMP_NE {
        return a::NE;
    }
    if c == core::SIMD_CMP_LT {
        return if sg {
            a::LT;
        } else {
            a::LO;
        };
    }
    if c == core::SIMD_CMP_LE {
        return if sg {
            a::LE;
        } else {
            a::LS;
        };
    }
    if c == core::SIMD_CMP_GT {
        return if sg {
            a::GT;
        } else {
            a::HI;
        };
    }
    return if sg {
        a::GE;
    } else {
        a::HS;
    };
}

// The condition of float comparison rule `c` after `fcmp`: ordered, but `!=` holds for a NaN.
const fn float_cond(c: u8) u32 {
    if c == core::SIMD_CMP_EQ {
        return a::EQ;
    }
    if c == core::SIMD_CMP_NE {
        return a::NE;
    }
    if c == core::SIMD_CMP_LT {
        return a::MI;
    }
    if c == core::SIMD_CMP_LE {
        return a::LS;
    }
    if c == core::SIMD_CMP_GT {
        return a::GT;
    }
    return a::GE;
}

extend Gen {
    // The reductions and `dot` (the evaluator's `vreduce`): a left-to-right fold, the halving tree, the
    // lowest extreme lane, or the exact-result test; the result into instruction `i`'s register.
    fn vreduce(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let vt = tys[0];
        let lt = lane_type(vt);
        let n = lanes(vt);
        let x = self.tmp(false);
        let y = self.tmp(false);
        let z = self.tmp(false);
        if c == core::SIMD_REDUCE_ADD_OVF || c == core::SIMD_REDUCE_MUL_OVF {
            self.reduce_ovf(i, c == core::SIMD_REDUCE_ADD_OVF, ops[0], lt, sg, x, y, z);
            return;
        }
        if c >= core::SIMD_ARG_MIN && c <= core::SIMD_ARG_MAX_NUM {
            self.reduce_arg(i, c == core::SIMD_ARG_MIN || c == core::SIMD_ARG_MIN_NUM, ops[0], lt, sg, x, y, z);
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
        let acc = self.tmp(false);
        if dot {
            self.emit(a::mov_reg(true, acc, a::ZR));
        } else {
            self.ld_lane(acc, ops[0], 0, lt, sg, false);
        }
        let from: u32 = if dot {
            0;
        } else {
            1;
        };
        let lt_c = if sg {
            a::LT;
        } else {
            a::LO;
        };
        for k in from..n {
            self.ld_lane(x, ops[0], k, lt, sg, false);
            if dot {
                self.ld_lane(y, ops[1], k, lt, sg, false);
                self.emit(a::madd(true, false, acc, x, y, acc));
            } else if c == core::SIMD_REDUCE_AND || c == core::SIMD_REDUCE_OR || c == core::SIMD_REDUCE_XOR {
                self.emit(a::logic_reg(true, c - core::SIMD_REDUCE_AND, false, acc, acc, x, 0, 0));
            } else if add {
                self.emit(a::addsub_reg(true, 0, false, acc, acc, x, 0, 0));
            } else if mul {
                self.emit(a::mul(true, acc, acc, x));
            } else {
                // min takes a lane below the accumulator, max one not below: both stay extended.
                self.emit(a::addsub_reg(true, 1, true, a::ZR, x, acc, 0, 0));
                if c == core::SIMD_REDUCE_MIN {
                    self.emit(a::csel(true, 0, 0, acc, x, acc, lt_c));
                } else {
                    self.emit(a::csel(true, 0, 0, acc, acc, x, lt_c));
                }
            }
        }
        let rd = self.def(i);
        self.emit(a::mov_reg(true, rd, acc));
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
        let fop = if add {
            a::FP_ADD;
        } else {
            a::FP_MUL;
        };
        if c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_MUL_TREE {
            // Halves in a scratch copy: lane j of the lower half with lane j of the upper, to one lane.
            let eb = type_bytes(lt, 8);
            let s = self.slot_alloc(n * eb, 16) as i64;
            let (b0, o0) = self.mloc(ops[0]);
            self.copy_mem(a::SP, s, b0, o0, n * eb);
            let mut h = n / 2;
            while h != 0 {
                for j in 0..h {
                    self.mem(mkind(lt, true), true, fa, a::SP, s + (j * eb) as i64);
                    self.mem(mkind(lt, true), true, fb, a::SP, s + ((j + h) * eb) as i64);
                    self.emit(a::fp2(dd, fop, fa - V0, fa - V0, fb - V0));
                    self.mem(mkind(lt, false), false, fa, a::SP, s + (j * eb) as i64);
                }
                h = h / 2;
            }
            let rd = self.def(i);
            self.mem(mkind(lt, true), true, rd, a::SP, s);
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
                    self.emit(a::fcvt(true, fa - V0, fa - V0));
                    self.emit(a::fcvt(true, fb - V0, fb - V0));
                }
                self.emit(a::fp2(dd, a::FP_MUL, fa - V0, fa - V0, fb - V0));
            }
            if fold {
                self.emit(a::fp2(dd, fop, acc - V0, acc - V0, fa - V0));
            } else {
                // The kept operand itself, as the lane rule's.
                self.fminmax(dd, lo, c >= core::SIMD_REDUCE_MINIMUM, false, acc, acc, fa, fb);
            }
        }
        let rd = self.def(i);
        self.emit(a::fmov(dd, rd - V0, acc - V0));
    }

    // `reduce_add_ovf` (`add`) or `reduce_mul_ovf` of vector `v` (lanes of `lt`, signed `sg`): 1 when the
    // exact sum or product does not fit the lane type (the evaluator's `exact_fits`).
    fn reduce_ovf(self: &mut Self, i: u32, add: bool, v: Value, lt: u8, sg: bool, x: u8, y: u8, z: u8) {
        let lb = type_bits(lt, 8);
        let n = lanes(self.vt(v));
        let lo = self.tmp(false);
        let hi = self.tmp(false);
        let rd = self.def(i);
        let ip0 = a::IP0 as u8;
        if add {
            // The sum in 128 bits: lo, and hi taking each lane's sign and carry.
            self.emit(a::mov_reg(true, lo, a::ZR));
            self.emit(a::mov_reg(true, hi, a::ZR));
            for k in 0..n {
                self.ld_lane(x, v, k, lt, sg, false);
                if sg {
                    self.emit(a::asr_imm(true, y, x, 63));
                } else {
                    self.emit(a::mov_reg(true, y, a::ZR));
                }
                self.emit(a::addsub_reg(true, 0, true, lo, lo, x, 0, 0));
                self.emit(a::adc(true, 0, false, hi, hi, y));
            }
            // Not fitting: signed, hi is not lo's sign or lo leaves the lane; unsigned, hi is not 0 or lo
            // leaves the lane.
            if sg {
                self.emit(a::addsub_reg(true, 1, true, a::ZR, hi, lo, 2, 63));
                self.emit(a::cset(true, rd, a::NE));
                if lb < 64 {
                    self.emit(a::sxt(true, z, lo, lb));
                    self.emit(a::addsub_reg(true, 1, true, a::ZR, z, lo, 0, 0));
                    self.emit(a::cset(true, ip0, a::NE));
                    self.emit(a::logic_reg(true, 1, false, rd, rd, ip0, 0, 0));
                }
            } else {
                self.emit(a::cmp_imm(true, hi, 0));
                self.emit(a::cset(true, rd, a::NE));
                if lb < 64 {
                    self.emit(a::lsr_imm(true, z, lo, lb));
                    self.emit(a::cmp_imm(true, z, 0));
                    self.emit(a::cset(true, ip0, a::NE));
                    self.emit(a::logic_reg(true, 1, false, rd, rd, ip0, 0, 0));
                }
            }
            return;
        }
        // The product of the magnitudes: `hi` gathers the bits past 64, `y` the sign, `z` the zero lanes.
        self.mov_imm(lo, 1, true);
        self.emit(a::mov_reg(true, hi, a::ZR));
        self.emit(a::mov_reg(true, y, a::ZR));
        self.emit(a::mov_reg(true, z, a::ZR));
        for k in 0..n {
            self.ld_lane(x, v, k, lt, sg, false);
            if sg {
                self.emit(a::logic_reg(true, 2, false, y, y, x, 1, 63));
                self.emit(a::cmp_imm(true, x, 0));
                self.emit(a::csel(true, 1, 1, x, x, x, a::GE));
            }
            self.emit(a::cmp_imm(true, x, 0));
            self.emit(a::csel(true, 0, 1, z, z, z, a::NE));
            self.emit(a::mulh(false, ip0, lo, x));
            self.emit(a::logic_reg(true, 1, false, hi, hi, ip0, 0, 0));
            self.emit(a::mul(true, lo, lo, x));
        }
        // Not fitting: past 64 bits, or the magnitude past the limit (the negative limit one more).
        let lim = if sg {
            1u64 << (lb - 1) as u64;
        } else {
            trunc64(~0u64, lb);
        };
        self.mov_imm(ip0, lim, true);
        self.emit(a::addsub_reg(true, 1, true, a::ZR, lo, ip0, 0, 0));
        self.emit(a::cset(true, rd, a::HI));
        if sg {
            // lo == lim fits only negative.
            self.emit(a::cset(true, ip0, a::EQ));
            self.emit(a::logic_reg(true, 0, true, ip0, ip0, y, 0, 0));
            self.emit(a::logic_reg(true, 1, false, rd, rd, ip0, 0, 0));
        }
        self.emit(a::cmp_imm(true, hi, 0));
        self.emit(a::cset(true, ip0, a::NE));
        self.emit(a::logic_reg(true, 1, false, rd, rd, ip0, 0, 0));
        // A zero lane: the product is 0, which fits.
        self.emit(a::cmp_imm(true, z, 0));
        self.emit(a::csel(true, 0, 0, rd, a::ZR, rd, a::NE));
    }

    // `arg_min` (`min`) or `arg_max` and their `_num` forms of vector `v`: the lowest lane whose value beats
    // every lane before it; a NaN lane never does, -0.0 is below +0.0; the lane count when none.
    fn reduce_arg(self: &mut Self, i: u32, min: bool, v: Value, lt: u8, sg: bool, x: u8, y: u8, z: u8) {
        let n = lanes(self.vt(v));
        let lb = type_bits(lt, 8);
        let rd = self.def(i);
        if !is_float(lt) {
            // The best value in `y`; a strictly better lane takes over.
            let c = if min && sg {
                a::LT;
            } else if min {
                a::LO;
            } else if sg {
                a::GT;
            } else {
                a::HI;
            };
            self.mov_imm(rd, 0, true);
            self.ld_lane(y, v, 0, lt, sg, false);
            for k in 1..n {
                self.ld_lane(x, v, k, lt, sg, false);
                self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
                self.emit(a::csel(true, 0, 0, y, x, y, c));
                self.mov_imm(z, k, true);
                self.emit(a::csel(true, 0, 0, rd, z, rd, c));
            }
            return;
        }
        let dd = lt == T_F64;
        let fa = self.tmp(true);
        let fb = self.tmp(true);
        self.mov_imm(rd, n, true);
        let mut skips = Vector::<u32>::new();
        let mut takes = Vector::<u32>::new();
        for k in 0..n {
            skips.truncate(0);
            takes.truncate(0);
            self.ld_lane(fa, v, k, lt, false, false);
            self.emit(a::fcmp(dd, fa - V0, fa - V0));
            skips.push(self.code.len() as u32);
            self.emit(a::bcond(a::VS, 0));
            if k != 0 {
                // No best yet, or strictly beyond the best: take; equal with the lane's sign on the min
                // side: take; else skip.
                self.emit(a::cmp_imm(true, rd, n));
                takes.push(self.code.len() as u32);
                self.emit(a::bcond(a::EQ, 0));
                self.emit(a::fcmp(dd, fa - V0, fb - V0));
                takes.push(self.code.len() as u32);
                self.emit(
                    a::bcond(
                        if min {
                            a::MI;
                        } else {
                            a::GT;
                        },
                        0,
                    ),
                );
                skips.push(self.code.len() as u32);
                self.emit(a::bcond(a::NE, 0));
                self.emit(a::fmov_gv(dd, false, x, fa - V0));
                self.emit(a::fmov_gv(dd, false, y, fb - V0));
                self.emit(a::logic_reg(true, 2, false, z, x, y, 0, 0));
                skips.push(self.code.len() as u32);
                self.emit(a::tbz(false, z, lb - 1, 0));
                skips.push(self.code.len() as u32);
                self.emit(a::tbz(!min, x, lb - 1, 0));
            }
            for q in 0..takes.len() {
                self.here(takes[q]);
            }
            self.emit(a::fmov(dd, fb - V0, fa - V0));
            self.mov_imm(rd, k, true);
            for q in 0..skips.len() {
                self.here(skips[q]);
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
        let s = eb.trailing_zeros() as u32;
        let x = self.tmp(false);
        let ix = self.tmp(false);
        let ad = self.tmp(false);
        if rule == core::SR_MASKED {
            // From `fill`, then compress: the active lanes of v from position 0; expand: active lane j takes
            // the next packed lane.
            let d = self.mdef(i);
            let (bf, of) = self.mloc(ops[2]);
            self.copy_mem(a::SP, d, bf, of, n * eb);
            let m = self.reg(ops[0]);
            self.emit(a::mov_reg(true, ix, a::ZR));
            // The packed side's base address: the result for compress, v for expand.
            if c == core::SIMD_COMPRESS {
                self.add_off(ad, a::SP, d);
            } else {
                let (bv, ov) = self.mloc(ops[1]);
                self.add_off(ad, bv, ov);
            }
            for k in 0..n {
                let w0 = self.code.len() as u32;
                self.emit(a::tbz(false, m, k, 0));
                if c == core::SIMD_COMPRESS {
                    self.ld_lane(x, ops[1], k, lt, false, true);
                    self.emit(a::ldst_reg(lane_st(lt, true), false, x, ad, ix, s != 0));
                } else {
                    self.emit(a::ldst_reg(lane_ld(lt, false, true), true, x, ad, ix, s != 0));
                    self.st_lane(x, d, k, lt, true);
                }
                self.emit(a::add_imm(true, ix, ix, 1));
                self.here(w0);
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
            self.emit(a::mov_reg(true, mk, a::ZR));
            let ilt = lane_type(tys[1]);
            for k in 0..cnt {
                self.ld_lane(ix, ops[1], k, ilt, false, false);
                self.emit(a::cmp_imm(true, ix, n));
                self.mask_bit(mk, a::HS, k, x);
            }
            return;
        }
        let d = self.mdef(i);
        if rule == core::SR_INDEX {
            for k in 0..cnt {
                let j = self.b().pool[(t.c + 1 + k) as usize];
                if j < n {
                    self.ld_lane(x, ops[0], j, lt, false, true);
                } else if c == core::SIMD_SHUFFLE {
                    self.ld_lane(x, ops[1], j - n, lt, false, true);
                } else {
                    self.emit(a::mov_reg(true, x, a::ZR));
                }
                self.st_lane(x, d, k, lt, true);
            }
            return;
        }
        // `swizzle_or_zero`: lane k is v[idx[k]], or 0 past the lanes (the index clamped before the load).
        let ilt = lane_type(tys[1]);
        let (bv, ov) = self.mloc(ops[0]);
        self.add_off(ad, bv, ov);
        for k in 0..cnt {
            self.ld_lane(ix, ops[1], k, ilt, false, false);
            self.emit(a::cmp_imm(true, ix, n));
            self.emit(a::csel(true, 0, 0, ix, ix, a::ZR, a::LO));
            self.emit(a::ldst_reg(lane_ld(lt, false, true), true, x, ad, ix, s != 0));
            self.emit(a::csel(true, 0, 0, x, x, a::ZR, a::LO));
            self.st_lane(x, d, k, lt, true);
        }
    }
}

extend Gen {
    // The text of body message `m`.
    const fn msg_text(self: &Self, m: u32) str {
        let p = unsafe &*self.pkg;
        return p.spell(p.msgs[self.b().msgs[m as usize] as usize]);
    }

    // Inline assembly (`O_ASM`), as GCC compiles it: the operands take the free ones of x0..x15 and
    // v0..v7, v16..v29 in order, past the clobbered ones (a memory operand the register of its address,
    // a matching input its output's); a value in one of those or in a clobbered register goes to its
    // home first, the others stay. The template's operand references name the registers, and each
    // output register goes to its address after. A clobbered callee-saved register is saved by the
    // prologue and, when it holds a value, around the statement.
    fn asm_inst(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let r = t.c;
        let no = asm_nout(b, r);
        let ni = asm_nin(b, r);
        let n = no + ni;
        // Per operand: its class (`AK_*`), register, type and immediate.
        let mut cls = Vector::<u8>::new();
        let mut reg = Vector::<u8>::new();
        let mut tys = Vector::<u8>::new();
        let mut imm = Vector::<i64>::new();
        let mut plus = Vector::<bool>::new();
        let mut clob: u64 = 0;
        for k in 0..asm_nclob(b, r) {
            let cr = clobber_reg(self.msg_text(asm_clob(b, r, k)));
            if cr != NOREG {
                clob |= bit(cr);
            }
        }
        let mut taken = clob;
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
            let mut pl = false;
            let mut tie: u32 = NONE;
            for j in 0..con.len() {
                let ch = con.byte_at(j);
                if ch == b'+' {
                    pl = true;
                } else if ch == b'r' {
                    c = AK_GP;
                } else if ch == b'w' {
                    c = AK_FP;
                } else if ch == b'm' || ch == b'Q' {
                    c = AK_MEM;
                } else if ch == b'i' || ch == b'n' || ch >= b'I' && ch <= b'N' {
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
            }
            if c == 0xFF {
                return self.refuse("an asm constraint this generator does not take");
            }
            if c == AK_FP && !is_float(ty) || k < no && c == AK_IMM {
                return self.refuse("an asm operand of the wrong class for its type");
            }
            let mut rg: u8 = NOREG;
            if tie != NONE {
                rg = reg[tie as usize];
            } else if c != AK_IMM {
                let free = if c == AK_FP {
                    valloc();
                } else {
                    XALLOC;
                } & ~taken;
                if free == 0 {
                    return self.refuse("an asm with more register operands than the free registers");
                }
                rg = free.trailing_zeros() as u8;
                taken |= bit(rg);
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
        }
        // The registers the statement writes: the caller-saved ones free, the callee-saved ones kept.
        let mut ev = taken & (XALLOC | valloc());
        // Each step clears one register's bit: at most 64 steps.
        while ev != 0 {
            let er = ev.trailing_zeros() as u8;
            ev &= ev - 1;
            self.evict(er);
        }
        let keep = taken & (XFIX | vfix());
        self.csr |= keep;
        // A callee-saved register that holds a value is saved to a slot of its own around the statement.
        let mut saved = Vector::<(u8, i64)>::new();
        let mut m = keep & self.held;
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let cr = m.trailing_zeros() as u8;
            m &= m - 1;
            let off = self.slot_alloc(16, 16) as i64;
            self.mem(
                if cr >= V0 {
                    a::M_VQ;
                } else {
                    a::M_X;
                },
                false,
                cr,
                a::SP,
                off,
            );
            saved.push((cr, off));
        }
        // The operands into their registers: inputs, a `+` output's value, a memory operand's address.
        let mut mem_slots = Vector::<i64>::new();
        for k in 0..n {
            let v = b.pool[(t.a + k) as usize];
            let c = cls[k as usize];
            let rg = reg[k as usize];
            if k < no {
                if c == AK_MEM {
                    self.materialize(v, rg);
                } else if plus[k as usize] {
                    self.materialize(v, a::IP0 as u8);
                    self.mem(mkind(tys[k as usize], true), true, rg, a::IP0, 0);
                }
                continue;
            }
            if c == AK_MEM {
                let off = self.slot_alloc(16, 16) as i64;
                let tr = if is_float(tys[k as usize]) {
                    V0 + 31;
                } else {
                    a::IP0 as u8;
                };
                self.materialize(v, tr);
                self.mem(mkind(tys[k as usize], false), false, tr, a::SP, off);
                self.add_off(rg, a::SP, off);
                mem_slots.push(off);
            } else if c != AK_IMM {
                self.materialize(v, rg);
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
            if c2 >= b'a' && c2 <= b'z' {
                md = c2;
                j += 1;
            }
            let st = j;
            let mut k: u32 = 0;
            while j < tpl.len() && tpl.byte_at(j) >= b'0' && tpl.byte_at(j) <= b'9' {
                k = k * 10 + (tpl.byte_at(j) - b'0') as u32;
                j += 1;
            }
            if j == st || k >= n {
                return self.refuse("an asm template names an operand it does not have");
            }
            if !asm_operand_text(&mut text, cls[k as usize], reg[k as usize], tys[k as usize], imm[k as usize], md) {
                return self.refuse("an asm operand modifier this generator does not take");
            }
        }
        let mut rels = Vector::<asmr::InlRel>::new();
        let mut e = String::new();
        if !asmr::Asm::inline_a64(text.as_str(), self.apple, &mut self.code, &mut rels, &mut e) {
            self.err.format_into("inline assembly: {}", e.as_str());
            return false;
        }
        for k in 0..rels.len() {
            let s = self.obj().sym(rels[k].name.as_str());
            self.rels.push(CRel { at: rels[k].at, kind: rels[k].kind, sym: s, addend: rels[k].addend });
        }
        for k in 0..saved.len() {
            let (cr, off) = saved[k];
            self.mem(
                if cr >= V0 {
                    a::M_VQ;
                } else {
                    a::M_X;
                },
                true,
                cr,
                a::SP,
                off,
            );
            self.free_slots.push(16u64 << 32 | (off as u32) as u64);
        }
        for k in 0..mem_slots.len() {
            self.free_slots.push(16u64 << 32 | (mem_slots[k] as u32) as u64);
        }
        // The outputs to their addresses.
        for k in 0..no {
            if cls[k as usize] == AK_MEM {
                continue;
            }
            self.materialize(b.pool[(t.a + k) as usize], a::IP0 as u8);
            self.mem(mkind(tys[k as usize], false), false, reg[k as usize], a::IP0, 0);
        }
        return true;
    }
}

// Inline assembly operand classes.
const AK_GP: u8 = 0; // an x or w register
const AK_FP: u8 = 1; // a v register as a float scalar
const AK_MEM: u8 = 2; // memory at the address an x register holds
const AK_IMM: u8 = 3; // an immediate

// Name operand register `rg` of class `c` and type `ty` into `o`, under modifier `md` (0: none; `w`,
// `x`, `b`, `h`, `s`, `d`, `q`); false for a modifier the class does not take.
fn asm_operand_text(o: &mut String, c: u8, rg: u8, ty: u8, k: i64, md: u8) bool {
    if c == AK_IMM {
        if md != 0 && md != b'c' {
            return false;
        }
        o.push_i64(k);
        return true;
    }
    if c == AK_MEM {
        o.format_into("[x{}]", rg);
        return md == 0;
    }
    if c == AK_GP {
        let wide = if md == 0 {
            ty == T_I64 || ty == T_PTR;
        } else {
            md == b'x';
        };
        if md != 0 && md != b'w' && md != b'x' {
            return false;
        }
        o.format_into(
            "{}{}",
            if wide {
                "x";
            } else {
                "w";
            },
            rg,
        );
        return true;
    }
    let l = if md != 0 {
        md;
    } else if ty == T_F64 {
        b'd';
    } else {
        b's';
    };
    if l != b'b' && l != b'h' && l != b's' && l != b'd' && l != b'q' && l != b'v' {
        return false;
    }
    o.push_byte(l);
    o.push_u64(rg - V0);
    return true;
}

// The register a clobber names (`x19`, `w19`, `d8`, `v8`, `q8`, `lr`), NOREG for none (`memory`, `cc`).
const fn clobber_reg(s: str) u8 {
    if s.len() < 2 {
        return NOREG;
    }
    if s == "lr" {
        return 30;
    }
    if s == "fp" {
        return 29;
    }
    let n = switch s.slice(1, s.len()).parse_u32() {
        Some(x) => x,
        None => 99u32,
    };
    if n > 31 {
        return NOREG;
    }
    let c = s.byte_at(0);
    if c == b'x' || c == b'w' {
        return n as u8;
    }
    if c == b'v' || c == b'd' || c == b's' || c == b'q' || c == b'b' || c == b'h' || c == b'z' {
        return V0 + n as u8;
    }
    return NOREG;
}
