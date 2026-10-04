// Bounds-check elimination: a local, near-linear proof pass over one final elaborated CoreBody. It rewrites IN_BOUNDS / IN_RANGE_BOUNDS operations to their
// PROVEN twins ONLY when the proof holds at the exact operation site; anything unknown, mutated,
// called-past, joined-away, or over-limit keeps its check. The pass is the first client of the
// Core fact service (`ir::facts`): the versions, generations, effects and integer facts come from
// there; it never imports the C emitter.
//
// Fact model (dense, per body): a value fact is keyed by (local, version) (`fx::VKey`), and a
// collection-length fact additionally by (place structure, heap generation, base generation). Facts
// flow along edges into blocks with one forward predecessor, loop headers included (the header's
// entry bumps everything the loop can write), which is enough for the canonical indexed loop: the
// header's `index < length` branch fact reaches the loop body. The solved integer facts (intervals,
// strides) are the second proof source.
import ast::ast as *;
import lexer::token as tok;
import lexer::token_type as tt;
import ir::core as ir;
import ir::facts as fx;
import module::loader as loader;
import stdlib;

// Retained-check reasons (report order).
pub const BR_UNKNOWN_INDEX: u8 = 0;
pub const BR_UNKNOWN_LENGTH: u8 = 1;
pub const BR_OVERFLOW_UNKNOWN: u8 = 2;
pub const BR_JOIN_LOST_FACT: u8 = 3;
pub const BR_RESOURCE_LIMIT: u8 = 4;
pub const BR_WIDENED: u8 = 5; // the index's interval was lost to loop-header widening
pub const BR_COUNT: usize = 6;

pub struct BceStats {
    pub total: u32,
    pub removed: u32,
    pub ranges_total: u32,
    pub ranges_removed: u32,
    pub coalesced: u32,
    pub folded: u32,
    pub sig_kept: u32, // calls crossed without discarding collection facts (signature transparency)
    pub reasons: [u32; 6],
}

extend BceStats {
    pub fn new() BceStats {
        return BceStats {
            total: 0,
            removed: 0,
            ranges_total: 0,
            ranges_removed: 0,
            coalesced: 0,
            folded: 0,
            sig_kept: 0,
            reasons: [[0] = 0u32],
        };
    }
}

// One established or branch-derived fact. kinds: 0 = idx < len, 1 = idx <= len.
// Fields sort by size (8, 4, then 1 byte) so the struct has no padding holes.
struct Fact {
    // index key: a constant or a (local, version) value plus an affine constant offset
    pub ic: i64,
    pub ioff: i64,
    // length value identity (local, version, affine offset)
    pub ln_off: i64,
    pub il: u32,
    pub iv: u32,
    pub ln_l: u32,
    pub ln_v: u32,
    // length place identity (structural place + generations at capture)
    pub lp: u32,
    pub lp_hg: u32,
    pub lp_bg: u32,
    pub lp_pg: u32,
    pub lp_fg: u32,
    pub kind: u8,
    pub iconst: bool,
    pub ln_ok: bool,
    pub lp_ok: bool,
}

const MAX_EDGE_FACTS: usize = 96;
const MAX_TOTAL_FACTS: usize = 16384;

// Per-local length bindings, stamped with the version of the OWNER local at definition time so a
// redefinition invalidates them without any sweep.
struct LenBind {
    pub pl: u32, // the measured place (structural identity)
    pub hg: u32,
    pub bg: u32,
    pub pg: u32,
    pub fg: u32, // the buffer generation; compared only for a place that heap memory may hold
    pub my_v: u32,
    pub ok: bool,
}
// Canonical comparison binding: every <, <=, > and >= records as `a OP b` with OP in {<, <=}
// (the operand pair swaps for > and >=). `a_lp`/`b_lp` are the sides' length-place identities
// captured AT THE COMPARISON (a still-current length local, or a direct prelude len-field read),
// so a later fold proof can match the side against a recorded length fact.
struct CmpBind {
    pub a: fx::VKey,
    pub b: fx::VKey,
    pub a_lp: LenBind,
    pub b_lp: LenBind,
    pub le: bool, // true: a <= b, false: a < b
    pub my_v: u32,
    pub ok: bool,
}
// `l = IN_CHUNK(i, e)` at version `my_v`: `l <= e`, so a branch fact `x < l` (or `x <= l`) also
// holds for `e`, whose key and length place are captured here. A strip-mined loop's body learns
// its index bound through this.
struct ChunkBind {
    pub e: fx::VKey,
    pub e_lp: LenBind,
    pub l: u32,
    pub my_v: u32,
}
// `l = x % c` (usize, c > 0) at version `my_v`: `x - l` is at most `x` and a multiple of `c`.
struct RemBind {
    pub x: fx::VKey,
    pub x_lp: LenBind,
    pub c: i64,
    pub my_v: u32,
    pub ok: bool,
}
// The value of a local at version `my_v` is a multiple of `st` (0: no binding).
struct AlBind {
    pub st: u64,
    pub my_v: u32,
}
// Local `l` at version `v` holds the length `lb` names: its solved interval bounds that length.
struct LRead {
    pub lb: LenBind,
    pub l: u32,
    pub v: u32,
}
const LREADS_MAX: usize = 16;

pub struct Bce {
    pub fx: fx::Facts,
    pub lenof: Vector<LenBind>,
    pub cmpof: Vector<CmpBind>,
    pub remof: Vector<RemBind>,
    pub alof: Vector<AlBind>,
    pub chunks: Vector<ChunkBind>, // the body's chunk ends, few per body
    pub lreads: Vector<LRead>, // the latest length reads, at most LREADS_MAX
    // Integer facts solve on demand: `iwant` when the body could use them, `itried` once solved,
    // `clens` the length identities compared with a constant of 2 or more, `ialign` when a
    // remainder alignment was bound, and the walk's position for the replay.
    pub iwant: bool,
    pub itried: bool,
    pub ialign: bool,
    pub clens: Vector<LenBind>,
    pub cur_blk: u32,
    pub cur_sid: u32,
    pub facts: Vector<Fact>, // facts of the block being processed
    // Facts entering each block, filled by its single forward predecessor: block k's facts are
    // in_facts[in_start[k] .. in_start[k] + in_len[k]] (one pool per pass, no per-block vectors).
    pub in_facts: Vector<Fact>,
    pub in_start: Vector<u32>,
    pub in_len: Vector<u32>,
    pub in_set: Vector<bool>,
    pub total_facts: usize,
    pub limited: bool,
    pub off: bool, // SC_BCE=0
    pub no_fold: bool, // SC_BCE_DISABLE rule switches
    pub no_sig: bool,
    pub no_int: bool,
    // Coalescing-lookahead scratch (per try_coalesce call; kept for capacity). `cwritten[l] ==
    // cstamp` marks a local reassigned inside the current window, whose recorded binds describe its
    // OLD value; each window takes a fresh stamp, so no per-window reset touches every local.
    pub cwritten: Vector<u32>,
    pub cstamp: u32,
    pub la_dest: Vector<u32>,
    pub la_off: Vector<i64>,
    pub ll_dest: Vector<u32>,
    pub ll_pl: Vector<u32>,
}

// The successor a two-way branch on a bool takes when the bool is `v`, or IR_NONE for another shape
// (`switch t [1 -> x] otherwise y` and `switch t [0 -> y] otherwise x` both branch to x on true).
fn bool_target(b: &ir::CoreBody, t: &ir::Terminator, v: bool) u32 {
    if t.kind != ir::TM_SWITCH || t.sw_len != 1 || t.a == ir::IR_NONE {
        return ir::IR_NONE;
    }
    let pair = b.switch_pool[t.sw_start as usize];
    let pv = pair >> 32;
    let target = (pair & 0xFFFFFFFFu64) as u32;
    if pv > 1 || target == t.t0 {
        return ir::IR_NONE;
    }
    if pv == 1 == v {
        return target;
    }
    return t.t0;
}

// The length-place identity a fact captured.
const fn fact_lp(f: &Fact) LenBind {
    return LenBind { pl: f.lp, hg: f.lp_hg, bg: f.lp_bg, pg: f.lp_pg, fg: f.lp_fg, my_v: 0, ok: f.lp_ok };
}

const fn lenbind_none() LenBind {
    return LenBind { pl: 0, hg: 0, bg: 0, pg: 0, fg: 0, my_v: 0, ok: false };
}

// `lb` bound to local version `my_v`.
const fn lenbind_at(lb: LenBind, my_v: u32) LenBind {
    let mut x = lb;
    x.my_v = my_v;
    return x;
}

extend Bce {
    /// Emission-lifetime state (one per DropCtx): the env switches read once, every per-body
    /// table kept for capacity. `run` resets what a body needs, and sets the package.
    pub fn new() Bce {
        let dis = stdlib::getenv("SC_BCE_DISABLE");
        let mut d = "";
        if dis != null {
            d = str::from_cstr(dis);
        }
        let e = stdlib::getenv("SC_BCE");
        return Bce {
            fx: fx::Facts::new(d.contains("sig")),
            lenof: Vector::<LenBind>::new(),
            cmpof: Vector::<CmpBind>::new(),
            remof: Vector::<RemBind>::new(),
            alof: Vector::<AlBind>::new(),
            chunks: Vector::<ChunkBind>::new(),
            lreads: Vector::<LRead>::new(),
            iwant: false,
            itried: false,
            ialign: false,
            clens: Vector::<LenBind>::new(),
            cur_blk: 0,
            cur_sid: 0,
            facts: Vector::<Fact>::new(),
            in_facts: Vector::<Fact>::new(),
            in_start: Vector::<u32>::new(),
            in_len: Vector::<u32>::new(),
            in_set: Vector::<bool>::new(),
            total_facts: 0,
            limited: false,
            off: e != null && str::from_cstr(e) == "0",
            no_fold: d.contains("fold"),
            no_sig: d.contains("sig"),
            no_int: d.contains("int"),
            cwritten: Vector::<u32>::new(),
            cstamp: 0,
            la_dest: Vector::<u32>::new(),
            la_off: Vector::<i64>::new(),
            ll_dest: Vector::<u32>::new(),
            ll_pl: Vector::<u32>::new(),
        };
    }

    // ---- operand resolution --------------------------------------------------------------------

    /// Do two length-place identities name one length: the same place, heap and base generations,
    /// and no write into the place between their path generations?
    fn lp_same(self: &Self, b: &ir::CoreBody, x: &LenBind, y: &LenBind) bool {
        return (x.hg == y.hg || !self.fx.reachable(b, x.pl)) && x.bg == y.bg && self.fx.places_eq(b, x.pl, y.pl) && self.fx.path_alive(
            b,
            x.pl,
            x.pg,
            y.pg,
        ) && (x.fg == y.fg || !self.fx.resident(b, x.pl));
    }

    fn vkey(self: &Self, b: &ir::CoreBody, opid: u32) fx::VKey {
        return self.fx.vkey(b, opid);
    }

    /// `vkey` refusing any resolution step through a local reassigned inside the current coalescing
    /// window (its recorded binds describe its OLD value).
    fn vkey_c(self: &Self, b: &ir::CoreBody, opid: u32) fx::VKey {
        return self.fx.vkey_w(b, opid, &self.cwritten, self.cstamp, true);
    }

    /// A compile-time length for the measured place of a still-current length binding: the fixed
    /// extent of a raw array, or -1 when unknown.
    const fn const_len_of(self: &Self, b: &ir::CoreBody, l: u32) i64 {
        let lb = *self.lenof.at(l as usize);
        if !lb.ok || lb.my_v != self.fx.ver(l) || (lb.pl & fx::SYNTH_PL) != 0 {
            return 0 - 1;
        }
        let ty = b.places.at(lb.pl as usize).ty;
        if ty == TYPE_NONE {
            return 0 - 1;
        }
        let pk = unsafe &*self.fx.pkg;
        let y = *(unsafe &*pk.module_ast_const(b.module)).type_at(ty);
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() && y.as_data.arr.len != 0 {
            return y.as_data.arr.len;
        }
        return 0 - 1;
    }

    /// The len-place identity carried by a resolved local, when its binding is still current.
    const fn len_place_of(self: &Self, l: u32) LenBind {
        let lb = *self.lenof.at(l as usize);
        if lb.ok && lb.my_v == self.fx.ver(l) {
            return lb;
        }
        return lenbind_none();
    }

    /// The length identity of place `pl` read now (current generations), bound to local version
    /// `my_v`.
    const fn len_capture(self: &Self, b: &ir::CoreBody, pl: u32, my_v: u32) LenBind {
        return LenBind {
            pl: pl,
            hg: self.fx.heapgen,
            bg: self.fx.bgen(b.places.at(pl as usize).base),
            pg: self.fx.pgen[b.places.at(pl as usize).base as usize],
            fg: self.fx.bufgen,
            my_v: my_v,
            ok: true,
        };
    }

    /// A length-place identity for a comparison operand: a still-current length local (behind
    /// copies), or a direct `[r, deref, .len]` read of a prelude view whose base resolves through
    /// a current reference binding -- stamped with the CURRENT generations, because the read
    /// happens here.
    fn oper_len_lp(self: &mut Self, b: &ir::CoreBody, opid: u32) LenBind {
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return lenbind_none();
        }
        let l = self.fx.whole_local(b, op.data);
        if l != ir::IR_NONE {
            return self.len_place_of(self.fx.copy_root(l));
        }
        let p = *b.places.at(op.data as usize);
        if p.proj_len != 2 {
            return lenbind_none();
        }
        let pj0 = *b.projections.at(p.proj_start as usize);
        let pj1 = *b.projections.at((p.proj_start + 1) as usize);
        if pj0.kind != ir::PJ_DEREF || pj1.kind != ir::PJ_FIELD || pj1.data == ir::PJ_UNION_FIELD {
            return lenbind_none();
        }
        if !self.fx.is_prelude_field(b, pj0.ty, pj1.sub, "len") {
            return lenbind_none();
        }
        let rl = self.fx.copy_root(p.base);
        let rb = *self.fx.refof.at(rl as usize);
        if rb.ok && rb.my_v == self.fx.ver(rl) {
            return self.len_capture(b, rb.pl, 0);
        }
        // No reference binding (a &view parameter): the reference VALUE is the collection
        // identity. A synthetic id keys it; `bg` carries the root local's version so a reassign
        // of the reference kills the match.
        return LenBind {
            pl: fx::SYNTH_PL | rl,
            hg: self.fx.heapgen,
            bg: self.fx.ver(rl),
            pg: 0,
            fg: self.fx.bufgen,
            my_v: 0,
            ok: true,
        };
    }

    /// Prove `ik OP lk` (OP is < unless `need_le`, then <=) from the standing facts. The length
    /// side matches by value identity or by the captured place identity `l_lp`.
    fn fold_proved(self: &Self, b: &ir::CoreBody, ik: &fx::VKey, lk: &fx::VKey, l_lp: &LenBind, need_le: bool) bool {
        if !ik.is_const && !ik.is_local {
            return false;
        }
        for i in 0..self.facts.len() {
            let f = *self.facts.at(i);
            if f.kind != 0 && !need_le {
                continue; // a <= fact cannot prove strict <
            }
            if !self.idx_matches(&f, ik, true) {
                continue;
            }
            if lk.is_local && f.ln_ok && f.ln_l == lk.l && f.ln_v == lk.v && f.ln_off == lk.off {
                return true;
            }
            let flp = fact_lp(&f);
            if f.lp_ok && l_lp.ok && self.lp_same(b, l_lp, &flp) {
                return true;
            }
        }
        return false;
    }

    /// `@c.noreturn` on the callee decl: the call is a trap terminator.
    fn callee_noreturn(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.fx.pkg;
        if d.node == NODE_NONE || d.module as usize >= pk.modules.len() || !pk.modules.at(d.module as usize).has_ast {
            return false;
        }
        return unsafe (*pk.module_ast_const(d.module)).attr_of(d.node, AttrKind::ATTR_NORETURN) != null;
    }

    /// The panic-guard shape: from `blk0`, through at most four effect-free goto hops, every path
    /// ends in a trap (an unreachable terminator or a direct `@c.noreturn` call). Statements on
    /// the way may only be storage markers or pure whole-local RV_USE/RV_REF assigns.
    fn doomed_panic(self: &Self, b: &ir::CoreBody, blk0: u32) bool {
        let mut cur = blk0;
        let mut guard = 0;
        while guard < 4 {
            guard += 1;
            let bb = b.blocks.at(cur as usize);
            for si in 0..bb.stmt_len {
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
                    continue;
                }
                if s.kind != ir::ST_ASSIGN {
                    return false;
                }
                if b.places.at(s.place as usize).proj_len != 0 {
                    return false; // a memory write is a visible effect
                }
                let k = b.rvalues.at(s.rvalue as usize).kind;
                if k != ir::RV_USE && k != ir::RV_REF {
                    return false;
                }
            }
            let t = &bb.term;
            if t.kind == ir::TM_UNREACHABLE {
                return true;
            }
            if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && self.callee_noreturn(t.callee) {
                return true;
            }
            if t.kind == ir::TM_GOTO {
                cur = t.t0;
                continue;
            }
            return false;
        }
        return false;
    }

    // ---- fact recording ------------------------------------------------------------------------

    fn push_fact(self: &mut Self, f: Fact) {
        if self.facts.len() >= MAX_EDGE_FACTS || self.total_facts >= MAX_TOTAL_FACTS {
            self.limited = true;
            return;
        }
        self.total_facts += 1;
        self.facts.push(f);
    }

    fn fact_from_check(self: &mut Self, b: &ir::CoreBody, kind: u8, ik: fx::VKey, lop: u32) {
        if !ik.is_const && !ik.is_local {
            return;
        }
        let lk = self.vkey(b, lop);
        let mut lp = lenbind_none();
        if lk.is_local && lk.off == 0 {
            lp = self.len_place_of(lk.l);
        }
        if !lk.is_local && !lk.is_const {
            return;
        }
        // constant lengths become (const idx-vs-const len) proofs only; keep the value identity
        self.push_fact(
            Fact {
                kind: kind,
                iconst: ik.is_const,
                ic: ik.c,
                il: ik.l,
                iv: ik.v,
                ioff: ik.off,
                ln_ok: lk.is_local,
                ln_l: lk.l,
                ln_v: lk.v,
                ln_off: lk.off,
                lp_ok: lp.ok,
                lp: lp.pl,
                lp_hg: lp.hg,
                lp_bg: lp.bg,
                lp_pg: lp.pg,
                lp_fg: lp.fg,
            },
        );
    }

    // ---- proofs --------------------------------------------------------------------------------

    const fn idx_matches(self: &Self, f: &Fact, ik: &fx::VKey, allow_smaller_const: bool) bool {
        if ik.is_const && f.iconst {
            if allow_smaller_const {
                return ik.c >= 0 && ik.c <= f.ic;
            }
            return ik.c == f.ic;
        }
        if ik.is_local && !f.iconst {
            // exact value identity only: equal (local, version, offset). An inequality between two
            // DIFFERENT offsets is never derived -- the smaller sum may still wrap past the larger.
            return f.il == ik.l && f.iv == ik.v && f.ioff == ik.off;
        }
        return false;
    }

    /// Does a recorded fact still say `len` (the current check's length operand) names the same
    /// value the fact captured?
    fn len_matches(self: &mut Self, b: &ir::CoreBody, f: &Fact, lop: u32) bool {
        let lk = self.vkey(b, lop);
        if lk.is_local && f.ln_ok && f.ln_l == lk.l && f.ln_v == lk.v && f.ln_off == lk.off {
            return true;
        }
        if lk.is_local && lk.off == 0 && f.lp_ok {
            let lp = self.len_place_of(lk.l);
            let flp = fact_lp(f);
            if lp.ok && self.lp_same(b, &lp, &flp) {
                return true;
            }
        }
        return false;
    }

    /// Prove `index < length` for one IN_BOUNDS site. Returns true when removable; fills the
    /// retained reason otherwise.
    fn prove_elem(self: &mut Self, b: &ir::CoreBody, iop: u32, lop: u32, reason: &mut u8) bool {
        let ik = self.vkey(b, iop);
        let lk = self.vkey(b, lop);
        if ik.is_const && lk.is_const {
            if ik.c >= 0 && lk.c >= 0 && ik.c < lk.c {
                return true;
            }
            *reason = BR_OVERFLOW_UNKNOWN; // a constant check that can fail must fail at runtime
            return false;
        }
        if !ik.is_const && !ik.is_local {
            *reason = BR_UNKNOWN_INDEX;
            return false;
        }
        for i in 0..self.facts.len() {
            let f = *self.facts.at(i);
            if f.kind != 0 {
                continue;
            }
            if self.idx_matches(&f, &ik, true) && self.len_matches(b, &f, lop) {
                return true;
            }
        }
        // the second source: the solved integer facts
        if self.prove_aligned(b, &ik, lop) {
            return true; // a relational chain, with the strides known so far
        }
        if !self.ints_for(b, lop) {
            // nothing to solve
        } else if self.int_le(b, iop, lop, true) {
            return true;
        } else if self.int_len_bound(b, iop, lop, true) {
            return true;
        } else if self.prove_aligned(b, &ik, lop) {
            return true;
        }
        if self.limited || self.fx.ilimited {
            *reason = BR_RESOURCE_LIMIT;
            return false;
        }
        if !lk.is_local && !lk.is_const {
            *reason = BR_UNKNOWN_LENGTH;
            return false;
        }
        *reason = BR_UNKNOWN_INDEX;
        if ik.is_local {
            *reason = BR_JOIN_LOST_FACT;
        }
        if self.int_widened(b, iop) {
            *reason = BR_WIDENED;
        }
        return false;
    }

    /// Prove `start <= end <= len` for one IN_RANGE_BOUNDS site.
    fn prove_range(self: &mut Self, b: &ir::CoreBody, sop: u32, eop: u32, lop: u32, reason: &mut u8) bool {
        let sk = self.vkey(b, sop);
        let ek = self.vkey(b, eop);
        let lk = self.vkey(b, lop);
        // full-view and constant forms: start <= end from const/identity, end <= len from identity
        let mut e_le_l = false;
        if ek.is_local && lk.is_local && ek.l == lk.l && ek.v == lk.v && ek.off == lk.off {
            e_le_l = true; // end IS the length value
        } else if ek.is_const && lk.is_const && ek.c >= 0 && ek.c <= lk.c {
            e_le_l = true;
        } else if ek.is_local && lk.is_local && ek.off == 0 && lk.off == 0 {
            // both carry the same still-current length-place identity
            let ep = self.len_place_of(ek.l);
            let lp = self.len_place_of(lk.l);
            if ep.ok && lp.ok && self.lp_same(b, &ep, &lp) {
                e_le_l = true;
            }
        } else if ek.is_const && lk.is_local && lk.off == 0 {
            // a constant end against the fixed extent of a raw array
            let cl = self.const_len_of(b, lk.l);
            if cl >= 0 && ek.c >= 0 && ek.c <= cl {
                e_le_l = true;
            }
        }
        if !e_le_l {
            // a fact recorded by an earlier equal-or-stronger range check
            for i in 0..self.facts.len() {
                let f = *self.facts.at(i);
                if f.kind == 1 && self.idx_matches(&f, &ek, true) && self.len_matches(b, &f, lop) {
                    e_le_l = true;
                    break;
                }
            }
        }
        if !e_le_l {}
        if !e_le_l && !(self.ints_for(b, lop) && (self.int_le(b, eop, lop, false) || self.int_len_bound(
            b,
            eop,
            lop,
            false,
        ))) {
            *reason = BR_UNKNOWN_LENGTH;
            return false;
        }
        let mut s_le_e = false;
        if sk.is_const && sk.c == 0 {
            s_le_e = true;
        } else if sk.is_const && ek.is_const && sk.c >= 0 && sk.c <= ek.c {
            s_le_e = true;
        } else if sk.is_local && ek.is_local && sk.l == ek.l && sk.v == ek.v && sk.off == ek.off {
            s_le_e = true;
        }
        if !s_le_e && !(self.ints_for(b, lop) && self.int_le(b, sop, eop, false)) {
            *reason = BR_UNKNOWN_INDEX;
            return false;
        }
        return true;
    }

    /// Do the solved integer facts prove `x < y` (`strict`) or `x <= y` here?
    fn int_le(self: &Self, b: &ir::CoreBody, xop: u32, yop: u32, strict: bool) bool {
        let mut xw: u32 = 0;
        let mut xs = false;
        let mut yw: u32 = 0;
        let mut ys = false;
        let x = self.fx.ival(b, xop, &mut xw, &mut xs);
        let y = self.fx.ival(b, yop, &mut yw, &mut ys);
        if xw == 0 || yw == 0 || xs || ys || x.hn || y.ln {
            return false;
        }
        if strict {
            return x.hi < y.lo;
        }
        return x.hi <= y.lo;
    }

    /// Did a loop-header widening change the index's interval?
    fn int_widened(self: &Self, b: &ir::CoreBody, iop: u32) bool {
        let mut w: u32 = 0;
        let mut sg = false;
        let f = self.fx.ival(b, iop, &mut w, &mut sg);
        return w != 0 && f.wid;
    }

    /// The stride and phase of the value (local `l`, version `v`): the solved facts when the version
    /// is current, or an alignment binding. (1, 0) when nothing is known.
    fn stride_of(self: &Self, l: u32, v: u32, st: &mut u64, ph: &mut u64) {
        *st = 1;
        *ph = 0;
        let ab = *self.alof.at(l as usize);
        if ab.st > 1 && ab.my_v == v {
            *st = ab.st;
            return;
        }
        if self.fx.ver(l) != v {
            return;
        }
        let f = self.fx.ilocal(l);
        let s = fx::istride(&f);
        if s == 1 {
            return;
        }
        *st = s;
        if s == 0 {
            *ph = f.lo; // exact: the phase is the value (a non-negative index)
            if f.ln {
                *st = 1;
            }
            return;
        }
        *ph = f.ph;
    }

    /// Prove `l + c < len` (the index key `ik`) from a fact `l < y` (or `l <= y`) and a fact `y <= len`
    /// (or `y < len`): `l` and `y` are multiples of a common stride A with the same phase, so `l < y`
    /// gives `l + c < y` for every `c < A`, with no wrap of `l + c`.
    fn prove_aligned(self: &mut Self, b: &ir::CoreBody, ik: &fx::VKey, lop: u32) bool {
        if !ik.is_local || ik.off < 0 {
            return false;
        }
        for i in 0..self.facts.len() {
            let f1 = *self.facts.at(i);
            if f1.iconst || f1.il != ik.l || f1.iv != ik.v || f1.ioff != 0 || !f1.ln_ok || f1.ln_off != 0 {
                continue;
            }
            let mut need_strict = false; // f2 must be y < len
            if f1.kind == 0 {
                if ik.off > 0 {
                    let mut sl: u64 = 1;
                    let mut pl: u64 = 0;
                    let mut sy: u64 = 1;
                    let mut py: u64 = 0;
                    self.stride_of(ik.l, ik.v, &mut sl, &mut pl);
                    self.stride_of(f1.ln_l, f1.ln_v, &mut sy, &mut py);
                    let mut a = fx::gcd(sl, sy);
                    if a == 0 || pl % a != py % a {
                        a = 1;
                    }
                    if ik.off as u64 >= a {
                        continue;
                    }
                }
            } else {
                if ik.off != 0 {
                    continue;
                }
                need_strict = true;
            }
            for j in 0..self.facts.len() {
                let f2 = *self.facts.at(j);
                if f2.iconst || f2.il != f1.ln_l || f2.iv != f1.ln_v || f2.ioff != 0 || need_strict && f2.kind != 0 {
                    continue;
                }
                if self.len_matches(b, &f2, lop) {
                    return true;
                }
            }
        }
        return false;
    }

    /// The receiver place behind the single `&self` argument of a len call, or IR_NONE. The
    /// argument may sit behind whole-local copies of the autoref temp.
    const fn len_call_receiver(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) u32 {
        let opid = b.oper_pool[t.args_start as usize];
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return ir::IR_NONE;
        }
        let l = self.fx.whole_local(b, op.data);
        if l != ir::IR_NONE {
            let rb = *self.fx.refof.at(l as usize);
            if rb.ok && rb.my_v == self.fx.ver(l) {
                return rb.pl;
            }
        }
        // the receiver reached the call as a direct place copy (by-value view or elided autoref):
        // that place IS the collection identity
        return op.data;
    }

    // ---- range-check coalescing ----------------------------------------------------------------

    // The absolute offset from coalescing root `ik` of operand `opid` (whole local `x`, IR_NONE
    // when it is none): an in-window alias of `x` first, else the operand's own clean chain.
    fn root_off(self: &mut Self, b: &ir::CoreBody, x: u32, opid: u32, ik: &fx::VKey, off: &mut i64) bool {
        if x != ir::IR_NONE {
            let mut q = self.la_dest.len();
            while q > 0 {
                q -= 1;
                if self.la_dest[q] == x {
                    *off = self.la_off[q];
                    return true;
                }
            }
        }
        let k = self.vkey_c(b, opid);
        if k.is_local && k.l == ik.l && k.v == ik.v {
            *off = k.off;
            return true;
        }
        return false;
    }

    /// Lookahead from the unproven element check at `si` for later checks over the same affine
    /// root and the same length value, separated only by statements that cannot write memory or
    /// panic. On a hit the CURRENT check is rewritten in place to IN_BOUNDS_GROUP covering the
    /// widest offset span (one stronger check at the first site; the members then prove against
    /// the per-offset facts recorded here). Returns the number of later member checks covered.
    fn try_coalesce(
        self: &mut Self,
        b: &mut ir::CoreBody,
        bb: &ir::BasicBlock,
        si: u32,
        rid: usize,
        iop: u32,
        lop: u32,
        sp: tok::Span,
    ) u32 {
        let ik = self.vkey(b, iop);
        if !ik.is_local {
            return 0;
        }
        let lk = self.vkey(b, lop);
        if !lk.is_const && !lk.is_local {
            return 0;
        }
        // the base length identity: a value key, plus a place identity when one is bound
        let mut lb = lenbind_none();
        if lk.is_local && lk.off == 0 {
            lb = self.len_place_of(lk.l);
        }
        self.cstamp += 1;
        // in-window definitions: affine aliases of the root (absolute offsets) and length copies
        self.la_dest.clear();
        self.la_off.clear();
        self.ll_dest.clear();
        self.ll_pl.clear();
        let mut maxoff = ik.off;
        let mut members: u32 = 0;
        let mut sj = si + 1;
        let scan_end = if bb.stmt_len > si + 48 {
            si + 48;
        } else {
            bb.stmt_len;
        };
        while sj < scan_end {
            let s2 = *b.statements.at((bb.stmt_start + sj) as usize);
            if s2.kind == ir::ST_STORAGE_LIVE {
                sj += 1;
                continue;
            }
            if s2.kind != ir::ST_ASSIGN {
                break;
            }
            let p2 = *b.places.at(s2.place as usize);
            if p2.proj_len != 0 {
                break; // an interior or deref write can alias the collection
            }
            if p2.base == ik.l || lk.is_local && p2.base == lk.l || lb.ok && p2.base == b.places.at(lb.pl as usize).base {
                break; // the root index, the length value, or the collection itself is redefined
            }
            // resolve one whole-local-copy operand to an absolute root offset, through the
            // in-window aliases first, then the clean pre-window chains
            let rv2 = *b.rvalues.at(s2.rvalue as usize);
            let k2 = rv2.kind;
            let mut bind_aff = false;
            let mut bind_off: i64 = 0;
            let mut bind_len = false;
            let mut bind_pl: u32 = 0;
            if k2 == ir::RV_INTRINSIC && rv2.c == ir::IN_BOUNDS {
                let iop2 = b.oper_pool[rv2.a as usize];
                let lop2 = b.oper_pool[(rv2.a + 1) as usize];
                let mut off2: i64 = 0;
                let o2 = *b.operands.at(iop2 as usize);
                let mut x = ir::IR_NONE;
                if o2.kind == ir::OP_COPY || o2.kind == ir::OP_MOVE {
                    x = self.fx.whole_local(b, o2.data);
                }
                let have2 = self.root_off(b, x, iop2, &ik, &mut off2);
                // length identity: same value key, or an in-window copy of the same length place
                let mut same_len = false;
                let k3 = self.vkey_c(b, lop2);
                if lk.is_const {
                    same_len = k3.is_const && k3.c == lk.c;
                } else if k3.is_local && k3.l == lk.l && k3.v == lk.v && k3.off == lk.off {
                    same_len = true;
                } else if lb.ok {
                    let o3 = *b.operands.at(lop2 as usize);
                    if o3.kind == ir::OP_COPY || o3.kind == ir::OP_MOVE {
                        let xl = self.fx.whole_local(b, o3.data);
                        if xl != ir::IR_NONE {
                            let mut q = self.ll_dest.len();
                            while q > 0 && !same_len {
                                q -= 1;
                                if self.ll_dest[q] == xl && self.fx.places_eq(b, self.ll_pl[q], lb.pl) {
                                    same_len = true;
                                }
                            }
                        }
                    }
                }
                if !have2 || !same_len || off2 < ik.off || off2 - ik.off >= 8 {
                    break; // an unrelated check is another possible panic: never move past it
                }
                if off2 > maxoff {
                    maxoff = off2;
                }
                members += 1;
                bind_aff = true; // the checked-index temp carries the member value
                bind_off = off2;
            } else if k2 == ir::RV_USE {
                let o2 = *b.operands.at(rv2.a as usize);
                if o2.kind == ir::OP_COPY || o2.kind == ir::OP_MOVE {
                    let x = self.fx.whole_local(b, o2.data);
                    if x != ir::IR_NONE {
                        bind_aff = self.root_off(b, x, rv2.a, &ik, &mut bind_off);
                        let mut q3 = self.ll_dest.len();
                        while q3 > 0 && !bind_len {
                            q3 -= 1;
                            if self.ll_dest[q3] == x {
                                bind_len = true;
                                bind_pl = self.ll_pl[q3];
                            }
                        }
                    }
                }
            } else if k2 == ir::RV_BINARY && (rv2.c == tt::TokenType::Plus as u8 || rv2.c == tt::TokenType::Minus as u8) {
                let ka = self.vkey_c(b, rv2.a);
                let kb = self.vkey_c(b, rv2.b);
                let ao = *b.operands.at(rv2.a as usize);
                let bo = *b.operands.at(rv2.b as usize);
                let mut basex = ir::IR_NONE;
                let mut ck: i64 = 0;
                let mut aside = false;
                if (ao.kind == ir::OP_COPY || ao.kind == ir::OP_MOVE) && kb.is_const {
                    basex = self.fx.whole_local(b, ao.data);
                    ck = if rv2.c == tt::TokenType::Plus as u8 {
                        kb.c;
                    } else {
                        0 - kb.c;
                    };
                    aside = true;
                } else if ka.is_const && rv2.c == tt::TokenType::Plus as u8 && (bo.kind == ir::OP_COPY || bo.kind == ir::OP_MOVE) {
                    basex = self.fx.whole_local(b, bo.data);
                    ck = ka.c;
                }
                if basex != ir::IR_NONE {
                    let side = if aside {
                        rv2.a;
                    } else {
                        rv2.b;
                    };
                    let mut baseoff: i64 = 0;
                    if self.root_off(b, basex, side, &ik, &mut baseoff) {
                        bind_aff = true;
                        bind_off = baseoff + ck;
                    }
                }
            } else if k2 == ir::RV_BINARY && (rv2.c == tt::TokenType::LessThan as u8 || rv2.c == tt::TokenType::LessThanEqual as u8) {
                // pure comparison
            } else if k2 == ir::RV_INTRINSIC && rv2.c == ir::IN_BOUNDS_PROVEN {
                // cannot panic
            } else if k2 == ir::RV_LEN {
                if lb.ok && self.fx.places_eq(b, rv2.a, lb.pl) {
                    bind_len = true;
                    bind_pl = rv2.a;
                }
            } else if k2 == ir::RV_REF || k2 == ir::RV_ADDR || k2 == ir::RV_DISCRIMINANT {
                // pure reads
            } else {
                break; // anything else may write memory, allocate, or panic
            }
            // a reassigned local no longer names its old value anywhere below
            self.cwritten.set(p2.base as usize, self.cstamp);
            let mut q2: usize = 0;
            while q2 < self.la_dest.len() {
                if self.la_dest[q2] == p2.base {
                    self.la_dest.set(q2, ir::IR_NONE);
                }
                q2 += 1;
            }
            q2 = 0;
            while q2 < self.ll_dest.len() {
                if self.ll_dest[q2] == p2.base {
                    self.ll_dest.set(q2, ir::IR_NONE);
                }
                q2 += 1;
            }
            if bind_aff && self.la_dest.len() < 16 {
                self.la_dest.push(p2.base);
                self.la_off.push(bind_off);
            }
            if bind_len && self.ll_dest.len() < 16 {
                self.ll_dest.push(p2.base);
                self.ll_pl.push(bind_pl);
            }
            sj += 1;
        }
        if members == 0 || maxoff <= ik.off {
            return 0;
        }
        // rewrite this check to the group form: (index, len, width)
        let w = maxoff - ik.off + 1;
        let ut = b.rvalues.at(rid).target;
        b.constants.push(
            ir::Constant { kind: ir::CK_INT, ty: ut, val: w, raw: sp, item: DefId { module: 0, node: NODE_NONE } },
        );
        b.operands.push(ir::Operand { kind: ir::OP_CONST, data: b.constants.len() as u32 - 1, ty: ut });
        let wop = b.operands.len() as u32 - 1;
        let start = b.oper_pool.len() as u32;
        b.oper_pool.push(iop);
        b.oper_pool.push(lop);
        b.oper_pool.push(wop);
        b.rvalues[rid].a = start;
        b.rvalues[rid].b = 3;
        b.rvalues[rid].c = ir::IN_BOUNDS_GROUP;
        // per-offset facts: the group proves root+k < len for every covered offset
        for k in 0..w {
            let mut ikk = ik;
            ikk.off = ik.off + k;
            self.fact_from_check(b, 0, ikk, lop);
        }
        return members;
    }
    /// DropCtx emits.
    // Push the true-edge fact of comparison `cb` with its right side read as `rk` (length place
    // `lp`), within the edge's fact budget (the edge's facts start at `st0`).
    fn edge_fact(self: &mut Self, cb: &CmpBind, rk: fx::VKey, lp: LenBind, st0: usize) {
        if self.in_facts.len() - st0 >= MAX_EDGE_FACTS {
            return;
        }
        self.in_facts.push(
            Fact {
                kind: if cb.le {
                    1;
                } else {
                    0;
                },
                iconst: cb.a.is_const,
                ic: cb.a.c,
                il: cb.a.l,
                iv: cb.a.v,
                ioff: cb.a.off,
                ln_ok: true,
                ln_l: rk.l,
                ln_v: rk.v,
                ln_off: rk.off,
                lp_ok: lp.ok,
                lp: lp.pl,
                lp_hg: lp.hg,
                lp_bg: lp.bg,
                lp_pg: lp.pg,
                lp_fg: lp.fg,
            },
        );
    }

    /// The short-circuit join `j` of `a && b` entered from `blk` (which computed `t = b`): `j` (and
    /// the single-predecessor gotos after it) only copy `t` and branch on it, and every other
    /// predecessor enters `j` on the false edge of a branch on `t`. Then the branch's true successor
    /// runs only after `blk` with `b` true: returns that successor (one predecessor, not yet filled)
    /// and sets `*tl` to `t`; IR_NONE else.
    fn and_join(self: &Self, b: &ir::CoreBody, blk: u32, j: u32, tl: &mut u32) u32 {
        if self.fx.fwd[j as usize] < 2 || self.fx.npred[j as usize] != self.fx.fwd[j as usize] {
            return ir::IR_NONE;
        }
        // the chain j -> k1 -> .. -> the branch block, through single-predecessor gotos
        let mut chain: [u32; 4] = [[0] = ir::IR_NONE];
        let mut nc: usize = 0;
        let mut cur = j;
        let mut found = false;
        for _h in 0..4 {
            unsafe chain[nc] = cur;
            nc += 1;
            let ct = b.blocks.at(cur as usize).term;
            if ct.kind != ir::TM_GOTO {
                found = true;
                break;
            }
            if self.fx.npred[ct.t0 as usize] != 1 {
                return ir::IR_NONE;
            }
            cur = ct.t0;
        }
        if !found {
            return ir::IR_NONE;
        }
        let jt = b.blocks.at(cur as usize).term;
        let tt9 = bool_target(b, &jt, true);
        if tt9 == ir::IR_NONE || self.fx.npred[tt9 as usize] != 1 || self.in_set[tt9 as usize] {
            return ir::IR_NONE;
        }
        let op = *b.operands.at(jt.a as usize);
        if op.kind == ir::OP_CONST {
            return ir::IR_NONE;
        }
        let mut u = self.fx.whole_local(b, op.data);
        if u == ir::IR_NONE {
            return ir::IR_NONE;
        }
        // back through the chain's copies; it writes no projected place and nothing but copies
        let mut ci = nc;
        while ci > 0 {
            ci -= 1;
            let jb = *b.blocks.at((unsafe chain[ci]) as usize);
            let mut si = jb.stmt_len;
            while si > 0 {
                si -= 1;
                let st = *b.statements.at((jb.stmt_start + si) as usize);
                if st.kind == ir::ST_STORAGE_LIVE || st.kind == ir::ST_STORAGE_DEAD && st.a != u {
                    continue;
                }
                if st.kind != ir::ST_ASSIGN || b.places.at(st.place as usize).proj_len != 0 {
                    return ir::IR_NONE;
                }
                let rv = *b.rvalues.at(st.rvalue as usize);
                if rv.kind != ir::RV_USE {
                    return ir::IR_NONE;
                }
                if b.places.at(st.place as usize).base != u {
                    continue; // another local's copy
                }
                let so = *b.operands.at(rv.a as usize);
                if so.kind == ir::OP_CONST || self.fx.whole_local(b, so.data) == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                u = self.fx.whole_local(b, so.data);
            }
        }
        // the chain must not write the branched-on local `u` itself
        for c2 in 0..nc {
            let jb = *b.blocks.at((unsafe chain[c2]) as usize);
            for k in 0..jb.stmt_len {
                let st = *b.statements.at((jb.stmt_start + k) as usize);
                if st.kind == ir::ST_ASSIGN && b.places.at(st.place as usize).base == u {
                    return ir::IR_NONE;
                }
            }
        }
        let fx9 = &self.fx;
        let mut n9 = 0;
        for k in fx9.pstart[j as usize]..fx9.pstart[j as usize + 1] {
            let p = fx9.plist[k as usize];
            if p == blk {
                n9 += 1;
                continue;
            }
            let pt = b.blocks.at(p as usize).term;
            if bool_target(b, &pt, false) != j || bool_target(b, &pt, true) == j {
                return ir::IR_NONE;
            }
            let po = *b.operands.at(pt.a as usize);
            if po.kind == ir::OP_CONST || self.fx.whole_local(b, po.data) != u {
                return ir::IR_NONE;
            }
        }
        if n9 != 1 {
            return ir::IR_NONE; // `blk` reaches the join once, by its goto
        }
        *tl = u;
        return tt9;
    }

    /// Do the facts at the end of `blk` flow into successor `s`: its only forward predecessor edge,
    /// not yet filled?
    const fn flows(self: &Self, blk: u32, s: u32) bool {
        return !self.in_set[s as usize] && self.fx.fwd[s as usize] == 1 && self.fx.rpo_of[blk as usize] < self.fx.rpo_of[s as usize];
    }

    /// Reset every per-body table for a fresh body; capacity persists across the bodies one
    /// DropCtx emits.
    fn begin_body(self: &mut Self, b: &ir::CoreBody, pkg: *const loader::Package) {
        let nl = b.locals.len();
        let nb = b.blocks.len();
        self.fx.begin(b, pkg);
        // the per-local bindings carry over: each names the version it was made at, below the floor
        // of every later body
        self.chunks.clear();
        self.lreads.clear();
        while self.lenof.len() < nl {
            self.lenof.push(lenbind_none());
            self.cmpof.push(
                CmpBind {
                    a: fx::vkey_none(),
                    b: fx::vkey_none(),
                    a_lp: lenbind_none(),
                    b_lp: lenbind_none(),
                    le: false,
                    my_v: 0,
                    ok: false,
                },
            );
            self.remof.push(RemBind { x: fx::vkey_none(), x_lp: lenbind_none(), c: 0, my_v: 0, ok: false });
            self.alof.push(AlBind { st: 0, my_v: 0 });
        }
        self.facts.clear();
        self.in_facts.clear();
        self.in_start.clear();
        self.in_start.resize_default(nb);
        self.in_len.clear();
        self.in_len.resize_default(nb);
        self.in_set.clear();
        self.in_set.resize_default(nb);
        self.total_facts = 0;
        self.limited = false;
        self.cwritten.clear();
        self.cwritten.resize_default(nl);
        self.cstamp = 0;
    }

    /// Record that local `l` (its current version) holds the length its binding names.
    fn note_read(self: &mut Self, l: u32) {
        if !self.iwant {
            return; // only an interval proof reads them
        }
        if self.lreads.len() >= LREADS_MAX {
            let _ = self.lreads.remove(0);
        }
        self.lreads.push(LRead { lb: *self.lenof.at(l as usize), l: l, v: self.fx.ver(l) });
    }

    /// Solve the integer facts now when a check with length operand `lop` could use them: its
    /// length is a fixed array's, or a length compared with a constant, or an alignment is bound.
    /// The scratch then holds the facts at the current statement.
    fn ints_for(self: &mut Self, b: &ir::CoreBody, lop: u32) bool {
        if self.fx.ion {
            return true;
        }
        if !self.iwant || self.itried {
            return false;
        }
        let mut go = self.ialign || self.fx.fixed_len(b, lop);
        if !go {
            let lk = self.vkey(b, lop);
            if lk.is_local && lk.off == 0 {
                let lp = self.len_place_of(lk.l);
                for i in 0..self.clens.len() {
                    if lp.ok && self.lp_same(b, &self.clens[i], &lp) {
                        go = true;
                        break;
                    }
                }
            }
        }
        if !go {
            return false;
        }
        self.itried = true;
        self.fx.solve(b);
        if self.fx.ion {
            self.fx.ireplay(b, self.cur_blk, self.cur_sid);
        }
        return self.fx.ion;
    }

    /// Prove `x < len` (`strict`) or `x <= len` from the solved interval of `x` and of an earlier
    /// read of the same length (same place, same generations, its local unchanged).
    fn int_len_bound(self: &Self, b: &ir::CoreBody, xop: u32, lop: u32, strict: bool) bool {
        let mut xw: u32 = 0;
        let mut xs = false;
        let x = self.fx.ival(b, xop, &mut xw, &mut xs);
        if xw == 0 || xs || x.hn {
            return false;
        }
        let lk = self.vkey(b, lop);
        if !lk.is_local || lk.off != 0 {
            return false;
        }
        let lp = self.len_place_of(lk.l);
        if !lp.ok {
            return false;
        }
        for i in 0..self.lreads.len() {
            let r = self.lreads[i];
            if self.fx.ver(r.l) != r.v || !self.lp_same(b, &r.lb, &lp) {
                continue;
            }
            let f = self.fx.ilocal(r.l);
            if !f.ln && (x.hi < f.lo || !strict && x.hi == f.lo) {
                return true;
            }
        }
        return false;
    }

    /// Two reads of one value: the same key, or the same length place at the same generations.
    fn same_value(self: &Self, b: &ir::CoreBody, x: &fx::VKey, xlp: &LenBind, a: &fx::VKey, alp: &LenBind) bool {
        if x.is_local && a.is_local && x.l == a.l && x.v == a.v && x.off == a.off {
            return true;
        }
        return xlp.ok && alp.ok && self.lp_same(b, xlp, alp);
    }

    /// Process statement `stm` (index `si` of block `bb`): prove its check, record what it binds,
    /// and apply its effect to the versions and the integer facts.
    fn statement(
        self: &mut Self,
        b: &mut ir::CoreBody,
        bb: &ir::BasicBlock,
        si: u32,
        st: &mut BceStats,
        check_only: bool,
        err: &mut str<'static>,
    ) {
        let sid = (bb.stmt_start + si) as usize;
        let stm = *b.statements.at(sid);
        if stm.kind != ir::ST_ASSIGN {
            self.fx.apply_stmt(b, &stm);
            self.fx.istep(b, sid);
            return;
        }
        let rid = stm.rvalue as usize;
        let rv = *b.rvalues.at(rid);
        let dest = self.fx.whole_local(b, stm.place);
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_BOUNDS_GROUP {
            let iop = b.oper_pool[rv.a as usize];
            let lop = b.oper_pool[(rv.a + 1) as usize];
            let wo = *b.operands.at(b.oper_pool[(rv.a + 2) as usize] as usize);
            let ik = self.vkey(b, iop);
            if ik.is_local && wo.kind == ir::OP_CONST {
                let wc = *b.constants.at(wo.data as usize);
                if wc.kind == ir::CK_INT && wc.val > 0 && wc.val <= 8 {
                    for k in 0..wc.val {
                        let mut ikk = ik;
                        ikk.off = ik.off + k;
                        self.fact_from_check(b, 0, ikk, lop);
                    }
                }
            }
        } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN) {
            let iop = b.oper_pool[rv.a as usize];
            let lop = b.oper_pool[(rv.a + 1) as usize];
            let mut reason: u8 = BR_UNKNOWN_INDEX;
            let proven = self.prove_elem(b, iop, lop, &mut reason);
            if check_only {
                if rv.c == ir::IN_BOUNDS_PROVEN && !proven {
                    *err = "bce: unprovable IN_BOUNDS_PROVEN";
                }
            } else {
                st.total += 1;
                if proven {
                    st.removed += 1;
                    b.rvalues[rid].c = ir::IN_BOUNDS_PROVEN;
                } else {
                    let mut grouped: u32 = 0;
                    if rv.c == ir::IN_BOUNDS {
                        grouped = self.try_coalesce(b, bb, si, rid, iop, lop, stm.span);
                    }
                    if grouped != 0 {
                        st.coalesced += grouped;
                    } else {
                        unsafe {
                            st.reasons[reason as usize] = st.reasons[reason as usize] + 1;
                        }
                    }
                }
            }
            // success establishes idx < len for later identical sites
            let ik = self.vkey(b, iop);
            self.fact_from_check(b, 0, ik, lop);
        } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS_PROVEN) {
            let sop = b.oper_pool[rv.a as usize];
            let eop = b.oper_pool[(rv.a + 1) as usize];
            let lop = b.oper_pool[(rv.a + 2) as usize];
            let mut reason: u8 = BR_UNKNOWN_INDEX;
            let proven = self.prove_range(b, sop, eop, lop, &mut reason);
            if check_only {
                if rv.c == ir::IN_RANGE_BOUNDS_PROVEN && !proven {
                    *err = "bce: unprovable IN_RANGE_BOUNDS_PROVEN";
                }
            } else {
                st.ranges_total += 1;
                if proven {
                    st.ranges_removed += 1;
                    b.rvalues[rid].c = ir::IN_RANGE_BOUNDS_PROVEN;
                } else {
                    unsafe {
                        st.reasons[reason as usize] = st.reasons[reason as usize] + 1;
                    }
                }
            }
            // success establishes end <= len
            let ek = self.vkey(b, eop);
            self.fact_from_check(b, 1, ek, lop);
        }
        // what the statement binds, read before its write
        let usz = rv.target == Ast::builtin(BuiltinType::BT_USIZE);
        let op9 = tt::TokenType::Percent as u8;
        let mut ck = fx::vkey_none(); // chunk end / comparison or remainder left side
        let mut ck2 = fx::vkey_none(); // comparison right side
        let mut lp1 = lenbind_none();
        let mut lp2 = lenbind_none();
        let mut le = false;
        let is_cmp = rv.kind == ir::RV_BINARY && (rv.c == tt::TokenType::LessThan as u8 || rv.c == tt::TokenType::LessThanEqual as u8 || rv.c == tt::TokenType::GreaterThan as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8);
        // the alignment pattern `a - a % c` exists only in a body with a remainder by a constant
        let is_rem = self.fx.grem && rv.kind == ir::RV_BINARY && (rv.c == op9 || rv.c == tt::TokenType::PercentEqual as u8) && usz;
        let is_sub = self.fx.grem && rv.kind == ir::RV_BINARY && (rv.c == tt::TokenType::Minus as u8 || rv.c == tt::TokenType::MinusEqual as u8) && usz;
        let mut flp = lenbind_none();
        if dest != ir::IR_NONE {
            if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_CHUNK {
                let eop = b.oper_pool[(rv.a + 1) as usize];
                ck = self.vkey(b, eop);
                lp1 = self.oper_len_lp(b, eop);
            } else if is_cmp {
                // canonical form: > and >= swap operands (a > b == b < a; a >= b == b <= a)
                let swap = rv.c == tt::TokenType::GreaterThan as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8;
                let aop = if swap {
                    rv.b;
                } else {
                    rv.a;
                };
                let bop = if swap {
                    rv.a;
                } else {
                    rv.b;
                };
                ck = self.vkey(b, aop);
                ck2 = self.vkey(b, bop);
                lp1 = self.oper_len_lp(b, aop);
                lp2 = self.oper_len_lp(b, bop);
                if self.iwant && self.clens.len() < LREADS_MAX {
                    if lp1.ok && self.fx.const_ge2(b, bop) {
                        self.clens.push(lp1);
                    } else if lp2.ok && self.fx.const_ge2(b, aop) {
                        self.clens.push(lp2);
                    }
                }
                le = rv.c == tt::TokenType::LessThanEqual as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8;
            } else if is_rem || is_sub {
                ck = self.vkey(b, rv.a);
                ck2 = self.vkey(b, rv.b);
                lp1 = self.oper_len_lp(b, rv.a);
            } else if rv.kind == ir::RV_USE {
                // a direct `[r, deref, .len]` read of a prelude view is a length capture: the
                // inlined std `len()` body reads the field where the call read the method
                let op = *b.operands.at(rv.a as usize);
                if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && self.fx.whole_local(b, op.data) == ir::IR_NONE {
                    flp = self.oper_len_lp(b, rv.a);
                }
            }
        }
        // the write
        self.fx.apply_stmt(b, &stm);
        self.fx.istep(b, sid);
        if dest == ir::IR_NONE {
            return;
        }
        let dv = self.fx.ver(dest);
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_CHUNK {
            self.chunks.push(ChunkBind { e: ck, e_lp: lp1, l: dest, my_v: dv });
        } else if rv.kind == ir::RV_LEN {
            self.lenof.set(dest as usize, self.len_capture(b, rv.a, dv));
            self.note_read(dest);
        } else if is_cmp {
            self.cmpof.set(dest as usize, CmpBind { a: ck, b: ck2, a_lp: lp1, b_lp: lp2, le: le, my_v: dv, ok: true });
        } else if is_rem {
            if ck2.is_const && ck2.c > 0 {
                self.remof.set(dest as usize, RemBind { x: ck, x_lp: lp1, c: ck2.c, my_v: dv, ok: true });
            }
        } else if is_sub {
            // `d = a - a % c`: d <= a and d is a multiple of c
            if ck2.is_local && ck2.off == 0 && ck.is_local {
                let rb = *self.remof.at(ck2.l as usize);
                if rb.ok && rb.my_v == ck2.v && self.same_value(b, &rb.x, &rb.x_lp, &ck, &lp1) {
                    self.alof.set(dest as usize, AlBind { st: rb.c as u64, my_v: dv });
                    self.ialign = true;
                    let mut lp = lenbind_none();
                    if ck.off == 0 {
                        lp = lp1;
                    }
                    self.push_fact(
                        Fact {
                            kind: 1,
                            iconst: false,
                            ic: 0,
                            il: dest,
                            iv: dv,
                            ioff: 0,
                            ln_ok: true,
                            ln_l: ck.l,
                            ln_v: ck.v,
                            ln_off: ck.off,
                            lp_ok: lp.ok,
                            lp: lp.pl,
                            lp_hg: lp.hg,
                            lp_bg: lp.bg,
                            lp_pg: lp.pg,
                            lp_fg: lp.fg,
                            lp_fg: lp.fg,
                        },
                    );
                }
            }
        } else if rv.kind == ir::RV_USE {
            if flp.ok {
                self.lenof.set(dest as usize, lenbind_at(flp, dv));
                self.note_read(dest);
                return;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let srcl = self.fx.whole_local(b, op.data);
                if srcl != ir::IR_NONE {
                    // a copy of a length keeps its place identity
                    let slb = self.len_place_of(srcl);
                    if slb.ok {
                        self.lenof.set(dest as usize, lenbind_at(slb, dv));
                        self.note_read(dest);
                    }
                }
            }
        }
    }
}

pub fn stats_line(st: &BceStats, out: &mut String) {
    out.push_str("bce total ");
    out.push_u64(st.total);
    out.push_str(" removed ");
    out.push_u64(st.removed);
    out.push_str(" ranges ");
    out.push_u64(st.ranges_total);
    out.push_str(" ranges_removed ");
    out.push_u64(st.ranges_removed);
    out.push_str(" coalesced ");
    out.push_u64(st.coalesced);
    out.push_str(" folded ");
    out.push_u64(st.folded);
    out.push_str(" sig_kept ");
    out.push_u64(st.sig_kept);
    out.push_str(" reasons");
    for i in 0..BR_COUNT {
        out.push_str(" ");
        out.push_u64(unsafe st.reasons[i]);
    }
}

/// Run BCE over one final elaborated body, rewriting provable checks to their PROVEN twins.
/// `z` is the emission-lifetime state pooled in the caller's DropCtx; every per-body table is
/// reset here. `check_only` re-proves instead: a PROVEN operation this pass cannot re-prove is
/// a compiler error (the SC_CORE_IR development verification), returned as a non-empty reason.
pub fn run(b: &mut ir::CoreBody, pkg: *const loader::Package, z: &mut Bce, st: &mut BceStats, check_only: bool) str<
    'static
> {
    if z.off {
        return "";
    }
    let nb = b.blocks.len();
    if nb == 0 {
        return "";
    }
    z.fx.pkg = pkg;
    // most bodies carry no checks at all: skip every allocation for them
    let mut checks = false;
    for i in 0..b.rvalues.len() {
        let k = b.rvalues.at(i);
        if k.kind == ir::RV_INTRINSIC && ir::is_check(k.c) {
            checks = true;
            break;
        }
    }
    let mut any = checks;
    if !any {
        // a fold candidate exists only where a panic sits: a direct @c.noreturn call terminator
        // (checked here so check-free bodies still skip the walk outright)
        for i in 0..nb {
            let t = &b.blocks.at(i).term;
            if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && z.callee_noreturn(t.callee) {
                any = true;
                break;
            }
        }
    }
    if !any {
        return "";
    }
    z.begin_body(b, pkg);
    // the integer facts serve only the checks, solved on demand: a body with no check allocates no
    // solver state
    z.iwant = checks && !z.no_int && z.fx.want_ints(b);
    z.itried = false;
    z.ialign = false;
    z.clens.clear();
    let mut err: str<'static> = "";
    for bi in 0..z.fx.rpo.len() {
        let blk = z.fx.rpo[bi] as usize;
        z.facts.clear();
        if z.in_set[blk] {
            let s0 = z.in_start[blk] as usize;
            for i in s0..s0 + z.in_len[blk] as usize {
                let f0 = z.in_facts[i];
                z.facts.push(f0);
            }
        }
        z.fx.enter_block(b, blk as u32);
        z.fx.ienter(b, blk as u32);
        let bb = *b.blocks.at(blk);
        z.cur_blk = blk as u32;
        for si in 0..bb.stmt_len {
            z.cur_sid = bb.stmt_start + si;
            z.statement(b, &bb, si, st, check_only, &mut err);
        }
        // terminator: panic-guard folding, then effects, then fact propagation
        let mut t = bb.term;
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 && b.switch_pool[t.sw_start as usize] >> 32 == 1 && t.a != ir::IR_NONE {
            let tt9 = (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32;
            let ft9 = t.t0;
            let ck = z.vkey(b, t.a);
            if ck.is_local && ck.off == 0 {
                let cb = *z.cmpof.at(ck.l as usize);
                if cb.ok && cb.my_v == ck.v {
                    // the condition is a canonical `a OP b`; a proof of it (or of its negation)
                    // whose doomed successor is a pure panic shape folds the branch away
                    let mut dir: u32 = 0;
                    if check_only || z.no_fold {
                        // no fold here: skip the proof
                    } else if z.fold_proved(b, &cb.a, &cb.b, &cb.b_lp, cb.le) {
                        dir = 1; // always true
                    } else if z.fold_proved(b, &cb.b, &cb.a, &cb.a_lp, !cb.le) {
                        dir = 2; // always false (the negation swaps sides and flips strictness)
                    }
                    if dir != 0 {
                        let doomed = if dir == 1 {
                            ft9;
                        } else {
                            tt9;
                        };
                        let survivor = if dir == 1 {
                            tt9;
                        } else {
                            ft9;
                        };
                        if z.doomed_panic(b, doomed) {
                            // the folded goto keeps the condition operand in `a`, the doomed block
                            // in args_start and the proof direction in args_len so SC_CORE_IR mode
                            // can re-prove the fold like a PROVEN check
                            t.kind = ir::TM_GOTO;
                            t.t0 = survivor;
                            t.args_start = doomed;
                            t.args_len = dir;
                            t.sw_len = 0;
                            b.blocks[blk].term = t;
                            st.folded += 1;
                        }
                    }
                }
            }
        } else if check_only && t.kind == ir::TM_GOTO && (t.args_len == 1 || t.args_len == 2) && t.a != ir::IR_NONE {
            // SC_CORE_IR re-proof of a folded site
            let ck = z.vkey(b, t.a);
            let mut ok9 = false;
            if ck.is_local && ck.off == 0 {
                let cb = *z.cmpof.at(ck.l as usize);
                if cb.ok && cb.my_v == ck.v {
                    ok9 = if t.args_len == 1 {
                        z.fold_proved(b, &cb.a, &cb.b, &cb.b_lp, cb.le);
                    } else {
                        z.fold_proved(b, &cb.b, &cb.a, &cb.a_lp, !cb.le);
                    };
                }
            }
            if !ok9 {
                err = "bce: unprovable fold";
            }
        }
        let mut recv = ir::IR_NONE;
        let pure = t.kind == ir::TM_CALL && t.intr == ir::CI_NONE && fx::is_prelude_len_call(pkg, b, &t);
        if pure {
            recv = z.len_call_receiver(b, &t);
        }
        if z.fx.apply_term(b, &t, pure) && !check_only {
            st.sig_kept += 1;
        }
        if recv != ir::IR_NONE {
            let dl = z.fx.whole_local(b, b.dest_pool[t.dests_start as usize]);
            if dl != ir::IR_NONE {
                z.lenof.set(dl as usize, z.len_capture(b, recv, z.fx.ver(dl)));
                z.note_read(dl);
            }
        }
        z.fx.leave_block(blk as u32);
        // facts flow along the edge into a block with one forward predecessor
        let mut succ0 = ir::IR_NONE;
        let mut succ_true = ir::IR_NONE;
        if t.kind == ir::TM_GOTO || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP || t.kind == ir::TM_ASSERT {
            succ0 = t.t0;
        } else if t.kind == ir::TM_SWITCH {
            succ0 = t.t0;
            succ_true = bool_target(b, &t, true);
            if succ_true == t.t0 {
                // `switch t [0 -> f] otherwise x`: the shared edge is the true one
                succ0 = bool_target(b, &t, false);
            }
        }
        if succ0 != ir::IR_NONE && z.flows(blk as u32, succ0) {
            z.in_start.set(succ0 as usize, z.in_facts.len() as u32);
            for i in 0..z.facts.len() {
                let f0 = *z.facts.at(i);
                z.in_facts.push(f0);
            }
            z.in_len.set(succ0 as usize, z.facts.len() as u32);
            z.in_set.set(succ0 as usize, true);
        }
        if succ_true != ir::IR_NONE && z.flows(blk as u32, succ_true) {
            let st0 = z.in_facts.len();
            for i in 0..z.facts.len() {
                let f0 = *z.facts.at(i);
                z.in_facts.push(f0);
            }
            let st_i = succ_true as usize;
            // the branch condition itself, on its true edge: `a < b` (or `a <= b`)
            let ck = z.vkey(b, t.a);
            if ck.is_local {
                let cb = *z.cmpof.at(ck.l as usize);
                if cb.ok && cb.my_v == ck.v && (cb.a.is_const || cb.a.is_local) && cb.b.is_local {
                    let lp = cb.b_lp; // captured at the comparison, so never stale here
                    z.edge_fact(&cb, cb.b, lp, st0);
                    if cb.b.off == 0 {
                        // `x < lim` with `lim = IN_CHUNK(i, e)`: also `x < e`
                        for ci in 0..z.chunks.len() {
                            let ch = z.chunks[ci];
                            if ch.l == cb.b.l && ch.my_v == cb.b.v && ch.e.is_local {
                                z.edge_fact(&cb, ch.e, ch.e_lp, st0);
                            }
                        }
                    }
                }
            }
            z.in_start.set(st_i, st0 as u32);
            z.in_len.set(st_i, (z.in_facts.len() - st0) as u32);
            z.in_set.set(st_i, true);
        }
        // `a && b`: the join's true edge is reachable with a true condition from this block only
        let mut tl = ir::IR_NONE;
        let tj = if t.kind == ir::TM_GOTO {
            z.and_join(b, blk as u32, t.t0, &mut tl);
        } else {
            ir::IR_NONE;
        };
        if tj != ir::IR_NONE {
            let st0 = z.in_facts.len();
            for i in 0..z.facts.len() {
                let f0 = *z.facts.at(i);
                z.in_facts.push(f0);
            }
            let tr = z.fx.copy_root(tl);
            let cb = *z.cmpof.at(tr as usize);
            if cb.ok && cb.my_v == z.fx.ver(tr) && (cb.a.is_const || cb.a.is_local) && cb.b.is_local {
                z.edge_fact(&cb, cb.b, cb.b_lp, st0);
            }
            z.in_start.set(tj as usize, st0 as u32);
            z.in_len.set(tj as usize, (z.in_facts.len() - st0) as u32);
            z.in_set.set(tj as usize, true);
        }
    }
    return err;
}
