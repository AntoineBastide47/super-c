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
// header's `index < length` branch fact reaches the loop body; an integer comparison's false edge
// gives the negated fact (`!(a < b)` is `b <= a`: an early-return guard), and a proof chains
// through up to two `x <= y` facts. The solved integer facts (intervals, strides) are the second
// proof source.
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
    pub sig_kept: u32, // calls the walk crossed without discarding collection facts (signature transparency)
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
pub struct Fact {
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
pub struct LenBind {
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
pub struct CmpBind {
    pub a: fx::VKey,
    pub b: fx::VKey,
    pub a_lp: LenBind,
    pub b_lp: LenBind,
    pub le: bool, // true: a <= b, false: a < b
    pub my_v: u32,
    pub ok: bool,
    // 0: the comparison. Else the binding of `IN_GROUP_FITS(a, b, w)`: true means `a + k < b` for
    // every k < w; false means nothing.
    pub w: i64,
    pub ao: u32, // a comparison's operands for `a` and `b` (IR_NONE for a group)
    pub bo: u32,
}
// `l = IN_CHUNK(i, e)` at version `my_v`: `l <= e`, so a branch fact `x < l` (or `x <= l`) also
// holds for `e`, whose key and length place are captured here. A strip-mined loop's body learns
// its index bound through this.
pub struct ChunkBind {
    pub e: fx::VKey,
    pub e_lp: LenBind,
    pub l: u32,
    pub my_v: u32,
}
// `l = x % c` (usize, c > 0) at version `my_v`: `x - l` is at most `x` and a multiple of `c`.
pub struct RemBind {
    pub x: fx::VKey,
    pub x_lp: LenBind,
    pub c: i64,
    pub my_v: u32,
    pub ok: bool,
}
// The value of a local at version `my_v` is a multiple of `st` (0: no binding).
pub struct AlBind {
    pub st: u64,
    pub my_v: u32,
}
// Local `l` at version `v` holds the length `lb` names: its solved interval bounds that length.
pub struct LRead {
    pub lb: LenBind,
    pub l: u32,
    pub v: u32,
}
const LREADS_MAX: usize = 16;

pub struct Bce {
    pub fx: fx::Facts,
    pub lenof: Vector<LenBind>,
    pub glp: LenBind, // a guard proof's length operand read in place: its place identity
    pub reads: Vector<u32>, // per local of the body: the operands that read it whole (`local_reads`; empty until asked)
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
    pub no_widen: bool,
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
    // Widening-lookahead scratch: the window's references (`rf_dest[i] = &rf_pl[i]`).
    pub rf_dest: Vector<u32>,
    pub rf_pl: Vector<u32>,
}

// The successor a two-way branch on a bool takes when the bool is `v`, or IR_NONE for another shape
// (`switch t [1 -> x] otherwise y` and `switch t [0 -> y] otherwise x` both branch to x on true).
const fn bool_target(b: &ir::CoreBody, t: &ir::Terminator, v: bool) u32 {
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
        let dis = stdlib::get_env("SC_BCE_DISABLE").unwrap_or(String::new());
        let d = dis.as_str();
        return Bce {
            fx: fx::Facts::new(d.contains("sig")),
            lenof: Vector::<LenBind>::with_capacity(fx::TABLE_MIN),
            glp: lenbind_none(),
            reads: Vector::<u32>::new(),
            cmpof: Vector::<CmpBind>::with_capacity(fx::TABLE_MIN),
            remof: Vector::<RemBind>::with_capacity(fx::TABLE_MIN),
            alof: Vector::<AlBind>::with_capacity(fx::TABLE_MIN),
            chunks: Vector::<ChunkBind>::new(),
            lreads: Vector::<LRead>::new(),
            iwant: false,
            itried: false,
            ialign: false,
            clens: Vector::<LenBind>::new(),
            cur_blk: 0,
            cur_sid: 0,
            facts: Vector::<Fact>::new(),
            in_facts: Vector::<Fact>::with_capacity(fx::TABLE_MIN),
            in_start: Vector::<u32>::with_capacity(fx::TABLE_MIN),
            in_len: Vector::<u32>::with_capacity(fx::TABLE_MIN),
            in_set: Vector::<bool>::with_capacity(fx::TABLE_MIN),
            total_facts: 0,
            limited: false,
            off: stdlib::env_is("SC_BCE", "0"),
            no_fold: d.contains("fold"),
            no_widen: d.contains("widen"),
            no_sig: d.contains("sig"),
            no_int: d.contains("int"),
            cwritten: Vector::<u32>::with_capacity(fx::TABLE_MIN),
            cstamp: 0,
            la_dest: Vector::<u32>::new(),
            la_off: Vector::<i64>::new(),
            ll_dest: Vector::<u32>::new(),
            ll_pl: Vector::<u32>::new(),
            rf_dest: Vector::<u32>::new(),
            rf_pl: Vector::<u32>::new(),
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

    const fn vkey(self: &Self, b: &ir::CoreBody, opid: u32) fx::VKey {
        return self.fx.vkey(b, opid);
    }

    /// `vkey` refusing any resolution step through a local reassigned inside the current coalescing
    /// window (its recorded binds describe its OLD value).
    const fn vkey_c(self: &Self, b: &ir::CoreBody, opid: u32) fx::VKey {
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
    /// copies), a read of a prelude view's `len` field in place, a direct `[r, deref, .len]` read
    /// of a prelude view whose base resolves through a current reference binding, or a read of any
    /// other integer field (a user container's length) -- stamped with the CURRENT generations,
    /// because the read happens here.
    fn oper_len_lp(self: &mut Self, b: &mut ir::CoreBody, opid: u32) LenBind {
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return lenbind_none();
        }
        let p = *b.places.at(op.data as usize);
        if p.proj_len == 0 {
            return self.len_place_of(self.fx.copy_root(p.base));
        }
        let last = *b.projections.at((p.proj_start + p.proj_len - 1) as usize);
        if last.kind != ir::PJ_FIELD || last.data == ir::PJ_UNION_FIELD {
            return lenbind_none();
        }
        let vt = if p.proj_len == 1 {
            b.locals.at(p.base as usize).ty;
        } else {
            b.projections.at((p.proj_start + p.proj_len - 2) as usize).ty;
        };
        if !self.fx.is_prelude_field(b, vt, last.sub, "len") {
            // The field place itself names the value: its generations end the identity at every
            // write that can reach it.
            if !self.int_ty(b, last.ty) {
                return lenbind_none();
            }
            return self.len_capture(b, op.data, 0);
        }
        if p.proj_len != 2 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
            // A `len` field read in place of a view (a spliced callee's `len()` reads its receiver's
            // field so when the receiver is the caller's place): a new place names the view, so its
            // length identity matches the view's `len` checks.
            b.places.push(ir::Place { base: p.base, proj_start: p.proj_start, proj_len: p.proj_len - 1, ty: vt });
            return self.len_capture(b, b.places.len() as u32 - 1, 0);
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
        // Zero is at most any unsigned value.
        if need_le && ik.is_const && ik.c == 0 && lk.is_local && lk.off == 0 {
            let t = b.locals.at(lk.l as usize).ty;
            if t != TYPE_NONE {
                let y = *(unsafe &*(&*self.fx.pkg).module_ast_const(b.module)).type_at(t);
                if y.kind == TypeKind::TYPE_BUILTIN && bt_is_unsigned(y.as_data.builtin) {
                    return true;
                }
            }
        }
        // A value is at most itself: the same value, or a read of the same length place.
        if need_le && ik.is_local && ik.off == 0 {
            if lk.is_local && lk.l == ik.l && lk.v == ik.v && lk.off == 0 {
                return true;
            }
            let ilp = self.len_place_of(ik.l);
            if ilp.ok && l_lp.ok && self.lp_same(b, &ilp, l_lp) {
                return true;
            }
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

    /// `@noreturn` on the callee decl: the call is a trap terminator.
    fn callee_noreturn(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.fx.pkg;
        if d.node == NODE_NONE || d.module as usize >= pk.modules.len() || !pk.modules.at(d.module as usize).has_ast {
            return false;
        }
        return unsafe (*pk.module_ast_const(d.module)).attr_of(d.node, AttrKind::ATTR_NORETURN) != null;
    }

    /// The panic-guard shape: from `blk0`, through at most four effect-free goto hops, every path
    /// ends in a trap (an unreachable terminator or a direct `@noreturn` call). Statements on
    /// the way may only be storage markers or pure whole-local RV_USE/RV_REF assigns and
    /// qualified type names (a message naming a type).
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
                let rv = b.rvalues.at(s.rvalue as usize);
                if rv.kind != ir::RV_USE && rv.kind != ir::RV_REF && !(rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_TYPE_NAME) {
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

    /// Can block `blk` fold: a branch of the fold shape with a pure panic successor?
    fn fold_site(self: &Self, b: &ir::CoreBody, blk: u32) bool {
        let t = &b.blocks.at(blk as usize).term;
        if t.kind != ir::TM_SWITCH || t.sw_len != 1 || t.a == ir::IR_NONE || b.switch_pool[t.sw_start as usize] >> 32 != 1 {
            return false;
        }
        return self.doomed_panic(b, (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32) || self.doomed_panic(
            b,
            t.t0,
        );
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
        // a view built by a struct literal: its length is the value its `len` holds
        if self.fx.views && f.ln_ok && f.ln_off == 0 {
            let vk = self.fx.view_len(b, lop);
            if vk.is_local && f.ln_l == vk.l && f.ln_v == vk.v {
                return true;
            }
        }
        if lk.is_local && lk.off == 0 && f.lp_ok {
            let lp = self.len_place_of(lk.l);
            let flp = fact_lp(f);
            if lp.ok && self.lp_same(b, &lp, &flp) {
                return true;
            }
        }
        // a length read in place (an inlined guard's `self.len`): its place identity
        if !lk.is_local && !lk.is_const && self.glp.ok && f.lp_ok {
            let flp = fact_lp(f);
            if self.lp_same(b, &self.glp, &flp) {
                return true;
            }
        }
        return false;
    }

    /// Does a chain of at most `hops + 1` facts `x <= y` (each over a whole value) lead from value
    /// `(l, v)` to the length operand `lop`? A guard (`if s.len() < n { return; }`) bounds a loop's
    /// limit this way.
    fn le_len(self: &mut Self, b: &ir::CoreBody, l: u32, v: u32, lop: u32, hops: u32) bool {
        for i in 0..self.facts.len() {
            let f = *self.facts.at(i);
            if f.iconst || f.il != l || f.iv != v || f.ioff != 0 {
                continue;
            }
            if self.len_matches(b, &f, lop) || hops != 0 && f.ln_ok && f.ln_off == 0 && self.le_len(
                b,
                f.ln_l,
                f.ln_v,
                lop,
                hops - 1,
            ) {
                return true;
            }
        }
        return false;
    }

    /// Is local `l` of an integer type? A float comparison's false edge gives no fact: a NaN makes
    /// both `a < b` and `b <= a` false.
    const fn int_local(self: &Self, b: &ir::CoreBody, l: u32) bool {
        return self.int_ty(b, b.locals.at(l as usize).ty);
    }

    const fn int_ty(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = *(unsafe &*(&*self.fx.pkg).module_ast_const(b.module)).type_at(t);
        return y.kind == TypeKind::TYPE_BUILTIN && bt_int_width(y.as_data.builtin, false) != 0;
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
        if lk.is_const && self.narrow_below(b, &ik, lk.c) {
            return true;
        }
        for i in 0..self.facts.len() {
            let f = *self.facts.at(i);
            if f.kind != 0 {
                continue;
            }
            if self.idx_matches(&f, &ik, true) && (self.len_matches(b, &f, lop) || f.ln_ok && f.ln_off == 0 && self.le_len(
                b,
                f.ln_l,
                f.ln_v,
                lop,
                1,
            )) {
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

    /// Is index `ik` an unsigned value of fewer bits cast up, whole, so that it stays below the
    /// constant length `len` (a `u8` index into 256 elements)?
    fn narrow_below(self: &Self, b: &ir::CoreBody, ik: &fx::VKey, len: i64) bool {
        if !ik.is_local || ik.off != 0 || ik.l as usize >= self.fx.ndef.len() || self.fx.ndef[ik.l as usize] != 1 {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(self.fx.def1[ik.l as usize] as usize).rvalue as usize);
        if rv.kind != ir::RV_CAST {
            return false;
        }
        let o = *b.operands.at(rv.a as usize);
        if o.ty == TYPE_NONE {
            return false;
        }
        let y = *(unsafe &*(&*self.fx.pkg).module_ast_const(b.module)).type_at(o.ty);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = y.as_data.builtin;
        let w = bt_int_width(bt, false);
        return (bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32) && w < 63 && 1i64 << w as i64 <= len;
    }

    /// Prove `start <= len && w <= len - start` for the group check of a vector access: its last lane
    /// `start + w - 1` is below the length, by the facts, the aligned strides or the intervals.
    fn prove_group(self: &mut Self, b: &ir::CoreBody, iop: u32, lop: u32, w: i64, reason: &mut u8) bool {
        let mut ik = self.vkey(b, iop);
        let lk = self.vkey(b, lop);
        if ik.is_const && lk.is_const {
            return ik.c >= 0 && lk.c >= 0 && ik.c <= lk.c && w <= lk.c - ik.c;
        }
        if !ik.is_local {
            return false;
        }
        ik.off += w - 1;
        for i in 0..self.facts.len() {
            let f = *self.facts.at(i);
            if f.kind == 0 && self.idx_matches(&f, &ik, true) && self.len_matches(b, &f, lop) {
                return true;
            }
        }
        if self.prove_aligned(b, &ik, lop) {
            return true;
        }
        if self.ints_for(b, lop) {
            let mut xw: u32 = 0;
            let mut xs = false;
            let mut yw: u32 = 0;
            let mut ys = false;
            let x = self.fx.ival(b, iop, &mut xw, &mut xs);
            let y = self.fx.ival(b, lop, &mut yw, &mut ys);
            if xw != 0 && yw != 0 && !xs && !ys && !x.hn && !y.ln && y.lo >= w as u64 && x.hi <= y.lo - w as u64 {
                return true;
            }
            if self.prove_aligned(b, &ik, lop) {
                return true;
            }
        }
        *reason = pick(self.limited || self.fx.ilimited, BR_RESOURCE_LIMIT, BR_JOIN_LOST_FACT);
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
    const fn stride_of(self: &Self, l: u32, v: u32, st: &mut u64, ph: &mut u64) {
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
                if self.len_matches(b, &f2, lop) || f2.ln_ok && f2.ln_off == 0 && self.le_len(
                    b,
                    f2.ln_l,
                    f2.ln_v,
                    lop,
                    1,
                ) {
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
    const fn root_off(self: &mut Self, b: &ir::CoreBody, x: u32, opid: u32, ik: &fx::VKey, off: &mut i64) bool {
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
    fn try_coalesce(self: &mut Self, b: &mut ir::CoreBody, bb: &ir::BasicBlock, si: u32, rid: usize, iop: u32, lop: u32) u32 {
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
                if rv2.item.node == ir::CHECK_LANES {
                    break; // a lane check keeps its own trap text
                }
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
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: w,
                raw: tok::Span::empty(),
                item: DefId { module: 0, node: NODE_NONE },
            },
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

    // ---- guard widening ------------------------------------------------------------------------

    // The block a panic-guard path from `blk0` ends in (the `doomed_panic` walk), or IR_NONE.
    const fn doomed_end(self: &Self, b: &ir::CoreBody, blk0: u32) u32 {
        let mut cur = blk0;
        for _h in 0..4 {
            let t = &b.blocks.at(cur as usize).term;
            if t.kind != ir::TM_GOTO {
                return cur;
            }
            cur = t.t0;
        }
        return ir::IR_NONE;
    }

    // The value operand `opid` names on the panic-guard path from `blk0`: a constant (its id), or the
    // qualified-name rvalue the path last assigned its whole local (its id, `is_rv` set). IR_NONE for
    // anything else.
    const fn path_value(self: &Self, b: &ir::CoreBody, blk0: u32, opid: u32, is_rv: &mut bool) u32 {
        *is_rv = false;
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            return op.data;
        }
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return ir::IR_NONE;
        }
        let x = self.fx.whole_local(b, op.data);
        if x == ir::IR_NONE {
            return ir::IR_NONE;
        }
        let mut found = ir::IR_NONE;
        let mut cur = blk0;
        for _h in 0..4 {
            let bb = b.blocks.at(cur as usize);
            for si in 0..bb.stmt_len {
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if s.kind != ir::ST_ASSIGN || self.fx.whole_local(b, s.place) != x {
                    continue;
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                found = ir::IR_NONE;
                *is_rv = false;
                if rv.kind == ir::RV_USE && b.operands.at(rv.a as usize).kind == ir::OP_CONST {
                    found = b.operands.at(rv.a as usize).data;
                } else if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_TYPE_NAME {
                    found = s.rvalue;
                    *is_rv = true;
                }
            }
            if bb.term.kind != ir::TM_GOTO {
                break;
            }
            cur = bb.term.t0;
        }
        return found;
    }

    /// Do the panic-guard paths from `d1` and `d2` fail alike: both end in an unreachable trap, or
    /// both call one `@noreturn` callee with equal constant arguments (one literal of one source, or
    /// the qualified name of one type)?
    fn same_panic(self: &Self, b: &ir::CoreBody, d1: u32, d2: u32) bool {
        let e1 = self.doomed_end(b, d1);
        let e2 = self.doomed_end(b, d2);
        if e1 == ir::IR_NONE || e2 == ir::IR_NONE {
            return false;
        }
        let t1 = b.blocks.at(e1 as usize).term;
        let t2 = b.blocks.at(e2 as usize).term;
        if t1.kind == ir::TM_UNREACHABLE && t2.kind == ir::TM_UNREACHABLE {
            return true;
        }
        if t1.kind != ir::TM_CALL || t2.kind != ir::TM_CALL || t1.callee.module != t2.callee.module || t1.callee.node != t2.callee.node || t1.args_len != t2.args_len {
            return false;
        }
        for k in 0..t1.args_len {
            let mut r1 = false;
            let mut r2 = false;
            let c1 = self.path_value(b, d1, b.oper_pool[(t1.args_start + k) as usize], &mut r1);
            let c2 = self.path_value(b, d2, b.oper_pool[(t2.args_start + k) as usize], &mut r2);
            if c1 == ir::IR_NONE || c2 == ir::IR_NONE || r1 != r2 {
                return false;
            }
            if r1 {
                if b.rvalues.at(c1 as usize).b != b.rvalues.at(c2 as usize).b {
                    return false;
                }
                continue;
            }
            let x = *b.constants.at(c1 as usize);
            let y = *b.constants.at(c2 as usize);
            if x.kind != y.kind || x.ty != y.ty || x.val != y.val {
                return false;
            }
            if x.kind == ir::CK_STR {
                // Two literals of one text (`val` keeps their form).
                if self.const_text(b, &x) != self.const_text(b, &y) {
                    return false;
                }
            } else if x.kind != ir::CK_INT && x.kind != ir::CK_BOOL && (x.raw.start != y.raw.start || x.raw.end != y.raw.end || x.item.module != y.item.module || x.item.node != y.item.node) {
                return false;
            }
        }
        return true;
    }

    // The source text of constant `c`: an inlined one spans the module its `item` names.
    const fn const_text(self: &Self, b: &ir::CoreBody, c: &ir::Constant) str {
        let m = if c.item.node != NODE_NONE {
            c.item.module;
        } else {
            b.module;
        };
        let src = unsafe (*self.fx.pkg).modules.at(m as usize).source.as_str();
        if c.raw.end < c.raw.start || c.raw.end as usize > src.len() {
            return "";
        }
        return src.slice(c.raw.start as usize, c.raw.end as usize);
    }

    // The local a length identity's place is based on.
    const fn lp_base(self: &Self, b: &ir::CoreBody, lb: &LenBind) u32 {
        if (lb.pl & fx::SYNTH_PL) != 0 {
            return lb.pl & ~fx::SYNTH_PL;
        }
        return b.places.at(lb.pl as usize).base;
    }

    // The statement of block `blk` that last assigns whole local `l`, or IR_NONE.
    const fn def_in(self: &Self, b: &ir::CoreBody, blk: u32, l: u32) u32 {
        let bb = b.blocks.at(blk as usize);
        let mut si = bb.stmt_len;
        while si > 0 {
            si -= 1;
            let s = *b.statements.at((bb.stmt_start + si) as usize);
            if s.kind == ir::ST_ASSIGN && self.fx.whole_local(b, s.place) == l {
                return bb.stmt_start + si;
            }
        }
        return ir::IR_NONE;
    }

    /// The panic guard block `blk` ends in, branching on the comparison statement `sid`: when one
    /// edge is a pure panic and the other needs a strict `index < len`, sets the index and length
    /// operands, the survivor and the doomed block, and `len_b` when the length is the canonical
    /// right side (`index < len`; else the guard panics on `len <= index`).
    fn guard_shape(
        self: &Self,
        b: &ir::CoreBody,
        blk: u32,
        sid: u32,
        iop: &mut u32,
        lop: &mut u32,
        surv: &mut u32,
        doom: &mut u32,
        len_b: &mut bool,
    ) bool {
        let t = b.blocks.at(blk as usize).term;
        let tt9 = (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32;
        let rv = *b.rvalues.at(b.statements.at(sid as usize).rvalue as usize);
        if rv.kind != ir::RV_BINARY {
            return false;
        }
        // canonical `ca OP cb` with OP in {<, <=}
        let swap = rv.c == tt::TokenType::GreaterThan as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8;
        let le = rv.c == tt::TokenType::LessThanEqual as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8;
        if !swap && !le && rv.c != tt::TokenType::LessThan as u8 {
            return false;
        }
        let ca = pick(swap, rv.b, rv.a);
        let cb = pick(swap, rv.a, rv.b);
        let d_false = self.doomed_panic(b, t.t0);
        let d_true = self.doomed_panic(b, tt9);
        if d_false && !d_true && !le {
            *iop = ca;
            *lop = cb;
            *surv = tt9;
            *doom = t.t0;
            *len_b = true;
            return true;
        }
        if d_true && !d_false && le {
            *iop = cb;
            *lop = ca;
            *surv = t.t0;
            *doom = tt9;
            *len_b = false;
            return true;
        }
        return false;
    }

    // How many operands read whole local `l`: counted once per body, since the run adds no operand
    // that reads a local and rewrites none.
    fn local_reads(self: &mut Self, b: &ir::CoreBody, l: u32) u32 {
        if self.reads.len() == 0 {
            self.reads.resize_default(b.locals.len());
            for i in 0..b.operands.len() {
                let op = *b.operands.at(i);
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    let x = b.places.at(op.data as usize).base as usize;
                    self.reads.set(x, self.reads[x] + 1);
                }
            }
        }
        return self.reads[l as usize];
    }

    // The place operand `opid` reads in place (a copy of a projected place), else IR_NONE.
    const fn in_place_read(self: &Self, b: &ir::CoreBody, opid: u32) u32 {
        let op = *b.operands.at(opid as usize);
        if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && b.places.at(op.data as usize).proj_len != 0 {
            return op.data;
        }
        return ir::IR_NONE;
    }

    /// One statement of a widening window: true when it writes no memory, cannot panic (the
    /// arithmetic `try_coalesce` crosses too) and redefines none of the index root `ik`, the length
    /// local `lk` and the locals `pr` the length read is based on. Records in-window affine aliases of
    /// the root (like `try_coalesce`), references, and copies of in-place reads.
    fn widen_step(self: &mut Self, b: &ir::CoreBody, s2: &ir::Statement, ik: &fx::VKey, lk: &fx::VKey, pr: &[u32; 3]) bool {
        if s2.kind == ir::ST_STORAGE_LIVE {
            return true;
        }
        let kept = |l: u32| l != ik.l && !(lk.is_local && l == lk.l) && l != pr[0] && l != pr[1] && l != pr[2];
        if s2.kind == ir::ST_STORAGE_DEAD {
            return kept(s2.a);
        }
        if s2.kind != ir::ST_ASSIGN {
            return false;
        }
        let p2 = *b.places.at(s2.place as usize);
        if p2.proj_len != 0 || !kept(p2.base) {
            return false;
        }
        let rv2 = *b.rvalues.at(s2.rvalue as usize);
        let k2 = rv2.kind;
        let mut bind_aff = false;
        let mut bind_off: i64 = 0;
        let mut bind_pl = ir::IR_NONE; // the place an in-place read copies
        let mut bind_rf = ir::IR_NONE; // the place a reference is taken of
        if k2 == ir::RV_USE {
            let o2 = *b.operands.at(rv2.a as usize);
            if o2.kind == ir::OP_COPY || o2.kind == ir::OP_MOVE {
                let x = self.fx.whole_local(b, o2.data);
                if x != ir::IR_NONE {
                    bind_aff = self.root_off(b, x, rv2.a, ik, &mut bind_off);
                    bind_pl = self.window_copy(&self.ll_dest, &self.ll_pl, x);
                    bind_rf = self.window_copy(&self.rf_dest, &self.rf_pl, x);
                } else {
                    bind_pl = o2.data;
                }
            }
        } else if k2 == ir::RV_REF {
            bind_rf = rv2.a;
        } else if k2 == ir::RV_BINARY && (rv2.c == tt::TokenType::Plus as u8 || rv2.c == tt::TokenType::Minus as u8) {
            let ka = self.vkey_c(b, rv2.a);
            let kb = self.vkey_c(b, rv2.b);
            let ao = *b.operands.at(rv2.a as usize);
            let bo = *b.operands.at(rv2.b as usize);
            let mut basex = ir::IR_NONE;
            let mut ck: i64 = 0;
            let mut side = rv2.a;
            if (ao.kind == ir::OP_COPY || ao.kind == ir::OP_MOVE) && kb.is_const {
                basex = self.fx.whole_local(b, ao.data);
                ck = pick(rv2.c == tt::TokenType::Plus as u8, kb.c, 0 - kb.c);
            } else if ka.is_const && rv2.c == tt::TokenType::Plus as u8 && (bo.kind == ir::OP_COPY || bo.kind == ir::OP_MOVE) {
                basex = self.fx.whole_local(b, bo.data);
                ck = ka.c;
                side = rv2.b;
            }
            let mut baseoff: i64 = 0;
            if basex != ir::IR_NONE && self.root_off(b, basex, side, ik, &mut baseoff) {
                bind_aff = true;
                bind_off = baseoff + ck;
            }
        } else if k2 == ir::RV_BINARY && (rv2.c == tt::TokenType::LessThan as u8 || rv2.c == tt::TokenType::LessThanEqual as u8 || rv2.c == tt::TokenType::GreaterThan as u8 || rv2.c == tt::TokenType::GreaterThanEqual as u8) {
            // a pure comparison
        } else if k2 == ir::RV_INTRINSIC && (rv2.c == ir::IN_BOUNDS_PROVEN || rv2.c == ir::IN_BOUNDS_GROUP_PROVEN || rv2.c == ir::IN_GROUP_FITS) {
            // cannot panic
        } else if k2 != ir::RV_ADDR && k2 != ir::RV_LEN && k2 != ir::RV_DISCRIMINANT {
            return false; // anything else may write memory, allocate, or panic
        }
        // a reassigned local no longer names its old value anywhere below
        self.cwritten.set(p2.base as usize, self.cstamp);
        for q in 0..self.la_dest.len() {
            if self.la_dest[q] == p2.base {
                self.la_dest.set(q, ir::IR_NONE);
            }
        }
        for q in 0..self.ll_dest.len() {
            if self.ll_dest[q] == p2.base {
                self.ll_dest.set(q, ir::IR_NONE);
            }
        }
        for q in 0..self.rf_dest.len() {
            if self.rf_dest[q] == p2.base {
                self.rf_dest.set(q, ir::IR_NONE);
            }
        }
        if bind_aff && self.la_dest.len() < 16 {
            self.la_dest.push(p2.base);
            self.la_off.push(bind_off);
        }
        if bind_pl != ir::IR_NONE && self.ll_dest.len() < 16 {
            self.ll_dest.push(p2.base);
            self.ll_pl.push(bind_pl);
        }
        if bind_rf != ir::IR_NONE && self.rf_dest.len() < 16 {
            self.rf_dest.push(p2.base);
            self.rf_pl.push(bind_rf);
        }
        return true;
    }

    // The place window table `dest`/`pl` binds local `x` to, else IR_NONE.
    const fn window_copy(self: &Self, dest: &Vector<u32>, pl: &Vector<u32>, x: u32) u32 {
        let mut q = dest.len();
        while q > 0 {
            q -= 1;
            if dest[q] == x {
                return pl[q];
            }
        }
        return ir::IR_NONE;
    }

    // Read place `pl` written from its root: when it first derefs a reference bound to `&q` (in the
    // window, else by the walk and not reassigned in the window), `q` with `skip` 1; else IR_NONE.
    const fn read_root(self: &Self, b: &ir::CoreBody, pl: u32, skip: &mut u32) u32 {
        *skip = 0;
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
            return ir::IR_NONE;
        }
        *skip = 1;
        let q = self.window_copy(&self.rf_dest, &self.rf_pl, p.base);
        if q != ir::IR_NONE {
            return q;
        }
        let rl = self.fx.copy_root(p.base);
        let rb = *self.fx.refof.at(rl as usize);
        if self.cwritten[p.base as usize] != self.cstamp && self.cwritten[rl as usize] != self.cstamp && rb.ok && rb.my_v == self.fx.ver(
            rl,
        ) && (rb.pl & fx::SYNTH_PL) == 0 {
            return rb.pl;
        }
        *skip = 0;
        return ir::IR_NONE;
    }

    // Projection `i` of read place `pl` written from its root `root` (IR_NONE: `pl` itself) past `skip`.
    const fn read_proj(self: &Self, b: &ir::CoreBody, root: u32, pl: u32, skip: u32, i: u32) ir::Projection {
        let n0 = if root == ir::IR_NONE {
            0u32;
        } else {
            b.places.at(root as usize).proj_len;
        };
        if i < n0 {
            return *b.projections.at((b.places.at(root as usize).proj_start + i) as usize);
        }
        return *b.projections.at((b.places.at(pl as usize).proj_start + skip + i - n0) as usize);
    }

    // The projection count of root `r` (IR_NONE: none).
    const fn root_len(self: &Self, b: &ir::CoreBody, r: u32) u32 {
        if r == ir::IR_NONE {
            return 0;
        }
        return b.places.at(r as usize).proj_len;
    }

    /// Do read places `p1` and `p2` name one place once each is written from its root: one base local
    /// and equal projections (no dynamic index)?
    fn same_read(self: &Self, b: &ir::CoreBody, p1: u32, p2: u32) bool {
        let mut s1: u32 = 0;
        let mut s2: u32 = 0;
        let r1 = self.read_root(b, p1, &mut s1);
        let r2 = self.read_root(b, p2, &mut s2);
        let base1 = b.places.at(pick(r1 == ir::IR_NONE, p1, r1) as usize).base;
        let base2 = b.places.at(pick(r2 == ir::IR_NONE, p2, r2) as usize).base;
        let n1 = self.root_len(b, r1) + b.places.at(p1 as usize).proj_len - s1;
        let n2 = self.root_len(b, r2) + b.places.at(p2 as usize).proj_len - s2;
        if base1 != base2 || n1 != n2 {
            return false;
        }
        for i in 0..n1 {
            let x = self.read_proj(b, r1, p1, s1, i);
            let y = self.read_proj(b, r2, p2, s2, i);
            if x.kind != y.kind || x.kind == ir::PJ_INDEX_OP || x.data != y.data || x.sub != y.sub {
                return false;
            }
        }
        return true;
    }

    // The base locals read place `pl` depends on: its own base, and its root's (`read_root`).
    fn read_bases(self: &Self, b: &ir::CoreBody, pl: u32, pr: &mut [u32; 3]) {
        let mut sk: u32 = 0;
        let r = self.read_root(b, pl, &mut sk);
        pr[0] = b.places.at(pl as usize).base;
        pr[1] = if r == ir::IR_NONE {
            ir::IR_NONE;
        } else {
            b.places.at(r as usize).base;
        };
    }

    // The place length operand `lop` reads in place, through an in-window copy (`widen_step`), else
    // IR_NONE.
    const fn window_read(self: &Self, b: &ir::CoreBody, lop: u32) u32 {
        let r = self.in_place_read(b, lop);
        if r != ir::IR_NONE {
            return r;
        }
        let o = *b.operands.at(lop as usize);
        if o.kind != ir::OP_COPY && o.kind != ir::OP_MOVE {
            return ir::IR_NONE;
        }
        let x = self.fx.whole_local(b, o.data);
        if x == ir::IR_NONE {
            return ir::IR_NONE;
        }
        return self.window_copy(&self.ll_dest, &self.ll_pl, x);
    }

    // The place whole local `l` holds a read of, through the copies made of it in block `blk` and in
    // the blocks that reach it alone by a goto, when nothing after the read writes memory or a base
    // local the read depends on (`read_bases`); IR_NONE else.
    fn block_read(self: &Self, b: &ir::CoreBody, blk: u32, l: u32) u32 {
        let mut chain: [u32; 4] = [[0] = ir::IR_NONE]; // the blocks after `cur`, up to `blk`
        let mut nc: usize = 0;
        let mut cur = blk;
        let mut x = l;
        for _h in 0..8 {
            let sid = self.def_in(b, cur, x);
            if sid == ir::IR_NONE {
                // the read is in the one block that reaches `cur`, by a goto
                if nc == 4 || self.fx.npred[cur as usize] != 1 {
                    return ir::IR_NONE;
                }
                let pb = self.fx.plist[self.fx.pstart[cur as usize] as usize];
                let pt = b.blocks.at(pb as usize).term;
                if pt.kind != ir::TM_GOTO || pt.t0 != cur {
                    return ir::IR_NONE;
                }
                unsafe chain[nc] = cur;
                nc += 1;
                cur = pb;
                continue;
            }
            let rv = *b.rvalues.at(b.statements.at(sid as usize).rvalue as usize);
            if rv.kind != ir::RV_USE {
                return ir::IR_NONE;
            }
            let pl = self.in_place_read(b, rv.a);
            if pl == ir::IR_NONE {
                let o = *b.operands.at(rv.a as usize);
                if o.kind != ir::OP_COPY && o.kind != ir::OP_MOVE {
                    return ir::IR_NONE;
                }
                x = self.fx.whole_local(b, o.data);
                if x == ir::IR_NONE {
                    return ir::IR_NONE;
                }
                continue;
            }
            let mut pr: [u32; 3] = [[0] = ir::IR_NONE];
            self.read_bases(b, pl, &mut pr);
            let bb = b.blocks.at(cur as usize);
            if !self.no_write_since(b, sid + 1, bb.stmt_start + bb.stmt_len, &pr) {
                return ir::IR_NONE;
            }
            for c in 0..nc {
                let cb = b.blocks.at((unsafe chain[c]) as usize);
                if !self.no_write_since(b, cb.stmt_start, cb.stmt_start + cb.stmt_len, &pr) {
                    return ir::IR_NONE;
                }
            }
            return pl;
        }
        return ir::IR_NONE;
    }

    // Do statements `lo..hi` write no memory and none of the locals `pr`?
    const fn no_write_since(self: &Self, b: &ir::CoreBody, lo: u32, hi: u32, pr: &[u32; 3]) bool {
        for k in lo..hi {
            let s = *b.statements.at(k as usize);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let wp = b.places.at(s.place as usize);
            if wp.proj_len != 0 || wp.base == pr[0] || wp.base == pr[1] {
                return false;
            }
        }
        return true;
    }

    /// Guard widening. Block `blk` ends in a panic guard on local `cl` (comparison `cb`, unproven)
    /// whose survivor needs `index < len`. Lookahead along the survivor for later guards
    /// `root + k < len` over the same root and the same length that panic alike, separated only by
    /// statements `widen_step` accepts. On a hit the guard's comparison becomes
    /// `IN_GROUP_FITS(index, len, width)` over the widest offset and keeps its panic: a member that
    /// would fail panics with the same panic, only before pure statements. The true edge then
    /// proves every member, which folds. Returns the number of members.
    fn try_widen(self: &mut Self, b: &mut ir::CoreBody, blk: u32, cl: u32, cb: &CmpBind) u32 {
        let sid = self.def_in(b, blk, cl);
        if sid == ir::IR_NONE || self.local_reads(b, cl) != 1 {
            return 0; // the branch must be the comparison's only reader
        }
        let mut iop = ir::IR_NONE;
        let mut lop = ir::IR_NONE;
        let mut surv = ir::IR_NONE;
        let mut doom = ir::IR_NONE;
        let mut len_b = false;
        if !self.guard_shape(b, blk, sid, &mut iop, &mut lop, &mut surv, &mut doom, &mut len_b) {
            return 0;
        }
        let ik = pick(len_b, cb.a, cb.b);
        let lk = pick(len_b, cb.b, cb.a);
        // a fresh window: no table of an earlier one (of this body or another) may answer for this one
        self.cstamp += 1;
        self.la_dest.clear();
        self.la_off.clear();
        self.ll_dest.clear();
        self.ll_pl.clear();
        self.rf_dest.clear();
        self.rf_pl.clear();
        // the length read in place, directly or by a copy this block made
        let mut lread = self.in_place_read(b, lop);
        let lo = *b.operands.at(lop as usize);
        if lread == ir::IR_NONE && (lo.kind == ir::OP_COPY || lo.kind == ir::OP_MOVE) && self.fx.whole_local(b, lo.data) != ir::IR_NONE {
            lread = self.block_read(b, blk, self.fx.whole_local(b, lo.data));
        }
        if !ik.is_local || !lk.is_const && !lk.is_local && lread == ir::IR_NONE {
            return 0;
        }
        let lb = pick(len_b, cb.b_lp, cb.a_lp);
        // the window keeps every local the length read depends on
        let mut pr: [u32; 3] = [[0] = ir::IR_NONE];
        if lread != ir::IR_NONE {
            self.read_bases(b, lread, &mut pr);
        }
        if lb.ok {
            pr[2] = self.lp_base(b, &lb);
        }
        let mut maxoff = ik.off;
        let mut members: u32 = 0;
        let mut cur = surv;
        let mut nst: u32 = 0;
        for _h in 0..16 {
            if cur == blk || self.fx.npred[cur as usize] != 1 {
                break;
            }
            let bb = *b.blocks.at(cur as usize);
            let mut clean = true;
            for si in 0..bb.stmt_len {
                nst += 1;
                let s2 = *b.statements.at((bb.stmt_start + si) as usize);
                if nst > 64 || !self.widen_step(b, &s2, &ik, &lk, &pr) {
                    clean = false;
                    break;
                }
            }
            if !clean {
                break;
            }
            let t2 = bb.term;
            if t2.kind == ir::TM_GOTO {
                cur = t2.t0;
                continue;
            }
            if t2.kind != ir::TM_SWITCH || t2.sw_len != 1 || t2.a == ir::IR_NONE || b.switch_pool[t2.sw_start as usize] >> 32 != 1 {
                break;
            }
            let o2 = *b.operands.at(t2.a as usize);
            if o2.kind != ir::OP_COPY && o2.kind != ir::OP_MOVE {
                break;
            }
            let c2 = self.fx.whole_local(b, o2.data);
            let sid2 = if c2 == ir::IR_NONE {
                ir::IR_NONE;
            } else {
                self.def_in(b, cur, c2);
            };
            let mut iop2 = ir::IR_NONE;
            let mut lop2 = ir::IR_NONE;
            let mut surv2 = ir::IR_NONE;
            let mut doom2 = ir::IR_NONE;
            let mut len_b2 = false;
            if sid2 == ir::IR_NONE || !self.guard_shape(
                b,
                cur,
                sid2,
                &mut iop2,
                &mut lop2,
                &mut surv2,
                &mut doom2,
                &mut len_b2,
            ) || !self.same_panic(b, doom, doom2) {
                break;
            }
            // the member's index: an affine offset of the root
            let mut off2: i64 = 0;
            let o3 = *b.operands.at(iop2 as usize);
            let mut x = ir::IR_NONE;
            if o3.kind == ir::OP_COPY || o3.kind == ir::OP_MOVE {
                x = self.fx.whole_local(b, o3.data);
            }
            if !self.root_off(b, x, iop2, &ik, &mut off2) || off2 < ik.off || off2 - ik.off >= 8 {
                break;
            }
            // its length: the same value, or the same place read again (the window wrote no memory
            // and kept the place's base)
            let k3 = self.vkey_c(b, lop2);
            let lread2 = self.window_read(b, lop2);
            let same_len = lk.is_const && k3.is_const && k3.c == lk.c || lk.is_local && k3.is_local && k3.l == lk.l && k3.v == lk.v && k3.off == lk.off || lread != ir::IR_NONE && lread2 != ir::IR_NONE && self.same_read(
                b,
                lread,
                lread2,
            );
            if !same_len {
                break;
            }
            if off2 > maxoff {
                maxoff = off2;
            }
            members += 1;
            cur = surv2;
        }
        if members == 0 || maxoff <= ik.off {
            return 0;
        }
        // the comparison becomes IN_GROUP_FITS(index, len, width); true is the survivor
        let w = maxoff - ik.off + 1;
        let ut = Ast::builtin(BuiltinType::BT_USIZE);
        b.constants.push(
            ir::Constant {
                kind: ir::CK_INT,
                ty: ut,
                val: w,
                raw: tok::Span::empty(),
                item: DefId { module: 0, node: NODE_NONE },
            },
        );
        b.operands.push(ir::Operand { kind: ir::OP_CONST, data: b.constants.len() as u32 - 1, ty: ut });
        let wop = b.operands.len() as u32 - 1;
        let start = b.oper_pool.len() as u32;
        b.oper_pool.push(iop);
        b.oper_pool.push(lop);
        b.oper_pool.push(wop);
        let rid = b.statements.at(sid as usize).rvalue as usize;
        let tgt = b.rvalues.at(rid).target;
        b.rvalues[rid] = ir::rv(ir::RV_INTRINSIC, start, 3, ir::IN_GROUP_FITS, tgt);
        let mut t = b.blocks.at(blk as usize).term;
        t.t0 = doom;
        b.switch_pool[t.sw_start as usize] = 1u64 << 32 | surv as u64;
        b.blocks[blk as usize].term = t;
        self.cmpof.set(
            cl as usize,
            CmpBind {
                a: ik,
                b: lk,
                a_lp: lenbind_none(),
                b_lp: lb,
                le: false,
                my_v: cb.my_v,
                ok: true,
                w: w,
                ao: ir::IR_NONE,
                bo: ir::IR_NONE,
            },
        );
        return members;
    }
    /// DropCtx emits.
    // Push the true-edge fact of comparison `cb` with its right side read as `rk` (length place
    // `lp`; a value key only when `rk` is a local), within the edge's fact budget (the edge's facts
    // start at `st0`).
    fn edge_fact(self: &mut Self, le: bool, ik: fx::VKey, rk: fx::VKey, lp: LenBind, st0: usize) {
        if self.in_facts.len() - st0 >= MAX_EDGE_FACTS {
            return;
        }
        self.in_facts.push(
            Fact {
                kind: if le {
                    1;
                } else {
                    0;
                },
                iconst: ik.is_const,
                ic: ik.c,
                il: ik.l,
                iv: ik.v,
                ioff: ik.off,
                ln_ok: rk.is_local,
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
                    w: 0,
                    ao: ir::IR_NONE,
                    bo: ir::IR_NONE,
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
    /// length is a fixed array's or a constant, or a length compared with a constant, or an alignment
    /// is bound.
    /// The scratch then holds the facts at the current statement.
    fn ints_for(self: &mut Self, b: &ir::CoreBody, lop: u32) bool {
        if self.fx.ion {
            return true;
        }
        if !self.iwant || self.itried {
            return false;
        }
        let mut go = self.ialign || self.fx.fixed_len(b, lop) || self.fx.const_ge2(b, lop);
        if !go {
            let lp = self.lop_place(b, lop);
            for i in 0..self.clens.len() {
                if lp.ok && self.lp_same(b, &self.clens[i], &lp) {
                    go = true;
                    break;
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
    /// The length place length operand `lop` reads: through its local, or in place as a guard's
    /// length operand (`glp`).
    fn lop_place(self: &Self, b: &ir::CoreBody, lop: u32) LenBind {
        let lk = self.vkey(b, lop);
        if lk.is_local && lk.off == 0 {
            return self.len_place_of(lk.l);
        }
        if !lk.is_local && !lk.is_const {
            return self.glp;
        }
        return lenbind_none();
    }

    fn int_len_bound(self: &Self, b: &ir::CoreBody, xop: u32, lop: u32, strict: bool) bool {
        let mut xw: u32 = 0;
        let mut xs = false;
        let x = self.fx.ival(b, xop, &mut xw, &mut xs);
        if xw == 0 || xs || x.hn {
            return false;
        }
        let lp = self.lop_place(b, lop);
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
        if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN) {
            let iop = b.oper_pool[rv.a as usize];
            let lop = b.oper_pool[(rv.a + 1) as usize];
            let wo = *b.operands.at(b.oper_pool[(rv.a + 2) as usize] as usize);
            let ik = self.vkey(b, iop);
            if rv.item.node == ir::CHECK_VEC {
                // A vector access's own check, provable like an element check of its last lane.
                let mut reason: u8 = BR_UNKNOWN_INDEX;
                let mut proven = false;
                if wo.kind == ir::OP_CONST {
                    let wc = *b.constants.at(wo.data as usize);
                    proven = wc.kind == ir::CK_INT && wc.val > 0 && self.prove_group(b, iop, lop, wc.val, &mut reason);
                }
                if check_only {
                    if rv.c == ir::IN_BOUNDS_GROUP_PROVEN && !proven {
                        *err = "bce: unprovable IN_BOUNDS_GROUP_PROVEN";
                    }
                } else {
                    st.total += 1;
                    if proven {
                        st.removed += 1;
                        b.rvalues[rid].c = ir::IN_BOUNDS_GROUP_PROVEN;
                    } else {
                        unsafe {
                            st.reasons[reason as usize] = st.reasons[reason as usize] + 1;
                        }
                    }
                }
            }
            if ik.is_local && wo.kind == ir::OP_CONST {
                let wc = *b.constants.at(wo.data as usize);
                // Each element's fact when the group is small; a wider vector access records its last
                // lane only, which proves the same access again.
                let mut k0 = wc.val;
                if wc.val <= 8 {
                    k0 = 0;
                } else if rv.item.node == ir::CHECK_VEC {
                    k0 = wc.val - 1;
                }
                if wc.kind == ir::CK_INT && wc.val > 0 {
                    for k in k0..wc.val {
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
                    // A lane check keeps its own trap text: it never joins a group.
                    if rv.c == ir::IN_BOUNDS && rv.item.node != ir::CHECK_LANES {
                        grouped = self.try_coalesce(b, bb, si, rid, iop, lop);
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
        let mut gw: i64 = 0; // an IN_GROUP_FITS width
        let mut cao = ir::IR_NONE; // a comparison's canonical operands
        let mut cbo = ir::IR_NONE;
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
            } else if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_GROUP_FITS {
                let lop = b.oper_pool[(rv.a + 1) as usize];
                let wo = *b.operands.at(b.oper_pool[(rv.a + 2) as usize] as usize);
                if wo.kind == ir::OP_CONST && b.constants.at(wo.data as usize).kind == ir::CK_INT {
                    ck = self.vkey(b, b.oper_pool[rv.a as usize]);
                    ck2 = self.vkey(b, lop);
                    lp2 = self.oper_len_lp(b, lop);
                    gw = b.constants.at(wo.data as usize).val;
                }
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
                cao = aop;
                cbo = bop;
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
        } else if is_cmp || gw > 0 {
            self.cmpof.set(
                dest as usize,
                CmpBind { a: ck, b: ck2, a_lp: lp1, b_lp: lp2, le: le, my_v: dv, ok: true, w: gw, ao: cao, bo: cbo },
            );
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
        // a fold candidate exists only where a panic sits: a direct @noreturn call terminator
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
    // the integer facts serve the checks and the panic guards, solved on demand: a body without a
    // length comparison they can use allocates no solver state
    z.iwant = !z.no_int && z.fx.want_ints(b);
    z.itried = false;
    z.ialign = false;
    z.clens.clear();
    z.reads.clear();
    let mut err: str<'static> = "";
    // Only a check or a fold candidate gets a result, and facts flow only forward: the walk ends
    // with the last block in reverse postorder that holds one. The SC_CORE_IR re-proof walks every
    // block, its folded sites included.
    let mut end = z.fx.rpo.len();
    while !check_only && end > 0 && end - 1 != z.fx.clast as usize && !z.fold_site(b, z.fx.rpo[end - 1]) {
        end -= 1;
    }
    for bi in 0..end {
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
                if cb.ok && cb.my_v == ck.v && cb.w == 0 {
                    // the condition is a canonical `a OP b`; a proof of it (or of its negation)
                    // whose doomed successor is a pure panic shape folds the branch away
                    let mut dir: u32 = 0;
                    if check_only || z.no_fold {
                        // no fold here: skip the proof
                    } else if z.fold_proved(b, &cb.a, &cb.b, &cb.b_lp, cb.le) {
                        dir = 1; // always true
                    } else if z.fold_proved(b, &cb.b, &cb.a, &cb.a_lp, !cb.le) {
                        dir = 2; // always false (the negation swaps sides and flips strictness)
                    } else if cb.ao != ir::IR_NONE {
                        // A strict comparison an element check's proof shows (the aligned strides, the
                        // solved intervals): `a < b`, or for `a <= b` its negation `b < a`.
                        let mut why: u8 = 0;
                        z.glp = if cb.le {
                            cb.a_lp;
                        } else {
                            cb.b_lp;
                        };
                        if !cb.le && z.prove_elem(b, cb.ao, cb.bo, &mut why) {
                            dir = 1;
                        } else if cb.le && z.prove_elem(b, cb.bo, cb.ao, &mut why) {
                            dir = 2;
                        }
                        z.glp = lenbind_none();
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
                    } else if !check_only && !z.no_fold && !z.no_widen {
                        let n9 = z.try_widen(b, blk as u32, ck.l, &cb);
                        if n9 != 0 {
                            st.coalesced += n9;
                            t = b.blocks[blk].term;
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
                    let mut why: u8 = 0;
                    if !ok9 && cb.ao != ir::IR_NONE {
                        z.glp = if cb.le {
                            cb.a_lp;
                        } else {
                            cb.b_lp;
                        };
                        ok9 = if t.args_len == 1 {
                            !cb.le && z.prove_elem(b, cb.ao, cb.bo, &mut why);
                        } else {
                            cb.le && z.prove_elem(b, cb.bo, cb.ao, &mut why);
                        };
                        z.glp = lenbind_none();
                    }
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
            let st0 = z.in_facts.len();
            for i in 0..z.facts.len() {
                let f0 = *z.facts.at(i);
                z.in_facts.push(f0);
            }
            // a branch condition on its false edge: `!(a < b)` is `b <= a`, `!(a <= b)` is `b < a`
            if succ_true != ir::IR_NONE {
                let ck = z.vkey(b, t.a);
                if ck.is_local {
                    let cb = *z.cmpof.at(ck.l as usize);
                    if cb.ok && cb.my_v == ck.v && cb.w == 0 && (cb.b.is_const || cb.b.is_local) && (cb.a.is_local && z.int_local(
                        b,
                        cb.a.l,
                    ) || !cb.a.is_local && cb.a_lp.ok) {
                        z.edge_fact(!cb.le, cb.b, cb.a, cb.a_lp, st0);
                    }
                }
            }
            z.in_start.set(succ0 as usize, st0 as u32);
            z.in_len.set(succ0 as usize, (z.in_facts.len() - st0) as u32);
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
                if cb.ok && cb.my_v == ck.v && cb.w > 0 && cb.a.is_local && (cb.b.is_local || cb.b_lp.ok) {
                    // a widened guard: every member offset is below the length
                    for k in 0..cb.w {
                        let mut ak = cb.a;
                        ak.off = cb.a.off + k;
                        z.edge_fact(false, ak, cb.b, cb.b_lp, st0);
                    }
                } else if cb.ok && cb.my_v == ck.v && cb.w == 0 && (cb.a.is_const || cb.a.is_local) && (cb.b.is_local || cb.b_lp.ok) {
                    let lp = cb.b_lp; // captured at the comparison, so never stale here
                    z.edge_fact(cb.le, cb.a, cb.b, lp, st0);
                    if cb.b.is_local && cb.b.off == 0 {
                        // `x < lim` with `lim = IN_CHUNK(i, e)`: also `x < e`
                        for ci in 0..z.chunks.len() {
                            let ch = z.chunks[ci];
                            if ch.l == cb.b.l && ch.my_v == cb.b.v && ch.e.is_local {
                                z.edge_fact(cb.le, cb.a, ch.e, ch.e_lp, st0);
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
            if cb.ok && cb.my_v == z.fx.ver(tr) && cb.w == 0 && (cb.a.is_const || cb.a.is_local) && cb.b.is_local {
                z.edge_fact(cb.le, cb.a, cb.b, cb.b_lp, st0);
            }
            z.in_start.set(tj as usize, st0 as u32);
            z.in_len.set(tj as usize, (z.in_facts.len() - st0) as u32);
            z.in_set.set(tj as usize, true);
        }
    }
    return err;
}
