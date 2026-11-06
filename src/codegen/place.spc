// Where a native generator keeps each value and how it moves values between those places: the homes, the
// locations and the parallel-move resolver the arm64 and x86-64 generators (`target::a64gen`,
// `target::x64gen`) share, the aggregate arguments a call takes from the stores before it, and the object
// symbols of a body's package symbols.
import lir::ir as *;
import codegen::live as lv;
import codegen::abi as ab;
import codegen::obj as ob;

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
pub(package) fn move_regs(mv: &Vector<Mv>) u64 {
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

/// The object symbol of body symbol `s` of `b` (package `p`) in object `o`, through the per package
/// symbol cache `osym` (NONE until used).
pub(package) fn osym_of(p: &Package, b: &Body, o: &mut ob::Obj, osym: &mut Vector<u32>, s: u32) u32 {
    if osym.len() == 0 {
        fill(osym, p.syms.len(), NONE);
    }
    let g = b.syms[s as usize] as usize;
    if osym[g] == NONE {
        let ps = p.syms[g];
        let nm0 = p.spell(ps.name);
        // `__sc_x_<name>` is a C library name's alias (a macro of a scoped extern header).
        let nm = if ps.def == NONE && nm0.starts_with("__sc_x_") {
            nm0.slice(7, nm0.len())
        } else {
            nm0
        };
        osym[g] = o.sym(nm);
    }
    return osym[g];
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
    // Each slot's address uses: operands, call arguments and edge arguments.
    let mut uses = Vector::<u32>::new();
    uses.resize_default(b.slots.len());
    let mut calls = false;
    let mut us = Vector::<Value>::new();
    for i in 0..ni {
        let t = b.insts[i];
        calls = calls || t.op == O_CALL || t.op == O_CALLIND;
        lv::each_use(b, t, &mut us);
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
            if t.op != O_CALL && t.op != O_CALLIND || !g.lay_call(t) {
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
    for q in 0..g.live().relayed.len() {
        let rq = g.live().relayed[q];
        if (rq >> 32) as u32 != i {
            continue;
        }
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
pub(package) fn span_part(lay: &ab::CallLayout, ptr: u32, loc: ab::ALoc, ty: u8, off: u32) u32 {
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
            return if arg {
                i
            } else {
                NONE
            };
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
pub(package) fn result_loads(b: &Body, lv: &lv::Live, lay: &ab::CallLayout, ptr: u32, suse: &Vector<u32>, i: u32) u32 {
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
    return if suse[b.insts[rv as usize].a as usize] == n + 1 {
        n
    } else {
        0
    };
}

/// The part (0 ..) of call layout `lay`'s register result that load `u` reads whole (pointers `ptr`
/// bytes), else NONE.
pub(package) fn result_part(lay: &ab::CallLayout, ptr: u32, u: Inst) u32 {
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
pub(package) fn arg_part(b: &Body, lay: &ab::CallLayout, ptr: u32, loc: ab::ALoc, u: Inst) u32 {
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
