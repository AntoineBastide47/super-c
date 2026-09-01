// Bounds-check elimination (plans/1_bounds_check_elimination.md): a local, near-linear proof pass
// over one final elaborated CoreBody. It rewrites IN_BOUNDS / IN_RANGE_BOUNDS operations to their
// PROVEN twins ONLY when the proof holds at the exact operation site; anything unknown, mutated,
// called-past, joined-away, or over-limit keeps its check. The pass owns its (tiny) control-flow
// facts -- it never imports the C emitter.
//
// Fact model (dense, per body): every value fact is keyed by (local, version) where the version
// bumps on any assignment to that local, so facts die with redefinition instead of a body-wide
// clear. Collection-length facts additionally key on (place structure, heap generation, base
// generation): any call, deref write, or asm bumps the heap generation, any direct write through a
// base local bumps that base's generation, and a stale generation silently misses. Facts flow only
// along edges into single-predecessor blocks (a join keeps nothing), which is exactly enough for
// the canonical indexed loop: the header's `index < length` branch fact reaches the loop body.
import ast::ast as *;
import lexer::token as tok;
import lexer::token_type as tt;
import ir::core as ir;
import module::loader as loader;
import stdlib;

// Retained-check reasons (report order).
pub const BR_UNKNOWN_INDEX: u8 = 0;
pub const BR_UNKNOWN_LENGTH: u8 = 1;
pub const BR_DIFFERENT_BASE: u8 = 2;
pub const BR_VALUE_REDEFINED: u8 = 3;
pub const BR_MAY_MUTATE_CALL: u8 = 4;
pub const BR_ALIAS_WRITE: u8 = 5;
pub const BR_OVERFLOW_UNKNOWN: u8 = 6;
pub const BR_JOIN_LOST_FACT: u8 = 7;
pub const BR_RESOURCE_LIMIT: u8 = 8;
pub const BR_COUNT: usize = 9;

pub struct BceStats {
    pub total: u32,
    pub removed: u32,
    pub ranges_total: u32,
    pub ranges_removed: u32,
    pub coalesced: u32,
    pub folded: u32,
    pub sig_kept: u32, // calls crossed without discarding collection facts (signature transparency)
    pub reasons: [u32; 9],
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
struct Fact {
    pub kind: u8,
    // index key: a constant or a (local, version) value plus an affine constant offset
    pub iconst: bool,
    pub ic: i64,
    pub il: u32,
    pub iv: u32,
    pub ioff: i64,
    // length value identity (local, version, affine offset)
    pub ln_ok: bool,
    pub ln_l: u32,
    pub ln_v: u32,
    pub ln_off: i64,
    // length place identity (structural place + generations at capture)
    pub lp_ok: bool,
    pub lp: u32,
    pub lp_hg: u32,
    pub lp_bg: u32,
}

// A resolved operand key: constant, or (local, version) + affine constant offset, or opaque.
// Two local keys with equal (l, v, off) name the SAME runtime value (identical expressions over
// the same definition), which stays true even when the addition wrapped -- the basis for every
// affine match below. No ordering is ever derived from two different offsets.
struct VKey {
    pub is_const: bool,
    pub c: i64,
    pub is_local: bool,
    pub l: u32,
    pub v: u32,
    pub off: i64,
}

const MAX_EDGE_FACTS: usize = 96;
const MAX_TOTAL_FACTS: usize = 16384;

/// LenBind.pl values with this bit set are SYNTHETIC identities: the low bits name the reference
/// LOCAL a `[r, deref, .len]` read routed through (no place for the collection exists in the
/// pool). Two synthetic identities match on equal ids; a synthetic never matches a real place.
const SYNTH_PL: u32 = 0x80000000u32;

// Per-local bindings, each stamped with the version of its OWNER local at definition time so a
// redefinition invalidates it without any sweep.
struct LenBind {
    pub pl: u32, // the measured place (structural identity)
    pub hg: u32,
    pub bg: u32,
    pub my_v: u32,
    pub ok: bool,
}
// Canonical comparison binding: every <, <=, > and >= records as `a OP b` with OP in {<, <=}
// (the operand pair swaps for > and >=). `a_lp`/`b_lp` are the sides' length-place identities
// captured AT THE COMPARISON (a still-current length local, or a direct prelude len-field read),
// so a later fold proof can match the side against a recorded length fact.
struct CmpBind {
    pub a: VKey,
    pub b: VKey,
    pub a_lp: LenBind,
    pub b_lp: LenBind,
    pub le: bool, // true: a <= b, false: a < b
    pub my_v: u32,
    pub ok: bool,
}
struct CopyBind {
    pub src: u32,
    pub src_v: u32,
    pub my_v: u32,
    pub ok: bool,
}
// dest = src + c (usize width only; c may be negative for a Minus form)
struct AffBind {
    pub src: u32,
    pub src_v: u32,
    pub c: i64,
    pub my_v: u32,
    pub ok: bool,
}
struct RefBind {
    pub pl: u32,
    pub my_v: u32,
    pub ok: bool,
}

pub struct Bce {
    pub pkg: *const loader::Package,
    pub lver: Vector<u32>,
    pub basegen: Vector<u32>,
    pub heapgen: u32,
    pub lenof: Vector<LenBind>,
    pub cmpof: Vector<CmpBind>,
    pub copyof: Vector<CopyBind>,
    pub affof: Vector<AffBind>,
    pub refof: Vector<RefBind>,
    pub facts: Vector<Fact>, // facts of the block being processed
    pub in_facts: Vector<Vector<Fact>>, // per block, filled by its single predecessor
    pub in_set: Vector<bool>,
    pub preds: Vector<u32>,
    pub rpo: Vector<u32>,
    pub total_facts: usize,
    pub limited: bool,
    pub off: bool, // SC_BCE=0
    pub dbg: bool, // SC_BCE_DBG
    pub no_dom: bool, // SC_BCE_DISABLE rule switches
    pub no_const: bool,
    pub no_loop: bool,
    pub no_range: bool,
    pub no_affine: bool,
    pub no_coalesce: bool,
    pub no_fold: bool,
    pub no_sig: bool,
    // Signature transparency state: a call keeps collection facts unless it can reach the
    // collection's header. `escroot`/`esclist` hold roots whose &mut or raw address escaped into
    // memory (killed at every kept boundary); `statics` holds LS_STATIC_REF locals (callees reach
    // statics freely); `pend_*` hold &mut borrow temps not yet consumed by a call terminator.
    // `escall` disables transparency for the rest of the body when provenance cannot be named.
    pub escall: bool,
    // Escape-collection pass marker: escapes in a loop body must be known before a transparency
    // decision in an earlier block that a later iteration reaches, so the walk runs twice and the
    // first pass only collects (no rewrites, no stats, no transparency).
    pub collecting: bool,
    pub escroot: Vector<bool>,
    pub esclist: Vector<u32>,
    pub statics: Vector<u32>,
    pub pend_t: Vector<u32>,
    pub pend_r: Vector<u32>,
    // Coalescing-lookahead scratch (per try_coalesce call; kept for capacity). `cwritten` marks
    // locals reassigned inside the window, whose recorded binds describe their OLD value.
    pub cwritten: Vector<bool>,
    pub la_dest: Vector<u32>,
    pub la_off: Vector<i64>,
    pub ll_dest: Vector<u32>,
    pub ll_pl: Vector<u32>,
}

extend Bce as Free {
    pub fn free(self: &mut Self) {
        self.lver.free();
        self.basegen.free();
        self.lenof.free();
        self.cmpof.free();
        self.copyof.free();
        self.affof.free();
        self.refof.free();
        self.facts.free();
        self.in_facts.free();
        self.in_set.free();
        self.preds.free();
        self.rpo.free();
        self.escroot.free();
        self.esclist.free();
        self.statics.free();
        self.pend_t.free();
        self.pend_r.free();
        self.cwritten.free();
        self.la_dest.free();
        self.la_off.free();
        self.ll_dest.free();
        self.ll_pl.free();
    }
}

const fn vkey_none() VKey {
    return VKey { is_const: false, c: 0, is_local: false, l: 0, v: 0, off: 0 };
}

const fn lenbind_none() LenBind {
    return LenBind { pl: 0, hg: 0, bg: 0, my_v: 0, ok: false };
}

extend Bce {
    /// Emission-lifetime state (one per DropCtx): the env switches read once, every per-body
    /// table kept for capacity. `run` resets what a body needs.
    pub fn new(pkg: *const loader::Package) Bce {
        let dis = stdlib::getenv("SC_BCE_DISABLE");
        let mut d = "";
        if dis != null {
            d = str::from_cstr(dis);
        }
        let e = stdlib::getenv("SC_BCE");
        return Bce {
            pkg: pkg,
            lver: Vector::<u32>::new(),
            basegen: Vector::<u32>::new(),
            heapgen: 0,
            lenof: Vector::<LenBind>::new(),
            cmpof: Vector::<CmpBind>::new(),
            copyof: Vector::<CopyBind>::new(),
            affof: Vector::<AffBind>::new(),
            refof: Vector::<RefBind>::new(),
            facts: Vector::<Fact>::new(),
            in_facts: Vector::<Vector<Fact>>::new(),
            in_set: Vector::<bool>::new(),
            preds: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            total_facts: 0,
            limited: false,
            off: e != null && str::from_cstr(e) == "0",
            dbg: stdlib::getenv("SC_BCE_DBG") != null,
            no_dom: d.contains("dom"),
            no_const: d.contains("const"),
            no_loop: d.contains("loop"),
            no_range: d.contains("range"),
            no_affine: d.contains("affine"),
            no_coalesce: d.contains("coalesce"),
            no_fold: d.contains("fold"),
            no_sig: d.contains("sig"),
            escall: false,
            collecting: false,
            escroot: Vector::<bool>::new(),
            esclist: Vector::<u32>::new(),
            statics: Vector::<u32>::new(),
            pend_t: Vector::<u32>::new(),
            pend_r: Vector::<u32>::new(),
            cwritten: Vector::<bool>::new(),
            la_dest: Vector::<u32>::new(),
            la_off: Vector::<i64>::new(),
            ll_dest: Vector::<u32>::new(),
            ll_pl: Vector::<u32>::new(),
        };
    }

    // ---- structural identity -------------------------------------------------------------------

    /// Exact structural place equality (base + full projection content). PJ_INDEX_OP compares its
    /// OperandId, so distinct dynamic indexes never merge -- conservative and sound.
    fn places_eq(self: &Self, b: &ir::CoreBody, p1: u32, p2: u32) bool {
        if p1 == p2 {
            return true;
        }
        if (p1 & SYNTH_PL) != 0 || (p2 & SYNTH_PL) != 0 {
            return false; // synthetic identities match only on equal ids (handled above)
        }
        let a = *b.places.at(p1 as usize);
        let c = *b.places.at(p2 as usize);
        if a.base != c.base || a.proj_len != c.proj_len {
            return false;
        }
        for i in 0..a.proj_len {
            let x = *b.projections.at((a.proj_start + i) as usize);
            let y = *b.projections.at((c.proj_start + i) as usize);
            if x.kind != y.kind || x.data != y.data || x.sub != y.sub {
                return false;
            }
        }
        return true;
    }

    // ---- operand resolution --------------------------------------------------------------------

    /// A whole-local place (no projections), or IR_NONE.
    fn whole_local(self: &Self, b: &ir::CoreBody, pl: u32) u32 {
        let p = *b.places.at(pl as usize);
        if p.proj_len != 0 {
            return ir::IR_NONE;
        }
        return p.base;
    }

    /// Resolve an operand to a value key, following at most four whole-local copies. With
    /// `clean`, any resolution step through a local marked in `cwritten` (reassigned inside a
    /// coalescing lookahead window, so its recorded binds describe its OLD value) is refused.
    fn vkey_w(self: &Self, b: &ir::CoreBody, opid: u32, clean: bool) VKey {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let cn = *b.constants.at(op.data as usize);
            if cn.kind == ir::CK_INT {
                return VKey { is_const: true, c: cn.val, is_local: false, l: 0, v: 0, off: 0 };
            }
            return vkey_none();
        }
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return vkey_none();
        }
        let mut l = self.whole_local(b, op.data);
        if l == ir::IR_NONE || clean && self.cwritten[l as usize] {
            return vkey_none();
        }
        let mut off: i64 = 0;
        let mut guard = 0;
        while guard < 6 {
            let cb = *self.copyof.at(l as usize);
            if cb.ok && cb.my_v == self.lver[l as usize] && self.lver[cb.src as usize] == cb.src_v && (!clean || !self.cwritten[cb.src as usize]) {
                l = cb.src;
                guard += 1;
                continue;
            }
            if !self.no_affine {
                let ab = *self.affof.at(l as usize);
                if ab.ok && ab.my_v == self.lver[l as usize] && self.lver[ab.src as usize] == ab.src_v && (!clean || !self.cwritten[ab.src as usize]) {
                    off = off + ab.c;
                    l = ab.src;
                    guard += 1;
                    continue;
                }
            }
            break;
        }
        return VKey { is_const: false, c: 0, is_local: true, l: l, v: self.lver[l as usize], off: off };
    }

    fn vkey(self: &Self, b: &ir::CoreBody, opid: u32) VKey {
        return self.vkey_w(b, opid, false);
    }

    /// A compile-time length for the measured place of a still-current length binding: the fixed
    /// extent of a raw array, or -1 when unknown.
    fn const_len_of(self: &Self, b: &ir::CoreBody, l: u32) i64 {
        let lb = *self.lenof.at(l as usize);
        if !lb.ok || lb.my_v != self.lver[l as usize] || (lb.pl & SYNTH_PL) != 0 {
            return 0 - 1;
        }
        let ty = b.places.at(lb.pl as usize).ty;
        if ty == TYPE_NONE {
            return 0 - 1;
        }
        let pk = unsafe &*self.pkg;
        let y = *(unsafe &*pk.module_ast_const(b.module)).type_at(ty);
        if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0 {
            return y.as_data.arr.len;
        }
        return 0 - 1;
    }

    /// The len-place identity carried by a resolved local, when its binding is still current.
    fn len_place_of(self: &Self, l: u32) LenBind {
        let lb = *self.lenof.at(l as usize);
        if lb.ok && lb.my_v == self.lver[l as usize] {
            return lb;
        }
        return lenbind_none();
    }

    /// The base local behind up to four still-current whole-local copies.
    fn copy_root(self: &Self, l0: u32) u32 {
        let mut l = l0;
        let mut guard = 0;
        while guard < 4 {
            let cb = *self.copyof.at(l as usize);
            if cb.ok && cb.my_v == self.lver[l as usize] && self.lver[cb.src as usize] == cb.src_v {
                l = cb.src;
                guard += 1;
                continue;
            }
            break;
        }
        return l;
    }

    /// Is `sub` the `len` field of the prelude view `view_ty` names? Sound because a place-identity
    /// match still requires the SAME place: the same place has one type, and every prelude view's
    /// `len()` returns exactly its `len` field.
    fn is_prelude_len_field(self: &Self, b: &ir::CoreBody, view_ty: TypeId, sub: NodeId) bool {
        if view_ty == TYPE_NONE || sub == NODE_NONE {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        let y = *da.type_at(view_ty);
        let mut m9: ModuleId = 0;
        if y.kind == TypeKind::TYPE_STRUCT {
            m9 = y.module;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            m9 = da.instance(y.as_data.inst).module;
        } else {
            return false;
        }
        if m9 as usize >= pk.modules.len() || !pk.modules.at(m9 as usize).prelude {
            return false;
        }
        let fa = unsafe &*pk.module_ast_const(m9);
        let fnode = fa.at_const(sub);
        if fnode.kind != NodeKind::NODE_FIELD {
            return false;
        }
        let ns = fa.at_const(fnode.as_data.field.name).as_data.name.text;
        let src = pk.modules.at(m9 as usize).source.as_str();
        return src.slice(ns.start as usize, ns.end as usize) == "len";
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
        let l = self.whole_local(b, op.data);
        if l != ir::IR_NONE {
            return self.len_place_of(self.copy_root(l));
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
        if !self.is_prelude_len_field(b, pj0.ty, pj1.sub) {
            return lenbind_none();
        }
        let rl = self.copy_root(p.base);
        let rb = *self.refof.at(rl as usize);
        if rb.ok && rb.my_v == self.lver[rl as usize] {
            return LenBind {
                pl: rb.pl,
                hg: self.heapgen,
                bg: self.basegen[b.places.at(rb.pl as usize).base as usize],
                my_v: 0,
                ok: true,
            };
        }
        // No reference binding (a &view parameter): the reference VALUE is the collection
        // identity. A synthetic id keys it; `bg` carries the root local's version so a reassign
        // of the reference kills the match.
        return LenBind { pl: SYNTH_PL | rl, hg: self.heapgen, bg: self.lver[rl as usize], my_v: 0, ok: true };
    }

    /// Prove `ik OP lk` (OP is < unless `need_le`, then <=) from the standing facts. The length
    /// side matches by value identity or by the captured place identity `l_lp`.
    fn fold_proved(self: &mut Self, b: &ir::CoreBody, ik: &VKey, lk: &VKey, l_lp: &LenBind, need_le: bool) bool {
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
            if f.lp_ok && l_lp.ok && l_lp.hg == f.lp_hg && l_lp.bg == f.lp_bg && self.places_eq(b, l_lp.pl, f.lp) {
                return true;
            }
        }
        return false;
    }

    /// `@c.noreturn` on the callee decl: the call is a trap terminator.
    fn callee_noreturn(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.pkg;
        if d.node == NODE_NONE || d.module as usize >= pk.modules.len() || !pk.modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = unsafe &*pk.module_ast_const(d.module);
        for k in 0..a.attrs.len() {
            let at = a.attrs.at(k);
            if at.owner == d.node && at.kind == AttrKind::ATTR_NORETURN as u8 {
                return true;
            }
        }
        return false;
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
                if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
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

    fn fact_from_check(self: &mut Self, b: &ir::CoreBody, kind: u8, ik: VKey, lop: u32) {
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
            },
        );
    }

    // ---- proofs --------------------------------------------------------------------------------

    const fn idx_matches(self: &Self, f: &Fact, ik: &VKey, allow_smaller_const: bool) bool {
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
            if lp.ok && lp.hg == f.lp_hg && lp.bg == f.lp_bg && self.places_eq(b, lp.pl, f.lp) {
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
        if ik.is_const && lk.is_const && !self.no_const {
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
        if !self.no_dom {
            for i in 0..self.facts.len() {
                let f = *self.facts.at(i);
                if f.kind != 0 {
                    continue;
                }
                if self.dbg {
                    eprint(
                        "bce-dbg: fact il={} iv={} ioff={} ln_l={} ln_v={} lnoff={} lp_ok={} | ik l={} v={} off={} loc={} | im={} lm={}\n",
                        f.il,
                        f.iv,
                        f.ioff,
                        f.ln_l,
                        f.ln_v,
                        f.ln_off,
                        f.lp_ok,
                        ik.l,
                        ik.v,
                        ik.off,
                        ik.is_local,
                        self.idx_matches(&f, &ik, true),
                        self.len_matches(b, &f, lop),
                    );
                }
                if self.idx_matches(&f, &ik, true) && self.len_matches(b, &f, lop) {
                    return true;
                }
            }
        }
        if self.dbg {
            eprint(
                "bce-dbg: no fact hit; facts={} ik loc={} l={} off={}\n",
                self.facts.len(),
                ik.is_local,
                ik.l,
                ik.off,
            );
        }
        if self.limited {
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
        return false;
    }

    /// Prove `start <= end <= len` for one IN_RANGE_BOUNDS site.
    fn prove_range(self: &mut Self, b: &ir::CoreBody, sop: u32, eop: u32, lop: u32, reason: &mut u8) bool {
        if self.no_range {
            *reason = BR_UNKNOWN_INDEX;
            return false;
        }
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
            if ep.ok && lp.ok && ep.hg == lp.hg && ep.bg == lp.bg && self.places_eq(b, ep.pl, lp.pl) {
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
        if !e_le_l {
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
        if !s_le_e {
            *reason = BR_UNKNOWN_INDEX;
            return false;
        }
        return true;
    }

    // ---- invalidation --------------------------------------------------------------------------

    fn bump_local(self: &mut Self, l: u32) {
        self.lver.set(l as usize, self.lver[l as usize] + 1);
    }

    fn write_place(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 {
            self.bump_local(p.base);
            return;
        }
        for i in 0..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                // a write through a reference can alias any collection
                self.heapgen += 1;
                return;
            }
        }
        // an interior write (field/index) through the base local
        self.basegen.set(p.base as usize, self.basegen[p.base as usize] + 1);
    }

    // ---- signature transparency ----------------------------------------------------------------

    /// The root local behind a place, through at most two current reference bindings: no deref
    /// resolves to the copy-rooted base local; a leading deref resolves through `refof`, and a
    /// reference with no binding (a parameter) is itself the root -- the identity the synthetic
    /// length path keys on. False when a deref sits behind other projections (a reference loaded
    /// from memory has no nameable owner here).
    fn root_of_place(self: &Self, b: &ir::CoreBody, pl0: u32, out: &mut u32) bool {
        let mut pl = pl0;
        let mut guard = 0;
        while guard < 3 {
            guard += 1;
            let p = *b.places.at(pl as usize);
            let mut deref = false;
            for i in 0..p.proj_len {
                if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                    if i != 0 {
                        return false;
                    }
                    deref = true;
                }
            }
            if !deref {
                // place identity keys on the base local itself (generations and places_eq use
                // the base index); a value-copy chain must not redirect the identity
                *out = p.base;
                return true;
            }
            let r = self.copy_root(p.base);
            let rb = *self.refof.at(r as usize);
            if rb.ok && rb.my_v == self.lver[r as usize] && (rb.pl & SYNTH_PL) == 0 {
                pl = rb.pl;
                continue;
            }
            *out = r;
            return true;
        }
        return false;
    }

    /// True when any projection of `pl` is a deref (the place reaches through a reference).
    fn place_has_deref(self: &Self, b: &ir::CoreBody, pl: u32) bool {
        let p = *b.places.at(pl as usize);
        for i in 0..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return true;
            }
        }
        return false;
    }

    /// Kill every fact identity rooted at `l`: the version stamp covers value binds and synthetic
    /// length identities, the base generation covers real length places.
    fn kill_root(self: &mut Self, l: u32) {
        self.bump_local(l);
        self.basegen.set(l as usize, self.basegen[l as usize] + 1);
    }

    fn kill_ambient(self: &mut Self) {
        for i in 0..self.statics.len() {
            self.kill_root(self.statics[i]);
        }
        for i in 0..self.esclist.len() {
            self.kill_root(self.esclist[i]);
        }
    }

    fn mark_escaped(self: &mut Self, r: u32) {
        if self.escroot[r as usize] {
            return;
        }
        if self.esclist.len() >= 16 {
            self.escall = true;
            return;
        }
        self.escroot.set(r as usize, true);
        self.esclist.push(r);
    }

    /// A raw pointer (or stored &mut) to `pl`'s root left the tracked borrow discipline: kill the
    /// root at every kept boundary from here on. Unresolvable provenance disables transparency
    /// for the rest of the body.
    fn note_escape_place(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let mut r: u32 = 0;
        if !self.root_of_place(b, pl, &mut r) {
            self.escall = true;
            return;
        }
        self.mark_escaped(r);
    }

    /// A mutable borrow bound to whole local `dest` is benign only when a call terminator consumes
    /// it as a direct argument (the argument classification kills its root there). Any other fate
    /// escapes the root at the next terminator.
    fn note_mut_borrow(self: &mut Self, b: &ir::CoreBody, pl: u32, dest: u32) {
        let mut r: u32 = 0;
        if !self.root_of_place(b, pl, &mut r) {
            self.escall = true;
            return;
        }
        if self.pend_t.len() >= 8 {
            self.escall = true;
            return;
        }
        self.pend_t.push(dest);
        self.pend_r.push(r);
    }

    /// Settle pending mutable borrows at a terminator: a temp consumed as a direct call argument
    /// is accounted for by the argument classification; every other pending borrow escapes.
    fn flush_pending(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) {
        if self.pend_t.len() == 0 {
            return;
        }
        for j in 0..self.pend_t.len() {
            let tl = self.pend_t[j];
            let mut consumed = false;
            if t.kind == ir::TM_CALL {
                for i in 0..t.args_len {
                    let op = *b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize);
                    if op.kind == ir::OP_CONST {
                        continue;
                    }
                    let l = self.whole_local(b, op.data);
                    if l != ir::IR_NONE && self.copy_root(l) == tl {
                        consumed = true;
                    }
                }
            }
            if !consumed {
                self.mark_escaped(self.pend_r[j]);
            }
        }
        self.pend_t.clear();
        self.pend_r.clear();
    }

    /// True when the callee is a local Super-C function body (not extern, not a fn value): the
    /// argument classification then bounds everything it can reach.
    fn callee_defined(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.pkg;
        if d.node == NODE_NONE || d.module as usize >= pk.modules.len() || !pk.modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = unsafe &*pk.module_ast_const(d.module);
        let n = a.at_const(d.node);
        if n.kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        return !n.as_data.function.is_extern;
    }

    /// `rv` casts a reference to a raw pointer: its target leaves the borrow discipline.
    fn is_ref_to_ptr_cast(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let op = *b.operands.at(rv.a as usize);
        if op.kind == ir::OP_CONST {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        if da.type_at(op.ty).kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        return da.type_at(rv.target).kind == TypeKind::TYPE_POINTER;
    }

    /// Signature transparency for one call: keep collection facts when every argument is a
    /// constant, a shared reference, or a by-value datum. Kills exactly the roots handed out
    /// mutably or by move, plus statics and escaped roots (any callee can reach those). A raw
    /// pointer, fn value, dyn value, variadic tail, fn-value callee, or extern callee keeps the
    /// old kill-everything behavior. A &mut loaded from memory kills nothing extra: it can alias
    /// only an escaped root (killed here anyway) or state no tracked fact roots -- a second live
    /// mutable alias of a tracked collection would break the reference rules.
    fn call_transparent(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if self.collecting || self.no_sig || self.escall || t.is_variadic || !self.callee_defined(t.callee) {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        let mut kills: [u32; 16] = [[0] = 0u32];
        let mut nk: usize = 0;
        for i in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize);
            if op.kind == ir::OP_CONST {
                continue;
            }
            let y = *da.type_at(op.ty);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_OPAQUE {
                return false;
            }
            let mut victim = ir::IR_NONE;
            let mut victim2 = ir::IR_NONE;
            if y.kind == TypeKind::TYPE_REFERENCE {
                if y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    continue; // a shared reference cannot mutate the header it points at
                }
                let l = self.whole_local(b, op.data);
                if l == ir::IR_NONE {
                    // a projected operand place is an elided autoref of a projected collection
                    // (s.field): kill its base. A deref inside is a loaded &mut: it can alias
                    // only an escaped root (killed below) or state no tracked fact roots.
                    if !self.place_has_deref(b, op.data) {
                        victim = b.places.at(op.data as usize).base;
                    }
                } else {
                    let r = self.copy_root(l);
                    let rb = *self.refof.at(r as usize);
                    let mut rt: u32 = 0;
                    if rb.ok && rb.my_v == self.lver[r as usize] && (rb.pl & SYNTH_PL) == 0 && self.root_of_place(
                        b,
                        rb.pl,
                        &mut rt,
                    ) {
                        victim = rt;
                    } else {
                        // an elided autoref (the local IS the collection), a &mut parameter, or
                        // an expired binding: kill both ends of the value chain
                        victim = l;
                        victim2 = r;
                    }
                }
            } else if op.kind == ir::OP_MOVE {
                // ownership leaves the caller: kill the moved-from base
                if self.place_has_deref(b, op.data) {
                    return false;
                }
                victim = b.places.at(op.data as usize).base;
            }
            if victim != ir::IR_NONE {
                if nk >= 15 {
                    return false;
                }
                unsafe kills[nk] = victim;
                nk += 1;
                if victim2 != ir::IR_NONE && victim2 != victim {
                    unsafe kills[nk] = victim2;
                    nk += 1;
                }
            }
        }
        for i in 0..nk {
            if self.dbg {
                eprint("bce-dbg: call kill root {}\n", unsafe kills[i]);
            }
            self.kill_root(unsafe kills[i]);
        }
        self.kill_ambient();
        return true;
    }

    /// A drop reaches only the dropped value's ownership tree (its `free` takes `&mut self`),
    /// plus statics and escaped roots like any call.
    fn drop_transparent(self: &mut Self, b: &ir::CoreBody, pl: u32) bool {
        if self.collecting || self.no_sig || self.escall {
            return false;
        }
        let mut r: u32 = 0;
        if !self.root_of_place(b, pl, &mut r) {
            return false;
        }
        self.kill_root(r);
        self.kill_ambient();
        return true;
    }

    // ---- statement walk ------------------------------------------------------------------------

    /// True when `t` is a call of the borrow-pure prelude length getter: `fn len(&self)` on a
    /// prelude view. Its shared receiver cannot mutate the collection, so it both yields a
    /// length fact and preserves standing facts.
    fn is_prelude_len_call(self: &Self, t: &ir::Terminator) bool {
        if t.callee.node == NODE_NONE || t.args_len != 1 || t.dests_len != 1 {
            return false;
        }
        let pk = unsafe &*self.pkg;
        if !pk.modules.at(t.callee.module as usize).prelude {
            return false;
        }
        let da = unsafe &*pk.module_ast_const(t.callee.module);
        let nd = da.at_const(t.callee.node);
        if nd.kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let ns = da.at_const(nd.as_data.function.name).as_data.name.text;
        let src = pk.modules.at(t.callee.module as usize).source.as_str();
        return src.slice(ns.start as usize, ns.end as usize) == "len";
    }

    /// The receiver place behind the single `&self` argument of a len call, or IR_NONE. The
    /// argument may sit behind whole-local copies of the autoref temp.
    fn len_call_receiver(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) u32 {
        let opid = b.oper_pool[t.args_start as usize];
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return ir::IR_NONE;
        }
        let l = self.whole_local(b, op.data);
        if l != ir::IR_NONE {
            let rb = *self.refof.at(l as usize);
            if rb.ok && rb.my_v == self.lver[l as usize] {
                return rb.pl;
            }
        }
        // the receiver reached the call as a direct place copy (by-value view or elided autoref):
        // that place IS the collection identity
        return op.data;
    }

    // ---- range-check coalescing ----------------------------------------------------------------

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
        self.cwritten.clear();
        self.cwritten.resize_default(b.locals.len());
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
                let mut have2 = false;
                let o2 = *b.operands.at(iop2 as usize);
                if o2.kind == ir::OP_COPY || o2.kind == ir::OP_MOVE {
                    let x = self.whole_local(b, o2.data);
                    if x != ir::IR_NONE {
                        let mut q = self.la_dest.len();
                        while q > 0 && !have2 {
                            q -= 1;
                            if self.la_dest[q] == x {
                                off2 = self.la_off[q];
                                have2 = true;
                            }
                        }
                    }
                }
                if !have2 {
                    let k = self.vkey_w(b, iop2, true);
                    if k.is_local && k.l == ik.l && k.v == ik.v {
                        off2 = k.off;
                        have2 = true;
                    }
                }
                // length identity: same value key, or an in-window copy of the same length place
                let mut same_len = false;
                let k3 = self.vkey_w(b, lop2, true);
                if lk.is_const {
                    same_len = k3.is_const && k3.c == lk.c;
                } else if k3.is_local && k3.l == lk.l && k3.v == lk.v && k3.off == lk.off {
                    same_len = true;
                } else if lb.ok {
                    let o3 = *b.operands.at(lop2 as usize);
                    if o3.kind == ir::OP_COPY || o3.kind == ir::OP_MOVE {
                        let xl = self.whole_local(b, o3.data);
                        if xl != ir::IR_NONE {
                            let mut q = self.ll_dest.len();
                            while q > 0 && !same_len {
                                q -= 1;
                                if self.ll_dest[q] == xl && self.places_eq(b, self.ll_pl[q], lb.pl) {
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
                    let x = self.whole_local(b, o2.data);
                    if x != ir::IR_NONE {
                        let mut q = self.la_dest.len();
                        while q > 0 && !bind_aff {
                            q -= 1;
                            if self.la_dest[q] == x {
                                bind_aff = true;
                                bind_off = self.la_off[q];
                            }
                        }
                        if !bind_aff {
                            let k = self.vkey_w(b, rv2.a, true);
                            if k.is_local && k.l == ik.l && k.v == ik.v {
                                bind_aff = true;
                                bind_off = k.off;
                            }
                        }
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
                let ka = self.vkey_w(b, rv2.a, true);
                let kb = self.vkey_w(b, rv2.b, true);
                let ao = *b.operands.at(rv2.a as usize);
                let bo = *b.operands.at(rv2.b as usize);
                let mut basex = ir::IR_NONE;
                let mut ck: i64 = 0;
                let mut aside = false;
                if (ao.kind == ir::OP_COPY || ao.kind == ir::OP_MOVE) && kb.is_const {
                    basex = self.whole_local(b, ao.data);
                    ck = if rv2.c == tt::TokenType::Plus as u8 {
                        kb.c;
                    } else {
                        0 - kb.c;
                    };
                    aside = true;
                } else if ka.is_const && rv2.c == tt::TokenType::Plus as u8 && (bo.kind == ir::OP_COPY || bo.kind == ir::OP_MOVE) {
                    basex = self.whole_local(b, bo.data);
                    ck = ka.c;
                }
                if basex != ir::IR_NONE {
                    let mut baseoff: i64 = 0;
                    let mut got = false;
                    let mut q = self.la_dest.len();
                    while q > 0 && !got {
                        q -= 1;
                        if self.la_dest[q] == basex {
                            baseoff = self.la_off[q];
                            got = true;
                        }
                    }
                    if !got {
                        let opk = if aside {
                            self.vkey_w(b, rv2.a, true);
                        } else {
                            self.vkey_w(b, rv2.b, true);
                        };
                        if opk.is_local && opk.l == ik.l && opk.v == ik.v {
                            baseoff = opk.off;
                            got = true;
                        }
                    }
                    if got {
                        bind_aff = true;
                        bind_off = baseoff + ck;
                    }
                }
            } else if k2 == ir::RV_BINARY && (rv2.c == tt::TokenType::LessThan as u8 || rv2.c == tt::TokenType::LessThanEqual as u8) {
                // pure comparison
            } else if k2 == ir::RV_INTRINSIC && rv2.c == ir::IN_BOUNDS_PROVEN {
                // cannot panic
            } else if k2 == ir::RV_LEN {
                if lb.ok && self.places_eq(b, rv2.a, lb.pl) {
                    bind_len = true;
                    bind_pl = rv2.a;
                }
            } else if k2 == ir::RV_REF || k2 == ir::RV_ADDR || k2 == ir::RV_DISCRIMINANT {
                // pure reads
            } else {
                break; // anything else may write memory, allocate, or panic
            }
            // a reassigned local no longer names its old value anywhere below
            self.cwritten.set(p2.base as usize, true);
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
                raw: sp,
                item: DefId { module: 0, node: NODE_NONE },
                targ_start: 0,
                targ_len: 0,
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

    /// Reset every per-body table for a fresh body; capacity persists across the bodies one
    /// DropCtx emits.
    fn begin_body(self: &mut Self, b: &ir::CoreBody) {
        let nl = b.locals.len();
        let nb = b.blocks.len();
        self.lver.clear();
        self.lver.resize_default(nl);
        self.basegen.clear();
        self.basegen.resize_default(nl);
        self.heapgen = 0;
        self.lenof.clear();
        self.cmpof.clear();
        self.copyof.clear();
        self.affof.clear();
        self.refof.clear();
        for _i in 0..nl {
            self.lenof.push(lenbind_none());
            self.cmpof.push(
                CmpBind {
                    a: vkey_none(),
                    b: vkey_none(),
                    a_lp: lenbind_none(),
                    b_lp: lenbind_none(),
                    le: false,
                    my_v: 0,
                    ok: false,
                },
            );
            self.copyof.push(CopyBind { src: 0, src_v: 0, my_v: 0, ok: false });
            self.affof.push(AffBind { src: 0, src_v: 0, c: 0, my_v: 0, ok: false });
            self.refof.push(RefBind { pl: 0, my_v: 0, ok: false });
        }
        self.facts.clear();
        while self.in_facts.len() < nb {
            self.in_facts.push(Vector::<Fact>::new());
        }
        for i in 0..nb {
            self.in_facts[i].clear();
        }
        self.in_set.clear();
        self.in_set.resize_default(nb);
        self.preds.clear();
        self.preds.resize_default(nb);
        self.rpo.clear();
        self.total_facts = 0;
        self.limited = false;
        self.escall = false;
        self.collecting = false;
        self.escroot.clear();
        self.escroot.resize_default(nl);
        self.esclist.clear();
        self.statics.clear();
        for i in 0..nl {
            if b.locals.at(i).storage == ir::LS_STATIC_REF {
                self.statics.push(i as u32);
            }
        }
        self.pend_t.clear();
        self.pend_r.clear();
    }

    /// Clear every per-walk table for the main pass; the collected escape set persists.
    fn reset_for_main_pass(self: &mut Self, nb: usize) {
        for i in 0..self.lver.len() {
            self.lver.set(i, 0);
            self.basegen.set(i, 0);
            self.lenof[i].ok = false;
            self.cmpof[i].ok = false;
            self.copyof[i].ok = false;
            self.affof[i].ok = false;
            self.refof[i].ok = false;
        }
        self.heapgen = 0;
        self.facts.clear();
        for i in 0..nb {
            self.in_facts[i].clear();
            self.in_set.set(i, false);
        }
        self.total_facts = 0;
        self.limited = false;
        self.pend_t.clear();
        self.pend_r.clear();
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
    z.pkg = pkg;
    // most bodies carry no checks at all: skip every allocation for them
    let mut any = false;
    for i in 0..b.rvalues.len() {
        let k = b.rvalues.at(i);
        if k.kind == ir::RV_INTRINSIC && ir::is_check(k.c) {
            any = true;
            break;
        }
    }
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
    z.begin_body(b);
    // predecessor counts + RPO over the reachable blocks (iterative DFS, dense vectors)
    {
        let mut seen = Vector::<u8>::new();
        seen.resize_default(nb);
        let mut stack = Vector::<u64>::new(); // block << 1 | phase
        stack.push(b.entry as u64 << 1);
        seen.set(b.entry as usize, 1);
        while stack.len() != 0 {
            let top = stack[stack.len() - 1];
            let _ = stack.pop();
            let blk = (top >> 1) as usize;
            if (top & 1) != 0 {
                z.rpo.push(blk as u32);
                continue;
            }
            stack.push(top | 1);
            let t = &b.blocks.at(blk).term;
            // successors without allocation: switch targets first, then the shared t0 edge
            let mut nsw: u32 = 0;
            if t.kind == ir::TM_SWITCH {
                nsw = t.sw_len;
            }
            for i in 0..nsw + 1 {
                let mut s = ir::IR_NONE;
                if i < nsw {
                    s = (b.switch_pool[(t.sw_start + i) as usize] & 0xFFFFFFFFu64) as u32;
                } else if t.kind == ir::TM_GOTO || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP || t.kind == ir::TM_ASSERT || t.kind == ir::TM_SWITCH {
                    s = t.t0;
                }
                if s == ir::IR_NONE {
                    continue;
                }
                z.preds.set(s as usize, z.preds[s as usize] + 1);
                if seen[s as usize] == 0 {
                    seen.set(s as usize, 1);
                    stack.push(s as u64 << 1);
                }
            }
        }
        seen.free();
        // rpo currently holds a POST order (children pushed after the phase-1 marker); reverse it
        z.rpo.reverse();
        stack.free();
    }
    let mut err: str<'static> = "";
    // the escape-collection pass exists only for signature transparency
    let pass0: usize = if z.no_sig {
        1;
    } else {
        0;
    };
    for pass9 in pass0..2 {
        z.collecting = pass9 == 0;
        for bi in 0..z.rpo.len() {
            let blk = z.rpo[bi] as usize;
            z.facts.clear();
            if z.in_set[blk] {
                for i in 0..z.in_facts[blk].len() {
                    let f0 = z.in_facts[blk][i];
                    z.facts.push(f0);
                }
                z.in_facts[blk].clear();
            }
            let bb = *b.blocks.at(blk);
            for si in 0..bb.stmt_len {
                let sid = (bb.stmt_start + si) as usize;
                let stm = *b.statements.at(sid);
                if stm.kind == ir::ST_ASSIGN {
                    let rid = stm.rvalue as usize;
                    let rv = *b.rvalues.at(rid);
                    let dest = z.whole_local(b, stm.place);
                    if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_BOUNDS_GROUP {
                        let iop = b.oper_pool[rv.a as usize];
                        let lop = b.oper_pool[(rv.a + 1) as usize];
                        let wo = *b.operands.at(b.oper_pool[(rv.a + 2) as usize] as usize);
                        let ik = z.vkey(b, iop);
                        if ik.is_local && wo.kind == ir::OP_CONST {
                            let wc = *b.constants.at(wo.data as usize);
                            if wc.kind == ir::CK_INT && wc.val > 0 && wc.val <= 8 {
                                for k in 0..wc.val {
                                    let mut ikk = ik;
                                    ikk.off = ik.off + k;
                                    z.fact_from_check(b, 0, ikk, lop);
                                }
                            }
                        }
                    } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN) {
                        let iop = b.oper_pool[rv.a as usize];
                        let lop = b.oper_pool[(rv.a + 1) as usize];
                        if !z.collecting {
                            let mut reason: u8 = BR_UNKNOWN_INDEX;
                            let proven = z.prove_elem(b, iop, lop, &mut reason);
                            if check_only {
                                if rv.c == ir::IN_BOUNDS_PROVEN && !proven {
                                    err = "bce: unprovable IN_BOUNDS_PROVEN";
                                }
                            } else {
                                st.total += 1;
                                if proven {
                                    st.removed += 1;
                                    b.rvalues[rid].c = ir::IN_BOUNDS_PROVEN;
                                } else {
                                    let mut grouped: u32 = 0;
                                    if !z.no_coalesce && rv.c == ir::IN_BOUNDS {
                                        grouped = z.try_coalesce(b, &bb, si, rid, iop, lop, stm.span);
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
                        }
                        // success establishes idx < len for later identical sites
                        let ik = z.vkey(b, iop);
                        z.fact_from_check(b, 0, ik, lop);
                    } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS_PROVEN) {
                        let sop = b.oper_pool[rv.a as usize];
                        let eop = b.oper_pool[(rv.a + 1) as usize];
                        let lop = b.oper_pool[(rv.a + 2) as usize];
                        if !z.collecting {
                            let mut reason: u8 = BR_UNKNOWN_INDEX;
                            let proven = z.prove_range(b, sop, eop, lop, &mut reason);
                            if check_only {
                                if rv.c == ir::IN_RANGE_BOUNDS_PROVEN && !proven {
                                    err = "bce: unprovable IN_RANGE_BOUNDS_PROVEN";
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
                        }
                        // success establishes end <= len
                        let ek = z.vkey(b, eop);
                        z.fact_from_check(b, 1, ek, lop);
                    } else if rv.kind == ir::RV_LEN && dest != ir::IR_NONE {
                        z.write_place(b, stm.place);
                        z.lenof.set(
                            dest as usize,
                            LenBind {
                                pl: rv.a,
                                hg: z.heapgen,
                                bg: z.basegen[b.places.at(rv.a as usize).base as usize],
                                my_v: z.lver[dest as usize],
                                ok: true,
                            },
                        );
                        continue;
                    } else if rv.kind == ir::RV_BINARY && dest != ir::IR_NONE && (rv.c == tt::TokenType::Plus as u8 || rv.c == tt::TokenType::Minus as u8) && rv.target == Ast::builtin(
                        BuiltinType::BT_USIZE,
                    ) && !z.no_affine {
                        // dest = src +- c: an affine alias of src, matched by exact offset only
                        let ka = z.vkey(b, rv.a);
                        let kb = z.vkey(b, rv.b);
                        let mut srcl = ir::IR_NONE;
                        let mut c0: i64 = 0;
                        if ka.is_local && kb.is_const {
                            srcl = ka.l;
                            c0 = ka.off + if rv.c == tt::TokenType::Plus as u8 {
                                kb.c;
                            } else {
                                0 - kb.c;
                            };
                        } else if kb.is_local && ka.is_const && rv.c == tt::TokenType::Plus as u8 {
                            srcl = kb.l;
                            c0 = kb.off + ka.c;
                        }
                        z.write_place(b, stm.place);
                        if srcl != ir::IR_NONE && srcl != dest && c0 > 0 - 1048576 && c0 < 1048576 {
                            z.affof.set(
                                dest as usize,
                                AffBind {
                                    src: srcl,
                                    src_v: z.lver[srcl as usize],
                                    c: c0,
                                    my_v: z.lver[dest as usize],
                                    ok: true,
                                },
                            );
                        }
                        continue;
                    } else if rv.kind == ir::RV_BINARY && dest != ir::IR_NONE && (rv.c == tt::TokenType::LessThan as u8 || rv.c == tt::TokenType::LessThanEqual as u8 || rv.c == tt::TokenType::GreaterThan as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8) {
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
                        let ak = z.vkey(b, aop);
                        let bk = z.vkey(b, bop);
                        let alp = z.oper_len_lp(b, aop);
                        let blp = z.oper_len_lp(b, bop);
                        z.write_place(b, stm.place);
                        z.cmpof.set(
                            dest as usize,
                            CmpBind {
                                a: ak,
                                b: bk,
                                a_lp: alp,
                                b_lp: blp,
                                le: rv.c == tt::TokenType::LessThanEqual as u8 || rv.c == tt::TokenType::GreaterThanEqual as u8,
                                my_v: z.lver[dest as usize],
                                ok: true,
                            },
                        );
                        continue;
                    } else if rv.kind == ir::RV_USE && dest != ir::IR_NONE {
                        // a direct `[r, deref, .len]` read of a prelude view is a length capture: the
                        // inlined std `len()` body reads the field where the call read the method
                        let flp = z.oper_len_lp(b, rv.a);
                        let op = *b.operands.at(rv.a as usize);
                        if flp.ok && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && z.whole_local(b, op.data) == ir::IR_NONE {
                            z.write_place(b, stm.place);
                            z.lenof.set(
                                dest as usize,
                                LenBind { pl: flp.pl, hg: flp.hg, bg: flp.bg, my_v: z.lver[dest as usize], ok: true },
                            );
                            continue;
                        }
                        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                            let srcl = z.whole_local(b, op.data);
                            if srcl != ir::IR_NONE {
                                z.write_place(b, stm.place);
                                z.copyof.set(
                                    dest as usize,
                                    CopyBind {
                                        src: srcl,
                                        src_v: z.lver[srcl as usize],
                                        my_v: z.lver[dest as usize],
                                        ok: true,
                                    },
                                );
                                // a copy of a length keeps its place identity
                                let slb = z.len_place_of(srcl);
                                if slb.ok {
                                    z.lenof.set(
                                        dest as usize,
                                        LenBind {
                                            pl: slb.pl,
                                            hg: slb.hg,
                                            bg: slb.bg,
                                            my_v: z.lver[dest as usize],
                                            ok: true,
                                        },
                                    );
                                }
                                continue;
                            }
                        }
                    } else if rv.kind == ir::RV_REF && dest != ir::IR_NONE {
                        z.write_place(b, stm.place);
                        z.refof.set(dest as usize, RefBind { pl: rv.a, my_v: z.lver[dest as usize], ok: true });
                        if rv.b == 1 {
                            z.note_mut_borrow(b, rv.a, dest);
                        }
                        continue;
                    }
                    if rv.kind == ir::RV_REF && rv.b == 1 || rv.kind == ir::RV_ADDR {
                        z.note_escape_place(b, rv.a);
                    } else if rv.kind == ir::RV_CAST && z.is_ref_to_ptr_cast(b, &rv) {
                        // resolve through the reference binding so the BORROWED collection
                        // escapes, not the reference temp
                        let cl = z.whole_local(b, b.operands.at(rv.a as usize).data);
                        if cl == ir::IR_NONE {
                            z.escall = true;
                        } else {
                            let cr = z.copy_root(cl);
                            let rb = *z.refof.at(cr as usize);
                            if rb.ok && rb.my_v == z.lver[cr as usize] && (rb.pl & SYNTH_PL) == 0 {
                                z.note_escape_place(b, rb.pl);
                            } else {
                                z.mark_escaped(cr);
                            }
                        }
                    }
                    z.write_place(b, stm.place);
                } else if stm.kind == ir::ST_SET_DISCR || stm.kind == ir::ST_DEINIT {
                    z.write_place(b, stm.place);
                } else if stm.kind == ir::ST_ASM {
                    z.heapgen += 1;
                } else if stm.kind == ir::ST_STORAGE_DEAD {
                    z.bump_local(stm.a);
                }
            }
            // terminator: panic-guard folding, then effects, then single-pred fact propagation
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
                        if z.fold_proved(b, &cb.a, &cb.b, &cb.b_lp, cb.le) {
                            dir = 1; // always true
                        } else if z.fold_proved(b, &cb.b, &cb.a, &cb.a_lp, !cb.le) {
                            dir = 2; // always false (the negation swaps sides and flips strictness)
                        }
                        if !check_only && !z.collecting && !z.no_fold && dir != 0 {
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
            } else if check_only && !z.collecting && t.kind == ir::TM_GOTO && (t.args_len == 1 || t.args_len == 2) && t.a != ir::IR_NONE {
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
            z.flush_pending(b, &t);
            if t.kind == ir::TM_CALL {
                let mut pure_len = z.is_prelude_len_call(&t);
                let mut recv = ir::IR_NONE;
                if pure_len {
                    recv = z.len_call_receiver(b, &t);
                    pure_len = recv != ir::IR_NONE;
                }
                if !pure_len {
                    if z.call_transparent(b, &t) {
                        if !check_only {
                            st.sig_kept += 1;
                        }
                    } else {
                        z.heapgen += 1;
                    }
                }
                for i in 0..t.dests_len {
                    let dpl = b.dest_pool[(t.dests_start + i) as usize];
                    z.write_place(b, dpl);
                }
                if pure_len && t.dests_len == 1 {
                    let dl = z.whole_local(b, b.dest_pool[t.dests_start as usize]);
                    if dl != ir::IR_NONE {
                        z.lenof.set(
                            dl as usize,
                            LenBind {
                                pl: recv,
                                hg: z.heapgen,
                                bg: z.basegen[b.places.at(recv as usize).base as usize],
                                my_v: z.lver[dl as usize],
                                ok: true,
                            },
                        );
                    }
                }
            } else if t.kind == ir::TM_DROP {
                if !z.drop_transparent(b, t.a) {
                    z.heapgen += 1;
                }
            }
            let mut succ0 = ir::IR_NONE;
            let mut succ_true = ir::IR_NONE;
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP || t.kind == ir::TM_ASSERT {
                succ0 = t.t0;
            } else if t.kind == ir::TM_SWITCH {
                succ0 = t.t0;
                if t.sw_len == 1 && b.switch_pool[t.sw_start as usize] >> 32 == 1 {
                    succ_true = (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32;
                }
            }
            if succ0 != ir::IR_NONE && z.preds[succ0 as usize] == 1 && !z.in_set[succ0 as usize] {
                for i in 0..z.facts.len() {
                    let f0 = *z.facts.at(i);
                    z.in_facts[succ0 as usize].push(f0);
                }
                z.in_set.set(succ0 as usize, true);
            }
            if succ_true != ir::IR_NONE && z.preds[succ_true as usize] == 1 && !z.in_set[succ_true as usize] && !z.no_loop {
                for i in 0..z.facts.len() {
                    let f0 = *z.facts.at(i);
                    z.in_facts[succ_true as usize].push(f0);
                }
                let st_i = succ_true as usize;
                // the branch condition itself, on its true edge: `a < b` (or `a <= b`)
                if t.kind == ir::TM_SWITCH {
                    let ck = z.vkey(b, t.a);
                    if ck.is_local {
                        let cb = *z.cmpof.at(ck.l as usize);
                        if cb.ok && cb.my_v == ck.v && (cb.a.is_const || cb.a.is_local) && cb.b.is_local {
                            let lp = cb.b_lp; // captured at the comparison, so never stale here
                            if z.in_facts[st_i].len() < MAX_EDGE_FACTS {
                                z.in_facts[st_i].push(
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
                                        ln_l: cb.b.l,
                                        ln_v: cb.b.v,
                                        ln_off: cb.b.off,
                                        lp_ok: lp.ok,
                                        lp: lp.pl,
                                        lp_hg: lp.hg,
                                        lp_bg: lp.bg,
                                    },
                                );
                            }
                        }
                    }
                }
                z.in_set.set(succ_true as usize, true);
            }
        }
        if pass9 == 0 {
            z.reset_for_main_pass(nb);
        }
    }
    return err;
}
