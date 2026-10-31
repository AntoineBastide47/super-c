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
        if s.kind == LC_REG && d.kind == LC_REG && s.reg == d.reg {
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

/// Whether every use of parameter value index `x` of `b` (an aggregate the body takes in registers, `loc`
/// of its own layout `lay`, pointers `ptr` bytes) is a load in the entry block, before any instruction
/// that `clobbers` registers, of one whole part of 4 bytes or more, no two of the same part: then each
/// load takes its part's register, appended to `taken` (part << 32 | load); else `taken` stays as it was.
/// `uses` is scratch.
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
        if t.op != O_LOAD || reads != 1 || (t.aux & MEM_VOLATILE) != 0 || lv.fold[i as usize] || is_vec(t.ty) || t.ty == T_I128 {
            taken.truncate(mark);
            return false;
        }
        let mut part = NONE;
        for q in 0..loc.n as u32 {
            let pa = lay.parts[(loc.p0 + q) as usize];
            if pa.off == t.c && pa.size as u32 == type_bytes(t.ty, ptr) && pa.v == is_v(t.ty) && type_bytes(t.ty, ptr) >= 4 {
                part = q;
            }
        }
        for q in mark..taken.len() {
            if taken[q] >> 32 == part as u64 {
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
