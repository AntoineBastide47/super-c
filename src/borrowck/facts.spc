// Input-fact generation for the Core IR loan analysis: dense points, origins, loans,
// point-local subset edges, accesses, kills, and the init/move event stream, produced in one walk of
// a verified CoreBody. Facts are integers in Core IR order: two serial runs generate identical
// vectors. Raw pointers, `str`, and slice views carry no origin here: their storage discipline is the
// unsafe world's contract, and tracking them would reject programs the language accepts.
import ast::ast as *;
import lexer::token as tok;
import module::loader as loader;
import ir::core as ir;
import borrowck::move_paths as mp;
import utils::bits as bits;

/// The absent fact index, place, local, or origin.
pub const BF_NONE: u32 = 0xFFFFFFFF;

/// Loan kinds (Loan.kind).
pub const LK_SHARED: u8 = 0;
pub const LK_MUT: u8 = 1;
pub const LK_RESERVED: u8 = 2; // two-phase mutable: reads stay legal until activation
pub const LK_CAP: u8 = 3; // closure mutable capture: exclusive like LK_MUT; diagnostics name the capture

/// Access kinds. FREE and CAP invalidate like moves; they exist so diagnostics can name the
/// operation (an explicit `.free()`, a closure capture) instead of a generic move.
pub const ACC_READ: u8 = 0;
pub const ACC_WRITE: u8 = 1;
pub const ACC_MOVE: u8 = 2;
pub const ACC_FREE: u8 = 3;
pub const ACC_CAP: u8 = 4;
pub const ACC_ACT: u8 = 6; // a reserved (two-phase) loan's exclusivity claim at its activation

/// Init/move events (dataflow transfer replays these per block).
pub const EV_ASSIGN: u8 = 0; // path fully (re)initialized
pub const EV_MOVE: u8 = 1; // path moved out
pub const EV_USE: u8 = 2; // path read (init required)
pub const EV_DEAD: u8 = 3; // local storage ends (path = local root)
pub const EV_MOVE_CUT: u8 = 4; // moved THROUGH a reference (unsafe ref-take): drops-visible only

/// One borrow the body issues: the borrowed place, its kind, and the point and origin it lives at.
pub struct Loan {
    pub through: bool, // the borrowed storage lies behind a reference or a view (`Gen::behind`, or a
    // reborrow through a call argument): never this body's storage, so neither its escape nor the
    // death of the place's base local is checked; the reference's own loans carry that.
    pub pin: bool, // a receiver pin from a carrying call result (a view into the receiver's storage)
    pub deref: bool, // a reborrow through a call argument: the loan is on the POINTEE of the reference
    // in `place`, so overwriting `place` itself only replaces the reference (it kills the loan).
    pub level: u8, // the reference level of its origin it is issued at (see SD_KEEP)
    pub place: ir::PlaceId,
    pub kind: u8,
    pub origin: u32,
    pub issued_at: u32,
    pub activated_at: u32, // BF_NONE until a reserved loan's first use point is known
    pub span: tok::Span,
}

/// One access to a place or a whole local at a point, with its ACC_* kind.
pub struct Access {
    pub place: ir::PlaceId, // BF_NONE for a whole-local access (storage death)
    pub local: u32, // BF_NONE for a place access
    pub kind: u8,
    pub copy_out: bool, // a call argument read as a borrow-free value: its base is used at `point` only
    pub def: bool, // a store of the whole local (a `&mut` claim of it is a use: the value survives)
    pub point: u32,
    pub span: tok::Span,
}

/// Subset edge kinds. A loan sits at reference level 0 of an origin when the value holds it
/// directly (its own reference or view borrows it), at level 1 when it lies behind exactly one of
/// the value's references, and at level 2 when it lies behind at least two (saturated: no edge
/// drops it). A level is never below the loan's true level. An edge maps levels 0 and 1 to a level
/// or to SD_DROP (level 2 stays 2): its kind packs the image of level 0 in bits 0-1 and of level 1
/// in bits 2-3. KEEP preserves every level; DEREF (a value read from behind one reference) drops
/// level 0; DEREF2 (behind two) drops levels 0 and 1; REF (a value placed behind one reference)
/// adds one level; SAT places a value behind references of a depth the facts do not know, so every
/// level saturates. An edge whose depth change is not exact must over-count its references and
/// under-count its dereferences (`sd_lift`, `sd_sink`).
pub const SD_DROP: u8 = 3;
pub const SD_KEEP: u8 = 4; // 0 -> 0, 1 -> 1
pub const SD_DEREF: u8 = 3; // 0 -> drop, 1 -> 0
pub const SD_DEREF2: u8 = 15; // 0 -> drop, 1 -> drop
pub const SD_REF: u8 = 9; // 0 -> 1, 1 -> 2
pub const SD_SAT: u8 = 10; // 0 -> 2, 1 -> 2
pub const SD_KEEP_SAT: u8 = 8; // 0 -> 0, 1 -> 2: a flow whose deeper levels the facts do not know

/// The level a loan at level `d` (0, 1 or 2) reaches over an edge of kind `e`, or SD_DROP.
pub const fn sd_level(e: u8, d: u32) u32 {
    if d >= 2 {
        return 2;
    }
    return e >> (2 * d) as u8 & 3u8;
}

/// Edge `a` followed by edge `b`.
pub const fn sd_then(a: u8, b: u8) u8 {
    let mut r: u8 = 0;
    for d in 0..2u32 {
        let x = sd_level(a, d);
        let y = if x == SD_DROP as u32 {
            SD_DROP as u32;
        } else {
            sd_level(b, x);
        };
        r = r | y as u8 << (2 * d) as u8;
    }
    return r;
}

/// The edge of a value placed behind `k` references: KEEP, REF, or SAT from two on.
pub const fn sd_lift(k: u32) u8 {
    if k == 0 {
        return SD_KEEP;
    }
    if k == 1 {
        return SD_REF;
    }
    return SD_SAT;
}

/// The edge of a value read from behind `k` references: KEEP, DEREF, or DEREF2 from two on.
pub const fn sd_sink(k: u32) u8 {
    if k == 0 {
        return SD_KEEP;
    }
    if k == 1 {
        return SD_DEREF;
    }
    return SD_DEREF2;
}

/// Edge `e` without the `k` levels a store behind `k` references added: a saturated level stays
/// saturated, and a level below `k` (not lifted by the store) stays at 0.
pub const fn sd_unlift(e: u8, k: u32) u8 {
    let mut r: u8 = 0;
    for d in 0..2u32 {
        let x = sd_level(e, d);
        let y = if x == SD_DROP as u32 || x == 2 {
            x;
        } else if x >= k {
            x - k;
        } else {
            0u32;
        };
        r = r | y as u8 << (2 * d) as u8;
    }
    return r;
}

/// Does edge `e` keep level 0 where it is (a copy, or a flow of unknown depth below it)?
pub const fn sd_keeps(e: u8) bool {
    return sd_level(e, 0) == 0;
}

/// An elided lifetime position in a token list (named tokens set bit 63, generic ones are
/// `module << 32 | node`).
const ELIDED_TOK: u64 = 1u64 << 62;

/// The parameters whose `'static` edge `CallSig::fl` records (two bits each above bit 8); a later
/// parameter's argument never flows into `'static`.
const STATIC_PARAMS_MAX: u32 = 28;

/// What a call site reads of its callee's signature alone (`Gen::call_sig`), memoized per callee:
/// call sites re-read the same signatures constantly. A call's own lifetime ties (`call_lt_pairs`)
/// widen the relation at the site.
pub struct CallSig {
    // 4 | explicit `self` first parameter << 0 | named `free` << 1 | the return has an elided
    // lifetime position << 3; from bit 8, two bits per parameter below STATIC_PARAMS_MAX: the edge
    // its argument takes into `'static` (0 = the type names no `'static`, 1 = the whole value, 2 =
    // what lies behind the parameter's own reference). 0 for a fn-value call.
    pub fl: u64,
    pub rel: u64, // the outlives relation (`Owner::callee_rel`)
    pub rbeh: u64, // the return's tokens behind a reference level (`behind_range`), 0 for no function
    pub rtok: u64, // the return's lifetime tokens: start << 16 | len in tok_pool
    pub lts: u64, // bit i: parameter i (below 64) has a lifetime position (`sig_lt`)
}

/// An origin subset edge `from: to` established at `point`, of SD_* kind `delta`.
pub struct SubsetAt {
    pub from: u32,
    pub to: u32,
    pub point: u32,
    pub delta: u8,
}

/// A store of origin `from` through the reference whose origin is `via`, at `point`, with the
/// argument's edge `e` and the edge `te` into a frame-owned container (see `resolve_stores`).
/// `inner`: the container the store reaches may store the value on through its own references (a
/// member `member_bounds` marks MB_THROUGH), so the store continues one level from there.
pub struct StoreVia {
    pub from: u32,
    pub via: u32,
    pub point: u32,
    pub e: u8,
    pub te: u8,
    pub inner: bool,
    pub more: u8, // reference levels the store passes past the container it reaches (`**p`: one)
    // A call through closure `cnode` stores into its captures in `caps` only (`CapTag`); NODE_NONE: all.
    pub cnode: NodeId,
    pub caps: u64,
}

/// A loan (`loan`) or a copy edge (`from` into `to`, `loan` BF_NONE) that capture `k` of closure
/// `node` puts into the closure value: a store through the value reaches the capture through it.
pub struct CapTag {
    pub loan: u32,
    pub from: u32,
    pub to: u32,
    pub node: NodeId,
    pub k: u32,
}

/// `Owner.interior_memo`'s mark of a declaration whose mask is being computed (a recursive type).
const INTERIOR_BUSY: u64 = 1u64 << 63;

/// What a value stored into a member must outlive besides its container (see `Gen::member_bounds`).
const MB_STATIC: u8 = 1;
const MB_THROUGH: u8 = 2;

/// The destruction of an observed local (`BodyFacts.observed`) at its storage end: a use of its
/// liveness slot `slot` at `point` of `block`, unless the local is moved out on every path there
/// (`BodyFacts::drop_use`). `path` is the local's root move path, `access` its storage-death access,
/// `seen` whether the block defined the slot before the point.
pub struct DropUse {
    pub block: u32,
    pub slot: u32,
    pub path: u32,
    pub point: u32,
    pub access: u32,
    pub seen: bool,
}

/// A loan killed (its storage or reference overwritten) at `point`.
pub struct KillAt {
    pub loan: u32,
    pub point: u32,
}

/// Two arguments of the call at `span` that reach overlapping borrowed storage, at least one of
/// them mutably: `first` and `second` are their `share` levels (1 shared, 2 mutable), in order.
pub struct ArgClash {
    pub span: tok::Span,
    pub first: u8,
    pub second: u8,
}

/// One init/move fact, packed to 16 bytes: replays stream millions of these, so `kind` rides in
/// `pk`'s top byte over the 24-bit path id (move-path creation checks the id fits).
pub struct Event {
    pub pk: u32, // kind << 24 | path; build with `ev()`, read via kind()/path()
    pub point: u32,
    pub span: tok::Span,
}

static_assert(sizeof(Event) == 16, "Event is deliberately packed to a quarter cache line");

/// An init/move event of `kind` on move path `path` (packed into 24 bits) at `point`.
pub const fn ev(kind: u8, path: u32, point: u32, span: tok::Span) Event {
    return Event { pk: kind as u32 << 24 | path, point: point, span: span };
}

extend Event {
    /// The EV_* kind.
    pub const fn kind(self: &Self) u8 {
        return (self.pk >> 24) as u8;
    }

    /// The move path the event is on.
    pub const fn path(self: &Self) u32 {
        return self.pk & 0xFFFFFF;
    }
}

/// Every fact the loan and move analyses read for one body: points, loans, accesses, origin
/// subsets, kills, and init/move events, all in Core IR order.
pub struct BodyFacts {
    pub npoints: u32,
    pub nmoves: u32, // move/move-cut events in the body: 0 (with no split-init decl) skips MoveFlow
    pub block_base: Vector<u32>, // per block: first point (2 per statement + 2 for the terminator)
    pub norigins: u32,
    pub nuniversal: u32, // origins [0, nuniversal): 0 = 'static, then per-arg/declared placeholders
    pub local_origin: Vector<u32>, // per local: its origin, or BF_NONE (type carries no borrow)
    pub origin_local: Vector<u32>, // per origin: the owning local (BF_NONE for placeholders)
    pub uni_name: Vector<tok::Span>, // per universal origin: declared lifetime name (empty = elided)
    pub named: Vector<u64>, // `origin << 32 | universal`: a closure value naming that lifetime holds it
    pub arg_universal: Vector<u32>, // per local: seeded placeholder, or BF_NONE
    pub ret_origin: Vector<u32>, // per return slot: placeholder origin
    pub loans: Vector<Loan>,
    pub origin_loans: Vector<u32>, // per origin: its newest loan, or BF_NONE; older ones chain by loan_next
    pub loan_next: Vector<u32>, // per loan: the next older loan of the same origin, or BF_NONE
    pub subsets: Vector<SubsetAt>,
    pub accesses: Vector<Access>,
    pub kills: Vector<KillAt>,
    pub clashes: Vector<ArgClash>,
    pub events: Vector<Event>,
    pub ev_start: Vector<u32>, // per block: first event (+ one sentinel entry at the end)
    // The state-CHANGING events only (assign/dead/move), same order and block ranges: the move/init
    // fixpoint's silent replays stream these, skipping the read events that dominate the full list.
    // A block with no entry here has an identity transfer even when it is full of reads.
    pub mev: Vector<Event>,
    pub mev_start: Vector<u32>,
    pub rep_blk: Vector<bool>, // per block: any USE/MOVE/MOVE_CUT event (the reporting replay can say something)
    pub easy_blk: Vector<bool>, // per block: only assign/root-leaf-use events, so a clean entry state cannot error
    pub easy_use: Vector<u64>, // per block x ewords: root-leaf paths the block USES (easy-block clearance mask)
    pub freed: Vector<u32>, // move paths consumed by an explicit `.free()` (wording refinement)
    pub observed: Vector<bool>, // per local: owned carrier whose destruction observes stored borrows
    pub cuts: Vector<u64>, // origin << 32 | stmt entry: whole-local rebind severs earlier flows there
    pub ewords: u32, // easy_use row width (ceil(nlocals/64))
    // Liveness slots: the locals, then one per closure local whose destruction observes what its
    // owned captures hold (`drop_slot`): its drop origin is live where that destruction is.
    pub nlive: u32,
    pub drop_slot: Vector<u32>, // per local: its drop origin's liveness slot, or BF_NONE
    pub drop_origin: Vector<u32>, // per local: its drop origin, or BF_NONE
    pub lwords: u32, // liveness row width (ceil(nlive/64))
    pub luse: Vector<u64>, // per block: liveness slots read before any full definition
    pub ldef: Vector<u64>, // per block: locals fully defined
    pub drop_uses: Vector<DropUse>, // the destructions of observed locals, applied by `drop_use`
    pub dead_free: Vector<u32>, // ascending: storage-death accesses whose local is moved out there
}

// One substitution entry for member walks under a generic instance: parameter decl -> the argument
// as a (module, TypeId) pair in the QUERYING pool, read under the frame `[f0, f1)` of `Owner.subst`
// that was active where the instance was named (its arguments may name outer parameters).
struct OwnSubst {
    pub pmod: ModuleId,
    pub pdecl: NodeId,
    pub amod: ModuleId,
    pub aty: TypeId,
    pub f0: u32,
    pub f1: u32,
}

// Owner walk bounds: `low` sentinels (see Owner::busy_enter) and the recursion depth cap.
const BUSY_NONE: i64 = 0x7FFFFFFFFFFFFFFFi64;
const BUSY_CUT: i64 = -1i64;
const BUSY_HIT: i64 = -2i64;
const WALK_DEPTH_MAX: u32 = 64;
// The most distinct interfaces `iface_requires_copy` visits in one superinterface closure.
const COPY_CLOSURE_MAX: usize = 16;

/// Package-level type classification, package-stable and independent of any checker state. `owns`
/// mirrors the emitter's Free verdicts (explicit conformance, bound-filtered generic conformance,
/// member-derived ownership); `carries` says whether a value of the type can HOLD a tracked borrow
/// (references, and aggregates/closures embedding them). Raw pointers never count for either.
pub struct Owner {
    pub pkg: *const loader::Package,
    pub slice_mut: DefId, // the prelude's `[]mut T` struct: a value of it passes write access
    pub slice: DefId, // the prelude's `[]T` struct
    pub str_def: DefId, // the prelude's `str` struct
    free_ext: Map<u64, u64>, // (tmod << 32 | tdecl) -> extend (emod << 32 | enode) + 1; absent = none
    ext_built: bool,
    // Owns/carries are pure functions of (mid, ty) on concrete types, and type ids are dense per
    // module, so a `[mid][ty]` byte array replaces the u64-keyed hashmap on these very hot recursive
    // queries (the single biggest borrowck cost was the Map probe). -1 = unknown, 0 = no, 1 = yes.
    owns_arr: Vector<Vector<u64>>,
    carry_arr: Vector<Vector<u64>>,
    obs_arr: Vector<Vector<u64>>,
    // Walk state of owns/carries: the busy stack and its lowest assumed index (see busy_enter),
    // the substitution frames, and the member-type stack (each call truncates back to its base).
    busy: Vector<u64>,
    low: i64,
    at: DefId, // the body an `owns` query asks for (see `param_owns`)
    subst: Vector<OwnSubst>,
    tys: Vector<TypeId>,
    // Per-callee and per-type-node caches: call boundaries re-read the same signatures constantly.
    pub call_sigs: Map<u64, CallSig>, // (mod << 32 | node) -> its signature summary
    pub gen_sigs: Map<u64, TypeId>, // generic parameter or closure (mod << 32 | node) -> its function type
    pub gen_cls: Map<u64, u64>, // closure (mod << 32 | node) -> its classes, start << 16 | len in gen_cls_pool
    pub gen_cls_pool: Vector<u8>,
    // Closure (mod << 32 | node) -> start << 16 | len in cap_reach_pool: per parameter, the captures
    // (bit k) its argument may be stored into (`bc_closure_escape`).
    pub cap_reach: Map<u64, u64>,
    pub cap_reach_pool: Vector<u64>,
    // Closure (mod << 32 | node) -> the captures (bit k) whose contents its destruction may read:
    // the ones it owns whose destruction observes borrows, and what its body stores into them.
    pub cap_keep: Map<u64, u64>,
    // Closure (mod << 32 | node) -> true when its results hold only what lies behind its
    // by-reference captures: no loan on a capture's own storage, nothing a by-value capture holds
    // (`bc_closure_result`). Absent: unknown.
    pub res_deep: Map<u64, bool>,
    pub kinds_memo: Map<u64, u64>, // (mod << 32 | node) -> start << 16 | len into kinds_pool
    pub kinds_pool: Vector<u8>,
    pub tok_memo: Map<u64, u64>, // (mod << 32 | type node) -> start << 16 | len into tok_pool
    pub beh_memo: Map<u64, u64>, // the same key, or a callee's -> its behind-reference tokens in tok_pool
    pub tok_pool: Vector<u64>,
    rel_memo: Map<u64, u64>, // a function's or declaration's key -> its outlives pairs in rel_pool (see callee_rel)
    rel_pool: Vector<u64>,
    // Gen scratch (capacity survives across bodies).
    sc_assign_sites: Vector<KillSite>,
    sc_seen: Vector<u64>,
    // Per-call and per-body scratch of the fact walk (taken and handed back, capacity kept).
    pub sc_kinds: Vector<u8>,
    pub sc_ptyn: Vector<NodeId>,
    pub sc_tys: Vector<TypeId>,
    pub sc_lb_start: Vector<u32>,
    pub sc_lb_flat: Vector<u32>,
    pub sc_curp: Vector<u32>,
    pub sc_tok_a: Vector<u64>, // lifetime-token scratch: the outer (parameter/return) side
    pub sc_tok_b: Vector<u64>, // the inner (argument) side
    pub sc_tok_r: Vector<u64>, // the return's tokens, read across a call's arguments
    pub sc_tok_c: Vector<u64>, // a store's walk down a parameter's `&mut` levels (`store_more`)
    pub sc_stat: Vector<u64>, // the tokens a declaration or a callee's signature makes `'static`
    pub sc_stores: Vector<StoreVia>, // the walk's stores through reference arguments
    pub sc_visit: Vector<u64>, // resolve_stores: visited origins (bits)
    pub sc_ties: Vector<u64>,
    pub sc_istores: Vector<StoreVia>,
    unsafe_cell: DefId, // the prelude's `UnsafeCell`: what a shared reference may write through
    interior_memo: Map<u64, u64>, // (mod << 32 | decl) -> `interior_mask` (INTERIOR_BUSY while computed)
}

// Read/grow a `[mid][ty]` cache byte; -1 means uncomputed. Type ids are dense per module.
@always_inline
const fn cache_get(arr: &mut Vector<Vector<u64>>, mid: ModuleId, ty: TypeId) i32 {
    if arr.len() <= mid as usize {
        return -1;
    }
    return memo2_get(arr.at(mid as usize), ty_dense(ty));
}

@always_inline
fn cache_set(arr: &mut Vector<Vector<u64>>, mid: ModuleId, ty: TypeId, r: bool) {
    while arr.len() <= mid as usize {
        arr.push(Vector::<u64>::new());
    }
    memo2_set(arr.index_mut(mid as usize), ty_dense(ty), r);
}

/// Bucket `loans` by their place's base local (counting sort): the loans on local `l` are
/// `flat[start[l]..start[l + 1]]`, in ascending loan id. `cur` is scratch.
pub fn bucket_loans_by_base(
    b: &ir::CoreBody,
    loans: &Vector<Loan>,
    start: &mut Vector<u32>,
    flat: &mut Vector<u32>,
    cur: &mut Vector<u32>,
) {
    let nlc = b.locals.len();
    start.truncate(0);
    start.resize_default(nlc + 1);
    for l in 0..loans.len() {
        let base = b.places.at(loans.at(l).place as usize).base as usize;
        start.set(base + 1, start[base + 1] + 1);
    }
    cur.truncate(0);
    for i in 0..nlc {
        start.set(i + 1, start[i + 1] + start[i]);
        cur.push(start[i]);
    }
    flat.truncate(0);
    flat.resize_default(loans.len());
    for l in 0..loans.len() {
        let base = b.places.at(loans.at(l).place as usize).base as usize;
        flat.set(cur[base] as usize, l as u32);
        cur.set(base, cur[base] + 1);
    }
}

// The token of `'static` (see `Owner::lt_tok`).
const fn static_tok() u64 {
    return 1u64 << 63 | fnv("'static") & 0x7FFFFFFFFFFFFFFF;
}

// Whether position `k` of classes `cls` has the lifetime token `tk` names (`tc::lt_class_tok`).
const fn lt_class_hit(cls: &Vector<u8>, k: usize, tk: u64) bool {
    let c = (tk >> 32 & 255) as u8;
    if c == LC_OUTER {
        return k as u64 == (tk & 0xFFFFFFFF);
    }
    return cls[k] == c;
}

// Whether positions `a0..a1` of classes `ca` and `b0..b1` of `cb` share a lifetime group.
const fn lt_meet(ca: &Vector<u8>, a0: u32, a1: u32, cb: &Vector<u8>, b0: u32, b1: u32) bool {
    for i in a0..a1 {
        for j in b0..b1 {
            if i as usize < ca.len() && j as usize < cb.len() && ca[i as usize] >= LC_GROUP && ca[i as usize] == cb[j as usize] {
                return true;
            }
        }
    }
    return false;
}

// Whether positions `s0..s1` of `cls` share a lifetime group with a position `base + k` that
// `reach[k]` marks.
const fn lt_meet_where(cls: &Vector<u8>, s0: u32, s1: u32, base: u32, reach: &Vector<bool>) bool {
    for k in 0..reach.len() {
        if reach[k] && lt_meet(cls, s0, s1, cls, base + k as u32, base + k as u32 + 1) {
            return true;
        }
    }
    return false;
}

// Record `sup: sub` in an outlives pair list; an elided or trivial pair says nothing.
fn rel_push(out: &mut Vector<u64>, sup: u64, sub: u64) {
    if sup != 0 && sub != 0 && sup != sub {
        out.push(sup);
        out.push(sub);
    }
}

// Whether two lifetime-token lists share a token.
const fn tokens_meet(a: &Vector<u64>, b: &Vector<u64>) bool {
    for x in 0..a.len() {
        if b.contains(&a[x]) {
            return true;
        }
    }
    return false;
}

/// One statement-order walk of a verified body. Reads happen at a statement's entry point, writes,
/// loan issues, and kills at its exit point, so an assignment's own read never conflicts with the
/// loan or kill it produces.
pub struct Gen {
    pub ow: *mut Owner,
    pub b: *const ir::CoreBody,
    pub mf: *const mp::MoveForest,
    pub f: BodyFacts,
    pub assign_sites: Vector<KillSite>, // every overwrite, paired against loans for kills afterwards
    pub cur_block: u32,
    pub in_caps: bool, // reading closure-capture operands: owned moves record ACC_CAP
    pub calling: bool, // reading a callee-position operand: calling borrows the env, never moves it
    pub plain_copy: bool, // reading an RV_USE operand: a `&mut` place copy consumes the binding
    pub no_drop: bool, // a flow into a closure value that its destruction never reads (`drop_origin`)
    pub copy_out: bool, // reading a call argument whose value holds no borrow
    pub loans: bool, // record origins, loans, accesses, subsets, kills and liveness rows (else moves only)
    pub seen: Vector<u64>, // per-block first-touch words for luse/ldef construction
    pub stores: Vector<StoreVia>, // stores through reference arguments, resolved after the walk
    // Invariant ties (`a << 32 | b` origins) between values that share an interior type argument
    // (`let tx = ch.sender()`), and the stores into such values (`tx.send(x)`), resolved after the walk.
    pub ties: Vector<u64>,
    pub istores: Vector<StoreVia>,
    // Per origin: the placeholder of the closure capture the origin belongs to when the closure
    // captures it by reference (its writes land in the enclosing frame's binding), else BF_NONE.
    pub cap_ph: Vector<u32>,
    pub cap_tags: Vector<CapTag>, // what each closure creation's captures put into the closure value
    pub ext: NodeId, // the extend of the callee whose signature the type walks read (`unself`)
    pub ext_mod: ModuleId,
    pub rel: u64, // the outlives relation of the callee under walk (`Owner::callee_rel`; 0: none)
    // The statement's flows into a destination behind references: subset index << 8 | the edge
    // before the store's lift (`flow_into`, read by `store_through`).
    pub pre_v: Vector<u64>,
}

/// One overwrite site for kill pairing: a place, or a whole local from a storage marker.
pub struct KillSite {
    pub place: ir::PlaceId, // BF_NONE for a whole-local site
    pub local: u32, // BF_NONE for a place site
    pub point: u32,
}

extend BodyFacts {
    /// Facts with no body and no heap storage; `generate_into` fills them.
    pub fn empty() BodyFacts {
        return BodyFacts {
            npoints: 0,
            nmoves: 0,
            block_base: Vector::<u32>::new(),
            norigins: 0,
            nuniversal: 0,
            local_origin: Vector::<u32>::new(),
            origin_local: Vector::<u32>::new(),
            uni_name: Vector::<tok::Span>::new(),
            named: Vector::<u64>::new(),
            arg_universal: Vector::<u32>::new(),
            ret_origin: Vector::<u32>::new(),
            loans: Vector::<Loan>::new(),
            origin_loans: Vector::<u32>::new(),
            loan_next: Vector::<u32>::new(),
            subsets: Vector::<SubsetAt>::new(),
            accesses: Vector::<Access>::new(),
            kills: Vector::<KillAt>::new(),
            clashes: Vector::<ArgClash>::new(),
            events: Vector::<Event>::new(),
            ev_start: Vector::<u32>::new(),
            mev: Vector::<Event>::new(),
            mev_start: Vector::<u32>::new(),
            rep_blk: Vector::<bool>::new(),
            easy_blk: Vector::<bool>::new(),
            easy_use: Vector::<u64>::new(),
            freed: Vector::<u32>::new(),
            observed: Vector::<bool>::new(),
            cuts: Vector::<u64>::new(),
            ewords: 0,
            nlive: 0,
            drop_slot: Vector::<u32>::new(),
            drop_origin: Vector::<u32>::new(),
            lwords: 0,
            luse: Vector::<u64>::new(),
            ldef: Vector::<u64>::new(),
            drop_uses: Vector::<DropUse>::new(),
            dead_free: Vector::<u32>::new(),
        };
    }

    /// Heap bytes kept across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        return (self.block_base.capacity() * sizeof(u32) + self.local_origin.capacity() * sizeof(u32) + self.origin_local.capacity() * sizeof(u32) + self.uni_name.capacity() * sizeof(tok::Span) + self.named.capacity() * sizeof(u64) + self.arg_universal.capacity() * sizeof(u32) + self.ret_origin.capacity() * sizeof(u32) + self.loans.capacity() * sizeof(Loan) + (self.origin_loans.capacity() + self.loan_next.capacity()) * sizeof(u32) + self.subsets.capacity() * sizeof(SubsetAt) + self.accesses.capacity() * sizeof(Access) + self.kills.capacity() * sizeof(KillAt) + self.clashes.capacity() * sizeof(ArgClash) + self.events.capacity() * sizeof(Event) + self.ev_start.capacity() * sizeof(u32) + self.mev.capacity() * sizeof(Event) + self.mev_start.capacity() * sizeof(u32) + self.rep_blk.capacity() * sizeof(bool) + self.easy_blk.capacity() * sizeof(bool) + self.easy_use.capacity() * sizeof(u64) + self.freed.capacity() * sizeof(u32) + self.observed.capacity() * sizeof(bool) + (self.drop_slot.capacity() + self.drop_origin.capacity()) * sizeof(u32) + self.cuts.capacity() * sizeof(u64) + self.luse.capacity() * sizeof(u64) + self.ldef.capacity() * sizeof(u64) + self.drop_uses.capacity() * sizeof(DropUse) + self.dead_free.capacity() * sizeof(u32)) as u64;
    }

    /// Apply destruction `i` (`drop_uses`): when the local may hold a value there (`runs`), its slot
    /// is used at the point; else its storage-death access observes nothing (`dead_free`).
    pub fn drop_use(self: &mut Self, i: usize, runs: bool) {
        let du = *self.drop_uses.at(i);
        if !runs {
            self.dead_free.push(du.access);
            return;
        }
        if !du.seen {
            let k = du.block as usize * self.lwords as usize + (du.slot / 64) as usize;
            self.luse.set(k, self.luse[k] | 1u64 << (du.slot & 63) as u64);
        }
    }

    /// Truncate every vector (keeping heap capacity) and clear scalars, for reuse across bodies.
    pub fn reset(self: &mut Self) {
        self.npoints = 0;
        self.nmoves = 0;
        self.norigins = 0;
        self.nuniversal = 0;
        self.ewords = 0;
        self.nlive = 0;
        self.lwords = 0;
        self.block_base.truncate(0);
        self.local_origin.truncate(0);
        self.origin_local.truncate(0);
        self.uni_name.truncate(0);
        self.named.truncate(0);
        self.arg_universal.truncate(0);
        self.ret_origin.truncate(0);
        self.loans.truncate(0);
        self.origin_loans.truncate(0);
        self.loan_next.truncate(0);
        self.subsets.truncate(0);
        self.accesses.truncate(0);
        self.kills.truncate(0);
        self.clashes.truncate(0);
        self.events.truncate(0);
        self.ev_start.truncate(0);
        self.mev.truncate(0);
        self.mev_start.truncate(0);
        self.rep_blk.truncate(0);
        self.easy_blk.truncate(0);
        self.easy_use.truncate(0);
        self.freed.truncate(0);
        self.observed.truncate(0);
        self.drop_slot.truncate(0);
        self.drop_origin.truncate(0);
        self.cuts.truncate(0);
        self.luse.truncate(0);
        self.ldef.truncate(0);
        self.drop_uses.truncate(0);
        self.dead_free.truncate(0);
    }
}

extend Gen {
    const fn body(self: &Self) &ir::CoreBody {
        return unsafe &*self.b;
    }

    const fn forest(self: &Self) &mp::MoveForest {
        return unsafe &*self.mf;
    }

    const fn owner(self: &Self) &mut Owner {
        return unsafe &mut *self.ow;
    }

    fn number_points(self: &mut Self) {
        let mut acc: u32 = 0;
        let nb = self.body().blocks.len();
        for bi in 0..nb {
            self.f.block_base.push(acc);
            acc += self.body().blocks.at(bi).stmt_len * 2 + 2;
        }
        self.f.npoints = acc;
    }

    const fn stmt_entry(self: &Self, blk: u32, i: u32) u32 {
        return self.f.block_base[blk as usize] + i * 2;
    }

    const fn term_entry(self: &Self, blk: u32) u32 {
        return self.f.block_base[blk as usize] + self.body().blocks.at(blk as usize).stmt_len * 2;
    }

    // The name of lifetime node `lt` of module `m`, empty when elided: absent or `'_`, which
    // names a fresh lifetime at each occurrence.
    fn lt_name(self: &Self, m: ModuleId, lt: NodeId) tok::Span {
        if lt == NODE_NONE {
            return tok::Span::empty();
        }
        let n = self.owner().ast_of(m).at_const(lt);
        if n.kind == NodeKind::NODE_GENERIC_PARAM {
            return self.lt_name(m, n.as_data.generic_param.name);
        }
        if self.owner().span_text_is(m, n.as_data.name.text, "'_") {
            return tok::Span::empty();
        }
        return n.as_data.name.text;
    }

    // The declared lifetime on a parameter/return slot's outermost reference type, or empty.
    fn slot_lifetime(self: &Self, m: ModuleId, slot: NodeId) tok::Span {
        if slot == NODE_NONE {
            return tok::Span::empty();
        }
        let a = self.owner().ast_of(m);
        let tyn = a.slot_type_node(slot);
        if tyn == NODE_NONE || !a.at_const(tyn).is_ref_type() {
            return tok::Span::empty();
        }
        return self.lt_name(m, a.at_const(tyn).as_data.indirect_type.lifetime);
    }

    const fn name_eq(self: &Self, a: tok::Span, bsp: tok::Span) bool {
        if a.end <= a.start || bsp.end <= bsp.start || a.end - a.start != bsp.end - bsp.start {
            return false;
        }
        let s = self.owner().src_of(self.body().module);
        return s.slice(a.start as usize, a.end as usize) == s.slice(bsp.start as usize, bsp.end as usize);
    }

    // Append to `out` the lifetime names the function types inside type node `tyn` (module `m`) fix:
    // those a position names that no enclosing function type's `for<..>` (`binders`) binds,
    // `'static` aside.
    fn fn_type_names(
        self: &Self,
        m: ModuleId,
        tyn: NodeId,
        binders: &mut Vector<NodeId>,
        out: &mut Vector<tok::Span>,
        depth: u32,
    ) {
        if tyn == NODE_NONE || depth > 8 {
            return;
        }
        let a = self.owner().ast_of(m);
        let n = *a.at_const(tyn);
        if n.kind == NodeKind::NODE_FUNCTION_TYPE {
            binders.push(tyn);
            for i in 0..n.as_data.function_type.params.len + n.as_data.function_type.returns.len {
                let sl = if i < n.as_data.function_type.params.len {
                    unsafe a.list(n.as_data.function_type.params)[i as usize];
                } else {
                    unsafe a.list(n.as_data.function_type.returns)[(i - n.as_data.function_type.params.len) as usize];
                };
                self.fn_type_names(m, a.slot_type_node(sl), binders, out, depth + 1);
            }
            let _ = binders.pop();
            return;
        }
        let mut lt = NODE_NONE;
        if n.has_lt_slot() {
            lt = n.as_data.indirect_type.lifetime;
        } else if n.kind == NodeKind::NODE_LIFETIME {
            lt = tyn;
        }
        if lt != NODE_NONE && binders.len() != 0 {
            let nm = self.lt_name(m, lt);
            let mut bound = nm.end <= nm.start || self.owner().span_text_is(m, nm, "'static");
            for b in 0..binders.len() {
                let lts = a.lifetimes_of(binders[b]);
                for i in 0..lts.len {
                    bound = bound || self.name_eq(self.lt_name(m, unsafe a.list(lts)[i as usize]), nm);
                }
            }
            if !bound {
                out.push(nm);
            }
        }
        if n.has_lt_slot() || n.kind == NodeKind::NODE_POINTER_TYPE || n.kind == NodeKind::NODE_DYN_TYPE {
            self.fn_type_names(m, n.as_data.indirect_type.ty, binders, out, depth + 1);
        } else if n.kind == NodeKind::NODE_ARRAY_TYPE {
            self.fn_type_names(m, n.as_data.array_type.element, binders, out, depth + 1);
        } else if n.kind == NodeKind::NODE_TUPLE_TYPE || n.kind == NodeKind::NODE_TYPE_PATH {
            let es = if n.kind == NodeKind::NODE_TUPLE_TYPE {
                n.as_data.array_literal.elements;
            } else {
                n.as_data.type_path.args;
            };
            for i in 0..es.len {
                self.fn_type_names(m, unsafe a.list(es)[i as usize], binders, out, depth + 1);
            }
        }
    }

    // The universal origin for declared name `nm` (empty = always fresh), created on first use.
    fn universal_for(self: &mut Self, nm: tok::Span) u32 {
        if nm.end > nm.start {
            for i in 1..self.f.nuniversal {
                if self.name_eq(self.f.uni_name[i as usize], nm) {
                    return i;
                }
            }
        }
        let id = self.f.norigins;
        self.f.norigins += 1;
        self.f.nuniversal += 1;
        self.f.origin_local.push(BF_NONE);
        self.f.uni_name.push(nm);
        return id;
    }

    fn build_origins(self: &mut Self) {
        if !self.loans {
            return;
        }
        // origin 0 = 'static.
        self.f.norigins = 1;
        self.f.nuniversal = 1;
        self.f.origin_local.push(BF_NONE);
        self.f.uni_name.push(tok::Span::empty());
        let bmod = self.body().module;
        let fnode = self.body().owner.node;
        let nlocals = self.body().locals.len();
        let nrets = self.body().returns;
        let nargs = self.body().args;
        let mut params = NodeList { start: 0, len: 0 };
        let mut rets = NodeList { start: 0, len: 0 };
        if fnode != NODE_NONE {
            let a = self.owner().ast_of(bmod);
            let _ = a.sig_lists(fnode, &mut params, &mut rets);
        }
        for _l in 0..nlocals {
            self.f.arg_universal.push(BF_NONE);
        }
        // Universal placeholders for borrow-carrying arguments, keyed by declared name.
        for i in 0..nargs {
            let l = (nrets + i) as usize;
            if l >= nlocals {
                break;
            }
            let lty = self.body().locals.at(l).ty;
            if !self.owner().carries(bmod, lty) {
                continue;
            }
            let mut nm = tok::Span::empty();
            if i < params.len {
                let slot = unsafe self.owner().ast_of(bmod).list(params)[i as usize];
                nm = self.slot_lifetime(bmod, slot);
            }
            let u = self.universal_for(nm);
            self.f.arg_universal.set(l, u);
        }
        // Return-slot placeholders.
        for r in 0..nrets {
            let lty = self.body().locals.at(r as usize).ty;
            if !self.owner().carries(bmod, lty) {
                self.f.ret_origin.push(BF_NONE);
                continue;
            }
            let mut nm = tok::Span::empty();
            if r < rets.len {
                let slot = unsafe self.owner().ast_of(bmod).list(rets)[r as usize];
                nm = self.slot_lifetime(bmod, slot);
            }
            let u = self.universal_for(nm);
            self.f.ret_origin.push(u);
        }
        // The placeholders of the enclosing function's lifetimes a local's function type names
        // (local, placeholder pairs in `fnames`), before the first inference origin.
        let mut fnames = Vector::<u32>::new();
        let mut names = Vector::<tok::Span>::new();
        let mut binders = Vector::<NodeId>::new();
        for l in 0..nlocals {
            let d = self.body().locals.at(l).decl;
            if d == NODE_NONE || self.owner().ast_of(bmod).at_const(d).kind != NodeKind::NODE_LET || !self.owner().carries(
                bmod,
                self.body().locals.at(l).ty,
            ) {
                continue;
            }
            names.truncate(0);
            self.fn_type_names(
                bmod,
                self.owner().ast_of(bmod).at_const(d).as_data.let_stmt.ty,
                &mut binders,
                &mut names,
                0,
            );
            for k in 0..names.len() {
                fnames.push(l as u32);
                fnames.push(self.universal_for(names[k]));
            }
        }
        // Inference origins: one per borrow-carrying local.
        for l in 0..nlocals {
            let ld = *self.body().locals.at(l);
            if ld.storage == ir::LS_STATIC_REF {
                self.f.local_origin.push(BF_NONE);
                self.f.observed.push(false);
                continue;
            }
            let mut o = BF_NONE;
            // Untyped temps are multi-return call destinations; assume they carry so argument
            // borrows flow through the destructure into the bindings.
            let lcar = self.owner().carries(bmod, ld.ty);
            if lcar || ld.ty == TYPE_NONE && ld.storage == ir::LS_TEMP {
                o = self.f.norigins;
                self.f.norigins += 1;
                self.f.origin_local.push(l as u32);
            }
            self.f.observed.push(
                lcar && self.owner().owns(self.body().owner, bmod, ld.ty) && self.owner().observes(bmod, ld.ty),
            );
            self.f.local_origin.push(o);
        }
        // A closure local whose destruction observes stored borrows gets a drop origin: what its
        // owned captures hold, live where it is destroyed, while what it only refers to (a capture
        // taken by reference) ends at its last use, as Rust drops a closure's fields.
        self.f.nlive = nlocals as u32;
        for l in 0..nlocals {
            let mut d = BF_NONE;
            if self.f.local_origin[l] != BF_NONE && self.f.observed[l] && self.closure_ty(self.body().locals.at(l).ty) {
                d = self.f.norigins;
                self.f.norigins += 1;
                self.f.origin_local.push(self.f.nlive);
                self.f.drop_slot.push(self.f.nlive);
                self.f.nlive += 1;
                if self.f.arg_universal[l] != BF_NONE {
                    self.f.subsets.push(SubsetAt { from: self.f.arg_universal[l], to: d, point: 0, delta: SD_KEEP });
                }
            } else {
                self.f.drop_slot.push(BF_NONE);
            }
            self.f.drop_origin.push(d);
        }
        // A local annotated with a function type naming the enclosing function's lifetimes holds
        // them: a call through it stores its arguments there (`sig_call`).
        for k in 0..fnames.len() / 2 {
            let o = self.f.local_origin[fnames[2 * k] as usize];
            if o != BF_NONE {
                self.f.subsets.push(SubsetAt { from: fnames[2 * k + 1], to: o, point: 0, delta: SD_KEEP });
            }
        }
        // Loans arriving through arguments: placeholder flows into the argument's own origin. A
        // mutable-reference argument also flows back out (stores through it reach the caller).
        for l in 0..nlocals {
            if self.f.arg_universal[l] == BF_NONE || self.f.local_origin[l] == BF_NONE {
                continue;
            }
            self.f.subsets.push(
                SubsetAt { from: self.f.arg_universal[l], to: self.f.local_origin[l], point: 0, delta: SD_KEEP },
            );
            // No omnipresent backflow edge in this direction: a store through the argument (a
            // call's, an assignment's) flows into the placeholder at the store (`resolve_stores`).
        }
        // A closure's capture taken by `&mut` is the enclosing frame's binding, and one it holds by
        // value lives in the closure value across calls: what the body stores into either lands in
        // storage that outlives the call (`subset_d`, `push_loan`).
        if fnode != NODE_NONE && self.owner().ast_of(bmod).at_const(fnode).kind == NodeKind::NODE_CLOSURE {
            let cf = self.owner().ast_of(bmod).closure_fact(fnode);
            if cf != null && unsafe (&*cf).ncaps != 0 {
                self.cap_ph.resize_default(self.f.norigins as usize);
                for o in 0..self.f.norigins as usize {
                    self.cap_ph.set(o, BF_NONE);
                }
                for k in 0..unsafe (&*cf).ncaps {
                    let l = (nrets + params.len + k) as usize;
                    let shared = k < 64 && (unsafe (&*cf).ref_caps >> k as u64 & 1u64) != 0;
                    if !shared && l < nlocals && self.f.arg_universal[l] != BF_NONE && self.f.local_origin[l] != BF_NONE {
                        self.cap_ph.set(self.f.local_origin[l] as usize, self.f.arg_universal[l]);
                    }
                }
            }
        }
    }

    const fn place_of(self: &Self, p: ir::PlaceId) ir::Place {
        return *self.body().places.at(p as usize);
    }

    const fn origin_of_place(self: &Self, p: ir::PlaceId) u32 {
        if !self.loans {
            return BF_NONE;
        }
        return self.f.local_origin[self.place_of(p).base as usize];
    }

    // The kind of type `ty` (module `m`) as an argument: a borrowed `dyn` (`&dyn I`, `&mut dyn I`)
    // is a reference, passed as it is, never autoref'd.
    const fn ref_kind(self: &Self, m: ModuleId, ty: TypeId) TypeKind {
        let y = self.owner().ast_of(m).type_at(ty);
        if y.kind == TypeKind::TYPE_DYN && y.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 {
            return TypeKind::TYPE_REFERENCE;
        }
        return y.kind;
    }

    // A place rooted in or reached through a raw pointer belongs to the unsafe world: accesses are
    // recorded, but no tracked loan ever forms on it. A raw pointer's only projections reach its
    // pointee: a dereference, or an index (`p[i]`, as `*(p + i)`).
    const fn behind_raw(self: &Self, pid: ir::PlaceId) bool {
        let pl = self.place_of(pid);
        let a = self.owner().ast_of(self.body().module);
        let mut prev = self.body().locals.at(pl.base as usize).ty;
        if prev != TYPE_NONE && a.type_at(prev).kind == TypeKind::TYPE_POINTER {
            return true;
        }
        for i in 0..pl.proj_len {
            let pj = *self.body().projections.at((pl.proj_start + i) as usize);
            if prev != TYPE_NONE && a.type_at(prev).kind == TypeKind::TYPE_POINTER {
                return true;
            }
            prev = pj.ty;
        }
        return false;
    }

    // Is `ty` (the body's pool) a view value: a `[]T`, a `[]mut T` or a `str`? Its elements are the
    // storage it borrows, not its own.
    const fn view_ty(self: &Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let a = self.owner().ast_of(self.body().module);
        let y = a.type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT {
            return y.as_data.decl == self.owner().str_def.node && y.module == self.owner().str_def.module;
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = a.instance(y.as_data.inst);
        return it.module == self.owner().slice.module && it.decl == self.owner().slice.node || it.module == self.owner().slice_mut.module && it.decl == self.owner().slice_mut.node;
    }

    // The reference levels place `p` passes on the way to its storage: each dereference, and each
    // index into a view value (`s[i]` of a `[]T` is the viewed storage, as `(*r)[i]` is).
    const fn ref_steps(self: &Self, p: ir::PlaceId) u32 {
        let pl = self.place_of(p);
        let mut prev = self.body().locals.at(pl.base as usize).ty;
        let mut n: u32 = 0;
        for i in 0..pl.proj_len {
            let pj = *self.body().projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF || (pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST) && self.view_ty(
                prev,
            ) {
                n += 1;
            }
            prev = pj.ty;
        }
        return n;
    }

    // Does place `p` reach storage through a reference or a view (`ref_steps`)?
    const fn behind(self: &Self, p: ir::PlaceId) bool {
        return self.ref_steps(p) != 0;
    }

    // Is the place's value a `[]mut T` view: an argument of it hands the callee its elements to write,
    // as a `&mut` does?
    const fn mut_view_place(self: &Self, pid: ir::PlaceId) bool {
        return self.mut_view_ty(self.place_of(pid).ty);
    }

    // Is `ty` (the body's pool) a `[]mut T` view?
    const fn mut_view_ty(self: &Self, ty: TypeId) bool {
        let a = self.owner().ast_of(self.body().module);
        if ty == TYPE_NONE || a.type_at(ty).kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = a.instance(a.type_at(ty).as_data.inst);
        return it.decl == self.owner().slice_mut.node && it.module == self.owner().slice_mut.module;
    }

    // Is the place's value a `&mut` reference (the only reference whose pointee a reborrow can
    // conflict over)?
    const fn mut_ref_place(self: &Self, pid: ir::PlaceId) bool {
        let ty = self.place_of(pid).ty;
        if ty == TYPE_NONE {
            return false;
        }
        let y = self.owner().ast_of(self.body().module).type_at(ty);
        return y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
    }

    // True when the place derefs a SHARED reference on the way: a `&mut` of such a place is the
    // language's unsafe interior-mutability escape (type checking already demanded the `unsafe`),
    // so no loan tracks it: exactly like a raw-pointer base.
    fn shared_deref(self: &Self, p: ir::PlaceId) bool {
        let pl = self.place_of(p);
        let mut prev = self.body().locals.at(pl.base as usize).ty;
        for i in 0..pl.proj_len {
            let pj = *self.body().projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF && prev != TYPE_NONE {
                let y = *self.owner().ast_of(self.body().module).type_at(prev);
                if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    return true;
                }
            }
            prev = pj.ty;
        }
        return false;
    }

    fn live_use(self: &mut Self, l: ir::LocalId) {
        if !self.loans {
            return;
        }
        let w = (l / 64) as usize;
        let bit = 1u64 << (l & 63);
        let base = self.cur_block as usize * self.f.lwords as usize;
        if (self.seen[w] & bit) == 0 {
            self.f.luse.set(base + w, self.f.luse[base + w] | bit);
        }
    }

    fn live_def(self: &mut Self, l: ir::LocalId) {
        if !self.loans {
            return;
        }
        let w = (l / 64) as usize;
        let bit = 1u64 << (l & 63);
        let base = self.cur_block as usize * self.f.lwords as usize;
        self.f.ldef.set(base + w, self.f.ldef[base + w] | bit);
        self.seen.set(w, self.seen[w] | bit);
        // A new value of a closure local ends the destruction its drop origin stands for.
        if l as usize < self.f.drop_slot.len() && self.f.drop_slot[l as usize] != BF_NONE {
            self.live_def(self.f.drop_slot[l as usize]);
        }
    }

    // Record a new loan (not yet activated) as its origin's newest.
    fn push_loan(
        self: &mut Self,
        pin: bool,
        deref: bool,
        level: u8,
        place: ir::PlaceId,
        kind: u8,
        origin: u32,
        issued_at: u32,
        span: tok::Span,
    ) {
        let o = origin as usize;
        while self.f.origin_loans.len() <= o {
            self.f.origin_loans.push(BF_NONE);
        }
        self.f.loan_next.push(self.f.origin_loans[o]);
        self.f.origin_loans.set(o, self.f.loans.len() as u32);
        if o < self.cap_ph.len() && self.cap_ph[o] != BF_NONE {
            // Issued into a `&mut` capture: the enclosing frame's binding holds it.
            self.f.subsets.push(SubsetAt { from: origin, to: self.cap_ph[o], point: issued_at, delta: SD_KEEP });
        }
        // Issued into a closure value: its destruction reads it unless the value only refers to it.
        let d = self.drop_of(origin);
        if d != BF_NONE && !self.no_drop {
            self.push_loan(pin, deref, level, place, kind, d, issued_at, span);
        }
        self.f.loans.push(
            Loan {
                through: deref || self.behind(place),
                pin: pin,
                deref: deref,
                level: level,
                place: place,
                kind: kind,
                origin: origin,
                issued_at: issued_at,
                activated_at: BF_NONE,
                span: span,
            },
        );
    }

    // A view of type `vty` read out of place `pl` pins the container when the view carries borrows,
    // the container does not, and the frame owns the container (no raw base, no deref on the way).
    fn pin_view(self: &mut Self, pl: ir::PlaceId, vty: TypeId, dor: u32, level: u8, exit: u32, sp: tok::Span) {
        let bty = self.body().locals.at(self.place_of(pl).base as usize).ty;
        let m = self.body().module;
        if bty != TYPE_NONE && !self.behind_raw(pl) && !self.behind(pl) && self.owner().carries(m, vty) && !self.owner().carries(
            m,
            bty,
        ) {
            self.push_loan(true, false, level, pl, LK_SHARED, dor, exit, sp);
        }
    }

    // The reference level a value stored into place `p` sits at in its local's origin.
    const fn store_level(self: &Self, p: ir::PlaceId) u8 {
        return sd_level(self.store_edge(p), 0) as u8;
    }

    // The newest loan of origin `o` (BF_NONE: none, or `o` is BF_NONE).
    const fn origin_first_loan(self: &Self, o: u32) u32 {
        if o as usize >= self.f.origin_loans.len() {
            return BF_NONE;
        }
        return self.f.origin_loans[o as usize];
    }

    @always_inline
    fn access(self: &mut Self, place: ir::PlaceId, local: u32, kind: u8, point: u32, sp: tok::Span) {
        if self.loans {
            self.f.accesses.push(
                Access {
                    place: place,
                    local: local,
                    kind: kind,
                    copy_out: self.copy_out,
                    def: false,
                    point: point,
                    span: sp,
                },
            );
        }
    }

    // A flow of value edge `v` stored into place `dst` (origin `to`): the edge takes the store's lift,
    // and a store behind references records `v` for `store_through`, which the lift would hide.
    fn flow_into(self: &mut Self, from: u32, to: u32, point: u32, v: u8, dst: ir::PlaceId) {
        let k = self.f.subsets.len();
        self.subset_d(from, to, point, sd_then(v, self.store_edge(dst)));
        if self.f.subsets.len() > k && self.behind(dst) {
            self.pre_v.push(k as u64 << 8 | v as u64);
        }
    }

    fn subset(self: &mut Self, from: u32, to: u32, point: u32) {
        self.subset_d(from, to, point, SD_KEEP);
    }

    fn subset_d(self: &mut Self, from: u32, to: u32, point: u32, delta: u8) {
        if from == BF_NONE || to == BF_NONE || from == to {
            return;
        }
        self.f.subsets.push(SubsetAt { from: from, to: to, point: point, delta: delta });
        // What flows into a closure value reaches its destruction too, unless its creation says the
        // value only refers to it (`no_drop`); from another one, what reaches that one's.
        let dt = self.drop_of(to);
        if dt != BF_NONE && !self.no_drop {
            let df = self.drop_of(from);
            self.f.subsets.push(
                SubsetAt {
                    from: if df != BF_NONE {
                        df;
                    } else {
                        from;
                    },
                    to: dt,
                    point: point,
                    delta: delta,
                },
            );
        }
        if to as usize < self.cap_ph.len() && self.cap_ph[to as usize] != BF_NONE && self.cap_ph[to as usize] != from {
            self.f.subsets.push(SubsetAt { from: from, to: self.cap_ph[to as usize], point: point, delta: delta });
        }
    }

    // Whether `t` (this body's module) is a closure's type.
    const fn closure_ty(self: &Self, t: TypeId) bool {
        let y = *self.owner().ast_of(self.body().module).type_at(t);
        return y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig() && self.owner().ast_of(y.module).at_const(
            y.as_data.decl,
        ).kind == NodeKind::NODE_CLOSURE;
    }

    // The drop origin of the closure local origin `o` belongs to, or BF_NONE.
    const fn drop_of(self: &Self, o: u32) u32 {
        let l = self.f.origin_local[o as usize];
        if l == BF_NONE || l as usize >= self.f.drop_origin.len() {
            return BF_NONE;
        }
        return self.f.drop_origin[l as usize];
    }

    // A store of origin `from` through an argument of origin `via`: into a frame-owned container
    // at once, else into the storage the reference reaches once the body's facts exist. `through`:
    // the container may store the value on through its own references (`member_bounds`).
    // `more`: the `&mut` levels past the container the store goes on through (`store_more`).
    fn store(self: &mut Self, from: u32, via: u32, owned: bool, point: u32, e: u8, te: u8, through: bool, more: u8) {
        if owned {
            self.subset_d(from, via, point, sd_then(e, te));
            self.interior_store(from, via, point, e, te);
            if through {
                self.stores.push(
                    StoreVia {
                        from: from,
                        via: via,
                        point: point,
                        e: e,
                        te: te,
                        inner: false,
                        more: 0,
                        cnode: NODE_NONE,
                        caps: 0,
                    },
                );
            }
            if more != 0 {
                // The frame's container is the first level: what its references reach takes the rest.
                let te2 = sd_lift(more - 1);
                self.stores.push(
                    StoreVia {
                        from: from,
                        via: via,
                        point: point,
                        e: e,
                        te: te2,
                        inner: false,
                        more: more - 1,
                        cnode: NODE_NONE,
                        caps: 0,
                    },
                );
            }
        } else {
            self.stores.push(
                StoreVia {
                    from: from,
                    via: via,
                    point: point,
                    e: e,
                    te: te,
                    inner: through,
                    more: more,
                    cnode: NODE_NONE,
                    caps: 0,
                },
            );
        }
    }

    // The tokens of the type arguments type node `tn` (module `cm`) keeps interior (`interior_mask`):
    // what a shared reference to such a value can store.
    fn interior_tokens(self: &mut Self, cm: ModuleId, tn0: NodeId, out: &mut Vector<u64>) {
        if tn0 == NODE_NONE {
            return;
        }
        let tn = self.unself(cm, tn0);
        let n = *self.owner().ast_of(cm).at_const(tn);
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return;
        }
        let d = self.owner().ast_of(cm).path_def(tn);
        if d.node == NODE_NONE {
            return;
        }
        let mask = self.owner().interior_mask(d.module, d.node, 0);
        if mask == 0 {
            return;
        }
        let args = n.as_data.type_path.args;
        let mut k: u64 = 0;
        for i in 0..args.len {
            let aid = unsafe self.owner().ast_of(cm).list(args)[i as usize];
            if self.owner().ast_of(cm).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                continue;
            }
            if k < 64 && (mask >> k & 1u64) != 0 {
                self.lt_tokens(cm, aid, out, 0);
            }
            k += 1;
        }
    }

    // The pointee of reference type node `tn` (module `cm`), else `tn`.
    const fn pointee_node(self: &Self, cm: ModuleId, tn: NodeId) NodeId {
        let pn = self.owner().ast_of(cm).at_const(tn);
        if pn.is_ref_type() {
            return pn.as_data.indirect_type.ty;
        }
        return tn;
    }

    // The `&mut` levels of pointee type `tn` (module `cm`) a store of a value with tokens `itok` passes
    // through: `&'b mut &'a T` takes an `'a` value one level down.
    fn store_more(self: &mut Self, cm: ModuleId, tn: NodeId, itok: &Vector<u64>) u8 {
        let mut n: u8 = 0;
        let mut cur = tn;
        let mut tk = replace(&mut self.owner().sc_tok_c, Vector::<u64>::new());
        while n < 255 && cur != NODE_NONE {
            let pn = *self.owner().ast_of(cm).at_const(cur);
            if pn.kind != NodeKind::NODE_REFERENCE_TYPE || pn.as_data.indirect_type.qualifier != TypeQualifier::TYPE_QUAL_MUT {
                break;
            }
            tk.truncate(0);
            self.lt_tokens(cm, pn.as_data.indirect_type.ty, &mut tk, 0);
            if !tokens_meet(&tk, itok) {
                break;
            }
            n += 1;
            cur = pn.as_data.indirect_type.ty;
        }
        self.owner().sc_tok_c = tk;
        return n;
    }

    // An assignment through a reference (`place` dereferences on the way) of a value that can hold
    // a borrow stores the value into the storage the reference reaches: each edge the statement
    // added into the reference's origin since `mark` becomes a store, and so does a value the
    // statement reads from the reference's own local (`*p.x = p.y`), which adds no edge. The value
    // lands in the reached storage at its own level when the place dereferences once, else behind a
    // reference.
    fn store_through(self: &mut Self, s: &ir::Statement, mark: usize, entry: u32) {
        let place = s.place;
        if !self.loans || !self.behind(place) || self.behind_raw(place) || !self.owner().carries(
            self.body().module,
            self.place_of(place).ty,
        ) {
            return;
        }
        let dor = self.origin_of_place(place);
        if dor == BF_NONE {
            return;
        }
        let pl = self.place_of(place);
        let derefs = self.ref_steps(place);
        let te = sd_lift(derefs - 1);
        let more = (derefs - 1).min(255) as u8;
        let inner = (self.place_bounds(place) & MB_THROUGH) != 0;
        for k in mark..self.f.subsets.len() {
            let sb = *self.f.subsets.at(k);
            if sb.to == dor && sb.from != dor {
                // The edge lifted the value behind the references; the store keeps its own level.
                let mut e = sd_unlift(sb.delta, derefs);
                for j in 0..self.pre_v.len() {
                    if (self.pre_v[j] >> 8) as usize == k {
                        e = (self.pre_v[j] & 0xFFu64) as u8;
                    }
                }
                self.stores.push(
                    StoreVia {
                        from: sb.from,
                        via: dor,
                        point: entry,
                        e: e,
                        te: te,
                        inner: inner,
                        more: more,
                        cnode: NODE_NONE,
                        caps: 0,
                    },
                );
            }
        }
        let rv = *self.body().rvalues.at(s.rvalue as usize);
        let start = rv.a;
        let mut len: u32 = 0;
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_DYN || rv.kind == ir::RV_REPEAT {
            len = 1;
        } else if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE {
            len = rv.b;
        }
        for i in 0..len {
            let oi = if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE {
                self.body().oper_pool[(start + i) as usize];
            } else {
                start;
            };
            if oi == ir::IR_NONE {
                continue;
            }
            let op = *self.body().operands.at(oi as usize);
            if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && self.place_of(op.data).base == pl.base && self.owner().carries(
                self.body().module,
                self.place_of(op.data).ty,
            ) {
                self.stores.push(
                    StoreVia {
                        from: dor,
                        via: dor,
                        point: entry,
                        e: self.place_edge(op.data),
                        te: te,
                        inner: inner,
                        more: more,
                        cnode: NODE_NONE,
                        caps: 0,
                    },
                );
            }
        }
    }

    // The struct or enum a value of type `ty` (the body's pool) is, or an instance of; NODE_NONE else.
    fn agg_decl(self: &Self, ty: TypeId) DefId {
        if ty == TYPE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let a = self.owner().ast_of(self.body().module);
        let y = a.type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return DefId { module: y.module, node: y.as_data.decl };
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = a.instance(y.as_data.inst);
            return DefId { module: it.module, node: it.decl };
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // What a value stored into a member of type node `ftn` of struct or enum `d` must outlive besides
    // its container: MB_STATIC when the type names `'static` or a lifetime `d` bounds by it (`struct
    // S<'a: 'static>`), MB_THROUGH when it names a lifetime `d` declares to outlive another of its own
    // (`struct S<'a, 'b: 'a>`): the container's code (its `Free`) may store the value on through the
    // container's references.
    fn member_bounds(self: &mut Self, d: DefId, ftn: NodeId) u8 {
        let rel = self.owner().decl_rel(d);
        let mut stat = replace(&mut self.owner().sc_stat, Vector::<u64>::new());
        self.owner().rel_static(rel, &mut stat);
        let mut r: u8 = 0;
        if self.names_static(d.module, ftn, &stat, 0) {
            r = MB_STATIC;
        }
        if (rel & 0xFFFF) != 0 {
            stat.truncate(0);
            self.lt_tokens(d.module, ftn, &mut stat, 0);
            if self.owner().rel_sup_in(rel, &stat) {
                r = r | MB_THROUGH;
            }
        }
        self.owner().sc_stat = stat;
        return r;
    }

    // The `member_bounds` of every member place `pid`'s path selects (a struct field, or a variant's
    // payload element after its downcast).
    fn place_bounds(self: &mut Self, pid: ir::PlaceId) u8 {
        let pl = self.place_of(pid);
        let mut prev = self.body().locals.at(pl.base as usize).ty;
        let mut enm = DefId { module: 0, node: NODE_NONE };
        let mut var = NODE_NONE;
        let mut r: u8 = 0;
        for i in 0..pl.proj_len {
            let pj = *self.body().projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DOWNCAST {
                enm = self.agg_decl(prev);
                var = pj.sub;
            } else if pj.kind == ir::PJ_FIELD {
                let d = if var != NODE_NONE {
                    enm;
                } else {
                    self.agg_decl(prev);
                };
                let ftn = self.member_type_node(d, var, pj.data, pj.sub);
                if ftn != NODE_NONE {
                    r = r | self.member_bounds(d, ftn);
                }
                var = NODE_NONE;
            } else {
                var = NODE_NONE;
            }
            prev = pj.ty;
        }
        return r;
    }

    // The type node of a member of struct `d` (field decl `field`, else positional member `idx`), or of
    // payload element `idx` of variant `var` of enum `d`; NODE_NONE when the member is not found.
    fn member_type_node(self: &Self, d: DefId, var: NodeId, idx: u32, field: NodeId) NodeId {
        if d.node == NODE_NONE {
            return NODE_NONE;
        }
        let a = self.owner().ast_of(d.module);
        let mut ms = NodeList { start: 0, len: 0 };
        if var != NODE_NONE {
            if a.at_const(var).kind != NodeKind::NODE_VARIANT {
                return NODE_NONE;
            }
            ms = a.at_const(var).as_data.variant.payload;
        } else if a.at_const(d.node).kind == NodeKind::NODE_STRUCT {
            if field != NODE_NONE && a.at_const(field).kind == NodeKind::NODE_FIELD {
                return a.at_const(field).as_data.field.ty;
            }
            ms = a.at_const(d.node).as_data.aggregate.members;
        }
        if idx >= ms.len {
            return NODE_NONE;
        }
        let e = unsafe a.list(ms)[idx as usize];
        if a.at_const(e).kind == NodeKind::NODE_FIELD {
            return a.at_const(e).as_data.field.ty;
        }
        return e;
    }

    // Does a value of type `ty` store what it holds on through its own references: a struct or enum
    // declaring one of its lifetimes to outlive another (see `member_bounds`)?
    fn type_through(self: &mut Self, ty: TypeId) bool {
        let d = self.agg_decl(ty);
        return d.node != NODE_NONE && self.owner().rel_sup_any(self.owner().decl_rel(d));
    }

    // Member `i` of aggregate `rv` takes the value of place `vp` (origin `aor`) into destination `dst`
    // (origin `dor`): a member `member_bounds` marks sends it into `'static`, or on through the
    // aggregate's references.
    fn member_value(
        self: &mut Self,
        rv: &ir::Rvalue,
        i: u32,
        aor: u32,
        vp: ir::PlaceId,
        dor: u32,
        dst: ir::PlaceId,
        entry: u32,
    ) {
        let d = self.agg_decl(rv.target);
        if d.node == NODE_NONE {
            return;
        }
        let mut var = NODE_NONE;
        let mut field = NODE_NONE;
        if rv.c == ir::AGG_VARIANT {
            var = rv.item.node;
        } else {
            let a = self.owner().ast_of(d.module);
            if a.at_const(d.node).kind != NodeKind::NODE_STRUCT || i >= a.at_const(d.node).as_data.aggregate.members.len {
                return;
            }
            field = unsafe a.list(a.at_const(d.node).as_data.aggregate.members)[i as usize];
        }
        let ftn = self.member_type_node(d, var, i, field);
        if ftn == NODE_NONE {
            return;
        }
        let mb = self.member_bounds(d, ftn);
        let e = self.place_edge(vp);
        if (mb & MB_STATIC) != 0 {
            self.subset_d(aor, 0, entry, e);
        }
        if (mb & MB_THROUGH) != 0 {
            self.stores.push(
                StoreVia {
                    from: aor,
                    via: dor,
                    point: entry,
                    e: e,
                    te: SD_KEEP,
                    inner: self.behind(dst),
                    more: 0,
                    cnode: NODE_NONE,
                    caps: 0,
                },
            );
        }
    }

    // A store into a member `place_bounds` marks: the stored value (each edge the statement added into
    // the destination's origin since `mark`) flows into `'static` (MB_STATIC) and, into a frame-owned
    // container, on through the container's references (MB_THROUGH; `store_through` marks a store
    // through a reference).
    fn member_store(self: &mut Self, s: &ir::Statement, mark: usize) {
        let dor = self.origin_of_place(s.place);
        if !self.loans || dor == BF_NONE || self.place_of(s.place).proj_len == 0 || self.behind_raw(s.place) {
            return;
        }
        let pb = self.place_bounds(s.place);
        if pb == 0 {
            return;
        }
        let owned = !self.behind(s.place);
        for k in mark..self.f.subsets.len() {
            let sb = *self.f.subsets.at(k);
            if sb.to != dor || sb.from == dor || sb.from == 0 {
                continue;
            }
            if (pb & MB_STATIC) != 0 {
                self.subset_d(sb.from, 0, sb.point, sb.delta);
            }
            if (pb & MB_THROUGH) != 0 && owned {
                self.stores.push(
                    StoreVia {
                        from: sb.from,
                        via: dor,
                        point: sb.point,
                        e: sb.delta,
                        te: SD_KEEP,
                        inner: false,
                        more: 0,
                        cnode: NODE_NONE,
                        caps: 0,
                    },
                );
            }
        }
    }

    // Resolve each store through a reference to the storage the reference reaches. An origin
    // reaches the place of each of its loans (through a reborrow's reference, what that reference
    // reaches) and what each of its KEEP sources (copies, reborrows) reaches; an argument
    // placeholder is caller storage. Flow-insensitive, like NLL's outlives constraints: a
    // reference that may reach several containers stores into each. An origin that reaches
    // nothing known takes the store behind its own reference level.
    // A store into a value with an interior type argument lands in every value tied to it
    // (`ties`), flow-insensitively: the sender, the channel and the receiver share one buffer.
    fn resolve_interior(self: &mut Self) {
        if self.istores.len() == 0 || self.ties.len() == 0 {
            return;
        }
        let no = self.f.norigins as usize;
        // Copies between values of interior types carry the tie: `let tx = ch.sender()` copies the
        // result into `tx`.
        let nt = self.ties.len();
        for k in 0..self.f.subsets.len() {
            let e = *self.f.subsets.at(k);
            if sd_keeps(e.delta) && self.interior_origin(e.from) && self.interior_origin(e.to) {
                self.ties.push(e.from as u64 << 32 | e.to as u64);
            }
        }
        let mut seen = Vector::<bool>::new();
        let mut stack = Vector::<u32>::new();
        for si in 0..self.istores.len() {
            let st = *self.istores.at(si);
            seen.truncate(0);
            seen.resize_default(no);
            stack.truncate(0);
            seen.set(st.via as usize, true);
            stack.push(st.via);
            // Each origin is pushed at most once.
            while stack.len() != 0 {
                let x = stack[stack.len() - 1];
                stack.truncate(stack.len() - 1);
                for k in 0..self.ties.len() {
                    let a = (self.ties[k] >> 32) as u32;
                    let b = (self.ties[k] & 0xFFFFFFFFu64) as u32;
                    let y = if a == x {
                        b;
                    } else if b == x {
                        a;
                    } else {
                        BF_NONE;
                    };
                    if y != BF_NONE && !seen[y as usize] {
                        seen.set(y as usize, true);
                        stack.push(y);
                        self.subset_d(st.from, y, st.point, sd_then(st.e, st.te));
                    }
                }
            }
        }
        self.ties.truncate(nt);
    }

    // A store into origin `via` of a value with an interior type also lands in the values tied to it.
    fn interior_store(self: &mut Self, from: u32, via: u32, point: u32, e: u8, te: u8) {
        if self.interior_origin(via) {
            self.istores.push(
                StoreVia {
                    from: from,
                    via: via,
                    point: point,
                    e: e,
                    te: te,
                    inner: false,
                    more: 0,
                    cnode: NODE_NONE,
                    caps: 0,
                },
            );
        }
    }

    // Does origin `o` belong to a local whose type keeps a type argument interior (`interior_mask`)?
    fn interior_origin(self: &mut Self, o: u32) bool {
        if o >= self.f.norigins {
            return false;
        }
        let l = self.f.origin_local[o as usize];
        if l == BF_NONE || l as usize >= self.body().locals.len() {
            return false;
        }
        let d = self.agg_decl(self.body().locals.at(l as usize).ty);
        return d.node != NODE_NONE && self.owner().interior_mask(d.module, d.node, 0) != 0;
    }

    // Whether store `st` through a closure passes over loan `l`, or the copy edge from `from` into
    // `to` (`l` BF_NONE): one a capture outside `st.caps` put into the closure value.
    const fn cap_skip(self: &Self, st: &StoreVia, l: u32, from: u32, to: u32) bool {
        if st.cnode == NODE_NONE {
            return false;
        }
        for i in 0..self.cap_tags.len() {
            let t = *self.cap_tags.at(i);
            if t.node == st.cnode && t.k < 64 && (st.caps >> t.k as u64 & 1u64) == 0 && t.loan == l && (l != BF_NONE || t.from == from && t.to == to) {
                return true;
            }
        }
        return false;
    }

    fn resolve_stores(self: &mut Self) {
        let ns = self.stores.len();
        if ns == 0 {
            return;
        }
        let no = self.f.norigins as usize;
        let nsub = self.f.subsets.len();
        // KEEP sources per origin, by counting sort on the target (only the walk's subsets: the
        // resolved edges appended below are no sources).
        let mut start = replace(&mut self.owner().sc_lb_start, Vector::<u32>::new());
        let mut flat = replace(&mut self.owner().sc_lb_flat, Vector::<u32>::new());
        let mut stack = replace(&mut self.owner().sc_curp, Vector::<u32>::new());
        let mut visit = replace(&mut self.owner().sc_visit, Vector::<u64>::new());
        start.truncate(0);
        start.resize_default(no + 1);
        for k in 0..nsub {
            let sb = self.f.subsets.at(k);
            if sd_keeps(sb.delta) {
                start.set(sb.to as usize + 1, start[sb.to as usize + 1] + 1);
            }
        }
        stack.truncate(0);
        for o in 0..no {
            start.set(o + 1, start[o + 1] + start[o]);
            stack.push(start[o]);
        }
        flat.truncate(0);
        flat.resize_default(start[no] as usize);
        for k in 0..nsub {
            let sb = *self.f.subsets.at(k);
            if sd_keeps(sb.delta) {
                flat.set(stack[sb.to as usize] as usize, sb.from);
                stack.set(sb.to as usize, stack[sb.to as usize] + 1);
            }
        }
        let vw = (no + 63) / 64;
        // A store reaching a container that stores on through its references (MB_THROUGH, `inner`)
        // continues from that container's origin: the walk's stores (the first `ns`) append at most
        // one continuation per loan they reach, and a continuation appends none.
        let mut si: usize = 0;
        while si < self.stores.len() {
            let st = *self.stores.at(si);
            si += 1;
            visit.truncate(0);
            visit.resize_default(vw);
            stack.truncate(0);
            stack.push(st.via);
            bits::bit_set(&mut visit, st.via);
            // Each origin is pushed at most once.
            while stack.len() != 0 {
                let x = stack[stack.len() - 1];
                stack.truncate(stack.len() - 1);
                let mut reached = false;
                let mut l = self.origin_first_loan(x);
                while l != BF_NONE {
                    let lo = *self.f.loans.at(l as usize);
                    let ob = self.f.local_origin[self.place_of(lo.place).base as usize];
                    if ob != BF_NONE && self.cap_skip(&st, l, BF_NONE, BF_NONE) {
                        reached = true;
                    } else if ob != BF_NONE {
                        reached = true;
                        if lo.deref || self.behind(lo.place) {
                            if !bits::bit_get(&visit, ob) {
                                bits::bit_set(&mut visit, ob);
                                stack.push(ob);
                            }
                        } else {
                            self.subset_d(st.from, ob, st.point, sd_then(st.e, st.te));
                            self.interior_store(st.from, ob, st.point, st.e, st.te);
                            let pb = self.place_bounds(lo.place);
                            if (pb & MB_STATIC) != 0 {
                                self.subset_d(st.from, 0, st.point, sd_then(st.e, st.te));
                            }
                            if si <= ns && (st.inner || (pb & MB_THROUGH) != 0) {
                                self.stores.push(
                                    StoreVia {
                                        from: st.from,
                                        via: ob,
                                        point: st.point,
                                        e: st.e,
                                        te: st.te,
                                        inner: false,
                                        more: 0,
                                        cnode: st.cnode,
                                        caps: st.caps,
                                    },
                                );
                            }
                            // A store through more reference levels goes on from what this container
                            // refers to. Past the bound the value must be 'static: over-rejection,
                            // never a lost store.
                            if st.more != 0 {
                                if self.stores.len() < ns * 4 + self.f.loans.len() + 64 {
                                    let te2 = sd_lift(st.more - 1);
                                    self.stores.push(
                                        StoreVia {
                                            from: st.from,
                                            via: ob,
                                            point: st.point,
                                            e: st.e,
                                            te: te2,
                                            inner: false,
                                            more: st.more - 1,
                                            cnode: st.cnode,
                                            caps: st.caps,
                                        },
                                    );
                                } else {
                                    self.subset_d(st.from, 0, st.point, st.e);
                                }
                            }
                        }
                    }
                    l = self.f.loan_next[l as usize];
                }
                for k in start[x as usize]..start[x as usize + 1] {
                    let src = flat[k as usize];
                    reached = true;
                    if self.cap_skip(&st, BF_NONE, src, x) {
                        continue;
                    }
                    if src < self.f.nuniversal {
                        self.subset_d(st.from, src, st.point, sd_then(sd_then(st.e, st.te), SD_REF));
                    } else if !bits::bit_get(&visit, src) {
                        bits::bit_set(&mut visit, src);
                        stack.push(src);
                    }
                }
                if !reached {
                    self.subset_d(st.from, x, st.point, sd_then(sd_then(st.e, st.te), SD_REF));
                }
            }
        }
        self.owner().sc_lb_start = start;
        self.owner().sc_lb_flat = flat;
        self.owner().sc_curp = stack;
        self.owner().sc_visit = visit;
    }

    // The edge a read of place `p` takes: a value read from behind a reference leaves the
    // reference's own loans behind.
    const fn place_edge(self: &Self, p: ir::PlaceId) u8 {
        return sd_sink(self.ref_steps(p));
    }

    // The edge a value stored into place `p` takes: a store through references lands behind each.
    const fn store_edge(self: &Self, p: ir::PlaceId) u8 {
        return sd_lift(self.ref_steps(p));
    }

    // A value read of a place: liveness, init/move event, and the matching access.
    @always_inline
    fn op_read(self: &mut Self, opid: ir::OperandId, point: u32, sp: tok::Span) {
        let op = *self.body().operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return;
        }
        let pl = self.place_of(op.data);
        self.live_use(pl.base);
        // A closure value read whole passes its destruction on (a move or a copy into another
        // closure local): its drop origin stays live to here.
        if self.loans && pl.proj_len == 0 && self.f.drop_slot[pl.base as usize] != BF_NONE {
            self.live_use(self.f.drop_slot[pl.base as usize]);
        }
        let path = self.forest().place_path[op.data as usize];
        let base_st = self.body().locals.at(pl.base as usize).storage;
        if base_st == ir::LS_STATIC_REF {
            return;
        }
        let owned = self.owner().owns(self.body().owner, self.body().module, pl.ty) && !self.calling;
        if owned {
            // A move THROUGH a reference has no full path: it lands on the nearest tracked
            // ancestor (the cut), so overwrite guards learn the maybe-moved state AND the drop
            // rewriter can clear the guard flag at this point.
            let mut mpath = path;
            if mpath == mp::MP_NONE {
                mpath = self.forest().place_cut[op.data as usize];
            }
            if mpath != mp::MP_NONE {
                let mut ak = ACC_MOVE;
                if self.in_caps {
                    ak = ACC_CAP;
                }
                let ek = if mpath == path {
                    EV_MOVE;
                } else {
                    // Through-a-reference: invisible to the checker, real to drops.
                    EV_MOVE_CUT;
                };
                self.push_ev(ek, mpath, point, sp);
                self.access(op.data, BF_NONE, ak, point, sp);
                return;
            }
        }
        // A plain copy of a `&mut` or `[]mut T` place consumes the binding (exclusivity); passing
        // one to a call reborrows instead, so only stored operands take this branch.
        if self.plain_copy && path != mp::MP_NONE && (self.mut_ref_place(op.data) || self.mut_view_place(op.data)) {
            self.push_ev(EV_MOVE, path, point, sp);
            self.access(op.data, BF_NONE, ACC_MOVE, point, sp);
            return;
        }
        let mut upath = path;
        if upath == mp::MP_NONE {
            upath = self.forest().place_cut[op.data as usize];
        }
        if upath != mp::MP_NONE {
            self.push_ev(EV_USE, upath, point, sp);
        }
        self.access(op.data, BF_NONE, ACC_READ, point, sp);
    }

    // A write of a place: liveness def, init event, write access, and a kill site. A whole-local
    // write of an origin-carrying value is a REBIND: earlier flows through that origin end here
    // (the solver's cut), which is what lets `r = p; return r` stop implicating the old borrow.
    fn write_place(self: &mut Self, pid: ir::PlaceId, point: u32, sp: tok::Span) {
        let pl = self.place_of(pid);
        if pl.proj_len == 0 {
            self.live_def(pl.base);
            let org = self.origin_of_place(pid);
            if org != BF_NONE && point > 0 {
                self.f.cuts.push(org as u64 << 32 | (point - 1) as u64);
            }
        } else {
            self.live_use(pl.base);
        }
        let path = self.forest().place_path[pid as usize];
        if path != mp::MP_NONE {
            self.push_ev(EV_ASSIGN, path, point, sp);
        } else {
            // Writing through a dereference READS the pointer: a moved `&mut` used as a store
            // target must still be a use-after-move.
            let upath = self.forest().place_cut[pid as usize];
            if upath != mp::MP_NONE && pl.proj_len != 0 {
                self.push_ev(EV_USE, upath, point - 1, sp);
            }
        }
        if self.loans {
            self.f.accesses.push(
                Access {
                    place: pid,
                    local: BF_NONE,
                    kind: ACC_WRITE,
                    copy_out: false,
                    def: pl.proj_len == 0,
                    point: point,
                    span: sp,
                },
            );
            self.assign_sites.push(KillSite { place: pid, local: BF_NONE, point: point });
        }
    }

    // The function-pointer type of callee operand `op` when it names lifetimes (`TyInstance.lts`):
    // a function pointer's, a `dyn fn`'s signature, a generic parameter's `fn(..)` bound; else
    // TYPE_NONE.
    fn value_sig(self: &Self, op: u32, ckey: &mut u64) TypeId {
        let a = self.owner().ast_of(self.body().module);
        let y = *a.type_at(self.body().operands.at(op as usize).ty);
        let mut sig = TYPE_NONE;
        *ckey = 0;
        if y.fn_sig() {
            sig = self.body().operands.at(op as usize).ty;
        } else if y.kind == TypeKind::TYPE_DYN {
            sig = a.dyn_fn_sig(&y);
        } else if y.kind == TypeKind::TYPE_GENERIC || y.kind == TypeKind::TYPE_FUNCTION {
            let key = y.module as u64 << 32 | y.as_data.decl as u64;
            switch self.owner().gen_sigs.get(&key) {
                Some(v) => {
                    sig = *v;
                },
                None => {},
            };
            if self.owner().gen_cls.contains_key(&key) {
                *ckey = key;
            }
        }
        if sig == TYPE_NONE || !a.type_at(sig).fn_sig() || *ckey == 0 && a.instance(a.type_at(sig).as_data.fnp.sig).lts == 0 {
            return TYPE_NONE;
        }
        return sig;
    }

    // The (sup, sub) token pairs the arguments of the call at `sp` make the callee's lifetimes
    // outlive (`Ast::call_lts`), into `out`.
    fn call_lt_pairs(self: &Self, sp: tok::Span, out: &mut Vector<u64>) {
        let a = self.owner().ast_of(self.body().module);
        let key = sp.start as u64 << 32 | sp.end as u64;
        let mut i = switch a.call_lt_at.get(&key) {
            Some(v) => *v,
            None => 0u32,
        };
        for _ in 0..a.call_lts.len() / 4 {
            if i == 0 {
                return;
            }
            let b = (i - 1) as usize * 4;
            out.push(a.call_lts[b + 1]);
            out.push(a.call_lts[b + 2]);
            i = a.call_lts[b + 3] as u32;
        }
    }

    // Apply to the classes `cls` of a call through a function value at `sp` what its arguments make
    // the value's lifetimes outlive (`lt_class_tok` tokens): `'static` makes their positions
    // `'static`; another of them, one lifetime with it.
    fn call_lt_classes(self: &Self, sp: tok::Span, cls: &mut Vector<u8>) {
        let mut ext = Vector::<u64>::new();
        self.call_lt_pairs(sp, &mut ext);
        for i in 0..ext.len() / 2 {
            let sup = ext[2 * i];
            let sub = ext[2 * i + 1];
            if sup >> 62 != 1 {
                continue;
            }
            let mut fresh = LC_GROUP;
            for k in 0..cls.len() {
                if cls[k] >= LC_GROUP && cls[k] < LC_OUTER {
                    fresh = fresh.max(cls[k] + 1);
                }
            }
            let to = if sub == static_tok() {
                LC_STATIC;
            } else {
                fresh.min(LC_OUTER - 1);
            };
            for k in 0..cls.len() {
                if lt_class_hit(cls, k, sup) || sub >> 62 == 1 && lt_class_hit(cls, k, sub) {
                    cls.set(k, to);
                }
            }
        }
    }

    // A call `t` through a function value of type `sig`, which names lifetimes: the result borrows
    // from the callee value and from each argument at a position whose lifetime a result position
    // has; an argument at a `'static` position flows into `'static`; an argument sharing a lifetime
    // with what a `&mut` argument points at (or the interior of what a shared one points at) is
    // stored there.
    fn sig_call(self: &mut Self, t: &ir::Terminator, sig: TypeId, ckey: u64, entry: u32) {
        let bm = self.body().module;
        let sy = *self.owner().ast_of(bm).type_at(sig);
        let mut cls = Vector::<u8>::new();
        let mut fl = Vector::<u8>::new();
        let mut nres: u32 = 0;
        self.owner().p().sig_classes(
            self.owner().ast_of(bm),
            &sy,
            &mut cls,
            &mut fl,
            &mut nres,
            &mut loader::Invariant {},
        );
        // A closure's classes (`Owner::gen_cls`), which its function type may not hold.
        switch self.owner().gen_cls.get(&ckey) {
            Some(r) => {
                let st = (*r >> 16) as usize;
                for k in 0..cls.len().min((*r & 0xFFFF) as usize) {
                    cls.set(k, self.owner().gen_cls_pool[st + k]);
                }
            },
            None => {},
        };
        self.call_lt_classes(t.span, &mut cls);
        let np = self.owner().ast_of(bm).sig_len(&sy, false).min(t.args_len);
        // Parameter `i`'s positions are `at[i]..at[i + 1]`.
        let mut at = Vector::<u32>::new();
        let mut p = nres;
        for i in 0..np {
            at.push(p);
            p = p + self.owner().p().lt_count(self.owner().ast_of(bm), self.owner().ast_of(bm).sig_at(&sy, false, i));
        }
        at.push(p);
        for d2 in 0..t.dests_len {
            let dor = self.origin_of_place(self.body().dest_pool[(t.dests_start + d2) as usize]);
            if dor == BF_NONE {
                continue;
            }
            if t.a != ir::IR_NONE {
                let cop = *self.body().operands.at(t.a as usize);
                if cop.kind == ir::OP_COPY || cop.kind == ir::OP_MOVE {
                    self.subset_d(self.origin_of_place(cop.data), dor, entry, SD_KEEP_SAT);
                }
            }
            // The classes give no reference depths: what lies behind a reference saturates.
            for i in 0..np {
                let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
                if (oi.kind == ir::OP_COPY || oi.kind == ir::OP_MOVE) && lt_meet(
                    &cls,
                    at[i as usize],
                    at[i as usize + 1],
                    &cls,
                    0,
                    nres,
                ) {
                    self.subset_d(self.origin_of_place(oi.data), dor, entry, SD_KEEP_SAT);
                }
            }
        }
        if !self.loans {
            return;
        }
        for i in 0..np {
            let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
            if oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                continue;
            }
            let s0 = at[i as usize];
            let s1 = at[i as usize + 1];
            // A `'static` position: the whole argument when no reference of the parameter holds it,
            // else what lies behind the argument.
            let mut st = false;
            let mut whole = false;
            for k in s0..s1 {
                if cls[k as usize] == LC_STATIC {
                    st = true;
                    whole = whole || (fl[k as usize] & LTF_REF) == 0;
                }
            }
            if st {
                let e = if whole {
                    SD_KEEP;
                } else {
                    SD_DEREF;
                };
                self.subset_d(self.origin_of_place(oi.data), 0, entry, sd_then(self.place_edge(oi.data), e));
            }
        }
        // An argument at a lifetime fixed outside the type is stored where the callee value keeps
        // that lifetime: the captures of a closure its body stores the parameter into
        // (`Owner::cap_reach`; every capture before its body is checked), or the caller storage a
        // parameter's type names.
        let cop = if t.a != ir::IR_NONE {
            *self.body().operands.at(t.a as usize);
        } else {
            ir::Operand { kind: ir::OP_CONST, data: 0, ty: TYPE_NONE };
        };
        let reach = switch self.owner().cap_reach.get(&ckey) {
            Some(r) => *r,
            None => 0u64,
        };
        let cnode = if reach != 0 {
            (ckey & 0xFFFFFFFFu64) as NodeId;
        } else {
            NODE_NONE;
        };
        if (cop.kind == ir::OP_COPY || cop.kind == ir::OP_MOVE) && !self.behind_raw(cop.data) {
            let tor = self.origin_of_place(cop.data);
            for i in 0..np {
                let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
                if tor == BF_NONE || oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                    continue;
                }
                let aor = self.origin_of_place(oi.data);
                let s0 = at[i as usize];
                let s1 = at[i as usize + 1];
                let mut outer = false;
                for k in s0..s1 {
                    outer = outer || cls[k as usize] >= LC_OUTER;
                }
                if aor == BF_NONE || !outer {
                    continue;
                }
                // The argument's own reference is stored only when its lifetime is the fixed one.
                let mut e = self.place_edge(oi.data);
                let pk = self.owner().ast_of(bm).type_at(self.owner().ast_of(bm).sig_at(&sy, false, i)).kind;
                if (pk == TypeKind::TYPE_REFERENCE || pk == TypeKind::TYPE_SLICE) && cls[s0 as usize] < LC_OUTER {
                    e = sd_then(e, SD_DEREF);
                }
                // Where the callee value keeps the argument, at a depth its type does not give.
                if cnode == NODE_NONE {
                    self.store(aor, tor, false, entry, e, SD_SAT, true, 0);
                    continue;
                }
                let caps = if i < (reach & 0xFFFF) as u32 {
                    self.owner().cap_reach_pool[(reach >> 16) as usize + i as usize];
                } else {
                    0u64;
                };
                if caps == 0 {
                    continue;
                }
                self.stores.push(
                    StoreVia {
                        from: aor,
                        via: tor,
                        point: entry,
                        e: e,
                        te: SD_SAT,
                        inner: true,
                        more: 0,
                        cnode: cnode,
                        caps: caps,
                    },
                );
                // A capture the closure owns holds the argument in the closure value itself.
                if (caps & self.owned_caps(ckey)) == 0 {
                    continue;
                }
                if self.behind(cop.data) {
                    self.stores.push(
                        StoreVia {
                            from: aor,
                            via: tor,
                            point: entry,
                            e: e,
                            te: SD_KEEP,
                            inner: false,
                            more: 0,
                            cnode: cnode,
                            caps: 0,
                        },
                    );
                } else {
                    self.subset_d(aor, tor, entry, e);
                }
            }
        }
        for j in 0..np {
            let pt = self.owner().ast_of(bm).sig_at(&sy, false, j);
            let py = *self.owner().ast_of(bm).type_at(pt);
            if py.kind != TypeKind::TYPE_REFERENCE {
                continue;
            }
            // The positions a store through argument `j` reaches: behind a `&mut`, or in the
            // interior arguments of what a shared reference points at.
            let mut reach = Vector::<bool>::new();
            reach.push(false);
            if py.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                for _ in at[j as usize] + 1..at[j as usize + 1] {
                    reach.push(true);
                }
            } else {
                self.interior_reach(py.as_data.elem, &mut reach);
            }
            let oj = *self.body().operands.at(self.body().oper_pool[(t.args_start + j) as usize] as usize);
            if oj.kind != ir::OP_COPY && oj.kind != ir::OP_MOVE || self.behind_raw(oj.data) {
                continue;
            }
            let jty = self.place_of(oj.data).ty;
            let y = *self.owner().ast_of(bm).type_at(jty);
            let mut pointee_ty = jty;
            if y.kind == TypeKind::TYPE_REFERENCE {
                pointee_ty = y.as_data.elem;
            }
            if y.kind == TypeKind::TYPE_POINTER || !self.owner().carries(bm, pointee_ty) {
                continue;
            }
            let tor = self.origin_of_place(oj.data);
            let owned = y.kind != TypeKind::TYPE_REFERENCE && !self.behind(oj.data);
            let through = self.type_through(pointee_ty);
            let mut behind = Vector::<u8>::new();
            self.owner().p().lt_walk(
                self.owner().ast_of(bm),
                py.as_data.elem,
                0,
                &mut behind,
                0,
                &mut loader::Invariant {},
            );
            for i in 0..np {
                let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
                if i == j || oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                    continue;
                }
                let aor = self.origin_of_place(oi.data);
                let s0 = at[i as usize];
                let s1 = at[i as usize + 1];
                if aor == BF_NONE || !lt_meet_where(&cls, s0, s1, at[j as usize], &reach) {
                    continue;
                }
                // The argument's own reference is stored only when its lifetime is one reached.
                let mut e = self.place_edge(oi.data);
                let it = self.owner().ast_of(bm).type_at(self.owner().ast_of(bm).sig_at(&sy, false, i)).kind;
                if it == TypeKind::TYPE_REFERENCE && !lt_meet_where(&cls, s0, s0 + 1, at[j as usize], &reach) {
                    e = sd_then(e, SD_DEREF);
                }
                // A store reaching a position behind a reference within the pointee lands there, at
                // a depth the classes do not give.
                let mut te = SD_KEEP;
                for k in 0..behind.len() {
                    let pk = at[j as usize] + 1 + k as u32;
                    if (behind[k] & LTF_BEHIND) != 0 && pk as usize < cls.len() && cls[pk as usize] >= LC_GROUP && lt_meet(
                        &cls,
                        s0,
                        s1,
                        &cls,
                        pk,
                        pk + 1,
                    ) {
                        te = SD_SAT;
                    }
                }
                let more = self.sig_store_more(&cls, at[j as usize] + 1, py.as_data.elem, s0, s1);
                self.store(aor, tor, owned, entry, e, te, through, more);
            }
        }
    }

    // The captures closure `ckey` (mod << 32 | node) holds by value and owns: a store into one stays
    // in the closure value.
    fn owned_caps(self: &mut Self, ckey: u64) u64 {
        let m = (ckey >> 32) as ModuleId;
        let c = (ckey & 0xFFFFFFFFu64) as NodeId;
        let cf = self.owner().ast_of(m).closure_fact(c);
        let by_ptr = if cf != null {
            unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
        } else {
            0u64;
        };
        let caps = self.owner().ast_of(m).at_const(c).as_data.closure.captures;
        let mut r: u64 = 0;
        for k in 0..caps.len.min(64) {
            let ty = self.owner().ast_of(m).type_of(unsafe self.owner().ast_of(m).list(caps)[k as usize]);
            if (by_ptr >> k as u64 & 1u64) == 0 && self.owner().owns(self.body().owner, m, ty) {
                r = r | 1u64 << k as u64;
            }
        }
        return r;
    }

    // The `&mut` levels past pointee `pt` (whose positions start at `p0` of `cls`) a store of an
    // argument with positions `s0..s1` passes through: `&mut &'a T` takes an `'a` value one level down.
    fn sig_store_more(self: &Self, cls: &Vector<u8>, p0: u32, pt0: TypeId, s0: u32, s1: u32) u8 {
        let bm = self.body().module;
        let mut n: u8 = 0;
        let mut pt = pt0;
        let mut p = p0;
        while n < 255 {
            let y = *self.owner().ast_of(bm).type_at(pt);
            if y.kind != TypeKind::TYPE_REFERENCE || y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                break;
            }
            let inner = self.owner().p().lt_count(self.owner().ast_of(bm), y.as_data.elem);
            if !lt_meet(cls, s0, s1, cls, p + 1, p + 1 + inner) {
                break;
            }
            n += 1;
            p = p + 1;
            pt = y.as_data.elem;
        }
        return n;
    }

    // Mark in `reach` (one entry per position of the reference's own, then of pointee `pt`) the
    // positions of `pt`'s interior arguments: those its declaration keeps behind an `UnsafeCell`.
    fn interior_reach(self: &mut Self, pt: TypeId, reach: &mut Vector<bool>) {
        let bm = self.body().module;
        let y = *self.owner().ast_of(bm).type_at(pt);
        if y.kind != TypeKind::TYPE_INSTANCE {
            for _ in 0..self.owner().p().lt_count(self.owner().ast_of(bm), pt) {
                reach.push(false);
            }
            return;
        }
        let it = *self.owner().ast_of(bm).instance(y.as_data.inst);
        let mask = self.owner().interior_mask(it.module, it.decl, 0);
        // The declaration's own lifetimes: reachable where it keeps anything behind an `UnsafeCell`.
        for _ in 0..self.owner().p().decl_nlt(self.owner().ast_of(bm), it.module, it.decl) {
            reach.push(mask != 0);
        }
        for i in 0..it.n {
            let c = self.owner().p().lt_count(self.owner().ast_of(bm), unsafe it.args[i as usize]);
            for _ in 0..c {
                reach.push(i < 64 && (mask >> i as u64 & 1u64) != 0);
            }
        }
    }

    // Terminator `t0`, a call through a local holding a function (not a closure, not a function
    // pointer) resolved to that function: the call runs it, so its signature applies.
    fn call_term(self: &Self, t0: ir::Terminator) ir::Terminator {
        let mut t = t0;
        if t.kind != ir::TM_CALL || t.callee.node != NODE_NONE || t.a == ir::IR_NONE {
            return t;
        }
        let y = *self.owner().ast_of(self.body().module).type_at(self.body().operands.at(t.a as usize).ty);
        if y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig() && self.owner().ast_of(y.module).at_const(y.as_data.decl).kind == NodeKind::NODE_FUNCTION {
            t.callee = DefId { module: y.module, node: y.as_data.decl };
        }
        return t;
    }

    // Parameter passing modes for a direct call: 0 = by value, 1 = &, 2 = &mut, 3 = raw pointer.
    // Super-C methods declare `self` explicitly, so terminator arguments align with the callee's
    // parameter list.
    fn arg_kinds(self: &mut Self, callee: DefId, n: u32, out: &mut Vector<u8>) {
        out.clear();
        out.resize_default(n as usize);
        if callee.node == NODE_NONE {
            return;
        }
        let kkey = skey_mix(0, callee.module as u64 << 32 | callee.node as u64);
        let mut hit = false;
        let mut range: u64 = 0;
        switch self.owner().kinds_memo.get(&kkey) {
            Some(v) => {
                hit = true;
                range = *v;
            },
            _ => {},
        };
        if hit {
            let kst = (range >> 16) as usize;
            let kl = (range & 0xFFFF) as u32;
            let mut lim2 = n;
            if kl < lim2 {
                lim2 = kl;
            }
            for i in 0..lim2 {
                out.set(i as usize, self.owner().kinds_pool[kst + i as usize]);
            }
            return;
        }
        let mut tys = replace(&mut self.owner().sc_tys, Vector::<TypeId>::new());
        tys.truncate(0);
        {
            let a = self.owner().ast_of(callee.module);
            let nd = a.at_const(callee.node);
            if nd.kind != NodeKind::NODE_FUNCTION {
                self.owner().sc_tys = tys;
                return;
            }
            let ps = nd.as_data.function.params;
            for i in 0..ps.len {
                let pid = unsafe a.list(ps)[i as usize];
                tys.push(a.type_of(pid));
            }
        }
        let cm = callee.module;
        let kst2 = self.owner().kinds_pool.len();
        for i in 0..tys.len() {
            let t = tys[i];
            let mut k: u8 = 0;
            if t != TYPE_NONE {
                let y = *self.owner().ast_of(cm).type_at(t);
                if y.kind == TypeKind::TYPE_REFERENCE {
                    k = 1;
                    if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                        k = 2;
                    }
                } else if y.kind == TypeKind::TYPE_POINTER {
                    k = 3;
                }
            }
            self.owner().kinds_pool.push(k);
            if i as u32 < n {
                out.set(i, k);
            }
        }
        self.owner().kinds_memo.insert(kkey, kst2 as u64 << 16 | tys.len() as u64);
        self.owner().sc_tys = tys;
    }

    // Can values of `ty` STORE borrows by type: declared lifetime params, or borrow-carrying
    // instance arguments (`Vector<&T>`)? A struct merely embedding a view field has no slot a
    // caller-side store could legally fill, so it is not a store target.
    fn stores_borrows(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.owner().ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.owner().ast_of(y.module).lifetimes_of(y.as_data.decl).len != 0;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.owner().ast_of(mid).instance(y.as_data.inst);
            if self.owner().ast_of(it.module).lifetimes_of(it.decl).len != 0 {
                return true;
            }
            for k in 0..it.n {
                let arg = unsafe it.args[k as usize];
                if self.owner().carries(mid, arg) {
                    return true;
                }
            }
        }
        return false;
    }

    // Collect the lifetime-carrying TOKENS of a type node: FNV hashes of named-lifetime texts and
    // resolved generic-parameter decls. Two parameter positions sharing a token are tied by the
    // callee's signature. Memoized per (module, node): signatures are re-read at every call site.
    fn lt_tokens(self: &mut Self, m: ModuleId, tyn: NodeId, out: &mut Vector<u64>, depth: i32) {
        if tyn == NODE_NONE || depth > 6 {
            return;
        }
        let key = skey_mix(0, m as u64 << 32 | tyn as u64);
        let mut hit = false;
        let mut range: u64 = 0;
        switch self.owner().tok_memo.get(&key) {
            Some(v) => {
                hit = true;
                range = *v;
            },
            _ => {},
        };
        if hit {
            let tst = (range >> 16) as usize;
            for i in 0..range & 0xFFFF {
                let tv = self.owner().tok_pool[tst + i as usize];
                out.push(tv);
            }
            return;
        }
        let mark = out.len();
        self.lt_tokens_walk(m, tyn, out, depth);
        let start = self.owner().tok_pool.len();
        for i in mark..out.len() {
            let tv = out[i];
            self.owner().tok_pool.push(tv);
        }
        self.owner().tok_memo.insert(key, start as u64 << 16 | (out.len() - mark) as u64);
    }

    // The tokens of the arguments of bound list `bs` (module `m`): `Put<'a, X>` gives `'a` and X's;
    // a function type bound `fn() &'a T` the tokens its positions name that its own `for<..>` does
    // not bind: a value of it may return what it holds there.
    fn bound_tokens(self: &mut Self, m: ModuleId, bs: NodeList, out: &mut Vector<u64>, depth: i32) {
        for i in 0..bs.len {
            let b = unsafe self.owner().ast_of(m).list(bs)[i as usize];
            if self.owner().ast_of(m).at_const(b).kind == NodeKind::NODE_FUNCTION_TYPE {
                self.fn_type_tokens(m, b, out, depth);
                continue;
            }
            if self.owner().ast_of(m).at_const(b).kind != NodeKind::NODE_TYPE_PATH {
                continue;
            }
            let args = self.owner().ast_of(m).at_const(b).as_data.type_path.args;
            for j in 0..args.len {
                let aid = unsafe self.owner().ast_of(m).list(args)[j as usize];
                if self.owner().ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    self.lt_name_token(m, aid, out);
                } else {
                    self.lt_tokens(m, aid, out, depth + 1);
                }
            }
        }
    }

    // The tokens function type node `fnn` (module `m`) names in its parameters and results, but for
    // the lifetimes its own `for<..>` binds.
    fn fn_type_tokens(self: &mut Self, m: ModuleId, fnn: NodeId, out: &mut Vector<u64>, depth: i32) {
        let ft = self.owner().ast_of(m).at_const(fnn).as_data.function_type;
        let mark = out.len();
        for i in 0..ft.params.len + ft.returns.len {
            let a = self.owner().ast_of(m);
            let sl = if i < ft.params.len {
                unsafe a.list(ft.params)[i as usize];
            } else {
                unsafe a.list(ft.returns)[(i - ft.params.len) as usize];
            };
            let tn = a.slot_type_node(sl);
            self.lt_tokens(m, tn, out, depth + 1);
        }
        let bound = self.owner().ast_of(m).lifetimes_of(fnn);
        let mut k = mark;
        for j in mark..out.len() {
            let tv = out[j];
            let mut own = false;
            for q in 0..bound.len {
                own = own || self.lt_token(m, unsafe self.owner().ast_of(m).list(bound)[q as usize]) == tv;
            }
            if !own {
                out.set(k, tv);
                k += 1;
            }
        }
        out.truncate(k);
    }

    fn lt_tokens_walk(self: &mut Self, m: ModuleId, tyn0: NodeId, out: &mut Vector<u64>, depth: i32) {
        let tyn = self.unself(m, tyn0);
        let mut k = NodeKind::NODE_NONE_KIND;
        let mut lt = NODE_NONE;
        let mut lts = false;
        let mut inner = NODE_NONE;
        let mut args = NodeList { start: 0, len: 0 };
        {
            let a = self.owner().ast_of(m);
            let node = a.at_const(tyn);
            k = node.kind;
            lts = node.has_lt_slot();
            if lts {
                lt = node.as_data.indirect_type.lifetime;
                inner = node.as_data.indirect_type.ty;
            } else if k == NodeKind::NODE_ARRAY_TYPE {
                inner = node.as_data.array_type.element;
            } else if k == NodeKind::NODE_TYPE_PATH {
                args = node.as_data.type_path.args;
            } else if k == NodeKind::NODE_TUPLE_TYPE {
                args = node.as_data.array_literal.elements;
            }
        }
        if k == NodeKind::NODE_TUPLE_TYPE {
            for i in 0..args.len {
                self.lt_tokens(m, unsafe self.owner().ast_of(m).list(args)[i as usize], out, depth + 1);
            }
            return;
        }
        if k == NodeKind::NODE_LIFETIME || k == NodeKind::NODE_GENERIC_PARAM {
            self.lt_name_token(m, tyn, out);
            return;
        }
        if lts {
            self.lt_name_token(m, lt, out);
            self.lt_tokens(m, inner, out, depth + 1);
            return;
        }
        if k == NodeKind::NODE_ARRAY_TYPE {
            self.lt_tokens(m, inner, out, depth + 1);
            return;
        }
        if k == NodeKind::NODE_TYPE_PATH {
            // A path naming a generic parameter is a token itself (`x: T` ties into `Vector<T>`), and
            // its bounds' arguments ride in it: `T: Put<'a>` can hold an `'a` borrow.
            let d = self.owner().ast_of(m).path_def(tyn);
            let dk = if d.node != NODE_NONE {
                self.owner().ast_of(d.module).at_const(d.node).kind;
            } else {
                NodeKind::NODE_NONE_KIND;
            };
            if dk == NodeKind::NODE_GENERIC_PARAM {
                out.push(d.module as u64 << 32 | d.node as u64);
                let bs = self.owner().ast_of(d.module).at_const(d.node).as_data.generic_param.bounds;
                self.bound_tokens(d.module, bs, out, depth);
                let nw = self.owner().ast_of(d.module).where_bounds.len();
                for w in 0..nw {
                    if self.owner().ast_of(d.module).where_scope(w, d.node, NODE_NONE) == WHERE_OWN {
                        let pred = self.owner().ast_of(d.module).where_bounds.at(w).pred;
                        let pbs = self.owner().ast_of(d.module).at_const(pred).as_data.where_predicate.bounds;
                        self.bound_tokens(d.module, pbs, out, depth);
                    }
                }
            } else if dk == NodeKind::NODE_INTERFACE {
                // `Self` of an interface: a conforming type may hold any of the interface's lifetime
                // and type parameters.
                let ia = self.owner().ast_of(d.module);
                let lts = ia.lifetimes_of(d.node);
                for i in 0..lts.len {
                    self.lt_name_token(d.module, unsafe self.owner().ast_of(d.module).list(lts)[i as usize], out);
                }
                let gs = self.owner().ast_of(d.module).at_const(d.node).as_data.interface_def.generics;
                for i in 0..gs.len {
                    out.push(d.module as u64 << 32 | (unsafe self.owner().ast_of(d.module).list(gs)[i as usize]) as u64);
                }
            }
            for i in 0..args.len {
                let aid = unsafe self.owner().ast_of(m).list(args)[i as usize];
                if self.owner().ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    self.lt_name_token(m, aid, out);
                } else {
                    self.lt_tokens(m, aid, out, depth + 1);
                }
            }
        }
    }

    // The lifetime tokens of type node `tyn` (of every return type of function `tyn` when `ret`)
    // that sit BEHIND a reference level of the value: in a reference's or slice's pointee, or in a
    // lifetime-generic aggregate, whose fields may place its lifetimes and type arguments behind
    // references. An elided lifetime there is ELIDED_TOK. Memoized: call sites re-read the same
    // signatures. Returns start << 16 | len into tok_pool.
    fn behind_range(self: &mut Self, m: ModuleId, tyn: NodeId, ret: bool) u64 {
        let key = skey_mix(0, m as u64 << 32 | tyn as u64);
        switch self.owner().beh_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let mut pool = replace(&mut self.owner().tok_pool, Vector::<u64>::new());
        let start = pool.len();
        if ret {
            let rets = self.owner().ast_of(m).at_const(tyn).as_data.function.returns;
            for r in 0..rets.len {
                let a = self.owner().ast_of(m);
                let rn = a.slot_type_node(unsafe a.list(rets)[r as usize]);
                self.behind_walk(m, rn, false, &mut pool, 0);
            }
        } else {
            self.behind_walk(m, tyn, false, &mut pool, 0);
        }
        let r = start as u64 << 16 | (pool.len() - start) as u64;
        self.owner().tok_pool = pool;
        self.owner().beh_memo.insert(key, r);
        return r;
    }

    // Is token `tk` in tok_pool range `r`?
    const fn range_has(self: &Self, r: u64, tk: u64) bool {
        let st = (r >> 16) as usize;
        for i in 0..r & 0xFFFF {
            if self.owner().tok_pool[st + i as usize] == tk {
                return true;
            }
        }
        return false;
    }

    // Does tok_pool range `r` share a token with `toks`?
    const fn range_meets(self: &Self, r: u64, toks: &Vector<u64>) bool {
        let st = (r >> 16) as usize;
        for i in 0..r & 0xFFFF {
            if toks.contains(&self.owner().tok_pool[st + i as usize]) {
                return true;
            }
        }
        return false;
    }

    fn behind_walk(self: &mut Self, m: ModuleId, tyn0: NodeId, behind: bool, out: &mut Vector<u64>, depth: i32) {
        if tyn0 == NODE_NONE || depth > 6 {
            return;
        }
        let tyn = self.unself(m, tyn0);
        let n = *self.owner().ast_of(m).at_const(tyn);
        if n.has_lt_slot() {
            if behind {
                let mut tk = self.lt_token(m, n.as_data.indirect_type.lifetime);
                if tk == 0 {
                    tk = ELIDED_TOK;
                }
                out.push(tk);
            }
            self.behind_walk(m, n.as_data.indirect_type.ty, true, out, depth + 1);
            return;
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            self.behind_walk(m, n.as_data.array_type.element, behind, out, depth + 1);
            return;
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                let e = unsafe self.owner().ast_of(m).list(es)[i as usize];
                self.behind_walk(m, e, behind, out, depth + 1);
            }
            return;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return;
        }
        let d = self.owner().ast_of(m).path_def(tyn);
        if d.node == NODE_NONE {
            return;
        }
        if self.owner().ast_of(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
            if behind {
                out.push(d.module as u64 << 32 | d.node as u64);
            }
            return;
        }
        let tp = n.as_data.type_path;
        let nlt = self.owner().ast_of(d.module).lifetimes_of(d.node).len;
        let inner = behind || nlt != 0;
        let mut named: u32 = 0;
        for i in 0..tp.args.len {
            let aid = unsafe self.owner().ast_of(m).list(tp.args)[i as usize];
            if self.owner().ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                let tk = self.lt_token(m, aid);
                if tk != 0 {
                    named += 1;
                    out.push(tk);
                }
            } else {
                self.behind_walk(m, aid, inner, out, depth + 1);
            }
        }
        if named < nlt && !(tp.parts.len == 1 && self.owner().span_text_is(
            m,
            self.owner().ast_of(m).at_const(unsafe self.owner().ast_of(m).list(tp.parts)[0]).as_data.name.text,
            "Self",
        )) {
            out.push(ELIDED_TOK);
        }
    }

    // The lifetime tokens of type node `tyn` that can sit within `refs` references of the value's
    // own level (0: outside every reference or slice pointee; an elided position is ELIDED_TOK). A
    // generic parameter or an interface's `Self` gives all its tokens. Memoized like `behind_range`;
    // returns start << 16 | len into tok_pool.
    fn own_range(self: &mut Self, m: ModuleId, tyn: NodeId, refs: u32) u64 {
        let key = skey_mix(skey_mix(0, m as u64 << 32 | tyn as u64), 1 + refs as u64);
        switch self.owner().beh_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        // The walk reads `lt_tokens`, which appends to tok_pool: collect apart, then copy.
        let mut own = Vector::<u64>::new();
        self.own_walk(m, tyn, &mut own, 0, refs);
        let start = self.owner().tok_pool.len();
        for i in 0..own.len() {
            self.owner().tok_pool.push(own[i]);
        }
        let r = start as u64 << 16 | own.len() as u64;
        self.owner().beh_memo.insert(key, r);
        return r;
    }

    // `own_range`'s walk, `refs` references still to cross. Past the depth bound a node gives all
    // its tokens.
    fn own_walk(self: &mut Self, m: ModuleId, tyn0: NodeId, out: &mut Vector<u64>, depth: i32, refs: u32) {
        if tyn0 == NODE_NONE {
            return;
        }
        if depth > 6 {
            self.lt_tokens(m, tyn0, out, 0);
            return;
        }
        let tyn = self.unself(m, tyn0);
        let n = *self.owner().ast_of(m).at_const(tyn);
        if n.has_lt_slot() {
            let tk = self.lt_token(m, n.as_data.indirect_type.lifetime);
            out.push(
                if tk == 0 {
                    ELIDED_TOK;
                } else {
                    tk;
                },
            );
            if refs != 0 {
                self.own_walk(m, n.as_data.indirect_type.ty, out, depth + 1, refs - 1);
            }
            return;
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            self.own_walk(m, n.as_data.array_type.element, out, depth + 1, refs);
            return;
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                self.own_walk(m, unsafe self.owner().ast_of(m).list(es)[i as usize], out, depth + 1, refs);
            }
            return;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            self.lt_tokens(m, tyn, out, depth);
            return;
        }
        let d = self.owner().ast_of(m).path_def(tyn);
        if d.node == NODE_NONE {
            return;
        }
        let dk = self.owner().ast_of(d.module).at_const(d.node).kind;
        if dk == NodeKind::NODE_GENERIC_PARAM || dk == NodeKind::NODE_INTERFACE {
            self.lt_tokens(m, tyn, out, depth);
            return;
        }
        let args = n.as_data.type_path.args;
        let mut named: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe self.owner().ast_of(m).list(args)[i as usize];
            if self.owner().ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                let tk = self.lt_token(m, aid);
                if tk != 0 {
                    named += 1;
                    out.push(tk);
                }
            } else {
                self.own_walk(m, aid, out, depth + 1, refs);
            }
        }
        if named < self.owner().ast_of(d.module).lifetimes_of(d.node).len && !(n.as_data.type_path.parts.len == 1 && self.owner().span_text_is(
            m,
            self.owner().ast_of(m).at_const(unsafe self.owner().ast_of(m).list(n.as_data.type_path.parts)[0]).as_data.name.text,
            "Self",
        )) {
            out.push(ELIDED_TOK);
        }
    }

    // Can a token of `toks`, or an elided position when `elided`, sit within `refs` references of
    // the own level of a value of type node `ptn` (`own_range`, widened by the call's outlives
    // relation)?
    fn own_ties(self: &mut Self, cm: ModuleId, ptn: NodeId, toks: &Vector<u64>, elided: bool, refs: u32) bool {
        let r = self.own_range(cm, ptn, refs);
        if elided && self.range_has(r, ELIDED_TOK) {
            return true;
        }
        if (self.rel & 0xFFFF) == 0 {
            return self.range_meets(r, toks);
        }
        let mut ts = Vector::<u64>::new();
        let st = (r >> 16) as usize;
        for i in 0..(r & 0xFFFF) as usize {
            ts.push(self.owner().tok_pool[st + i]);
        }
        self.owner().rel_widen(self.rel, false, &mut ts);
        return tokens_meet(&ts, toks);
    }

    // The fewest references of a value of type node `ptn` above a position of `toks` (or an elided
    // position when `elided`): 0, 1, or 2 for two or more. A value tied only through such positions
    // passes on only what lies behind that many of its references: `Option<&K>` tied through `K`
    // keeps nothing its own reference borrows.
    fn tie_depth(self: &mut Self, cm: ModuleId, ptn: NodeId, toks: &Vector<u64>, elided: bool) u32 {
        if self.own_ties(cm, ptn, toks, elided, 0) {
            return 0;
        }
        if self.own_ties(cm, ptn, toks, elided, 1) {
            return 1;
        }
        return 2;
    }

    // Does the autoref or reborrow of reference parameter `i` land behind a reference level of the
    // result: its lifetime (named, or elided when the elision rule picks it) appears in `rbeh`?
    fn ref_deep(self: &Self, cm: ModuleId, ptyn: &Vector<NodeId>, rbeh: u64, i: u32) bool {
        if i as usize >= ptyn.len() {
            return true;
        }
        let pn = self.owner().ast_of(cm).at_const(ptyn[i as usize]);
        if !pn.is_ref_type() {
            return true;
        }
        let tk = self.lt_token(cm, pn.as_data.indirect_type.lifetime);
        if tk == 0 {
            return self.range_has(rbeh, ELIDED_TOK);
        }
        if (self.rel & 0xFFFF) == 0 {
            return self.range_has(rbeh, tk);
        }
        // A lifetime the parameter's outlives lands where that one does.
        let mut ts = Vector::<u64>::new();
        ts.push(tk);
        self.owner().rel_widen(self.rel, false, &mut ts);
        return self.range_meets(rbeh, &ts);
    }

    // The edge of argument `i`'s value into a result the signature ties it to: what lies behind the
    // references of the argument above every tied position is all the result can hold of it (a
    // reference whose own lifetime is not tied contributes only what lies behind it; a value tied by
    // the return's tokens `rtok` (`by_tok`) through `K` of `Option<&K>` only what lies behind the
    // Option's reference), and a value whose lifetimes reach a position behind a reference of the
    // result lands there, at a depth the signature does not give (saturated). An autoref'd place is
    // the pointee of the reference the callee receives.
    fn tie_edge(
        self: &mut Self,
        cm: ModuleId,
        ptyn: &Vector<NodeId>,
        rbeh: u64,
        rtok: &Vector<u64>,
        pid: ir::PlaceId,
        k: u8,
        i: u32,
        lvl: bool,
        picked: bool,
        by_tok: bool,
        relided: bool,
    ) u8 {
        let e = self.place_edge(pid);
        let ty = self.place_of(pid).ty;
        let mut yk = TypeKind::TYPE_ERROR;
        if ty != TYPE_NONE {
            yk = self.ref_kind(self.body().module, ty);
        }
        if i as usize >= ptyn.len() {
            return sd_then(e, SD_SAT);
        }
        let ptn = ptyn[i as usize];
        let pn = *self.owner().ast_of(cm).at_const(ptn);
        if k != 0 && yk != TypeKind::TYPE_POINTER && (pn.is_ref_type() || yk == TypeKind::TYPE_REFERENCE) {
            // A reference parameter: the edge of the reference the callee receives (an alias spells
            // no pointee to read depths from).
            let mut r = if self.ref_deep(cm, ptyn, rbeh, i) {
                SD_SAT;
            } else {
                SD_KEEP;
            };
            if !lvl && !pn.is_ref_type() {
                r = sd_then(SD_DEREF, self.tie_lift(cm, ptn, rbeh, picked));
            } else if !lvl {
                let d = if by_tok {
                    self.tie_depth(cm, pn.as_data.indirect_type.ty, rtok, picked && relided);
                } else {
                    0u32;
                };
                r = sd_then(sd_sink(1 + d), self.tie_lift(cm, pn.as_data.indirect_type.ty, rbeh, picked));
            }
            if yk == TypeKind::TYPE_REFERENCE {
                return sd_then(e, r);
            }
            // The place lies behind that reference.
            return sd_then(e, sd_then(SD_REF, r));
        }
        if k != 0 && yk != TypeKind::TYPE_POINTER {
            if lvl {
                return sd_then(e, SD_SAT);
            }
            return e;
        }
        let mut d = if by_tok && k == 0 {
            self.tie_depth(cm, ptn, rtok, picked && relided);
        } else {
            0u32;
        };
        if d == 0 && by_tok && k == 0 && self.closure_result_tie(cm, ptn, rtok, ty) {
            d = 1;
        }
        return sd_then(e, sd_then(sd_sink(d), self.tie_lift(cm, ptn, rbeh, picked)));
    }

    // Is a value of closure type `ty` passed as parameter type `ptn` tied to the result only through
    // what the closure returns: `ptn` is a type parameter whose bounds are all function types, the
    // return names it nowhere (`rtok`), and the closure's results hold nothing of its own level
    // (`Owner::res_deep`): its by-reference captures' storage stays out of the result.
    fn closure_result_tie(self: &mut Self, cm: ModuleId, ptn: NodeId, rtok: &Vector<u64>, ty: TypeId) bool {
        if ty == TYPE_NONE || !self.closure_ty(ty) {
            return false;
        }
        let y = *self.owner().ast_of(self.body().module).type_at(ty);
        let deep = switch self.owner().res_deep.get(&(y.module as u64 << 32 | y.as_data.decl as u64)) {
            Some(v) => *v,
            None => false,
        };
        if !deep || self.owner().ast_of(cm).at_const(ptn).kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let d = self.owner().ast_of(cm).path_def(ptn);
        if d.node == NODE_NONE || self.owner().ast_of(d.module).at_const(d.node).kind != NodeKind::NODE_GENERIC_PARAM || rtok.contains(
            &(d.module as u64 << 32 | d.node as u64),
        ) {
            return false;
        }
        let bs = self.owner().ast_of(d.module).at_const(d.node).as_data.generic_param.bounds;
        if bs.len == 0 {
            return false;
        }
        for i in 0..bs.len {
            let b = unsafe self.owner().ast_of(d.module).list(bs)[i as usize];
            if self.owner().ast_of(d.module).at_const(b).kind != NodeKind::NODE_FUNCTION_TYPE {
                return false;
            }
        }
        let nw = self.owner().ast_of(d.module).where_bounds.len();
        for w in 0..nw {
            if self.owner().ast_of(d.module).where_scope(w, d.node, NODE_NONE) == WHERE_OWN {
                return false;
            }
        }
        return true;
    }

    // SAT when a value of parameter type `ptn` may land behind a reference of the result: a token of
    // it (or an elided position the elision rule picks) is in the return's behind-reference tokens
    // `rbeh`; else KEEP.
    fn tie_lift(self: &mut Self, cm: ModuleId, ptn: NodeId, rbeh: u64, picked: bool) u8 {
        if (rbeh & 0xFFFF) == 0 {
            return SD_KEEP;
        }
        let mut itok = replace(&mut self.owner().sc_tok_b, Vector::<u64>::new());
        itok.truncate(0);
        self.lt_tokens(cm, ptn, &mut itok, 0);
        self.owner().rel_widen(self.rel, false, &mut itok);
        let deep = self.range_meets(rbeh, &itok) || picked && self.range_has(rbeh, ELIDED_TOK) && self.has_elided_lt(
            cm,
            ptn,
            0,
        );
        self.owner().sc_tok_b = itok;
        if deep {
            return SD_SAT;
        }
        return SD_KEEP;
    }

    // The edge of argument `pid` (passed as parameter type `ptn` in mode `k`) stored into a
    // container: only what lies behind the references above every position the store names
    // (`tie_depth`); a reference whose own named lifetime the store names is stored itself.
    fn store_arg_edge(self: &mut Self, cm: ModuleId, pid: ir::PlaceId, k: u8, ptn: NodeId, jtok: &Vector<u64>) u8 {
        let e = self.place_edge(pid);
        let ty = self.place_of(pid).ty;
        let mut yk = TypeKind::TYPE_ERROR;
        if ty != TYPE_NONE {
            yk = self.ref_kind(self.body().module, ty);
        }
        let pn = *self.owner().ast_of(cm).at_const(ptn);
        if k == 0 {
            return sd_then(e, sd_sink(self.tie_depth(cm, ptn, jtok, false)));
        }
        if yk == TypeKind::TYPE_POINTER || !pn.is_ref_type() {
            return e;
        }
        let tk = self.lt_token(cm, pn.as_data.indirect_type.lifetime);
        let r = if tk != 0 && jtok.contains(&tk) {
            SD_KEEP;
        } else {
            sd_sink(1 + self.tie_depth(cm, pn.as_data.indirect_type.ty, jtok, false));
        };
        if yk == TypeKind::TYPE_REFERENCE {
            return sd_then(e, r);
        }
        // An autoref'd place lies behind the reference the callee receives.
        return sd_then(e, sd_then(SD_REF, r));
    }

    // The edge into a container of pointee type node `ptn` (a `&mut P` parameter) for an argument
    // with tokens `itok`: a store reaching a position behind a reference of P lands there, at a
    // depth the type does not give.
    fn store_target_edge(self: &mut Self, cm: ModuleId, ptn: NodeId, itok: &Vector<u64>) u8 {
        let pn = *self.owner().ast_of(cm).at_const(ptn);
        if !pn.is_ref_type() {
            return SD_SAT;
        }
        if self.range_meets(self.behind_range(cm, pn.as_data.indirect_type.ty, false), itok) {
            return SD_SAT;
        }
        return SD_KEEP;
    }

    fn lt_name_token(self: &mut Self, m: ModuleId, lt: NodeId, out: &mut Vector<u64>) {
        let tk = self.lt_token(m, lt);
        if tk != 0 {
            out.push(tk);
        }
    }

    // The token of a named lifetime (bit 63 set), or 0 for an elided one.
    fn lt_token(self: &Self, m: ModuleId, lt: NodeId) u64 {
        return self.owner().lt_tok(m, lt);
    }

    // The tokens under which argument `place`, passed as parameter type `ptn` in mode `kind`, can be
    // stored. A reference-typed source can only be STORED through its own named lifetime; its
    // pointee's tokens matter only when the pointee value itself carries borrows (`swap<T>(&mut T,
    // &mut T)` with T = &i32). By-value sources, and references spelled through an alias, use all
    // their tokens.
    fn arg_tokens(self: &mut Self, cm: ModuleId, place: ir::PlaceId, kind: u8, ptn: NodeId, out: &mut Vector<u64>) {
        let oty = self.place_of(place).ty;
        let mut pointee_carries = false;
        if oty != TYPE_NONE {
            let ya = *self.owner().ast_of(self.body().module).type_at(oty);
            if ya.kind == TypeKind::TYPE_REFERENCE {
                pointee_carries = self.owner().carries(self.body().module, ya.as_data.elem);
            }
        }
        let a = self.owner().ast_of(cm);
        if (kind == 1 || kind == 2) && !pointee_carries && a.at_const(ptn).is_ref_type() {
            self.lt_name_token(cm, a.at_const(ptn).as_data.indirect_type.lifetime, out);
        } else {
            // A reference spelled through an alias (`IntRef<'a>`) names its lifetime as an argument.
            self.lt_tokens(cm, ptn, out, 0);
        }
    }

    // Does the callee's signature tie the lifetime of reference parameter `i` to its return? A named
    // lifetime ties when the return names it too; an elided one follows the elision rule when the
    // return has an elided position: the `self` reference when there is one, else the single
    // borrowing input. A call with no declared parameter types (a fn value) ties conservatively.
    fn reborrow_ties(
        self: &Self,
        cm: ModuleId,
        ptyn: &Vector<NodeId>,
        rtok: &Vector<u64>,
        i: u32,
        ref_self: bool,
        nborrowing: u32,
        bidx: u32,
        relided: bool,
    ) bool {
        if i as usize >= ptyn.len() {
            return true;
        }
        let pn = self.owner().ast_of(cm).at_const(ptyn[i as usize]);
        if !pn.is_ref_type() {
            return true;
        }
        let tk = self.lt_token(cm, pn.as_data.indirect_type.lifetime);
        if tk != 0 {
            return rtok.contains(&tk);
        }
        if !relided {
            return false;
        }
        if ref_self {
            return i == 0;
        }
        return nborrowing == 1 && i == bidx;
    }

    // Does type node `tyn` hold an elided lifetime position: a reference or slice without a named lifetime,
    // or a path to a lifetime-generic declaration naming fewer lifetimes than it declares? `Self` names
    // the whole receiver type, its lifetimes included.
    fn has_elided_lt(self: &Self, m: ModuleId, tyn: NodeId, depth: i32) bool {
        if tyn == NODE_NONE || depth > 6 {
            return false;
        }
        let a = self.owner().ast_of(m);
        let n = a.at_const(tyn);
        if n.has_lt_slot() {
            let sp = self.lt_name(m, n.as_data.indirect_type.lifetime);
            return sp.end <= sp.start || self.has_elided_lt(m, n.as_data.indirect_type.ty, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.has_elided_lt(m, n.as_data.array_type.element, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                if self.has_elided_lt(m, unsafe a.list(es)[i as usize], depth + 1) {
                    return true;
                }
            }
            return false;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let tp = n.as_data.type_path;
        if tp.parts.len == 1 && self.owner().span_text_is(
            m,
            a.at_const(unsafe a.list(tp.parts)[0]).as_data.name.text,
            "Self",
        ) {
            return false;
        }
        let mut nlt: u32 = 0;
        for i in 0..tp.args.len {
            let aid = unsafe a.list(tp.args)[i as usize];
            if a.at_const(aid).kind == NodeKind::NODE_LIFETIME {
                let sp = self.lt_name(m, aid);
                if sp.end > sp.start {
                    nlt += 1;
                }
            } else if self.has_elided_lt(m, aid, depth + 1) {
                return true;
            }
        }
        let d = a.path_def(tyn);
        return d.node != NODE_NONE && self.owner().ast_of(d.module).lifetimes_of(d.node).len > nlt;
    }

    // Read callee `callee`'s signature: `Self` there names the target type of its extend.
    fn enter_callee(self: &mut Self, callee: DefId) {
        self.ext = NODE_NONE;
        if callee.node == NODE_NONE {
            return;
        }
        let a = self.owner().ast_of(callee.module);
        let c = a.container_of(callee.node);
        if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND {
            self.ext = c;
            self.ext_mod = callee.module;
        }
    }

    // Type node `tyn` of module `m`, a `Self` of the callee's signature read as its extend's target
    // type, which spells the lifetimes `Self` stands for.
    const fn unself(self: &Self, m: ModuleId, tyn: NodeId) NodeId {
        if self.ext == NODE_NONE || m != self.ext_mod {
            return tyn;
        }
        let a = self.owner().ast_of(m);
        let n = a.at_const(tyn);
        if n.kind != NodeKind::NODE_TYPE_PATH || n.as_data.type_path.parts.len != 1 || !self.owner().span_text_is(
            m,
            a.at_const(unsafe a.list(n.as_data.type_path.parts)[0]).as_data.name.text,
            "Self",
        ) {
            return tyn;
        }
        let tt = a.at_const(self.ext).as_data.extend_def.target_type;
        if tt == NODE_NONE {
            return tyn;
        }
        return tt;
    }

    // The signature summary of `callee` (`CallSig`), memoized; all zero for a fn-value call.
    fn call_sig(self: &mut Self, callee: DefId) CallSig {
        let mut cs = CallSig { fl: 0, rel: 0, rbeh: 0, rtok: 0, lts: 0 };
        if callee.node == NODE_NONE {
            return cs;
        }
        let key = skey_mix(0, callee.module as u64 << 32 | callee.node as u64);
        switch self.owner().call_sigs.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let ext0 = self.ext;
        let em0 = self.ext_mod;
        self.enter_callee(callee);
        cs.rel = self.owner().callee_rel(callee);
        let mut stat = replace(&mut self.owner().sc_stat, Vector::<u64>::new());
        self.owner().rel_static(cs.rel, &mut stat);
        cs.fl = 4;
        let mut pn = tok::Span { start: 0, end: 0 };
        let mut fn0 = tok::Span { start: 0, end: 0 };
        let mut rets = NodeList { start: 0, len: 0 };
        let mut ps = NodeList { start: 0, len: 0 };
        let mut isfn = false;
        {
            let a = self.owner().ast_of(callee.module);
            let nd = a.at_const(callee.node);
            if nd.kind == NodeKind::NODE_FUNCTION {
                isfn = true;
                fn0 = a.at_const(nd.as_data.function.name).as_data.name.text;
                if nd.as_data.function.params.len != 0 {
                    let p0 = unsafe a.list(nd.as_data.function.params)[0];
                    pn = a.at_const(a.at_const(p0).as_data.parameter.name).as_data.name.text;
                }
                rets = nd.as_data.function.returns;
                for r in 0..rets.len {
                    if self.has_elided_lt(callee.module, a.slot_type_node(unsafe a.list(rets)[r as usize]), 0) {
                        cs.fl = cs.fl | 8;
                    }
                }
                ps = nd.as_data.function.params;
                for i in 0..ps.len.min(STATIC_PARAMS_MAX) {
                    let ptn = a.at_const(unsafe a.list(ps)[i as usize]).as_data.parameter.ty;
                    cs.fl = cs.fl | self.static_kind(callee.module, ptn, &stat) as u64 << (8 + 2 * i) as u64;
                }
            }
        }
        self.owner().sc_stat = stat;
        if pn.end > pn.start && self.owner().span_text_is(callee.module, pn, "self") {
            cs.fl = cs.fl | 1;
        }
        if fn0.end > fn0.start && self.owner().span_text_is(callee.module, fn0, "free") {
            cs.fl = cs.fl | 2;
        }
        if isfn {
            cs.rbeh = self.behind_range(callee.module, callee.node, true);
        }
        let mut rt = replace(&mut self.owner().sc_tok_r, Vector::<u64>::new());
        rt.truncate(0);
        for r in 0..rets.len {
            let ca = self.owner().ast_of(callee.module);
            let rn = ca.slot_type_node(unsafe ca.list(rets)[r as usize]);
            self.lt_tokens(callee.module, rn, &mut rt, 0);
        }
        let start = self.owner().tok_pool.len();
        for i in 0..rt.len() {
            self.owner().tok_pool.push(rt[i]);
        }
        cs.rtok = start as u64 << 16 | rt.len() as u64;
        self.owner().sc_tok_r = rt;
        for i in 0..ps.len.min(64) {
            let ptn = self.owner().ast_of(callee.module).at_const(
                unsafe self.owner().ast_of(callee.module).list(ps)[i as usize],
            ).as_data.parameter.ty;
            if self.sig_lt(callee.module, ptn) {
                cs.lts = cs.lts | 1u64 << i as u64;
            }
        }
        self.ext = ext0;
        self.ext_mod = em0;
        self.owner().call_sigs.insert(key, cs);
        return cs;
    }

    // Does parameter type node `ptn` of module `m` have a lifetime position: an elided one, or a
    // named lifetime token?
    fn sig_lt(self: &mut Self, m: ModuleId, ptn: NodeId) bool {
        if self.has_elided_lt(m, ptn, 0) {
            return true;
        }
        let mut ptok = replace(&mut self.owner().sc_tok_b, Vector::<u64>::new());
        ptok.truncate(0);
        self.lt_tokens(m, ptn, &mut ptok, 0);
        let mut lt = false;
        for k in 0..ptok.len() {
            if ptok[k] >> 63 != 0 {
                lt = true;
            }
        }
        self.owner().sc_tok_b = ptok;
        return lt;
    }

    // How an argument passed as parameter type `ptn` reaches `'static`: 0 = the type names no
    // `'static`, 1 = the whole value (`&'static T`, `S<'static>`), 2 = only what lies behind the
    // parameter's own reference (`&Vector<&'static T>`). `stat` holds the tokens the signature makes
    // `'static` (`Owner::rel_static`).
    fn static_kind(self: &Self, m: ModuleId, ptn: NodeId, stat: &Vector<u64>) u8 {
        if ptn == NODE_NONE {
            return 0;
        }
        let n = self.owner().ast_of(m).at_const(ptn);
        if n.has_lt_slot() {
            if stat.contains(&self.lt_token(m, n.as_data.indirect_type.lifetime)) {
                return 1;
            }
            if self.names_static(m, n.as_data.indirect_type.ty, stat, 1) {
                return 2;
            }
            return 0;
        }
        if self.names_static(m, ptn, stat, 0) {
            return 1;
        }
        return 0;
    }

    // Does type node `tyn` name a lifetime of `stat` (`'static`, or one the signature makes `'static`)
    // at some lifetime position?
    fn names_static(self: &Self, m: ModuleId, tyn0: NodeId, stat: &Vector<u64>, depth: i32) bool {
        if tyn0 == NODE_NONE || depth > 6 {
            return false;
        }
        let tyn = self.unself(m, tyn0);
        let a = self.owner().ast_of(m);
        let n = a.at_const(tyn);
        if n.kind == NodeKind::NODE_LIFETIME {
            return stat.contains(&self.lt_token(m, tyn));
        }
        if n.has_lt_slot() {
            return stat.contains(&self.lt_token(m, n.as_data.indirect_type.lifetime)) || self.names_static(
                m,
                n.as_data.indirect_type.ty,
                stat,
                depth + 1,
            );
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.names_static(m, n.as_data.array_type.element, stat, depth + 1);
        }
        if n.kind == NodeKind::NODE_DYN_TYPE && n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_NONE {
            return true; // an owned `dyn I` is `dyn I + 'static`
        }
        let mut es = NodeList { start: 0, len: 0 };
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            es = n.as_data.array_literal.elements;
        } else if n.kind == NodeKind::NODE_TYPE_PATH {
            es = n.as_data.type_path.args;
            // A type parameter bounded `'static` (`F: fn() + 'static`) holds only `'static` borrows.
            let d = a.path_def(tyn);
            if d.node != NODE_NONE && self.owner().ast_of(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
                if stat.contains(&(d.module as u64 << 32 | d.node as u64)) {
                    return true;
                }
                let bs = self.owner().ast_of(d.module).at_const(d.node).as_data.generic_param.bounds;
                for i in 0..bs.len {
                    let b = unsafe self.owner().ast_of(d.module).list(bs)[i as usize];
                    if self.owner().ast_of(d.module).at_const(b).kind == NodeKind::NODE_LIFETIME && self.owner().span_text_is(
                        d.module,
                        self.lt_name(d.module, b),
                        "'static",
                    ) {
                        return true;
                    }
                }
            }
        }
        for i in 0..es.len {
            if self.names_static(m, unsafe a.list(es)[i as usize], stat, depth + 1) {
                return true;
            }
        }
        return false;
    }

    // A `&mut` or `[]mut T` place `p` stored into a field of, or a member of a literal for, place `dst`
    // (origin `dor`) reborrows its referent for as long as `dst` holds it, as Rust reborrows at a
    // coercion site: a use of `p` conflicts until then, and overwriting `p` only ends the loan.
    fn reborrow_store(self: &mut Self, p: ir::PlaceId, dor: u32, dst: ir::PlaceId, exit: u32, sp: tok::Span) {
        if self.loans && dor != BF_NONE && !self.behind_raw(p) && (self.mut_ref_place(p) || self.mut_view_place(p)) {
            self.push_loan(false, true, self.store_level(dst), p, LK_MUT, dor, exit, sp);
        }
    }

    // How argument `i` of call `t`, a copy or move of place `p` passed to a parameter of kind `k`,
    // shares borrowed storage with the callee: 2 mutably (a `&mut` or `[]mut` it hands over, or a
    // `&mut` autoref), 1 shared (any other borrow-carrying value, or a shared autoref), 0 not at all
    // (a value without borrows, or a reference erased to a raw pointer).
    fn arg_share(self: &mut Self, t: &ir::Terminator, k: u8, p: ir::PlaceId) u8 {
        let ty = self.place_of(p).ty;
        if ty == TYPE_NONE {
            return 0;
        }
        let m = self.body().module;
        let yk = self.ref_kind(m, ty);
        if k == 3 {
            return 0;
        }
        if k != 0 && yk != TypeKind::TYPE_REFERENCE && yk != TypeKind::TYPE_POINTER {
            return k;
        }
        if self.mut_ref_place(p) && (k != 1 || t.callee.node == NODE_NONE) || self.mut_view_place(p) {
            return 2;
        }
        if self.owner().carries(m, ty) {
            return 1;
        }
        return 0;
    }

    // Record a clash when two arguments of call `t` reach overlapping borrowed storage and one of them
    // shares it mutably. Each argument only reads its place at the call's entry, so no loan orders the
    // pair, yet the callee would hold two live paths to storage one of them writes.
    fn arg_clashes(self: &mut Self, t: &ir::Terminator, kinds: &Vector<u8>) {
        for j in 1..t.args_len {
            let oj = *self.body().operands.at(self.body().oper_pool[(t.args_start + j) as usize] as usize);
            if oj.kind != ir::OP_COPY && oj.kind != ir::OP_MOVE {
                continue;
            }
            let sj = self.arg_share(t, kinds[j as usize], oj.data);
            if sj == 0 {
                continue;
            }
            for i in 0..j {
                let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
                if oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                    continue;
                }
                let si = self.arg_share(t, kinds[i as usize], oi.data);
                if si == 0 || si == 1 && sj == 1 || !places_conflict(self.body(), oi.data, oj.data) {
                    continue;
                }
                self.f.clashes.push(ArgClash { span: t.span, first: si, second: sj });
                return;
            }
        }
    }

    // An argument the callee receives by reference while the operand names a non-reference place:
    // the checker's autoref, implicit in Core IR. It reads or claims the place for the call and,
    // when the call produces a borrow-carrying result, opens a loan owned by that result's origin.
    fn implicit_borrow(
        self: &mut Self,
        pid: ir::PlaceId,
        k: u8,
        entry: u32,
        dorigin: u32,
        tie: bool,
        deep: bool,
        dsd: u8,
        mutres: bool,
        sp: tok::Span,
    ) {
        // A tie whose lifetime the result holds behind its own references (`deep`) places the
        // autoref at a depth the signature does not give: it saturates.
        let pl = self.place_of(pid);
        self.live_use(pl.base);
        let mut upath = self.forest().place_path[pid as usize];
        if upath == mp::MP_NONE {
            upath = self.forest().place_cut[pid as usize];
        }
        if upath != mp::MP_NONE {
            self.push_ev(EV_USE, upath, entry, sp);
        }
        let mut ak = ACC_READ;
        if k == 2 {
            ak = ACC_WRITE;
        }
        self.access(pid, BF_NONE, ak, entry, sp);
        if dorigin != BF_NONE && !self.behind_raw(pid) {
            // The pin a carrying RESULT holds is SHARED unless the result can write (`mutres`: a
            // `&mut`, a `[]mut` view or a value holding one) through a `&mut` autoref: the exclusive
            // claim then lives as long as the result. Else it lives in the access above and ends with
            // the call. The result pins the place when the signature ties the autoref's lifetime to
            // the return; a place that itself CARRIES borrows also contributes what it holds, behind
            // the autoref when tied.
            if self.owner().carries(self.body().module, pl.ty) {
                let mut e = self.place_edge(pid);
                if tie {
                    e = sd_then(
                        e,
                        if deep {
                            SD_SAT;
                        } else {
                            SD_REF;
                        },
                    );
                }
                self.subset_d(self.origin_of_place(pid), dorigin, entry, sd_then(e, dsd));
            }
            if tie {
                let lk = if k == 2 && mutres {
                    LK_MUT;
                } else {
                    LK_SHARED;
                };
                self.push_loan(
                    true,
                    false,
                    if deep {
                        2u8;
                    } else {
                        sd_level(dsd, 0) as u8;
                    },
                    pid,
                    lk,
                    dorigin,
                    entry + 1,
                    sp,
                );
            }
        }
    }

    // Can a value of type `ty` (the body's pool) write what it reaches: a `&mut`, a `[]mut` view, or an
    // instance holding one (`Option<&mut T>`)?
    fn grants_write(self: &Self, ty: TypeId, depth: i32) bool {
        if ty == TYPE_NONE || depth > 4 {
            return false;
        }
        let a = self.owner().ast_of(self.body().module);
        let y = *a.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *a.instance(y.as_data.inst);
        if it.decl == self.owner().slice_mut.node && it.module == self.owner().slice_mut.module {
            return true;
        }
        for k in 0..it.n {
            if self.grants_write(unsafe it.args[k as usize], depth + 1) {
                return true;
            }
        }
        return false;
    }

    fn walk(self: &mut Self) {
        let nlocals = self.body().locals.len() as u32;
        let nb = self.body().blocks.len();
        let ew = ((nlocals + 63) / 64).max(1);
        if self.f.nlive < nlocals {
            self.f.nlive = nlocals;
        }
        let lw = ((self.f.nlive + 63) / 64).max(1);
        self.f.ewords = ew;
        self.f.lwords = lw;
        // `generate_into` reset the rows.
        let rows = nb * lw as usize;
        self.f.easy_use.resize_default(nb * ew as usize);
        if self.loans {
            self.f.luse.resize_default(rows);
            self.f.ldef.resize_default(rows);
        }
        for bi in 0..nb {
            self.cur_block = bi as u32;
            let ne = self.f.events.len() as u32;
            self.f.ev_start.push(ne);
            self.f.mev_start.push(self.f.mev.len() as u32);
            self.f.rep_blk.push(false);
            self.f.easy_blk.push(true);
            if self.loans {
                self.seen.truncate(0);
                self.seen.resize_default(lw as usize);
            }
            let blk = *self.body().blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *self.body().statements.at((blk.stmt_start + si) as usize);
                let entry = self.stmt_entry(bi as u32, si);
                let exit = entry + 1;
                if s.kind == ir::ST_ASSIGN {
                    let mark = self.f.subsets.len();
                    self.pre_v.truncate(0);
                    self.stmt_assign(&s, entry, exit);
                    self.store_through(&s, mark, entry);
                    self.member_store(&s, mark);
                } else if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
                    let root = self.forest().local_root[s.a as usize];
                    self.push_ev(EV_DEAD, root, exit, s.span);
                    if self.loans {
                        self.assign_sites.push(KillSite { place: BF_NONE, local: s.a, point: exit });
                        if s.kind == ir::ST_STORAGE_DEAD {
                            // An owned carrier's destruction observes what it stores (`Free` runs),
                            // so the local counts as USED here: stored borrows must survive to it.
                            // Recorded, not applied: the destruction runs only where the local may
                            // still hold a value (`BodyFacts::drop_use`).
                            if self.f.observed[s.a as usize] {
                                let slot = if self.f.drop_slot[s.a as usize] != BF_NONE {
                                    self.f.drop_slot[s.a as usize];
                                } else {
                                    s.a;
                                };
                                self.f.drop_uses.push(
                                    DropUse {
                                        block: bi as u32,
                                        slot: slot,
                                        path: root,
                                        point: exit,
                                        access: self.f.accesses.len() as u32,
                                        seen: (self.seen[(slot / 64) as usize] >> (slot & 63) as u64 & 1u64) != 0,
                                    },
                                );
                            }
                            self.access(BF_NONE, s.a, ACC_WRITE, exit, s.span);
                        }
                    }
                }
            }
            let t = self.call_term(blk.term);
            let entry = self.term_entry(bi as u32);
            let exit = entry + 1;
            if t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT {
                self.op_read(t.a, entry, t.span);
                // An assert's message and reported values are read, never moved.
                self.calling = true;
                for i2 in 0..t.args_len {
                    self.op_read(self.body().oper_pool[(t.args_start + i2) as usize], entry, t.span);
                }
                self.calling = false;
            } else if t.kind == ir::TM_CALL {
                self.enter_callee(t.callee);
                let cs = self.call_sig(t.callee);
                // A signature relating two lifetimes (`'b: 'a`) ties them as one name would; so do
                // the function values the call passes (`Ast::call_lts`).
                self.rel = if self.loans {
                    cs.rel;
                } else {
                    0u64;
                };
                let mut cext = Vector::<u64>::new();
                if self.loans && t.callee.node != NODE_NONE {
                    self.call_lt_pairs(t.span, &mut cext);
                    if cext.len() != 0 {
                        self.rel = self.owner().rel_extend(self.rel, &cext);
                    }
                }
                if t.callee.node != NODE_NONE && self.owner().ast_of(t.callee.module).at_const(t.callee.node).kind == NodeKind::NODE_CLOSURE {
                    // A closure called as its hoisted function follows the lifetimes its parameters name.
                    let csig = switch self.owner().gen_sigs.get(&(t.callee.module as u64 << 32 | t.callee.node as u64)) {
                        Some(v) => *v,
                        None => TYPE_NONE,
                    };
                    if csig != TYPE_NONE && csig != TYPE_ERROR {
                        self.sig_call(&t, csig, t.callee.module as u64 << 32 | t.callee.node as u64, entry);
                    }
                }
                if t.callee.node == NODE_NONE && t.a != ir::IR_NONE {
                    self.calling = true;
                    self.op_read(t.a, entry, t.span);
                    self.calling = false;
                    let mut ckey: u64 = 0;
                    let sig = self.value_sig(t.a, &mut ckey);
                    if sig != TYPE_NONE {
                        self.sig_call(&t, sig, ckey, entry);
                    }
                    // A fn-value call without a type naming lifetimes: conservatively derive carrying
                    // dests from every carrying argument AND the callee value's own captures.
                    for d2 in 0..t.dests_len {
                        if sig != TYPE_NONE {
                            break;
                        }
                        let dp2 = self.body().dest_pool[(t.dests_start + d2) as usize];
                        let dor2 = self.origin_of_place(dp2);
                        if dor2 == BF_NONE {
                            continue;
                        }
                        let cop = *self.body().operands.at(t.a as usize);
                        if cop.kind == ir::OP_COPY || cop.kind == ir::OP_MOVE {
                            self.subset_d(self.origin_of_place(cop.data), dor2, entry, SD_KEEP_SAT);
                        }
                        for i2 in 0..t.args_len {
                            let oi2 = *self.body().operands.at(
                                self.body().oper_pool[(t.args_start + i2) as usize] as usize,
                            );
                            if oi2.kind == ir::OP_COPY || oi2.kind == ir::OP_MOVE {
                                self.subset_d(self.origin_of_place(oi2.data), dor2, entry, SD_KEEP_SAT);
                            }
                        }
                    }
                }
                // The first borrow-carrying destination owns loans the call opens on autoref args.
                let mut dor0 = BF_NONE;
                let mut dsd0 = SD_KEEP;
                let mut dmut0 = false;
                for d in 0..t.dests_len {
                    let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                    if dor0 == BF_NONE {
                        dor0 = self.origin_of_place(dp);
                        dsd0 = self.store_edge(dp);
                        dmut0 = self.grants_write(self.place_of(dp).ty, 0);
                    }
                }
                let mut kinds = replace(&mut self.owner().sc_kinds, Vector::<u8>::new());
                self.arg_kinds(t.callee, t.args_len, &mut kinds);
                // The callee's parameter type nodes for the arguments it declares: the signature ties
                // below read them.
                let mut ptyn = replace(&mut self.owner().sc_ptyn, Vector::<NodeId>::new());
                ptyn.truncate(0);
                if self.loans && t.callee.node != NODE_NONE {
                    let a = self.owner().ast_of(t.callee.module);
                    let nd = a.at_const(t.callee.node);
                    if nd.kind == NodeKind::NODE_FUNCTION {
                        let ps = nd.as_data.function.params;
                        for i in 0..ps.len.min(t.args_len) {
                            ptyn.push(a.at_const(unsafe a.list(ps)[i as usize]).as_data.parameter.ty);
                        }
                    }
                }
                // What the SIGNATURE ties to the return: the return's lifetime tokens, whether it has
                // an elided position, and the borrowing inputs the elision rule picks from.
                let recv = t.args_len != 0 && (cs.fl & 1) != 0;
                let mut rtok = replace(&mut self.owner().sc_tok_r, Vector::<u64>::new());
                rtok.truncate(0);
                let mut relide = false;
                let mut relided = false;
                let mut nborrowing: u32 = 0;
                let mut bidx: u32 = 0;
                let mut rbeh: u64 = 0; // the return's tokens behind a reference level (tok_pool range)
                if self.loans && t.callee.node != NODE_NONE {
                    rbeh = cs.rbeh;
                    let rst = (cs.rtok >> 16) as usize;
                    for r3 in 0..(cs.rtok & 0xFFFF) as usize {
                        let tv = self.owner().tok_pool[rst + r3];
                        rtok.push(tv);
                    }
                    // An argument whose lifetime outlives the return's is tied to it.
                    self.owner().rel_widen(self.rel, true, &mut rtok);
                    // No named token on the return: any borrow-carrying result elides; its borrows
                    // come from the single borrowing input (rule 2/3; receiver ties are separate).
                    // The dest-origin guards below keep this to carrying results.
                    relide = rtok.len() == 0;
                    relided = (cs.fl & 8) != 0;
                    // The inputs with a lifetime position: references, and views or aggregates
                    // whose lifetimes are elided or named.
                    for i3 in 0..t.args_len {
                        let mut lt = kinds[i3 as usize] == 1 || kinds[i3 as usize] == 2;
                        if !lt && i3 as usize < ptyn.len() {
                            lt = if i3 < 64 {
                                (cs.lts >> i3 as u64 & 1u64) != 0;
                            } else {
                                self.sig_lt(t.callee.module, ptyn[i3 as usize]);
                            };
                        }
                        if lt {
                            nborrowing += 1;
                            bidx = i3;
                        }
                    }
                }
                let ref_self = recv && kinds[0] != 0;
                // Explicit `.free()` consumes its receiver even though the parameter is `&mut`.
                let frees = t.args_len == 1 && (cs.fl & 2) != 0;
                let mut autoref: u64 = 0; // the arguments below STATIC_PARAMS_MAX taken by implicit autoref
                for i in 0..t.args_len {
                    let opid = self.body().oper_pool[(t.args_start + i) as usize];
                    let op = *self.body().operands.at(opid as usize);
                    let mut implicit = false;
                    if kinds[i as usize] != 0 && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                        let bmod = self.body().module;
                        let pty = self.place_of(op.data).ty;
                        let yk = self.ref_kind(bmod, pty);
                        if yk != TypeKind::TYPE_REFERENCE && yk != TypeKind::TYPE_POINTER {
                            implicit = true;
                        }
                    }
                    if implicit && frees && i == 0 && kinds[0] == 2 && self.forest().place_path[op.data as usize] != mp::MP_NONE {
                        let path = self.forest().place_path[op.data as usize];
                        self.live_use(self.place_of(op.data).base);
                        self.push_ev(EV_MOVE, path, entry, t.span);
                        self.access(op.data, BF_NONE, ACC_FREE, entry, t.span);
                        self.f.freed.push(path);
                    } else if implicit {
                        if i < STATIC_PARAMS_MAX {
                            autoref = autoref | 1u64 << i as u64;
                        }
                        let tie = self.reborrow_ties(
                            t.callee.module,
                            &ptyn,
                            &rtok,
                            i,
                            ref_self,
                            nborrowing,
                            bidx,
                            relided,
                        );
                        let deep = tie && self.ref_deep(t.callee.module, &ptyn, rbeh, i);
                        self.implicit_borrow(op.data, kinds[i as usize], entry, dor0, tie, deep, dsd0, dmut0, t.span);
                    } else {
                        // A value that holds no borrow is copied out before the call runs: the
                        // loans its base holds end at the read, ahead of the callee's `&mut` claims.
                        if self.loans && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                            self.copy_out = !self.owner().carries(self.body().module, self.place_of(op.data).ty);
                        }
                        self.op_read(opid, entry, t.span);
                        self.copy_out = false;
                        // A `&mut` passed to a `&mut` parameter (every parameter of a fn value
                        // taking one is) reborrows its pointee: the call claims `*r` exactly like an
                        // autoref claims its place. A `[]mut T` view argument claims it alike.
                        if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && ((kinds[i as usize] == 2 || t.callee.node == NODE_NONE) && self.mut_ref_place(
                            op.data,
                        ) || self.mut_view_place(op.data)) {
                            self.access(op.data, BF_NONE, ACC_WRITE, entry, t.span);
                        }
                        // ref -> pointer at an argument erases the borrow: the reference leaves the
                        // checked world here, exactly like the walk's erase rule.
                        if self.loans && kinds[i as usize] == 3 && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                            let oty = self.place_of(op.data).ty;
                            if oty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(oty).kind == TypeKind::TYPE_REFERENCE {
                                let mut l = self.origin_first_loan(self.origin_of_place(op.data));
                                while l != BF_NONE {
                                    self.f.kills.push(KillAt { loan: l, point: entry });
                                    l = self.f.loan_next[l as usize];
                                }
                            }
                        }
                    }
                }
                if self.loans {
                    self.arg_clashes(&t, &kinds);
                }
                // A parameter naming `'static` keeps what its argument borrows for the whole
                // program: the argument's origin flows into `'static` (origin 0), so a borrow of
                // frame storage escapes, and a caller region must be declared `'static`. An
                // autoref'd place is the pointee itself: `'static` holds its contents at their own
                // level, and a `&'static` parameter's implicit borrow of the place.
                let mut sfl = if self.loans && t.callee.node != NODE_NONE {
                    cs.fl >> 8;
                } else {
                    0u64;
                };
                if cext.len() != 0 {
                    let mut stat = replace(&mut self.owner().sc_stat, Vector::<u64>::new());
                    self.owner().rel_static(self.rel, &mut stat);
                    sfl = 0;
                    for i in 0..ptyn.len().min(STATIC_PARAMS_MAX as usize) {
                        sfl = sfl | self.static_kind(t.callee.module, ptyn[i], &stat) as u64 << (2 * i) as u64;
                    }
                    self.owner().sc_stat = stat;
                }
                if sfl != 0 {
                    for i in 0..t.args_len.min(STATIC_PARAMS_MAX) {
                        let sk = (sfl >> (2 * i) as u64 & 3u64) as u8;
                        let oi = *self.body().operands.at(self.body().oper_pool[(t.args_start + i) as usize] as usize);
                        if sk != 0 && (oi.kind == ir::OP_COPY || oi.kind == ir::OP_MOVE) {
                            let auto = (autoref >> i as u64 & 1u64) != 0;
                            let e = if sk == 1 || auto {
                                SD_KEEP;
                            } else {
                                SD_DEREF;
                            };
                            self.subset_d(self.origin_of_place(oi.data), 0, entry, sd_then(self.place_edge(oi.data), e));
                            if auto && sk == 1 && !self.behind_raw(oi.data) {
                                // The implicit reference gets an origin of its own, held by `'static`.
                                let o = self.f.norigins;
                                self.f.norigins += 1;
                                self.f.origin_local.push(BF_NONE);
                                self.push_loan(false, false, 0u8, oi.data, LK_SHARED, o, entry + 1, t.span);
                                self.subset_d(o, 0, entry + 1, SD_KEEP);
                            }
                        }
                    }
                }
                // Arguments the callee's SIGNATURE ties to the pointee of a `&mut` parameter can
                // be stored through it (`put<'a>(s: &mut Slot<'a>, x: &'a i32)`, `push_into<T>(v:
                // &mut Vector<T>, x: T)`; the reference's own lifetime stores nothing): flow them
                // into the storage that argument reaches.
                // A shared reference stores too where its pointee keeps a type argument behind an
                // `UnsafeCell` (`send(self: &Sender<T>, value: T)`): those arguments' tokens only.
                for j in 0..ptyn.len() {
                    if kinds[j] != 2 && kinds[j] != 1 {
                        continue;
                    }
                    let mut jtok = replace(&mut self.owner().sc_tok_a, Vector::<u64>::new());
                    jtok.truncate(0);
                    let mut pointee = ptyn[j];
                    {
                        let pn = self.owner().ast_of(t.callee.module).at_const(pointee);
                        if pn.is_ref_type() {
                            pointee = pn.as_data.indirect_type.ty;
                        }
                    }
                    if kinds[j] == 2 {
                        self.lt_tokens(t.callee.module, pointee, &mut jtok, 0);
                    } else {
                        self.interior_tokens(t.callee.module, pointee, &mut jtok);
                    }
                    self.owner().rel_widen(self.rel, true, &mut jtok);
                    if jtok.len() != 0 {
                        let oj = *self.body().operands.at(
                            self.body().oper_pool[(t.args_start + j as u32) as usize] as usize,
                        );
                        // A pointee that can hold a borrow takes the store: a frame-owned container
                        // (an autoref with no deref on the way) here, else the storage the reference
                        // reaches, resolved once the whole body's facts exist.
                        let mut tor = BF_NONE;
                        let mut owned = false;
                        let mut through = false;
                        if (oj.kind == ir::OP_COPY || oj.kind == ir::OP_MOVE) && !self.behind_raw(oj.data) {
                            let bmod = self.body().module;
                            let jty = self.place_of(oj.data).ty;
                            let y = *self.owner().ast_of(bmod).type_at(jty);
                            let mut pointee_ty = jty;
                            if y.kind == TypeKind::TYPE_REFERENCE {
                                pointee_ty = y.as_data.elem;
                            }
                            if y.kind != TypeKind::TYPE_POINTER && self.owner().carries(bmod, pointee_ty) {
                                tor = self.origin_of_place(oj.data);
                                owned = y.kind != TypeKind::TYPE_REFERENCE && !self.behind(oj.data);
                                through = self.type_through(pointee_ty);
                            }
                        }
                        for i in 0..ptyn.len() {
                            if i == j || tor == BF_NONE {
                                continue;
                            }
                            let oi = *self.body().operands.at(
                                self.body().oper_pool[(t.args_start + i as u32) as usize] as usize,
                            );
                            if oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                                continue;
                            }
                            let mut itok = replace(&mut self.owner().sc_tok_b, Vector::<u64>::new());
                            itok.truncate(0);
                            self.arg_tokens(t.callee.module, oi.data, kinds[i], ptyn[i], &mut itok);
                            self.owner().rel_widen(self.rel, false, &mut itok);
                            if tokens_meet(&itok, &jtok) {
                                let aor = self.origin_of_place(oi.data);
                                if aor != BF_NONE {
                                    let te = self.store_target_edge(t.callee.module, ptyn[j], &itok);
                                    let e = self.store_arg_edge(t.callee.module, oi.data, kinds[i], ptyn[i], &jtok);
                                    let more = self.store_more(t.callee.module, pointee, &itok);
                                    self.store(aor, tor, owned, entry, e, te, through, more);
                                }
                            }
                            self.owner().sc_tok_b = itok;
                        }
                    }
                    self.owner().sc_tok_a = jtok;
                }
                // A `&mut self` receiver whose pointee holds borrows is a STORE TARGET: argument
                // borrows can land in the container (`v.push(&x)`), so they flow into the
                // receiver's origin. Other cross-argument stores are the signature checks' job.
                if self.loans && t.args_len != 0 && kinds[0] == 2 && (cs.fl & 1) != 0 {
                    let op0 = *self.body().operands.at(self.body().oper_pool[t.args_start as usize] as usize);
                    if op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE {
                        // A container the FRAME owns (no deref on the way, non-reference base)
                        // takes the store here; through a reference it lands in the storage the
                        // reference reaches (caller storage for a parameter).
                        let mut tor = BF_NONE;
                        let mut through0 = false;
                        let p0 = self.place_of(op0.data);
                        let mut owned0 = !self.behind(op0.data);
                        let b0ty = self.body().locals.at(p0.base as usize).ty;
                        // A `&dyn` / `&mut dyn` value points at its object like a reference.
                        if b0ty != TYPE_NONE && (self.owner().ast_of(self.body().module).type_at(b0ty).kind == TypeKind::TYPE_REFERENCE || self.owner().ast_of(
                            self.body().module,
                        ).type_at(b0ty).kind == TypeKind::TYPE_DYN) {
                            owned0 = false;
                        }
                        let p0ty = p0.ty;
                        if p0ty != TYPE_NONE && !self.behind_raw(op0.data) {
                            let y0 = *self.owner().ast_of(self.body().module).type_at(p0ty);
                            let mut inner = p0ty;
                            if y0.kind == TypeKind::TYPE_REFERENCE {
                                inner = y0.as_data.elem;
                                owned0 = false;
                            }
                            // A `dyn` or generic receiver may be any conforming type: the signature
                            // tokens below decide what it can take.
                            let ik = self.owner().ast_of(self.body().module).type_at(inner).kind;
                            if self.stores_borrows(self.body().module, inner) || ik == TypeKind::TYPE_DYN || ik == TypeKind::TYPE_GENERIC {
                                tor = self.origin_of_place(op0.data);
                                through0 = self.type_through(inner);
                            }
                        }
                        if tor != BF_NONE {
                            // Same signature gate as the `&mut`-parameter ties: an argument lands
                            // in the container only when the receiver's type tokens admit it.
                            let mut jtok0 = replace(&mut self.owner().sc_tok_a, Vector::<u64>::new());
                            jtok0.truncate(0);
                            if ptyn.len() != 0 {
                                self.lt_tokens(t.callee.module, ptyn[0], &mut jtok0, 0);
                            }
                            self.owner().rel_widen(self.rel, true, &mut jtok0);
                            // An argument the callee does not declare has no tokens, so no tie.
                            for j in 1..ptyn.len() {
                                let oj = *self.body().operands.at(
                                    self.body().oper_pool[t.args_start as usize + j] as usize,
                                );
                                if oj.kind != ir::OP_COPY && oj.kind != ir::OP_MOVE {
                                    continue;
                                }
                                let aor = self.origin_of_place(oj.data);
                                if aor == BF_NONE {
                                    continue;
                                }
                                let mut itok3 = replace(&mut self.owner().sc_tok_b, Vector::<u64>::new());
                                itok3.truncate(0);
                                self.arg_tokens(t.callee.module, oj.data, kinds[j], ptyn[j], &mut itok3);
                                self.owner().rel_widen(self.rel, false, &mut itok3);
                                if tokens_meet(&itok3, &jtok0) {
                                    let e = self.store_arg_edge(t.callee.module, oj.data, kinds[j], ptyn[j], &jtok0);
                                    let te = self.store_target_edge(t.callee.module, ptyn[0], &itok3);
                                    let more = if ptyn.len() != 0 {
                                        self.store_more(
                                            t.callee.module,
                                            self.pointee_node(t.callee.module, ptyn[0]),
                                            &itok3,
                                        );
                                    } else {
                                        0u8;
                                    };
                                    self.store(aor, tor, owned0, entry, e, te, through0, more);
                                }
                                self.owner().sc_tok_b = itok3;
                            }
                            self.owner().sc_tok_a = jtok0;
                        }
                    }
                }
                for d in 0..t.dests_len {
                    let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                    self.write_place(dp, exit, t.span);
                }
                // A borrow-carrying result derives from its RECEIVER (the walk's result-pin hook)
                // and from the arguments the SIGNATURE ties to the return: shared lifetime/generic
                // tokens, or the elision rule (one borrowing input feeds an elided return).
                if self.loans {
                    for d in 0..t.dests_len {
                        let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                        let dor = self.origin_of_place(dp);
                        if dor == BF_NONE {
                            continue;
                        }
                        let dty = self.place_of(dp).ty;
                        if dty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(dty).kind == TypeKind::TYPE_POINTER {
                            continue;
                        }
                        for i in 0..t.args_len {
                            let opid = self.body().oper_pool[(t.args_start + i) as usize];
                            let op = *self.body().operands.at(opid as usize);
                            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                                continue;
                            }
                            let mut tie = i == 0 && recv;
                            if !tie && relide && nborrowing == 1 && i == bidx {
                                // Elision: the single borrowing input feeds the return.
                                tie = true;
                            }
                            let mut by_tok = false;
                            if !tie && rtok.len() != 0 && i as usize < ptyn.len() {
                                let mut itok2 = replace(&mut self.owner().sc_tok_b, Vector::<u64>::new());
                                itok2.truncate(0);
                                self.lt_tokens(t.callee.module, ptyn[i as usize], &mut itok2, 0);
                                tie = tokens_meet(&itok2, &rtok);
                                by_tok = tie;
                                self.owner().sc_tok_b = itok2;
                            }
                            let lvl = self.reborrow_ties(
                                t.callee.module,
                                &ptyn,
                                &rtok,
                                i,
                                ref_self,
                                nborrowing,
                                bidx,
                                relided,
                            );
                            if tie {
                                let aor = self.origin_of_place(op.data);
                                if aor != BF_NONE {
                                    let picked = if ref_self {
                                        i == 0;
                                    } else {
                                        nborrowing == 1 && i == bidx;
                                    };
                                    let e = self.tie_edge(
                                        t.callee.module,
                                        &ptyn,
                                        rbeh,
                                        &rtok,
                                        op.data,
                                        kinds[i as usize],
                                        i,
                                        lvl,
                                        picked,
                                        by_tok,
                                        relided,
                                    );
                                    self.subset_d(aor, dor, entry, sd_then(e, self.store_edge(dp)));
                                }
                                // A tie through a type argument the argument keeps interior is
                                // invariant: what the result holds may land in the argument too
                                // (`let tx = ch.sender(); tx.send(..)` fills the channel).
                                if i as usize < ptyn.len() {
                                    let mut itok3 = replace(&mut self.owner().sc_tok_c, Vector::<u64>::new());
                                    itok3.truncate(0);
                                    self.interior_tokens(
                                        t.callee.module,
                                        self.pointee_node(t.callee.module, ptyn[i as usize]),
                                        &mut itok3,
                                    );
                                    let back = tokens_meet(&itok3, &rtok);
                                    self.owner().sc_tok_c = itok3;
                                    let ao = self.origin_of_place(op.data);
                                    if back && ao != BF_NONE && !self.behind_raw(op.data) {
                                        self.ties.push(ao as u64 << 32 | dor as u64);
                                    }
                                }
                            }
                            // A `&mut` handed to a reference parameter is reborrowed: when the
                            // signature ties that parameter's own lifetime to the return, the result
                            // holds a loan on the pointee, so a later claim or write of `*r`
                            // conflicts, whatever other borrows the pointee holds (those flow above).
                            // Through a `&mut` parameter (any parameter of a fn value) into a result
                            // that grants write, the loan is exclusive, as an autoref's is
                            // (`implicit_borrow`): a later read of `*r` conflicts too.
                            let kd = kinds[i as usize];
                            if (kd == 1 || kd == 2 || t.callee.node == NODE_NONE) && self.mut_ref_place(op.data) && lvl {
                                let level = if self.ref_deep(t.callee.module, &ptyn, rbeh, i) {
                                    2u8;
                                } else {
                                    self.store_level(dp);
                                };
                                let lk = if kd != 1 && self.grants_write(dty, 0) {
                                    LK_MUT;
                                } else {
                                    LK_SHARED;
                                };
                                self.push_loan(false, true, level, op.data, lk, dor, exit, t.span);
                            }
                        }
                    }
                }
                self.owner().sc_tok_r = rtok;
                self.owner().sc_kinds = kinds;
                self.owner().sc_ptyn = ptyn;
            } else if t.kind == ir::TM_RETURN {
                let nrets = self.body().returns;
                for r in 0..nrets {
                    self.live_use(r);
                }
                for r in 0..nrets {
                    if r as usize < self.f.ret_origin.len() && self.f.ret_origin[r as usize] != BF_NONE {
                        let lo = self.f.local_origin[r as usize];
                        let ro = self.f.ret_origin[r as usize];
                        self.subset(lo, ro, entry);
                    }
                }
            } else if t.kind == ir::TM_DROP {
                if t.a != ir::IR_NONE {
                    // At analysis time only USER-written destruction exists (`d.free()` on a dyn);
                    // elaboration inserts its drops afterwards. It consumes the place, unless the
                    // place is (or is reached through) a raw pointer: `p.free()` destroys the
                    // POINTEE, unsafe-world storage the checker never tracks, and only reads the
                    // pointer.
                    self.live_use(self.place_of(t.a).base);
                    let path = self.forest().place_path[t.a as usize];
                    if self.behind_raw(t.a) {
                        if path != mp::MP_NONE {
                            self.push_ev(EV_USE, path, entry, t.span);
                        }
                        self.access(t.a, BF_NONE, ACC_READ, entry, t.span);
                    } else {
                        if path != mp::MP_NONE {
                            self.push_ev(EV_MOVE, path, entry, t.span);
                        }
                        self.access(t.a, BF_NONE, ACC_FREE, entry, t.span);
                    }
                }
            }
        }
        let ne = self.f.events.len() as u32;
        self.f.ev_start.push(ne);
        self.f.mev_start.push(self.f.mev.len() as u32);
    }

    // Push one event, mirroring it into the fixpoint's mutating stream and the block's report and
    // easy flags as it lands, so no later pass re-reads the whole stream. A block stays "easy"
    // while it holds only assigns (which strictly improve state) and uses of root-leaf paths
    // (whose error checks reduce to that path's own entry bits): the reporting pass can then
    // clear it against the entry rows in O(words) instead of replaying.
    @always_inline
    fn push_ev(self: &mut Self, kind: u8, path: u32, point: u32, sp: tok::Span) {
        self.f.events.push(ev(kind, path, point, sp));
        if kind == EV_ASSIGN || kind == EV_DEAD || kind == EV_MOVE {
            self.f.mev.push(ev(kind, path, point, sp));
        }
        if kind == EV_USE || kind == EV_MOVE || kind == EV_MOVE_CUT {
            self.f.rep_blk.set(self.cur_block as usize, true);
        }
        if kind == EV_MOVE || kind == EV_MOVE_CUT {
            self.f.nmoves += 1;
        }
        if kind != EV_ASSIGN {
            let fo = self.forest();
            if kind != EV_USE || fo.parent[path as usize] != mp::MP_NONE || !fo.is_leaf(path) {
                self.f.easy_blk.set(self.cur_block as usize, false);
            } else {
                let slot = (self.cur_block * self.f.ewords + path / 64) as usize;
                self.f.easy_use.set(slot, self.f.easy_use[slot] | 1u64 << (path & 63) as u64);
            }
        }
    }

    // A borrow of place `src` stored into `s.place` (origin `dor`): `&src` / `&mut src`, or an array's
    // slice view.
    fn borrow_place(self: &mut Self, s: &ir::Statement, src: ir::PlaceId, mutb: bool, dor: u32, entry: u32, exit: u32) {
        let spl = self.place_of(src);
        self.live_use(spl.base);
        // The borrow itself reads (shared) or claims (mutable) the place. A two-phase `&mut`
        // (temp destination) claims nothing at issue: its activation carries the claim.
        let mut ak = ACC_READ;
        if mutb && self.body().locals.at(self.place_of(s.place).base as usize).storage != ir::LS_TEMP {
            ak = ACC_WRITE;
        }
        self.access(src, BF_NONE, ak, entry, s.span);
        // Init requirement: every borrow reads the place's current value. A `&mut` of a moved or
        // uninitialized path would let its holder read or drop the stale bytes.
        let mut upath = self.forest().place_path[src as usize];
        if upath == mp::MP_NONE {
            upath = self.forest().place_cut[src as usize];
        }
        if upath != mp::MP_NONE {
            self.push_ev(EV_USE, upath, entry, s.span);
        }
        if self.loans {
            let mut kind = LK_SHARED;
            if mutb {
                kind = LK_MUT;
                if self.body().locals.at(self.place_of(s.place).base as usize).storage == ir::LS_TEMP {
                    kind = LK_RESERVED;
                }
            }
            let mut org = dor;
            if org == BF_NONE {
                org = 0;
            }
            // A borrow stored into a member `place_bounds` marks starts in an origin of its own that
            // flows into the destination's, so `member_store` finds it as a stored value.
            let mut own = BF_NONE;
            if dor != BF_NONE && self.place_of(s.place).proj_len != 0 && !self.behind_raw(s.place) && self.place_bounds(
                s.place,
            ) != 0 {
                own = self.f.norigins;
                self.f.norigins += 1;
                self.f.origin_local.push(BF_NONE);
                org = own;
            }
            if !self.behind_raw(src) && !(mutb && self.shared_deref(src)) {
                self.push_loan(false, false, self.store_level(s.place), src, kind, org, exit, s.span);
            }
            // A reborrow's validity chains to the reference it went through (its loans keep their
            // level); a borrow of a slot that itself HOLDS borrows links the slot's origin, whose
            // loans now lie behind the new reference: both ways when mutable, because stores
            // through the reference land in the slot (invariance).
            let src_carries = self.owner().carries(self.body().module, self.place_of(src).ty);
            // A reborrow through a raw pointer is unbounded: the pointer carries no origin.
            if !self.behind_raw(src) {
                if self.behind(src) {
                    self.flow_into(self.f.local_origin[spl.base as usize], org, entry, SD_KEEP, s.place);
                } else if src_carries {
                    self.flow_into(self.f.local_origin[spl.base as usize], org, entry, SD_REF, s.place);
                }
                if mutb && src_carries {
                    self.subset_d(org, self.f.local_origin[spl.base as usize], entry, SD_DEREF);
                }
            }
            if own != BF_NONE {
                // No local keeps `own` live between the points: its flows into it at the entry
                // (reborrow chains) and its loan at the exit pass on where they arrive.
                self.subset_d(own, dor, entry, SD_KEEP);
                self.subset_d(own, dor, exit, SD_KEEP);
            }
        }
        self.write_place(s.place, exit, s.span);
    }

    // What by-reference capture `p` holds lies behind the closure value's reference to it (origin
    // `org`, stored into `dst`), as it does behind `&p`: a call of the closure through a value or a
    // bound returns those borrows.
    fn cap_contents(self: &mut Self, p: ir::PlaceId, org: u32, entry: u32, dst: ir::PlaceId) {
        let po = self.f.local_origin[self.place_of(p).base as usize];
        if self.behind(p) {
            self.flow_into(po, org, entry, SD_KEEP, dst);
        } else if self.owner().carries(self.body().module, self.place_of(p).ty) {
            self.flow_into(po, org, entry, SD_REF, dst);
        }
    }

    fn stmt_assign(self: &mut Self, s: &ir::Statement, entry: u32, exit: u32) {
        let rv = *self.body().rvalues.at(s.rvalue as usize);
        let mut dor = self.origin_of_place(s.place);
        // A raw-pointer destination is the unsafe world's handoff: the stored value's origins do
        // not flow through it.
        {
            let dty = self.place_of(s.place).ty;
            if dty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(dty).kind == TypeKind::TYPE_POINTER {
                dor = BF_NONE;
            }
        }
        if rv.kind == ir::RV_REF {
            self.borrow_place(s, rv.a, rv.b == 1, dor, entry, exit);
            return;
        }
        // An array's slice view borrows the array like `&x` / `&mut x`: the view holds the loan.
        if rv.kind == ir::RV_USE && rv.b != 0 {
            let op = *self.body().operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                self.borrow_place(s, op.data, rv.b == 2, dor, entry, exit);
                return;
            }
        }
        if rv.kind == ir::RV_ADDR {
            // Raw addresses live in the unsafe world; the base local stays live, nothing else.
            self.live_use(self.place_of(rv.a).base);
            self.write_place(s.place, exit, s.span);
            return;
        }
        if rv.kind == ir::RV_CLOSURE {
            let mut mut_caps: u64 = 0;
            let mut ref_caps: u64 = 0;
            if rv.item.node != NODE_NONE {
                let cf = self.owner().ast_of(self.body().module).closure_fact(rv.item.node);
                if cf != null {
                    mut_caps = unsafe (&*cf).mut_caps;
                    ref_caps = unsafe (&*cf).ref_caps;
                }
            }
            let mut org = dor;
            if org == BF_NONE {
                org = 0;
            }
            // A closure whose body names a lifetime of this function holds that region.
            if self.loans && rv.item.node != NODE_NONE {
                let bm = self.body().module;
                for k in 0..self.owner().ast_of(bm).closure_lts.len() {
                    let e = self.owner().ast_of(bm).closure_lts[k];
                    if (e >> 32) as NodeId != rv.item.node {
                        continue;
                    }
                    let nm = self.lt_name(bm, (e & 0xFFFFFFFFu64) as NodeId);
                    for u in 1..self.f.nuniversal {
                        if org >= self.f.nuniversal && self.name_eq(self.f.uni_name[u as usize], nm) {
                            self.f.named.push(org as u64 << 32 | u as u64);
                        }
                    }
                }
            }
            for i in 0..rv.b {
                let opid = self.body().oper_pool[(rv.a + i) as usize];
                let op = *self.body().operands.at(opid as usize);
                if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                    continue;
                }
                let l0 = self.f.loans.len() as u32;
                // A capture the closure's destruction cannot read flows into it, not into its drop
                // origin (`Owner::cap_keep`).
                self.no_drop = i < 64 && (self.owner().cap_keep_of(self.body().module, rv.item.node) >> i as u64 & 1u64) == 0;
                if (mut_caps >> i as u64 & 1u64) != 0 {
                    // A mutable capture is a mutable borrow held by the closure value.
                    let pl = self.place_of(op.data);
                    self.live_use(pl.base);
                    self.access(op.data, BF_NONE, ACC_WRITE, entry, s.span);
                    if self.loans && !self.behind_raw(op.data) {
                        self.push_loan(false, false, self.store_level(s.place), op.data, LK_CAP, org, exit, s.span);
                        self.cap_contents(op.data, org, entry, s.place);
                    }
                } else if (ref_caps >> i as u64 & 1u64) != 0 {
                    // A borrowed capture is a shared borrow held by the closure value.
                    let pl = self.place_of(op.data);
                    self.live_use(pl.base);
                    self.access(op.data, BF_NONE, ACC_READ, entry, s.span);
                    if self.loans && !self.behind_raw(op.data) {
                        self.push_loan(false, false, self.store_level(s.place), op.data, LK_SHARED, org, exit, s.span);
                        self.cap_contents(op.data, org, entry, s.place);
                    }
                } else {
                    self.in_caps = true;
                    self.op_read(opid, entry, s.span);
                    self.in_caps = false;
                    let aor = self.origin_of_place(op.data);
                    self.flow_into(aor, dor, entry, self.place_edge(op.data), s.place);
                    if aor != BF_NONE && dor != BF_NONE && aor != dor {
                        self.cap_tags.push(CapTag { loan: BF_NONE, from: aor, to: dor, node: rv.item.node, k: i });
                    }
                    // A copied `&mut` or `[]mut T` capture is a unique reborrow held by the closure.
                    self.reborrow_store(op.data, dor, s.place, exit, s.span);
                }
                for l in l0..self.f.loans.len() as u32 {
                    self.cap_tags.push(CapTag { loan: l, from: BF_NONE, to: BF_NONE, node: rv.item.node, k: i });
                }
                self.no_drop = false;
            }
            self.write_place(s.place, exit, s.span);
            return;
        }
        // Value-carrying rvalues: read operands, flow borrow-carrying operand origins into the
        // destination, then write.
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_DYN || rv.kind == ir::RV_REPEAT {
            // The `&mut`-copy-consumes rule is a REBIND rule: a `&mut` or `[]mut T` copied whole into a
            // local of its own kind (`let r2 = r1`) moves; a store into a field reborrows below, and a
            // coercion into the raw-pointer world does neither.
            let mut field_store = false;
            if rv.kind == ir::RV_USE {
                let dpl = self.place_of(s.place);
                let own_kind = self.mut_ref_place(s.place) || self.mut_view_place(s.place);
                self.plain_copy = own_kind && dpl.proj_len == 0;
                field_store = own_kind && dpl.proj_len != 0;
            }
            self.op_read(rv.a, entry, s.span);
            self.plain_copy = false;
            let op = *self.body().operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let aor = self.origin_of_place(op.data);
                self.flow_into(aor, dor, entry, self.place_edge(op.data), s.place);
                if field_store {
                    self.reborrow_store(op.data, dor, s.place, exit, s.span);
                }
                // Reading a VIEW value out of a non-carrying container (`v[0..2]` copies a slice)
                // pins the container exactly like the call-result hook.
                let opl = self.place_of(op.data);
                if dor != BF_NONE && rv.kind == ir::RV_USE && opl.ty != TYPE_NONE && opl.proj_len != 0 {
                    self.pin_view(op.data, opl.ty, dor, self.store_level(s.place), exit, s.span);
                }
            }
        } else if rv.kind == ir::RV_SLICE {
            // Structural slicing yields a VIEW of the container's storage. An owned container (an
            // array, a vector, a string the frame holds) is borrowed like `&c` / `&mut c`: the view
            // holds the loan, and what the container holds lies behind it.
            let sub_mut = self.mut_view_ty(rv.target);
            if !self.behind(rv.a) && !self.view_ty(self.place_of(rv.a).ty) && !self.behind_raw(rv.a) {
                if rv.b != ir::IR_NONE {
                    self.op_read(rv.b, entry, s.span);
                }
                if rv.item.node != ir::IR_NONE {
                    self.op_read(rv.item.node, entry, s.span);
                }
                self.borrow_place(s, rv.a, sub_mut, dor, entry, exit);
                return;
            }
            // A container reached through a reference or a view, or a view itself: the sub-view
            // views the same storage, so it holds the reference's or the view's loans at their levels.
            let bpl = self.place_of(rv.a);
            self.live_use(bpl.base);
            self.access(rv.a, BF_NONE, ACC_READ, entry, s.span);
            if rv.b != ir::IR_NONE {
                self.op_read(rv.b, entry, s.span);
            }
            if rv.item.node != ir::IR_NONE {
                self.op_read(rv.item.node, entry, s.span);
            }
            self.flow_into(self.origin_of_place(rv.a), dor, entry, SD_KEEP, s.place);
            // A sub-view of a `[]mut T` reborrows its elements: shared for a `[]T`, exclusive for a
            // `[]mut T`, for as long as the sub-view lives.
            if dor != BF_NONE && self.loans && self.mut_view_place(rv.a) && !self.behind_raw(rv.a) {
                let lk = if sub_mut {
                    LK_MUT;
                } else {
                    LK_SHARED;
                };
                self.push_loan(false, true, self.store_level(s.place), rv.a, lk, dor, exit, s.span);
            }
        } else if rv.kind == ir::RV_BINARY {
            // An operator never consumes its operands: an owning operand only reaches a built-in
            // binary operator as a comparison, which the backend evaluates through the operands'
            // addresses, so the read is not a move and the owner still drops it.
            self.calling = true;
            self.op_read(rv.a, entry, s.span);
            self.op_read(rv.b, entry, s.span);
            self.calling = false;
        } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF || rv.c == ir::IN_TYPE_INFO || rv.c == ir::IN_DANGLING) {
            // No operands: `b` is the measured/described type.
        } else if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_INTRINSIC || rv.kind == ir::RV_SIMD {
            // A vector operation reads its operands; a store (whole, masked, scatter or compressing)
            // writes through its `[]mut T` slice, as a call taking the view does (a raw pointer
            // carries no loan).
            for i in 0..rv.b {
                let opid = self.body().oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    // Omitted struct member: no operand, C zero-fills.
                    continue;
                }
                self.op_read(opid, entry, s.span);
                let op = *self.body().operands.at(opid as usize);
                if rv.kind == ir::RV_SIMD && i == 0 && ir::simd_writes(rv.c) && op.kind != ir::OP_CONST && self.mut_view_place(
                    op.data,
                ) {
                    self.access(op.data, BF_NONE, ACC_WRITE, entry, s.span);
                }
                if rv.kind == ir::RV_AGGREGATE {
                    let op = *self.body().operands.at(opid as usize);
                    if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                        let aor = self.origin_of_place(op.data);
                        self.flow_into(aor, dor, entry, self.place_edge(op.data), s.place);
                        self.reborrow_store(op.data, dor, s.place, exit, s.span);
                        if self.loans && aor != BF_NONE && dor != BF_NONE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_VARIANT || rv.c == ir::AGG_TUPLE && rv.item.node != NODE_NONE) {
                            self.member_value(&rv, i, aor, op.data, dor, s.place, entry);
                        }
                    }
                }
            }
        } else if rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            let pl = self.place_of(rv.a);
            self.live_use(pl.base);
            self.access(rv.a, BF_NONE, ACC_READ, entry, s.span);
        }
        self.write_place(s.place, exit, s.span);
    }

    // Kills: an assignment that overwrites a loan's borrowed storage (its path is a must-equal
    // prefix of the loan's) ends the loan. Storage markers kill every loan based on their local.
    fn finish(self: &mut Self) {
        if !self.loans {
            return;
        }
        let na = self.assign_sites.len();
        let nl = self.f.loans.len();
        if na * nl >= 1024 {
            // Loans bucketed by their place's base local: a site can only kill loans on its own
            // base (kill_covers demands equal bases), so the na*nl sweep shrinks to the matches.
            // Bucket order is ascending loan id: exactly the subsequence the sweep pushed.
            let mut lb_start = replace(&mut self.owner().sc_lb_start, Vector::<u32>::new());
            let mut lb_flat = replace(&mut self.owner().sc_lb_flat, Vector::<u32>::new());
            let mut curp = replace(&mut self.owner().sc_curp, Vector::<u32>::new());
            bucket_loans_by_base(self.body(), &self.f.loans, &mut lb_start, &mut lb_flat, &mut curp);
            for a in 0..na {
                let site = *self.assign_sites.at(a);
                let base = if site.local != BF_NONE {
                    site.local as usize;
                } else {
                    self.place_of(site.place).base as usize;
                };
                for li in lb_start[base]..lb_start[base + 1] {
                    let l = lb_flat[li as usize];
                    if site.local != BF_NONE || self.kill_covers(site.place, self.f.loans.at(l as usize).place) {
                        self.f.kills.push(KillAt { loan: l, point: site.point });
                    }
                }
            }
            self.owner().sc_lb_start = lb_start;
            self.owner().sc_lb_flat = lb_flat;
            self.owner().sc_curp = curp;
        } else {
            for a in 0..na {
                let site = *self.assign_sites.at(a);
                for l in 0..nl {
                    let lp = self.f.loans.at(l).place;
                    if site.local != BF_NONE {
                        if self.place_of(lp).base == site.local {
                            self.f.kills.push(KillAt { loan: l as u32, point: site.point });
                        }
                    } else if self.kill_covers(site.place, lp) {
                        self.f.kills.push(KillAt { loan: l as u32, point: site.point });
                    }
                }
            }
        }
        // Reserved loans activate at the first later read of the holder temp. The pre-activation
        // access list is point-sorted (the walk emits blocks and statements in order; ACC_ACT
        // records appended below stay past the snapshot), so a lower bound plus a short forward
        // scan replaces the full sweeps: the first ascending match IS the earliest point.
        let nacc = self.f.accesses.len();
        for l in 0..nl {
            if self.f.loans.at(l).kind != LK_RESERVED {
                continue;
            }
            let ip = self.f.loans.at(l).issued_at;
            let mut lo2: usize = 0;
            let mut hi2 = nacc;
            while lo2 < hi2 {
                let mid = (lo2 + hi2) / 2;
                if self.f.accesses.at(mid).point < ip {
                    lo2 = mid + 1;
                } else {
                    hi2 = mid;
                }
            }
            let mut holder = BF_NONE;
            let mut a = lo2;
            while a < nacc && self.f.accesses.at(a).point == ip {
                let ac = *self.f.accesses.at(a);
                if ac.kind == ACC_WRITE && ac.place != BF_NONE && self.place_of(ac.place).proj_len == 0 {
                    holder = self.place_of(ac.place).base;
                    break;
                }
                a += 1;
            }
            if holder == BF_NONE {
                continue;
            }
            let mut act = BF_NONE;
            a = lo2;
            while a < nacc {
                let ac = *self.f.accesses.at(a);
                // A `&mut` holder temp is consumed (ACC_MOVE) when it lands in a user binding; that
                // copy is the activation read.
                if (ac.kind == ACC_READ || ac.kind == ACC_MOVE) && ac.place != BF_NONE && ac.point > ip && self.place_of(
                    ac.place,
                ).base == holder {
                    act = ac.point;
                    break;
                }
                a += 1;
            }
            self.f.loans[l].activated_at = act;
            if act != BF_NONE {
                // Activation asserts the mutable claim against every OTHER required loan.
                let lpl = self.f.loans.at(l).place;
                let lsp = self.f.loans.at(l).span;
                self.access(lpl, BF_NONE, ACC_ACT, act, lsp);
            }
        }
    }

    // Is `a`'s projection path a must-equal prefix of `b`'s (same base)?
    const fn kill_covers(self: &Self, a: ir::PlaceId, bp: ir::PlaceId) bool {
        let pa = self.place_of(a);
        let pb = self.place_of(bp);
        if pa.base != pb.base || pa.proj_len > pb.proj_len {
            return false;
        }
        for i in 0..pa.proj_len {
            let ea = *self.body().projections.at((pa.proj_start + i) as usize);
            let eb = *self.body().projections.at((pb.proj_start + i) as usize);
            if ea.kind != eb.kind {
                return false;
            }
            if ea.kind == ir::PJ_FIELD && (ea.sub != eb.sub || ir::field_data(&ea) != ir::field_data(&eb)) {
                return false;
            }
            if (ea.kind == ir::PJ_DOWNCAST || ea.kind == ir::PJ_INDEX_CONST) && (ea.data != eb.data || ea.sub != eb.sub) {
                return false;
            }
            if ea.kind == ir::PJ_INDEX_OP {
                // A dynamic index cannot prove it hits the borrowed element.
                return false;
            }
        }
        return true;
    }
}

/// May accesses of `a` and `b` touch overlapping storage? Same base local, and neither path proves
/// disjointness (differing fields, variants, or constant indexes) before one ends.
pub const fn places_conflict(b: &ir::CoreBody, a: ir::PlaceId, c: ir::PlaceId) bool {
    let pa = *b.places.at(a as usize);
    let pc = *b.places.at(c as usize);
    if pa.base != pc.base {
        return false;
    }
    let mut n = pa.proj_len;
    if pc.proj_len < n {
        n = pc.proj_len;
    }
    for i in 0..n {
        let ea = *b.projections.at((pa.proj_start + i) as usize);
        let ec = *b.projections.at((pc.proj_start + i) as usize);
        if ea.kind != ec.kind {
            // Differing shapes at the same depth still reach overlapping storage only through the
            // same chain; stay conservative and report overlap.
            return true;
        }
        if ea.kind == ir::PJ_FIELD && ea.data == ir::IR_NONE && ea.sub == NODE_NONE {
            // A reflection-binder member has no per-field identity yet; expansion re-proves each
            // copy, so two such projections never conflict here.
            return false;
        }
        if ea.kind == ir::PJ_FIELD && (ea.data == ir::PJ_UNION_FIELD || ec.data == ir::PJ_UNION_FIELD) {
            // Union members share storage whatever the field.
            return true;
        }
        if ea.kind == ir::PJ_FIELD && ir::fields_differ(&ea, &ec) {
            return false;
        }
        if (ea.kind == ir::PJ_DOWNCAST || ea.kind == ir::PJ_INDEX_CONST) && (ea.data != ec.data || ea.sub != ec.sub) {
            return false;
        }
    }
    return true;
}

extend Owner {
    /// An ownership oracle over `pkg` (which must outlive it) with empty memo tables.
    pub fn new(pkg: *const loader::Package) Owner {
        let sm = unsafe (&*pkg).prelude_lookup("SliceMut", true);
        let sl = unsafe (&*pkg).prelude_lookup("Slice", true);
        let ss = unsafe (&*pkg).prelude_lookup("str", true);
        let uc = unsafe (&*pkg).prelude_lookup("UnsafeCell", true);
        return Owner {
            pkg: pkg,
            slice_mut: DefId { module: sm.mid, node: sm.node },
            slice: DefId { module: sl.mid, node: sl.node },
            str_def: DefId { module: ss.mid, node: ss.node },
            unsafe_cell: DefId { module: uc.mid, node: uc.node },
            interior_memo: Map::<u64, u64>::new(),
            free_ext: Map::<u64, u64>::new(),
            ext_built: false,
            owns_arr: Vector::<Vector<u64>>::new(),
            carry_arr: Vector::<Vector<u64>>::new(),
            obs_arr: Vector::<Vector<u64>>::new(),
            busy: Vector::<u64>::new(),
            low: BUSY_NONE,
            at: DefId { module: 0, node: NODE_NONE },
            subst: Vector::<OwnSubst>::new(),
            tys: Vector::<TypeId>::new(),
            call_sigs: Map::<u64, CallSig>::new(),
            gen_sigs: Map::<u64, TypeId>::new(),
            gen_cls: Map::<u64, u64>::new(),
            gen_cls_pool: Vector::<u8>::new(),
            cap_reach: Map::<u64, u64>::new(),
            cap_reach_pool: Vector::<u64>::new(),
            cap_keep: Map::<u64, u64>::new(),
            res_deep: Map::<u64, bool>::new(),
            kinds_memo: Map::<u64, u64>::new(),
            kinds_pool: Vector::<u8>::new(),
            tok_memo: Map::<u64, u64>::new(),
            beh_memo: Map::<u64, u64>::new(),
            tok_pool: Vector::<u64>::new(),
            rel_memo: Map::<u64, u64>::new(),
            rel_pool: Vector::<u64>::new(),
            sc_assign_sites: Vector::<KillSite>::new(),
            sc_seen: Vector::<u64>::new(),
            sc_kinds: Vector::<u8>::new(),
            sc_ptyn: Vector::<NodeId>::new(),
            sc_tys: Vector::<TypeId>::new(),
            sc_lb_start: Vector::<u32>::new(),
            sc_lb_flat: Vector::<u32>::new(),
            sc_curp: Vector::<u32>::new(),
            sc_tok_a: Vector::<u64>::new(),
            sc_tok_b: Vector::<u64>::new(),
            sc_tok_c: Vector::<u64>::new(),
            sc_tok_r: Vector::<u64>::new(),
            sc_stat: Vector::<u64>::new(),
            sc_stores: Vector::<StoreVia>::new(),
            sc_visit: Vector::<u64>::new(),
            sc_ties: Vector::<u64>::new(),
            sc_istores: Vector::<StoreVia>::new(),
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    /// Module `m`'s frozen AST (types are read through it).
    pub const fn ast_of(self: &Self, m: ModuleId) &Ast {
        return unsafe &*self.p().module_ast_const(m);
    }

    const fn src_of(self: &Self, m: ModuleId) str<'static> {
        let s = self.p().modules.at(m as usize).source.as_str();
        return s;
    }

    const fn span_text_is(self: &Self, m: ModuleId, sp: tok::Span, what: str) bool {
        let s = self.src_of(m);
        if sp.end <= sp.start || sp.end as usize > s.len() {
            return false;
        }
        return s.slice(sp.start as usize, sp.end as usize) == what;
    }

    /// The name of lifetime node `lt` of `a` (a use or a declaration), or empty.
    fn lt_name(self: &Self, a: &Ast, lt: NodeId) tok::Span {
        if lt == NODE_NONE {
            return tok::Span::empty();
        }
        let n = a.at_const(lt);
        if n.kind == NodeKind::NODE_GENERIC_PARAM {
            return self.lt_name(a, n.as_data.generic_param.name);
        }
        return n.as_data.name.text;
    }

    /// Does function `callee` take a `&'static` parameter (or a reference whose lifetime its signature
    /// declares or implies to outlive `'static`)? An implicit autoref passed to one borrows for the
    /// whole program.
    pub fn takes_static_ref(self: &mut Self, callee: DefId) bool {
        let rel = self.callee_rel(callee);
        let mut stat = replace(&mut self.sc_stat, Vector::<u64>::new());
        self.rel_static(rel, &mut stat);
        let a = self.ast_of(callee.module);
        let nd = a.at_const(callee.node);
        let mut r = false;
        if nd.kind == NodeKind::NODE_FUNCTION {
            let ps = nd.as_data.function.params;
            for i in 0..ps.len {
                let ptn = a.at_const(unsafe a.list(ps)[i as usize]).as_data.parameter.ty;
                if ptn != NODE_NONE && a.at_const(ptn).is_ref_type() && stat.contains(
                    &self.lt_tok(callee.module, a.at_const(ptn).as_data.indirect_type.lifetime),
                ) {
                    r = true;
                    break;
                }
            }
        }
        self.sc_stat = stat;
        return r;
    }

    /// The token of lifetime node `lt` of module `m`, a use or a declaration: its name's hash with bit
    /// 63 set, 0 when elided (absent or `'_`). Equal names give equal tokens in every module.
    pub fn lt_tok(self: &Self, m: ModuleId, lt: NodeId) u64 {
        let sp = self.lt_name(self.ast_of(m), lt);
        if sp.end <= sp.start || self.span_text_is(m, sp, "'_") {
            return 0;
        }
        return 1u64 << 63 | fnv(self.src_of(m).slice(sp.start as usize, sp.end as usize)) & 0x7FFFFFFFFFFFFFFF;
    }

    /// The outlives relation function `callee` declares between lifetime tokens: `(sup, sub)` pairs in
    /// `rel_pool`, as the range `start << 16 | count`. It holds the bounds of the function's and its
    /// extend's lifetime parameters, its `where` predicates, and the bounds its parameter types and
    /// its extend's target imply through the declarations they name (`S<'x>` of `struct S<'a:
    /// 'static>` gives `'x: 'static`). Memoized: call sites re-read the same signatures.
    pub fn callee_rel(self: &mut Self, callee: DefId) u64 {
        if callee.node == NODE_NONE {
            return 0;
        }
        let key = skey_mix(skey_mix(0, callee.module as u64 << 32 | callee.node as u64), 1);
        switch self.rel_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let mut pool = replace(&mut self.rel_pool, Vector::<u64>::new());
        let start = pool.len();
        self.rel_fn(callee, &mut pool);
        self.rel_pool = pool;
        return self.rel_keep(key, start);
    }

    /// The outlives relation among the lifetime parameters of struct or enum `d`, as `callee_rel`
    /// gives it.
    pub fn decl_rel(self: &mut Self, d: DefId) u64 {
        let key = skey_mix(skey_mix(0, d.module as u64 << 32 | d.node as u64), 2);
        switch self.rel_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let mut pool = replace(&mut self.rel_pool, Vector::<u64>::new());
        let start = pool.len();
        self.rel_lts(d.module, self.ast_of(d.module).lifetimes_of(d.node), &mut pool);
        self.rel_pool = pool;
        return self.rel_keep(key, start);
    }

    // Record the pairs the relation appended to `rel_pool` from `start` as `key`'s relation.
    fn rel_keep(self: &mut Self, key: u64, start: usize) u64 {
        let r = start as u64 << 16 | ((self.rel_pool.len() - start) / 2) as u64;
        self.rel_memo.insert(key, r);
        return r;
    }

    fn rel_fn(self: &Self, callee: DefId, out: &mut Vector<u64>) {
        let m = callee.module;
        let a = self.ast_of(m);
        let nd = *a.at_const(callee.node);
        if nd.kind != NodeKind::NODE_FUNCTION {
            return;
        }
        self.rel_lts(m, a.lifetimes_of(callee.node), out);
        let wc = nd.as_data.function.where_clause;
        for w in 0..wc.len {
            let wp = a.at_const(unsafe a.list(wc)[w as usize]).as_data.where_predicate;
            if a.at_const(wp.ty).kind != NodeKind::NODE_LIFETIME {
                continue;
            }
            for b in 0..wp.bounds.len {
                let bid = unsafe a.list(wp.bounds)[b as usize];
                if a.at_const(bid).kind == NodeKind::NODE_LIFETIME {
                    rel_push(out, self.lt_tok(m, wp.ty), self.lt_tok(m, bid));
                }
            }
        }
        let c = a.container_of(callee.node);
        if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND {
            self.rel_lts(m, a.lifetimes_of(c), out);
            self.rel_implied(m, a.at_const(c).as_data.extend_def.target_type, out, 0);
        }
        let ps = nd.as_data.function.params;
        for i in 0..ps.len {
            self.rel_implied(m, a.at_const(unsafe a.list(ps)[i as usize]).as_data.parameter.ty, out, 0);
        }
    }

    // The bounds of lifetime parameters `lts` of module `m`.
    fn rel_lts(self: &Self, m: ModuleId, lts: NodeList, out: &mut Vector<u64>) {
        let a = self.ast_of(m);
        for i in 0..lts.len {
            let lp = unsafe a.list(lts)[i as usize];
            let bs = a.at_const(lp).as_data.generic_param.bounds;
            for b in 0..bs.len {
                rel_push(out, self.lt_tok(m, lp), self.lt_tok(m, unsafe a.list(bs)[b as usize]));
            }
        }
    }

    // The bounds type node `tyn` of module `m` implies: each path to a struct or enum with bounded
    // lifetime parameters relates the path's lifetime arguments as the declaration relates its
    // parameters.
    fn rel_implied(self: &Self, m: ModuleId, tyn: NodeId, out: &mut Vector<u64>, depth: i32) {
        if tyn == NODE_NONE || depth > 6 {
            return;
        }
        let a = self.ast_of(m);
        let n = *a.at_const(tyn);
        if n.has_lt_slot() {
            self.rel_implied(m, n.as_data.indirect_type.ty, out, depth + 1);
            return;
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            self.rel_implied(m, n.as_data.array_type.element, out, depth + 1);
            return;
        }
        let mut es = NodeList { start: 0, len: 0 };
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            es = n.as_data.array_literal.elements;
        } else if n.kind == NodeKind::NODE_TYPE_PATH {
            es = n.as_data.type_path.args;
        }
        for i in 0..es.len {
            let e = unsafe a.list(es)[i as usize];
            if a.at_const(e).kind != NodeKind::NODE_LIFETIME {
                self.rel_implied(m, e, out, depth + 1);
            }
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return;
        }
        let d = a.path_def(tyn);
        if d.node == NODE_NONE {
            return;
        }
        let da = self.ast_of(d.module);
        let dk = da.at_const(d.node).kind;
        let lts = da.lifetimes_of(d.node);
        if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM || lts.len == 0 {
            return;
        }
        // The path's lifetime arguments by parameter position (0: elided).
        let mut toks = Vector::<u64>::new();
        toks.resize_default(lts.len as usize);
        let mut k: usize = 0;
        for i in 0..es.len {
            let e = unsafe a.list(es)[i as usize];
            if a.at_const(e).kind == NodeKind::NODE_LIFETIME && k < toks.len() {
                toks.set(k, self.lt_tok(m, e));
                k += 1;
            }
        }
        let st = static_tok();
        for i in 0..lts.len {
            let bs = da.at_const(unsafe da.list(lts)[i as usize]).as_data.generic_param.bounds;
            for b in 0..bs.len {
                let bt = self.lt_tok(d.module, unsafe da.list(bs)[b as usize]);
                if bt == st {
                    rel_push(out, toks[i as usize], st);
                    continue;
                }
                for j in 0..lts.len {
                    if self.lt_tok(d.module, unsafe da.list(lts)[j as usize]) == bt {
                        rel_push(out, toks[i as usize], toks[j as usize]);
                    }
                }
            }
        }
    }

    /// Add to `toks` every token relation `rel` relates to one of them, transitively: each token that
    /// outlives one when `up`, else each token one outlives.
    /// Relation `rel` with the (sup, sub) token pairs `extra` added, those of `tc::lt_class_tok`
    /// aside.
    pub fn rel_extend(self: &mut Self, rel: u64, extra: &Vector<u64>) u64 {
        let st = (rel >> 16) as usize;
        let n = (rel & 0xFFFF) as usize;
        let start = self.rel_pool.len();
        for i in 0..2 * n {
            let v = self.rel_pool[st + i];
            self.rel_pool.push(v);
        }
        for i in 0..extra.len() / 2 {
            if extra[2 * i] >> 62 != 1 {
                self.rel_pool.push(extra[2 * i]);
                self.rel_pool.push(extra[2 * i + 1]);
            }
        }
        return start as u64 << 16 | ((self.rel_pool.len() - start) / 2) as u64;
    }

    pub fn rel_widen(self: &Self, rel: u64, up: bool, toks: &mut Vector<u64>) {
        let st = (rel >> 16) as usize;
        let n = (rel & 0xFFFF) as usize;
        if n == 0 || toks.len() == 0 {
            return;
        }
        // A pass that changes nothing ends the walk; each other pass adds one of at most 2n tokens.
        for _pass in 0..2 * n + 1 {
            let mut grew = false;
            for i in 0..n {
                let sup = self.rel_pool[st + 2 * i];
                let sub = self.rel_pool[st + 2 * i + 1];
                let from = pick(up, sub, sup);
                let to = pick(up, sup, sub);
                if toks.contains(&from) && !toks.contains(&to) {
                    toks.push(to);
                    grew = true;
                }
            }
            if !grew {
                return;
            }
        }
    }

    /// The tokens relation `rel` makes `'static` into `out`: `'static` and each token declared or
    /// implied to outlive it.
    pub fn rel_static(self: &Self, rel: u64, out: &mut Vector<u64>) {
        out.truncate(0);
        out.push(static_tok());
        self.rel_widen(rel, true, out);
    }

    /// Does relation `rel` declare a lifetime to outlive another lifetime than `'static`?
    pub const fn rel_sup_any(self: &Self, rel: u64) bool {
        let st = (rel >> 16) as usize;
        let stt = static_tok();
        for i in 0..(rel & 0xFFFF) as usize {
            if self.rel_pool[st + 2 * i + 1] != stt {
                return true;
            }
        }
        return false;
    }

    /// Does relation `rel` declare a lifetime of `toks` to outlive another lifetime than `'static`?
    pub const fn rel_sup_in(self: &Self, rel: u64, toks: &Vector<u64>) bool {
        let st = (rel >> 16) as usize;
        let stt = static_tok();
        for i in 0..(rel & 0xFFFF) as usize {
            if self.rel_pool[st + 2 * i + 1] != stt && toks.contains(&self.rel_pool[st + 2 * i]) {
                return true;
            }
        }
        return false;
    }

    // Scan every module's items once for `extend T as Free`.
    fn build_ext(self: &mut Self) {
        if self.ext_built {
            return;
        }
        self.ext_built = true;
        let mut keys = Vector::<u64>::new();
        let mut vals = Vector::<u64>::new();
        for m in 0..self.p().modules.len() {
            if !self.p().modules.at(m).has_ast {
                continue;
            }
            let a = self.ast_of(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND {
                    continue;
                }
                if it.as_data.extend_def.interface_type == NODE_NONE || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tr = a.resolution_def(it.as_data.extend_def.interface_type);
                if tr.node == NODE_NONE {
                    continue;
                }
                let trn = self.ast_of(tr.module).at_const(tr.node);
                if trn.kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                if !self.span_text_is(
                    tr.module,
                    self.ast_of(tr.module).at_const(trn.as_data.interface_def.name).as_data.name.text,
                    "Free",
                ) {
                    continue;
                }
                let tg = a.resolution_def(it.as_data.extend_def.target_type);
                if tg.node == NODE_NONE {
                    continue;
                }
                keys.push(skey_mix(0, tg.module as u64 << 32 | tg.node as u64));
                vals.push((m as u64 << 32 | iid as u64) + 1u64);
            }
        }
        for i in 0..keys.len() {
            let key = keys[i];
            switch self.free_ext.get(&key) {
                Some(_v) => {},
                None => {
                    self.free_ext.insert(key, vals[i]);
                },
            };
        }
    }

    fn free_extend_of(self: &mut Self, tmod: ModuleId, tdecl: NodeId) DefId {
        self.build_ext();
        let key = skey_mix(0, tmod as u64 << 32 | tdecl as u64);
        return switch self.free_ext.get(&key) {
            Some(v) => {
                let e = *v - 1u64;
                DefId { module: (e >> 32) as ModuleId, node: (e & 0xFFFFFFFFu64) as NodeId };
            },
            None => DefId { module: 0, node: NODE_NONE },
        };
    }

    fn param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.ast_of(m);
        let bs = a.at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bid = unsafe a.list(bs)[i as usize];
            if a.at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                if a.at_const(bid).as_data.function_type.is_move {
                    return true;
                }
                continue;
            }
            let bd = a.resolution_def(bid);
            if bd.node == NODE_NONE {
                continue;
            }
            let bn = self.ast_of(bd.module).at_const(bd.node);
            if bn.kind == NodeKind::NODE_INTERFACE && self.span_text_is(
                bd.module,
                self.ast_of(bd.module).at_const(bn.as_data.interface_def.name).as_data.name.text,
                "Free",
            ) {
                return true;
            }
        }
        return false;
    }

    // Is interface `d` the `Copy` marker, or does its superinterface closure reach it? The closure is
    // built breadth-first over at most `COPY_CLOSURE_MAX` distinct interfaces (a larger hierarchy answers
    // false, the conservative verdict: the parameter owns), as the typechecker's `dyn_super_closure` does
    // for `tc_iface_requires_copy`, so both agree.
    fn iface_requires_copy(self: &Self, d: DefId) bool {
        let mut seen = Array::<DefId, COPY_CLOSURE_MAX> {};
        let mut n: usize = 0;
        if d.node == NODE_NONE {
            return false;
        }
        seen[0] = d;
        n = 1;
        let mut scan: usize = 0;
        while scan < n {
            let cur = seen[scan];
            scan = scan + 1;
            let a = self.ast_of(cur.module);
            let cn = a.at_const(cur.node);
            if cn.kind != NodeKind::NODE_INTERFACE {
                continue;
            }
            let bs = cn.as_data.interface_def.bounds;
            for b in 0..bs.len {
                let bd = a.resolution_def(unsafe a.list(bs)[b as usize]);
                if bd.node == NODE_NONE || self.ast_of(bd.module).at_const(bd.node).kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                let mut dup = false;
                for k in 0..n {
                    if seen[k].module == bd.module && seen[k].node == bd.node {
                        dup = true;
                    }
                }
                if !dup {
                    if n == COPY_CLOSURE_MAX {
                        return false;
                    }
                    seen[n] = bd;
                    n = n + 1;
                }
            }
        }
        for i in 0..n {
            let a = self.ast_of(seen[i].module);
            let cn = a.at_const(seen[i].node);
            if cn.kind == NodeKind::NODE_INTERFACE && self.span_text_is(
                seen[i].module,
                a.at_const(cn.as_data.interface_def.name).as_data.name.text,
                "Copy",
            ) {
                return true;
            }
        }
        return false;
    }

    // Is one of `bs` a `fn` bound (`*is_fn` set, the result is its `move` mark) or a bound that reaches
    // `Copy` (the result is false)? True when neither: the bounds leave the parameter owning.
    fn bounds_own(self: &Self, m: ModuleId, bs: NodeList, is_fn: &mut bool) bool {
        let a = self.ast_of(m);
        for i in 0..bs.len {
            let bid = unsafe a.list(bs)[i as usize];
            if a.at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                *is_fn = true;
                return a.at_const(bid).as_data.function_type.is_move;
            }
            if self.iface_requires_copy(a.resolution_def(bid)) {
                return false;
            }
        }
        return true;
    }

    // Does a value of the type parameter `gp` own in the body of `self.at`? Rust's default: yes, unless
    // its bounds (inline, or in a `where` clause that applies there: `Ast::where_scope`) reach `Copy`. A `fn` bound keeps its own rule: `fn move` owns, a
    // plain `fn` copies. `Self` inside an interface's default body is copyable only when the interface
    // requires `Copy`.
    fn param_owns(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.ast_of(m);
        let k = a.at_const(gp).kind;
        if k == NodeKind::NODE_INTERFACE {
            return !self.iface_requires_copy(DefId { module: m, node: gp });
        }
        if k != NodeKind::NODE_GENERIC_PARAM {
            return true;
        }
        let mut is_fn = false;
        let r = self.bounds_own(m, a.at_const(gp).as_data.generic_param.bounds, &mut is_fn);
        if is_fn || !r {
            return r;
        }
        let at = if self.at.module == m {
            self.at.node;
        } else {
            NODE_NONE;
        };
        for w in 0..a.where_bounds.len() {
            let sc = a.where_scope(w, gp, at);
            if sc == WHERE_OWN || sc == WHERE_IN {
                let pred = a.at_const(a.where_bounds.at(w).pred).as_data.where_predicate;
                let rw = self.bounds_own(m, pred.bounds, &mut is_fn);
                if is_fn || !rw {
                    return rw;
                }
            }
        }
        return true;
    }

    /// Does a value of `(mid, ty)` own memory (Free semantics: value uses are moves) in the body of
    /// `at`? The body decides which `where` bounds apply to a type parameter.
    /// The captures of closure `node` (module `m`) its destruction may read (`cap_keep`); all when
    /// its body was not analyzed.
    pub fn cap_keep_of(self: &Self, m: ModuleId, node: NodeId) u64 {
        return switch self.cap_keep.get(&(m as u64 << 32 | node as u64)) {
            Some(v) => *v,
            None => 0xFFFFFFFFFFFFFFFFu64,
        };
    }

    pub fn owns(self: &mut Self, at: DefId, mid: ModuleId, ty: TypeId) bool {
        self.low = BUSY_NONE;
        self.at = at;
        return self.owns_f(mid, ty, 0, 0, 0);
    }

    // `[f0, f1)` is the substitution frame in `subst` that the generic parameters of `ty` read.
    fn owns_f(self: &mut Self, mid: ModuleId, ty: TypeId, f0: u32, f1: u32, depth: u32) bool {
        if ty == TYPE_NONE {
            return false;
        }
        if depth > WALK_DEPTH_MAX {
            // Only an unbounded chain of ever-growing substitutions gets here, and each step adds
            // nothing that owns: the least fixpoint is false. Never cached.
            self.low = BUSY_CUT;
            return false;
        }
        let y = *self.ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in f0..f1 {
                let e = self.subst[i as usize];
                if e.pmod == y.module && e.pdecl == y.as_data.decl {
                    return self.owns_f(e.amod, e.aty, e.f0, e.f1, depth + 1);
                }
            }
            return self.param_owns(y.module, y.as_data.decl);
        }
        if y.kind == TypeKind::TYPE_ASSOC {
            // `T::Output` is known per instance only: it owns, as an unbounded parameter does.
            return true;
        }
        if !self.ast_of(mid).type_concrete(ty) {
            return self.owns_raw(mid, &y, f0, f1, depth);
        }
        // A concrete type reads no frame, so its verdict is a pure function of (mid, ty).
        let c = cache_get(&mut self.owns_arr, mid, ty);
        if c >= 0 {
            return c != 0;
        }
        let outer = self.low;
        let at = self.busy_enter(mid, ty);
        if at == BUSY_HIT {
            return false;
        }
        let r = self.owns_raw(mid, &y, 0, 0, depth);
        if self.busy_leave(at, outer) {
            cache_set(&mut self.owns_arr, mid, ty, r);
        }
        return r;
    }

    fn owns_raw(self: &mut Self, mid: ModuleId, y: &Ty, f0: u32, f1: u32, depth: u32) bool {
        if y.kind == TypeKind::TYPE_ARRAY {
            let e = y.as_data.arr.elem;
            return self.owns_f(mid, e, f0, f1, depth + 1);
        }
        if y.kind == TypeKind::TYPE_DYN {
            return y.dyn_owns();
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let base = self.tys.len();
            let cf = self.ast_of(y.module).closure_fact(y.as_data.decl);
            if cf == null {
                return false;
            }
            let by_ptr = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
            for i in 0..unsafe (&*cf).ncaps {
                if (by_ptr >> i as u64 & 1u64) == 0 {
                    self.tys.push(unsafe self.ast_of(y.module).caps_of(cf)[i as usize].ty);
                }
            }
            let mut r = false;
            for i in base..self.tys.len() {
                if self.owns_f(y.module, self.tys[i], 0, 0, depth + 1) {
                    r = true;
                    break;
                }
            }
            self.tys.truncate(base);
            return r;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            if self.free_extend_of(y.module, y.as_data.decl).node != NODE_NONE {
                return true;
            }
            return self.derives(mid, y, f0, f1, depth);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        if !self.ast_of(mid).instance_valid(y.as_data.inst) {
            return false;
        }
        let it = *self.ast_of(mid).instance(y.as_data.inst);
        let ext = self.free_extend_of(it.module, it.decl);
        if ext.node == NODE_NONE {
            return self.derives(mid, y, f0, f1, depth);
        }
        let gens = self.ast_of(ext.module).at_const(ext.node).as_data.extend_def.generics;
        let mut i: u32 = 0;
        while i < gens.len && i as u8 < it.n {
            let gid = unsafe self.ast_of(ext.module).list(gens)[i as usize];
            if self.param_has_free_bound(ext.module, gid) && !self.owns_f(
                mid,
                unsafe it.args[i as usize],
                f0,
                f1,
                depth + 1,
            ) {
                // The extend does not cover this instance: it derives ownership from its members.
                return self.derives(mid, y, f0, f1, depth);
            }
            i = i + 1;
        }
        return true;
    }

    // Member-derived ownership: a non-union aggregate with no explicit conformance owns memory when
    // any member does. Instances judge members under their argument substitution, whose arguments
    // read the caller's frame.
    fn derives(self: &mut Self, mid: ModuleId, y: &Ty, f0: u32, f1: u32, depth: u32) bool {
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut s0 = f0;
        let mut s1 = f1;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
            s0 = self.subst.len() as u32;
            let gens = self.ast_of(om).at_const(od).as_data.aggregate.generics;
            let mut k: u8 = 0;
            for g in 0..gens.len {
                let gid = unsafe self.ast_of(om).list(gens)[g as usize];
                if self.ast_of(om).at_const(gid).as_data.generic_param.is_lifetime {
                    continue;
                }
                if k < it.n {
                    self.subst.push(
                        OwnSubst { pmod: om, pdecl: gid, amod: mid, aty: unsafe it.args[k as usize], f0: f0, f1: f1 },
                    );
                }
                k = k + 1;
            }
            s1 = self.subst.len() as u32;
        } else {
            om = y.module;
            od = y.as_data.decl;
        }
        let r = self.derives_members(om, od, s0, s1, depth);
        if y.kind == TypeKind::TYPE_INSTANCE {
            self.subst.truncate(s0 as usize);
        }
        return r;
    }

    fn derives_members(self: &mut Self, om: ModuleId, od: NodeId, s0: u32, s1: u32, depth: u32) bool {
        let dn = *self.ast_of(om).at_const(od);
        let is_enum = dn.kind == NodeKind::NODE_ENUM;
        if dn.kind != NodeKind::NODE_STRUCT && !is_enum {
            return false;
        }
        if !is_enum && dn.as_data.aggregate.is_union {
            return false;
        }
        let base = self.tys.len();
        self.push_member_types(om, &dn);
        let mut r = false;
        for i in base..self.tys.len() {
            if self.owns_f(om, self.tys[i], s0, s1, depth + 1) {
                r = true;
            }
        }
        self.tys.truncate(base);
        return r;
    }

    // Push the member types of aggregate `dn` (fields, tuple members, variant payloads) onto `tys`.
    fn push_member_types(self: &mut Self, om: ModuleId, dn: &Node) {
        let is_enum = dn.kind == NodeKind::NODE_ENUM;
        let ms = dn.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid2 = unsafe self.ast_of(om).list(ms)[i as usize];
            let mn = *self.ast_of(om).at_const(mid2);
            // Tuple members are bare type nodes; named members are NODE_FIELD.
            if !is_enum && (mn.kind == NodeKind::NODE_FIELD || dn.as_data.aggregate.is_tuple) {
                let tn = self.ast_of(om).member_type_node(mid2, true);
                self.tys.push(self.ast_of(om).type_of(tn));
            } else if is_enum && mn.kind == NodeKind::NODE_VARIANT {
                for k in 0..mn.as_data.variant.payload.len {
                    let pid = unsafe self.ast_of(om).list(mn.as_data.variant.payload)[k as usize];
                    let tn = self.ast_of(om).member_type_node(pid, true);
                    self.tys.push(self.ast_of(om).type_of(tn));
                }
            }
        }
    }

    // Cycle handling for the owns and carries walks. `busy` holds the (mid, ty) keys on the walk's
    // stack. A walk that meets a busy key assumes false: both verdicts are unions over members, so
    // a cycle adds nothing and false is the least fixpoint. The assumption is exact for the type
    // that opened the cycle, but a type inside the cycle computed under it may be wrong, so a
    // verdict is final only when it assumed nothing about a type entered before it. `low` is the
    // lowest stack index assumed so far: BUSY_NONE when none, BUSY_CUT after a depth cut.
    // Enter `(mid, ty)`: its stack index, or BUSY_HIT when it is already on the stack.
    fn busy_enter(self: &mut Self, mid: ModuleId, ty: TypeId) i64 {
        let key = mid as u64 << 32 | ty as u64;
        for b in 0..self.busy.len() {
            if self.busy[b] == key {
                if b as i64 < self.low {
                    self.low = b as i64;
                }
                return BUSY_HIT;
            }
        }
        self.busy.push(key);
        self.low = BUSY_NONE;
        return self.busy.len() as i64 - 1;
    }

    // Close the entry at stack index `at` (`outer` is `low` from before the entry): true when its
    // verdict is final, so the caller may cache it.
    const fn busy_leave(self: &mut Self, at: i64, outer: i64) bool {
        let _ = self.busy.pop();
        let exact = self.low >= at;
        if exact || outer < self.low {
            self.low = outer;
        }
        return exact;
    }

    /// The field declarations and member types of a struct (or struct instance) value; false for
    /// every other shape. Types are the OWNER module's recorded member types (`om`).
    pub fn agg_fields(
        self: &mut Self,
        mid: ModuleId,
        ty: TypeId,
        decls: &mut Vector<NodeId>,
        tys: &mut Vector<TypeId>,
        om_out: &mut ModuleId,
    ) bool {
        decls.clear();
        tys.clear();
        let y = *self.ast_of(mid).type_at(ty);
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            om = y.module;
            od = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
        } else {
            return false;
        }
        let dn = *self.ast_of(om).at_const(od);
        if dn.kind != NodeKind::NODE_STRUCT || dn.as_data.aggregate.is_union {
            return false;
        }
        {
            let oa = self.ast_of(om);
            let is_tuple = dn.as_data.aggregate.is_tuple;
            let ms = dn.as_data.aggregate.members;
            for i in 0..ms.len {
                let mid2 = unsafe oa.list(ms)[i as usize];
                let mn = *oa.at_const(mid2);
                // Tuple members are bare type nodes named `_i`; named members are NODE_FIELD.
                if is_tuple {
                    decls.push(mid2);
                    tys.push(oa.type_of(mid2));
                } else if mn.kind == NodeKind::NODE_FIELD {
                    decls.push(mid2);
                    tys.push(oa.type_of(mn.as_data.field.ty));
                }
            }
        }
        *om_out = om;
        return true;
    }

    /// Can a value of `(mid, ty)` hold a tracked borrow? References and borrowed dyn values do;
    /// aggregates and closures do when a member/capture does. Raw pointers, `str`, and slice views
    /// (pointer-field structs) do not: their fields are handles, not tracked borrows.
    /// Does destroying a value of `(mid, ty)` observe the borrows it carries? Only an explicit
    /// `Free` can read through them: derived destruction frees owned members and never reads a
    /// reference. So a carrying type observes when it has an explicit conformance or a member does
    /// (for an instance: a type argument or a concrete member). Other kinds answer yes.
    pub fn observes(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        return self.observes_f(mid, ty, 0);
    }

    fn observes_f(self: &mut Self, mid: ModuleId, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE {
            return false;
        }
        if depth > WALK_DEPTH_MAX {
            return true;
        }
        let front = self.ast_of(mid).type_concrete(ty);
        if front {
            let c = cache_get(&mut self.obs_arr, mid, ty);
            if c >= 0 {
                return c != 0;
            }
        }
        let r = self.observes_go(mid, ty, depth);
        if front {
            cache_set(&mut self.obs_arr, mid, ty, r);
        }
        return r;
    }

    fn observes_go(self: &mut Self, mid: ModuleId, ty: TypeId, depth: u32) bool {
        if !self.carries(mid, ty) {
            return false;
        }
        let y = *self.ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return false;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.observes_f(mid, y.as_data.arr.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig() && self.ast_of(y.module).at_const(y.as_data.decl).kind == NodeKind::NODE_CLOSURE {
            // A closure has no destructor of its own: it destroys the captures it holds by value and
            // never reads one it holds by reference.
            let cf = self.ast_of(y.module).closure_fact(y.as_data.decl);
            let by_ptr = if cf != null {
                unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
            } else {
                0u64;
            };
            let caps = self.ast_of(y.module).at_const(y.as_data.decl).as_data.closure.captures;
            for k in 0..caps.len {
                if k < 64 && (by_ptr >> k as u64 & 1u64) != 0 {
                    continue;
                }
                let ct = self.ast_of(y.module).type_of(unsafe self.ast_of(y.module).list(caps)[k as usize]);
                if self.observes_f(y.module, ct, depth + 1) {
                    return true;
                }
            }
            return false;
        }
        let mut om = y.module;
        let mut od = y.as_data.decl;
        if y.kind == TypeKind::TYPE_INSTANCE {
            if !self.ast_of(mid).instance_valid(y.as_data.inst) {
                return true;
            }
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
            for k in 0..it.n {
                if self.observes_f(mid, unsafe it.args[k as usize], depth + 1) {
                    return true;
                }
            }
        } else if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM {
            return true;
        }
        if self.free_extend_of(om, od).node != NODE_NONE {
            return true;
        }
        let dn = *self.ast_of(om).at_const(od);
        if dn.kind != NodeKind::NODE_STRUCT && dn.kind != NodeKind::NODE_ENUM || dn.kind == NodeKind::NODE_STRUCT && dn.as_data.aggregate.is_union {
            return true;
        }
        let base = self.tys.len();
        self.push_member_types(om, &dn);
        let mut r = false;
        for i in base..self.tys.len() {
            let t = self.tys[i];
            if self.ast_of(om).type_concrete(t) && self.observes_f(om, t, depth + 1) {
                r = true;
                break;
            }
        }
        self.tys.truncate(base);
        return r;
    }

    /// Set `forest.covered` for every path of body module `mid` whose struct or tuple type has a
    /// tracked child for each member. Enums, unions and every other kind stay unset.
    pub fn mark_covered(self: &Self, mid: ModuleId, forest: &mut mp::MoveForest) {
        for p in 0..forest.paths.len() {
            let ty = forest.paths.at(p).ty;
            if forest.is_leaf(p as u32) || ty == TYPE_NONE {
                continue;
            }
            let y = *self.ast_of(mid).type_at(ty);
            let mut om = y.module;
            let mut od = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                if !self.ast_of(mid).instance_valid(y.as_data.inst) {
                    continue;
                }
                let it = *self.ast_of(mid).instance(y.as_data.inst);
                om = it.module;
                od = it.decl;
            } else if y.kind != TypeKind::TYPE_STRUCT {
                continue;
            }
            let dn = *self.ast_of(om).at_const(od);
            if dn.kind != NodeKind::NODE_STRUCT || dn.as_data.aggregate.is_union {
                continue;
            }
            let ms = dn.as_data.aggregate.members;
            let mut all = true;
            for i in 0..ms.len {
                let m = unsafe self.ast_of(om).list(ms)[i as usize];
                let c = if dn.as_data.aggregate.is_tuple {
                    forest.tuple_child(p as u32, i);
                } else if self.ast_of(om).at_const(m).kind == NodeKind::NODE_FIELD {
                    forest.field_child(p as u32, m);
                } else {
                    0u32; // not a field: nothing to track
                };
                if c == mp::MP_NONE {
                    all = false;
                    break;
                }
            }
            if all {
                bits::bit_set(&mut forest.covered, p as u32);
            }
        }
    }

    /// The generic parameters of aggregate `(m, decl)` that reach an `UnsafeCell` through its fields
    /// (directly, behind pointers or references, or as an argument another aggregate keeps interior):
    /// a shared reference to such a value can store values of those parameters. Bit i: parameter i.
    pub fn interior_mask(self: &mut Self, m: ModuleId, decl: NodeId, depth: u32) u64 {
        if decl == NODE_NONE || depth > 6 {
            return 0;
        }
        if m == self.unsafe_cell.module && decl == self.unsafe_cell.node {
            return 1;
        }
        let key = m as u64 << 32 | decl as u64;
        switch self.interior_memo.get(&key) {
            Some(v) => {
                return *v & ~INTERIOR_BUSY;
            },
            None => {},
        };
        let dn = *self.ast_of(m).at_const(decl);
        if dn.kind != NodeKind::NODE_STRUCT {
            return 0;
        }
        self.interior_memo.insert(key, INTERIOR_BUSY);
        let mut mask: u64 = 0;
        let ms = dn.as_data.aggregate.members;
        for j in 0..ms.len {
            let fd = *self.ast_of(m).at_const(unsafe self.ast_of(m).list(ms)[j as usize]);
            if fd.kind == NodeKind::NODE_FIELD {
                mask = mask | self.interior_in(m, decl, fd.as_data.field.ty, depth);
            }
        }
        self.interior_memo.insert(key, mask);
        return mask;
    }

    // The parameters of `decl` (module `m`) that type node `tyn` places in an interior position.
    fn interior_in(self: &mut Self, m: ModuleId, decl: NodeId, tyn: NodeId, depth: u32) u64 {
        if tyn == NODE_NONE || depth > 6 {
            return 0;
        }
        let n = *self.ast_of(m).at_const(tyn);
        if n.kind == NodeKind::NODE_POINTER_TYPE || n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            return self.interior_in(m, decl, n.as_data.indirect_type.ty, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.interior_in(m, decl, n.as_data.array_type.element, depth + 1);
        }
        let mut r: u64 = 0;
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                r = r | self.interior_in(m, decl, unsafe self.ast_of(m).list(es)[i as usize], depth + 1);
            }
            return r;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return 0;
        }
        let d2 = self.ast_of(m).path_def(tyn);
        let m2 = if d2.node != NODE_NONE {
            self.interior_mask(d2.module, d2.node, depth + 1);
        } else {
            0u64;
        };
        let args = n.as_data.type_path.args;
        let mut k: u64 = 0;
        for i in 0..args.len {
            let aid = unsafe self.ast_of(m).list(args)[i as usize];
            if self.ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                continue;
            }
            r = r | self.interior_in(m, decl, aid, depth + 1);
            if k < 64 && (m2 >> k & 1u64) != 0 {
                r = r | self.params_named(m, decl, aid, depth + 1);
            }
            k += 1;
        }
        return r;
    }

    // The generic parameters of `decl` (module `m`) type node `tyn` names anywhere.
    fn params_named(self: &Self, m: ModuleId, decl: NodeId, tyn: NodeId, depth: u32) u64 {
        if tyn == NODE_NONE || depth > 8 {
            return 0;
        }
        let a = self.ast_of(m);
        let n = a.at_const(tyn);
        if n.kind == NodeKind::NODE_POINTER_TYPE || n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            return self.params_named(m, decl, n.as_data.indirect_type.ty, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.params_named(m, decl, n.as_data.array_type.element, depth + 1);
        }
        let mut es = NodeList { start: 0, len: 0 };
        let mut r: u64 = 0;
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            es = n.as_data.array_literal.elements;
        } else if n.kind == NodeKind::NODE_TYPE_PATH {
            es = n.as_data.type_path.args;
            let d = a.path_def(tyn);
            if d.module == m && d.node != NODE_NONE {
                let gs = a.at_const(decl).as_data.aggregate.generics;
                for i in 0..gs.len.min(64) {
                    if unsafe a.list(gs)[i as usize] == d.node {
                        r = r | 1u64 << i as u64;
                    }
                }
            }
        }
        for i in 0..es.len {
            r = r | self.params_named(m, decl, unsafe a.list(es)[i as usize], depth + 1);
        }
        return r;
    }

    pub fn carries(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        self.low = BUSY_NONE;
        return self.carries_f(mid, ty, 0);
    }

    fn carries_f(self: &mut Self, mid: ModuleId, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE {
            return false;
        }
        if depth > WALK_DEPTH_MAX {
            // Unreachable for real types (every step enters a distinct busy key); may-hold is the
            // sound answer. Never cached.
            self.low = BUSY_CUT;
            return true;
        }
        // Front cache: mut_caps bits are final before any Owner query runs (bc_ir_lower sets
        // them), so closure-typed results are stable, unlike the walk-side memo.
        let front = self.ast_of(mid).type_concrete(ty);
        if front {
            let c = cache_get(&mut self.carry_arr, mid, ty);
            if c >= 0 {
                return c != 0;
            }
        }
        let outer = self.low;
        let at = self.busy_enter(mid, ty);
        if at == BUSY_HIT {
            return false;
        }
        let r = self.carries_go(mid, ty, depth);
        if self.busy_leave(at, outer) && front {
            cache_set(&mut self.carry_arr, mid, ty, r);
        }
        return r;
    }

    fn carries_go(self: &mut Self, mid: ModuleId, ty: TypeId, depth: u32) bool {
        let y = *self.ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let e = y.as_data.arr.elem;
            return self.carries_f(mid, e, depth + 1);
        }
        if y.kind == TypeKind::TYPE_DYN {
            // An erased value can hold captured borrows whatever its ownership.
            return true;
        }
        if y.fn_sig() {
            // A function pointer whose type fixes a lifetime outside it holds that region: a call
            // stores those arguments where the value keeps them (`Gen::sig_call`).
            for k in 0..self.ast_of(mid).sig_lt_len(&y) {
                if self.ast_of(mid).sig_lt_class(&y, k) >= LC_OUTER {
                    return true;
                }
            }
            return false;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let cf = self.ast_of(y.module).closure_fact(y.as_data.decl);
            if cf == null {
                return false;
            }
            if (unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps) != 0 {
                return true;
            }
            // A body naming an enclosing function's lifetime holds that region.
            let cls = &self.ast_of(y.module).closure_lts;
            for k in 0..cls.len() {
                if (cls[k] >> 32) as NodeId == y.as_data.decl {
                    return true;
                }
            }
            let base = self.tys.len();
            for i in 0..unsafe (&*cf).ncaps {
                self.tys.push(unsafe self.ast_of(y.module).caps_of(cf)[i as usize].ty);
            }
            let mut r = false;
            for i in base..self.tys.len() {
                if self.carries_f(y.module, self.tys[i], depth + 1) {
                    r = true;
                    break;
                }
            }
            self.tys.truncate(base);
            return r;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            om = y.module;
            od = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            if !self.ast_of(mid).instance_valid(y.as_data.inst) {
                return false;
            }
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
            for k in 0..it.n {
                if self.carries_f(mid, unsafe it.args[k as usize], depth + 1) {
                    return true;
                }
            }
        } else {
            return false;
        }
        // A view type (a `str`, a slice, any aggregate declaring lifetime params) is a borrow by
        // declaration even when its fields are raw: values of it pin what they were made from.
        if od != NODE_NONE && self.ast_of(om).lifetimes_of(od).len != 0 {
            return true;
        }
        let dn = *self.ast_of(om).at_const(od);
        if dn.kind != NodeKind::NODE_STRUCT && dn.kind != NodeKind::NODE_ENUM {
            return false;
        }
        let base = self.tys.len();
        self.push_member_types(om, &dn);
        let mut r = false;
        for i in base..self.tys.len() {
            if self.carries_f(om, self.tys[i], depth + 1) {
                r = true;
                break;
            }
        }
        self.tys.truncate(base);
        return r;
    }

    /// The facts of body `b` over move forest `mf`, freshly allocated.
    pub fn generate(self: &mut Self, b: &ir::CoreBody, mf: &mp::MoveForest) BodyFacts {
        let mut f = BodyFacts::empty();
        self.generate_into(b, mf, &mut f, true);
        return f;
    }

    /// Fill `dst` in place, reusing its vector capacity across bodies (the reusable-context path). The
    /// generator owns a BodyFacts by value, so `dst`'s reset storage is moved in, filled, and moved back.
    /// With `loans` false only the move/init facts are produced (events, their block ranges and the
    /// easy-block masks): origins, loans, accesses, subsets, kills and the liveness rows stay empty.
    /// That is all drop elaboration reads, and all a body the loan-skip predicate cleared needs.
    pub fn generate_into(self: &mut Self, b: &ir::CoreBody, mf: &mp::MoveForest, dst: &mut BodyFacts, loans: bool) {
        dst.reset();
        let mut sites = replace(&mut self.sc_assign_sites, Vector::<KillSite>::new());
        sites.truncate(0);
        let mut seen = replace(&mut self.sc_seen, Vector::<u64>::new());
        seen.truncate(0);
        let mut stores = replace(&mut self.sc_stores, Vector::<StoreVia>::new());
        stores.truncate(0);
        let mut ties = replace(&mut self.sc_ties, Vector::<u64>::new());
        ties.truncate(0);
        let mut istores = replace(&mut self.sc_istores, Vector::<StoreVia>::new());
        istores.truncate(0);
        let mut g = Gen {
            ow: self,
            b: b,
            mf: mf,
            f: replace(dst, BodyFacts::empty()),
            assign_sites: sites,
            cur_block: 0,
            in_caps: false,
            plain_copy: false,
            no_drop: false,
            copy_out: false,
            calling: false,
            loans: loans,
            seen: seen,
            stores: stores,
            ties: ties,
            istores: istores,
            cap_ph: Vector::<u32>::new(),
            cap_tags: Vector::<CapTag>::new(),
            ext: NODE_NONE,
            ext_mod: 0,
            rel: 0,
            pre_v: Vector::<u64>::new(),
        };
        g.number_points();
        g.build_origins();
        g.walk();
        g.resolve_stores();
        g.resolve_interior();
        g.finish();
        // Hand the filled facts back to `dst` and the scratch back to the owner; the throwaway
        // empties return to `g`, freed when it drops.
        replace(dst, replace(&mut g.f, BodyFacts::empty()));
        self.sc_assign_sites = replace(&mut g.assign_sites, Vector::<KillSite>::new());
        self.sc_seen = replace(&mut g.seen, Vector::<u64>::new());
        self.sc_stores = replace(&mut g.stores, Vector::<StoreVia>::new());
        self.sc_ties = replace(&mut g.ties, Vector::<u64>::new());
        self.sc_istores = replace(&mut g.istores, Vector::<StoreVia>::new());
    }
}
