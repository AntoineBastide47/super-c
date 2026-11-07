// The LIR inliner of an optimizing build: a direct call of a small function body becomes a copy of that
// body. The call's block ends with a jump to the copy's entry block, which takes the call's arguments as
// its parameters (an aggregate argument is a pointer to a copy the callee owns, an aggregate result a
// pointer the caller passes: both stay pointers), and each `ret` of the copy jumps to a new block that
// holds the rest of the caller's block, the result as its parameter. The optimizer then forwards the
// parameters of the blocks with one predecessor and merges the blocks a jump alone enters.
//
// `lir::opt::optimize` inlines callees first: a body splices the bodies of its callees as they are after
// their own inlining and optimization.
import lir::ir as *;
import lir::eval as le;
import lir::verify as lv;

/// A caller takes no more callees past CALLER_MAX instructions, but the ones no bigger than their call.
pub(package) const CALLER_MAX: u32 = 8000;

/// The inline budgets: a callee inlines when it holds at most `warm` instructions outside rare blocks
/// (`BLOCK_RARE`) and `all` in all; a `@cold` one, within SHRINK; an `@always_inline` one (`Sym.always`)
/// whatever its size, up to CALLER_MAX. `optimize`'s levels: none, the callees
/// no bigger than their calls (`SHRINK`), and past them by optimization level (scaled as LLVM's and GCC's
/// thresholds: for size a fifth of the speed one, at the highest level half again).
pub(package) struct Budget {
    pub(package) warm: u32,
    pub(package) all: u32,
}

extend Budget as Copy {}

pub(package) const NONE_INLINES: Budget = Budget { warm: 0, all: 0 };
pub(package) const SHRINK: Budget = Budget { warm: 8, all: 24 };
pub(package) const SIZE: Budget = Budget { warm: 12, all: 48 };
pub(package) const SPEED: Budget = Budget { warm: 40, all: 160 };
pub(package) const FAST: Budget = Budget { warm: 60, all: 240 };

/// Whether body `b` of function symbol `s` of `pk` may be copied into a caller: not `@noinline`, naked,
/// variadic or a routine the evaluator models; no inline assembly, variadic access, return address or
/// call of itself; its blocks in order in its instruction array (as the optimizer leaves them).
pub(package) const fn shape_ok(pk: &Package, s: u32, b: &Body) bool {
    let sy = pk.syms[s as usize];
    if sy.noinline || b.naked || b.sig == NONE || (b.pool[b.sig as usize + 1] & SIG_VARIADIC) != 0 || le::modeled(
        pk.spell(sy.name),
    ) {
        return false;
    }
    let mut at: u32 = 0;
    for k in 0..b.blocks.len() {
        if b.blocks[k].start != at {
            return false;
        }
        at += b.blocks[k].len;
    }
    for i in 0..b.insts.len() {
        let t = b.insts[i];
        if t.op == O_ASM || t.op == O_VASTART || t.op == O_RETADDR || t.op == O_CALL && b.syms[t.a as usize] == s {
            return false;
        }
    }
    return true;
}

/// Whether body `b` only forwards its parameters to one call: one block of loads of its parameters'
/// bytes, constants and the call, then `ret` or `unreachable` (`panic_parts`, which passes the parts of
/// two strings on). Inlined, its loads read what the caller stored, so it is no bigger than its call, on
/// a failure path too.
pub(package) const fn forwarder(b: &Body) bool {
    if b.blocks.len() != 1 {
        return false;
    }
    let n = b.insts.len();
    let mut calls: u32 = 0;
    for i in 0..n {
        let t = b.insts[i];
        let ok = t.op == O_LOAD && (t.a & VPARAM) != 0 && (t.aux & MEM_VOLATILE) == 0 || t.op == O_ICONST || (t.op == O_RET || t.op == O_UNREACHABLE) && i + 1 == n;
        calls += (t.op == O_CALL) as u32;
        if !ok && t.op != O_CALL {
            return false;
        }
    }
    return calls == 1;
}

/// Whether body `b` may fit budget `bu` at a call: at most `bu.all` instructions (`small`, or `folds_small`
/// for the call's constant arguments).
pub(package) const fn bounded(b: &Body, bu: Budget) bool {
    return b.insts.len() as u32 <= bu.all;
}

/// Whether the blocks of body `e` that call `t` of `c` reaches fit budget `bu` (`small`): a branch or a
/// switch on an entry parameter whose argument is a constant, or on its comparison with a constant, takes
/// its one edge (`scale(x, 1)` reaches one arm of `switch mode`). `seen` and `work` are scratch.
fn folds_small(
    e: &Body,
    c: &Body,
    t: Inst,
    bu: Budget,
    seen: &mut Vector<bool>,
    work: &mut Vector<u32>,
    es: &mut Vector<u32>,
) bool {
    fill(seen, e.blocks.len(), false);
    work.truncate(0);
    work.push(0);
    seen[0] = true;
    let mut warm: u32 = 0;
    let mut all: u32 = 0;
    // Each block enters the walk once.
    while work.len() != 0 {
        let k = work.pop().unwrap();
        let bk = e.blocks[k as usize];
        all += bk.len;
        if (bk.flags & BLOCK_RARE) == 0 {
            warm += bk.len;
        }
        let end = e.insts[(bk.start + bk.len - 1) as usize];
        e.succ_edges(end, es);
        let mut only = NONE;
        if end.op == O_BR && (end.a & (VPARAM | VFLAG)) == 0 && e.insts[end.a as usize].op == O_ICMP {
            let q = e.insts[end.a as usize];
            let x = known(e, c, t, q.a);
            let y = known(e, c, t, q.b);
            if x.is_some() && y.is_some() {
                only = if le::icmp(q.aux, e.type_of(q.a), 8, x.unwrap(), y.unwrap()) {
                    end.b
                } else {
                    end.c
                };
            }
        } else if end.op == O_SWITCH {
            let x = known(e, c, t, end.a);
            if x.is_some() {
                let m = mask(e.type_of(end.a));
                only = e.switch_edge(end, end.aux);
                for q in 0..end.aux as u32 {
                    if (e.words[(end.b + q) as usize] & m) == (x.unwrap() & m) {
                        only = e.switch_edge(end, q);
                    }
                }
            }
        }
        for q in 0..es.len() {
            let s = e.edge_target(es[q]);
            if (only == NONE || es[q] == only) && !seen[s as usize] {
                seen[s as usize] = true;
                work.push(s);
            }
        }
    }
    return warm <= bu.warm && all <= bu.all;
}

// The constant value `v` of callee `e` has at call `t` of `c`: an integer constant, or an entry parameter
// whose argument is one.
fn known(e: &Body, c: &Body, t: Inst, v: Value) Option<u64> {
    let w = if (v & VPARAM) != 0 && (v & ~VPARAM) < e.blocks[0].param_len as u32 {
        c.pool[(t.c + (v & ~VPARAM)) as usize]
    } else if (v & (VPARAM | VFLAG)) == 0 {
        v
    } else {
        return None;
    };
    let b = if w == v {
        e
    } else {
        c
    };
    if w == VNONE || (w & (VPARAM | VFLAG)) != 0 || b.insts[w as usize].op != O_ICONST || b.insts[w as usize].ty == T_I128 {
        return None;
    }
    let k = b.insts[w as usize];
    return Some(k.b as u64 << 32 | k.a as u64);
}

// The bits of integer type `ty` up to 64.
const fn mask(ty: u8) u64 {
    let n = type_bits(ty, 8);
    return if n >= 64 {
        ~0u64
    } else {
        (1u64 << n as u64) - 1
    };
}

/// The facts of an inlinable body that each call of it reads (`Run.ok`, set once the body is final):
/// callers may inline it, it is `small` within SHRINK, `small` within the run's budget, a `forwarder`, it
/// computes with floats (`floats`).
pub(package) const IL_OK: u8 = 1;
pub(package) const IL_SHRINK: u8 = 2;
pub(package) const IL_SMALL: u8 = 4;
pub(package) const IL_FWD: u8 = 8;
pub(package) const IL_FLOAT: u8 = 16;

/// The `IL_*` facts of inlinable body `b` under budget `bu`.
pub(package) const fn facts(b: &Body, bu: Budget) u8 {
    return IL_OK | small(b, SHRINK) as u8 * IL_SHRINK | small(b, bu) as u8 * IL_SMALL | forwarder(b) as u8 * IL_FWD | floats(
        b,
    ) as u8 * IL_FLOAT;
}

/// Whether body `b` has an instruction a float rewrite (`Body.fmath`) may change: a float result, scalar or
/// in lanes, or a float comparison.
const fn floats(b: &Body) bool {
    for i in 0..b.insts.len() {
        let t = b.insts[i];
        let ty = if is_vec(t.ty) {
            lane_type(t.ty)
        } else {
            t.ty
        };
        if is_float(ty) || t.op == O_FCMP {
            return true;
        }
    }
    return false;
}

/// Whether body `b` fits budget `bu`.
pub(package) const fn small(b: &Body, bu: Budget) bool {
    let mut warm: u32 = 0;
    for k in 0..b.blocks.len() {
        if (b.blocks[k].flags & BLOCK_RARE) == 0 {
            warm += b.blocks[k].len;
        }
    }
    return warm <= bu.warm && b.insts.len() as u32 <= bu.all;
}

// A call to inline: its instruction, the callee's body and the bases of the copy's blocks, values and
// parameters, and the continuation block and its parameter (NONE: a call without a result).
struct Site {
    pub(package) inst: u32,
    pub(package) cold: u16, // the call's block's rare marks (`BLOCK_RARE`): the copy's blocks take them
    pub(package) callee: u32,
    pub(package) bbase: u32,
    pub(package) vbase: u32,
    pub(package) pbase: u32,
    pub(package) kblock: u32,
    pub(package) kparam: u32,
}

extend Site as Copy {}

/// The inliner's scratch, reused from body to body.
pub(package) struct Inliner {
    sites: Vector<Site>,
    cmap: Vector<u32>, // per caller instruction, its value in the new body
    cbmap: Vector<u32>, // per caller block, the new block that starts it
    done: Vector<bool>, // per pool word of the new body, whether it is rewritten
    smap: Map<u32, u32>, // package symbol -> the new body's symbol number
    mmap: Map<u32, u32>, // package message -> the new body's message number
    csym: Vector<u32>, // per callee symbol number, the new body's
    cmsg: Vector<u32>, // per callee message number, the new body's
    edges: Vector<u32>,
    seen: Vector<bool>, // `folds_small`'s scratch
    work: Vector<u32>,
    /// Per caller instruction, whether `run` may inline its call; empty: every call.
    pub(package) only: Vector<bool>,
    // The new body's instruction, block and parameter counts (`plan`).
    ni: u32,
    nb: u32,
    np: u32,
}

// The bases of one callee copy's tables in the new body.
struct Bases {
    pub(package) pool: u32,
    pub(package) words: u32,
    pub(package) slots: u32,
    pub(package) lines: u32,
}

extend Bases as Copy {}

extend Inliner {
    pub(package) fn new() Inliner {
        return Inliner {
            sites: Vector::<Site>::new(),
            cmap: Vector::<u32>::new(),
            cbmap: Vector::<u32>::new(),
            done: Vector::<bool>::new(),
            smap: Map::<u32, u32>::new(),
            mmap: Map::<u32, u32>::new(),
            csym: Vector::<u32>::new(),
            cmsg: Vector::<u32>::new(),
            seen: Vector::<bool>::new(),
            work: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
            only: Vector::<bool>::new(),
            ni: 0,
            nb: 0,
            np: 0,
        };
    }

    /// Inline into `c`, body `ci` of `bodies`, the calls of the bodies of a lower `level` that `ok` marks
    /// (`IL_*` facts, `facts` under `bu`; read for those only: a body of another level may be in the works),
    /// a body with a `unit`
    /// (per body: its unit when the unit keeps its bodies, else NONE) into a body of that unit only.
    /// Whether any inlined.
    pub(package) fn run(
        self: &mut Self,
        pk: &Package,
        bodies: *const Body,
        ok: &Vector<u8>,
        level: &Vector<u32>,
        unit: &Vector<u32>,
        ci: u32,
        bu: Budget,
        c: &mut Body,
    ) bool {
        if !self.plan(pk, bodies, ok, level, unit, ci, bu, c) {
            return false;
        }
        let out = self.build(bodies, c);
        *c = out;
        return true;
    }

    // The sites, and the numbering of the new body: per caller block its first part, a call's part ending
    // in a jump to the copy, the copy's blocks, then the continuation that holds the rest.
    fn plan(
        self: &mut Self,
        pk: &Package,
        bodies: *const Body,
        ok: &Vector<u8>,
        level: &Vector<u32>,
        unit: &Vector<u32>,
        ci: u32,
        bu: Budget,
        c: &Body,
    ) bool {
        self.sites.truncate(0);
        let mut size = c.insts.len() as u32;
        let mut nb: u32 = 0;
        let mut ni: u32 = 0;
        let mut np = c.params.len() as u32;
        fill(&mut self.cmap, c.insts.len(), NONE);
        fill(&mut self.cbmap, c.blocks.len(), NONE);
        for k in 0..c.blocks.len() {
            let bk = c.blocks[k];
            self.cbmap[k] = nb;
            nb += 1;
            // A failure path (a cold block, or one that ends the program) keeps its calls but forwarders.
            let end = c.insts[(bk.start + bk.len - 1) as usize].op;
            let warm = (bk.flags & BLOCK_COLD) == 0 && end != O_UNREACHABLE && end != O_PANIC;
            for i in bk.start..bk.start + bk.len {
                let t = c.insts[i as usize];
                let callee = if t.op == O_CALL {
                    callee_of(pk, c, t)
                } else {
                    NONE
                };
                if callee == NONE || self.only.len() != 0 && !self.only[i as usize] || level[callee as usize] >= level[ci as usize] || (ok[callee as usize] & IL_OK) == 0 || unit[callee as usize] != NONE && unit[callee as usize] != unit[ci as usize] {
                    self.cmap[i as usize] = ni;
                    ni += 1;
                    continue;
                }
                let e = unsafe &*(bodies + callee as usize);
                let f = ok[callee as usize];
                // A callee of one block and at most 3 instructions (a field read) is no bigger than its
                // call: CALLER_MAX does not stop it. A failure path takes forwarders alone.
                let tiny = e.blocks.len() == 1 && e.insts.len() <= 3;
                // An `@always_inline` callee passes the size, cold and rare-path gates (the Core IR's
                // inliner, which a native build skips, did as much: `ir::inline::always_native`).
                let always = pk.syms[c.syms[t.a as usize] as usize].always;
                // A `@cold` callee stays a call unless it is no bigger than one: its callers' code stays small.
                let cold = pk.syms[c.syms[t.a as usize] as usize].cold && (f & IL_SHRINK) == 0 && !always;
                // A call in a rare block (`BLOCK_RARE`) takes the callees no bigger than it: a copy there grows the
                // code for a path that seldom runs (a caller's second round takes it once that path is the
                // caller's warm one, `Run::warm_copies`).
                let (cb, cf) = if (bk.flags & BLOCK_RARE) != 0 {
                    (SHRINK, IL_SHRINK)
                } else {
                    (bu, IL_SMALL)
                };
                // A float rewrite the caller allows and the callee does not would apply to the copy (of a
                // callee that computes with floats).
                if (c.fmath & ~e.fmath) != 0 && (f & IL_FLOAT) != 0 || !warm && (f & IL_FWD) == 0 && !always || cold || size + e.insts.len() as u32 > CALLER_MAX && !tiny || e.blocks[0].param_len as u32 != t.aux as u32 || (f & cf) == 0 && !always && !folds_small(
                    e,
                    c,
                    t,
                    cb,
                    &mut self.seen,
                    &mut self.work,
                    &mut self.edges,
                ) {
                    self.cmap[i as usize] = ni;
                    ni += 1;
                    continue;
                }
                size += e.insts.len() as u32;
                ni += 1; // the jump to the copy
                let s = Site {
                    inst: i,
                    cold: bk.flags & BLOCK_RARE,
                    callee: callee,
                    bbase: nb,
                    vbase: ni,
                    pbase: np,
                    kblock: nb + e.blocks.len() as u32,
                    kparam: if t.ty == T_NONE {
                        NONE
                    } else {
                        np + e.params.len() as u32
                    },
                };
                nb += e.blocks.len() as u32 + 1;
                ni += e.insts.len() as u32;
                np += e.params.len() as u32 + if t.ty == T_NONE {
                    0u32
                } else {
                    1u32
                };
                self.cmap[i as usize] = if s.kparam == NONE {
                    VNONE
                } else {
                    VPARAM | s.kparam
                };
                self.sites.push(s);
            }
        }
        self.ni = ni;
        self.nb = nb;
        self.np = np;
        return self.sites.len() != 0;
    }

    // The new body, in the numbering `plan` chose.
    fn build(self: &mut Self, bodies: *const Body, c: &Body) Body {
        let mut o = Body::new();
        self.reserve(bodies, c, &mut o);
        o.pool.extend_copy(&c.pool);
        o.words.extend_copy(&c.words);
        o.slots.extend_copy(&c.slots);
        o.syms.extend_copy(&c.syms);
        o.msgs.extend_copy(&c.msgs);
        o.lines.truncate(0);
        o.lines.extend_copy(&c.lines);
        o.params.extend_copy(&c.params);
        o.sig = c.sig;
        o.refs.extend_copy(&c.refs);
        o.owned.extend_copy(&c.owned);
        o.bools = c.bools;
        o.fmath = c.fmath;
        for x in 0..c.scopes.len() {
            let sc = c.scopes[x];
            o.scopes.push(Scope { site: sc.site, group: sc.group, root: self.cval(sc.root) });
        }
        self.smap.clear();
        for k in 0..c.syms.len() {
            self.smap.insert(c.syms[k], k as u32);
        }
        self.mmap.clear();
        for k in 0..c.msgs.len() {
            self.mmap.insert(c.msgs[k], k as u32);
        }
        fill(&mut self.done, c.pool.len(), false);
        let mut si: usize = 0;
        for k in 0..c.blocks.len() {
            let bk = c.blocks[k];
            let mut start = o.insts.len() as u32;
            let mut ps = bk.param_start;
            let mut pl = bk.param_len;
            for i in bk.start..bk.start + bk.len {
                if si < self.sites.len() && self.sites[si].inst == i {
                    let s = self.sites[si];
                    si += 1;
                    let t = c.insts[i as usize];
                    let e = unsafe &*(bodies + s.callee as usize);
                    // The part before the call jumps to the copy's entry with the call's arguments.
                    let mut args = Vector::<u32>::with_capacity(t.aux as usize);
                    for q in 0..t.aux as u32 {
                        args.push(self.cval(c.pool[(t.c + q) as usize]));
                    }
                    let edge = o.edge(s.bbase, &args);
                    o.insts.push(Inst { op: O_JMP, ty: T_NONE, aux: 0, a: edge, b: 0, c: 0 });
                    o.locs.push(c.locs[i as usize]);
                    o.inl.push(site_of(c, i, false));
                    o.blocks.push(
                        Block {
                            start: start,
                            len: o.insts.len() as u32 - start,
                            param_start: ps,
                            param_len: pl,
                            flags: bk.flags,
                        },
                    );
                    let mut site = site_of(c, i, true);
                    if site_of(c, i, false) == 0 && site != 0 && Inliner::exclusive(e) {
                        // A site of its own: the copy's instructions alone hold it (`Scope`).
                        o.lines.push(c.lines[site as usize]);
                        site = o.lines.len() as u32 - 1;
                        Inliner::scopes(e, s, site, &mut o);
                    }
                    self.copy(e, s, c.locs[i as usize], site, &mut o);
                    // The continuation: the call's result as its parameter.
                    start = o.insts.len() as u32;
                    if s.kparam == NONE {
                        ps = 0;
                        pl = 0;
                    } else {
                        ps = s.kparam;
                        pl = 1;
                        o.params.push(t.ty);
                    }
                    continue;
                }
                let t = self.caller_inst(c, c.insts[i as usize], &mut o);
                o.insts.push(t);
                o.locs.push(c.locs[i as usize]);
                o.inl.push(site_of(c, i, false));
            }
            o.blocks.push(
                Block {
                    start: start,
                    len: o.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: pl,
                    flags: bk.flags,
                },
            );
        }
        return o;
    }

    // Each table of the new body `o` at its size (the instructions, blocks and parameters `plan` numbered,
    // the copies' tables), or at a bound (the jumps' and returns' edges, the symbols and messages, the
    // sites' own `lines` entries), so that no copy grows a table by doubling. The instruction, block,
    // parameter and pool tables take a quarter more: the first walk adds constants and hoisted copies, the
    // loop passes preheaders, and a full table would double for those few.
    fn reserve(self: &Self, bodies: *const Body, c: &Body, o: &mut Body) {
        let mut pool = c.pool.len();
        let mut words = c.words.len();
        let mut slots = c.slots.len();
        let mut lines = c.lines.len();
        let mut syms = c.syms.len();
        let mut msgs = c.msgs.len();
        for x in 0..self.sites.len() {
            let s = self.sites[x];
            let e = unsafe &*(bodies + s.callee as usize);
            // The jump's edge passes the call's arguments; a `ret`, a block's terminator, passes one value.
            pool += e.pool.len() + 2 + c.insts[s.inst as usize].aux as usize + 3 * e.blocks.len();
            words += e.words.len();
            slots += e.slots.len();
            lines += e.lines.len(); // entry 0 is the caller's own; one for the site's scopes
            syms += e.syms.len();
            msgs += e.msgs.len();
        }
        let ni = grown(self.ni);
        o.insts.reserve_exact(ni);
        o.locs.reserve_exact(ni);
        o.inl.reserve_exact(ni);
        o.blocks.reserve_exact(grown(self.nb));
        o.params.reserve_exact(grown(self.np));
        o.pool.reserve_exact(grown(pool as u32));
        o.words.reserve_exact(words);
        o.slots.reserve_exact(slots);
        o.lines.reserve_exact(lines);
        o.syms.reserve_exact(syms);
        o.msgs.reserve_exact(msgs);
    }

    // The new value of caller value `v`.
    const fn cval(self: &Self, v: Value) Value {
        if v == VNONE || (v & VPARAM) != 0 {
            return v;
        }
        return self.cmap[(v & ~VFLAG) as usize] | v & VFLAG;
    }

    // Caller instruction `t` with its values, blocks and pool lists in the new numbering.
    fn caller_inst(self: &mut Self, c: &Body, t0: Inst, o: &mut Body) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.cval(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.cval(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.cval(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for q in 0..t.aux as u32 {
                self.cpool(o, t.c + q);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                self.cpool(o, t.a + q);
            }
        }
        c.succ_edges(t, &mut self.edges);
        for x in 0..self.edges.len() {
            let e = self.edges[x];
            if !self.done[e as usize] {
                self.done[e as usize] = true;
                o.pool[e as usize] = self.cbmap[o.pool[e as usize] as usize];
                for q in 0..o.pool[e as usize + 1] {
                    self.cpool(o, e + 2 + q);
                }
            }
        }
        return t;
    }

    const fn cpool(self: &mut Self, o: &mut Body, at: u32) {
        if !self.done[at as usize] {
            self.done[at as usize] = true;
            o.pool[at as usize] = self.cval(o.pool[at as usize]);
        }
    }

    // Whether callee `e` has an exclusive parameter (`REF_NOALIAS`).
    const fn exclusive(e: &Body) bool {
        for k in 0..e.refs.len() {
            if (e.refs[k] & REF_NOALIAS) != 0 {
                return true;
            }
        }
        return false;
    }

    // The scopes of callee `e`'s exclusive parameters in its copy for site `s` at `lines` entry `site`:
    // a reference's root is the copy's parameter; a view's (`REF_INNER`) are the copies of the loads of
    // its element pointer, when the callee reads the parameter only as loads' address.
    fn scopes(e: &Body, s: Site, site: u32, o: &mut Body) {
        let e0 = e.blocks[0];
        for k in 0..e.refs.len() as u32 {
            let r = e.refs[k as usize];
            if (r & REF_NOALIAS) == 0 || k >= e0.param_len as u32 {
                continue;
            }
            let p = VPARAM | e0.param_start + k;
            if (r & REF_INNER) == 0 {
                o.scopes.push(Scope { site: site, group: k, root: VPARAM | s.pbase + e0.param_start + k });
                continue;
            }
            if !Inliner::loads_only(e, p) {
                continue;
            }
            for x in 0..e.insts.len() as u32 {
                let t = e.insts[x as usize];
                if t.op == O_LOAD && t.a == p && t.c == 0 && t.ty == T_PTR {
                    o.scopes.push(Scope { site: site, group: k, root: s.vbase + x });
                }
            }
        }
    }

    // Whether body `e` uses value `p` only as a load's address.
    fn loads_only(e: &Body, p: Value) bool {
        let mut uses = Vector::<Value>::new();
        let mut edges = Vector::<u32>::new();
        for x in 0..e.insts.len() {
            let t = e.insts[x];
            lv::uses(e, t, &mut uses);
            e.succ_edges(t, &mut edges);
            for j in 0..edges.len() {
                for a in 0..e.edge_nargs(edges[j]) {
                    uses.push(e.edge_arg(edges[j], a));
                }
            }
            for u in 0..uses.len() {
                if uses[u] == p && !(t.op == O_LOAD && u == 0) {
                    return false;
                }
            }
        }
        return true;
    }

    // Copy callee `e` into `o` for site `s` (the call at location `loc`, inlined from the caller's statement
    // at `site`): its tables appended, its blocks and values at the site's bases, each `ret` a jump to
    // the continuation.
    fn copy(self: &mut Self, e: &Body, s: Site, loc: u32, site: u32, o: &mut Body) {
        let bs = Bases {
            pool: o.pool.len() as u32,
            words: o.words.len() as u32,
            slots: o.slots.len() as u32,
            lines: o.lines.len() as u32,
        };
        o.pool.extend_copy(&e.pool);
        o.words.extend_copy(&e.words);
        o.slots.extend_copy(&e.slots);
        // Entry 0, "no location", is the caller's own.
        if e.lines.len() > 1 {
            o.lines.extend_from_slice(e.lines[1..e.lines.len()]);
        }
        o.params.extend_copy(&e.params);
        fill_bool_to(&mut self.done, o.pool.len());
        fill(&mut self.csym, e.syms.len(), 0);
        for q in 0..e.syms.len() {
            self.csym[q] = Inliner::ref_in(&mut self.smap, &mut o.syms, e.syms[q]);
        }
        fill(&mut self.cmsg, e.msgs.len(), 0);
        for q in 0..e.msgs.len() {
            self.cmsg[q] = Inliner::ref_in(&mut self.mmap, &mut o.msgs, e.msgs[q]);
        }
        for k in 0..e.blocks.len() {
            let bk = e.blocks[k];
            let start = o.insts.len() as u32;
            for i in bk.start..bk.start + bk.len {
                let t = self.callee_inst(e.insts[i as usize], s, bs, o);
                o.insts.push(t);
                let l = e.locs[i as usize];
                o.locs.push(
                    if l == 0 {
                        loc
                    } else {
                        bs.lines + l - 1
                    },
                );
                o.inl.push(site);
            }
            o.blocks.push(
                Block {
                    start: start,
                    len: o.insts.len() as u32 - start,
                    param_start: s.pbase + bk.param_start,
                    param_len: bk.param_len,
                    flags: bk.flags | s.cold,
                },
            );
        }
    }

    // The body number in `syms` of package entry `x` (a symbol or a message), added when new.
    fn ref_in(m: &mut Map<u32, u32>, syms: &mut Vector<u32>, x: u32) u32 {
        let found = switch m.get(&x) {
            Some(k) => *k,
            None => NONE,
        };
        if found != NONE {
            return found;
        }
        syms.push(x);
        m.insert(x, syms.len() as u32 - 1);
        return syms.len() as u32 - 1;
    }

    // Callee instruction `t0`, copied for site `s` with table bases `bs` into `o`.
    fn callee_inst(self: &mut Self, t0: Inst, s: Site, bs: Bases, o: &mut Body) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if t.op == O_RET {
            // A jump to the continuation, with the result.
            let mut args = Vector::<u32>::new();
            if s.kparam != NONE {
                args.push(ev(s, t.a));
            }
            return Inst { op: O_JMP, ty: T_NONE, aux: 0, a: o.edge(s.kblock, &args), b: 0, c: 0 };
        }
        if lv::operand_a(f) {
            t.a = ev(s, t.a);
        }
        if lv::operand_b(f) {
            t.b = ev(s, t.b);
        }
        if lv::operand_c(f) {
            t.c = ev(s, t.c);
        }
        if f == F_SYM || f == F_CALL {
            t.a = self.csym[t.a as usize];
        } else if f == F_SLOT {
            t.a += bs.slots;
        } else if f == F_WIDE {
            t.a += bs.words;
        } else if f == F_PANIC {
            t.a = self.cmsg[t.a as usize];
        }
        if f == F_CALL || f == F_CALLIND {
            t.b += bs.pool;
            t.c += bs.pool;
            self.sig_fix(o, t.b, bs.pool);
            for q in 0..t.aux as u32 {
                self.epool(o, t.c + q, s);
            }
        } else if f == F_VOP {
            t.a += bs.pool;
            for q in 0..t.b {
                self.epool(o, t.a + q, s);
            }
            if t.c != VNONE {
                t.c += bs.pool;
            }
        } else if f == F_SWITCH {
            t.b += bs.words;
            t.c += bs.pool;
            for q in 0..t.aux as u32 + 1 {
                if !self.done[(t.c + q) as usize] {
                    self.done[(t.c + q) as usize] = true;
                    o.pool[(t.c + q) as usize] += bs.pool;
                }
            }
        } else if f == F_JMP {
            t.a += bs.pool;
        } else if f == F_BR {
            t.b += bs.pool;
            t.c += bs.pool;
        }
        o.succ_edges(t, &mut self.edges);
        for x in 0..self.edges.len() {
            let ed = self.edges[x];
            if !self.done[ed as usize] {
                self.done[ed as usize] = true;
                o.pool[ed as usize] += s.bbase;
                for q in 0..o.pool[ed as usize + 1] {
                    self.epool(o, ed + 2 + q, s);
                }
            }
        }
        return t;
    }

    const fn epool(self: &mut Self, o: &mut Body, at: u32, s: Site) {
        if !self.done[at as usize] {
            self.done[at as usize] = true;
            o.pool[at as usize] = ev(s, o.pool[at as usize]);
        }
    }

    // A signature record at `sig` of the copy: its aggregate layouts moved by `base`.
    const fn sig_fix(self: &mut Self, o: &mut Body, sig: u32, base: u32) {
        if self.done[sig as usize] {
            return;
        }
        self.done[sig as usize] = true;
        let n = o.pool[sig as usize];
        for q in sig + 2..sig + 3 + n {
            if (o.pool[q as usize] & AGG) != 0 {
                o.pool[q as usize] += base;
            }
        }
    }
}

// The body index of the function direct call `t` of `c` calls (NONE: none defined).
const fn callee_of(pk: &Package, c: &Body, t: Inst) u32 {
    let sy = pk.syms[c.syms[t.a as usize] as usize];
    return if sy.kind == SK_FUNC && sy.def != NONE {
        sy.def
    } else {
        NONE
    };
}

// The inline site of caller instruction `i` of `c`: the call it came from, 0 for the caller's own; with
// `copy`, that of an instruction inlined from it: its own location when it is the caller's.
const fn site_of(c: &Body, i: u32, copy: bool) u32 {
    let s = if c.inl.len() != 0 {
        c.inl[i as usize]
    } else {
        0u32
    };
    return if copy && s == 0 {
        c.locs[i as usize]
    } else {
        s
    };
}

// The new value of callee value `v` at site `s`.
const fn ev(s: Site, v: Value) Value {
    if v == VNONE {
        return v;
    }
    if (v & VPARAM) != 0 {
        return VPARAM | s.pbase + (v & ~VPARAM);
    }
    return s.vbase + (v & ~VFLAG) | v & VFLAG;
}

// A table size `n` with room for the passes' additions.
const fn grown(n: u32) usize {
    return n as usize + n as usize / 4 + 16;
}

// `v` grown to `n` entries, the new ones false.
fn fill_bool_to(v: &mut Vector<bool>, n: usize) {
    v.resize_default(n);
}
