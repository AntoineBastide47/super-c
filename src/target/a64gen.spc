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
import codegen::place;
import codegen::place as *;
import lir::verify as lver;
import codegen::obj as ob;
import codegen::dwarf as dw;
import target::a64 as a;
import target::aapcs64 as cc;
import codegen::abi as ab;
import ir::core as core;
import std::float as fl;
import target::assembler as asmr;
import target::intrin as intrin;

const V0: u8 = 32; // register number of v0: x registers are 0..31

// Register sets: bit `r` for register number `r`.
const XALLOC: u64 = 0xFFFF;
const XFIX: u64 = 0x1FF80000;
// The caller-saved x registers a value may hold for its whole range: x9..x15 (no argument register); in
// a body that calls nothing, x0..x8 too; in one that calls in rare blocks only, x2..x8 too (`Gen.scr`).
const XSCR: u64 = 0xFE00;
const XSCR_LEAF: u64 = 0xFFFF;
const XSCR_RARE: u64 = 0xFFFC;

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

// A pending condition: the flags hold the result of the instruction before, which a branch or select
// right after reads instead of a value.
struct Cond {
    pub(package) inst: u32, // the instruction whose value (or flag) it stands for, NONE without one
    pub(package) cc: u32, // the condition code; `cc2` too when not NONE (a float compare of two conditions)
    pub(package) cc2: u32,
}

extend Cond as Copy {}

/// The arm64 generator of one object.
pub(package) struct Gen {
    pub(package) err: String, // the first refusal, empty when every body compiled
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
    rstore: Vector<u32>, // per instruction, 1 + the result part a store moves into its register (`ret_stores`), else 0
    rr: u32, // the eviction cursor
    pos: u32, // the layout position of the block being compiled
    cur: u32, // the instruction being compiled
    paired: u32, // the access the one before it took into an `ldp` or `stp` (NONE: none)
    taken: Vector<u64>, // the loads of a register-passed aggregate that take its registers (`parts_taken`): part << 32 | load
    csave: Vector<(u8, i64)>, // the scratch homes saved around a rare call (`save_scratch`)
    rarec: Vector<bool>, // per instruction, a call that returns in a rare block (`call_tables`)
    cret: Vector<bool>, // per instruction, a call that returns (`clobbers`, not `dead_end`; `call_tables`)
    hform: Vector<bool>, // per instruction, whether it computes in binary16 (`half_forms`)
    shared: Vector<u32>, // the block parameters that share a header parameter's slot (`back_share`)
    scr: u64, // the x registers that may be scratch homes (`plan_homes`): XSCR_LEAF, XSCR_RARE or XSCR
    dying: Vector<u32>, // values whose register frees after the current instruction
    wparams: Vector<u32>, // the parameters the current terminator's edges write
    want: Vector<u8>, // per value, its request to `Live::plan`
    lconst: Vector<bool>, // per instruction, a constant a loop keeps in a register (`Live::loop_consts`)
    vmem: Vector<bool>, // per value, a vector some instruction reads or writes in memory (`vec_homes`)
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
    // Without a frame pointer, nothing reaches the caller's frame through x29: the body keeps no frame
    // record when its code calls nothing (`finish`).
    frameless: bool,
    sret_off: i64, // the slot of x8 for a vector result in memory, -1 when none
    canary: i64, // the stack canary's slot above the LIR slots, -1 when none
    // The register save area of a variadic body under the standard convention (x0..x7 at its start,
    // then q0..q7), NONE when none.
    va_save: u32,
    // Labels.
    blk_at: Vector<u32>, // per block, its first word, NONE before it is compiled
    fix: Vector<u64>, // word << 32 | block: a branch to patch
    // A conditional branch to a block is an inverted one over a `B`: the function is past the 1 MiB a
    // conditional branch reaches (`func`).
    far: bool,
    // Shrink-wrapping: the frame is set up on the edges into the rare blocks and taken down on the edges out
    // (`shrinkable`); the warm code, which calls nothing, keeps no value in memory and no callee-saved
    // register, has none. Whether the body is compiled so, whether it touched the frame in a warm block
    // (`frame_use`: the body is compiled again without), and whether that try failed.
    shrink: bool,
    shrink_bad: bool,
    no_shrink: bool,
    again: bool, // the next `func` compiles the body it compiled last again (`unshrunk`, `far`)
    prot: bool, // the body has a stack canary (`lver::protected`)
    opf: u8, // the body's `lv::op_flags`
    epi: Vector<u32>, // branches to the epilogue
    // The sibling calls (`sibling`): the word of each one's branch << 32 | its callee's object symbol
    // (NONE: the callee in x16); whether the body may make them; the return they replace.
    tails: Vector<u64>,
    tail_ok: bool,
    tail_ret: u32,
    rels: Vector<CRel>,
    osym: Vector<u32>, // per package symbol, its object symbol in this generator's object (NONE until used)
    // Calls.
    lay: ab::CallLayout,
    // Per symbol of the body at hand, its intrinsic's instructions (`intrin::of_symbols`); per signature
    // a call of it takes, its layout (`call_layout`: `lays[q]` for `lay_sig[q]`, the first `nlay`).
    itpl: Vector<str<'static>>,
    lays: Vector<ab::CallLayout>,
    lay_sig: Vector<u32>,
    self_lay: ab::CallLayout,
    uses: Vector<Value>,
    mv: Vector<Mv>,
    local: bool, // the function compiling is a local copy
    cs: ob::CStrs, // the object's C strings
}

extend Gen {
    pub(package) fn new(pkg: &Package, o: &mut ob::Obj, apple: bool, elf: bool) Gen {
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
            rstore: Vector::<u32>::new(),
            rr: 0,
            pos: 0,
            cur: 0,
            paired: NONE,
            taken: Vector::<u64>::new(),
            csave: Vector::<(u8, i64)>::new(),
            rarec: Vector::<bool>::new(),
            cret: Vector::<bool>::new(),
            hform: Vector::<bool>::new(),
            shared: Vector::<u32>::new(),
            scr: XSCR,
            dying: Vector::<u32>::new(),
            wparams: Vector::<u32>::new(),
            want: Vector::<u8>::new(),
            lconst: Vector::<bool>::new(),
            vmem: Vector::<bool>::new(),
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
            frameless: false,
            sret_off: -1,
            canary: -1,
            va_save: NONE,
            blk_at: Vector::<u32>::new(),
            fix: Vector::<u64>::new(),
            far: false,
            shrink: false,
            shrink_bad: false,
            no_shrink: false,
            again: false,
            prot: false,
            opf: 0,
            epi: Vector::<u32>::new(),
            tails: Vector::<u64>::new(),
            tail_ok: false,
            tail_ret: NONE,
            rels: Vector::<CRel>::new(),
            osym: Vector::<u32>::new(),
            lay: ab::CallLayout::new(),
            itpl: Vector::<str<'static>>::new(),
            lays: Vector::<ab::CallLayout>::new(),
            lay_sig: Vector::<u32>::new(),
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

    // Whether `v` is an instruction value the generator recomputes at each use.
    const fn remat_inst(self: &Self, v: Value) bool {
        return lv::remat_inst(unsafe &*self.pkg, self.b(), v);
    }

    // Whether body symbol `s` is a thread-local variable.
    const fn tls_sym(self: &Self, s: u32) bool {
        return lv::tls_sym(unsafe &*self.pkg, self.b(), s);
    }

    // Whether `v` is an integer constant; its bits in `out`.
    const fn const_of(self: &Self, v: Value, out: &mut u64) bool {
        return lv::const_of(self.b(), v, out);
    }

    // ---- Registers ----

    // A free register of file `vreg`, evicting another value's when none is.
    fn alloc(self: &mut Self, vreg: bool) u8 {
        let set = if vreg {
            valloc()
        } else {
            XALLOC
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
                s + (busy >> s as u64).trailing_zeros() as u32
            } else {
                busy.trailing_zeros() as u32
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
        let vr = is_v(self.vt(v)) || in_vreg(self.vt(v));
        let r = self.take_home(x, vr, NOREG);
        if r != NOREG {
            self.lock |= bit(r);
            return r;
        }
        let n = self.next_reg(v, 0);
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

    // The register the instruction after instruction `v` in its block takes `v` in, when that is `v`'s
    // only use: a call's scalar register argument, or the result; so `v` is there for it. NOREG when not,
    // or when a value (but one in `free`) or the current instruction holds that register.
    fn next_reg(self: &mut Self, v: Value, free: u64) u8 {
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
        if r == NOREG || (((self.held | self.lock) & ~free | self.tmps | self.fixed_busy) & bit(r)) != 0 || (XALLOC & bit(
            r,
        )) == 0 {
            return NOREG;
        }
        return r;
    }

    // `def_step` of instruction `i` into the register the next instruction takes it in (`next_reg`) when a
    // value that dies at `i` holds that register: `i`'s one machine instruction reads it before it writes.
    // NOREG when not.
    fn take_dying(self: &mut Self, i: u32) u8 {
        let mut free: u64 = 0;
        for k in 0..self.dying.len() {
            let x = self.dying[k];
            let va = self.va[x as usize];
            if va.reg != NOREG && (XALLOC & bit(va.reg)) != 0 && self.owner[va.reg as usize] == x {
                free |= bit(va.reg);
            }
        }
        if free == 0 || self.va[i as usize].home != H_NONE || self.fix_class(i) != FIX_NONE {
            return NOREG;
        }
        let r = self.next_reg(i, free);
        if r == NOREG || (free & bit(r)) == 0 {
            return NOREG;
        }
        self.drop_reg(self.owner[r as usize]);
        self.bind(i, r);
        return r;
    }

    // Value index `x`, which dies at the current instruction, gives up its register to the result: a
    // register home (a caller-saved one, which `take_scratch` would evict a value from) frees too.
    fn drop_reg(self: &mut Self, x: u32) {
        if self.va[x as usize].home == H_FIXED {
            self.fixed_busy &= ~bit(self.va[x as usize].reg);
        }
        self.va.index_mut(x as usize).reg = NOREG;
        self.va.index_mut(x as usize).dirty = false;
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

    // A register for the result of value `v` that holds operand `a`'s bits (in `ra`), for an instruction
    // that only gives them another type: `ra` itself when `a` dies here and `v` takes no fixed home, else
    // a copy of it.
    fn def_from(self: &mut Self, v: Value, a: Value, ra: u8) u8 {
        let x = self.vx(v);
        let xa = self.vx(a);
        let t = self.vt(v);
        let fixed = self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE;
        if !fixed && ((XALLOC | valloc()) & bit(ra)) != 0 && is_v(t) == ra >= V0 {
            let own = self.owner[ra as usize];
            let temp = own == NONE && (self.tmps & bit(ra)) != 0;
            let dies = own == xa && self.lv.uses[xa as usize] == 0 && self.lv.end[xa as usize] == self.pos;
            if temp || dies {
                if dies {
                    self.drop_reg(xa);
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

    // `def` of instruction `i`, one machine instruction that reads its operands before it writes its
    // result: the fixed register of a parameter the back edge ending `i`'s block passes `i` to
    // (`Live::back_param`), when nothing in the block reads that parameter after `i` (a loop counter's
    // step, an accumulator), so the edge's move vanishes. The parameter's old value is dead from `i` on;
    // the register is the parameter's over the whole loop. When `i` dies in its block, the parameter
    // keeps the register, which its release frees; when `i` outlives it (a rotated loop's exit reads
    // it) and the parameter's range ends in this block, `i` takes the register over as its home. Not for
    // an `i` with a home of its own or that lives across a call (the register may be caller-saved: the
    // parameter's range need not hold the call).
    fn def_step(self: &mut Self, i: u32) u8 {
        let rd = self.take_dying(i);
        if rd != NOREG {
            return rd;
        }
        let b = self.b();
        let k = self.lv.def_blk[i as usize];
        let bk = b.blocks[k as usize];
        let tm = b.insts[(bk.start + bk.len - 1) as usize];
        let past = self.lv.end[i as usize] != self.pos;
        // A register home holds no vector an instruction reads in memory (`vec_homes`).
        if past && self.vmem[i as usize] {
            return self.def(i);
        }
        if self.lv.pos[k as usize] != self.pos || self.va[i as usize].home != H_NONE || !past && self.fix_class(i) != FIX_NONE || self.crosses_call(
            i,
        ) {
            return self.def(i);
        }
        let px = self.lv.back_param(b, tm, i, self.pos);
        if px == NONE && !past {
            return self.def_fwd(i, tm);
        }
        if px == NONE || self.va[px as usize].home != H_FIXED || self.lv.end[px as usize] < self.pos || past && self.lv.end[px as usize] != self.pos || self.lv.reads_after(
            b,
            k,
            i,
            VPARAM | px - b.insts.len() as u32,
        ) {
            return self.def(i);
        }
        let r = self.va[px as usize].reg;
        self.lock |= bit(r);
        if past {
            self.set_owner(r, i);
        }
        let w = self.va.index_mut(i as usize);
        w.reg = r;
        w.dirty = false;
        w.clean = false;
        if past {
            w.home = H_FIXED;
        }
        return r;
    }

    // `def_step` of instruction `i`, which dies in its block, whose block ends in jump `tm` to a later block,
    // passing `i` once: the register home of the parameter it passes `i` to (taken now when this is the
    // first edge into that block), when that register holds nothing, or holds the header parameter
    // `back_share` gave it and nothing after `i` reads that one, so the jump's move vanishes.
    fn def_fwd(self: &mut Self, i: u32, tm: Inst) u8 {
        let b = self.b();
        if tm.op != O_JMP {
            return self.def(i);
        }
        let j = b.edge_target(tm.a);
        if self.lv.pos[j as usize] == NONE || self.lv.pos[j as usize] <= self.pos {
            return self.def(i);
        }
        let ni = b.insts.len() as u32;
        let mut x = NONE;
        for q in 0..b.edge_nargs(tm.a) {
            if b.edge_arg(tm.a, q) == i {
                if x != NONE {
                    return self.def(i);
                }
                x = ni + b.blocks[j as usize].param_start + q;
            }
        }
        if x == NONE || self.xty(x) != self.vt(i) || in_mem(self.xty(x)) {
            return self.def(i);
        }
        self.param_home(x, NOREG);
        let va = self.va[x as usize];
        if va.home != H_FIXED || va.reg == NOREG || (self.tmps & bit(va.reg)) != 0 {
            return self.def(i);
        }
        let r = va.reg;
        let ov = self.owner[r as usize];
        if ov != x {
            let k = self.lv.def_blk[i as usize];
            if ov == NONE || ov < ni || self.lv.reads_after(b, k, i, VPARAM | ov - ni) {
                return self.def(i);
            }
            for q in 0..b.edge_nargs(tm.a) {
                if b.edge_arg(tm.a, q) == (VPARAM | ov - ni) {
                    return self.def(i);
                }
            }
        }
        self.lock |= bit(r);
        let w = self.va.index_mut(i as usize);
        w.reg = r;
        w.dirty = false;
        w.clean = false;
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

    // Plan the homes (`Live::plan`) over each value's request: none in memory or rematerialized; a callee-saved
    // register for a value a call that returns runs in the range of (v8..v15 keep only their low 8 bytes: no vector
    // asks); either for one that lives past its block or a block parameter (a flag: callee-saved only); none for the
    // others, which temporaries hold (an entry parameter that dies in the entry block stays in the register it arrives
    // in). A vector of 16 bytes that lives past its block or is a block parameter, which no call that returns runs in
    // the range of and no instruction reads or writes in memory (`vec_homes`: a loop's accumulator, a value splat
    // before the loop), asks a caller-saved v register. x19..x28 and v8..v15; six of x9..x15 and twelve of v16..v29,
    // the others left to temporaries.
    fn plan_homes(self: &mut Self) {
        let b = self.b();
        let n = self.lv.end.len();
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        self.lv.loop_consts(b, &mut self.lconst);
        // An integer that one instruction builds stays rematerialized; one of three or more instructions
        // that several blocks read is kept in a register too, loop or not.
        for x in 0..ni {
            let t = b.insts[x];
            if t.op != O_ICONST {
                continue;
            }
            let n = self.imm_insts(t.b as u64 << 32 | t.a as u64, type_bytes(t.ty, self.ptr) == 8);
            if n < 2 {
                self.lconst[x] = false;
            } else if n >= 3 && self.lv.uses[x] >= 2 && self.lv.def_blk[x] != NONE && self.lv.pos[self.lv.def_blk[x] as usize] != NONE && self.lv.end[x] > self.lv.pos[self.lv.def_blk[x] as usize] {
                self.lconst[x] = true;
            }
        }
        self.vec_homes();
        // A body that calls nothing that returns (no instruction `clobbers` but one before a trap, no
        // thread-local address's getter) and runs no system operation or variadic access: its homes may
        // take x0..x8; x2..x8 when it calls in rare blocks only, as a call's result arrives in x0 and x1,
        // where a home saved around it (`save_scratch`) would come back.
        let mut leaf = true;
        let mut rare = true;
        for x in 0..ni {
            let t = b.insts[x];
            let calls = self.cret[x];
            let other = t.op == O_SYS || t.op == O_VASTART || t.op == O_VAARG || t.op == O_SYMADDR && !self.remat_inst(
                x as u32,
            );
            leaf = leaf && !calls && !other;
            rare = rare && !(calls && !self.rarec[x]) && !other;
        }
        self.scr = if leaf {
            XSCR_LEAF
        } else if rare {
            XSCR_RARE
        } else {
            XSCR
        };
        self.want.truncate(0);
        for x in 0..n {
            let t = self.xty(x as u32);
            let d = self.lv.def_blk[x];
            let mut w: u8 = 0;
            if in_vreg(t) && type_bytes(t, 8) == 16 && x < nv && !self.vmem[x] && d != NONE && self.lv.pos[d as usize] != NONE && (self.lv.end[x] > self.lv.pos[d as usize] || x >= ni) && !self.crosses_call(
                x as u32,
            ) {
                w = lv::WANT_SCRATCH | lv::WANT_V;
            }
            if !in_mem(t) && d != NONE && self.lv.pos[d as usize] != NONE && !(x < ni && self.remat_inst(x as u32) && !self.lconst[x]) {
                if x < nv && self.crosses_call(x as u32) {
                    w = lv::WANT_CALLEE;
                } else if x >= nv && self.lv.end[x] > self.lv.pos[d as usize] {
                    w = lv::WANT_CALLEE;
                } else if self.lv.end[x] > self.lv.pos[d as usize] || x >= ni && x < nv && d != 0 {
                    w = lv::WANT_CALLEE | lv::WANT_SCRATCH;
                }
                if is_v(t) {
                    w |= lv::WANT_V;
                }
            }
            // Shrink-wrapped, the warm code saves no callee-saved register: every home is a scratch one, which
            // the rare calls save around them.
            if self.shrink && (w & lv::WANT_CALLEE) != 0 {
                w = w & ~lv::WANT_CALLEE | lv::WANT_SCRATCH;
            }
            self.want.push(w);
        }
        // Six of x0..x15 stay for temporaries in a leaf (no call's arguments, no masked vector access),
        // ten of them else.
        let xs: u32 = if self.scr != XSCR {
            10
        } else {
            6
        };
        // Twelve scratch homes of v16..v29 (the others, v30, v31 and v0..v7 stay for temporaries);
        // shrink-wrapped, no callee-saved home.
        let (xc, vc, vs) = if self.shrink {
            (0u32, 0u32, 12u32)
        } else {
            (10u32, 8u32, 12u32)
        };
        self.lv.plan(b, &self.want, lv::Caps { xc: xc, xs: xs, xj: 16, vc: vc, vs: vs, vj: 16 });
        for x in 0..ni {
            if self.lconst[x] && self.fix_class(x as u32) != FIX_NONE {
                self.va.index_mut(x).home = H_NONE;
            }
        }
    }

    // `vmem`: per value, whether it is a vector some instruction defines or reads in memory: any but a
    // vector load, a lane-wise operation with a Neon form (its operands too), a store of it, and an edge
    // argument (a return reads its vector in memory).
    fn vec_homes(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        self.vmem.truncate(0);
        self.vmem.resize_default(self.lv.end.len());
        for i in 0..ni {
            let t = b.insts[i];
            let mut un = false;
            let reg_op = is_vec(t.ty) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT) && neon_of_op(
                t.op,
                lane_type(t.ty),
                &mut un,
            ) != NONE || (t.op == O_SPLAT || t.op == O_VSEL || t.op == O_VUNZIP || t.op == O_VZIPLO || t.op == O_VZIPHI || t.op == O_WCONST || t.op == O_VINSERT) && in_vreg(
                t.ty,
            ) || (t.op == O_VCMP || t.op == O_VEXTRACT) && in_vreg(self.vt(t.a)) || t.op == O_VOP && self.vop_reg(t) || self.conv_reg(
                t,
            ) || (t.op == O_LSHR || t.op == O_ASHR) && is_vec(t.ty) && in_vreg(t.ty);
            if is_vec(t.ty) && !reg_op && t.op != O_LOAD {
                self.vmem[i] = true;
            }
            if t.op == O_RET && t.a != VNONE && is_vec(self.vt(t.a)) {
                // A returned vector is read in memory.
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

    // Whether `vop` `t` computes in v registers (`vlanes`' register forms, a bitcast, a shift by a scalar):
    // its vector operands and result need no memory.
    fn vop_reg(self: &Self, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        if t.b == 0 || t.c != VNONE {
            return false;
        }
        let t0 = self.vt(self.b().pool[t.a as usize]);
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            return in_vreg(t.ty) && t0 == t.ty;
        }
        if code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return false;
        }
        let c = (code - core::OP_SIMD) as u8;
        let rule = core::simd_op(c).rule;
        if rule == core::SR_BITCAST {
            return in_vreg(t.ty) && in_vreg(t0) && type_bytes(t.ty, 8) == type_bytes(t0, 8);
        }
        if c == core::SIMD_GATHER_UNCHECKED {
            return Gen::gather_reg(self.b(), t);
        }
        if c == core::SIMD_LOAD_MASKED_PTR || c == core::SIMD_STORE_MASKED_PTR {
            return Gen::masked_reg(self.b(), t);
        }
        if c == core::SIMD_ABS_DIFF {
            return in_vreg(t.ty) && in_vreg(t0) && type_bytes(lane_type(t0), 8) < 8;
        }
        if rule == core::SR_CHOOSE {
            return in_vreg(t.ty) && lanes(t.ty) >= 2;
        }
        let lt = lane_type(t0);
        if rule == core::SR_MASK {
            let fl = is_float(lt);
            let test = c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE || fl && (c == core::SIMD_IS_NAN || c == core::SIMD_IS_INF || c == core::SIMD_IS_FINITE || c == core::SIMD_IS_SIGN_NEG);
            return test && in_vreg(t0) && lanes(t0) >= 2;
        }
        let mut un = false;
        let mut fma = false;
        return rule == core::SR_VEC && in_vreg(t.ty) && neon_of_simd(
            c,
            lt,
            (t.aux & VOP_SIGNED) != 0,
            &mut un,
            &mut fma,
        ) != NONE;
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
            x + 1
        } else {
            bk.start
        };
        if e <= dp {
            return self.cpre[self.lv.last[x as usize] as usize] > self.cpre[from as usize];
        }
        return self.cpre[(bk.start + bk.len) as usize] > self.cpre[from as usize] || self.cpos[e as usize + 1] > self.cpos[dp as usize + 1];
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
        let mut m = self.held & self.fixed_busy & (XSCR_LEAF | vscr());
        // Each step clears one register's bit: at most 64 steps.
        while m != 0 {
            let r = m.trailing_zeros() as u8;
            m &= m - 1;
            if !self.live_on(self.owner[r as usize]) {
                continue;
            }
            let off = self.slot_alloc(16, 16) as i64;
            let m = if r >= V0 {
                a::M_VQ
            } else {
                a::M_X
            };
            self.mem(m, false, r, a::SP, off);
            self.csave.push((r, off));
        }
        return self.csave.len();
    }

    // After the instruction `save_scratch` saved `n` registers around: those registers back.
    fn restore_scratch(self: &mut Self, n: usize) {
        for k in 0..n {
            let (r, off) = self.csave[k];
            let m = if r >= V0 {
                a::M_VQ
            } else {
                a::M_X
            };
            self.mem(m, true, r, a::SP, off);
            self.free_slots.push(16u64 << 32 | (off as u32) as u64);
        }
        self.csave.truncate(0);
    }

    // `cpre` and `cpos`: the calls that return to a use (`clobbers`, not `dead_end`)
    // before each instruction index, and the blocks holding one before each layout position.
    // `hform`, with FEAT_FP16 (`Package.half`): an `fadd`, `fsub`, `fmul` or `fdiv` of two f32 values that
    // `O_HTOF`s give, whose one use is an `O_FTOH`, computes in binary16, and so does that `O_FTOH` (a move
    // out of the H register) and each such `O_HTOF` whose every use is such an operation (a move into the H
    // register): the same result, which binary16 rounds once either way. Each round unmarks the operations
    // with an operand that keeps its f32 form, at most one round per instruction.
    fn half_forms(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        self.hform.truncate(0);
        self.hform.resize_default(ni);
        if unsafe (*self.pkg).half != HALF_ARITH {
            return;
        }
        // Each value's uses: `Live::folds`' counts.
        let nuse = &self.lv.count;
        let mut ops = Vector::<u32>::new();
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_FTOH && (t.a & (VPARAM | VFLAG)) == 0 {
                let u = b.insts[t.a as usize];
                if u.op >= O_FADD && u.op <= O_FDIV && u.ty == T_F32 && half_conv_of(b, u.a) && half_conv_of(b, u.b) {
                    ops.push(i as u32);
                }
            }
        }
        for q in 0..ops.len() {
            let r = b.insts[ops[q] as usize].a as usize;
            if nuse[r] == 1 {
                self.hform[r] = true;
                self.hform[ops[q] as usize] = true;
            }
        }
        let mut uses = Vector::<u32>::new();
        for _ in 0..ni + 1 {
            // Each conversion is binary16 when the marked operations are all its uses.
            uses.truncate(0);
            uses.resize_default(ni);
            for q in 0..ops.len() {
                let r = b.insts[ops[q] as usize].a as usize;
                if self.hform[r] {
                    uses[b.insts[r].a as usize] += 1;
                    uses[b.insts[r].b as usize] += 1;
                }
            }
            for i in 0..ni {
                if b.insts[i].op == O_HTOF {
                    self.hform[i] = uses[i] != 0 && uses[i] == nuse[i];
                }
            }
            let mut changed = false;
            for q in 0..ops.len() {
                let r = b.insts[ops[q] as usize].a as usize;
                let u = b.insts[r];
                if self.hform[r] && !(self.hform[u.a as usize] && self.hform[u.b as usize]) {
                    self.hform[r] = false;
                    self.hform[ops[q] as usize] = false;
                    changed = true;
                }
            }
            if !changed {
                return;
            }
        }
        assert(false, "a64gen: the binary16 forms do not settle");
    }

    fn call_tables(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len();
        fill(&mut self.cpre, ni + 1, 0);
        self.rarec.truncate(0);
        self.rarec.resize_default(ni);
        fill(&mut self.cret, ni, false);
        for i in 0..ni {
            // An intrinsic's template writes x0, x1 and v0 to v4 and its arguments' registers: no
            // scratch home.
            let t = b.insts[i];
            // A sibling call does not come back: the body around it may be a leaf.
            let c = Gen::clobbers(b, t) && !lv::dead_end(unsafe &*self.pkg, b, &self.lv, i, &mut self.uses) && !(t.op == O_CALL && self.intrinsic(
                t.a,
            ).len() == 0 && self.sib_shape(i as u32, t));
            self.cret[i] = c;
            if c && self.rare(i as u32) {
                self.rarec[i] = true;
            } else if c && !(t.op == O_CALL && self.intrinsic(t.a).len() != 0) {
                self.cpre[i + 1] = 1;
            }
        }
        let nq = self.lv.order.len();
        fill(&mut self.cpos, nq + 1, 0);
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

    // Whether instruction `t` of `b` may call a function that returns, which writes the caller-saved
    // registers: a call, inline assembly, a float vector remainder (`fmod` per lane), a copy or a fill,
    // an i128 division or conversion. Another vector operation calls only a lane's trap, which does not
    // return.
    const fn clobbers(b: &Body, t: Inst) bool {
        let op = t.op;
        let fmod = op == O_VOP && (t.aux & VOP_CODE) as u32 == core::OP_REM && t.b != 0 && is_float(
            lane_type(b.type_of(b.pool[t.a as usize])),
        );
        if op == O_CALL || op == O_CALLIND || op == O_ASM || fmod || op == O_MEMCPY || op == O_MEMSET {
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
            vfix()
        } else {
            XFIX
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

    // Give value index `x` a caller-saved register of file `vr` (`Gen.scr`, `vscr`) as its home,
    // the value there evicted: `prefer` when it is one (the register `x` arrives in), else one the current
    // instruction does not use; NOREG when none is.
    fn take_scratch(self: &mut Self, x: u32, vr: bool, prefer: u8) u8 {
        let set = if vr {
            vscr()
        } else {
            self.scr
        } & ~self.fixed_busy;
        let open = set & ~(self.lock | self.tmps);
        // A free one first.
        let r = if prefer != NOREG && (set & bit(prefer)) != 0 {
            prefer
        } else if (open & ~self.held) != 0 {
            (open & ~self.held).trailing_zeros() as u8
        } else if open != 0 {
            open.trailing_zeros() as u8
        } else {
            NOREG
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
            let r = self.tmp(is_v(t));
            self.materialize(v, r);
            return r;
        }
        let r = self.alloc(is_v(t));
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
                    a::SP
                } else {
                    a::FP
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
                    a::SP
                } else {
                    a::FP
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
                    lo | 0xFFFFFFFF << bits as u64 & 0xFFFFFFFF
                } else {
                    lo
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
        } else if is_v(t) {
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
        self.uses.truncate(0);
        self.uses.extend_from_slice(self.lv.uses_of(i));
        for k in 0..self.uses.len() {
            let x = self.vx(self.uses[k]);
            self.use_once(x);
        }
        // Code that may branch past a lane reads a vector from its home: a vector in a register reaches
        // it first, but for the instructions with register forms (`vop` and `vec_arith` sync their others)
        // and calls (a vector passed in memory goes through `mloc`).
        let reg_form = t.op == O_STORE || t.op == O_VOP || t.op == O_CALL || t.op == O_CALLIND || is_vec(t.ty) && (t.op >= O_ADD && t.op <= O_NOT || t.op >= O_FADD && t.op <= O_FNEG || t.op == O_FSQRT || t.op == O_VCMP || t.op == O_VSEL || t.op == O_VUNZIP || t.op == O_VZIPLO || t.op == O_VZIPHI || t.op == O_VINSERT) || t.op == O_VEXTRACT || self.conv_reg(
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

    // A stack slot of `size` bytes aligned to `al` (memory values and spills); its sp offset.
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

    // `rd` = `base` + `off` (base may be sp).
    fn add_off(self: &mut Self, rd: u8, base: u32, off: i64) {
        self.frame_use(base);
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
        return (rn, rm, p.aux != 1);
    }

    // An access `m` of register `rt` at `rn` + `rm`, scaled by its size when `scaled`.
    fn mem_ix(self: &mut Self, m: u32, load: bool, rt: u8, rn: u32, rm: u32, scaled: bool) {
        let r = if m >= a::M_VB {
            (rt - V0) as u32
        } else {
            rt as u32
        };
        self.emit(a::ldst_reg(m, load, r, rn, rm, scaled));
    }

    fn mem(self: &mut Self, m: u32, load: bool, rt: u8, base: u32, off: i64) {
        self.frame_use(base);
        let r = if m >= a::M_VB {
            (rt - V0) as u32
        } else {
            rt as u32
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
            (rt - V0) as u32
        } else {
            rt as u32
        };
        let os = self.osym_of(s);
        self.reloc(a::R_PAGE21, os, add);
        self.emit(a::adr(true, a::IP1, 0));
        self.reloc(a::R_PAGEOFF12, os, add);
        self.emit(a::ldst_uimm(m, load, r, a::IP1, 0));
    }

    // `rd` = `v` (64-bit when `sf`), in the fewest instructions.
    // The instructions `mov_imm` takes for `v`.
    fn imm_insts(self: &mut Self, v: u64, sf: bool) u32 {
        let n = self.code.len();
        self.mov_imm(a::IP0 as u8, v, sf);
        let k = (self.code.len() - n) as u32;
        self.code.truncate(n);
        return k;
    }

    fn mov_imm(self: &mut Self, rd: u8, v0: u64, sf: bool) {
        let v = if sf {
            v0
        } else {
            v0 & 0xFFFFFFFF
        };
        let nh: u32 = if sf {
            4
        } else {
            2
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
        // A 64-bit value of three or four halfwords besides the all-zero or all-one ones: ORR of a logical
        // immediate that differs from it in one halfword, then MOVK of that halfword, when there is one.
        if sf && nh - zeros.max(ones) >= 3 {
            for k in 0..4u32 {
                let h = v >> (16 * k) as u64 & 0xFFFF;
                for j in 0..4u32 {
                    let c = v & ~(0xFFFFu64 << (16 * k) as u64) | (v >> (16 * j) as u64 & 0xFFFF) << (16 * k) as u64;
                    let li = a::logical_imm(c, true);
                    if j != k && li != 0xFFFFFFFF {
                        self.emit(a::logic_imm(true, 1, rd, a::ZR, li));
                        self.emit(a::movw(true, 3, rd, h as u32, k));
                        return;
                    }
                }
            }
        }
        // MOVN when more halfwords are all ones than all zeros.
        let inv = ones > zeros;
        let skip: u64 = if inv {
            0xFFFF
        } else {
            0
        };
        let mut first = true;
        for k in 0..nh {
            let h = v >> (16 * k) as u64 & 0xFFFF;
            if h == skip {
                continue;
            }
            if first {
                let imm = if inv {
                    ~h & 0xFFFF
                } else {
                    h
                };
                self.emit(
                    a::movw(
                        sf,
                        if inv {
                            0u32
                        } else {
                            2u32
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
                        0u32
                    } else {
                        2u32
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

    // The code section of a `@cold` function (`Sym.cold`): apart from the other functions', which the
    // linker lays out together.
    const fn cold_text(self: &Self) str<'static> {
        return if self.elf {
            ".text.unlikely"
        } else {
            "__TEXT,__text_cold"
        };
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
            T_F32
        } else if v && bytes == 8 {
            T_F64
        } else {
            int_type(bytes)
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
            V0 + 30
        } else {
            a::IP0 as u8
        };
        let r = if src.kind == LC_REG {
            src.reg
        } else {
            self.materialize(self.xval(src.val), s);
            s
        };
        self.mem(mkind(t, false), false, r, dst.reg, dst.off);
    }

    fn scratch(self: &mut Self) Lc {
        let s = self.slot_alloc(64, 16) as i32;
        return Lc { kind: LC_MEM, reg: a::SP as u8, off: s, val: NONE };
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

// The memory access kind of type `t` (`load`: an integer below 64 bits loads zero-extended).
const fn mkind(t: u8, load: bool) u32 {
    let _ = load;
    if is_vec(t) {
        return if type_bytes(t, 8) == 16 {
            a::M_VQ
        } else {
            a::M_VD
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
    pub(package) fn func(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        self.bp = &p.bodies[ps.def as usize];
        let b = self.b();
        self.lv.fold_max = 16;
        self.lv.fold_ops = lv::FOLD_CMP | lv::FOLD_TST | lv::FOLD_MADD | lv::FOLD_UBFX | lv::FOLD_ROT | lv::FOLD_ROT_NARROW | lv::FOLD_CCMP | lv::FOLD_SHAMT | lv::FOLD_CSEL | lv::FOLD_MULL | lv::FOLD_SHOP;
        // A compilation again (`again`: without shrink-wrapping, or with far branches) keeps the relays, the
        // canary and the analysis of the body but its layout.
        if self.again {
            self.again = false;
            self.lv.after.truncate(0);
            self.lv.relayout(b);
        } else {
            intrin::of_symbols(unsafe &*self.pkg, b, "aarch64", &mut self.itpl);
            self.lay_sig.truncate(0);
            arg_relays(self);
            self.prot = lver::protected(unsafe (*self.pkg).protect, b);
            self.opf = lv::op_flags(b);
            self.lv.after.truncate(0);
            self.lv.run(b);
        }
        self.shrink = !self.no_shrink && self.shrinkable();
        self.shrink_bad = false;
        if self.shrink {
            self.lv.relayout(b);
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
        fill(&mut self.owner, 64, NONE);
        self.held = 0;
        fill(&mut self.blk_at, b.blocks.len(), NONE);
        self.code.truncate(0);
        self.fix.truncate(0);
        self.epi.truncate(0);
        self.tails.truncate(0);
        self.tail_ret = NONE;
        self.rels.truncate(0);
        self.free_slots.truncate(0);
        self.taken.truncate(0);
        self.shared.truncate(0);
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
        // Sibling calls leave the frame first: none with a canary to check, variadic arguments in it, or a
        // slot's address that may outlive it.
        self.tail_ok = unsafe (*self.pkg).tail && self.canary < 0 && (self.opf & lv::OP_VASTART) == 0 && !lver::frame_escapes(
            b,
        );
        self.bucket_ends();
        self.call_tables();
        self.half_forms();
        self.plan_homes();
        if self.shrink && self.lv.homeless(&self.want) {
            return self.unshrunk(s, local);
        }
        if self.err.len() != 0 || !self.entry() {
            return false;
        }
        // A stack parameter, the return address, the variadic arguments and an over-aligned frame are
        // reached through x29; inline assembly may name it.
        self.frameless = unsafe (*self.pkg).omit_fp && self.max_align <= 16;
        for k in 0..self.self_lay.locs.len() {
            let kd = self.self_lay.locs[k].kind;
            self.frameless = self.frameless && kd != ab::L_STACK && kd != ab::L_REF_STACK;
        }
        self.frameless = self.frameless && (self.opf & (lv::OP_RETADDR | lv::OP_VASTART | lv::OP_ASM)) == 0;
        for q in 0..self.lv.order.len() {
            if !self.block(q as u32) {
                return false;
            }
        }
        assert(self.fixed_busy == 0, "a64gen: a register home outlives its value");
        if self.shrink && (self.shrink_bad || self.csr != 0 || self.warm_calls()) {
            return self.unshrunk(s, local);
        }
        if self.finish(s) {
            return true;
        }
        if self.err.len() != 0 || self.far {
            return false;
        }
        // A conditional branch out of range: once more, every one of them over a `B`.
        self.far = true;
        self.again = true;
        let ok = self.func(s, local);
        self.far = false;
        return ok;
    }

    // The warm code of shrink-wrapped function `s` needs the frame: once more, with the frame set up at the
    // entry.
    fn unshrunk(self: &mut Self, s: u32, local: bool) bool {
        self.no_shrink = true;
        self.again = true;
        let ok = self.func(s, local);
        self.no_shrink = false;
        return ok;
    }

    // Whether the body may set its frame up in its rare blocks alone (`shrink`): every call (one that does
    // not return too: it needs the frame's alignment) is in a rare block (`Live::rare`), there is one, and
    // the body reads no return address, variadic argument or inline assembly, runs no system operation,
    // aligns no slot past 16 bytes and has no canary. The rare blocks connected to one with a call by edges
    // between rare blocks set the frame up: `Live::after`, which the layout puts after the others.
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
            // A vector operation's lane trap calls too: its block needs the frame.
            if d == NONE || self.lv.pos[d as usize] == NONE || !Gen::clobbers(b, t) && !(t.op == O_VOP && !lv::reduces(
                t,
            )) {
                continue;
            }
            if !self.lv.rare[d as usize] {
                return false;
            }
            framed[d as usize] = true;
            any = true;
        }
        if any {
            self.lv.set_after(b, &framed);
        }
        return any;
    }

    // Under `shrink`, a stack or frame address `base` (sp, x29) in a warm block: the try fails.
    const fn frame_use(self: &mut Self, base: u32) {
        if self.shrink && (base == a::SP || base == a::FP) && self.pos as usize < self.lv.order.len() && !self.lv.after[self.lv.order[self.pos as usize] as usize] {
            self.shrink_bad = true;
        }
    }

    // Whether the warm code (the words before the first rare block) branches with a link (`BL`, `BLR`):
    // it would lose the return address its frame does not save.
    fn warm_calls(self: &Self) bool {
        return self.calls_before(self.rare_at());
    }

    // Whether a code word before `to` is a `BL` or a `BLR`.
    const fn calls_before(self: &Self, to: u32) bool {
        for w in 0..to {
            let x = self.code[w as usize];
            if (x & 0xFC000000) == 0x94000000 || (x & 0xFFFFFC1F) == 0xD63F0000 {
                return true;
            }
        }
        return false;
    }

    // The first word of the blocks that set the frame up, which the layout puts last (`Live::after`); the
    // code's length when there is none.
    const fn rare_at(self: &Self) u32 {
        for q in 0..self.lv.order.len() {
            let k = self.lv.order[q] as usize;
            if self.lv.after[k] && self.blk_at[k] != NONE {
                return self.blk_at[k];
            }
        }
        return self.code.len() as u32;
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
        self.va_save = NONE;
        if !self.apple && (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 {
            // x0..x7 (64 bytes), then q0..q7 (128 bytes).
            at = at + 15 & ~15u32;
            self.va_save = at;
            at += 192;
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
    fn entry(self: &mut Self) bool {
        let b = self.b();
        if self.canary >= 0 {
            self.guard(a::IP0 as u8);
            self.mem(a::M_X, false, a::IP0 as u8, a::SP, self.canary);
        }
        cc::classify(b, b.sig, self.ptr, self.apple, self.vregs, &mut self.self_lay);
        if self.self_lay.unknown {
            return self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        self.ret_stores();
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
        // A home in x0..x8 (`leaf`) takes no register a parameter arrives in.
        if self.scr != XSCR {
            if self.self_lay.ret.kind == ab::L_SRET {
                self.lock |= bit(8);
            }
            for k in 0..np {
                let loc = self.self_lay.locs[k as usize];
                if loc.kind == ab::L_REG || loc.kind == ab::L_REF_REG {
                    for q in 0..loc.n as u32 {
                        let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                        if !pa.v {
                            self.lock |= bit(pa.reg);
                        }
                    }
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
                let home = if agg {
                    H_FPADDR
                } else {
                    H_ARG
                };
                self.va.index_mut(x as usize).home = home;
                self.va.index_mut(x as usize).off = (16 + loc.off) as i32;
            } else if loc.kind == ab::L_REF_STACK {
                if !agg && in_mem(t) {
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
            } else if agg && self.parts_taken(x, loc) {
                continue;
            } else if agg || in_mem(t) {
                // Register parts into a slot: the aggregate's memory, or the memory value.
                let (size, _) = sig_size(b, pt, self.ptr);
                let off = self.slot_alloc(size + 7 & ~7u32, 16);
                for q in 0..loc.n as u32 {
                    let pa = self.self_lay.parts[(loc.p0 + q) as usize];
                    self.store_part(pa, a::SP, off as i64 + pa.off as i64);
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

    // Parameter value index `x` arrives in register `r`.
    fn entry_reg(self: &mut Self, x: u32, r: u8) {
        if self.lv.uses[x as usize] == 0 {
            return;
        }
        let t = self.xty(x);
        let f = self.take_home(x, is_v(t), r);
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
                place::row(&mut self.rows, self.code.len() as u64, b.locs[i as usize]);
            }
            self.begin_inst(i);
            if i == self.paired {
                self.paired = NONE;
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
            1
        } else if t.op == O_BR {
            2
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1
        } else {
            0
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
            1
        } else if t.op == O_BR {
            2
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1
        } else {
            0
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
            let tb = b.blocks[b.edge_target(ed) as usize];
            for q in 0..tb.param_len as u32 {
                let x = ni + tb.param_start + q;
                let r = self.ret_reg(b, x);
                self.param_home(
                    x,
                    if r != NOREG {
                        r
                    } else {
                        self.dying_reg(b.edge_arg(ed, q))
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
        if (!in_mem(t) || in_vreg(t)) && self.take_home(x, is_v(t) || in_vreg(t), prefer) != NOREG {
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
        return place::loc_of(&self.va, x, a::SP as u8, a::FP as u8);
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
                Lc { kind: LC_MEM, reg: a::SP as u8, off: pva.off, val: px }
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

    // Copy `n` bytes from `sb` + `so` to `db` + `do` (registers or sp) through x16 and v30.
    fn copy_mem(self: &mut Self, db: u32, do0: i64, sb: u32, so0: i64, n: u32) {
        let mut at: u32 = 0;
        // Chunks of 16, 8, 4, 2 and 1 bytes: at most n / 16 + 4 steps.
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
            let m = if step == 16 {
                a::M_VQ
            } else {
                size_kind(step)
            };
            let r = if m == a::M_VQ {
                V0 + 30
            } else {
                a::IP0 as u8
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
                a::M_VS
            } else if pa.size == 8 {
                a::M_VD
            } else {
                a::M_VQ
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
                a::M_VS
            } else if pa.size == 8 {
                a::M_VD
            } else {
                a::M_VQ
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
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
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
                4u32
            } else if left >= 2 {
                2u32
            } else {
                1u32
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
        return (b.pool[l], 1u32 << b.pool[l + 1]);
    }
    return (type_bytes(pt as u8, ptr), type_align(pt as u8, ptr));
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
        if op == O_FCONST {
            let r = self.def(i);
            self.fconst(r, t.ty == T_F64, t.b as u64 << 32 | t.a as u64);
            return true;
        }
        if op == O_ICONST {
            let r = self.def(i);
            self.mov_imm(r, t.b as u64 << 32 | t.a as u64, type_bytes(t.ty, self.ptr) == 8);
            return true;
        }
        if op == O_WCONST && in_vreg(t.ty) {
            self.wconst_reg(i, t);
            return true;
        }
        if op == O_WCONST {
            let off = self.mdef(i);
            // A zero word is xzr's.
            for k in 0..t.b {
                let w = self.b().words[(t.a + k) as usize];
                let r = if w == 0 {
                    a::ZR as u8
                } else {
                    a::IP0 as u8
                };
                if w != 0 {
                    self.mov_imm(r, w, true);
                }
                self.mem(a::M_X, false, r, a::SP, off + 8 * k as i64);
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
        if op == O_BSWAP {
            let bits = type_bits(t.ty, self.ptr);
            let r = self.reg(t.a) as u32;
            let rd = self.def(i) as u32;
            let opc = if bits == 16 {
                a::DP1_REV16
            } else if bits == 32 {
                a::DP1_REV32
            } else {
                a::DP1_REV64
            };
            self.emit(a::dp1(bits == 64, opc, rd, r));
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
        if op == O_FMA {
            let ra = self.reg(t.a);
            let rb = self.reg(t.b);
            let rc = self.reg(t.c);
            let rd = self.def(i);
            self.emit(a::fmadd(t.ty == T_F64, false, rd - V0, ra - V0, rb - V0, rc - V0));
            return true;
        }
        if op == O_MULHU || op == O_MULHS {
            // 64 bits: UMULH or SMULH; fewer: the extended operands' 64-bit product (UMULL or SMULL, which
            // read 32 bits), shifted down.
            let bits = type_bits(t.ty, self.ptr);
            let sgn = op == O_MULHS;
            if bits == 64 {
                let ra = self.reg(t.a);
                let rb = self.reg(t.b);
                let rd = self.def(i);
                self.emit(a::mulh(sgn, rd, ra, rb));
                return true;
            }
            let ra = if bits == 32 {
                self.reg(t.a)
            } else {
                self.ext(t.a, sgn, bits)
            };
            let rb = if bits == 32 {
                self.reg(t.b)
            } else {
                self.ext(t.b, sgn, bits)
            };
            let rd = self.def(i);
            self.emit(a::mull(sgn, rd, ra, rb));
            if sgn {
                self.emit(a::asr_imm(true, rd, rd, bits));
            } else {
                self.emit(a::lsr_imm(true, rd, rd, bits));
            }
            return true;
        }
        if op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            if is_vec(t.ty) {
                return self.vec_arith(i, t);
            }
            let d = t.ty == T_F64;
            let ra = self.reg(t.a);
            if op == O_FNEG || op == O_FSQRT {
                let rd = self.def(i);
                self.emit(
                    a::fp1(d, a::on(op == O_FNEG, a::FP_NEG) | a::on(op == O_FSQRT, a::FP_SQRT), rd - V0, ra - V0),
                );
                return true;
            }
            let rb = self.reg(t.b);
            let rd = self.def_step(i);
            let f = if op == O_FADD {
                a::FP_ADD
            } else if op == O_FSUB {
                a::FP_SUB
            } else if op == O_FMUL {
                a::FP_MUL
            } else {
                a::FP_DIV
            };
            if self.hform[i as usize] {
                self.emit(a::fp2_h(f, rd - V0, ra - V0, rb - V0));
                return true;
            }
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
        if in_vreg(self.vt(v)) {
            self.spill(self.vx(v));
        }
    }

    // Where memory value `v` is: a base register and offset; a vector whose register holds what its home
    // lacks is stored there first.
    fn mloc(self: &mut Self, v: Value) (u32, i64) {
        self.spill(self.vx(v));
        let va = self.va[self.vx(v) as usize];
        if va.home == H_ARG {
            return (a::FP, va.off);
        }
        assert(va.home == H_SLOT, "a64gen: a memory value without a slot");
        return (a::SP, va.off);
    }

    // Whether address `v` is a slot or frame address no register holds (`addr`'s folds), with the frame's
    // register and the offset; else false, x17 and 0 (the caller puts `v` there).
    fn frame_addr(self: &Self, v: Value) (bool, u32, i64) {
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.home == H_SPADDR {
            return (true, a::SP, va.off);
        }
        if va.home == H_FPADDR {
            return (true, a::FP, va.off);
        }
        if va.home == H_REMAT && va.reg == NOREG && (v & (VPARAM | VFLAG)) == 0 {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return (true, a::SP, self.slot_off[it.a as usize]);
            }
        }
        return (false, a::IP1, 0);
    }

    // The address `v` + `off` as a base register and an offset: a slot or frame address folds in.
    fn addr(self: &mut Self, v: Value, off: i64) (u32, i64) {
        let x = self.vx(v);
        let va = self.va[x as usize];
        if va.home == H_SPADDR {
            return (a::SP, va.off as i64 + off);
        }
        if va.home == H_FPADDR {
            return (a::FP, va.off as i64 + off);
        }
        if va.home == H_REMAT && va.reg == NOREG {
            let it = self.b().insts[v as usize];
            if it.op == O_SLOTADDR {
                return (a::SP, self.slot_off[it.a as usize] as i64 + off);
            }
        }
        return (self.reg(v), off);
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
        if self.lv.pfold[i as usize] {
            return true; // each select or branch on it compares (`folded_cmp`)
        }
        let ty = self.vt(t.a);
        assert(!is_vec(ty), "a64gen: a vector comparison the verifier rejects");
        if ty == T_I128 {
            return self.icmp128(i, t);
        }
        let c = self.compare(t);
        self.cond_value(i, c, NONE);
        return true;
    }

    // The flags of the comparison condition value `v` folds into its select or branch (`lv::FOLD_CMP`),
    // set here; NONE when it does not fold.
    fn folded_cmp(self: &mut Self, v: Value) u32 {
        if (v & (VPARAM | VFLAG)) != 0 || !self.lv.pfold[v as usize] {
            return NONE;
        }
        if self.lv.conj[v as usize] != 0 {
            return self.conj_flags(v);
        }
        return self.compare(self.b().insts[v as usize]);
    }

    // The flags of `and` or `or` `v` of flags folded into conditional comparisons (`lv::FOLD_CCMP`): its
    // chain operand's flags (or its first comparison's), then its comparison when they let it run (`ccmp`),
    // else flags that decide it (false for an `and`, true for an `or`). The condition on them.
    fn conj_flags(self: &mut Self, v: Value) u32 {
        let t = self.b().insts[v as usize];
        let b_leaf = self.lv.conj[t.b as usize] == 0;
        let (first, leaf) = if b_leaf {
            (t.a, t.b)
        } else {
            (t.b, t.a)
        };
        let c1 = if self.lv.conj[first as usize] != 0 {
            self.conj_flags(first)
        } else {
            self.compare(self.b().insts[first as usize])
        };
        let l = self.b().insts[leaf as usize];
        let c = l.aux;
        let ty = self.vt(l.a);
        let bits = type_bits(ty, self.ptr);
        let sf = bits == 64;
        let signed = signed_cond(c);
        let ra = if bits < 32 {
            self.ext(l.a, signed, bits)
        } else {
            self.reg(l.a)
        } as u32;
        let lc = icond(c);
        let and = t.op == O_AND;
        let run = if and {
            c1
        } else {
            a::invert(c1)
        };
        let nzcv = if and {
            a::nzcv_for(a::invert(lc))
        } else {
            a::nzcv_for(lc)
        };
        let mut k: u64 = 0;
        if self.const_of(l.b, &mut k) {
            let kv: i64 = if signed {
                lp_sext(k, bits)
            } else {
                k as i64
            };
            if kv >= 0 && kv < 32 || kv < 0 && kv > -32 {
                let m = if kv < 0 {
                    -kv
                } else {
                    kv
                };
                self.emit(a::ccmp(sf, kv < 0, true, ra, m as u32, nzcv, run));
                return lc;
            }
        }
        let rb = if bits < 32 {
            self.ext(l.b, signed, bits)
        } else {
            self.reg(l.b)
        } as u32;
        self.emit(a::ccmp(sf, false, false, ra, rb, nzcv, run));
        return lc;
    }

    // Comparison `t` of integers of at most 64 bits into the flags: its condition. A folded `and` compared
    // with 0 is a test (`lv::FOLD_TST`).
    fn compare(self: &mut Self, t: Inst) u32 {
        let c = t.aux;
        let ty = self.vt(t.a);
        let bits = type_bits(ty, self.ptr);
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            let n = self.b().insts[t.a as usize];
            let ra = self.reg(n.a);
            let mut m: u64 = 0;
            let li = if self.const_of(n.b, &mut m) {
                a::logical_imm(m, bits == 64)
            } else {
                0xFFFFFFFFu32
            };
            if li != 0xFFFFFFFF {
                self.emit_cmp(a::logic_imm(bits == 64, 3, a::ZR, ra, li));
            } else {
                let rb = self.reg(n.b);
                self.emit_cmp(a::logic_reg(bits == 64, 3, false, a::ZR, ra, rb, 0, 0));
            }
            return icond(c);
        }
        let sf = bits == 64;
        let small = bits < 32;
        let signed = signed_cond(c);
        let ra = if small {
            self.ext(t.a, signed, bits)
        } else {
            self.reg(t.a)
        };
        let mut k: u64 = 0;
        if self.const_of(t.b, &mut k) {
            let kv: i64 = if signed {
                lp_sext(k, bits)
            } else {
                k as i64
            };
            if kv == 0 {
                let fc = self.set_flags(ra, sf, c);
                if fc != NONE {
                    return fc;
                }
            }
            if kv >= 0 && kv < 4096 {
                self.emit_cmp(a::cmp_imm(sf, ra, kv as u32));
                return icond(c);
            }
            if kv < 0 && kv > -4096 {
                self.emit_cmp(a::cmn_imm(sf, ra, (-kv) as u32));
                return icond(c);
            }
        }
        let rb = if small {
            self.ext(t.b, signed, bits)
        } else {
            self.reg(t.b)
        };
        self.emit_cmp(a::addsub_reg(sf, 1, true, a::ZR, ra, rb, 0, 0));
        return icond(c);
    }

    // A comparison of register `r` (64 bits: `sf`) with 0 under condition `c`, when the block's last
    // instruction wrote `r` by an `add`, `sub`, `and` or `bic`: that instruction sets the flags in its place
    // (`adds`, `subs`, `ands`, `bics`), and the condition on them is returned; NONE when it does not apply.
    // An addition or subtraction may set V, so only `==`, `!=`, `< 0` (MI) and `>= 0` (PL) read its
    // flags; a logical one clears V, so every signed condition does.
    fn set_flags(self: &mut Self, r: u32, sf: bool, c: u16) u32 {
        let k = self.lv.order[self.pos as usize];
        let n = self.code.len();
        if n == 0 || self.blk_at[k as usize] >= n as u32 {
            return NONE;
        }
        let w = self.code[n - 1];
        if (w & 31) != r || r == 31 || w >> 31 != 0 != sf {
            return NONE;
        }
        let arith = (w & 0x3F200000) == 0x0B000000 || (w & 0x3F800000) == 0x11000000;
        let logic = (w & 0x7F000000) == 0x0A000000 || (w & 0x7F800000) == 0x12000000;
        let cc = if c == C_EQ || c == C_NE {
            icond(c)
        } else if c == C_SLT && arith {
            a::MI
        } else if c == C_SGE && arith {
            a::PL
        } else if (c == C_SLT || c == C_SLE || c == C_SGT || c == C_SGE) && logic {
            icond(c)
        } else {
            NONE
        };
        if cc == NONE || !arith && !logic {
            return NONE;
        }
        // The S bit of an addition or subtraction, opc 11 (ANDS) of a logical operation.
        self.code[n - 1] = w | if arith {
            0x20000000u32
        } else {
            0x60000000u32
        };
        return cc;
    }

    // Compare `w`, unless it starts a block whose one predecessor ends with `w` and a `b.cond` (to
    // elsewhere, falling through here): the flags hold its result already.
    fn emit_cmp(self: &mut Self, w: u32) {
        let k = self.lv.order[self.pos as usize];
        let n = self.code.len();
        let nf = self.fix.len();
        if self.blk_at[k as usize] == n as u32 && self.lv.npred[k as usize] == 1 && n >= 2 && self.code[n - 2] == w && (self.code[n - 1] & 0xFF000010) == 0x54000000 && nf != 0 && (self.fix[nf - 1] >> 32) as usize == n - 1 {
            return;
        }
        // The same comparison earlier in the block, only conditional selects and moves since (a `cset`
        // reads the flags), none of which writes its operands: the flags hold.
        let rn = w >> 5 & 31;
        let rm = w >> 16 & 31;
        let mut q = n;
        while q > self.blk_at[k as usize] as usize && n - q < 8 {
            q -= 1;
            let c = self.code[q];
            if c == w {
                return;
            }
            let csel = (c & 0x1FE00000) == 0x1A800000;
            let movw = (c & 0x1F800000) == 0x12800000;
            let mov = (c & 0x7F200000) == 0x2A000000;
            if !csel && !movw && !mov || (c & 31) == rn || (c & 31) == rm {
                break;
            }
        }
        self.emit(w);
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
            lo_b
        } else {
            lo_a
        };
        let h1 = if swap {
            hi_b
        } else {
            hi_a
        };
        let l2 = if swap {
            lo_a
        } else {
            lo_b
        };
        let h2 = if swap {
            hi_a
        } else {
            hi_b
        };
        self.emit(a::addsub_reg(true, 1, true, a::ZR, l1, l2, 0, 0));
        self.emit(a::adc(true, 1, true, a::ZR, h1, h2));
        let cc = if c == C_SLT || c == C_SGT {
            a::LT
        } else if c == C_SGE || c == C_SLE {
            a::GE
        } else if c == C_ULT || c == C_UGT {
            a::LO
        } else {
            a::HS
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
        return (lo, hi);
    }

    // Store two words as i128 instruction `i`'s value.
    fn store128(self: &mut Self, i: u32, lo: u8, hi: u8) {
        let off = self.mdef(i);
        self.mem(a::M_X, false, lo, a::SP, off);
        self.mem(a::M_X, false, hi, a::SP, off + 8);
    }

    // clz: CLZ; ctz: RBIT then CLZ; popcnt: CNT over the bytes in v30 (of 4 bytes but at 64 bits), summed
    // by ADDV. An operand under
    // 32 bits is zero-extended, but for ctz, whose bit set at the width (making 0 count the width) hides
    // the bits above it. The count, at most the width, is `clean`.
    fn bit_count(self: &mut Self, i: u32, t: Inst) {
        let bits = type_bits(t.ty, self.ptr);
        let sf = bits == 64;
        let mut r = if bits < 32 && t.op != O_CTZ {
            self.ext(t.a, false, bits) as u32
        } else {
            self.reg(t.a) as u32
        };
        if t.op == O_CTZ && bits < 32 {
            self.emit(a::logic_imm(false, 1, a::IP0, r, a::logical_imm(1u64 << bits as u64, false)));
            r = a::IP0;
        }
        let rd = self.def(i) as u32;
        self.va.index_mut(i as usize).clean = true;
        if t.op == O_POPCNT {
            // A 32-bit move for a narrower count: the register's bits above 32 are no part of the value.
            self.emit(a::fmov_gv(sf, true, 30, r));
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

    // Whether value `v` is an instruction that folds into its use (`lv::FOLD_*`).
    const fn folds_in(self: &Self, v: Value) bool {
        return v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize];
    }

    // Rotation `i` of value `xv`, 8 or 16 `bits` wide (`lv::FOLD_ROT_NARROW`), on the 32-bit register: by
    // constant `kr` to the left, the value zero-extended shifted both ways and joined (LSR, then ORR of the
    // LSL); by register `amt` (right when `right`), the register filled with the value's copies (ORR with
    // itself shifted by 8 and 16, or by 16), which a 32-bit RORV rotates as the narrow value: the copies
    // repeat every `bits` bits, so a rotation by n modulo 32 is one by n modulo `bits`, and RORV reads the
    // amount's low 5 bits only. A left rotation rotates right by the negation. The scratch registers take
    // the steps, so the result, written last, may take an operand's register; the bits above the width
    // hold the copies (not `clean`).
    fn rotate_narrow(self: &mut Self, i: u32, xv: Value, rot: lv::Rotation, kr: u32, right: bool, bits: u32) bool {
        let xz = self.ext(xv, false, bits) as u32;
        if rot.amt == VNONE {
            let rd = self.def(i) as u32;
            self.emit(a::lsr_imm(false, a::IP0, xz, bits - kr));
            self.emit(a::logic_reg(false, 1, false, rd, a::IP0, xz, 0, kr));
            return true;
        }
        let rn = self.reg(lv::rot_amount(self.b(), &self.lv.pfold, rot)) as u32;
        let rd = self.def(i) as u32;
        self.emit(a::logic_reg(false, 1, false, a::IP1, xz, xz, 0, bits));
        if bits == 8 {
            self.emit(a::logic_reg(false, 1, false, a::IP1, a::IP1, a::IP1, 0, 16));
        }
        if right {
            self.emit(a::dp2(false, a::DP2_RORV, rd, a::IP1, rn));
        } else {
            self.emit(a::addsub_reg(false, 1, false, a::IP0, a::ZR, rn, 0, 0));
            self.emit(a::dp2(false, a::DP2_RORV, rd, a::IP1, a::IP0));
        }
        return true;
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
        if self.lv.conj[i as usize] != 0 {
            let c = self.conj_flags(i);
            self.cond_value(i, c, NONE);
            return true;
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
        // A rotation whose shifts fold into it (`lv::FOLD_ROT`), before the folded product a sum may take:
        // ROR by an immediate, or RORV by a register, of a left rotation by its negation.
        let rot = if (op == O_OR || op == O_XOR || op == O_ADD) && self.folds_in(t.a) && self.folds_in(t.b) {
            lv::rotate_of(self.b(), i)
        } else {
            lv::Rotation { x: VNONE, amt: VNONE, src: VNONE, k: 0, right: false }
        };
        if rot.x != VNONE {
            let xv = rot.x;
            let amt = rot.amt;
            let kr = rot.k;
            let right = rot.right;
            if bits < 32 {
                return self.rotate_narrow(i, xv, rot, kr, right, bits);
            }
            let ra = self.reg(xv) as u32;
            if amt == VNONE {
                let rd = self.def(i) as u32;
                self.emit(a::ror_imm(sf, rd, ra, (bits - kr) % bits));
                return true;
            }
            let n = lv::rot_amount(self.b(), &self.lv.pfold, rot);
            let rn = self.reg(n) as u32;
            let rd = self.def(i) as u32;
            if right {
                self.emit(a::dp2(sf, a::DP2_RORV, rd, ra, rn));
            } else {
                self.emit(a::addsub_reg(sf, 1, false, a::IP0, a::ZR, rn, 0, 0));
                self.emit(a::dp2(sf, a::DP2_RORV, rd, ra, a::IP0));
            }
            return true;
        }
        // A product of two folded 32-bit extensions (`lv::FOLD_MULL`): `umull` or `smull`.
        if op == O_MUL && (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            let e = lv::mull_ext(self.b(), t);
            let rn = self.reg(self.b().insts[t.a as usize].a) as u32;
            let rm = self.reg(self.b().insts[t.b as usize].a) as u32;
            let rd = self.def_step(i) as u32;
            self.emit(a::mull(e == O_SEXT, rd, rn, rm));
            return true;
        }
        // An operand shifted by a constant (`lv::FOLD_SHOP`): the shifted register form.
        let sv = lv::shop_side(self.b(), &self.lv.pfold, t);
        if sv != VNONE {
            let s = self.b().insts[sv as usize];
            let o = if sv == t.b {
                t.a
            } else {
                t.b
            };
            let mut amt: u64 = 0;
            let _ = self.const_of(s.b, &mut amt);
            let kind = (s.op - O_SHL) as u32;
            let rn = self.reg(o) as u32;
            let rm = self.reg(s.a) as u32;
            let rd = self.def_step(i) as u32;
            if op == O_ADD || op == O_SUB {
                self.emit(a::addsub_reg(sf, (op == O_SUB) as u32, false, rd, rn, rm, kind, amt as u32));
            } else {
                let opc = if op == O_AND {
                    0u32
                } else if op == O_OR {
                    1u32
                } else {
                    2u32
                };
                self.emit(a::logic_reg(sf, opc, false, rd, rn, rm, kind, amt as u32));
            }
            return true;
        }
        // A folded product added or subtracted (`lv::FOLD_MADD`).
        if (op == O_ADD || op == O_SUB) && (t.b & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.b as usize] {
            let m = self.b().insts[t.b as usize];
            let ra = self.reg(t.a);
            let rn = self.reg(m.a);
            let rm = self.reg(m.b);
            let rd = self.def_step(i);
            self.emit(a::madd(sf, op == O_SUB, rd, rn, rm, ra));
            return true;
        }
        let mut k: u64 = 0;
        let kc = self.const_of(t.b, &mut k);
        // A field of a folded shift (`lv::FOLD_UBFX`): `ubfx`.
        if kc && op == O_AND && (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            let s = self.b().insts[t.a as usize];
            let mut sh: u64 = 0;
            let _ = self.const_of(s.b, &mut sh);
            let w = (k + 1).trailing_zeros() as u32;
            let rn = self.reg(s.a);
            let rd = self.def(i);
            self.emit(a::bitfield(sf, 2, rd, rn, sh as u32, sh as u32 + w - 1));
            self.va.index_mut(i as usize).clean = true;
            return true;
        }
        if kc && (op == O_ADD || op == O_SUB) {
            let kv = lp_sext(k, bits);
            let neg = op == O_SUB;
            if kv >= 0 && kv < 4096 || kv < 0 && kv > -4096 {
                let ra = self.reg(t.a);
                let rd = self.def_step(i);
                let sub = neg != kv < 0;
                let m = if kv < 0 {
                    -kv
                } else {
                    kv
                };
                self.emit(
                    a::addsub_imm(
                        sf,
                        if sub {
                            1u32
                        } else {
                            0u32
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
                    0u32
                } else if op == O_OR {
                    1u32
                } else {
                    2u32
                };
                self.emit(a::logic_imm(sf, opc, rd, ra, li));
                // A mask within the width clears the bits above it.
                if small && op == O_AND && (k & 0xFFFFFFFF) >> bits as u64 == 0 {
                    self.va.index_mut(i as usize).clean = true;
                }
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
                            2u32
                        } else {
                            0u32
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
        // A product by 2^s + 1 is a shifted sum, by 2^s - 1 a shift and a difference (LLVM's lowering).
        if kc && op == O_MUL {
            let m = if bits >= 64 {
                k
            } else {
                k & (1u64 << bits as u64) - 1
            };
            if m >= 3 && (m - 1 & m - 2) == 0 {
                let ra = self.reg(t.a) as u32;
                let rd = self.def_step(i) as u32;
                self.emit(a::addsub_reg(sf, 0, false, rd, ra, ra, 0, (m - 1).trailing_zeros() as u32));
                return true;
            }
            if m >= 7 && m < 1u64 << (bits - 1) as u64 && (m & m + 1) == 0 {
                let ra = self.reg(t.a) as u32;
                let rd = self.def_step(i) as u32;
                self.emit(a::lsl_imm(sf, a::IP0, ra, (m + 1).trailing_zeros() as u32));
                self.emit(a::addsub_reg(sf, 1, false, rd, a::IP0, ra, 0, 0));
                return true;
            }
        }
        let div = op >= O_SDIV && op <= O_UREM;
        let sgn = op == O_SDIV || op == O_SREM || op == O_ASHR;
        let ext_a = small && (div || op == O_LSHR || op == O_ASHR);
        let ra = if ext_a {
            self.ext(t.a, sgn, bits)
        } else {
            self.reg(t.a)
        };
        let rb = if small && div {
            self.ext(t.b, sgn, bits)
        } else if op >= O_SHL && op <= O_ASHR {
            self.reg(lv::shift_amount(self.b(), &self.lv.pfold, t.b))
        } else {
            self.reg(t.b)
        };
        // An `and` of a value whose bits above the type are 0, an `or` or `xor` of two: so are the result's.
        let ca = self.va[self.vx(t.a) as usize].clean;
        let cb = self.va[self.vx(t.b) as usize].clean;
        let rd = self.def_step(i);
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
                0u32
            } else if op == O_OR {
                1u32
            } else {
                2u32
            };
            self.emit(a::logic_reg(sf, opc, false, xd, xa, xb, 0, 0));
            if small && (op == O_AND && (ca || cb) || ca && cb) {
                self.va.index_mut(i as usize).clean = true;
            }
        } else if op == O_SHL {
            self.emit(a::dp2(sf, a::DP2_LSLV, xd, xa, xb));
        } else if op == O_LSHR {
            self.emit(a::dp2(sf, a::DP2_LSRV, xd, xa, xb));
        } else if op == O_ASHR {
            self.emit(a::dp2(sf, a::DP2_ASRV, xd, xa, xb));
        } else {
            let d = if op == O_SDIV || op == O_SREM {
                a::DP2_SDIV
            } else {
                a::DP2_UDIV
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
                0u32
            } else if op == O_OR {
                1u32
            } else {
                2u32
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
            a::DP2_ASRV
        } else {
            a::DP2_LSRV
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
                4u32
            } else {
                0u32
            } + if bits == 16 {
                1u32
            } else {
                0u32
            };
            self.emit(a::addsub_ext(false, 1, true, a::ZR, rd, rd, opt, 0));
        } else {
            let mut k: u64 = 0;
            let imm = (op == O_ADDO || op == O_SUBO) && self.const_of(t.b, &mut k) && k < 4096;
            let ra = self.reg(t.a) as u32;
            let rb = if imm {
                a::ZR
            } else {
                self.reg(t.b) as u32
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
                    a::VS
                } else if sub {
                    a::LO
                } else {
                    a::HS
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
        if self.lv.pfold[i as usize] {
            return true; // its use computes it (`lv::FOLD_ROT`: a rotation's amount)
        }
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if is_vec(from) || is_vec(to) {
            if op == O_BITCAST && in_mem(from) && in_mem(to) {
                let (base, off) = self.mloc(t.a);
                let d = self.mdef(i);
                self.copy_mem(a::SP, d, base, off, type_bytes(to, self.ptr));
                return true;
            }
            if op == O_BITCAST {
                // A vector and a scalar of one size: through memory.
                if in_mem(from) {
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
        // A zero extension of a value whose register holds nothing above its bits (a byte load's, say)
        // gives it another type.
        if op == O_ZEXT && self.va[self.vx(t.a) as usize].clean {
            let ra = self.reg(t.a);
            let _ = self.def_from(i, t.a, ra);
            self.va.index_mut(i as usize).clean = true;
            return true;
        }
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
        if op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST && !is_v(from) && !is_v(to) {
            let ra = self.reg(t.a);
            let _ = self.def_from(i, t.a, ra);
            return true;
        }
        if op == O_BITCAST {
            let ra = self.reg(t.a);
            let rd = self.def(i);
            if is_v(from) {
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
                self.ext(t.a, signed, fb)
            } else {
                self.reg(t.a)
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
                (1u64 << (tb - 1) as u64) - 1
            } else {
                (1u64 << tb as u64) - 1
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
                        a::GT
                    } else {
                        a::HI
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
                            64u32
                        } else {
                            fb
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
            rd
        } else {
            base
        };
        let roff = if base == a::SP || base == a::FP && boff != 0 {
            0
        } else {
            boff
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

    // Whether access `i` and the next instruction of its block, the same access of the next bytes through
    // the same address value, pair into one `ldp` or `stp` (`pair`): 4- or 8-byte integers, floats, vectors
    // in v registers, not volatile, not through a folded index or a symbol's page; loaded values without a
    // fixed register (the pair defines the second one early).
    fn pairs(self: &Self, i: u32) bool {
        let b = self.b();
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        if i + 1 >= bk.start + bk.len {
            return false;
        }
        let t = b.insts[i as usize];
        let u = b.insts[i as usize + 1];
        let load = t.op == O_LOAD;
        if t.op != u.op || !load && t.op != O_STORE || t.a != u.a || ((t.aux | u.aux) & MEM_VOLATILE) != 0 || self.lv.fold[i as usize] || self.lv.fold[i as usize + 1] {
            return false;
        }
        let ty = if load {
            t.ty
        } else {
            self.vt(t.b)
        };
        let uy = if load {
            u.ty
        } else {
            self.vt(u.b)
        };
        let m = mkind(ty, load);
        if ty != uy || m != a::M_W && m != a::M_X && m != a::M_VS && m != a::M_VD && m != a::M_VQ || in_mem(ty) && !in_vreg(
            ty,
        ) {
            return false;
        }
        let size = type_bytes(ty, self.ptr) as i64;
        let mut sy: u32 = 0;
        let mut add: i64 = 0;
        if (u.c as i32) as i64 != (t.c as i32) as i64 + size || self.sym_mem(
            t.a,
            t.c as i32,
            size as u32,
            &mut sy,
            &mut add,
        ) {
            return false;
        }
        if load {
            for x in i..i + 2 {
                if self.va[x as usize].home == H_FIXED || self.fix_class(x) != FIX_NONE {
                    return false;
                }
            }
        }
        return true;
    }

    // Access `i` and the next one (`pairs`) as one `ldp` or `stp` at `base` + `off`, when the offset fits the
    // pair's scaled 7 bits; the next one then emits nothing. Whether it did.
    fn pair(self: &mut Self, i: u32, base: u32, off: i64) bool {
        let b = self.b();
        let t = b.insts[i as usize];
        let u = b.insts[i as usize + 1];
        let load = t.op == O_LOAD;
        let ty = if load {
            t.ty
        } else {
            self.vt(t.b)
        };
        let size = type_bytes(ty, self.ptr) as i64;
        if off % size != 0 || off < -64 * size || off > 63 * size {
            return false;
        }
        let m = mkind(ty, load);
        let (r1, r2) = if load {
            (self.def(i), self.def(i + 1))
        } else if in_vreg(ty) {
            (self.vec_use(t.b, V0 + 30), self.vec_use(u.b, V0 + 31))
        } else {
            (self.store_reg(t.b), self.store_reg(u.b))
        };
        let vr = m >= a::M_VB;
        let n1 = if vr {
            r1 - V0
        } else {
            r1
        };
        let n2 = if vr {
            r2 - V0
        } else {
            r2
        };
        self.frame_use(base);
        self.emit(a::ldstp(m, load, 2, n1, n2, base, off as i32));
        if load && !vr {
            self.va.index_mut(i as usize).clean = size < 8;
            self.va.index_mut(i as usize + 1).clean = size < 8;
        }
        self.paired = i + 1;
        return true;
    }

    // The register a store writes value `v` from: the zero register for 0.
    fn store_reg(self: &mut Self, v: Value) u8 {
        let mut k: u64 = 0;
        return if !is_v(self.vt(v)) && self.const_of(v, &mut k) && k == 0 {
            a::ZR as u8
        } else {
            self.reg(v)
        };
    }

    fn load(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        // A part of a register-passed aggregate: its register already.
        for q in 0..self.taken.len() {
            if self.taken[q] as u32 == i {
                return true;
            }
        }
        if self.pairs(i) {
            let (base, off) = self.addr(t.a, t.c as i32);
            if self.pair(i, base, off) {
                return true;
            }
        }
        if self.lv.fold[i as usize] {
            let (rn, rm, sc) = self.folded(i);
            let rd = if in_vreg(ty) {
                self.vec_def(i)
            } else {
                self.def_step(i)
            };
            self.mem_ix(mkind(ty, true), true, rd, rn, rm, sc);
            self.va.index_mut(i as usize).clean = !is_v(ty) && type_bits(ty, self.ptr) < 64;
            return true;
        }
        let mut s: u32 = 0;
        let mut add: i64 = 0;
        if !in_mem(ty) && self.sym_mem(t.a, t.c as i32, type_bytes(ty, self.ptr), &mut s, &mut add) {
            let rd = self.def(i);
            self.mem_sym(mkind(ty, true), true, rd, s, add);
            self.va.index_mut(i as usize).clean = !is_v(ty) && type_bits(ty, self.ptr) < 64;
            return true;
        }
        let (base, off) = self.addr(t.a, t.c as i32);
        if in_vreg(ty) {
            let rd = self.vec_def(i);
            self.mem(mkind(ty, true), true, rd, base, off);
            return true;
        }
        if in_mem(ty) {
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, base, off, type_bytes(ty, self.ptr));
            return true;
        }
        let rd = self.def_step(i);
        self.mem(mkind(ty, true), true, rd, base, off);
        self.va.index_mut(i as usize).clean = !is_v(ty) && type_bits(ty, self.ptr) < 64;
        return true;
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
        if self.pairs(self.cur) {
            let (base, off) = self.addr(t.a, t.c as i32);
            if self.pair(self.cur, base, off) {
                return true;
            }
        }
        if self.lv.fold[self.cur as usize] {
            let (rn, rm, sc) = self.folded(self.cur);
            let mut k: u64 = 0;
            let r = if in_vreg(ty) {
                self.vec_use(t.b, V0 + 30)
            } else if !is_v(ty) && self.const_of(t.b, &mut k) && k == 0 {
                a::ZR as u8
            } else {
                self.reg(t.b)
            };
            self.mem_ix(mkind(ty, false), false, r, rn, rm, sc);
            return true;
        }
        let mut s: u32 = 0;
        let mut add: i64 = 0;
        let sym = !in_mem(ty) && self.sym_mem(t.a, t.c as i32, type_bytes(ty, self.ptr), &mut s, &mut add);
        let mut base: u32 = 0;
        let mut off: i64 = 0;
        if !sym {
            let (b, o) = self.addr(t.a, t.c as i32);
            base = b;
            off = o;
        }
        if in_vreg(ty) {
            let r = self.vec_use(t.b, V0 + 30);
            self.mem(mkind(ty, false), false, r, base, off);
            return true;
        }
        if in_mem(ty) {
            let (sb, so) = self.mloc(t.b);
            self.copy_mem(base, off, sb, so, type_bytes(ty, self.ptr));
            return true;
        }
        let mut k: u64 = 0;
        let r = if !is_v(ty) && self.const_of(t.b, &mut k) && k == 0 {
            a::ZR as u8
        } else {
            self.reg(t.b)
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
                let byte = if self.const_of(t.b, &mut k) {
                    k & 0xFF
                } else {
                    0x100
                };
                let src = if byte == 0 {
                    a::ZR as u8
                } else if byte == 0x100 {
                    let rb = self.reg(t.b) as u32;
                    // Replicate the byte into every byte of x16.
                    self.emit(a::uxt(a::IP0, rb, 8));
                    self.mov_imm(a::IP1 as u8, 0x0101010101010101, true);
                    self.emit(a::mul(true, a::IP0, a::IP0, a::IP1));
                    a::IP0 as u8
                } else {
                    self.mov_imm(a::IP0 as u8, byte * 0x0101010101010101, true);
                    a::IP0 as u8
                };
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
                let r = self.tmp(step == 16);
                self.mem(
                    if step == 16 {
                        a::M_VQ
                    } else {
                        size_kind(step)
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
                self.mem(
                    if step == 16 {
                        a::M_VQ
                    } else {
                        size_kind(step)
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
            "memset"
        } else if overlap {
            "memmove"
        } else {
            "memcpy"
        };
        let vs: [Value; 3] = [t.a, t.b, t.c];
        return self.rt_call(i, name, vs, T_NONE);
    }

    fn select_op(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let cx = self.vx(t.a);
        let fc = self.folded_cmp(t.a);
        let cc = if fc != NONE {
            fc
        } else if self.pend.inst == cx && self.pend.inst != NONE {
            self.pend.cc
        } else {
            let rc = self.reg(t.a);
            self.emit(a::logic_imm(false, 3, a::ZR, rc, a::logical_imm(0xFF, false)));
            a::NE
        };
        if in_mem(ty) {
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
        if !is_v(ty) && self.cond_sel(i, t, cc) {
            return true;
        }
        // An integer 0 is the zero register.
        let rb = self.reg_or_zr(t.b, ty);
        let rc = self.reg_or_zr(t.c, ty);
        let rd = self.def_step(i);
        if is_v(ty) {
            self.emit(a::fcsel(ty == T_F64, rd - V0, rb - V0, rc - V0, cc));
        } else {
            self.emit(a::csel(true, 0, 0, rd, rb, rc, cc));
        }
        return true;
    }

    // Integer select `t`, instruction `i`, on condition `cc` as one conditional instruction from one side
    // (`csinc`, `csinv`, `csneg`): a folded side that is the other plus 1, negated or inverted
    // (`lv::FOLD_CSEL`), or a side 1 or all ones, the other no constant (the zero register gives it).
    // Whether it did.
    fn cond_sel(self: &mut Self, i: u32, t: Inst, cc: u32) bool {
        let bits = type_bits(t.ty, self.ptr);
        let sf = bits == 64;
        let m = if sf {
            u64::MAX
        } else {
            (1u64 << bits as u64) - 1
        };
        let b = self.b();
        let fb = (t.b & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.b as usize];
        let fc = (t.c & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.c as usize];
        if fb || fc {
            let (side, x, cond) = if fb {
                (t.b, t.c, a::invert(cc))
            } else {
                (t.c, t.b, cc)
            };
            let kind = lv::cs_kind(b, side, x);
            let rx = self.reg(x) as u32;
            let rd = self.def_step(i) as u32;
            let (op, o2) = if kind == lv::CS_INC {
                (0u32, 1u32)
            } else if kind == lv::CS_NOT {
                (1u32, 0u32)
            } else {
                (1u32, 1u32)
            };
            self.emit(a::csel(sf, op, o2, rd, rx, rx, cond));
            return true;
        }
        let mut kb: u64 = 0;
        let mut kc: u64 = 0;
        let cb = self.const_of(t.b, &mut kb);
        let cc2 = self.const_of(t.c, &mut kc);
        let ob = cb && !cc2 && ((kb & m) == 1 || (kb & m) == m);
        let oc = cc2 && !cb && ((kc & m) == 1 || (kc & m) == m);
        if !ob && !oc {
            return false;
        }
        let (x, k, cond) = if ob {
            (t.c, kb & m, a::invert(cc))
        } else {
            (t.b, kc & m, cc)
        };
        let rx = self.reg(x) as u32;
        let rd = self.def_step(i) as u32;
        // `csinc rd, x, zr` gives 1 where the condition fails, `csinv rd, x, zr` all ones.
        self.emit(a::csel(sf, (k != 1) as u32, (k == 1) as u32, rd, rx, a::ZR, cond));
        return true;
    }

    // Value `v` of type `ty` in a register: the zero register for an integer constant 0.
    fn reg_or_zr(self: &mut Self, v: Value, ty: u8) u8 {
        let mut k: u64 = 0;
        if !is_v(ty) && self.const_of(v, &mut k) && k == 0 {
            return a::ZR as u8;
        }
        return self.reg(v);
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
        if in_mem(ty) {
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
            28
        } else {
            24
        };
        let step = if vr {
            16 * n
        } else {
            8 * n
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
                16i64
            } else {
                8i64
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
            8
        } else {
            sz + 7 & ~7u32
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
            t.ty
        } else {
            self.vt(t.b)
        };
        assert(!in_mem(ty) && !is_v(ty), "a64gen: an atomic access of a type the verifier rejects");
        let size = type_bytes(ty, self.ptr).trailing_zeros() as u32;
        let ord = t.aux & 7;
        let acq = ord == MO_ACQUIRE || ord == MO_ACQ_REL || ord == MO_SEQ_CST;
        let rel = ord == MO_RELEASE || ord == MO_ACQ_REL || ord == MO_SEQ_CST;
        // The address in a register.
        let (base, off) = self.addr(
            t.a,
            if op == O_ACAS {
                0
            } else {
                t.c as i32
            },
        );
        let rp = if base == a::SP || base == a::FP || off != 0 {
            self.add_off(a::IP1 as u8, base, off);
            a::IP1
        } else {
            base
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
                a::LSE_SWP
            } else if r == RMW_ADD {
                a::LSE_ADD
            } else if r == RMW_SUB {
                self.emit(a::addsub_reg(true, 1, false, a::IP0, a::ZR, rv, 0, 0));
                src = a::IP0;
                a::LSE_ADD
            } else if r == RMW_AND {
                self.emit(a::logic_reg(true, 1, true, a::IP0, a::ZR, rv, 0, 0));
                src = a::IP0;
                a::LSE_CLR
            } else if r == RMW_OR {
                a::LSE_SET
            } else {
                a::LSE_EOR
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

// A branch condition: the flags (`cc`), a register compared with zero (`cbz`, `cbnz`: `cc` 64 for all
// its bits, else the low 32), or one bit of a register (`tbz`, `tbnz`: `cc` the bit).
struct Test {
    pub(package) kind: u8, // T_CC, T_CBZ, T_CBNZ, T_TBZ, T_TBNZ
    pub(package) cc: u32,
    pub(package) reg: u32,
}

extend Test as Copy {}

const T_CC: u8 = 0;
const T_CBZ: u8 = 1;
const T_CBNZ: u8 = 2;
const T_TBZ: u8 = 3;
const T_TBNZ: u8 = 4;

// Whether value `v` of `b` is an `O_HTOF`'s.
const fn half_conv_of(b: &Body, v: Value) bool {
    return (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_HTOF;
}

const fn invert_test(t: Test) Test {
    if t.kind == T_CC {
        return Test { kind: T_CC, cc: a::invert(t.cc), reg: 0 };
    }
    // T_CBZ and T_CBNZ, T_TBZ and T_TBNZ: each pair differs in the low bit of `kind - 1`.
    return Test { kind: (t.kind - 1 ^ 1) + 1, cc: t.cc, reg: t.reg };
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
            self.intrinsic(t.a)
        } else {
            ""
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
                    V0
                } else {
                    0
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
                self.lay.parts[loc.p0 as usize].reg as u32
            } else {
                0u32
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
            if !shared && loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!in_mem(vty) || self.vec_in_reg(
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
                } else if in_mem(vty) {
                    let (base, off) = self.mloc(v);
                    self.copy_mem(a::SP, loc.off, base, off, loc.size);
                } else {
                    let r = self.tmp(is_v(vty));
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
            let mv = loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) == 0 && (!in_mem(vty) || self.vec_in_reg(
                loc,
                vty,
            )) && src.kind != LC_VAL;
            if loc.kind == ab::L_REG && (b.pool[(sig + 3 + k) as usize] & AGG) != 0 && relay_parts(
                self,
                i,
                v,
                loc,
                &mut rvals,
            ) {
                moved.push(true);
                clean.push(true);
                continue;
            }
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
                            rres
                        } else if pa.v {
                            pa.reg + V0
                        } else {
                            pa.reg
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
        resolve_moves(self);
        // The moved values' registers now hold arguments.
        self.forget_caller_saved();
        // The relayed aggregate parts' constants and addresses (`relay_parts`).
        for q in 0..rvals.len() {
            self.materialize(rvals[q] as u32, (rvals[q] >> 32) as u8);
        }
        for k in 0..np {
            let loc = self.lay.locs[k as usize];
            let v = b.pool[(t.c + k) as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            let agg = (pt & AGG) != 0;
            let vty = self.vt(v);
            if moved[k as usize] && agg {
                continue;
            }
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
                    // A frame address loads its parts through the frame's register; two 8-byte integer
                    // parts as a pair.
                    let (fr, base, off) = self.frame_addr(v);
                    if !fr {
                        self.materialize(v, a::IP1 as u8);
                    }
                    let p0 = self.lay.parts[loc.p0 as usize];
                    let p1 = self.lay.parts[(loc.p0 + loc.n as u32 - 1) as usize];
                    let at = off + p0.off as i64;
                    if loc.n == 2 && !p0.v && !p1.v && p0.size == 8 && p1.size == 8 && p1.off == p0.off + 8 && at % 8 == 0 && at >= -512 && at < 512 {
                        self.emit(a::ldstp(a::M_X, true, 2, p0.reg, p1.reg, base, at as i32));
                    } else {
                        for q in 0..loc.n as u32 {
                            let pa = self.lay.parts[(loc.p0 + q) as usize];
                            self.load_part(pa, base, off + pa.off as i64);
                        }
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
                if !asmr::Asm::inline_a64(&text, self.apple, &mut self.code, &mut rels, &mut e) {
                    self.err.format_into("intrinsic: {}", e.as_str());
                    return false;
                }
                assert(rels.len() == 0, "a64: an intrinsic's instructions name no symbol");
            } else if self.elf && unsafe (*self.pkg).no_plt && unsafe (*self.pkg).syms[b.syms[t.a as usize] as usize].ext {
                // Through the address slot (`-fno-plt`): adrp x16, :got:x; ldr x16, [x16, :got_lo12:x];
                // blr x16.
                let os = self.osym_of(t.a);
                self.reloc(a::R_GOT_PAGE21, os, 0);
                self.emit(a::adr(true, a::IP0 as u8, 0));
                self.reloc(a::R_GOT_PAGEOFF12, os, 0);
                self.emit(a::ldst_uimm(a::M_X, true, a::IP0 as u8, a::IP0 as u8, 0));
                self.emit(a::blr(a::IP0));
            } else if self.sibling(i, t) {
                let os = self.osym_of(t.a);
                self.tails.push(self.code.len() as u64 << 32 | os as u64);
                self.emit(a::b(0));
                return true;
            } else {
                let os = self.osym_of(t.a);
                self.reloc(a::R_BRANCH26, os, 0);
                self.emit(a::bl(0));
            }
        } else {
            self.materialize(t.a, a::IP0 as u8);
            if self.sibling(i, t) {
                self.tails.push(self.code.len() as u64 << 32 | NONE as u64);
                self.emit(a::b(0));
                return true;
            }
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
                        rres
                    } else {
                        self.lay.parts[rl.p0 as usize].reg + V0
                    },
                );
            }
            return true;
        }
        if in_mem(t.ty) {
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
            V0
        } else {
            0
        };
        if self.fix_class(x) != FIX_NONE {
            let rd = self.def(i);
            self.move_reg(t.ty, rd, r);
        } else {
            self.bind(x, r);
        }
        return true;
    }

    // Whether call `t`, instruction `i`, is a sibling call (`Package.tail`, `tail_ok`): its block returns
    // its result (or nothing) right after it, its result's code is the body's, and it passes every
    // argument in registers and none an aggregate (a copy in this frame); then its return is not emitted
    // (`tail_ret`). The callee's argument registers are set; its branch follows the epilogue (`finish`).
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
        if !self.tail_ok || i + 2 != bk.start + bk.len {
            return false;
        }
        let r = b.insts[i as usize + 1];
        let rt = b.pool[t.b as usize + 2];
        if r.op != O_RET || !(r.a == i && t.ty != T_NONE || r.a == VNONE && t.ty == T_NONE) || rt != b.pool[b.sig as usize + 2] || (rt & AGG) != 0 {
            return false;
        }
        self.call_layout(t);
        if self.lay.ret.kind == ab::L_SRET {
            return false;
        }
        for k in 0..b.pool[t.b as usize] {
            if (b.pool[(t.b + 3 + k) as usize] & AGG) != 0 || self.lay.locs[k as usize].kind != ab::L_REG {
                return false;
            }
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
        if loc.kind != ab::L_REG || loc.n != 1 || !in_vreg(t) {
            return false;
        }
        let pa = self.lay.parts[loc.p0 as usize];
        return pa.v && pa.size as u32 == type_bytes(t, 8);
    }

    fn call_layout(self: &mut Self, t: Inst) {
        let b = self.b();
        if t.op == O_CALL && self.intrinsic(t.a).len() != 0 {
            let gp: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
            ab::intrinsic_layout(b, t.b, self.ptr, gp[0..8], 0, &mut self.lay);
            return;
        }
        // Once per signature in the body: the same signature has the same layout.
        for q in 0..self.lay_sig.len() {
            if self.lay_sig[q] == t.b {
                self.lay.copy_from(&self.lays[q]);
                return;
            }
        }
        cc::classify(b, t.b, self.ptr, self.apple, self.vregs, &mut self.lay);
        let q = self.lay_sig.len();
        self.lay_sig.push(t.b);
        if q == self.lays.len() {
            self.lays.push(ab::CallLayout::new());
        }
        self.lays[q].copy_from(&self.lay);
    }

    // The instructions of the intrinsic body symbol `s` names (`target::intrin`, `itpl`); empty for another
    // function.
    const fn intrinsic(self: &Self, s: u32) str<'static> {
        return self.itpl[s as usize];
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
        // The operands in registers stay there for one parallel move into x0.., as a call's arguments do;
        // one that lives on is in its home too. The constants and addresses follow.
        let mut keep = Vector::<u32>::with_capacity(vs.len());
        for k in 0..vs.len() {
            let x = self.vx(vs[k]);
            if self.va[x as usize].reg != NOREG {
                keep.push(x);
            }
        }
        self.clob = ~0u64;
        self.spill_around_call(&keep);
        self.mv.truncate(0);
        let mut vals = Vector::<bool>::with_capacity(vs.len());
        for k in 0..vs.len() {
            let src = self.loc_of(self.vx(vs[k]));
            vals.push(src.kind == LC_VAL);
            if src.kind != LC_VAL {
                self.mv.push(
                    Mv {
                        src: src,
                        dst: Lc { kind: LC_REG, reg: k as u8, off: 0, val: NONE },
                        v: false,
                        bytes: type_bytes(self.vt(vs[k]), self.ptr),
                        done: false,
                    },
                );
            }
        }
        resolve_moves(self);
        self.forget_caller_saved();
        for k in 0..vs.len() {
            if vals[k] {
                self.materialize(vs[k], k as u8);
            }
        }
        // A narrow integer (a 32-bit size, a fill byte) extends to the register's width, as C reads it.
        for k in 0..vs.len() {
            let ty = self.vt(vs[k]);
            if type_bytes(ty, self.ptr) < 8 {
                self.emit(a::uxt(k as u32, k as u32, type_bits(ty, self.ptr)));
            }
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
                x
            } else {
                y
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
                    if is_v(ty) {
                        V0
                    } else {
                        gr
                    },
                );
                if !is_v(ty) {
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
                        if is_v(ty) {
                            V0
                        } else {
                            0
                        },
                    );
                } else {
                    self.bind(
                        x2,
                        if is_v(ty) {
                            V0
                        } else {
                            0
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
        let zt = self.zero_test(v);
        if zt.kind != T_CC {
            return zt;
        }
        let fc = self.folded_cmp(v);
        if fc != NONE {
            return Test { kind: T_CC, cc: fc, reg: 0 };
        }
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

    // The test of folded comparison `v` with zero as one branch: `x == 0` and `x != 0` as `cbz` and
    // `cbnz`, `(x & 2^n) == 0` and `!= 0` as `tbz` and `tbnz`. T_CC when `v` is not one.
    fn zero_test(self: &mut Self, v: Value) Test {
        let none = Test { kind: T_CC, cc: 0, reg: 0 };
        if (v & (VPARAM | VFLAG)) != 0 || !self.lv.pfold[v as usize] {
            return none;
        }
        let t = self.b().insts[v as usize];
        let mut k: u64 = 1;
        if t.op != O_ICMP || t.aux != C_EQ && t.aux != C_NE || !self.const_of(t.b, &mut k) || k != 0 {
            return none;
        }
        let bits = type_bits(self.vt(t.a), self.ptr);
        let eq = t.aux == C_EQ;
        if (t.a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[t.a as usize] {
            let n = self.b().insts[t.a as usize];
            if n.op != O_AND {
                return none;
            }
            let mut m: u64 = 0;
            if !self.const_of(n.b, &mut m) || m == 0 || (m & m - 1) != 0 || m.trailing_zeros() as u32 >= bits {
                return none;
            }
            let ra = self.reg(n.a) as u32;
            let kt = if eq {
                T_TBZ
            } else {
                T_TBNZ
            };
            return Test { kind: kt, cc: m.trailing_zeros() as u32, reg: ra };
        }
        let r = if bits < 32 {
            self.ext(t.a, false, bits)
        } else {
            self.reg(t.a)
        };
        let kz = if eq {
            T_CBZ
        } else {
            T_CBNZ
        };
        let w: u32 = if bits == 64 {
            64
        } else {
            32
        };
        return Test { kind: kz, cc: w, reg: r };
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
        } else if test.kind == T_TBZ || test.kind == T_TBNZ {
            self.emit(a::tbz(test.kind == T_TBNZ, test.reg, test.cc, 0));
        } else {
            self.emit(a::cbz(test.cc == 64, test.kind == T_CBNZ, test.reg, 0));
        }
    }

    // Whether block `k` follows the current one.
    const fn next_is(self: &Self, k: u32) bool {
        let q = self.pos as usize + 1;
        return q < self.lv.order.len() && self.lv.order[q] == k && !self.crosses(k);
    }

    // Whether block `k` is on the other side of the frame's edge from the current one (`shrink`).
    const fn crosses(self: &Self, k: u32) bool {
        return self.shrink && self.lv.after[k as usize] != self.lv.after[self.lv.order[self.pos as usize] as usize];
    }

    // Jump to block `k` (nothing when it follows, unless `force`).
    fn goto(self: &mut Self, k: u32, force: bool) {
        let q = self.pos as usize + 1;
        if !force && q < self.lv.order.len() && self.lv.order[q] == k && !self.crosses(k) {
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

    // Whether edge `e`'s moves may run before a branch on flags `test`: they leave the flags as they are,
    // and every parameter of `e`'s target (a loop header, its back edge) ends its range in this block, so
    // the other path reads none of the homes they write. One branch then takes the edge.
    fn early_moves(self: &Self, test: Test, e: u32) bool {
        if test.kind != T_CC {
            return false;
        }
        let b = self.b();
        let tb = b.blocks[b.edge_target(e) as usize];
        let ni = b.insts.len() as u32;
        for q in 0..tb.param_len as u32 {
            if self.lv.end[(ni + tb.param_start + q) as usize] > self.pos {
                return false;
            }
        }
        return true;
    }

    // A two-way branch: `test` takes edge `et`, else `ef`; each edge's moves on its own path, or before the
    // branch (`early_moves`).
    fn branch2(self: &mut Self, test: Test, et: u32, ef: u32) {
        let b = self.b();
        let mt = self.moves_needed(et);
        let mf = self.moves_needed(ef);
        let tt = b.edge_target(et);
        let tf = b.edge_target(ef);
        let q = self.pos as usize + 1;
        let next = if q < self.lv.order.len() && !self.crosses(self.lv.order[q]) {
            self.lv.order[q]
        } else {
            NONE
        };
        if !mt && !mf {
            if tt == next {
                self.cbranch(invert_test(test), tf);
            } else {
                self.cbranch(test, tt);
                self.goto(tf, false);
            }
        } else if mt && !mf && self.early_moves(test, et) {
            self.edge_moves(et);
            self.cbranch(test, tt);
            self.goto(tf, false);
        } else if !mt && mf && self.early_moves(test, ef) {
            self.edge_moves(ef);
            self.cbranch(invert_test(test), tf);
            self.goto(tt, false);
        } else if mt && !mf {
            self.branch_over(invert_test(test), tf, et);
        } else if !mt && mf {
            self.branch_over(test, tt, ef);
        } else {
            let w = self.code.len() as u32;
            self.emit_test(test);
            self.edge_moves(ef);
            // No move of `ef` left code (its arguments were in place): its branch alone, inverted.
            if self.code.len() as u32 == w + 1 {
                let _ = self.code.pop();
                self.cbranch(invert_test(test), tf);
            } else {
                self.goto(tf, true);
                self.here(w);
            }
            self.edge_moves(et);
            self.goto(tt, false);
        }
    }

    // A branch on `test` to block `k`, then the moves of edge `e` and a jump to its target. When the moves
    // leave no code (their arguments were in place), the branch inverted to that target alone.
    fn branch_over(self: &mut Self, test: Test, k: u32, e: u32) {
        let w = self.code.len() as u32;
        let nf = self.fix.len();
        self.cbranch(test, k);
        self.edge_moves(e);
        let te = self.b().edge_target(e);
        if !self.far && self.code.len() as u32 == w + 1 {
            let _ = self.code.pop();
            self.fix.truncate(nf);
            self.cbranch(invert_test(test), te);
            self.goto(k, false);
        } else {
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
                self.ext(t.a, false, bits)
            } else {
                self.reg(t.a)
            } as u32;
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
                if b.edge_nargs(e) == 0 {
                    self.cbranch(Test { kind: T_CC, cc: a::EQ, reg: 0 }, b.edge_target(e));
                } else {
                    stubs.push(self.code.len() as u64 << 32 | e as u64);
                    self.emit(a::bcond(a::EQ, 0));
                }
            }
            if last != NONE && stubs.len() == 0 && !self.far && self.next_is(b.edge_target(last)) && b.edge_nargs(last) == 0 && !self.moves_needed(
                d,
            ) {
                // The last case's block follows: its branch inverted to the default.
                let _ = self.code.pop();
                let _ = self.fix.pop();
                self.cbranch(Test { kind: T_CC, cc: a::NE, reg: 0 }, b.edge_target(d));
                return true;
            }
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
            let i = self.cur;
            if (rt & AGG) != 0 && i > b.blocks[self.lv.def_blk[i as usize] as usize].start && self.rstore[i as usize - 1] != 0 {
                // In the part registers already (`ret_moves`).
            } else if (rt & AGG) != 0 {
                let np = b.pool[b.sig as usize];
                let pv = VPARAM | b.blocks[0].param_start + np;
                let (base, off) = self.addr(pv, 0);
                for q in 0..rl.n as u32 {
                    let pa = self.self_lay.parts[(rl.p0 + q) as usize];
                    self.load_part(pa, base, off + pa.off as i64);
                }
            } else if self.ret_in_vreg(t.a) {
                // A vector a register holds, returned whole in one v register.
                let pa = self.self_lay.parts[rl.p0 as usize];
                let ra = self.va[self.vx(t.a) as usize].reg;
                self.emit(a::vmov(pa.size == 16, pa.reg, ra - V0));
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

    // Whether the body returns vector `v` whole in one v register and a v register holds it.
    const fn ret_in_vreg(self: &Self, v: Value) bool {
        let rl = self.self_lay.ret;
        if rl.kind != ab::L_REG || rl.n != 1 || self.va[self.vx(v) as usize].reg == NOREG || !in_vreg(self.vt(v)) {
            return false;
        }
        let pa = self.self_lay.parts[rl.p0 as usize];
        return pa.v && pa.size as u32 == type_bytes(self.vt(v), 8);
    }

    // The object symbol of C string `text`, one per text.
    fn cstr(self: &mut Self, text: str) u32 {
        return self.cs.sym(self.obj(), text);
    }

    // The stack guard's value into `r`: `__stack_chk_guard`, through its address slot.
    fn guard(self: &mut Self, r: u8) {
        let os = self.obj().sym("__stack_chk_guard");
        self.reloc(a::R_GOT_PAGE21, os, 0);
        self.emit(a::adr(true, r, 0));
        self.reloc(a::R_GOT_PAGEOFF12, os, 0);
        self.emit(a::ldst_uimm(a::M_X, true, r, r, 0));
        self.emit(a::ldst_uimm(a::M_X, true, r, r, 0));
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
        // A last branch to the epilogue falls through instead, and so does the one before it when the
        // block between held only that branch: one step per branch.
        let mut popped = false;
        while self.epi.len() != 0 && self.epi[self.epi.len() - 1] + 1 == self.code.len() as u32 {
            let _ = self.epi.pop();
            let _ = self.code.pop();
            popped = true;
        }
        let mut local = self.spill_base + self.spill_top + 15 & ~15u32;
        if self.max_align > 16 {
            local = local + self.max_align - 1 & ~(self.max_align - 1);
        }
        let mut pro = Vector::<u32>::new();
        // A leaf body keeps its return address in x30: no frame record, and its frame from sp. The
        // compact unwind encoding's frameless form holds frames up to 65520 bytes.
        let leaf = self.frameless && local <= 32768 && self.canary < 0 && !self.calls_before(self.code.len() as u32);
        if !leaf {
            pro.push(a::ldstp(a::M_X, false, 3, a::FP, a::LR, a::SP, -16));
            pro.push(a::add_imm(true, a::FP, a::SP, 0));
        }
        // The callee-saved registers in the pairs compact unwind names (x19/x20 to x27/x28, d8/d9 to
        // d14/d15), both of a pair when the body uses one: each pair below the last, its lower register 8
        // bytes higher (x19 at x29 - 8), as libunwind reads a frame. `xs` and `vs` hold each pair's lower
        // register.
        let mut xs = Vector::<u32>::new();
        let mut vs = Vector::<u32>::new();
        let mut enc: u32 = if leaf {
            0x02000000
        } else {
            0x04000000
        };
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
        if leaf {
            enc |= (csr_bytes + local) / 16 << 12;
        }
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
        // Shrink-wrapped (`shrink`), the prologue runs on each edge into the rare code (its words before the
        // warm code's end, `ra`), the epilogue but its `ret` on each edge out; a return from the warm code is a
        // `ret` alone.
        let sw = self.shrink;
        let ra = if sw {
            self.rare_at()
        } else {
            0u32
        };
        let pl = if sw {
            0u32
        } else {
            pro.len() as u32
        };
        let body_n = self.code.len() as u32;
        // The canary's check: on a mismatch `__stack_chk_fail`, which does not return.
        if self.canary >= 0 {
            self.mem(a::M_X, true, a::IP0 as u8, a::SP, self.canary);
            self.guard((a::IP0 + 1) as u8);
            self.emit(a::addsub_reg(true, 1, true, 31, a::IP0, a::IP0 + 1, 0, 0));
            self.emit(a::bcond(a::EQ, 8));
            let fs = self.obj().sym("__stack_chk_fail");
            self.reloc(a::R_BRANCH26, fs, 0);
            self.emit(a::bl(0));
        }
        // The epilogue.
        let mut epi = Vector::<u32>::new();
        if leaf {
            let mut back = local;
            while back > 4095 {
                epi.push(a::add_imm(true, a::SP, a::SP, 4095));
                back -= 4095;
            }
            if back != 0 {
                epi.push(a::add_imm(true, a::SP, a::SP, back));
            }
        } else if csr_bytes != 0 {
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
        if !leaf {
            epi.push(a::ldstp(a::M_X, true, 1, a::FP, a::LR, a::SP, 16));
        }
        epi.push(a::RET);
        // Branches: through a block that is one `b` alone, to that branch's target (at most 8 steps; one
        // to the epilogue's start).
        let mut thru = Map::<u32, u32>::new();
        for q in 0..self.fix.len() {
            let w = (self.fix[q] >> 32) as u32;
            if (self.code[w as usize] & 0xFC000000) == 0x14000000 {
                thru.insert(w, self.blk_at[(self.fix[q] as u32) as usize]);
            }
        }
        for q in 0..self.epi.len() {
            thru.insert(self.epi[q], body_n);
        }
        // An epilogue of `ret` alone (no frame, no canary check) takes each branch's place.
        let lone = epi.len() == 1 && self.code.len() as u32 == body_n;
        // Shrink-wrapped, the epilogue is in the code when the rare code returns (it falls into it, or
        // branches); its words `elen`.
        let mut used = !sw || popped;
        for q in 0..self.epi.len() {
            used = used || self.epi[q] >= ra;
        }
        let elen = if used {
            epi.len() as u32
        } else {
            0u32
        };
        let mut stubs = Vector::<u32>::new();
        // Shrink-wrapped: per target word, its entry or exit stub (NONE: none yet); the warm code's `ret`, and
        // the rare code's copy of the epilogue when the code holds none.
        let mut enter = Map::<u32, u32>::new();
        let mut leave = Map::<u32, u32>::new();
        let mut wret = NONE;
        let mut fret = NONE;
        for q in 0..self.fix.len() {
            let w = (self.fix[q] >> 32) as u32;
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
            if lone && to == body_n && (self.code[w as usize] & 0xFC000000) == 0x14000000 {
                self.code[w as usize] = a::RET;
                continue;
            }
            if sw && w < ra && to >= ra {
                // From the warm code into the rare code: through the prologue, or to a `ret` for the epilogue.
                let base = body_n + elen;
                to = if to >= body_n {
                    if wret == NONE {
                        wret = base + stubs.len() as u32;
                        stubs.push(a::RET);
                    }
                    wret
                } else {
                    switch enter.get(&to) {
                        Some(x) => *x,
                        None => {
                            let at = base + stubs.len() as u32;
                            stubs.extend_copy(&pro);
                            let bw = base + stubs.len() as u32;
                            stubs.push(a::b(((to as i64 - bw as i64) * 4) as i32));
                            enter.insert(to, at);
                            at
                        },
                    }
                };
            } else if sw && w >= ra && to >= body_n && !used {
                // From the rare code to the epilogue, which is not in the code: a copy of it.
                if fret == NONE {
                    fret = body_n + elen + stubs.len() as u32;
                    stubs.extend_copy(&epi);
                }
                to = fret;
            } else if sw && w >= ra && to < ra {
                // From the rare code into the warm code: through the epilogue but its `ret`.
                let base = body_n + elen;
                to = (switch leave.get(&to) {
                    Some(x) => *x,
                    None => {
                        let at = base + stubs.len() as u32;
                        for e in 0..epi.len() - 1 {
                            stubs.push(epi[e]);
                        }
                        let bw = base + stubs.len() as u32;
                        stubs.push(a::b(((to as i64 - bw as i64) * 4) as i32));
                        leave.insert(to, at);
                        at
                    },
                });
            }
            let off = (to as i64 - w as i64) * 4;
            if !a::reaches(self.code[w as usize], off) {
                // A conditional one makes `func` try again with every one over a `B`.
                return self.far && self.refuse("a branch out of range");
            }
            self.code[w as usize] = a::repatch(self.code[w as usize], off as i32);
        }
        for q in 0..self.epi.len() {
            let w = self.epi[q];
            self.code[w as usize] = if lone || sw && w < ra {
                a::RET
            } else {
                a::repatch(self.code[w as usize], ((body_n - w) * 4) as i32)
            };
        }
        // Each sibling call: the epilogue but its `ret`, then the branch to the callee (`b`, or `br x16`).
        // With no epilogue but the `ret` (or from shrink-wrapped warm code, which has no frame), the branch is
        // the call's own; else the call branches to a copy past the epilogue.
        // The body's last word a sibling call's branch, and no branch to the epilogue nor to a block at the
        // body's end (one whose branch to the epilogue went): nothing reaches the epilogue but that call, so
        // the branch goes and its copy of the epilogue takes the epilogue's place.
        let nt = self.tails.len();
        let mut reached = false;
        for q in 0..self.fix.len() {
            reached = reached || self.blk_at[(self.fix[q] as u32) as usize] >= body_n;
        }
        if !sw && nt != 0 && !reached && self.epi.len() == 0 && self.code.len() as u32 == body_n && (self.tails[nt - 1] >> 32) as u32 + 1 == body_n {
            let os = self.tails[nt - 1] as u32;
            let _ = self.tails.pop();
            let _ = self.code.pop();
            let _ = epi.pop();
            if os == NONE {
                epi.push(0xD61F0000u32 | a::IP0 << 5);
            } else {
                self.rels.push(
                    CRel { at: self.code.len() as u32 + epi.len() as u32, kind: a::R_BRANCH26, sym: os, addend: 0 },
                );
                epi.push(a::b(0));
            }
        }
        for q in 0..self.tails.len() {
            let w = (self.tails[q] >> 32) as u32;
            let os = self.tails[q] as u32;
            let mut at = w;
            if epi.len() > 1 && !(sw && w < ra) {
                at = self.code.len() as u32 + elen + stubs.len() as u32;
                self.code[w as usize] = a::repatch(self.code[w as usize], ((at - w) * 4) as i32);
                for k in 0..epi.len() - 1 {
                    stubs.push(epi[k]);
                }
                at += epi.len() as u32 - 1;
            }
            let word = if os == NONE {
                0xD61F0000u32 | a::IP0 << 5
            } else {
                self.rels.push(CRel { at: at, kind: a::R_BRANCH26, sym: os, addend: 0 });
                a::b(0)
            };
            if at == w {
                self.code[w as usize] = word;
            } else {
                stubs.push(word);
            }
        }
        // Into the object.
        let p = unsafe &*self.pkg;
        let ps = p.syms[s as usize];
        let o = self.obj();
        let k2 = o.sym(p.spell(ps.name));
        let size = (pl + self.code.len() as u32 + elen + stubs.len() as u32) * 4;
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
        let at = o.define(k2, sec, 2, size, fl);
        if !sw {
            o.put_words(sec, &pro);
        }
        o.put_words(sec, &self.code);
        if used {
            o.put_words(sec, &epi);
        }
        o.put_words(sec, &stubs);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + (pl + r.at) * 4, r.sym, r.addend);
        }
        if sw && self.elf {
            shrink_rules(o, k2, size, ra);
        } else if sw {
            // The warm code: no frame, the return address in x30. The rest: the frame record.
            o.frames.push(ob::OFrame { sym: k2, size: ra * 4, cfi_at: 0, cfi_len: 0, compact: 0x02000000, off: 0 });
            o.frames.push(ob::OFrame { sym: k2, size: size - ra * 4, cfi_at: 0, cfi_len: 0, compact: enc, off: ra * 4 });
        } else if self.elf && leaf {
            leaf_rules(o, k2, size, &xs, &vs, pl, local);
        } else if self.elf {
            frame_rules(o, k2, size, &xs, &vs);
        } else {
            o.frames.push(ob::OFrame { sym: k2, size: size, cfi_at: 0, cfi_len: 0, compact: enc, off: 0 });
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
            if !asmr::Asm::inline_a64(&tpl, self.apple, &mut self.code, &mut rels, &mut e) {
                self.err.format_into("inline assembly: {}", e.as_str());
                return false;
            }
            for k in 0..rels.len() {
                let sym = self.obj().sym(&rels[k].name);
                self.rels.push(CRel { at: rels[k].at, kind: rels[k].kind, sym: sym, addend: rels[k].addend });
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
        let at = o.define(k2, sec, 2, self.code.len() as u64 * 4, fl);
        o.put_words(sec, &self.code);
        for q in 0..self.rels.len() {
            let r = self.rels[q];
            o.reloc(sec, r.kind, at as u32 + r.at * 4, r.sym, r.addend);
        }
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

// The unwind rules of shrink-wrapped function `sym` (`size` bytes) for `.eh_frame`: the common entry's
// (no frame, the return address in x30) to its rare code's first word `ra`; from there the frame record (CFA
// = x29 + 16, x29 and x30 saved below it).
fn shrink_rules(o: &mut ob::Obj, sym: u32, size: u32, ra: u32) {
    let c0 = o.cfi.len() as u32;
    if ra < 64 {
        o.cfi.push((0x40 | ra) as u8);
    } else {
        // DW_CFA_advance_loc4.
        o.cfi.push(0x04);
        ob::w32(&mut o.cfi, ra);
    }
    // DW_CFA_def_cfa x29, 16; x29 at CFA - 16, x30 at CFA - 8.
    o.cfi.push(0x0C);
    o.cfi.push(a::FP as u8);
    o.cfi.push(16);
    o.cfi.push(0x80 | a::FP as u8);
    o.cfi.push(2);
    o.cfi.push(0x80 | a::LR as u8);
    o.cfi.push(1);
    o.frames.push(ob::OFrame { sym: sym, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0, compact: 0, off: 0 });
}

// The unwind rules of leaf function `sym` (`size` bytes, a prologue of `pl` words) for `.eh_frame`: the
// return address stays in x30; the CFA is sp plus 16 after each push of the callee-saved pairs whose
// lower registers are `xs` and `vs` (the lower register at the pair's top, its upper one 8 bytes below),
// then plus the `local` bytes the prologue's end has allocated.
fn leaf_rules(o: &mut ob::Obj, sym: u32, size: u32, xs: &Vector<u32>, vs: &Vector<u32>, pl: u32, local: u32) {
    let c0 = o.cfi.len() as u32;
    let nx = xs.len() as u32;
    let npush = nx + vs.len() as u32;
    for k in 0..npush {
        // One word per push; the pairs' DWARF numbers: x registers as they are, v0..v31 at 64..95.
        o.cfi.push(0x40 | 1);
        o.cfi.push(0x0E);
        dw::uleb(&mut o.cfi, 16 * (k + 1));
        let lo = if k < nx {
            xs[k as usize]
        } else {
            64 + vs[(k - nx) as usize]
        };
        o.cfi.push(0x05);
        dw::uleb(&mut o.cfi, lo);
        dw::uleb(&mut o.cfi, 2 * k + 1);
        o.cfi.push(0x05);
        dw::uleb(&mut o.cfi, lo + 1);
        dw::uleb(&mut o.cfi, 2 * k + 2);
    }
    if local != 0 {
        let d = pl - npush;
        if d < 64 {
            o.cfi.push((0x40 | d) as u8);
        } else {
            o.cfi.push(0x02);
            o.cfi.push(d as u8);
        }
        o.cfi.push(0x0E);
        dw::uleb(&mut o.cfi, 16 * npush + local);
    }
    o.frames.push(ob::OFrame { sym: sym, size: size, cfi_at: c0, cfi_len: o.cfi.len() as u32 - c0, compact: 0 });
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

// The NEON instruction (registers 0) of conversion `op` of lanes of `fl` into lanes of `tl`, NONE without
// one: an integer to a float of its width (SCVTF, UCVTF) and back (FCVTZS, FCVTZU: toward zero, saturating,
// NaN to 0, as the scalar conversions), an integer to twice its width (SSHLL, USHLL by 0) or half (XTN), a
// float to twice its width (FCVTL) or half (FCVTN).
const fn neon_conv(op: u8, fl: u8, tl: u8) u32 {
    let fb = type_bytes(fl, 8);
    let tb = type_bytes(tl, 8);
    let fi = !is_float(fl);
    let ti = !is_float(tl);
    if (op == O_SEXT || op == O_ZEXT) && fi && ti && tb == 2 * fb {
        return 0x0F00A400 | a::on(op == O_ZEXT, 1u32 << 29) | fb * 8 << 16;
    }
    if op == O_TRUNC && fi && ti && fb == 2 * tb {
        return a::v2op(false, 0x12, vsize(tb), 0, 0);
    }
    if (op == O_SITOFP || op == O_UITOFP) && fi && !ti && fb == tb {
        return a::v2op(false, 0x1D | a::on(op == O_UITOFP, 0x20), (tb == 8) as u32, 0, 0);
    }
    if (op == O_FPTOSI || op == O_FPTOUI) && !fi && ti && fb == tb {
        return a::v2op(false, 0x1B | a::on(op == O_FPTOUI, 0x20), 2 | (fb == 8) as u32, 0, 0);
    }
    if op == O_FPEXT && fl == T_F32 && tl == T_F64 {
        return a::v2op(false, 0x17, 1, 0, 0);
    }
    if op == O_FPTRUNC && fl == T_F64 && tl == T_F32 {
        return a::v2op(false, 0x16, 1, 0, 0);
    }
    return NONE;
}

// The NEON instruction (8 bytes, registers 0) of element-wise LIR operation `op` on lanes of `lt`, NONE
// without one; `un` set for one operand.
const fn neon_of_op(op: u8, lt: u8, un: &mut bool) u32 {
    let eb = type_bytes(lt, 8);
    let s = vsize(eb);
    let sz = (lt == T_F64) as u32;
    *un = op == O_NOT || op == O_NEG || op == O_FNEG || op == O_FSQRT;
    if op == O_ADD {
        return a::v3op(false, a::V3_ADD, s, 0, 0, 0);
    }
    if op == O_SUB {
        return a::v3op(false, a::V3_SUB, s, 0, 0, 0);
    }
    if op == O_MUL && eb < 8 {
        return a::v3op(false, a::V3_MUL, s, 0, 0, 0);
    }
    if op == O_SHL {
        // USHL: each lane by its amount's low byte.
        return 0x2E204400 | s << 22;
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
    if op == O_FSQRT {
        return a::v2op(false, a::V2_FSQRT, 2 | sz, 0, 0);
    }
    return NONE;
}

// The NEON compare (as `neon_of_op`) of `O_VCMP` condition `c` on lanes of `lt`, and whether it takes the
// operands swapped (the less-than conditions); `ne` and `une` are `eq`'s and `oeq`'s, NOT after.
const fn neon_cmp(c: u16, lt: u8) (u32, bool) {
    if is_float(lt) {
        let sz = (lt == T_F64) as u32;
        if c == C_OEQ || c == C_UNE {
            return (a::v3op(false, 0x1C, sz, 0, 0, 0), false);
        }
        // FCMGE size 0|sz, FCMGT size 2|sz.
        let size = if c == C_OGE || c == C_OLE {
            sz
        } else {
            2 | sz
        };
        return (a::v3op(false, 0x3C, size, 0, 0, 0), c == C_OLT || c == C_OLE);
    }
    let s = vsize(type_bytes(lt, 8));
    if c == C_EQ || c == C_NE {
        return (a::v3op(false, 0x31, s, 0, 0, 0), false);
    }
    // CMGT 0x06, CMGE 0x07, CMHI 0x26, CMHS 0x27.
    let u = c >= C_ULT;
    let ge = c == C_SGE || c == C_SLE || c == C_UGE || c == C_ULE;
    let op = a::on(u, 0x20) | 0x06 | ge as u32;
    return (a::v3op(false, op, s, 0, 0, 0), c == C_SLT || c == C_SLE || c == C_ULT || c == C_ULE);
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
                a::V3_SMIN
            } else {
                a::V3_UMIN
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
                a::V3_SMAX
            } else {
                a::V3_UMAX
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
        return (b, o + (k * eb) as i64);
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
            16
        } else {
            8
        };
        let m = if q {
            a::M_VQ
        } else {
            a::M_VD
        };
        let wq = w | a::on(q, 1u32 << 30);
        let r30 = V0 + 30;
        let r31 = V0 + 31;
        let rc = if acc != VNONE {
            self.tmp(true)
        } else {
            r30
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
                31u32 << 16
            } else {
                0u32
            };
            self.emit(wq | (rc - V0) as u32 | 30u32 << 5 | rm);
            self.mem(m, false, rc, a::SP, d + at as i64);
            at += step;
        }
    }

    // NEON instruction `w` of vector `x` and register v`m` into vector `i`'s register.
    fn neon_reg_m(self: &mut Self, w: u32, i: u32, x: Value, m: u32, nb: u32) {
        let rx = self.vec_use(x, V0 + 30);
        let rd = self.def_step(i);
        self.emit(w | a::on(nb == 16, 1u32 << 30) | (rd - V0) as u32 | (rx - V0) as u32 << 5 | m << 16);
    }

    // Neon instruction `w` (its register fields 0) of one register's width (`nb`, 8 or 16 bytes) on `x`
    // and `y` (VNONE: none), accumulating into a copy of `acc` (VNONE: none), into a register that holds
    // result `i`.
    fn neon_reg(self: &mut Self, w: u32, i: u32, x: Value, y: Value, acc: Value, nb: u32) {
        let wq = w | a::on(nb == 16, 1u32 << 30);
        let rx = self.vec_use(x, V0 + 30);
        let ry = if y != VNONE {
            self.vec_use(y, V0 + 31)
        } else {
            0u8
        };
        // A result written over no operand may take a back edge's parameter register (`def_step`).
        let rd = if acc == VNONE {
            self.def_step(i)
        } else {
            self.vec_def(i)
        };
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
            (ry - V0) as u32 << 16
        } else {
            0u32
        };
        self.emit(wq | (rd - V0) as u32 | (rx - V0) as u32 << 5 | rm);
    }

    // Lane-wise comparison `t` into mask `i`: one NEON compare (`neon_cmp`), then NOT for `ne` and `une`; a
    // vector outside a v register compares each lane, CSETM giving its mask.
    fn vcmp(self: &mut Self, i: u32, t: Inst) {
        let vt = self.vt(t.a);
        let lt = lane_type(vt);
        let nb = type_bytes(vt, 8);
        if in_vreg(vt) {
            let (w, swap) = neon_cmp(t.aux, lt);
            if swap {
                self.neon_reg(w, i, t.b, t.a, VNONE, nb);
            } else {
                self.neon_reg(w, i, t.a, t.b, VNONE, nb);
            }
            if t.aux == C_NE || t.aux == C_UNE {
                let rd = self.va[self.vx(i) as usize].reg;
                self.emit(a::v2op(nb == 16, a::V2_NOT, 0, rd - V0, rd - V0));
            }
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let ml = lane_type(mask_type(vt));
        let x = self.tmp(false);
        if is_float(lt) {
            let dd = lt == T_F64;
            let fa = self.tmp(true);
            let fb = self.tmp(true);
            let mut c2: u32 = NONE;
            let cond = fcond(t.aux, &mut c2);
            for k in 0..lanes(vt) {
                self.ld_lane(fa, t.a, k, lt, false, false);
                self.ld_lane(fb, t.b, k, lt, false, false);
                self.emit(a::fcmp(dd, fa - V0, fb - V0));
                self.emit(a::csel(true, 1, 0, x, a::ZR, a::ZR, a::invert(cond)));
                self.st_lane(x, d, k, ml, false);
            }
            return;
        }
        let y = self.tmp(false);
        let sg = signed_cond(t.aux);
        for k in 0..lanes(vt) {
            self.ld_lane(x, t.a, k, lt, sg, false);
            self.ld_lane(y, t.b, k, lt, sg, false);
            self.emit(a::addsub_reg(true, 1, true, a::ZR, x, y, 0, 0));
            self.emit(a::csel(true, 1, 0, x, a::ZR, a::ZR, a::invert(icond(t.aux))));
            self.st_lane(x, d, k, ml, false);
        }
    }

    // Vector constant `t` into a v register for `i`: 0 and all ones by MOVI, else each 8-byte word through
    // ip0 (DUP when one word repeats, else FMOV then INS).
    fn wconst_reg(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let q = type_bytes(t.ty, 8) == 16;
        let w0 = b.words[t.a as usize];
        let w1 = if q {
            b.words[t.a as usize + 1]
        } else {
            w0
        };
        let rd = self.vec_def(i) - V0;
        if w0 == w1 && (w0 == 0 || w0 == ~0u64) {
            // MOVI Vd.2D (or Dd), #0 or #-1: cmode 1110, op 1, imm8 0 or 0xFF.
            self.emit(0x2F00E400 | a::on(q, 1u32 << 30) | a::on(w0 != 0, 0x7u32 << 16 | 0x1Fu32 << 5) | rd as u32);
            return;
        }
        self.mov_imm(a::IP0 as u8, w0, true);
        if q && w0 == w1 {
            // DUP Vd.2D, ip0.
            self.emit(0x4E080C00 | a::IP0 << 5 | rd as u32);
            return;
        }
        self.emit(a::fmov_gv(true, true, rd, a::IP0 as u8));
        if q {
            self.mov_imm(a::IP0 as u8, w1, true);
            // INS Vd.D[1], ip0.
            self.emit(0x4E181C00 | a::IP0 << 5 | rd as u32);
        }
    }

    // The even lanes of `t.a ++ t.b` into vector `i`: UZP1; a vector outside a v register moves each lane.
    fn vunzip(self: &mut Self, i: u32, t: Inst) {
        let nb = type_bytes(t.ty, 8);
        let lt = lane_type(t.ty);
        if in_vreg(t.ty) {
            self.neon_reg(0x0E001800 | vsize(type_bytes(lt, 8)) << 22, i, t.a, t.b, VNONE, nb);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let n = lanes(t.ty);
        let x = self.tmp(false);
        for k in 0..n {
            if 2 * k < n {
                self.ld_lane(x, t.a, 2 * k, lt, false, true);
            } else {
                self.ld_lane(x, t.b, 2 * k - n, lt, false, true);
            }
            self.st_lane(x, d, k, lt, true);
        }
    }

    // Lane interleave `t` (`O_VZIPLO`, `O_VZIPHI`) into vector `i`: ZIP1 or ZIP2; a vector outside a v
    // register moves each lane.
    fn vzip(self: &mut Self, i: u32, t: Inst) {
        let nb = type_bytes(t.ty, 8);
        let lt = lane_type(t.ty);
        if in_vreg(t.ty) {
            let w = if t.op == O_VZIPLO {
                0x0E003800u32
            } else {
                0x0E007800u32
            };
            self.neon_reg(w | vsize(type_bytes(lt, 8)) << 22, i, t.a, t.b, VNONE, nb);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        let d = self.mdef(i);
        let n = lanes(t.ty);
        let h = if t.op == O_VZIPHI {
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

    // Lane access `t` (`O_VEXTRACT`, `O_VINSERT`, lane `t.aux`) into `i`: DUP (a float) or UMOV (an
    // integer) of the lane, or a copy of the vector then INS of the scalar; a vector outside a v register
    // loads the lane, or copies its bytes and stores the lane.
    fn vlane(self: &mut Self, i: u32, t: Inst) {
        let k = t.aux as u32;
        if t.op == O_VEXTRACT {
            let eb = type_bytes(t.ty, 8);
            if in_vreg(self.vt(t.a)) {
                let rv = self.vec_use(t.a, V0 + 31) as u32 - V0 as u32;
                let rd = self.def(i) as u32;
                // imm5: the index above the lane size's bit.
                let imm5 = (k << 1 | 1) << eb.trailing_zeros() as u32;
                if is_float(t.ty) {
                    self.emit(0x5E000400 | imm5 << 16 | rv << 5 | rd - V0 as u32);
                } else {
                    self.emit(0x0E003C00 | a::on(eb == 8, 1u32 << 30) | imm5 << 16 | rv << 5 | rd);
                }
                return;
            }
            let rd = self.def(i);
            self.ld_lane(rd, t.a, k, t.ty, false, false);
            return;
        }
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        let nb = type_bytes(t.ty, 8);
        if !in_vreg(t.ty) {
            let (sb, so) = self.mloc(t.a);
            let rs = self.reg(t.b);
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, sb, so, nb);
            self.st_lane(rs, d, k, lt, false);
            return;
        }
        let mut rs = self.reg(t.b) as u32;
        let ra = self.vec_use(t.a, V0 + 30);
        let rd = self.vec_def(i);
        if is_float(lt) && rs == rd as u32 {
            // The scalar shares the result's register: kept in v31 across the vector's copy.
            self.emit(a::vmov(true, 31, rd - V0));
            rs = V0 as u32 + 31;
        }
        if ra != rd {
            self.emit(a::vmov(nb == 16, rd - V0, ra - V0));
        }
        let imm5 = (k << 1 | 1) << eb.trailing_zeros() as u32;
        if is_float(lt) {
            // INS Vd.T[k], Vn.T[0].
            self.emit(0x6E000400 | imm5 << 16 | rs - V0 as u32 << 5 | (rd - V0) as u32);
        } else {
            // INS Vd.T[k], Wn or Xn.
            self.emit(0x4E001C00 | imm5 << 16 | rs << 5 | (rd - V0) as u32);
        }
    }

    // Lane select `t` into vector `i`: BSL over a copy of the mask; a vector outside a v register selects
    // each lane's bits.
    fn vsel(self: &mut Self, i: u32, t: Inst) {
        let nb = type_bytes(t.ty, 8);
        if in_vreg(t.ty) {
            self.neon_reg(a::v3op(false, a::V3_EOR, 1, 0, 0, 0), i, t.b, t.c, t.a, nb);
            return;
        }
        self.sync(t.a);
        self.sync(t.b);
        self.sync(t.c);
        let d = self.mdef(i);
        let lt = lane_type(t.ty);
        let m = self.tmp(false);
        let x = self.tmp(false);
        let y = self.tmp(false);
        for k in 0..lanes(t.ty) {
            self.ld_lane(m, t.a, k, lt, false, true);
            self.ld_lane(x, t.b, k, lt, false, true);
            self.ld_lane(y, t.c, k, lt, false, true);
            self.emit(a::logic_reg(true, 0, false, x, x, m, 0, 0));
            self.emit(a::logic_reg(true, 0, true, y, y, m, 0, 0));
            self.emit(a::logic_reg(true, 1, false, x, x, y, 0, 0));
            self.st_lane(x, d, k, lt, true);
        }
    }

    // A binary16 conversion (`O_HTOF`, `O_FTOH`): the encoding in the low 16 bits of a v register, which
    // FMOV moves to and from a general register's low 32 bits, and FCVT widens or rounds.
    // In binary16 form (`hform`), the encoding stays in the H register: a move alone.
    fn half_conv(self: &mut Self, i: u32, t: Inst) {
        let h = self.hform[i as usize];
        if t.op == O_HTOF {
            let ra = self.reg(t.a) as u32;
            let rd = self.def(i) as u32 - V0 as u32;
            self.emit(a::fmov_gv(false, true, rd, ra));
            if !h {
                self.emit(a::fcvt_h(true, rd, rd));
            }
            return;
        }
        let ra = self.reg(t.a) as u32 - V0 as u32;
        let rd = self.def(i) as u32;
        if h {
            self.emit(a::fmov_gv(false, false, rd, ra));
            return;
        }
        let s = 31u32;
        self.emit(a::fcvt_h(false, s, ra));
        self.emit(a::fmov_gv(false, false, rd, s));
    }

    // `dup` of scalar `t.a` into every lane of vector `i`: from a general register, or lane 0 of a float's v
    // register; a vector wider than a v register stores each lane.
    fn splat(self: &mut Self, i: u32, t: Inst) {
        let lt = lane_type(t.ty);
        let eb = type_bytes(lt, 8);
        if !in_vreg(t.ty) {
            let r = self.reg(t.a);
            let d = self.mdef(i);
            for k in 0..lanes(t.ty) {
                self.st_lane(r, d, k, lt, false);
            }
            return;
        }
        let rs = self.reg(t.a);
        let rd = self.vec_def(i);
        // imm5: the lane size's bit, index 0.
        let w = a::on(type_bytes(t.ty, 8) == 16, 1u32 << 30) | eb << 16 | (rd - V0) as u32;
        if is_float(lt) {
            self.emit(0x0E000400 | w | (rs - V0) as u32 << 5);
        } else {
            self.emit(0x0E000C00 | w | rs as u32 << 5);
        }
    }

    // A v register for vector result `i`, which holds it: its home register (`plan_homes`), else a free
    // one (its home, a slot, comes when it spills).
    fn vec_def(self: &mut Self, i: u32) u8 {
        return self.def(i);
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

    // Lane test `c` (a comparison, or a float class test: NaN, infinite, finite, sign) of the vectors `ops`
    // in v registers (`nb` bytes of lanes of `lt`, signed `sg`) into bitmask `i`: the NEON compare's lane
    // masks (`neon_cmp`, NOT for `ne`; `nan` as `x != x`, the magnitude against infinity by FACGT or FACGE,
    // the sign by CMLT #0), then `mask_bits`.
    fn mask_reg(self: &mut Self, i: u32, c: u8, sg: bool, lt: u8, nb: u32, ops: &[Value; 4]) {
        let q = nb == 16;
        let fl = is_float(lt);
        let sz = (lt == T_F64) as u32;
        let rx = self.vec_use(ops[0], V0 + 30) - V0;
        let m = self.tmp(true);
        let mv = (m - V0) as u32;
        if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
            let ry = self.vec_use(ops[1], V0 + 31) - V0;
            let (w, swap) = neon_cmp(simd_cond(c, sg, fl), lt);
            let (p, r) = if swap {
                (ry, rx)
            } else {
                (rx, ry)
            };
            self.emit(w | a::on(q, 1u32 << 30) | mv | p as u32 << 5 | r as u32 << 16);
            if c == core::SIMD_CMP_NE {
                self.emit(a::v2op(q, a::V2_NOT, 0, mv, mv));
            }
        } else if c == core::SIMD_IS_NAN {
            self.emit(a::v3op(q, 0x1C, sz, mv, rx, rx));
            self.emit(a::v2op(q, a::V2_NOT, 0, mv, mv));
        } else if c == core::SIMD_IS_SIGN_NEG {
            // CMLT #0 of the lanes' bits.
            self.emit(0x0E20A800 | a::on(q, 1u32 << 30) | vsize(type_bytes(lt, 8)) << 22 | rx as u32 << 5 | mv);
        } else {
            let inf = self.tmp(true);
            let ib = if sz != 0 {
                0x7FF0000000000000u64
            } else {
                0x7F8000007F800000u64
            };
            self.vwords(inf, ib, ib, q);
            if c == core::SIMD_IS_FINITE {
                // FACGT: |inf| > |x|.
                self.emit(a::v3op(q, 0x3D, 2 | sz, mv, inf - V0, rx));
            } else {
                // FACGE: |x| >= |inf|.
                self.emit(a::v3op(q, 0x3D, sz, mv, rx, inf - V0));
            }
        }
        let mk = self.def(i);
        self.mask_bits(mk, m, type_bytes(lt, 8), nb);
    }

    // The bitmask of lane masks `m` (`nb` bytes of `eb`-byte lanes, each all ones or 0) into general
    // register `mk`, bit k for lane k: each lane ANDed with its bit, then summed across the lanes (ADDV;
    // ADDP for two lanes; each half of sixteen bytes on its own). `m` is clobbered.
    fn mask_bits(self: &mut Self, mk: u8, m: u8, eb: u32, nb: u32) {
        let q = nb == 16;
        let n = nb / eb;
        let mv = (m - V0) as u32;
        let w = self.tmp(true);
        let wv = (w - V0) as u32;
        self.lane_bits(w, eb, q);
        self.emit(a::v3op(q, a::V3_AND, 0, mv, mv, wv));
        if n == 16 {
            // EXT w, m, m, #8; ADDV of each half's bytes.
            self.emit(0x6E004000 | mv << 16 | mv << 5 | wv);
            self.emit(0x0E31B800 | mv << 5 | mv);
            self.emit(0x0E31B800 | wv << 5 | wv);
            let hi = self.tmp(false);
            self.emit(a::fmov_gv(false, false, mk, mv));
            self.emit(a::fmov_gv(false, false, hi, wv));
            self.emit(a::logic_reg(true, 1, false, mk, mk, hi, 0, 8));
            return;
        }
        if n == 2 && eb == 8 {
            // ADDP Dd, Vn.2D.
            self.emit(0x5EF1B800 | mv << 5 | mv);
            self.emit(a::fmov_gv(true, false, mk, mv));
            return;
        }
        if n == 2 {
            // ADDP Vd.2S.
            self.emit(0x0E20BC00 | 2u32 << 22 | mv << 16 | mv << 5 | mv);
        } else {
            self.emit(0x0E31B800 | a::on(q, 1u32 << 30) | vsize(eb) << 22 | mv << 5 | mv);
        }
        self.emit(a::fmov_gv(false, false, mk, mv));
    }

    // Each lane k of v register `w` (`eb`-byte lanes, 16 bytes when `q`, else 8) set to 1 << k, counted
    // from 0 again in each 8-byte half of byte lanes.
    fn lane_bits(self: &mut Self, w: u8, eb: u32, q: bool) {
        let (w0, w1) = if eb == 8 {
            (1u64, 2u64)
        } else if eb == 4 {
            (0x0000000200000001u64, 0x0000000800000004u64)
        } else if eb == 2 {
            (0x0008000400020001u64, 0x0080004000200010u64)
        } else {
            (0x8040201008040201u64, 0x8040201008040201u64)
        };
        self.vwords(w, w0, w1, q);
    }

    // v register `w` = 8-byte words `w0`, then `w1` when `q`, through ip0 (DUP when they are equal).
    fn vwords(self: &mut Self, w: u8, w0: u64, w1: u64, q: bool) {
        let wv = (w - V0) as u32;
        self.mov_imm(a::IP0 as u8, w0, true);
        if q && w0 == w1 {
            // DUP Vd.2D, ip0.
            self.emit(0x4E080C00 | a::IP0 << 5 | wv);
            return;
        }
        self.emit(a::fmov_gv(true, true, wv, a::IP0));
        if q {
            self.mov_imm(a::IP0 as u8, w1, true);
            // INS Vd.D[1], ip0.
            self.emit(0x4E181C00 | a::IP0 << 5 | wv);
        }
    }

    // Lane choice `ops[1]` where bitmask `ops[0]` has the lane's bit, else `ops[2]` (vectors in v
    // registers, `nb` bytes of lanes of `lt`): the bitmask in every lane (bytes: its low byte in the low
    // half, its high byte in the high one), CMTST against each lane's bit, then BSL.
    fn choose_reg(self: &mut Self, i: u32, ops: &[Value; 4], lt: u8, nb: u32) {
        let q = nb == 16;
        let eb = type_bytes(lt, 8);
        let rx = self.vec_use(ops[1], V0 + 30) - V0;
        let ry = self.vec_use(ops[2], V0 + 31) - V0;
        let rm = self.reg(ops[0]) as u32;
        let m = self.tmp(true);
        let mv = (m - V0) as u32;
        let w = self.tmp(true);
        let wv = (w - V0) as u32;
        if eb == 1 && q {
            // DUP m.8H; UZP1 w.16B (the low bytes); UZP2 m.16B (the high ones); ZIP1 m.2D, w, m.
            self.emit(0x4E020C00 | rm << 5 | mv);
            self.emit(0x4E001800 | mv << 16 | mv << 5 | wv);
            self.emit(0x4E005800 | mv << 16 | mv << 5 | mv);
            self.emit(0x4EC03800 | mv << 16 | wv << 5 | mv);
        } else {
            // DUP m.T, the bitmask.
            self.emit(0x0E000C00 | a::on(q, 1u32 << 30) | eb << 16 | rm << 5 | mv);
        }
        self.lane_bits(w, eb, q);
        // CMTST m, m, w.
        self.emit(a::v3op(q, 0x11, vsize(eb), mv, mv, wv));
        let rd = self.vec_def(i);
        self.emit(a::vmov(q, rd - V0, mv));
        // BSL rd, x, y.
        self.emit(a::v3op(q, a::V3_EOR, 1, rd - V0, rx, ry));
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

    // Vector arithmetic: O_ADD .. O_NOT, O_FADD .. O_FNEG and O_FSQRT on vectors.
    fn vec_arith(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let nb = type_bytes(t.ty, 8);
        let mut un = false;
        let w = neon_of_op(op, lt, &mut un);
        let y = if un {
            VNONE
        } else {
            t.b
        };
        if w != NONE && in_vreg(t.ty) {
            self.neon_reg(w, i, t.a, y, VNONE, nb);
            return true;
        }
        if (op == O_LSHR || op == O_ASHR) && in_vreg(t.ty) {
            // USHL or SSHL by the negated amounts.
            let s = vsize(type_bytes(lt, 8));
            let rx = self.vec_use(t.a, V0 + 30);
            let ry = self.vec_use(t.b, V0 + 31);
            let rd = self.vec_def(i);
            let m = self.tmp(true);
            self.emit(a::v2op(nb == 16, a::V2_NEG, s, m - V0, ry - V0));
            let sh = if op == O_ASHR {
                0x0E204400u32
            } else {
                0x2E204400u32
            };
            self.emit(
                sh | a::on(nb == 16, 1u32 << 30) | s << 22 | (m - V0) as u32 << 16 | (rx - V0) as u32 << 5 | (rd - V0) as u32,
            );
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
                a::FP_ADD
            } else if op == O_FSUB {
                a::FP_SUB
            } else if op == O_FMUL {
                a::FP_MUL
            } else {
                a::FP_DIV
            };
            for k in 0..n {
                self.ld_lane(fa, t.a, k, lt, false, false);
                if op == O_FNEG || op == O_FSQRT {
                    self.emit(
                        a::fp1(dd, a::on(op == O_FNEG, a::FP_NEG) | a::on(op == O_FSQRT, a::FP_SQRT), fa - V0, fa - V0),
                    );
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
                        a::DP2_SDIV
                    } else {
                        a::DP2_UDIV
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
                        a::DP2_SDIV
                    } else {
                        a::DP2_UDIV
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
            (1u64 << (tb - 1) as u64) - 1
        } else {
            (1u64 << tb as u64) - 1
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
                    a::GT
                } else {
                    a::HI
                },
            ),
        );
        if signed {
            self.mov_imm(a::IP0 as u8, ~hi & 0xFFFFFFFF, false);
            self.emit(a::addsub_reg(false, 1, true, a::ZR, r, a::IP0, 0, 0));
            self.emit(a::csel(false, 0, 0, r, a::IP0, r, a::LT));
        }
    }

    // Whether vector conversion `t` has one NEON form (`neon_conv`) and both its vectors are in v registers.
    fn conv_reg(self: &Self, t: Inst) bool {
        return is_vec(t.ty) && t.op >= O_SEXT && t.op <= O_UITOFP && in_vreg(t.ty) && in_vreg(self.vt(t.a)) && neon_conv(
            t.op,
            lane_type(self.vt(t.a)),
            lane_type(t.ty),
        ) != NONE;
    }

    // A vector conversion of LIR (O_SEXT .. O_UITOFP on vectors): one NEON instruction in v registers
    // (`neon_conv`), else lane by lane.
    fn vec_convert(self: &mut Self, i: u32, t: Inst) {
        let op = t.op;
        let fl = lane_type(self.vt(t.a));
        let tl = lane_type(t.ty);
        if self.conv_reg(t) {
            // The forms between widths read or write the low 8 bytes (Q = 0).
            let same = type_bytes(fl, 8) == type_bytes(tl, 8);
            let nb = if same {
                type_bytes(t.ty, 8)
            } else {
                8
            };
            self.neon_reg(neon_conv(op, fl, tl), i, t.a, VNONE, VNONE, nb);
            return;
        }
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
            core::simd_op((code - core::OP_SIMD) as u8).rule
        } else {
            0u8
        };
        let sc = if simd {
            (code - core::OP_SIMD) as u8
        } else {
            0u8
        };
        let mreg = (sc == core::SIMD_LOAD_MASKED_PTR || sc == core::SIMD_STORE_MASKED_PTR) && Gen::masked_reg(
            self.b(),
            t,
        );
        if mreg {
            self.masked_in_reg(i, sc == core::SIMD_STORE_MASKED_PTR, &ops, &tys);
            return true;
        }
        let greg = sc == core::SIMD_GATHER_UNCHECKED && Gen::gather_reg(self.b(), t);
        if !greg && (!simd || rule == core::SR_MLOAD || rule == core::SR_MSTORE || rule == core::SR_REDUCE || rule == core::SR_DOT || rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED) {
            self.sync_ops(&ops);
        }
        if greg {
            self.gather_in_reg(i, &ops, &tys);
            return true;
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
            if in_vreg(t.ty) {
                // The count in each lane of v31 (negated for a right shift), then USHL or SSHL.
                let nb = type_bytes(t.ty, 8);
                let eb = type_bytes(lt, 8);
                if code == core::OP_SHR_SCALAR {
                    self.emit(a::addsub_reg(true, 1, false, kr, a::ZR, kr, 0, 0));
                }
                self.emit(0x0E000C00 | a::on(nb == 16, 1u32 << 30) | eb << 16 | kr as u32 << 5 | 31);
                let u = code == core::OP_SHL_SCALAR || !sg;
                let w = a::on(u, 0x20000000) | 0x0E204400 | vsize(eb) << 22;
                self.neon_reg_m(w, i, ops[0], 31, nb);
                return true;
            }
            let x = self.tmp(false);
            let d = self.mdef(i);
            let sop = if code == core::OP_SHL_SCALAR {
                a::DP2_LSLV
            } else if sg {
                a::DP2_ASRV
            } else {
                a::DP2_LSRV
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
                "fmodf"
            } else {
                "fmod"
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
        // A mask (`Mask<N>`, one bit per lane) of vectors in v registers, and a choice by one: lane masks.
        let lane_test = c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE || fl && (c == core::SIMD_IS_NAN || c == core::SIMD_IS_INF || c == core::SIMD_IS_FINITE || c == core::SIMD_IS_SIGN_NEG);
        if n >= 2 && in_vreg(vt) && (rule == core::SR_MASK && lane_test || rule == core::SR_CHOOSE) {
            if rule == core::SR_CHOOSE {
                self.choose_reg(i, ops, lt, nb);
            } else {
                self.mask_reg(i, c, sg, lt, nb, ops);
            }
            return;
        }
        if c == core::SIMD_ABS_DIFF && in_vreg(t.ty) && in_vreg(vt) && eb < 8 {
            // UABD or SABD.
            self.neon_reg(a::on(!sg, 0x20000000) | 0x0E207400 | vsize(eb) << 22, i, ops[0], ops[1], VNONE, nb);
            return;
        }
        if rule == core::SR_BITCAST && in_vreg(t.ty) && in_vreg(vt) && type_bytes(t.ty, 8) == nb {
            // The same bits in a register: a copy.
            let rx = self.vec_use(ops[0], V0 + 30);
            let rd = self.def_step(i);
            if rd != rx {
                self.emit(a::vmov(nb == 16, rd - V0, rx - V0));
            }
            return;
        }
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
            NONE
        } else {
            neon_of_simd(c, lt, sg, &mut un, &mut fma)
        };
        if w != NONE && in_vreg(t.ty) {
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
            lt
        } else {
            lane_type(t.ty)
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
            self.reg(ops[1])
        } else {
            NOREG
        };
        let cm = if rule == core::SR_CHOOSE {
            self.reg(ops[0])
        } else {
            NOREG
        };
        let x = self.tmp(false);
        let y = self.tmp(false);
        let z = self.tmp(false);
        let wr = self.tmp(false);
        let traps = !fl && sg && c == core::SIMD_ABS || c == core::SIMD_NARROW_CHECKED;
        // The bit rules read a lane's own bits: zero-extended whatever its sign.
        let bitop = c >= core::SIMD_CLZ && c <= core::SIMD_BSWAP;
        let fr = if traps {
            self.tmp(false)
        } else {
            NOREG
        };
        if traps {
            self.emit(a::mov_reg(true, fr, a::ZR));
        }
        let mut fails = Vector::<u64>::new();
        let (fa, fb, fc) = if fl {
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
                    a::HS
                } else {
                    a::LO
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
            a::LT
        } else {
            a::LO
        };
        if c == core::SIMD_WRAP_ADD || c == core::SIMD_WRAP_SUB || c == core::SIMD_WRAP_MUL {
            let op = if c == core::SIMD_WRAP_ADD {
                O_ADD
            } else if c == core::SIMD_WRAP_SUB {
                O_SUB
            } else {
                O_MUL
            };
            self.int_lane(op, x, y, z);
        } else if c == core::SIMD_WRAP_NEG {
            self.int_lane(O_NEG, x, y, z);
        } else if c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR {
            self.emit(a::logic_imm(true, 0, y, y, a::logical_imm(lb - 1, true)));
            let s = if c == core::SIMD_WRAP_SHL {
                a::DP2_LSLV
            } else if sg {
                a::DP2_ASRV
            } else {
                a::DP2_LSRV
            };
            self.emit(a::dp2(true, s, x, x, y));
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit: a signed overflow goes the way of the operand's sign, an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1
            } else {
                trunc64(~0u64, lb)
            };
            let min = if sg {
                (1u64 << (lb - 1) as u64).wrapping_neg()
            } else {
                0u64
            };
            let cond = self.ovf_lane(c, lb, sg, x, y, z, wr);
            self.emit(a::cset(true, wr, cond));
            if sg {
                self.mov_imm(
                    z,
                    if add {
                        max
                    } else {
                        min
                    },
                    true,
                );
                self.mov_imm(
                    a::IP0 as u8,
                    if add {
                        min
                    } else {
                        max
                    },
                    true,
                );
                self.emit(a::cmp_imm(true, y, 0));
                self.emit(a::csel(true, 0, 0, z, a::IP0, z, a::LT));
            } else {
                self.mov_imm(
                    z,
                    if add {
                        max
                    } else {
                        min
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
                        a::GT
                    } else {
                        a::HI
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
                (a::DP2_LSLV, a::DP2_LSRV)
            } else {
                (a::DP2_LSRV, a::DP2_LSLV)
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
            (1u64 << (rw - 1) as u64) - 1
        } else {
            trunc64(~0u64, rw)
        };
        let rmin = if rsg {
            (1u64 << (rw - 1) as u64).wrapping_neg()
        } else {
            0u64
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
                    a::GT
                } else {
                    a::HI
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
                a::FP_ABS
            } else if c == core::SIMD_SQRT {
                a::FP_SQRT
            } else if c == core::SIMD_CEIL {
                a::FP_RINTP
            } else if c == core::SIMD_FLOOR {
                a::FP_RINTM
            } else if c == core::SIMD_TRUNC {
                a::FP_RINTZ
            } else if c == core::SIMD_ROUND_EVEN {
                a::FP_RINTN
            } else {
                a::FP_NEG
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
                        a::FP_MIN
                    } else {
                        a::FP_MAX
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
            a::FP_MINNM
        } else {
            a::FP_MAXNM
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
            V0 + 30
        } else {
            fa
        };
        let vb = if fb == NOREG {
            V0 + 31
        } else {
            fb
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
            self.emit(a::mov_reg(true, p, r0));
        } else {
            let (base, off) = self.addr(ops[0], 0);
            self.mem(a::M_X, true, p, base, off);
            let st = self.reg(ops[1]);
            self.emit(a::addsub_reg(true, 0, false, p, p, st, 0, eb.trailing_zeros() as u32));
        }
        let vv = if raw {
            ops[1]
        } else {
            ops[2]
        };
        if load && in_vreg(vt) {
            let rd = self.vec_def(i);
            self.mem(mkind(vt, true), true, rd, p, 0);
        } else if load {
            let d = self.mdef(i);
            self.copy_mem(a::SP, d, p, 0, nb);
        } else if in_vreg(vt) {
            let r = self.vec_use(vv, V0 + 30);
            self.mem(mkind(vt, false), false, r, p, 0);
        } else {
            let (bv, ov) = self.mloc(vv);
            self.copy_mem(p, 0, bv, ov, nb);
        }
    }

    // The masked, partial and gather forms (the evaluator's `vmem_masked`): every active lane is checked
    // before the first access, the lowest failing one traps; an inactive lane never touches its element.
    // Whether unchecked gather `t` of `b` (place, indexes, mask, fallback) runs in v registers: its
    // indexes and result each one register of integer indexes of 4 or 8 bytes.
    const fn gather_reg(b: &Body, t: Inst) bool {
        if t.b != 4 {
            return false;
        }
        let it = b.type_of(b.pool[(t.a + 1) as usize]);
        return in_vreg(t.ty) && in_vreg(it) && lanes(it) == lanes(t.ty) && type_bytes(lane_type(it), 8) >= 4;
    }

    // Whether masked access `t` of `b` through a pointer (pointer, mask, vector) runs in a v register.
    const fn masked_reg(b: &Body, t: Inst) bool {
        return t.b == 3 && in_vreg(b.type_of(b.pool[(t.a + 2) as usize]));
    }

    // Masked load (into vector `i`, from the fallback's copy) or `store` through a pointer (`masked_reg`):
    // per lane the mask sets (each without a test for a constant mask), the lane's bytes through a
    // general register and INS or UMOV.
    fn masked_in_reg(self: &mut Self, i: u32, store: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let vt = tys[2];
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let n = lanes(vt);
        let nb = type_bytes(vt, 8);
        let mut mc: u64 = 0;
        let known = self.const_of(ops[1], &mut mc);
        let act = if known {
            NOREG
        } else {
            self.reg(ops[1])
        };
        let p = self.reg(ops[0]);
        let x = self.tmp(false);
        let rv = self.vec_use(ops[2], V0 + 31);
        let rd = if store {
            rv
        } else {
            let r = self.vec_def(i);
            if r != rv {
                self.emit(a::vmov(nb == 16, r - V0, rv - V0));
            }
            r
        };
        for k in 0..n {
            if known && (mc >> k as u64 & 1) == 0 {
                continue;
            }
            let w0 = self.code.len() as u32;
            if !known {
                self.emit(a::tbz(false, act, k, 0));
            }
            let im = (k << 1 | 1) << eb.trailing_zeros() as u32;
            if store {
                // UMOV x, rd.T[k]; its bytes at p + k * eb.
                self.emit(0x0E003C00 | a::on(eb == 8, 1u32 << 30) | im << 16 | (rd - V0) as u32 << 5 | x as u32);
                self.mem(lane_st(lt, true), false, x, p, k * eb);
            } else {
                self.mem(lane_ld(lt, false, true), true, x, p, k * eb);
                self.emit(0x4E001C00 | im << 16 | x as u32 << 5 | (rd - V0) as u32);
            }
            if !known {
                self.here(w0);
            }
        }
    }

    // Unchecked gather `ops` (`gather_reg`) into vector `i`: the fallback's copy, then per lane the mask
    // allows (every lane for a constant mask of all of them) the index by UMOV, the element's load and
    // INS into its lane.
    fn gather_in_reg(self: &mut Self, i: u32, ops: &[Value; 4], tys: &[u8; 4]) {
        let vt = tys[3];
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 8);
        let ib = type_bytes(lane_type(tys[1]), 8);
        let n = lanes(vt);
        let nb = type_bytes(vt, 8);
        let mut mc: u64 = 0;
        let all = trunc64(~0u64, n);
        let act = if self.const_of(ops[2], &mut mc) && (mc & all) == all {
            NOREG
        } else {
            self.reg(ops[2])
        };
        let r0 = self.reg(ops[0]);
        let p = self.tmp(false);
        self.mem(a::M_X, true, p, r0, 0);
        let ix = self.tmp(false);
        let x = self.tmp(false);
        let ri = self.vec_use(ops[1], V0 + 30) as u32 - V0 as u32;
        let rf = self.vec_use(ops[3], V0 + 31);
        let rd = self.vec_def(i);
        if rd != rf {
            self.emit(a::vmov(nb == 16, rd - V0, rf - V0));
        }
        let s = eb.trailing_zeros() as u32;
        for k in 0..n {
            let w0 = self.code.len() as u32;
            if act != NOREG {
                self.emit(a::tbz(false, act, k, 0));
            }
            // UMOV ix, ri.T[k]; the element at p + (ix << s); INS rd.T[k] from it.
            let im = (k << 1 | 1) << ib.trailing_zeros() as u32;
            self.emit(0x0E003C00 | a::on(ib == 8, 1u32 << 30) | im << 16 | ri << 5 | ix as u32);
            self.emit(a::addsub_reg(true, 0, false, x, p, ix, 0, s));
            self.mem(lane_ld(lt, false, true), true, x, x, 0);
            let em = (k << 1 | 1) << eb.trailing_zeros() as u32;
            self.emit(0x4E001C00 | em << 16 | x as u32 << 5 | (rd - V0) as u32);
            if act != NOREG {
                self.here(w0);
            }
        }
    }

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
            self.reg(ops[1])
        } else {
            NOREG
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
                ix
            } else {
                p
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
            a::LT
        } else {
            a::LO
        };
    }
    if c == core::SIMD_CMP_LE {
        return if sg {
            a::LE
        } else {
            a::LS
        };
    }
    if c == core::SIMD_CMP_GT {
        return if sg {
            a::GT
        } else {
            a::HI
        };
    }
    return if sg {
        a::GE
    } else {
        a::HS
    };
}

// The condition of float comparison rule `c` after `fcmp`: ordered, but `!=` holds for a NaN.
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
            0
        } else {
            1
        };
        let lt_c = if sg {
            a::LT
        } else {
            a::LO
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
            a::FP_ADD
        } else {
            a::FP_MUL
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
            1u64 << (lb - 1) as u64
        } else {
            trunc64(~0u64, lb)
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
                a::LT
            } else if min {
                a::LO
            } else if sg {
                a::GT
            } else {
                a::HI
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
                            a::MI
                        } else {
                            a::GT
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
            tys[1]
        } else {
            tys[0]
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
            self.b().pool[t.c as usize]
        } else {
            lanes(tys[1])
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

    // System operation `t` (`i`, `O_SYS`): the instructions the inline assembly it replaces held.
    fn sys(self: &mut Self, i: u32, t: Inst) bool {
        let s = t.aux;
        if s == SYS_BARRIER || s == SYS_KEEP {
            return true;
        }
        if s == SYS_SPIN {
            self.emit(a::ISB);
            return true;
        }
        if s == SYS_CYCLES || s == SYS_SVL {
            let rd = self.def(i);
            self.emit(
                if s == SYS_CYCLES {
                    a::mrs_cntvct(rd)
                } else {
                    a::rdsvl1(rd)
                },
            );
            return true;
        }
        if s == SYS_FPSAVE {
            let ra = self.reg(t.a);
            self.emit(a::mrs_fpcr(a::IP0));
            self.mem(a::M_X, false, a::IP0 as u8, ra, 0);
            return true;
        }
        return self.refuse("a system operation of another processor");
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
                    valloc()
                } else {
                    XALLOC
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
                    a::M_VQ
                } else {
                    a::M_X
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
                    V0 + 31
                } else {
                    a::IP0 as u8
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
        if !asmr::Asm::inline_a64(&text, self.apple, &mut self.code, &mut rels, &mut e) {
            self.err.format_into("inline assembly: {}", e.as_str());
            return false;
        }
        for k in 0..rels.len() {
            let s = self.obj().sym(&rels[k].name);
            self.rels.push(CRel { at: rels[k].at, kind: rels[k].kind, sym: s, addend: rels[k].addend });
        }
        for k in 0..saved.len() {
            let (cr, off) = saved[k];
            self.mem(
                if cr >= V0 {
                    a::M_VQ
                } else {
                    a::M_X
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
            ty == T_I64 || ty == T_PTR
        } else {
            md == b'x'
        };
        if md != 0 && md != b'w' && md != b'x' {
            return false;
        }
        o.format_into(
            "{}{}",
            if wide {
                "x"
            } else {
                "w"
            },
            rg,
        );
        return true;
    }
    let l = if md != 0 {
        md
    } else if ty == T_F64 {
        b'd'
    } else {
        b's'
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
