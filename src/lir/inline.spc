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

/// A caller takes no more callees past CALLER_MAX instructions.
pub const CALLER_MAX: u32 = 8000;

/// The inline budgets: a callee inlines when it holds at most `warm` instructions outside cold blocks and
/// `all` in all. `optimize`'s levels: none, the callees no bigger than their calls (`SHRINK`), and past
/// them by optimization level (the LLVM and GCC thresholds of the step 18 survey: for size a fifth of the
/// speed one, at the highest level half again).
pub struct Budget {
    pub warm: u32,
    pub all: u32,
}

extend Budget as Copy {}

pub const NONE_INLINES: Budget = Budget { warm: 0, all: 0 };
pub const SHRINK: Budget = Budget { warm: 8, all: 24 };
pub const SIZE: Budget = Budget { warm: 12, all: 48 };
pub const SPEED: Budget = Budget { warm: 40, all: 160 };
pub const FAST: Budget = Budget { warm: 60, all: 240 };

/// Whether body `b` of function symbol `s` of `pk` may be copied into a caller: not `@noinline`, naked,
/// variadic or a routine the evaluator models; no inline assembly, variadic access, return address or
/// call of itself; its blocks in order in its instruction array (as the optimizer leaves them).
pub fn shape_ok(pk: &Package, s: u32, b: &Body) bool {
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

/// Whether body `b` fits budget `bu`.
pub fn small(b: &Body, bu: Budget) bool {
    let mut warm: u32 = 0;
    for k in 0..b.blocks.len() {
        if (b.blocks[k].flags & BLOCK_COLD) == 0 {
            warm += b.blocks[k].len;
        }
    }
    return warm <= bu.warm && b.insts.len() as u32 <= bu.all;
}

// A call to inline: its instruction, the callee's body and the bases of the copy's blocks, values and
// parameters, and the continuation block and its parameter (NONE: a call without a result).
struct Site {
    pub inst: u32,
    pub callee: u32,
    pub bbase: u32,
    pub vbase: u32,
    pub pbase: u32,
    pub kblock: u32,
    pub kparam: u32,
}

extend Site as Copy {}

/// The inliner's scratch, reused from body to body.
pub struct Inliner {
    sites: Vector<Site>,
    cmap: Vector<u32>, // per caller instruction, its value in the new body
    cbmap: Vector<u32>, // per caller block, the new block that starts it
    done: Vector<bool>, // per pool word of the new body, whether it is rewritten
    smap: Map<u32, u32>, // package symbol -> the new body's symbol number
    mmap: Map<u32, u32>, // package message -> the new body's message number
    csym: Vector<u32>, // per callee symbol number, the new body's
    cmsg: Vector<u32>, // per callee message number, the new body's
    edges: Vector<u32>,
}

// The bases of one callee copy's tables in the new body.
struct Bases {
    pub pool: u32,
    pub words: u32,
    pub slots: u32,
    pub lines: u32,
}

extend Bases as Copy {}

extend Inliner {
    pub fn new() Inliner {
        return Inliner {
            sites: Vector::<Site>::new(),
            cmap: Vector::<u32>::new(),
            cbmap: Vector::<u32>::new(),
            done: Vector::<bool>::new(),
            smap: Map::<u32, u32>::new(),
            mmap: Map::<u32, u32>::new(),
            csym: Vector::<u32>::new(),
            cmsg: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
        };
    }

    /// Inline into `c`, body `ci` of `bodies`, the calls of the bodies `ok` marks, a body with a `unit`
    /// (per body: its unit when the unit keeps its bodies, else NONE) into a body of that unit only.
    /// Whether any inlined.
    pub fn run(
        self: &mut Self,
        pk: &Package,
        bodies: *const Body,
        ok: &Vector<bool>,
        unit: &Vector<u32>,
        ci: u32,
        c: &mut Body,
    ) bool {
        if !self.plan(pk, bodies, ok, unit, ci, c) {
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
        ok: &Vector<bool>,
        unit: &Vector<u32>,
        ci: u32,
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
            // A failure path (a cold block, or one that ends the program) keeps its calls.
            let end = c.insts[(bk.start + bk.len - 1) as usize].op;
            let warm = (bk.flags & BLOCK_COLD) == 0 && end != O_UNREACHABLE && end != O_PANIC;
            for i in bk.start..bk.start + bk.len {
                let t = c.insts[i as usize];
                let callee = if t.op == O_CALL && warm {
                    callee_of(pk, c, t);
                } else {
                    NONE;
                };
                if callee == NONE || callee == ci || !ok[callee as usize] || unit[callee as usize] != NONE && unit[callee as usize] != unit[ci as usize] {
                    self.cmap[i as usize] = ni;
                    ni += 1;
                    continue;
                }
                let e = unsafe &*(bodies + callee as usize);
                if size + e.insts.len() as u32 > CALLER_MAX || e.blocks[0].param_len as u32 != t.aux as u32 {
                    self.cmap[i as usize] = ni;
                    ni += 1;
                    continue;
                }
                size += e.insts.len() as u32;
                ni += 1; // the jump to the copy
                let s = Site {
                    inst: i,
                    callee: callee,
                    bbase: nb,
                    vbase: ni,
                    pbase: np,
                    kblock: nb + e.blocks.len() as u32,
                    kparam: if t.ty == T_NONE {
                        NONE;
                    } else {
                        np + e.params.len() as u32;
                    },
                };
                nb += e.blocks.len() as u32 + 1;
                ni += e.insts.len() as u32;
                np += e.params.len() as u32 + if t.ty == T_NONE {
                    0u32;
                } else {
                    1u32;
                };
                self.cmap[i as usize] = if s.kparam == NONE {
                    VNONE;
                } else {
                    VPARAM | s.kparam;
                };
                self.sites.push(s);
            }
        }
        return self.sites.len() != 0;
    }

    // The new body, in the numbering `plan` chose.
    fn build(self: &mut Self, bodies: *const Body, c: &Body) Body {
        let mut o = Body::new();
        o.pool.extend_copy(&c.pool);
        o.words.extend_copy(&c.words);
        o.slots.extend_copy(&c.slots);
        o.syms.extend_copy(&c.syms);
        o.msgs.extend_copy(&c.msgs);
        o.lines.truncate(0);
        o.lines.extend_copy(&c.lines);
        o.params.extend_copy(&c.params);
        o.sig = c.sig;
        self.smap.clear();
        for k in 0..c.syms.len() {
            self.smap.insert(c.syms[k], k as u32);
        }
        self.mmap.clear();
        for k in 0..c.msgs.len() {
            self.mmap.insert(c.msgs[k], k as u32);
        }
        fill_bool(&mut self.done, c.pool.len(), false);
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
                    let edge = o.edge(s.bbase, args.as_slice());
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
                    self.copy(e, s, c.locs[i as usize], site_of(c, i, true), &mut o);
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

    fn cpool(self: &mut Self, o: &mut Body, at: u32) {
        if !self.done[at as usize] {
            self.done[at as usize] = true;
            o.pool[at as usize] = self.cval(o.pool[at as usize]);
        }
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
        for q in 1..e.lines.len() {
            o.lines.push(e.lines[q]);
        }
        for q in 0..e.params.len() {
            o.params.push(e.params[q]);
        }
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
                        loc;
                    } else {
                        bs.lines + l - 1;
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
                    flags: bk.flags,
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
            return Inst { op: O_JMP, ty: T_NONE, aux: 0, a: o.edge(s.kblock, args.as_slice()), b: 0, c: 0 };
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

    fn epool(self: &mut Self, o: &mut Body, at: u32, s: Site) {
        if !self.done[at as usize] {
            self.done[at as usize] = true;
            o.pool[at as usize] = ev(s, o.pool[at as usize]);
        }
    }

    // A signature record at `sig` of the copy: its aggregate layouts moved by `base`.
    fn sig_fix(self: &mut Self, o: &mut Body, sig: u32, base: u32) {
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
fn callee_of(pk: &Package, c: &Body, t: Inst) u32 {
    let sy = pk.syms[c.syms[t.a as usize] as usize];
    return if sy.kind == SK_FUNC && sy.def != NONE {
        sy.def;
    } else {
        NONE;
    };
}

// The inline site of caller instruction `i` of `c`: the call it came from, 0 for the caller's own; with
// `copy`, that of an instruction inlined from it: its own location when it is the caller's.
fn site_of(c: &Body, i: u32, copy: bool) u32 {
    let s = if c.inl.len() != 0 {
        c.inl[i as usize];
    } else {
        0u32;
    };
    return if copy && s == 0 {
        c.locs[i as usize];
    } else {
        s;
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

fn fill(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

fn fill_bool(v: &mut Vector<bool>, n: usize, x: bool) {
    v.truncate(0);
    v.resize_default(n);
    if x {
        v.as_mut_slice().fill(x);
    }
}

// `v` grown to `n` entries, the new ones false.
fn fill_bool_to(v: &mut Vector<bool>, n: usize) {
    v.resize_default(n);
}
