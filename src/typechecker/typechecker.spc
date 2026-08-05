// Type checking for one module: consumes the resolver's AST (+ the Package for imports) and types it
// in place -- per-node/decl TypeIds, member/method resolutions, call_info, dyn uses, deref chains and
// generic instances -- everything the borrowck pass and codegen read. Borrow/move/lifetime analysis is
// the separate src/borrowck stage (extends TypeChecker, replays bodies after check()); the flow/borrow/
// region fields here are its state. Invariant: TC-* memoizations must not change type-pool interning
// order -- emitted C is byte-compared across bootstrap generations.
import string as cstring;
import stdio;
import lexer::token as tok;
import lexer::token_type as *;
import ast::ast as *;
import module::loader as loader;
import consteval::consteval as ce;
import utils::errors as diag;

pub const TYPE_ALIAS_MAX_DEPTH: u32 = 64;
pub const BOUND_MAX_DEPTH: i32 = 8;
pub const PLACE_MAX_STEPS: i32 = 16;
pub const MATCH_MAX_VARIANTS: u32 = 256;
pub const BORROW_ESCAPE_MAX_DEPTH: u32 = 64;

pub const BORROW_SHARED: u8 = 0;
pub const BORROW_MUT: u8 = 1;
/// The reserved RegionVid for `'static`: outlives every other region.
pub const REGION_STATIC: u32 = 0;
/// "no region" -- a lifetime name that denotes nothing in the current signature.
pub const REGION_NONE: u32 = 0xFFFFFFFF;
pub const PS_FIELD: u8 = 0;
pub const PS_INDEX: u8 = 1;
pub const PS_DEREF: u8 = 2;

// Variance of a type/lifetime parameter in an aggregate, 2 bits, packed LSB-first per parameter
// (lifetime params first, then type params). Used for subtyping: `C<'a> <: C<'b>` requires 'a and 'b
// related per C's variance in that slot. BIVARIANT is the lattice bottom (unconstrained); INVARIANT
// the top. Composition/join in v_transform / v_join.
pub const V_BIVARIANT: u32 = 0;
pub const V_COVARIANT: u32 = 1;
pub const V_CONTRAVARIANT: u32 = 2;
pub const V_INVARIANT: u32 = 3;

// --- fixed-buffer / small-array wrappers (a struct field zero-inits its array) ------------------
pub type Buf96 = Array<char, 96>;
pub type Buf512 = Array<char, 512>;
pub type Defs8 = Array<DefId, 8>;
pub type Tys8 = Array<TypeId, 8>;
pub type BoundArr8 = Array<BoundIface, 8>;
pub type Names14 = Array<*const char, 16>;
pub type Steps16 = Array<PStep, 16>;
pub type Keep256 = Array<bool, 256>;
// Worklist/visited scratch for the outlives closure. The DECLARED outlives graph is signature-sized
// (a handful of lifetimes), so 32 is ample; overflowing answers "cannot prove", which over-rejects.
pub type Regions32 = Array<u32, 32>;
// Field-chain scratch for resolving a store slot's lifetime through nested aggregates.
pub type Nodes8 = Array<NodeId, 8>;
pub type Spans8 = Array<tok::Span, 8>;
pub type Cover4 = Array<u64, 4>;
pub type Buf128 = Array<char, 128>;
pub type NodeArr16 = Array<NodeId, 16>;

/// A live borrow: `root` = the borrowed place's base binding, `place` = the place node, `origin` = the
/// expression that created it, `binding` = the binding holding it (NODE_NONE = transient, released at
/// statement end), `region` = scope depth at creation, `kind` = BORROW_SHARED/BORROW_MUT.
pub struct Borrow {
    pub root: NodeId,
    pub place: NodeId,
    pub origin: NodeId,
    pub binding: NodeId,
    pub region: u16,
    pub kind: u8,
}

/// One access step of a decomposed place (see place_decompose): PS_FIELD (`name`), PS_INDEX
/// (`index_val` valid when `index_const`), or PS_DEREF.
pub struct PStep {
    pub kind: u8,
    pub index_const: bool,
    pub index_val: i64,
    pub name: tok::Span,
}

/// An interface bound plus its lowered type arguments (`n` <= 8).
pub struct BoundIface {
    pub iface: DefId,
    pub n: u8,
    pub args: [TypeId; 8],
}

pub struct LoopEntry {
    pub label: tok::Span,
    pub node: NodeId,
    pub break_ty: TypeId,
    pub value_loop: bool,
    pub saw_value: bool,
    pub saw_bare: bool,
    // Scope depth on entry to this loop. A binding declared DEEPER than this lives inside the loop
    // body and therefore dies at the end of each iteration -- which is what makes source-order
    // last-use reasoning valid for it despite the back edge (see borrow_dead_after).
    pub depth: u32,
}

/// Snapshot of the flow-sensitive state (moves, partial moves, uninit, freed, borrows), saved/merged
/// around branches (TC-4b: filled via out-param; only the counted prefixes are touched).
pub struct FlowState {
    pub moved: [NodeId; 256],
    pub nmoved: u32,
    pub moved_places: [NodeId; 128],
    pub nmoved_places: u32,
    pub uninit: [NodeId; 64],
    pub nuninit: u32,
    pub late: [NodeId; 64],
    pub nlate: u32,
    pub freed: [NodeId; 64],
    pub nfreed: u32,
    pub borrows: [Borrow; 64],
    pub nborrows: u32,
}

/// TC-11: method/assoc-const/default-method query key. `name` is a CONTENT view (span slice of the
/// querying module's source, or the caller's literal), so span- and cstr-form queries for the same
/// name share one entry. Exact-keyed (Hash + full Eq), so collisions cannot alias.
pub struct MQKey<'a> {
    pub m: ModuleId,
    pub decl: NodeId,
    pub kind: u8,
    pub name: str<'a>,
}

extend MQKey as Hash {
    pub fn hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        h = (h ^ self.m as u64) * 1099511628211u64;
        h = (h ^ self.decl as u64) * 1099511628211u64;
        h = (h ^ self.kind as u64) * 1099511628211u64;
        return (h ^ self.name.hash()) * 1099511628211u64;
    }
}

extend MQKey as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        return self.m == other.m && self.decl == other.decl && self.kind == other.kind && self.name == other.name;
    }
}

/// The per-module checker. Also the state substrate for the borrowck pass, which extends TypeChecker
/// and re-walks function bodies after check() (Ast.call_info bridges the two).
pub struct TypeChecker<'a> {
    pub ast: UnsafeCell<Ast>,
    pub source: str<'a>,
    // Private const-evaluator for the parallel borrow-check stage (address of a ce::ConstEval, held
    // as usize so the checker never owns it): the shared Package.ceval single-threads cycle marks and
    // memo writes, which concurrent workers may not share. 0 = use the shared one.
    pub current_returns: NodeList,
    pub current_self: NodeId,
    pub current_extend: NodeId,
    pub current_fn: NodeId,
    pub clos_stack: [NodeId; 8],
    pub nclos: u32,
    pub package: *mut loader::Package,
    pub alias_depth: u32,
    pub ext_scope: Vector<ModuleId>,
    pub n_ext_scope: i32,
    // TC-1: per-module list of EXTEND item ids (item order), built lazily. The find_*/dispatch scans iterate
    // this instead of every top-level item; targets are still peeled on-demand in the same order, so type
    // interning (hence emitted C) is byte-identical.
    pub ext_items: Vector<Vector<NodeId>>,
    pub ext_items_built: Vector<bool>,
    pub expected: TypeId,
    pub moved: [NodeId; 1024],
    pub nmoved: u32,
    // Partial (field/index) moves: the moved sub-place NODES (`p.a`, `arr[0]`). A whole binding uses the
    // `moved` set above; a sub-place is tracked here and tested with places_overlap so using/re-moving
    // the same sub-place, or the whole value while a part is moved, is caught (else a Free field moved
    // twice double-frees). Merged across branches like `moved`.
    pub moved_places: [NodeId; 256],
    pub nmoved_places: u32,
    pub uninit: [NodeId; 256],
    pub nuninit: u32,
    /// Split-initialization tracking: immutable `let x;` bindings assigned on SOME path so far --
    /// a second assignment (or one on a path that may repeat) is "cannot assign twice".
    pub late: [NodeId; 256],
    pub nlate: u32,
    pub freed: [NodeId; 256],
    pub nfreed: u32,
    pub borrows: [Borrow; 256],
    pub nborrows: u32,
    pub scope_depth: u32,
    pub loop_depth: u32,
    pub binding_depth: Map<u32, u32>,
    pub defer_stack: [NodeId; 256],
    pub defer_depth: [u32; 256],
    pub ndefers: u32,
    pub in_loop_recheck: bool,
    pub place_use: bool,
    pub addr_ctx: bool,
    pub mret_call: NodeId,
    pub mret_types: [TypeId; 8],
    pub mret_n: u8,
    pub mret_total: u32,
    pub unsafe_depth: u32,
    // ---- region inference state (per function) ----
    // Next RegionVid to hand out. REGION_STATIC (0) is reserved; the current function's declared
    // lifetimes take the ids after it (universal -- they outlive the whole body), and every other
    // region is existential, allocated one per lifetime slot of a value's type as the body is walked.
    pub region_next: u32,
    // Flat storage for region VECTORS: the RegionVids filling a type's lifetime slots, in canonical
    // structural order. `rv_of` maps a node to its slice as (start << 32 | len). A flat pool avoids a
    // per-node allocation, and nodes whose type has no regions at all never enter the map.
    pub rv_pool: Vector<u32>,
    pub rv_of: Map<u32, u64>,
    // (module << 32 | TypeId) -> number of lifetime slots in that type. Pure function of the interned
    // type, so the memo is sound -- same idiom as carries_memo.
    pub arity_memo: Map<u64, u32>,
    // Per-aggregate variance of each lifetime-then-type parameter, 2 bits each (V_*), packed LSB-first,
    // keyed by decl (module << 32 | node). Lazy + memoized; a recursive-type cycle resolves to the
    // conservative all-V_INVARIANT (over-restricts only recursion). `variance_wip` marks a decl whose
    // inference is on the stack. Consumed by the invariance check and by `relate` for subtyping.
    pub variance_of: Map<u64, u64>,
    pub variance_wip: Map<u64, bool>,
    // Per-callee (module << 32 | node): is the result's lifetime fully attributable to bare-parameter
    // returns, so the modular return check (tc_check_return_lifetime) has verified exactly what it
    // borrows? Only then may a call site release the non-flowing arguments (relate_result_precision);
    // a laundered return (`let z = y; return z;`) is not attributable, so the call stays conservative.
    pub attributable_memo: Map<u64, bool>,
    // A declared lifetime param node -> the universal RegionVid standing for it in this function.
    pub lt_region: Map<u32, u32>,
    // Outlives constraints for the current function, packed (sup << 32 | sub) meaning "sup: sub",
    // i.e. sup outlives sub. Seeded from the signature (`<'a: 'b>` bounds and `where 'a: 'b`) and
    // later from constraint generation. Cleared per function -- RegionVids are function-scoped.
    pub outlives: Vector<u64>,
    // Index into `errors` where the CURRENT function's diagnostics begin. Region/lifetime errors are
    // discovered after the body has been walked (the solver only knows once its constraints are
    // solved), so they are inserted back into source order within this function's range rather than
    // appended after every other diagnostic. See tc_region_diag / diag::Errors::emit_ordered.
    pub err_wm: usize,
    // Two-phase-borrow watermark. While a method call's `&mut self` receiver borrow is being checked,
    // this holds the borrow-array index at which THIS call's argument borrows begin; a reserved `&mut`
    // does not conflict with the shared borrows its own arguments produced (`v.push(v.len())`,
    // `self.m(self.field.as_str())`). 0xFFFFFFFF = not in a receiver check.
    pub tc_twophase_wm: u32,
    pub unsafe_used: u32, // ops inside the innermost active 'unsafe' that actually required it (lint)
    pub len_reported: Vector<u64>, // array-length nodes already diagnosed ((module<<32)|node; resolve_type revisits)
    pub lint: bool,
    pub free_derive_memo: Map<u64, u64>, // (module<<32|decl) -> 1 = not owning, 2 = derives Free (non-generic only)
    pub bc_free_recv: bool, // marking a `.free()` receiver: destruction, exempt from the ref-move rejection
    pub derive_busy: Vector<u64>, // derive-recursion guard (value cycles are infinite-size errors anyway)
    pub mut_used: Vector<NodeId>, // bindings whose mutability was actually required (unnecessary-mut lint)
    pub loop_stack: [LoopEntry; 32],
    pub nloops: u32,
    pub loop_floor: u32,
    pub errors: diag::Errors,
    // TC-3: per-decl index of the LAST node whose resolution targets it (built lazily from the
    // resolver's tables; the one typechecker-added resolution kind that can target a binding --
    // break/continue -> loop node -- is folded in at its set site). Replaces the full-arena scan
    // in borrow_dead_after; answers are identical by construction.
    pub last_use: Vector<NodeId>,
    pub last_use_built: bool,
    // TC-5: presence bitset mirroring moved[0..nmoved] (bit index = decl NodeId), so is_moved is
    // O(1) per identifier. Kept in sync at every moved[] mutation site.
    pub moved_bits: Vector<u64>,
    // TC-6: (module<<32|decl) -> packed (module<<32|extend) of the type's Free extend (0 = none).
    // Same shape as codegen's CG-3 memo; the first full scan already interned everything the
    // repeat scans would, so pool order is unchanged.
    pub free_ext_memo: Map<u64, u64>,
    // TC-8: (module<<32|method) -> enclosing extend/interface item (NODE_NONE misses included).
    pub encl_ext_memo: Map<u64, NodeId>,
    pub encl_trait_memo: Map<u64, NodeId>,
    // TC-7: dyn-fn canonicalization worklist -- pool indices of TYPE_DYN-over-fn entries, collected
    // incrementally (each pool index scanned once); list order == pool order == old rescan order.
    pub dynfn_list: Vector<TypeId>,
    pub dynfn_scan: TypeId,
    // TC-9: format helpers are marked used once per module, not once per print call.
    pub fmt_marked: bool,
    // TC-11: (target, name-content, query kind) -> packed DefId (module<<32|node), misses included
    // (node == NODE_NONE). Valid for the whole check: the ext scope, ASTs and self.cur_module() (the
    // privacy filter input) are all fixed per checker. mark_method_used is re-fired on method hits
    // (idempotent set), so used-lint marking is unchanged.
    pub method_memo: Map<MQKey<'a>, u64>,
    /// The receiver type the last aggregate lookup resolved on: what tc_mark_method_used pairs a method
    /// with, since the lookups themselves are keyed by the receiver's DECL and never carry its arguments.
    pub mark_recv: TypeId,
    // TC-12: tc_peel_target memo, (module<<32|node) -> packed DefId. The first peel does the
    // named_type_of interning; repeats re-derived the same DefId from frozen inputs.
    pub peel_memo: Map<u64, u64>,
    // TC-13: foreign generic-instance lowering memo, (module<<32|node) -> current-pool TypeId,
    // HEAVY NODES ONLY (type paths with generic args; anything cheaper loses to the hash probe).
    // Foreign lowering is context-free (resolution_def/builtin_of_decl/consteval only; Self and
    // generic params lower to identity types, substitution happens in callers). DIAGNOSTICS GATE:
    // entries are inserted only when the lowering emitted no new errors and the result is not
    // TYPE_ERROR, so error-carrying programs re-emit their diagnostics exactly as before.
    pub lower_memo: Map<u64, TypeId>,
    // Memoized "does a value of this type carry a borrow" -- a pure function of the interned type, so
    // caching per (module, TypeId) makes the DEEP structural check O(1) after first use (it runs on
    // every method call and every binding/return). 1 = carries, 0 = does not.
    pub carries_memo: Map<u64, u8>,
    // TC-10: prelude lookup hits resolved once at construction (prelude_lookup is a linear scan).
    pub ph_str: loader::LookupHit,
    pub ph_slice: loader::LookupHit,
    pub ph_slicemut: loader::LookupHit,
    pub ph_range: loader::LookupHit,
    pub ph_box: loader::LookupHit,
    pub ph_global: loader::LookupHit,
    pub ph_t2: loader::LookupHit,
    pub ph_t3: loader::LookupHit,
    pub ph_t4: loader::LookupHit,
    pub ph_option: loader::LookupHit,
    pub ph_result: loader::LookupHit,
}

// Takes the package pointer as usize: a *mut Package value is move-tracked (Package is Free).
fn ph_lookup(pkg: usize, name: str) loader::LookupHit {
    let package = pkg as *mut loader::Package;
    if package == null {
        return loader::LookupHit { node: NODE_NONE, mid: 0 };
    }
    return package.prelude_lookup(name, true);
}

// --- result structs (out-params) ----------------------------------------------------------------
pub struct FnSig {
    pub n: i32,
    pub params: [TypeId; 4],
    pub ret: TypeId,
}
pub struct SliceKind {
    pub kind: i32,
    pub elem: TypeId,
}
pub struct BoxOf {
    pub ok: bool,
    pub inner: TypeId,
    pub global_alloc: bool,
}
pub struct RecvSubst {
    pub n: i32,
    pub p: [DefId; 8],
    pub a: [TypeId; 8],
}

// --- span helpers -------------------------------------------------------------------------------
pub const fn span_is(src: str, s: tok::Span, lit: str) bool {
    let n = lit.len();
    if (s.end - s.start) as usize != n {
        return false;
    }
    return unsafe cstring::memcmp(src.ptr() + s.start as usize, lit.ptr(), n) == 0;
}

pub const fn spans_eq2(sa: str, a: tok::Span, sb: str, b: tok::Span) bool {
    let la = a.end - a.start;
    if la != b.end - b.start {
        return false;
    }
    return unsafe cstring::memcmp(sa.ptr() + a.start as usize, sb.ptr() + b.start as usize, la as usize) == 0;
}

const fn builtin_name(b: BuiltinType) str<'static> {
    return bt_name(b);
}

const fn builtin_of(src: str, s: tok::Span) i32 {
    return bt_of_name(src, s);
}

const fn bt_is_int(b: BuiltinType) bool {
    return b as u8 >= BuiltinType::BT_I8 as u8 && b as u8 <= BuiltinType::BT_USIZE as u8;
}
const fn bt_is_float(b: BuiltinType) bool {
    return b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64;
}
const fn bt_is_complex(b: BuiltinType) bool {
    return b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64;
}

const fn bt_int_max(b: BuiltinType) u64 {
    if b == BuiltinType::BT_I8 {
        return 127u64;
    }
    if b == BuiltinType::BT_I16 {
        return 32767u64;
    }
    if b == BuiltinType::BT_I32 {
        return 2147483647u64;
    }
    if b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE {
        return 9223372036854775807u64;
    }
    if b == BuiltinType::BT_U8 {
        return 255u64;
    }
    if b == BuiltinType::BT_U16 {
        return 65535u64;
    }
    if b == BuiltinType::BT_U32 {
        return 4294967295u64;
    }
    return 0u64; // u64/usize
}

const fn tc_lit_in_range(b: BuiltinType, mag: u64, neg: bool) bool {
    let mx = bt_int_max(b);
    if neg {
        let sgn = b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
        return sgn && (mx == 0 || mag <= mx + 1);
    }
    return mx == 0 || mag <= mx;
}

// Implicit lossless numeric widening.
const fn bt_widens(from: BuiltinType, to: BuiltinType) bool {
    if from == BuiltinType::BT_F32 && to == BuiltinType::BT_F64 {
        return true;
    }
    let fs = from as u8 >= BuiltinType::BT_I8 as u8 && from as u8 <= BuiltinType::BT_I64 as u8;
    let fu = from as u8 >= BuiltinType::BT_U8 as u8 && from as u8 <= BuiltinType::BT_U64 as u8;
    let ts = to as u8 >= BuiltinType::BT_I8 as u8 && to as u8 <= BuiltinType::BT_I64 as u8;
    let tu = to as u8 >= BuiltinType::BT_U8 as u8 && to as u8 <= BuiltinType::BT_U64 as u8;
    if !(fs || fu) || !(ts || tu) {
        return false;
    }
    let mut fw = from as i32 - BuiltinType::BT_U8 as i32;
    if fs {
        fw = from as i32 - BuiltinType::BT_I8 as i32;
    }
    let mut tw = to as i32 - BuiltinType::BT_U8 as i32;
    if ts {
        tw = to as i32 - BuiltinType::BT_I8 as i32;
    }
    if fu {
        return tw > fw;
    }
    return ts && tw > fw;
}

// Shared integer-literal base-prefix detection: returns (base, prefix chars consumed).
const fn lit_base_prefix(p: *const u8, len: usize) (u64, usize) {
    if len >= 2 && unsafe p[0] == b'0' {
        let c1 = unsafe p[1] | 0x20u8;
        if c1 == b'x' {
            return 16u64, 2;
        }
        if c1 == b'b' {
            return 2u64, 2;
        }
        if c1 == b'o' {
            return 8u64, 2;
        }
    }
    return 10u64, 0;
}

const fn hex_digit(c: u8) u32 {
    if c <= b'9' {
        return c - b'0';
    }
    return (c | 0x20u8) - b'a' + 10u8;
}

extend TypeChecker {
    /// Ownership: consumes `ast` (reclaim it with take_ast); `package` is a borrowed raw pointer (may be null).
    pub fn new(ast: Ast, source: str, package: *mut loader::Package) TypeChecker {
        let pkg = package as usize; // read the address before the literal's `package:` field moves it
        return TypeChecker {
            ast: UnsafeCell::<Ast>::new(ast),
            source: source,
            current_returns: NodeList { start: 0, len: 0 },
            current_self: NODE_NONE,
            current_extend: NODE_NONE,
            current_fn: NODE_NONE,
            nclos: 0,
            package: package,
            alias_depth: 0,
            ext_scope: Vector::<ModuleId>::new(),
            n_ext_scope: -1,
            ext_items: Vector::<Vector<NodeId>>::new(),
            ext_items_built: Vector::<bool>::new(),
            expected: TYPE_NONE,
            nmoved: 0,
            nmoved_places: 0,
            nuninit: 0,
            nlate: 0,
            nfreed: 0,
            nborrows: 0,
            scope_depth: 0,
            loop_depth: 0,
            binding_depth: Map::<u32, u32>::new(),
            ndefers: 0,
            in_loop_recheck: false,
            place_use: false,
            addr_ctx: false,
            mret_call: NODE_NONE,
            mret_n: 0,
            mret_total: 0,
            unsafe_depth: 0,
            region_next: 1,
            rv_pool: Vector::<u32>::new(),
            rv_of: Map::<u32, u64>::new(),
            arity_memo: Map::<u64, u32>::new(),
            variance_of: Map::<u64, u64>::new(),
            variance_wip: Map::<u64, bool>::new(),
            attributable_memo: Map::<u64, bool>::new(),
            lt_region: Map::<u32, u32>::new(),
            outlives: Vector::<u64>::new(),
            err_wm: 0,
            tc_twophase_wm: 0xFFFFFFFF,
            unsafe_used: 0,
            len_reported: Vector::<u64>::new(),
            lint: false,
            free_derive_memo: Map::<u64, u64>::new(),
            bc_free_recv: false,
            derive_busy: Vector::<u64>::new(),
            mut_used: Vector::<NodeId>::new(),
            nloops: 0,
            loop_floor: 0,
            errors: diag::Errors::new(),
            last_use: Vector::<NodeId>::new(),
            last_use_built: false,
            moved_bits: Vector::<u64>::new(),
            free_ext_memo: Map::<u64, u64>::new(),
            encl_ext_memo: Map::<u64, NodeId>::new(),
            encl_trait_memo: Map::<u64, NodeId>::new(),
            dynfn_list: Vector::<TypeId>::new(),
            dynfn_scan: 1,
            fmt_marked: false,
            method_memo: Map::<MQKey, u64>::new(),
            mark_recv: TYPE_NONE,
            peel_memo: Map::<u64, u64>::new(),
            lower_memo: Map::<u64, TypeId>::new(),
            carries_memo: Map::<u64, u8>::new(),
            ph_str: ph_lookup(pkg, "str"),
            ph_slice: ph_lookup(pkg, "Slice"),
            ph_slicemut: ph_lookup(pkg, "SliceMut"),
            ph_range: ph_lookup(pkg, "Range"),
            ph_box: ph_lookup(pkg, "Box"),
            ph_global: ph_lookup(pkg, "Global"),
            ph_t2: ph_lookup(pkg, "Tuple2"),
            ph_t3: ph_lookup(pkg, "Tuple3"),
            ph_t4: ph_lookup(pkg, "Tuple4"),
            ph_option: ph_lookup(pkg, "Option"),
            ph_result: ph_lookup(pkg, "Result"),
        };
    }

    /// Ownership: moves the typed Ast out, leaving an empty placeholder -- the checker is done after this.
    pub fn take_ast(self: &mut Self) Ast {
        let out = replace(&mut self.ast, UnsafeCell::<Ast>::new(Ast::new(0))).into_inner();
        return out;
    }

    // ---- ast / source access (raw pointers) ----
    pub const fn cur_ast(self: &Self) *mut Ast {
        return self.ast.get();
    }
    // The module id of the AST under check. A by-value read (no lingering borrow of `self`), so it composes
    // inside expressions that also take `&mut self` -- which a reference through `ast.get_ref()` would not.
    pub const fn cur_module(self: &Self) ModuleId {
        return unsafe self.cur_ast().module;
    }

    pub const fn mod_ast(self: &Self, m: ModuleId) *mut Ast {
        if self.package != null && m != self.cur_module() {
            // A stage holding module `m`'s Ast left an empty placeholder in the table. That used to matter
            // for one module at a time; a stage that checks its modules in parallel has ALL of them in
            // flight, so a foreign lookup that skipped the override would read an empty Ast.
            let ov = self.package.override_at(m);
            if ov != 0 {
                return ov as *mut Ast;
            }
            return unsafe &mut self.package.modules[m as usize].ast;
        }
        return self.ast.get();
    }
    pub const fn mod_src(self: &Self, m: ModuleId) str {
        if self.package != null && m != self.cur_module() {
            return unsafe self.package.modules[m as usize].source.as_str();
        }
        return self.source;
    }
    pub const fn pkg_count(self: &Self) usize {
        if self.package == null {
            return 0;
        }
        return unsafe self.package.modules.len();
    }
    const fn ceval(self: &Self) *mut ce::ConstEval {
        if self.package == null {
            return null;
        }
        return (unsafe self.package.ceval) as *mut ce::ConstEval;
    }

    pub const fn name_span(self: &Self, name_node: NodeId) tok::Span {
        return self.cur_ast().at_const(name_node).as_data.name.text;
    }

    pub const fn type_at(self: &Self, x: TypeId) &Ty {
        return self.cur_ast().type_at(x);
    }
    const fn at_not_fn(self: &Self, x: TypeId) bool {
        return self.type_at(x).kind != TypeKind::TYPE_FUNCTION;
    }

    // ---- simple type predicates ----
    const fn is_bool(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_BOOL;
    }
    const fn is_int(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && bt_is_int(y.as_data.builtin);
    }
    const fn is_numeric(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && (bt_is_int(y.as_data.builtin) || bt_is_float(y.as_data.builtin) || bt_is_complex(
            y.as_data.builtin,
        ));
    }
    const fn is_void_type(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
    }
    const fn bt_of(self: &Self, x: TypeId) BuiltinType {
        let y = self.type_at(x);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return y.as_data.builtin;
        }
        return BuiltinType::BT_COUNT;
    }
    fn is_plain_enum(self: &Self, x: TypeId) bool {
        let y = *self.type_at(x);
        if y.kind != TypeKind::TYPE_ENUM {
            return false;
        }
        let a = self.mod_ast(y.module);
        let ms = a.at_const(y.as_data.decl).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            if a.at_const(mid).as_data.variant.payload.len > 0 {
                return false;
            }
        }
        return true;
    }
    pub fn strip(self: &Self, x0: TypeId) TypeId {
        let mut x = x0;
        let mut y = self.type_at(x);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            x = y.as_data.elem;
            y = self.type_at(x);
        }
        return x;
    }
    fn tc_ref(self: &mut Self, elem: TypeId, mut2: bool) TypeId {
        let mut q = TypeQualifier::TYPE_QUAL_NONE;
        if mut2 {
            q = TypeQualifier::TYPE_QUAL_MUT;
        }
        return self.cur_ast().intern_type(
            Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: q as u8, as_data: TyAs { elem: elem } },
        );
    }

    fn tc_is_prelude_decl(self: &Self, t: TypeId, name: str) bool {
        if self.package == null {
            return false;
        }
        let hit = self.package.prelude_lookup(name, true);
        if hit.node == NODE_NONE {
            return false;
        }
        let y = self.type_at(t);
        return y.kind == TypeKind::TYPE_STRUCT && y.module == hit.mid && y.as_data.decl == hit.node;
    }
    fn tc_main_params_ok(self: &Self, params: NodeList) bool {
        if params.len == 0 {
            return true;
        }
        if params.len != 1 || self.package == null {
            return false;
        }
        let ids = self.cur_ast().list(params);
        let argv = self.type_at(self.cur_ast().type_of(unsafe ids[0]));
        if argv.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let hit = self.package.prelude_lookup("Vector", true);
        if hit.node == NODE_NONE {
            return false;
        }
        let it = self.cur_ast().instance(argv.as_data.inst);
        return it.module == hit.mid && it.decl == hit.node && it.n >= 1 && self.tc_is_prelude_decl(it.args[0], "str");
    }

    // ---- loop stack ----
    /// Returns the loop-stack index, or -1 when 32 loops are already open (callers skip the matching pop).
    pub const fn tc_loop_push(self: &mut Self, label: tok::Span, node: NodeId, value_loop: bool) i32 {
        if self.nloops >= 32 {
            return -1;
        }
        let n = self.nloops;
        unsafe self.loop_stack[n as usize] = LoopEntry {
            label: label,
            node: node,
            break_ty: TYPE_NONE,
            value_loop: value_loop,
            saw_value: false,
            saw_bare: false,
            depth: self.scope_depth,
        };
        self.nloops = n + 1;
        return n as i32;
    }
    fn tc_loop_pop(self: &mut Self, le: i32, sp: tok::Span) {
        if le < 0 {
            return;
        }
        if unsafe self.loop_stack[le as usize].saw_value && unsafe self.loop_stack[le as usize].saw_bare {
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("every 'break' in a value-yielding 'loop' must carry a value"),
            );
        }
        self.nloops = le as u32;
    }
    fn tc_find_loop(self: &Self, label: tok::Span) i32 {
        let mut i = self.nloops;
        while i > self.loop_floor {
            i = i - 1;
            if label.end == label.start {
                return i as i32;
            }
            let ls = unsafe self.loop_stack[i as usize].label;
            if ls.end - ls.start == label.end - label.start && unsafe cstring::memcmp(
                self.source.ptr() + ls.start as usize,
                self.source.ptr() + label.start as usize,
                (ls.end - ls.start) as usize,
            ) == 0 {
                return i as i32;
            }
        }
        return -1;
    }

    // ---- test-fn visibility ----
    fn tc_is_test_fn(self: &Self, m: ModuleId, fnode: NodeId) bool {
        let a = self.mod_ast(m);
        for i in 0..unsafe a.attrs.len() {
            let at = unsafe a.attrs.at(i);
            if at.owner == fnode && (at.kind == AttrKind::ATTR_TEST as u8 || at.kind == AttrKind::ATTR_TEST_INIT as u8 || at.kind == AttrKind::ATTR_TEST_FREE as u8) {
                return true;
            }
        }
        return false;
    }
    fn tc_in_test_fn(self: &Self) bool {
        return self.current_fn != NODE_NONE && self.tc_is_test_fn(self.cur_module(), self.current_fn);
    }
    fn tc_check_test_ref(self: &mut Self, d: DefId, sp: tok::Span) {
        if d.node == NODE_NONE || !self.tc_is_test_fn(d.module, d.node) || self.tc_in_test_fn() {
            return;
        }
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("a '@test' function can only be called from other test functions"),
        );
        self.errors.note(
            format("test functions are not compiled outside 'super-c --test'; move shared logic into a plain function"),
        );
    }

    // ---- literal helpers ----
    fn tc_literal_pinned(self: &Self, id: NodeId) bool {
        let n = self.cur_ast().at_const(id);
        if n.kind != NodeKind::NODE_LITERAL {
            return false;
        }
        let tt = n.as_data.literal.token_type;
        if tt != TokenType::IntegerLiteral && tt != TokenType::FloatLiteral {
            return false;
        }
        return ast_numeric_suffix(self.source, n.as_data.literal.raw.start, n.as_data.literal.raw.end, null) != BuiltinType::BT_COUNT;
    }
    const fn is_integer_literal_node(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return false;
        }
        let a = self.cur_ast();
        let mut nid = id;
        let n0 = a.at_const(nid);
        if n0.kind == NodeKind::NODE_UNARY && n0.as_data.unary.op == TokenType::Minus {
            nid = n0.as_data.unary.operand;
        }
        let n = a.at_const(nid);
        return n.kind == NodeKind::NODE_LITERAL && n.as_data.literal.token_type == TokenType::IntegerLiteral;
    }
    fn lit_mag(self: &Self, id: NodeId, out: *mut u64) bool {
        let n = self.cur_ast().at_const(id);
        let lr = n.as_data.literal.raw;
        let mut endd = lr.end;
        ast_numeric_suffix(self.source, lr.start, lr.end, &mut endd);
        let mut p = unsafe (self.source.ptr() + lr.start as usize);
        let mut len = (endd - lr.start) as usize;
        let (base, skip) = lit_base_prefix(p, len);
        p = unsafe (p + skip);
        len = len - skip;
        let mut acc: u64 = 0;
        for i in 0..len {
            let ch = unsafe p[i];
            if ch == b'_' {
                continue;
            }
            let mut d: u64 = 0;
            if ch <= b'9' {
                d = ch - b'0';
            } else {
                d = (ch | 0x20u8) - b'a' + 10u8;
            }
            if d >= base || acc > (0xFFFFFFFFFFFFFFFFu64 - d) / base {
                return false;
            }
            acc = acc * base + d;
        }
        unsafe *out = acc;
        return true;
    }

    fn char_literal_cp(self: &Self, s: tok::Span) u32 {
        let src = self.source;
        let mut i = (s.start + 1) as usize;
        if i >= s.end as usize {
            return 0;
        }
        if src[i] != b'\\' {
            let b = src[i];
            if b < 0x80u8 {
                return b;
            }
            if b <= 0xDFu8 {
                return (b & 0x1Fu8) as u32 << 6 | (src[i + 1] & 0x3Fu8) as u32;
            }
            if b <= 0xEFu8 {
                return (b & 0x0Fu8) as u32 << 12 | (src[i + 1] & 0x3Fu8) as u32 << 6 | (src[i + 2] & 0x3Fu8) as u32;
            }
            return (b & 0x07u8) as u32 << 18 | (src[i + 1] & 0x3Fu8) as u32 << 12 | (src[i + 2] & 0x3Fu8) as u32 << 6 | (src[i + 3] & 0x3Fu8) as u32;
        }
        i = i + 1;
        let e = src[i];
        i = i + 1;
        if e == b'x' {
            return hex_digit(src[i]) << 4 | hex_digit(src[i + 1]);
        }
        if e == b'u' {
            if i < s.end as usize && src[i] == b'{' {
                i = i + 1;
            }
            let mut cp: u32 = 0;
            while i < s.end as usize && src[i] != b'}' {
                cp = cp << 4 | hex_digit(src[i]);
                i = i + 1;
            }
            return cp;
        }
        return 0;
    }

    // An operation that requires 'unsafe': counts against the innermost active marker (for the
    // unnecessary-unsafe lint) and reports whether the requirement is unmet.
    const fn tc_needs_unsafe(self: &mut Self) bool {
        self.unsafe_used = self.unsafe_used + 1;
        return self.unsafe_depth == 0;
    }

    // Const-fold `nid` to an integer via the always-on interpreter. False when it isn't a
    // compile-time constant (locals, calls the fx summary rejects, ...) -- never an error.
    fn tc_fold_int(self: &mut Self, nid: NodeId, out: *mut i64) bool {
        let ceptr = self.ceval();
        if ceptr == null {
            return false;
        }
        let v = ceptr.eval(self.cur_module(), nid);
        if v.kind != ce::CONST_INT {
            return false;
        }
        unsafe *out = v.as_data.i;
        return true;
    }

    // ---- error / misc ----
    @c.cold
    fn err_unsafe(self: &mut Self, sp: tok::Span, what: str) {
        self.errors.emit(sp.start, sp.end - sp.start, format("{} requires an 'unsafe' block", what));
        self.errors.note(format("{}", "wrap the operation in 'unsafe { ... }' or prefix the expression with 'unsafe'"));
    }
    fn tc_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.mod_ast(m);
        for i in 0..unsafe a.attrs.len() {
            let at = unsafe a.attrs.at(i);
            if at.owner == owner && at.kind == kind as u8 {
                return at;
            }
        }
        return null;
    }
    /// Whether `t` mentions a '@no_const' declaration anywhere (through pointers, references,
    /// slices, arrays and instance arguments). Used by the `const fn` def-site check: no value of
    /// such a type can exist at compile time, so the signature cannot be part of a const contract.
    fn tc_ty_no_const(self: &Self, t: TypeId, depth: u32) bool {
        if t == TYPE_NONE || depth > 16 {
            return false;
        }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.tc_ty_no_const(y.as_data.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.tc_attr(y.module, y.as_data.decl, AttrKind::ATTR_NO_CONST) != null;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.cur_ast().instance(y.as_data.inst);
            if self.tc_attr(it.module, it.decl, AttrKind::ATTR_NO_CONST) != null {
                return true;
            }
            for i in 0..it.n {
                if self.tc_ty_no_const(unsafe it.args[i as usize], depth + 1) {
                    return true;
                }
            }
        }
        return false;
    }

    fn peel_wrappers(self: &Self, id0: NodeId) NodeId {
        let a = self.cur_ast();
        let mut id = id0;
        loop {
            let n = a.at_const(id);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                id = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        return id;
    }
    fn through_raw_pointer(self: &Self, ty0: TypeId) bool {
        let mut ty = ty0;
        let mut y = self.type_at(ty);
        while y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            if y.kind == TypeKind::TYPE_POINTER {
                return true;
            }
            ty = y.as_data.elem;
            y = self.type_at(ty);
        }
        return false;
    }

    fn render_type(self: &Self, tid: TypeId, buf: *mut char, cap: usize) {
        render_type_into(self.package, self.cur_ast(), self.source, tid, buf, cap);
    }

    @c.cold
    fn err_mismatch(self: &mut Self, node: NodeId, expected: TypeId) {
        let mut e = Buf96 {};
        let mut f = Buf96 {};
        self.render_type(expected, &mut e[0], 96);
        self.render_type(self.cur_ast().type_of(node), &mut f[0], 96);
        let sp = self.cur_ast().at_const(node).span;
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("mismatched types: expected '{}', found '{}'", diag::cstr(&e[0]), diag::cstr(&f[0])),
        );
    }

    // ---- function-type helpers ----
    fn fn_sig(self: &mut Self, fid: TypeId, params: *mut TypeId, cap: i32, ret: *mut TypeId) i32 {
        let fty = *self.type_at(fid);
        let m = fty.module;
        let fa = self.mod_ast(m);
        let fk = fa.at_const(fty.as_data.decl).kind;
        let mut ps = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        if fk == NodeKind::NODE_FUNCTION {
            ps = fa.at_const(fty.as_data.decl).as_data.function.params;
            rs = fa.at_const(fty.as_data.decl).as_data.function.returns;
        } else if fk == NodeKind::NODE_CLOSURE {
            ps = fa.at_const(fty.as_data.decl).as_data.closure.params;
            rs = fa.at_const(fty.as_data.decl).as_data.closure.returns;
        } else {
            ps = fa.at_const(fty.as_data.decl).as_data.function_type.params;
            rs = fa.at_const(fty.as_data.decl).as_data.function_type.returns;
        }
        let mut i: u32 = 0;
        while i < ps.len && i as i32 < cap {
            let pid = unsafe fa.list(ps)[i as usize];
            let p = fa.at_const(pid);
            if p.kind == NodeKind::NODE_PARAMETER && p.as_data.parameter.ty == NODE_NONE {
                let pty = fa.type_of(pid);
                unsafe params[i as usize] = pty;
            } else {
                let tn = if_node(p.kind == NodeKind::NODE_PARAMETER, p.as_data.parameter.ty, pid);
                unsafe params[i as usize] = self.lower_type_in(m, tn);
            }
            i = i + 1;
        }
        if fk == NodeKind::NODE_CLOSURE && fa.at_const(fty.as_data.decl).as_data.closure.expr_body {
            let rty = fa.type_of(fa.at_const(fty.as_data.decl).as_data.closure.body);
            unsafe *ret = rty;
        } else if rs.len == 1 {
            let r0 = unsafe fa.list(rs)[0];
            let rn = fa.at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            unsafe *ret = self.lower_type_in(m, tn);
        } else if rs.len == 0 {
            // an omitted return type IS void -- TYPE_NONE here would make call sites lenient
            unsafe *ret = Ast::builtin(BuiltinType::BT_VOID);
        } else {
            unsafe *ret = TYPE_NONE; // multi-return: callers read the component list instead
        }
        return ps.len as i32;
    }

    const fn receiver_type_eq(self: &Self, a: TypeId, b: TypeId) bool {
        if a == b {
            return true;
        }
        let at = self.type_at(a);
        let bt = self.type_at(b);
        let ap = at.kind == TypeKind::TYPE_POINTER || at.kind == TypeKind::TYPE_REFERENCE;
        let bp = bt.kind == TypeKind::TYPE_POINTER || bt.kind == TypeKind::TYPE_REFERENCE;
        return ap && bp && at.qualifier == bt.qualifier && at.as_data.elem == bt.as_data.elem;
    }

    fn generic_fn_bound(self: &Self, m: ModuleId, decl: NodeId) NodeId {
        let a = self.mod_ast(m);
        let gp = a.at_const(decl);
        if gp.kind != NodeKind::NODE_GENERIC_PARAM {
            return NODE_NONE;
        }
        let bounds = gp.as_data.generic_param.bounds;
        for i in 0..bounds.len {
            let bid = unsafe a.list(bounds)[i as usize];
            if a.at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                return bid;
            }
        }
        if self.current_fn != NODE_NONE && (self.package == null || m == self.cur_module()) {
            let wc = self.cur_ast().at_const(self.current_fn).as_data.function.where_clause;
            for w in 0..wc.len {
                let wid = unsafe self.cur_ast().list(wc)[w as usize];
                let wp = self.cur_ast().at_const(wid).as_data.where_predicate;
                if self.cur_ast().resolution(wp.ty) == decl {
                    for b in 0..wp.bounds.len {
                        let wbid = unsafe self.cur_ast().list(wp.bounds)[b as usize];
                        if self.cur_ast().at_const(wbid).kind == NodeKind::NODE_FUNCTION_TYPE {
                            return wbid;
                        }
                    }
                }
            }
        }
        return NODE_NONE;
    }

    const fn fn_is_capturing(self: &Self, fid: TypeId) bool {
        let fy = self.type_at(fid);
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let a = self.mod_ast(fy.module);
        let fnn = a.at_const(fy.as_data.decl);
        return fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0;
    }

    pub fn tc_capture_index(self: &Self, clos: NodeId, decl: NodeId) i32 {
        let a = self.cur_ast();
        let caps = a.at_const(clos).as_data.closure.captures;
        for i in 0..caps.len {
            let cid = unsafe a.list(caps)[i as usize];
            if cid == decl {
                return i as i32;
            }
        }
        return -1;
    }

    fn fn_owns(self: &mut Self, fid: TypeId) bool {
        let fy = *self.type_at(fid);
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let fa = self.mod_ast(fy.module);
        let fnn = fa.at_const(fy.as_data.decl);
        if fnn.kind != NodeKind::NODE_CLOSURE {
            return false;
        }
        let caps = fnn.as_data.closure.captures;
        let mut_caps = fnn.as_data.closure.mut_caps as u64;
        for i in 0..caps.len {
            let cid = unsafe fa.list(caps)[i as usize];
            if (mut_caps >> i as u64 & 1u64) == 0 {
                let rt = self.cur_ast().reintern(unsafe &*fa, fa.type_of(cid));
                if self.tc_type_is_free(rt) {
                    return true;
                }
            }
        }
        return false;
    }

    const fn ret_eq(self: &Self, a: TypeId, b: TypeId) bool {
        if a == b {
            return true;
        }
        let v = Ast::builtin(BuiltinType::BT_VOID);
        return (a == TYPE_NONE || a == v) && (b == TYPE_NONE || b == v);
    }

    fn fn_compatible(self: &mut Self, exid: TypeId, acid: TypeId) bool {
        if exid != acid && self.fn_is_capturing(acid) {
            return false;
        }
        return self.dynfn_sig_ok(exid, acid);
    }

    /// The generic function `node` names, or NODE_NONE when it names something else. A generic function
    /// has no type of its own -- only its instantiations do -- so naming one as a VALUE needs the type
    /// arguments pinned before it can be a fn pointer.
    fn tc_generic_fn_named(self: &Self, node: NodeId) DefId {
        let a = self.cur_ast();
        let mut n = node;
        if a.at_const(n).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            n = a.at_const(n).as_data.specialization.expression;
        }
        let k = a.at_const(n).kind;
        if k != NodeKind::NODE_IDENTIFIER && (k != NodeKind::NODE_MEMBER || !a.at_const(n).as_data.member.path) {
            return DefId { module: 0, node: NODE_NONE };
        }
        let d = a.resolution_def(n);
        if d.node == NODE_NONE || d.module != self.cur_module() && (self.package == null || d.module as usize >= self.pkg_count()) {
            return DefId { module: 0, node: NODE_NONE };
        }
        let dn = self.mod_ast(d.module).at_const(d.node);
        if dn.kind != NodeKind::NODE_FUNCTION || dn.as_data.function.generics.len == 0 {
            return DefId { module: 0, node: NODE_NONE };
        }
        return d;
    }

    /// Does `node` need the context type pushed into it before it can be checked? A generic function
    /// named as a value and an empty array literal both carry no type of their own.
    fn tc_wants_param_type(self: &Self, node: NodeId) bool {
        let n = self.cur_ast().at_const(node);
        if n.kind == NodeKind::NODE_ARRAY_LITERAL {
            return !n.as_data.array_literal.repeat && n.as_data.array_literal.elements.len == 0;
        }
        return self.tc_generic_fn_named(node).node != NODE_NONE;
    }

    /// Coerce a generic function named as a value to the expected function-pointer type: bind its type
    /// parameters by matching its declared signature against `expected`'s, then check the substituted
    /// signature. On success the node ADOPTS `expected` (a concrete signature the rest of the pipeline
    /// can render and emit) and records its type arguments, so codegen names the monomorphized instance
    /// exactly as a call site does. A turbofish pre-binds the arguments it spells out.
    fn tc_coerce_generic_fn(self: &mut Self, expected: TypeId, node: NodeId) bool {
        let d = self.tc_generic_fn_named(node);
        if d.node == NODE_NONE || self.type_at(expected).kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let fa = self.mod_ast(d.module);
        let gens = fa.at_const(d.node).as_data.function.generics;
        let g = gens.len as i32;
        if g > 8 {
            return false;
        }
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        for i in 0..g {
            gp[i as usize] = DefId { module: d.module, node: unsafe fa.list(gens)[i as usize] };
            ga[i as usize] = TYPE_NONE;
        }
        // explicit turbofish arguments bind first, left to right
        let sn = self.cur_ast().at_const(node);
        if sn.kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            let tas = sn.as_data.specialization.types;
            let mut i: u32 = 0;
            while i < tas.len && i as i32 < g {
                ga[i as usize] = self.resolve_type(unsafe self.cur_ast().list(tas)[i as usize]);
                i = i + 1;
            }
        }
        let mut ep = Tys8 {};
        let mut er: TypeId = TYPE_NONE;
        let en = self.fn_sig(expected, &mut ep[0], 4, &mut er);
        let params = fa.at_const(d.node).as_data.function.params;
        let rets = fa.at_const(d.node).as_data.function.returns;
        if params.len as i32 != en || en > 4 || rets.len > 1 {
            return false;
        }
        // infer the rest from the wanted signature, parameters then return
        for i in 0..en {
            let pid = unsafe fa.list(params)[i as usize];
            self.unify_infer(self.decl_type_in(d.module, pid), ep[i as usize], &gp[0], &mut ga[0], g);
        }
        if rets.len == 1 {
            let r0 = unsafe fa.list(rets)[0];
            let rn = self.mod_ast(d.module).at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            self.unify_infer(self.lower_type_in(d.module, tn), er, &gp[0], &mut ga[0], g);
        }
        for i in 0..g {
            if ga[i as usize] == TYPE_NONE {
                return false;
            }
        }
        // the substituted signature must be exactly what was asked for
        for i in 0..en {
            let pid = unsafe fa.list(params)[i as usize];
            if self.subst_type(self.decl_type_in(d.module, pid), &gp[0], &ga[0], g) != ep[i as usize] {
                return false;
            }
        }
        let mut ar = Ast::builtin(BuiltinType::BT_VOID);
        if rets.len == 1 {
            let r0 = unsafe fa.list(rets)[0];
            let rn = self.mod_ast(d.module).at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            ar = self.subst_type(self.lower_type_in(d.module, tn), &gp[0], &ga[0], g);
        }
        if !self.ret_eq(er, ar) {
            return false;
        }
        self.check_generic_bounds(node, d.module, d.node, gens, &gp[0], &ga[0], g, &gp[0], &ga[0], 0);
        self.cur_ast().set_type(node, expected);
        self.cur_ast().set_type_args(node, &ga[0], g as u8);
        return true;
    }

    fn dynfn_sig_ok(self: &mut Self, exid: TypeId, acid: TypeId) bool {
        let mut ep = Tys8 {};
        let mut ap = Tys8 {};
        let mut er: TypeId = TYPE_NONE;
        let mut ar: TypeId = TYPE_NONE;
        let en = self.fn_sig(exid, &mut ep[0], 4, &mut er);
        let an = self.fn_sig(acid, &mut ap[0], 4, &mut ar);
        if en != an || en > 4 || !self.ret_eq(er, ar) {
            return false;
        }
        for i in 0..en {
            if ep[i as usize] != ap[i as usize] {
                return false;
            }
        }
        return true;
    }

    fn tc_dyn_fn_sig(self: &mut Self, ty: &Ty) TypeId {
        if ty.kind != TypeKind::TYPE_DYN {
            return TYPE_NONE;
        }
        let dnode = self.cur_ast().dyn_decl_of(ty);
        if self.mod_ast(ty.module).at_const(dnode).kind != NodeKind::NODE_FUNCTION_TYPE {
            return TYPE_NONE;
        }
        return self.lower_type_in(ty.module, dnode);
    }

    fn tc_dyn_same(self: &mut Self, a: &Ty, b: &Ty) bool {
        let as2 = self.tc_dyn_fn_sig(a);
        let bs = self.tc_dyn_fn_sig(b);
        if as2 != TYPE_NONE != (bs != TYPE_NONE) {
            return false;
        }
        if as2 != TYPE_NONE {
            return as2 == bs || self.fn_compatible(as2, bs);
        }
        return a.module == b.module && a.as_data.inst == b.as_data.inst;
    }
}

pub const fn if_node(c: bool, a: NodeId, b: NodeId) NodeId {
    if c {
        return a;
    }
    return b;
}
pub const fn if_ty(c: bool, a: TypeId, b: TypeId) TypeId {
    if c {
        return a;
    }
    return b;
}
const fn src_at(p: str, off: u32) *const char {
    return (unsafe (p.ptr() + off as usize)) as *const char;
}

// The Ast to read for module `m`'s decls when rendering against the in-flight ast `a` (mirrors
// TypeChecker::mod_ast): foreign modules come from the package, the current one from `a` itself.
const fn rt_ast(pkg: *const loader::Package, a: *const Ast, m: ModuleId) *const Ast {
    if pkg != null && m != unsafe a.module {
        let ov = pkg.override_at(m); // in-flight Ast when a stage holds it -- see TypeChecker::mod_ast
        if ov != 0 {
            return ov as *const Ast;
        }
        return unsafe &pkg.modules[m as usize].ast;
    }
    return a;
}
const fn rt_src(pkg: *const loader::Package, a: *const Ast, cur_src: str, m: ModuleId) str {
    if pkg != null && m != unsafe a.module {
        return unsafe pkg.modules[m as usize].source.as_str();
    }
    return cur_src;
}

// `fn(P, Q) R` from a function type's decl node. Reads the CACHED type of each parameter/return node
// rather than lowering (no checker here); an uncached slot renders `..`, so a signature never checked
// still names itself. Without this every function type printed as a bare "fn" and a mismatch between
// two of them read "expected 'fn', found 'fn'".
fn render_fn_sig_into(pkg: *const loader::Package, a: *const Ast, cur_src: str, ty: &Ty, buf: *mut char, cap: usize) {
    let ma = rt_ast(pkg, a, ty.module);
    let d = ma.at_const(ty.as_data.decl);
    let mut ps = NodeList { start: 0, len: 0 };
    let mut rs = NodeList { start: 0, len: 0 };
    if d.kind == NodeKind::NODE_FUNCTION {
        ps = d.as_data.function.params;
        rs = d.as_data.function.returns;
    } else if d.kind == NodeKind::NODE_CLOSURE {
        ps = d.as_data.closure.params;
        rs = d.as_data.closure.returns;
    } else if d.kind == NodeKind::NODE_FUNCTION_TYPE {
        ps = d.as_data.function_type.params;
        rs = d.as_data.function_type.returns;
    } else {
        unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "fn".ptr() as *const char);
        return;
    }
    let mut at: usize = 0;
    at = at + (unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "fn(".ptr() as *const char)) as usize;
    for i in 0..ps.len {
        let mut pb = Buf96 {};
        render_slot_into(pkg, a, cur_src, ma, unsafe ma.list(ps)[i as usize], &mut pb[0], 96);
        let mut sep = ", ".ptr() as *const char;
        if i == 0 {
            sep = "".ptr() as *const char;
        }
        if at >= cap {
            return;
        }
        at = at + (unsafe stdio::snprintf(buf + at, cap - at, "%s%s".ptr() as *const char, sep, &pb[0])) as usize;
    }
    if at >= cap {
        return;
    }
    let mut rb = Buf96 {};
    if rs.len == 1 {
        render_slot_into(pkg, a, cur_src, ma, unsafe ma.list(rs)[0], &mut rb[0], 96);
        unsafe stdio::snprintf(buf + at, cap - at, ") %s".ptr() as *const char, &rb[0]);
    } else {
        unsafe stdio::snprintf(buf + at, cap - at, "%s".ptr() as *const char, ")".ptr() as *const char);
    }
}

// One parameter/return slot of a function type: the node is either a NODE_PARAMETER wrapping a type
// node or the type node itself.
fn render_slot_into(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    ma: *const Ast,
    slot: NodeId,
    buf: *mut char,
    cap: usize,
) {
    let mut tn = slot;
    if ma.at_const(slot).kind == NodeKind::NODE_PARAMETER {
        tn = ma.at_const(slot).as_data.parameter.ty;
    }
    let mut t = TYPE_NONE;
    if tn != NODE_NONE {
        t = ma.type_of(tn);
    }
    if t == TYPE_NONE {
        t = ma.type_of(slot);
    }
    if t == TYPE_NONE {
        unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "..".ptr() as *const char);
        return;
    }
    render_type_into(pkg, ma, rt_src(pkg, a, cur_src, unsafe ma.module), t, buf, cap);
}

/// Render `tid` as Super-C surface syntax into `buf` (NUL-terminated, truncating at `cap`). The
/// standalone form of TypeChecker::render_type: `a` is the Ast owning the type pool (a checker's
/// in-flight ast, or a module's held ast after the build), `cur_src` that module's source, `pkg` the
/// package for cross-module decl names (null falls back to `a`/`cur_src` for everything). Also serves
/// LSP hover, which renders from a fully built package.
pub fn render_type_into(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    tid: TypeId,
    buf: *mut char,
    cap: usize,
) {
    let ty = *a.type_at(tid);
    if ty.kind == TypeKind::TYPE_BUILTIN {
        unsafe stdio::snprintf(
            buf,
            cap,
            "%s".ptr() as *const char,
            builtin_name(ty.as_data.builtin).ptr() as *const char,
        );
    } else if ty.kind == TypeKind::TYPE_NEVER {
        unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "never".ptr() as *const char);
    } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
        let mut inb = Buf96 {};
        render_type_into(pkg, a, cur_src, ty.as_data.elem, &mut inb[0], 96);
        let mut pfx = "&".ptr() as *const char;
        if ty.kind == TypeKind::TYPE_POINTER {
            pfx = "*".ptr() as *const char;
        }
        let mut mq = "".ptr() as *const char;
        if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            mq = "mut ".ptr() as *const char;
        } else if ty.kind == TypeKind::TYPE_POINTER && ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
            mq = "const ".ptr() as *const char; // a bare `*T` and `*const T` are distinct types
        }
        unsafe stdio::snprintf(buf, cap, "%s%s%s".ptr() as *const char, pfx, mq, &inb[0]);
    } else if ty.kind == TypeKind::TYPE_SLICE {
        let mut inb = Buf96 {};
        render_type_into(pkg, a, cur_src, ty.as_data.elem, &mut inb[0], 96);
        unsafe stdio::snprintf(buf, cap, "[]%s".ptr() as *const char, &inb[0]);
    } else if ty.kind == TypeKind::TYPE_ARRAY {
        let mut inb = Buf96 {};
        render_type_into(pkg, a, cur_src, ty.as_data.arr.elem, &mut inb[0], 96);
        unsafe stdio::snprintf(buf, cap, "[%s; %u]".ptr() as *const char, &inb[0], ty.as_data.arr.len);
    } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM || ty.kind == TypeKind::TYPE_GENERIC {
        let ma = rt_ast(pkg, a, ty.module);
        let d = ma.at_const(ty.as_data.decl);
        let mut nm = d.as_data.aggregate.name;
        if d.kind == NodeKind::NODE_GENERIC_PARAM {
            nm = d.as_data.generic_param.name;
        }
        let s = ma.at_const(nm).as_data.name.text;
        unsafe stdio::snprintf(
            buf,
            cap,
            "%.*s".ptr() as *const char,
            (s.end - s.start) as i32,
            src_at(rt_src(pkg, a, cur_src, ty.module), s.start),
        );
    } else if ty.kind == TypeKind::TYPE_OPAQUE {
        let ma = rt_ast(pkg, a, ty.module);
        let s = ma.at_const(ma.at_const(ty.as_data.decl).as_data.type_alias.name).as_data.name.text;
        unsafe stdio::snprintf(
            buf,
            cap,
            "%.*s".ptr() as *const char,
            (s.end - s.start) as i32,
            src_at(rt_src(pkg, a, cur_src, ty.module), s.start),
        );
    } else if ty.kind == TypeKind::TYPE_INSTANCE {
        let it = *a.instance(ty.as_data.inst);
        let ma = rt_ast(pkg, a, it.module);
        let s = ma.at_const(ma.at_const(it.decl).as_data.aggregate.name).as_data.name.text;
        let at0 = unsafe stdio::snprintf(
            buf,
            cap,
            "%.*s<".ptr() as *const char,
            (s.end - s.start) as i32,
            src_at(rt_src(pkg, a, cur_src, it.module), s.start),
        );
        let mut at = at0 as usize;
        let mut i: u8 = 0;
        while i < it.n && at < cap {
            let mut argb = Buf96 {};
            render_type_into(pkg, a, cur_src, unsafe it.args[i as usize], &mut argb[0], 64);
            let mut sep = "".ptr() as *const char;
            if i != 0 {
                sep = ", ".ptr() as *const char;
            }
            let mut room: usize = 0;
            if cap > at {
                room = cap - at;
            }
            let w = unsafe stdio::snprintf(buf + at, room, "%s%s".ptr() as *const char, sep, &argb[0]);
            at = at + w as usize;
            i = i + 1;
        }
        if at < cap {
            unsafe stdio::snprintf(buf + at, cap - at, "%s".ptr() as *const char, ">".ptr() as *const char);
        }
    } else if ty.kind == TypeKind::TYPE_FUNCTION {
        render_fn_sig_into(pkg, a, cur_src, &ty, buf, cap);
    } else if ty.kind == TypeKind::TYPE_DYN {
        let ma = rt_ast(pkg, a, ty.module);
        let mut pfx = "Box<dyn ".ptr() as *const char;
        if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            pfx = "&mut dyn ".ptr() as *const char;
        } else if ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
            pfx = "&dyn ".ptr() as *const char;
        }
        let mut sfx = "".ptr() as *const char;
        if ty.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
            sfx = ">".ptr() as *const char;
        }
        let ddecl = a.dyn_decl_of(&ty);
        if ma.at_const(ddecl).kind == NodeKind::NODE_FUNCTION_TYPE {
            unsafe stdio::snprintf(buf, cap, "%sfn(..) ..%s".ptr() as *const char, pfx, sfx);
        } else {
            let s = ma.at_const(ma.at_const(ddecl).as_data.interface_def.name).as_data.name.text;
            unsafe stdio::snprintf(
                buf,
                cap,
                "%s%.*s%s".ptr() as *const char,
                pfx,
                (s.end - s.start) as i32,
                src_at(rt_src(pkg, a, cur_src, ty.module), s.start),
                sfx,
            );
        }
    } else if ty.kind == TypeKind::TYPE_CONST_EXPR {
        // Printed from the canonical form rather than as written: two of these failing to match is the
        // one diagnostic this type produces, and the forms are what actually differ.
        let l = a.const_lin_at(ty.as_data.inst);
        let mut at: usize = 0;
        if cap > 1 {
            unsafe buf[0] = '{' as char;
            at = 1;
        }
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c == 0 {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            let pa = rt_ast(pkg, a, pd.module);
            let ns = pa.at_const(pa.at_const(pd.node).as_data.generic_param.name).as_data.name.text;
            let sep = if at > 1 {
                " + ".ptr() as *const char;
            } else {
                "".ptr() as *const char;
            };
            if c == 1 {
                at = at + (unsafe stdio::snprintf(
                    buf + at,
                    cap - at,
                    "%s%.*s".ptr() as *const char,
                    sep,
                    (ns.end - ns.start) as i32,
                    src_at(rt_src(pkg, a, cur_src, pd.module), ns.start),
                )) as usize;
            } else {
                at = at + (unsafe stdio::snprintf(
                    buf + at,
                    cap - at,
                    "%s%lld * %.*s".ptr() as *const char,
                    sep,
                    c,
                    (ns.end - ns.start) as i32,
                    src_at(rt_src(pkg, a, cur_src, pd.module), ns.start),
                )) as usize;
            }
        }
        if l.k != 0 && at < cap {
            at = at + (unsafe stdio::snprintf(buf + at, cap - at, " + %lld".ptr() as *const char, l.k)) as usize;
        }
        if at + 1 < cap {
            unsafe buf[at] = '}' as char;
            unsafe buf[at + 1] = 0 as char;
        }
    } else {
        unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "?".ptr() as *const char);
    }
}

/// Shares value 0 with TYPE_NONE: an errored type reads as "untyped" downstream, so one diagnostic
/// does not cascade.
pub const TYPE_ERROR: TypeId = 0;

extend TypeChecker {
    /// Unwrap a struct/enum/instance type to its module + decl; for an instance also copies up to 8
    /// param->arg substitution pairs into `params`/`args`. False for any other type kind.
    pub fn aggregate_of(
        self: &Self,
        ty: TypeId,
        mod_out: &mut ModuleId,
        decl_out: &mut NodeId,
        params: &mut Defs8,
        args: &mut Tys8,
        n_out: &mut i32,
    ) bool {
        *n_out = 0;
        // Every method lookup reaches its (module, decl) through here, so this is where the RECEIVER a
        // method is resolved on is recorded -- the one piece the lookups themselves never carry.
        unsafe {
            ((self as *const TypeChecker) as *mut TypeChecker).mark_recv = ty;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            *mod_out = y.module;
            *decl_out = y.as_data.decl;
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.cur_ast().instance(y.as_data.inst);
            *mod_out = it.module;
            *decl_out = it.decl;
            let da = self.mod_ast(it.module);
            // `generics` never contains lifetime params (the parser splits them into `lifetimes`),
            // so it stays index-aligned with the erased-lifetime `it.args`.
            let gens = da.at_const(it.decl).as_data.aggregate.generics;
            let mut nn: i32 = 0;
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && nn as usize < params.len() {
                let gid = unsafe da.list(gens)[i as usize];
                params[nn as usize] = DefId { module: it.module, node: gid };
                args[nn as usize] = unsafe it.args[i as usize];
                nn = nn + 1;
                i = i + 1;
            }
            *n_out = nn;
            return true;
        }
        return false;
    }

    // Structural params[i]->args[i] substitution; unmatched generics pass through, and unchanged
    // subtrees return the original TypeId (nothing new interned).
    fn subst_type(self: &mut Self, ty: TypeId, params: *const DefId, args: *const TypeId, n: i32) TypeId {
        if ty == TYPE_NONE || n == 0 {
            return ty;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let mut out = ConstLin { k: 0, n: 0 };
            if self.tc_lin_subst(y.as_data.inst, params, args, n, &mut out, 0) {
                return self.cur_ast().intern_const_lin(&out);
            }
            return ty; // a parameter this instantiation does not bind: still symbolic
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..n {
                if unsafe params[i as usize].module == y.module && unsafe params[i as usize].node == y.as_data.decl {
                    return unsafe args[i as usize];
                }
            }
            return ty;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.subst_type(y.as_data.elem, params, args, n);
            if e == y.as_data.elem {
                return ty;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            return self.cur_ast().intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *self.cur_ast().instance(y.as_data.inst);
            let mut na = Tys8 {};
            let mut changed = false;
            for i in 0..src.n {
                na[i as usize] = self.subst_type(unsafe src.args[i as usize], params, args, n);
                if na[i as usize] != unsafe src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                return self.cur_ast().intern_instance(src.module, src.decl, &na[0], src.n);
            }
            return ty;
        }
        return ty;
    }

    /// A const-generic expression in canonical form: a constant plus a coefficient per parameter. This is
    /// what makes `{(N * 2) * 2}` and `{N * 4}` the same width -- comparing the expressions as written
    /// says they differ, and they do not. Linear is exactly the closed set here: `+`, `-`, and scaling by
    /// a constant stay inside it, and `N * N` does not, which is refused rather than approximated.
    fn tc_lin(
        self: &mut Self,
        m: ModuleId,
        id: NodeId,
        params: *const DefId,
        args: *const TypeId,
        n: i32,
        out: &mut ConstLin,
        depth: i32,
    ) bool {
        if id == NODE_NONE || depth > 12 {
            return false;
        }
        let a = self.mod_ast(m);
        let node = *a.at_const(id);
        if node.kind == NodeKind::NODE_IDENTIFIER || node.kind == NodeKind::NODE_MEMBER {
            let d = a.resolution_def(id);
            if d.node == NODE_NONE {
                return false;
            }
            // A bound parameter contributes what it is bound TO: a value, or another expression whose
            // own form is folded in here. That is what composes `dbl(dbl(x))` into one width.
            for i in 0..n {
                if unsafe params[i as usize].module == d.module && unsafe params[i as usize].node == d.node {
                    let bt = unsafe args[i as usize];
                    if bt == TYPE_NONE {
                        return false;
                    }
                    let by = *self.type_at(bt);
                    if by.kind == TypeKind::TYPE_CONST {
                        out.k = out.k + by.as_data.value;
                        return true;
                    }
                    if by.kind == TypeKind::TYPE_CONST_EXPR {
                        // The binding is itself an expression: fold ITS form in, which is what composes
                        // `dbl(dbl(x))` into one width rather than leaving two nested ones.
                        let mut inner = ConstLin { k: 0, n: 0 };
                        if !self.tc_lin_subst(by.as_data.inst, params, args, n, &mut inner, depth + 1) {
                            return false;
                        }
                        return lin_scale(&inner, 1, out);
                    }
                    if by.kind == TypeKind::TYPE_GENERIC {
                        return lin_add_term(out, DefId { module: by.module, node: by.as_data.decl }, 1);
                    }
                    return false;
                }
            }
            return lin_add_term(out, d, 1);
        }
        if node.kind == NodeKind::NODE_BINARY {
            let op = node.as_data.binary.op;
            let lid = node.as_data.binary.left;
            let rid = node.as_data.binary.right;
            if op == TokenType::Plus || op == TokenType::Minus {
                if !self.tc_lin(m, lid, params, args, n, out, depth + 1) {
                    return false;
                }
                let mut rhs = ConstLin { k: 0, n: 0 };
                if !self.tc_lin(m, rid, params, args, n, &mut rhs, depth + 1) {
                    return false;
                }
                let sign = if op == TokenType::Plus {
                    1;
                } else {
                    0 - 1;
                };
                out.k = out.k + sign * rhs.k;
                for i in 0..rhs.n {
                    if !lin_add_term(out, unsafe rhs.p[i as usize], sign * unsafe rhs.c[i as usize]) {
                        return false;
                    }
                }
                return true;
            }
            let mut lhs = ConstLin { k: 0, n: 0 };
            let mut rhs = ConstLin { k: 0, n: 0 };
            if !self.tc_lin(m, lid, params, args, n, &mut lhs, depth + 1) || !self.tc_lin(
                m,
                rid,
                params,
                args,
                n,
                &mut rhs,
                depth + 1,
            ) {
                return false;
            }
            if op == TokenType::Star {
                // One side must be a plain constant: a product of two parameters is not linear.
                if rhs.n == 0 {
                    return lin_scale(&lhs, rhs.k, out);
                }
                if lhs.n == 0 {
                    return lin_scale(&rhs, lhs.k, out);
                }
                return false;
            }
            if op == TokenType::LeftShift && rhs.n == 0 && rhs.k >= 0 && rhs.k < 32 {
                return lin_scale(&lhs, 1i64 << rhs.k, out);
            }
            if op == TokenType::Slash && rhs.n == 0 && rhs.k != 0 {
                return lin_divide(&lhs, rhs.k, out);
            }
            if op == TokenType::RightShift && rhs.n == 0 && rhs.k >= 0 && rhs.k < 32 {
                return lin_divide(&lhs, 1i64 << rhs.k, out);
            }
            return false;
        }
        // A leaf with no parameter in it -- a literal, a named const -- is the evaluator's business.
        let ceptr = self.ceval();
        if ceptr != null {
            let lv = ceptr.eval(m, id);
            if lv.kind == ce::CONST_INT {
                out.k = out.k + lv.as_data.i;
                return true;
            }
        }
        return false;
    }

    /// Substitute a canonical form: every parameter that this instantiation binds is replaced by what it
    /// is bound to -- a value, or another form, folded in. What is left is the composed width.
    fn tc_lin_subst(
        self: &mut Self,
        idx: u32,
        params: *const DefId,
        args: *const TypeId,
        n: i32,
        out: &mut ConstLin,
        depth: i32,
    ) bool {
        let a = self.cur_ast();
        return unsafe lin_subst(&*a, &*a, idx, params, args, n, out, depth);
    }

    /// Do two types denote the same thing when one or both still carry an unfolded const-generic
    /// expression? Compared by canonical form, not as written, so `{(N * 2) * 2}` matches `{N * 4}`.
    fn tc_const_expr_same(self: &mut Self, a: TypeId, b: TypeId) bool {
        if a == b {
            return true;
        }
        if a == TYPE_NONE || b == TYPE_NONE {
            return false;
        }
        let ya = *self.type_at(a);
        let yb = *self.type_at(b);
        if ya.kind == TypeKind::TYPE_CONST_EXPR && yb.kind == TypeKind::TYPE_CONST_EXPR {
            return const_lin_eq(
                self.cur_ast().const_lin_at(ya.as_data.inst),
                self.cur_ast().const_lin_at(yb.as_data.inst),
            );
        }
        if ya.kind != yb.kind {
            return false;
        }
        if ya.kind == TypeKind::TYPE_POINTER || ya.kind == TypeKind::TYPE_REFERENCE || ya.kind == TypeKind::TYPE_SLICE {
            return ya.qualifier == yb.qualifier && self.tc_const_expr_same(ya.as_data.elem, yb.as_data.elem);
        }
        if ya.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let ia = *self.cur_ast().instance(ya.as_data.inst);
        let ib = *self.cur_ast().instance(yb.as_data.inst);
        if ia.module != ib.module || ia.decl != ib.decl || ia.n != ib.n {
            return false;
        }
        let mut all = false;
        for i in 0..ia.n {
            if !self.tc_const_expr_same(unsafe ia.args[i as usize], unsafe ib.args[i as usize]) {
                return false;
            }
            all = true;
        }
        return all;
    }

    /// Fold a const-generic argument expression with the enclosing generic's parameters bound. The same
    /// arithmetic the compile-time evaluator does, over a substitution it has no way to see: `{BITS * 2}`
    /// is written where BITS is a parameter and read where it is a value.

    // A const-generic parameter used as an ARRAY LENGTH (`fn f<const N: usize>(a: [T; N])`). The lowered
    // parameter type cannot carry the binding -- `[T; N]` interns with a length of 0 while N is unbound --
    // so it is read from the parameter's type NODE against the argument's concrete array type. Without it
    // the call inferred nothing: the instance emitted as `f__v` with a bare `N` left in the C, and only an
    // explicit `f::<3>(..)` worked.
    fn infer_const_len(
        self: &mut Self,
        m: ModuleId,
        tn: NodeId,
        arg_ty: TypeId,
        arg_node: NodeId,
        params: *const DefId,
        bound: *mut TypeId,
        n: i32,
        depth: u32,
    ) {
        if tn == NODE_NONE || arg_ty == TYPE_NONE || depth > 8 {
            return;
        }
        let a = self.mod_ast(m);
        let nk = a.at_const(tn).kind;
        let at = *self.type_at(arg_ty);
        if nk == NodeKind::NODE_POINTER_TYPE || nk == NodeKind::NODE_REFERENCE_TYPE {
            if at.kind == TypeKind::TYPE_POINTER || at.kind == TypeKind::TYPE_REFERENCE {
                self.infer_const_len(
                    m,
                    a.at_const(tn).as_data.indirect_type.ty,
                    at.as_data.elem,
                    NODE_NONE,
                    params,
                    bound,
                    n,
                    depth + 1,
                );
            }
            return;
        }
        if nk != NodeKind::NODE_ARRAY_TYPE || at.kind != TypeKind::TYPE_ARRAY {
            return;
        }
        let ar = a.at_const(tn).as_data.array_type;
        if ar.length != NODE_NONE && a.at_const(ar.length).kind == NodeKind::NODE_IDENTIFIER {
            // An array LITERAL argument is typed against the expected type, which is this very parameter --
            // so while N is unbound the literal types as length 0 and has to be counted directly.
            let mut alen = at.as_data.arr.len;
            if alen == 0 && arg_node != NODE_NONE && self.cur_ast().at_const(arg_node).kind == NodeKind::NODE_ARRAY_LITERAL {
                let al = self.cur_ast().at_const(arg_node).as_data.array_literal;
                if !al.repeat {
                    alen = al.elements.len;
                }
            }
            let d = a.resolution_def(ar.length);
            for i in 0..n {
                if unsafe params[i as usize].module == d.module && unsafe params[i as usize].node == d.node && unsafe bound[i as usize] == TYPE_NONE {
                    unsafe bound[i as usize] = self.cur_ast().const_value(alen);
                    break;
                }
            }
        }
        self.infer_const_len(m, ar.element, at.as_data.arr.elem, NODE_NONE, params, bound, n, depth + 1);
    }

    fn unify_infer(self: &mut Self, param_ty: TypeId, arg_ty: TypeId, params: *const DefId, bound: *mut TypeId, n: i32) {
        if param_ty == TYPE_NONE || arg_ty == TYPE_NONE {
            return;
        }
        let p = *self.type_at(param_ty);
        // A parameter position written as a bare const-generic parameter reduces to the form `1 * P`,
        // which binds P exactly as a type parameter would. Anything more (`{P * 2}` in a PARAMETER) would
        // have to be solved for P, which this does not attempt.
        if p.kind == TypeKind::TYPE_CONST_EXPR {
            let l = *self.cur_ast().const_lin_at(p.as_data.inst);
            if l.k == 0 && l.n == 1 && l.c[0] == 1 {
                for i in 0..n {
                    if unsafe params[i as usize].module == l.p[0].module && unsafe params[i as usize].node == l.p[0].node {
                        if unsafe bound[i as usize] == TYPE_NONE {
                            unsafe bound[i as usize] = arg_ty;
                        }
                        return;
                    }
                }
            }
            return;
        }
        if p.kind == TypeKind::TYPE_GENERIC {
            for i in 0..n {
                if unsafe params[i as usize].module == p.module && unsafe params[i as usize].node == p.as_data.decl {
                    if unsafe bound[i as usize] == TYPE_NONE {
                        unsafe bound[i as usize] = arg_ty;
                    }
                    return;
                }
            }
            return;
        }
        let aT = *self.type_at(arg_ty);
        if aT.kind == p.kind && (p.kind == TypeKind::TYPE_POINTER || p.kind == TypeKind::TYPE_REFERENCE || p.kind == TypeKind::TYPE_SLICE || p.kind == TypeKind::TYPE_ARRAY) {
            self.unify_infer(p.as_data.elem, aT.as_data.elem, params, bound, n);
        } else if p.kind == TypeKind::TYPE_INSTANCE && aT.kind == TypeKind::TYPE_INSTANCE {
            let pi = *self.cur_ast().instance(p.as_data.inst);
            let ai = *self.cur_ast().instance(aT.as_data.inst);
            if pi.decl == ai.decl && pi.module == ai.module && pi.n == ai.n {
                for i in 0..pi.n {
                    self.unify_infer(unsafe pi.args[i as usize], unsafe ai.args[i as usize], params, bound, n);
                }
            }
        } else if p.kind == TypeKind::TYPE_FUNCTION && aT.kind == TypeKind::TYPE_FUNCTION {
            let mut pp = Tys8 {};
            let mut ap = Tys8 {};
            let mut pr: TypeId = TYPE_NONE;
            let mut ar: TypeId = TYPE_NONE;
            let pn = self.fn_sig(param_ty, &mut pp[0], 4, &mut pr);
            let an = self.fn_sig(arg_ty, &mut ap[0], 4, &mut ar);
            if pn == an && pn <= 4 {
                for i in 0..pn {
                    self.unify_infer(pp[i as usize], ap[i as usize], params, bound, n);
                }
                self.unify_infer(pr, ar, params, bound, n);
            }
        }
    }

    fn named_type_of(self: &mut Self, m: ModuleId, decl: NodeId) TypeId {
        let a = self.mod_ast(m);
        let dk = a.at_const(decl).kind;
        if dk == NodeKind::NODE_STRUCT {
            return self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_STRUCT, module: m, as_data: TyAs { decl: decl } },
            );
        }
        if dk == NodeKind::NODE_ENUM {
            return self.cur_ast().intern_type(Ty { kind: TypeKind::TYPE_ENUM, module: m, as_data: TyAs { decl: decl } });
        }
        if dk == NodeKind::NODE_TYPE_ALIAS {
            let aliased_node = a.at_const(decl).as_data.type_alias.ty;
            if aliased_node == NODE_NONE {
                return self.cur_ast().intern_type(
                    Ty { kind: TypeKind::TYPE_OPAQUE, module: m, as_data: TyAs { decl: decl } },
                );
            }
            if self.alias_depth >= TYPE_ALIAS_MAX_DEPTH {
                let sp = a.at_const(decl).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("type alias is cyclic"));
                return TYPE_ERROR;
            }
            self.alias_depth = self.alias_depth + 1;
            let aliased = self.lower_type_in(m, aliased_node);
            self.alias_depth = self.alias_depth - 1;
            return aliased;
        }
        if dk == NodeKind::NODE_GENERIC_PARAM || dk == NodeKind::NODE_INTERFACE {
            return self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_GENERIC, module: m, as_data: TyAs { decl: decl } },
            );
        }
        return TYPE_ERROR;
    }

    const fn agg_has_default_at(self: &Self, dmod: ModuleId, dn: NodeId, from: u32) bool {
        let da = self.mod_ast(dmod);
        let gens = da.at_const(dn).as_data.aggregate.generics;
        if from >= gens.len {
            return false;
        }
        let gid = unsafe da.list(gens)[from as usize];
        return da.at_const(gid).as_data.generic_param.default_type != NODE_NONE;
    }

    fn apply_default_args(self: &mut Self, dmod: ModuleId, dn: NodeId, ta: *mut TypeId, tn: *mut u8) {
        let da = self.mod_ast(dmod);
        let gens = da.at_const(dn).as_data.aggregate.generics;
        if unsafe *tn >= gens.len as u8 {
            return;
        }
        let mut i = (unsafe *tn) as u32;
        while i < gens.len && unsafe *tn < 8 {
            let gid = unsafe da.list(gens)[i as usize];
            let dft = da.at_const(gid).as_data.generic_param.default_type;
            if dft == NODE_NONE {
                break;
            }
            let mut d = self.lower_type_in(dmod, dft);
            if unsafe *tn > 0 {
                let mut prm = Defs8 {};
                for j in 0..unsafe *tn {
                    let gj = unsafe da.list(gens)[j as usize];
                    prm[j as usize] = DefId { module: dmod, node: gj };
                }
                d = self.subst_type(d, &prm[0], ta, unsafe *tn);
            }
            let k = unsafe *tn;
            unsafe ta[k as usize] = d;
            unsafe *tn = k + 1;
            i = i + 1;
        }
    }

    // ---- prelude type intercepts (all through the TC-10 cached hits) ----
    fn prelude_str_type(self: &mut Self) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        if self.ph_str.node != NODE_NONE {
            return self.named_type_of(self.ph_str.mid, self.ph_str.node);
        }
        return TYPE_ERROR;
    }
    fn prelude_slice_type(self: &mut Self, elem: TypeId, mut2: bool) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        let mut hit = self.ph_slice;
        if mut2 {
            hit = self.ph_slicemut;
        }
        if hit.node != NODE_NONE {
            return self.cur_ast().intern_instance(hit.mid, hit.node, &elem, 1);
        }
        return TYPE_ERROR;
    }
    fn prelude_range_type(self: &mut Self, elem: TypeId) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        if self.ph_range.node != NODE_NONE {
            return self.cur_ast().intern_instance(self.ph_range.mid, self.ph_range.node, &elem, 1);
        }
        return TYPE_ERROR;
    }
    fn prelude_tuple_type(self: &mut Self, args: *const TypeId, n: u32) TypeId {
        if self.package == null || n < 2 || n > 4 {
            return TYPE_ERROR;
        }
        let mut hit = self.ph_t2;
        if n == 3 {
            hit = self.ph_t3;
        } else if n == 4 {
            hit = self.ph_t4;
        }
        if hit.node != NODE_NONE {
            return self.cur_ast().intern_instance(hit.mid, hit.node, args, n as u8);
        }
        return TYPE_ERROR;
    }

    // If `tid` is the prelude instance `hit`, copy its args into `out` and return the count; else -1.
    fn prelude_instance_args_hit(self: &Self, tid: TypeId, hit: loader::LookupHit, out: *mut TypeId, maxn: i32) i32 {
        if self.package == null || tid == TYPE_NONE || hit.node == NODE_NONE {
            return -1;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return -1;
        }
        let it = *self.cur_ast().instance(ty.as_data.inst);
        if it.module != hit.mid || it.decl != hit.node {
            return -1;
        }
        let mut i: i32 = 0;
        while i < it.n as i32 && i < maxn {
            unsafe out[i as usize] = unsafe it.args[i as usize];
            i = i + 1;
        }
        return it.n;
    }
    fn tuple_args_of(self: &Self, tid: TypeId, out: *mut TypeId, maxn: i32) i32 {
        let n2 = self.prelude_instance_args_hit(tid, self.ph_t2, out, maxn);
        if n2 >= 0 {
            return n2;
        }
        let n3 = self.prelude_instance_args_hit(tid, self.ph_t3, out, maxn);
        if n3 >= 0 {
            return n3;
        }
        return self.prelude_instance_args_hit(tid, self.ph_t4, out, maxn);
    }
    const fn range_instance_elem(self: &Self, tid: TypeId) TypeId {
        if self.package == null {
            return TYPE_NONE;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return TYPE_NONE;
        }
        let it = *self.cur_ast().instance(ty.as_data.inst);
        if it.n == 1 && it.module == self.ph_range.mid && it.decl == self.ph_range.node {
            return it.args[0];
        }
        return TYPE_NONE;
    }
    // 0 not a slice, 1 Slice<E>, 2 SliceMut<E>; sets *elem.
    const fn slice_kind(self: &Self, tid: TypeId, elem: *mut TypeId) i32 {
        if self.package == null {
            return 0;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return 0;
        }
        let it = *self.cur_ast().instance(ty.as_data.inst);
        if it.n != 1 {
            return 0;
        }
        let mut kind: i32 = 0;
        if it.module == self.ph_slice.mid && it.decl == self.ph_slice.node {
            kind = 1;
        } else if it.module == self.ph_slicemut.mid && it.decl == self.ph_slicemut.node {
            kind = 2;
        }
        if kind != 0 && elem != null {
            unsafe *elem = it.args[0];
        }
        return kind;
    }
    const fn tc_box_of(self: &Self, y: &Ty, inner: *mut TypeId, global_alloc: *mut bool) bool {
        if y.kind != TypeKind::TYPE_INSTANCE || self.package == null {
            return false;
        }
        let it = *self.cur_ast().instance(y.as_data.inst);
        if it.module != self.ph_box.mid || it.decl != self.ph_box.node || it.n < 1 {
            return false;
        }
        unsafe *inner = it.args[0];
        let mut ga = false;
        if it.n >= 2 {
            let ay = self.type_at(it.args[1]);
            ga = ay.kind == TypeKind::TYPE_STRUCT && ay.module == self.ph_global.mid && ay.as_data.decl == self.ph_global.node;
        }
        unsafe *global_alloc = ga;
        return true;
    }

    fn decl_type_in(self: &mut Self, m: ModuleId, decl: NodeId) TypeId {
        if decl == NODE_NONE {
            return TYPE_NONE;
        }
        let local = self.package == null || m == self.cur_module();
        if local {
            let cached = self.cur_ast().type_of(decl);
            if cached != TYPE_NONE {
                return cached;
            }
        }
        let a = self.mod_ast(m);
        let dk = a.at_const(decl).kind;
        let mut result = TYPE_NONE;
        if dk == NodeKind::NODE_PARAMETER {
            result = self.lower_type_in(m, a.at_const(decl).as_data.parameter.ty);
        } else if dk == NodeKind::NODE_FIELD {
            result = self.lower_type_in(m, a.at_const(decl).as_data.field.ty);
        } else if dk == NodeKind::NODE_CONST {
            result = self.lower_type_in(m, a.at_const(decl).as_data.const_def.ty);
        } else if dk == NodeKind::NODE_LET {
            result = self.lower_type_in(m, a.at_const(decl).as_data.let_stmt.ty);
        } else if dk == NodeKind::NODE_FUNCTION {
            result = self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_FUNCTION, module: m, as_data: TyAs { decl: decl } },
            );
        } else if dk == NodeKind::NODE_GENERIC_PARAM {
            let gp = a.at_const(decl).as_data.generic_param;
            // In value position a const-generic param has its declared type (e.g. usize); a type param is TYPE_GENERIC.
            // A LIFETIME param has no type at all -- lifetimes are erased before monomorphization, so it must never
            // become a TYPE_GENERIC (that would make it a mono argument and mangle into the emitted symbol).
            if gp.is_lifetime {
                result = TYPE_NONE;
            } else if gp.is_const {
                result = self.lower_type_in(m, gp.const_type);
            } else {
                result = self.named_type_of(m, decl);
            }
        } else if dk == NodeKind::NODE_STRUCT || dk == NodeKind::NODE_ENUM {
            result = self.named_type_of(m, decl);
        }
        if local {
            self.cur_ast().set_type(decl, result);
        }
        return result;
    }
    fn decl_type(self: &mut Self, decl: NodeId) TypeId {
        return self.decl_type_in(self.cur_module(), decl);
    }

    fn type_of_type_node(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        if self.cur_ast().at_const(id).kind != NodeKind::NODE_IDENTIFIER {
            return self.resolve_type(id);
        }
        let d = self.cur_ast().resolution_def(id);
        if d.node != NODE_NONE {
            return self.named_type_of(d.module, d.node);
        }
        let b = builtin_of(self.source, self.name_span(id));
        if b >= 0 {
            return Ast::builtin(b as BuiltinType);
        }
        return TYPE_ERROR;
    }

    // Is this generic argument a const VALUE rather than a type? A bare integer literal always is; that is
    // the only form `parse_type_args` recognises, so everything else arrives as a type node and the deciding
    // fact is what the resolver bound it to. A one-part path bound to a `const` is a named constant standing
    // where a literal used to be required. A const-generic PARAMETER is deliberately not included: it is
    // declared in both namespaces and keeps flowing through the type path, which already substitutes it.
    const fn tc_arg_is_const(self: &mut Self, m: ModuleId, aid: NodeId) bool {
        let k = self.mod_ast(m).at_const(aid).kind;
        if k == NodeKind::NODE_LITERAL {
            return true;
        }
        // A braced argument is written as an expression, so it arrives as one: anything that is not a
        // type path cannot be a type, and the braces already said it is a value.
        if k == NodeKind::NODE_BINARY || k == NodeKind::NODE_UNARY || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF || k == NodeKind::NODE_CALL {
            return true;
        }
        if k != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let tp = self.mod_ast(m).at_const(aid).as_data.type_path;
        if tp.parts.len != 1 || tp.args.len != 0 {
            return false;
        }
        let d = self.mod_ast(m).resolution_def(aid);
        if d.node == NODE_NONE {
            return false;
        }
        return self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_CONST;
    }

    // Fold a const-generic argument expression (e.g. the `4` in `Buff<i32, 4>`) to an interned TYPE_CONST value.
    fn tc_const_arg(self: &mut Self, m: ModuleId, aid: NodeId) TypeId {
        let ceptr = self.ceval();
        if ceptr != null {
            let lv = ceptr.eval(m, aid);
            if lv.kind == ce::CONST_INT {
                return self.cur_ast().const_value(lv.as_data.i);
            }
        }
        // A braced argument is an ordinary expression node, and one in a TYPE position is never checked,
        // so the evaluator has no type to work from and answers only its leaves. Reduce it to canonical
        // form instead: an expression of literals comes out a plain value, and one over the enclosing
        // generic's own parameters -- unbound HERE -- comes out a form, interned by VALUE so substitution
        // can compose forms later and two spellings of one width are already the same type.
        let mut lin = ConstLin { k: 0, n: 0 };
        if self.tc_lin(m, aid, null, null, 0, &mut lin, 0) {
            return self.cur_ast().intern_const_lin(&lin);
        }
        let sp = self.mod_ast(m).at_const(aid).span;
        if ceptr != null && ceptr.ce_trap_get().len() != 0 {
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("const generic argument must be a constant integer: {}", ceptr.ce_trap_detail()),
            );
        } else {
            self.errors.emit(sp.start, sp.end - sp.start, format("const generic argument must be a constant integer"));
        }
        return TYPE_ERROR;
    }

    fn ce_array_len(self: &mut Self, m: ModuleId, lenNode: NodeId) u32 {
        let ceptr = self.ceval();
        if ceptr == null {
            return 0;
        }
        let lv = ceptr.eval(m, lenNode);
        // A length of 0 is legal (an empty carrier type); it interns as the same len-0 array a
        // `[]` literal types with, which is exactly the type the literal must match.
        if lv.kind == ce::CONST_INT && lv.as_data.i >= 0 && lv.as_data.i <= 0xFFFFFFFFi64 {
            return lv.as_data.i as u32;
        }
        // A length that belongs to ANOTHER module is that module's to diagnose, in its own source: this
        // one is only lowering the foreign type to learn its layout, and the module has not been
        // typechecked yet, so a const-valued length (`[u8; CAP]`, `CAP` folding a `sizeof`) has no value
        // to fold TO yet and fails here through no fault of its own. Reporting it against the current
        // module also rendered the foreign span against the wrong source. Every module is typechecked, so
        // a genuinely non-constant length is still reported -- once, where it is written.
        if m != self.cur_module() {
            return 0;
        }
        // diagnose once per node; unsubstituted generic contexts stay silent (re-lowered at instantiation)
        let key = m as u64 << 32 | lenNode as u64;
        for i in 0..self.len_reported.len() {
            if self.len_reported[i] == key {
                return 0;
            }
        }
        let sp = self.mod_ast(m).at_const(lenNode).span;
        if ceptr.ce_trap_get().len() != 0 {
            self.len_reported.push(key);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("array length cannot be evaluated: {}", ceptr.ce_trap_detail()),
            );
        } else if lv.kind != ce::CONST_NONE {
            self.len_reported.push(key);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("array length must be a non-negative constant expression"),
            );
        } else if !self.tc_mentions_generic(m, lenNode, 0) {
            self.len_reported.push(key);
            self.errors.emit(sp.start, sp.end - sp.start, format("array length must be a constant expression"));
        }
        return 0;
    }

    // Does the expression mention a generic parameter or a sizeof/alignof (possibly generic-typed)?
    // Such lengths legitimately fail pre-instantiation and must not be diagnosed.
    fn tc_mentions_generic(self: &Self, m: ModuleId, id: NodeId, depth: u32) bool {
        if id == NODE_NONE || depth > 32 {
            return true;
        }
        let a = self.mod_ast(m);
        let n = a.at_const(id);
        switch n.kind {
            NODE_SIZEOF | NODE_ALIGNOF => {
                return true;
            },
            NODE_IDENTIFIER => {
                let d = a.resolution_def(id);
                return d.node != NODE_NONE && self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM;
            },
            NODE_MEMBER => {
                if !n.as_data.member.path {
                    return self.tc_mentions_generic(m, n.as_data.member.object, depth + 1);
                }
                let d = a.resolution_def(id);
                return d.node != NODE_NONE && self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM;
            },
            NODE_UNARY => {
                return self.tc_mentions_generic(m, n.as_data.unary.operand, depth + 1);
            },
            NODE_BINARY => {
                return self.tc_mentions_generic(m, n.as_data.binary.left, depth + 1) || self.tc_mentions_generic(
                    m,
                    n.as_data.binary.right,
                    depth + 1,
                );
            },
            NODE_CAST => {
                return self.tc_mentions_generic(m, n.as_data.cast.expression, depth + 1);
            },
            NODE_CALL => {
                let args = n.as_data.call.args;
                for i in 0..args.len {
                    if self.tc_mentions_generic(m, unsafe a.list(args)[i as usize], depth + 1) {
                        return true;
                    }
                }
                return false;
            },
            NODE_LITERAL => {
                return false;
            },
            _ => {},
        };
        return true; // unknown shapes: assume generic-dependent (stay silent)
    }

    /// Lower a type node of module `m` to a TypeId interned in the CURRENT module's pool: the current
    /// module goes through resolve_type's per-node cache, foreign modules through the memoized
    /// context-free lowering (TC-13).
    pub fn lower_type_in(self: &mut Self, m: ModuleId, id: NodeId) TypeId {
        if self.package == null || m == self.cur_module() {
            return self.resolve_type(id);
        }
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        // TC-13: memoized foreign lowering with the diagnostics gate. Only generic-instance
        // paths take the memo: they re-lower every argument and probe the instance maps, so a
        // hash probe wins; plain paths/builtins are CHEAPER than the probe itself (measured:
        // an unconditional memo made typechecking 32% slower).
        let hn = self.mod_ast(m).at_const(id);
        if hn.kind != NodeKind::NODE_TYPE_PATH || hn.as_data.type_path.args.len == 0 {
            return self.lower_foreign_type(m, id);
        }
        let lk = m as u64 << 32 | id as u64;
        switch self.lower_memo.get(&lk) {
            Some(t) => {
                return *t;
            },
            None => {},
        };
        let ne = self.errors.errors.len();
        let r = self.lower_foreign_type(m, id);
        if r != TYPE_ERROR && self.errors.errors.len() == ne {
            self.lower_memo.insert(lk, r);
        }
        return r;
    }
    fn lower_foreign_type(self: &mut Self, m: ModuleId, id: NodeId) TypeId {
        let a = self.mod_ast(m);
        let nk = a.at_const(id).kind;
        if nk == NodeKind::NODE_TYPE_PATH {
            let d = a.resolution_def(id);
            let args = a.at_const(id).as_data.type_path.args;
            if d.node != NODE_NONE {
                let bb = self.package.builtin_of_decl(d.module, d.node);
                if bb >= 0 {
                    return Ast::builtin(bb as BuiltinType);
                }
                let dnk = self.mod_ast(d.module).at_const(d.node).kind;
                if args.len == 1 && self.package != null {
                    let a0 = unsafe a.list(args)[0];
                    let an = a.at_const(a0);
                    if an.kind == NodeKind::NODE_DYN_TYPE && an.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_NONE {
                        if d.module == self.ph_box.mid && d.node == self.ph_box.node {
                            return self.lower_type_in(m, a0);
                        }
                    }
                }
                if (dnk == NodeKind::NODE_STRUCT || dnk == NodeKind::NODE_ENUM) && self.mod_ast(d.module).at_const(
                    d.node,
                ).as_data.aggregate.generics.len > 0 && (args.len > 0 || self.agg_has_default_at(
                    d.module,
                    d.node,
                    args.len,
                )) {
                    let mut ta = Tys8 {};
                    if args.len > 8 {
                        let sp = a.at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("too many generic arguments ({}; the maximum is 8)", args.len),
                        );
                    }
                    let mut tn: u8 = 0;
                    let mut i: u32 = 0;
                    while i < args.len && tn < 8 {
                        let aid = unsafe a.list(args)[i as usize];
                        if self.tc_arg_is_const(m, aid) {
                            ta[tn as usize] = self.tc_const_arg(m, aid);
                            tn = tn + 1;
                            i = i + 1;
                            continue;
                        }
                        ta[tn as usize] = self.lower_type_in(m, aid);
                        if ta[tn as usize] != TYPE_NONE && self.type_at(ta[tn as usize]).kind == TypeKind::TYPE_ARRAY && self.type_at(
                            ta[tn as usize],
                        ).as_data.arr.len == 0 {
                            let asp = a.at_const(aid).span;
                            self.errors.emit(
                                asp.start,
                                asp.end - asp.start,
                                format(
                                    "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct",
                                ),
                            );
                            ta[tn as usize] = TYPE_NONE;
                        }
                        tn = tn + 1;
                        i = i + 1;
                    }
                    self.apply_default_args(d.module, d.node, &mut ta[0], &mut tn);
                    return self.cur_ast().intern_instance(d.module, d.node, &ta[0], tn);
                }
                return self.named_type_of(d.module, d.node);
            }
            let parts = a.at_const(id).as_data.type_path.parts;
            let mut b: i32 = -1;
            if parts.len != 0 {
                let p0 = unsafe a.list(parts)[0];
                b = builtin_of(self.mod_src(m), a.at_const(p0).as_data.name.text);
            }
            if b >= 0 {
                return Ast::builtin(b as BuiltinType);
            }
            return TYPE_ERROR;
        }
        if nk == NodeKind::NODE_SLICE_TYPE {
            let it = a.at_const(id).as_data.indirect_type;
            return self.prelude_slice_type(self.lower_type_in(m, it.ty), it.qualifier == TypeQualifier::TYPE_QUAL_MUT);
        }
        if nk == NodeKind::NODE_TUPLE_TYPE {
            let elems = a.at_const(id).as_data.array_literal.elements;
            if elems.len > 4 {
                return TYPE_ERROR;
            }
            let mut targs = Tys8 {};
            for i in 0..elems.len {
                targs[i as usize] = self.lower_type_in(m, unsafe a.list(elems)[i as usize]);
            }
            return self.prelude_tuple_type(&targs[0], elems.len);
        }
        if nk == NodeKind::NODE_POINTER_TYPE || nk == NodeKind::NODE_REFERENCE_TYPE {
            let it = a.at_const(id).as_data.indirect_type;
            let mut k = TypeKind::TYPE_REFERENCE;
            if nk == NodeKind::NODE_POINTER_TYPE {
                k = TypeKind::TYPE_POINTER;
            }
            return self.cur_ast().intern_type(
                Ty { kind: k, qualifier: it.qualifier as u8, as_data: TyAs { elem: self.lower_type_in(m, it.ty) } },
            );
        }
        if nk == NodeKind::NODE_ARRAY_TYPE {
            let at = a.at_const(id).as_data.array_type;
            let alen = self.ce_array_len(m, at.length);
            return self.cur_ast().intern_type(
                Ty {
                    kind: TypeKind::TYPE_ARRAY,
                    as_data: TyAs { arr: TyArr { elem: self.lower_type_in(m, at.element), len: alen } },
                },
            );
        }
        if nk == NodeKind::NODE_FUNCTION_TYPE {
            return self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_FUNCTION, module: m, as_data: TyAs { decl: id } },
            );
        }
        if nk == NodeKind::NODE_DYN_TYPE {
            let it = a.at_const(id).as_data.indirect_type;
            let inner = it.ty;
            if a.at_const(inner).kind == NodeKind::NODE_FUNCTION_TYPE {
                return self.tc_intern_dynfn(m, inner, it.qualifier);
            }
            let mut d = DefId { module: 0, node: NODE_NONE };
            if a.at_const(inner).kind == NodeKind::NODE_TYPE_PATH {
                d = a.resolution_def(inner);
            }
            if d.node == NODE_NONE || self.mod_ast(d.module).at_const(d.node).kind != NodeKind::NODE_INTERFACE {
                return TYPE_ERROR;
            }
            let targs = a.at_const(inner).as_data.type_path.args;
            let mut na = Tys8 {};
            let mut nn: u8 = 0;
            for ti in 0..targs.len {
                if nn < 8 {
                    na[nn as usize] = self.lower_type_in(m, unsafe a.list(targs)[ti as usize]);
                    nn = nn + 1;
                }
            }
            return self.cur_ast().intern_dyn(d.module, d.node, &na[0], nn, it.qualifier as u8);
        }
        return TYPE_ERROR;
    }

    fn resolve_type(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        let cached = self.cur_ast().type_of(id);
        if cached != TYPE_NONE {
            return cached;
        }
        let a = self.cur_ast();
        let nk = a.at_const(id).kind;
        let mut result = TYPE_ERROR;
        switch nk {
            NODE_TYPE_PATH => {
                let parts = a.at_const(id).as_data.type_path.parts;
                let args = a.at_const(id).as_data.type_path.args;
                // Box<dyn I> interception
                let mut i: u32 = 0;
                while i < args.len && self.package != null {
                    let aid = unsafe a.list(args)[i as usize];
                    let an = a.at_const(aid);
                    if an.kind != NodeKind::NODE_DYN_TYPE || an.as_data.indirect_type.qualifier != TypeQualifier::TYPE_QUAL_NONE {
                        i = i + 1;
                        continue;
                    }
                    let bh = self.ph_box;
                    let hd = a.resolution_def(id);
                    if args.len == 1 && hd.module == bh.mid && hd.node == bh.node {
                        result = self.resolve_dyn_node(unsafe a.list(args)[0], TypeQualifier::TYPE_QUAL_NONE);
                    } else {
                        let sp = a.at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("a bare 'dyn' type can only be the generic argument of 'Box'"),
                        );
                    }
                    self.cur_ast().set_type(id, result);
                    return result;
                }
                i = 0;
                while i < args.len {
                    self.resolve_type(unsafe a.list(args)[i as usize]);
                    i = i + 1;
                }
                let d = a.resolution_def(id);
                if d.node != NODE_NONE {
                    let mut bb: i32 = -1;
                    if self.package != null {
                        bb = self.package.builtin_of_decl(d.module, d.node);
                    }
                    if bb >= 0 {
                        result = Ast::builtin(bb as BuiltinType);
                    } else {
                        let dnk = self.mod_ast(d.module).at_const(d.node).kind;
                        let generic_agg = (dnk == NodeKind::NODE_STRUCT || dnk == NodeKind::NODE_ENUM) && self.mod_ast(
                            d.module,
                        ).at_const(d.node).as_data.aggregate.generics.len > 0;
                        if generic_agg && args.len == 0 && self.current_extend != NODE_NONE && d.module == self.cur_module() && d.node == self.current_self {
                            let target = a.at_const(self.current_extend).as_data.extend_def.target_type;
                            if target != id {
                                result = self.resolve_type(target);
                            } else {
                                result = self.named_type_of(d.module, d.node);
                            }
                        } else if generic_agg && (args.len > 0 || self.agg_has_default_at(d.module, d.node, args.len)) {
                            let mut ta = Tys8 {};
                            if args.len > 8 {
                                let sp = a.at_const(id).span;
                                self.errors.emit(
                                    sp.start,
                                    sp.end - sp.start,
                                    format("too many generic arguments ({}; the maximum is 8)", args.len),
                                );
                            }
                            let mut tn: u8 = 0;
                            let mut j: u32 = 0;
                            while j < args.len && tn < 8 {
                                let aid = unsafe a.list(args)[j as usize];
                                // Lifetime arguments (`P<'a, T>`) are ERASED: skip them so the
                                // instance's args stay index-aligned with the declaration's
                                // (lifetime-free) generic params. Without this the type param binds to
                                // the lifetime slot and every `T` in the type resolves to `?`.
                                if a.at_const(aid).kind == NodeKind::NODE_LIFETIME {
                                    j = j + 1;
                                    continue;
                                }
                                if self.tc_arg_is_const(self.cur_module(), aid) {
                                    ta[tn as usize] = self.tc_const_arg(self.cur_module(), aid);
                                } else {
                                    ta[tn as usize] = self.resolve_type(aid);
                                    if ta[tn as usize] != TYPE_NONE && self.type_at(ta[tn as usize]).kind == TypeKind::TYPE_ARRAY && self.type_at(
                                        ta[tn as usize],
                                    ).as_data.arr.len == 0 {
                                        let asp = a.at_const(aid).span;
                                        self.errors.emit(
                                            asp.start,
                                            asp.end - asp.start,
                                            format(
                                                "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct",
                                            ),
                                        );
                                        ta[tn as usize] = TYPE_NONE;
                                    }
                                }
                                tn = tn + 1;
                                j = j + 1;
                            }
                            self.apply_default_args(d.module, d.node, &mut ta[0], &mut tn);
                            result = self.cur_ast().intern_instance(d.module, d.node, &ta[0], tn);
                        } else {
                            result = self.named_type_of(d.module, d.node);
                            if dnk == NodeKind::NODE_INTERFACE && parts.len != 0 && !span_is(
                                self.source,
                                self.name_span(unsafe a.list(parts)[0]),
                                "Self",
                            ) {
                                let isp = self.name_span(unsafe a.list(parts)[0]);
                                self.errors.emit(
                                    isp.start,
                                    isp.end - isp.start,
                                    format(
                                        "an interface is not a type; use '&dyn {}', 'Box<dyn {}>', or a generic bound",
                                        diag::span_str(self.source, isp.start, isp.end),
                                        diag::span_str(self.source, isp.start, isp.end),
                                    ),
                                );
                            }
                            if d.module == self.cur_module() {
                                for k in 1..parts.len {
                                    let pid = unsafe a.list(parts)[k as usize];
                                    let member = self.find_member(d.module, d.node, self.name_span(pid));
                                    if member != NODE_NONE {
                                        self.cur_ast().set_resolution(pid, member);
                                    }
                                }
                            }
                        }
                    }
                } else if parts.len > 0 {
                    let b = builtin_of(self.source, self.name_span(unsafe a.list(parts)[0]));
                    if b >= 0 {
                        result = Ast::builtin(b as BuiltinType);
                    } else {
                        result = TYPE_ERROR;
                    }
                }
            },
            NODE_SLICE_TYPE => {
                let it = a.at_const(id).as_data.indirect_type;
                result = self.prelude_slice_type(self.resolve_type(it.ty), it.qualifier == TypeQualifier::TYPE_QUAL_MUT);
            },
            NODE_TUPLE_TYPE => {
                let elems = a.at_const(id).as_data.array_literal.elements;
                if elems.len > 4 {
                    let sp = a.at_const(id).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("tuple arity is limited to 4 elements"));
                } else {
                    let mut targs = Tys8 {};
                    for i in 0..elems.len {
                        targs[i as usize] = self.resolve_type(unsafe a.list(elems)[i as usize]);
                    }
                    result = self.prelude_tuple_type(&targs[0], elems.len);
                }
            },
            NODE_POINTER_TYPE | NODE_REFERENCE_TYPE => {
                let it = a.at_const(id).as_data.indirect_type;
                let mut k = TypeKind::TYPE_REFERENCE;
                if nk == NodeKind::NODE_POINTER_TYPE {
                    k = TypeKind::TYPE_POINTER;
                }
                result = self.cur_ast().intern_type(
                    Ty { kind: k, qualifier: it.qualifier as u8, as_data: TyAs { elem: self.resolve_type(it.ty) } },
                );
            },
            NODE_ARRAY_TYPE => {
                let at = a.at_const(id).as_data.array_type;
                self.check_expr(at.length);
                let alen = self.ce_array_len(self.cur_module(), at.length);
                result = self.cur_ast().intern_type(
                    Ty {
                        kind: TypeKind::TYPE_ARRAY,
                        as_data: TyAs { arr: TyArr { elem: self.resolve_type(at.element), len: alen } },
                    },
                );
            },
            NODE_FUNCTION_TYPE => {
                result = self.cur_ast().intern_type(
                    Ty { kind: TypeKind::TYPE_FUNCTION, module: self.cur_module(), as_data: TyAs { decl: id } },
                );
            },
            NODE_DYN_TYPE => {
                let q = a.at_const(id).as_data.indirect_type.qualifier;
                if q == TypeQualifier::TYPE_QUAL_NONE {
                    let sp = a.at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a 'dyn' type must be '&dyn I', '&mut dyn I', or 'Box<dyn I>'"),
                    );
                } else {
                    result = self.resolve_dyn_node(id, q);
                }
            },
            _ => {},
        };
        self.cur_ast().set_type(id, result);
        return result;
    }

    // ---- dyn trait objects ----
    fn tc_intern_dynfn(self: &mut Self, m: ModuleId, sig: NodeId, qual: TypeQualifier) TypeId {
        let mysig = self.lower_type_in(m, sig);
        // TC-7: candidates come from dynfn_list instead of a full pool rescan. New pool entries
        // (including ones interned by the compares below) are absorbed before each compare, so the
        // candidate sequence is exactly the old in-order scan's.
        let mut idx: usize = 0;
        loop {
            while self.dynfn_scan as usize < unsafe self.cur_ast().type_pool.len() {
                let e = *self.type_at(self.dynfn_scan);
                if e.kind == TypeKind::TYPE_DYN && self.mod_ast(e.module).at_const(self.cur_ast().dyn_decl_of(&e)).kind == NodeKind::NODE_FUNCTION_TYPE {
                    self.dynfn_list.push(self.dynfn_scan);
                }
                self.dynfn_scan = self.dynfn_scan + 1;
            }
            if idx >= self.dynfn_list.len() {
                break;
            }
            let e = *self.type_at(self.dynfn_list[idx]);
            idx = idx + 1;
            let edecl = self.cur_ast().dyn_decl_of(&e);
            let esig = self.lower_type_in(e.module, edecl);
            if esig == mysig || self.fn_compatible(esig, mysig) {
                return self.cur_ast().intern_dyn(e.module, edecl, null, 0, qual as u8);
            }
        }
        return self.cur_ast().intern_dyn(m, sig, null, 0, qual as u8);
    }

    fn resolve_dyn_node(self: &mut Self, id: NodeId, qual: TypeQualifier) TypeId {
        let a = self.cur_ast();
        let inner = a.at_const(id).as_data.indirect_type.ty;
        let mut result = TYPE_ERROR;
        if a.at_const(inner).kind == NodeKind::NODE_FUNCTION_TYPE {
            let sp = a.at_const(id).span;
            let mut concrete = qual != TypeQualifier::TYPE_QUAL_MUT;
            if !concrete {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("a 'dyn fn' is always called through a shared view; write '&dyn fn(..) ..'"),
                );
            }
            let ftp = a.at_const(inner).as_data.function_type;
            let mut i: u32 = 0;
            while concrete && i < ftp.params.len {
                concrete = self.type_at(self.resolve_type(unsafe a.list(ftp.params)[i as usize])).kind != TypeKind::TYPE_GENERIC;
                i = i + 1;
            }
            i = 0;
            while concrete && i < ftp.returns.len {
                let rid = unsafe a.list(ftp.returns)[i as usize];
                let rn = a.at_const(rid);
                let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rid);
                concrete = self.type_at(self.resolve_type(tn)).kind != TypeKind::TYPE_GENERIC;
                i = i + 1;
            }
            if concrete {
                result = self.tc_intern_dynfn(self.cur_module(), inner, qual);
            } else if qual != TypeQualifier::TYPE_QUAL_MUT {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("a 'dyn fn' signature cannot name a generic parameter"),
                );
            }
            self.cur_ast().set_type(id, result);
            return result;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        if a.at_const(inner).kind == NodeKind::NODE_TYPE_PATH {
            d = a.resolution_def(inner);
        }
        let sp = a.at_const(id).span;
        if d.node == NODE_NONE || self.mod_ast(d.module).at_const(d.node).kind != NodeKind::NODE_INTERFACE {
            self.errors.emit(sp.start, sp.end - sp.start, format("'dyn' requires an interface"));
        } else {
            // `dyn I<T, ..>`: lower the type-path arguments and check the count against the
            // interface's generic parameters (zero args for a plain interface)
            let targs = a.at_const(inner).as_data.type_path.args;
            let ig = self.mod_ast(d.module).at_const(d.node).as_data.interface_def.generics;
            let mut na = Tys8 {};
            let mut nn: u8 = 0;
            for ti in 0..targs.len {
                if nn < 8 {
                    na[nn as usize] = self.resolve_type(unsafe a.list(targs)[ti as usize]);
                    nn = nn + 1;
                }
            }
            if targs.len != ig.len {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("interface expects {} type argument(s), got {}", ig.len, targs.len),
                );
            } else if self.dyn_compatible(d, sp) {
                result = self.cur_ast().intern_dyn(d.module, d.node, &na[0], nn, qual as u8);
            }
        }
        self.cur_ast().set_type(id, result);
        return result;
    }

    const fn dyn_method(self: &Self, imod: ModuleId, mnode: NodeId) bool {
        let ia = self.mod_ast(imod);
        let mn = ia.at_const(mnode);
        if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
            return false;
        }
        let p0 = unsafe ia.list(mn.as_data.function.params)[0];
        let pnm = ia.at_const(ia.at_const(p0).as_data.parameter.name).as_data.name.text;
        return span_is(self.mod_src(imod), pnm, "self");
    }

    fn tc_mentions_self(self: &Self, imod: ModuleId, tn: NodeId, iface: DefId) bool {
        if tn == NODE_NONE {
            return false;
        }
        let ia = self.mod_ast(imod);
        let n = ia.at_const(tn);
        if n.kind == NodeKind::NODE_TYPE_PATH {
            let d = ia.resolution_def(tn);
            if d.module == iface.module && d.node == iface.node {
                return true;
            }
            let args = n.as_data.type_path.args;
            for i in 0..args.len {
                if self.tc_mentions_self(imod, unsafe ia.list(args)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        if n.kind == NodeKind::NODE_POINTER_TYPE || n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE || n.kind == NodeKind::NODE_DYN_TYPE {
            return self.tc_mentions_self(imod, n.as_data.indirect_type.ty, iface);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.tc_mentions_self(imod, n.as_data.array_type.element, iface);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let elems = n.as_data.array_literal.elements;
            for i in 0..elems.len {
                if self.tc_mentions_self(imod, unsafe ia.list(elems)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        if n.kind == NodeKind::NODE_FUNCTION_TYPE {
            let ft = n.as_data.function_type;
            for i in 0..ft.params.len {
                if self.tc_mentions_self(imod, unsafe ia.list(ft.params)[i as usize], iface) {
                    return true;
                }
            }
            for i in 0..ft.returns.len {
                if self.tc_mentions_self(imod, unsafe ia.list(ft.returns)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    // The transitive superinterface closure of `iface` (itself first), deduped, depth-capped.
    fn dyn_super_closure(self: &mut Self, iface: DefId, out: *mut DefId, cap: i32) i32 {
        let mut n: i32 = 0;
        unsafe out[0] = iface;
        n = 1;
        let mut scan: i32 = 0;
        while scan < n {
            let cur = unsafe out[scan as usize];
            let ca = self.mod_ast(cur.module);
            let bs = ca.at_const(cur.node).as_data.interface_def.bounds;
            for b in 0..bs.len {
                let bd = ca.resolution_def(unsafe ca.list(bs)[b as usize]);
                if bd.node == NODE_NONE || self.mod_ast(bd.module).at_const(bd.node).kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                let mut dup = false;
                for k in 0..n {
                    if unsafe out[k as usize].module == bd.module && unsafe out[k as usize].node == bd.node {
                        dup = true;
                    }
                }
                if !dup && n < cap {
                    unsafe out[n as usize] = bd;
                    n = n + 1;
                }
            }
            scan = scan + 1;
        }
        return n;
    }

    fn dyn_compatible(self: &mut Self, iface: DefId, at: tok::Span) bool {
        let ia = self.mod_ast(iface.module);
        let isrc = self.mod_src(iface.module);
        let idn = ia.at_const(iface.node).as_data.interface_def;
        let mut why: str = "";
        let mut mn = tok::Span { start: 0, end: 0 };
        // validate the whole superinterface closure: every method of every interface in it is
        // dispatched through the SAME vtable (inherited methods are named fields), so each must
        // be dyn-able and no two may share a name (they would collide as C struct fields)
        let mut clo = Defs8 {};
        let nclo = self.dyn_super_closure(iface, &mut clo[0], 8);
        let mut ci: i32 = 0;
        while why.len() == 0 && ci < nclo {
            let cd = clo[ci as usize];
            let ca = self.mod_ast(cd.module);
            let cdn = ca.at_const(cd.node).as_data.interface_def;
            if cdn.generics.len != 0 && ci != 0 {
                // the root interface's generics are instantiated by the `dyn I<..>` arguments;
                // generic SUPERinterfaces are not wired up yet
                why = "a superinterface has generic parameters";
                break;
            }
            for mi in 0..cdn.items.len {
                let mid0 = unsafe ca.list(cdn.items)[mi as usize];
                if !self.dyn_method(cd.module, mid0) {
                    continue;
                }
                let nm0 = ca.at_const(ca.at_const(mid0).as_data.function.name).as_data.name.text;
                let mut cj: i32 = 0;
                while why.len() == 0 && cj < ci {
                    let od = clo[cj as usize];
                    let oa = self.mod_ast(od.module);
                    let odn = oa.at_const(od.node).as_data.interface_def;
                    for oi in 0..odn.items.len {
                        let omid = unsafe oa.list(odn.items)[oi as usize];
                        if self.dyn_method(od.module, omid) && spans_eq2(
                            self.mod_src(cd.module),
                            nm0,
                            self.mod_src(od.module),
                            oa.at_const(oa.at_const(omid).as_data.function.name).as_data.name.text,
                        ) {
                            why = "two methods in the superinterface hierarchy share a name";
                            mn = nm0;
                        }
                    }
                    cj = cj + 1;
                }
            }
            ci = ci + 1;
        }
        let mut cx: i32 = 0;
        while why.len() == 0 && cx < nclo {
            if !self.dyn_iface_methods_ok(clo[cx as usize], &mut why, &mut mn) {
                break;
            }
            cx = cx + 1;
        }
        if why.len() == 0 {
            return true;
        }
        let inm = ia.at_const(idn.name).as_data.name.text;
        self.errors.emit(
            at.start,
            at.end - at.start,
            format("interface '{}' is not dyn-compatible: {}", diag::span_str(isrc, inm.start, inm.end), why),
        );
        if mn.end > mn.start {
            self.errors.note(format("offending method: '{}'", diag::span_str(isrc, mn.start, mn.end)));
        }
        return false;
    }

    // Per-interface dyn-ability of every method; on failure sets `why`/`mn` and returns false.
    fn dyn_iface_methods_ok(self: &mut Self, iface: DefId, why: &mut str, mnp: &mut tok::Span) bool {
        let ia = self.mod_ast(iface.module);
        let idn = ia.at_const(iface.node).as_data.interface_def;
        let mut i: u32 = 0;
        while why.len() == 0 && i < idn.items.len {
            let mid = unsafe ia.list(idn.items)[i as usize];
            if self.dyn_method(iface.module, mid) {
                let m = ia.at_const(mid).as_data.function;
                *mnp = ia.at_const(m.name).as_data.name.text;
                let p0 = unsafe ia.list(m.params)[0];
                let st = ia.at_const(p0).as_data.parameter.ty;
                let mut sk = NodeKind::NODE_NONE_KIND;
                if st != NODE_NONE {
                    sk = ia.at_const(st).kind;
                }
                if m.generics.len != 0 {
                    *why = "a method has its own generic parameters";
                } else if sk != NodeKind::NODE_REFERENCE_TYPE && sk != NodeKind::NODE_POINTER_TYPE {
                    *why = "a method takes 'Self' by value";
                } else if m.returns.len > 1 {
                    *why = "a method has multiple return values";
                }
                let mut p: u32 = 1;
                while why.len() == 0 && p < m.params.len {
                    let pid = unsafe ia.list(m.params)[p as usize];
                    if self.tc_mentions_self(iface.module, ia.at_const(pid).as_data.parameter.ty, iface) {
                        *why = "a method mentions 'Self' outside the receiver";
                    }
                    p = p + 1;
                }
                let mut r: u32 = 0;
                while why.len() == 0 && r < m.returns.len {
                    let rid = unsafe ia.list(m.returns)[r as usize];
                    let rn = ia.at_const(rid);
                    let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rid);
                    if self.tc_mentions_self(iface.module, tn, iface) {
                        *why = "a method mentions 'Self' outside the receiver";
                    }
                    r = r + 1;
                }
            }
            i = i + 1;
        }
        return why.len() == 0;
    }

    // ---- extension / method lookup ----
    fn ext_scopes(self: &mut Self) i32 {
        if self.n_ext_scope < 0 {
            self.ext_scope.clear();
            self.ext_scope.push(self.cur_module());
            if self.package != null {
                let closure = self.package.import_closure(self.cur_module());
                for i in 0..closure.len() {
                    self.ext_scope.push(closure[i]);
                }
            }
            self.n_ext_scope = self.ext_scope.len() as i32;
        }
        return self.n_ext_scope;
    }
    const fn ext_scope_at(self: &Self, i: i32) ModuleId {
        return self.ext_scope[i as usize];
    }

    // Build (once) module `mm`'s list of top-level EXTEND item ids. No type interning happens here, so it is
    // safe to build lazily at any point during type-checking.
    fn ensure_ext_items(self: &mut Self, mm: ModuleId) {
        let idx = mm as usize;
        while self.ext_items.len() <= idx {
            self.ext_items.push(Vector::<NodeId>::new());
        }
        while self.ext_items_built.len() <= idx {
            self.ext_items_built.push(false);
        }
        if self.ext_items_built[idx] {
            return;
        }
        self.ext_items_built[idx] = true;
        let a = self.mod_ast(mm);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
                self.ext_items[idx].push(iid);
            }
        }
    }
    const fn ext_items_len(self: &Self, mm: ModuleId) usize {
        return self.ext_items[mm as usize].len();
    }
    const fn ext_items_at(self: &Self, mm: ModuleId, i: usize) NodeId {
        return self.ext_items[mm as usize][i];
    }

    /// The type-identity an extend's target dispatches on (peeling a transparent alias).
    pub fn tc_peel_target(self: &mut Self, tg: DefId) DefId {
        if tg.node == NODE_NONE {
            return tg;
        }
        // TC-12: peel is a pure function of frozen decls; the uncached path's named_type_of
        // interning happens on the first peel, so pool order is unchanged.
        let pk = tg.module as u64 << 32 | tg.node as u64;
        switch self.peel_memo.get(&pk) {
            Some(v) => {
                return DefId { module: (*v >> 32) as ModuleId, node: (*v) as NodeId };
            },
            None => {},
        };
        let r = self.tc_peel_target_uncached(tg);
        self.peel_memo.insert(pk, r.module as u64 << 32 | r.node as u64);
        return r;
    }
    fn tc_peel_target_uncached(self: &mut Self, tg: DefId) DefId {
        let dn = *self.mod_ast(tg.module).at_const(tg.node);
        if dn.kind != NodeKind::NODE_TYPE_ALIAS || dn.as_data.type_alias.ty == NODE_NONE || dn.as_data.type_alias.generics.len != 0 {
            return tg;
        }
        let ty = *self.type_at(self.named_type_of(tg.module, tg.node));
        if ty.kind == TypeKind::TYPE_BUILTIN {
            let mut bd = NODE_NONE;
            if self.package != null {
                bd = self.package.builtin_decl(ty.as_data.builtin);
            }
            if bd != NODE_NONE {
                return DefId { module: unsafe self.package.core_module, node: bd };
            }
            return tg;
        }
        if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            return DefId { module: ty.module, node: ty.as_data.decl };
        }
        if ty.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.cur_ast().instance(ty.as_data.inst);
            return DefId { module: it.module, node: it.decl };
        }
        return tg;
    }

    fn find_member(self: &Self, m: ModuleId, decl: NodeId, name: tok::Span) NodeId {
        let a = self.mod_ast(m);
        let src = self.mod_src(m);
        let d = a.at_const(decl);
        if d.kind != NodeKind::NODE_STRUCT && d.kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let members = d.as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe a.list(members)[i as usize];
            let mem = a.at_const(mid);
            let mname = if_node(mem.kind == NodeKind::NODE_FIELD, mem.as_data.field.name, mem.as_data.variant.name);
            if spans_eq2(self.source, name, src, a.at_const(mname).as_data.name.text) {
                return mid;
            }
        }
        return NODE_NONE;
    }
    fn find_member_cstr(self: &Self, m: ModuleId, decl: NodeId, name: str) NodeId {
        let a = self.mod_ast(m);
        let src = self.mod_src(m);
        let d = a.at_const(decl);
        if d.kind != NodeKind::NODE_STRUCT && d.kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let members = d.as_data.aggregate.members;
        let nl = name.len();
        for i in 0..members.len {
            let mid = unsafe a.list(members)[i as usize];
            let mem = a.at_const(mid);
            let mname = if_node(mem.kind == NodeKind::NODE_FIELD, mem.as_data.field.name, mem.as_data.variant.name);
            let sp = a.at_const(mname).as_data.name.text;
            if (sp.end - sp.start) as usize == nl && unsafe cstring::memcmp(
                src.ptr() + sp.start as usize,
                name.ptr(),
                nl,
            ) == 0 {
                return mid;
            }
        }
        return NODE_NONE;
    }

    // TC-8: both lookups are memoized -- callers re-resolve the same method's owner repeatedly
    // (tc_method_param + tc_method_ret alone scan twice per operator check). Lazy insert through a
    // const-cast, the codebase's established pattern for caches behind &Self.
    fn enclosing_extend(self: &Self, m: ModuleId, method: NodeId) NodeId {
        let key = m as u64 << 32 | method as u64;
        switch self.encl_ext_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let a = self.mod_ast(m);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        let mut res = NODE_NONE;
        let mut i: u32 = 0;
        while i < items.len && res == NODE_NONE {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
                let ms = a.at_const(iid).as_data.extend_def.items;
                for j in 0..ms.len {
                    if unsafe a.list(ms)[j as usize] == method {
                        res = iid;
                        break;
                    }
                }
            }
            i = i + 1;
        }
        let mself = (self as *const TypeChecker) as *mut TypeChecker;
        unsafe mself.encl_ext_memo.insert(key, res);
        return res;
    }
    fn enclosing_trait(self: &Self, m: ModuleId, method: NodeId) NodeId {
        let key = m as u64 << 32 | method as u64;
        switch self.encl_trait_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let a = self.mod_ast(m);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        let mut res = NODE_NONE;
        let mut i: u32 = 0;
        while i < items.len && res == NODE_NONE {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_INTERFACE {
                let ms = a.at_const(iid).as_data.interface_def.items;
                for j in 0..ms.len {
                    if unsafe a.list(ms)[j as usize] == method {
                        res = iid;
                        break;
                    }
                }
            }
            i = i + 1;
        }
        let mself = (self as *const TypeChecker) as *mut TypeChecker;
        unsafe mself.encl_trait_memo.insert(key, res);
        return res;
    }

    // Method names codegen can synthesize calls to WITHOUT a type-checked call node (assert/format
    // templates, auto-free, operator/index/for lowering, `?` conversions). Marks on these must stay
    // unconditional -- they can be referenced from emitted C that no tc-visible caller explains.
    const fn tc_mark_always_root(self: &Self, d: DefId) bool {
        let a = self.mod_ast(d.module);
        let f = a.at_const(d.node);
        if f.kind != NodeKind::NODE_FUNCTION {
            return true;
        }
        let nm = a.at_const(f.as_data.function.name).as_data.name.text;
        let s = self.mod_src(d.module);
        return span_is(s, nm, "free") || span_is(s, nm, "eq") || span_is(s, nm, "cmp") || span_is(s, nm, "index") || span_is(
            s,
            nm,
            "index_mut",
        ) || span_is(s, nm, "index_range") || span_is(s, nm, "index_range_mut") || span_is(s, nm, "len") || span_is(
            s,
            nm,
            "next",
        ) || span_is(s, nm, "from") || span_is(s, nm, "try_from") || span_is(s, nm, "as_str") || span_is(s, nm, "new") || span_is(
            s,
            nm,
            "print",
        ) || span_is(s, nm, "eprint") || span_is(s, nm, "pad_at") || span_is(s, nm, "push_str") || span_is(
            s,
            nm,
            "push_byte",
        ) || span_is(s, nm, "push_bin") || span_is(s, nm, "push_hex") || span_is(s, nm, "push_hex_i64") || span_is(
            s,
            nm,
            "push_i64",
        ) || span_is(s, nm, "push_u64") || span_is(s, nm, "push_f64") || span_is(s, nm, "push_f64_prec") || span_is(
            s,
            nm,
            "push_padded",
        );
    }
    // Route a method-used mark through its calling context. Inside a non-generic method of a plain
    // generic extend -- exactly the shape codegen's demand-gate prunes -- the mark becomes a
    // caller->callee edge resolved after typechecking, so callees kept alive only by never-emitted
    // methods are pruned too. Every other context (top-level code, conformance/interface methods,
    // generic methods, @emit_macro targets: all emitted unconditionally) marks directly, as before.
    fn tc_mark_method_used(self: &mut Self, d: DefId) {
        if self.package == null {
            return;
        }
        // Recorded before the early return below: the demand this stands for is per (instance, method),
        // and the first mark settles only the instance it was reached through.
        if d.node != NODE_NONE {
            let r = self.mark_recv;
            if r == TYPE_NONE {
                unsafe self.package.always_methods.insert(d.module as u64 << 32 | d.node as u64);
            } else {
                let cf = self.current_fn;
                unsafe self.cur_ast().method_refs.push(MethodRef { owner: cf, recv: r, callee: d });
            }
        }
        // Marks repeat heavily (memoized lookups re-fire them): once the callee is already used,
        // both the direct mark and the edge are no-ops -- skip the context classification.
        if self.package.method_used_get(d) {
            return;
        }
        let cf = self.current_fn;
        if cf != NODE_NONE {
            let m = self.cur_module();
            let ext = self.enclosing_extend(m, cf);
            if ext != NODE_NONE {
                let a = self.mod_ast(m);
                let ed = a.at_const(ext).as_data.extend_def;
                if ed.generics.len != 0 && ed.interface_type == NODE_NONE && ed.target_type != NODE_NONE && a.at_const(
                    cf,
                ).as_data.function.generics.len == 0 && !self.tc_mark_always_root(d) {
                    let tg = self.tc_peel_target(a.resolution_def(ed.target_type));
                    if tg.node != NODE_NONE && self.tc_attr(tg.module, tg.node, AttrKind::ATTR_EMIT_MACRO) == null {
                        self.package.record_method_edge(DefId { module: m, node: cf }, d);
                        return;
                    }
                }
            }
        }
        self.package.mark_method_used(d);
    }

    // Find a method named `name`/`lit` in an extend of (m,decl); marks it used. Searches the type's home
    // module, then the current module + imports.
    fn find_method_impl(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span, lit: str) DefId {
        // TC-11: memoized by (target, name content), misses included; a hit re-fires the
        // idempotent mark_method_used exactly as the scan's hit path did. Only span-form queries
        // are memoized: a span slices self.source (stable for the checker's life), while a caller's
        // `lit` may view a stack buffer (e.g. dyn_coerce_alloc) that dies before the next lookup.
        if lit.len() != 0 {
            return self.find_method_scan(m, decl, name, lit);
        }
        let mq = MQKey { m: m, decl: decl, kind: 0, name: self.source.slice(name.start as usize, name.end as usize) };
        switch self.method_memo.get(&mq) {
            Some(v) => {
                let d = DefId { module: (*v >> 32) as ModuleId, node: (*v) as NodeId };
                if d.node != NODE_NONE {
                    self.tc_mark_method_used(d);
                }
                return d;
            },
            None => {},
        };
        let r = self.find_method_scan(m, decl, name, lit);
        self.method_memo.insert(mq, r.module as u64 << 32 | r.node as u64);
        return r;
    }
    fn find_method_scan(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span, lit: str) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut mm = m;
            if s >= 0 {
                mm = self.ext_scope_at(s);
            }
            if s >= 0 && mm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(mm);
            let a = self.mod_ast(mm);
            let ne = self.ext_items_len(mm);
            for i in 0..ne {
                let iid = self.ext_items_at(mm, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = a.at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let mid = unsafe a.list(ms)[j as usize];
                            let mn = a.at_const(mid);
                            // Privacy: a method from another module must be `pub` (mirrors find_assoc_const).
                            if mn.kind == NodeKind::NODE_FUNCTION && !(mm != self.cur_module() && !mn.as_data.function.is_public) {
                                let mname = a.at_const(mn.as_data.function.name).as_data.name.text;
                                let mut hit = false;
                                if lit.len() != 0 {
                                    hit = span_is(self.mod_src(mm), mname, lit);
                                } else {
                                    hit = spans_eq2(self.source, name, self.mod_src(mm), mname);
                                }
                                if hit {
                                    self.tc_mark_method_used(DefId { module: mm, node: mid });
                                    return DefId { module: mm, node: mid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn find_method(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span) DefId {
        return self.find_method_impl(m, decl, name, "");
    }

    // Every method named `name` on (m, decl) across the extend scopes -- the un-memoized collector
    // behind overload disambiguation. Only runs when a first candidate's return type did not fit the
    // expected type, so the common single-candidate path never pays for it.
    fn find_method_all(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span, out: &mut Defs8) i32 {
        let ni = self.ext_scopes();
        let mut nout: i32 = 0;
        let mut s: i32 = -1;
        while s < ni {
            let mut mm = m;
            if s >= 0 {
                mm = self.ext_scope_at(s);
            }
            if s >= 0 && mm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(mm);
            let a = self.mod_ast(mm);
            let ne = self.ext_items_len(mm);
            for i in 0..ne {
                let iid = self.ext_items_at(mm, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                if tg.module != m || tg.node != decl {
                    continue;
                }
                let ms = a.at_const(iid).as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe a.list(ms)[j as usize];
                    let mn = a.at_const(mid);
                    if mn.kind != NodeKind::NODE_FUNCTION || mm != self.cur_module() && !mn.as_data.function.is_public {
                        continue;
                    }
                    if spans_eq2(
                        self.source,
                        name,
                        self.mod_src(mm),
                        a.at_const(mn.as_data.function.name).as_data.name.text,
                    ) && nout as usize < out.len() {
                        out[nout as usize] = DefId { module: mm, node: mid };
                        nout = nout + 1;
                    }
                }
            }
            s = s + 1;
        }
        return nout;
    }

    // Several extends may define the same method name through different interface conformances
    // (`extend X as Conv<i32>` and `as Conv<bool>` both provide `conv`). find_method is memoized by
    // (target, name) and yields whichever is found first; when the EXPECTED type at this use is known
    // and that first candidate's return does not produce it while another candidate's does, resolve to
    // the one that fits. With no expected type the first candidate stands, as before.
    fn tc_pick_method_overload(
        self: &mut Self,
        m: ModuleId,
        decl: NodeId,
        name: tok::Span,
        first: DefId,
        recv: TypeId,
        want: TypeId,
    ) DefId {
        if first.node == NODE_NONE || want == TYPE_NONE || recv == TYPE_NONE {
            return first;
        }
        if self.tc_method_ret(self.strip(recv), first) == want {
            return first;
        }
        let mut cands = Defs8 {};
        let n = self.find_method_all(m, decl, name, &mut cands);
        if n < 2 {
            return first;
        }
        for i in 0..n {
            let c = cands[i as usize];
            if c.module == first.module && c.node == first.node {
                continue;
            }
            if self.tc_method_ret(self.strip(recv), c) == want {
                self.mark_recv = self.strip(recv); // the overload search bypassed aggregate_of
                self.tc_mark_method_used(c);
                return c;
            }
        }
        return first;
    }
    fn find_method_cstr(self: &mut Self, m: ModuleId, decl: NodeId, lit: str) DefId {
        return self.find_method_impl(m, decl, tok::Span::empty(), lit);
    }

    fn find_assoc_const(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span) DefId {
        // TC-11 (kind 1): same memo, no used-marking on this query family.
        let mq = MQKey { m: m, decl: decl, kind: 1, name: self.source.slice(name.start as usize, name.end as usize) };
        switch self.method_memo.get(&mq) {
            Some(v) => {
                return DefId { module: (*v >> 32) as ModuleId, node: (*v) as NodeId };
            },
            None => {},
        };
        let r = self.find_assoc_const_scan(m, decl, name);
        self.method_memo.insert(mq, r.module as u64 << 32 | r.node as u64);
        return r;
    }
    fn find_assoc_const_scan(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut sm = m;
            if s >= 0 {
                sm = self.ext_scope_at(s);
            }
            if s >= 0 && sm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(sm);
            let a = self.mod_ast(sm);
            let ne = self.ext_items_len(sm);
            for i in 0..ne {
                let iid = self.ext_items_at(sm, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.generics.len == 0 {
                    let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = a.at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let cid = unsafe a.list(ms)[j as usize];
                            let cn = a.at_const(cid);
                            if cn.kind == NodeKind::NODE_CONST && !(sm != self.cur_module() && !cn.as_data.const_def.is_public) {
                                if spans_eq2(
                                    self.source,
                                    name,
                                    self.mod_src(sm),
                                    a.at_const(cn.as_data.const_def.name).as_data.name.text,
                                ) {
                                    return DefId { module: sm, node: cid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn find_extend_as(self: &mut Self, tmod: ModuleId, tdecl: NodeId, iface: DefId, imod: *mut ModuleId) NodeId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut m = tmod;
            if s >= 0 {
                m = self.ext_scope_at(s);
            }
            if s >= 0 && m == tmod {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(m);
            let a = self.mod_ast(m);
            let ne = self.ext_items_len(m);
            for i in 0..ne {
                let iid = self.ext_items_at(m, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                    let tr = a.resolution_def(it.as_data.extend_def.interface_type);
                    let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                    if tr.module == iface.module && tr.node == iface.node && tg.module == tmod && tg.node == tdecl {
                        unsafe *imod = m;
                        return iid;
                    }
                }
            }
            s = s + 1;
        }
        return NODE_NONE;
    }

    fn find_interface_method(self: &Self, m: ModuleId, iface: NodeId, name: tok::Span, depth: i32) DefId {
        if depth > 8 {
            return DefId { module: 0, node: NODE_NONE };
        }
        let a = self.mod_ast(m);
        let tn = a.at_const(iface);
        if tn.kind != NodeKind::NODE_INTERFACE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let items = tn.as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe a.list(items)[i as usize];
            let mn = a.at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && spans_eq2(
                self.source,
                name,
                self.mod_src(m),
                a.at_const(mn.as_data.function.name).as_data.name.text,
            ) {
                return DefId { module: m, node: mid };
            }
        }
        let bounds = tn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            let bid = unsafe a.list(bounds)[i as usize];
            let sb = a.resolution_def(bid);
            if sb.node != NODE_NONE {
                let r = self.find_interface_method(sb.module, sb.node, name, depth + 1);
                if r.node != NODE_NONE {
                    return r;
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn find_default_method(self: &mut Self, tmod: ModuleId, tdecl: NodeId, name: tok::Span) DefId {
        // TC-11 (kind 2): same memo; find_interface_method reads only frozen interface bodies.
        let mq = MQKey {
            m: tmod,
            decl: tdecl,
            kind: 2,
            name: self.source.slice(name.start as usize, name.end as usize),
        };
        switch self.method_memo.get(&mq) {
            Some(v) => {
                return DefId { module: (*v >> 32) as ModuleId, node: (*v) as NodeId };
            },
            None => {},
        };
        let r = self.find_default_method_scan(tmod, tdecl, name);
        self.method_memo.insert(mq, r.module as u64 << 32 | r.node as u64);
        return r;
    }
    fn find_default_method_scan(self: &mut Self, tmod: ModuleId, tdecl: NodeId, name: tok::Span) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut m = tmod;
            if s >= 0 {
                m = self.ext_scope_at(s);
            }
            if s >= 0 && m == tmod {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(m);
            let a = self.mod_ast(m);
            let ne = self.ext_items_len(m);
            for i in 0..ne {
                let iid = self.ext_items_at(m, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.interface_type != NODE_NONE {
                    let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == tmod && tg.node == tdecl {
                        let iff = a.resolution_def(it.as_data.extend_def.interface_type);
                        if iff.node != NODE_NONE {
                            let mth = self.find_interface_method(iff.module, iff.node, name, 0);
                            if mth.node != NODE_NONE && self.mod_ast(mth.module).at_const(mth.node).as_data.function.body != NODE_NONE {
                                return mth;
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn add_bound_ifaces_full(
        self: &mut Self,
        m: ModuleId,
        bounds: NodeList,
        out: *mut BoundIface,
        n: *mut i32,
        cap: i32,
    ) {
        let a = self.mod_ast(m);
        let mut i: u32 = 0;
        while i < bounds.len && unsafe *n < cap {
            let bid = unsafe a.list(bounds)[i as usize];
            let d = a.resolution_def(bid);
            if d.node != NODE_NONE {
                let mut b = BoundIface { iface: d, n: 0 };
                if a.at_const(bid).kind == NodeKind::NODE_TYPE_PATH {
                    let aids = a.at_const(bid).as_data.type_path.args;
                    let mut k: u32 = 0;
                    while k < aids.len && b.n < 8 {
                        unsafe b.args[b.n as usize] = self.lower_type_in(m, unsafe a.list(aids)[k as usize]);
                        b.n = b.n + 1;
                        k = k + 1;
                    }
                }
                let idx = unsafe *n;
                unsafe out[idx as usize] = b;
                unsafe *n = idx + 1;
            }
            i = i + 1;
        }
    }
    fn collect_param_bounds_full(self: &mut Self, pmod: ModuleId, pdecl: NodeId, out: *mut BoundIface, cap: i32) i32 {
        let mut n: i32 = 0;
        let pa = self.mod_ast(pmod);
        self.add_bound_ifaces_full(pmod, pa.at_const(pdecl).as_data.generic_param.bounds, out, &mut n, cap);
        if pmod == self.cur_module() && self.current_fn != NODE_NONE {
            let wc = self.cur_ast().at_const(self.current_fn).as_data.function.where_clause;
            for w in 0..wc.len {
                let wid = unsafe self.cur_ast().list(wc)[w as usize];
                let wp = self.cur_ast().at_const(wid).as_data.where_predicate;
                if self.cur_ast().resolution(wp.ty) == pdecl {
                    self.add_bound_ifaces_full(self.cur_module(), wp.bounds, out, &mut n, cap);
                }
            }
        }
        return n;
    }
    fn trait_contains_method(self: &Self, iface: DefId, method: DefId, depth: i32) bool {
        if iface.node == NODE_NONE || depth > 8 {
            return false;
        }
        let ia = self.mod_ast(iface.module);
        let idn = ia.at_const(iface.node);
        if idn.kind != NodeKind::NODE_INTERFACE {
            return false;
        }
        let items = idn.as_data.interface_def.items;
        for i in 0..items.len {
            if iface.module == method.module && unsafe ia.list(items)[i as usize] == method.node {
                return true;
            }
        }
        let bounds = idn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            if self.trait_contains_method(ia.resolution_def(unsafe ia.list(bounds)[i as usize]), method, depth + 1) {
                return true;
            }
        }
        return false;
    }
    fn bound_method_subst(
        self: &mut Self,
        pmod: ModuleId,
        pdecl: NodeId,
        method: DefId,
        outp: *mut DefId,
        outa: *mut TypeId,
        cap: i32,
    ) i32 {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, &mut ifaces[0], 8);
        for i in 0..ni {
            if self.trait_contains_method(ifaces[i as usize].iface, method, 0) {
                let ia = self.mod_ast(ifaces[i as usize].iface.module);
                let gens = ia.at_const(ifaces[i as usize].iface.node).as_data.interface_def.generics;
                let mut n: i32 = 0;
                let mut g: u32 = 0;
                while g < gens.len && g as u8 < ifaces[i as usize].n && n < cap {
                    let gid = unsafe ia.list(gens)[g as usize];
                    unsafe outp[n as usize] = DefId { module: ifaces[i as usize].iface.module, node: gid };
                    unsafe outa[n as usize] = unsafe ifaces[i as usize].args[g as usize];
                    n = n + 1;
                    g = g + 1;
                }
                return n;
            }
        }
        return 0;
    }
    fn find_bound_method(self: &mut Self, pmod: ModuleId, pdecl: NodeId, name: tok::Span, iface: *mut DefId) DefId {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, &mut ifaces[0], 8);
        for b in 0..ni {
            let id = ifaces[b as usize].iface;
            let m = self.find_interface_method(id.module, id.node, name, 0);
            if m.node != NODE_NONE {
                if iface != null {
                    unsafe *iface = id;
                }
                return m;
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn interface_declares_cstr(self: &Self, iface: DefId, m: str, depth: i32) bool {
        if depth > 8 || iface.node == NODE_NONE {
            return false;
        }
        let a = self.mod_ast(iface.module);
        let idn = a.at_const(iface.node);
        if idn.kind != NodeKind::NODE_INTERFACE {
            return false;
        }
        let items = idn.as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe a.list(items)[i as usize];
            let mn = a.at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                self.mod_src(iface.module),
                a.at_const(mn.as_data.function.name).as_data.name.text,
                m,
            ) {
                return true;
            }
        }
        let bounds = idn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            if self.interface_declares_cstr(a.resolution_def(unsafe a.list(bounds)[i as usize]), m, depth + 1) {
                return true;
            }
        }
        return false;
    }
    fn tc_param_bound_provides(self: &mut Self, pmod: ModuleId, pdecl: NodeId, m: str) bool {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, &mut ifaces[0], 8);
        for b in 0..ni {
            if self.interface_declares_cstr(ifaces[b as usize].iface, m, 0) {
                return true;
            }
        }
        return false;
    }

    fn type_satisfies(self: &mut Self, ty: TypeId, iface: DefId, depth: i32) bool {
        if ty == TYPE_NONE || ty == TYPE_ERROR || depth > BOUND_MAX_DEPTH {
            return true;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            let mut dclo = Defs8 {};
            let nd = self.dyn_super_closure(
                DefId { module: y.module, node: self.cur_ast().dyn_decl_of(&y) },
                &mut dclo[0],
                8,
            );
            for di in 0..nd {
                if dclo[di as usize].module == iface.module && dclo[di as usize].node == iface.node {
                    return true;
                }
            }
            return false;
        }
        // Send / Sync are STRUCTURAL markers: no explicit `extend` is required (an explicit one is honored
        // below as an unsafe override). Answer them from the type's shape -- this handles pointers /
        // references / closures / slices that the aggregate path below cannot even name.
        if self.is_send_iface(iface) {
            return self.tc_thread_marker(ty, false, depth);
        }
        if self.is_sync_iface(iface) {
            return self.tc_thread_marker(ty, true, depth);
        }
        let mut tmod: ModuleId = 0;
        let mut tdecl = NODE_NONE;
        let mut iargs = Tys8 {};
        let mut in2: i32 = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            tmod = y.module;
            tdecl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = *self.cur_ast().instance(y.as_data.inst);
            tmod = inst.module;
            tdecl = inst.decl;
            let mut k: u8 = 0;
            while k < inst.n && in2 < 8 {
                iargs[in2 as usize] = unsafe inst.args[k as usize];
                in2 = in2 + 1;
                k = k + 1;
            }
        } else if y.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = self.package.builtin_decl(y.as_data.builtin);
            if bd == NODE_NONE {
                return false;
            }
            tmod = unsafe self.package.core_module;
            tdecl = bd;
        } else {
            return false;
        }
        let mut imod: ModuleId = 0;
        let extnode = self.find_extend_as(tmod, tdecl, iface, &mut imod);
        if extnode == NODE_NONE {
            return false;
        }
        let ia = self.mod_ast(imod);
        let gens = ia.at_const(extnode).as_data.extend_def.generics;
        let mut g: u32 = 0;
        while g < gens.len && g as i32 < in2 {
            let gid = unsafe ia.list(gens)[g as usize];
            let gb = ia.at_const(gid).as_data.generic_param.bounds;
            for b in 0..gb.len {
                let gbi = ia.resolution_def(unsafe ia.list(gb)[b as usize]);
                if gbi.node != NODE_NONE && !self.type_satisfies(iargs[g as usize], gbi, depth + 1) {
                    return false;
                }
            }
            g = g + 1;
        }
        return true;
    }

    const fn is_free_iface(self: &Self, tr: DefId) bool {
        if tr.node == NODE_NONE {
            return false;
        }
        let trn = self.mod_ast(tr.module).at_const(tr.node);
        return trn.kind == NodeKind::NODE_INTERFACE && span_is(
            self.mod_src(tr.module),
            self.mod_ast(tr.module).at_const(trn.as_data.interface_def.name).as_data.name.text,
            "Free",
        );
    }
    const fn iface_named(self: &Self, tr: DefId, name: str) bool {
        if tr.node == NODE_NONE {
            return false;
        }
        let trn = self.mod_ast(tr.module).at_const(tr.node);
        return trn.kind == NodeKind::NODE_INTERFACE && span_is(
            self.mod_src(tr.module),
            self.mod_ast(tr.module).at_const(trn.as_data.interface_def.name).as_data.name.text,
            name,
        );
    }
    const fn is_send_iface(self: &Self, tr: DefId) bool {
        return self.iface_named(tr, "Send");
    }
    // True while checking a method of the prelude `UnsafeCell` -- the one place `&T as *mut T` is allowed
    // (its `get` is the sanctioned interior-mutability hole).
    fn in_unsafe_cell(self: &Self) bool {
        if self.package == null || self.current_self == NODE_NONE {
            return false;
        }
        let hit = self.package.prelude_lookup("UnsafeCell", true);
        return hit.node != NODE_NONE && unsafe self.cur_ast().module == hit.mid && self.current_self == hit.node;
    }
    const fn is_sync_iface(self: &Self, tr: DefId) bool {
        return self.iface_named(tr, "Sync");
    }
    // Is this aggregate the prelude `UnsafeCell`? See the `Sync` rule in `tc_thread_marker`.
    fn is_unsafe_cell_decl(self: &Self, om: ModuleId, od: NodeId) bool {
        if self.package == null {
            return false;
        }
        let hit = self.package.prelude_lookup("UnsafeCell", true);
        return hit.node != NODE_NONE && hit.mid == om && hit.node == od;
    }
    // Structural `Send`/`Sync`: is `ty` safe to transfer to (`sync=false`) or share with (`sync=true`)
    // another thread? Scalars/str yes; a raw pointer no (so is anything transitively holding one); a
    // reference reduces to `Sync` of its pointee; a closure to all its captures; an aggregate to all its
    // fields -- but an explicit `extend T as Send/Sync {}` overrides the field walk (the unsafe escape
    // hatch, e.g. Arc). Mirrors tc_type_is_free's decomposition; the depth cap breaks reference cycles.
    fn tc_thread_marker(self: &mut Self, ty: TypeId, sync: bool, depth: i32) bool {
        if ty == TYPE_NONE || depth > BOUND_MAX_DEPTH {
            return true;
        }
        let y = *self.type_at(ty);
        let k = y.kind;
        if k == TypeKind::TYPE_GENERIC {
            return true; // a generic param -- enforced where it is instantiated
        }
        if k == TypeKind::TYPE_POINTER {
            return false; // raw pointer: neither Send nor Sync
        }
        if k == TypeKind::TYPE_REFERENCE {
            return self.tc_thread_marker(y.as_data.elem, true, depth + 1); // &T needs T: Sync
        }
        if k == TypeKind::TYPE_SLICE || k == TypeKind::TYPE_ARRAY {
            return self.tc_thread_marker(y.as_data.elem, sync, depth + 1);
        }
        if k == TypeKind::TYPE_BUILTIN {
            return true; // scalars, bool, char, str view
        }
        if k == TypeKind::TYPE_DYN {
            return false; // a trait object does not advertise Send/Sync -- conservative
        }
        if k == TypeKind::TYPE_FUNCTION {
            let fa = self.mod_ast(y.module);
            let fnn = fa.at_const(y.as_data.decl);
            if fnn.kind != NodeKind::NODE_CLOSURE {
                return true; // a bare fn pointer captures nothing
            }
            let caps = fnn.as_data.closure.captures;
            for i in 0..caps.len {
                let cid = unsafe fa.list(caps)[i as usize];
                let cty = self.cur_ast().reintern(unsafe &*fa, fa.type_of(cid));
                let ci = self.marker_iface(sync);
                if ci.node != NODE_NONE && !self.type_satisfies(cty, ci, depth + 1) {
                    return false;
                }
            }
            return true;
        }
        // Aggregate: an explicit conformance is an unsafe override; otherwise every field must qualify.
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(ty), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        // `UnsafeCell<T>` is never `Sync`. It hands out a `*mut T` from a SHARED borrow, so two threads
        // holding `&UnsafeCell<T>` can write the same value at once -- and the field walk below would read
        // straight through the cell to its payload and grant `Sync` for free, which is the whole hole
        // interior mutability is supposed to be gated by. Anything built on one (`Atomic`, `Mutex`,
        // `RwLock`) is shareable only by ASSERTING `Sync`, which is where its discipline is written down.
        if sync && self.is_unsafe_cell_decl(om, od) {
            return false;
        }
        let ci = self.marker_iface(sync);
        if ci.node != NODE_NONE {
            let mut imod: ModuleId = 0;
            let extnode = self.find_extend_as(om, od, ci, &mut imod);
            if extnode != NODE_NONE {
                // Explicit `extend T as Send/Sync {}` -- an unsafe override, but its own bounds still hold
                // (e.g. `extend<T: Send + Sync> Arc<T> as Send` is Send only for a Send + Sync payload).
                let ia = self.mod_ast(imod);
                let gens = ia.at_const(extnode).as_data.extend_def.generics;
                let mut g: u32 = 0;
                while g < gens.len && g as i32 < gn {
                    let gid = unsafe ia.list(gens)[g as usize];
                    let gb = ia.at_const(gid).as_data.generic_param.bounds;
                    for b in 0..gb.len {
                        let gbi = ia.resolution_def(unsafe ia.list(gb)[b as usize]);
                        if gbi.node != NODE_NONE && !self.type_satisfies(ga[g as usize], gbi, depth + 1) {
                            return false;
                        }
                    }
                    g = g + 1;
                }
                return true;
            }
        }
        let dn = *self.mod_ast(om).at_const(od);
        let is_enum = dn.kind == NodeKind::NODE_ENUM;
        if dn.kind != NodeKind::NODE_STRUCT && !is_enum {
            return false;
        }
        let a = self.mod_ast(om);
        let ms = dn.as_data.aggregate.members;
        let mids = a.list(ms);
        for i in 0..ms.len {
            let mn = *a.at_const(unsafe mids[i as usize]);
            if !is_enum && mn.kind == NodeKind::NODE_FIELD {
                if !self.tc_member_marker(om, mn.as_data.field.ty, &gp[0], &ga[0], gn, sync, depth) {
                    return false;
                }
            } else if is_enum && mn.kind == NodeKind::NODE_VARIANT {
                let pids = a.list(mn.as_data.variant.payload);
                for p in 0..mn.as_data.variant.payload.len {
                    let pe = *a.at_const(unsafe pids[p as usize]);
                    let tn = if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, unsafe pids[p as usize]);
                    if !self.tc_member_marker(om, tn, &gp[0], &ga[0], gn, sync, depth) {
                        return false;
                    }
                }
            }
        }
        return true;
    }
    fn marker_iface(self: &mut Self, sync: bool) DefId {
        if self.package == null {
            return DefId { module: 0, node: NODE_NONE };
        }
        let nm = if sync {
            "Sync";
        } else {
            "Send";
        };
        let h = self.package.prelude_lookup(nm, true);
        return DefId { module: h.mid, node: h.node };
    }
    fn tc_member_marker(
        self: &mut Self,
        om: ModuleId,
        tnode: NodeId,
        gp: *const DefId,
        ga: *const TypeId,
        gn: i32,
        sync: bool,
        depth: i32,
    ) bool {
        let mut ft = self.lower_type_in(om, tnode);
        let mut conc = true;
        for k in 0..gn {
            if !self.cur_ast().type_concrete(unsafe ga[k as usize]) {
                conc = false;
            }
        }
        if gn > 0 && conc {
            ft = self.subst_type(ft, gp, ga, gn);
        }
        let ci = self.marker_iface(sync);
        if ci.node == NODE_NONE {
            return true;
        }
        return self.type_satisfies(ft, ci, depth + 1);
    }
    // Leak check (lint, error-level): structs and enums DERIVE Free when their members own
    // memory, but a UNION cannot (only the author knows the active member), so an owning union
    // with no explicit Free conformance silently leaks -- reject it. No machine fix: a generated
    // body freeing every overlapping member would double-free.
    fn tc_lint_missing_free(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let sty = a.intern_type(
            Ty { kind: TypeKind::TYPE_STRUCT, module: self.cur_module(), as_data: TyAs { decl: id } },
        );
        if self.tc_type_is_free(sty) {
            return;
        }
        let agg = a.at_const(id).as_data.aggregate;
        let sname = a.at_const(agg.name).as_data.name.text;
        let nm = diag::span_str(self.source, sname.start, sname.end);
        let ms = agg.members;
        let mut fields = String::new();
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            let fnd = a.at_const(fid);
            if fnd.kind != NodeKind::NODE_FIELD {
                continue;
            }
            let ft = self.resolve_type(fnd.as_data.field.ty);
            if ft == TYPE_NONE {
                continue;
            }
            let fk = self.type_at(ft).kind;
            if fk == TypeKind::TYPE_POINTER || fk == TypeKind::TYPE_REFERENCE {
                continue;
            }
            if !self.tc_type_is_free(ft) {
                continue;
            }
            let fsp = a.at_const(fnd.as_data.field.name).as_data.name.text;
            if fields.len() != 0 {
                fields.push_str("', '");
            }
            fields.push_str(diag::span_str(self.source, fsp.start, fsp.end));
        }
        if fields.len() == 0 {
            return;
        }
        self.errors.emit(
            sname.start,
            sname.end - sname.start,
            format(
                "union '{}' has owning fields ('{}') but no 'free': unions never free implicitly",
                nm,
                fields.as_str(),
            ),
        );
        self.errors.note(format("implement Free for '{}' and free the ACTIVE member there", nm));
    }
    fn tc_member_owns(self: &mut Self, om: ModuleId, tnode: NodeId, gp: *const DefId, ga: *const TypeId, gn: i32) bool {
        let mut ft = self.lower_type_in(om, tnode);
        // substitute only fully-concrete instantiations: generic args would intern novel
        // partially-generic instances into the pool (they emit as undefined C type names);
        // generic members fall to the TYPE_GENERIC bound-based verdict instead
        let mut conc = true;
        for k in 0..gn {
            if !self.cur_ast().type_concrete(unsafe ga[k as usize]) {
                conc = false;
            }
        }
        if gn > 0 && conc {
            ft = self.subst_type(ft, gp, ga, gn);
        }
        if ft == TYPE_NONE {
            return false;
        }
        let fk = self.type_at(ft).kind;
        if fk == TypeKind::TYPE_POINTER || fk == TypeKind::TYPE_REFERENCE {
            return false;
        }
        return self.tc_type_is_free(ft);
    }
    fn tc_type_derives_free(self: &mut Self, om: ModuleId, od: NodeId, gp: *const DefId, ga: *const TypeId, gn: i32) bool {
        let a = self.mod_ast(om);
        let dn = *a.at_const(od);
        let is_enum = dn.kind == NodeKind::NODE_ENUM;
        if dn.kind != NodeKind::NODE_STRUCT && !is_enum {
            return false;
        }
        if !is_enum && dn.as_data.aggregate.is_union {
            return false;
        }
        let key = om as u64 << 32 | od as u64;
        if gn == 0 {
            switch self.free_derive_memo.get(&key) {
                Some(v) => {
                    return *v == 2u64;
                },
                _ => {},
            };
        }
        for b in 0..self.derive_busy.len() {
            if self.derive_busy[b] == key {
                return false;
            }
        }
        self.derive_busy.push(key);
        let mut owns = false;
        let ms = dn.as_data.aggregate.members;
        let mids = a.list(ms);
        for i in 0..ms.len {
            let mid = unsafe mids[i as usize];
            let mn = *a.at_const(mid);
            if !is_enum && mn.kind == NodeKind::NODE_FIELD {
                if self.tc_member_owns(om, mn.as_data.field.ty, gp, ga, gn) {
                    owns = true;
                }
            } else if is_enum && mn.kind == NodeKind::NODE_VARIANT {
                let pids = a.list(mn.as_data.variant.payload);
                for k in 0..mn.as_data.variant.payload.len {
                    let pid = unsafe pids[k as usize];
                    let pe = *a.at_const(pid);
                    let tn = if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, pid);
                    if self.tc_member_owns(om, tn, gp, ga, gn) {
                        owns = true;
                    }
                }
            }
        }
        let _ = self.derive_busy.pop();
        if gn == 0 {
            self.free_derive_memo.insert(
                key,
                if owns {
                    2u64;
                } else {
                    1u64;
                },
            );
        }
        return owns;
    }
    /// Does a value of `ty` occupy no bytes? A struct with no fields, or whose every field is itself
    /// zero-sized (`Global`, any allocator tag). The depth cap breaks reference cycles.
    fn tc_type_is_zero_sized(self: &mut Self, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE || depth > 8 {
            return false;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_ARRAY {
            return y.as_data.arr.len == 0 || self.tc_type_is_zero_sized(y.as_data.arr.elem, depth + 1);
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(ty, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        let dn = self.mod_ast(om).at_const(od);
        if dn.kind != NodeKind::NODE_STRUCT {
            return false; // an enum carries a tag; a union is as big as its widest member
        }
        let ms = dn.as_data.aggregate.members;
        for i in 0..ms.len {
            let fid = unsafe self.mod_ast(om).list(ms)[i as usize];
            if self.mod_ast(om).at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let ft = self.subst_type(self.decl_type_in(om, fid), &gp[0], &ga[0], gn);
            if !self.tc_type_is_zero_sized(ft, depth + 1) {
                return false;
            }
        }
        return true;
    }

    /// The stateful allocator a constant of `ty` would EMBED, or TYPE_NONE. A constant's storage is static
    /// data no allocator provided, so an allocator value stored beside it describes memory that does not
    /// exist -- and a state field holding a compile-time pointer bakes that block into the binary as
    /// read-only data the allocator could never legally hand out. Walks stored fields only: a pointer is
    /// not embedded state, and elements a program deliberately stores are data, not the container's
    /// allocator.
    fn tc_const_alloc_state(self: &mut Self, ty: TypeId, depth: u32) TypeId {
        if ty == TYPE_NONE || depth > 8 {
            return TYPE_NONE;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.tc_const_alloc_state(y.as_data.arr.elem, depth + 1);
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(ty, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return TYPE_NONE;
        }
        if self.mod_ast(om).at_const(od).kind != NodeKind::NODE_STRUCT {
            return TYPE_NONE;
        }
        let ms = self.mod_ast(om).at_const(od).as_data.aggregate.members;
        for i in 0..ms.len {
            let fid = unsafe self.mod_ast(om).list(ms)[i as usize];
            if self.mod_ast(om).at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let ft = self.subst_type(self.decl_type_in(om, fid), &gp[0], &ga[0], gn);
            if ft == TYPE_NONE {
                continue;
            }
            let fk = self.type_at(ft).kind;
            if fk == TypeKind::TYPE_POINTER || fk == TypeKind::TYPE_REFERENCE {
                continue; // a pointer field is not embedded state
            }
            if self.tc_is_stateful_allocator(ft) {
                return ft;
            }
            let inner = self.tc_const_alloc_state(ft, depth + 1);
            if inner != TYPE_NONE {
                return inner;
            }
        }
        return TYPE_NONE;
    }

    /// Does `ty` implement Allocator AND occupy bytes? Those bytes are the state a constant cannot carry.
    fn tc_is_stateful_allocator(self: &mut Self, ty: TypeId) bool {
        if self.tc_type_is_zero_sized(ty, 0) || self.package == null {
            return false;
        }
        let h = self.package.prelude_lookup("Allocator", true);
        if h.node == NODE_NONE {
            return false;
        }
        return self.type_satisfies(ty, DefId { module: h.mid, node: h.node }, 0);
    }

    fn tc_param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.mod_ast(m);
        let bs = a.at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bd = a.resolution_def(unsafe a.list(bs)[i as usize]);
            if self.is_free_iface(bd) {
                return true;
            }
        }
        return false;
    }
    /// Does a value of `ty` own memory (i.e. is it Free)? An explicit Free extend decides first (its
    /// per-param Free bounds re-checked against the instance args); otherwise structs/enums DERIVE Free
    /// when any field/payload owns, transitively -- unions never derive. Owning closures (a by-copy Free
    /// capture) and owned `Box<dyn>` count too. References/pointers peel to their referent: callers that
    /// must treat a borrow as non-owning gate on the pointer kind first.
    pub fn tc_type_is_free(self: &mut Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y0 = *self.type_at(ty);
        if y0.kind == TypeKind::TYPE_FUNCTION {
            return self.fn_owns(ty);
        }
        if y0.kind == TypeKind::TYPE_DYN {
            return y0.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8;
        }
        if y0.kind == TypeKind::TYPE_GENERIC {
            let fb = self.generic_fn_bound(y0.module, y0.as_data.decl);
            if fb != NODE_NONE {
                return self.mod_ast(y0.module).at_const(fb).as_data.function_type.is_move;
            }
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(ty), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        // TC-6: the (first) Free extend of a (module, decl) is a parse-time fact -- memoize it and
        // re-run only the per-instance bound check below. 0 = "no Free extend".
        let key = om as u64 << 32 | od as u64;
        let mut fm: ModuleId = 0;
        let mut fx = NODE_NONE;
        let mut have = false;
        switch self.free_ext_memo.get(&key) {
            Some(v) => {
                if *v == 0u64 {
                    return self.tc_type_derives_free(om, od, &gp[0], &ga[0], gn);
                }
                fm = (*v >> 32) as ModuleId;
                fx = (*v & 0xFFFFFFFFu64) as NodeId;
                have = true;
            },
            _ => {},
        };
        if !have {
            let ni = self.ext_scopes();
            let mut s: i32 = -1;
            while s < ni && !have {
                let mut m = om;
                if s >= 0 {
                    m = self.ext_scope_at(s);
                }
                if s >= 0 && m == om {
                    s = s + 1;
                    continue;
                }
                self.ensure_ext_items(m);
                let a = self.mod_ast(m);
                let ne = self.ext_items_len(m);
                let mut i: usize = 0;
                while i < ne && !have {
                    let iid = self.ext_items_at(m, i);
                    let it = a.at_const(iid);
                    if it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                        let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                        if tg.module == om && tg.node == od {
                            let tr = a.resolution_def(it.as_data.extend_def.interface_type);
                            if self.is_free_iface(tr) {
                                fm = m;
                                fx = iid;
                                have = true;
                            }
                        }
                    }
                    i = i + 1;
                }
                s = s + 1;
            }
            if !have {
                self.free_ext_memo.insert(key, 0u64);
                return self.tc_type_derives_free(om, od, &gp[0], &ga[0], gn);
            }
            self.free_ext_memo.insert(key, fm as u64 << 32 | fx as u64);
        }
        let fa = self.mod_ast(fm);
        let gens = fa.at_const(fx).as_data.extend_def.generics;
        let mut k: u32 = 0;
        while k < gens.len && k as i32 < gn {
            let gid = unsafe fa.list(gens)[k as usize];
            if self.tc_param_has_free_bound(fm, gid) && !self.tc_type_is_free(ga[k as usize]) {
                return false;
            }
            k = k + 1;
        }
        return true;
    }

    fn method_extend_bounds_hold(self: &mut Self, target: TypeId, md: DefId) bool {
        if target == TYPE_NONE || md.node == NODE_NONE {
            return true;
        }
        let extnode = self.enclosing_extend(md.module, md.node);
        if extnode == NODE_NONE {
            return true;
        }
        let ia = self.mod_ast(md.module);
        let gens = ia.at_const(extnode).as_data.extend_def.generics;
        if gens.len == 0 {
            return true;
        }
        let mut tm: ModuleId = 0;
        let mut td = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(target), &mut tm, &mut td, &mut gp, &mut ga, &mut gn) {
            return true;
        }
        for g in 0..gens.len {
            if g as i32 >= gn {
                return false;
            }
            let gid = unsafe ia.list(gens)[g as usize];
            let gb = ia.at_const(gid).as_data.generic_param.bounds;
            for b in 0..gb.len {
                let bi = ia.resolution_def(unsafe ia.list(gb)[b as usize]);
                if bi.node != NODE_NONE && !self.type_satisfies(ga[g as usize], bi, 0) {
                    return false;
                }
            }
        }
        return true;
    }
    fn err_method_extend_bounds(self: &mut Self, at: tok::Span, target: TypeId, md: DefId) {
        let mut ty = Buf96 {};
        self.render_type(self.strip(target), &mut ty[0], 96);
        let ma = self.mod_ast(md.module);
        let mn = ma.at_const(ma.at_const(md.node).as_data.function.name).as_data.name.text;
        self.errors.emit(
            at.start,
            at.end - at.start,
            format(
                "cannot call '{}::{}': unsatisfied interface bounds",
                diag::cstr(&ty[0]),
                diag::span_str(self.mod_src(md.module), mn.start, mn.end),
            ),
        );
        self.errors.note(format("these bounds come from the extend block that defines the method"));
    }

    fn mark_format_helpers(self: &mut Self) {
        if self.package == null || self.fmt_marked {
            return;
        }
        let sh = self.package.prelude_lookup("String", true);
        if sh.node == NODE_NONE {
            return;
        }
        self.fmt_marked = true;
        // Resolved by decl with no receiver: they land in always_methods, which is what the print
        // lowering needs -- it names them for whatever String instance it happens to build.
        self.mark_recv = TYPE_NONE;
        let mut names = Names14 {};
        names[0] = "new".ptr() as *const char;
        names[1] = "print".ptr() as *const char;
        names[2] = "eprint".ptr() as *const char;
        names[3] = "push_i64".ptr() as *const char;
        names[4] = "push_u64".ptr() as *const char;
        names[5] = "push_f64".ptr() as *const char;
        names[6] = "push_hex_i64".ptr() as *const char;
        names[7] = "push_hex".ptr() as *const char;
        names[8] = "push_byte".ptr() as *const char;
        names[9] = "push_str".ptr() as *const char;
        names[10] = "as_str".ptr() as *const char;
        names[11] = "push_bin".ptr() as *const char;
        names[12] = "push_f64_prec".ptr() as *const char;
        names[13] = "push_padded".ptr() as *const char;
        names[14] = "pad_at".ptr() as *const char;
        names[15] = "len".ptr() as *const char;
        for i in 0..16 {
            self.find_method_cstr(sh.mid, sh.node, diag::cstr(names[i as usize]));
        }
    }

    fn resolve_conversion(self: &mut Self, name: tok::Span, want: TypeId) DefId {
        let is_into = span_is(self.source, name, "into");
        let is_try = span_is(self.source, name, "try_into");
        if !is_into && !is_try || want == TYPE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let mut m: ModuleId = 0;
        let mut decl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(want), &mut m, &mut decl, &mut gp, &mut ga, &mut gn) {
            return DefId { module: 0, node: NODE_NONE };
        }
        if is_try {
            if gn < 1 {
                return DefId { module: 0, node: NODE_NONE };
            }
            if !self.aggregate_of(self.strip(ga[0]), &mut m, &mut decl, &mut gp, &mut ga, &mut gn) {
                return DefId { module: 0, node: NODE_NONE };
            }
        }
        let mut lit = "from";
        if is_try {
            lit = "try_from";
        }
        return self.find_method_cstr(m, decl, lit);
    }

    /// The type a `.into()` / `.try_into()` call builds, when `mname` is one of those and it resolved to
    /// the mirror `from` / `try_from`. That is the type whose generic arguments the call substitutes
    /// through; TYPE_NONE for any ordinary method call. Mirrors resolve_conversion's unwrapping: the
    /// fallible pair names `Result<Target, E>`, so the target is its first argument.
    fn tc_conversion_target(self: &mut Self, mname: NodeId, md: DefId, want: TypeId) TypeId {
        if md.node == NODE_NONE || want == TYPE_NONE {
            return TYPE_NONE;
        }
        let nsp = self.name_span(mname);
        let is_into = span_is(self.source, nsp, "into");
        let is_try = span_is(self.source, nsp, "try_into");
        if !is_into && !is_try {
            return TYPE_NONE;
        }
        let mn = self.mod_ast(md.module).at_const(md.node);
        if mn.kind != NodeKind::NODE_FUNCTION {
            return TYPE_NONE;
        }
        let fnm = self.mod_ast(md.module).at_const(mn.as_data.function.name).as_data.name.text;
        let msrc = self.mod_src(md.module);
        let mut ok = span_is(msrc, fnm, "from");
        if is_try {
            ok = span_is(msrc, fnm, "try_from");
        }
        if !ok {
            return TYPE_NONE;
        }
        if !is_try {
            return self.strip(want);
        }
        let mut m: ModuleId = 0;
        let mut decl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        let ok2 = self.aggregate_of(self.strip(want), &mut m, &mut decl, &mut gp, &mut ga, &mut gn);
        if !ok2 || gn < 1 {
            return TYPE_NONE;
        }
        return self.strip(ga[0]);
    }

    fn tc_find_from_for(self: &mut Self, target: TypeId, src: TypeId) DefId {
        let ty = *self.type_at(self.strip(target));
        if ty.kind != TypeKind::TYPE_STRUCT && ty.kind != TypeKind::TYPE_ENUM {
            return DefId { module: 0, node: NODE_NONE };
        }
        let m = ty.module;
        let decl = ty.as_data.decl;
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut mm = m;
            if s >= 0 {
                mm = self.ext_scope_at(s);
            }
            if s >= 0 && mm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(mm);
            let a = self.mod_ast(mm);
            let ne = self.ext_items_len(mm);
            for i in 0..ne {
                let iid = self.ext_items_at(mm, i);
                let it = a.at_const(iid);
                if it.as_data.extend_def.target_type != NODE_NONE && it.as_data.extend_def.generics.len == 0 {
                    let tg = self.tc_peel_target(a.resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = a.at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let mid = unsafe a.list(ms)[j as usize];
                            let mn = a.at_const(mid);
                            if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                                self.mod_src(mm),
                                a.at_const(mn.as_data.function.name).as_data.name.text,
                                "from",
                            ) {
                                let ps = mn.as_data.function.params;
                                if ps.len == 1 && self.decl_type_in(mm, unsafe a.list(ps)[0]) == src {
                                    self.tc_mark_method_used(DefId { module: mm, node: mid });
                                    return DefId { module: mm, node: mid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn dyn_coerce(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId, probe: bool) bool {
        return self.dyn_coerce_alloc(node, src, dyn_ty, TYPE_NONE, probe);
    }

    // `probe` = answer without observable effects (no diagnostics, no dyn-use recording): a path that
    // would diagnose reports false instead. (A probe may still warm idempotent caches/method-used
    // marks -- harmless.) Used by the redundant-cast lint.
    fn dyn_coerce_alloc(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId, balloc: TypeId, probe: bool) bool {
        let dy = *self.type_at(dyn_ty);
        let iface = DefId { module: dy.module, node: self.cur_ast().dyn_decl_of(&dy) };
        let sy = *self.type_at(src);
        let sp = self.cur_ast().at_const(node).span;
        if sy.kind == TypeKind::TYPE_GENERIC {
            if probe {
                return false;
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot erase a generic type parameter to 'dyn'"));
            return true;
        }
        if !self.type_satisfies(src, iface, 0) {
            return false;
        }
        let mut tmod: ModuleId = 0;
        let mut tdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(src, &mut tmod, &mut tdecl, &mut gp, &mut ga, &mut gn) {
            if sy.kind == TypeKind::TYPE_BUILTIN && self.package != null && self.package.builtin_decl(
                sy.as_data.builtin,
            ) != NODE_NONE {
                tmod = unsafe self.package.core_module;
                tdecl = self.package.builtin_decl(sy.as_data.builtin);
            } else {
                return false;
            }
        }
        let ia = self.mod_ast(iface.module);
        let isrc = self.mod_src(iface.module);
        let items = ia.at_const(iface.node).as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe ia.list(items)[i as usize];
            if self.dyn_method(iface.module, mid) {
                let mn = ia.at_const(ia.at_const(mid).as_data.function.name).as_data.name.text;
                let mut nmb = Buf96 {};
                unsafe stdio::snprintf(
                    &mut nmb[0],
                    96,
                    "%.*s".ptr() as *const char,
                    (mn.end - mn.start) as i32,
                    src_at(isrc, mn.start),
                );
                if self.find_method_cstr(tmod, tdecl, diag::cstr(&nmb[0])).node != NODE_NONE {
                    continue;
                }
                let mut emod: ModuleId = 0;
                if ia.at_const(mid).as_data.function.body != NODE_NONE && self.find_extend_as(
                    tmod,
                    tdecl,
                    iface,
                    &mut emod,
                ) != NODE_NONE {
                    continue;
                }
                if probe {
                    return false;
                }
                let mut tn = Buf96 {};
                self.render_type(src, &mut tn[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "cannot erase '{}' to 'dyn': method '{}' has no emittable implementation",
                        diag::cstr(&tn[0]),
                        diag::cstr(&nmb[0]),
                    ),
                );
                self.errors.note(format("implement the method in an 'extend .. as ..' block or give it a default body"));
                return true;
            }
        }
        if probe {
            return true; // erasure would succeed; record nothing
        }
        // Synthesize (superinterface, src) uses FIRST so codegen emits their vtables (the root
        // vtable's __super_* fields point at them); the real use goes last so dyn_at[node] wins.
        let mut sclo = Defs8 {};
        let nsc = self.dyn_super_closure(iface, &mut sclo[0], 8);
        let mut si: i32 = 1;
        while si < nsc {
            let sd = sclo[si as usize];
            let sdy = self.cur_ast().intern_dyn(sd.module, sd.node, null, 0, dy.qualifier);
            self.cur_ast().add_dyn_use_alloc(node, src, sdy, balloc);
            si = si + 1;
        }
        self.cur_ast().add_dyn_use_alloc(node, src, dyn_ty, balloc);
        return true;
    }

    // Attach the ` as T` deletion fix for the unnecessary-cast lints. Grouping parens are dropped
    // without re-spanning (`(x) as T` records x's span without the parens), so the deletion starts
    // after any closing parens between the expression end and the `as` keyword.
    @c.cold
    fn tc_cast_drop_fix(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let csp = a.at_const(id).span;
        let esp = a.at_const(a.at_const(id).as_data.cast.expression).span;
        if esp.end >= csp.end || esp.start < csp.start {
            return;
        }
        let mut fs = esp.end;
        let mut j = esp.end;
        while j < csp.end && self.source[j as usize] != b'a' {
            if self.source[j as usize] == b')' {
                fs = j + 1;
            }
            j = j + 1;
        }
        self.errors.fix(fs, csp.end, 0);
    }

    // Lint: `E as P` at a position expecting exactly P, where E converts to P implicitly -- the cast
    // is redundant (dropping it typechecks identically). Delegates to compatible_in(probe): whatever
    // the language accepts implicitly, this flags, by construction. Casts with no expected type stay
    // exempt (an unannotated `let x = E as P` uses the cast to pick the binding's type), as do pinned
    // (suffixed) literals via the probe itself. Fires once per cast node.
    @c.cold
    fn tc_lint_redundant_coalesce(self: &mut Self, expected: TypeId, node: NodeId) {
        let a = self.cur_ast();
        // peel `move`/`unsafe` wrappers: `unsafe (E as P)` is as redundant as the bare cast
        let mut nid = node;
        while a.at_const(nid).kind == NodeKind::NODE_UNARY && (a.at_const(nid).as_data.unary.op == TokenType::Move || a.at_const(
            nid,
        ).as_data.unary.op == TokenType::Unsafe) {
            nid = a.at_const(nid).as_data.unary.operand;
        }
        if a.at_const(nid).kind != NodeKind::NODE_CAST {
            return;
        }
        let opn = a.at_const(nid).as_data.cast.expression;
        if opn as usize >= unsafe a.types.len() {
            return;
        }
        let ot = a.type_of(opn);
        if ot == expected {
            return; // same-type casts belong to the existing unnecessary-cast lint
        }
        if !self.compatible_in(expected, opn, true) {
            return;
        }
        let key = self.cur_module() as u64 << 32 | nid as u64;
        for i in 0..self.len_reported.len() {
            if self.len_reported[i] == key {
                return;
            }
        }
        self.len_reported.push(key);
        let mut f = Buf96 {};
        if ot == TYPE_NONE {
            unsafe stdio::snprintf(&mut f[0], 96, "%s".ptr() as *const char, "null".ptr() as *const char);
        } else {
            self.render_type(ot, &mut f[0], 96);
        }
        let mut d = Buf96 {};
        self.render_type(expected, &mut d[0], 96);
        let sp = a.at_const(nid).span;
        self.errors.warn(
            sp.start,
            sp.end - sp.start,
            format("unnecessary cast: '{}' converts to '{}' implicitly here", diag::cstr(&f[0]), diag::cstr(&d[0])),
        );
        self.tc_cast_drop_fix(nid);
    }

    fn compatible(self: &mut Self, expected: TypeId, node: NodeId) bool {
        return self.compatible_in(expected, node, false);
    }

    // The one implicit-conversion oracle. `probe` answers "would this coerce, cleanly?" with no
    // observable effects: paths that would diagnose report false, and nothing is recorded
    // (set_type/dyn uses). The redundant-cast lint probes the cast OPERAND against the expected type
    // through this, so it covers every implicit conversion by construction.
    fn compatible_in(self: &mut Self, expected: TypeId, node: NodeId, probe: bool) bool {
        let actual = self.cur_ast().type_of(node);
        if actual == TYPE_NONE && expected != TYPE_NONE {
            // `null` types as TYPE_NONE; don't let the wildcard below accept it for value types
            // (str, structs, ints) -- it is only a pointer/reference/fn-pointer literal.
            let n = self.cur_ast().at_const(node);
            if n.kind == NodeKind::NODE_LITERAL && n.as_data.literal.token_type == TokenType::Null {
                let ek = self.type_at(expected).kind;
                return ek == TypeKind::TYPE_POINTER || ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_FUNCTION;
            }
        }
        if expected == TYPE_NONE || expected == actual {
            if self.lint && expected != TYPE_NONE && !probe {
                self.tc_lint_redundant_coalesce(expected, node);
            }
            return true;
        }
        if actual == TYPE_NONE {
            // An untyped expression: only lenient as error recovery. In an error-free compile an
            // untyped node reaching a compat check is a typechecker hole, not a wildcard match.
            return self.errors.errors.len() != 0;
        }
        let ex = *self.type_at(expected);
        let ac = *self.type_at(actual);
        if ac.kind == TypeKind::TYPE_NEVER {
            return true;
        }
        // Two unfolded const-generic expressions are interned per NODE, so the same `{N * 2}` written in
        // a return type and in the value returned are different ids. They denote the same width, and
        // structural equality is what says so until a substitution folds both to one value.
        if self.tc_const_expr_same(expected, actual) {
            return true;
        }
        // A reference coalesces to its raw-pointer form (`&T` -> `*const T`, `&mut T` -> `*mut T`).
        // Normalizing it here lets the single pointer rule below apply transitively, so `&T` reaches
        // `*const void` via `*const T` (ref -> ptr -> void) with no special case. A BARE `*T` accepts
        // references of either mutability (`&T`/`&mut T` -> `*T`); the reverse (pointer -> reference)
        // is never implicit -- it needs an explicit cast inside `unsafe`.
        let mut acp = ac;
        if ac.kind == TypeKind::TYPE_REFERENCE && ex.kind == TypeKind::TYPE_POINTER {
            // Coercing a reference into a RAW POINTER ERASES the borrow. A raw pointer carries no
            // region, and it is precisely the boundary at which this language hands lifetime
            // responsibility to the programmer (dereferencing it needs `unsafe`). Keeping the borrow
            // live would pin the referent for as long as whatever stored the pointer lives -- which
            // the checker cannot see -- and would reject correct code like
            // `ConstEval::new(&mut p, ..)` where the parameter is `*mut Package`.
            if !probe {}
            acp.kind = TypeKind::TYPE_POINTER;
            if acp.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                acp.qualifier = TypeQualifier::TYPE_QUAL_CONST as u8;
            }
            if ex.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                acp.qualifier = TypeQualifier::TYPE_QUAL_NONE as u8;
            }
        }
        if ex.kind == TypeKind::TYPE_REFERENCE && ac.kind == TypeKind::TYPE_REFERENCE && ex.as_data.elem == ac.as_data.elem && ex.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && ac.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return true;
        }
        if ex.kind == TypeKind::TYPE_POINTER && acp.kind == TypeKind::TYPE_POINTER && (ex.as_data.elem == acp.as_data.elem || ex.as_data.elem == Ast::builtin(
            BuiltinType::BT_VOID,
        )) && (ex.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 || acp.qualifier != TypeQualifier::TYPE_QUAL_CONST as u8) {
            return true;
        }
        if ex.kind == TypeKind::TYPE_FUNCTION && ac.kind == TypeKind::TYPE_FUNCTION {
            if self.fn_compatible(expected, actual) {
                return true;
            }
            // The actual may be a GENERIC function named as a value: its declared signature still
            // mentions its type parameters, so it matches only once they are bound.
            return !probe && self.tc_coerce_generic_fn(expected, node);
        }
        if ex.kind == TypeKind::TYPE_ARRAY && ac.kind == TypeKind::TYPE_ARRAY {
            if ex.as_data.arr.len != 0 && ac.as_data.arr.len != 0 && ex.as_data.arr.len != ac.as_data.arr.len {
                return false;
            }
            // An array literal types with len 0 (unknown), so the wildcard rule above never sees its
            // real element count: enforce it here -- excess initializers are a C constraint violation
            // downstream, missing ones a silent zero-fill. Strict both ways for plain positional
            // literals; a designated literal may underfill (sparse zero-fill is that feature) but
            // never exceed. A precise error beats the generic mismatch, so emit and report compatible.
            if ex.as_data.arr.len != 0 && ac.as_data.arr.len == 0 && self.cur_ast().at_const(node).kind == NodeKind::NODE_ARRAY_LITERAL {
                let mut sparse = false;
                let ext = self.tc_array_lit_extent(node, &mut sparse);
                let bad = ext >= 0 && (ext > ex.as_data.arr.len as i64 || !sparse && ext < ex.as_data.arr.len as i64);
                if bad && probe {
                    return false;
                }
                if bad {
                    let sp = self.cur_ast().at_const(node).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "array literal has {} elements but the expected type has length {}",
                            ext,
                            ex.as_data.arr.len,
                        ),
                    );
                    return true;
                }
            }
            if ex.as_data.arr.elem == ac.as_data.arr.elem {
                return true;
            }
            let ee = self.type_at(ex.as_data.arr.elem).kind;
            let ae = self.type_at(ac.as_data.arr.elem).kind;
            return ee == TypeKind::TYPE_FUNCTION && ae == TypeKind::TYPE_FUNCTION && self.fn_compatible(
                ex.as_data.arr.elem,
                ac.as_data.arr.elem,
            );
        }
        if ac.kind == TypeKind::TYPE_ARRAY {
            let mut selem: TypeId = TYPE_NONE;
            let sk = self.slice_kind(expected, &mut selem);
            if sk != 0 && selem == ac.as_data.arr.elem && (sk == 1 || self.is_assignable(node)) {
                if !probe {
                    self.cur_ast().set_type(node, expected);
                }
                return true;
            }
        }
        // Deref coercion: `&W` reaches a `&Target` parameter through W's Deref, the same step
        // `w.method()` already takes. Only tightens (`&mut W` also satisfies `&Target`); the reverse
        // would hand out mutability the source never had.
        if ex.kind == TypeKind::TYPE_REFERENCE && ac.kind == TypeKind::TYPE_REFERENCE && ex.as_data.elem != ac.as_data.elem && (ex.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 || ac.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8) {
            let mut dm = DefId { module: 0, node: NODE_NONE };
            let dt = self.tc_deref_step(ac.as_data.elem, &mut dm);
            if dt == ex.as_data.elem && dt != TYPE_NONE {
                if !probe {
                    self.tc_record_deref(node, ac.as_data.elem, dm, dt);
                    self.cur_ast().set_type(node, expected);
                }
                return true;
            }
        }
        if ex.kind == TypeKind::TYPE_DYN {
            let exsig = self.tc_dyn_fn_sig(&ex);
            let sp = self.cur_ast().at_const(node).span;
            if ac.kind == TypeKind::TYPE_DYN {
                let qual_ok = ex.qualifier == ac.qualifier || ex.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 && ac.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
                if self.tc_dyn_same(&ex, &ac) {
                    return qual_ok;
                }
                // upcast: dyn X coerces to dyn Y when Y is in X's superinterface closure; the fat
                // value's data is reused and the vtable comes from the __super_* embed
                if qual_ok && exsig == TYPE_NONE && self.mod_ast(ac.module).at_const(self.cur_ast().dyn_decl_of(&ac)).kind == NodeKind::NODE_INTERFACE {
                    let mut uclo = Defs8 {};
                    let nu = self.dyn_super_closure(
                        DefId { module: ac.module, node: self.cur_ast().dyn_decl_of(&ac) },
                        &mut uclo[0],
                        8,
                    );
                    let mut ui: i32 = 1;
                    while ui < nu {
                        if uclo[ui as usize].module == ex.module && uclo[ui as usize].node == self.cur_ast().dyn_decl_of(
                            &ex,
                        ) {
                            if !probe {
                                self.cur_ast().add_dyn_use(node, actual, expected);
                            }
                            return true;
                        }
                        ui = ui + 1;
                    }
                }
                return false;
            }
            if ex.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 && ac.kind == TypeKind::TYPE_REFERENCE {
                let rel = *self.type_at(ac.as_data.elem);
                if rel.kind == TypeKind::TYPE_DYN {
                    if rel.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 || !self.tc_dyn_same(&ex, &rel) {
                        return false;
                    }
                    if !probe {
                        self.cur_ast().add_dyn_use(node, TYPE_NONE, expected);
                    }
                    return true;
                }
                if exsig != TYPE_NONE {
                    if rel.kind != TypeKind::TYPE_FUNCTION || !self.dynfn_sig_ok(exsig, ac.as_data.elem) {
                        return false;
                    }
                    if !probe {
                        self.cur_ast().add_dyn_use(node, ac.as_data.elem, expected);
                    }
                    return true;
                }
                if ex.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 && ac.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    return false;
                }
                return self.dyn_coerce(node, ac.as_data.elem, expected, probe);
            }
            if exsig != TYPE_NONE && ac.kind == TypeKind::TYPE_FUNCTION {
                if self.mod_ast(ac.module).at_const(ac.as_data.decl).kind == NodeKind::NODE_FUNCTION_TYPE {
                    if probe {
                        return false;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a runtime 'fn(..)' pointer cannot erase to 'dyn fn'; wrap it in a closure"),
                    );
                    return true;
                }
                if !self.dynfn_sig_ok(exsig, actual) {
                    return false;
                }
                if ex.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 && self.fn_is_capturing(actual) {
                    if probe {
                        return false;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a capturing closure must be borrowed to view it as '&dyn fn': write '&f'"),
                    );
                    return true;
                }
                if !probe {
                    self.cur_ast().add_dyn_use(node, actual, expected);
                }
                return true;
            }
            if ex.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 && ac.kind == TypeKind::TYPE_INSTANCE && exsig == TYPE_NONE {
                let mut inner: TypeId = TYPE_NONE;
                let mut galloc = false;
                if self.tc_box_of(&ac, &mut inner, &mut galloc) {
                    let it2 = *self.cur_ast().instance(ac.as_data.inst);
                    let mut balloc = TYPE_NONE;
                    if !galloc && it2.n >= 2 {
                        balloc = it2.args[1];
                        // the 2-word fat value cannot carry allocator state: the free glue
                        // reconstructs the allocator via Default
                        let dh = self.package.prelude_lookup("Default", true);
                        let ddef = DefId { module: dh.mid, node: dh.node };
                        if !self.type_satisfies(balloc, ddef, 0) {
                            if probe {
                                return false;
                            }
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format(
                                    "the Box allocator must implement 'Default' to be erased to 'Box<dyn I>' (its state is not carried)",
                                ),
                            );
                            return true;
                        }
                    }
                    return self.dyn_coerce_alloc(node, inner, expected, balloc, probe);
                }
            }
            return false;
        }
        if ex.kind == TypeKind::TYPE_BUILTIN && ac.kind == TypeKind::TYPE_BUILTIN && bt_widens(
            ac.as_data.builtin,
            ex.as_data.builtin,
        ) {
            return true;
        }
        let mut vid = node;
        let v0 = self.cur_ast().at_const(node);
        if v0.kind == NodeKind::NODE_UNARY && v0.as_data.unary.op == TokenType::Minus {
            vid = v0.as_data.unary.operand;
        }
        let v = self.cur_ast().at_const(vid);
        if v.kind != NodeKind::NODE_LITERAL {
            return false;
        }
        let et = *self.type_at(expected);
        let tt = v.as_data.literal.token_type;
        if tt == TokenType::IntegerLiteral {
            if self.tc_literal_pinned(vid) {
                return false;
            }
            if et.kind != TypeKind::TYPE_BUILTIN || !(bt_is_int(et.as_data.builtin) || bt_is_float(et.as_data.builtin) || bt_is_complex(
                et.as_data.builtin,
            )) {
                return false;
            }
            if bt_is_int(et.as_data.builtin) {
                let mut mag: u64 = 0;
                let neg = vid != node;
                let got = self.lit_mag(vid, &mut mag);
                if got && !tc_lit_in_range(et.as_data.builtin, mag, neg) && probe {
                    return false;
                }
                if got && !tc_lit_in_range(et.as_data.builtin, mag, neg) {
                    let mut tn = Buf96 {};
                    self.render_type(expected, &mut tn[0], 96);
                    let vsp = self.cur_ast().at_const(node).span;
                    self.errors.emit(
                        vsp.start,
                        vsp.end - vsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                    return true;
                }
                if !neg && !probe {
                    self.cur_ast().set_type(node, expected);
                }
            }
            return true;
        }
        if tt == TokenType::CharacterLiteral {
            return et.kind == TypeKind::TYPE_BUILTIN && bt_is_int(et.as_data.builtin);
        }
        if tt == TokenType::FloatLiteral {
            if self.tc_literal_pinned(vid) {
                return false;
            }
            return et.kind == TypeKind::TYPE_BUILTIN && (bt_is_float(et.as_data.builtin) || bt_is_complex(
                et.as_data.builtin,
            ));
        }
        if tt == TokenType::StringLiteral || tt == TokenType::RawStringLiteral {
            if et.kind != TypeKind::TYPE_POINTER || et.qualifier != TypeQualifier::TYPE_QUAL_CONST as u8 {
                return false;
            }
            let pe = self.type_at(et.as_data.elem);
            if pe.kind != TypeKind::TYPE_BUILTIN || pe.as_data.builtin != BuiltinType::BT_CHAR && pe.as_data.builtin != BuiltinType::BT_U8 {
                return false;
            }
            if !probe {
                self.cur_ast().set_type(node, expected);
            }
            return true;
        }
        if tt == TokenType::Null {
            return et.kind == TypeKind::TYPE_POINTER || et.kind == TypeKind::TYPE_REFERENCE;
        }
        return false;
    }

    fn return_list_is_explicit_void(self: &mut Self, rets: NodeList) bool {
        if rets.len != 1 {
            return false;
        }
        let r0 = unsafe self.cur_ast().list(rets)[0];
        let rn = self.cur_ast().at_const(r0);
        let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
        return self.is_void_type(self.resolve_type(tn));
    }

    fn range_type(self: &mut Self, id: NodeId, start: TypeId, end: TypeId) TypeId {
        let n = self.cur_ast().at_const(id).as_data.pattern_range;
        let has_start = n.start != NODE_NONE;
        let has_end = n.end != NODE_NONE;
        let start_ok = !has_start || start == TYPE_NONE || self.is_int(start);
        let end_ok = !has_end || end == TYPE_NONE || self.is_int(end);
        let sp = self.cur_ast().at_const(id).span;
        if !start_ok || !end_ok {
            self.errors.emit(sp.start, sp.end - sp.start, format("range bounds must be integers"));
            return TYPE_NONE;
        }
        if !has_start {
            return end;
        }
        if !has_end {
            return start;
        }
        if start == TYPE_NONE {
            return end;
        }
        if end == TYPE_NONE || start == end {
            return start;
        }
        if self.is_integer_literal_node(n.start) && self.compatible(end, n.start) {
            return end;
        }
        if self.is_integer_literal_node(n.end) && self.compatible(start, n.end) {
            return start;
        }
        self.err_mismatch(n.end, start);
        return TYPE_NONE;
    }

    // Every read and write of a `static mut` is an unsafe operation, on the same footing as dereferencing a
    // raw pointer. A `static mut` is unsynchronised shared mutable state reachable from any task without
    // being captured, so it slips past the `Send`/`Sync` check on a `launch` -- there is nothing to capture
    // and so nothing to check. Nothing in the type system can prove such an access is free of a data race,
    // so the compiler stops guessing and makes the author say so: the marker is the audit trail.
    //
    // Use an `Atomic`, or a `Mutex`, or keep the state in the task. `unsafe` here is a claim that the
    // accesses are ordered by something the compiler cannot see.
    fn tc_static_mut_use(self: &mut Self, id: NodeId, d: DefId) {
        if d.node == NODE_NONE {
            return;
        }
        let dn = self.mod_ast(d.module).at_const(d.node);
        if dn.kind != NodeKind::NODE_CONST || !dn.as_data.const_def.is_static_mut {
            return;
        }
        if self.tc_needs_unsafe() {
            self.err_unsafe(self.cur_ast().at_const(id).span, "accessing a 'static mut'");
        }
    }
    // ---- places / assignability ----
    const fn tc_path_static_mut(self: &Self, id: NodeId) bool {
        let n = self.cur_ast().at_const(id);
        let mut d = self.cur_ast().resolution_def(id);
        if d.node == NODE_NONE {
            d = self.cur_ast().resolution_def(n.as_data.member.member);
        }
        if d.node == NODE_NONE {
            return false;
        }
        let dn = self.mod_ast(d.module).at_const(d.node);
        return dn.kind == NodeKind::NODE_CONST && dn.as_data.const_def.is_static_mut;
    }
    /// Does this qualified path name a constant? A constant emits as a named object with an address,
    /// so `mod::C` is a PLACE -- borrowing through it (`mod::TABLE.at(i)`) is rooted in that object,
    /// not in a temporary. (Assignability is decided separately, and a constant is never assignable.)
    const fn tc_path_const(self: &Self, id: NodeId) bool {
        let n = self.cur_ast().at_const(id);
        let mut d = self.cur_ast().resolution_def(id);
        if d.node == NODE_NONE {
            d = self.cur_ast().resolution_def(n.as_data.member.member);
        }
        if d.node == NODE_NONE {
            return false;
        }
        return self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_CONST;
    }
    fn is_assignable(self: &mut Self, node_in: NodeId) bool {
        let node = self.peel_wrappers(node_in);
        let a = self.cur_ast();
        let nk = a.at_const(node).kind;
        if nk == NodeKind::NODE_IDENTIFIER {
            let dd = a.resolution_def(node);
            if dd.node != NODE_NONE && dd.module != self.cur_module() {
                let fdn = self.mod_ast(dd.module).at_const(dd.node);
                return fdn.kind == NodeKind::NODE_CONST && fdn.as_data.const_def.is_static_mut;
            }
            let d = a.resolution(node);
            if d == NODE_NONE {
                return false;
            }
            let dn = a.at_const(d);
            if dn.kind == NodeKind::NODE_CONST {
                return dn.as_data.const_def.is_static_mut;
            }
            // every caller is a genuine mutation requirement (assignment LHS, `&mut`, `&mut self`
            // receiver, mut-slice coercion): a positive answer through a local binding marks it for
            // the unnecessary-mut lint
            if dn.kind == NodeKind::NODE_LET {
                if dn.as_data.let_stmt.is_mutable {
                    self.tc_mark_mut_used(d);
                    return true;
                }
                // Split declaration/initialization: an immutable binding declared WITHOUT a value is
                // assignable; the borrow checker enforces exactly-once on every path. Requiring no
                // mutability is what keeps the C emission const-free only for these bindings.
                return dn.as_data.let_stmt.value == NODE_NONE;
            }
            if dn.kind == NodeKind::NODE_PARAMETER {
                if dn.as_data.parameter.is_mutable {
                    self.tc_mark_mut_used(d);
                    return true;
                }
                return false;
            }
            if dn.kind == NodeKind::NODE_PATTERN_NAME {
                if a.at_const(dn.as_data.pattern.name).as_data.name.is_mutable {
                    self.tc_mark_mut_used(d);
                    return true;
                }
                return false;
            }
            if dn.kind == NodeKind::NODE_IDENTIFIER {
                let letn = a.resolution(d);
                if letn != NODE_NONE && a.at_const(letn).kind == NodeKind::NODE_LET && a.at_const(letn).as_data.let_stmt.is_mutable {
                    self.tc_mark_mut_used(letn);
                    return true;
                }
                return false;
            }
            return false;
        }
        if nk == NodeKind::NODE_UNARY {
            if a.at_const(node).as_data.unary.op != TokenType::Star {
                return false;
            }
            let ot = self.type_at(a.type_of(a.at_const(node).as_data.unary.operand));
            return (ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE) && ot.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
        }
        if nk == NodeKind::NODE_INDEX || nk == NodeKind::NODE_MEMBER {
            if nk == NodeKind::NODE_MEMBER && a.at_const(node).as_data.member.path {
                return self.tc_path_static_mut(node);
            }
            let obj = if_node(
                nk == NodeKind::NODE_INDEX,
                a.at_const(node).as_data.index.object,
                a.at_const(node).as_data.member.object,
            );
            let mut oty = a.type_of(obj);
            let mut via_ref = false;
            let mut ref_mut = false;
            if nk == NodeKind::NODE_INDEX {
                let mut y = *self.type_at(oty);
                while y.kind == TypeKind::TYPE_REFERENCE {
                    via_ref = true;
                    ref_mut = y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
                    oty = y.as_data.elem;
                    y = *self.type_at(oty);
                }
            }
            let mut sk: i32 = 0;
            if nk == NodeKind::NODE_INDEX {
                sk = self.slice_kind(oty, null);
            }
            if sk != 0 {
                return sk == 2;
            }
            let ot = *self.type_at(oty);
            if nk == NodeKind::NODE_INDEX && (ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE) {
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                if !self.aggregate_of(oty, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                    return false;
                }
                let im = self.find_method_cstr(om, od, "index_mut");
                if im.node == NODE_NONE {
                    return false;
                }
                let ia = self.mod_ast(im.module);
                let irs = ia.at_const(im.node).as_data.function.returns;
                if irs.len != 1 {
                    return false;
                }
                let ir0 = unsafe ia.list(irs)[0];
                let irn = ia.at_const(ir0);
                let itn = if_node(irn.kind == NodeKind::NODE_PARAMETER, irn.as_data.parameter.ty, ir0);
                if itn == NODE_NONE || ia.at_const(itn).kind != NodeKind::NODE_REFERENCE_TYPE {
                    return false;
                }
                if via_ref {
                    return ref_mut;
                }
                return self.is_assignable(obj);
            }
            if ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE {
                return ot.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            return self.is_assignable(obj);
        }
        return false;
    }
    /// Syntactic place (lvalue) test; a path member (`E::x`) counts only when it names a 'static mut'.
    pub fn is_place(self: &Self, id: NodeId) bool {
        let node = self.peel_wrappers(id);
        let n = self.cur_ast().at_const(node);
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_INDEX {
            return true;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            return !n.as_data.member.path || self.tc_path_static_mut(node) || self.tc_path_const(node);
        }
        if n.kind == NodeKind::NODE_UNARY {
            return n.as_data.unary.op == TokenType::Star;
        }
        return false;
    }
    fn receiver_mutable(self: &mut Self, recv: NodeId) bool {
        let rt = self.cur_ast().type_of(recv);
        if rt != TYPE_NONE {
            let rty = self.type_at(rt);
            if rty.kind == TypeKind::TYPE_POINTER || rty.kind == TypeKind::TYPE_REFERENCE {
                return rty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
            }
        }
        if self.is_place(recv) {
            return self.is_assignable(recv);
        }
        return true;
    }

    // ---- move / definite-init / free tracking ----
    // Is this borrow root a REFERENCE binding? Such a root does not own the data it names.

    // TC-5: moved[] membership bitset (bit index = decl NodeId). moved[] stays authoritative for
    // flow save/merge; the bits are updated at every mutation site so is_moved is O(1).

    pub fn tc_is_late(self: &Self, decl: NodeId) bool {
        for i in 0..self.nlate {
            if unsafe self.late[i as usize] == decl {
                return true;
            }
        }
        return false;
    }

    pub fn tc_add_late(self: &mut Self, decl: NodeId) {
        if self.tc_is_late(decl) {
            return;
        }
        if self.nlate < 256 {
            let k = self.nlate;
            unsafe self.late[k as usize] = decl;
            self.nlate = k + 1;
        }
    }

    pub fn tc_is_uninit(self: &Self, decl: NodeId) bool {
        for i in 0..self.nuninit {
            if unsafe self.uninit[i as usize] == decl {
                return true;
            }
        }
        return false;
    }

    // ---- flow state save/set/collect ----
    // TC-4b: save/clear fill an uninitialized caller local through an out-param and only touch the
    // counted prefixes -- a by-value `FlowState {}` zero-fills ~3KB twice per branch construct.

    /// Definitely-returns test: a return, a block whose LAST statement returns, an `if` with BOTH
    /// branches returning, or a never-typed expression statement.
    pub fn tc_stmt_returns(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return false;
        }
        let n = self.cur_ast().at_const(id);
        if n.kind == NodeKind::NODE_RETURN {
            return true;
        }
        if n.kind == NodeKind::NODE_BLOCK {
            let ss = n.as_data.block.statements;
            return ss.len != 0 && self.tc_stmt_returns(unsafe self.cur_ast().list(ss)[(ss.len - 1) as usize]);
        }
        if n.kind == NodeKind::NODE_IF {
            return n.as_data.if_stmt.else_branch != NODE_NONE && self.tc_stmt_returns(n.as_data.if_stmt.then_branch) && self.tc_stmt_returns(
                n.as_data.if_stmt.else_branch,
            );
        }
        if n.kind == NodeKind::NODE_EXPRESSION_STATEMENT {
            let ty = self.cur_ast().type_of(n.as_data.single.value);
            return ty != TYPE_NONE && self.type_at(ty).kind == TypeKind::TYPE_NEVER;
        }
        return false;
    }

    // ---- scope / borrow set ----

    fn place_index_const(self: &Self, idx: NodeId, out: *mut i64) bool {
        let n = self.cur_ast().at_const(idx);
        if n.kind != NodeKind::NODE_LITERAL || n.as_data.literal.token_type != TokenType::IntegerLiteral {
            return false;
        }
        let lr = n.as_data.literal.raw;
        let mut p = unsafe (self.source.ptr() + lr.start as usize);
        let mut len = (lr.end - lr.start) as usize;
        let (base, skip) = lit_base_prefix(p, len);
        p = unsafe (p + skip);
        len = len - skip;
        let mut acc: u64 = 0;
        for i in 0..len {
            let ch = unsafe p[i];
            if ch == b'_' {
                continue;
            }
            let mut d: u64 = 0;
            if ch <= b'9' {
                d = ch - b'0';
            } else {
                d = (ch | 0x20u8) - b'a' + 10u8;
            }
            if d >= base || acc > (0x7FFFFFFFFFFFFFFFi64 - d as i64) as u64 / base {
                return false;
            }
            acc = acc * base + d;
        }
        unsafe *out = acc as i64;
        return true;
    }

    fn tc_type_is_union(self: &Self, ty: TypeId) bool {
        let mut m: ModuleId = 0;
        let mut d = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if ty == TYPE_NONE || !self.aggregate_of(ty, &mut m, &mut d, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        let dn = self.mod_ast(m).at_const(d);
        return dn.kind == NodeKind::NODE_STRUCT && dn.as_data.aggregate.is_union;
    }

    /// Decompose a place `x.f[i]...` into its root binding + access steps (leaf-first). Returns the
    /// root local decl, or NODE_NONE when the chain crosses a raw pointer, indexes through a
    /// reference, or does not end at a local binding. A union member access drops the steps below it
    /// (all members overlap).
    pub fn place_decompose(self: &mut Self, place0: NodeId, steps: *mut PStep, nsteps: *mut i32, cap: i32) NodeId {
        unsafe *nsteps = 0;
        let a = self.cur_ast();
        let mut place = place0;
        loop {
            let pn = a.at_const(place);
            if pn.kind == NodeKind::NODE_UNARY && (pn.as_data.unary.op == TokenType::Move || pn.as_data.unary.op == TokenType::Unsafe) {
                place = pn.as_data.unary.operand;
                continue;
            }
            if pn.kind == NodeKind::NODE_UNARY && pn.as_data.unary.op == TokenType::Star {
                let op = pn.as_data.unary.operand;
                let ot = a.type_of(op);
                if ot == TYPE_NONE || self.type_at(ot).kind != TypeKind::TYPE_REFERENCE {
                    return NODE_NONE;
                }
                if unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = PStep { kind: PS_DEREF };
                    unsafe *nsteps = k + 1;
                }
                place = op;
                continue;
            }
            let mut base = NODE_NONE;
            let mut step = PStep { kind: PS_FIELD };
            if pn.kind == NodeKind::NODE_MEMBER && !pn.as_data.member.path {
                base = pn.as_data.member.object;
                step.kind = PS_FIELD;
                step.name = self.name_span(pn.as_data.member.member);
            } else if pn.kind == NodeKind::NODE_INDEX {
                base = pn.as_data.index.object;
                step.kind = PS_INDEX;
                let mut v: i64 = 0;
                if self.place_index_const(pn.as_data.index.index, &mut v) {
                    step.index_const = true;
                    step.index_val = v;
                }
            } else {
                break;
            }
            let bt = a.type_of(base);
            if bt == TYPE_NONE {
                return NODE_NONE;
            }
            let btk = *self.type_at(bt);
            let mut union_ty = bt;
            if btk.kind == TypeKind::TYPE_REFERENCE {
                union_ty = btk.as_data.elem;
            }
            let base_union = pn.kind == NodeKind::NODE_MEMBER && self.tc_type_is_union(union_ty);
            if base_union {
                unsafe *nsteps = 0;
            }
            if btk.kind == TypeKind::TYPE_REFERENCE {
                if pn.kind == NodeKind::NODE_INDEX {
                    return NODE_NONE;
                }
                if !base_union && unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = step;
                    unsafe *nsteps = k + 1;
                }
                if unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = PStep { kind: PS_DEREF };
                    unsafe *nsteps = k + 1;
                }
                place = base;
                continue;
            }
            if btk.kind == TypeKind::TYPE_POINTER {
                return NODE_NONE;
            }
            if pn.kind == NodeKind::NODE_INDEX && btk.kind != TypeKind::TYPE_ARRAY {
                // An overloaded Index result views the container it was called on, so `v[i]` is a
                // sub-place of `v`; unlike a real array, distinct constant indices prove nothing
                // about distinct storage, so they must keep overlapping.
                step.index_const = false;
            }
            if !base_union && unsafe *nsteps < cap {
                let k = unsafe *nsteps;
                unsafe steps[k as usize] = step;
                unsafe *nsteps = k + 1;
            }
            place = base;
        }
        if a.at_const(place).kind != NodeKind::NODE_IDENTIFIER {
            return NODE_NONE;
        }
        let d = a.resolution_def(place);
        if d.node == NODE_NONE || d.module != self.cur_module() {
            return NODE_NONE;
        }
        let dk = a.at_const(d.node).kind;
        if dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_FOR {
            return d.node;
        }
        return NODE_NONE;
    }
    /// Do two places alias? Conservative: same root required; differing field names or differing
    /// constant indices prove disjoint, everything else (unknown indices, step-kind mismatch) reports
    /// overlap. False whenever either place fails to decompose.
    pub fn places_overlap(self: &mut Self, aN: NodeId, bN: NodeId) bool {
        let mut sa = Steps16 {};
        let mut sb = Steps16 {};
        let mut na: i32 = 0;
        let mut nb: i32 = 0;
        let ra = self.place_decompose(aN, &mut sa[0], &mut na, PLACE_MAX_STEPS);
        let rb = self.place_decompose(bN, &mut sb[0], &mut nb, PLACE_MAX_STEPS);
        if ra == NODE_NONE || rb == NODE_NONE || ra != rb {
            return false;
        }
        let mut common = na;
        if nb < na {
            common = nb;
        }
        for i in 0..common {
            let pa = sa[(na - 1 - i) as usize];
            let pb = sb[(nb - 1 - i) as usize];
            if pa.kind != pb.kind {
                return true;
            }
            if pa.kind == PS_FIELD {
                let la = pa.name.end - pa.name.start;
                let lb = pb.name.end - pb.name.start;
                if la != lb || unsafe cstring::memcmp(
                    self.source.ptr() + pa.name.start as usize,
                    self.source.ptr() + pb.name.start as usize,
                    la as usize,
                ) != 0 {
                    return false;
                }
            } else if pa.kind == PS_INDEX && pa.index_const && pb.index_const && pa.index_val != pb.index_val {
                return false;
            }
        }
        return true;
    }

    // The owning binding at the base of an assignable PLACE, walking field / index / deref steps
    // down to the root identifier (`s.r.x` -> s, `arr[i]` -> arr, `*p` -> p). Unlike
    // place_through_binding this does not require the chain to pass through a reference -- it is the
    // root a stored borrow's region must be checked against.

    // When a method/index result REBORROWS its receiver -- the receiver is itself a view carrying a
    // borrow, so the result views the same underlying storage -- the result must INHERIT the borrows
    // the receiver holds of the real container, not silently drop them. `let s = v[0..3]` retains a
    // borrow of `v` tied to `s`; a sub-view `let sub = s[0..2]` reborrows `s`, and without inheriting
    // `s`'s borrow of `v`, `sub` stops pinning `v` the moment `s`'s own borrow ends -> `v` reallocates
    // and `sub` dangles. Re-expose each borrow held by the receiver as a fresh transient borrow rooted
    // at the same container, so the enclosing `let`/store ties it to the result binding.

    // A `[..]` slice result views its source's storage: mint (source owns its data) or inherit (source
    // is itself a view) a borrow of the source so the container cannot be reallocated while the slice
    // is live. Shared by both range exits -- an `index_range` method result and a `prelude_slice_type`
    // result (the latter covers a slice-of-a-slice, which `slice_kind` handles before index_range).

    /// The local binding a place reaches THROUGH a reference (`*p` -> p, `r.f` with `r: &T` -> r), or
    /// NODE_NONE when no hop dereferences a reference binding.
    pub fn place_through_binding(self: &Self, place0: NodeId) NodeId {
        let a = self.cur_ast();
        let mut place = place0;
        loop {
            let pn = a.at_const(place);
            let mut base = NODE_NONE;
            if pn.kind == NodeKind::NODE_UNARY && pn.as_data.unary.op == TokenType::Star {
                base = pn.as_data.unary.operand;
            } else if pn.kind == NodeKind::NODE_MEMBER && !pn.as_data.member.path {
                base = pn.as_data.member.object;
            } else if pn.kind == NodeKind::NODE_INDEX {
                base = pn.as_data.index.object;
            } else {
                return NODE_NONE;
            }
            let bt = a.type_of(base);
            let mut is_ref = false;
            if bt != TYPE_NONE && self.type_at(bt).kind == TypeKind::TYPE_REFERENCE {
                is_ref = true;
            }
            if (pn.kind == NodeKind::NODE_UNARY || is_ref) && a.at_const(base).kind == NodeKind::NODE_IDENTIFIER {
                let d = a.resolution_def(base);
                if d.node != NODE_NONE && d.module == self.cur_module() {
                    return d.node;
                }
                return NODE_NONE;
            }
            place = base;
        }
    }

    // Drop the borrow(s) produced by `origin` -- used where a reference is erased into a raw pointer.

    /// TC-3: one pass over the resolution table records, per local decl, the LAST node that
    /// resolves to it. "any use after `after`" then collapses to one compare. Typechecker-added
    /// resolutions never target a value binding except break/continue -> loop node (a `for` node IS
    /// its loop binding), which tc_note_resolution folds in at the set site.
    pub fn tc_build_last_use(self: &mut Self) {
        self.last_use_built = true;
        let n = unsafe self.cur_ast().nodes.len();
        self.last_use.clear();
        let mut i: usize = 0;
        while i < n {
            self.last_use.push(NODE_NONE);
            i = i + 1;
        }
        let mut nid: NodeId = 0;
        while nid as usize < n {
            let rd = self.cur_ast().resolution_def(nid);
            if rd.node != NODE_NONE && rd.module == self.cur_module() && rd.node as usize < n {
                self.last_use.set(rd.node as usize, nid);
            }
            nid = nid + 1;
        }
    }
    const fn tc_note_resolution(self: &mut Self, ref_id: NodeId, decl: NodeId) {
        if self.last_use_built && decl as usize < self.last_use.len() && ref_id > self.last_use[decl as usize] {
            self.last_use.set(decl as usize, ref_id);
        }
    }

    // Is a binding confined to the CURRENT innermost loop's body? Such a binding is re-created every
    // iteration and dies at the end of each one, so no use of it can execute after a given point via
    // the back edge -- which is exactly the condition that makes source-order last-use reasoning valid
    // inside a loop. A binding declared at or outside the loop's entry depth can be used again on the
    // next iteration (after the point in execution order, though before it in source order).

    // ---- escape analysis ----

    // True if a value of this type can carry a borrow out of the scope that produced it: a reference,
    // an aggregate that declares a lifetime param, an instance whose generic ARG is borrowing
    // (`Vector<&i32>`), or an aggregate with a reference-typed field, transitively. Conservative --
    // a spurious `true` only over-rejects, never under-rejects.
    // Memoized entry: does a value of this type carry a borrow (a reference, an aggregate/instance
    // holding one, transitively, or a type with a lifetime param)? Pure function of the interned type.

    // Does method parameter `pdecl` share a borrow-carrying TYPE VARIABLE with the receiver?
    // This is the Rust argument-boundary rule that makes `Vector<&'a T>::push(&mut self, value: T)`
    // reject a too-short borrow with NO "does it store" flag: `value: T` and the container's elements
    // are the SAME `T`, so they share `T`'s region. When `T` is instantiated to a borrow-carrying type
    // (`&i32`), the argument passed for `value` must outlive the receiver -- by variance, whether or
    // not push actually stores it. Returns true when pdecl's declared type is exactly a generic
    // parameter that the receiver aggregate instantiates with a borrow-carrying type.

    // The referent a `&mut <place>`/`&<place>` argument points at (its base binding), or the arg's own
    // base binding when a place is passed directly. Used to region-tie borrows stored through it.

    // Every lifetime NAME a type node mentions, anywhere: the annotation on a reference, and the
    // lifetime arguments of an aggregate (`Ref<'a>`), recursively. A value parameter shares a region
    // with a storage parameter whenever ANY of these matches -- reading only the outermost reference's
    // annotation missed `src: Ref<'a>`, an aggregate that borrows just as much as `&'a i32` does.

    // Does a `&mut` storage pointee TYPE NODE mention the named lifetime `lt` (compared in module `m`)?
    // Either it is an aggregate carrying `lt` as a lifetime argument (`Slot<'a>`), or it is itself a
    // reference with that lifetime (`&mut &'a T`). Lifetime args are read off the AST node, not the
    // interned type, since lifetimes are erased from `Ty`.

    // Does the pointee `elem` of a `&mut` storage parameter mention the type variable (`vd`,`vm`)?
    // Either it IS that variable (`&mut T`) or it is an aggregate carrying it as a generic argument
    // (`&mut Vector<T>`, `&mut Cell<T>`). Storing a value of that variable through such a parameter
    // stores it into `elem`'s container.

    // The interned generic ELEMENT of a `&mut T` parameter (T a callee type variable), or TYPE_NONE.
    // Does a type mention a callee TYPE VARIABLE anywhere inside it? `T`, `Cell<T>`, `&T`, `[T; N]`
    // all do. Used to find the `&mut` parameters whose pointee the caller instantiates.

    // The POINTEE of a `&mut` parameter, when that pointee mentions a callee type variable. `&mut` is
    // invariant in its pointee unconditionally -- no per-aggregate variance needed -- so two arguments
    // passed for the SAME pointee type must have equal regions. Covers `&mut T` and `&mut Cell<T>`
    // alike; the latter was a hole while this only recognised a bare type variable.
    // Copy the content borrows a `&mut T` argument's referent holds onto the OTHER `&mut T` argument's
    // referent. `&mut T` is INVARIANT in T: a function may write either referent's content into the
    // other (`swap`), so each must outlive the other's referent lifetime. The copied borrow is bound
    // to `to_ref` at `to_ref`'s region, so scope exit reports `to_ref` outliving `from_ref`'s content.
    // `&mut T` invariance across a call: two parameters `&mut T` for the SAME callee type variable can
    // have their contents swapped, so their arguments' referents must have equal lifetime. Cross-tie
    // the content borrows both ways; a no-op when T is not a borrow-carrier (no content borrows exist).

    // ---- lifetime elision (Rust's three rules) ----
    // Rule 1 is structural: every elided INPUT position is its own fresh lifetime, which is why two
    // elided parameters never share a region. Rules 2 and 3 say which lifetime an elided OUTPUT gets:
    // with exactly one input position it takes that one; with a `&self` receiver it takes self's.
    // When neither applies the output's region is unconstrained -- the caller cannot tell what it
    // borrows -- so it must be written, exactly as Rust demands.
    //
    // Counts lifetime POSITIONS in a type: each reference, and each lifetime argument slot of a
    // borrowing aggregate, whether written or elided.

    // Does this type have an ELIDED lifetime position -- a reference with no annotation, or a
    // borrowing aggregate given no lifetime argument?

    // Apply rules 2 and 3 to a signature: an elided output lifetime must be determined by a `&self`
    // receiver or by there being exactly one input position.

    // A reference stored in an aggregate must NAME the lifetime it borrows for, and that lifetime must
    // be one the aggregate declares (or `'static`). Rust's "missing lifetime specifier": without it the
    // field's region is unrelated to anything the type says, so no caller can reason about how long the
    // aggregate may be kept. Declaring `<'a>` is what makes the borrow checkable at every use site.

    // `T: 'a` bounds, enforced at the call site. The bound promises every region inside the type
    // substituted for `T` outlives `'a`; it was parsed and ignored, so a callee could rely on a
    // guarantee the caller never had to meet. The checkable case here is `T: 'static` -- the argument's
    // type must then carry no borrow at all, since nothing borrowed from a local outlives the program.
    // A bound naming a signature lifetime is left to the argument-boundary tie, which already relates
    // the argument's region to that lifetime's.

    // Does generic param `g` of `fdecl` carry a `'static` bound, written inline (`<T: 'static>`) or in
    // the where clause (`where T: 'static`)?

    // Family B: a borrow passed for a bare value parameter `x: T` that ANOTHER parameter stores through
    // (`dst: &mut T` or `dst: &mut C<..T..>`) must outlive that storage's referent -- the Rust
    // argument-boundary variance rule across a plain function boundary (bug6 covered only the receiver-
    // as-container case of a method). Tie this call's argument borrows to the storage argument's
    // referent region; the existing scope-exit check then reports a referent that dies while the
    // container holding it lives on. Excludes the storage arg's own borrow (rooted at the container).

    // Region-aware return check. `addr_escape` only recognizes a reference taken DIRECTLY of a local
    // or parameter (`return &x`). It misses a borrow that reaches the caller indirectly -- e.g.
    // `return b.get()` where `b` is a local `Box` (the reference points into b's heap cell, not into
    // b's own storage, so no `&local` is ever seen, yet the cell is freed when b drops at return), or
    // a borrow buried in a returned aggregate (`return R { p: &local }`).
    //
    // Rule: evaluating the returned expression may CREATE borrows; any of those still live and rooted
    // at a binding declared inside this function dies at return, so if the returned value can carry a
    // borrow out at all, that is a dangling return. `bm` is the watermark taken before the operands.

    // ---- extend conformance ----
    fn find_extend_item_named(self: &Self, extnode: NodeId, name: tok::Span, nmod: ModuleId) NodeId {
        let a = self.cur_ast();
        let have = a.at_const(extnode).as_data.extend_def.items;
        for j in 0..have.len {
            let hid = unsafe a.list(have)[j as usize];
            let hm = a.at_const(hid);
            if hm.kind == NodeKind::NODE_FUNCTION && spans_eq2(
                self.mod_src(nmod),
                name,
                self.source,
                a.at_const(hm.as_data.function.name).as_data.name.text,
            ) {
                return hid;
            }
        }
        return NODE_NONE;
    }
    // An interface type node `Self::Assoc` projected to the IMPL's concrete associated type (`type
    // Assoc = X` in the extend), or TYPE_NONE if the node is not such a projection. This is what lets a
    // method returning `Self::Item` conform: the interface's abstract `Self::Item` becomes the impl's i32.
    fn tc_project_self_assoc(self: &mut Self, m: ModuleId, tynode: NodeId, ext: NodeId) TypeId {
        if tynode == NODE_NONE || ext == NODE_NONE {
            return TYPE_NONE;
        }
        let n = self.mod_ast(m).at_const(tynode);
        if n.kind != NodeKind::NODE_TYPE_PATH || n.as_data.type_path.parts.len < 2 {
            return TYPE_NONE;
        }
        let p0 = unsafe self.mod_ast(m).list(n.as_data.type_path.parts)[0];
        if !span_is(self.mod_src(m), self.mod_ast(m).at_const(p0).as_data.name.text, "Self") {
            return TYPE_NONE;
        }
        let assoc = self.mod_ast(m).at_const(unsafe self.mod_ast(m).list(n.as_data.type_path.parts)[1]).as_data.name.text;
        let hm = self.tc_find_extend_alias(ext, assoc, m);
        if hm == NODE_NONE {
            return TYPE_NONE;
        }
        let aliased = self.cur_ast().at_const(hm).as_data.type_alias.ty;
        if aliased == NODE_NONE {
            return TYPE_NONE;
        }
        return self.lower_type_in(self.cur_module(), aliased);
    }

    // The interface-side type for a conformance comparison: a `Self::Assoc` projects through the impl;
    // otherwise it is lowered and substituted with the interface's generic arguments as before.
    fn tc_iface_cmp_type(
        self: &mut Self,
        m: ModuleId,
        tynode: NodeId,
        ext: NodeId,
        subp: *const DefId,
        suba: *const TypeId,
        nsub: i32,
    ) TypeId {
        let proj = self.tc_project_self_assoc(m, tynode, ext);
        if proj != TYPE_NONE {
            return proj;
        }
        return self.subst_type(self.lower_type_in(m, tynode), subp, suba, nsub);
    }

    fn extend_method_signature_matches(
        self: &mut Self,
        req: DefId,
        have: NodeId,
        ext: NodeId,
        subp: *const DefId,
        suba: *const TypeId,
        nsub: i32,
    ) bool {
        let ra = self.mod_ast(req.module);
        let rf = ra.at_const(req.node).as_data.function;
        let hf = self.cur_ast().at_const(have).as_data.function;
        if rf.params.len != hf.params.len {
            return false;
        }
        for i in 0..rf.params.len {
            let rp = unsafe ra.list(rf.params)[i as usize];
            let hp = unsafe self.cur_ast().list(hf.params)[i as usize];
            let rt = self.tc_iface_cmp_type(req.module, ra.at_const(rp).as_data.parameter.ty, ext, subp, suba, nsub);
            let ht = self.lower_type_in(self.cur_module(), self.cur_ast().at_const(hp).as_data.parameter.ty);
            if rt != ht && (i != 0 || !self.receiver_type_eq(rt, ht)) {
                return false;
            }
        }
        if rf.returns.len != hf.returns.len {
            if rf.returns.len > 1 || hf.returns.len > 1 {
                return false;
            }
            let mut rt: TypeId = TYPE_NONE;
            let mut ht: TypeId = TYPE_NONE;
            if rf.returns.len == 1 {
                let rr = unsafe ra.list(rf.returns)[0];
                let rn = ra.at_const(rr);
                rt = self.tc_iface_cmp_type(
                    req.module,
                    if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rr),
                    ext,
                    subp,
                    suba,
                    nsub,
                );
            }
            if hf.returns.len == 1 {
                let hr = unsafe self.cur_ast().list(hf.returns)[0];
                let hn = self.cur_ast().at_const(hr);
                ht = self.lower_type_in(
                    self.cur_module(),
                    if_node(hn.kind == NodeKind::NODE_PARAMETER, hn.as_data.parameter.ty, hr),
                );
            }
            return self.ret_eq(rt, ht);
        }
        for k in 0..rf.returns.len {
            let rr = unsafe ra.list(rf.returns)[k as usize];
            let hr = unsafe self.cur_ast().list(hf.returns)[k as usize];
            let rn = ra.at_const(rr);
            let hn = self.cur_ast().at_const(hr);
            let rt = self.tc_iface_cmp_type(
                req.module,
                if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rr),
                ext,
                subp,
                suba,
                nsub,
            );
            let ht = self.lower_type_in(
                self.cur_module(),
                if_node(hn.kind == NodeKind::NODE_PARAMETER, hn.as_data.parameter.ty, hr),
            );
            if !self.ret_eq(rt, ht) {
                return false;
            }
        }
        return true;
    }
    // A type alias named `name` among an extend's items, or NODE_NONE.
    fn tc_find_extend_alias(self: &Self, extnode: NodeId, name: tok::Span, nmod: ModuleId) NodeId {
        let a = self.cur_ast();
        let have = a.at_const(extnode).as_data.extend_def.items;
        for j in 0..have.len {
            let hid = unsafe a.list(have)[j as usize];
            let hm = a.at_const(hid);
            if hm.kind == NodeKind::NODE_TYPE_ALIAS && spans_eq2(
                self.mod_src(nmod),
                name,
                self.source,
                a.at_const(hm.as_data.type_alias.name).as_data.name.text,
            ) {
                return hid;
            }
        }
        return NODE_NONE;
    }

    fn check_interface_requirements(
        self: &mut Self,
        extnode: NodeId,
        iface: DefId,
        self_ty: TypeId,
        subp: *const DefId,
        suba: *const TypeId,
        nsub: i32,
        depth: i32,
    ) {
        if iface.node == NODE_NONE || depth > 8 {
            return;
        }
        let ia = self.mod_ast(iface.module);
        if ia.at_const(iface.node).kind != NodeKind::NODE_INTERFACE {
            return;
        }
        let req = ia.at_const(iface.node).as_data.interface_def.items;
        for i in 0..req.len {
            let rid = unsafe ia.list(req)[i as usize];
            let rm = ia.at_const(rid);
            // An ASSOCIATED TYPE requirement (`type Item<'a>;` -- no definition). The impl must
            // provide it with the same lifetime and type-generic arity: the interface's declared
            // shape is a contract even though lifetimes are erased from the interned types.
            if rm.kind == NodeKind::NODE_TYPE_ALIAS && rm.as_data.type_alias.ty == NODE_NONE {
                let rn = ia.at_const(rm.as_data.type_alias.name).as_data.name.text;
                let hm = self.tc_find_extend_alias(extnode, rn, iface.module);
                let at = self.cur_ast().at_const(self.cur_ast().at_const(extnode).as_data.extend_def.interface_type).span;
                if hm == NODE_NONE {
                    self.errors.emit(
                        at.start,
                        at.end - at.start,
                        format(
                            "missing associated type '{}' required by this interface",
                            diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                        ),
                    );
                } else {
                    let want_lt = ia.lifetimes_of(rid).len;
                    let have_lt = self.cur_ast().lifetimes_of(hm).len;
                    let want_g = rm.as_data.type_alias.generics.len;
                    let have_g = self.cur_ast().at_const(hm).as_data.type_alias.generics.len;
                    if want_lt != have_lt || want_g != have_g {
                        let hat = self.cur_ast().at_const(hm).span;
                        self.errors.emit(
                            hat.start,
                            hat.end - hat.start,
                            format(
                                "associated type '{}' does not match the interface: it declares {} lifetime and {} type parameter(s)",
                                diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                                want_lt,
                                want_g,
                            ),
                        );
                    }
                }
                continue;
            }
            if rm.kind == NodeKind::NODE_FUNCTION && rm.as_data.function.body == NODE_NONE {
                let rn = ia.at_const(rm.as_data.function.name).as_data.name.text;
                let hm = self.find_extend_item_named(extnode, rn, iface.module);
                let reqdef = DefId { module: iface.module, node: rid };
                if hm == NODE_NONE {
                    let at = self.cur_ast().at_const(self.cur_ast().at_const(extnode).as_data.extend_def.interface_type).span;
                    self.errors.emit(
                        at.start,
                        at.end - at.start,
                        format(
                            "missing method '{}' required by this interface",
                            diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                        ),
                    );
                } else if !self.extend_method_signature_matches(reqdef, hm, extnode, subp, suba, nsub) {
                    let at = self.cur_ast().at_const(hm).span;
                    self.errors.emit(
                        at.start,
                        at.end - at.start,
                        format(
                            "method '{}' does not match interface signature",
                            diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                        ),
                    );
                } else {
                    self.check_method_qualifiers(reqdef, hm, rn);
                }
            }
        }
        let bounds = ia.at_const(iface.node).as_data.interface_def.bounds;
        for i in 0..bounds.len {
            let sb = ia.resolution_def(unsafe ia.list(bounds)[i as usize]);
            if sb.node != NODE_NONE && !self.type_satisfies(self_ty, sb, 0) {
                let at = self.cur_ast().at_const(self.cur_ast().at_const(extnode).as_data.extend_def.interface_type).span;
                self.errors.emit(at.start, at.end - at.start, format("type does not satisfy required superinterface"));
            }
        }
    }
    // `Send` and `Sync` are the two conformances the compiler cannot verify. Every other interface is checked
    // against its requirements; these two are DERIVED structurally, and writing one by hand overrides that
    // derivation -- it asserts a synchronisation discipline living outside the type system (an `Arc`'s
    // refcount, a `Mutex`'s lock, an atomic instruction). Nothing checks the claim, so the claim is marked:
    // `unsafe extend` puts every such assertion one grep away from an audit.
    fn check_marker_is_unsafe(self: &mut Self, id: NodeId, iface: DefId) {
        let send = self.is_send_iface(iface);
        if !send && !self.is_sync_iface(iface) {
            return;
        }
        if self.cur_ast().at_const(id).as_data.extend_def.is_unsafe {
            return;
        }
        let itype = self.cur_ast().at_const(id).as_data.extend_def.interface_type;
        let sp = self.cur_ast().at_const(itype).span;
        let name = if send {
            "Send";
        } else {
            "Sync";
        };
        self.errors.emit(sp.start, sp.end - sp.start, format("asserting '{}' requires 'unsafe extend'", name));
        self.errors.note(
            format(
                "{}",
                "nothing verifies this: write 'unsafe extend' to take responsibility for it, or let the compiler derive the marker from the fields",
            ),
        );
    }

    // An interface method's `const` and `unsafe` are part of the REQUIREMENT, not decoration on it.
    //
    // `unsafe` must match exactly, and the direction that matters is an implementation MORE unsafe than its
    // declaration: a caller reaching it through the bound sees the safe declaration, promises nothing, and
    // lands in an unsafe body -- the mark laundered away by the interface. The other direction is only
    // confusing (a direct call needs no mark while a call through the bound does), so both are errors and
    // the two signatures simply agree.
    //
    // `const` only has to be strong ENOUGH. An implementation may be `const fn` where the interface asks for
    // a plain one -- it is more capable, and `std` leans on this throughout (`Array as Default` is const
    // where `Default` is not). It may not be plain where the interface asks for `const`, or a `const fn`
    // calling through the bound would fail at the fold, far from the implementation that caused it.
    fn check_method_qualifiers(self: &mut Self, req: DefId, hm: NodeId, rn: tok::Span) {
        let rf = self.mod_ast(req.module).at_const(req.node).as_data.function;
        let hf = self.cur_ast().at_const(hm).as_data.function;
        let at = self.cur_ast().at_const(hm).span;
        let name = diag::span_str(self.mod_src(req.module), rn.start, rn.end);
        if rf.is_unsafe != hf.is_unsafe {
            let what = if rf.is_unsafe {
                "is declared 'unsafe fn' by this interface";
            } else {
                "is not declared 'unsafe fn' by this interface, so a caller through the bound makes no promise";
            };
            self.errors.emit(at.start, at.end - at.start, format("method '{}' {}", name, what));
        }
        if rf.is_const && !hf.is_const {
            self.errors.emit(
                at.start,
                at.end - at.start,
                format("method '{}' is declared 'const fn' by this interface", name),
            );
        }
    }

    fn check_extend_conformance(self: &mut Self, id: NodeId) {
        let iface = self.cur_ast().resolution_def(self.cur_ast().at_const(id).as_data.extend_def.interface_type);
        if iface.node == NODE_NONE {
            return;
        }
        self.check_marker_is_unsafe(id, iface);
        let target = self.cur_ast().at_const(id).as_data.extend_def.target_type;
        let self_ty = self.resolve_type(target);
        let mut subp = Defs8 {};
        let mut suba = Tys8 {};
        let mut nsub: i32 = 0;
        subp[0] = DefId { module: iface.module, node: iface.node };
        suba[0] = self_ty;
        nsub = 1;
        let ia = self.mod_ast(iface.module);
        let itype = self.cur_ast().at_const(id).as_data.extend_def.interface_type;
        if ia.at_const(iface.node).kind == NodeKind::NODE_INTERFACE && self.cur_ast().at_const(itype).kind == NodeKind::NODE_TYPE_PATH {
            let gens = ia.at_const(iface.node).as_data.interface_def.generics;
            let targs = self.cur_ast().at_const(itype).as_data.type_path.args;
            let mut i: u32 = 0;
            while i < gens.len && i < targs.len && nsub < 8 {
                let gid = unsafe ia.list(gens)[i as usize];
                subp[nsub as usize] = DefId { module: iface.module, node: gid };
                suba[nsub as usize] = self.resolve_type(unsafe self.cur_ast().list(targs)[i as usize]);
                nsub = nsub + 1;
                i = i + 1;
            }
            // A parameter the conformance did not spell takes its DEFAULT -- `Mul<Rhs = Self>` written as a
            // bare `as Mul`. Lowered through the frame built so far, so `Self` in the default is the
            // implementing type and a later default may name an earlier parameter.
            while i < gens.len && nsub < 8 {
                let gid = unsafe ia.list(gens)[i as usize];
                let dft = ia.at_const(gid).as_data.generic_param.default_type;
                if dft == NODE_NONE {
                    break;
                }
                let d = self.lower_type_in(iface.module, dft);
                subp[nsub as usize] = DefId { module: iface.module, node: gid };
                suba[nsub as usize] = self.subst_type(d, &subp[0], &suba[0], nsub);
                nsub = nsub + 1;
                i = i + 1;
            }
        }
        self.check_interface_requirements(id, iface, self_ty, &subp[0], &suba[0], nsub, 0);
    }

    // ---- operators ----
    fn method_recv_subst(self: &mut Self, recv: TypeId, md: DefId, rsubp: *mut DefId, rsuba: *mut TypeId) i32 {
        let mut nrsub: i32 = 0;
        let rvy = *self.type_at(self.strip(recv));
        if rvy.kind == TypeKind::TYPE_DYN {
            // dyn receiver over an instantiated generic interface: map the interface's generic
            // params to the dyn type's arguments (method sigs mention them directly)
            let dinst = *self.cur_ast().instance(rvy.as_data.inst);
            if dinst.n > 0 && self.mod_ast(dinst.module).at_const(dinst.decl).kind == NodeKind::NODE_INTERFACE {
                let ig = self.mod_ast(dinst.module).at_const(dinst.decl).as_data.interface_def.generics;
                let mut gi: u8 = 0;
                while gi < dinst.n && gi as u32 < ig.len && nrsub < 8 {
                    unsafe rsubp[nrsub as usize] = DefId {
                        module: dinst.module,
                        node: unsafe self.mod_ast(dinst.module).list(ig)[gi as usize],
                    };
                    unsafe rsuba[nrsub as usize] = unsafe dinst.args[gi as usize];
                    nrsub = nrsub + 1;
                    gi = gi + 1;
                }
                return nrsub;
            }
        }
        let mut rmod: ModuleId = 0;
        let mut rdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut sn: i32 = 0;
        let agok = self.aggregate_of(self.strip(recv), &mut rmod, &mut rdecl, &mut gp, &mut ga, &mut sn);
        if agok && sn > 0 {
            let extnode = self.enclosing_extend(md.module, md.node);
            if extnode != NODE_NONE {
                let ma = self.mod_ast(md.module);
                let ig = ma.at_const(extnode).as_data.extend_def.generics;
                let mut g = ig.len as i32;
                if sn < g {
                    g = sn;
                }
                let mut i: i32 = 0;
                while i < g && nrsub < 8 {
                    let gid = unsafe ma.list(ig)[i as usize];
                    unsafe rsubp[nrsub as usize] = DefId { module: md.module, node: gid };
                    unsafe rsuba[nrsub as usize] = ga[i as usize];
                    nrsub = nrsub + 1;
                    i = i + 1;
                }
            }
        }
        return nrsub;
    }
    /// Method `md`'s single return type as seen on receiver `recv` (owner-extend / dyn-interface
    /// generics substituted); void when none is declared, TYPE_NONE for multi-return methods.
    pub fn tc_method_ret(self: &mut Self, recv: TypeId, md: DefId) TypeId {
        let fa = self.mod_ast(md.module);
        let fnn = fa.at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.returns.len > 1 {
            return TYPE_NONE;
        }
        if fnn.as_data.function.returns.len == 0 {
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let nrsub = self.method_recv_subst(recv, md, &mut rsubp[0], &mut rsuba[0]);
        let r0 = unsafe fa.list(fnn.as_data.function.returns)[0];
        let rn = fa.at_const(r0);
        let ret = self.lower_type_in(
            md.module,
            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
        );
        return self.subst_type(ret, &rsubp[0], &rsuba[0], nrsub);
    }
    /// Method `md`'s parameter `idx` type on receiver `recv`, with the same substitution as tc_method_ret.
    pub fn tc_method_param(self: &mut Self, recv: TypeId, md: DefId, idx: i32) TypeId {
        let fa = self.mod_ast(md.module);
        let fnn = fa.at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.params.len as i32 <= idx {
            return TYPE_NONE;
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let nrsub = self.method_recv_subst(recv, md, &mut rsubp[0], &mut rsuba[0]);
        let p = unsafe fa.list(fnn.as_data.function.params)[idx as usize];
        let pn = fa.at_const(p);
        let pt = self.lower_type_in(md.module, if_node(pn.kind == NodeKind::NODE_PARAMETER, pn.as_data.parameter.ty, p));
        return self.subst_type(pt, &rsubp[0], &rsuba[0], nrsub);
    }
    fn method_self_kind(self: &mut Self, md: DefId) i32 {
        let fa = self.mod_ast(md.module);
        let fnn = fa.at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.params.len == 0 {
            return 0;
        }
        let pt = self.decl_type_in(md.module, unsafe fa.list(fnn.as_data.function.params)[0]);
        let y = self.type_at(pt);
        if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
            return 0;
        }
        if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return 2;
        }
        return 1;
    }
    fn operand_fits_param(self: &mut Self, pt: TypeId, operand: NodeId) bool {
        if pt == TYPE_NONE || self.compatible(pt, operand) {
            return true;
        }
        let p = *self.type_at(pt);
        return p.kind == TypeKind::TYPE_REFERENCE && self.compatible(p.as_data.elem, operand);
    }
}

// Compound-assignment token -> the same overload method its binary form uses ("<<=" -> shl).
const fn compound_method_name(op: TokenType) str<'static> {
    if op == TokenType::PlusEqual {
        return "add";
    }
    if op == TokenType::MinusEqual {
        return "sub";
    }
    if op == TokenType::StarEqual {
        return "mul";
    }
    if op == TokenType::SlashEqual {
        return "div";
    }
    if op == TokenType::PercentEqual {
        return "rem";
    }
    if op == TokenType::AmpersandEqual {
        return "bit_and";
    }
    if op == TokenType::PipeEqual {
        return "bit_or";
    }
    if op == TokenType::CaretEqual {
        return "bit_xor";
    }
    if op == TokenType::LeftShiftEqual {
        return "shl";
    }
    if op == TokenType::RightShiftEqual {
        return "shr";
    }
    return "";
}

const fn arith_method_name(op: TokenType) str<'static> {
    if op == TokenType::Plus {
        return "add";
    }
    if op == TokenType::Minus {
        return "sub";
    }
    if op == TokenType::Star {
        return "mul";
    }
    if op == TokenType::Slash {
        return "div";
    }
    if op == TokenType::Percent {
        return "rem";
    }
    if op == TokenType::Ampersand {
        return "bit_and";
    }
    if op == TokenType::Pipe {
        return "bit_or";
    }
    if op == TokenType::Caret {
        return "bit_xor";
    }
    if op == TokenType::LeftShift {
        return "shl";
    }
    if op == TokenType::RightShift {
        return "shr";
    }
    return "";
}

// Only when every part divides exactly: `{(N * 4) / 2}` is `{N * 2}`, and `{N / 2}` is not an integer
// form of anything this can compare.
fn lin_divide(src: &ConstLin, d: i64, out: &mut ConstLin) bool {
    if d == 0 || src.k % d != 0 {
        return false;
    }
    out.k = out.k + src.k / d;
    for i in 0..src.n {
        let c = unsafe src.c[i as usize];
        if c % d != 0 {
            return false;
        }
        if !lin_add_term(out, unsafe src.p[i as usize], c / d) {
            return false;
        }
    }
    return true;
}

extend TypeChecker {
    fn check_unary(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let op = a.at_const(id).as_data.unary.op;
        let operand = a.at_const(id).as_data.unary.operand;
        let qual = a.at_const(id).as_data.unary.qualifier;
        if op == TokenType::Ampersand {
            self.addr_ctx = true;
        }
        let outer_unsafe_used = self.unsafe_used;
        if op == TokenType::Unsafe {
            self.unsafe_depth = self.unsafe_depth + 1;
            self.unsafe_used = 0;
        }
        let opnd = self.check_expr(operand);
        if op == TokenType::Unsafe {
            self.unsafe_depth = self.unsafe_depth - 1;
            // an `unsafe` take of a Free field through a reference is CONSUMED by the borrow
            // checker's E0507 exemption (a later pass this lint cannot see): count it as used
            if self.unsafe_used == 0 {
                let mut w = operand;
                loop {
                    let wn = a.at_const(w);
                    if wn.kind == NodeKind::NODE_UNARY && (wn.as_data.unary.op == TokenType::Move || wn.as_data.unary.op == TokenType::Unsafe) {
                        w = wn.as_data.unary.operand;
                    } else {
                        break;
                    }
                }
                let wk = a.at_const(w).kind;
                if (wk == NodeKind::NODE_MEMBER && !a.at_const(w).as_data.member.path || wk == NodeKind::NODE_INDEX) && self.tc_type_is_free(
                    opnd,
                ) {
                    self.unsafe_used = 1;
                }
            }
            if self.lint && self.unsafe_used == 0 {
                let usp = a.at_const(id).span;
                self.errors.warn(usp.start, 6, format("unnecessary 'unsafe': nothing inside requires it"));
                // Prefix form only: a bare block is not an expression, so `unsafe { .. }` keeps its marker.
                // Delete just the keyword + trailing blanks -- the operand span excludes dropped grouping
                // parens, so deleting up to it would swallow a '(' (`unsafe (a + 1)`).
                if a.at_const(operand).kind != NodeKind::NODE_BLOCK {
                    let mut fe = usp.start + 6;
                    while fe as usize < self.source.len() && (self.source[fe as usize] == b' ' || self.source[fe as usize] == b'\t') {
                        fe = fe + 1;
                    }
                    self.errors.fix(usp.start, fe, 0);
                }
            }
            self.unsafe_used = outer_unsafe_used;
        }
        let sp = a.at_const(id).span;
        if op == TokenType::Minus {
            if opnd != TYPE_NONE && !self.is_numeric(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '-' requires a numeric operand"));
            }
            return opnd;
        }
        if op == TokenType::Bang {
            if opnd != TYPE_NONE && !self.is_bool(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '!' requires a 'bool' operand"));
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if op == TokenType::Tilde {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_bit_not_overload(id, opnd, &mut ov) {
                return ov;
            }
            if opnd != TYPE_NONE && !self.is_int(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '~' requires an integer operand"));
            }
            return opnd;
        }
        if op == TokenType::Star {
            // Lint: `*&x` (any mutability) yields the place/value x itself -- both tokens cancel.
            if self.lint && a.at_const(operand).kind == NodeKind::NODE_UNARY && a.at_const(operand).as_data.unary.op == TokenType::Ampersand {
                let usp = a.at_const(id).span;
                self.errors.warn(
                    usp.start,
                    usp.end - usp.start,
                    format("unnecessary '*&': the expression can be used directly"),
                );
                self.tc_lint_pair_fix(usp.start, a.at_const(a.at_const(operand).as_data.unary.operand).span.start);
            }
            if opnd == TYPE_NONE {
                return TYPE_NONE;
            }
            let ot = *self.type_at(opnd);
            if ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(sp, "dereferencing a raw pointer");
                }
                return ot.as_data.elem;
            }
            // `*x` on a type that implements Deref is that impl's job, exactly as `x.method()` is
            let mut dm = DefId { module: 0, node: NODE_NONE };
            let dt = self.tc_deref_step(self.strip(opnd), &mut dm);
            if dt != TYPE_NONE {
                self.tc_record_deref(id, self.strip(opnd), dm, dt);
                return dt;
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot dereference a non-pointer"));
            return TYPE_NONE;
        }
        if op == TokenType::Ampersand {
            let mut2 = qual == TypeQualifier::TYPE_QUAL_MUT;
            // Lint: `&*r` on a shared reference re-produces r -- both tokens cancel. (`&mut *r`
            // reborrows and `&*p` on a raw pointer materializes a reference: both meaningful.)
            if self.lint && !mut2 && a.at_const(operand).kind == NodeKind::NODE_UNARY && a.at_const(operand).as_data.unary.op == TokenType::Star {
                let inner = a.at_const(operand).as_data.unary.operand;
                let it = a.type_of(inner);
                if it != TYPE_NONE && self.type_at(it).kind == TypeKind::TYPE_REFERENCE && self.type_at(it).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    let usp = a.at_const(id).span;
                    self.errors.warn(
                        usp.start,
                        usp.end - usp.start,
                        format("unnecessary '&*': the reference can be used directly"),
                    );
                    self.tc_lint_pair_fix(usp.start, a.at_const(inner).span.start);
                }
            }
            if mut2 && self.is_place(operand) && !self.is_assignable(operand) {
                let osp = a.at_const(operand).span;
                self.errors.emit(
                    osp.start,
                    osp.end - osp.start,
                    format("cannot take '&mut' of an immutable binding (bind it with 'mut')"),
                );
            }
            if mut2 {}
            let mut opw = operand;
            loop {
                let onn = a.at_const(opw);
                if onn.kind == NodeKind::NODE_UNARY && (onn.as_data.unary.op == TokenType::Move || onn.as_data.unary.op == TokenType::Unsafe) {
                    opw = onn.as_data.unary.operand;
                } else {
                    break;
                }
            }
            let onk = a.at_const(opw).kind;
            if mut2 && onk == NodeKind::NODE_IDENTIFIER {
                let od = a.resolution_def(opw);
                if od.module == self.cur_module() && od.node != NODE_NONE {}
            }
            if !self.is_place(opw) && opnd != TYPE_NONE && self.type_at(opnd).kind != TypeKind::TYPE_BUILTIN && (onk == NodeKind::NODE_CALL || onk == NodeKind::NODE_IF || onk == NodeKind::NODE_MATCH || onk == NodeKind::NODE_BLOCK || onk == NodeKind::NODE_BINARY || onk == NodeKind::NODE_ASSIGNMENT || onk == NodeKind::NODE_CAST) {
                let osp = a.at_const(opw).span;
                self.errors.emit(
                    osp.start,
                    osp.end - osp.start,
                    format("cannot take the address of a temporary value; bind it to a 'let' first"),
                );
            }
            let mut bk = BORROW_SHARED;
            if mut2 {
                bk = BORROW_MUT;
            }
            return self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: qual as u8, as_data: TyAs { elem: opnd } },
            );
        }
        if op == TokenType::Question {
            if opnd == TYPE_NONE {
                return TYPE_NONE;
            }
            let os = self.strip(opnd);
            let mut oa = Tys8 {};
            let mut fa = Tys8 {};
            let nopt = self.prelude_instance_args_hit(os, self.ph_option, &mut oa[0], 2);
            let mut nres: i32 = -1;
            if nopt < 0 {
                nres = self.prelude_instance_args_hit(os, self.ph_result, &mut oa[0], 2);
            }
            if nopt < 0 && nres < 0 {
                self.errors.emit(sp.start, sp.end - sp.start, format("'?' requires an Option or Result operand"));
                self.errors.note(format("the operand must be an Option<T> or Result<T, E> value"));
                return TYPE_NONE;
            }
            let mut fnret: TypeId = TYPE_NONE;
            if self.current_returns.len == 1 {
                let r0 = unsafe self.cur_ast().list(self.current_returns)[0];
                let rnn = self.cur_ast().at_const(r0);
                fnret = self.resolve_type(if_node(rnn.kind == NodeKind::NODE_PARAMETER, rnn.as_data.parameter.ty, r0));
            }
            let mut frs = TYPE_NONE;
            if fnret != TYPE_NONE {
                frs = self.strip(fnret);
            }
            if nopt >= 0 {
                if self.prelude_instance_args_hit(frs, self.ph_option, &mut fa[0], 2) < 0 {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("'?' on an Option requires the function to return an Option"),
                    );
                    self.errors.note(format("change the function return type or handle None explicitly"));
                }
                return oa[0];
            }
            if self.prelude_instance_args_hit(frs, self.ph_result, &mut fa[0], 2) < 0 {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'?' on a Result requires the function to return a Result"),
                );
                self.errors.note(format("the function must return Result<_, E> with the same error type"));
            } else if oa[1] != fa[1] {
                let conv = self.tc_find_from_for(fa[1], oa[1]);
                if conv.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(id, conv);
                } else {
                    let mut a1 = Buf96 {};
                    let mut a2 = Buf96 {};
                    self.render_type(oa[1], &mut a1[0], 96);
                    self.render_type(fa[1], &mut a2[0], 96);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "'?' error type '{}' does not match the function's error type '{}'",
                            diag::cstr(&a1[0]),
                            diag::cstr(&a2[0]),
                        ),
                    );
                }
            }
            return oa[0];
        }
        return opnd;
    }

    fn binary_numeric(self: &mut Self, id: NodeId, l: TypeId, ln: NodeId, r: TypeId, rn: NodeId, require_int: bool) TypeId {
        if l == TYPE_NONE || r == TYPE_NONE {
            return TYPE_NONE;
        }
        let sp = self.cur_ast().at_const(id).span;
        let mut ok = self.is_numeric(l) && self.is_numeric(r);
        if require_int {
            ok = self.is_int(l) && self.is_int(r);
        }
        if !ok {
            let mut w = "numeric".ptr() as *const char;
            if require_int {
                w = "integer".ptr() as *const char;
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("operator requires {} operands", diag::cstr(w)));
            return TYPE_NONE;
        }
        if l == r {
            return l;
        }
        if self.cur_ast().at_const(ln).kind == NodeKind::NODE_LITERAL && !self.tc_literal_pinned(ln) {
            if self.is_int(r) {
                let mut mag: u64 = 0;
                let got = self.lit_mag(ln, &mut mag);
                let rb = self.type_at(r).as_data.builtin;
                if got && !tc_lit_in_range(rb, mag, false) {
                    let mut tn = Buf96 {};
                    self.render_type(r, &mut tn[0], 96);
                    let lsp = self.cur_ast().at_const(ln).span;
                    self.errors.emit(
                        lsp.start,
                        lsp.end - lsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                } else {
                    self.cur_ast().set_type(ln, r);
                }
            }
            return r;
        }
        if self.cur_ast().at_const(rn).kind == NodeKind::NODE_LITERAL && !self.tc_literal_pinned(rn) {
            if self.is_int(l) {
                let mut mag: u64 = 0;
                let got = self.lit_mag(rn, &mut mag);
                let lb = self.type_at(l).as_data.builtin;
                if got && !tc_lit_in_range(lb, mag, false) {
                    let mut tn = Buf96 {};
                    self.render_type(l, &mut tn[0], 96);
                    let rsp = self.cur_ast().at_const(rn).span;
                    self.errors.emit(
                        rsp.start,
                        rsp.end - rsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                } else {
                    self.cur_ast().set_type(rn, l);
                }
            }
            return l;
        }
        if bt_widens(self.bt_of(l), self.bt_of(r)) {
            return r;
        }
        if bt_widens(self.bt_of(r), self.bt_of(l)) {
            return l;
        }
        self.err_mismatch(rn, l);
        return l;
    }

    fn check_ptr_arith(self: &mut Self, id: NodeId, l: TypeId, r: TypeId, handled: *mut bool) TypeId {
        unsafe *handled = false;
        if l == TYPE_NONE || r == TYPE_NONE {
            return TYPE_NONE;
        }
        let lp = self.type_at(l).kind == TypeKind::TYPE_POINTER;
        let rp = self.type_at(r).kind == TypeKind::TYPE_POINTER;
        if !lp && !rp {
            return TYPE_NONE;
        }
        unsafe *handled = true;
        let sp = self.cur_ast().at_const(id).span;
        if self.tc_needs_unsafe() {
            self.err_unsafe(sp, "raw pointer arithmetic");
        }
        let minus = self.cur_ast().at_const(id).as_data.binary.op == TokenType::Minus;
        if lp && rp {
            if minus && l == r {
                return Ast::builtin(BuiltinType::BT_ISIZE);
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("invalid pointer arithmetic"));
            return TYPE_NONE;
        }
        if lp && self.is_int(r) {
            return l;
        }
        if rp && !minus && self.is_int(l) {
            return r;
        }
        self.errors.emit(sp.start, sp.end - sp.start, format("pointer arithmetic requires an integer offset"));
        return TYPE_NONE;
    }

    fn check_arith_overload(self: &mut Self, id: NodeId, l: TypeId, out: *mut TypeId) bool {
        let op = self.cur_ast().at_const(id).as_data.binary.op;
        let m = arith_method_name(op);
        if m.len() == 0 {
            return false;
        }
        let mut ls = l;
        while ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_REFERENCE {
            ls = self.type_at(ls).as_data.elem;
        }
        if ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_POINTER {
            return false;
        }
        if ls == TYPE_NONE {
            return false;
        }
        let lt = *self.type_at(ls);
        let right = self.cur_ast().at_const(id).as_data.binary.right;
        if lt.kind == TypeKind::TYPE_GENERIC {
            if !self.tc_param_bound_provides(lt.module, lt.as_data.decl, m) {
                let sp = self.cur_ast().at_const(id).span;
                let mut ty = Buf96 {};
                self.render_type(ls, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "type parameter '{}' has no '{}' method for this operator (add a bound that provides it)",
                        diag::cstr(&ty[0]),
                        m,
                    ),
                );
                unsafe *out = TYPE_NONE;
            }
            return true;
        }
        if lt.kind != TypeKind::TYPE_STRUCT && lt.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        unsafe *out = ls;
        if self.aggregate_of(ls, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            let md = self.find_method_cstr(om, od, m);
            if md.node == NODE_NONE {
                let sp = self.cur_ast().at_const(id).span;
                let mut ty = Buf96 {};
                self.render_type(ls, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'{}' has no '{}' method for this operator", diag::cstr(&ty[0]), m),
                );
                unsafe *out = TYPE_NONE;
            } else {
                if !self.method_extend_bounds_hold(ls, md) {
                    let sp = self.cur_ast().at_const(id).span;
                    self.err_method_extend_bounds(sp, ls, md);
                    unsafe *out = TYPE_NONE;
                    return true;
                }
                let p1 = self.tc_method_param(ls, md, 1);
                if !self.operand_fits_param(p1, right) {
                    self.err_mismatch(right, p1);
                }
                let ret = self.tc_method_ret(ls, md);
                if ret != TYPE_NONE {
                    unsafe *out = ret;
                }
            }
        }
        return true;
    }

    /// Unary `~` on an aggregate: the same dispatch the binary operators get, through `bit_not`. Reports
    /// against the operator rather than falling through to "requires an integer operand", which would name
    /// the wrong problem for a type that simply has no such method.
    fn check_bit_not_overload(self: &mut Self, id: NodeId, opnd: TypeId, out: *mut TypeId) bool {
        let mut os = opnd;
        while os != TYPE_NONE && self.type_at(os).kind == TypeKind::TYPE_REFERENCE {
            os = self.type_at(os).as_data.elem;
        }
        if os == TYPE_NONE {
            return false;
        }
        let ot = *self.type_at(os);
        let sp = self.cur_ast().at_const(id).span;
        if ot.kind == TypeKind::TYPE_GENERIC {
            if !self.tc_param_bound_provides(ot.module, ot.as_data.decl, "bit_not") {
                let mut ty = Buf96 {};
                self.render_type(os, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "type parameter '{}' has no 'bit_not' method for this operator (add a bound that provides it)",
                        diag::cstr(&ty[0]),
                    ),
                );
                unsafe *out = TYPE_NONE;
                return true;
            }
            unsafe *out = os;
            return true;
        }
        if ot.kind != TypeKind::TYPE_STRUCT && ot.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        unsafe *out = os;
        if self.aggregate_of(os, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            let md = self.find_method_cstr(om, od, "bit_not");
            if md.node == NODE_NONE {
                let mut ty = Buf96 {};
                self.render_type(os, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("type '{}' has no 'bit_not' method for this operator", diag::cstr(&ty[0])),
                );
                unsafe *out = TYPE_NONE;
                return true;
            }
            let ret = self.tc_method_ret(os, md);
            if ret != TYPE_NONE {
                unsafe *out = ret;
            }
        }
        return true;
    }

    fn check_binary(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let bd = a.at_const(id).as_data.binary;
        let ln = bd.left;
        let rn = bd.right;
        let op = bd.op;
        let l = self.check_expr(ln);
        let r = self.check_expr(rn);
        let sp = a.at_const(id).span;
        if op == TokenType::Plus || op == TokenType::Minus {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_arith_overload(id, l, &mut ov) {
                return ov;
            }
            let mut handled = false;
            let pt = self.check_ptr_arith(id, l, r, &mut handled);
            if handled {
                return pt;
            }
            return self.binary_numeric(id, l, ln, r, rn, false);
        }
        if op == TokenType::Star || op == TokenType::Slash || op == TokenType::Percent {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_arith_overload(id, l, &mut ov) {
                return ov;
            }
            return self.binary_numeric(id, l, ln, r, rn, false);
        }
        if op == TokenType::Ampersand || op == TokenType::Pipe || op == TokenType::Caret || op == TokenType::LeftShift || op == TokenType::RightShift {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_arith_overload(id, l, &mut ov) {
                return ov;
            }
            return self.binary_numeric(id, l, ln, r, rn, true);
        }
        if op == TokenType::AmpersandAmpersand || op == TokenType::PipePipe {
            if l != TYPE_NONE && !self.is_bool(l) || r != TYPE_NONE && !self.is_bool(r) {
                self.errors.emit(sp.start, sp.end - sp.start, format("logical operator requires 'bool' operands"));
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        // comparisons
        let ord = op == TokenType::LessThan || op == TokenType::LessThanEqual || op == TokenType::GreaterThan || op == TokenType::GreaterThanEqual;
        // `null == value` mirror of the null-operand check in the struct-eq branch below.
        let lnn = self.cur_ast().at_const(ln);
        if lnn.kind == NodeKind::NODE_LITERAL && lnn.as_data.literal.token_type == TokenType::Null && r != TYPE_NONE {
            let mut rs = r;
            while self.type_at(rs).kind == TypeKind::TYPE_REFERENCE {
                rs = self.type_at(rs).as_data.elem;
            }
            let rk = self.type_at(rs).kind;
            if rk == TypeKind::TYPE_STRUCT || rk == TypeKind::TYPE_INSTANCE {
                let mut ty = Buf96 {};
                self.render_type(rs, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("cannot compare '{}' with 'null' (it is a value, not a pointer)", diag::cstr(&ty[0])),
                );
                return Ast::builtin(BuiltinType::BT_BOOL);
            }
        }
        let mut ls = l;
        while ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_REFERENCE {
            ls = self.type_at(ls).as_data.elem;
        }
        let mut rstrip = r;
        while rstrip != TYPE_NONE && self.type_at(rstrip).kind == TypeKind::TYPE_REFERENCE {
            rstrip = self.type_at(rstrip).as_data.elem;
        }
        // a raw pointer compares by ADDRESS, a reference by VALUE: one of each in a comparison has
        // no consistent meaning, so it is rejected instead of silently picking a side
        let lptr = ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_POINTER;
        let rptr = rstrip != TYPE_NONE && self.type_at(rstrip).kind == TypeKind::TYPE_POINTER;
        if lptr != rptr && (lptr && r != rstrip || rptr && l != ls) {
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "cannot compare a raw pointer with a reference (pointers compare by address, references by value)",
                ),
            );
            self.errors.note(
                format(
                    "cast the reference with 'as' to compare addresses, or dereference the pointer to compare values",
                ),
            );
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if lptr {
            if l != TYPE_NONE && r != TYPE_NONE && l != r && !self.compatible(l, rn) && !self.compatible(r, ln) {
                self.err_mismatch(rn, l);
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if ls != TYPE_NONE && (self.type_at(ls).kind == TypeKind::TYPE_STRUCT || self.type_at(ls).kind == TypeKind::TYPE_INSTANCE) {
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            if self.aggregate_of(ls, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                let mut mm = "eq";
                if ord {
                    mm = "cmp";
                }
                let rnn = self.cur_ast().at_const(rn);
                if rnn.kind == NodeKind::NODE_LITERAL && rnn.as_data.literal.token_type == TokenType::Null {
                    let mut ty = Buf96 {};
                    self.render_type(ls, &mut ty[0], 96);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot compare '{}' with 'null' (it is a value, not a pointer)", diag::cstr(&ty[0])),
                    );
                    return Ast::builtin(BuiltinType::BT_BOOL);
                }
                let md = self.find_method_cstr(om, od, mm);
                if md.node == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(ls, &mut ty[0], 96);
                    let mut iface = "Eq".ptr() as *const char;
                    if ord {
                        iface = "Ord".ptr() as *const char;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "'{}' has no '{}' method for this operator (implement {})",
                            diag::cstr(&ty[0]),
                            mm,
                            diag::cstr(iface),
                        ),
                    );
                    self.errors.note(format("operator overloads are resolved through interface-style methods"));
                } else if !self.method_extend_bounds_hold(ls, md) {
                    self.err_method_extend_bounds(sp, ls, md);
                } else {
                    let p1 = self.tc_method_param(ls, md, 1);
                    if !self.operand_fits_param(p1, rn) {
                        self.err_mismatch(rn, p1);
                    }
                }
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_GENERIC {
            let gy = *self.type_at(ls);
            let mut mm = "eq";
            if ord {
                mm = "cmp";
            }
            if !self.tc_param_bound_provides(gy.module, gy.as_data.decl, mm) {
                let mut iface = "Eq".ptr() as *const char;
                if ord {
                    iface = "Ord".ptr() as *const char;
                }
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "type parameter has no '{}' method for this operator (add a `{}` bound)",
                        mm,
                        diag::cstr(iface),
                    ),
                );
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        // scalar comparison: references compare by value, so validate the reference-STRIPPED types
        // (`&i32 == &i32`, `&i32 == i32`, `i32 == &i32` are all i32-value comparisons). Raw pointers
        // were handled by the pointer branch above.
        if ls != TYPE_NONE && rstrip != TYPE_NONE && ls != rstrip && !self.compatible(ls, rn) && !self.compatible(
            rstrip,
            ln,
        ) {
            self.err_mismatch(rn, ls);
        }
        return Ast::builtin(BuiltinType::BT_BOOL);
    }

    fn check_variant_call(self: &mut Self, id: NodeId, vmod: ModuleId, variant: NodeId, enum_ty: TypeId) TypeId {
        let a = self.cur_ast();
        let args = a.at_const(id).as_data.call.args;
        for i in 0..args.len {
            self.check_expr(unsafe a.list(args)[i as usize]);
        }
        let va = self.mod_ast(vmod);
        let payload = va.at_const(variant).as_data.variant.payload;
        let sp = a.at_const(id).span;
        let mut amod: ModuleId = 0;
        let mut adecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        let inst = self.aggregate_of(enum_ty, &mut amod, &mut adecl, &mut gp, &mut ga, &mut gn);
        if args.len != payload.len {
            let mut s2 = "s".ptr() as *const char;
            if payload.len == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("variant expects {} argument{}, found {}", payload.len, diag::cstr(s2), args.len),
            );
        } else {
            for k in 0..args.len {
                let pid = unsafe va.list(payload)[k as usize];
                let pe = va.at_const(pid);
                let raw = self.lower_type_in(vmod, if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, pid));
                let mut pt = raw;
                if inst {
                    pt = self.subst_type(raw, &gp[0], &ga[0], gn);
                }
                let aid = unsafe a.list(args)[k as usize];
                if !self.compatible(pt, aid) {
                    self.err_mismatch(aid, pt);
                }
            }
        }
        return enum_ty;
    }

    const fn tc_is_iface_assoc_call(self: &Self, e: NodeId) bool {
        let a = self.cur_ast();
        let en = a.at_const(e);
        if en.kind != NodeKind::NODE_CALL {
            return false;
        }
        let cn = a.at_const(en.as_data.call.callee);
        if cn.kind != NodeKind::NODE_MEMBER || !cn.as_data.member.path {
            return false;
        }
        let ob = a.resolution_def(cn.as_data.member.object);
        return ob.node != NODE_NONE && (ob.module == self.cur_module() || self.package != null && ob.module as usize < self.pkg_count()) && self.mod_ast(
            ob.module,
        ).at_const(ob.node).kind == NodeKind::NODE_INTERFACE;
    }

    fn tc_param_expected(self: &mut Self, callee: TypeId, callee_node: NodeId, argi: u32) TypeId {
        if callee == TYPE_NONE {
            return TYPE_NONE;
        }
        let ct = *self.type_at(callee);
        if ct.kind != TypeKind::TYPE_FUNCTION {
            return TYPE_NONE;
        }
        let fa = self.mod_ast(ct.module);
        let fnn = fa.at_const(ct.as_data.decl);
        if fnn.kind == NodeKind::NODE_FUNCTION_TYPE {
            // a call THROUGH a fn-pointer value: the parameter types are the signature's own
            let fps = fnn.as_data.function_type.params;
            if argi >= fps.len {
                return TYPE_NONE;
            }
            return self.lower_type_in(ct.module, unsafe fa.list(fps)[argi as usize]);
        }
        if fnn.kind != NodeKind::NODE_FUNCTION {
            return TYPE_NONE;
        }
        let cnn = self.cur_ast().at_const(callee_node);
        let mut skip: u32 = 0;
        if cnn.kind == NodeKind::NODE_MEMBER && !cnn.as_data.member.path && fnn.as_data.function.params.len > 0 {
            let md = self.cur_ast().resolution_def(cnn.as_data.member.member);
            if md.node != NODE_NONE && self.mod_ast(md.module).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                skip = 1;
            }
        }
        if argi + skip >= fnn.as_data.function.params.len {
            return TYPE_NONE;
        }
        let mut pt = self.decl_type_in(ct.module, unsafe fa.list(fnn.as_data.function.params)[(argi + skip) as usize]);
        if pt != TYPE_NONE && self.type_at(pt).kind == TypeKind::TYPE_GENERIC {
            let g = *self.type_at(pt);
            let fb = self.generic_fn_bound(g.module, g.as_data.decl);
            if fb != NODE_NONE {
                pt = self.lower_type_in(ct.module, fb);
            }
        }
        if pt != TYPE_NONE && !self.cur_ast().type_concrete(pt) && skip != 0 {
            let md = self.cur_ast().resolution_def(cnn.as_data.member.member);
            let mut extnode = NODE_NONE;
            if md.node != NODE_NONE {
                extnode = self.enclosing_extend(md.module, md.node);
            }
            let mut rm: ModuleId = 0;
            let mut rd = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = extnode != NODE_NONE && self.aggregate_of(
                self.strip(self.cur_ast().type_of(cnn.as_data.member.object)),
                &mut rm,
                &mut rd,
                &mut gp,
                &mut ga,
                &mut gn,
            );
            if agok && gn > 0 {
                let ma = self.mod_ast(md.module);
                let ig = ma.at_const(extnode).as_data.extend_def.generics;
                let mut sp2 = Defs8 {};
                let mut sa = Tys8 {};
                let mut ns: i32 = 0;
                let mut i: u32 = 0;
                while i < ig.len && i as i32 < gn && ns < 8 {
                    let gid = unsafe ma.list(ig)[i as usize];
                    sp2[ns as usize] = DefId { module: md.module, node: gid };
                    sa[ns as usize] = ga[i as usize];
                    ns = ns + 1;
                    i = i + 1;
                }
                pt = self.subst_type(pt, &sp2[0], &sa[0], ns);
            }
        }
        if pt != TYPE_NONE && self.cur_ast().type_concrete(pt) {
            return pt;
        }
        return TYPE_NONE;
    }

    fn iter_elem_type(self: &mut Self, it: TypeId) TypeId {
        let mut im: ModuleId = 0;
        let mut idl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(it, &mut im, &mut idl, &mut gp, &mut ga, &mut gn) {
            return TYPE_NONE;
        }
        let nx = self.find_method_cstr(im, idl, "next");
        if nx.node == NODE_NONE {
            return TYPE_NONE;
        }
        let na = self.mod_ast(nx.module);
        let rets = na.at_const(nx.node).as_data.function.returns;
        if rets.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe na.list(rets)[0];
        let rn = na.at_const(r0);
        let mut ret = self.lower_type_in(
            nx.module,
            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
        );
        let extnode = self.enclosing_extend(nx.module, nx.node);
        if extnode != NODE_NONE && gn > 0 {
            let ig = na.at_const(extnode).as_data.extend_def.generics;
            let mut ip = Defs8 {};
            let mut ia = Tys8 {};
            let mut in2: i32 = 0;
            let mut i: u32 = 0;
            while i < ig.len && i as i32 < gn && in2 < 8 {
                let gid = unsafe na.list(ig)[i as usize];
                ip[in2 as usize] = DefId { module: nx.module, node: gid };
                ia[in2 as usize] = ga[i as usize];
                in2 = in2 + 1;
                i = i + 1;
            }
            ret = self.subst_type(ret, &ip[0], &ia[0], in2);
        }
        let rt = self.type_at(ret);
        if rt.kind == TypeKind::TYPE_INSTANCE {
            let oi = *self.cur_ast().instance(rt.as_data.inst);
            if oi.n >= 1 {
                return oi.args[0];
            }
        }
        return TYPE_NONE;
    }

    fn tc_check_assert(self: &mut Self, id: NodeId, kind: i32) TypeId {
        let a = self.cur_ast();
        let args = a.at_const(id).as_data.call.args;
        let sp = a.at_const(id).span;
        if kind == 1 {
            if args.len < 1 || args.len > 2 {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'assert' takes a condition and an optional str message"),
                );
                for i in 0..args.len {
                    self.check_expr(unsafe a.list(args)[i as usize]);
                }
                return Ast::builtin(BuiltinType::BT_VOID);
            }
            let ct = self.check_expr(unsafe a.list(args)[0]);
            if ct != TYPE_NONE && !self.is_bool(ct) {
                self.errors.emit(sp.start, sp.end - sp.start, format("'assert' condition must be 'bool'"));
            }
            if args.len == 2 {
                let mt = self.check_expr(unsafe a.list(args)[1]);
                if mt != TYPE_NONE && self.strip(mt) != self.prelude_str_type() {
                    self.errors.emit(sp.start, sp.end - sp.start, format("'assert' message must be a 'str'"));
                }
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let mut nm = "assert_eq".ptr() as *const char;
        if kind == 3 {
            nm = "assert_ne".ptr() as *const char;
        }
        if args.len != 2 {
            self.errors.emit(sp.start, sp.end - sp.start, format("'{}' takes exactly two arguments", diag::cstr(nm)));
            for i in 0..args.len {
                self.check_expr(unsafe a.list(args)[i as usize]);
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let lt = self.check_expr(unsafe a.list(args)[0]);
        self.expected = lt;
        let rt = self.check_expr(unsafe a.list(args)[1]);
        if lt == TYPE_NONE || rt == TYPE_NONE {
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        if lt != rt && !self.compatible(lt, unsafe a.list(args)[1]) && !self.compatible(rt, unsafe a.list(args)[0]) {
            self.err_mismatch(unsafe a.list(args)[1], lt);
        }
        let base = self.strip(lt);
        let y = *self.type_at(base);
        let mut comparable = y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin != BuiltinType::BT_VOID && y.as_data.builtin != BuiltinType::BT_VALIST;
        if base == self.prelude_str_type() {
            comparable = true;
        }
        if !comparable && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE || y.kind == TypeKind::TYPE_ENUM) {
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            if self.aggregate_of(base, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                comparable = self.find_method_cstr(om, od, "eq").node != NODE_NONE;
                if !comparable && self.is_plain_enum(base) {
                    comparable = true;
                }
                if comparable {
                    self.find_method_cstr(om, od, "as_str");
                }
            }
        }
        if !comparable {
            let mut ty = Buf96 {};
            self.render_type(lt, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("'{}' cannot compare values of type '{}'", diag::cstr(nm), diag::cstr(&ty[0])),
            );
            self.errors.note(format("implement 'Eq' (an 'eq' method) for the type, or compare a field/element instead"));
        }
        return Ast::builtin(BuiltinType::BT_VOID);
    }

    fn infer_from_bounds(
        self: &mut Self,
        fmod: ModuleId,
        fdecl: NodeId,
        gids: *const NodeId,
        gparams: *const DefId,
        bound: *mut TypeId,
        g: i32,
    ) {
        let fa = self.mod_ast(fmod);
        for pass in 0..2 {
            for i in 0..g {
                if unsafe bound[i as usize] != TYPE_NONE {
                    let mut bs = BoundArr8 {};
                    let mut nb: i32 = 0;
                    self.add_bound_ifaces_full(
                        fmod,
                        fa.at_const(unsafe gids[i as usize]).as_data.generic_param.bounds,
                        &mut bs[0],
                        &mut nb,
                        8,
                    );
                    let wc = fa.at_const(fdecl).as_data.function.where_clause;
                    for w in 0..wc.len {
                        let wid = unsafe fa.list(wc)[w as usize];
                        let wp = fa.at_const(wid).as_data.where_predicate;
                        if fa.resolution(wp.ty) == unsafe gids[i as usize] {
                            self.add_bound_ifaces_full(fmod, wp.bounds, &mut bs[0], &mut nb, 8);
                        }
                    }
                    for b in 0..nb {
                        if bs[b as usize].n != 0 {
                            let mut tm: ModuleId = 0;
                            let mut td = NODE_NONE;
                            let mut sp = Defs8 {};
                            let mut sa = Tys8 {};
                            let mut sn: i32 = 0;
                            if self.aggregate_of(
                                self.strip(unsafe bound[i as usize]),
                                &mut tm,
                                &mut td,
                                &mut sp,
                                &mut sa,
                                &mut sn,
                            ) {
                                let mut imod: ModuleId = 0;
                                let extn = self.find_extend_as(tm, td, bs[b as usize].iface, &mut imod);
                                if extn != NODE_NONE {
                                    let ia = self.mod_ast(imod);
                                    let egids = ia.at_const(extn).as_data.extend_def.generics;
                                    let mut egp = Defs8 {};
                                    let mut ega = Tys8 {};
                                    let mut egn: i32 = 0;
                                    let mut k: u32 = 0;
                                    while k < egids.len && k as i32 < sn && egn < 8 {
                                        let xg = unsafe ia.list(egids)[k as usize];
                                        egp[egn as usize] = DefId { module: imod, node: xg };
                                        ega[egn as usize] = sa[k as usize];
                                        egn = egn + 1;
                                        k = k + 1;
                                    }
                                    let itf = ia.at_const(ia.at_const(extn).as_data.extend_def.interface_type);
                                    if itf.kind == NodeKind::NODE_TYPE_PATH {
                                        let iargs = itf.as_data.type_path.args;
                                        let mut kk: u32 = 0;
                                        while kk < iargs.len && kk < bs[b as usize].n as u32 {
                                            let lowered = self.lower_type_in(imod, unsafe ia.list(iargs)[kk as usize]);
                                            let subst = self.subst_type(lowered, &egp[0], &ega[0], egn);
                                            self.unify_infer(
                                                unsafe bs[b as usize].args[kk as usize],
                                                subst,
                                                gparams,
                                                bound,
                                                g,
                                            );
                                            kk = kk + 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn fn_compatible_subst(
        self: &mut Self,
        exid: TypeId,
        acid: TypeId,
        gp: *const DefId,
        ga: *const TypeId,
        gn: i32,
        rp: *const DefId,
        ra: *const TypeId,
        rn: i32,
    ) bool {
        if exid != acid && self.fn_owns(acid) {
            let exy = *self.type_at(exid);
            let exn = self.mod_ast(exy.module).at_const(exy.as_data.decl);
            if exn.kind != NodeKind::NODE_FUNCTION_TYPE || !exn.as_data.function_type.is_move {
                return false;
            }
        }
        let mut ep = Tys8 {};
        let mut ap = Tys8 {};
        let mut er: TypeId = TYPE_NONE;
        let mut ar: TypeId = TYPE_NONE;
        let en = self.fn_sig(exid, &mut ep[0], 4, &mut er);
        let an = self.fn_sig(acid, &mut ap[0], 4, &mut ar);
        if en != an || en > 4 {
            return false;
        }
        let er2 = self.subst_type(self.subst_type(er, gp, ga, gn), rp, ra, rn);
        if !self.ret_eq(er2, ar) {
            return false;
        }
        for i in 0..en {
            let ep2 = self.subst_type(self.subst_type(ep[i as usize], gp, ga, gn), rp, ra, rn);
            if ep2 != ap[i as usize] {
                return false;
            }
        }
        return true;
    }

    fn check_field_visibility(self: &mut Self, m: ModuleId, field: NodeId, owner: NodeId, at: tok::Span) {
        let f = self.mod_ast(m).at_const(field);
        let inside_owner = (self.package == null || m == self.cur_module()) && owner == self.current_self;
        if f.kind == NodeKind::NODE_FIELD && !f.as_data.field.is_public && !inside_owner {
            self.errors.emit(
                at.start,
                at.end - at.start,
                format("field '{}' is private", diag::span_str(self.source, at.start, at.end)),
            );
        }
    }

    fn check_call(self: &mut Self, id: NodeId, want: TypeId) TypeId {
        let a = self.cur_ast();
        let callee_id = a.at_const(id).as_data.call.callee;
        let pck = a.at_const(callee_id).kind;
        let mut callee = TYPE_NONE;
        // `x.free()` intrinsic no-op check
        if pck == NodeKind::NODE_MEMBER && !a.at_const(callee_id).as_data.member.path && a.at_const(id).as_data.call.args.len == 0 {
            let mem = a.at_const(callee_id).as_data.member.member;
            if span_is(self.mod_src(self.cur_module()), a.at_const(mem).as_data.name.text, "free") {
                let obj = a.at_const(callee_id).as_data.member.object;
                let rt = self.check_expr(obj);
                let fname = self.name_span(mem);
                let mut resolvable = false;
                if rt != TYPE_NONE {
                    let rty = *self.type_at(self.strip(rt));
                    if rty.kind == TypeKind::TYPE_STRUCT || rty.kind == TypeKind::TYPE_INSTANCE {
                        let mut om: ModuleId = 0;
                        let mut od = NODE_NONE;
                        let mut gp = Defs8 {};
                        let mut ga = Tys8 {};
                        let mut gn: i32 = 0;
                        if self.aggregate_of(self.strip(rt), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                            resolvable = self.find_method_cstr(om, od, "free").node != NODE_NONE;
                        }
                    } else if rty.kind == TypeKind::TYPE_GENERIC {
                        let mut iface = DefId { module: 0, node: NODE_NONE };
                        resolvable = self.find_bound_method(rty.module, rty.as_data.decl, fname, &mut iface).node != NODE_NONE;
                    } else if rty.kind == TypeKind::TYPE_DYN && rty.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                        return Ast::builtin(BuiltinType::BT_VOID);
                    }
                }
                if !resolvable {
                    return Ast::builtin(BuiltinType::BT_VOID);
                }
            }
        }
        if pck == NodeKind::NODE_MEMBER && a.at_const(callee_id).as_data.member.path {
            self.expected = want;
            callee = self.check_expr(callee_id);
            let vd = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            if vd.node != NODE_NONE && self.mod_ast(vd.module).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                return self.check_variant_call(id, vd.module, vd.node, callee);
            }
        } else if pck == NodeKind::NODE_MEMBER {
            self.expected = want;
            callee = self.check_member(callee_id, true);
            let fd = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            if fd.node != NODE_NONE && (fd.module == self.cur_module() || self.package != null && fd.module as usize < self.pkg_count()) && self.mod_ast(
                fd.module,
            ).at_const(fd.node).kind == NodeKind::NODE_FIELD {
                self.cur_ast().set_type(callee_id, callee);
            }
        } else {
            callee = self.check_expr(callee_id);
        }
        if pck == NodeKind::NODE_MEMBER {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            let addressable = md.module == self.cur_module() || self.package != null && md.module as usize < self.pkg_count();
            if md.node != NODE_NONE && addressable && self.mod_ast(md.module).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                self.tc_check_test_ref(md, a.at_const(id).span);
            }
        }
        // assert builtins
        if pck == NodeKind::NODE_IDENTIFIER && self.package != null {
            let ad = a.resolution_def(callee_id);
            if ad.node != NODE_NONE && ad.module as usize < self.pkg_count() && unsafe self.package.modules[ad.module as usize].prelude && self.mod_ast(
                ad.module,
            ).at_const(ad.node).kind == NodeKind::NODE_FUNCTION {
                let anm = self.mod_ast(ad.module).at_const(
                    self.mod_ast(ad.module).at_const(ad.node).as_data.function.name,
                ).as_data.name.text;
                let mut akind: i32 = 0;
                if span_is(self.mod_src(ad.module), anm, "assert") {
                    akind = 1;
                } else if span_is(self.mod_src(ad.module), anm, "assert_eq") {
                    akind = 2;
                } else if span_is(self.mod_src(ad.module), anm, "assert_ne") {
                    akind = 3;
                }
                if akind != 0 {
                    return self.tc_check_assert(id, akind);
                }
            }
        }
        // dyn_cast::<T>(d): compiler intrinsic -- vtable type-id compare, Option<&T> result
        if pck == NodeKind::NODE_GENERIC_SPECIALIZATION {
            let spx = a.at_const(callee_id).as_data.specialization;
            let tp_args = spx.types;
            if a.at_const(spx.expression).kind == NodeKind::NODE_IDENTIFIER && a.resolution_def(spx.expression).node == NODE_NONE && span_is(
                self.source,
                a.at_const(spx.expression).as_data.name.text,
                "dyn_cast",
            ) {
                let sp2 = a.at_const(id).span;
                let args2 = a.at_const(id).as_data.call.args;
                if tp_args.len != 1 || args2.len != 1 {
                    self.errors.emit(
                        sp2.start,
                        sp2.end - sp2.start,
                        format("dyn_cast takes exactly one type argument and one value"),
                    );
                    return TYPE_NONE;
                }
                let tt = self.resolve_type(unsafe a.list(tp_args)[0]);
                let av = self.check_expr(unsafe a.list(args2)[0]);
                let ay = *self.type_at(av);
                if ay.kind != TypeKind::TYPE_DYN || ay.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 || self.tc_dyn_fn_sig(
                    &ay,
                ) != TYPE_NONE {
                    self.errors.emit(
                        sp2.start,
                        sp2.end - sp2.start,
                        format("dyn_cast expects a '&dyn I' or '&mut dyn I' value"),
                    );
                    return TYPE_NONE;
                }
                let mut rq = TypeQualifier::TYPE_QUAL_CONST as u8;
                if ay.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    rq = TypeQualifier::TYPE_QUAL_MUT as u8;
                }
                let rt2 = self.cur_ast().intern_type(
                    Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: rq, module: 0, as_data: TyAs { elem: tt } },
                );
                let oh = self.package.prelude_lookup("Option", true);
                let mut oa = Tys8 {};
                oa[0] = rt2;
                let ot = self.cur_ast().intern_instance(oh.mid, oh.node, &oa[0], 1);
                self.cur_ast().set_type(id, ot);
                return ot;
            }
        }
        let args = a.at_const(id).as_data.call.args;
        for i in 0..args.len {
            let aid = unsafe a.list(args)[i as usize];
            // `[]` and a generic fn named as a value both take their type from the parameter.
            if self.tc_is_iface_assoc_call(aid) || a.at_const(aid).kind == NodeKind::NODE_CLOSURE || self.tc_wants_param_type(
                aid,
            ) {
                self.expected = self.tc_param_expected(callee, callee_id, i);
            }
            self.check_expr(aid);
        }
        if callee == TYPE_NONE {
            return TYPE_NONE;
        }
        let mut ct = *self.type_at(callee);
        let sp = a.at_const(id).span;
        if ct.kind == TypeKind::TYPE_GENERIC {
            let fb = self.generic_fn_bound(ct.module, ct.as_data.decl);
            if fb != NODE_NONE {
                callee = self.lower_type_in(ct.module, fb);
                ct = *self.type_at(callee);
            }
        }
        if ct.kind == TypeKind::TYPE_DYN {
            let ds = self.tc_dyn_fn_sig(&ct);
            if ds != TYPE_NONE {
                callee = ds;
                ct = *self.type_at(callee);
            }
        }
        if ct.kind == TypeKind::TYPE_STRUCT {
            let sd = self.mod_ast(ct.module).at_const(ct.as_data.decl);
            if sd.kind == NodeKind::NODE_STRUCT && sd.as_data.aggregate.is_tuple {
                let sm = ct.module;
                let sdecl = ct.as_data.decl;
                let members = sd.as_data.aggregate.members;
                if args.len != members.len {
                    let mut s2 = "s".ptr() as *const char;
                    if members.len == 1 {
                        s2 = "".ptr() as *const char;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("tuple struct takes {} element{}, got {}", members.len, diag::cstr(s2), args.len),
                    );
                    return TYPE_NONE;
                }
                for k in 0..args.len {
                    let et = self.lower_type_in(sm, unsafe self.mod_ast(sm).list(members)[k as usize]);
                    let aid = unsafe a.list(args)[k as usize];
                    if !self.compatible(et, aid) {
                        self.err_mismatch(aid, et);
                    }
                }
                return self.named_type_of(sm, sdecl);
            }
        }
        if ct.kind != TypeKind::TYPE_FUNCTION {
            self.errors.emit(sp.start, sp.end - sp.start, format("called value is not a function"));
            return TYPE_NONE;
        }
        let fmod = ct.module;
        let fdecl = ct.as_data.decl;
        let fa = self.mod_ast(fmod);
        let fk = fa.at_const(fdecl).kind;
        let named = fk == NodeKind::NODE_FUNCTION;
        if named && fa.at_const(fdecl).as_data.function.is_extern && self.tc_needs_unsafe() {
            self.err_unsafe(sp, "calling an extern \"C\" function");
        } else if named && fa.at_const(fdecl).as_data.function.is_unsafe && self.tc_needs_unsafe() {
            self.err_unsafe(sp, "calling an unsafe function");
        }
        let clos = fk == NodeKind::NODE_CLOSURE;
        let mut params = NodeList { start: 0, len: 0 };
        let mut returns = NodeList { start: 0, len: 0 };
        if named {
            params = fa.at_const(fdecl).as_data.function.params;
            returns = fa.at_const(fdecl).as_data.function.returns;
        } else if clos {
            params = fa.at_const(fdecl).as_data.closure.params;
            returns = fa.at_const(fdecl).as_data.closure.returns;
        } else {
            params = fa.at_const(fdecl).as_data.function_type.params;
            returns = fa.at_const(fdecl).as_data.function_type.returns;
        }
        let mut fmt_builtin = false;
        if named && self.package != null && fmod as usize < self.pkg_count() && unsafe self.package.modules[fmod as usize].prelude {
            let fnm = fa.at_const(fa.at_const(fdecl).as_data.function.name).as_data.name.text;
            fmt_builtin = span_is(self.mod_src(fmod), fnm, "format") || span_is(self.mod_src(fmod), fnm, "format_into") || span_is(
                self.mod_src(fmod),
                fnm,
                "print",
            ) || span_is(self.mod_src(fmod), fnm, "println") || span_is(self.mod_src(fmod), fnm, "eprint") || span_is(
                self.mod_src(fmod),
                fnm,
                "eprintln",
            );
            if fmt_builtin {
                self.mark_format_helpers();
            }
        }
        let mut skip: u32 = 0;
        let cn_path = a.at_const(callee_id).as_data.member.path;
        if named && pck == NodeKind::NODE_MEMBER && !cn_path && params.len > 0 {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            if md.node != NODE_NONE && self.mod_ast(md.module).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                skip = 1;
            }
        }
        // generic-instance receiver substitution + generic call inference
        let ret = self.check_call_finish(
            id,
            callee_id,
            fmod,
            fdecl,
            named,
            clos,
            params,
            returns,
            args,
            skip,
            want,
            fmt_builtin,
        );
        // A method whose RESULT carries a borrow (`Option<&V>`, a view, ...) borrows its receiver
        // just as much as one returning a bare `&T`. check_call_receiver can only inspect the
        // DECLARED return node, which is not enough: the borrow may sit inside a generic argument
        // that exists only after substitution (`Map::get` is declared `Option<T>`, and is
        // `Option<&i64>` only here). Re-check with the resolved type and persist the receiver borrow
        // so the container cannot be mutated while the returned view is live.
        return ret;
    }

    fn check_call_finish(
        self: &mut Self,
        id: NodeId,
        callee_id: NodeId,
        fmod: ModuleId,
        fdecl: NodeId,
        named: bool,
        clos: bool,
        params: NodeList,
        returns: NodeList,
        args: NodeList,
        skip: u32,
        want: TypeId,
        fmt_builtin: bool,
    ) TypeId {
        let a = self.cur_ast();
        let fa = self.mod_ast(fmod);
        // Record what the flow pass replays for this call: the resolved function and receiver skip.
        if named && fdecl != NODE_NONE {
            unsafe self.cur_ast().call_info.insert(id, fmod as u64 << 40 | fdecl as u64 << 8 | skip as u64);
        }
        let sp = a.at_const(id).span;
        let cn_kind = a.at_const(callee_id).kind;
        let cn_path = cn_kind == NodeKind::NODE_MEMBER && a.at_const(callee_id).as_data.member.path;
        let mut cdu: *const DerefUse = null;
        if cn_kind == NodeKind::NODE_MEMBER && !cn_path {
            cdu = a.deref_use_at(a.at_const(callee_id).as_data.member.member);
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let mut nrsub: i32 = 0;
        let mut conv_target = TYPE_NONE;
        if cn_kind == NodeKind::NODE_MEMBER {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            let mut recvbase = self.strip(a.type_of(a.at_const(callee_id).as_data.member.object));
            if cdu != null {
                recvbase = unsafe cdu.target;
            }
            // `x.into()` calls `Target::from(x)`, so the generics to bind are the TARGET's, taken from
            // the expected type -- the object is the argument here, not the receiver. Without this a
            // generic target (`let v: Vector<i32> = [..].into()`) kept its parameters unbound.
            conv_target = self.tc_conversion_target(a.at_const(callee_id).as_data.member.member, md, want);
            if conv_target != TYPE_NONE {
                recvbase = conv_target;
            }
            let mut rmod: ModuleId = 0;
            let mut rdecl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut sn: i32 = 0;
            let mdfn = md.node != NODE_NONE && self.mod_ast(md.module).at_const(md.node).kind == NodeKind::NODE_FUNCTION;
            let agok = mdfn && self.aggregate_of(recvbase, &mut rmod, &mut rdecl, &mut gp, &mut ga, &mut sn);
            if agok && sn > 0 {
                let extnode = self.enclosing_extend(md.module, md.node);
                if extnode != NODE_NONE {
                    let ma = self.mod_ast(md.module);
                    let ig = ma.at_const(extnode).as_data.extend_def.generics;
                    let mut g = ig.len as i32;
                    if sn < g {
                        g = sn;
                    }
                    let mut i: i32 = 0;
                    while i < g && nrsub < 8 {
                        let gid = unsafe ma.list(ig)[i as usize];
                        rsubp[nrsub as usize] = DefId { module: md.module, node: gid };
                        rsuba[nrsub as usize] = ga[i as usize];
                        nrsub = nrsub + 1;
                        i = i + 1;
                    }
                }
            }
            // dyn receiver over an instantiated generic interface: interface generics -> dyn args
            if nrsub == 0 {
                let rvy2 = *self.type_at(recvbase);
                if rvy2.kind == TypeKind::TYPE_DYN {
                    let dinst = *self.cur_ast().instance(rvy2.as_data.inst);
                    if dinst.n > 0 && self.mod_ast(dinst.module).at_const(dinst.decl).kind == NodeKind::NODE_INTERFACE {
                        let dig = self.mod_ast(dinst.module).at_const(dinst.decl).as_data.interface_def.generics;
                        let mut gi: u8 = 0;
                        while gi < dinst.n && gi as u32 < dig.len && nrsub < 8 {
                            rsubp[nrsub as usize] = DefId {
                                module: dinst.module,
                                node: unsafe self.mod_ast(dinst.module).list(dig)[gi as usize],
                            };
                            rsuba[nrsub as usize] = unsafe dinst.args[gi as usize];
                            nrsub = nrsub + 1;
                            gi = gi + 1;
                        }
                    }
                }
            }
        }
        // method through a generic bound: substitute interface Self
        if cn_kind == NodeKind::NODE_MEMBER && !cn_path && nrsub < 8 {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            let mut tr = NODE_NONE;
            if md.node != NODE_NONE {
                tr = self.enclosing_trait(md.module, md.node);
            }
            if tr != NODE_NONE {
                let mut target = self.strip(a.type_of(a.at_const(callee_id).as_data.member.object));
                if cdu != null {
                    target = unsafe cdu.target;
                }
                rsubp[nrsub as usize] = DefId { module: md.module, node: tr };
                rsuba[nrsub as usize] = target;
                nrsub = nrsub + 1;
                let ro = *self.type_at(target);
                if ro.kind == TypeKind::TYPE_GENERIC && nrsub < 8 {
                    nrsub = nrsub + self.bound_method_subst(
                        ro.module,
                        ro.as_data.decl,
                        md,
                        unsafe ((&mut rsubp[0]) as *mut DefId + nrsub as usize),
                        unsafe ((&mut rsuba[0]) as *mut TypeId + nrsub as usize),
                        4 - nrsub,
                    );
                }
            }
        }
        // `T::assoc()` (a static interface method on a type param): substitute the interface's Self by the
        // param's type, so a `Self` return resolves to T inside the generic function.
        if cn_kind == NodeKind::NODE_MEMBER && cn_path && nrsub < 8 {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            let mut tr = NODE_NONE;
            if md.node != NODE_NONE {
                tr = self.enclosing_trait(md.module, md.node);
            }
            let ob = a.resolution_def(a.at_const(callee_id).as_data.member.object);
            let mut ob_kind = NodeKind::NODE_NONE_KIND;
            if ob.node != NODE_NONE {
                ob_kind = self.mod_ast(ob.module).at_const(ob.node).kind;
            }
            if tr != NODE_NONE && ob.node != NODE_NONE && ob_kind == NodeKind::NODE_GENERIC_PARAM {
                rsubp[nrsub as usize] = DefId { module: md.module, node: tr };
                rsuba[nrsub as usize] = self.named_type_of(ob.module, ob.node);
                nrsub = nrsub + 1;
                if nrsub < 8 {
                    nrsub = nrsub + self.bound_method_subst(
                        ob.module,
                        ob.node,
                        md,
                        unsafe ((&mut rsubp[0]) as *mut DefId + nrsub as usize),
                        unsafe ((&mut rsuba[0]) as *mut TypeId + nrsub as usize),
                        4 - nrsub,
                    );
                }
            }
            // `Interface::assoc()` on a generic instance target (`let v: Vector<String> = Default::default();`):
            // the resolved method's signature uses the EXTEND's type params -- bind them to the target's args.
            if ob.node != NODE_NONE && md.node != NODE_NONE && ob_kind == NodeKind::NODE_INTERFACE {
                let mut em: ModuleId = 0;
                let mut ed = NODE_NONE;
                let mut egp2 = Defs8 {};
                let mut ega2 = Tys8 {};
                let mut egn2: i32 = 0;
                let mut agg = false;
                if want != TYPE_NONE {
                    let sw = self.strip(want);
                    agg = self.aggregate_of(sw, &mut em, &mut ed, &mut egp2, &mut ega2, &mut egn2);
                }
                if agg && egn2 > 0 {
                    let ext = self.enclosing_extend(md.module, md.node);
                    if ext != NODE_NONE {
                        let ma = self.mod_ast(md.module);
                        let ig = ma.at_const(ext).as_data.extend_def.generics;
                        let gids = ma.list(ig);
                        let mut i: u32 = 0;
                        while i < ig.len && i as i32 < egn2 && nrsub < 8 {
                            rsubp[nrsub as usize] = DefId { module: md.module, node: unsafe gids[i as usize] };
                            rsuba[nrsub as usize] = ega2[i as usize];
                            nrsub = nrsub + 1;
                            i = i + 1;
                        }
                    }
                }
            }
        }
        // method-extend bounds check
        if cn_kind == NodeKind::NODE_MEMBER {
            let md = a.resolution_def(a.at_const(callee_id).as_data.member.member);
            if md.node != NODE_NONE && self.mod_ast(md.module).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                let mut mt = TYPE_NONE;
                if !cn_path {
                    if cdu != null {
                        mt = unsafe cdu.target;
                    } else {
                        mt = self.strip(a.type_of(a.at_const(callee_id).as_data.member.object));
                    }
                } else {
                    let ob = a.resolution_def(a.at_const(callee_id).as_data.member.object);
                    if ob.node != NODE_NONE && self.mod_ast(ob.module).at_const(ob.node).kind == NodeKind::NODE_INTERFACE && want != TYPE_NONE {
                        mt = self.strip(want);
                    } else {
                        mt = self.strip(a.type_of(a.at_const(callee_id).as_data.member.object));
                    }
                }
                if mt != TYPE_NONE && !self.method_extend_bounds_hold(mt, md) {
                    self.err_method_extend_bounds(sp, mt, md);
                    return TYPE_NONE;
                }
            }
        }
        // generic function call inference
        let mut gparams = Defs8 {};
        let mut gargs = Tys8 {};
        let mut gn: i32 = 0;
        if named && fa.at_const(fdecl).as_data.function.generics.len != 0 {
            let gens = fa.at_const(fdecl).as_data.function.generics;
            let mut g = gens.len as i32;
            if g > 8 {
                g = 8;
            }
            for ii in 0..g {
                gparams[ii as usize] = DefId { module: fmod, node: unsafe fa.list(gens)[ii as usize] };
                gargs[ii as usize] = TYPE_NONE;
            }
            let mut bound = Tys8 {};
            let mut nexplicit: i32 = 0;
            if cn_kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let tas = a.at_const(callee_id).as_data.specialization.types;
                let mut i: u32 = 0;
                while i < tas.len && nexplicit < g {
                    bound[nexplicit as usize] = a.type_of(unsafe a.list(tas)[i as usize]);
                    nexplicit = nexplicit + 1;
                    i = i + 1;
                }
            }
            if nexplicit < g && args.len == params.len - skip {
                for i in 0..args.len {
                    let pid = unsafe fa.list(params)[(i + skip) as usize];
                    let aty = a.type_of(unsafe a.list(args)[i as usize]);
                    self.unify_infer(self.decl_type_in(fmod, pid), aty, &gparams[0], &mut bound[0], g);
                    if fa.at_const(pid).kind == NodeKind::NODE_PARAMETER {
                        self.infer_const_len(
                            fmod,
                            fa.at_const(pid).as_data.parameter.ty,
                            aty,
                            unsafe a.list(args)[i as usize],
                            &gparams[0],
                            &mut bound[0],
                            g,
                            0,
                        );
                    }
                }
                for k in 0..g {
                    if bound[k as usize] != TYPE_NONE && self.type_at(bound[k as usize]).kind == TypeKind::TYPE_FUNCTION {
                        let fb = self.generic_fn_bound(fmod, unsafe fa.list(gens)[k as usize]);
                        if fb != NODE_NONE {
                            self.unify_infer(
                                self.lower_type_in(fmod, fb),
                                bound[k as usize],
                                &gparams[0],
                                &mut bound[0],
                                g,
                            );
                        }
                    }
                }
                self.infer_from_bounds(fmod, fdecl, fa.list(gens), &gparams[0], &mut bound[0], g);
                nexplicit = g;
            }
            for i in 0..nexplicit {
                gargs[i as usize] = bound[i as usize];
            }
            gn = nexplicit;
            // A closure written inside a generic body is monomorphized with that body, so its C form
            // differs per instantiation. Binding it to ANOTHER function's type parameter would make
            // that function's instance depend on which instantiation produced the closure -- which the
            // closure's type does not record, so both would collapse onto one wrong symbol.
            if self.tc_fn_is_generic(self.cur_module(), self.current_fn) {
                let mut bad = false;
                for i in 0..gn {
                    if self.tc_is_local_closure(gargs[i as usize]) {
                        bad = true;
                    }
                }
                if bad {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "a closure declared inside a generic function cannot be passed to another generic function; call it directly, or take the callback as a plain 'fn' pointer type",
                        ),
                    );
                }
            }
            if gn == g {
                self.cur_ast().set_type_args(id, &gargs[0], gn as u8);
                // enforce bounds (best-effort; diagnostics)
                self.check_generic_bounds(
                    id,
                    fmod,
                    fdecl,
                    gens,
                    &gparams[0],
                    &gargs[0],
                    gn,
                    &rsubp[0],
                    &rsuba[0],
                    nrsub,
                );
            }
        }
        // Owner (extend) generics for a static/associated call: a constructor like `Box::new(w)` calls
        // `new`, which has NO generics of its own -- `T`/`A` belong to `extend<T, A> Box<T, A>`. The
        // function-generic pass above therefore binds nothing, and no receiver instance supplies the
        // owner args (nrsub == 0). Infer them from the arguments the way function-own generics are, then
        // fill any that remain with the extend's declared defaults (e.g. `A = Global`). Result and
        // parameter types below are substituted through rsubp/rsuba, so `T` resolves to the argument's
        // concrete type and `Box<T>` coerces to `Box<dyn I>` at the use site -- no turbofish needed.
        if nrsub == 0 && named && fdecl != NODE_NONE && args.len == params.len - skip {
            let extnode = self.enclosing_extend(fmod, fdecl);
            if extnode != NODE_NONE {
                let ig = fa.at_const(extnode).as_data.extend_def.generics;
                let mut og = ig.len as i32;
                if og > 8 {
                    og = 8;
                }
                if og > 0 {
                    // The owner type's own generic list (`struct Box<T, A = Global>`) supplies the
                    // DEFAULTS, which the extend's re-declared `<T, A: Allocator + Default>` does not.
                    let target = fa.at_const(extnode).as_data.extend_def.target_type;
                    let sdef = self.tc_peel_target(fa.resolution_def(target));
                    let mut sgens = NodeList { start: 0, len: 0 };
                    if sdef.node != NODE_NONE {
                        let sdn = self.mod_ast(sdef.module).at_const(sdef.node);
                        if sdn.kind == NodeKind::NODE_STRUCT || sdn.kind == NodeKind::NODE_ENUM {
                            sgens = sdn.as_data.aggregate.generics;
                        }
                    }
                    let mut oparams = Defs8 {};
                    let mut obound = Tys8 {};
                    for k in 0..og {
                        oparams[k as usize] = DefId { module: fmod, node: unsafe fa.list(ig)[k as usize] };
                        obound[k as usize] = TYPE_NONE;
                    }
                    for i in 0..args.len {
                        let pid = unsafe fa.list(params)[(i + skip) as usize];
                        self.unify_infer(
                            self.decl_type_in(fmod, pid),
                            a.type_of(unsafe a.list(args)[i as usize]),
                            &oparams[0],
                            &mut obound[0],
                            og,
                        );
                    }
                    let mut ia = Tys8 {};
                    let mut ic: u8 = 0;
                    for k in 0..og {
                        let mut b = obound[k as usize];
                        if b == TYPE_NONE && k as u32 < sgens.len {
                            let dft = self.mod_ast(sdef.module).at_const(
                                unsafe self.mod_ast(sdef.module).list(sgens)[k as usize],
                            ).as_data.generic_param.default_type;
                            if dft != NODE_NONE {
                                b = self.lower_type_in(sdef.module, dft);
                            }
                        }
                        if b != TYPE_NONE && nrsub < 8 {
                            rsubp[nrsub as usize] = oparams[k as usize];
                            rsuba[nrsub as usize] = b;
                            nrsub = nrsub + 1;
                            ia[ic as usize] = b;
                            ic = ic + 1;
                        }
                    }
                    // Make the inferred owner instance visible to codegen and monomorphization: give the
                    // callee's type object the concrete instance type (`Box<W2, Global>`), exactly as an
                    // explicit `Box::<W2>` turbofish would, so the static method is mangled and emitted.
                    if ic > 0 && cn_kind == NodeKind::NODE_MEMBER && cn_path && sdef.node != NODE_NONE {
                        let inst = self.cur_ast().intern_instance(sdef.module, sdef.node, &ia[0], ic);
                        self.cur_ast().set_type(a.at_const(callee_id).as_data.member.object, inst);
                    }
                }
            }
        }
        // `x.into()` hands the OBJECT to `from`'s parameter; it is never in `args`, so its conversions
        // (an array reaching a slice parameter, most of all) have to be checked here, or the value goes
        // to codegen unconverted.
        if conv_target != TYPE_NONE && skip == 1 && params.len == 1 {
            let pid0 = unsafe fa.list(params)[0];
            let raw0 = if_ty(named, self.decl_type_in(fmod, pid0), self.lower_type_in(fmod, pid0));
            let pt0 = self.subst_type(self.subst_type(raw0, &gparams[0], &gargs[0], gn), &rsubp[0], &rsuba[0], nrsub);
            let obj0 = a.at_const(callee_id).as_data.member.object;
            if pt0 != TYPE_NONE && !self.compatible(pt0, obj0) {
                self.err_mismatch(obj0, pt0);
            }
        }
        // arity + arg compatibility
        let variadic = named && fa.at_const(fdecl).as_data.function.is_variadic;
        let expected = params.len - skip;
        let bad = if_bool(variadic, args.len < expected, args.len != expected);
        if bad {
            let mut s2 = "s".ptr() as *const char;
            if expected == 1 {
                s2 = "".ptr() as *const char;
            }
            if variadic {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("expected at least {} argument{}, found {}", expected, diag::cstr(s2), args.len),
                );
            } else {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("expected {} argument{}, found {}", expected, diag::cstr(s2), args.len),
                );
            }
        } else {
            for i in 0..expected {
                let pid = unsafe fa.list(params)[(i + skip) as usize];
                let raw = if_ty(named, self.decl_type_in(fmod, pid), self.lower_type_in(fmod, pid));
                let pt = self.subst_type(self.subst_type(raw, &gparams[0], &gargs[0], gn), &rsubp[0], &rsuba[0], nrsub);
                let aid = unsafe a.list(args)[i as usize];
                if self.type_at(pt).kind == TypeKind::TYPE_FUNCTION {
                    let at = a.type_of(aid);
                    if pt != at && at != TYPE_NONE && self.fn_is_capturing(at) {
                        let asp = a.at_const(aid).span;
                        self.errors.emit(
                            asp.start,
                            asp.end - asp.start,
                            format("a capturing closure cannot be passed as a bare 'fn' pointer"),
                        );
                    } else if at == TYPE_NONE || self.at_not_fn(at) || !self.fn_compatible_subst(
                        pt,
                        at,
                        &gparams[0],
                        &gargs[0],
                        gn,
                        &rsubp[0],
                        &rsuba[0],
                        nrsub,
                    ) && !self.tc_coerce_generic_fn(pt, aid) {
                        self.err_mismatch(aid, pt);
                    }
                } else if !self.compatible(pt, aid) {
                    self.err_mismatch(aid, pt);
                }
            }
        }
        // C-vararg string-literal default to *const char
        if variadic && !fmt_builtin && args.len >= expected {
            let cstr = self.cur_ast().intern_type(
                Ty {
                    kind: TypeKind::TYPE_POINTER,
                    qualifier: TypeQualifier::TYPE_QUAL_CONST as u8,
                    as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_CHAR) },
                },
            );
            let mut i = expected;
            while i < args.len {
                let aid = unsafe a.list(args)[i as usize];
                let an = a.at_const(aid);
                if an.kind == NodeKind::NODE_LITERAL && (an.as_data.literal.token_type == TokenType::StringLiteral || an.as_data.literal.token_type == TokenType::RawStringLiteral) {
                    self.cur_ast().set_type(aid, cstr);
                }
                i = i + 1;
            }
        }
        // &mut self receiver mutability
        if skip == 1 && cn_kind == NodeKind::NODE_MEMBER && params.len > 0 {
            let selfp = *self.type_at(self.decl_type_in(fmod, unsafe fa.list(params)[0]));
            if (selfp.kind == TypeKind::TYPE_REFERENCE || selfp.kind == TypeKind::TYPE_POINTER) && selfp.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                let recv = a.at_const(callee_id).as_data.member.object;
                let rvt = *self.type_at(a.type_of(recv));
                if rvt.kind == TypeKind::TYPE_DYN {
                    if rvt.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                        let rsp = a.at_const(recv).span;
                        self.errors.emit(
                            rsp.start,
                            rsp.end - rsp.start,
                            format("cannot call a '&mut self' method through '&dyn' (use '&mut dyn')"),
                        );
                    } else if rvt.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 && !self.receiver_mutable(recv) {
                        let rsp = a.at_const(recv).span;
                        self.errors.emit(
                            rsp.start,
                            rsp.end - rsp.start,
                            format("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')"),
                        );
                    }
                } else {
                    let consuming_free = rvt.kind != TypeKind::TYPE_REFERENCE && rvt.kind != TypeKind::TYPE_POINTER && span_is(
                        self.mod_src(self.cur_module()),
                        a.at_const(a.at_const(callee_id).as_data.member.member).as_data.name.text,
                        "free",
                    );
                    if !consuming_free {
                        if !self.receiver_mutable(recv) {
                            let rsp = a.at_const(recv).span;
                            self.errors.emit(
                                rsp.start,
                                rsp.end - rsp.start,
                                format("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')"),
                            );
                        }
                    }
                }
            }
        }
        if clos && fa.at_const(fdecl).as_data.closure.expr_body {
            return fa.type_of(fa.at_const(fdecl).as_data.closure.body);
        }
        if named && self.tc_attr(fmod, fdecl, AttrKind::ATTR_NORETURN) != null {
            return self.cur_ast().intern_type(Ty { kind: TypeKind::TYPE_NEVER });
        }
        if returns.len != 1 {
            if returns.len > 1 {
                self.mret_n = if_u8(returns.len < 8, returns.len as u8, 8);
                self.mret_total = returns.len;
                for i in 0..self.mret_n {
                    let mrid = unsafe fa.list(returns)[i as usize];
                    let mrn = fa.at_const(mrid);
                    let mrt = self.lower_type_in(
                        fmod,
                        if_node(mrn.kind == NodeKind::NODE_PARAMETER, mrn.as_data.parameter.ty, mrid),
                    );
                    unsafe self.mret_types[i as usize] = self.subst_type(
                        self.subst_type(mrt, &gparams[0], &gargs[0], gn),
                        &rsubp[0],
                        &rsuba[0],
                        nrsub,
                    );
                }
                self.mret_call = id;
                return TYPE_NONE;
            }
            // an omitted return type IS void: the call must not type-check leniently
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let r0 = unsafe fa.list(returns)[0];
        let rn = fa.at_const(r0);
        let ret = self.lower_type_in(fmod, if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
        return self.subst_type(self.subst_type(ret, &gparams[0], &gargs[0], gn), &rsubp[0], &rsuba[0], nrsub);
    }

    fn check_generic_bounds(
        self: &mut Self,
        id: NodeId,
        fmod: ModuleId,
        fdecl: NodeId,
        gens: NodeList,
        gparams: *const DefId,
        gargs: *const TypeId,
        gn: i32,
        rsubp: *const DefId,
        rsuba: *const TypeId,
        nrsub: i32,
    ) {
        let a = self.cur_ast();
        let fa = self.mod_ast(fmod);
        let sp = a.at_const(id).span;
        for i in 0..gn {
            let gid = unsafe fa.list(gens)[i as usize];
            let pb = fa.at_const(gid).as_data.generic_param.bounds;
            for b in 0..pb.len {
                let bid = unsafe fa.list(pb)[b as usize];
                if fa.at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                    let bt = self.lower_type_in(fmod, bid);
                    let garg = unsafe gargs[i as usize];
                    if garg != TYPE_NONE {
                        let gy = *self.type_at(garg);
                        if gy.kind != TypeKind::TYPE_GENERIC && (gy.kind != TypeKind::TYPE_FUNCTION || !self.fn_compatible_subst(
                            bt,
                            garg,
                            gparams,
                            gargs,
                            gn,
                            rsubp,
                            rsuba,
                            nrsub,
                        )) {
                            let mut tn = Buf96 {};
                            self.render_type(garg, &mut tn[0], 96);
                            let bsp = fa.at_const(bid).span;
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format(
                                    "type '{}' does not satisfy bound '{}'",
                                    diag::cstr(&tn[0]),
                                    diag::span_str(self.mod_src(fmod), bsp.start, bsp.end),
                                ),
                            );
                        }
                    }
                } else {
                    let bi = fa.resolution_def(bid);
                    if bi.node != NODE_NONE && !self.type_satisfies(unsafe gargs[i as usize], bi, 0) {
                        let mut tn = Buf96 {};
                        self.render_type(unsafe gargs[i as usize], &mut tn[0], 96);
                        let bsp = fa.at_const(bid).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format(
                                "type '{}' does not satisfy bound '{}'",
                                diag::cstr(&tn[0]),
                                diag::span_str(self.mod_src(fmod), bsp.start, bsp.end),
                            ),
                        );
                    }
                }
            }
        }
        // where clause
        let wc = fa.at_const(fdecl).as_data.function.where_clause;
        for w in 0..wc.len {
            let wp = fa.at_const(unsafe fa.list(wc)[w as usize]).as_data.where_predicate;
            let wt = self.subst_type(self.lower_type_in(fmod, wp.ty), gparams, gargs, gn);
            for b in 0..wp.bounds.len {
                let wbid = unsafe fa.list(wp.bounds)[b as usize];
                if fa.at_const(wbid).kind == NodeKind::NODE_FUNCTION_TYPE {
                    let bt = self.lower_type_in(fmod, wbid);
                    if wt != TYPE_NONE {
                        let wy = *self.type_at(wt);
                        if wy.kind != TypeKind::TYPE_GENERIC && (wy.kind != TypeKind::TYPE_FUNCTION || !self.fn_compatible_subst(
                            bt,
                            wt,
                            gparams,
                            gargs,
                            gn,
                            rsubp,
                            rsuba,
                            nrsub,
                        )) {
                            let mut tn = Buf96 {};
                            self.render_type(wt, &mut tn[0], 96);
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format("type '{}' does not satisfy a where-clause bound", diag::cstr(&tn[0])),
                            );
                        }
                    }
                } else {
                    let bi = fa.resolution_def(wbid);
                    if bi.node != NODE_NONE && !self.type_satisfies(wt, bi, 0) {
                        let mut tn = Buf96 {};
                        self.render_type(wt, &mut tn[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("type '{}' does not satisfy a where-clause bound", diag::cstr(&tn[0])),
                        );
                    }
                }
            }
        }
    }
}

pub const fn if_u8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

extend TypeChecker {
    /// Is `ty` a closure's own type (not a fn pointer, not a named function)?
    const fn tc_is_local_closure(self: &Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.type_at(ty);
        return y.kind == TypeKind::TYPE_FUNCTION && self.mod_ast(y.module).at_const(y.as_data.decl).kind == NodeKind::NODE_CLOSURE;
    }

    /// Does `decl` carry type parameters of its own, or inherit an extend's?
    fn tc_fn_is_generic(self: &mut Self, m: ModuleId, decl: NodeId) bool {
        if decl == NODE_NONE || self.mod_ast(m).at_const(decl).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        if self.mod_ast(m).at_const(decl).as_data.function.generics.len != 0 {
            return true;
        }
        let ext = self.enclosing_extend(m, decl);
        return ext != NODE_NONE && self.mod_ast(m).at_const(ext).as_data.extend_def.generics.len != 0;
    }

    /// One `Deref` step: the type behind `ty`, with the `deref` that produces it written to `out`.
    /// TYPE_NONE when `ty` has no Deref, or its `deref` does not return a reference/pointer.
    fn tc_deref_step(self: &mut Self, ty: TypeId, out: *mut DefId) TypeId {
        unsafe *out = DefId { module: 0, node: NODE_NONE };
        let mut cm: ModuleId = 0;
        let mut cd = NODE_NONE;
        let mut cgp = Defs8 {};
        let mut cga = Tys8 {};
        let mut cgn: i32 = 0;
        if !self.aggregate_of(ty, &mut cm, &mut cd, &mut cgp, &mut cga, &mut cgn) {
            return TYPE_NONE;
        }
        let dm = self.find_method_cstr(cm, cd, "deref");
        if dm.node == NODE_NONE {
            return TYPE_NONE;
        }
        let dret = self.tc_method_ret(ty, dm);
        if dret == TYPE_NONE {
            return TYPE_NONE;
        }
        let dry = *self.type_at(dret);
        if dry.kind != TypeKind::TYPE_REFERENCE && dry.kind != TypeKind::TYPE_POINTER {
            return TYPE_NONE;
        }
        unsafe *out = dm;
        return dry.as_data.elem;
    }

    /// Record the single deref hop `node` needs, so codegen emits `T__deref(&x)` around it.
    fn tc_record_deref(self: &mut Self, node: NodeId, recv: TypeId, dm: DefId, target: TypeId) {
        let mut du = DerefUse { node: node, target: target, n: 1 };
        du.recv[0] = recv;
        du.method[0] = dm;
        self.cur_ast().add_deref_use(&du);
    }

    fn check_member(self: &mut Self, id: NodeId, prefer_method: bool) TypeId {
        let a = self.cur_ast();
        let want = self.expected;
        self.expected = TYPE_NONE;
        let obj_node = a.at_const(id).as_data.member.object;
        let obj = self.check_expr(obj_node);
        if obj == TYPE_NONE {
            return TYPE_NONE;
        }
        if self.lint {
            self.tc_lint_unnecessary_deref(obj_node);
        }
        let mname = a.at_const(id).as_data.member.member;
        let name = self.name_span(mname);
        let base = self.strip(obj);
        let mut bmod: ModuleId = 0;
        let mut bdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if self.aggregate_of(base, &mut bmod, &mut bdecl, &mut gp, &mut ga, &mut gn) {
            let mut mhit = DefId { module: 0, node: NODE_NONE };
            let mut fhit = NODE_NONE;
            let mut digits = name.end > name.start && name.end - name.start <= 2;
            let mut di = name.start;
            while di < name.end && digits {
                if self.source[di as usize] < b'0' || self.source[di as usize] > b'9' {
                    digits = false;
                }
                di = di + 1;
            }
            if digits {
                let bd0 = self.mod_ast(bmod).at_const(bdecl);
                if bd0.kind == NodeKind::NODE_STRUCT && bd0.as_data.aggregate.is_tuple {
                    let mut idx: u32 = 0;
                    let mut k = name.start;
                    while k < name.end {
                        idx = idx * 10 + (self.source[k as usize] - b'0') as u32;
                        k = k + 1;
                    }
                    if idx >= bd0.as_data.aggregate.members.len {
                        self.errors.emit(
                            name.start,
                            name.end - name.start,
                            format("tuple struct has no element {}", idx),
                        );
                        return TYPE_NONE;
                    }
                    let tnode = unsafe self.mod_ast(bmod).list(bd0.as_data.aggregate.members)[idx as usize];
                    self.cur_ast().set_resolution_def(mname, DefId { module: bmod, node: tnode });
                    return self.subst_type(self.lower_type_in(bmod, tnode), &gp[0], &ga[0], gn);
                }
                let mut fld = Buf96 {};
                unsafe stdio::snprintf(
                    &mut fld[0],
                    8,
                    "_%.*s".ptr() as *const char,
                    (name.end - name.start) as i32,
                    src_at(self.source, name.start),
                );
                fhit = self.find_member_cstr(bmod, bdecl, diag::cstr(&fld[0]));
            }
            if fhit == NODE_NONE && prefer_method {
                mhit = self.tc_pick_method_overload(bmod, bdecl, name, self.find_method(bmod, bdecl, name), base, want);
                if mhit.node == NODE_NONE {
                    fhit = self.find_member(bmod, bdecl, name);
                }
            } else if fhit == NODE_NONE {
                fhit = self.find_member(bmod, bdecl, name);
                if fhit == NODE_NONE {
                    mhit = self.tc_pick_method_overload(
                        bmod,
                        bdecl,
                        name,
                        self.find_method(bmod, bdecl, name),
                        base,
                        want,
                    );
                }
            }
            if mhit.node != NODE_NONE {
                self.cur_ast().set_resolution_def(mname, mhit);
                return self.subst_type(self.decl_type_in(mhit.module, mhit.node), &gp[0], &ga[0], gn);
            }
            if fhit != NODE_NONE {
                self.cur_ast().set_resolution_def(mname, DefId { module: bmod, node: fhit });
                let fty = self.subst_type(self.decl_type_in(bmod, fhit), &gp[0], &ga[0], gn);
                if self.mod_ast(bmod).at_const(fhit).kind == NodeKind::NODE_FIELD {
                    self.check_field_visibility(bmod, fhit, bdecl, name);
                    // raw-pointer gate FIRST: tc_needs_unsafe() counts a use for the unnecessary-'unsafe'
                    // lint, and a field access through a reference/value must not consume the marker
                    if self.through_raw_pointer(obj) && self.tc_needs_unsafe() {
                        self.err_unsafe(a.at_const(id).span, "accessing a field through a raw pointer");
                    }
                    // A reference-typed field of an untagged UNION overlaps every other field, so
                    // accessing it materializes a `&T` from arbitrary bytes -- an int->reference
                    // transmute. Gate it behind `unsafe` (a raw *pointer* field stays free: its
                    // deref is already gated). is_union is on the aggregate decl.
                    let fty_is_ref = fty != TYPE_NONE && self.type_at(fty).kind == TypeKind::TYPE_REFERENCE;
                    let owner_is_union = self.mod_ast(bmod).at_const(bdecl).as_data.aggregate.is_union;
                    if fty_is_ref && owner_is_union && self.tc_needs_unsafe() {
                        self.err_unsafe(a.at_const(id).span, "accessing a reference-typed field of a union");
                    }
                }
                return fty;
            }
            if prefer_method {
                let dm = self.find_default_method(bmod, bdecl, name);
                if dm.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(mname, dm);
                    return self.subst_type(self.decl_type_in(dm.module, dm.node), &gp[0], &ga[0], gn);
                }
            }
        }
        // builtin method
        let bty = *self.type_at(base);
        if bty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = self.package.builtin_decl(bty.as_data.builtin);
            if bd != NODE_NONE {
                let mut mhit = self.find_method(unsafe self.package.core_module, bd, name);
                if mhit.node == NODE_NONE {
                    mhit = self.find_default_method(unsafe self.package.core_module, bd, name);
                }
                if mhit.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(mname, mhit);
                    return self.decl_type_in(mhit.module, mhit.node);
                }
            }
        }
        // generic/dyn receiver bound method
        let bt2 = *self.type_at(base);
        if bt2.kind == TypeKind::TYPE_GENERIC || bt2.kind == TypeKind::TYPE_DYN {
            let bdecl = if bt2.kind == TypeKind::TYPE_DYN {
                self.cur_ast().dyn_decl_of(&bt2);
            } else {
                bt2.as_data.decl;
            };
            let gd = self.mod_ast(bt2.module).at_const(bdecl);
            if gd.kind == NodeKind::NODE_INTERFACE {
                let m = self.find_interface_method(bt2.module, bdecl, name, 0);
                if m.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(mname, m);
                    return self.decl_type_in(m.module, m.node);
                }
            } else {
                let mut iface = DefId { module: 0, node: NODE_NONE };
                let m = self.find_bound_method(bt2.module, bt2.as_data.decl, name, &mut iface);
                if m.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(mname, m);
                    return self.decl_type_in(m.module, m.node);
                }
            }
        }
        // into/try_into conversion
        if prefer_method {
            let conv = self.resolve_conversion(name, want);
            if conv.node != NODE_NONE {
                self.cur_ast().set_resolution_def(mname, conv);
                return self.decl_type_in(conv.module, conv.node);
            }
        }
        // auto-deref chain -- for fields as well as methods: `b.v` through a Deref is the same step
        // `b.peek()` takes, and stopping at methods left the field unreachable.
        let mut deref_capped = false;
        {
            let mut du = DerefUse { node: mname, n: 0 };
            let mut cur = base;
            let mut seen = Tys8 {};
            seen[0] = base;
            let mut nseen: i32 = 1;
            loop {
                if du.n >= 8 {
                    break;
                }
                let mut cm: ModuleId = 0;
                let mut cd = NODE_NONE;
                let mut cgp = Defs8 {};
                let mut cga = Tys8 {};
                let mut cgn: i32 = 0;
                if !self.aggregate_of(cur, &mut cm, &mut cd, &mut cgp, &mut cga, &mut cgn) {
                    break;
                }
                let dm = self.find_method_cstr(cm, cd, "deref");
                if dm.node == NODE_NONE {
                    break;
                }
                let dret = self.tc_method_ret(cur, dm);
                if dret == TYPE_NONE {
                    break;
                }
                let dry = *self.type_at(dret);
                if dry.kind != TypeKind::TYPE_REFERENCE && dry.kind != TypeKind::TYPE_POINTER {
                    break;
                }
                let target = dry.as_data.elem;
                let mut cyc = false;
                for z in 0..nseen {
                    if seen[z as usize] == target {
                        cyc = true;
                    }
                }
                if cyc {
                    self.errors.emit(
                        name.start,
                        name.end - name.start,
                        format(
                            "cyclic deref chain while resolving '{}'",
                            diag::span_str(self.source, name.start, name.end),
                        ),
                    );
                    return TYPE_NONE;
                }
                unsafe du.recv[du.n as usize] = cur;
                unsafe du.method[du.n as usize] = dm;
                du.n = du.n + 1;
                seen[nseen as usize] = target;
                nseen = nseen + 1;
                let mut tm: ModuleId = 0;
                let mut td = NODE_NONE;
                let mut tgp = Defs8 {};
                let mut tga = Tys8 {};
                let mut tgn: i32 = 0;
                let mut mhit = DefId { module: 0, node: NODE_NONE };
                let mut tfhit = NODE_NONE;
                let tty = *self.type_at(target);
                if self.aggregate_of(target, &mut tm, &mut td, &mut tgp, &mut tga, &mut tgn) {
                    if prefer_method {
                        mhit = self.find_method(tm, td, name);
                        if mhit.node == NODE_NONE {
                            mhit = self.find_default_method(tm, td, name);
                        }
                    }
                    if mhit.node == NODE_NONE {
                        tfhit = self.find_member(tm, td, name);
                    }
                } else if tty.kind == TypeKind::TYPE_BUILTIN && self.package != null && prefer_method {
                    let bd = self.package.builtin_decl(tty.as_data.builtin);
                    if bd != NODE_NONE {
                        mhit = self.find_method(unsafe self.package.core_module, bd, name);
                        if mhit.node == NODE_NONE {
                            mhit = self.find_default_method(unsafe self.package.core_module, bd, name);
                        }
                    }
                }
                if mhit.node != NODE_NONE {
                    let sk = self.method_self_kind(mhit);
                    if sk == 0 && tty.kind != TypeKind::TYPE_BUILTIN {
                        self.errors.emit(
                            name.start,
                            name.end - name.start,
                            format("cannot call a by-value 'self' method through auto-deref"),
                        );
                        return TYPE_NONE;
                    }
                    if sk == 2 {
                        for hi in 0..du.n {
                            let mut hm: ModuleId = 0;
                            let mut hd = NODE_NONE;
                            let mut hgp = Defs8 {};
                            let mut hga = Tys8 {};
                            let mut hgn: i32 = 0;
                            self.aggregate_of(
                                unsafe du.recv[hi as usize],
                                &mut hm,
                                &mut hd,
                                &mut hgp,
                                &mut hga,
                                &mut hgn,
                            );
                            let dmm = self.find_method_cstr(hm, hd, "deref_mut");
                            if dmm.node == NODE_NONE {
                                let mut tn = Buf96 {};
                                self.render_type(unsafe du.recv[hi as usize], &mut tn[0], 96);
                                self.errors.emit(
                                    name.start,
                                    name.end - name.start,
                                    format(
                                        "cannot call a '&mut self' method through '{}': it has 'deref' but no 'deref_mut'",
                                        diag::cstr(&tn[0]),
                                    ),
                                );
                                return TYPE_NONE;
                            }
                            unsafe du.method[hi as usize] = dmm;
                        }
                    }
                    du.target = target;
                    self.cur_ast().add_deref_use(&du);
                    self.cur_ast().set_resolution_def(mname, mhit);
                    return self.subst_type(self.decl_type_in(mhit.module, mhit.node), &tgp[0], &tga[0], tgn);
                }
                if tfhit != NODE_NONE {
                    du.target = target;
                    self.cur_ast().add_deref_use(&du);
                    self.cur_ast().set_resolution_def(mname, DefId { module: tm, node: tfhit });
                    if self.mod_ast(tm).at_const(tfhit).kind == NodeKind::NODE_FIELD {
                        self.check_field_visibility(tm, tfhit, td, name);
                    }
                    return self.subst_type(self.decl_type_in(tm, tfhit), &tgp[0], &tga[0], tgn);
                }
                cur = target;
            }
            deref_capped = du.n == 8;
        }
        let mut ty = Buf96 {};
        self.render_type(base, &mut ty[0], 96);
        self.errors.emit(
            name.start,
            name.end - name.start,
            format(
                "no field or method '{}' on '{}'",
                diag::span_str(self.source, name.start, name.end),
                diag::cstr(&ty[0]),
            ),
        );
        if deref_capped {
            self.errors.note(format("auto-deref stopped after its maximum of 8 hops"));
        } else {
            self.errors.note(
                format(
                    "fields are accessed as 'value.name'; methods must be declared in an 'extend' block or provided by a bound",
                ),
            );
        }
        return TYPE_NONE;
    }

    fn check_path_member(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let direct = a.resolution_def(id);
        let mem = a.at_const(id).as_data.member.member;
        if direct.node != NODE_NONE {
            let dnk = self.mod_ast(direct.module).at_const(direct.node).kind;
            if dnk == NodeKind::NODE_FUNCTION || dnk == NodeKind::NODE_CONST || dnk == NodeKind::NODE_LET {
                self.cur_ast().set_resolution_def(mem, direct);
                self.tc_static_mut_use(id, direct); // `mod::G` reaches the same shared state as a bare `G`
                return self.decl_type_in(direct.module, direct.node);
            }
            return self.named_type_of(direct.module, direct.node);
        }
        let obj = a.at_const(id).as_data.member.object;
        let on_kind = a.at_const(obj).kind;
        let mut bmod: ModuleId = 0;
        let mut bdecl = NODE_NONE;
        let mut inst_ty = TYPE_NONE;
        if on_kind == NodeKind::NODE_IDENTIFIER {
            let b = a.resolution_def(obj);
            bmod = b.module;
            bdecl = b.node;
            if bdecl == NODE_NONE && self.package != null {
                let bb = builtin_of(self.source, a.at_const(obj).span);
                let mut bnd = NODE_NONE;
                if bb >= 0 {
                    bnd = self.package.builtin_decl(bb as BuiltinType);
                }
                if bnd != NODE_NONE {
                    bmod = unsafe self.package.core_module;
                    bdecl = bnd;
                }
            }
            if bdecl != NODE_NONE && self.mod_ast(bmod).at_const(bdecl).kind == NodeKind::NODE_TYPE_ALIAS {
                let at = self.named_type_of(bmod, bdecl);
                if at != TYPE_NONE && at != TYPE_ERROR {
                    let aty = *self.type_at(at);
                    if aty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                        bmod = unsafe self.package.core_module;
                        bdecl = self.package.builtin_decl(aty.as_data.builtin);
                    } else if aty.kind == TypeKind::TYPE_STRUCT || aty.kind == TypeKind::TYPE_ENUM {
                        bmod = aty.module;
                        bdecl = aty.as_data.decl;
                    } else if aty.kind == TypeKind::TYPE_INSTANCE {
                        let ai = *self.cur_ast().instance(aty.as_data.inst);
                        bmod = ai.module;
                        bdecl = ai.decl;
                        inst_ty = at;
                        self.cur_ast().set_type(obj, at);
                    }
                }
            }
            if bdecl != NODE_NONE {
                let bdn = self.mod_ast(bmod).at_const(bdecl);
                if (bdn.kind == NodeKind::NODE_STRUCT || bdn.kind == NodeKind::NODE_ENUM) && bdn.as_data.aggregate.generics.len > 0 && self.agg_has_default_at(
                    bmod,
                    bdecl,
                    0,
                ) {
                    let mut ta = Tys8 {};
                    let mut tn: u8 = 0;
                    self.apply_default_args(bmod, bdecl, &mut ta[0], &mut tn);
                    if tn == bdn.as_data.aggregate.generics.len as u8 {
                        inst_ty = self.cur_ast().intern_instance(bmod, bdecl, &ta[0], tn);
                        self.cur_ast().set_type(obj, inst_ty);
                    }
                }
            }
        } else {
            let bt = self.check_expr(obj);
            let ty = *self.type_at(bt);
            if ty.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.cur_ast().instance(ty.as_data.inst);
                bmod = it.module;
                bdecl = it.decl;
                inst_ty = bt;
            } else if ty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                bmod = unsafe self.package.core_module;
                bdecl = self.package.builtin_decl(ty.as_data.builtin);
            } else {
                bmod = ty.module;
                bdecl = if_node(
                    bt != TYPE_NONE && (ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM),
                    ty.as_data.decl,
                    NODE_NONE,
                );
            }
        }
        let mname = self.name_span(mem);
        let mut bd_kind = NodeKind::NODE_NONE_KIND;
        if bdecl != NODE_NONE {
            bd_kind = self.mod_ast(bmod).at_const(bdecl).kind;
        }
        if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_GENERIC_PARAM {
            let mut iface = DefId { module: 0, node: NODE_NONE };
            let m = self.find_bound_method(bmod, bdecl, mname, &mut iface);
            if m.node != NODE_NONE {
                self.cur_ast().set_resolution_def(mem, m);
                return self.decl_type_in(m.module, m.node);
            }
        }
        if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_INTERFACE && expected != TYPE_NONE {
            let mut emod: ModuleId = 0;
            let mut edecl = NODE_NONE;
            let mut egp = Defs8 {};
            let mut ega = Tys8 {};
            let mut egn: i32 = 0;
            if self.aggregate_of(self.strip(expected), &mut emod, &mut edecl, &mut egp, &mut ega, &mut egn) {
                let m = self.find_method(emod, edecl, mname);
                if m.node != NODE_NONE {
                    self.cur_ast().set_resolution_def(mem, m);
                    return self.decl_type_in(m.module, m.node);
                }
            }
        }
        if bdecl == NODE_NONE || bd_kind != NodeKind::NODE_STRUCT && bd_kind != NodeKind::NODE_ENUM {
            let sp = a.at_const(id).span;
            if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_INTERFACE {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("cannot infer the implementing type for this interface call"),
                );
            } else {
                self.errors.emit(sp.start, sp.end - sp.start, format("'::' base must be a struct or enum type"));
            }
            return TYPE_NONE;
        }
        if bd_kind == NodeKind::NODE_ENUM {
            let variant = self.find_member(bmod, bdecl, mname);
            if variant != NODE_NONE && self.mod_ast(bmod).at_const(variant).kind == NodeKind::NODE_VARIANT {
                self.cur_ast().set_resolution_def(mem, DefId { module: bmod, node: variant });
                return if_ty(inst_ty != TYPE_NONE, inst_ty, self.named_type_of(bmod, bdecl));
            }
        }
        // `T::assoc()` names its type rather than passing a receiver, so aggregate_of never sees it:
        // hand the qualifying instance to the used-marking directly.
        self.mark_recv = inst_ty;
        let method = self.find_method(bmod, bdecl, mname);
        if method.node != NODE_NONE {
            self.cur_ast().set_resolution_def(mem, method);
            return self.decl_type_in(method.module, method.node);
        }
        let ac = self.find_assoc_const(bmod, bdecl, mname);
        if ac.node != NODE_NONE {
            self.cur_ast().set_resolution_def(mem, ac);
            return self.decl_type_in(ac.module, ac.node);
        }
        let mut kindw = "associated method or constant".ptr() as *const char;
        if bd_kind == NodeKind::NODE_ENUM {
            kindw = "variant, method, or constant".ptr() as *const char;
        }
        self.errors.emit(
            mname.start,
            mname.end - mname.start,
            format("no {} '{}' on this type", diag::cstr(kindw), diag::span_str(self.source, mname.start, mname.end)),
        );
        return TYPE_NONE;
    }

    fn check_struct_init(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let stn = a.at_const(id).as_data.struct_initializer.ty;
        let sty = self.type_of_type_node(stn);
        let mut smod: ModuleId = 0;
        let mut decl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(sty, &mut smod, &mut decl, &mut gp, &mut ga, &mut gn) {
            decl = NODE_NONE;
        }
        let mut variant = NODE_NONE;
        let mut vmod = smod;
        if a.at_const(stn).kind == NodeKind::NODE_TYPE_PATH {
            let parts = a.at_const(stn).as_data.type_path.parts;
            if parts.len >= 2 {
                let vd = a.resolution_def(unsafe a.list(parts)[(parts.len - 1) as usize]);
                if vd.node != NODE_NONE && self.mod_ast(vd.module).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                    variant = vd.node;
                    vmod = vd.module;
                }
            }
        }
        let fields = a.at_const(id).as_data.struct_initializer.fields;
        for i in 0..fields.len {
            let fid = unsafe a.list(fields)[i as usize];
            let fnn = a.at_const(fid).as_data.field_initializer.name;
            let fval = a.at_const(fid).as_data.field_initializer.value;
            let fname = self.name_span(fnn);
            // A field's own type is the expected type for its initializer -- the same contextual type a
            // `let` with an annotation gives. Without it an array literal in field position has nothing to
            // widen towards, so `Plain { b: [3, 0, 0, 7] }` typed itself `[i32]` and was rejected against a
            // `[i64; 4]` field. This used to be done only for an interface assoc call; the reason applies to
            // every initializer.
            if variant == NODE_NONE && decl != NODE_NONE {
                let field = self.find_member(smod, decl, fname);
                let ft = if_ty(
                    field != NODE_NONE,
                    self.subst_type(self.decl_type_in(smod, field), &gp[0], &ga[0], gn),
                    TYPE_NONE,
                );
                if ft != TYPE_NONE && self.cur_ast().type_concrete(ft) {
                    self.expected = ft;
                }
            }
            self.check_expr(fval);
            if variant != NODE_NONE {
                let va = self.mod_ast(vmod);
                let vpl = va.at_const(variant).as_data.variant.payload;
                let mut field = NODE_NONE;
                for j in 0..vpl.len {
                    let pfid = unsafe va.list(vpl)[j as usize];
                    let pf = va.at_const(pfid);
                    if pf.kind == NodeKind::NODE_FIELD && spans_eq2(
                        self.source,
                        fname,
                        self.mod_src(vmod),
                        va.at_const(pf.as_data.field.name).as_data.name.text,
                    ) {
                        field = pfid;
                        break;
                    }
                }
                if field == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(sty, &mut ty[0], 96);
                    self.errors.emit(
                        fname.start,
                        fname.end - fname.start,
                        format(
                            "no field '{}' on '{}'",
                            diag::span_str(self.source, fname.start, fname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                } else {
                    self.cur_ast().set_resolution_def(fnn, DefId { module: vmod, node: field });
                    let ft = self.subst_type(
                        self.lower_type_in(vmod, self.mod_ast(vmod).at_const(field).as_data.field.ty),
                        &gp[0],
                        &ga[0],
                        gn,
                    );
                    if !self.compatible(ft, fval) {
                        self.err_mismatch(fval, ft);
                    }
                }
                continue;
            }
            if decl == NODE_NONE {
                continue;
            }
            let field = self.find_member(smod, decl, fname);
            if field == NODE_NONE {
                let mut ty = Buf96 {};
                self.render_type(sty, &mut ty[0], 96);
                self.errors.emit(
                    fname.start,
                    fname.end - fname.start,
                    format(
                        "no field '{}' on '{}'",
                        diag::span_str(self.source, fname.start, fname.end),
                        diag::cstr(&ty[0]),
                    ),
                );
                continue;
            }
            self.cur_ast().set_resolution_def(fnn, DefId { module: smod, node: field });
            self.check_field_visibility(smod, field, decl, fname);
            let ft = self.subst_type(self.decl_type_in(smod, field), &gp[0], &ga[0], gn);
            if !self.compatible(ft, fval) {
                self.err_mismatch(fval, ft);
            }
        }
        return sty;
    }

    fn check_if_stmt(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let ifd = a.at_const(id).as_data.if_stmt;
        let c = self.check_expr(ifd.condition);
        if c != TYPE_NONE && !self.is_bool(c) {
            let sp = a.at_const(ifd.condition).span;
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("if condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
        }
        self.check_stmt(ifd.then_branch);
        self.check_stmt(ifd.else_branch);
    }

    fn pattern_irrefutable(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return true;
        }
        let a = self.cur_ast();
        let p = a.at_const(id);
        if p.kind == NodeKind::NODE_PATTERN_WILDCARD || p.kind == NodeKind::NODE_IDENTIFIER {
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_NAME || p.kind == NodeKind::NODE_PATTERN_TUPLE || p.kind == NodeKind::NODE_PATTERN_STRUCT {
            let nameId = p.as_data.pattern.name;
            if nameId != NODE_NONE {
                let d = a.resolution_def(nameId);
                if d.node != NODE_NONE && self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_VARIANT {
                    return false;
                }
            }
            if p.kind == NodeKind::NODE_PATTERN_NAME {
                return true;
            }
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if !self.pattern_irrefutable(unsafe a.list(children)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_FIELD {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if !self.pattern_irrefutable(unsafe a.list(children)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_OR {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if self.pattern_irrefutable(unsafe a.list(children)[i as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }
    fn pattern_covered_variant(self: &Self, id: NodeId) NodeId {
        let a = self.cur_ast();
        let p = a.at_const(id);
        if p.kind != NodeKind::NODE_PATTERN_NAME && p.kind != NodeKind::NODE_PATTERN_TUPLE && p.kind != NodeKind::NODE_PATTERN_STRUCT {
            return NODE_NONE;
        }
        let nameId = p.as_data.pattern.name;
        if nameId == NODE_NONE {
            return NODE_NONE;
        }
        let d = a.resolution_def(nameId);
        if d.node == NODE_NONE || self.mod_ast(d.module).at_const(d.node).kind != NodeKind::NODE_VARIANT {
            return NODE_NONE;
        }
        let children = p.as_data.pattern.children;
        for i in 0..children.len {
            if !self.pattern_irrefutable(unsafe a.list(children)[i as usize]) {
                return NODE_NONE;
            }
        }
        return d.node;
    }
    fn match_arm_coverage(
        self: &Self,
        pid: NodeId,
        emod: ModuleId,
        has_ea: bool,
        variants: NodeList,
        covered: *mut u64,
        catchall: *mut bool,
        tcov: *mut bool,
        fcov: *mut bool,
    ) {
        if pid == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let p = a.at_const(pid);
        if p.kind == NodeKind::NODE_PATTERN_OR {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                self.match_arm_coverage(
                    unsafe a.list(children)[i as usize],
                    emod,
                    has_ea,
                    variants,
                    covered,
                    catchall,
                    tcov,
                    fcov,
                );
            }
            return;
        }
        if self.pattern_irrefutable(pid) {
            unsafe *catchall = true;
            return;
        }
        if p.kind == NodeKind::NODE_PATTERN_LITERAL {
            let v = a.at_const(p.as_data.single.value);
            if v.kind == NodeKind::NODE_LITERAL && v.as_data.literal.token_type == TokenType::True {
                unsafe *tcov = true;
            } else if v.kind == NodeKind::NODE_LITERAL && v.as_data.literal.token_type == TokenType::False {
                unsafe *fcov = true;
            }
            return;
        }
        let var = self.pattern_covered_variant(pid);
        if var == NODE_NONE || !has_ea {
            return;
        }
        let ea = self.mod_ast(emod);
        let mut i: u32 = 0;
        while i < variants.len && i < MATCH_MAX_VARIANTS {
            if unsafe ea.list(variants)[i as usize] == var {
                let idx = (i >> 6) as usize;
                let cur = unsafe covered[idx];
                unsafe covered[idx] = cur | 1u64 << (i & 63) as u64;
                return;
            }
            i = i + 1;
        }
    }
    fn check_match_exhaustive(self: &mut Self, id: NodeId, scrut: TypeId) {
        if scrut == TYPE_NONE {
            return;
        }
        let a = self.cur_ast();
        let base = self.strip(scrut);
        let mut emod: ModuleId = 0;
        let mut edecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        let agok = self.aggregate_of(base, &mut emod, &mut edecl, &mut gp, &mut ga, &mut gn);
        let is_enum = agok && self.mod_ast(emod).at_const(edecl).kind == NodeKind::NODE_ENUM;
        let mut variants = NodeList { start: 0, len: 0 };
        if is_enum {
            variants = self.mod_ast(emod).at_const(edecl).as_data.aggregate.members;
        }
        let mut covered = Cover4 {};
        let mut catchall = false;
        let mut tcov = false;
        let mut fcov = false;
        let arms = a.at_const(id).as_data.match_expr.arms;
        for i in 0..arms.len {
            let arm = a.at_const(unsafe a.list(arms)[i as usize]);
            if arm.as_data.match_arm.guard == NODE_NONE {
                self.match_arm_coverage(
                    arm.as_data.match_arm.pattern,
                    emod,
                    is_enum,
                    variants,
                    &mut covered[0],
                    &mut catchall,
                    &mut tcov,
                    &mut fcov,
                );
            }
        }
        if catchall {
            return;
        }
        let sp = a.at_const(a.at_const(id).as_data.match_expr.value).span;
        if is_enum && variants.len <= MATCH_MAX_VARIANTS {
            let mut nmiss: u32 = 0;
            for k in 0..variants.len {
                if (covered[(k >> 6) as usize] & 1u64 << (k & 63) as u64) == 0 {
                    nmiss = nmiss + 1;
                }
            }
            if nmiss == 0 {
                return;
            }
            let mut s2 = "s".ptr() as *const char;
            if nmiss == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("switch is not exhaustive: missing {} variant{}", nmiss, diag::cstr(s2)),
            );
            self.errors.note(format("match every variant or add a '_' arm"));
            return;
        }
        if base == Ast::builtin(BuiltinType::BT_BOOL) && tcov && fcov {
            return;
        }
        self.errors.emit(sp.start, sp.end - sp.start, format("switch is not exhaustive"));
        self.errors.note(format("add a '_' arm to cover the remaining values"));
    }

    // ---- region variables (phase 1: allocation + slot counting; the solver consumes these later) ----
    //
    // A RegionVid is an inference variable standing for a region -- ultimately a set of program points
    // plus the universal regions it must outlive. `REGION_STATIC` outlives everything. A function's
    // declared lifetimes are UNIVERSAL (they outlive the body, and their relationships come from the
    // signature); every reference slot in a local's type gets a fresh EXISTENTIAL region.

    // Start a fresh region arena for `fnid` and bind its declared lifetimes to universal regions.
    // Only the id counter resets: RegionVids are function-scoped and never compared across functions,
    // and a node's region vector is only ever read while checking the function that owns it. Keeping
    // the pool and maps means no stale slice can dangle into re-used pool storage.

    // The universal RegionVid a declared lifetime NAME denotes in the current function, or REGION_NONE.

    // Record `sup: sub` -- sup outlives sub.

    // Does region `a` outlive region `b`? Reflexive, `'static` outlives everything, and TRANSITIVE
    // over the declared edges -- so `'a: 'b, 'b: 'c` proves `'a: 'c`, which a one-hop scan could not.
    // The declared graph is tiny (signature lifetimes only), so a bounded worklist is ample; running
    // out of room answers "cannot prove", which only ever over-rejects.

    // How many lifetime SLOTS does a type have? This is the length of its region vector, so it must be
    // exact and stable. Well-founded because an aggregate contributes only its DECLARED lifetime params
    // plus the regions of its generic arguments -- never its fields, which are expressed in terms of
    // those params. So `struct Node<'a> { next: &'a Node<'a> }` is arity 1, not infinite.
    // Raw pointers contribute nothing: this language hands lifetime responsibility to the programmer
    // there, and `&T -> *T` coercion already erases the borrow.

    // Give `node` a fresh region vector for `ty` -- one existential region per lifetime slot. Types
    // with no regions at all (the overwhelming majority in this codebase) never enter the map.

    // Record a region/lifetime diagnostic. These are the diagnostics the region SOLVER will produce
    // once it lands: it only knows a borrow outlives its referent after the whole body is walked and
    // its constraints are solved, so the message must be placed back into source order within this
    // function's range rather than appended at the end. Returns the index, for tc_region_note.

    // ---- fn_sig_regions: signature lifetime relationships + body-side elision enforcement ----
    // A lifetime is identified by its NAME (function-scoped; lifetimes are never resolved). An empty
    // span means "elided" -- a fresh, distinct lifetime that outlives nothing it is not explicitly
    // tied to. These helpers read the annotations off signature type nodes and the outlives edges off
    // the `where` clause and lifetime-param bounds, so a store into caller-visible data can be checked
    // against the declared relationships (Rust's elision rules) rather than guessed at.
    // Name span of a NODE_LIFETIME (or the NODE_LIFETIME held by a lifetime NODE_GENERIC_PARAM);
    // empty when NODE_NONE.
    // The lifetime annotation on a reference TYPE node (`&'a T`), empty if elided or not a reference.
    // Is `node` a `&`/`&mut` PARAMETER of the current function?
    // The lifetime a value's borrow carries, in the current function's scope: for a parameter reference
    // `x: &'a T` it is `'a`; anything else (a local, a computed borrow) is elided/empty -- i.e. does
    // not outlive caller data.
    // The lifetime of the reference SLOT a store targets, in the current function's scope. `*param`
    // stores at the parameter's own reference lifetime. `param.f1.f2...` walks the field chain,
    // mapping each aggregate's lifetime PARAMS through its instantiation at every hop -- so in
    // `o: &mut Outer<'a>` with `struct Outer<'a> { inner: Inner<'a> }`, the slot `o.inner.r` resolves
    // to `'a`. A single hop was all that resolved before, which rejected every nested store.
    // Unhandled shapes return empty (conservative: the store is then rejected).

    // The lifetime ARGUMENTS written on a type node (`Outer<'a, T>` -> ['a]), as name spans in `m`.

    // Map a lifetime NAME written inside aggregate `dd` to the argument that instantiates it.

    // The lifetime of a `&mut` container parameter's borrow-carrying ELEMENT, read off the type node
    // (`&mut Vector<&'a i32>` -> `'a`; elided -> empty). Used to check a store CALL into the container.
    // The `&`/`&mut` PARAMETER an argument identifier resolves to (unwrapping move/unsafe/cast), else
    // NODE_NONE. A store of such an argument into caller data is a signature-level relationship (unlike
    // a local, which the region tie + scope exit already catch).

    // The declared type node of aggregate field `fname`, or NODE_NONE.

    // tc_lt_name against an arbitrary module's AST (for struct-scope lifetime names).
    // Does the source lifetime provably outlive the destination? Reflexive, and TRANSITIVE over the
    // signature's declared outlives edges via the region solver -- so `'a: 'b, 'b: 'c` now proves
    // `'a: 'c`, which the previous one-hop scan rejected. Empty (elided) lifetimes outlive nothing.
    // Body-side elision check: storing a borrow into caller-visible data reachable through a `&`/`&mut`
    // PARAMETER escapes into the caller and is sound only if the stored value's lifetime is declared to
    // outlive the destination's. With elided (independent) lifetimes this is unprovable, so it is
    // rejected -- write a shared `<'a>` to express it. A reborrow of the same parameter's own data has
    // exactly the destination's lifetime and is always fine.

    /// The parameter a compound assignment's right operand answers to, when the overload takes it BY
    /// VALUE. `x <<= 3` lowers to `x = x.shl(3)`, so 3 is a count and not another x. A by-reference
    /// parameter (`add(self, other: &Self)`) keeps the plain same-type check, which is what it means.
    fn compound_param_type(self: &mut Self, op: TokenType, l: TypeId) TypeId {
        let m = compound_method_name(op);
        if m.len() == 0 || l == TYPE_NONE {
            return TYPE_NONE;
        }
        let mut ls = l;
        while ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_REFERENCE {
            ls = self.type_at(ls).as_data.elem;
        }
        let k = self.type_at(ls).kind;
        if k != TypeKind::TYPE_STRUCT && k != TypeKind::TYPE_INSTANCE {
            return TYPE_NONE;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(ls, &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return TYPE_NONE;
        }
        let md = self.find_method_cstr(om, od, m);
        if md.node == NODE_NONE {
            return TYPE_NONE;
        }
        let p1 = self.tc_method_param(ls, md, 1);
        if p1 == TYPE_NONE || self.type_at(p1).kind == TypeKind::TYPE_REFERENCE {
            return TYPE_NONE;
        }
        return p1;
    }

    fn check_assignment(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let bd = a.at_const(id).as_data.binary;
        let l = self.check_expr(bd.left);
        let pt = self.compound_param_type(bd.op, l);
        self.expected = if_ty(pt != TYPE_NONE, pt, l);
        self.check_expr(bd.right);
        if !self.is_assignable(bd.left) {
            let sp = a.at_const(bd.left).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot assign to this expression"));
        } else if pt != TYPE_NONE {
            if !self.operand_fits_param(pt, bd.right) {
                self.err_mismatch(bd.right, pt);
            }
        } else if !self.compatible(l, bd.right) {
            self.err_mismatch(bd.right, l);
        }
        return l;
    }
    fn check_closure(self: &mut Self, id: NodeId, cwant: TypeId) TypeId {
        let a = self.cur_ast();
        let params = a.at_const(id).as_data.closure.params;
        let mut sigp = Tys8 {};
        let mut sigr: TypeId = TYPE_NONE;
        let mut sn: i32 = -1;
        for i in 0..params.len {
            let pid = unsafe a.list(params)[i as usize];
            if a.at_const(pid).as_data.parameter.ty != NODE_NONE {
                continue;
            }
            if sn < 0 {
                if cwant != TYPE_NONE && self.type_at(cwant).kind == TypeKind::TYPE_FUNCTION {
                    sn = self.fn_sig(cwant, &mut sigp[0], 8, &mut sigr);
                } else {
                    sn = 0;
                }
            }
            if i as i32 < sn && sigp[i as usize] != TYPE_NONE {
                self.cur_ast().set_type(pid, sigp[i as usize]);
            } else {
                let psp = a.at_const(pid).span;
                self.errors.emit(
                    psp.start,
                    psp.end - psp.start,
                    format("closure parameter needs a type annotation (no expected function type supplies one)"),
                );
                self.errors.note(
                    format("annotate it (`|x: i32| ..`) or bind the closure where a 'fn' type is expected"),
                );
            }
        }
        for i in 0..params.len {
            self.decl_type(unsafe a.list(params)[i as usize]);
        }
        if self.nclos >= 8 {
            let sp = a.at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("closures nested too deeply (max 8)"));
            return TYPE_NONE;
        }
        let cn = self.nclos;
        unsafe self.clos_stack[cn as usize] = id;
        self.nclos = cn + 1;
        let saved_lf = self.loop_floor;
        self.loop_floor = self.nloops;
        if a.at_const(id).as_data.closure.expr_body {
            self.check_expr(a.at_const(id).as_data.closure.body);
        } else {
            let saved = self.current_returns;
            self.current_returns = a.at_const(id).as_data.closure.returns;
            self.check_stmt(a.at_const(id).as_data.closure.body);
            self.current_returns = saved;
        }
        self.loop_floor = saved_lf;
        self.nclos = self.nclos - 1;
        // capture validation
        let caps = a.at_const(id).as_data.closure.captures;
        let mut_caps = a.at_const(id).as_data.closure.mut_caps as u64;
        for i in 0..caps.len {
            let cid = unsafe a.list(caps)[i as usize];
            let cty = self.decl_type(cid);
            let is_mut = (mut_caps >> i as u64 & 1u64) != 0;
            if cty != TYPE_NONE && !is_mut && self.type_at(cty).kind == TypeKind::TYPE_ARRAY {
                let sp = a.at_const(id).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("closure cannot capture a fixed-size array by copy; capture a slice instead"),
                );
                continue;
            }
            if cty == TYPE_NONE || is_mut || !self.tc_type_is_free(cty) {
                continue;
            }
            if self.nmoved < 1024 {
                let k = self.nmoved;
                unsafe self.moved[k as usize] = cid;
                self.nmoved = k + 1;
            }
        }
        // A closure captures its free variables BY COPY into its environment. When a captured value
        // holds a borrow (a `&T` binding, or a struct/view carrying one), the environment carries
        // that borrow -- but unlike a struct field, it is ERASED from the closure's stored type
        // (`dyn fn` / a bare `fn` bound), so no later type-based check can recover it. Re-expose each
        // captured borrow as a fresh transient borrow rooted at the same referent; the enclosing
        // `let`/assignment that stores the closure then ties it to the destination's region (see
        // tc_expr_is_closure), so a closure stored past its captured referent's scope fails scope
        // exit exactly like a stored reference field. A closure that is merely called or passed
        // (not stored) leaves these transient and they release with the statement.
        let cap_bw = self.nborrows;
        for i in 0..caps.len {
            let cid = unsafe a.list(caps)[i as usize];
            for b in 0..cap_bw {
                let bb = unsafe self.borrows[b as usize];
                if bb.binding == cid && bb.root != NODE_NONE {}
            }
        }
        return self.cur_ast().intern_type(
            Ty { kind: TypeKind::TYPE_FUNCTION, module: self.cur_module(), as_data: TyAs { decl: id } },
        );
    }

    fn check_index(self: &mut Self, id: NodeId, addr_ctx: bool, _place_use: bool) TypeId {
        let a = self.cur_ast();
        let obj_n = a.at_const(id).as_data.index.object;
        let index_n = a.at_const(id).as_data.index.index;
        self.addr_ctx = addr_ctx;
        self.place_use = !addr_ctx;
        let mut obj = self.check_expr(obj_n);
        if self.type_at(obj).kind == TypeKind::TYPE_REFERENCE {
            let mut p = obj;
            let mut y = *self.type_at(p);
            while y.kind == TypeKind::TYPE_REFERENCE {
                p = y.as_data.elem;
                y = *self.type_at(p);
            }
            if y.kind != TypeKind::TYPE_ARRAY {
                obj = p;
            }
        }
        let ot = *self.type_at(obj);
        let idxn_kind = a.at_const(index_n).kind;
        if idxn_kind == NodeKind::NODE_RANGE {
            let mut elem = TYPE_NONE;
            let mut selem: TypeId = TYPE_NONE;
            let mut user_result = TYPE_NONE;
            if ot.kind == TypeKind::TYPE_ARRAY || ot.kind == TypeKind::TYPE_POINTER {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(a.at_const(obj_n).span, "slicing a raw pointer");
                }
                elem = ot.as_data.elem;
            } else if self.slice_kind(obj, &mut selem) != 0 {
                elem = selem;
            } else if ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE {
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                let sp = a.at_const(obj_n).span;
                if self.aggregate_of(self.strip(obj), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                    let md = self.find_method_cstr(om, od, "index_range");
                    if md.node == NODE_NONE {
                        let mut ty = Buf96 {};
                        self.render_type(self.strip(obj), &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'{}' has no 'index_range' method for '[..]'", diag::cstr(&ty[0])),
                        );
                    } else if !self.method_extend_bounds_hold(self.strip(obj), md) {
                        self.err_method_extend_bounds(sp, self.strip(obj), md);
                    } else {
                        if a.at_const(index_n).as_data.pattern_range.end == NODE_NONE && self.find_method_cstr(
                            om,
                            od,
                            "len",
                        ).node == NODE_NONE {
                            let mut ty = Buf96 {};
                            self.render_type(self.strip(obj), &mut ty[0], 96);
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format(
                                    "an open-ended range index needs a 'len' method on '{}' to supply the end",
                                    diag::cstr(&ty[0]),
                                ),
                            );
                        }
                        self.prelude_range_type(Ast::builtin(BuiltinType::BT_USIZE));
                        user_result = self.tc_method_ret(self.strip(obj), md);
                    }
                }
            } else if obj != TYPE_NONE {
                let sp = a.at_const(obj_n).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("cannot slice this expression"));
            }
            let bstart = a.at_const(index_n).as_data.pattern_range.start;
            let bend = a.at_const(index_n).as_data.pattern_range.end;
            if bstart != NODE_NONE {
                let bt = self.check_expr(bstart);
                if bt != TYPE_NONE && !self.is_int(bt) && a.at_const(bstart).kind != NodeKind::NODE_LITERAL {
                    let sp = a.at_const(bstart).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("range bound must be an integer"));
                }
            }
            if bend != NODE_NONE {
                let bt = self.check_expr(bend);
                if bt != TYPE_NONE && !self.is_int(bt) && a.at_const(bend).kind != NodeKind::NODE_LITERAL {
                    let sp = a.at_const(bend).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("range bound must be an integer"));
                }
            }
            // Slicing a raw `[T; N]` follows the raw-array indexing rule: every written bound must
            // const-fold with 0 <= start <= end <= N (a missing bound is 0 / N), else the view is
            // unproven and needs 'unsafe'. A provably out-of-range constant bound is a hard error.
            if ot.kind == TypeKind::TYPE_ARRAY {
                let n = ot.as_data.arr.len as i64;
                let inclusive = a.at_const(index_n).as_data.pattern_range.inclusive;
                let mut lo: i64 = 0;
                let mut hi: i64 = n;
                let mut proven = n != 0;
                if proven && bstart != NODE_NONE {
                    proven = self.tc_fold_int(bstart, &mut lo);
                }
                if proven && bend != NODE_NONE {
                    proven = self.tc_fold_int(bend, &mut hi);
                    if proven && inclusive {
                        hi = hi + 1;
                    }
                }
                let sp = a.at_const(id).span;
                if proven && (lo < 0 || lo > hi || hi > n) {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("range [{}, {}) is out of bounds for an array of length {}", lo, hi, n),
                    );
                } else if !proven && self.tc_needs_unsafe() {
                    self.err_unsafe(sp, "slicing an array with a non-constant range");
                }
            }
            // A `[..]` view borrows its source's storage, but `index_range` dispatches INLINE here
            // rather than through check_call, so the receiver-result-borrow hook never sees it. Pin
            // the source (or, when the source is itself a view like `s[0..2]`, inherit its container
            // borrow -- the reborrow rule). Both the `index_range` result and the `prelude_slice_type`
            // result (slice-of-a-slice, which `slice_kind` routes here before index_range) go through
            // the shared hook.
            let mut sresult = user_result;
            if sresult == TYPE_NONE && elem != TYPE_NONE {
                sresult = self.prelude_slice_type(elem, false);
            }
            return sresult;
        }
        let idx = self.check_expr(index_n);
        let mut overloaded = false;
        let mut result = TYPE_NONE;
        if obj != TYPE_NONE {
            let mut selem: TypeId = TYPE_NONE;
            if ot.kind == TypeKind::TYPE_ARRAY || ot.kind == TypeKind::TYPE_POINTER {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(a.at_const(obj_n).span, "indexing a raw pointer");
                }
                // Raw `[T; N]` indexing is unsafe-gated like raw pointers UNLESS the index
                // const-folds in bounds; a constant provably out of bounds is a hard error (never
                // unsafe-able). Safe dynamic indexing lives in the std views (Array/Slice/Vector).
                if ot.kind == TypeKind::TYPE_ARRAY {
                    let n = ot.as_data.arr.len as i64;
                    let mut v: i64 = 0;
                    if n != 0 && self.tc_fold_int(index_n, &mut v) {
                        if v < 0 || v >= n {
                            let sp = a.at_const(id).span;
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format("index {} is out of bounds for an array of length {}", v, n),
                            );
                        }
                    } else if self.tc_needs_unsafe() {
                        self.err_unsafe(a.at_const(obj_n).span, "indexing an array with a non-constant index");
                    }
                }
                result = ot.as_data.elem;
            } else if self.slice_kind(obj, &mut selem) != 0 {
                result = selem;
            } else if ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE {
                overloaded = true;
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                let sp = a.at_const(obj_n).span;
                if self.aggregate_of(self.strip(obj), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
                    let md = self.find_method_cstr(om, od, "index");
                    if md.node == NODE_NONE {
                        let mut ty = Buf96 {};
                        self.render_type(self.strip(obj), &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'{}' has no 'index' method for '[]'", diag::cstr(&ty[0])),
                        );
                    } else if !self.method_extend_bounds_hold(self.strip(obj), md) {
                        self.err_method_extend_bounds(sp, self.strip(obj), md);
                        result = TYPE_NONE;
                    } else {
                        let p1 = self.tc_method_param(self.strip(obj), md, 1);
                        if !self.operand_fits_param(p1, index_n) {
                            self.err_mismatch(index_n, p1);
                        }
                        result = self.tc_method_ret(self.strip(obj), md);
                        if result != TYPE_NONE && self.type_at(result).kind == TypeKind::TYPE_REFERENCE {
                            result = self.type_at(result).as_data.elem;
                        }
                    }
                }
            } else {
                let sp = a.at_const(obj_n).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("cannot index this expression"));
            }
        }
        if !overloaded && idx != TYPE_NONE && !self.is_int(idx) && a.at_const(index_n).kind != NodeKind::NODE_LITERAL {
            let sp = a.at_const(index_n).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("index must be an integer"));
        }
        return result;
    }

    fn check_match_expr(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let scrut = self.check_expr(a.at_const(id).as_data.match_expr.value);
        let sy = *self.type_at(scrut);
        let mut bind_ref: i32 = 0;
        if sy.kind == TypeKind::TYPE_REFERENCE || sy.kind == TypeKind::TYPE_POINTER {
            if sy.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                bind_ref = 2;
            } else {
                bind_ref = 1;
            }
        }
        if bind_ref == 0 {}
        let arms = a.at_const(id).as_data.match_expr.arms;
        let mut first = true;
        let ovf = false;
        let mut caught = false;
        let mut result = TYPE_NONE;
        for i in 0..arms.len {
            let aid = unsafe a.list(arms)[i as usize];
            let arm = a.at_const(aid).as_data.match_arm;
            // Lint: an unguarded wildcard / bare-binding arm catches everything; later arms never run.
            if caught {
                let psp = a.at_const(arm.pattern).span;
                self.errors.warn(
                    psp.start,
                    psp.end - psp.start,
                    format("unreachable arm: a previous arm matches every value"),
                );
                caught = false; // once per switch
            }
            self.check_pattern(arm.pattern, scrut, bind_ref);
            if self.lint && arm.guard == NODE_NONE && !caught {
                let pk = a.at_const(arm.pattern).kind;
                if pk == NodeKind::NODE_PATTERN_WILDCARD {
                    caught = true;
                } else if pk == NodeKind::NODE_PATTERN_NAME && a.at_const(arm.pattern).as_data.pattern.children.len == 0 {
                    let d = a.resolution_def(a.at_const(arm.pattern).as_data.pattern.name);
                    caught = d.node == NODE_NONE || d.module as usize < self.pkg_count() && self.mod_ast(d.module).at_const(
                        d.node,
                    ).kind != NodeKind::NODE_VARIANT;
                }
            }
            let g = self.check_expr(arm.guard);
            if arm.guard != NODE_NONE && g != TYPE_NONE && !self.is_bool(g) {
                let sp = a.at_const(arm.guard).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("match guard must be 'bool'"));
            }
            self.expected = expected;
            let mut body = self.check_expr(arm.body);
            if expected != TYPE_NONE {
                self.tc_tail_adapt(expected, arm.body);
                body = self.cur_ast().type_of(arm.body);
            }
            let body_never = body != TYPE_NONE && self.type_at(body).kind == TypeKind::TYPE_NEVER;
            if expected != TYPE_NONE {
                // a context type is known: each arm coerces to IT (widening, adaptation, the works)
                // instead of having to equal the first arm exactly
                if body != TYPE_NONE && !body_never && !self.compatible(expected, arm.body) {
                    self.err_mismatch(arm.body, expected);
                }
                if first {
                    result = body;
                    first = false;
                } else if !body_never {
                    result = expected;
                }
            } else if first {
                result = body;
                first = false;
            } else if result != TYPE_NONE && self.type_at(result).kind == TypeKind::TYPE_NEVER {
                result = body;
            } else if !body_never && result != body && body != TYPE_NONE && result != TYPE_NONE {
                self.err_mismatch(arm.body, result);
                result = TYPE_NONE;
            }
        }
        if arms.len != 0 {}
        if ovf {}
        self.check_match_exhaustive(id, scrut);
        return result;
    }

    fn check_expr(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        let a = self.cur_ast();
        let nk = a.at_const(id).kind;
        let expected = self.expected;
        self.expected = TYPE_NONE;
        let addr_ctx = self.addr_ctx;
        self.addr_ctx = false;
        let place_use = self.place_use;
        self.place_use = false;
        let mut result = TYPE_NONE;
        switch nk {
            NODE_LITERAL => {
                result = self.check_literal(id);
            },
            NODE_IDENTIFIER => {
                let d = a.resolution_def(id);
                result = self.decl_type_in(d.module, d.node);
                if d.node != NODE_NONE && self.mod_ast(d.module).at_const(d.node).kind == NodeKind::NODE_FUNCTION {
                    self.tc_check_test_ref(d, a.at_const(id).span);
                }
                self.tc_static_mut_use(id, d);
            },
            NODE_UNARY => {
                result = self.check_unary(id);
            },
            NODE_BINARY => {
                result = self.check_binary(id);
            },
            NODE_ASSIGNMENT => {
                result = self.check_assignment(id);
            },
            NODE_CALL => {
                result = self.check_call(id, expected);
            },
            NODE_CLOSURE => {
                result = self.check_closure(id, expected);
            },
            NODE_INDEX => {
                result = self.check_index(id, addr_ctx, place_use);
            },
            NODE_MEMBER => {
                let value_read = !a.at_const(id).as_data.member.path && !addr_ctx;
                self.addr_ctx = addr_ctx;
                self.place_use = value_read;
                if a.at_const(id).as_data.member.path {
                    result = self.check_path_member(id, expected);
                } else {
                    self.expected = expected;
                    result = self.check_member(id, false);
                }
            },
            NODE_CAST => {
                let src = self.check_expr(a.at_const(id).as_data.cast.expression);
                let dst = self.resolve_type(a.at_const(id).as_data.cast.ty);
                if self.lint && src != TYPE_NONE && src == dst && a.at_const(a.at_const(id).as_data.cast.expression).kind != NodeKind::NODE_LITERAL {
                    let csp = a.at_const(id).span;
                    self.errors.warn(
                        csp.start,
                        csp.end - csp.start,
                        format("unnecessary cast: the expression already has this type"),
                    );
                    self.tc_cast_drop_fix(id);
                }
                if src != TYPE_NONE && dst != TYPE_NONE && self.type_at(src).kind == TypeKind::TYPE_POINTER && self.type_at(
                    dst,
                ).kind == TypeKind::TYPE_REFERENCE {
                    // materializing a reference from a raw pointer asserts validity: unsafe territory
                    if self.tc_needs_unsafe() {
                        let sp = a.at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("casting a raw pointer to a reference requires 'unsafe'"),
                        );
                    }
                }
                // Forming a MUTABLE raw pointer from an IMMUTABLE reference launders the shared-borrow
                // guarantee into mutation (interior mutability). Rejected everywhere except UnsafeCell::get,
                // the one sanctioned hole -- use `&mut`, or wrap the value in an `UnsafeCell`.
                if src != TYPE_NONE && dst != TYPE_NONE && self.type_at(src).kind == TypeKind::TYPE_REFERENCE && self.type_at(
                    src,
                ).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && self.type_at(dst).kind == TypeKind::TYPE_POINTER && self.type_at(
                    dst,
                ).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 && !self.in_unsafe_cell() {
                    let sp = a.at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "cannot cast an immutable reference to a '*mut' pointer; use '&mut', or 'UnsafeCell' for interior mutability",
                        ),
                    );
                }
                if src != TYPE_NONE && dst != TYPE_NONE && src != dst {
                    let sk = self.type_at(src).kind;
                    let dk = self.type_at(dst).kind;
                    let aggregate = sk == TypeKind::TYPE_STRUCT || sk == TypeKind::TYPE_ENUM || sk == TypeKind::TYPE_FUNCTION || dk == TypeKind::TYPE_STRUCT || dk == TypeKind::TYPE_ENUM || dk == TypeKind::TYPE_FUNCTION;
                    let enum_int = self.is_plain_enum(src) && self.is_int(dst) || self.is_plain_enum(dst) && self.is_int(
                        src,
                    );
                    let complex_lossy = sk == TypeKind::TYPE_BUILTIN && bt_is_complex(self.type_at(src).as_data.builtin) && dk == TypeKind::TYPE_BUILTIN && !bt_is_complex(
                        self.type_at(dst).as_data.builtin,
                    );
                    if aggregate && !enum_int || complex_lossy {
                        let mut s = Buf96 {};
                        let mut d = Buf96 {};
                        self.render_type(src, &mut s[0], 96);
                        self.render_type(dst, &mut d[0], 96);
                        let sp = a.at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("invalid cast from '{}' to '{}'", diag::cstr(&s[0]), diag::cstr(&d[0])),
                        );
                    }
                }
                result = dst;
            },
            NODE_SIZEOF | NODE_ALIGNOF => {
                let v = a.at_const(id).as_data.single.value;
                let d = a.resolution_def(v);
                let mut dk = NodeKind::NODE_NONE_KIND;
                if d.node != NODE_NONE && d.module == self.cur_module() {
                    dk = a.at_const(d.node).kind;
                }
                if dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_FOR || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_CONST {
                    let vt = a.type_of(d.node);
                    if vt == TYPE_NONE {
                        let vsp = a.at_const(v).span;
                        self.errors.emit(
                            vsp.start,
                            vsp.end - vsp.start,
                            format("cannot take the size of this value here"),
                        );
                    }
                    self.cur_ast().set_type(v, vt);
                } else {
                    self.resolve_type(v);
                }
                result = Ast::builtin(BuiltinType::BT_USIZE);
            },
            NODE_VA_EXPR => {
                let vo = a.at_const(id).as_data.va_op;
                if vo.op == VA_START && a.at_const(vo.ap).kind == NodeKind::NODE_IDENTIFIER {
                    let d = a.resolution_def(vo.ap);
                    if d.module == self.cur_module() && d.node != NODE_NONE {}
                }
                let apt = self.check_expr(vo.ap);
                if apt != TYPE_NONE {
                    let ay = *self.type_at(apt);
                    if !(ay.kind == TypeKind::TYPE_BUILTIN && ay.as_data.builtin == BuiltinType::BT_VALIST) {
                        let sp = a.at_const(vo.ap).span;
                        let mut ty = Buf96 {};
                        self.render_type(apt, &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("expected a 'va_list', found '{}'", diag::cstr(&ty[0])),
                        );
                    }
                }
                if vo.op == VA_ARG {
                    result = self.resolve_type(vo.extra);
                } else {
                    if vo.op == VA_START {
                        self.check_expr(vo.extra);
                    }
                    result = Ast::builtin(BuiltinType::BT_VOID);
                }
            },
            NODE_GENERIC_SPECIALIZATION => {
                let inner = a.at_const(id).as_data.specialization.expression;
                let types = a.at_const(id).as_data.specialization.types;
                // A const-generic value arg: cache its TYPE_CONST so both the aggregate instance below and
                // fn-turbofish binding (type_of) see it.
                for i in 0..types.len {
                    let tid = unsafe a.list(types)[i as usize];
                    if self.tc_arg_is_const(self.cur_module(), tid) {
                        self.cur_ast().set_type(tid, self.tc_const_arg(self.cur_module(), tid));
                    } else {
                        self.resolve_type(tid);
                    }
                }
                let d = a.resolution_def(inner);
                let mut is_agg = false;
                if d.node != NODE_NONE {
                    let dn = self.mod_ast(d.module).at_const(d.node);
                    is_agg = (dn.kind == NodeKind::NODE_ENUM || dn.kind == NodeKind::NODE_STRUCT) && dn.as_data.aggregate.generics.len > 0 && types.len > 0;
                }
                if is_agg {
                    if types.len > 8 {
                        let sp = a.at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("too many generic arguments ({}; the maximum is 8)", types.len),
                        );
                    }
                    let mut ta = Tys8 {};
                    let mut tn: u8 = 0;
                    let mut j: u32 = 0;
                    while j < types.len && tn < 8 {
                        let tj = unsafe a.list(types)[j as usize];
                        ta[tn as usize] = if self.tc_arg_is_const(self.cur_module(), tj) {
                            a.type_of(tj);
                        } else {
                            self.resolve_type(tj);
                        };
                        tn = tn + 1;
                        j = j + 1;
                    }
                    self.apply_default_args(d.module, d.node, &mut ta[0], &mut tn);
                    result = self.cur_ast().intern_instance(d.module, d.node, &ta[0], tn);
                } else {
                    // A turbofished generic fn used as a VALUE (`f::<T>` fn pointer): record the explicit
                    // type args on this node so codegen names and emits the monomorphized instance, exactly
                    // as a call callee's MonoUse does. Without this the fn-pointer value emits the bare
                    // generic name and the C link fails.
                    if d.node != NODE_NONE && types.len > 0 {
                        let dn = self.mod_ast(d.module).at_const(d.node);
                        if dn.kind == NodeKind::NODE_FUNCTION && dn.as_data.function.generics.len > 0 {
                            let mut ta = Tys8 {};
                            let mut tn: u8 = 0;
                            let mut j: u32 = 0;
                            while j < types.len && tn < 8 {
                                let tj = unsafe a.list(types)[j as usize];
                                ta[tn as usize] = self.resolve_type(tj);
                                tn = tn + 1;
                                j = j + 1;
                            }
                            self.cur_ast().set_type_args(id, &ta[0], tn);
                        }
                    }
                    result = self.check_expr(inner);
                }
            },
            NODE_MATCH => {
                result = self.check_match_expr(id, expected);
            },
            NODE_NEW => {
                let declared = self.resolve_type(a.at_const(id).as_data.new_expr.ty);
                let mut inner = declared;
                let init = a.at_const(id).as_data.new_expr.initializer;
                if init != NODE_NONE {
                    let it = self.check_expr(init);
                    if a.at_const(init).kind == NodeKind::NODE_STRUCT_INITIALIZER {
                        inner = it;
                    } else if !self.compatible(declared, init) {
                        self.err_mismatch(init, declared);
                    }
                }
                result = self.cur_ast().intern_type(
                    Ty {
                        kind: TypeKind::TYPE_POINTER,
                        qualifier: TypeQualifier::TYPE_QUAL_MUT as u8,
                        as_data: TyAs { elem: inner },
                    },
                );
            },
            NODE_ARRAY_LITERAL => {
                result = self.check_array_literal(id, expected);
            },
            NODE_STRUCT_INITIALIZER => {
                result = self.check_struct_init(id);
            },
            NODE_BLOCK => {
                result = self.check_block_value(id, expected);
            },
            NODE_WHILE => {
                self.loop_depth = self.loop_depth + 1;
                let le = self.tc_loop_push(tok::Span { start: 0, end: 0 }, id, true);
                self.check_loop_body(a.at_const(id).as_data.while_stmt.body);
                if le >= 0 {
                    result = unsafe self.loop_stack[le as usize].break_ty;
                    self.tc_loop_pop(le, a.at_const(id).span);
                }
                if result == TYPE_NONE {
                    result = self.cur_ast().intern_type(Ty { kind: TypeKind::TYPE_NEVER });
                }
                self.loop_depth = self.loop_depth - 1;
            },
            NODE_IF => {
                result = self.check_if_value(id, expected);
            },
            NODE_TUPLE => {
                result = self.check_tuple_value(id, expected);
            },
            NODE_RANGE => {
                let s = self.check_expr(a.at_const(id).as_data.pattern_range.start);
                let e = self.check_expr(a.at_const(id).as_data.pattern_range.end);
                let elem = self.range_type(id, s, e);
                if a.at_const(id).as_data.pattern_range.start == NODE_NONE || a.at_const(id).as_data.pattern_range.end == NODE_NONE {
                    let sp = a.at_const(id).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("a range value needs both a start and an end"));
                } else {
                    result = if_ty(elem != TYPE_NONE, self.prelude_range_type(elem), TYPE_NONE);
                }
            },
            _ => {},
        };
        self.cur_ast().set_type(id, result);
        return result;
    }

    fn check_literal(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let tt = a.at_const(id).as_data.literal.token_type;
        let lr = a.at_const(id).as_data.literal.raw;
        if tt == TokenType::IntegerLiteral {
            let mut sfx = lr.end;
            let sb = ast_numeric_suffix(self.source, lr.start, lr.end, &mut sfx);
            let mut result = Ast::builtin(BuiltinType::BT_I32);
            if sb != BuiltinType::BT_COUNT {
                result = Ast::builtin(sb);
            }
            let mut p = unsafe (self.source.ptr() + lr.start as usize);
            let mut len = (sfx - lr.start) as usize;
            let (base, skip) = lit_base_prefix(p, len);
            p = unsafe (p + skip);
            len = len - skip;
            let mut acc: u64 = 0;
            let mut overflow = false;
            let mut i: usize = 0;
            while i < len && !overflow {
                let ch = unsafe p[i];
                if ch == b'_' {
                    i = i + 1;
                    continue;
                }
                let mut d: u64 = 0;
                if ch <= b'9' {
                    d = ch - b'0';
                } else {
                    d = (ch | 0x20u8) - b'a' + 10u8;
                }
                if acc > (0xFFFFFFFFFFFFFFFFu64 - d) / base {
                    overflow = true;
                } else {
                    acc = acc * base + d;
                }
                i = i + 1;
            }
            let sp = a.at_const(id).span;
            if overflow {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("integer literal is too large to fit in a 64-bit integer"),
                );
            } else if sb != BuiltinType::BT_COUNT && bt_int_max(sb) != 0 && acc > bt_int_max(sb) {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("integer literal does not fit in its suffixed type"),
                );
            }
            return result;
        }
        if tt == TokenType::FloatLiteral {
            let sb = ast_numeric_suffix(self.source, lr.start, lr.end, null);
            if sb == BuiltinType::BT_F64 {
                return Ast::builtin(BuiltinType::BT_F64);
            }
            return Ast::builtin(BuiltinType::BT_F32);
        }
        if tt == TokenType::CharacterLiteral {
            if self.char_literal_cp(lr) > 0xFF {
                let sp = a.at_const(id).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("character literal does not fit in 'char' (one byte); use a string or an integer"),
                );
            }
            return Ast::builtin(BuiltinType::BT_CHAR);
        }
        if tt == TokenType::ByteCharacterLiteral {
            return Ast::builtin(BuiltinType::BT_U8);
        }
        if tt == TokenType::True || tt == TokenType::False {
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if tt == TokenType::StringLiteral || tt == TokenType::RawStringLiteral {
            return self.prelude_str_type();
        }
        if tt == TokenType::ByteStringLiteral {
            return self.prelude_slice_type(Ast::builtin(BuiltinType::BT_U8), false);
        }
        return TYPE_NONE;
    }

    // The index extent an array literal covers: positional elements advance a cursor, a designated
    // element jumps it to its (const) index + 1, C-style. -1 when a designator cannot be folded (its
    // own diagnostic already fired) -- callers skip length checking then. `sparse` reports whether any
    // designator appeared: a designated literal intentionally underfills (zero-fill is the feature),
    // so only excess is an error for it.
    fn tc_array_lit_extent(self: &mut Self, id: NodeId, sparse: *mut bool) i64 {
        let a = self.cur_ast();
        let elements = a.at_const(id).as_data.array_literal.elements;
        let mut cursor: i64 = 0;
        let mut extent: i64 = 0;
        for i in 0..elements.len {
            let eid = unsafe a.list(elements)[i as usize];
            let el = a.at_const(eid);
            let mut pos = cursor;
            if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                unsafe *sparse = true;
                let ceptr = self.ceval();
                if ceptr == null {
                    return -1;
                }
                let lv = ceptr.eval(self.cur_module(), el.as_data.field_initializer.name);
                if lv.kind != ce::CONST_INT || lv.as_data.i < 0 {
                    return -1;
                }
                pos = lv.as_data.i;
            }
            if pos + 1 > extent {
                extent = pos + 1;
            }
            cursor = pos + 1;
        }
        return extent;
    }

    // The element type the surrounding context asked for, or TYPE_NONE. Only arrays: a slice is a prelude
    // instance by the time it gets here, and an array literal coerces to one after this.
    const fn wanted_elem(self: &mut Self, expected: TypeId) TypeId {
        if expected == TYPE_NONE {
            return TYPE_NONE;
        }
        let ex = *self.type_at(expected);
        if ex.kind != TypeKind::TYPE_ARRAY {
            return TYPE_NONE;
        }
        return ex.as_data.arr.elem;
    }

    // Would every element convert cleanly to `we`? Probing, so nothing is recorded and nothing is reported
    // for the elements that would not -- the caller keeps its own inferred type and diagnoses from there.
    fn elements_fit(self: &mut Self, elements: NodeList, we: TypeId) bool {
        for i in 0..elements.len {
            let eid = unsafe self.cur_ast().list(elements)[i as usize];
            let el = self.cur_ast().at_const(eid);
            let vid = if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                el.as_data.field_initializer.value;
            } else {
                eid;
            };
            if !self.compatible_in(we, vid, true) {
                return false;
            }
        }
        return true;
    }

    fn check_array_literal(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let elements = a.at_const(id).as_data.array_literal.elements;
        if a.at_const(id).as_data.array_literal.repeat {
            return self.check_array_repeat(elements, expected);
        }
        if elements.len == 0 {
            // `[]` carries no element type of its own: take it from the context, which is the only
            // place a zero-length array can come from.
            if expected != TYPE_NONE && self.type_at(expected).kind == TypeKind::TYPE_ARRAY {
                return expected;
            }
            let sp = a.at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("cannot infer the element type of an empty array literal"),
            );
            return TYPE_NONE;
        }
        let mut elem = TYPE_NONE;
        for i in 0..elements.len {
            let eid = unsafe a.list(elements)[i as usize];
            let el = a.at_const(eid);
            let mut et = TYPE_NONE;
            if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                let it = self.check_expr(el.as_data.field_initializer.name);
                if it != TYPE_NONE {
                    let iy = *self.type_at(it);
                    if !(iy.kind == TypeKind::TYPE_BUILTIN && (bt_is_int(iy.as_data.builtin) || iy.as_data.builtin == BuiltinType::BT_CHAR)) {
                        let sp = a.at_const(el.as_data.field_initializer.name).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("array designator index must be an integer"),
                        );
                    } else {
                        let ceptr = self.ceval();
                        if ceptr != null && ceptr.eval(self.cur_module(), el.as_data.field_initializer.name).kind == ce::CONST_NONE {
                            let sp = a.at_const(el.as_data.field_initializer.name).span;
                            if ceptr.ce_trap_get().len() != 0 {
                                self.errors.emit(
                                    sp.start,
                                    sp.end - sp.start,
                                    format(
                                        "array designator index must be a constant expression: {}",
                                        ceptr.ce_trap_detail(),
                                    ),
                                );
                            } else {
                                self.errors.emit(
                                    sp.start,
                                    sp.end - sp.start,
                                    format("array designator index must be a constant expression"),
                                );
                            }
                        }
                    }
                }
                et = self.check_expr(el.as_data.field_initializer.value);
            } else {
                et = self.check_expr(eid);
            }
            if i == 0 {
                elem = et;
            } else if et != elem && et != TYPE_NONE && elem != TYPE_NONE {
                let e0 = self.type_at(elem).kind;
                let ei = self.type_at(et).kind;
                if !(e0 == TypeKind::TYPE_FUNCTION && ei == TypeKind::TYPE_FUNCTION && self.fn_compatible(elem, et)) {
                    self.err_mismatch(eid, elem);
                    elem = TYPE_NONE;
                }
            }
        }
        if elem != TYPE_NONE {
            // The context may want a WIDER element than the elements gave themselves. An integer literal is
            // i32 on its own, so `let a: [i64; 4] = [3, 0, 0, 7]` was rejected over a difference the same
            // lossless widening already smooths away for a scalar `let x: i64 = 3`. Adopt the wanted element
            // type when every element converts to it cleanly, and otherwise leave the inferred one so the
            // mismatch is reported against what was actually written.
            let we = self.wanted_elem(expected);
            if we != TYPE_NONE && we != elem && self.elements_fit(elements, we) {
                elem = we;
            }
            return self.cur_ast().intern_type(
                Ty { kind: TypeKind::TYPE_ARRAY, as_data: TyAs { arr: TyArr { elem: elem, len: 0 } } },
            );
        }
        return TYPE_NONE;
    }

    // `[v; N]`: one value and a count. The count must be a constant -- the length is part of the type -- so
    // it is folded here, with the same const-eval every other array length goes through.
    fn check_array_repeat(self: &mut Self, elements: NodeList, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let vid = unsafe a.list(elements)[0];
        let nid = unsafe a.list(elements)[1];
        let mut elem = self.check_expr(vid);
        let we = self.wanted_elem(expected); // same widening as the element-list form above
        if we != TYPE_NONE && we != elem && elem != TYPE_NONE && self.compatible_in(we, vid, true) {
            elem = we;
        }
        let cnt = self.check_expr(nid);
        let sp = a.at_const(nid).span;
        if cnt != TYPE_NONE {
            let cy = *self.type_at(cnt);
            if !(cy.kind == TypeKind::TYPE_BUILTIN && bt_is_int(cy.as_data.builtin)) {
                self.errors.emit(sp.start, sp.end - sp.start, format("an array repeat count must be an integer"));
                return TYPE_NONE;
            }
        }
        let ceptr = self.ceval();
        let mut n: i64 = -1;
        if ceptr != null {
            let cv = ceptr.eval(self.cur_module(), nid);
            if cv.kind == ce::CONST_INT {
                n = cv.as_data.i;
            }
        }
        if n < 0 {
            self.errors.emit(sp.start, sp.end - sp.start, format("an array repeat count must be a constant expression"));
            return TYPE_NONE;
        }
        if elem == TYPE_NONE {
            return TYPE_NONE;
        }
        // Every slot holds its own copy, and a `Free` value cannot be copied into more than one owner.
        if n > 1 && self.tc_type_is_free(elem) {
            let vsp = a.at_const(vid).span;
            self.errors.emit(
                vsp.start,
                vsp.end - vsp.start,
                format("an array repeat needs a value that can be copied; this one owns resources"),
            );
            return TYPE_NONE;
        }
        return self.cur_ast().intern_type(
            Ty { kind: TypeKind::TYPE_ARRAY, as_data: TyAs { arr: TyArr { elem: elem, len: n as u32 } } },
        );
    }

    // Adapt a branch/arm/block-tail LITERAL to the expected type. Literal adaptation is the one
    // implicit conversion that is position-sensitive -- it must run ON the literal node -- so the
    // expected type is pushed into value-position branches and applied here; every other conversion
    // keeps working on the merged value at the outer coercion site, unchanged.
    fn tc_tail_adapt(self: &mut Self, expected: TypeId, lv: NodeId) {
        if expected == TYPE_NONE || lv == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let mut vid = lv;
        let v0 = a.at_const(lv);
        if v0.kind == NodeKind::NODE_UNARY && v0.as_data.unary.op == TokenType::Minus {
            vid = v0.as_data.unary.operand;
        }
        if a.at_const(vid).kind != NodeKind::NODE_LITERAL {
            // a non-literal tail needs no adaptation, but a cast tail that now matches the context
            // type exactly is the redundant-cast lint's business (arms/tails see expected now)
            if self.lint && lv as usize < unsafe a.types.len() && a.type_of(lv) == expected {
                self.tc_lint_redundant_coalesce(expected, lv);
            }
            return;
        }
        let _ = self.compatible(expected, lv); // the literal path adapts + range-checks in place
    }

    fn check_block_value(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let stmts = a.at_const(id).as_data.block.statements;
        for i in 0..stmts.len {
            let sid = unsafe a.list(stmts)[i as usize];
            if expected != TYPE_NONE && i == stmts.len - 1 && a.at_const(sid).kind == NodeKind::NODE_EXPRESSION_STATEMENT {
                self.expected = expected; // the tail is this block's value: let it see the context type
            }
            self.check_stmt(sid);
        }
        while self.ndefers != 0 && unsafe self.defer_depth[(self.ndefers - 1) as usize] == self.scope_depth {
            self.ndefers = self.ndefers - 1;
            let dv = unsafe self.defer_stack[self.ndefers as usize];
            self.check_expr(dv);
        }
        if stmts.len > 0 {
            let lastid = unsafe a.list(stmts)[(stmts.len - 1) as usize];
            let last = a.at_const(lastid);
            let lv = if_node(last.kind == NodeKind::NODE_EXPRESSION_STATEMENT, last.as_data.single.value, NODE_NONE);
            if lv != NODE_NONE && a.at_const(lv).kind != NodeKind::NODE_ASSIGNMENT {
                self.tc_tail_adapt(expected, lv);
                return a.type_of(lv);
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        return Ast::builtin(BuiltinType::BT_VOID);
    }

    fn check_if_value(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let ifd = a.at_const(id).as_data.if_stmt;
        let c = self.check_expr(ifd.condition);
        if c != TYPE_NONE && !self.is_bool(c) {
            let sp = a.at_const(ifd.condition).span;
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("if condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
        }
        self.expected = expected;
        let then_ty = self.check_expr(ifd.then_branch);
        if ifd.else_branch == NODE_NONE {
            let sp = a.at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("an 'if' used as a value must have an 'else' branch"));
            return TYPE_NONE;
        }
        self.expected = expected;
        let else_ty = self.check_expr(ifd.else_branch);
        let then_never = then_ty != TYPE_NONE && self.type_at(then_ty).kind == TypeKind::TYPE_NEVER;
        let else_never = else_ty != TYPE_NONE && self.type_at(else_ty).kind == TypeKind::TYPE_NEVER;
        if then_never || else_never {
            return if_ty(then_never, else_ty, then_ty);
        }
        if expected != TYPE_NONE {
            // a context type is known: each branch coerces to IT (widening, adaptation, the works)
            // instead of having to equal the other branch exactly
            if then_ty != TYPE_NONE && !self.compatible(expected, ifd.then_branch) {
                self.err_mismatch(ifd.then_branch, expected);
            }
            if else_ty != TYPE_NONE && !self.compatible(expected, ifd.else_branch) {
                self.err_mismatch(ifd.else_branch, expected);
            }
            return expected;
        }
        if then_ty != else_ty && then_ty != TYPE_NONE && else_ty != TYPE_NONE {
            self.err_mismatch(ifd.else_branch, then_ty);
            return TYPE_NONE;
        }
        return then_ty;
    }

    fn check_tuple_value(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let elems = a.at_const(id).as_data.array_literal.elements;
        if elems.len > 4 {
            let sp = a.at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("tuple arity is limited to 4 elements"));
            return TYPE_NONE;
        }
        let mut wargs = Tys8 {};
        let mut wn: i32 = -1;
        if expected != TYPE_NONE {
            wn = self.tuple_args_of(self.strip(expected), &mut wargs[0], 4);
        }
        let mut targs = Tys8 {};
        for i in 0..elems.len {
            let eid = unsafe a.list(elems)[i as usize];
            let et = self.check_expr(eid);
            targs[i as usize] = et;
            if i as i32 < wn && et != wargs[i as usize] && self.compatible(wargs[i as usize], eid) {
                targs[i as usize] = wargs[i as usize];
                self.cur_ast().set_type(eid, wargs[i as usize]);
            }
        }
        return self.prelude_tuple_type(&targs[0], elems.len);
    }

    fn check_loop_body(self: &mut Self, body: NodeId) {
        let nm0 = self.nmoved;
        let nb0 = self.nborrows;
        self.check_stmt(body);
        if (self.nmoved > nm0 || self.nborrows > nb0) && !self.in_loop_recheck {
            self.in_loop_recheck = true;
            self.check_stmt(body);
            self.in_loop_recheck = false;
        }
    }

    fn check_tuple_let(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let value = a.at_const(id).as_data.let_stmt.value;
        let nm = a.at_const(id).as_data.let_stmt.name;
        let names = a.at_const(nm).as_data.pattern.children;
        self.mret_call = NODE_NONE;
        self.check_expr(value);
        let stashed = value != NODE_NONE && self.mret_call == value;
        let mut targs = Tys8 {};
        let mut tn: i32 = -1;
        if !stashed && value != NODE_NONE {
            tn = self.tuple_args_of(self.strip(a.type_of(value)), &mut targs[0], 4);
            if tn >= 0 {}
        }
        let mut returns = NodeList { start: 0, len: 0 };
        let mut ok = false;
        if value != NODE_NONE && a.at_const(value).kind == NodeKind::NODE_CALL {
            let calleeId = a.at_const(value).as_data.call.callee;
            let callee = a.type_of(calleeId);
            if callee != TYPE_NONE {
                let ct = *self.type_at(callee);
                if ct.kind == TypeKind::TYPE_FUNCTION {
                    let fnn = self.mod_ast(ct.module).at_const(ct.as_data.decl);
                    returns = if_nl(
                        fnn.kind == NodeKind::NODE_FUNCTION,
                        fnn.as_data.function.returns,
                        fnn.as_data.function_type.returns,
                    );
                    ok = true;
                }
            } else {
                let cn = a.at_const(calleeId);
                if cn.kind == NodeKind::NODE_MEMBER {
                    let md = a.resolution_def(cn.as_data.member.member);
                    if md.node != NODE_NONE && md.module == self.cur_module() && self.mod_ast(md.module).at_const(
                        md.node,
                    ).kind == NodeKind::NODE_FUNCTION {
                        returns = self.mod_ast(md.module).at_const(md.node).as_data.function.returns;
                        ok = true;
                    }
                }
            }
        }
        if !ok && !stashed && tn < 0 {
            let sp = a.at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("a tuple binding requires a multi-value function call or a tuple value"),
            );
            return;
        }
        let nret = if_u32(stashed, self.mret_total, if_u32(tn >= 0, tn as u32, returns.len));
        if names.len != nret {
            let sp = a.at_const(id).span;
            let mut s1 = "s".ptr() as *const char;
            if names.len == 1 {
                s1 = "".ptr() as *const char;
            }
            let mut s2 = "s".ptr() as *const char;
            if nret == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "expected {} binding{}, the call returns {} value{}",
                    names.len,
                    diag::cstr(s1),
                    nret,
                    diag::cstr(s2),
                ),
            );
        }
        for i in 0..names.len {
            let mut et = TYPE_NONE;
            if stashed && i < self.mret_n as u32 {
                et = unsafe self.mret_types[i as usize];
            } else if tn >= 0 {
                et = if_ty(i < tn as u32, targs[i as usize], TYPE_NONE);
            } else if i < returns.len {
                let r0 = unsafe self.cur_ast().list(returns)[i as usize];
                let rn = self.cur_ast().at_const(r0);
                et = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
            }
            self.cur_ast().set_type(unsafe self.cur_ast().list(names)[i as usize], et);
        }
    }

    fn check_return(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let values = a.at_const(id).as_data.return_stmt.values;
        let rets = self.current_returns;
        let returns_void = self.return_list_is_explicit_void(rets);
        if values.len == 1 && !returns_void && rets.len == 1 {
            let r0 = unsafe a.list(rets)[0];
            let rn = a.at_const(r0);
            self.expected = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
        }
        for i in 0..values.len {
            let vid = unsafe a.list(values)[i as usize];
            self.check_expr(vid);
        }
        for i in 0..values.len {
            let vid = unsafe a.list(values)[i as usize];
            let esc = 0;
            if esc != 0 {
                let sp = a.at_const(vid).span;
                let mut w = "local variable".ptr() as *const char;
                if esc == 2 {
                    w = "function parameter".ptr() as *const char;
                }
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("returning a pointer/reference to a {}, which does not outlive the call", diag::cstr(w)),
                );
            } else {}
        }
        let expected = if_u32(returns_void, 0, rets.len);
        if values.len != expected {
            let sp = a.at_const(id).span;
            let mut s2 = "s".ptr() as *const char;
            if expected == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("expected {} return value{}, found {}", expected, diag::cstr(s2), values.len),
            );
            return;
        }
        if returns_void {
            return;
        }
        for i in 0..values.len {
            let vid = unsafe a.list(values)[i as usize];
            let r0 = unsafe a.list(rets)[i as usize];
            let rn = a.at_const(r0);
            let rt = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
            if !self.compatible(rt, vid) {
                self.err_mismatch(vid, rt);
            }
        }
    }

    // Does the expression contain a call? A call-bearing const initializer requires execution to
    // have a value, so it MUST fold at compile time; call-free initializers stay best-effort
    // (they are already valid C constant expressions).
    fn expr_has_call(self: &Self, id: NodeId, depth: u32) bool {
        if id == NODE_NONE || depth > 64 {
            return depth > 64;
        }
        let a = self.cur_ast();
        let n = a.at_const(id);
        switch n.kind {
            NODE_CALL => {
                return true;
            },
            NODE_UNARY => {
                return self.expr_has_call(n.as_data.unary.operand, depth + 1);
            },
            NODE_BINARY | NODE_ASSIGNMENT => {
                return self.expr_has_call(n.as_data.binary.left, depth + 1) || self.expr_has_call(
                    n.as_data.binary.right,
                    depth + 1,
                );
            },
            NODE_CAST => {
                return self.expr_has_call(n.as_data.cast.expression, depth + 1);
            },
            NODE_MEMBER => {
                if n.as_data.member.path {
                    return false;
                }
                return self.expr_has_call(n.as_data.member.object, depth + 1);
            },
            NODE_INDEX => {
                return self.expr_has_call(n.as_data.index.object, depth + 1) || self.expr_has_call(
                    n.as_data.index.index,
                    depth + 1,
                );
            },
            NODE_STRUCT_INITIALIZER => {
                let fields = n.as_data.struct_initializer.fields;
                for i in 0..fields.len {
                    let fid = unsafe a.list(fields)[i as usize];
                    if a.at_const(fid).kind == NodeKind::NODE_FIELD_INITIALIZER && self.expr_has_call(
                        a.at_const(fid).as_data.field_initializer.value,
                        depth + 1,
                    ) {
                        return true;
                    }
                }
                return false;
            },
            NODE_ARRAY_LITERAL | NODE_TUPLE => {
                let elements = n.as_data.array_literal.elements;
                for i in 0..elements.len {
                    if self.expr_has_call(unsafe a.list(elements)[i as usize], depth + 1) {
                        return true;
                    }
                }
                return false;
            },
            NODE_IF | NODE_MATCH | NODE_BLOCK => {
                return true; // requires execution just like a call
            },
            _ => {},
        };
        return false;
    }

    // Mandatory evaluation of a call-bearing const initializer: failure with a trap is an error,
    // undecidable-in-module-order defers to flush_consts (mirrors check_static_assert).
    fn tc_mandatory_const(self: &mut Self, id: NodeId, value: NodeId) {
        if !self.expr_has_call(value, 0) {
            return;
        }
        let ceptr = self.ceval();
        if ceptr == null {
            return;
        }
        let m = self.cur_module();
        let v = ceptr.eval(m, value);
        if v.kind != ce::CONST_NONE {
            return;
        }
        if ceptr.ce_trap_get().len() == 0 && ceptr.eval_static(m, value).ok {
            return;
        }
        if ceptr.ce_trap_get().len() != 0 {
            let cd = self.cur_ast().at_const(id).as_data.const_def;
            let sp = self.name_span(cd.name);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "constant '{}' cannot be evaluated at compile time: {}",
                    diag::span_str(self.source, sp.start, sp.end),
                    ceptr.ce_trap_detail(),
                ),
            );
        } else {
            ceptr.defer_const(m, id);
        }
    }

    /// `asm(..)` hands a template straight to the C compiler, so the checker owns the SHAPE, not the
    /// contents: the template and every constraint must be string literals, an output must be assignable
    /// (the assembly writes it), and the whole statement needs `unsafe` -- nothing here can know what the
    /// instructions do.
    fn tc_check_asm(self: &mut Self, id: NodeId) {
        let d = self.cur_ast().at_const(id).as_data.asm_stmt;
        let sp = self.cur_ast().at_const(id).span;
        if self.tc_needs_unsafe() {
            self.err_unsafe(sp, "inline assembly");
        }
        self.tc_asm_literal(d.template, "an asm template");
        let mut i: u32 = 0;
        while i < d.outputs.len {
            let c = unsafe self.cur_ast().list(d.outputs)[i as usize];
            self.tc_asm_literal(c, "an asm constraint");
            if i + 1 < d.outputs.len {
                let e = unsafe self.cur_ast().list(d.outputs)[(i + 1) as usize];
                self.check_expr(e);
                if !self.is_assignable(e) {
                    let esp = self.cur_ast().at_const(e).span;
                    self.errors.emit(
                        esp.start,
                        esp.end - esp.start,
                        format("an asm output must be an assignable place (the assembly writes it)"),
                    );
                }
            }
            i = i + 2;
        }
        i = 0;
        while i < d.inputs.len {
            let c = unsafe self.cur_ast().list(d.inputs)[i as usize];
            self.tc_asm_literal(c, "an asm constraint");
            if i + 1 < d.inputs.len {
                self.check_expr(unsafe self.cur_ast().list(d.inputs)[(i + 1) as usize]);
            }
            i = i + 2;
        }
        for k in 0..d.clobbers.len {
            self.tc_asm_literal(unsafe self.cur_ast().list(d.clobbers)[k as usize], "an asm clobber");
        }
    }

    fn tc_asm_literal(self: &mut Self, e: NodeId, what: str) {
        if e == NODE_NONE {
            return;
        }
        self.check_expr(e);
        let n = self.cur_ast().at_const(e);
        let lit = n.kind == NodeKind::NODE_LITERAL && (n.as_data.literal.token_type == TokenType::StringLiteral || n.as_data.literal.token_type == TokenType::RawStringLiteral);
        if !lit {
            let sp = n.span;
            self.errors.emit(sp.start, sp.end - sp.start, format("{} must be a string literal", what));
        }
    }

    fn check_static_assert(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let left = a.at_const(id).as_data.binary.left;
        let c = self.check_expr(left);
        let sp = a.at_const(left).span;
        if c != TYPE_NONE && !self.is_bool(c) {
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("static_assert condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
            return;
        }
        let ceptr = self.ceval();
        if ceptr == null {
            return;
        }
        let v = ceptr.eval(self.cur_module(), left);
        if v.kind == ce::CONST_BOOL && v.as_data.i == 0 {
            self.errors.emit(sp.start, sp.end - sp.start, format("static assertion failed"));
        } else if v.kind == ce::CONST_NONE {
            let trap = ceptr.ce_trap_get();
            if trap.len() != 0 {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("static assertion cannot be evaluated: {}", ceptr.ce_trap_detail()),
                );
            } else {
                ceptr.defer_assert(self.cur_module(), left);
            }
        }
    }

    // The three statement kinds carrying FlowState snapshots (2,832 B each, up to two) live in
    // their own frames: inlined into check_stmt they put a ~5.7 KB frame + unconditional stack
    // probe on EVERY recursive statement check. @c.noinline keeps LTO from folding them back.
    @c.noinline
    fn tc_check_defer(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let dv = a.at_const(id).as_data.single.value;
        self.check_expr(dv);
        if self.ndefers < 256 {
            let k = self.ndefers;
            unsafe self.defer_stack[k as usize] = dv;
            unsafe self.defer_depth[k as usize] = self.scope_depth;
            self.ndefers = k + 1;
        } else {
            let sp = a.at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("too many pending 'defer' statements in one function (analysis limit)"),
            );
        }
    }
    @c.noinline
    fn tc_check_while(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        self.loop_depth = self.loop_depth + 1;
        let le = self.tc_loop_push(a.at_const(id).as_data.while_stmt.label, id, false);
        let c = self.check_expr(a.at_const(id).as_data.while_stmt.condition);
        if c != TYPE_NONE && !self.is_bool(c) {
            let sp = a.at_const(a.at_const(id).as_data.while_stmt.condition).span;
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("while condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
        }
        let body = a.at_const(id).as_data.while_stmt.body;
        if a.at_const(id).as_data.while_stmt.is_do || a.at_const(id).as_data.while_stmt.condition == NODE_NONE {
            self.check_loop_body(body);
        } else {
            self.check_loop_body(body);
        }
        if le >= 0 {
            self.tc_loop_pop(le, self.cur_ast().at_const(id).span);
        }
        self.loop_depth = self.loop_depth - 1;
    }
    @c.noinline
    fn tc_check_for(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        self.loop_depth = self.loop_depth + 1;
        let le = self.tc_loop_push(a.at_const(id).as_data.for_stmt.label, id, false);
        let iter = a.at_const(id).as_data.for_stmt.iterable;
        let mut elem = TYPE_NONE;
        if a.at_const(iter).kind == NodeKind::NODE_RANGE {
            let s = self.check_expr(a.at_const(iter).as_data.pattern_range.start);
            let e = self.check_expr(a.at_const(iter).as_data.pattern_range.end);
            elem = self.range_type(iter, s, e);
            self.cur_ast().set_type(iter, elem);
        } else {
            let it = self.check_expr(iter);
            let ity = *self.type_at(it);
            let mut selem: TypeId = TYPE_NONE;
            if ity.kind == TypeKind::TYPE_ARRAY {
                elem = ity.as_data.elem;
            } else if self.slice_kind(it, &mut selem) != 0 {
                elem = selem;
            } else {
                elem = self.range_instance_elem(it);
            }
            if elem == TYPE_NONE && it != TYPE_NONE {
                elem = self.iter_elem_type(it);
            }
            if elem == TYPE_NONE && it != TYPE_NONE {
                let sp = self.cur_ast().at_const(iter).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("cannot iterate over this value (need an array, slice, range, or an Iterator)"),
                );
            }
        }
        self.cur_ast().set_type(id, elem);
        if id != NODE_NONE {
            self.binding_depth.insert(id, self.scope_depth + 1);
        }
        self.check_loop_body(self.cur_ast().at_const(id).as_data.for_stmt.body);
        if le >= 0 {
            self.tc_loop_pop(le, self.cur_ast().at_const(id).span);
        }
        self.loop_depth = self.loop_depth - 1;
    }
    fn check_stmt(self: &mut Self, id: NodeId) {
        if id == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let nk = a.at_const(id).kind;
        switch nk {
            NODE_STATIC_ASSERT => {
                self.check_static_assert(id);
            },
            NODE_BLOCK => {
                let stmts = a.at_const(id).as_data.block.statements;
                // Stable across the recursion: children storage is append-only and nothing commits
                // AST nodes during checking (interning goes to the separate type/instance pools).
                let sp = a.list(stmts);
                let mut diverged = false;
                for i in 0..stmts.len {
                    let sid = unsafe sp[i as usize];
                    let sk = a.at_const(sid).kind;
                    // Lint: the first statement after a diverging one (return/break/continue, or an
                    // expression of type `!`) never executes. static_asserts are compile-time: exempt.
                    if diverged && sk != NodeKind::NODE_STATIC_ASSERT {
                        let ssp = a.at_const(sid).span;
                        self.errors.warn(ssp.start, ssp.end - ssp.start, format("unreachable statement"));
                        diverged = false; // once per block
                    }
                    self.check_stmt(sid);
                    if self.lint && !diverged {
                        if sk == NodeKind::NODE_RETURN || sk == NodeKind::NODE_BREAK || sk == NodeKind::NODE_CONTINUE {
                            diverged = true;
                        } else if sk == NodeKind::NODE_EXPRESSION_STATEMENT {
                            let v = a.at_const(sid).as_data.single.value;
                            let vt = a.type_of(v);
                            diverged = vt != TYPE_NONE && self.type_at(vt).kind == TypeKind::TYPE_NEVER;
                        }
                    }
                }
                while self.ndefers != 0 && unsafe self.defer_depth[(self.ndefers - 1) as usize] == self.scope_depth {
                    self.ndefers = self.ndefers - 1;
                    let dv = unsafe self.defer_stack[self.ndefers as usize];
                    self.check_expr(dv);
                }
            },
            NODE_LET => {
                let nm = a.at_const(id).as_data.let_stmt.name;
                if a.at_const(nm).kind == NodeKind::NODE_PATTERN_TUPLE {
                    self.check_tuple_let(id);
                    return;
                }
                let tyn = a.at_const(id).as_data.let_stmt.ty;
                let value = a.at_const(id).as_data.let_stmt.value;
                let annotated = tyn != NODE_NONE;
                let valued = value != NODE_NONE;
                let declared = if_ty(annotated, self.resolve_type(tyn), TYPE_NONE);
                if valued {
                    self.expected = declared;
                    self.check_expr(value);
                }
                let mut binding = TYPE_NONE;
                if annotated {
                    if valued && !self.compatible(declared, value) {
                        self.err_mismatch(value, declared);
                    }
                    binding = declared;
                } else if valued {
                    binding = self.cur_ast().type_of(value);
                    // A generic function has no type of its own -- only a fn POINTER to one of its
                    // instances does, and nothing here says which signature that pointer has (the type
                    // arguments fix the parameters, not the reverse). Reject it: codegen would
                    // otherwise emit the unsubstituted signature, which is not valid C.
                    if binding != TYPE_NONE && self.tc_generic_fn_named(value).node != NODE_NONE {
                        let sp = a.at_const(value).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format(
                                "cannot infer the type of a generic function used as a value; annotate the binding with its signature, e.g. 'let f: fn(i32) i32 = ..'",
                            ),
                        );
                        binding = TYPE_NONE;
                    }
                    // An array literal types with len 0 (unknown -- `compatible`'s extent sugar needs
                    // that), so an INFERRED binding would lose its length and every index on it would
                    // look unprovable to the raw-array unsafe gate: pin the literal's real extent here.
                    if binding != TYPE_NONE && self.type_at(binding).kind == TypeKind::TYPE_ARRAY && self.type_at(
                        binding,
                    ).as_data.arr.len == 0 && a.at_const(value).kind == NodeKind::NODE_ARRAY_LITERAL {
                        let mut sparse = false;
                        let ext = self.tc_array_lit_extent(value, &mut sparse);
                        if ext > 0 {
                            let elem = self.type_at(binding).as_data.arr.elem;
                            binding = self.cur_ast().intern_type(
                                Ty {
                                    kind: TypeKind::TYPE_ARRAY,
                                    as_data: TyAs { arr: TyArr { elem: elem, len: ext as u32 } },
                                },
                            );
                            self.cur_ast().set_type(value, binding);
                        }
                    }
                } else {
                    let sp = self.name_span(nm);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot infer type of '{}'", diag::span_str(self.source, sp.start, sp.end)),
                    );
                }
                self.cur_ast().set_type(id, binding);
                // A binding whose type has lifetime slots gets a region vector; the solver will
                // constrain these against the initializer's regions.
                if annotated && !valued {
                    // tc_type_is_free peels to the referent, so gate on the kind first: a `&String`
                    // binding borrows an owner, it does not become one.
                    let bk = self.type_at(binding).kind;
                    if bk != TypeKind::TYPE_POINTER && bk != TypeKind::TYPE_REFERENCE && self.tc_type_is_free(binding) {
                        let sp = self.name_span(nm);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("a Free-typed binding must be initialized when declared (it is freed at scope exit)"),
                        );
                    } else {}
                }
            },
            NODE_CONST => {
                let declared = self.resolve_type(a.at_const(id).as_data.const_def.ty);
                let value = a.at_const(id).as_data.const_def.value;
                if value != NODE_NONE {
                    self.check_expr(value);
                    if !self.compatible(declared, value) {
                        self.err_mismatch(value, declared);
                    }
                    self.tc_mandatory_const(id, value);
                }
                self.cur_ast().set_type(id, declared);
            },
            NODE_RETURN => {
                self.check_return(id);
            },
            NODE_DEFER => {
                self.tc_check_defer(id);
            },
            NODE_ASM => {
                self.tc_check_asm(id);
            },
            NODE_IF => {
                self.check_if_stmt(id);
            },
            NODE_WHILE => {
                self.tc_check_while(id);
            },
            NODE_FOR => {
                self.tc_check_for(id);
            },
            NODE_EXPRESSION_STATEMENT => {
                let _es = self.check_expr(a.at_const(id).as_data.single.value);
            },
            NODE_BREAK | NODE_CONTINUE => {
                let lb = a.at_const(id).as_data.flow.label;
                let le = self.tc_find_loop(lb);
                if le < 0 {
                    let sp = a.at_const(id).span;
                    if lb.end > lb.start {
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("no enclosing loop is labeled {}", diag::span_str(self.source, lb.start, lb.end)),
                        );
                    } else {
                        let mut w = "continue".ptr() as *const char;
                        if nk == NodeKind::NODE_BREAK {
                            w = "break".ptr() as *const char;
                        }
                        self.errors.emit(sp.start, sp.end - sp.start, format("'{}' outside of a loop", diag::cstr(w)));
                    }
                    let fv = a.at_const(id).as_data.flow.value;
                    if fv != NODE_NONE {
                        self.check_expr(fv);
                    }
                    return;
                }
                unsafe self.cur_ast().set_resolution(id, self.loop_stack[le as usize].node);
                self.tc_note_resolution(id, unsafe self.loop_stack[le as usize].node);
                if nk != NodeKind::NODE_BREAK {
                    return;
                }
                let fv = self.cur_ast().at_const(id).as_data.flow.value;
                if fv == NODE_NONE {
                    unsafe self.loop_stack[le as usize].saw_bare = true;
                    return;
                }
                self.expected = unsafe self.loop_stack[le as usize].break_ty;
                let vt = self.check_expr(fv);
                let sp = self.cur_ast().at_const(id).span;
                if !unsafe self.loop_stack[le as usize].value_loop {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("'break' can only carry a value inside a 'loop' expression"),
                    );
                } else if unsafe self.loop_stack[le as usize].break_ty == TYPE_NONE {
                    unsafe self.loop_stack[le as usize].break_ty = vt;
                } else if !self.compatible(unsafe self.loop_stack[le as usize].break_ty, fv) {
                    self.err_mismatch(fv, unsafe self.loop_stack[le as usize].break_ty);
                }
                unsafe self.loop_stack[le as usize].saw_value = true;
            },
            _ => {},
        };
    }

    fn check_pattern(self: &mut Self, id: NodeId, expected: TypeId, bind_ref: i32) {
        if id == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let nk = a.at_const(id).kind;
        if nk == NodeKind::NODE_IDENTIFIER {
            self.cur_ast().set_type(id, if_ty(bind_ref != 0, self.tc_ref(expected, bind_ref == 2), expected));
        } else if nk == NodeKind::NODE_PATTERN_NAME {
            let nameId = a.at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = self.aggregate_of(self.strip(expected), &mut bmod, &mut decl, &mut gp, &mut ga, &mut gn);
            if agok && self.mod_ast(bmod).at_const(decl).kind == NodeKind::NODE_ENUM {
                let v = self.find_member(bmod, decl, self.name_span(nameId));
                if v != NODE_NONE && self.mod_ast(bmod).at_const(v).kind == NodeKind::NODE_VARIANT && self.mod_ast(bmod).at_const(
                    v,
                ).as_data.variant.payload.len == 0 {
                    self.cur_ast().set_resolution_def(nameId, DefId { module: bmod, node: v });
                    return;
                }
            }
            self.cur_ast().set_type(id, if_ty(bind_ref != 0, self.tc_ref(expected, bind_ref == 2), expected));
            let subs = self.cur_ast().at_const(id).as_data.pattern.children;
            for i in 0..subs.len {
                self.check_pattern(unsafe self.cur_ast().list(subs)[i as usize], expected, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_STRUCT {
            let base = self.strip(expected);
            let nameId = a.at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agg = self.aggregate_of(base, &mut bmod, &mut decl, &mut gp, &mut ga, &mut gn);
            let mut variant = NODE_NONE;
            if agg && nameId != NODE_NONE && self.mod_ast(bmod).at_const(decl).kind == NodeKind::NODE_ENUM {
                let v = self.find_member(bmod, decl, self.name_span(nameId));
                if v != NODE_NONE && self.mod_ast(bmod).at_const(v).kind == NodeKind::NODE_VARIANT {
                    variant = v;
                    self.cur_ast().set_resolution_def(nameId, DefId { module: bmod, node: variant });
                }
            }
            let children = self.cur_ast().at_const(id).as_data.pattern.children;
            if variant != NODE_NONE {
                let va = self.mod_ast(bmod);
                let vpl = va.at_const(variant).as_data.variant.payload;
                for i in 0..children.len {
                    let fid = unsafe self.cur_ast().list(children)[i as usize];
                    let fldName = self.cur_ast().at_const(fid).as_data.pattern.name;
                    let fn2 = self.name_span(fldName);
                    let mut ft = TYPE_NONE;
                    let mut matchId = NODE_NONE;
                    for j in 0..vpl.len {
                        let pfid = unsafe va.list(vpl)[j as usize];
                        let pf = va.at_const(pfid);
                        if pf.kind == NodeKind::NODE_FIELD && spans_eq2(
                            self.source,
                            fn2,
                            self.mod_src(bmod),
                            va.at_const(pf.as_data.field.name).as_data.name.text,
                        ) {
                            matchId = pfid;
                            ft = self.subst_type(self.lower_type_in(bmod, pf.as_data.field.ty), &gp[0], &ga[0], gn);
                            break;
                        }
                    }
                    if matchId != NODE_NONE {
                        self.cur_ast().set_resolution_def(fldName, DefId { module: bmod, node: matchId });
                    } else {
                        let mut ty = Buf96 {};
                        self.render_type(base, &mut ty[0], 96);
                        self.errors.emit(
                            fn2.start,
                            fn2.end - fn2.start,
                            format(
                                "no field '{}' on '{}'",
                                diag::span_str(self.source, fn2.start, fn2.end),
                                diag::cstr(&ty[0]),
                            ),
                        );
                    }
                    let fc = self.cur_ast().at_const(fid).as_data.pattern.children;
                    for k in 0..fc.len {
                        self.check_pattern(unsafe self.cur_ast().list(fc)[k as usize], ft, bind_ref);
                    }
                }
            } else {
                if agg && nameId != NODE_NONE {
                    self.cur_ast().set_resolution_def(nameId, DefId { module: bmod, node: decl });
                }
                for i in 0..children.len {
                    self.check_pattern(unsafe self.cur_ast().list(children)[i as usize], base, bind_ref);
                }
            }
        } else if nk == NodeKind::NODE_PATTERN_FIELD {
            let base = self.strip(expected);
            let nameId = a.at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agg = self.aggregate_of(base, &mut bmod, &mut decl, &mut gp, &mut ga, &mut gn);
            let mut field_type = TYPE_NONE;
            if agg && nameId != NODE_NONE {
                let fname = self.name_span(nameId);
                let field = self.find_member(bmod, decl, fname);
                if field != NODE_NONE {
                    self.cur_ast().set_resolution_def(nameId, DefId { module: bmod, node: field });
                    field_type = self.subst_type(self.decl_type_in(bmod, field), &gp[0], &ga[0], gn);
                } else {
                    let mut ty = Buf96 {};
                    self.render_type(base, &mut ty[0], 96);
                    self.errors.emit(
                        fname.start,
                        fname.end - fname.start,
                        format(
                            "no field '{}' on '{}'",
                            diag::span_str(self.source, fname.start, fname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                }
            }
            let children = self.cur_ast().at_const(id).as_data.pattern.children;
            for i in 0..children.len {
                self.check_pattern(unsafe self.cur_ast().list(children)[i as usize], field_type, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_TUPLE {
            let base = self.strip(expected);
            let nameId = a.at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = self.cur_module();
            let mut decl0 = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = self.aggregate_of(base, &mut bmod, &mut decl0, &mut gp, &mut ga, &mut gn);
            let agg = agok && self.mod_ast(bmod).at_const(decl0).kind == NodeKind::NODE_ENUM;
            let decl = if_node(agg, decl0, NODE_NONE);
            let mut variant = NODE_NONE;
            if nameId != NODE_NONE {
                let vname = self.name_span(nameId);
                if decl == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(base, &mut ty[0], 96);
                    self.errors.emit(
                        vname.start,
                        vname.end - vname.start,
                        format(
                            "pattern '{}(..)' expects an enum, but the value has type '{}'",
                            diag::span_str(self.source, vname.start, vname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                } else {
                    variant = self.find_member(bmod, decl, vname);
                    if variant != NODE_NONE {
                        self.cur_ast().set_resolution_def(nameId, DefId { module: bmod, node: variant });
                    } else {
                        let mut ty = Buf96 {};
                        self.render_type(base, &mut ty[0], 96);
                        self.errors.emit(
                            vname.start,
                            vname.end - vname.start,
                            format(
                                "no variant '{}' on '{}'",
                                diag::span_str(self.source, vname.start, vname.end),
                                diag::cstr(&ty[0]),
                            ),
                        );
                    }
                }
            }
            let children = self.cur_ast().at_const(id).as_data.pattern.children;
            let mut payload = NodeList { start: 0, len: 0 };
            let mut va: *mut Ast = a;
            if variant != NODE_NONE {
                va = self.mod_ast(bmod);
                payload = va.at_const(variant).as_data.variant.payload;
            }
            for i in 0..children.len {
                let mut pt = TYPE_NONE;
                if i < payload.len {
                    let plid = unsafe va.list(payload)[i as usize];
                    let pe = va.at_const(plid);
                    pt = self.subst_type(
                        self.lower_type_in(bmod, if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid)),
                        &gp[0],
                        &ga[0],
                        gn,
                    );
                }
                self.check_pattern(unsafe self.cur_ast().list(children)[i as usize], pt, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_OR {
            let children = a.at_const(id).as_data.pattern.children;
            for i in 0..children.len {
                self.check_pattern(unsafe self.cur_ast().list(children)[i as usize], expected, bind_ref);
            }
        }
    }

    fn tc_embeds_by_value(self: &mut Self, m: ModuleId, d: NodeId, tm: ModuleId, td: NodeId, depth: i32) bool {
        if depth > 16 {
            return false;
        }
        let a = self.mod_ast(m);
        let dn = *a.at_const(d);
        if dn.kind != NodeKind::NODE_STRUCT && dn.kind != NodeKind::NODE_ENUM || dn.as_data.aggregate.generics.len != 0 {
            return false;
        }
        let members = dn.as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe a.list(members)[i as usize];
            let mn = *a.at_const(mid);
            let mut tns = NodeArr16 {};
            let mut ntn: u32 = 0;
            if dn.as_data.aggregate.is_tuple {
                tns[0] = mid;
                ntn = 1;
            } else if mn.kind == NodeKind::NODE_FIELD {
                tns[0] = mn.as_data.field.ty;
                ntn = 1;
            } else if mn.kind == NodeKind::NODE_VARIANT {
                let pl = mn.as_data.variant.payload;
                let mut j: u32 = 0;
                while j < pl.len && ntn < 16 {
                    let plid = unsafe a.list(pl)[j as usize];
                    let pe = a.at_const(plid);
                    tns[ntn as usize] = if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid);
                    ntn = ntn + 1;
                    j = j + 1;
                }
            }
            for j in 0..ntn {
                let mut ft = self.lower_type_in(m, tns[j as usize]);
                let mut y = *self.type_at(ft);
                while y.kind == TypeKind::TYPE_ARRAY {
                    ft = y.as_data.elem;
                    y = *self.type_at(ft);
                }
                if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
                    if y.module == tm && y.as_data.decl == td || self.tc_embeds_by_value(
                        y.module,
                        y.as_data.decl,
                        tm,
                        td,
                        depth + 1,
                    ) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn check_item(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let nk = a.at_const(id).kind;
        switch nk {
            NODE_STATIC_ASSERT => {
                self.check_static_assert(id);
            },
            NODE_FUNCTION => {
                let params = a.at_const(id).as_data.function.params;
                for i in 0..params.len {
                    self.decl_type(unsafe a.list(params)[i as usize]);
                }
                let fnd = self.cur_ast().at_const(id).as_data.function;
                // `@blocking` is implemented by packing the call's arguments into a frame the pool thread
                // runs from, and a variadic call has no fixed shape to pack -- so say so here rather than
                // let codegen quietly emit an ordinary (worker-blocking) call.
                if fnd.is_variadic && self.tc_attr(self.cur_module(), id, AttrKind::ATTR_BLOCKING) != null {
                    let sp = self.name_span(fnd.name);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "'@blocking' cannot apply to a variadic function: its arguments cannot be forwarded to the blocking pool",
                        ),
                    );
                }
                if fnd.is_variadic && !fnd.is_extern && params.len == 0 {
                    let sp = self.name_span(fnd.name);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a variadic function needs at least one fixed parameter before '...'"),
                    );
                }
                if span_is(self.source, self.name_span(fnd.name), "main") {
                    let rets = fnd.returns;
                    let mut rt = TYPE_NONE;
                    if rets.len == 1 {
                        let r0 = unsafe self.cur_ast().list(rets)[0];
                        let rn = self.cur_ast().at_const(r0);
                        rt = self.resolve_type(
                            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
                        );
                    }
                    if !self.tc_main_params_ok(params) || rets.len != 1 || rt != Ast::builtin(BuiltinType::BT_I32) {
                        let sp = self.name_span(fnd.name);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'main' must be declared 'fn main() i32' or 'fn main(argv: Vector<str>) i32'"),
                        );
                    }
                }
                if fnd.is_const {
                    // '@no_const' in the signature disqualifies the const contract outright: no such
                    // value can exist at compile time, so the shallow body scan need not prove it.
                    let mut ncsite = NODE_NONE;
                    for i in 0..params.len {
                        let pid = unsafe self.cur_ast().list(params)[i as usize];
                        let pn = *self.cur_ast().at_const(pid);
                        let tnode = if_node(pn.kind == NodeKind::NODE_PARAMETER, pn.as_data.parameter.ty, pid);
                        if self.tc_ty_no_const(self.resolve_type(tnode), 0) {
                            ncsite = pid;
                        }
                    }
                    let rets = fnd.returns;
                    for i in 0..rets.len {
                        let rid = unsafe self.cur_ast().list(rets)[i as usize];
                        let rn = *self.cur_ast().at_const(rid);
                        let tnode = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rid);
                        if self.tc_ty_no_const(self.resolve_type(tnode), 0) {
                            ncsite = rid;
                        }
                    }
                    if ncsite != NODE_NONE {
                        let sp = self.cur_ast().at_const(ncsite).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format(
                                "a 'const fn' signature cannot use a '@no_const' type: no such value can exist at compile time",
                            ),
                        );
                    }
                }
                let saved = self.current_returns;
                let savedfn = self.current_fn;
                let saved_wm = self.err_wm;
                self.current_returns = fnd.returns;
                self.current_fn = id;
                self.err_wm = self.errors.errors.len();
                self.nmoved = 0;
                self.nuninit = 0;
                self.nlate = 0;
                self.nfreed = 0;
                self.nborrows = 0;
                self.scope_depth = 0;
                self.loop_depth = 0;
                self.ndefers = 0;
                if fnd.body != NODE_NONE {
                    // an `unsafe fn` body is one big unsafe context: raw-pointer work inside needs
                    // no per-statement markers -- the safety obligation moved to the call sites
                    if fnd.is_unsafe {
                        self.unsafe_depth = self.unsafe_depth + 1;
                    }
                    self.check_stmt(fnd.body);
                    if fnd.is_unsafe {
                        self.unsafe_depth = self.unsafe_depth - 1;
                    }
                }
                // Def-site `const fn` validation, AFTER the body walk: type-based disqualifiers
                // ('@no_const' mentions) only exist once the body is typed, so a pre-body verdict
                // would be blind to them (ce_fn_recheck also overwrites any blind memoized verdict).
                if fnd.is_const && fnd.body != NODE_NONE && !fnd.is_extern {
                    let ceptr = self.ceval();
                    if ceptr != null && ceptr.ce_fn_recheck(self.cur_module(), id) == ce::FX_NO {
                        let sp = self.name_span(fnd.name);
                        // the actionable token is the `const` keyword itself: [pub] [unsafe] const fn
                        // is the canonical order, so scan back from the name across `fn`
                        let mut cstart = sp.start;
                        let mut cend = sp.end;
                        let mut i = sp.start as usize;
                        while i > 0 && (self.source[i - 1] == b' ' || self.source[i - 1] == b'\t' || self.source[i - 1] == b'\n' || self.source[i - 1] == b'\r') {
                            i = i - 1;
                        }
                        if i >= 2 && self.source[i - 2] == b'f' && self.source[i - 1] == b'n' {
                            let mut j = i - 2;
                            while j > 0 && (self.source[j - 1] == b' ' || self.source[j - 1] == b'\t' || self.source[j - 1] == b'\n' || self.source[j - 1] == b'\r') {
                                j = j - 1;
                            }
                            if j >= 5 && diag::span_str(self.source, (j - 5) as u32, j as u32) == "const" {
                                cstart = (j - 5) as u32;
                                cend = j as u32;
                            }
                        }
                        let mut why: str = "cannot be evaluated at compile time";
                        let r = ceptr.fx_no_reason(self.cur_module(), id);
                        if r != null {
                            why = unsafe r.why;
                        }
                        self.errors.emit(
                            cstart,
                            cend - cstart,
                            format(
                                "function '{}' is declared 'const fn' but {}",
                                diag::span_str(self.source, sp.start, sp.end),
                                why,
                            ),
                        );
                        if r != null && unsafe r.site != NODE_NONE {
                            let ss = self.cur_ast().at_const(unsafe r.site).span;
                            let mut line: u32 = 1;
                            for k in 0..ss.start as usize {
                                if self.source[k] == b'\n' {
                                    line = line + 1;
                                }
                            }
                            self.errors.note(
                                format(
                                    "disqualified at '{}' (line {})",
                                    diag::span_str(self.source, ss.start, ss.end),
                                    line,
                                ),
                            );
                        }
                    }
                }
                for mi in 0..self.nmoved {}
                self.nmoved = 0;
                self.nuninit = 0;
                self.nlate = 0;
                self.nfreed = 0;
                self.nborrows = 0;
                self.scope_depth = 0;
                self.loop_depth = 0;
                self.ndefers = 0;
                self.current_returns = saved;
                self.current_fn = savedfn;
                self.err_wm = saved_wm;
            },
            NODE_STRUCT | NODE_ENUM => {
                let agg = a.at_const(id).as_data.aggregate;
                let members = agg.members;
                if agg.is_tuple {
                    for i in 0..members.len {
                        self.resolve_type(unsafe self.cur_ast().list(members)[i as usize]);
                    }
                } else {
                    for i in 0..members.len {
                        let mid = unsafe self.cur_ast().list(members)[i as usize];
                        let mn = *self.cur_ast().at_const(mid);
                        if mn.kind == NodeKind::NODE_FIELD {
                            self.resolve_type(mn.as_data.field.ty);
                        } else {
                            if mn.as_data.variant.value != NODE_NONE {
                                let vt = self.check_expr(mn.as_data.variant.value);
                                if vt != TYPE_NONE && !self.is_int(vt) {
                                    let sp = self.cur_ast().at_const(mn.as_data.variant.value).span;
                                    self.errors.emit(
                                        sp.start,
                                        sp.end - sp.start,
                                        format("enum discriminant must be an integer"),
                                    );
                                }
                            }
                            let payload = mn.as_data.variant.payload;
                            for j in 0..payload.len {
                                let plid = unsafe self.cur_ast().list(payload)[j as usize];
                                let pe = self.cur_ast().at_const(plid);
                                self.resolve_type(if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid));
                            }
                        }
                    }
                }
                if agg.generics.len == 0 && self.tc_embeds_by_value(self.cur_module(), id, self.cur_module(), id, 0) {
                    let sp = self.cur_ast().at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("this type embeds itself by value, so it would have infinite size"),
                    );
                    self.errors.note(format("break the cycle with a pointer ('*mut T'), a reference, or 'Box<T>'"));
                }
                if self.lint && agg.generics.len == 0 && agg.is_union {
                    self.tc_lint_missing_free(id);
                }
            },
            NODE_INTERFACE => {
                self.check_associated(a.at_const(id).as_data.interface_def.items);
            },
            NODE_EXTEND => {
                let saved = self.current_self;
                let saved_impl = self.current_extend;
                self.current_self = a.resolution(a.at_const(id).as_data.extend_def.target_type);
                self.current_extend = id;
                if self.cur_ast().at_const(id).as_data.extend_def.interface_type != NODE_NONE {
                    self.check_extend_conformance(id);
                }
                self.check_associated(self.cur_ast().at_const(id).as_data.extend_def.items);
                self.current_self = saved;
                self.current_extend = saved_impl;
            },
            NODE_CONST => {
                let declared = self.resolve_type(a.at_const(id).as_data.const_def.ty);
                let cd = self.cur_ast().at_const(id).as_data.const_def;
                let dtk = self.type_at(declared).kind;
                // An owning (Free) type IS representable: its object graph -- heap blocks included --
                // materializes into static storage with relocations, exactly as a malloc'd graph does.
                // What makes it sound is that nothing can ever free or mutate it: the value is
                // immutable, and borrowck refuses to move it out of the const (bc_const_move), so no
                // copy exists to run free() on storage the allocator never handed out.
                // The one thing that does NOT survive materialization is allocator STATE: the constant's
                // storage is static data, so state describing it is fiction, and a state field holding a
                // compile-time pointer would freeze that block into the binary as read-only data.
                if !cd.is_extern && !cd.is_static_mut && dtk != TypeKind::TYPE_BUILTIN {
                    let bad = self.tc_const_alloc_state(declared, 0);
                    if bad != TYPE_NONE {
                        let sp = self.name_span(cd.name);
                        let mut tn = Buf96 {};
                        self.render_type(bad, &mut tn[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("a constant cannot use the stateful allocator '{}'", diag::cstr(&tn[0])),
                        );
                        self.errors.note(
                            format(
                                "a constant's storage is static data that no allocator provided, so allocator state beside it describes memory that does not exist; use a zero-sized allocator",
                            ),
                        );
                    }
                }
                if cd.value != NODE_NONE {
                    self.expected = declared; // `[..].into()` and `[]` take their type from here
                    self.check_expr(cd.value);
                    if !self.compatible(declared, cd.value) {
                        self.err_mismatch(cd.value, declared);
                    }
                    if !cd.is_extern && !cd.is_static_mut {
                        self.tc_mandatory_const(id, cd.value);
                    }
                }
                // A raw pointer / reference never owns its pointee (`tc_type_is_free` peels them via
                // `strip`, so it would wrongly report `*mut FreeStruct` as owning) -- a `static mut` holding
                // one is fine, which is how a heap-managed global singleton is expressed.
                if cd.is_static_mut && dtk != TypeKind::TYPE_POINTER && dtk != TypeKind::TYPE_REFERENCE && self.tc_type_is_free(
                    declared,
                ) {
                    let sp = self.cur_ast().at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a 'static mut' cannot hold an owning (Free) type"),
                    );
                    self.errors.note(
                        format("no scope ever frees a global; store a scalar/view or manage the value locally"),
                    );
                }
            },
            NODE_TYPE_ALIAS => {
                let _ = self.resolve_type(a.at_const(id).as_data.type_alias.ty);
            },
            NODE_EXTERN_BLOCK => {
                self.check_associated(a.at_const(id).as_data.extern_block.items);
            },
            _ => {},
        };
    }

    fn check_associated(self: &mut Self, items: NodeList) {
        for i in 0..items.len {
            self.check_item(unsafe self.cur_ast().list(items)[i as usize]);
        }
    }

    fn close_instances(self: &mut Self) {
        let mut ii: usize = 0;
        while ii < unsafe self.cur_ast().instances.len() {
            let it = *self.cur_ast().instance(ii as u32);
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe self.cur_ast().type_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                ii = ii + 1;
                continue;
            }
            self.ensure_ext_items(it.module);
            let ma = self.mod_ast(it.module);
            let ne = self.ext_items_len(it.module);
            for i in 0..ne {
                let iid = self.ext_items_at(it.module, i);
                let itn = ma.at_const(iid);
                // A plain generic extend's methods are instantiated per (instance, method) pair instead,
                // by seed_mono_body_instances -- closing their signatures for every instance is what a
                // method returning a wider view of its own receiver turns into an endless chain.
                let demand = itn.as_data.extend_def.interface_type == NODE_NONE && self.tc_attr(
                    it.module,
                    it.decl,
                    AttrKind::ATTR_EMIT_MACRO,
                ) == null;
                if itn.as_data.extend_def.generics.len != 0 && ma.resolution(itn.as_data.extend_def.target_type) == it.decl {
                    let gens = itn.as_data.extend_def.generics;
                    let mut ip = Defs8 {};
                    let mut ia = Tys8 {};
                    let mut ipn: i32 = 0;
                    let mut g: u32 = 0;
                    while g < gens.len && g as u8 < it.n && ipn < 8 {
                        ip[ipn as usize] = DefId { module: it.module, node: unsafe ma.list(gens)[g as usize] };
                        ia[ipn as usize] = unsafe it.args[g as usize];
                        ipn = ipn + 1;
                        g = g + 1;
                    }
                    let ms = ma.at_const(iid).as_data.extend_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe ma.list(ms)[j as usize];
                        let mn = ma.at_const(mid);
                        if mn.kind == NodeKind::NODE_FUNCTION && mn.as_data.function.generics.len == 0 && !demand {
                            let ps = mn.as_data.function.params;
                            for p in 0..ps.len {
                                let pid = unsafe ma.list(ps)[p as usize];
                                self.subst_type(
                                    self.lower_type_in(it.module, ma.at_const(pid).as_data.parameter.ty),
                                    &ip[0],
                                    &ia[0],
                                    ipn,
                                );
                            }
                            let rs = mn.as_data.function.returns;
                            if rs.len == 1 {
                                let r0 = unsafe ma.list(rs)[0];
                                let rn = ma.at_const(r0);
                                self.subst_type(
                                    self.lower_type_in(
                                        it.module,
                                        if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
                                    ),
                                    &ip[0],
                                    &ia[0],
                                    ipn,
                                );
                            }
                        }
                    }
                }
            }
            ii = ii + 1;
        }
    }

    // ---- lint: bindings declared `mut` whose mutability is never required ------------------------
    // is_assignable marks every binding whose mutability actually answered a requirement; a `mut`
    // binding that is referenced but never marked can drop the keyword. Unreferenced bindings are
    // the unused-variable lint's business (and cover @platform-dropped items, which never resolve).
    @c.cold
    fn tc_mark_mut_used(self: &mut Self, decl: NodeId) {
        if !self.lint {
            return;
        }
        for i in 0..self.mut_used.len() {
            if self.mut_used[i] == decl {
                return;
            }
        }
        self.mut_used.push(decl);
    }

    // Delete [from, to) when it holds no grouping parens (`*(&x)` would leave text unbalanced).
    @c.cold
    fn tc_lint_pair_fix(self: &mut Self, from: u32, to: u32) {
        let mut j = from;
        while j < to {
            if self.source[j as usize] == b'(' || self.source[j as usize] == b')' {
                return;
            }
            j = j + 1;
        }
        if from < to {
            self.errors.fix(from, to, 0);
        }
    }

    // Lint: `(*e).member` -- member access strips its receiver's pointers/references (auto-deref), so the
    // explicit `(*...)` deref is redundant; `e.member` resolves to the identical field/method. Warns and
    // offers a replace fix rewriting `(*e)` to `e`. Only the outer deref wrapping the receiver is removed;
    // the member's own unsafe obligation (a field through a raw pointer still needs `unsafe`) is unchanged.
    fn tc_lint_unnecessary_deref(self: &mut Self, obj_node: NodeId) {
        let a = self.cur_ast();
        let on = *a.at_const(obj_node);
        if on.kind != NodeKind::NODE_UNARY || on.as_data.unary.op != TokenType::Star {
            return;
        }
        let operand = on.as_data.unary.operand;
        if operand == NODE_NONE {
            return;
        }
        // `*E` typechecks only when E is a pointer/reference (the sole thing member access can auto-deref),
        // so the deref is always redundant here; re-confirm against error-recovery operand types.
        let ot = a.type_of(operand);
        if ot == TYPE_NONE {
            return;
        }
        let otk = self.type_at(ot).kind;
        if otk != TypeKind::TYPE_POINTER && otk != TypeKind::TYPE_REFERENCE {
            return;
        }
        let star = on.span.start; // the `*`
        let n = self.source.len();
        // Postfix (`.`/`()`/`[]`) binds tighter than the deref, so `(*E).m` only parses with the receiver
        // parenthesized: the `(` sits immediately before the `*` (across horizontal whitespace). Its
        // matching `)` is then found by a balanced scan -- the operand's own node span excludes any parens
        // it carries, so a nested `(*(*pp))` needs true paren matching, not the span's end.
        let mut lp = star;
        while lp > 0 && (self.source[(lp - 1) as usize] == b' ' || self.source[(lp - 1) as usize] == b'\t') {
            lp = lp - 1;
        }
        if lp == 0 || self.source[(lp - 1) as usize] != b'(' {
            return;
        }
        lp = lp - 1; // the `(`
        let mut depth: i32 = 0;
        let mut j = lp;
        let mut rpe: u32 = 0; // past the matching `)`; 0 = not found
        while j as usize < n {
            let c = self.source[j as usize];
            if c == b'"' || c == b'\'' {
                // skip a string/char literal so a `)` inside it never miscounts the depth
                j = j + 1;
                while j as usize < n {
                    let d = self.source[j as usize];
                    if d == b'\\' {
                        j = j + 2;
                        continue;
                    }
                    j = j + 1;
                    if d == c {
                        break;
                    }
                }
                continue;
            }
            if c == b'(' {
                depth = depth + 1;
            } else if c == b')' {
                depth = depth - 1;
                if depth == 0 {
                    rpe = j + 1;
                    break;
                }
            }
            j = j + 1;
        }
        if rpe == 0 {
            return;
        }
        // Keep everything after the `*`, trimmed -- that is E exactly as written (its own parens included).
        let mut ts = star + 1;
        while ts < rpe - 1 && (self.source[ts as usize] == b' ' || self.source[ts as usize] == b'\t') {
            ts = ts + 1;
        }
        let mut te = rpe - 1;
        while te > ts && (self.source[(te - 1) as usize] == b' ' || self.source[(te - 1) as usize] == b'\t') {
            te = te - 1;
        }
        self.errors.warn(
            lp,
            rpe - lp,
            format("unnecessary deref: '.' auto-derefs the receiver, so '(*...)' is redundant"),
        );
        self.errors.fix_replace(lp, rpe, String::from_str(diag::span_str(self.source, ts, te)));
    }

    // Attach the `mut ` deletion fix: the keyword sits just before the name, across whitespace.
    @c.cold
    fn tc_lint_mut_fix(self: &mut Self, nsp: tok::Span) {
        let mut i = nsp.start as usize;
        while i > 0 && (self.source[i - 1] == b' ' || self.source[i - 1] == b'\t' || self.source[i - 1] == b'\n' || self.source[i - 1] == b'\r') {
            i = i - 1;
        }
        if i >= 3 && self.source[i - 3] == b'm' && self.source[i - 2] == b'u' && self.source[i - 1] == b't' {
            self.errors.fix((i - 3) as u32, nsp.start, 0);
        }
    }

    fn tc_lint_unneeded_mut(self: &mut Self) {
        let a = self.cur_ast();
        let n = unsafe a.nodes.len();
        let mut used = Vector::<bool>::new();
        let mut marked = Vector::<bool>::new();
        used.reserve(n);
        marked.reserve(n);
        for i in 0..n {
            used.push(false);
            marked.push(false);
        }
        for i in 0..a.resolutions_len() {
            let d = a.resolution_def(i as NodeId);
            if d.node != NODE_NONE && d.module == self.cur_module() && d.node as usize < n && i != d.node as usize {
                used.set(d.node as usize, true);
            }
        }
        for i in 0..self.mut_used.len() {
            if self.mut_used[i] as usize < n {
                marked.set(self.mut_used[i] as usize, true);
            }
        }
        let mut i: u32 = 1;
        while i as usize < n {
            let nd = *a.at_const(i);
            let mut nn = NODE_NONE;
            if nd.kind == NodeKind::NODE_LET && nd.as_data.let_stmt.is_mutable && nd.as_data.let_stmt.name != NODE_NONE {
                nn = nd.as_data.let_stmt.name;
            } else if nd.kind == NodeKind::NODE_PARAMETER && nd.as_data.parameter.is_mutable {
                nn = nd.as_data.parameter.name;
            } else if nd.kind == NodeKind::NODE_PATTERN_NAME && nd.as_data.pattern.name != NODE_NONE && a.at_const(
                nd.as_data.pattern.name,
            ).as_data.name.is_mutable {
                nn = nd.as_data.pattern.name;
            }
            if nn != NODE_NONE && used[i as usize] && !marked[i as usize] {
                let sp = a.at_const(nn).as_data.name.text;
                if sp.end > sp.start && self.source[sp.start as usize] != b'_' {
                    self.errors.warn(
                        sp.start,
                        sp.end - sp.start,
                        format("'{}' does not need to be mutable", diag::span_str(self.source, sp.start, sp.end)),
                    );
                    self.tc_lint_mut_fix(sp);
                }
            }
            i = i + 1;
        }
    }

    /// Entry point: types every top-level item, closes concrete generic instances (interning their
    /// methods' signature types), runs whole-module lints, and finalizes diagnostics. Reclaim the
    /// typed Ast with take_ast(); the borrowck pass re-walks it from there.
    pub fn check(self: &mut Self) {
        self.cur_ast().init_types();
        let items = self.cur_ast().at_const(unsafe self.cur_ast().root).as_data.program.items;
        for i in 0..items.len {
            self.check_item(unsafe self.cur_ast().list(items)[i as usize]);
        }
        self.close_instances();
        if self.lint {
            self.tc_lint_unneeded_mut();
        }
        let mut file: str = "";
        if self.package != null && self.cur_module() as usize < self.pkg_count() {
            file = unsafe self.package.modules[self.cur_module() as usize].file.as_str();
        }
        self.errors.finalize(self.source, file);
    }

    pub const fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) {
        self.errors.log();
    }
}

extend TypeChecker as Free {
    pub fn free(self: &mut Self) {
        self.ext_scope.free();
        self.ext_items.free();
        self.len_reported.free();
        self.free_derive_memo.free();
        self.derive_busy.free();
        self.mut_used.free();
        self.ext_items_built.free();
        self.binding_depth.free();
        self.last_use.free();
        self.moved_bits.free();
        self.free_ext_memo.free();
        self.encl_ext_memo.free();
        self.encl_trait_memo.free();
        self.method_memo.free();
        self.peel_memo.free();
        self.lower_memo.free();
        self.dynfn_list.free();
        self.rv_pool.free();
        self.rv_of.free();
        self.arity_memo.free();
        self.variance_of.free();
        self.variance_wip.free();
        self.attributable_memo.free();
        self.lt_region.free();
        self.outlives.free();
        self.carries_memo.free();
        self.errors.free();
        // Free the AST through the cell's raw pointer (like Box::free frees its pointee) rather than
        // invoking UnsafeCell's own drop glue, which a cross-module instance would not have emitted here.
        self.ast.get().free();
    }
}

const fn if_bool(c: bool, a: bool, b: bool) bool {
    if c {
        return a;
    }
    return b;
}
const fn if_u32(c: bool, a: u32, b: u32) u32 {
    if c {
        return a;
    }
    return b;
}
const fn if_nl(c: bool, a: NodeList, b: NodeList) NodeList {
    if c {
        return a;
    }
    return b;
}
