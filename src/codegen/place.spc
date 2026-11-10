// Where a native generator keeps each value and how it moves values between those places: the homes, the
// locations and the parallel-move resolver the arm64 and x86-64 generators (`target::a64gen`,
// `target::x64gen`) share, the aggregate arguments a call takes from the stores before it, and the object
// symbols of a body's package symbols.
import lir::ir as *;
import codegen::live as lv;
import codegen::abi as ab;
import codegen::obj as ob;
import ir::core as core;
import std::float as fl;
import ast::ast as ast;

pub(package) const NOREG: u8 = 0xFF;

// Homes.
pub(package) const H_NONE: u8 = 0; // only a register
pub(package) const H_SLOT: u8 = 1; // a stack slot at the stack pointer + off
pub(package) const H_ARG: u8 = 2; // an incoming stack argument at the frame pointer + off (read-only)
pub(package) const H_FIXED: u8 = 3; // `reg` for its whole range
pub(package) const H_REMAT: u8 = 4; // a constant or an address, recomputed at each use
pub(package) const H_SPADDR: u8 = 5; // the address stack pointer + off
pub(package) const H_FPADDR: u8 = 6; // the address frame pointer + off
// An aggregate parameter's parts in the registers they arrive in, kept for the one call that reads it
// (`parts_passed`); `off` is the parameter's index.
pub(package) const H_PASSED: u8 = 7;

/// Per value: where it is.
pub(package) struct Va {
    pub(package) reg: u8, // NOREG or the register holding it
    pub(package) home: u8,
    pub(package) dirty: bool, // the register holds it and the home does not
    pub(package) clean: bool, // its register's bits above its width are zero (an i8 compare result, say)
    pub(package) off: i32,
}

extend Va as Copy {}

// A relocation of the body's code: at code position `at` (a word on arm64, a byte on x86-64; before the
// prologue), of kind `kind` against object symbol `sym` plus `addend`.
pub(package) struct CRel {
    pub(package) at: u32,
    pub(package) kind: u8,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

extend CRel as Copy {}

// A move of the parallel-move resolver: `src` to `dst` (locations), `bytes` wide in register file `v`.
pub(package) struct Mv {
    pub(package) src: Lc,
    pub(package) dst: Lc,
    pub(package) v: bool,
    pub(package) bytes: u32,
    pub(package) done: bool,
}

extend Mv as Copy {}

// A location: a register, memory at base + off, or a value to rematerialize.
pub(package) struct Lc {
    pub(package) kind: u8, // LC_REG, LC_MEM, LC_VAL
    pub(package) reg: u8, // the register, or the base register of memory
    pub(package) off: i32,
    pub(package) val: u32, // LC_VAL: the value index
}

extend Lc as Copy {}

pub(package) const LC_REG: u8 = 0;
pub(package) const LC_MEM: u8 = 1;
pub(package) const LC_VAL: u8 = 2;

/// The register file of type `t`: false for the general registers, true for the vector ones. Memory types
/// are neither (`in_mem`).
pub(package) const fn is_v(t: u8) bool {
    return is_float(t);
}

/// Whether values of type `t` live in memory.
pub(package) const fn in_mem(t: u8) bool {
    return t == T_I128 || is_vec(t);
}

/// Whether memory value type `t` may also be in a vector register: a vector of 8 or 16 bytes.
pub(package) const fn in_vreg(t: u8) bool {
    return is_vec(t) && (type_bytes(t, 8) == 8 || type_bytes(t, 8) == 16);
}

/// Whether instruction `v` of `b` (in block `bk`) is followed by a zero extension or a truncation of it
/// alone, which the block returns next (a narrow result widened for the return, a wide one cut to it):
/// either reads `v` in the return's register.
pub(package) const fn zext_returned(b: &Body, bk: Block, v: u32) bool {
    if v + 2 >= bk.start + bk.len {
        return false;
    }
    let z = b.insts[v as usize + 1];
    let r = b.insts[v as usize + 2];
    return (z.op == O_ZEXT || z.op == O_TRUNC && is_int(z.ty)) && z.a == v && r.op == O_RET && r.a == v + 1;
}

/// Whether instruction `v` of `b` (in block `bk`) is followed by a plain store of it, then a return of it
/// (a result also written through a pointer).
pub(package) const fn store_returned(b: &Body, bk: Block, v: u32) bool {
    if v + 2 >= bk.start + bk.len {
        return false;
    }
    let s = b.insts[v as usize + 1];
    let r = b.insts[v as usize + 2];
    return s.op == O_STORE && s.b == v && s.a != v && (s.aux & MEM_VOLATILE) == 0 && r.op == O_RET && r.a == v;
}

/// The location value index `x` is read from now (`va`): its register, its slot at stack pointer `sp` +
/// off, its incoming argument at frame pointer `fp` + off, else the value to rematerialize.
pub(package) const fn loc_of(va: &Vector<Va>, x: u32, sp: u8, fp: u8) Lc {
    let a = va[x as usize];
    if a.reg != NOREG {
        return Lc { kind: LC_REG, reg: a.reg, off: 0, val: x };
    }
    if a.home == H_SLOT {
        return Lc { kind: LC_MEM, reg: sp, off: a.off, val: x };
    }
    if a.home == H_ARG {
        return Lc { kind: LC_MEM, reg: fp, off: a.off, val: x };
    }
    return Lc { kind: LC_VAL, reg: 0, off: 0, val: x };
}

/// A generator the parallel-move resolver (`resolve_moves`) drives.
pub(package) interface Mover {
    /// The pending moves.
    fn moves(self: &mut Self) &mut Vector<Mv>;
    /// One move of `bytes` bytes (`v`: a float or memory value) from `src` to `dst`.
    fn do_move(self: &mut Self, src: Lc, dst: Lc, v: bool, bytes: u32);
    /// A location that breaks a cycle by holding move `m`'s source: a free register of its file, else a free
    /// stack location of 64 bytes, aligned 16.
    fn scratch(self: &mut Self, m: Mv) Lc;
}

/// The registers the pending moves of `mv` read or write, a bit each (a memory location's base too).
pub(package) const fn move_regs(mv: &Vector<Mv>) u64 {
    let mut r: u64 = 0;
    for i in 0..mv.len() {
        let m = mv[i];
        if m.done {
            continue;
        }
        if m.src.kind != LC_VAL {
            r |= 1u64 << m.src.reg as u64;
        }
        if m.dst.kind != LC_VAL {
            r |= 1u64 << m.dst.reg as u64;
        }
    }
    return r;
}

/// Perform the pending moves of `g` as one parallel move: a move waits while its destination is a pending
/// move's source; a cycle breaks through a scratch register or slot (`Mover::scratch`).
pub(package) fn resolve_moves<G: Mover>(g: &mut G) {
    let n = g.moves().len();
    let mut left = n;
    // Each round performs a move or breaks a cycle (which frees one): at most 2n rounds.
    for _ in 0..2 * n + 1 {
        if left == 0 {
            return;
        }
        let mut progress = false;
        for i in 0..n {
            if g.moves()[i].done || blocked(g.moves(), i) {
                continue;
            }
            let m = g.moves()[i];
            g.do_move(m.src, m.dst, m.v, m.bytes);
            g.moves().index_mut(i).done = true;
            left -= 1;
            progress = true;
        }
        if !progress {
            for i in 0..n {
                if !g.moves()[i].done {
                    let m = g.moves()[i];
                    let tmp = g.scratch(m);
                    g.do_move(m.src, tmp, m.v, m.bytes);
                    g.moves().index_mut(i).src = tmp;
                    break;
                }
            }
        }
    }
    assert(left == 0, "a parallel move did not finish");
}

// Whether move `i` of `mv` writes another pending move's source.
const fn blocked(mv: &Vector<Mv>, i: usize) bool {
    let d = mv[i].dst;
    for j in 0..mv.len() {
        if j == i || mv[j].done {
            continue;
        }
        let s = mv[j].src;
        // A register move's source, or a memory source's base register (an aggregate's address).
        if s.kind != LC_VAL && d.kind == LC_REG && s.reg == d.reg {
            return true;
        }
        if s.kind == LC_MEM && d.kind == LC_MEM && s.reg == d.reg {
            let a0 = d.off as i64;
            let a1 = a0 + mv[i].bytes as i64;
            let b0 = s.off as i64;
            let b1 = b0 + mv[j].bytes as i64;
            if a0 < b1 && b0 < a1 {
                return true;
            }
        }
    }
    return false;
}

/// The header parameter whose home block parameter `x` (a value index of `b`, homes `va`) may share: the
/// one its block's jump back passes it to alone, of a home of its own of the same type, when nothing in
/// the block or the jump reads that parameter; else NONE.
pub(package) fn back_share(b: &Body, lv: &lv::Live, va: &Vector<Va>, x: u32) u32 {
    let ni = b.insts.len() as u32;
    let p = x - ni;
    let j = lv.def_blk[x as usize];
    let jb = b.blocks[j as usize];
    let t = b.insts[(jb.start + jb.len - 1) as usize];
    if t.op != O_JMP {
        return NONE;
    }
    let h = b.edge_target(t.a);
    let hb = b.blocks[h as usize];
    if lv.pos[h as usize] == NONE || lv.pos[h as usize] > lv.pos[j as usize] {
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
    if px == NONE || va[px as usize].home != H_FIXED && va[px as usize].home != H_SLOT || lv::xty(b, px) != lv::xty(
        b,
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

/// Whether `b` has a call, copy or fill right before a return: the only place a sibling call may be (the
/// generators' `sib_shape`, `mem_tail_shape`), which `tail_ok`'s frame test (`lir::verify::frame_escapes`)
/// serves.
pub(package) const fn tail_candidate(b: &Body) bool {
    for i in 1..b.insts.len() {
        let op = b.insts[i - 1].op;
        if (op == O_CALL || op == O_CALLIND || op == O_MEMCPY || op == O_MEMSET) && b.insts[i].op == O_RET {
            return true;
        }
    }
    return false;
}

/// The block parameter whose stack slot instruction `x` of `b` (homes `va`), spilled without a home, may
/// take as its own (`lv::Live::slot_partner`): a parameter `x` reads, in a slot of its own, of `x`'s type,
/// a value in a register. NONE else.
pub(package) fn step_slot(b: &Body, lv: &lv::Live, va: &Vector<Va>, x: u32) u32 {
    let ni = b.insts.len() as u32;
    if x >= ni {
        return NONE;
    }
    let us = lv.uses_of(x);
    for k in 0..us.len() {
        let v = us[k];
        if (v & (VPARAM | VFLAG)) != VPARAM || v == VNONE {
            continue;
        }
        let px = ni + (v & ~VPARAM);
        let ty = lv::xty(b, px);
        if va[px as usize].home != H_SLOT || lv.cut[px as usize] != NONE || ty != lv::xty(b, x) || in_mem(ty) {
            continue;
        }
        if lv.slot_partner(b, x, px) {
            return px;
        }
    }
    return NONE;
}

/// A line row at code position `at` for location `loc` (a `lines` index) into `rows` when it differs from
/// the last: code position << 32 | location.
pub(package) fn row(rows: &mut Vector<u64>, at: u64, loc: u32) {
    let n = rows.len();
    if loc == 0 || n != 0 && (rows[n - 1] & 0xFFFFFFFF) as u32 == loc {
        return;
    }
    if n != 0 && rows[n - 1] >> 32 == at {
        rows[n - 1] = at << 32 | loc as u64;
        return;
    }
    rows.push(at << 32 | loc as u64);
}

/// A generator's object symbols (`osym_of`): per package symbol, its object symbol in the generator's
/// object (NONE until used), and the package symbols set. An object sets a few hundred of the entries, so
/// one table serves the objects a worker compiles in turn (`clear`).
pub(package) struct Osyms {
    pub(package) at: Vector<u32>,
    pub(package) set: Vector<u32>,
}

extend Osyms {
    pub(package) fn new() Osyms {
        return Osyms { at: Vector::<u32>::new(), set: Vector::<u32>::new() };
    }

    /// The table of a new object: every entry NONE.
    pub(package) fn clear(self: &mut Self) {
        for i in 0..self.set.len() {
            self.at[self.set[i] as usize] = NONE;
        }
        self.set.truncate(0);
    }
}

/// The object symbol of body symbol `s` of `b` (package `p`) in object `o`, through the per package
/// symbol cache `osym`.
pub(package) fn osym_of(p: &Package, b: &Body, o: &mut ob::Obj, osym: &mut Osyms, s: u32) u32 {
    if osym.at.len() == 0 {
        fill(&mut osym.at, p.syms.len(), NONE);
    }
    let g = b.syms[s as usize] as usize;
    if osym.at[g] == NONE {
        let ps = p.syms[g];
        let nm0 = p.spell(ps.name);
        // `__sc_x_<name>` is a C library name's alias (a macro of a scoped extern header).
        let nm = if ps.def == NONE && nm0.starts_with("__sc_x_") {
            nm0.slice(7, nm0.len())
        } else {
            nm0
        };
        osym.at[g] = o.sym(nm);
        osym.set.push(g as u32);
    }
    return osym.at[g];
}

/// A generator whose call arguments the stores before a call may relay (`arg_relays`).
pub(package) interface Relays {
    /// The body compiling.
    fn body(self: &Self) &'static Body;
    /// Its liveness facts.
    fn live(self: &mut Self) &mut lv::Live;
    /// The argument and result locations of call `t` (`layout`), false for an intrinsic's call.
    fn lay_call(self: &mut Self, t: Inst) bool;
    /// The locations `lay_call` gave.
    fn layout(self: &Self) &ab::CallLayout;
    /// The pointer size in bytes.
    fn ptr(self: &Self) u32;
    /// The location value index `x` is read from now (`loc_of`).
    fn source(self: &Self, x: u32) Lc;
    /// The number of the first vector register.
    fn vreg0(self: &Self) u8;
}

/// `lv.relay`: the stores whose value a call takes in place of a register-passed aggregate argument's
/// memory. The argument is a slot's address; the stores into the slot before the call in its block (back
/// to another use of the slot's addresses) each write a whole part (its offset, size and register file),
/// and every part has one. When every use of the slot's addresses is such a store or such an argument,
/// no other access reads the bytes: the stores write nothing, and each call moves the last store's value
/// of each part into the part's register.
pub(package) fn arg_relays<G: Relays>(g: &mut G) {
    let b = g.body();
    let ni = b.insts.len();
    g.live().relay.truncate(0);
    g.live().relayed.truncate(0);
    g.live().relay_lo.truncate(0);
    let mut us = Vector::<Value>::new();
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
            if t.op != O_CALL && t.op != O_CALLIND || !slot_agg_arg(b, t) || !g.lay_call(t) {
                continue;
            }
            let np = b.pool[t.b as usize];
            for q in 0..np {
                let v = b.pool[(t.c + q) as usize];
                let loc = g.layout().locs[q as usize];
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
                        if lv::reads_slot(b, u, s, &mut us) {
                            break;
                        }
                        continue;
                    }
                    let pq = arg_part(b, g.layout(), g.ptr(), loc, u);
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
                let gr = groups.len() as u64;
                groups.push(s as u64 << 32 | c as u64);
                // The argument, and each store once.
                covered[s as usize] += 1;
                for z in 0..stores.len() {
                    gst.push(gr << 32 | stores[z] as u64);
                    covered[s as usize] += ((stores[z] & 0x80000000) != 0) as u32;
                }
            }
        }
    }
    if groups.len() == 0 {
        return;
    }
    // Each slot's address uses: operands, call arguments and edge arguments.
    let mut uses = Vector::<u32>::new();
    uses.resize_default(b.slots.len());
    for i in 0..ni {
        lv::each_use(b, b.insts[i], &mut us);
        for q in 0..us.len() {
            let v = us[q];
            if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR {
                uses[b.insts[v as usize].a as usize] += 1;
            }
        }
    }
    // A slot whose every address use its groups account for: their stores relay.
    let l = g.live();
    for z in 0..gst.len() {
        let gr = groups[(gst[z] >> 32) as usize];
        let s = (gr >> 32) as usize;
        if covered[s] != uses[s] {
            continue;
        }
        if l.relay.len() == 0 {
            fill(&mut l.relay, ni, NONE);
        }
        let c = gr as u32;
        let st = gst[z] as u32 & 0x7FFFFFFF;
        if (gst[z] & 0x80000000) != 0 {
            l.relay[st as usize] = c;
        } else {
            l.relayed.push(c as u64 << 32 | st as u64);
        }
    }
    if l.relayed.len() == 0 {
        return;
    }
    fill(&mut l.relay_lo, ni, NONE);
    for q in 0..l.relayed.len() {
        let c = (l.relayed[q] >> 32) as usize;
        if l.relay_lo[c] == NONE {
            l.relay_lo[c] = q as u32;
        } else {
            assert((l.relayed[q - 1] >> 32) as usize == c, "arg_relays: a call's relayed stores are adjacent");
        }
    }
}

// Whether call `t` of `b` passes an aggregate as a slot's address (`arg_relays`' arguments, before their
// layout).
const fn slot_agg_arg(b: &Body, t: Inst) bool {
    for q in 0..b.pool[t.b as usize] {
        let v = b.pool[(t.c + q) as usize];
        if (b.pool[(t.b + 3 + q) as usize] & AGG) != 0 && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR {
            return true;
        }
    }
    return false;
}

/// Aggregate argument `v` (`loc`) of call `i` taken from its relayed stores' values (`arg_relays`): into
/// the parallel move (`Mover::moves`) for those in a register or a home, else into `vals` (part register
/// << 32 | value) for after it; whether it is.
pub(package) fn relay_parts<G: Relays + Mover>(g: &mut G, i: u32, v: Value, loc: ab::ALoc, vals: &mut Vector<u64>) bool {
    let b = g.body();
    if g.live().relay.len() == 0 || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SLOTADDR {
        return false;
    }
    let s = b.insts[v as usize].a;
    let mut any = false;
    let (lo, hi) = g.live().relayed_of(i);
    for q in lo..hi {
        let rq = g.live().relayed[q as usize];
        let st = b.insts[(rq & 0xFFFFFFFF) as usize];
        if b.insts[st.a as usize].a != s {
            continue;
        }
        any = true;
        let pa = g.layout().parts[(loc.p0 + arg_part(b, g.layout(), g.ptr(), loc, st)) as usize];
        let r = pa.reg + if pa.v {
            g.vreg0()
        } else {
            0
        };
        let x = g.live().vix(b, st.b);
        let src = g.source(x);
        if src.kind == LC_VAL {
            vals.push(r as u64 << 32 | st.b as u64);
            continue;
        }
        g.moves().push(
            Mv { src: src, dst: Lc { kind: LC_REG, reg: r, off: 0, val: NONE }, v: pa.v, bytes: pa.size, done: false },
        );
    }
    return any;
}

/// `parts_taken`'s mark of a 16-byte vector load of two 8-byte vector register parts, the first's number below.
pub(package) const SPAN: u32 = 0x80000000;

/// The 16-byte vector access `t` (pointers `ptr` bytes) spans, whole, vector register parts `q` and `q + 1` of
/// 8 bytes each of location `loc` of call layout `lay` (System V's two eightbytes of floats): `q | SPAN`, else
/// NONE.
pub(package) const fn span_part(lay: &ab::CallLayout, ptr: u32, loc: ab::ALoc, ty: u8, off: u32) u32 {
    if !is_vec(ty) || type_bytes(ty, ptr) != 16 {
        return NONE;
    }
    for q in 0..(loc.n as u32).max(1) - 1 {
        let p0 = lay.parts[(loc.p0 + q) as usize];
        let p1 = lay.parts[(loc.p0 + q + 1) as usize];
        if p0.v && p1.v && p0.size == 8 && p1.size == 8 && p0.off == off && p1.off == off + 8 {
            return q | SPAN;
        }
    }
    return NONE;
}

/// Whether every use of parameter value index `x` of `b` (an aggregate the body takes in registers, `loc`
/// of its own layout `lay`, pointers `ptr` bytes) is a load in the entry block, before any instruction
/// that `clobbers` registers, of one whole part of 4 bytes or more, or a 16-byte vector of two 8-byte vector
/// parts (`span_part`), no two of the same part: then each load takes its part's register, appended to
/// `taken` (part << 32 | load); else `taken` stays as it was. `uses` is scratch.
pub(package) fn parts_taken(
    b: &Body,
    lv: &lv::Live,
    lay: &ab::CallLayout,
    ptr: u32,
    clobbers: fn(&Body, Inst) bool,
    x: u32,
    loc: ab::ALoc,
    taken: &mut Vector<u64>,
    uses: &mut Vector<Value>,
) bool {
    let e = b.blocks[0];
    let v = VPARAM | x - b.insts.len() as u32;
    let mut n: u32 = 0;
    let mark = taken.len();
    for i in e.start..e.start + e.len {
        let t = b.insts[i as usize];
        lv.uses_at(b, i, uses);
        let mut reads: u32 = 0;
        for q in 0..uses.len() {
            reads += (uses[q] == v) as u32;
        }
        if reads == 0 {
            // A call before a load would take its register.
            if clobbers(b, t) {
                break;
            }
            continue;
        }
        if t.op != O_LOAD || reads != 1 || (t.aux & MEM_VOLATILE) != 0 || lv.fold[i as usize] || t.ty == T_I128 {
            taken.truncate(mark);
            return false;
        }
        let mut part = span_part(lay, ptr, loc, t.ty, t.c);
        for q in 0..loc.n as u32 {
            let pa = lay.parts[(loc.p0 + q) as usize];
            if pa.off == t.c && pa.size as u32 == type_bytes(t.ty, ptr) && pa.v == is_v(t.ty) && type_bytes(t.ty, ptr) >= 4 && !is_vec(
                t.ty,
            ) {
                part = q;
            }
        }
        // The parts a load takes: one, or two for a span.
        let lo = part & ~SPAN;
        let hi = lo + ((part & SPAN) != 0) as u32;
        for q in mark..taken.len() {
            let o = (taken[q] >> 32) as u32;
            let olo = o & ~SPAN;
            let ohi = olo + ((o & SPAN) != 0) as u32;
            if part != NONE && olo <= hi && lo <= ohi {
                part = NONE;
            }
        }
        if part == NONE {
            taken.truncate(mark);
            return false;
        }
        taken.push(part as u64 << 32 | i as u64);
        n += 1;
    }
    if n != lv.uses[x as usize] {
        taken.truncate(mark);
        return false;
    }
    return true;
}

/// The call of `b`'s entry block whose one argument is the only use of parameter value index `x` (an
/// aggregate the body takes in registers), when no instruction before it `clobbers` registers: that
/// call's instruction, whose registers may take the aggregate's parts from the registers they arrive in;
/// NONE else. `uses` is scratch.
pub(package) fn parts_passed(b: &Body, lv: &lv::Live, clobbers: fn(&Body, Inst) bool, x: u32, uses: &mut Vector<Value>) u32 {
    if lv.uses[x as usize] != 1 {
        return NONE;
    }
    let e = b.blocks[0];
    let v = VPARAM | x - b.insts.len() as u32;
    for i in e.start..e.start + e.len {
        let t = b.insts[i as usize];
        lv.uses_at(b, i, uses);
        let mut reads = false;
        for q in 0..uses.len() {
            reads = reads || uses[q] == v;
        }
        if reads {
            if t.op != O_CALL && t.op != O_CALLIND || lv.fold[i as usize] {
                return NONE;
            }
            let mut arg = false;
            for k in 0..b.pool[t.b as usize] {
                arg = arg || b.pool[(t.c + k) as usize] == v;
            }
            return ast::pick(arg, i, NONE);
        }
        if clobbers(b, t) {
            return NONE;
        }
    }
    return NONE;
}

/// Per entry parameter of `b` (signature layout `lay`), whether it is an aggregate that arrives in
/// registers, whose memory the frame holds, into `out`.
pub(package) fn held_params(b: &Body, lay: &ab::CallLayout, out: &mut Vector<bool>) {
    out.truncate(0);
    for k in 0..b.pool[b.sig as usize] {
        out.push((b.pool[(b.sig + 3 + k) as usize] & AGG) != 0 && lay.locs[k as usize].kind == ab::L_REG);
    }
}

/// Whether address `v` of `b` may point into the frame: a slot's address or that of an entry parameter
/// `held` marks (an aggregate whose memory the frame holds), through `ptradd` bases and `select`s, followed
/// FRAME_DEPTH steps; a block parameter or an integer made a pointer may, being followed no further.
pub(package) fn frame_based(b: &Body, held: &Vector<bool>, v: Value, depth: u32) bool {
    if v == VNONE || (v & VFLAG) != 0 {
        return false;
    }
    if depth == 0 {
        return true;
    }
    if (v & VPARAM) != 0 {
        let p = v & ~VPARAM;
        let e = b.blocks[0];
        if p < e.param_start || p >= e.param_start + e.param_len as u32 {
            return true;
        }
        let k = (p - e.param_start) as usize;
        return k < held.len() && held[k];
    }
    let t = b.insts[v as usize];
    if t.op == O_SLOTADDR || t.op == O_INTTOPTR {
        return true;
    }
    if t.op == O_PTRADD {
        return frame_based(b, held, t.a, depth - 1);
    }
    if t.op == O_SELECT {
        return frame_based(b, held, t.b, depth - 1) || frame_based(b, held, t.c, depth - 1);
    }
    return false;
}

/// `frame_based` follows at most FRAME_DEPTH steps.
pub(package) const FRAME_DEPTH: u32 = 8;

/// Per slot of `b`, the uses of its addresses (`lv.uses`, before the code generator consumes any), into
/// `out`.
pub(package) fn slot_uses(b: &Body, lv: &lv::Live, out: &mut Vector<u32>) {
    out.truncate(0);
    out.resize_default(b.slots.len());
    for k in 0..b.insts.len() {
        let t = b.insts[k];
        if t.op == O_SLOTADDR {
            out[t.a as usize] += lv.uses[k];
        }
    }
}

/// The count of the loads right after call `i` of `b` whose values its aggregate result's register parts
/// (`lay`'s result, pointers `ptr` bytes) give: each reads one whole part (`result_part`) at the
/// result's address, a slot's whose addresses nothing uses but the call and those loads (`suse`, from
/// `slot_uses`), and none folds into its user (`lv.pfold`: a memory operand reads the slot); then the
/// call stores nothing. 0 when not.
pub(package) const fn result_loads(b: &Body, lv: &lv::Live, lay: &ab::CallLayout, ptr: u32, suse: &Vector<u32>, i: u32) u32 {
    let t = b.insts[i as usize];
    let rl = lay.ret;
    let rv = b.pool[(t.c + b.pool[t.b as usize]) as usize];
    if rl.kind != ab::L_REG || (rv & (VPARAM | VFLAG)) != 0 || b.insts[rv as usize].op != O_SLOTADDR {
        return 0;
    }
    let mut n: u32 = 0;
    while n < rl.n as u32 && i + 1 + n < b.insts.len() as u32 {
        let u = b.insts[(i + 1 + n) as usize];
        if u.op != O_LOAD || u.a != rv || (u.aux & MEM_VOLATILE) != 0 || result_part(lay, ptr, u) == NONE {
            break;
        }
        if lv.pfold[(i + 1 + n) as usize] {
            return 0;
        }
        n += 1;
    }
    return ast::pick(suse[b.insts[rv as usize].a as usize] == n + 1, n, 0);
}

/// The part (0 ..) of call layout `lay`'s register result that load `u` reads whole (pointers `ptr`
/// bytes), else NONE.
pub(package) const fn result_part(lay: &ab::CallLayout, ptr: u32, u: Inst) u32 {
    let rl = lay.ret;
    for q in 0..rl.n as u32 {
        let pa = lay.parts[(rl.p0 + q) as usize];
        if pa.off == u.c && pa.size as u32 == type_bytes(u.ty, ptr) && pa.v == is_v(u.ty) && !is_vec(u.ty) {
            return q;
        }
    }
    return NONE;
}

/// The part (0 ..) of register-passed argument `loc` (of call layout `lay`, pointers `ptr` bytes) that
/// store `u` of `b` writes whole, else NONE.
pub(package) const fn arg_part(b: &Body, lay: &ab::CallLayout, ptr: u32, loc: ab::ALoc, u: Inst) u32 {
    if (u.aux & MEM_VOLATILE) != 0 || (u.b & VFLAG) != 0 {
        return NONE;
    }
    let ty = b.type_of(u.b);
    for q in 0..loc.n as u32 {
        let pa = lay.parts[(loc.p0 + q) as usize];
        if pa.off == u.c && pa.size as u32 == type_bytes(ty, ptr) && pa.v == is_v(ty) && !in_mem(ty) {
            return q;
        }
    }
    return NONE;
}

/// The register and slot state both register code generators keep per body, and the methods they share
/// over it.
pub(package) struct Core {
    pub(package) err: String, // the first refusal, empty when every body compiled
    pub(package) o: *mut ob::Obj,
    pub(package) ptr: u32,
    // ---- per body ----
    pub(package) bp: *const Body,
    pub(package) lv: lv::Live,
    pub(package) va: Vector<Va>,
    pub(package) owner: Vector<u32>, // per register number, the value index it holds, NONE
    /// Per register number, the parameter of a block after a loop that shares it with the loop's parameter
    /// (`lv::Live::share`): it holds the register on when the value that holds it now (the loop's
    /// parameter, or the step `def_step` defines in its register) is released. NONE else.
    pub(package) heir: Vector<u32>,
    pub(package) held: u64, // a bit per register whose `owner` is a value
    pub(package) lock: u64, // registers the current instruction reads or writes
    pub(package) tmps: u64, // registers the current instruction took as temporaries
    pub(package) fixed_busy: u64,
    pub(package) rstore: Vector<u32>, // per instruction, 1 + the result part a store moves into its register (`ret_stores`), else 0
    pub(package) pos: u32, // the layout position of the block being compiled
    pub(package) shared: Vector<u32>, // the values that share another's slot, which that one frees (`back_share`, `step_slot`)
    pub(package) dying: Vector<u32>, // values whose register frees after the current instruction
    pub(package) pheld: Vector<bool>, // per entry parameter, an aggregate whose memory the frame holds (`frame_escapes`)
    pub(package) ends: Vector<u32>, // values by the position their range ends at (CSR, `ends_at`)
    pub(package) ends_at: Vector<u32>,
    pub(package) spill_base: u32,
    pub(package) spill_top: u32,
    pub(package) free_slots: Vector<u64>, // size << 32 | offset of a released spill slot
    pub(package) tail_ok: bool,
    // Calls.
    pub(package) lay: ab::CallLayout,
    pub(package) self_lay: ab::CallLayout,
    pub(package) uses: Vector<Value>,
}

extend Core {
    /// The state of a generator for package `pkg` writing `o`, with `nregs` register numbers.
    pub(package) fn new(pkg: &Package, o: &mut ob::Obj, nregs: u32) Core {
        let mut owner = Vector::<u32>::with_capacity(nregs as usize);
        for _ in 0..nregs {
            owner.push(NONE);
        }
        return Core {
            err: String::new(),
            o: o,
            ptr: pkg.ptr_bytes,
            bp: null,
            lv: lv::Live::new(),
            va: Vector::<Va>::new(),
            owner: owner,
            heir: Vector::<u32>::new(),
            held: 0,
            lock: 0,
            tmps: 0,
            fixed_busy: 0,
            rstore: Vector::<u32>::new(),
            pos: 0,
            shared: Vector::<u32>::new(),
            dying: Vector::<u32>::new(),
            pheld: Vector::<bool>::new(),
            ends: Vector::<u32>::new(),
            ends_at: Vector::<u32>::new(),
            spill_base: 0,
            spill_top: 0,
            free_slots: Vector::<u64>::new(),
            tail_ok: false,
            lay: ab::CallLayout::new(),
            self_lay: ab::CallLayout::new(),
            uses: Vector::<Value>::new(),
        };
    }

    // The home register of the parameter jump `t` passes `v` to (once), when the jump is no back edge, so
    // nothing reads that parameter's earlier value here (`def_step` takes the back edges): `v` defined
    // there needs no move. NOREG else.
    pub(package) const fn jump_reg(self: &Self, b: &Body, t: Inst, v: Value) u8 {
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
        return ast::pick(r == NOREG || ((self.lock | self.tmps) & bit(r)) != 0, NOREG, r);
    }

    // Free value index `x`'s register and slot.
    pub(package) fn release(self: &mut Self, x: u32) {
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

    // `same_moves` one way: each move of edge `e` is one of edge `o`'s.
    pub(package) const fn moves_within(self: &Self, e: u32, o: u32) bool {
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

    // A stack slot of `size` bytes aligned to `al` (memory values and spills); its sp offset.
    pub(package) const fn slot_alloc(self: &mut Self, size0: u32, al0: u32) u32 {
        let size = ast::pick(size0 < 8, 8u32, size0);
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

    // Whether call `t` (its layout in `lay`) reads vector `u` only as arguments it passes whole in one
    // register (`whole_vreg`), not in memory.
    pub(package) const fn whole_arg(self: &Self, t: Inst, u: Value) bool {
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

    // `ends`: the values grouped by the position their range ends at.
    pub(package) fn bucket_ends(self: &mut Self) {
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

    // Whether copy or fill `t`, instruction `i`, calls its C routine (no constant size it does inline) right
    // before the body returns nothing: a sibling call where `mem_tail` holds, which `shrinkable` reads before
    // `tail_ok` is known (when it fails, the warm code calls, and the body is compiled again unshrunk).
    pub(package) const fn mem_tail_shape(self: &Self, i: u32, t: Inst) bool {
        let b = self.b();
        if t.op != O_MEMCPY && t.op != O_MEMSET || b.pool[b.sig as usize + 2] != T_NONE as u32 {
            return false;
        }
        let mut n: u64 = 0;
        let lim: u64 = ast::pick(t.op == O_MEMCPY && t.aux == MEM_OVERLAP, 64, 128);
        if self.const_of(t.c, &mut n) && n <= lim {
            return false;
        }
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        let r = b.insts[i as usize + 1];
        return i + 2 == bk.start + bk.len && r.op == O_RET && r.a == VNONE;
    }

    // Whether call `t`, instruction `i`, is right before the return of its result (or of nothing, for a call
    // of no result), not into memory: a sibling call's shape, which `shrinkable` reads before `tail_ok` is
    // known (when the call is no sibling call, the warm code calls, and the body is compiled again unshrunk).
    pub(package) const fn call_tail_shape(self: &Self, i: u32, t: Inst) bool {
        let b = self.b();
        if t.op != O_CALL && t.op != O_CALLIND {
            return false;
        }
        let bk = b.blocks[self.lv.def_blk[i as usize] as usize];
        if i + 2 != bk.start + bk.len {
            return false;
        }
        let r = b.insts[i as usize + 1];
        return r.op == O_RET && (r.a == i && t.ty != T_NONE || r.a == VNONE && t.ty == T_NONE) && (b.pool[t.b as usize + 2] & AGG) == 0;
    }

    // The register home of edge argument `v` when `v` dies at this terminator, NOREG else.
    pub(package) const fn home_dying(self: &Self, v: Value) u8 {
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
        return ast::pick(
            va.home == H_FIXED && va.reg != NOREG && self.owner[va.reg as usize] == x && (self.heir[va.reg as usize] == NONE || self.heir[va.reg as usize] == x) && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos,
            va.reg,
            NOREG,
        );
    }

    // Whether every return of the body takes the result from a run of part stores (`rstore`): then nothing
    // reads the result's memory, which needs no slot.
    pub(package) const fn ret_moved(self: &Self) bool {
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

    // The register of edge argument `v` when it holds `v` without being its home and `v` dies at this
    // terminator: the parameter that takes it may keep it, and the edge then moves nothing. NOREG else.
    pub(package) const fn dying_reg(self: &Self, v: Value) u8 {
        if v == VNONE {
            return NOREG;
        }
        let x = self.vx(v);
        if x == NONE {
            return NOREG;
        }
        let va = self.va[x as usize];
        return ast::pick(
            va.reg != NOREG && va.home != H_FIXED && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos,
            va.reg,
            NOREG,
        );
    }

    // Whether an argument of edge `e` is not in its parameter's home yet (the homes chosen).
    pub(package) const fn moves_needed(self: &Self, e: u32) bool {
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

    // The return register when block parameter value index `x` is an integer whose one use returns it from
    // its block: there it needs no move. NOREG else.
    pub(package) const fn ret_reg(self: &Self, b: &Body, x: u32) u8 {
        let d = self.lv.def_blk[x as usize];
        let bk = b.blocks[d as usize];
        let t = b.insts[(bk.start + bk.len - 1) as usize];
        let rl = self.self_lay.ret;
        if self.lv.uses[x as usize] != 1 || t.op != O_RET || t.a != (VPARAM | x - b.insts.len() as u32) || rl.kind != ab::L_REG || rl.n != 1 || self.self_lay.parts[rl.p0 as usize].v {
            return NOREG;
        }
        return self.self_lay.parts[rl.p0 as usize].reg;
    }

    // Edge argument `v`, when register `r` is its home and it dies at this terminator, gives `r` up: the
    // parameter that takes `r` then holds it, and the edge moves nothing.
    pub(package) const fn free_home(self: &mut Self, v: Value, r: u8) {
        let x = self.vx(v);
        if x == NONE {
            return;
        }
        let va = self.va[x as usize];
        if va.home == H_FIXED && va.reg == r && self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            self.fixed_busy &= ~bit(r);
        }
    }

    // Whether the instruction after `i` is a branch or a select on value `v`.
    pub(package) const fn next_reads(self: &Self, i: u32, v: Value) bool {
        let b = self.b();
        let k = self.lv.def_blk[i as usize];
        let bk = b.blocks[k as usize];
        if i + 1 >= bk.start + bk.len {
            return false;
        }
        let n = b.insts[i as usize + 1];
        return (n.op == O_BR || n.op == O_SELECT) && n.a == v;
    }

    // Whether every late edge's target lies before layout position `q` (`lv::Live::late`).
    pub(package) const fn late_ready(self: &Self, q: u32) bool {
        let b = self.b();
        for j in 0..self.lv.late.len() {
            if self.lv.pos[b.edge_target(self.lv.late[j] as u32) as usize] >= q {
                return false;
            }
        }
        return true;
    }

    // Whether copy or fill `t`, instruction `i`, calls its C routine as a sibling call (`tail_ok`): of that
    // shape (`mem_tail_shape`), neither address may point into this frame (`frame_based`). Its return
    // is not emitted (`tail_ret`).
    pub(package) fn mem_tail(self: &Self, i: u32, t: Inst) bool {
        let b = self.b();
        return self.tail_ok && self.mem_tail_shape(i, t) && !frame_based(b, &self.pheld, t.a, FRAME_DEPTH) && (t.op == O_MEMSET || !frame_based(
            b,
            &self.pheld,
            t.b,
            FRAME_DEPTH,
        ));
    }

    // Register `r` holds value `x` from now on (NONE: no value).
    pub(package) const fn set_owner(self: &mut Self, r: u8, x: u32) {
        self.owner[r as usize] = x;
        if x == NONE {
            self.held &= ~bit(r);
        } else {
            self.held |= bit(r);
        }
    }

    // Bind register `r` to value index `x` as its newest copy.
    pub(package) fn bind(self: &mut Self, x: u32, r: u8) {
        self.set_owner(r, x);
        self.lock |= bit(r);
        let va = self.va.index_mut(x as usize);
        va.reg = r;
        va.dirty = va.home != H_FIXED;
        va.clean = false;
    }

    // Whether value index `x` shares another value's slot, which that one frees (`back_share`,
    // `step_slot`).
    pub(package) const fn is_shared(self: &Self, x: u32) bool {
        for k in 0..self.shared.len() {
            if self.shared[k] == x {
                return true;
            }
        }
        return false;
    }

    // Whether value index `x` has its last use in the current instruction.
    pub(package) const fn dies(self: &Self, x: u32) bool {
        for k in 0..self.dying.len() {
            if self.dying[k] == x {
                return true;
            }
        }
        return false;
    }

    // Whether the current instruction reads value `x`.
    pub(package) const fn read_now(self: &Self, x: u32) bool {
        for k in 0..self.uses.len() {
            if self.vx(self.uses[k]) == x {
                return true;
            }
        }
        return false;
    }

    // The value whose low bits value `v` is: the source of a folded truncation (`lv::FOLD_TRUNC`), else `v`.
    pub(package) const fn narrow_src(self: &Self, v: Value) Value {
        return if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize] && self.b().insts[v as usize].op == O_TRUNC {
            self.b().insts[v as usize].a
        } else {
            v
        };
    }

    // One use of value index `x` done: it frees after the current instruction when that was its last.
    pub(package) fn use_once(self: &mut Self, x: u32) {
        self.lv.uses[x as usize] -= 1;
        if self.lv.uses[x as usize] == 0 && self.lv.end[x as usize] == self.pos {
            self.dying.push(x);
        }
    }

    // The memory value instruction `i` defines: a slot; its sp offset.
    pub(package) fn mdef(self: &mut Self, i: u32) i64 {
        let x = self.vx(i);
        let t = self.xty(x);
        let off = self.slot_alloc(type_bytes(t, self.ptr), 16);
        self.va.index_mut(x as usize).home = H_SLOT;
        self.va.index_mut(x as usize).off = off as i32;
        return off;
    }

    pub(package) fn refuse(self: &mut Self, why: str) bool {
        if self.err.len() == 0 {
            self.err.push_str(why);
        }
        return false;
    }

    // The type of value index `x`.
    pub(package) const fn xty(self: &Self, x: u32) u8 {
        return lv::xty(self.b(), x);
    }

    // The body being compiled and the object: both outlive the generator's borrows.
    pub(package) const fn b(self: &Self) &'static Body {
        return bref(self.bp);
    }

    pub(package) const fn obj(self: &Self) &'static mut ob::Obj {
        return oref(self.o);
    }

    // Whether `v` is an integer constant; its bits in `out`.
    pub(package) const fn const_of(self: &Self, v: Value, out: &mut u64) bool {
        return lv::const_of(self.b(), v, out);
    }

    // Whether value `x` is used after the current instruction.
    pub(package) const fn live_on(self: &Self, x: u32) bool {
        return self.lv.uses[x as usize] != 0 || self.lv.end[x as usize] > self.pos;
    }

    // The type of value `v`.
    pub(package) const fn vt(self: &Self, v: Value) u8 {
        return self.b().type_of(v);
    }

    // The value index of `v`.
    pub(package) const fn vx(self: &Self, v: Value) u32 {
        return self.lv.vix(self.b(), v);
    }

    pub(package) fn data(self: &mut Self, p: &Package, s: u32, local: bool, coff: bool, abs64: u8) bool {
        let ps = p.syms[s as usize];
        let d = p.data[ps.def as usize];
        let tls = ps.kind == SK_TLS;
        let mut zero = d.nrelocs == 0;
        for j in 0..d.nbytes {
            zero = zero && p.bytes[(d.bytes + j) as usize] == 0;
        }
        // COFF has no zero-filled thread-local section: `.tls$` holds every byte.
        zero = zero && !(tls && coff);
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
            o.reloc(sec, abs64, (at + r.offset as u64) as u32, ks, r.addend);
        }
        return true;
    }
}

/// The mask of register `r`.
pub(package) const fn bit(r: u8) u64 {
    return 1u64 << r as u64;
}

const fn bref(p: *const Body) &'static Body {
    return unsafe &*p;
}

const fn oref(p: *mut ob::Obj) &'static mut ob::Obj {
    return unsafe &mut *p;
}

/// The LIR condition of SIMD comparison `c` (`SIMD_CMP_EQ` .. `SIMD_CMP_GE`): of floats, else signed or not.
pub(package) const fn simd_cond(c: u8, sg: bool, fl: bool) u16 {
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

/// The chunk of a copy with `left` bytes to go: the largest power of two up to both `left` and `max` (a
/// power of two), at least 1.
pub(package) const fn chunk(left: u32, max: u32) u32 {
    let mut s = max;
    // Each step halves `s`.
    while s > left && s > 1 {
        s /= 2;
    }
    return s;
}

/// The bits of integer `k` converted to a float of lane type `lt` (`T_F32` or `T_F64`).
pub(package) const fn float_bits(lt: u8, k: u32) u64 {
    if lt == T_F32 {
        return fl::f32_bits(k as f32);
    }
    return fl::f64_bits(k as f64);
}

/// The text section of function symbol `ps` of `p`: its own section, `cold` for a cold function, else
/// `S_TEXT`.
pub(package) fn text_section(o: &mut ob::Obj, p: &Package, ps: Sym, cold: str) u8 {
    if ps.sect != NONE {
        return o.named(p.spell(ps.sect), true);
    }
    if ps.cold {
        return o.named(cold, true);
    }
    return ob::S_TEXT;
}

/// The object flags of function symbol `ps`: global when its linkage is and `global`, used when it is
/// `@used` and `used`.
pub(package) const fn func_flags(ps: Sym, global: bool, used: bool) u8 {
    return ob::SF_FUNC | ast::pick(ps.linkage == SL_GLOBAL && global, ob::SF_GLOBAL, 0) | ast::pick(
        ps.used && used,
        ob::SF_USED,
        0,
    );
}
