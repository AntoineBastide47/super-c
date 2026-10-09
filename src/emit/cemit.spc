// Streaming C emitter for verified Core IR bodies: one function at a time into one reusable
// buffer, as strict portable C11 (explicit temporaries, no GNU statement expressions, no
// `__auto_type`). Control flow structures through emit::cflow, with goto over `bb_N` labels as
// the fallback; emission is a pure function of the Core body, so serial runs are byte-identical.
// Types and symbols come from the frozen mangler (emit::mangle): the emitter reads only Core IR
// and pools, never resolving, inferring, or interning. Unsupported bodies refuse with a reason.
import ast::ast as *;
import emit::mangle as mbe;
import emit::cflow as cfl;
import emit::probe as prb;
import ir::interp as iri;
import ir::layout as lay;
import ir::core as ir;
import lexer::token_type as tt;
import module::loader as loader;
import emit::simd_plan as sp;
import ir::cpu_features as cf;

/// Nesting bound for the recursive renderers (operands through inlined temporaries, structured
/// control flow through regions): clang's default bracket depth, past which the C would not
/// compile either. Exceeding it fails the body with a diagnostic instead of exhausting the stack.
const RENDER_NEST_MAX: u32 = 256;

/// Deepest chain of nested generic instantiations a body is emitted under. Realistic code nests a
/// few dozen levels; a generic function that reaches itself with a growing type argument (`f::<W<T>>`
/// inside `f<T>`) never stops, and every level deepens each type the mangler spells.
const INST_DEPTH_MAX: u32 = 256;

/// The refusal reason of a body past INST_DEPTH_MAX: a user error, reported as written.
pub const fn inst_depth_why() str<'static> {
    return "generic instantiation nests deeper than 256 levels: a generic function or type reaches itself with a growing type argument";
}

/// Statements `compute_inline` steps over between a candidate's definition and its read.
const INLINE_LOOKAHEAD: u32 = 256;

/// Longest chain of folded temporaries one read spells (see `compute_inline`); well under
/// RENDER_NEST_MAX so a chain nests inside other renderer levels.
const INLINE_CHAIN_MAX: u32 = 64;

/// A body the backend refused to emit: its module, a source span inside it (the function's or
/// closure's own span when it has a return slot or parameter) and the first reason.
pub struct Refusal {
    pub m: ModuleId,
    pub start: u32,
    pub end: u32,
    pub why: str<'static>,
}

/// The body emitter: per-TU output buffers, the mangler, the dedup gates every demand kind goes
/// through, and the per-body scratch (local names, coalescing, inlining decisions).
pub struct CEmit {
    pub pkg: *const loader::Package,
    pub out: String, // the reusable output buffer (caller-owned lifecycle, cleared per TU)
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub refused: Vector<Refusal>, // every body `emit_fn`/`emit_closure` refused, for the driver's report
    pub mg: mbe::Mangler,
    /// Demand-driven monomorphization: when collecting, every per-instance callee this emitter
    /// spells is queued with its SYMBOL and the substitution chain that spelled it, so a driver
    /// can drain the queue to the closed instance set.
    pub collect_demand: bool,
    pub demand: Vector<Demand>,
    pub glue_envs: Vector<GlueEnv>,
    // The current body returns a fixed array by value (in its carrier, `mret`).
    arr_ret: bool,
    /// Set by the caller before `emit_fn` for a `@c.noreturn` item: the signature (and so its
    /// prototype) gets the `_Noreturn` specifier; without it -Werror flags the paths behind a
    /// panic as reading uninitialized locals. Cleared on every emission.
    pub noret: bool,
    // Closure env bridge: Core IR closure bodies take captures as TRAILING arg locals, but the C
    // ABI passes one env pointer: locals >= cap_base spell `__env-><name>` while `cap_on` is
    // set (a void zero-param closure's captures start at local 0, so 0 is not a valid sentinel).
    cap_base: u32,
    cap_on: bool,
    // Bit k set: capture k is mutated (an implicit `&mut`) or borrowed (an implicit `&`) by the
    // body, so the env holds a pointer to the captured binding and the body spells it
    // `(*__env-><name>)`.
    cap_mut: u64,
    // Capture `k`'s C name is `cap_pool[cap_off[k] .. cap_off[k] + cap_len[k]]`.
    cap_pool: String,
    cap_off: Vector<u32>,
    cap_len: Vector<u32>,
    /// Out-of-line declarations a body needs BEFORE itself (its `_ret` typedef); caller-cleared.
    pub aux: String,
    /// Closure-env forward typedefs: spliced into the shared header's FORWARD section.
    pub env_fwd: String,
    /// Env structs the DECLARATION pass already defined (embedded in aggregates): skip ours.
    pub env_skip: Map<u64, u64>,
    /// Env structs THIS emitter defined (the late aggregate replay must skip them).
    pub env_hashes: Vector<u64>,
    /// `extern <decl>;` stubs for every static/const item bodies reference (fusion-TU gate).
    pub stat_decls: String,
    pub fn_attrs: String,
    /// The backend table has an entry the build's features hold, and SC_SIMD_SCALAR is not 1:
    /// vector statements go through the planner (`simd_plan`). `simd_trace` (SC_SIMD_TRACE=1) reports
    /// each operation without a native entry.
    pub simd_on: bool,
    simd_trace: bool,
    /// Per local of the body being emitted: the statement of the one `choose` that reads it, when it
    /// is a comparison result nothing else reads (`lane_only`); IR_NONE otherwise. Empty until a
    /// comparison asks. `ml_chunks`: per such local the comparison rendered as lane-mask temps, their
    /// chunk count (0: bits in the local).
    ml_ch: Vector<u32>,
    ml_chunks: Vector<u32>,
    /// Per local: the comparison result it copies when that copy is the one read of both (`let m =
    /// a.lt(b); m.choose(..)`): the `choose` reads the comparison's temps. IR_NONE otherwise.
    ml_alias: Vector<u32>,
    /// Per local: its reads, its one definition (IR_NONE - 1 for several), the statement of its one
    /// read (`mask_red`).
    ml_cnt: Vector<u32>,
    ml_def: Vector<u32>,
    ml_use: Vector<u32>,
    pub blk_defs: String,
    pub blk_seen: Set<u64>,
    /// Block-wrapper prototypes, one per `sh_blk_k` row (ends in `sh_blk_e2`).
    pub blk_protos: String,
    pub uses_tasks: u8,
    pub stat_seen: Set<u64>,
    /// The referenced items themselves (the definition pass folds each into `<T> <sym> = <v>;`).
    pub stat_items: Vector<StatRef>,
    /// Derived destructor worklist: every `__free__d` symbol bodies referenced, with the resolved
    /// type it destroys (the glue pass emits their definitions, recursing into fields).
    pub glue: Vector<StatRef>,
    pub glue_seen: Set<u64>,
    /// Prototypes for every called EXTERN function (their headers may not be included).
    pub extern_protos: String,
    pub extern_seen: Set<u64>,
    mret: String, // the carrier a body with several stored results or a fixed-array result returns
    /// `SC_DYN_<stem>` typedef blocks (vtable + fat value + inline free) for every dyn stem any
    /// spelling touched; assembled between forward typedefs and aggregate definitions.
    pub dyn_defs: String,
    pub dyn_def_seen: Set<u64>,
    /// Per-coercion thunks (static) + vtable definitions (extern const): exactly one TU owns them.
    pub dyn_tabs: String,
    pub dyn_tab_seen: Set<u64>,
    /// `extern const <stem>__vt <pair>__vtbl;` for every referenced vtable (every TU sees these).
    pub dyn_decls: String,
    /// `type_info::<T>()` sites: each names an exported descriptor group the driver evaluates
    /// through the CTFE static graph and defines once (`__sc_ti__<mangle>`).
    pub ti_reqs: Vector<StatRef>,
    pub ti_seen: Set<u64>,
    /// Extern fns whose `extern "C" "<header>"` block ships real prototypes: the include supplies
    /// them, so a call-site proto would conflict. Keyed (module << 32 | node), driver-filled.
    pub ext_backed: Set<u64>,
    /// Aligned ZST sentinels: one program-level byte per alignment an address-observable ZST
    /// needs (`__sc_zst_<A>`). Every ZST reference of that alignment shares it; the language
    /// permits equal addresses. Definitions land in the instance TU, externs in the protos header.
    pub sent_decls: String,
    pub sent_defs: String,
    pub sent_seen: Set<u64>,
    /// Reusable per-function scratch for structured emission: blocks already spelled, and blocks a
    /// forward goto targets (their label prints when the block is reached). Cleared per body.
    sx_emitted: Vector<bool>,
    sx_lbl: Vector<bool>,
    /// Set by emit_region when it returned by reaching its follow (control can continue past the
    /// region), cleared when it returned by a terminator/transfer. A switch case reads it to decide
    /// whether a trailing `break;` is reachable.
    sx_fell: bool,
    sx_nest: u32, // live depth of the recursive renderers, bounded by RENDER_NEST_MAX
    /// Set during the label-planning pass when the structure would need a `goto` (a cross edge or a
    /// secondary merge the region tree cannot place). Its presence makes the whole body fall back to
    /// the goto layout, so structured output never emits an unplaceable jump.
    sx_goto: bool,
    /// Per-body local spelling, rebuilt by setup_locals. `sx_coal[l]` is the local `l` coalesces
    /// into (itself when it does not): a transparent `_dst = move _src` where the source is used
    /// nowhere else shares one C variable. `sx_name[l]` is the C identifier for local `l`: the
    /// preserved user name (keyword/collision-disambiguated) or `_N` for temps and return slots.
    sx_coal: Vector<u32>,
    // `sx_nm_pool[sx_nm_off[l] .. +sx_nm_len[l]]`; a zero length spells `_<id>`.
    sx_nm_pool: String,
    sx_nm_off: Vector<u32>,
    sx_nm_len: Vector<u32>,
    /// `sx_used[l]` is false when local `l` is referenced nowhere in the body; its declaration is
    /// then dropped (a dead temporary the plan requires we not emit).
    sx_used: Vector<bool>,
    /// `sx_addr[l]`: the body takes the address of local `l` or of a part of it (`&`, a raw address).
    sx_addr: Vector<bool>,
    /// `sx_inline[l]` is the rvalue that defines a single-use pure temporary whose sole read is
    /// adjacent to its definition (nothing runs between them): the definition statement is skipped
    /// and the rvalue is spelled directly at the read, so `_t = a + b; x = _t;` reads `x = a + b;`.
    /// IR_NONE when local `l` is not inlined. Set by setup_locals; consumed by emit_operand.
    sx_inline: Vector<u32>,
    /// `sx_fuse[l]` is true when local `l` declares at its initializing write instead of up front:
    /// its first write is a plain whole-local store that dominates every access, so `int32_t t; t = 0;`
    /// becomes `int32_t t = 0;`. Set per body from the CFG; `sx_declared[l]` records that the fused
    /// declaration has been emitted (later writes to `l` then spell a plain assignment).
    sx_fuse: Vector<bool>,
    sx_declared: Vector<bool>,
    /// A single-return call whose result is used exactly once, in the continuation block with nothing
    /// effectful before the use, forwards into that use: `_r = f(..); return _r;` reads `return f(..);`.
    /// `sx_call_fwd[l]` marks such a destination; the call terminator writes its `f(..)` spelling into
    /// `sx_call_str[l]` (emitting nothing itself), which the single read then spells in place.
    sx_call_fwd: Vector<bool>,
    // `sx_cs_pool[sx_cs_off[l] .. +sx_cs_len[l]]` is local `l`'s forwarded call text.
    sx_cs_pool: String,
    sx_cs_off: Vector<u32>,
    sx_cs_len: Vector<u32>,
    assert_helpers: u8,
    /// String constants past STR_LIT_MAX bytes the current body spells: `lit_decls` declares each as
    /// a body-scope static array `__sc_lit<constant id>` (constant ids in `lit_ids`), placed ahead of
    /// the body's statements. `lit_on` is set only while a body renders.
    lit_on: bool,
    lit_ids: Vector<u32>,
    lit_decls: String,
    /// One induction update moved into the active C `for` clause.
    sx_skip_place: u32,
    sx_skip_rvalue: u32,
    // Newline offsets of every module source (CSR: per-module ranges into one pool), built on the
    // first assert line lookup: line numbers must not rescan the source per assert site.
    line_pool: Vector<u32>,
    line_off: Vector<u64>,
    // Plain concrete-call symbols per (fm, fnode), valid for one mark_ctx (cleared on change so
    // cross-TU spelling edges still record once per spelling TU). Every body re-spells the same
    // callees; the mangle walk must not repeat per call site.
    // The memo maps the callee key to a slot: `sym_pool[sym_off[slot] .. +sym_len[slot]]` is the
    // symbol, `sym_hash[slot]` its reserved-identifier hash (setup_locals reserves it without a
    // second spelling).
    sym_memo: Map<u64, u64>,
    sym_memo_ctx: i64,
    sym_pool: String,
    sym_off: Vector<u32>,
    sym_len: Vector<u32>,
    sym_hash: Vector<u64>,
    // Reusable spelling buffers: the statement/place emitters build every C fragment in a
    // temporary String, so the pool keeps their capacity across the whole emission.
    scratch: Vector<String>,
    // Reusable per-function CFG analyses (a CFlow rebuilds in place without allocating).
    cf_pool: Vector<cfl::CFlow>,
    // Per-body u32/bool scratch arrays for the local-analysis passes (setup_locals, fusion,
    // call forwarding): reallocating them for every body dominated the emitter's allocator traffic.
    u32_pool: Vector<Vector<u32>>,
    bool_pool: Vector<Vector<bool>>,
    // Per-(module, TypeId) declaration-render memo: `decl_txt[i]` is ty_c's spelling with an empty
    // name, `decl_mode[i]` how the name joins (0 = space, 1 = direct, 2 = not prefix-form: call
    // ty_c). Validated per type by comparing against a real ty_c render, so hits are byte-exact.
    // Edge/reserved-ident safety: setup_locals replays both for every local type before decls.
    decl_memo: Map<u64, u64>,
    decl_txt: Vector<String>,
    // `is_destructible` verdicts (1 = needs a free call) of substitution-free types, keyed by the
    // mixed (module, TypeId).
    destr_memo: Map<u64, u64>,
    // The current body's write index (`wx_build`), built on first demand; `setup_locals` drops it.
    // Per local: operand reads (`wx_use`), ST_ASSIGN writes by base in statement order
    // (`wx_wst[wx_woff[l]..wx_woff[l + 1]]`, statement indexes) and one-destination calls into it in
    // block order (`wx_cblk[wx_coff[l]..wx_coff[l + 1]]`, block indexes); per statement its block
    // (`wx_sblk`, ir::IR_NONE when no block holds it); per local whether a reference or address of
    // it is taken (`wx_addr`).
    wx_on: bool,
    wx_addr: Vector<bool>,
    wx_use: Vector<u32>,
    wx_woff: Vector<u32>,
    wx_wst: Vector<u32>,
    wx_coff: Vector<u32>,
    wx_cblk: Vector<u32>,
    wx_sblk: Vector<u32>,
    decl_mode: Vector<u8>,
    /// Caller-provided CFG for the next `emit_fn` (null = build internally). The drain loop
    /// re-emits one lowered body per instantiation; its CFlow is substitution-independent, so the
    /// driver builds it once per body and lends it here.
    pub cf_ext: *const cfl::CFlow,
    // setup_locals' reserved/assigned identifier sets and distinct local types, cleared per body
    // (capacity retained).
    sx_reserved: Map<u64, u64>,
    sx_assigned: Map<u64, u64>,
    sx_seen_ty: Map<u64, u64>,
    // Fingerprints of demands already queued: many call sites raise the identical
    // (sym, chain, sfx) demand, and a duplicate can never emit anything the first did not.
    pub demand_seen: Set<u64>,
    // Per (module, TypeId): the reserved-set ident hashes of the type's C spelling (CSR pool;
    // empty-env spellings only).
    // setup_locals spells every local's type per body; this makes revisits two pool scans.
    ti_memo2: Map<u64, u64>,
    /// Frontier shard capture: when `sh_on`, every first-claimant emission records (key, buffer
    /// end[s]) so the driver can merge shards into the master CEmit in module order, reproducing
    /// the serial claim history byte-for-byte. Value-vector pairs record post-push lengths.
    pub sh_on: bool,
    pub sh_env_k: Vector<u64>,
    pub sh_env_e: Vector<u32>,
    pub sh_stat_k: Vector<u64>,
    pub sh_stat_v: Vector<u32>,
    pub sh_glue_k: Vector<u64>,
    pub sh_glue_v: Vector<u32>,
    pub sh_ext_k: Vector<u64>,
    pub sh_ext_e: Vector<u32>,
    pub sh_dyd_k: Vector<u64>,
    pub sh_dyd_e: Vector<u32>,
    pub sh_dyt_k: Vector<u64>,
    pub sh_dyt_e: Vector<u32>,
    pub sh_dyt_e2: Vector<u32>,
    pub sh_blk_k: Vector<u64>,
    pub sh_blk_e: Vector<u32>,
    pub sh_blk_e2: Vector<u32>,
    pub sh_sent_k: Vector<u64>,
    pub sh_sent_e: Vector<u32>,
    pub sh_sent_e2: Vector<u32>,
    pub sh_ti_k: Vector<u64>,
    pub sh_ti_v: Vector<u32>,
    pub sh_aux_k: Vector<u64>,
    pub sh_aux_e: Vector<u32>,
    /// Owner module of every `aux` entry (0xFFFF = shared helper, forward header), parallel to
    /// `sh_aux_k`; and of every `stat_decls` entry (the constant's declaring module), with the
    /// entry's end offset. Both are kept on every emitter, not only shards.
    pub aux_own: Vector<ModuleId>,
    pub stat_end: Vector<u32>,
    /// Owner module of every dyn table (`sh_dyt_k` row): the receiver type's module, else the
    /// interface's. Block wrappers are keyed by their callee's DefId (`sh_blk_k >> 32`).
    pub dyt_own: Vector<ModuleId>,
    /// Header dependencies bodies added: a `_ret` typedef in module `hdr_k`'s prototype header
    /// names the result carrier whose C name has FNV `hdr_h` (see `Mangler::ret_pack`).
    pub hdr_k: Vector<ModuleId>,
    pub hdr_h: Vector<u64>,
    tid_start: Vector<u32>,
    tid_pool: Vector<u64>,
    /// Emission counters (SC_CEMIT_STATS): declaration planning, rendering, symbol construction.
    pub pr: prb::Probe,
}

/// The substitution env a glue entry was RECORDED under (its type may still name generics).
pub struct GlueEnv {
    pub subs: Vector<mbe::MSub>,
}

/// One static/const definition demanded by an emitted body, keyed for the instance TU.
pub struct StatRef {
    pub em: ModuleId,
    pub def: DefId,
    pub sym: String,
    /// The reference site's local type (pool `em`): what the stub declared, so the definition
    /// must spell the same C type (decl-side types may be unrecorded).
    pub ty: TypeId,
    /// A generic extend constant's instance: each target parameter (`pm`, `pnode`) bound to its
    /// concrete argument (`am`, `at`). Empty for any other item.
    pub args: Vector<mbe::MSub>,
}

/// One demanded per-instance emission: the generic declaration, its C symbol, and the full
/// substitution chain (parent chain + this instance's own bindings, innermost last).
/// A call's generic arguments (`n` types of pool `m` at `at`) passed on to the method an interface
/// method call dispatches to.
pub struct IfTargs {
    pub m: ModuleId,
    pub at: *const TypeId,
    pub n: u32,
}

pub struct Demand {
    pub def: DefId,
    pub sym: String,
    /// The record-time dedupe key when this demand came through the gated method path (0 =
    /// ungated); the frontier merge re-applies cross-module suppression with it.
    pub dk: u64,
    pub subs: Vector<mbe::MSub>,
    /// The instantiation's closure suffix (receiver-args for methods, targs for fn specs);
    /// hoisted closures of the instance body append it to their symbols.
    pub sfx: String,
}

// Does the body carry any loop-back-edge safepoint marker? Decides whether the function needs
// its local preemption tick declared.
extend CEmit {
    /// An emitter over `pkg` (which must outlive it) with empty buffers and gates.
    pub fn new(pkg: *const loader::Package) CEmit {
        let mut mg = mbe::Mangler::new(pkg);
        // The emitted text's type uses decide each unit's definition headers.
        mg.tn_on = true;
        let pk = unsafe &*pkg;
        mg.vec_regs = simd_enabled(pk);
        let st = stdlib::getenv("SC_SIMD_TRACE");
        return CEmit {
            pkg: pkg,
            simd_on: simd_enabled(pk),
            simd_trace: st != null && str::from_cstr(st) == "1",
            out: String::new(),
            err: "",
            refused: Vector::<Refusal>::new(),
            mg: mg,
            collect_demand: false,
            arr_ret: false,
            noret: false,
            demand: Vector::<Demand>::new(),
            glue_envs: Vector::<GlueEnv>::new(),
            cap_base: 0,
            cap_on: false,
            cap_mut: 0,
            cap_pool: String::new(),
            cap_off: Vector::<u32>::new(),
            cap_len: Vector::<u32>::new(),
            aux: String::new(),
            env_fwd: String::new(),
            env_skip: Map::<u64, u64>::new(),
            env_hashes: Vector::<u64>::new(),
            mret: String::new(),
            stat_decls: String::new(),
            fn_attrs: String::new(),
            blk_defs: String::new(),
            blk_seen: Set::<u64>::new(),
            blk_protos: String::new(),
            uses_tasks: 0,
            stat_seen: Set::<u64>::new(),
            stat_items: Vector::<StatRef>::new(),
            glue: Vector::<StatRef>::new(),
            glue_seen: Set::<u64>::new(),
            extern_protos: String::new(),
            extern_seen: Set::<u64>::new(),
            dyn_defs: String::new(),
            dyn_def_seen: Set::<u64>::new(),
            dyn_tabs: String::new(),
            dyn_tab_seen: Set::<u64>::new(),
            dyn_decls: String::new(),
            ti_reqs: Vector::<StatRef>::new(),
            ti_seen: Set::<u64>::new(),
            ext_backed: Set::<u64>::new(),
            sent_decls: String::new(),
            sent_defs: String::new(),
            sent_seen: Set::<u64>::new(),
            sx_emitted: Vector::<bool>::new(),
            sx_lbl: Vector::<bool>::new(),
            sx_fell: false,
            sx_nest: 0,
            sx_goto: false,
            sx_coal: Vector::<u32>::new(),
            sx_nm_pool: String::new(),
            sx_nm_off: Vector::<u32>::new(),
            sx_nm_len: Vector::<u32>::new(),
            sx_used: Vector::<bool>::new(),
            sx_addr: Vector::<bool>::new(),
            sx_inline: Vector::<u32>::new(),
            sx_call_fwd: Vector::<bool>::new(),
            sx_cs_pool: String::new(),
            sx_cs_off: Vector::<u32>::new(),
            sx_cs_len: Vector::<u32>::new(),
            assert_helpers: 0,
            lit_on: false,
            lit_ids: Vector::<u32>::new(),
            lit_decls: String::new(),
            sx_fuse: Vector::<bool>::new(),
            sx_declared: Vector::<bool>::new(),
            sx_skip_place: ir::IR_NONE,
            sx_skip_rvalue: ir::IR_NONE,
            line_pool: Vector::<u32>::new(),
            line_off: Vector::<u64>::new(),
            sym_memo: Map::<u64, u64>::new(),
            sym_memo_ctx: -2,
            sym_pool: String::new(),
            sym_off: Vector::<u32>::new(),
            sym_len: Vector::<u32>::new(),
            sym_hash: Vector::<u64>::new(),
            scratch: Vector::<String>::new(),
            cf_pool: Vector::<cfl::CFlow>::new(),
            u32_pool: Vector::<Vector<u32>>::new(),
            bool_pool: Vector::<Vector<bool>>::new(),
            decl_memo: Map::<u64, u64>::new(),
            decl_txt: Vector::<String>::new(),
            destr_memo: Map::<u64, u64>::new(),
            wx_on: false,
            wx_addr: Vector::<bool>::new(),
            wx_use: Vector::<u32>::new(),
            wx_woff: Vector::<u32>::new(),
            wx_wst: Vector::<u32>::new(),
            wx_coff: Vector::<u32>::new(),
            wx_cblk: Vector::<u32>::new(),
            wx_sblk: Vector::<u32>::new(),
            decl_mode: Vector::<u8>::new(),
            cf_ext: null,
            sx_reserved: Map::<u64, u64>::new(),
            sx_assigned: Map::<u64, u64>::new(),
            sx_seen_ty: Map::<u64, u64>::new(),
            demand_seen: Set::<u64>::new(),
            ti_memo2: Map::<u64, u64>::new(),
            sh_on: false,
            sh_env_k: Vector::<u64>::new(),
            sh_env_e: Vector::<u32>::new(),
            sh_stat_k: Vector::<u64>::new(),
            sh_stat_v: Vector::<u32>::new(),
            sh_glue_k: Vector::<u64>::new(),
            sh_glue_v: Vector::<u32>::new(),
            sh_ext_k: Vector::<u64>::new(),
            sh_ext_e: Vector::<u32>::new(),
            sh_dyd_k: Vector::<u64>::new(),
            sh_dyd_e: Vector::<u32>::new(),
            sh_dyt_k: Vector::<u64>::new(),
            sh_dyt_e: Vector::<u32>::new(),
            sh_dyt_e2: Vector::<u32>::new(),
            sh_blk_k: Vector::<u64>::new(),
            sh_blk_e: Vector::<u32>::new(),
            sh_blk_e2: Vector::<u32>::new(),
            sh_sent_k: Vector::<u64>::new(),
            sh_sent_e: Vector::<u32>::new(),
            sh_sent_e2: Vector::<u32>::new(),
            sh_ti_k: Vector::<u64>::new(),
            sh_ti_v: Vector::<u32>::new(),
            sh_aux_k: Vector::<u64>::new(),
            sh_aux_e: Vector::<u32>::new(),
            aux_own: Vector::<ModuleId>::new(),
            stat_end: Vector::<u32>::new(),
            dyt_own: Vector::<ModuleId>::new(),
            hdr_k: Vector::<ModuleId>::new(),
            hdr_h: Vector::<u64>::new(),
            tid_start: Vector::<u32>::new(),
            tid_pool: Vector::<u64>::new(),
            pr: prb::Probe::new(stdlib::getenv("SC_CEMIT_STATS") != null, stdlib::getenv("SC_BUILD_MEM") != null),
        };
    }

    fn cfget(self: &mut Self) cfl::CFlow {
        let c9 = switch self.cf_pool.pop() {
            Some(c) => c,
            None => cfl::CFlow::new_empty(),
        };
        return c9;
    }

    fn cfput(self: &mut Self, cf: cfl::CFlow) {
        self.cf_pool.push(cf);
    }

    fn sget(self: &mut Self) String {
        let s9 = switch self.scratch.pop() {
            Some(s) => s,
            None => String::new(),
        };
        return s9;
    }

    fn sput(self: &mut Self, s: String) {
        let mut s9 = s;
        s9.clear();
        self.scratch.push(s9);
    }
    fn uget(self: &mut Self) Vector<u32> {
        let v9 = switch self.u32_pool.pop() {
            Some(v) => v,
            None => Vector::<u32>::new(),
        };
        return v9;
    }

    fn uput(self: &mut Self, v: Vector<u32>) {
        let mut v9 = v;
        v9.clear();
        self.u32_pool.push(v9);
    }

    fn bget(self: &mut Self) Vector<bool> {
        let v9 = switch self.bool_pool.pop() {
            Some(v) => v,
            None => Vector::<bool>::new(),
        };
        return v9;
    }

    fn bput(self: &mut Self, v: Vector<bool>) {
        let mut v9 = v;
        v9.clear();
        self.bool_pool.push(v9);
    }

    // Feed local type `(m, t)`'s C-spelling identifiers into the reserved set, through the
    // per-type cache when the substitution env is empty. The spelling records no edge: a local
    // the output declares records its own (a zero-sized one is never declared).
    fn reserve_local_ty(self: &mut Self, m: ModuleId, t: TypeId) {
        if self.mg.subs.len() != 0 {
            let mut cs = self.sget();
            self.mg.no_edges = true;
            let okc = self.mg.ctype(m, t, "", &mut cs);
            self.mg.no_edges = false;
            if okc {
                // The tail of the per-type pool serves as scratch: this env's spelling is not cached.
                let h0 = self.tid_pool.len();
                collect_ident_hashes(cs.as_str(), &mut self.tid_pool);
                for k in h0..self.tid_pool.len() {
                    self.sx_reserved.insert(*self.tid_pool.at(k), 1);
                }
                self.tid_pool.truncate(h0);
            }
            self.sput(cs);
            return;
        }
        if self.tid_start.len() == 0 {
            self.tid_start.push(0);
        }
        let key = skey_mix(0, m as u64 << 32 | t as u64);
        let hit = switch self.ti_memo2.get(&key) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if hit >= 0 {
            let ei = hit as usize;
            for k in *self.tid_start.at(ei)..*self.tid_start.at(ei + 1) {
                self.sx_reserved.insert(*self.tid_pool.at(k as usize), 1);
            }
            return;
        }
        let ei = self.tid_start.len() - 1;
        let mut cs = self.sget();
        self.mg.no_edges = true;
        let okc = self.mg.ctype(m, t, "", &mut cs);
        self.mg.no_edges = false;
        if okc {
            let h0 = self.tid_pool.len();
            collect_ident_hashes(cs.as_str(), &mut self.tid_pool);
            for k in h0..self.tid_pool.len() {
                self.sx_reserved.insert(*self.tid_pool.at(k), 1);
            }
        }
        self.sput(cs);
        self.tid_start.push(self.tid_pool.len() as u32);
        self.ti_memo2.insert(key, ei as u64);
    }

    // 1-based line of byte offset `pos` in module `m`'s source (line ends strictly before `pos`: `\n`,
    // `\r\n` at its `\n`, or a lone `\r`, as the diagnostics count them).
    fn src_line(self: &mut Self, m: ModuleId, pos: u64) u64 {
        if self.line_off.len() == 0 {
            // Slots for every module; a module's newline table fills on its first lookup (most
            // modules never ask, and scanning every source per emitter was measurable).
            for _mi in 0..self.p().modules.len() {
                self.line_off.push(0xFFFFFFFFFFFFFFFFu64);
                self.line_off.push(0);
            }
        }
        if self.line_off[m as usize * 2] == 0xFFFFFFFFFFFFFFFFu64 {
            let start = self.line_pool.len() as u64;
            let src = self.p().modules.at(m as usize).source.as_str();
            for k in 0..src.len() {
                let c = src.byte_at(k);
                if c == 10 || c == 13 && (k + 1 == src.len() || src.byte_at(k + 1) != 10) {
                    self.line_pool.push(k as u32);
                }
            }
            self.line_off.set(m as usize * 2, start);
            self.line_off.set(m as usize * 2 + 1, self.line_pool.len() as u64);
        }
        let s = self.line_off[m as usize * 2] as usize;
        let mut lo = s;
        let mut hi = self.line_off[m as usize * 2 + 1] as usize;
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.line_pool[mid] as u64 < pos {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return 1 + (lo - s) as u64;
    }

    const fn p<'a>(self: &Self) &'a loader::Package {
        return unsafe &*self.pkg;
    }

    const fn fail(self: &mut Self, why: str<'static>) bool {
        if self.err.len() == 0 {
            self.err = why;
        }
        return false;
    }

    // `(pm, t)` as a C declarator around `decl`; TYPE_NONE (unit) spells `void`.
    fn ty_c(self: &mut Self, m: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        if t == TYPE_NONE {
            out.push_str("void");
            if decl.len() != 0 {
                out.push_str(" ");
                out.push_str(decl);
            }
            return true;
        }
        if !self.mg.ctype(m, t, decl, out) {
            return self.fail("ctype");
        }
        return true;
    }

    // Push a demand binding unless it is the identity (a receiver spelled with its own param:
    // `self.method()` inside the generic body): the outer chain already binds it, and an
    // identity entry would make resolution loop.
    // `lim` is the snapshot length where the bind GROUP starts: every payload references the env
    // below the group, never a sibling frame (extend + struct params alias the same spellings).
    fn push_bind(
        self: &Self,
        snap: &mut Vector<mbe::MSub>,
        pm: ModuleId,
        pnode: NodeId,
        am: ModuleId,
        at: TypeId,
        lim: u32,
    ) {
        let y = *unsafe (*self.p().module_ast_const(am)).type_at(at);
        if y.kind == TypeKind::TYPE_GENERIC && y.module == pm && y.as_data.decl == pnode {
            return;
        }
        snap.push(mbe::MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
    }

    // Bind the parameters of the conformance of receiver `(rm, rt)` to interface `iface` into `snap`:
    // the extend's from the receiver, then the interface's to the arguments the conformance writes,
    // which name the extend's. `conf` is the conformance extend when the caller chose one among
    // several (`conf_for_args`); node NODE_NONE takes the first (`conform_ext`).
    fn bind_conformance(
        self: &mut Self,
        snap: &mut Vector<mbe::MSub>,
        rm: ModuleId,
        rt: TypeId,
        iface: DefId,
        conf: DefId,
    ) {
        let mut em = conf.module;
        let ext = if conf.node != NODE_NONE {
            conf.node;
        } else {
            self.mg.conform_ext(rm, rt, iface, &mut em);
        };
        if ext == NODE_NONE {
            return;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.p().module_ast_const(rm)).instance(y.as_data.inst);
            self.bind_recv(snap, em, ext, rm, &it);
        }
        let ea = self.p().module_ast_const(em);
        let itn = unsafe (*ea).at_const(ext).as_data.extend_def.interface_type;
        if unsafe (*ea).at_const(itn).kind != NodeKind::NODE_TYPE_PATH {
            return;
        }
        let targs = unsafe (*ea).at_const(itn).as_data.type_path.args;
        let igens = unsafe (*self.p().module_ast_const(iface.module)).at_const(iface.node).as_data.interface_def.generics;
        let l0 = snap.len() as u32;
        let mut g: u32 = 0;
        while g < targs.len && g < igens.len {
            let at = unsafe (*ea).type_of(unsafe (*ea).list(targs)[g as usize]);
            if at != TYPE_NONE {
                self.push_bind(
                    snap,
                    iface.module,
                    unsafe (*self.p().module_ast_const(iface.module)).list(igens)[g as usize],
                    em,
                    at,
                    l0,
                );
            }
            g += 1;
        }
    }

    // Among several extends conforming resolved receiver `(rm, rt)` to the interface of instance
    // `iit` (arguments in pool `pm`), the one whose interface arguments, under the extend's
    // parameters bound to the receiver, equal `iit`'s: the one the checker admitted the coercion
    // through. Node NODE_NONE when at most one conformance applies (the by-name lookup finds it).
    fn conf_for_args(self: &mut Self, rm: ModuleId, rt: TypeId, pm: ModuleId, iit: &TyInstance) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut rit = TyInstance { module: y.module, decl: NODE_NONE, n: 0 };
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            rit.decl = y.as_data.decl;
        } else if unsafe (*self.p().module_ast_const(rm)).targs_of(rt, &mut rit) {} else if y.kind == TypeKind::TYPE_BUILTIN {
            rit.module = self.p().core_module;
            rit.decl = self.p().builtin_decl(y.as_data.builtin);
        }
        if rit.decl == NODE_NONE {
            return none;
        }
        let mut hit = none;
        let mut napply: u32 = 0;
        for xm in 0..self.p().modules.len() {
            if !self.p().modules.at(xm).has_ast {
                continue;
            }
            let em = xm as ModuleId;
            let da = self.p().module_ast_const(em);
            let items = unsafe (*da).at_const((*da).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*da).list(items)[i as usize];
                if unsafe (*da).at_const(iid).kind != NodeKind::NODE_EXTEND {
                    continue;
                }
                let ed = unsafe (*da).at_const(iid).as_data.extend_def;
                if ed.interface_type == NODE_NONE || unsafe (*da).at_const(ed.interface_type).kind != NodeKind::NODE_TYPE_PATH {
                    continue;
                }
                let ir0 = unsafe (*da).resolution_def(ed.interface_type);
                let tg = unsafe (*da).resolution_def(ed.target_type);
                if ir0.module != iit.module || ir0.node != iit.decl || tg.module != rit.module || tg.node != rit.decl {
                    continue;
                }
                if rit.n != 0 && !self.mg.ext_applies_inst(em, iid, rm, &rit) {
                    continue;
                }
                napply += 1;
                if hit.node != NODE_NONE {
                    continue;
                }
                let mut snap = mbe::subs_copy(&self.mg.subs);
                let base = snap.len();
                if rit.n != 0 {
                    self.bind_recv(&mut snap, em, iid, rm, &rit);
                }
                for k in base..snap.len() {
                    self.mg.push_msub(snap[k]);
                }
                // The conformance's whole argument list, defaults included, as the checker recorded it
                // on the interface path (`dyn I<args>`).
                let dt = unsafe (*da).type_of(ed.interface_type);
                let mut same = dt != TYPE_NONE;
                if same {
                    let di = *unsafe (*da).instance(unsafe (*da).type_at(dt).as_data.inst);
                    same = di.n == iit.n;
                    let mut k: u8 = 0;
                    while same && k < di.n {
                        let mut g1 = TYPE_NONE;
                        let mut g2 = TYPE_NONE;
                        same = self.mg.ground(em, unsafe di.args[k as usize], pm, &mut g1) && self.mg.ground(
                            pm,
                            unsafe iit.args[k as usize],
                            pm,
                            &mut g2,
                        ) && g1 == g2;
                        k += 1;
                    }
                }
                self.mg.pop_subs(snap.len() - base);
                if same {
                    hit = DefId { module: em, node: iid };
                }
            }
        }
        return pick(napply > 1, hit, none);
    }

    // Bind the receiver instance `it` (args in module `am`) to the generics of extend `ext` (declared
    // in module `em`) AND to the struct declaration's own generics: body types reference either decl.
    // An extend whose target is not its parameters in order binds each through the argument that
    // solves it (`xarg_of`): a form's parameter takes the value that inverts it, interned in `am`.
    fn bind_recv(self: &Self, snap: &mut Vector<mbe::MSub>, em: ModuleId, ext: NodeId, am: ModuleId, it: &TyInstance) {
        let g0 = snap.len() as u32;
        let ea = self.p().module_ast_const(em);
        let eg = unsafe (*ea).at_const(ext).as_data.extend_def.generics;
        let pat = unsafe (*ea).type_of(unsafe (*ea).at_const(ext).as_data.extend_def.target_type);
        if ext_is_identity(unsafe &*ea, pat, unsafe &*ea, em, ext) {
            let mut gi: u32 = 0;
            while gi < eg.len && gi as u8 < it.n {
                self.push_bind(snap, em, unsafe (*ea).list(eg)[gi as usize], am, unsafe it.args[gi as usize], g0);
                gi += 1;
            }
        } else {
            let mut pi = TyInstance {};
            let _ = unsafe (*ea).targs_of(pat, &mut pi);
            let np = ext_arity(unsafe &*ea, ext, pi.n);
            let mut j: u32 = 0;
            while j < np && j < it.n {
                let x = xarg_of(unsafe &*ea, unsafe pi.args[j as usize], unsafe &*ea, em, eg);
                let at = unsafe it.args[j as usize];
                if x.kind == XA_PARAM {
                    self.push_bind(snap, em, unsafe (*ea).list(eg)[x.par as usize], am, at, g0);
                } else if x.kind == XA_FORM {
                    let gid = unsafe (*ea).list(eg)[x.par as usize];
                    let gbt = self.p().const_param_bt(em, gid);
                    let mut v: i64 = 0;
                    let mut vbt = BuiltinType::BT_COUNT;
                    let mut q = i128::zero();
                    let ptr32 = lay::target_for(self.p().arch).ptr == 4;
                    if self.mg.fold_cval_at(am, at, &mut v, &mut vbt, self.mg.subs.len()) && xarg_solve(
                        &x,
                        cval_exact(v, vbt),
                        gbt,
                        ptr32,
                        &mut q,
                    ) {
                        let ct = unsafe (*(self.p().module_ast_const(am) as *mut Ast)).const_value(cval_bits(q), gbt);
                        self.push_bind(snap, em, gid, am, ct, g0);
                    }
                }
                j += 1;
            }
        }
        let ra = self.p().module_ast_const(it.module);
        let sg = unsafe (*ra).at_const(it.decl).as_data.aggregate.generics;
        let mut gj: u32 = 0;
        while gj < sg.len && gj as u8 < it.n {
            self.push_bind(snap, it.module, unsafe (*ra).list(sg)[gj as usize], am, unsafe it.args[gj as usize], g0);
            gj += 1;
        }
    }

    // The source name of aggregate declaration `decl` in module `m`.
    const fn agg_name<'a>(self: &Self, m: ModuleId, decl: NodeId) str<'a> {
        let da = self.p().module_ast_const(m);
        let sp = unsafe (*da).at_const(unsafe (*da).at_const(decl).as_data.aggregate.name).as_data.name.text;
        return self.p().modules.at(m as usize).source.as_str().slice(sp.start as usize, sp.end as usize);
    }

    // The prelude `str` view type (STRUCT named `str` in a prelude module).
    const fn is_str_ty(self: &Self, rm: ModuleId, rt: TypeId) bool {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind != TypeKind::TYPE_STRUCT || !self.p().modules.at(y.module as usize).prelude {
            return false;
        }
        return self.agg_name(y.module, y.as_data.decl) == "str";
    }

    // The cast that prefixes each operand of comparison `t` over operand type `rt`: an ordered raw-pointer
    // comparison compares addresses as `uintptr_t`, because C defines `<` only within one object.
    const fn ptr_order_cast(self: &Self, rm: ModuleId, rt: TypeId, t: tt::TokenType) str<'static> {
        if rt == TYPE_NONE || t != tt::TokenType::LessThan && t != tt::TokenType::LessThanEqual && t != tt::TokenType::GreaterThan && t != tt::TokenType::GreaterThanEqual {
            return "";
        }
        return mbe::if_s(
            unsafe (*self.p().module_ast_const(rm)).type_at(rt).kind == TypeKind::TYPE_POINTER,
            "(uintptr_t)",
            "",
        );
    }

    // The C-visible fixed-array length of the value a place denotes, or -1: the recorded types may
    // say "slice" (a checker coercion), but a FIELD's declared type says what C emitted.
    fn place_c_arr_len(self: &mut Self, b: &ir::CoreBody, plid: ir::PlaceId) i64 {
        let pl = *b.places.at(plid as usize);
        if pl.proj_len == 0 {
            let n = self.arr_n(b, b.locals.at(pl.base as usize).ty);
            if n > 0 {
                return n;
            }
            return 0 - 1;
        }
        let pj = *b.projections.at((pl.proj_start + pl.proj_len - 1) as usize);
        if pj.kind != ir::PJ_FIELD {
            return 0 - 1;
        }
        let prev = if pl.proj_len >= 2 {
            b.projections.at((pl.proj_start + pl.proj_len - 2) as usize).ty;
        } else {
            b.locals.at(pl.base as usize).ty;
        };
        let mut rm = b.module;
        let mut rt = prev;
        self.rty(b, prev, &mut rm, &mut rt);
        self.peel_refs(&mut rm, &mut rt);
        let dm = self.agg_module_res(rm, rt);
        let da = self.p().module_ast_const(dm);
        // Named field: `sub` is the NODE_FIELD. Tuple member: `sub` is NODE_NONE and `data` is the index.
        let ftn = if pj.sub != NODE_NONE {
            if unsafe (*da).at_const(pj.sub).kind != NodeKind::NODE_FIELD {
                return 0 - 1;
            }
            unsafe (*da).at_const(pj.sub).as_data.field.ty;
        } else {
            let decl = self.agg_decl_res(rm, rt);
            if decl == NODE_NONE {
                return 0 - 1;
            }
            let ms = unsafe (*da).at_const(decl).as_data.aggregate.members;
            if pj.data >= ms.len {
                return 0 - 1;
            }
            unsafe (*da).list(ms)[pj.data as usize];
        };
        let ftl = unsafe (*da).type_of(ftn);
        if ftl == TYPE_NONE {
            return 0 - 1;
        }
        let yF = *unsafe (*da).type_at(ftl);
        if yF.kind != TypeKind::TYPE_ARRAY {
            return 0 - 1;
        }
        // A symbolic field length folds under the aggregate instance's arguments.
        let ay = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut nb: usize = 0;
        if yF.arr_sym() && ay.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.p().module_ast_const(rm)).instance(ay.as_data.inst);
            nb = self.mg.push_generics(dm, unsafe (*da).at_const(it.decl).as_data.aggregate.generics, rm, &it);
        }
        let n = self.mg.arr_len(dm, &yF);
        self.mg.pop_subs(nb);
        if n > 0 {
            return n;
        }
        return 0 - 1;
    }

    // Does argument `i` lose its C slot? Only a BY-VALUE zero-sized argument does: when the
    // callee's declared param is a reference or pointer (a receiver auto-ref), the slot is a real
    // pointer even though the OPERAND is recorded with the value type. Mirrors emit_call_arg's
    // param inspection so caller and callee always agree.
    fn arg_slot_erased(self: &mut Self, b: &ir::CoreBody, callee0: DefId, i: u32, opid: ir::OperandId) bool {
        let aty = b.operands.at(opid as usize).ty;
        if aty == TYPE_NONE || !self.erased(b, aty) {
            return false;
        }
        if callee0.node == NODE_NONE {
            // Fn-value call: reference params carry reference-typed operands.
            return true;
        }
        let mut callee = callee0;
        if self.mg.in_interface(callee0.module, callee0.node) != NODE_NONE && self.mg.last_method_def.node != NODE_NONE {
            callee = self.mg.last_method_def;
        }
        let fa = self.p().module_ast_const(callee.module);
        let fnn = unsafe (*fa).at_const(callee.node);
        if fnn.kind != NodeKind::NODE_FUNCTION {
            return true;
        }
        let ps = fnn.as_data.function.params;
        if i >= ps.len {
            return true;
        }
        let pn = unsafe (*fa).at_const(unsafe (*fa).list(ps)[i as usize]);
        if pn.kind != NodeKind::NODE_PARAMETER || pn.as_data.parameter.ty == NODE_NONE {
            return true;
        }
        let pty = unsafe (*fa).type_of(pn.as_data.parameter.ty);
        if pty == TYPE_NONE {
            return true;
        }
        let mut pk = unsafe (*fa).type_at(pty).kind;
        if pk == TypeKind::TYPE_GENERIC {
            let mut xm = callee.module;
            let mut xt = pty;
            if self.mg.resolve(callee.module, pty, &mut xm, &mut xt) {
                pk = unsafe (*self.p().module_ast_const(xm)).type_at(xt).kind;
            }
        }
        return pk != TypeKind::TYPE_REFERENCE && pk != TypeKind::TYPE_POINTER;
    }

    // Render one call argument with the implicit adjustments the language applies at calls:
    // autoref (`&` when the param is a reference and the arg a value) and Box auto-deref
    // (`b.ptr` bridges Box<T> receivers to T* params).
    fn emit_call_arg(self: &mut Self, b: &ir::CoreBody, callee0: DefId, i: u32, opid: ir::OperandId, dst: &mut String) bool {
        if callee0.node == NODE_NONE {
            return self.emit_operand(b, opid, dst);
        }
        // A bound-dispatched interface member resolved to a concrete impl: the IMPL's params
        // decide the arg shapes (its `&mut Box<..>` self must not take the auto-deref hop).
        let mut callee = callee0;
        if self.mg.in_interface(callee0.module, callee0.node) != NODE_NONE && self.mg.last_method_def.node != NODE_NONE {
            callee = self.mg.last_method_def;
        }
        let fa = self.p().module_ast_const(callee.module);
        let fnn = unsafe (*fa).at_const(callee.node);
        if fnn.kind == NodeKind::NODE_FUNCTION && i >= fnn.as_data.function.params.len && fnn.as_data.function.is_variadic() {
            return self.emit_vararg(b, opid, dst);
        }
        if self.extern_fn(callee) && self.wrap_ptr(b, b.operands.at(opid as usize).ty) {
            // C declares the parameter a pointer to the array itself: convert the value.
            dst.push_str("(void *)(");
            let okx = self.emit_operand(b, opid, dst);
            dst.push_str(")");
            return okx;
        }
        let mut want_ref = false;
        let mut want_val = false; // the param takes the VALUE: reference args deref
        let mut param_box = false; // the param's own pointee IS a Box or a generic: no deref hop
        if fnn.kind == NodeKind::NODE_FUNCTION {
            let ps = fnn.as_data.function.params;
            if i < ps.len {
                let pn = unsafe (*fa).at_const(unsafe (*fa).list(ps)[i as usize]);
                if pn.kind == NodeKind::NODE_PARAMETER && pn.as_data.parameter.ty != NODE_NONE {
                    let mut pty = unsafe (*fa).type_of(pn.as_data.parameter.ty);
                    let mut fap = fa;
                    // A GENERIC param decides shapes by its BOUND type under the active
                    // substitution (T = &i64 is a reference param, not a by-value one); an
                    // UNRESOLVED generic decides nothing, so the lowered operand's shape stands.
                    if pty != TYPE_NONE && unsafe (*fap).type_at(pty).kind == TypeKind::TYPE_GENERIC {
                        let mut xm = callee.module;
                        let mut xt = pty;
                        let grounded = self.mg.resolve(callee.module, pty, &mut xm, &mut xt);
                        if grounded && unsafe (*self.p().module_ast_const(xm)).type_at(xt).kind != TypeKind::TYPE_GENERIC {
                            pty = xt;
                            fap = self.p().module_ast_const(xm);
                        } else {
                            pty = TYPE_NONE;
                        }
                    }
                    if pty != TYPE_NONE && unsafe (*fap).type_at(pty).kind != TypeKind::TYPE_REFERENCE && unsafe (*fap).type_at(
                        pty,
                    ).kind != TypeKind::TYPE_POINTER {
                        want_val = true;
                        // A wide-literal arg into a SCALAR param (a `from` widening shim) fits
                        // one limb by construction.
                        if unsafe (*fap).type_at(pty).kind == TypeKind::TYPE_BUILTIN {
                            let op0 = *b.operands.at(opid as usize);
                            if op0.kind == ir::OP_CONST {
                                let c0 = *b.constants.at(op0.data as usize);
                                if c0.kind == ir::CK_WIDE {
                                    let aW = self.p().module_ast_const(b.module);
                                    let wW = *unsafe (*aW).wide_lits.at(c0.val as usize);
                                    dst.push_str("0x");
                                    dst.push_hex(wW.limbs[0], false);
                                    dst.push_str("ULL");
                                    return true;
                                }
                            }
                        }
                    }
                    if pty != TYPE_NONE && unsafe (*fap).type_at(pty).kind == TypeKind::TYPE_REFERENCE {
                        want_ref = true;
                        let pe = unsafe (*fap).type_at(pty).as_data.elem;
                        if pe != TYPE_NONE && unsafe (*fap).type_at(pe).kind == TypeKind::TYPE_GENERIC {
                            // A generic pointee binds to the argument's own type (a Deref coercion
                            // the checker chose is already in the operand): no hop either.
                            param_box = true;
                        } else if pe != TYPE_NONE && unsafe (*fap).type_at(pe).kind == TypeKind::TYPE_INSTANCE {
                            let pit = *unsafe (*fap).instance(unsafe (*fap).type_at(pe).as_data.inst);
                            param_box = self.agg_name(pit.module, pit.decl) == "Box";
                        }
                    }
                }
            }
        }
        if !want_ref {
            if want_val {
                let mut aty0 = b.operands.at(opid as usize).ty;
                if aty0 == TYPE_NONE {
                    let op0 = *b.operands.at(opid as usize);
                    if op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE {
                        aty0 = b.places.at(op0.data as usize).ty;
                    }
                }
                let mut rm0 = b.module;
                let mut rt0 = aty0;
                self.rty(b, aty0, &mut rm0, &mut rt0);
                if unsafe (*self.p().module_ast_const(rm0)).type_at(rt0).kind == TypeKind::TYPE_REFERENCE {
                    dst.push_str("(*");
                    let ok0 = self.emit_operand(b, opid, dst);
                    dst.push_str(")");
                    return ok0;
                }
            }
            return self.emit_operand(b, opid, dst);
        }
        let aty = b.operands.at(opid as usize).ty;
        let mut rm = b.module;
        let mut rt = aty;
        self.rty(b, aty, &mut rm, &mut rt);
        let mut ay = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut through_ref = false;
        if ay.kind == TypeKind::TYPE_REFERENCE || ay.kind == TypeKind::TYPE_POINTER {
            // A reference arg may still need the Box hop: peel one level and check.
            let mut em2 = rm;
            let mut et2 = ay.as_data.elem;
            if self.mg.resolve(rm, ay.as_data.elem, &mut em2, &mut et2) {
                let ey = *unsafe (*self.p().module_ast_const(em2)).type_at(et2);
                if ey.kind == TypeKind::TYPE_INSTANCE {
                    rm = em2;
                    rt = et2;
                    ay = ey;
                    through_ref = true;
                } else {
                    return self.emit_operand(b, opid, dst);
                }
            } else {
                return self.emit_operand(b, opid, dst);
            }
        }
        // Box<T> receivers deref through their owning pointer.
        if ay.kind == TypeKind::TYPE_INSTANCE {
            let a2 = self.p().module_ast_const(rm);
            let it = *unsafe (*a2).instance(ay.as_data.inst);
            if !param_box && self.agg_name(it.module, it.decl) == "Box" {
                let ok = self.emit_operand(b, opid, dst);
                dst.push_str(mbe::if_s(through_ref, "->ptr", ".ptr"));
                return ok;
            }
        }
        if through_ref {
            // An ordinary reference arg passes through.
            return self.emit_operand(b, opid, dst);
        }
        if !self.is_unit(b, aty) && self.erased(b, aty) {
            // A zero-sized receiver/argument taken by reference: no storage exists, so its
            // auto-ref binds to the aligned sentinel.
            return self.zst_sentinel_ref(rm, rt, dst);
        }
        dst.push_str("&");
        return self.emit_operand(b, opid, dst);
    }

    // Unit-typed data carries no C: TYPE_NONE or the void builtin (what generic unit
    // instantiations resolve to).
    fn is_unit(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return true;
        }
        let y = self.rty_y(b, t);
        if y.kind == TypeKind::TYPE_NEVER {
            // Never-typed temps hold no value (their writers do not return).
            return true;
        }
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
    }

    // A body value with no C storage: unit-like (no value exists) or zero-sized (the value exists
    // but its storage is elided). Both suppress locals, loads, stores, and data movement; a ZST
    // additionally keeps its effects and drops, and its references bind to the aligned sentinel.
    // Raw-kind fast paths keep the (memoized) resolve+layout off scalar and pointer values.
    fn erased(self: &mut Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return true;
        }
        let y = *unsafe (*self.p().module_ast_const(b.module)).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return y.as_data.builtin == BuiltinType::BT_VOID;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION || y.kind == TypeKind::TYPE_DYN {
            return false;
        }
        if y.kind == TypeKind::TYPE_NEVER {
            return true;
        }
        if self.mg.macro_on {
            return false;
        }
        return (self.mg.zclass(b.module, t) & 6) != 0;
    }

    /// Demand the sentinel byte for `align` and spell its name. One byte per alignment program-
    /// wide; every ZST reference of that alignment shares its address.
    pub fn sentinel(self: &mut Self, align: u64, dst: &mut String) {
        let fresh = !self.sent_seen.contains(&align);
        if self.mg.rec_on && self.mg.rec_dup_once(align ^ 18) {
            let mut ev = mbe::RecEv::blank(mbe::RK_ZST);
            ev.a = align as u32;
            self.mg.rec.push(ev);
        }
        if fresh {
            self.sent_seen.insert(align);
            self.sent_decls.push_str("extern unsigned char __sc_zst_");
            self.sent_decls.push_u64(align);
            self.sent_decls.push_str(";\n");
            if align > 1 {
                self.sent_defs.push_str("_Alignas(");
                self.sent_defs.push_u64(align);
                self.sent_defs.push_str(") ");
            }
            self.sent_defs.push_str("unsigned char __sc_zst_");
            self.sent_defs.push_u64(align);
            self.sent_defs.push_str(";\n");
            if self.sh_on {
                self.sh_sent_k.push(align);
                self.sh_sent_e.push(self.sent_decls.len() as u32);
                self.sh_sent_e2.push(self.sent_defs.len() as u32);
            }
        }
        dst.push_str("__sc_zst_");
        dst.push_u64(align);
    }

    /// A reference to a zero-sized value of resolved type `(rm, rt)`: the aligned sentinel as
    /// `void *` (C converts it implicitly to any object-pointer type, so no per-type cast spelling
    /// is needed; ZST loads and stores never dereference it).
    pub fn zst_sentinel_ref(self: &mut Self, rm: ModuleId, rt: TypeId, dst: &mut String) bool {
        let lo = self.mg.layout_sub(rm, rt);
        let mut a9: u64 = 1;
        if lo.ok && lo.align > 1 {
            a9 = lo.align;
        }
        dst.push_str("((void *)&");
        self.sentinel(a9, dst);
        dst.push_str(")");
        return true;
    }

    // Resolve `(b.module, t)` through the substitution env (identity when unbound).
    fn rty(self: &Self, b: &ir::CoreBody, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) {
        if !self.mg.resolve(b.module, t, rm, rt) {
            *rm = b.module;
            *rt = t;
        }
    }

    // The resolved type of pool type `(b.module, t)`, copied.
    fn rty_y(self: &Self, b: &ir::CoreBody, t: TypeId) Ty {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        return *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
    }

    // The element count of `(b.module, t)` when it resolves to an array (a symbolic length folded
    // under the active substitutions); -1 for any other type or a length that does not fold.
    fn arr_n(self: &Self, b: &ir::CoreBody, t: TypeId) i64 {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind != TypeKind::TYPE_ARRAY {
            return -1;
        }
        return self.mg.arr_len(rm, &y);
    }

    // Open a drop statement: guarded (`if (_N) { `) when the rewrite's move flag rides args_start.
    fn open_drop_guard(o: &mut String, t: &ir::Terminator) {
        o.push_str("  ");
        if t.args_len == 1 {
            o.push_str("if (_");
            o.push_u64(t.args_start);
            o.push_str(") { ");
        }
    }

    // The number of return slots with a C carrier (zero-sized results have none).
    fn stored_returns(self: &mut Self, b: &ir::CoreBody) u32 {
        let mut n: u32 = 0;
        for r in 0..b.returns {
            if !self.erased(b, b.locals.at(r as usize).ty) {
                n += 1;
            }
        }
        return n;
    }

    // Does drop terminator `t` emit no code? A generic body is elaborated once, so a value of a type
    // parameter (or of an aggregate over one) gets its drop scheduled for every instance; the instance
    // whose concrete type owns nothing (a scalar, a reference, a plain struct) drops as pure control
    // flow. A drop of a concrete type was scheduled because that type owns, and frees something
    // unless every owning member is a zero-length array (it moves, but holds no element). An explicit
    // `.free()` through a pointer frees the pointee: never a no-op.
    fn drop_emits_nothing(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let pl = *b.places.at(t.a as usize);
        let a = self.p().module_ast_const(b.module);
        let uk = unsafe (*a).type_at(pl.ty).kind;
        if uk == TypeKind::TYPE_POINTER || uk == TypeKind::TYPE_REFERENCE {
            return false;
        }
        if unsafe (*a).type_concrete(pl.ty) {
            return !self.is_destructible(b.module, pl.ty);
        }
        let mut rm = b.module;
        let mut rt = pl.ty;
        self.rty(b, pl.ty, &mut rm, &mut rt);
        let rk = unsafe (*self.p().module_ast_const(rm)).type_at(rt).kind;
        if rk == TypeKind::TYPE_POINTER || rk == TypeKind::TYPE_REFERENCE {
            return true;
        }
        return !self.is_destructible(rm, rt);
    }

    const fn agg_module_res(self: &Self, rm: ModuleId, rt: TypeId) ModuleId {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return unsafe (*a).instance(y.as_data.inst).module;
        }
        return y.module;
    }
    const fn agg_decl_res(self: &Self, rm: ModuleId, rt: TypeId) NodeId {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return unsafe (*a).instance(y.as_data.inst).decl;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.as_data.decl;
        }
        return NODE_NONE;
    }

    // The module whose ast declares the aggregate behind pool type `(b.module, t)` (instances
    // answer their owner), which spells member and variant names.
    fn agg_module(self: &Self, b: &ir::CoreBody, t: TypeId) ModuleId {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        return self.agg_module_res(rm, rt);
    }

    // The aggregate DECL node behind pool type `(b.module, t)` (instances answer the generic decl).
    fn agg_decl(self: &Self, b: &ir::CoreBody, t: TypeId) NodeId {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        return self.agg_decl_res(rm, rt);
    }

    /// Emit `b` as one C function named `name` into the shared buffer. False (with `err`) when the
    /// body leaves the portable subset; the buffer then holds no partial function.
    pub fn emit_fn(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.err = "";
        if self.inst_depth() > INST_DEPTH_MAX {
            self.err = inst_depth_why();
            self.refuse(b);
            return false;
        }
        let mark = self.out.len();
        let pm = self.pr.start();
        let d0 = self.pr.ns[prb::P_DECL];
        let a0 = self.pr.an[prb::P_DECL];
        let b0 = self.pr.ab[prb::P_DECL];
        let ok = self.emit_fn_inner(b, name);
        self.pr.stop_less(prb::P_RENDER, pm, prb::P_DECL, d0, a0, b0);
        self.noret = false;
        return self.close_body(b, mark, ok);
    }

    // Keep a rendered body (counted) or drop its partial output and report the refusal.
    fn close_body(self: &mut Self, b: &ir::CoreBody, mark: usize, ok: bool) bool {
        if !ok {
            self.out.truncate(mark);
            self.refuse(b);
            return false;
        }
        self.pr.count(prb::C_BODIES, 1);
        self.pr.count(prb::C_OUT_BYTES, (self.out.len() - mark) as u64);
        return true;
    }

    // The number of nested instantiations the active substitution chain holds: the binds of one
    // level share one `lim`, the chain length before that level.
    fn inst_depth(self: &Self) u32 {
        let mut n: u32 = 0;
        for i in 0..self.mg.subs.len() {
            if i == 0 || self.mg.subs.at(i).lim != self.mg.subs.at(i - 1).lim {
                n += 1;
            }
        }
        return n;
    }

    fn refuse(self: &mut Self, b: &ir::CoreBody) {
        let mut m = b.module;
        let mut sp = if b.locals.len() != 0 {
            b.locals.at(0).span;
        } else {
            b.blocks.at(b.entry as usize).term.span;
        };
        if self.err == inst_depth_why() && self.is_std(m) {
            // A growing chain refused inside std is the user's error: report it at the outermost
            // generic parameter the user's code declares in the chain.
            for i in 0..self.mg.subs.len() {
                let sb = *self.mg.subs.at(i);
                if !self.is_std(sb.pm) {
                    m = sb.pm;
                    sp = unsafe (*self.p().module_ast_const(m)).at_const(sb.pnode).span;
                    break;
                }
            }
        }
        self.refused.push(Refusal { m: m, start: sp.start, end: sp.end, why: self.err });
    }

    // Whether module `m` belongs to the standard library.
    const fn is_std(self: &Self, m: ModuleId) bool {
        let md = self.p().modules.at(m as usize);
        return md.prelude || md.path.as_str().starts_with("std::");
    }

    /// Finish a function declarator in `o`: the result type `(m, t)` spelled `o[mark..decl]` (then one
    /// space) precedes the declarator `o[decl..]`, unless C spells that type around the name (a
    /// pointer to an array or to a function: `T (*f(void))[N]`); it is then spelled again, around
    /// the declarator.
    fn fn_decl(self: &mut Self, m: ModuleId, t: TypeId, mark: usize, decl: usize, o: &mut String) bool {
        let rs = o.as_str().slice(mark, decl - 1);
        if !rs.ends_with(")") && !rs.ends_with("]") {
            return true;
        }
        let mut d = self.sget();
        d.push_str(o.as_str().slice(decl, o.len()));
        o.truncate(mark);
        let ok = self.mg.ctype(m, t, d.as_str(), o);
        self.sput(d);
        return ok;
    }

    // Close the `<name>_ret` typedef in `aux` (owned by module `m`) and open the signature
    // `<name>_ret <name>(`.
    fn close_ret_typedef(self: &mut Self, m: ModuleId, name: str) {
        self.aux.push_str(" ");
        self.aux.push_str(name);
        self.aux.push_str("_ret;\n");
        self.aux_mark(0, m);
        self.out.push_str(name);
        self.out.push_str("_ret ");
        self.out.push_str(name);
        self.out.push_str("(");
    }

    fn emit_fn_inner(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.arr_ret = false;
        // A plain function has no captured locals.
        self.cap_on = false;
        let dm = self.pr.start();
        self.setup_locals(b);
        self.pr.stop(prb::P_DECL, dm);
        let mut ok0 = true;
        // The single result's spelling spans `hmark..hdecl` of `out`; `fn_decl` wraps it around the
        // finished declarator when C needs that.
        let mut hmark: usize = 0;
        let mut hdecl: usize = 0;
        let mut hty = TYPE_NONE;
        if self.fn_attrs.len() != 0 {
            self.out.push_string(&self.fn_attrs);
        }
        if b.returns > 1 {
            // multi-return: `typedef struct { <t> _0; ... } <name>_ret;` + struct-returning sig.
            // Zero-sized results take no member (their semantic `_N` names survive on the stored
            // ones); a pack with NO stored member returns C void.
            let rmat = self.stored_returns(b);
            if rmat == 0 {
                self.out.push_str("void ");
                self.out.push_str(name);
                self.out.push_str("(");
            } else {
                // `<name>_ret` names the result pack every function and function pointer with
                // these results returns (`Mangler::ret_pack`); the prototype header includes its
                // definition, which callers need complete.
                let mut tys = Vector::<TypeId>::new();
                for r in 0..b.returns {
                    tys.push(b.locals.at(r as usize).ty);
                }
                let mut pk = self.sget();
                if !self.mg.ret_pack(b.module, &tys, &mut pk) {
                    self.sput(pk);
                    return self.fail("ctype");
                }
                self.aux.push_str("typedef struct ");
                self.aux.push_string(&pk);
                self.hdr_dep(b.module, pk.as_str());
                self.sput(pk);
                self.close_ret_typedef(b.module, name);
                self.mret.truncate(0);
                self.mret.push_str(name);
                self.mret.push_str("_ret");
            }
        } else {
            let mut rty = TYPE_NONE;
            if b.returns == 1 {
                rty = b.locals.at(0).ty;
            }
            // A fixed array returned by value returns in its carrier (C cannot return arrays),
            // named `<name>_ret` here (`Mangler::ret_pack`).
            if rty != TYPE_NONE {
                self.arr_ret = self.arr_n(b, rty) > 0;
            }
            if self.arr_ret {
                let mut tys = Vector::<TypeId>::new();
                tys.push(rty);
                let mut pk = self.sget();
                if !self.mg.ret_pack(b.module, &tys, &mut pk) {
                    self.sput(pk);
                    return self.fail("ctype");
                }
                self.aux.push_str("typedef struct ");
                self.aux.push_string(&pk);
                self.hdr_dep(b.module, pk.as_str());
                self.sput(pk);
                self.close_ret_typedef(b.module, name);
                self.mret.truncate(0);
                self.mret.push_str(name);
                self.mret.push_str("_ret");
            } else {
                if self.noret {
                    self.out.push_str("_Noreturn ");
                }
                if rty != TYPE_NONE && self.erased(b, rty) {
                    // Zero-sized results have no C carrier.
                    rty = TYPE_NONE;
                }
                hmark = self.out.len();
                let mut out = replace(&mut self.out, String::new());
                ok0 = self.ty_c(b.module, rty, "", &mut out);
                self.out = out;
                self.out.push_str(" ");
                hdecl = self.out.len();
                self.out.push_str(name);
                self.out.push_str("(");
                hty = rty;
            }
        }
        if !ok0 {
            return false;
        }
        let mut arrcp = Vector::<u32>::new();
        let mut np9: u32 = 0;
        for i in 0..b.args {
            let l = (b.returns + i) as usize;
            if self.erased(b, b.locals.at(l).ty) {
                // Zero-sized by-value params take no C parameter.
                continue;
            }
            if np9 != 0 {
                self.out.push_str(", ");
            }
            np9 += 1;
            let mut nm = self.sget();
            // A `&mut T` is exclusive for the whole call: `restrict` lets C keep its referent's
            // fields in registers across stores through other pointers.
            let py = self.rty_y(b, b.locals.at(l).ty);
            if py.kind == TypeKind::TYPE_REFERENCE && py.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                nm.push_str("restrict ");
            }
            self.lspell(l as u32, &mut nm);
            // A `mut` fixed-array VALUE param: C hands a pointer to the caller's array, so the
            // body works on an entry copy (writes must not reach the caller).
            {
                if b.locals.at(l).is_mutable && self.arr_n(b, b.locals.at(l).ty) > 0 {
                    nm.push_str("_p");
                    arrcp.push(l as u32);
                }
            }
            let mut out = replace(&mut self.out, String::new());
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut out);
            self.out = out;
            self.sput(nm);
            if !ok {
                return false;
            }
        }
        if np9 == 0 {
            self.out.push_str("void");
        }
        {
            // A DEFINED variadic keeps its `...` tail (va_start in a fixed-args fn is a C error).
            let on9 = unsafe (*self.p().module_ast_const(b.owner.module)).at_const(b.owner.node);
            if on9.kind == NodeKind::NODE_FUNCTION && on9.as_data.function.is_variadic() && np9 != 0 {
                self.out.push_str(", ...");
            }
        }
        self.out.push_str(")");
        if hdecl != 0 {
            let mut out = replace(&mut self.out, String::new());
            let okd = self.fn_decl(b.module, hty, hmark, hdecl, &mut out);
            self.out = out;
            if !okd {
                return false;
            }
        }
        self.out.push_str(" {\n");
        for k in 0..arrcp.len() {
            let l = arrcp[k];
            let mut nm2 = String::new();
            self.lspell(l, &mut nm2);
            let mut ts2 = String::new();
            if !self.ty_c(b.module, b.locals.at(l as usize).ty, nm2.as_str(), &mut ts2) {
                return false;
            }
            self.out.push_str("  ");
            self.out.push_string(&ts2);
            self.out.push_str(";\n  memcpy(&");
            self.out.push_string(&nm2);
            self.out.push_str(", ");
            self.out.push_string(&nm2);
            self.out.push_str("_p, sizeof(");
            self.out.push_string(&nm2);
            self.out.push_str("));\n");
        }
        return self.emit_body_core(b);
    }

    // A name that would collide with the `_N` temp spelling: `_` followed by only digits.
    const fn templike(s: str) bool {
        if s.len() < 2 || s.byte_at(0) != 95 {
            return false;
        }
        for i in 1..s.len() {
            let c = s.byte_at(i);
            if c < 48 || c > 57 {
                return false;
            }
        }
        return true;
    }

    // Count one reference to place `pid`'s base into refs (and a definition into defs when it is a
    // whole-local assignment target).
    fn count_place(
        self: &Self,
        b: &ir::CoreBody,
        pid: ir::PlaceId,
        is_def: bool,
        refs: &mut Vector<u32>,
        defs: &mut Vector<u32>,
    ) {
        let pl = *b.places.at(pid as usize);
        refs.set(pl.base as usize, *refs.at(pl.base as usize) + 1);
        if is_def && pl.proj_len == 0 {
            defs.set(pl.base as usize, *defs.at(pl.base as usize) + 1);
        }
    }

    // A rvalue with no side effect: its store can be dropped when the destination is never read.
    const fn pure_rvalue(k: u8) bool {
        return k == ir::RV_USE || k == ir::RV_UNARY || k == ir::RV_BINARY || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT || k == ir::RV_REPEAT || k == ir::RV_AGGREGATE;
    }

    // One pass over the body for every per-local counter: reference/definition counts (never
    // under-counting a use, so a coalesce guarded by `refs[src] == 1` is safe), use counts, read
    // counts (a taken address counts; over-counting only keeps more locals live), and the
    // hard-write flag (a whole-local write whose value must land: a call destination or a
    // side-effecting rvalue). A local with no reads and no hard write is dead.
    fn count_all(
        self: &mut Self,
        b: &ir::CoreBody,
        refs: &mut Vector<u32>,
        defs: &mut Vector<u32>,
        uses: &mut Vector<u32>,
        reads: &mut Vector<u32>,
        hardw: &mut Vector<bool>,
    ) {
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                self.count_place(b, op.data, false, refs, defs);
                let base = b.places.at(op.data as usize).base as usize;
                uses.set(base, *uses.at(base) + 1);
                reads.set(base, *reads.at(base) + 1);
            }
        }
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind == ir::ST_ASSIGN {
                self.count_place(b, s.place, true, refs, defs);
                let pl = *b.places.at(s.place as usize);
                let rv = *b.rvalues.at(s.rvalue as usize);
                if pl.proj_len != 0 {
                    reads.set(pl.base as usize, *reads.at(pl.base as usize) + 1);
                } else if !CEmit::pure_rvalue(rv.kind) {
                    hardw.set(pl.base as usize, true);
                }
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                    self.count_place(b, rv.a, false, refs, defs);
                    let rb = b.places.at(rv.a as usize).base as usize;
                    reads.set(rb, *reads.at(rb) + 1);
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_DROP && !self.drop_emits_nothing(b, &t) {
                self.count_place(b, t.a, false, refs, defs);
                reads.set(
                    b.places.at(t.a as usize).base as usize,
                    *reads.at(b.places.at(t.a as usize).base as usize) + 1,
                );
                if t.args_len == 1 {
                    // A guarded drop reads its move flag (a local carried on args_start, not a place).
                    reads.set(t.args_start as usize, *reads.at(t.args_start as usize) + 1);
                }
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    self.count_place(b, b.dest_pool[(t.dests_start + d) as usize], true, refs, defs);
                    let pl = *b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize);
                    if pl.proj_len != 0 {
                        reads.set(pl.base as usize, *reads.at(pl.base as usize) + 1);
                    } else {
                        hardw.set(pl.base as usize, true);
                    }
                }
            }
        }
    }

    // Reserve the source name of item `node` (a referenced function/const/type/variant): a local
    // reusing it would hide the global.
    fn reserve_item(self: &mut Self, m: ModuleId, node: NodeId) {
        if node == NODE_NONE {
            return;
        }
        let a = self.p().module_ast_const(m);
        let nd = unsafe (*a).at_const(node);
        let mut nn = NODE_NONE;
        if nd.kind == NodeKind::NODE_FUNCTION {
            nn = nd.as_data.function.name;
        } else if nd.kind == NodeKind::NODE_CONST {
            nn = nd.as_data.const_def.name;
        } else if nd.kind == NodeKind::NODE_STRUCT || nd.kind == NodeKind::NODE_ENUM {
            nn = nd.as_data.aggregate.name;
        } else if nd.kind == NodeKind::NODE_VARIANT {
            nn = nd.as_data.variant.name;
        }
        if nn == NODE_NONE {
            return;
        }
        let sp = unsafe (*a).at_const(nn).as_data.name.text;
        let mut s = self.sget();
        self.mg.ident(m, sp, &mut s);
        self.sx_reserved.insert(s.as_str().hash(), 1);
        self.sput(s);
    }

    fn same_local_type(self: &Self, b: &ir::CoreBody, a: TypeId, c: TypeId) bool {
        let mut am = b.module;
        let mut at = a;
        self.rty(b, a, &mut am, &mut at);
        let mut cm = b.module;
        let mut ct = c;
        self.rty(b, c, &mut cm, &mut ct);
        if am == cm && at == ct {
            return true;
        }
        let ay = *unsafe (*self.p().module_ast_const(am)).type_at(at);
        let cy = *unsafe (*self.p().module_ast_const(cm)).type_at(ct);
        if ay.kind != TypeKind::TYPE_ARRAY || cy.kind != TypeKind::TYPE_ARRAY || self.mg.arr_len(am, &ay) != self.mg.arr_len(
            cm,
            &cy,
        ) {
            return false;
        }
        let mut aem = am;
        let mut aet = ay.as_data.elem;
        let _ = self.mg.resolve(am, ay.as_data.elem, &mut aem, &mut aet);
        let mut cem = cm;
        let mut cet = cy.as_data.elem;
        let _ = self.mg.resolve(cm, cy.as_data.elem, &mut cem, &mut cet);
        return aem == cem && aet == cet;
    }

    fn coal_type_compatible(self: &Self, b: &ir::CoreBody, dst: TypeId, src: TypeId, slocal: u32) bool {
        if self.same_local_type(b, dst, src) {
            return true;
        }
        let mut dm = b.module;
        let mut dt = dst;
        self.rty(b, dst, &mut dm, &mut dt);
        let mut sm = b.module;
        let mut st = src;
        self.rty(b, src, &mut sm, &mut st);
        let dy = *unsafe (*self.p().module_ast_const(dm)).type_at(dt);
        let sy = *unsafe (*self.p().module_ast_const(sm)).type_at(st);
        if dy.kind != TypeKind::TYPE_ARRAY || sy.kind != TypeKind::TYPE_ARRAY || self.mg.arr_len(dm, &dy) <= 0 || self.filled_len(
            b,
            slocal,
        ) > self.mg.arr_len(dm, &dy) as u64 {
            return false;
        }
        let mut dem = dm;
        let mut det = dy.as_data.elem;
        let _ = self.mg.resolve(dm, dy.as_data.elem, &mut dem, &mut det);
        let mut sem = sm;
        let mut set = sy.as_data.elem;
        let _ = self.mg.resolve(sm, sy.as_data.elem, &mut sem, &mut set);
        return dem == sem && det == set;
    }

    // The source is defined immediately before this copy, apart from storage markers. `start` is
    // the first statement of the copy's block (ir::IR_NONE when no block holds it).
    fn adjacent_copy_source(self: &Self, b: &ir::CoreBody, copy: usize, start: u32, source: u32) bool {
        if start == ir::IR_NONE {
            return false;
        }
        let mut i = copy;
        while i > start as usize {
            i -= 1;
            let s = *b.statements.at(i);
            if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
                continue;
            }
            if s.kind != ir::ST_ASSIGN {
                return false;
            }
            let pl = *b.places.at(s.place as usize);
            return pl.base == source && pl.proj_len == 0;
        }
        return false;
    }

    // Rebuild the per-body local spelling: transparent-move coalescing, then preserved user names.
    // `_dst = move _src` where the source is used nowhere else and the destination is defined only
    // there shares one C variable (`_dst` never declares, its assignment never emits). Named user
    // parameters and locals keep their source spelling, C keywords and collisions disambiguated;
    // temporaries and return slots stay `_N`.
    fn setup_locals(self: &mut Self, b: &ir::CoreBody) {
        let n = b.locals.len();
        self.ml_ch.clear();
        self.ml_chunks.clear();
        self.ml_alias.clear();
        self.ml_cnt.clear();
        self.ml_def.clear();
        self.ml_use.clear();
        self.wx_on = false;
        self.sx_coal.clear();
        self.sx_nm_pool.clear();
        self.sx_nm_off.clear();
        self.sx_nm_len.clear();
        for l in 0..n {
            self.sx_coal.push(l as u32);
        }
        let mut refs = self.uget();
        let mut defs = self.uget();
        let mut uses = self.uget();
        let mut coal_root = self.bget();
        let mut reads = self.uget();
        let mut hardw = self.bget();
        refs.resize_default(n);
        defs.resize_default(n);
        uses.resize_default(n);
        coal_root.resize_default(n);
        reads.resize_default(n);
        hardw.resize_default(n);
        self.count_all(b, &mut refs, &mut defs, &mut uses, &mut reads, &mut hardw);
        // First statement of each statement's block, built on the first mutable binding copy.
        let mut stmt_block = Vector::<u32>::new();
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.proj_len != 0 || pl.base as usize < b.returns as usize {
                continue;
            }
            let dstore = b.locals.at(pl.base as usize).storage;
            if dstore != ir::LS_USER && dstore != ir::LS_TEMP {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind != ir::RV_USE {
                continue;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind != ir::OP_MOVE && op.kind != ir::OP_COPY {
                continue;
            }
            let sp = *b.places.at(op.data as usize);
            if sp.proj_len != 0 || sp.base == pl.base {
                continue;
            }
            let ss = b.locals.at(sp.base as usize).storage;
            let tempish = sp.base as usize >= b.returns as usize && ss != ir::LS_ARG && ss != ir::LS_STATIC_REF && b.locals.at(
                sp.base as usize,
            ).decl == NODE_NONE;
            let user_source = ss == ir::LS_USER && b.locals.at(sp.base as usize).decl != NODE_NONE && !b.locals.at(
                sp.base as usize,
            ).is_mutable && dstore == ir::LS_TEMP;
            let mut binding_source = false;
            if ss == ir::LS_USER && dstore == ir::LS_USER && b.locals.at(pl.base as usize).is_mutable {
                if stmt_block.len() == 0 {
                    for _k in 0..b.statements.len() {
                        stmt_block.push(ir::IR_NONE);
                    }
                    for bi in 0..b.blocks.len() {
                        let blk = *b.blocks.at(bi);
                        for k in 0..blk.stmt_len {
                            stmt_block.set((blk.stmt_start + k) as usize, blk.stmt_start);
                        }
                    }
                }
                binding_source = self.adjacent_copy_source(b, si, *stmt_block.at(si), sp.base);
            }
            let inline_pattern_dest = dstore == ir::LS_USER && b.locals.at(pl.base as usize).dkind == ir::LK_PATTERN && *defs.at(
                pl.base as usize,
            ) == 1 && *uses.at(pl.base as usize) == 1;
            // A closure capture is an argument too, but it spells `__env->name`, not a plain local;
            // aliasing a local onto it would lose that env indirection.
            if self.cap_on && ss == ir::LS_ARG && sp.base >= self.cap_base {
                continue;
            }
            // A vector result that the next statement copies into a local assigned again (a loop's
            // accumulator) writes that local itself: no temporary, no copy.
            if tempish && dstore == ir::LS_USER && *defs.at(sp.base as usize) == 1 && *uses.at(sp.base as usize) == 1 && self.vec_forward(
                b,
                si,
                sp.base,
                pl.base,
            ) {
                self.sx_coal.set(sp.base as usize, pl.base);
                coal_root.set(pl.base as usize, true);
                continue;
            }
            if !binding_source && *defs.at(pl.base as usize) != 1 {
                continue;
            }
            if ss == ir::LS_ARG && *refs.at(sp.base as usize) != 1 {
                continue;
            }
            // A temporary is counted once at its definition and once at this sole read.
            if tempish && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1) {
                continue;
            }
            if user_source && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1) {
                continue;
            }
            if binding_source && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1 || *refs.at(
                sp.base as usize,
            ) != 2) {
                continue;
            }
            if ss != ir::LS_ARG && !tempish && !user_source && !binding_source {
                continue;
            }
            let dty = b.locals.at(pl.base as usize).ty;
            let sty = b.locals.at(sp.base as usize).ty;
            let mut types_ok = dty != TYPE_NONE && (sty == TYPE_NONE || self.coal_type_compatible(b, dty, sty, sp.base));
            if dty == TYPE_NONE && sty == TYPE_NONE {
                let mut ds = self.sget();
                let mut ssym = self.sget();
                types_ok = self.untyped_ret_struct(b, pl.base, &mut ds) && self.untyped_ret_struct(
                    b,
                    sp.base,
                    &mut ssym,
                ) && ds.as_str() == ssym.as_str();
                self.sput(ssym);
                self.sput(ds);
            }
            if !types_ok {
                continue;
            }
            if dty != TYPE_NONE && self.erased(b, dty) {
                continue;
            }
            if binding_source {
                self.sx_coal.set(sp.base as usize, pl.base);
                coal_root.set(pl.base as usize, true);
            } else if ss == ir::LS_ARG {
                self.sx_coal.set(pl.base as usize, sp.base);
            } else if user_source {
                self.sx_coal.set(pl.base as usize, sp.base);
                coal_root.set(sp.base as usize, true);
            } else if tempish && !inline_pattern_dest && *refs.at(pl.base as usize) > *defs.at(pl.base as usize) {
                self.sx_coal.set(sp.base as usize, pl.base);
                coal_root.set(pl.base as usize, true);
            }
        }
        for l in 0..n {
            let mut r = l as u32;
            let mut g: usize = 0;
            while *self.sx_coal.at(r as usize) != r && g <= n {
                r = *self.sx_coal.at(r as usize);
                g += 1;
            }
            self.sx_coal.set(l, r);
        }
        // Every C ordinary-namespace identifier the body references is reserved: a local that reused
        // one would hide it and silently change what a later use means. Collected: the typedef names
        // of every local type, every enum-variant constant the body constructs, and the source names
        // of every function/const/static/type item it names. Over-approximation is safe (it only
        // suffixes more names); the set is a hash set, so collection and lookup are near-linear.
        self.sx_reserved.clear();
        {
            // Bodies repeat a handful of local types; one replay per distinct type is enough
            // (reserve_local_ty only inserts into sx_reserved, which is idempotent).
            self.sx_seen_ty.clear();
            for l in 0..n {
                let ty = b.locals.at(l).ty;
                if ty != TYPE_NONE && !self.sx_seen_ty.contains_key(&(ty as u64)) {
                    self.sx_seen_ty.insert(ty, 1);
                    self.reserve_local_ty(b.module, ty);
                }
                if b.locals.at(l).storage == ir::LS_STATIC_REF {
                    let it = b.locals.at(l).item;
                    self.reserve_item(it.module, it.node);
                }
            }
        }
        for ri in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(ri);
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_VARIANT {
                let edecl = self.agg_decl(b, rv.target);
                if edecl != NODE_NONE {
                    let am = self.agg_module(b, rv.target);
                    let mut tag = self.sget();
                    self.mg.enum_tag(am, edecl, rv.item.node, &mut tag);
                    self.sx_reserved.insert(tag.as_str().hash(), 1);
                    self.sput(tag);
                }
            }
        }
        for ci in 0..b.constants.len() {
            let c = *b.constants.at(ci);
            if c.kind == ir::CK_ITEM {
                self.reserve_item(c.item.module, c.item.node);
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
                // Reserve the EXACT emitted call symbol: the mangled name a generic/method/interface
                // /cross-module call spells (e.g. `id__i32`), which a source name alone misses.
                let mh = if t.targs_len == 0 {
                    self.sym_memo_hash(t.callee);
                } else {
                    0u64;
                };
                if mh != 0 {
                    self.sx_reserved.insert(mh, 1);
                    continue;
                }
                let mut sym = self.sget();
                let saved = self.collect_demand;
                // A probe: a call with no symbol (a dyn dispatch) reserves nothing, and the call
                // site reports its own failures.
                let err0 = self.err;
                self.collect_demand = false;
                let ok = self.term_callee_sym(b, &t, true, &mut sym);
                self.collect_demand = saved;
                self.err = err0;
                if ok {
                    self.sx_reserved.insert(sym.as_str().hash(), 1);
                }
                self.sput(sym);
            }
        }
        // Names: preserve user identifiers, disambiguating keywords, type names, and collisions; the
        // `_<id>` fallback is always free because only local `id` itself ever spells `_<id>`. Already-
        // assigned names live in a hash set, so the whole pass is near-linear.
        self.sx_assigned.clear();
        for l in 0..n {
            let start = self.sx_nm_pool.len();
            if *self.sx_coal.at(l) == l as u32 && l >= b.returns as usize {
                let st = b.locals.at(l).storage;
                if st != ir::LS_TEMP && st != ir::LS_STATIC_REF {
                    let decl = b.locals.at(l).decl;
                    if decl != NODE_NONE {
                        let sp = b.locals.at(l).name();
                        if sp.end > sp.start {
                            self.mg.ident(b.module, sp, &mut self.sx_nm_pool);
                            let nm0 = self.sx_nm_pool.as_str().slice(start, self.sx_nm_pool.len());
                            if CEmit::templike(nm0) || ident_in(nm0, &self.sx_reserved) || self.sx_assigned.contains_key(
                                &nm0.hash(),
                            ) {
                                self.sx_nm_pool.push_str("_");
                                self.sx_nm_pool.push_u64(l as u64);
                                // The suffixed name must clear BOTH sets: `<name>_<id>` can itself be
                                // a reserved symbol or an earlier local's name.
                                let nm1 = self.sx_nm_pool.as_str().slice(start, self.sx_nm_pool.len());
                                if ident_in(nm1, &self.sx_reserved) || self.sx_assigned.contains_key(&nm1.hash()) {
                                    self.sx_nm_pool.truncate(start);
                                }
                            }
                            if self.sx_nm_pool.len() != start {
                                let nm2 = self.sx_nm_pool.as_str().slice(start, self.sx_nm_pool.len());
                                self.sx_assigned.insert(nm2.hash(), 1);
                            }
                        }
                    }
                }
            }
            self.sx_nm_off.push(start as u32);
            self.sx_nm_len.push((self.sx_nm_pool.len() - start) as u32);
        }

        // Liveness for declaration + dead-store removal: a local needs a declaration when it is read
        // (a taken address counts) or written by something that must land in it (a call result or a
        // side-effecting rvalue). Neither -> dead: no declaration, and its pure stores are dropped.
        self.sx_used.clear();
        for l in 0..n {
            self.sx_used.push(*reads.at(l) != 0 || *hardw.at(l));
        }
        self.sx_addr.clear();
        self.sx_addr.resize_default(n);
        for i in 0..b.statements.len() {
            let st = *b.statements.at(i);
            if st.kind == ir::ST_ASSIGN {
                let rv = *b.rvalues.at(st.rvalue as usize);
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
                    self.sx_addr.set(b.places.at(rv.a as usize).base as usize, true);
                }
            }
        }

        self.compute_inline(b, &coal_root);
        self.uput(refs);
        self.uput(defs);
        self.uput(uses);
        self.uput(reads);
        self.bput(coal_root);
        self.bput(hardw);
    }

    /// Append the C spelling of local `l` for the body most recently emitted through `emit_fn`: its
    /// coalesce target's preserved name, or `_<id>`. A driver synthesizing a wrapper reads the
    /// receiver name here instead of parsing emitted text.
    pub fn lspell(self: &Self, l: u32, dst: &mut String) {
        let c = (*self.sx_coal.at(l as usize)) as usize;
        let ln = self.sx_nm_len[c] as usize;
        if ln != 0 {
            let off = self.sx_nm_off[c] as usize;
            dst.push_str(self.sx_nm_pool.as_str().slice(off, off + ln));
        } else {
            dst.push_str("_");
            dst.push_u64(c as u64);
        }
    }

    // Whether this assignment became a no-op self-copy after coalescing (its declaration and store
    // are both elided).
    const fn is_coalesced_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 {
            return false;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        if rv.kind != ir::RV_USE {
            return false;
        }
        let op = *b.operands.at(rv.a as usize);
        if op.kind != ir::OP_MOVE && op.kind != ir::OP_COPY {
            return false;
        }
        let sp = *b.places.at(op.data as usize);
        if sp.proj_len != 0 {
            return false;
        }
        return *self.sx_coal.at(pl.base as usize) == *self.sx_coal.at(sp.base as usize);
    }

    // A store to a dead local (never read, no declaration): its pure rvalue has no side effect, so
    // the whole statement is dropped. Whole-local writes only; the local's liveness (sx_used) already
    // accounts for reads and hard writes, so `!sx_used` here guarantees the rvalue is pure.
    const fn is_dead_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 || pl.base as usize < b.returns as usize {
            return false;
        }
        let st = b.locals.at(pl.base as usize).storage;
        if st == ir::LS_ARG || st == ir::LS_STATIC_REF {
            return false;
        }
        if *self.sx_coal.at(pl.base as usize) != pl.base {
            // Coalesced: handled by is_coalesced_store.
            return false;
        }
        return !*self.sx_used.at(pl.base as usize);
    }

    // Two places name the same storage: identical base and identical projection sequence. A dynamic
    // index compares by its operand id (a conservative match: distinct ids that happen to hold the
    // same value read as different, which only forgoes a rewrite).
    fn places_equal(self: &Self, b: &ir::CoreBody, a: u32, c: u32) bool {
        let pa = *b.places.at(a as usize);
        let pc = *b.places.at(c as usize);
        if pa.base != pc.base || pa.proj_len != pc.proj_len {
            return false;
        }
        for i in 0..pa.proj_len {
            let ja = *b.projections.at((pa.proj_start + i) as usize);
            let jc = *b.projections.at((pc.proj_start + i) as usize);
            if ja.kind != jc.kind || ja.data != jc.data || ja.sub != jc.sub {
                return false;
            }
        }
        return true;
    }

    // The C compound-assignment spelling for a binary operator token, or "" when the operator has no
    // `op=` form (comparisons, logical, equality).
    const fn compound_op(t: tt::TokenType) str<'static> {
        return switch t {
            Plus => "+=",
            Minus => "-=",
            Star => "*=",
            Slash => "/=",
            Percent => "%=",
            Ampersand => "&=",
            Pipe => "|=",
            Caret => "^=",
            LeftShift => "<<=",
            RightShift => ">>=",
            _ => "",
        };
    }

    // The C operator for a binary token: a compound token spells its base operator, and `&&`/`||`
    // spell `&`/`|` (both operands are already evaluated). "" for any other token.
    const fn c_binop(t: tt::TokenType) str<'static> {
        return switch t {
            Plus | PlusEqual => "+",
            Minus | MinusEqual => "-",
            Star | StarEqual => "*",
            Slash | SlashEqual => "/",
            Percent | PercentEqual => "%",
            Ampersand | AmpersandAmpersand | AmpersandEqual => "&",
            Pipe | PipePipe | PipeEqual => "|",
            Caret | CaretEqual => "^",
            LeftShift | LeftShiftEqual => "<<",
            RightShift | RightShiftEqual => ">>",
            EqualEqual => "==",
            BangEqual => "!=",
            LessThan => "<",
            LessThanEqual => "<=",
            GreaterThan => ">",
            GreaterThanEqual => ">=",
            _ => "",
        };
    }

    // `x = x op y` reads better as `x op= y`, and evaluates the destination once. Applies only to the
    // scalar C-operator path (aggregates dispatch through a method) when the binary's left operand is
    // the destination place itself. Returns whether it emitted the statement.
    fn try_compound_assign(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        // See through a store of an inlined temporary (`x = _t` where `_t = x op y`): the binary
        // reaches the store directly, so the compound form still applies.
        let mut rvid = s.rvalue;
        let rv0 = *b.rvalues.at(rvid as usize);
        if rv0.kind == ir::RV_USE {
            let op = *b.operands.at(rv0.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let p = *b.places.at(op.data as usize);
                if p.proj_len == 0 && *self.sx_inline.at(p.base as usize) != ir::IR_NONE {
                    rvid = *self.sx_inline.at(p.base as usize);
                }
            }
        }
        let rv = *b.rvalues.at(rvid as usize);
        if rv.kind != ir::RV_BINARY || !self.is_scalar(b, pl.ty) {
            return false;
        }
        let opstr = CEmit::compound_op(rv.c as tt::TokenType);
        let mut abt = BuiltinType::BT_VOID;
        if opstr.len() == 0 || self.arith_fn(b, &rv, &mut abt).len() != 0 {
            return false;
        }
        let la = *b.operands.at(rv.a as usize);
        if la.kind != ir::OP_COPY && la.kind != ir::OP_MOVE {
            return false;
        }
        if !self.places_equal(b, s.place, la.data) {
            return false;
        }
        // Committed: a later failure sets self.err rather than returning false, so the caller does not
        // re-run the general path and double emit_place's collection side effects.
        let mut bm = b.module;
        let mut bt = TYPE_NONE;
        let bref = self.bin_op_ty(b, rv.b, &mut bm, &mut bt);
        o.push_str("  ");
        if self.emit_place(b, s.place, o) {
            o.push_str(" ");
            o.push_str(opstr);
            o.push_str(" ");
            let _ = self.emit_op_d(b, rv.b, bref, o);
        }
        o.push_str(";\n");
        return true;
    }

    // The whole-local definition of an inlined temporary: its statement is skipped, the rvalue
    // reappears at the single read (emit_operand). Whole-local writes only.
    const fn is_inlined_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        return pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE;
    }

    // A scalar type: builtin (int/bool/float), pointer, or reference. Only scalar temporaries
    // inline: an aggregate operand is taken by address in the equality/ordering/overload dispatch
    // paths, and C forbids the address of a materialized rvalue. Scalars are never address-taken in
    // a statement right-hand side or switch discriminant, so folding them is always spellable.
    fn is_scalar(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = self.rty_y(b, t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            return true;
        }
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin != BuiltinType::BT_VOID;
    }

    // Pure, scalar rvalue kinds whose result is a self-contained C expression (parenthesized or
    // atomic), so folding one into its single use never reorders evaluation or breaks precedence.
    const fn inlinable_def_kind(k: u8) bool {
        return k == ir::RV_USE || k == ir::RV_UNARY || k == ir::RV_BINARY || k == ir::RV_CAST || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT;
    }

    // `IN_LIKELY(x)`: pure, one operand, spelled as one call expression. It must fold into the
    // branch that tests it: clang drops a `__builtin_expect` whose result passes through a variable.
    const fn is_likely(rv: &ir::Rvalue) bool {
        return rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_LIKELY;
    }

    // Whether operand `opid` reads local `l` through no projection (a whole-local copy/move).
    const fn op_is_bare_local(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        return pl.proj_len == 0 && pl.base == l;
    }

    // A call returning a pointer/reference can also fold through one direct dereference: `_p = f();
    // x = *_p` becomes `x = *f()`. No field/index chain is accepted here.
    const fn op_is_deref_local(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        return pl.base == l && pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF;
    }

    const fn op_is_call_use(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        return self.op_is_bare_local(b, opid, l) || self.op_is_deref_local(b, opid, l);
    }

    // Whether rvalue `rid` reads local `l` as a bare operand: the adjacency probe for the one
    // statement that immediately follows an inline candidate's definition.
    fn rvalue_reads_local_bare(self: &Self, b: &ir::CoreBody, rid: u32, l: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
            return self.op_is_bare_local(b, rv.a, l);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_bare_local(b, rv.a, l) || self.op_is_bare_local(b, rv.b, l);
        }
        if CEmit::is_likely(&rv) {
            return self.op_is_bare_local(b, b.oper_pool[rv.a as usize], l);
        }
        if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE || rv.kind == ir::RV_SIMD {
            // B is a genuine operand count here (RV_INTRINSIC overloads b as a TypeId, so it is
            // excluded; a temp used only inside an intrinsic stays declared, which is safe).
            for i in 0..rv.b {
                if self.op_is_bare_local(b, b.oper_pool[(rv.a + i) as usize], l) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    const fn rvalue_reads_call_use(self: &Self, b: &ir::CoreBody, rid: u32, l: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
            return self.op_is_call_use(b, rv.a, l);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_call_use(b, rv.a, l) || self.op_is_call_use(b, rv.b, l);
        }
        return false;
    }

    // Whether operand `opid` reads local `base` through any projection (a whole or field/element read).
    const fn op_reads_base(self: &Self, b: &ir::CoreBody, opid: u32, base: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        return b.places.at(op.data as usize).base == base;
    }

    // Whether an inlinable-kind rvalue reads local `base` (as an operand or the place it projects
    // from), which tests whether a statement between a temp's definition and its use writes one of
    // the definition's inputs.
    fn rvalue_reads_base(self: &Self, b: &ir::CoreBody, rid: u32, base: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return self.op_reads_base(b, rv.a, base);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_reads_base(b, rv.a, base) || self.op_reads_base(b, rv.b, base);
        }
        if CEmit::is_likely(&rv) {
            return self.op_reads_base(b, b.oper_pool[rv.a as usize], base);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            return b.places.at(rv.a as usize).base == base;
        }
        if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                if self.op_reads_base(b, b.oper_pool[(rv.a + i) as usize], base) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    // Whether an operand reads through a projection (dereference, field, or index), so it reads
    // memory rather than a whole local value.
    const fn op_is_projected(self: &Self, b: &ir::CoreBody, opid: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        return b.places.at(op.data as usize).proj_len > 0;
    }

    // Whether an inlinable-kind rvalue reads memory (any projected operand or projected place-read).
    // A memory-reading definition cannot be folded across a store that might alias that memory.
    fn rvalue_reads_mem(self: &Self, b: &ir::CoreBody, rid: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return self.op_is_projected(b, rv.a);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_projected(b, rv.a) || self.op_is_projected(b, rv.b);
        }
        if CEmit::is_likely(&rv) {
            return self.op_is_projected(b, b.oper_pool[rv.a as usize]);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            return b.places.at(rv.a as usize).proj_len > 0;
        }
        if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                if self.op_is_projected(b, b.oper_pool[(rv.a + i) as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    // Whether operand `opid` is a bare whole-local read of a mem-tainted local.
    const fn op_taints(self: &Self, b: &ir::CoreBody, opid: u32, taint: &Vector<bool>) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        return pl.proj_len == 0 && taint[pl.base as usize];
    }

    // Whether an inlinable-kind rvalue reads a mem-tainted local through a bare operand (the one
    // link shape whose fold relays the operand's spelled expression).
    fn rvalue_reads_tainted(self: &Self, b: &ir::CoreBody, rid: u32, taint: &Vector<bool>) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return self.op_taints(b, rv.a, taint);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_taints(b, rv.a, taint) || self.op_taints(b, rv.b, taint);
        }
        if CEmit::is_likely(&rv) {
            return self.op_taints(b, b.oper_pool[rv.a as usize], taint);
        }
        if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                if self.op_taints(b, b.oper_pool[(rv.a + i) as usize], taint) {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether statement `s`, sitting between a single-use temp's definition (rvalue `def_rv`, which
    // reads memory iff `reads_mem`) and its read, leaves that definition's value unchanged, so the
    // definition may fold past it. Safe when: a marker, or a pure whole/projected store that neither
    // writes an input the definition reads nor writes memory the definition depends on. Any effecting
    // statement (asm, allocation) blocks it.
    fn inline_safe_between(self: &Self, b: &ir::CoreBody, s: &ir::Statement, def_rv: u32, reads_mem: bool) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
            return true;
        }
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        if b.rvalues.at(s.rvalue as usize).kind == ir::RV_INTRINSIC || b.rvalues.at(s.rvalue as usize).kind == ir::RV_SIMD {
            // Asm/new/safepoint and a vector store carry an effect, a vector load reads memory.
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        if self.rvalue_reads_base(b, def_rv, pl.base) {
            // Writes a local the definition reads.
            return false;
        }
        if pl.proj_len != 0 && reads_mem {
            // A projected store may alias the definition's memory.
            return false;
        }
        return true;
    }

    // Select single-use pure temporaries whose one read is adjacent to their definition (nothing
    // executes between them) so the definition can be dropped and its rvalue spelled at the read.
    // Conservative by construction: any projected use, taken address, extra write, non-pure producer,
    // or non-adjacent read leaves the local as an ordinary declared temporary. Near-linear: one
    // operand pass, one statement/terminator pass, then a per-candidate look-ahead of at most
    // INLINE_LOOKAHEAD statements (a read farther away leaves the temporary declared).
    fn compute_inline(self: &mut Self, b: &ir::CoreBody, coal_root: &Vector<bool>) {
        let n = b.locals.len();
        self.sx_inline.clear();
        for _l in 0..n {
            self.sx_inline.push(ir::IR_NONE);
        }
        let mut bare_read = self.uget();
        let mut ndef = self.uget();
        let mut blocked = self.bget();
        let mut def_rv = self.uget();
        let mut def_blk = self.uget();
        let mut def_idx = self.uget();
        bare_read.resize_default(n);
        ndef.resize_default(n);
        blocked.resize_default(n);
        def_idx.resize_default(n);
        for _l in 0..n {
            def_rv.push(ir::IR_NONE);
            def_blk.push(ir::IR_NONE);
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let pl = *b.places.at(op.data as usize);
                if pl.proj_len == 0 {
                    bare_read.set(pl.base as usize, *bare_read.at(pl.base as usize) + 1);
                } else {
                    blocked.set(pl.base as usize, true);
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(s.place as usize);
                    let rv = *b.rvalues.at(s.rvalue as usize);
                    if pl.proj_len == 0 {
                        // A non-array struct/tuple/variant literal folds too (spelled as one compound
                        // literal at its read); array-bearing aggregates keep their element-wise store.
                        let agg_ok = rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_VARIANT) && !self.agg_has_array_field(
                            b,
                            &rv,
                        );
                        // A vector-array cast is a `memcpy` statement (`emit_vec_cast_store`), no expression.
                        let vcast = rv.kind == ir::RV_CAST && rv.b == ir::CAST_SIMD_ARRAY;
                        if CEmit::inlinable_def_kind(rv.kind) && !vcast && !self.vec_rv(b, &rv) || agg_ok || CEmit::is_likely(
                            &rv,
                        ) {
                            ndef.set(pl.base as usize, *ndef.at(pl.base as usize) + 1);
                            def_rv.set(pl.base as usize, s.rvalue);
                            def_blk.set(pl.base as usize, bi as u32);
                            def_idx.set(pl.base as usize, si);
                        } else {
                            blocked.set(pl.base as usize, true);
                        }
                    } else {
                        blocked.set(pl.base as usize, true);
                    }
                    if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                        blocked.set(b.places.at(rv.a as usize).base as usize, true);
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_DROP && !self.drop_emits_nothing(b, &t) {
                blocked.set(b.places.at(t.a as usize).base as usize, true);
                if t.args_len == 1 {
                    blocked.set(t.args_start as usize, true);
                }
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    blocked.set(b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize).base as usize, true);
                }
            }
        }
        // Transitive memory-read taint. Folding is recursive at the SPELL site: a folded local's
        // use spells its definition, which spells ITS folded operands, so a leaf memory read can
        // relocate to the final use across every span only the intermediate links were checked
        // against. Taint every single-def foldable local whose spelled expression may contain a
        // memory read once substitution bottoms out, and use that as the local's reads_mem below.
        // Over-approximates (assumes every eligible link folds): only blocks a fold, never admits.
        let mut mem_taint = self.bget();
        for l in 0..n {
            let single = !*blocked.at(l) && *ndef.at(l) == 1 && *def_rv.at(l) != ir::IR_NONE;
            mem_taint.push(single && self.rvalue_reads_mem(b, *def_rv.at(l)));
        }
        {
            let mut pass = 0;
            let mut changed = true;
            while changed && pass < 8 {
                changed = false;
                pass += 1;
                for l in 0..n {
                    if *mem_taint.at(l) || *blocked.at(l) || *ndef.at(l) != 1 || *def_rv.at(l) == ir::IR_NONE {
                        continue;
                    }
                    if self.rvalue_reads_tainted(b, *def_rv.at(l), &mem_taint) {
                        mem_taint.set(l, true);
                        changed = true;
                    }
                }
            }
            if changed {
                // Deeper chains than the pass bound: give up precision, keep soundness.
                for l in 0..n {
                    if !*blocked.at(l) && *ndef.at(l) == 1 && *def_rv.at(l) != ir::IR_NONE {
                        mem_taint.set(l, true);
                    }
                }
            }
        }
        for l in 0..n {
            let ls = b.locals.at(l).storage;
            let pattern = b.locals.at(l).dkind == ir::LK_PATTERN;
            if ls != ir::LS_TEMP && !(ls == ir::LS_USER && (!b.locals.at(l).is_mutable || pattern)) {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 || l < b.returns as usize {
                continue;
            }
            if *coal_root.at(l) {
                continue;
            }
            if *blocked.at(l) || *ndef.at(l) != 1 || *bare_read.at(l) != 1 {
                continue;
            }
            // a closure capture spells `__env->name`, never a plain local; never fold it. Captures
            // are the trailing arguments [cap_base, returns+args); temporaries come after and DO fold.
            if self.cap_on && l as u32 >= self.cap_base && l as u32 < b.returns + b.args {
                continue;
            }
            // An aggregate operand is taken by address in the equality/ordering/overload dispatch and
            // by-reference call paths, and C forbids the address of a materialized rvalue, so an
            // aggregate temporary folds only into a whole-value copy (`x = _agg`, including a return
            // slot store), never into a comparison, a discriminant test, or a call argument. Scalars
            // are never address-taken in those spots and fold anywhere.
            let scalar = self.is_scalar(b, b.locals.at(l).ty);
            let bd = *def_blk.at(l);
            let di = *def_idx.at(l);
            let blk = *b.blocks.at(bd as usize);
            let drv = *def_rv.at(l);
            let reads_mem = *mem_taint.at(l);
            // Fold the definition forward to its single read, stepping over statements that provably
            // leave the definition's value intact (they neither write an input nor alias its memory).
            // The read is a later statement's operand or the block's switch discriminant; any statement
            // that could change the definition halts the search and the temp stays declared.
            let mut ok = true;
            let mut inlined = false;
            let mut sk = di + 1;
            while sk < blk.stmt_len {
                if sk - di > INLINE_LOOKAHEAD {
                    ok = false;
                    break;
                }
                let s2 = *b.statements.at((blk.stmt_start + sk) as usize);
                if s2.kind == ir::ST_ASSIGN && self.rvalue_reads_local_bare(b, s2.rvalue, l as u32) {
                    if scalar || b.rvalues.at(s2.rvalue as usize).kind == ir::RV_USE {
                        self.sx_inline.set(l, drv);
                    }
                    // The sole read; stop whether or not it was a foldable position.
                    inlined = true;
                    break;
                }
                if !self.inline_safe_between(b, &s2, drv, reads_mem) {
                    ok = false;
                    break;
                }
                sk += 1;
            }
            if !inlined && ok && scalar && (blk.term.kind == ir::TM_SWITCH || blk.term.kind == ir::TM_ASSERT) && self.op_is_bare_local(
                b,
                blk.term.a,
                l as u32,
            ) {
                self.sx_inline.set(l, drv);
            }
        }
        // Multi-return slots (locals 0..returns) are read only by the synthesized carrier
        // `(name_ret){ ._0 = _0, .. }`, never as an operand, so the loop above skips them. A slot with
        // one pure definition and no operand reads folds into that carrier field, provided its
        // definition reaches the return with nothing overwriting its inputs. Single-return `_0` is
        // left alone (return-slot forwarding owns it).
        if b.returns > 1 {
            for l in 0..b.returns as usize {
                if *blocked.at(l) || *ndef.at(l) != 1 || *bare_read.at(l) != 0 {
                    continue;
                }
                let bd = *def_blk.at(l);
                if bd == ir::IR_NONE || b.blocks.at(bd as usize).term.kind != ir::TM_RETURN {
                    continue;
                }
                let drv = *def_rv.at(l);
                let reads_mem = *mem_taint.at(l);
                let blk = *b.blocks.at(bd as usize);
                let mut ok = true;
                let mut sk = *def_idx.at(l) + 1;
                while sk < blk.stmt_len {
                    let s = *b.statements.at((blk.stmt_start + sk) as usize);
                    if !self.inline_safe_between(b, &s, drv, reads_mem) {
                        ok = false;
                        break;
                    }
                    sk += 1;
                }
                if ok {
                    self.sx_inline.set(l, drv);
                }
            }
        }
        // A repeat spells its element at every lane or element: an element that computes binds once.
        for i in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(i);
            if rv.kind != ir::RV_REPEAT || b.operands.at(rv.a as usize).kind == ir::OP_CONST {
                continue;
            }
            let x = *b.places.at(b.operands.at(rv.a as usize).data as usize);
            let d = *self.sx_inline.at(x.base as usize);
            if x.proj_len == 0 && d != ir::IR_NONE && b.rvalues.at(d as usize).kind != ir::RV_USE {
                self.sx_inline.set(x.base as usize, ir::IR_NONE);
            }
        }
        // A vector made from an array literal or repeat that only the next statement's cast reads: the
        // cast spells the vector's compound literal (`emit_vec_cast_store`), no array.
        self.vec_literals(b);
        // A load or lane-wise operation that only the next lane loop reads: that loop computes its lanes.
        self.vec_fusion(b);
        // A fold chain spells nested inside its final read: one renderer level and one C bracket
        // level per link. Every link past INLINE_CHAIN_MAX stays a declared temporary and starts a
        // new chain, so an expression of any length renders within RENDER_NEST_MAX. A definition
        // precedes its read in the same block, so one pass in statement order sees each operand's
        // chain length before its reader.
        let mut chain = self.uget();
        chain.resize_default(n);
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if !self.is_inlined_store(b, &s) {
                    continue;
                }
                let d = 1 + self.rvalue_chain(b, s.rvalue, &chain);
                let l = b.places.at(s.place as usize).base as usize;
                if d > INLINE_CHAIN_MAX {
                    self.sx_inline.set(l, ir::IR_NONE);
                } else {
                    chain.set(l, d);
                }
            }
        }
        self.uput(chain);
        self.uput(bare_read);
        self.uput(ndef);
        self.uput(def_rv);
        self.uput(def_blk);
        self.uput(def_idx);
        self.bput(blocked);
        self.bput(mem_taint);
    }

    // Without backend entries, mark (`sx_inline`) each temporary vector that a slice load or a lane-wise
    // operation that cannot trap defines and only a later lane loop of its block reads, when no
    // statement between them writes memory, a local whose address is taken, or a local the definition
    // reads: the reader's loop computes its lanes (`fused_lanes`), in a chain to the last reader.
    fn vec_fusion(self: &mut Self, b: &ir::CoreBody) {
        if self.simd_on {
            return;
        }
        let n = b.locals.len();
        let mut reads = self.uget();
        reads.resize_default(n);
        for i in 0..b.operands.len() {
            let x = *b.operands.at(i);
            if x.kind != ir::OP_CONST {
                let k = b.places.at(x.data as usize).base as usize;
                reads.set(k, reads[k] + 1);
            }
        }
        let mut defs = self.uget();
        defs.resize_default(n);
        for i in 0..b.statements.len() {
            let st = *b.statements.at(i);
            if st.kind == ir::ST_ASSIGN {
                let k = b.places.at(st.place as usize).base as usize;
                defs.set(k, defs[k] + 1);
            }
        }
        for i in 0..b.blocks.len() {
            let t = &b.blocks.at(i).term;
            if t.kind == ir::TM_CALL {
                for j in 0..t.dests_len {
                    let k = b.places.at(b.dest_pool[(t.dests_start + j) as usize] as usize).base as usize;
                    defs.set(k, defs[k] + 1);
                }
            }
        }
        // Per merged local: the statement whose loop computes its lanes.
        let mut at = self.uget();
        at.resize_default(n);
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            let end = (blk.stmt_start + blk.stmt_len) as usize;
            let mut k = end;
            while k > blk.stmt_start as usize {
                k -= 1;
                let s = *b.statements.at(k);
                if s.kind != ir::ST_ASSIGN || b.places.at(s.place as usize).proj_len != 0 {
                    continue;
                }
                let p0 = b.places.at(s.place as usize).base;
                let rv = *b.rvalues.at(s.rvalue as usize);
                let cmp = rv.kind == ir::RV_SIMD && rv.c >= ir::SIMD_CMP_EQ && rv.c <= ir::SIMD_CMP_GE;
                // A result coalesced into the local it is copied to (`let m = a < b;`): that local.
                let p = *self.sx_coal.at(p0 as usize);
                let st = b.locals.at(p as usize).storage;
                if reads[p as usize] != 1 || defs[p as usize] != 1 || p != p0 && (reads[p0 as usize] != 1 || defs[p0 as usize] != 1) || st != ir::LS_TEMP && st != ir::LS_USER || *self.sx_addr.at(
                    p as usize,
                ) || *self.sx_inline.at(p as usize) != ir::IR_NONE || !cmp && !self.lane_value(b, &rv, true) {
                    continue;
                }
                // The reader, later in the block (thirty-two statements at most).
                let mut r = end;
                for j in k + 1..end {
                    if j > k + 32 {
                        break;
                    }
                    let sj = *b.statements.at(j);
                    if sj.kind == ir::ST_ASSIGN && CEmit::rv_reads(b, b.rvalues.at(sj.rvalue as usize), p) {
                        r = j;
                        break;
                    }
                }
                if r == end {
                    continue;
                }
                let rr = *b.rvalues.at(b.statements.at(r).rvalue as usize);
                // A slice store merges the vector it stores.
                let store = rr.kind == ir::RV_SIMD && rr.c == ir::SIMD_STORE && b.operands.at(
                    b.oper_pool[(rr.a + 2) as usize] as usize,
                ).kind != ir::OP_CONST && b.places.at(
                    b.operands.at(b.oper_pool[(rr.a + 2) as usize] as usize).data as usize,
                ).base == p;
                if !store && !self.lane_value(b, &rr, false) {
                    continue;
                }
                // A comparison merges into the `choose` it gives the lanes of (its mask operand).
                if cmp && !(rr.kind == ir::RV_SIMD && rr.c == ir::SIMD_CHOOSE && b.operands.at(
                    b.oper_pool[rr.a as usize] as usize,
                ).kind != ir::OP_CONST && b.places.at(b.operands.at(b.oper_pool[rr.a as usize] as usize).data as usize).base == p) {
                    continue;
                }
                // The loop that computes the lanes: the reader's, or its own reader's when it merges too.
                let q = b.places.at(b.statements.at(r).place as usize).base;
                let e = pick(
                    b.places.at(b.statements.at(r).place as usize).proj_len == 0 && at[q as usize] != 0,
                    at[q as usize],
                    r as u32,
                );
                // A load from the slice a loop stores to stays out of it: a lane would read memory an
                // earlier lane wrote, where the vector reads every lane first. A load from another
                // slice (borrowed apart, so not overlapping) merges only on wasm: elsewhere the C
                // compiler, unable to tell the two apart, keeps the merged loop scalar.
                let ev = *b.rvalues.at(b.statements.at(e as usize).rvalue as usize);
                if rv.kind == ir::RV_SIMD && rv.c == ir::SIMD_LOAD && ev.kind == ir::RV_SIMD && ev.c == ir::SIMD_STORE && (self.p().arch != 2 || CEmit::rv_reads(
                    b,
                    &rv,
                    b.places.at(b.operands.at(b.oper_pool[ev.a as usize] as usize).data as usize).base,
                )) {
                    continue;
                }
                let mut quiet = true;
                for m in k + 1..e as usize {
                    let sm = *b.statements.at(m);
                    if sm.kind != ir::ST_ASSIGN {
                        continue;
                    }
                    let pm = *b.places.at(sm.place as usize);
                    let rm = *b.rvalues.at(sm.rvalue as usize);
                    let stores = rm.kind == ir::RV_SIMD && (ir::simd_op(rm.c).rule == ir::SR_STORE || ir::simd_op(rm.c).rule == ir::SR_MSTORE);
                    // A check only traps: it writes no memory.
                    let writes = rm.kind == ir::RV_INTRINSIC && !ir::is_check(rm.c);
                    if pm.proj_len != 0 || stores || writes || *self.sx_addr.at(pm.base as usize) || CEmit::rv_reads(
                        b,
                        &rv,
                        pm.base,
                    ) {
                        quiet = false;
                    }
                }
                if quiet {
                    self.sx_inline.set(p as usize, s.rvalue);
                    self.sx_inline.set(p0 as usize, s.rvalue);
                    at.set(p as usize, e);
                    at.set(p0 as usize, e);
                }
            }
        }
        self.uput(at);
        self.uput(defs);
        self.uput(reads);
    }

    // Whether `rv` computes a vector lane by lane in a lane loop: a lane-wise operator, conversion or
    // operation (as the reader: also a comparison); as a merged definition (`def`): also a slice
    // load, and no operation that can trap or gives a mask.
    fn lane_value(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue, def: bool) bool {
        if !self.vec_rv(b, rv) {
            return false;
        }
        if rv.kind != ir::RV_SIMD {
            let mut n: i64 = 0;
            let mut bt = BuiltinType::BT_VOID;
            let mut rbt = BuiltinType::BT_VOID;
            let _ = self.vec_ty(b, b.operands.at(rv.a as usize).ty, &mut n, &mut bt);
            let _ = self.vec_ty(b, rv.target, &mut n, &mut rbt);
            let t = if rv.kind == ir::RV_CAST {
                vec_cast_tpl(bt, rbt);
            } else {
                vec_op_tpl(rv.kind == ir::RV_UNARY, pick(rv.kind == ir::RV_UNARY, rv.b as u8, rv.c), bt);
            };
            return t.len() != 0 && !(def && t.contains("__sc_f"));
        }
        if def && rv.c == ir::SIMD_LOAD {
            return true;
        }
        let r = ir::simd_op(rv.c).rule;
        if r != ir::SR_VEC && r != ir::SR_LANES && r != ir::SR_CHOOSE && !(!def && r == ir::SR_MASK) || rv.c == ir::SIMD_IOTA {
            return false;
        }
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let mut rbt = BuiltinType::BT_VOID;
        let vi = pick(rv.c == ir::SIMD_CHOOSE, 1u32, 0u32);
        let _ = self.vec_ty(b, b.operands.at(b.oper_pool[(rv.a + vi) as usize] as usize).ty, &mut n, &mut bt);
        let _ = self.vec_ty(b, rv.target, &mut n, &mut rbt);
        let t = vec_simd_tpl(rv.c, bt, rbt);
        return t.len() != 0 && !(def && t.contains("__sc_f"));
    }

    // Whether rvalue `rv` reads local `l` whole or in part.
    fn rv_reads(b: &ir::CoreBody, rv: &ir::Rvalue, l: u32) bool {
        let (st, len) = if ir::has_op_range(rv) {
            (rv.a, rv.b);
        } else if rv.kind == ir::RV_INTRINSIC {
            return false; // a type or nothing, not operands
        } else if rv.kind == ir::RV_BINARY {
            (0u32, 2u32);
        } else if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_REPEAT {
            (0u32, 1u32);
        } else {
            return rv.kind != ir::RV_LEN && rv.kind != ir::RV_DISCRIMINANT && rv.kind != ir::RV_REF && rv.kind != ir::RV_ADDR && rv.kind != ir::RV_SLICE || b.places.at(
                rv.a as usize,
            ).base == l;
        };
        for i in 0..len {
            let o = if rv.kind == ir::RV_BINARY {
                pick(i == 0, rv.a, rv.b);
            } else if ir::has_op_range(rv) {
                b.oper_pool[(st + i) as usize];
            } else {
                rv.a;
            };
            let x = *b.operands.at(o as usize);
            if x.kind != ir::OP_CONST && b.places.at(x.data as usize).base == l {
                return true;
            }
        }
        return false;
    }

    // The merged vector local (`vec_fusion`) operand `opid` reads, or IR_NONE.
    fn fused_local(self: &Self, b: &ir::CoreBody, opid: u32) u32 {
        let x = *b.operands.at(opid as usize);
        if self.simd_on || x.kind == ir::OP_CONST || b.places.at(x.data as usize).proj_len != 0 {
            return ir::IR_NONE;
        }
        let l = b.places.at(x.data as usize).base;
        let k = self.rty_y(b, b.locals.at(l as usize).ty).kind;
        return pick(
            *self.sx_inline.at(l as usize) != ir::IR_NONE && (k == TypeKind::TYPE_SIMD || k == TypeKind::TYPE_MASK),
            l,
            ir::IR_NONE,
        );
    }

    // Append to `pre` the lane `__sc_v<p>` of merged vector local `p` inside a lane loop, after those of
    // the merged locals it reads: its load or its operation's template over their lanes.
    fn fused_lanes(self: &mut Self, b: &ir::CoreBody, p: u32, pre: &mut String) bool {
        let rv = *b.rvalues.at((*self.sx_inline.at(p as usize)) as usize);
        let nops = if rv.kind == ir::RV_SIMD {
            rv.b;
        } else if rv.kind == ir::RV_BINARY {
            2u32;
        } else {
            1u32;
        };
        let mut ok = true;
        let mut a: [String; 3] = [String::new(), String::new(), String::new()];
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let mut rbt = BuiltinType::BT_VOID;
        let _ = self.vec_ty(b, rv.target, &mut n, &mut rbt);
        for i in 0..nops {
            let opid = if rv.kind == ir::RV_SIMD {
                b.oper_pool[(rv.a + i) as usize];
            } else {
                pick(i == 0, rv.a, rv.b);
            };
            let q = self.fused_local(b, opid);
            let mut on: i64 = 0;
            let mut obt = BuiltinType::BT_VOID;
            let vec = self.vec_ty(b, b.operands.at(opid as usize).ty, &mut on, &mut obt) && obt != BuiltinType::BT_VOID;
            if vec && bt == BuiltinType::BT_VOID {
                bt = obt;
            }
            if q != ir::IR_NONE {
                ok = ok && self.fused_lanes(b, q, pre);
                unsafe a[i as usize].format_into("__sc_v{}", q);
            } else {
                ok = ok && self.emit_operand(b, opid, unsafe &mut a[i as usize]);
                if vec {
                    unsafe a[i as usize].push_str(".l[__sc_i]");
                }
            }
        }
        if rv.kind == ir::RV_SIMD && rv.c == ir::SIMD_LOAD {
            pre.format_into("{} __sc_v{} = {}.ptr[{} + __sc_i]; ", lane_c(rbt), p, a[0].as_str(), a[1].as_str());
            return ok;
        }
        if rv.kind == ir::RV_SIMD && rv.c >= ir::SIMD_CMP_EQ && rv.c <= ir::SIMD_CMP_GE {
            // The lane's truth, not its bit: `__sc_m |= (uint64_t)(X) << __sc_i;` gives `X`.
            let t = vec_simd_tpl(rv.c, bt, bt);
            pre.format_into("bool __sc_v{} = ", p);
            self.tpl_expand(pre, t.slice(20, t.len() - 11), "", &a, bt, bt);
            pre.push_str("; ");
            return ok;
        }
        if rv.kind == ir::RV_SIMD && rv.c == ir::SIMD_CHOOSE {
            let mut cn: i64 = 0;
            let _ = self.vec_ty(b, b.operands.at(b.oper_pool[(rv.a + 1) as usize] as usize).ty, &mut cn, &mut bt);
        }
        let t = if rv.kind == ir::RV_SIMD && rv.c == ir::SIMD_CHOOSE && self.fused_local(b, b.oper_pool[rv.a as usize]) != ir::IR_NONE {
            "$d = $a ? $b : $c;"; // a merged comparison gives the lane's truth, not its bit
        } else if rv.kind == ir::RV_SIMD {
            vec_simd_tpl(rv.c, bt, rbt);
        } else if rv.kind == ir::RV_CAST {
            vec_cast_tpl(bt, rbt);
        } else {
            vec_op_tpl(rv.kind == ir::RV_UNARY, pick(rv.kind == ir::RV_UNARY, rv.b as u8, rv.c), bt);
        };
        // A template that only assigns `$d` declares the lane at its value.
        let one = t.starts_with("$d = ") && t.find(";") == t.len() as isize - 1;
        let dx = format("__sc_v{}", p);
        pre.format_into("{} ", lane_c(rbt));
        if one {
            pre.push_string(&dx);
        } else {
            pre.format_into("{}; ", dx.as_str());
        }
        self.tpl_expand(pre, pick(one, t.slice(2, t.len()), t), dx.as_str(), &a, bt, rbt);
        pre.push_byte(b' ');
        return ok;
    }

    // Mark (`sx_inline`) each temporary array that a repeat or array literal defines and that only
    // the next statement in its block reads, a cast to a vector of its lanes.
    fn vec_literals(self: &mut Self, b: &ir::CoreBody) {
        let mut reads = self.uget();
        reads.resize_default(b.locals.len());
        for i in 0..b.operands.len() {
            let x = *b.operands.at(i);
            if x.kind != ir::OP_CONST {
                let k = b.places.at(x.data as usize).base as usize;
                reads.set(k, reads[k] + 1);
            }
        }
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            for k in 1..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + k) as usize);
                let d = *b.statements.at((blk.stmt_start + k - 1) as usize);
                if s.kind != ir::ST_ASSIGN || d.kind != ir::ST_ASSIGN || b.places.at(d.place as usize).proj_len != 0 {
                    continue;
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                let dv = *b.rvalues.at(d.rvalue as usize);
                if rv.kind != ir::RV_CAST || rv.b != ir::CAST_SIMD_ARRAY {
                    continue;
                }
                let a = b.places.at(d.place as usize).base;
                let x = *b.operands.at(rv.a as usize);
                let lit = dv.kind == ir::RV_REPEAT && b.operands.at(dv.b as usize).kind == ir::OP_CONST || dv.kind == ir::RV_AGGREGATE && dv.c == ir::AGG_ARRAY;
                if lit && x.kind != ir::OP_CONST && b.places.at(x.data as usize).proj_len == 0 && b.places.at(
                    x.data as usize,
                ).base == a && reads[a as usize] == 1 && b.locals.at(a as usize).storage == ir::LS_TEMP && *self.sx_coal.at(
                    a as usize,
                ) == a && self.rty_y(b, rv.target).kind == TypeKind::TYPE_SIMD {
                    self.sx_inline.set(a as usize, d.rvalue);
                }
            }
        }
        self.uput(reads);
    }

    // The longest fold chain among rvalue `rid`'s whole-local operands (`chain` is 0 for a local
    // that does not fold).
    fn rvalue_chain(self: &Self, b: &ir::CoreBody, rid: u32, chain: &Vector<u32>) u32 {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return CEmit::op_chain(b, rv.a, chain);
        }
        let mut d: u32 = 0;
        if rv.kind == ir::RV_BINARY {
            d = CEmit::op_chain(b, rv.a, chain);
            let d2 = CEmit::op_chain(b, rv.b, chain);
            if d2 > d {
                d = d2;
            }
        } else if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                let d2 = CEmit::op_chain(b, b.oper_pool[(rv.a + i) as usize], chain);
                if d2 > d {
                    d = d2;
                }
            }
        }
        return d;
    }

    const fn op_chain(b: &ir::CoreBody, opid: u32, chain: &Vector<u32>) u32 {
        if opid == ir::IR_NONE {
            return 0;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return 0;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len != 0 {
            return 0;
        }
        return chain[pl.base as usize];
    }

    // Build the current body's write index (see `wx_on`) unless it is built: two counting passes
    // and one fill pass over the operands, statements and blocks.
    fn wx_build(self: &mut Self, b: &ir::CoreBody) {
        if self.wx_on {
            return;
        }
        self.wx_on = true;
        let n = b.locals.len();
        self.wx_use.clear();
        self.wx_woff.clear();
        self.wx_coff.clear();
        self.wx_wst.clear();
        self.wx_cblk.clear();
        self.wx_sblk.clear();
        self.wx_addr.clear();
        self.wx_addr.resize_default(n);
        self.wx_use.resize_default(n);
        self.wx_woff.resize_default(n);
        self.wx_coff.resize_default(n);
        self.wx_woff.push(0);
        self.wx_coff.push(0);
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let base = b.places.at(op.data as usize).base as usize;
                self.wx_use.set(base, self.wx_use[base] + 1);
            }
        }
        // Counts at [base + 1], then prefix sums: [l] is local l's first slot.
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            self.wx_sblk.push(ir::IR_NONE);
            if s.kind == ir::ST_ASSIGN && s.place != ir::IR_NONE {
                let base = b.places.at(s.place as usize).base as usize + 1;
                self.wx_woff.set(base, self.wx_woff[base] + 1);
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
                    self.wx_addr.set(b.places.at(rv.a as usize).base as usize, true);
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                self.wx_sblk.set((blk.stmt_start + si) as usize, bi as u32);
            }
            if blk.term.kind == ir::TM_CALL && blk.term.dests_len == 1 {
                let base = b.places.at(b.dest_pool[blk.term.dests_start as usize] as usize).base as usize + 1;
                self.wx_coff.set(base, self.wx_coff[base] + 1);
            }
        }
        for l in 0..n {
            self.wx_woff.set(l + 1, self.wx_woff[l + 1] + self.wx_woff[l]);
            self.wx_coff.set(l + 1, self.wx_coff[l + 1] + self.wx_coff[l]);
        }
        let mut cur = self.uget();
        for l in 0..n {
            cur.push(self.wx_woff[l]);
        }
        self.wx_wst.resize_default(self.wx_woff[n] as usize);
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind == ir::ST_ASSIGN && s.place != ir::IR_NONE {
                let base = b.places.at(s.place as usize).base as usize;
                self.wx_wst.set(cur[base] as usize, si as u32);
                cur.set(base, cur[base] + 1);
            }
        }
        cur.clear();
        for l in 0..n {
            cur.push(self.wx_coff[l]);
        }
        self.wx_cblk.resize_default(self.wx_coff[n] as usize);
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && t.dests_len == 1 {
                let base = b.places.at(b.dest_pool[t.dests_start as usize] as usize).base as usize;
                self.wx_cblk.set(cur[base] as usize, bi as u32);
                cur.set(base, cur[base] + 1);
            }
        }
        self.uput(cur);
    }

    // Inline a single-use slice/array length into a loop comparison when its source is not written
    // in that loop. Re-evaluating `value.len` is then equivalent and removes the bound temporary.
    fn compute_loop_inline(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        for h in 0..b.blocks.len() {
            if !*cf.is_header.at(h) {
                continue;
            }
            let t = b.blocks.at(h).term;
            if t.kind != ir::TM_SWITCH {
                continue;
            }
            let cop = *b.operands.at(t.a as usize);
            if cop.kind != ir::OP_COPY && cop.kind != ir::OP_MOVE {
                continue;
            }
            let cp = *b.places.at(cop.data as usize);
            if cp.proj_len != 0 || *self.sx_inline.at(cp.base as usize) == ir::IR_NONE {
                continue;
            }
            let crv = *b.rvalues.at((*self.sx_inline.at(cp.base as usize)) as usize);
            if crv.kind != ir::RV_BINARY {
                continue;
            }
            let ro = *b.operands.at(crv.b as usize);
            if ro.kind != ir::OP_COPY && ro.kind != ir::OP_MOVE {
                continue;
            }
            let rp = *b.places.at(ro.data as usize);
            let bound = rp.base as usize;
            if rp.proj_len != 0 || bound < b.returns as usize || *self.sx_inline.at(bound) != ir::IR_NONE {
                continue;
            }
            self.wx_build(b);
            if self.wx_use[bound] != 1 {
                continue;
            }
            // The bound's one whole write held by a block must be a length.
            let mut def = ir::IR_NONE;
            let mut def_block = cfl::NONE;
            let mut source = ir::IR_NONE;
            let mut nwhole: u32 = 0;
            for k in self.wx_woff[bound]..self.wx_woff[bound + 1] {
                let si = self.wx_wst[k as usize];
                let s = *b.statements.at(si as usize);
                if self.wx_sblk[si as usize] == ir::IR_NONE || b.places.at(s.place as usize).proj_len != 0 {
                    continue;
                }
                nwhole += 1;
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_LEN {
                    def = s.rvalue;
                    def_block = self.wx_sblk[si as usize];
                    source = b.places.at(rv.a as usize).base;
                }
            }
            if nwhole != 1 || def == ir::IR_NONE || !cf.dominates(def_block, h as u32) {
                continue;
            }
            let mut changed = false;
            for k in self.wx_woff[source as usize]..self.wx_woff[source as usize + 1] {
                let bi = self.wx_sblk[self.wx_wst[k as usize] as usize];
                if bi != ir::IR_NONE && *cf.loop_of.at(bi as usize) == h as u32 {
                    changed = true;
                }
            }
            if !changed {
                self.sx_inline.set(bound, def);
            }
        }
    }

    // A type with an ordinary single-declarator C spelling, so `T name = init;` is well-formed:
    // excludes arrays (special extent syntax, and C forbids array assignment), the unit/void and
    // never placeholders, and untyped temps (their type recovers at declaration).
    fn simple_decl_type(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = self.rty_y(b, t);
        if y.kind == TypeKind::TYPE_NEVER || y.kind == TypeKind::TYPE_ARRAY && self.arr_n(b, t) <= 0 {
            return false;
        }
        return !(y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID);
    }

    // Whether statement `si` (`dst = src`, both vectors) runs right after the one definition of
    // `src`, and that definition may write `dst` itself: it computes each lane from the same lane of
    // its operands (a lane-wise operation, a choice, a conversion), or it reads no `dst`.
    fn vec_forward(self: &Self, b: &ir::CoreBody, si: usize, src: u32, dst: u32) bool {
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        if !self.vec_ty(b, b.locals.at(dst as usize).ty, &mut n, &mut bt) || bt == BuiltinType::BT_VOID {
            return false;
        }
        let mut blk = ir::IR_NONE;
        for i in 0..b.blocks.len() {
            let bk = b.blocks.at(i);
            if si >= bk.stmt_start as usize && si < (bk.stmt_start + bk.stmt_len) as usize {
                blk = i as u32;
            }
        }
        if blk == ir::IR_NONE {
            return false;
        }
        // Back to the definition: past storage markers, and into a block's one predecessor when that one
        // jumps to it (sixteen steps at most).
        let mut k = si - b.blocks.at(blk as usize).stmt_start as usize;
        let mut rv = *b.rvalues.at(b.statements.at(si).rvalue as usize);
        let mut found = false;
        for _ in 0..16 {
            if k == 0 {
                blk = CEmit::sole_goto_pred(b, blk);
                if blk == ir::IR_NONE {
                    return false;
                }
                k = b.blocks.at(blk as usize).stmt_len as usize;
                continue;
            }
            k -= 1;
            let d = *b.statements.at(b.blocks.at(blk as usize).stmt_start as usize + k);
            if d.kind == ir::ST_STORAGE_LIVE || d.kind == ir::ST_STORAGE_DEAD {
                continue;
            }
            if d.kind != ir::ST_ASSIGN || b.places.at(d.place as usize).base != src || b.places.at(d.place as usize).proj_len != 0 {
                return false;
            }
            rv = *b.rvalues.at(d.rvalue as usize);
            found = true;
            break;
        }
        if found && rv.kind == ir::RV_USE {
            // A copy of another vector writes `dst` as well.
            let o = *b.operands.at(rv.a as usize);
            return o.kind == ir::OP_CONST || b.places.at(o.data as usize).base != dst;
        }
        if !found || !self.vec_rv(b, &rv) && !(rv.kind == ir::RV_CAST && rv.b == ir::CAST_SIMD_ARRAY) {
            return false;
        }
        if rv.kind != ir::RV_SIMD {
            return true; // `+`, `-`, a conversion, an array's lanes
        }
        let r = ir::simd_op(rv.c).rule;
        if r == ir::SR_VEC || r == ir::SR_LANES || r == ir::SR_CHOOSE {
            return true;
        }
        for i in 0..rv.b {
            let y = *b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize);
            if y.kind != ir::OP_CONST && b.places.at(y.data as usize).base == dst {
                return false;
            }
        }
        return true;
    }

    // The one predecessor of block `cur` when it reaches `cur` by a jump and nothing else does;
    // IR_NONE otherwise.
    fn sole_goto_pred(b: &ir::CoreBody, cur: u32) u32 {
        let mut pred = ir::IR_NONE;
        let mut ins: u32 = 0;
        for i in 0..b.blocks.len() {
            let t = &b.blocks.at(i).term;
            if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE && t.t0 == cur {
                ins += 1;
                pred = pick(t.kind == ir::TM_GOTO, i as u32, ir::IR_NONE);
            }
            for k in 0..pick(t.kind == ir::TM_SWITCH, t.sw_len, 0) {
                if (b.switch_pool[(t.sw_start + k) as usize] & 0xFFFFFFFF) as u32 == cur {
                    ins += 2;
                }
            }
        }
        return pick(ins == 1, pred, ir::IR_NONE);
    }

    // An rvalue whose store emits through the general `lhs = rhs;` path as a single C initializer, so
    // its declaration can fuse. Excludes array literals, repeats, array-bearing aggregates, `new`,
    // dynamic-env construction, and other multi-statement stores.
    fn fusable_init_rvalue(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let k = rv.kind;
        if k == ir::RV_CAST && rv.b == ir::CAST_SIMD_ARRAY || self.vec_rv(b, rv) {
            return false;
        }
        if k == ir::RV_USE || k == ir::RV_BINARY || k == ir::RV_UNARY || k == ir::RV_CAST || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT || k == ir::RV_SLICE {
            return true;
        }
        if k == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_VARIANT) {
            return !self.agg_has_array_field(b, rv);
        }
        if k == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY {
            return !self.agg_has_array_field(b, rv);
        }
        if k == ir::RV_INTRINSIC && rv.c as u32 == ir::IN_NEW as u32 {
            return true;
        }
        // Explicit safe-access checks emit as a single call (or the bare operand when PROVEN):
        // fusing the declaration keeps one C statement without reordering anything.
        if k == ir::RV_INTRINSIC && ir::is_check(rv.c) {
            return true;
        }
        if k == ir::RV_CLOSURE {
            return !self.closure_has_array_cap(b, rv);
        }
        return false;
    }

    // Domination probe over one written place: if local `p.base` is a fusion candidate whose init
    // block does not dominate the writing block `bi`, the fused declaration would not dominate that
    // write, so the candidate is withdrawn.
    fn dom_check_place(
        self: &Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        pid: u32,
        bi: u32,
        init_blk: &Vector<u32>,
        out: &mut Vector<bool>,
    ) {
        let base = (*self.sx_coal.at(b.places.at(pid as usize).base as usize)) as usize;
        if *init_blk.at(base) != cfl::NONE && !cf.dominates(*init_blk.at(base), bi) {
            out.set(base, true);
        }
    }

    // Choose locals that declare at their initializing write. A candidate's first write must be a
    // whole-local store with a single-initializer rvalue, and that write's block must dominate every
    // WRITE to the local, which, with the checker's definite-init guarantee, also dominates every
    // read (a read the init did not dominate would need a write the init did not dominate). So the
    // fused declaration is in scope and has run before any use on every path. Two near-linear passes:
    // first write per local, then a write-domination sweep.
    fn compute_fusion(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        let n = b.locals.len();
        self.sx_fuse.clear();
        self.sx_declared.clear();
        self.sx_fuse.resize_default(n);
        self.sx_declared.resize_default(n);
        let mut init_blk = self.uget();
        let mut seen = self.bget();
        let mut bad = self.bget();
        let mut nread = self.uget();
        let mut direct_array = self.bget();
        seen.resize_default(n);
        bad.resize_default(n);
        nread.resize_default(n);
        direct_array.resize_default(n);
        for _l in 0..n {
            init_blk.push(cfl::NONE);
        }
        // Pass 1: first write per local, in emission (reverse-postorder) order.
        for oi in 0..cf.order.len() {
            let bi = *cf.order.at(oi);
            let blk = *b.blocks.at(bi as usize);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                let mut wl = ir::IR_NONE;
                let mut ok_init = false;
                let mut is_array_init = false;
                if s.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(s.place as usize);
                    let rv0 = *b.rvalues.at(s.rvalue as usize);
                    wl = *self.sx_coal.at(pl.base as usize);
                    ok_init = pl.proj_len == 0 && self.fusable_init_rvalue(b, &rv0);
                    is_array_init = rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY;
                }
                if wl != ir::IR_NONE && !*seen.at(wl as usize) {
                    seen.set(wl as usize, true);
                    if ok_init {
                        init_blk.set(wl as usize, bi);
                        direct_array.set(wl as usize, is_array_init);
                    } else {
                        bad.set(wl as usize, true);
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    let dp = b.dest_pool[(t.dests_start + d) as usize];
                    let pl = *b.places.at(dp as usize);
                    let wl = *self.sx_coal.at(pl.base as usize);
                    if !*seen.at(wl as usize) {
                        seen.set(wl as usize, true);
                        let mut call_init = t.dests_len == 1 && pl.proj_len == 0;
                        if call_init && pl.ty == TYPE_NONE {
                            let mut rs = self.sget();
                            call_init = self.untyped_ret_struct(b, wl, &mut rs);
                            self.sput(rs);
                        } else if call_init {
                            call_init = self.simple_decl_type(b, pl.ty);
                        }
                        if call_init && pl.ty != TYPE_NONE {
                            call_init = self.rty_y(b, pl.ty).kind != TypeKind::TYPE_ARRAY;
                        }
                        if call_init {
                            init_blk.set(wl as usize, bi);
                        } else {
                            bad.set(wl as usize, true);
                        }
                    }
                }
            }
        }
        // Pass 2: every WRITE must be dominated by its local's init block (definite-init then extends
        // this to reads); tally reads. Writes are whole/projected assigns, discriminant/deinit stores,
        // and call destinations. A drop is checked too: a flag-guarded drop of a temporary made on
        // one side of a branch (`a && f(T::new())`) runs where the init does not dominate.
        for oi in 0..cf.order.len() {
            let bi = *cf.order.at(oi);
            let blk = *b.blocks.at(bi as usize);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN {
                    self.dom_check_place(b, cf, s.place, bi, &init_blk, &mut bad);
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    self.dom_check_place(b, cf, b.dest_pool[(t.dests_start + d) as usize], bi, &init_blk, &mut bad);
                }
            } else if t.kind == ir::TM_DROP {
                self.dom_check_place(b, cf, t.a, bi, &init_blk, &mut bad);
            }
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let rb = *self.sx_coal.at(b.places.at(op.data as usize).base as usize);
                nread.set(rb as usize, *nread.at(rb as usize) + 1);
            }
        }
        for l in 0..n {
            let st = b.locals.at(l).storage;
            if st != ir::LS_USER && st != ir::LS_TEMP {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 || l < b.returns as usize {
                continue;
            }
            if *self.sx_inline.at(l) != ir::IR_NONE || *bad.at(l) || *init_blk.at(l) == cfl::NONE {
                continue;
            }
            // A general initializer must sit outside every loop because C dominance does not imply
            // lexical scope across a loop exit. A range-loop index is scoped to that loop and may
            // declare at its initializer even when the loop is nested.
            if *cf.loop_of.at((*init_blk.at(l)) as usize) != cfl::NONE {
                if b.locals.at(l).dkind != ir::LK_FOR {
                    continue;
                }
            }
            let mut decl_ok = self.simple_decl_type(b, b.locals.at(l).ty);
            if b.locals.at(l).ty == TYPE_NONE {
                let mut rs = self.sget();
                decl_ok = self.untyped_ret_struct(b, l as u32, &mut rs);
                self.sput(rs);
            }
            if *nread.at(l) == 0 || !decl_ok {
                continue;
            }
            {
                if self.rty_y(b, b.locals.at(l).ty).kind == TypeKind::TYPE_ARRAY && !*direct_array.at(l) {
                    continue;
                }
            }
            if self.cap_on && l as u32 >= self.cap_base {
                continue;
            }
            self.sx_fuse.set(l, true);
        }
        self.uput(init_blk);
        self.uput(nread);
        self.bput(seen);
        self.bput(bad);
        self.bput(direct_array);
    }

    // Whether a statement produces C output (so it "runs" between a forwarded call and its use).
    fn stmt_emits(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
            return false;
        }
        if self.is_dead_store(b, s) || self.is_coalesced_store(b, s) || self.is_inlined_store(b, s) {
            return false;
        }
        if s.kind == ir::ST_ASSIGN && b.rvalues.at(s.rvalue as usize).kind == ir::RV_SIMD {
            return true;
        }
        if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).ty != TYPE_NONE && self.erased(
            b,
            b.places.at(s.place as usize).ty,
        ) {
            return false;
        }
        return true;
    }

    // Forward a single-return call result into its one use. `_r = f(..)` (a call terminator) followed
    // by a use of `_r` in the continuation block, with nothing emitted between them, folds to spelling
    // `f(..)` at the use: `return _r;` becomes `return f(..);`, `x = _r;` becomes `x = f(..);`, and a
    // condition `_r != 5` becomes `f(..) != 5`. The call still executes at the same point (nothing runs
    // between), and the continuation's sole predecessor is this call, so no path skips it.
    fn compute_call_fwd(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        let n = b.locals.len();
        self.sx_call_fwd.clear();
        self.sx_cs_pool.clear();
        self.sx_cs_off.clear();
        self.sx_cs_len.clear();
        self.sx_call_fwd.resize_default(n);
        self.sx_cs_off.resize_default(n);
        self.sx_cs_len.resize_default(n);
        let mut bare = self.uget();
        let mut deref = self.uget();
        let mut bad = self.bget();
        let mut ncall = self.uget();
        bare.resize_default(n);
        deref.resize_default(n);
        bad.resize_default(n);
        ncall.resize_default(n);
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let pl = *b.places.at(op.data as usize);
                if pl.proj_len == 0 {
                    bare.set(pl.base as usize, *bare.at(pl.base as usize) + 1);
                } else if pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF {
                    deref.set(pl.base as usize, *deref.at(pl.base as usize) + 1);
                } else {
                    bad.set(pl.base as usize, true);
                }
            }
        }
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind == ir::ST_ASSIGN {
                if !self.is_coalesced_store(b, &s) {
                    // Any other store defeats the single-def call dest.
                    bad.set(b.places.at(s.place as usize).base as usize, true);
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                    bad.set(b.places.at(rv.a as usize).base as usize, true);
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_DROP && !self.drop_emits_nothing(b, &t) {
                bad.set(b.places.at(t.a as usize).base as usize, true);
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    let dp = *b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize);
                    if dp.proj_len == 0 {
                        ncall.set(dp.base as usize, *ncall.at(dp.base as usize) + 1);
                    } else {
                        bad.set(dp.base as usize, true);
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            if !*cf.reach.at(bi) {
                continue;
            }
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || t.dests_len != 1 {
                continue;
            }
            let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
            let r = dp.base;
            let root = *self.sx_coal.at(r as usize);
            if dp.proj_len != 0 || r as usize < b.returns as usize {
                continue;
            }
            let cont = cf.succ(b, bi as u32, 0);
            let cblk = *b.blocks.at(cont as usize);
            let assert_use = self.assert_call_use(b, &cblk, root);
            let uses = *bare.at(root as usize) + *deref.at(root as usize);
            if *ncall.at(r as usize) != 1 || *bad.at(r as usize) || *bad.at(root as usize) || uses != 1 && !(assert_use && uses == 2) {
                continue;
            }
            if self.erased(b, b.locals.at(root as usize).ty) {
                continue;
            }
            // A fixed-array result stores through a `_ret` carrier + memcpy, not a plain expression.
            {
                if self.arr_n(b, b.locals.at(root as usize).ty) > 0 {
                    continue;
                }
            }
            // An aggregate result is taken by address in the equality/ordering/overload dispatch, and
            // C forbids the address of a call rvalue; fold it only into a whole-value copy or return.
            let scalar = self.is_scalar(b, b.locals.at(root as usize).ty);
            // The use must sit in the continuation with nothing emitted before it.
            let mut before = false;
            let mut used = false;
            for si in 0..cblk.stmt_len {
                let s = *b.statements.at((cblk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN && self.rvalue_reads_call_use(b, s.rvalue, root) {
                    // A use that emits no statement cannot receive the forwarded call. Keep the call
                    // as its own statement so its side effect remains, then elide the unused copy.
                    if !self.stmt_emits(b, &s) {
                        if assert_use && scalar && self.is_inlined_store(b, &s) {
                            used = true;
                        } else {
                            before = true;
                        }
                        break;
                    }
                    used = scalar || b.rvalues.at(s.rvalue as usize).kind == ir::RV_USE;
                    // The sole read, but not a foldable position -> keep the temp.
                    before = !used;
                    break;
                }
                if self.stmt_emits(b, &s) {
                    before = true;
                    break;
                }
            }
            if !used && !before && scalar {
                let ct = cblk.term;
                if (ct.kind == ir::TM_SWITCH || ct.kind == ir::TM_ASSERT) && self.op_is_bare_local(b, ct.a, root) {
                    used = true;
                }
            }
            if used && !before {
                self.sx_call_fwd.set(r as usize, true);
                self.sx_call_fwd.set(root as usize, true);
            }
        }
        self.uput(bare);
        self.uput(deref);
        self.uput(ncall);
        self.bput(bad);
    }

    fn assert_call_use(self: &mut Self, b: &ir::CoreBody, blk: &ir::BasicBlock, l: u32) bool {
        let t = blk.term;
        if t.kind != ir::TM_ASSERT || t.args_len != 4 {
            return false;
        }
        let mut diag: u32 = 0;
        for i in 0..2 {
            if self.op_is_call_use(b, b.oper_pool[(t.args_start + i as u32) as usize], l) {
                diag += 1;
            }
        }
        if diag != 1 {
            return false;
        }
        for i in 0..blk.stmt_len {
            let s = *b.statements.at((blk.stmt_start + i) as usize);
            if s.kind == ir::ST_ASSIGN && self.rvalue_reads_call_use(b, s.rvalue, l) {
                return self.is_inlined_store(b, &s);
            }
            if self.stmt_emits(b, &s) {
                return false;
            }
        }
        return false;
    }

    // Locals, labels, blocks and the closing brace, shared by plain functions and closures.
    fn emit_body_core(self: &mut Self, b: &ir::CoreBody) bool {
        if self.cf_ext != null {
            return self.emit_body_core_cf(b, unsafe &*self.cf_ext);
        }
        let mut cf = self.cfget();
        let dm = self.pr.start();
        cf.build_into(b);
        self.pr.stop(prb::P_DECL, dm);
        let ok9 = self.emit_body_core_cf(b, &cf);
        self.cfput(cf);
        return ok9;
    }

    fn emit_body_core_cf(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        // The body renders into the TU buffer taken out of `self`, so every renderer writes to it
        // while `self` stays borrowed; nothing else may touch `self.out` meanwhile.
        let mut o = replace(&mut self.out, String::new());
        self.lit_on = true;
        self.lit_ids.clear();
        self.lit_decls.truncate(0);
        let ok = self.emit_body_core_o(&mut o, b, cf);
        self.lit_on = false;
        assert(self.out.len() == 0);
        self.out = o;
        return ok;
    }

    // A local declaration's class: 3 erased (no C), 4 never, 2 spelled by ty_c.
    fn decl_class(self: &mut Self, b: &ir::CoreBody, t: TypeId) u8 {
        let y = self.rty_y(b, t);
        if self.erased(b, t) {
            return 3;
        }
        if y.kind == TypeKind::TYPE_NEVER {
            return 4;
        }
        return 2;
    }

    fn emit_body_core_o(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        assert(self.sx_nest == 0);
        let dm = self.pr.start();
        self.compute_loop_inline(b, cf);
        self.compute_fusion(b, cf);
        self.compute_call_fwd(b, cf);
        let ret_dead = !self.ret_slot_live(b, cf);
        // The instances of inlined calls whose per-instantiation static_asserts still run: their
        // symbols demand them, as the calls did.
        for i in 0..b.demands.len() {
            let mut s9 = self.sget();
            let t9 = *b.demands.at(i);
            let _ = self.term_callee_sym(b, &t9, true, &mut s9);
            self.sput(s9);
        }
        self.pr.stop(prb::P_DECL, dm);
        // Preemption tick, function-local so the C compiler can keep it in a register: the TLS
        // countdown cost a load+store on every loop back-edge. A loop reaching 2048 back-edges
        // still hits the hook; the cross-call accumulation the TLS tick had was incidental.
        if b.has_safepoint() && self.ticks_on(b) {
            o.push_str("  int32_t __sc_spc = 2048;\n");
        }
        // Every non-argument local declares up front, explicitly typed; unit locals carry no C.
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            if st == ir::LS_ARG {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 {
                // Coalesced into another local; shares its declaration.
                continue;
            }
            if l >= b.returns as usize && !*self.sx_used.at(l) {
                // Referenced nowhere: a dead temporary, not declared.
                continue;
            }
            if *self.sx_inline.at(l) != ir::IR_NONE {
                // Single-use pure temp: inlined at its read, no declaration.
                continue;
            }
            let ml = if self.simd_on && b.locals.at(l).ty != TYPE_NONE && self.rty_y(b, b.locals.at(l).ty).kind == TypeKind::TYPE_MASK {
                self.lane_only(b, l as u32);
                pick(self.ml_alias[l] != ir::IR_NONE, self.ml_alias[l], l as u32);
            } else {
                ir::IR_NONE;
            };
            let mut to = BuiltinType::BT_VOID;
            if ml != ir::IR_NONE && self.ml_lanes(b, ml, &mut to) {
                // A comparison in lane-mask temporaries, or the copy its `choose` reads: no value.
                continue;
            }
            if *self.sx_fuse.at(l) {
                // Declares at its initializing write instead of up front.
                continue;
            }
            if *self.sx_call_fwd.at(l) {
                // A forwarded call result: its call spells `f(..)` at the read, no storage.
                continue;
            }
            if l == 0 && ret_dead {
                // Return-slot forwarding made `_0` dead; drop its declaration.
                continue;
            }
            if b.locals.at(l).ty == TYPE_NONE {
                // Untyped temps recover their type from whatever writes them (rvalue target or a
                // call destination); scalars fall back to int64_t.
                let mut retsym = self.sget();
                let multi = self.untyped_ret_struct(b, l as u32, &mut retsym);
                if multi {
                    o.push_str("  ");
                    o.push_string(&retsym);
                    o.push_str(" _");
                    o.push_u64(l as u64);
                    o.push_str(";\n");
                }
                self.sput(retsym);
                if multi {
                    continue;
                }

                let rt0 = self.untyped_local_ty(b, l as u32);
                if rt0 != TYPE_NONE {
                    let mut nm3 = String::from_str("_");
                    nm3.push_u64(l as u64);
                    o.push_str("  ");
                    let ok3 = self.ty_c(b.module, rt0, nm3.as_str(), o);
                    o.push_str(";\n");

                    if !ok3 {
                        return false;
                    }
                    continue;
                }
                o.push_str("  int64_t _");
                o.push_u64(l as u64);
                o.push_str(";\n");
                continue;
            }
            // Substituted bodies re-resolve generic-dependent types per instantiation, memo-free.
            // Substitution-free: one classification per (module, TypeId) covers the open-array,
            // never, and unit checks too; the per-local resolve chain runs once, not per body.
            let mut slot: u64 = 0;
            let mut md: u8 = 2;
            if self.mg.subs.len() != 0 {
                md = self.decl_class(b, b.locals.at(l).ty);
            } else {
                let dk = skey_mix(0, b.module as u64 << 32 | b.locals.at(l).ty as u64);
                slot = (switch self.decl_memo.get(&dk) {
                    Some(v) => *v,
                    None => {
                        let mut t0 = String::new();
                        let mut md0 = self.decl_class(b, b.locals.at(l).ty);
                        let mut tx = String::new();
                        if md0 == 2 && self.ty_c(b.module, b.locals.at(l).ty, "", &mut t0) && self.ty_c(
                            b.module,
                            b.locals.at(l).ty,
                            "x",
                            &mut tx,
                        ) {
                            let mut probe = String::from_str(t0.as_str());
                            probe.push_str("x");
                            if tx.as_str() == probe.as_str() {
                                md0 = 1;
                            } else {
                                probe.truncate(t0.len());
                                probe.push_str(" x");
                                if tx.as_str() == probe.as_str() {
                                    md0 = 0;
                                }
                            }
                        }
                        let ix = self.decl_txt.len() as u64;
                        self.decl_txt.push(t0);
                        self.decl_mode.push(md0);
                        self.decl_memo.insert(dk, ix);
                        ix;
                    },
                });
                md = self.decl_mode[slot as usize];
            }
            if md == 3 {
                continue;
            }
            if md == 4 {
                // Never-typed temps only appear on dead paths; a scalar placeholder keeps
                // their (unreachable) reads compilable.
                o.push_str("  int64_t _");
                o.push_u64(l as u64);
                o.push_str(";\n");
                continue;
            }
            if st == ir::LS_STATIC_REF {
                // Reads spell the item's own symbol; the local never declares.
                continue;
            }
            let mut nm = self.sget();
            self.lspell(l as u32, &mut nm);
            let mut ok = true;
            if md != 2 {
                o.push_str("  ");
                o.push_string(self.decl_txt.at(slot as usize));
                if md == 0 {
                    o.push_str(" ");
                }
                o.push_string(&nm);
                o.push_str(";\n");
            } else {
                let mut ts = self.sget();
                ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
                if ok {
                    o.push_str("  ");
                    o.push_string(&ts);
                    o.push_str(";\n");
                }
                self.sput(ts);
            }
            self.sput(nm);
            if !ok {
                return false;
            }
        }
        let lit_at = o.len();
        let mut ok2 = false;
        if cf.reducible && self.plan_structured(o, b, cf) {
            ok2 = self.emit_structured(o, b, cf);
        } else {
            ok2 = self.emit_layout(o, b, cf);
        }
        if !ok2 {
            return false;
        }
        if self.lit_decls.len() != 0 {
            // The long string constants the statements spell, declared ahead of them.
            o.insert_str(lit_at, self.lit_decls.as_str());
        }
        if b.returns == 1 && self.erased(b, b.locals.at(0).ty) && o.as_str().ends_with("  return;\n") {
            o.truncate(o.len() - 10);
        }
        o.push_str("}\n");
        return self.err.len() == 0;
    }

    // Emit reachable blocks in reverse-postorder: a label only where a goto lands, fall-through
    // when the sole successor is the next block, one goto otherwise. Unreachable blocks, the dead
    // fall-off sentinels, and jump-to-next chains never appear. Structured `if`/`switch`/loops are
    // layered on this by emit_body_core's structural pass; this is the goto-correct fallback.
    fn emit_layout(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        let m = cf.order.len();
        let mut need = self.bget();
        let mut skip = self.bget();
        let mut chain_default = self.uget();
        let mut chain_target = self.uget();
        let mut chain_kind = self.uget();
        need.resize_default(b.blocks.len());
        skip.resize_default(b.blocks.len());
        chain_kind.resize_default(b.blocks.len());
        for _i in 0..b.blocks.len() {
            chain_default.push(cfl::NONE);
            chain_target.push(cfl::NONE);
        }
        // Pattern OR arms lower as a chain of one-case switches. Merge a chain only when every
        // continuation has one predecessor and emits no statement.
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let t = b.blocks.at(x as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 {
                continue;
            }
            let target = cf.succ(b, x, 0);
            let mut cur = x;
            let mut d = cf.succ(b, cur, 1);
            while *cf.preds.at(d as usize) == 1 && self.block_output_empty(b, d) {
                let dt = b.blocks.at(d as usize).term;
                if dt.kind != ir::TM_SWITCH || dt.sw_len != 1 || cf.succ(b, d, 0) != target {
                    break;
                }
                skip.set(d as usize, true);
                cur = d;
                d = cf.succ(b, cur, 1);
            }
            if cur != x {
                chain_default.set(x as usize, d);
                chain_target.set(x as usize, target);
                chain_kind.set(x as usize, 1);
            }
        }
        // Inclusive ranges lower as two true-edge comparisons with the same false edge.
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let t = b.blocks.at(x as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 {
                continue;
            }
            let mid = cf.succ(b, x, 0);
            if *cf.preds.at(mid as usize) != 1 || !self.block_output_empty(b, mid) {
                continue;
            }
            let mt = b.blocks.at(mid as usize).term;
            let fail = cf.succ(b, x, 1);
            if mt.kind == ir::TM_SWITCH && mt.sw_len == 1 && cf.succ(b, mid, 1) == fail {
                skip.set(mid as usize, true);
                chain_default.set(x as usize, fail);
                chain_target.set(x as usize, cf.succ(b, mid, 0));
                chain_kind.set(x as usize, 2);
            }
        }
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let mut ni = i + 1;
            while ni < m && *skip.at((*cf.order.at(ni)) as usize) {
                ni += 1;
            }
            let next = if ni < m {
                *cf.order.at(ni);
            } else {
                cfl::NONE;
            };
            let t = b.blocks.at(x as usize).term;
            if t.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, x, &mut cs) {
                    if cs != next {
                        need.set(cs as usize, true);
                    }
                } else if *chain_default.at(x as usize) != cfl::NONE {
                    need.set((*chain_target.at(x as usize)) as usize, true);
                    let ot = *chain_default.at(x as usize);
                    if ot != next {
                        need.set(ot as usize, true);
                    }
                } else {
                    for k in 0..t.sw_len {
                        need.set(cf.succ(b, x, k) as usize, true);
                    }
                    let ot = cf.succ(b, x, t.sw_len);
                    if ot != next {
                        need.set(ot as usize, true);
                    }
                }
            } else if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
                let s = cf.succ(b, x, 0);
                if s != next {
                    need.set(s as usize, true);
                }
            }
        }
        let mut ok = true;
        for i in 0..m {
            if !ok {
                break;
            }
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let mut ni = i + 1;
            while ni < m && *skip.at((*cf.order.at(ni)) as usize) {
                ni += 1;
            }
            let next = if ni < m {
                *cf.order.at(ni);
            } else {
                cfl::NONE;
            };
            if *need.at(x as usize) {
                o.push_str("bb_");
                o.push_u64(x);
                o.push_str(": ;\n");
            }
            let blk = *b.blocks.at(x as usize);
            if !self.emit_block_content(o, b, &blk) {
                ok = false;
                break;
            }
            if blk.term.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, x, &mut cs) {
                    if cs != next {
                        o.push_str("  goto bb_");
                        o.push_u64(cs);
                        o.push_str(";\n");
                    }
                } else {
                    let cd = *chain_default.at(x as usize);
                    if cd != cfl::NONE {
                        ok = self.emit_switch_chain(
                            o,
                            b,
                            cf,
                            x,
                            *chain_target.at(x as usize),
                            cd,
                            *chain_kind.at(x as usize) != 1,
                        );
                    } else {
                        ok = self.emit_switch_gotos(o, b, cf, x);
                    }
                    if !ok {
                        ok = false;
                        break;
                    }
                    let ot = if cd != cfl::NONE {
                        cd;
                    } else {
                        cf.succ(b, x, blk.term.sw_len);
                    };
                    if ot != next {
                        o.push_str("  goto bb_");
                        o.push_u64(ot);
                        o.push_str(";\n");
                    }
                }
            } else if blk.term.kind != ir::TM_RETURN && blk.term.kind != ir::TM_UNREACHABLE {
                let s = cf.succ(b, x, 0);
                if s != next {
                    o.push_str("  goto bb_");
                    o.push_u64(s);
                    o.push_str(";\n");
                }
            }
        }
        self.bput(need);
        self.bput(skip);
        self.uput(chain_default);
        self.uput(chain_target);
        self.uput(chain_kind);
        return ok;
    }

    // Whether block `x` emits no C: every statement is a marker or is elided (dead, coalesced,
    // inlined, or unit). Such a loop header is pure condition evaluation, so it reconstructs as a
    // native `while (cond)` instead of `while (1) { if (cond) .. else break; }`.
    fn block_output_empty(self: &mut Self, b: &ir::CoreBody, x: u32) bool {
        let blk = *b.blocks.at(x as usize);
        for i in 0..blk.stmt_len {
            if self.stmt_emits(b, b.statements.at((blk.stmt_start + i) as usize)) {
                return false;
            }
        }
        return true;
    }

    // One `if (..) goto bb_target;` over a switch chain from `x`: an OR chain follows each test's
    // fall-through edge until `end`; an AND pair (`and`) joins `x`'s test with its match edge's test,
    // and holds only when that second test falls through to `end`.
    fn emit_switch_chain(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        x: u32,
        target: u32,
        end: u32,
        and: bool,
    ) bool {
        let mut cur = x;
        o.push_str("  if (");
        let mut d = self.sget();
        let mut n: u32 = 0;
        loop {
            let t = b.blocks.at(cur as usize).term;
            d.clear();
            if !self.emit_operand(b, t.a, &mut d) {
                self.sput(d);
                return false;
            }
            if n != 0 {
                o.push_str(mbe::if_s(and, " && ", " || "));
            }
            n += 1;
            self.push_case_test(o, false, self.is_bool(b, b.operands.at(t.a as usize).ty), &d, self.case_val(b, &t, 0));
            if and {
                if n == 2 {
                    break;
                }
                cur = cf.succ(b, cur, 0);
            } else {
                let next = cf.succ(b, cur, 1);
                if next == end {
                    break;
                }
                cur = next;
            }
        }
        self.sput(d);
        o.push_str(") goto bb_");
        o.push_u64(target);
        o.push_str(";\n");
        return !and || cf.succ(b, cur, 1) == end;
    }

    // The live successor of a switch on a literal (succ follows only that edge); false otherwise.
    fn const_switch_succ(self: &Self, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32, out: &mut u32) bool {
        if cfl::const_switch_edge(b, x) == cfl::NONE {
            return false;
        }
        *out = cf.succ(b, x, 0);
        return true;
    }

    // The per-arm equality tests of a switch terminator: `if ((disc) == value) goto bb_target;`.
    fn emit_switch_gotos(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32) bool {
        let t = b.blocks.at(x as usize).term;
        let mut d = self.sget();
        if !self.emit_operand(b, t.a, &mut d) {
            self.sput(d);
            return false;
        }
        let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
        let mut k: u32 = 0;
        while k < t.sw_len {
            o.push_str("  if (");
            self.push_case_test(o, false, isb, &d, self.case_val(b, &t, k));
            let target = cf.succ(b, x, k);
            let mut j = k + 1;
            while j < t.sw_len && cf.succ(b, x, j) == target {
                o.push_str(" || ");
                self.push_case_test(o, false, isb, &d, self.case_val(b, &t, j));
                j += 1;
            }
            o.push_str(") goto bb_");
            o.push_u64(target);
            o.push_str(";\n");
            k = j;
        }
        self.sput(d);
        return true;
    }

    // The block-relative index of a `_0 = <operand>` statement that can forward straight to
    // `return <operand>`: the last real statement of a single-value return block, skipping trailing
    // storage/nop markers. IR_NONE when the block is not that exact shape.
    fn ret_fwd_idx(self: &mut Self, b: &ir::CoreBody, blk: &ir::BasicBlock) u32 {
        if blk.term.kind != ir::TM_RETURN || blk.term.args_len == ir::RET_CANCEL || b.returns != 1 || self.arr_ret {
            return ir::IR_NONE;
        }
        if self.erased(b, b.locals.at(0).ty) {
            return ir::IR_NONE;
        }
        let mut i = blk.stmt_len;
        while i > 0 {
            let k = b.statements.at((blk.stmt_start + i - 1) as usize).kind;
            if k == ir::ST_STORAGE_LIVE || k == ir::ST_STORAGE_DEAD {
                i -= 1;
                continue;
            }
            break;
        }
        if i == 0 {
            return ir::IR_NONE;
        }
        let idx = i - 1;
        let s = *b.statements.at((blk.stmt_start + idx) as usize);
        if s.kind != ir::ST_ASSIGN {
            return ir::IR_NONE;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.base != 0 || pl.proj_len != 0 {
            return ir::IR_NONE;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        if rv.kind == ir::RV_INTRINSIC || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY || !self.fusable_init_rvalue(
            b,
            &rv,
        ) {
            return ir::IR_NONE;
        }
        if rv.kind == ir::RV_USE {
            let op = *b.operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                if b.places.at(op.data as usize).base == 0 {
                    // The slot reads itself; leave the copy in place.
                    return ir::IR_NONE;
                }
            }
        }
        return idx;
    }

    // Whether the single return slot `_0` is still referenced after return-slot forwarding. When
    // every return forwards its value directly, the slot's declaration is dead and must be dropped
    // (it would otherwise trip -Werror=unused-variable). Conservative: any read, any non-forwarded
    // write, or any `return _0` keeps it live.
    fn ret_slot_live(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        if b.returns != 1 || self.arr_ret || self.erased(b, b.locals.at(0).ty) {
            return true;
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                if b.places.at(op.data as usize).base == 0 {
                    return true;
                }
            }
        }
        for bi in 0..b.blocks.len() {
            if !*cf.reach.at(bi) {
                // Unreachable blocks (the fall-off return sentinel) never emit.
                continue;
            }
            let blk = *b.blocks.at(bi);
            let skip = self.ret_fwd_idx(b, &blk);
            if blk.term.kind == ir::TM_RETURN && blk.term.args_len != ir::RET_CANCEL && skip == ir::IR_NONE {
                // A cancellation return spells a zero literal, never the slot.
                return true;
            }
            for si in 0..blk.stmt_len {
                if si == skip {
                    continue;
                }
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).base == 0 {
                    return true;
                }
            }
        }
        return false;
    }

    // Emit a block's statements and terminator effect, applying return-slot forwarding. Shared by the
    // structured driver and the goto layout so both spell the same body.
    fn emit_block_content(self: &mut Self, o: &mut String, b: &ir::CoreBody, blk: &ir::BasicBlock) bool {
        let skip = self.ret_fwd_idx(b, blk);
        for si in 0..blk.stmt_len {
            if si == skip {
                continue;
            }
            let s = *b.statements.at((blk.stmt_start + si) as usize);
            if !self.emit_stmt(o, b, &s) {
                return false;
            }
        }
        if skip != ir::IR_NONE {
            o.push_str("  return ");
            if !self.emit_rvalue(b, b.statements.at((blk.stmt_start + skip) as usize).rvalue, o) {
                return false;
            }
            o.push_str(";\n");
            return true;
        }
        return self.emit_term_effect(o, b, &blk.term);
    }

    // Reconstruct structured C over a reducible, simple-loop CFG: straight-line runs, `if`/`else`,
    // native `switch`, and `while` loops with `break`/`continue`. Any control the structure cannot
    // express directly (a header that is a multi-way switch, a cross exit) becomes a forward `goto`
    // whose label prints when its block is reached. The goto layout is the fallback for CFGs that
    // are not simple; both are behavior-equivalent.
    // Label-planning pass: walk the region tree with no output or statement side effects. Returns
    // true when the body structures with no goto (so the real pass is safe), leaving self.sx_lbl
    // marking any block that still needs a label. A false result sends the body to the goto layout,
    // which also takes a body the dry walk fails on, such as regions nesting past RENDER_NEST_MAX (a
    // long `else if` chain whose tests need statements nests one region per arm).
    fn plan_structured(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        self.sx_emitted.clear();
        self.sx_lbl.clear();
        self.sx_emitted.resize_default(b.blocks.len());
        self.sx_lbl.resize_default(b.blocks.len());
        self.sx_goto = false;
        let err = self.err;
        if !self.emit_region(o, b, cf, cf.entry, cfl::NONE, cfl::NONE, cfl::NONE, true) {
            self.err = err;
            return false;
        }
        if self.sx_goto {
            return false;
        }
        for i in 0..b.blocks.len() {
            if *self.sx_lbl.at(i) && !*self.sx_emitted.at(i) {
                return false;
            }
        }
        return true;
    }

    // The structured pass proper; runs only after plan_structured returned true (no goto needed).
    fn emit_structured(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        for i in 0..b.blocks.len() {
            self.sx_emitted.set(i, false);
        }
        return self.emit_region(o, b, cf, cf.entry, cfl::NONE, cfl::NONE, cfl::NONE, false);
    }

    const fn w(self: &mut Self, o: &mut String, dry: bool, s: str) {
        if !dry {
            o.push_str(s);
        }
    }

    const fn wu(self: &mut Self, o: &mut String, dry: bool, x: u64) {
        if !dry {
            o.push_u64(x);
        }
    }

    const fn ws(self: &mut Self, o: &mut String, dry: bool, s: &String) {
        if !dry {
            o.push_string(s);
        }
    }

    // A boolean-valued type: its switch discriminant carries only 0/1, so a one-case test reads as
    // the value itself (`cond`) or its negation (`!(cond)`) rather than `(cond) == 1`.
    fn is_bool(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = self.rty_y(b, t);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_BOOL;
    }

    // The condition text without one redundant enclosing paren pair. An inlined comparison already
    // wraps itself in `(...)`; the surrounding `if (...)`/`while (...)` would then spell `((x == y))`,
    // which -Wparentheses-equality rejects. Returns the inner text when `s` is exactly one balanced
    // `( .. )` group (and contains no string literal, whose bytes could unbalance the scan), else `s`.
    fn unwrap_parens(s: &String, out: &mut String) {
        let ss = s.as_str();
        let n = ss.len();
        let mut wrapped = n >= 2 && ss.byte_at(0) == 40 && ss.byte_at(n - 1) == 41;
        if wrapped {
            let mut depth = 0;
            for i in 0..n {
                let c = ss.byte_at(i);
                if c == 34 {
                    wrapped = false;
                    break;
                }
                if c == 40 {
                    depth += 1;
                } else if c == 41 {
                    depth -= 1;
                    if depth == 0 && i + 1 != n {
                        wrapped = false;
                        break;
                    }
                }
            }
        }
        if wrapped {
            out.push_str(ss.slice(1, n - 1));
        } else {
            out.push_string(s);
        }
    }

    // The value of case `k` of switch terminator `t`: the pool's 32 bits, sign-extended for an i32
    // discriminant (an enum with a negative tag).
    fn case_val(self: &Self, b: &ir::CoreBody, t: &ir::Terminator, k: u32) i64 {
        let v = (b.switch_pool[(t.sw_start + k) as usize] >> 32) as i64;
        let ty = b.operands.at(t.a as usize).ty;
        if v < 2147483648 || ty == TYPE_NONE {
            return v;
        }
        let y = self.rty_y(b, ty);
        if y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_I32 {
            return v - 4294967296;
        }
        return v;
    }

    // Append one switch-case test on the already-spelled discriminant `d`: a boolean discriminant
    // reads as `d` (value 1) or `!d` (value 0); any other discriminant as `(d) == value`. `d` for a
    // true case drops one redundant paren layer so an inlined comparison does not double up.
    fn push_case_test(self: &mut Self, o: &mut String, dry: bool, is_bool: bool, d: &String, value: i64) {
        if is_bool && value == 1 {
            if !dry {
                CEmit::unwrap_parens(d, o);
            }
        } else if is_bool && value == 0 {
            self.w(o, dry, "!");
            self.ws(o, dry, d);
        } else {
            self.w(o, dry, "(");
            self.ws(o, dry, d);
            self.w(o, dry, ") == ");
            if !dry {
                o.push_i64(value);
            }
        }
    }

    // A labeled break may leave nested loops for the follow of an enclosing loop. This is a safe
    // forward goto; no other cross-region transfer is accepted by the structured plan.
    fn outer_break_target(self: &Self, cf: &cfl::CFlow, current: u32, target: u32) bool {
        if current == cfl::NONE || target == cfl::NONE || *cf.rpo.at(target as usize) <= *cf.rpo.at(current as usize) {
            return false;
        }
        let mut h = *cf.loop_of.at(current as usize);
        if h == current {
            h = *cf.loop_parent.at(h as usize);
        }
        while h != cfl::NONE {
            if *cf.loop_follow.at(h as usize) == target {
                return true;
            }
            h = *cf.loop_parent.at(h as usize);
        }
        return false;
    }

    // Emit the region entered at `entry`, falling through when it reaches `stop`; `brk`/`cont` are
    // the enclosing loop's break/continue block targets (NONE outside a loop). Sets self.sx_fell to
    // whether control left by fall-through (vs a terminator or transfer). In `dry` mode it makes the
    // identical control decisions but writes no C and runs no statement side effects.
    fn emit_region(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        entry: u32,
        stop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
    ) bool {
        if self.sx_nest == RENDER_NEST_MAX {
            return self.fail("nesting");
        }
        self.sx_nest += 1;
        let ok = self.emit_region_i(o, b, cf, entry, stop, brk, cont, dry);
        self.sx_nest -= 1;
        return ok;
    }

    fn emit_region_i(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        mut entry: u32,
        stop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
    ) bool {
        let mut node = entry;
        loop {
            if node == stop {
                self.sx_fell = true;
                return true;
            }
            if node == cont {
                self.w(o, dry, "  continue;\n");
                self.sx_fell = false;
                return true;
            }
            if node == brk {
                self.w(o, dry, "  break;\n");
                self.sx_fell = false;
                return true;
            }
            if self.outer_break_target(cf, cont, node) {
                self.w(o, dry, "  goto bb_");
                self.wu(o, dry, node);
                self.w(o, dry, ";\n");
                self.sx_lbl.set(node as usize, true);
                self.sx_fell = false;
                return true;
            }
            if *self.sx_emitted.at(node as usize) || !cf.dominates(entry, node) {
                self.sx_goto = true;
                self.w(o, dry, "  goto bb_");
                self.wu(o, dry, node);
                self.w(o, dry, ";\n");
                self.sx_lbl.set(node as usize, true);
                self.sx_fell = false;
                return true;
            }
            if *cf.is_header.at(node as usize) {
                if !self.emit_loop(o, b, cf, node, dry) {
                    return false;
                }
                let lf = *cf.loop_follow.at(node as usize);
                if lf == cfl::NONE {
                    self.sx_fell = false;
                    return true;
                }
                node = lf;
                continue;
            }
            self.sx_emitted.set(node as usize, true);
            if *self.sx_lbl.at(node as usize) {
                self.w(o, dry, "bb_");
                self.wu(o, dry, node);
                self.w(o, dry, ": ;\n");
            }
            let blk = *b.blocks.at(node as usize);
            if !dry {
                if !self.emit_block_content(o, b, &blk) {
                    return false;
                }
            }
            if blk.term.kind == ir::TM_RETURN || blk.term.kind == ir::TM_UNREACHABLE {
                self.sx_fell = false;
                return true;
            }
            if blk.term.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, node, &mut cs) {
                    node = cs;
                    continue;
                }
                let f = *cf.follow.at(node as usize);
                let mut tail = cfl::NONE;
                if !self.emit_branch(o, b, cf, node, f, stop, brk, cont, dry, &mut tail) {
                    return false;
                }
                if tail != cfl::NONE {
                    // The otherwise region is the rest of this region: continue it here as its own
                    // region (entered at `tail`) instead of one more nested level.
                    entry = tail;
                    node = tail;
                    continue;
                }
                if f == cfl::NONE {
                    return true;
                }
                node = f;
                continue;
            }
            node = cf.succ(b, node, 0);
        }
    }

    // A switch terminator as an `if`/`else` (or `else if` chain), or a native C `switch` when the
    // arms are >= 2 integer cases outside any loop (so a case `break` cannot escape a loop). Arms
    // stop at the branch join `f`, or at the region stop when the arms do not rejoin. When no arm
    // falls through and the arms do not rejoin, the otherwise region follows the `if` unwrapped as
    // the rest of the caller's region: `tail` receives its entry and the caller continues there.
    fn emit_branch(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        x: u32,
        f: u32,
        rstop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
        tail: &mut u32,
    ) bool {
        let mut d = self.sget();
        let ok = self.emit_branch_i(o, b, cf, x, f, rstop, brk, cont, dry, &mut d, tail);
        self.sput(d);
        return ok;
    }

    fn emit_branch_i(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        x: u32,
        f: u32,
        rstop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
        d: &mut String,
        tail: &mut u32,
    ) bool {
        let arm_stop = if f != cfl::NONE {
            f;
        } else {
            rstop;
        };
        let t = b.blocks.at(x as usize).term;
        if !dry && !self.emit_operand(b, t.a, d) {
            return false;
        }
        if t.sw_len >= 2 && brk == cfl::NONE && cont == cfl::NONE {
            self.w(o, dry, "  switch (");
            self.ws(o, dry, d);
            self.w(o, dry, ") {\n");
            let mut fell = false;
            for k in 0..t.sw_len {
                self.w(o, dry, "  case ");
                if !dry {
                    o.push_i64(self.case_val(b, &t, k));
                }
                self.w(o, dry, ": {\n");
                if !self.emit_region(o, b, cf, cf.succ(b, x, k), arm_stop, brk, cont, dry) {
                    return false;
                }
                if self.sx_fell {
                    self.w(o, dry, "  break;\n");
                    fell = true;
                }
                self.w(o, dry, "  }\n");
            }
            self.w(o, dry, "  default: {\n");
            if !self.emit_region(o, b, cf, cf.succ(b, x, t.sw_len), arm_stop, brk, cont, dry) {
                return false;
            }
            if self.sx_fell {
                self.w(o, dry, "  break;\n");
                fell = true;
            }
            self.w(o, dry, "  }\n  }\n");
            self.sx_fell = fell;
            return true;
        }
        let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
        let mut ot = cf.succ(b, x, t.sw_len);
        let mut fell = false;
        // Set when the otherwise region may follow the arms unwrapped once no arm falls through.
        let mut unwrap = false;
        if !dry && t.sw_len == 1 {
            let mark = o.len();
            o.push_str("  if (");
            self.push_case_test(o, false, isb, d, self.case_val(b, &t, 0));
            o.push_str(") {\n");
            let body_mark = o.len();
            if !self.emit_region(o, b, cf, cf.succ(b, x, 0), arm_stop, brk, cont, false) {
                return false;
            }
            fell = self.sx_fell;
            if fell && o.len() == body_mark && (ot == arm_stop || !self.else_if_link(b, cf, ot, arm_stop, brk, cont)) {
                o.truncate(mark);
                if ot == arm_stop {
                    self.sx_fell = true;
                    return true;
                }
                o.push_str("  if (");
                if !self.push_case_test_negated(o, b, &t, isb, d, self.case_val(b, &t, 0)) {
                    return false;
                }
                o.push_str(") {\n");
                if !self.emit_region(o, b, cf, ot, arm_stop, brk, cont, false) {
                    return false;
                }
                o.push_str("  }\n");
                self.sx_fell = true;
                return true;
            }
            o.push_str("  }");
            unwrap = true;
        } else {
            for k in 0..t.sw_len {
                if k == 0 {
                    self.w(o, dry, "  if (");
                } else {
                    self.w(o, dry, " else if (");
                }
                self.push_case_test(o, dry, isb, d, self.case_val(b, &t, k));
                self.w(o, dry, ") {\n");
                if !self.emit_region(o, b, cf, cf.succ(b, x, k), arm_stop, brk, cont, dry) {
                    return false;
                }
                if self.sx_fell {
                    fell = true;
                }
                self.w(o, dry, "  }");
            }
        }
        // Each link marks one more block emitted, so the chain ends within the body's block count.
        loop {
            if ot == arm_stop {
                self.w(o, dry, "\n");
                fell = true;
                break;
            }
            if !fell && t.sw_len == 1 && f == cfl::NONE {
                self.w(o, dry, "\n");
                *tail = ot;
                return true;
            }
            if !self.else_if_link(b, cf, ot, arm_stop, brk, cont) {
                if unwrap && !fell {
                    self.w(o, dry, "\n");
                    return self.emit_region(o, b, cf, ot, arm_stop, brk, cont, dry);
                }
                let else_mark = o.len();
                self.w(o, dry, " else {\n");
                let else_body = o.len();
                if !self.emit_region(o, b, cf, ot, arm_stop, brk, cont, dry) {
                    return false;
                }
                if self.sx_fell {
                    fell = true;
                }
                if !dry && self.sx_fell && o.len() == else_body {
                    o.truncate(else_mark);
                    o.push_str("\n");
                } else {
                    self.w(o, dry, "  }\n");
                }
                break;
            }
            // The link as a flat `else if`: the decisions its own region would make (block emitted,
            // test, true arm, the join counted as a fall-through) without one more level.
            self.sx_emitted.set(ot as usize, true);
            let lt = b.blocks.at(ot as usize).term;
            d.clear();
            if !dry && !self.emit_operand(b, lt.a, d) {
                return false;
            }
            self.w(o, dry, " else if (");
            let lb = self.is_bool(b, b.operands.at(lt.a as usize).ty);
            self.push_case_test(o, dry, lb, d, self.case_val(b, &lt, 0));
            self.w(o, dry, ") {\n");
            if !self.emit_region(o, b, cf, cf.succ(b, ot, 0), arm_stop, brk, cont, dry) {
                return false;
            }
            if self.sx_fell || *cf.follow.at(ot as usize) != cfl::NONE {
                fell = true;
            }
            self.w(o, dry, "  }");
            ot = cf.succ(b, ot, 1);
        }
        self.sx_fell = fell;
        return true;
    }

    // Whether the otherwise region entered at `ot` continues the chain as one more `else if`: a
    // two-way test reached only from the branch before it, with every statement elided (nothing
    // spells before the test), rejoining at the chain's stop or not at all. The inputs are the ones
    // the planning pass sees too, so both passes decide alike, and a long `else if` chain renders
    // flat instead of one nested region per arm.
    fn else_if_link(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, ot: u32, stop: u32, brk: u32, cont: u32) bool {
        let t = b.blocks.at(ot as usize).term;
        if t.kind != ir::TM_SWITCH || t.sw_len != 1 || *cf.preds.at(ot as usize) != 1 || ot == brk || ot == cont {
            return false;
        }
        let f = *cf.follow.at(ot as usize);
        let mut cs = cfl::NONE;
        return (f == cfl::NONE || f == stop) && !self.outer_break_target(cf, cont, ot) && !self.const_switch_succ(
            b,
            cf,
            ot,
            &mut cs,
        ) && self.block_output_empty(b, ot);
    }

    fn push_case_test_negated(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        t: &ir::Terminator,
        is_bool: bool,
        d: &String,
        value: i64,
    ) bool {
        if is_bool && value == 1 {
            if !self.emit_cond_negated(b, t.a, o) {
                return false;
            }
        } else if is_bool && value == 0 {
            CEmit::unwrap_parens(d, o);
        } else {
            o.push_str("(");
            o.push_string(d);
            o.push_str(") != ");
            o.push_i64(value);
        }
        return true;
    }

    // Find a unique `i = i +/- 1` back-edge update for a Boolean comparison header.
    fn counted_loop_step(
        self: &mut Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        h: u32,
        index_out: &mut u32,
        place: &mut u32,
        rvalue: &mut u32,
        step: &mut String,
    ) bool {
        let t = b.blocks.at(h as usize).term;
        let cop = *b.operands.at(t.a as usize);
        if cop.kind != ir::OP_COPY && cop.kind != ir::OP_MOVE {
            return false;
        }
        let cp = *b.places.at(cop.data as usize);
        if cp.proj_len != 0 || *self.sx_inline.at(cp.base as usize) == ir::IR_NONE {
            return false;
        }
        let crv = *b.rvalues.at((*self.sx_inline.at(cp.base as usize)) as usize);
        if crv.kind != ir::RV_BINARY {
            return false;
        }
        let ct = crv.c as tt::TokenType;
        if ct != tt::TokenType::LessThan && ct != tt::TokenType::LessThanEqual && ct != tt::TokenType::GreaterThan && ct != tt::TokenType::GreaterThanEqual {
            return false;
        }
        let lo = *b.operands.at(crv.a as usize);
        if lo.kind != ir::OP_COPY && lo.kind != ir::OP_MOVE {
            return false;
        }
        let lp = *b.places.at(lo.data as usize);
        if lp.proj_len != 0 {
            return false;
        }
        let index = lp.base;
        let mut found = false;
        for pi in *cf.pred_start.at(h as usize)..*cf.pred_start.at((h + 1) as usize) {
            let bi = *cf.pred_list.at(pi as usize);
            if bi == h {
                continue;
            }
            let bb = *b.blocks.at(bi as usize);
            if bb.term.kind != ir::TM_GOTO {
                continue;
            }
            let mut si = bb.stmt_len;
            while si > 0 {
                si -= 1;
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
                    continue;
                }
                if s.kind != ir::ST_ASSIGN {
                    break;
                }
                let dp = *b.places.at(s.place as usize);
                let rv = *b.rvalues.at(s.rvalue as usize);
                if dp.proj_len != 0 || dp.base != index || rv.kind != ir::RV_BINARY || !self.op_is_bare_local(
                    b,
                    rv.a,
                    index,
                ) {
                    break;
                }
                let ot = rv.c as tt::TokenType;
                if ot != tt::TokenType::Plus && ot != tt::TokenType::Minus {
                    break;
                }
                let ro = *b.operands.at(rv.b as usize);
                if ro.kind != ir::OP_CONST {
                    break;
                }
                let c = *b.constants.at(ro.data as usize);
                if c.kind != ir::CK_INT || c.val != 1 {
                    break;
                }
                // An integer step overflow traps: `++`/`--` only where the header test bounds it.
                let ib = self.int_builtin(b, b.locals.at(index as usize).ty);
                if (int_signed(ib) || bt_is_unsigned(ib)) && !self.step_bounded(b, cf, h, &crv, ot, bb.stmt_start + si) {
                    break;
                }
                if found {
                    return false;
                }
                found = true;
                *index_out = index;
                *place = s.place;
                *rvalue = s.rvalue;
                self.lspell(index, step);
                step.push_str(mbe::if_s(ot == tt::TokenType::Plus, "++", "--"));
                break;
            }
        }
        return found;
    }

    // Whether integer step `i = i +/- 1` (statement `step`) of loop `h`, whose header tests `crv`
    // (`i < e` or `i > e`, `i` the left operand), stays in range: `i < e` bounds `i + 1` by `e` and
    // `i > e` bounds `i - 1` by `e` when `e` has `i`'s type and nothing else in the loop writes `i`.
    fn step_bounded(
        self: &mut Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        h: u32,
        crv: &ir::Rvalue,
        ot: tt::TokenType,
        step: u32,
    ) bool {
        let ct = crv.c as tt::TokenType;
        if !(ct == tt::TokenType::LessThan && ot == tt::TokenType::Plus || ct == tt::TokenType::GreaterThan && ot == tt::TokenType::Minus) {
            return false;
        }
        let index = b.places.at(b.operands.at(crv.a as usize).data as usize).base as usize;
        if self.int_builtin(b, b.operands.at(crv.b as usize).ty) != self.int_builtin(b, b.locals.at(index).ty) {
            return false;
        }
        self.wx_build(b);
        if self.wx_addr[index] {
            return false;
        }
        for k in self.wx_woff[index]..self.wx_woff[index + 1] {
            let si = self.wx_wst[k as usize];
            if si != step && CEmit::in_loop(cf, self.wx_sblk[si as usize], h) {
                return false;
            }
        }
        for k in self.wx_coff[index]..self.wx_coff[index + 1] {
            if CEmit::in_loop(cf, self.wx_cblk[k as usize], h) {
                return false;
            }
        }
        return true;
    }

    // Whether block `x` (ir::IR_NONE: none) lies in loop `h` or a loop nested in it.
    fn in_loop(cf: &cfl::CFlow, x: u32, h: u32) bool {
        if x == ir::IR_NONE {
            return false;
        }
        let mut l = *cf.loop_of.at(x as usize);
        for _ in 0..cf.n {
            if l == h {
                return true;
            }
            if l == cfl::NONE {
                return false;
            }
            l = *cf.loop_parent.at(l as usize);
        }
        return false;
    }

    // Move an immediately preceding fused zero-initializer into a counted `for` header.
    fn take_loop_init(self: &mut Self, o: &mut String, b: &ir::CoreBody, index: u32, init: &mut String) bool {
        let local = *b.locals.at(index as usize);
        if local.dkind == ir::LK_LET {
            return false;
        }
        if !*self.sx_fuse.at(index as usize) || !*self.sx_declared.at(index as usize) {
            return false;
        }
        let mut rid = ir::IR_NONE;
        self.wx_build(b);
        for k in self.wx_woff[index as usize]..self.wx_woff[index as usize + 1] {
            let s = *b.statements.at(self.wx_wst[k as usize] as usize);
            if b.places.at(s.place as usize).proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind != ir::RV_USE {
                continue;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind != ir::OP_CONST || b.constants.at(op.data as usize).kind != ir::CK_INT || b.constants.at(
                op.data as usize,
            ).val != 0 || rid != ir::IR_NONE {
                return false;
            }
            rid = s.rvalue;
        }
        if rid == ir::IR_NONE {
            return false;
        }
        let mut name = self.sget();
        self.lspell(index, &mut name);
        let okd = self.ty_c(b.module, local.ty, name.as_str(), init);
        self.sput(name);
        if !okd {
            return false;
        }
        init.push_str(" = ");
        if !self.emit_rvalue(b, rid, init) {
            return false;
        }
        // The declaration line already spelled is `  <init>;\n`, the tail of the body so far.
        let n = init.len() + 4;
        if o.len() < n {
            return false;
        }
        let start = o.len() - n;
        let tail = o.as_str().slice(start, o.len());
        if tail.slice(0, 2) != "  " || tail.slice(2, n - 2) != init.as_str() || tail.slice(n - 2, n) != ";\n" {
            return false;
        }
        o.truncate(start);
        return true;
    }

    fn do_loop_latch(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, h: u32, out: &mut u32) bool {
        if b.blocks.at(h as usize).term.kind != ir::TM_GOTO {
            return false;
        }
        let lf = *cf.loop_follow.at(h as usize);
        let mut found = cfl::NONE;
        for p in 0..cf.n {
            if !*cf.reach.at(p as usize) || *cf.loop_of.at(p as usize) != h {
                continue;
            }
            let t = b.blocks.at(p as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 || !self.block_output_empty(b, p) {
                continue;
            }
            let raw_case = (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32;
            let case_t = *cf.thread.at(raw_case as usize);
            let other = *cf.thread.at(t.t0 as usize);
            if !(case_t == h && other == lf || case_t == lf && other == h) {
                continue;
            }
            if found != cfl::NONE {
                return false;
            }
            found = p;
        }
        *out = found;
        return found != cfl::NONE;
    }

    // A loop header as `while (cond) { body }` when it only tests a condition, otherwise
    // `while (1) { <header>; if (cond) { body } else break; }`: the body's stop is the header, so a
    // natural back-edge falls through to the closing brace (re-iterates) and only a real
    // `break`/`continue` spells one. An unconditional header is an infinite `while (1)`.
    fn emit_loop(self: &mut Self, o: &mut String, b: &ir::CoreBody, cf: &cfl::CFlow, h: u32, dry: bool) bool {
        self.sx_emitted.set(h as usize, true);
        if *self.sx_lbl.at(h as usize) {
            self.w(o, dry, "bb_");
            self.wu(o, dry, h);
            self.w(o, dry, ": ;\n");
        }
        let lf = *cf.loop_follow.at(h as usize);
        let blk = *b.blocks.at(h as usize);
        let t = blk.term;
        let mut latch = cfl::NONE;
        if self.do_loop_latch(b, cf, h, &mut latch) {
            self.sx_emitted.set(latch as usize, true);
            self.w(o, dry, "  do {\n");
            if !dry && !self.emit_block_content(o, b, &blk) {
                return false;
            }
            if !self.emit_region(o, b, cf, cf.succ(b, h, 0), latch, lf, latch, dry) {
                return false;
            }
            let lt = b.blocks.at(latch as usize).term;
            let mut d = self.sget();
            if !dry && !self.emit_operand(b, lt.a, &mut d) {
                self.sput(d);
                return false;
            }
            self.w(o, dry, "  } while (");
            let raw_case = (b.switch_pool[lt.sw_start as usize] & 0xFFFFFFFFu64) as u32;
            let case_t = *cf.thread.at(raw_case as usize);
            let isb = self.is_bool(b, b.operands.at(lt.a as usize).ty);
            let mut ok = true;
            if case_t == h {
                self.push_case_test(o, dry, isb, &d, self.case_val(b, &lt, 0));
            } else if !dry {
                ok = self.push_case_test_negated(o, b, &lt, isb, &d, self.case_val(b, &lt, 0));
            }
            self.sput(d);
            if !ok {
                return false;
            }
            self.w(o, dry, ");\n");
            return true;
        }
        // A single-test header whose false edge leaves the loop and whose body carries no code before
        // the test reads as a direct `while (cond)`. The condition arm (succ 0) is the body; the
        // otherwise arm is the loop exit.
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 && self.block_output_empty(b, h) {
            let body = cf.succ(b, h, 0);
            let exit_tgt = cf.succ(b, h, 1);
            if exit_tgt == lf && body != lf {
                let mut d = self.sget();
                if !dry && !self.emit_operand(b, t.a, &mut d) {
                    self.sput(d);
                    return false;
                }
                let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
                let mut loop_index = ir::IR_NONE;
                let mut skip_place = ir::IR_NONE;
                let mut skip_rvalue = ir::IR_NONE;
                let mut step = self.sget();
                let counted = self.counted_loop_step(
                    b,
                    cf,
                    h,
                    &mut loop_index,
                    &mut skip_place,
                    &mut skip_rvalue,
                    &mut step,
                );
                let mut init = self.sget();
                let took_init = counted && !dry && self.take_loop_init(o, b, loop_index, &mut init);
                if counted {
                    self.w(o, dry, "  for (");
                    if took_init {
                        self.ws(o, dry, &init);
                    }
                    self.w(o, dry, "; ");
                } else {
                    self.w(o, dry, "  while (");
                }
                self.push_case_test(o, dry, isb, &d, self.case_val(b, &t, 0));
                if counted {
                    self.w(o, dry, "; ");
                    self.ws(o, dry, &step);
                }
                self.w(o, dry, ") {\n");
                self.sput(d);
                self.sput(step);
                self.sput(init);
                let old_place = self.sx_skip_place;
                let old_rvalue = self.sx_skip_rvalue;
                if counted {
                    self.sx_skip_place = skip_place;
                    self.sx_skip_rvalue = skip_rvalue;
                }
                let body_ok = self.emit_region(o, b, cf, body, h, lf, h, dry);
                self.sx_skip_place = old_place;
                self.sx_skip_rvalue = old_rvalue;
                if !body_ok {
                    return false;
                }
                self.w(o, dry, "  }\n");
                return true;
            }
        }
        self.w(o, dry, "  while (1) {\n");
        // A loop header never ends in a return, so the block content has no return to forward.
        if !dry && !self.emit_block_content(o, b, &blk) {
            return false;
        }
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 {
            let mut d = self.sget();
            if !dry && !self.emit_operand(b, t.a, &mut d) {
                self.sput(d);
                return false;
            }
            let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
            self.w(o, dry, "  if (");
            self.push_case_test(o, dry, isb, &d, self.case_val(b, &t, 0));
            self.sput(d);
            self.w(o, dry, ") {\n");
            if !self.emit_region(o, b, cf, cf.succ(b, h, 0), h, lf, h, dry) {
                return false;
            }
            self.w(o, dry, "  }");
            let exit_tgt = cf.succ(b, h, 1);
            if exit_tgt == lf {
                self.w(o, dry, " else {\n  break;\n  }\n");
            } else {
                self.w(o, dry, " else {\n");
                if !self.emit_region(o, b, cf, exit_tgt, h, lf, h, dry) {
                    return false;
                }
                self.w(o, dry, "  }\n");
            }
        } else if t.kind == ir::TM_SWITCH {
            let mut tail = cfl::NONE;
            if !self.emit_branch(o, b, cf, h, cfl::NONE, h, lf, h, dry, &mut tail) {
                return false;
            }
            if tail != cfl::NONE && !self.emit_region(o, b, cf, tail, h, lf, h, dry) {
                return false;
            }
        } else if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
            if !self.emit_region(o, b, cf, cf.succ(b, h, 0), h, lf, h, dry) {
                return false;
            }
        }
        self.w(o, dry, "  }\n");
        return true;
    }

    /// Emit a closure body: `<ret> <sym>(<sym>_env *const __env, <params...>)` with
    /// captures read through the env; `env_out` receives the env struct typedef (empty when the
    /// closure captures nothing; it is then a plain function taking only its params).
    pub fn emit_closure(self: &mut Self, b: &ir::CoreBody, cm: ModuleId, cnode: NodeId, sym: str, env_out: &mut String) bool {
        self.fn_attrs.truncate(0);
        self.err = "";
        self.arr_ret = false;
        let mark = self.out.len();
        let pm = self.pr.start();
        let d0 = self.pr.ns[prb::P_DECL];
        let a0 = self.pr.an[prb::P_DECL];
        let b0 = self.pr.ab[prb::P_DECL];
        let ok = self.emit_closure_inner(b, cm, cnode, sym, env_out);
        self.pr.stop_less(prb::P_RENDER, pm, prb::P_DECL, d0, a0, b0);
        self.cap_base = 0;
        self.cap_on = false;
        self.cap_mut = 0;
        self.cap_pool.clear();
        self.cap_off.clear();
        self.cap_len.clear();
        return self.close_body(b, mark, ok);
    }

    fn emit_closure_inner(
        self: &mut Self,
        b: &ir::CoreBody,
        cm: ModuleId,
        cnode: NodeId,
        sym: str,
        env_out: &mut String,
    ) bool {
        let ca = self.p().module_ast_const(cm);
        let cf = unsafe &*(*ca).closure_fact(cnode);
        let np = cf.nparams;
        let ncaps = cf.ncaps;
        if b.args != np + ncaps {
            return self.fail("closure-args");
        }
        self.cap_base = b.returns + np;
        self.cap_on = ncaps != 0;
        self.cap_mut = cf.mut_caps | cf.ref_caps;
        let dm = self.pr.start();
        self.setup_locals(b);
        self.pr.stop(prb::P_DECL, dm);
        for k in 0..ncaps {
            let csp = unsafe (*ca).caps_of(cf)[k as usize].name;
            if csp.end <= csp.start {
                return self.fail("closure-cap-name");
            }
            let off = self.cap_pool.len();
            self.mg.ident(cm, csp, &mut self.cap_pool);
            self.cap_off.push(off as u32);
            self.cap_len.push((self.cap_pool.len() - off) as u32);
        }
        let mut env_pre = false; // the declaration pass defined this env (aggregate-embedded)
        let mut eh0: u64 = 0; // the env hash, hoisted for the shard capture below
        if ncaps != 0 {
            let mut enm = String::from_str(sym);
            enm.push_str("_env");
            let eh = enm.as_str().hash();
            env_pre = self.env_skip.contains_key(&eh);
            if !env_pre {
                // A closure can emit more than once (seed + drained instances): one env only.
                self.env_skip.insert(eh, 1);
                self.env_hashes.push(eh);
            }
            eh0 = eh;
        }
        if ncaps != 0 && !env_pre {
            // named struct + a fwd typedef in the header's FORWARD section: aggregates and protos
            // may name the env before its body appears.
            self.env_fwd.push_str("typedef struct ");
            self.env_fwd.push_str(sym);
            self.env_fwd.push_str("_env ");
            self.env_fwd.push_str(sym);
            self.env_fwd.push_str("_env;\n");
            env_out.push_str("struct ");
            env_out.push_str(sym);
            env_out.push_str("_env { ");
            let mut cmat9: usize = 0;
            for k in 0..ncaps {
                let l = (self.cap_base + k) as usize;
                if self.erased(b, b.locals.at(l).ty) {
                    // Zero-sized captures take no env storage (reads are erased).
                    continue;
                }
                cmat9 += 1;
                let cs = (*self.cap_off.at(k as usize)) as usize;
                let mut cname = String::new();
                let by_ptr = ((cf.mut_caps | cf.ref_caps) >> k as u64 & 1u64) != 0;
                if (cf.ref_caps >> k as u64 & 1u64) != 0 {
                    // Only owning aggregates (and arrays of them) are borrowed: a leading `const`
                    // qualifies the pointee, which may be a non-`mut` (C `const`) binding.
                    env_out.push_str("const ");
                }
                cname.push_str(mbe::if_s(by_ptr, "(*", ""));
                cname.push_str(self.cap_pool.as_str().slice(cs, cs + (*self.cap_len.at(k as usize)) as usize));
                cname.push_str(mbe::if_s(by_ptr, ")", ""));
                if !self.mg.ctype(b.module, b.locals.at(l).ty, cname.as_str(), env_out) {
                    return self.fail("closure-cap-ty");
                }
                env_out.push_str("; ");
            }
            if cmat9 == 0 {
                // C forbids an empty struct (see tu.spc).
                env_out.push_str("unsigned char _sc_zenv; ");
            }
            env_out.push_str("};\n");
            if self.sh_on {
                self.sh_env_k.push(eh0);
                self.sh_env_e.push(self.env_fwd.len() as u32);
            }
        }
        let mut rty = TYPE_NONE;
        if b.returns == 1 {
            rty = b.locals.at(0).ty;
        }
        if rty != TYPE_NONE && self.erased(b, rty) {
            rty = TYPE_NONE;
        }
        let hmark = self.out.len();
        let mut out = replace(&mut self.out, String::new());
        self.arr_ret = rty != TYPE_NONE && self.arr_n(b, rty) > 0;
        let ok0 = if b.returns > 1 || self.arr_ret {
            // Several results, or a fixed array, return in their carrier (`Mangler::ret_pack`).
            let mut tys = Vector::<TypeId>::new();
            for r in 0..b.returns {
                tys.push(b.locals.at(r as usize).ty);
            }
            self.mret.truncate(0);
            let okp = self.mg.ret_pack(b.module, &tys, &mut self.mret);
            out.push_string(&self.mret);
            okp;
        } else {
            self.ty_c(b.module, rty, "", &mut out);
        };
        self.out = out;
        let hdecl = self.out.len() + 1;
        if ok0 {
            // extern: dyn-fn thunks in the instance TU call hoisted closures by name, and each
            // closure emits exactly once (its symbol carries module + node + instance suffix).
            self.out.push_str(" ");
            self.out.push_str(sym);
            self.out.push_str("(");
            if ncaps != 0 {
                // The body reads its captures through the env: it needs the definition.
                self.mg.need_name(eh0, true);
                self.out.push_str(sym);
                // A following param supplies its own comma.
                self.out.push_str("_env *const __env");
            }
        }

        if !ok0 {
            return false;
        }
        let mut np9: u32 = 0;
        for i in 0..np {
            let l = (b.returns + i) as usize;
            if self.erased(b, b.locals.at(l).ty) {
                // Zero-sized by-value params take no C parameter.
                continue;
            }
            if np9 != 0 || ncaps != 0 {
                self.out.push_str(", ");
            }
            np9 += 1;
            let mut nm = self.sget();
            self.lspell(l as u32, &mut nm);
            let mut out = replace(&mut self.out, String::new());
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut out);
            self.out = out;
            self.sput(nm);
            if !ok {
                return false;
            }
        }
        if np9 == 0 && ncaps == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(")");
        let mut out2 = replace(&mut self.out, String::new());
        let okd = self.fn_decl(b.module, pick(self.arr_ret, TYPE_NONE, rty), hmark, hdecl, &mut out2);
        self.out = out2;
        if !okd {
            return false;
        }
        self.out.push_str(" {\n");
        return self.emit_body_core(b);
    }

    // When untyped local `l` receives a MULTI-return call, its C type into `sym`: the callee's
    // `<sym>_ret`, or the result pack of a function value's type (field names `_N` match tuple
    // reads).
    fn untyped_ret_struct(self: &mut Self, b: &ir::CoreBody, l: u32, sym: &mut String) bool {
        return self.untyped_ret_struct_d(b, l, sym, 0);
    }
    fn untyped_ret_struct_d(self: &mut Self, b: &ir::CoreBody, l: u32, sym: &mut String, depth: u32) bool {
        if depth > 4 {
            return false;
        }
        // An untyped COPY of an untyped local chases the source's writer.
        self.wx_build(b);
        for k in self.wx_woff[l as usize]..self.wx_woff[l as usize + 1] {
            let st = *b.statements.at(self.wx_wst[k as usize] as usize);
            if b.places.at(st.place as usize).proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.ty == TYPE_NONE && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                    let spl = *b.places.at(op.data as usize);
                    if spl.proj_len == 0 && spl.base != l && b.locals.at(spl.base as usize).ty == TYPE_NONE {
                        if self.untyped_ret_struct_d(b, spl.base, sym, depth + 1) {
                            return true;
                        }
                    }
                }
            }
        }
        for k in self.wx_coff[l as usize]..self.wx_coff[l as usize + 1] {
            let tm = b.blocks.at(self.wx_cblk[k as usize] as usize).term;
            let dp = *b.places.at(b.dest_pool[tm.dests_start as usize] as usize);
            if dp.proj_len != 0 {
                continue;
            }
            if tm.callee.node == NODE_NONE {
                if tm.a != ir::IR_NONE && self.mg.fn_ret_pack(b.module, b.operands.at(tm.a as usize).ty, sym) {
                    return true;
                }
                continue;
            }
            let ca = self.p().module_ast_const(tm.callee.module);
            let fd = unsafe (*ca).at_const(tm.callee.node);
            if fd.kind != NodeKind::NODE_FUNCTION || fd.as_data.function.returns.len < 2 {
                continue;
            }
            // Through a vtable the results arrive in the slot's carrier: the interface's result list
            // under the dyn type's arguments (`dyn_ret`).
            let mut dm0 = b.module;
            let mut dt0 = TYPE_NONE;
            let mut st0: u32 = 0;
            if self.dyn_recv_of(b, &tm, &mut dm0, &mut dt0, &mut st0) != ir::IR_NONE {
                let mut it = TyInstance { decl: NODE_NONE };
                if !self.dyn_iface_inst(dm0, dt0, tm.callee, &mut it) {
                    return false;
                }
                let ifn = unsafe (*self.p().module_ast_const(it.module)).at_const(it.decl).as_data.interface_def;
                let nb = self.mg.push_generics(it.module, ifn.generics, dm0, &it);
                let mut tys = Vector::<TypeId>::new();
                let mut rtys = Vector::<TypeId>::new();
                let ok = self.slot_types(
                    tm.callee.module,
                    fd.as_data.function.params,
                    fd.as_data.function.returns,
                    1,
                    &mut tys,
                    &mut rtys,
                ) && self.mg.ret_pack(tm.callee.module, &rtys, sym);
                self.mg.pop_subs(nb);
                return ok;
            }
            if !self.term_callee_sym(b, &tm, false, sym) {
                return false;
            }
            sym.push_str("_ret");
            return true;
        }
        return false;
    }

    // The recorded type of whatever writes untyped local `l` (an rvalue's target, an operand's
    // type, or a call destination's declared return); TYPE_NONE when nothing carries one.
    fn untyped_local_ty(self: &Self, b: &ir::CoreBody, l: u32) TypeId {
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN || s.place == ir::IR_NONE {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.base != l || pl.proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.target != TYPE_NONE {
                return rv.target;
            }
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.ty != TYPE_NONE {
                    return op.ty;
                }
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    let spl = *b.places.at(op.data as usize);
                    if spl.proj_len == 0 && spl.base != l {
                        let src_ty = b.locals.at(spl.base as usize).ty;
                        if src_ty != TYPE_NONE {
                            return src_ty;
                        }
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || t.dests_len != 1 || t.callee.node == NODE_NONE || t.callee.module != b.module {
                // Foreign return types live in a foreign pool: unusable here.
                continue;
            }
            let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
            if dp.base != l || dp.proj_len != 0 {
                continue;
            }
            if unsafe (*self.p().module_ast_const(t.callee.module)).at_const(t.callee.node).kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let rt = self.fn_ret_ty(t.callee.module, t.callee.node);
            if rt != TYPE_NONE {
                return rt;
            }
        }
        return TYPE_NONE;
    }

    // The element count an open-array local is filled with (its RV_REPEAT count or array-literal
    // arity); 0 = no filler found.
    fn filled_len(self: &Self, b: &ir::CoreBody, l: u32) u64 {
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN || s.place == ir::IR_NONE {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.base != l || pl.proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY {
                return rv.b;
            }
            if rv.kind == ir::RV_REPEAT {
                let cnt = *b.operands.at(rv.b as usize);
                if cnt.kind == ir::OP_CONST {
                    let c = *b.constants.at(cnt.data as usize);
                    if c.kind == ir::CK_INT && c.val > 0 {
                        return c.val as u64;
                    }
                }
            }
        }
        return 0;
    }

    // Does this struct literal fill any fixed-array member from a place (C cannot initialize an
    // array member from a variable)?
    fn agg_has_array_field(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == ir::IR_NONE {
                continue;
            }
            let op = *b.operands.at(opid as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                continue;
            }
            let y = self.rty_y(b, op.ty);
            if y.kind == TypeKind::TYPE_ARRAY {
                // Len 0 = a generic [T; N] interned unsized: still a C array field.
                return true;
            }
        }
        return false;
    }

    // `lhs = (T){ ..., .arr = {0}, ... }; memcpy(&lhs.arr, src, sizeof(T[n])); ...`.
    fn emit_struct_store_arrays(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let sdecl = self.agg_decl(b, rv.target);
        if sdecl == NODE_NONE {
            return self.fail("agg-struct");
        }
        let am = self.agg_module(b, rv.target);
        let sa = self.p().module_ast_const(am);
        let is_tuple = unsafe (*sa).at_const(sdecl).as_data.aggregate.is_tuple;
        let ms = unsafe (*sa).at_const(sdecl).as_data.aggregate.members;
        if ms.len != rv.b {
            return self.fail("agg-arity");
        }
        let mut lhs = self.sget();
        let mut ok = self.emit_place(b, s.place, &mut lhs);
        let mut post = self.sget();
        let mut fnm = self.sget();
        if ok {
            o.push_str("  ");
            o.push_string(&lhs);
            o.push_str(" = (");
            ok = self.ty_c(b.module, rv.target, "", o);
        }
        if ok {
            o.push_str("){ ");
            let mut emitted: u32 = 0;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue;
                }
                {
                    let aty9 = b.operands.at(opid as usize).ty;
                    if aty9 != TYPE_NONE && self.erased(b, aty9) {
                        // Zero-sized field: no C member to store.
                        continue;
                    }
                }
                let fid = unsafe (*sa).list(ms)[i as usize];
                fnm.clear();
                if is_tuple {
                    fnm.push_str("_");
                    fnm.push_u64(i);
                } else {
                    self.mg.ident(
                        am,
                        unsafe (*sa).at_const(unsafe (*sa).at_const(fid).as_data.field.name).as_data.name.text,
                        &mut fnm,
                    );
                }
                let op = *b.operands.at(opid as usize);
                let y = self.rty_y(b, op.ty);
                let is_arr = (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && y.kind == TypeKind::TYPE_ARRAY;
                if is_arr {
                    // Left out of the compound literal on purpose: C zero-inits any non-designated
                    // field, and the memcpy below fills it. Emitting `.arr = {0}` for an array of
                    // aggregates would trip -Werror=missing-braces on stricter cc lanes.
                    let mut dstA = self.sget();
                    dstA.push_string(&lhs);
                    dstA.push_str(".");
                    dstA.push_string(&fnm);
                    ok = self.emit_array_copy(&mut post, b, &dstA, op.data);
                    self.sput(dstA);
                    continue;
                }
                if emitted != 0 {
                    o.push_str(", ");
                }
                o.push_str(".");
                o.push_string(&fnm);
                o.push_str(" = ");
                ok = self.emit_operand(b, opid, o);
                emitted += 1;
            }
            if emitted == 0 {
                o.push_str("0");
            }
            o.push_str(" };\n");
            o.push_string(&post);
        }
        self.sput(lhs);
        self.sput(post);
        self.sput(fnm);
        return ok;
    }

    // `lhs = (E){ .tag = T };` then one store per payload member: C cannot initialize an array
    // payload member from a variable (see `emit_member_store`).
    fn emit_variant_store_arrays(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let edecl = self.agg_decl(b, rv.target);
        if edecl == NODE_NONE {
            return self.fail("agg-enum");
        }
        let am = self.agg_module(b, rv.target);
        let ea = self.p().module_ast_const(am);
        let vn = unsafe (*ea).at_const(rv.item.node);
        let pl = vn.as_data.variant.payload;
        if pl.len != rv.b {
            return self.fail("agg-arity");
        }
        let mut lhs = self.sget();
        let mut ok = self.emit_place(b, s.place, &mut lhs);
        if ok {
            o.push_str("  ");
            o.push_string(&lhs);
            o.push_str(" = (");
            ok = self.ty_c(b.module, rv.target, "", o);
            o.push_str("){ .tag = ");
            self.mg.enum_tag(am, edecl, rv.item.node, o);
            o.push_str(" };\n");
        }
        let mut mem = self.sget();
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let opid = b.oper_pool[(rv.a + i) as usize];
            let aty = b.operands.at(opid as usize).ty;
            if aty != TYPE_NONE && self.erased(b, aty) {
                // Zero-sized payload member: no C storage.
                continue;
            }
            mem.clear();
            mem.push_string(&lhs);
            mem.push_str(".payload.");
            self.mg.ident(am, unsafe (*ea).at_const(vn.as_data.variant.name).as_data.name.text, &mut mem);
            mem.push_str(".");
            let pid = unsafe (*ea).list(pl)[i as usize];
            if vn.as_data.variant.struct_payload && unsafe (*ea).at_const(pid).kind == NodeKind::NODE_FIELD {
                self.mg.ident(
                    am,
                    unsafe (*ea).at_const(unsafe (*ea).at_const(pid).as_data.field.name).as_data.name.text,
                    &mut mem,
                );
            } else {
                mem.push_str("_");
                mem.push_u64(i);
            }
            ok = self.emit_member_store(o, b, &mem, opid);
        }
        self.sput(lhs);
        self.sput(mem);
        return ok;
    }

    // A fixed-array literal whose temporary was coalesced with its final local can initialize that
    // local directly. C array assignment is illegal, so this must run at the declaration point.
    fn emit_array_init(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 {
            return false;
        }
        let root = *self.sx_coal.at(pl.base as usize);
        if !*self.sx_fuse.at(root as usize) || *self.sx_declared.at(root as usize) {
            return false;
        }
        let mut name = self.sget();
        self.lspell(root, &mut name);
        o.push_str("  ");
        let okd = self.ty_c(b.module, b.locals.at(root as usize).ty, name.as_str(), o);
        self.sput(name);
        if !okd {
            return false;
        }
        self.sx_declared.set(root as usize, true);
        o.push_str(" = { ");
        let ok = self.emit_lit_elems(o, b, rv);
        o.push_str(" };\n");
        return ok;
    }

    fn emit_stmt(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
            // Markers carry no C.
            return true;
        }
        if s.kind == ir::ST_ASSIGN && s.place == self.sx_skip_place && s.rvalue == self.sx_skip_rvalue {
            return true;
        }
        if self.is_dead_store(b, s) {
            // Store to a never-read local: the pure rvalue has no side effect.
            return true;
        }
        if self.is_coalesced_store(b, s) {
            // `_dst = move _src` collapsed: both spell the same C variable.
            return true;
        }
        if self.is_inlined_store(b, s) {
            // Single-use pure temp: its rvalue reappears at the read.
            return true;
        }
        if s.kind != ir::ST_ASSIGN {
            return self.fail("stmt");
        }
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_ASM as u32 {
                return self.emit_asm_stmt(o, b, &rv0);
            }
            if self.vec_rv(b, &rv0) {
                return self.emit_vec_store(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_USE && self.ml_chunks.len() != 0 && b.places.at(s.place as usize).proj_len == 0 && self.ml_alias[b.places.at(
                s.place as usize,
            ).base as usize] != ir::IR_NONE && self.ml_src(b.places.at(s.place as usize).base) != ir::IR_NONE {
                // The copy of a comparison's result its `choose` reads as the comparison's lane temps.
                return true;
            }
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_SAFEPOINT as u32 {
                if self.ticks_on(b) {
                    o.push_str("  if (__builtin_expect(--__sc_spc == 0, 0)) __sc_spc = __sc_preempt_check();\n");
                }
                return true;
            }
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_SAFEPOINT_C as u32 {
                // Combined form: identical hot tick; the cold half also asks the runtime's cancel
                // hook, and the switch on the result enters the frame's cancellation ladder.
                let mut cp = self.sget();
                let okc = self.emit_place(b, s.place, &mut cp);
                if okc {
                    o.push_str("  ");
                    o.push_string(&cp);
                    o.push_str(" = 0;\n");
                    if self.ticks_on(b) {
                        o.push_str("  if (__builtin_expect(--__sc_spc == 0, 0)) { __sc_spc = __sc_preempt_check(); ");
                        o.push_string(&cp);
                        o.push_str(" = __sc_cancel_tick(); }\n");
                    }
                }
                self.sput(cp);
                return okc;
            }
            if rv0.kind == ir::RV_INTRINSIC && (rv0.c as u32 == ir::IN_VA_START as u32 || rv0.c as u32 == ir::IN_VA_END as u32) {
                // The assignment's place IS the va_list lvalue the macro mutates.
                let mut mac = String::from_str(
                    mbe::if_s(rv0.c as u32 == ir::IN_VA_START as u32, "  va_start(", "  va_end("),
                );
                if !self.emit_place(b, s.place, &mut mac) {
                    return false;
                }
                if rv0.c as u32 == ir::IN_VA_START as u32 && rv0.b != 0 {
                    mac.push_str(", ");
                    if !self.emit_operand(b, b.oper_pool[rv0.a as usize], &mut mac) {
                        return false;
                    }
                }
                mac.push_str(");\n");
                o.push_string(&mac);
                return true;
            }
        }
        // Rvalues are effect-free (calls are terminators), so a VOID-typed store carries no C
        // (untyped places are real data whose type recovers at declaration).
        if b.places.at(s.place as usize).ty != TYPE_NONE && self.erased(b, b.places.at(s.place as usize).ty) {
            return true;
        }
        // A stored CK_UNIT is the lowerer's "no meaningful value" marker (expression-statement
        // results); the established emitter never materializes it.
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_USE {
                let op0 = *b.operands.at(rv0.a as usize);
                if op0.kind == ir::OP_CONST && b.constants.at(op0.data as usize).kind == ir::CK_UNIT {
                    return true;
                }
            }
        }
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY {
                let pl9 = *b.places.at(s.place as usize);
                let root9 = *self.sx_coal.at(pl9.base as usize);
                let root_array = self.rty_y(b, b.locals.at(root9 as usize).ty).kind == TypeKind::TYPE_ARRAY;
                if root_array && pl9.proj_len == 0 && *self.sx_fuse.at(root9 as usize) && !*self.sx_declared.at(
                    root9 as usize,
                ) {
                    return self.emit_array_init(o, b, s, &rv0);
                }
                // An array literal COERCED to a slice view: `(Slice__T){ (T[N]){..}, N }`; the
                // compound literal lives to the end of the enclosing block.
                let mut rmS = b.module;
                let mut rtS = b.places.at(s.place as usize).ty;
                self.rty(b, b.places.at(s.place as usize).ty, &mut rmS, &mut rtS);
                let yS = *unsafe (*self.p().module_ast_const(rmS)).type_at(rtS);
                if yS.kind == TypeKind::TYPE_INSTANCE {
                    let itS = *unsafe (*self.p().module_ast_const(rmS)).instance(yS.as_data.inst);
                    let nm9 = self.agg_name(itS.module, itS.decl);
                    if (nm9 == "Slice" || nm9 == "SliceMut") && itS.n >= 1 {
                        let mut lhs9 = self.sget();
                        let mut cast9 = self.sget();
                        let mut et9 = self.sget();
                        let mut ok9 = self.emit_place(b, s.place, &mut lhs9) && self.ty_c(
                            b.module,
                            b.places.at(s.place as usize).ty,
                            "",
                            &mut cast9,
                        ) && self.mg.ctype(rmS, itS.args[0], "", &mut et9);
                        if ok9 {
                            o.push_str("  ");
                            let fuse9 = pl9.proj_len == 0 && *self.sx_fuse.at(root9 as usize) && !*self.sx_declared.at(
                                root9 as usize,
                            );
                            if fuse9 {
                                ok9 = self.ty_c(b.module, b.locals.at(root9 as usize).ty, lhs9.as_str(), o);
                                if ok9 {
                                    self.sx_declared.set(root9 as usize, true);
                                }
                            } else {
                                o.push_string(&lhs9);
                            }
                            o.push_str(" = (");
                            o.push_string(&cast9);
                            o.push_str("){ .ptr = (");
                            o.push_string(&et9);
                            o.push_str("[");
                            o.push_u64(rv0.b);
                            o.push_str("]){ ");
                            ok9 = ok9 && self.emit_lit_elems(o, b, &rv0);
                            o.push_str(" }, .len = ");
                            o.push_u64(rv0.b);
                            o.push_str(" };\n");
                        }
                        self.sput(lhs9);
                        self.sput(cast9);
                        self.sput(et9);
                        return ok9;
                    }
                }
                return self.emit_array_stores(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_REPEAT {
                return self.emit_repeat_stores(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_AGGREGATE && (rv0.c == ir::AGG_STRUCT || rv0.c == ir::AGG_TUPLE) && self.agg_has_array_field(
                b,
                &rv0,
            ) {
                return self.emit_struct_store_arrays(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_VARIANT && self.agg_has_array_field(b, &rv0) {
                return self.emit_variant_store_arrays(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_CLOSURE && self.closure_has_array_cap(b, &rv0) {
                return self.emit_closure_store_arrays(o, b, s, &rv0);
            }
            if rv0.kind == ir::RV_CAST && rv0.b == ir::CAST_SIMD_ARRAY {
                return self.emit_vec_cast_store(o, b, s, &rv0);
            }
        }
        // `new T { .. }`: allocate, then store the initializer through the fresh pointer.
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_NEW as u32 {
                let mut rmN = b.module;
                let mut rtN = rv0.target;
                self.rty(b, rv0.target, &mut rmN, &mut rtN);
                let yN = *unsafe (*self.p().module_ast_const(rmN)).type_at(rtN);
                if yN.kind != TypeKind::TYPE_POINTER && yN.kind != TypeKind::TYPE_REFERENCE {
                    return self.fail("new-target");
                }
                let mut es = self.sget();
                let mut lhs = self.sget();
                let mut iv = self.sget();
                // A zero-sized `T` has no C storage: one byte gives a distinct block to free, and the
                // initializer stores nothing.
                let zN = self.mg.is_zst(rmN, yN.as_data.elem);
                let mut okn = true;
                if zN {
                    es.push_str("1");
                } else {
                    es.push_str("sizeof(");
                    okn = self.ty_c(rmN, yN.as_data.elem, "", &mut es);
                    es.push_str(")");
                }
                okn = okn && self.emit_place(b, s.place, &mut lhs);
                if okn && rv0.b != 0 && !zN {
                    okn = self.emit_operand(b, b.oper_pool[rv0.a as usize], &mut iv);
                }
                if okn {
                    okn = self.emit_new_store(o, b, s, &es, &lhs, &iv);
                }
                self.sput(es);
                self.sput(lhs);
                self.sput(iv);
                return okn;
            }
        }
        return self.emit_stmt_tail(o, b, s);
    }

    // `Box`-style allocation: `[T ]lhs = __sc_new(size); *lhs = iv;` with the pieces spelled by the
    // caller (`iv` empty = no initializer).
    fn emit_new_store(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        s: &ir::Statement,
        size: &String,
        lhs: &String,
        iv: &String,
    ) bool {
        o.push_str("  ");
        let plN = *b.places.at(s.place as usize);
        let rootN = *self.sx_coal.at(plN.base as usize);
        let fuseN = plN.proj_len == 0 && *self.sx_fuse.at(rootN as usize) && !*self.sx_declared.at(rootN as usize);
        if fuseN {
            self.sx_declared.set(rootN as usize, true);
            if !self.ty_c(b.module, b.locals.at(rootN as usize).ty, lhs.as_str(), o) {
                return false;
            }
        } else {
            o.push_string(lhs);
        }
        o.push_str(" = __sc_new(");
        o.push_string(size);
        o.push_str(");\n");
        if iv.len() != 0 {
            o.push_str("  *");
            o.push_string(lhs);
            o.push_str(" = ");
            o.push_string(iv);
            o.push_str(";\n");
        }
        return true;
    }

    // The store forms after the intrinsic ones: erased dyn envs, dead never-typed copies, whole
    // array copies, compound assignment, then the plain `place = rvalue`.
    fn emit_stmt_tail(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement) bool {
        // a capturing closure erased to `dyn fn` boxes its env first: statement-level emission.
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_DYN {
                let mut omD = b.module;
                let mut otD = b.operands.at(rv0.a as usize).ty;
                self.rty(b, b.operands.at(rv0.a as usize).ty, &mut omD, &mut otD);
                if unsafe (*self.p().module_ast_const(omD)).type_at(otD).kind == TypeKind::TYPE_FUNCTION {
                    return self.emit_dyn_env_store(o, b, s, &rv0, omD, otD);
                }
            }
        }
        // A store whose source is a NEVER-typed temp sits on a dead path: emit nothing.
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_USE {
                let op0 = *b.operands.at(rv0.a as usize);
                if (op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE) && op0.ty != TYPE_NONE {
                    if self.rty_y(b, op0.ty).kind == TypeKind::TYPE_NEVER {
                        return true;
                    }
                }
            }
        }
        // Fixed C arrays cannot assign: whole-array stores copy bytes.
        {
            let an = self.arr_n(b, b.places.at(s.place as usize).ty);
            if an > 0 {
                let rv0 = *b.rvalues.at(s.rvalue as usize);
                if rv0.kind != ir::RV_USE {
                    return self.fail("array-store");
                }
                let op0 = *b.operands.at(rv0.a as usize);
                if op0.kind == ir::OP_CONST {
                    let c0 = *b.constants.at(op0.data as usize);
                    if c0.kind == ir::CK_INT && c0.val == 0 {
                        // Zeroing a whole array is a byte fill.
                        let mut zl = self.sget();
                        let okz = self.emit_place(b, s.place, &mut zl);
                        if okz {
                            o.push_str("  memset(&");
                            o.push_string(&zl);
                            o.push_str(", 0, sizeof(");
                            o.push_string(&zl);
                            o.push_str("));\n");
                        }
                        self.sput(zl);
                        return okz;
                    }
                }
                if op0.kind != ir::OP_COPY && op0.kind != ir::OP_MOVE {
                    return self.fail("array-store");
                }
                let mut lhs2 = self.sget();
                let mut rhs2 = self.sget();
                let ok2 = self.emit_place(b, s.place, &mut lhs2) && self.emit_place(b, op0.data, &mut rhs2);
                if ok2 {
                    // A designated literal may carry FEWER elements than the destination (its
                    // recorded type keeps the spelled count): zero-fill, then copy what exists.
                    let mut short_src = false;
                    {
                        let sn = self.arr_n(b, b.places.at(op0.data as usize).ty);
                        if sn > 0 && sn < an {
                            short_src = true;
                        }
                    }
                    if short_src {
                        o.push_str("  memset(&");
                        o.push_string(&lhs2);
                        o.push_str(", 0, sizeof(");
                        o.push_string(&lhs2);
                        o.push_str("));\n");
                    }
                    // The source is spelled without `&`: an array parameter is a pointer in C.
                    o.push_str("  memcpy(&");
                    o.push_string(&lhs2);
                    o.push_str(", ");
                    o.push_string(&rhs2);
                    o.push_str(", sizeof(");
                    if short_src {
                        o.push_string(&rhs2);
                    } else {
                        o.push_string(&lhs2);
                    }
                    o.push_str("));\n");
                }
                self.sput(lhs2);
                self.sput(rhs2);
                return ok2;
            }
        }
        if self.try_compound_assign(o, b, s) {
            return self.err.len() == 0;
        }
        let pl0 = *b.places.at(s.place as usize);
        let root0 = *self.sx_coal.at(pl0.base as usize);
        let fuse_decl = pl0.proj_len == 0 && *self.sx_fuse.at(root0 as usize) && !*self.sx_declared.at(root0 as usize);
        if !fuse_decl {
            // The pieces appear in output order, so they spell straight into the output buffer
            // (a failed statement leaves partial text; every failure path discards the body).
            o.push_str("  ");
            let mut ok = self.emit_place(b, s.place, o);
            if ok {
                o.push_str(" = ");
                ok = self.emit_rvalue(b, s.rvalue, o);
            }
            if ok {
                o.push_str(";\n");
            }
            return ok;
        }
        let mut lhs = self.sget();
        let mut rhs = self.sget();
        let ok = self.emit_place(b, s.place, &mut lhs) && self.emit_rvalue(b, s.rvalue, &mut rhs);
        if ok {
            o.push_str("  ");
            self.sx_declared.set(root0 as usize, true);
            let mut decl = self.sget();
            if !self.ty_c(b.module, b.locals.at(root0 as usize).ty, lhs.as_str(), &mut decl) {
                return false;
            }
            o.push_string(&decl);
            self.sput(decl);
            o.push_str(" = ");
            o.push_string(&rhs);
            o.push_str(";\n");
        }
        self.sput(lhs);
        self.sput(rhs);
        return ok;
    }

    // A capturing closure erased to `dyn fn`: box the env on the Global heap, then build the fat
    // value. The pair's `__free` only deallocates the env, so owning captures refuse.
    fn emit_dyn_env_store(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        s: &ir::Statement,
        rv: &ir::Rvalue,
        om: ModuleId,
        ot: TypeId,
    ) bool {
        let mut dm = b.module;
        let mut dt = rv.target;
        self.rty(b, rv.target, &mut dm, &mut dt);
        let mut envc = String::new();
        let mut tc = String::new();
        let mut pair = String::new();
        let mut lhs = String::new();
        let mut opv = String::new();
        let mut dpd = String::new();
        let mut ok = self.mg.ctype(om, ot, "", &mut envc) && self.mg.ctype(om, ot, "*__dp", &mut dpd) && self.ty_c(
            b.module,
            rv.target,
            "",
            &mut tc,
        ) && self.emit_place(b, s.place, &mut lhs) && self.emit_operand(b, rv.a, &mut opv);
        if ok {
            ok = self.dyn_pair(dm, dt, om, ot, true, 0, TYPE_NONE, &mut pair);
        }
        if ok {
            // The env of a closure without captures is its function pointer: a declarator, so
            // the allocation converts through `void *`.
            o.push_str("  { ");
            o.push_string(&dpd);
            o.push_str(" = (void *)Global__alloc(");
            self.push_global_arg(o);
            o.push_str(", sizeof(");
            o.push_string(&envc);
            o.push_str("), _Alignof(");
            o.push_string(&envc);
            o.push_str(")); *__dp = ");
            o.push_string(&opv);
            o.push_str("; ");
            o.push_string(&lhs);
            o.push_str(" = ((");
            o.push_string(&tc);
            o.push_str("){ .data = __dp, .vt = &");
            o.push_string(&pair);
            o.push_str("__vtbl }); }\n");
        }
        return ok;
    }

    // `__asm__ volatile ("tpl" : "=r"(out).. : "r"(in).. : "clobber"..);`, strings verbatim from
    // the body's asm record the rvalue's item indexes; outputs render the place a copy operand
    // carries.
    fn emit_asm_stmt(self: &mut Self, o: &mut String, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let src = self.p().modules.at(rv.item.module as usize).source.as_str();
        let d = *b.asms.at(rv.item.node as usize);
        o.push_str("  __asm__ volatile (");
        if d.template.end <= d.template.start {
            o.push_str("\"\"");
        } else {
            o.push_str(src.slice(d.template.start as usize, d.template.end as usize));
        }
        let want = d.nout != 0 || d.nin != 0 || d.nclob != 0;
        let mut ok = true;
        if want {
            o.push_str(" : ");
            for i in 0..d.nout {
                if !ok {
                    break;
                }
                if i != 0 {
                    o.push_str(", ");
                }
                let cs = *b.asm_spans.at((d.cons + i) as usize);
                o.push_str(src.slice(cs.start as usize, cs.end as usize));
                o.push_str("(");
                let opid = b.oper_pool[(rv.a + i) as usize];
                let op = *b.operands.at(opid as usize);
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    ok = self.emit_place(b, op.data, o);
                } else {
                    ok = self.fail("asm-out");
                }
                o.push_str(")");
            }
        }
        if (d.nin != 0 || d.nclob != 0) && ok {
            o.push_str(" : ");
            for i in 0..d.nin {
                if !ok {
                    break;
                }
                if i != 0 {
                    o.push_str(", ");
                }
                let cs = *b.asm_spans.at((d.cons + d.nout + i) as usize);
                o.push_str(src.slice(cs.start as usize, cs.end as usize));
                o.push_str("(");
                let opid = b.oper_pool[(rv.a + d.nout + i) as usize];
                ok = self.emit_operand(b, opid, o);
                o.push_str(")");
            }
        }
        if d.nclob != 0 && ok {
            o.push_str(" : ");
            for k in 0..d.nclob {
                if k != 0 {
                    o.push_str(", ");
                }
                let cs = *b.asm_spans.at((d.cons + d.nout + d.nin + k) as usize);
                o.push_str(src.slice(cs.start as usize, cs.end as usize));
            }
        }
        o.push_str(");\n");
        return ok;
    }

    // True when array literal `rv` leaves a slot unwritten (an IR_NONE operand).
    const fn lit_has_holes(b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        for i in 0..rv.b {
            if b.oper_pool[(rv.a + i) as usize] == ir::IR_NONE {
                return true;
            }
        }
        return false;
    }

    // Array literal `rv`'s C initializer elements: with holes each written slot is designated
    // (`[i] = v`); an empty list spells `0`.
    fn emit_lit_elems(self: &mut Self, o: &mut String, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let sparse = CEmit::lit_has_holes(b, rv);
        let mut emitted: u32 = 0;
        for i in 0..rv.b {
            let op = b.oper_pool[(rv.a + i) as usize];
            if op == ir::IR_NONE {
                continue;
            }
            if emitted != 0 {
                o.push_str(", ");
            }
            if sparse {
                o.push_str("[");
                o.push_u64(i);
                o.push_str("] = ");
            }
            if !self.emit_operand(b, op, o) {
                return false;
            }
            emitted += 1;
        }
        if emitted == 0 {
            o.push_str("0");
        }
        return true;
    }

    // C forbids array assignment: an array literal stores element-wise into the place.
    fn emit_array_stores(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let mut base = self.sget();
        let mut ok = self.emit_place(b, s.place, &mut base);
        {
            // Designated-init holes zero-fill: blank the storage before the written slots land.
            if ok && CEmit::lit_has_holes(b, rv) {
                o.push_str("  memset(&");
                o.push_string(&base);
                o.push_str(", 0, sizeof(");
                o.push_string(&base);
                o.push_str("));\n");
            }
        }
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == ir::IR_NONE {
                continue;
            }
            let mut elem = self.sget();
            elem.push_string(&base);
            elem.push_str("[");
            elem.push_u64(i);
            elem.push_str("]");
            ok = self.emit_member_store(o, b, &elem, opid);
            self.sput(elem);
        }
        self.sput(base);
        return ok;
    }

    // `dst = op;`, or an array copy when `op` reads a fixed-array place: C cannot assign or
    // initialize an array from a variable.
    fn emit_member_store(self: &mut Self, o: &mut String, b: &ir::CoreBody, dst: &String, opid: u32) bool {
        let op = *b.operands.at(opid as usize);
        if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && self.rty_y(b, op.ty).kind == TypeKind::TYPE_ARRAY {
            return self.emit_array_copy(o, b, dst, op.data);
        }
        o.push_str("  ");
        o.push_string(dst);
        o.push_str(" = ");
        let ok = self.emit_operand(b, opid, o);
        o.push_str(";\n");
        return ok;
    }

    // A vector or mask type resolved: its lane count and, for a vector, its lane builtin. False for any
    // other type.
    fn vec_ty(self: &Self, b: &ir::CoreBody, t: TypeId, n: &mut i64, bt: &mut BuiltinType) bool {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if !y.is_vec() {
            return false;
        }
        *n = self.mg.arr_len(rm, &y);
        if y.kind == TypeKind::TYPE_SIMD {
            let mut em = rm;
            let mut et = y.as_data.arr.elem;
            let _ = self.mg.resolve(rm, y.as_data.arr.elem, &mut em, &mut et);
            *bt = unsafe (*self.p().module_ast_const(em)).type_at(et).as_data.builtin;
        }
        return *n > 0;
    }

    // An rvalue the emitter writes as vector statements (`emit_vec_store`): an RV_SIMD, or an
    // operator or numeric cast over vector types.
    fn vec_rv(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let k = rv.kind;
        let unary = k == ir::RV_UNARY && (rv.b == tt::TokenType::Minus as u32 || rv.b == tt::TokenType::Tilde as u32);
        return k == ir::RV_SIMD || (k == ir::RV_BINARY || unary || k == ir::RV_CAST && rv.b == ir::CAST_NUMERIC) && rv.target != TYPE_NONE && self.rty_y(
            b,
            rv.target,
        ).kind == TypeKind::TYPE_SIMD;
    }

    // Vector rvalue `rv` stored to `s.place`: a lane loop over the storage arrays with a constant trip
    // count, or `memcpy` for the operations that move bytes. A trapping lane operation collects a
    // failure bit per lane and traps once, at the lowest failing lane (`__sc_panic_lane`); a mask
    // result collects its lane bits.
    fn emit_vec_store(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        if rv.kind == ir::RV_SIMD && rv.c >= ir::SIMD_SWIZZLE {
            return self.emit_vec_ops(o, b, s, rv);
        }
        let mut ops: [u32; 3] = [ir::IR_NONE; 3];
        let mut nops: u32 = 1;
        ops[0] = rv.a;
        if rv.kind == ir::RV_SIMD {
            nops = rv.b;
            for i in 0..nops {
                unsafe ops[i as usize] = b.oper_pool[(rv.a + i) as usize];
            }
        } else if rv.kind == ir::RV_BINARY {
            nops = 2;
            ops[1] = rv.b;
        }
        let c = pick(rv.kind == ir::RV_SIMD, rv.c, 255u8);
        let mut d = self.sget();
        let store = c == ir::SIMD_STORE || c == ir::SIMD_STORE_RAW;
        let mut ok = store || self.emit_place(b, s.place, &mut d);
        let mut sp: [String; 3] = [String::new(), String::new(), String::new()];
        let mut lanes: [bool; 3] = [false; 3];
        let mut pre = String::new();
        let mut fz: [bool; 3] = [false; 3];
        let mut n: i64 = 0;
        let mut rn: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let mut rbt = BuiltinType::BT_VOID;
        let mut obt = BuiltinType::BT_VOID;
        for i in 0..nops {
            let opid = unsafe ops[i as usize];
            let mut on: i64 = 0;
            let ot = b.operands.at(opid as usize).ty;
            unsafe lanes[i as usize] = self.vec_ty(b, ot, &mut on, &mut obt) && self.rty_y(b, ot).kind == TypeKind::TYPE_SIMD;
            if unsafe lanes[i as usize] && (n == 0 || c == ir::SIMD_CHOOSE) {
                n = on;
                bt = obt;
            }
            // A merged operand: its lanes are computed in this statement's loop.
            let q = self.fused_local(b, opid);
            if q != ir::IR_NONE {
                ok = ok && self.fused_lanes(b, q, &mut pre);
                unsafe sp[i as usize].format_into("__sc_v{}", q);
                unsafe fz[i as usize] = true;
            } else {
                ok = ok && self.emit_operand(b, opid, unsafe &mut sp[i as usize]);
            }
        }
        // The result's lanes: of the cast result for the changed-lane mask.
        let rt = if c == ir::SIMD_CAST_CHANGED {
            b.operands.at(ops[1] as usize).ty;
        } else {
            rv.target;
        };
        let _ = self.vec_ty(b, rt, &mut rn, &mut rbt);
        if c == ir::SIMD_IOTA {
            n = rn;
            bt = rbt;
        }
        if !ok {
            self.sput(d);
            return false;
        }
        // A contiguous load or store through its entry, at the checked start.
        if self.simd_on && (c == ir::SIMD_LOAD || c == ir::SIMD_LOAD_RAW || store) {
            let mut vp = vplan_none();
            let ld = !store;
            let vi = pick(c == ir::SIMD_STORE, 2usize, 1usize);
            let mut pn: i64 = 0;
            let mut pbt = BuiltinType::BT_VOID;
            if ld {
                pn = rn;
                pbt = rbt;
            } else {
                let _ = self.vec_ty(b, b.operands.at((unsafe ops[vi]) as usize).ty, &mut pn, &mut pbt);
            }
            vp.pl = self.vplan(
                ir::OP_SIMD + pick(ld, ir::SIMD_LOAD, ir::SIMD_STORE) as u32,
                pbt,
                pick(ld, pbt, BuiltinType::BT_VOID),
                pn,
            );
            if vp.pl.form != sp::PF_SCALAR {
                let mut psp: [String; 3] = [String::new(), String::new(), String::new()];
                psp[0].push_string(&sp[0]);
                if c == ir::SIMD_LOAD || c == ir::SIMD_STORE {
                    psp[0].format_into(".ptr + {}", sp[1].as_str());
                }
                vp.kinds[0] = VK_PTR;
                vp.res = pick(ld, VR_VEC, VR_UNIT);
                vp.raw = (c == ir::SIMD_LOAD_RAW || c == ir::SIMD_STORE_RAW) && self.vec_addr_taken(b, s.place, rv);
                if !ld {
                    psp[1].push_string(unsafe &sp[vi]);
                }
                let pok = self.emit_planned(o, &vp, &psp, pick(ld, 1u32, 2u32), d.as_str());
                self.sput(d);
                return pok;
            }
        }
        // The operations that move lanes: a lane loop. A bitcast reads the bytes as other lanes, and a
        // raw pointer may address the destination: `memmove`.
        let lp = "  for (uint32_t __sc_i = 0; __sc_i < ";
        if c == ir::SIMD_BITCAST || c == ir::SIMD_LOAD_RAW || c == ir::SIMD_STORE_RAW {
            if c == ir::SIMD_STORE_RAW {
                o.format_into("  memmove({}, &{}, sizeof({}));\n", sp[0].as_str(), sp[1].as_str(), sp[1].as_str());
            } else {
                o.format_into(
                    "  memmove(&{}, {}{}, sizeof({}));\n",
                    d.as_str(),
                    pick(c == ir::SIMD_BITCAST, "&", ""),
                    sp[0].as_str(),
                    d.as_str(),
                );
            }
        } else if c == ir::SIMD_LOAD {
            o.format_into(
                "{}{}; __sc_i++) {}.l[__sc_i] = {}.ptr[{} + __sc_i];\n",
                lp,
                rn,
                d.as_str(),
                sp[0].as_str(),
                sp[1].as_str(),
            );
        } else if c == ir::SIMD_STORE {
            // A merged vector's lanes are computed in the loop (`vec_fusion`).
            o.format_into(
                "{}{}; __sc_i++) {{ {}{}.ptr[{} + __sc_i] = {}{}; }}\n",
                lp,
                n,
                pre.as_str(),
                sp[0].as_str(),
                sp[1].as_str(),
                sp[2].as_str(),
                pick(fz[2], "", ".l[__sc_i]"),
            );
        } else if c == ir::SIMD_LOW_HALF || c == ir::SIMD_HIGH_HALF {
            o.format_into(
                "{}{}; __sc_i++) {}.l[__sc_i] = {}.l[__sc_i + {}];\n",
                lp,
                rn,
                d.as_str(),
                sp[0].as_str(),
                pick(c == ir::SIMD_HIGH_HALF, rn, 0),
            );
        } else if c == ir::SIMD_CONCAT {
            o.format_into(
                "{}{}; __sc_i++) {{ {}.l[__sc_i] = {}.l[__sc_i]; {}.l[__sc_i + {}] = {}.l[__sc_i]; }}\n",
                lp,
                n,
                d.as_str(),
                sp[0].as_str(),
                d.as_str(),
                n,
                sp[1].as_str(),
            );
        } else {
            ok = self.emit_vec_lanes(o, b, s.place, rv, c, &ops, &d, &sp, &lanes, n, bt, rbt, pre.as_str(), &fz);
        }
        self.sput(d);
        return ok;
    }

    // RV_SIMD codes SIMD_SWIZZLE and up (`ir::SR_INDEX` and up), stored to `s.place`: a rearrangement
    // into a scratch result (an operand may be the destination), a reduction as one loop in the order
    // its definition fixes, and a masked or gather memory form as a loop that collects the failing
    // active lanes, one trap at the lowest, then one element access per active lane in lane order.
    fn emit_vec_ops(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let c = rv.c;
        let op = ir::simd_op(c);
        let mut sp: [String; 4] = [String::new(), String::new(), String::new(), String::new()];
        let mut ok = true;
        for i in 0..rv.b {
            ok = ok && self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], unsafe &mut sp[i as usize]);
        }
        let vk = pick(op.rule == ir::SR_MASKED || op.rule >= ir::SR_MLOAD, op.arity as u32 - 1, 0u32);
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        ok = ok && self.vec_ty(b, b.operands.at(b.oper_pool[(rv.a + vk) as usize] as usize).ty, &mut n, &mut bt);
        let mut rn: i64 = 0;
        let mut rbt = bt;
        let mut rm = b.module;
        let mut rt = rv.target;
        self.rty(b, rv.target, &mut rm, &mut rt);
        let ry = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if ry.kind == TypeKind::TYPE_BUILTIN {
            rbt = ry.as_data.builtin;
        } else {
            let _ = self.vec_ty(b, rv.target, &mut rn, &mut rbt);
        }
        let unit = ry.kind == TypeKind::TYPE_BUILTIN && rbt == BuiltinType::BT_VOID;
        let mut d = self.sget();
        ok = ok && (unit || self.emit_place(b, s.place, &mut d));
        if !ok {
            self.sput(d);
            return false;
        }
        if self.simd_on && self.emit_vec_ops_planned(o, b, rv, &sp, n, bt, rn, rbt, d.as_str()) {
            self.sput(d);
            return true;
        }
        o.push_str("  {\n");
        // A start, a mask, a pointer or a slice reads once, before any lane: a forwarded operand
        // expression (its own checks included) must run exactly once whatever the lanes do. A name or
        // a literal is read where it is used.
        for i in 0..rv.b {
            let ot = b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize).ty;
            let k = self.rty_y(b, ot).kind;
            if k != TypeKind::TYPE_SIMD && k != TypeKind::TYPE_ARRAY && !plain_spelling(unsafe sp[i as usize].as_str()) {
                let mut nm = String::new();
                nm.format_into("__sc_o{}", i);
                o.push_str("  ");
                ok = ok && self.ty_c(b.module, ot, nm.as_str(), o);
                o.format_into(" = {};\n", unsafe sp[i as usize].as_str());
                unsafe sp[i as usize] = nm;
            }
        }
        let raw = self.vec_addr_taken(b, s.place, rv);
        if self.simd_on && self.emit_vec_mem_planned(o, c, &sp, n, bt, d.as_str(), raw) {
            o.push_str("  }\n");
            self.sput(d);
            return ok;
        }
        let a = sp[0].as_str();
        let x = sp[1].as_str();
        let lp = "  for (uint32_t __sc_i = 0; __sc_i < ";
        if op.rule == ir::SR_INDEX || op.rule == ir::SR_RT_INDEX || op.rule == ir::SR_MASKED || op.rule == ir::SR_MLOAD {
            if c != ir::SIMD_SWIZZLE_OOB {
                o.push_str("  ");
                ok = self.ty_c(b.module, rv.target, " __sc_r;\n", o);
            }
        }
        switch op.rule {
            ir::SR_INDEX => {
                if rv.item.node == ir::IR_NONE {
                    self.sput(d);
                    return self.fail("vector index list");
                }
                if rn <= 16 {
                    // One assignment per lane, in index order.
                    for i in 0..rn as u64 {
                        let k = ir::aux_lane(b, rv.item.node, i) as i64;
                        o.format_into("  __sc_r.l[{}] = {}.l[{}];\n", i, pick(k < n, a, x), pick(k < n, k, k - n));
                    }
                } else {
                    o.format_into("  static const uint8_t __sc_x[{}] = {{", rn);
                    for i in 0..rn as u64 {
                        o.format_into("{}{}", mbe::if_s(i == 0, "", ", "), ir::aux_lane(b, rv.item.node, i));
                    }
                    o.format_into("}};\n{}{}; __sc_i++) __sc_r.l[__sc_i] = ", lp, rn);
                    if rv.b == 1 {
                        o.format_into("{}.l[__sc_x[__sc_i]];\n", a);
                    } else {
                        o.format_into(
                            "__sc_x[__sc_i] < {} ? {}.l[__sc_x[__sc_i]] : {}.l[__sc_x[__sc_i] - {}];\n",
                            n,
                            a,
                            x,
                            n,
                        );
                    }
                }
            },
            ir::SR_RT_INDEX => {
                if c == ir::SIMD_SWIZZLE_OOB {
                    o.format_into(
                        "  uint64_t __sc_m = 0;\n{}{}; __sc_i++) __sc_m |= (uint64_t)({}.l[__sc_i] >= {}) << __sc_i;\n",
                        lp,
                        rn,
                        x,
                        n,
                    );
                    o.format_into("  {} = __sc_m;\n", d.as_str());
                    o.push_str("  }\n");
                    self.sput(d);
                    return ok;
                }
                o.format_into(
                    "{}{}; __sc_i++) __sc_r.l[__sc_i] = {}.l[__sc_i] < {} ? {}.l[{}.l[__sc_i]] : 0;\n",
                    lp,
                    rn,
                    x,
                    n,
                    a,
                    x,
                );
            },
            ir::SR_MASKED => {
                // compress: the active lanes from position 0 over `fill`; expand: each active lane takes
                // the next packed lane.
                let f = sp[2].as_str();
                o.push_str("  uint32_t __sc_k = 0;\n");
                if c == ir::SIMD_COMPRESS {
                    o.format_into(
                        "  __sc_r = {};\n{}{}; __sc_i++) if (({} >> __sc_i) & 1) __sc_r.l[__sc_k++] = {}.l[__sc_i];\n",
                        f,
                        lp,
                        n,
                        a,
                        x,
                    );
                } else {
                    o.format_into(
                        "{}{}; __sc_i++) __sc_r.l[__sc_i] = (({} >> __sc_i) & 1) ? {}.l[__sc_k++] : {}.l[__sc_i];\n",
                        lp,
                        n,
                        a,
                        x,
                        f,
                    );
                }
            },
            ir::SR_REDUCE | ir::SR_DOT => {
                ok = ok && self.emit_vec_reduce(o, c, &sp, n, bt, rbt, d.as_str());
                o.push_str("  }\n");
                self.sput(d);
                return ok;
            },
            _ => {
                // A gather's or scatter's index check through the comparison entries.
                let mut checked = false;
                if self.simd_on && (c == ir::SIMD_GATHER || c == ir::SIMD_SCATTER) {
                    let mut xn: i64 = 0;
                    let mut ib = BuiltinType::BT_VOID;
                    let _ = self.vec_ty(
                        b,
                        b.operands.at(b.oper_pool[(rv.a + 1) as usize] as usize).ty,
                        &mut xn,
                        &mut ib,
                    );
                    let m = unsafe sp[(op.arity - 2) as usize].as_str();
                    checked = self.index_check_planned(o, sp[0].as_str(), sp[1].as_str(), m, n, ib);
                }
                if c == ir::SIMD_COMPRESS_STORE && self.simd_on {
                    checked = self.compress_store_planned(o, &sp, n, bt);
                }
                self.emit_vec_mem(o, c, &sp, n, checked);
            },
        };
        if op.rule != ir::SR_MSTORE || c == ir::SIMD_COMPRESS_STORE {
            o.format_into("  {} = {};\n", d.as_str(), mbe::if_s(c == ir::SIMD_COMPRESS_STORE, "__sc_c", "__sc_r"));
        }
        o.push_str("  }\n");
        self.sput(d);
        return ok;
    }

    // The reductions and `dot` of `emit_vec_ops` over the `n` lanes of `bt` of `sp[0]` (and `sp[1]`),
    // the result (of builtin `rbt`) stored to `d`: the left-to-right fold, the halving tree, the lowest
    // extreme lane, or the exact-result test, each the interpreter's sequence (`Interp::vec_reduce`).
    fn emit_vec_reduce(
        self: &mut Self,
        o: &mut String,
        c: u8,
        sp: &[String; 4],
        n: i64,
        bt: BuiltinType,
        rbt: BuiltinType,
        d: str,
    ) bool {
        let v = sp[0].as_str();
        let fl = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
        let sg = int_signed(bt);
        let w = self.int_bits(bt);
        let t = lane_c(bt);
        let p = mbe::if_s(w <= 32, "uint32_t", "uint64_t");
        let lp = "  for (uint32_t __sc_i = ";
        if c == ir::SIMD_REDUCE_ADD_OVF {
            // The exact sum in 128 bits, `__sc_hi`:`__sc_lo`, against the lane type's range.
            o.format_into(
                "  uint64_t __sc_lo = 0; int64_t __sc_hi = 0;\n{}0; __sc_i < {}; __sc_i++) {{ {} __sc_y = {}.l[__sc_i]; uint64_t __sc_s = __sc_lo + (uint64_t)__sc_y; __sc_hi += ",
                lp,
                n,
                t,
                v,
            );
            o.push_str(mbe::if_s(sg, "(__sc_y < 0 ? -1 : 0) + ", ""));
            o.push_str("(__sc_s < __sc_lo); __sc_lo = __sc_s; }\n");
            if sg {
                o.format_into(
                    "  {} = !(__sc_hi == ((int64_t)__sc_lo >> 63) && (int64_t)__sc_lo >= {} && (int64_t)__sc_lo <= {});\n",
                    d,
                    lane_limit(bt, false),
                    lane_limit(bt, true),
                );
            } else {
                o.format_into("  {} = !(__sc_hi == 0 && __sc_lo <= {});\n", d, lane_limit(bt, true));
            }
            return true;
        }
        if c == ir::SIMD_REDUCE_MUL_OVF {
            // A zero lane makes the product zero; otherwise its magnitude only grows, so one past 64
            // bits never fits.
            o.format_into(
                "  uint64_t __sc_p = 1; int __sc_ng = 0, __sc_ov = 0, __sc_z = 0;\n{}0; __sc_i < {}; __sc_i++) {{ {} __sc_y = {}.l[__sc_i]; ",
                lp,
                n,
                t,
                v,
            );
            if sg {
                o.push_str(
                    "uint64_t __sc_g = __sc_y < 0 ? 0 - (uint64_t)__sc_y : (uint64_t)__sc_y; __sc_ng ^= __sc_y < 0; ",
                );
            } else {
                o.push_str("uint64_t __sc_g = __sc_y; ");
            }
            o.push_str("__sc_z |= __sc_g == 0; __sc_ov |= __builtin_mul_overflow(__sc_p, __sc_g, &__sc_p); }\n");
            if sg {
                o.format_into("  {} = !__sc_z && (__sc_ov || __sc_p > ((uint64_t)1 << {}) - !__sc_ng);\n", d, w - 1);
            } else {
                o.format_into("  {} = !__sc_z && (__sc_ov || __sc_p > {});\n", d, lane_limit(bt, true));
            }
            return true;
        }
        if c >= ir::SIMD_ARG_MIN && c <= ir::SIMD_ARG_MAX_NUM {
            // The lowest lane that beats every lane before it; a NaN lane never does, -0.0 is below +0.0.
            let min = c == ir::SIMD_ARG_MIN || c == ir::SIMD_ARG_MIN_NUM;
            o.format_into(
                "  size_t __sc_b = {};\n{}0; __sc_i < {}; __sc_i++) {{ {} __sc_y = {}.l[__sc_i]; ",
                n,
                lp,
                n,
                t,
                v,
            );
            o.push_str(mbe::if_s(fl, "if (__sc_y != __sc_y) continue; ", ""));
            o.format_into("if (__sc_b == {} || __sc_y {} {}.l[__sc_b]", n, mbe::if_s(min, "<", ">"), v);
            if fl {
                o.format_into(
                    " || (__sc_y == {}.l[__sc_b] && {}signbit(__sc_y) && {}signbit({}.l[__sc_b]))",
                    v,
                    mbe::if_s(min, "", "!"),
                    mbe::if_s(min, "!", ""),
                    v,
                );
            }
            o.format_into(") __sc_b = __sc_i; }}\n  {} = __sc_b;\n", d);
            return true;
        }
        if c == ir::SIMD_REDUCE_ADD_TREE || c == ir::SIMD_REDUCE_MUL_TREE {
            // Halves: lane i of the lower half with lane i of the upper, until one lane.
            let opc = mbe::if_s(c == ir::SIMD_REDUCE_ADD_TREE, "+", "*");
            o.format_into(
                "  {} __sc_t[{}];\n{}0; __sc_i < {}; __sc_i++) __sc_t[__sc_i] = {}.l[__sc_i];\n",
                t,
                n,
                lp,
                n,
                v,
            );
            o.format_into(
                "  for (uint32_t __sc_h = {}; __sc_h != 0; __sc_h /= 2) for (uint32_t __sc_i = 0; __sc_i < __sc_h; __sc_i++) __sc_t[__sc_i] = __sc_t[__sc_i] {} __sc_t[__sc_i + __sc_h];\n",
                n / 2,
                opc,
            );
            o.format_into("  {} = __sc_t[0];\n", d);
            return true;
        }
        if c == ir::SIMD_DOT {
            // Each product in the accumulator's type (wrapped, or rounded), then the sum in lane order.
            let at = lane_c(rbt);
            let u = v;
            let y = sp[1].as_str();
            if rbt == BuiltinType::BT_F32 || rbt == BuiltinType::BT_F64 {
                o.format_into(
                    "  {} __sc_x = -0.0;\n{}0; __sc_i < {}; __sc_i++) {{ {} __sc_p = ({}){}.l[__sc_i] * ({}){}.l[__sc_i]; __sc_x = __sc_x + __sc_p; }}\n",
                    at,
                    lp,
                    n,
                    at,
                    at,
                    u,
                    at,
                    y,
                );
            } else {
                let ap = mbe::if_s(self.int_bits(rbt) <= 32, "uint32_t", "uint64_t");
                o.format_into(
                    "  {} __sc_x = 0;\n{}0; __sc_i < {}; __sc_i++) __sc_x = __sc_x + ({})({}){}.l[__sc_i] * ({})({}){}.l[__sc_i];\n",
                    ap,
                    lp,
                    n,
                    ap,
                    at,
                    u,
                    ap,
                    at,
                    y,
                );
                o.format_into("  {} = ({})__sc_x;\n", d, at);
                return true;
            }
            o.format_into("  {} = __sc_x;\n", d);
            return true;
        }
        if fl && c <= ir::SIMD_REDUCE_MUL_ORD {
            let add = c == ir::SIMD_REDUCE_ADD_ORD;
            o.format_into(
                "  {} __sc_x = {};\n{}0; __sc_i < {}; __sc_i++) __sc_x = __sc_x {} {}.l[__sc_i];\n",
                t,
                mbe::if_s(add, "-0.0", "1.0"),
                lp,
                n,
                mbe::if_s(add, "+", "*"),
                v,
            );
        } else if fl {
            // The lane rule on (accumulator, lane): the kept operand itself.
            let lc = if c == ir::SIMD_REDUCE_MIN_NUM {
                ir::SIMD_MIN;
            } else if c == ir::SIMD_REDUCE_MAX_NUM {
                ir::SIMD_MAX;
            } else if c == ir::SIMD_REDUCE_MINIMUM {
                ir::SIMD_MINIMUM;
            } else {
                ir::SIMD_MAXIMUM;
            };
            let st = String::from_str(vec_simd_tpl(lc, bt, bt)).replace("$d", "__sc_x").replace("$a", "__sc_x").replace(
                "$b",
                "__sc_y",
            );
            o.format_into(
                "  {} __sc_x = {}.l[0];\n{}1; __sc_i < {}; __sc_i++) {{ {} __sc_y = {}.l[__sc_i]; {} }}\n",
                t,
                v,
                lp,
                n,
                t,
                v,
                st.as_str(),
            );
        } else if c == ir::SIMD_REDUCE_ADD || c == ir::SIMD_REDUCE_MUL {
            o.format_into(
                "  {} __sc_x = ({}){}.l[0];\n{}1; __sc_i < {}; __sc_i++) __sc_x = __sc_x {} ({}){}.l[__sc_i];\n",
                p,
                p,
                v,
                lp,
                n,
                mbe::if_s(c == ir::SIMD_REDUCE_ADD, "+", "*"),
                p,
                v,
            );
            o.format_into("  {} = ({})__sc_x;\n", d, t);
            return true;
        } else {
            let e = if c == ir::SIMD_REDUCE_MIN {
                "__sc_y < __sc_x ? __sc_y : __sc_x";
            } else if c == ir::SIMD_REDUCE_MAX {
                "__sc_y > __sc_x ? __sc_y : __sc_x";
            } else if c == ir::SIMD_REDUCE_AND {
                "__sc_x & __sc_y";
            } else if c == ir::SIMD_REDUCE_OR {
                "__sc_x | __sc_y";
            } else {
                "__sc_x ^ __sc_y";
            };
            o.format_into(
                "  {} __sc_x = {}.l[0];\n{}1; __sc_i < {}; __sc_i++) {{ {} __sc_y = {}.l[__sc_i]; __sc_x = ({})({}); }}\n",
                t,
                v,
                lp,
                n,
                t,
                v,
                t,
                e,
            );
        }
        o.format_into("  {} = __sc_x;\n", d);
        return true;
    }

    // The index check of a gather or scatter of slice `s` by index vector `x` (`n` lanes of `ib`) with
    // active lanes `m`: whether any index exceeds `len - 1` (at most the lane type's largest value),
    // through the comparison, `|` and `any` entries; only then the bits of the active failing lanes
    // and the trap (`index_bits`). False when the planner has no entry (nothing written).
    fn index_check_planned(self: &mut Self, o: &mut String, s: str, x: str, m: str, n: i64, ib: BuiltinType) bool {
        let mut vp = vplan_none();
        vp.pl = self.vplan(ir::OP_CMP_LANES + (ir::SIMD_CMP_GT - ir::SIMD_CMP_EQ) as u32, ib, ib, n);
        let cl = vp.pl.chunk_lanes;
        vp.cadd = pick(vp.pl.chunks > 1, self.ventry(ir::OP_OR, ib, ib, cl), -1);
        vp.cred = self.ventry(ir::OP_ANY_LANES, ib, BuiltinType::BT_BOOL, cl);
        if vp.pl.form == sp::PF_SCALAR || vp.cred < 0 || vp.pl.chunks > 1 && vp.cadd < 0 {
            return false;
        }
        vp.res = VR_FOLD;
        vp.kinds = [VK_VEC, VK_VEC, VK_VEC];
        let max = pick(ib == BuiltinType::BT_U32, "0xFFFFFFFFu", "~0ULL");
        o.format_into(
            "  __typeof__({}) __sc_lim;\n  for (uint32_t __sc_i = 0; __sc_i < {}; __sc_i++) __sc_lim.l[__sc_i] = {}.len - 1 > {} ? {} : {}.len - 1;\n  bool __sc_a;\n",
            x,
            n,
            s,
            max,
            max,
            s,
        );
        let xsp: [String; 3] = [String::from_str(x), String::from_str("__sc_lim"), String::new()];
        let ok = self.emit_planned(o, &vp, &xsp, 2, "__sc_a");
        // Some lane, active or not, is past the end (or the slice is empty): the active ones' bits.
        o.format_into("  if (__sc_a || {}.len == 0) {{\n", s);
        index_bits(o, n, m, x, s);
        o.push_str("  }\n");
        return ok;
    }

    // `compress_store(s, st, m, v)` over `n` lanes of `bt` in chunks of 16 or 8 bytes of at most 8 lanes,
    // through the `SwizzleOrZero` entry and the `u8` `Load` and `Store` entries of their bytes: after
    // the range check, when the slice holds a chunk past the written elements, each chunk's active
    // lanes are moved to its front by a table of byte indexes (one row per mask) and the whole chunk
    // is stored at the next free element; a chunk's tail is overwritten by the next chunk, and the
    // last one's is restored from the elements read first (`s` is borrowed alone). Writes the opening of the `else` that `emit_vec_mem`'s lane
    // loop closes; false when there is no such entry (nothing written).
    fn compress_store_planned(self: &mut Self, o: &mut String, sp: &[String; 4], n: i64, bt: BuiltinType) bool {
        let lb = lane_bytes(bt);
        let mut cb: u64 = pick(n as u64 * lb >= 16, 16u64, 8u64);
        let mut e = self.ventry(ir::OP_SIMD + ir::SIMD_SWIZZLE_ZERO as u32, BuiltinType::BT_U8, BuiltinType::BT_U8, cb);
        if e < 0 && cb == 16 {
            cb = 8;
            e = self.ventry(ir::OP_SIMD + ir::SIMD_SWIZZLE_ZERO as u32, BuiltinType::BT_U8, BuiltinType::BT_U8, cb);
        }
        let cl = cb / lb;
        // The bytes move through the `u8` load and store entries.
        let ld = self.ventry(ir::OP_SIMD + ir::SIMD_LOAD as u32, BuiltinType::BT_U8, BuiltinType::BT_U8, cb);
        let sv = self.ventry(ir::OP_SIMD + ir::SIMD_STORE as u32, BuiltinType::BT_U8, BuiltinType::BT_VOID, cb);
        if e < 0 || ld < 0 || sv < 0 || cl > 8 || cl < 2 || n as u64 % cl != 0 {
            return false;
        }
        let (s, st, m, v) = (sp[0].as_str(), sp[1].as_str(), sp[2].as_str(), sp[3].as_str());
        o.format_into(
            "  uint64_t __sc_c = (uint64_t)__builtin_popcountll({}), __sc_k = 0;\n  (void)__sc_bounds_vec({}, {}.len, __sc_c);\n",
            m,
            st,
            s,
        );
        // Row `r`: the bytes of the lanes of mask `r` in order, then the others (overwritten later).
        o.format_into("  static const uint8_t __sc_ct[{}][{}] = {{", 1u64 << cl, cb);
        for r in 0..1u64 << cl {
            o.push_str(pick(r == 0, "{", ", {"));
            let mut w: u64 = 0;
            for pass in 0..2u64 {
                for i in 0..cl {
                    if (r >> i & 1) == 1 - pass {
                        for j in 0..lb {
                            o.format_into("{}{}", pick(w == 0, "", ", "), i * lb + j);
                            w += 1;
                        }
                    }
                }
            }
            o.push_str("}");
        }
        // Each mask's lane count (one load, not a population count's four instructions).
        o.format_into("}};\n  static const uint8_t __sc_cn[{}] = {{", 1u64 << cl);
        for r in 0..1u64 << cl {
            o.format_into("{}{}", pick(r == 0, "", ", "), r.count_ones());
        }
        o.format_into("}};\n  if ({}.len - {} - __sc_c >= {}u) {{\n  ", s, st, cl);
        let ok = self.entry_ty(e as u32, 0, "__sc_o", o);
        let (mut lds, mut sts, mut swz) = (String::new(), String::new(), String::new());
        self.entry_name(ld as u32, &mut lds);
        self.entry_name(sv as u32, &mut sts);
        self.entry_name(e as u32, &mut swz);
        let bits = (1u64 << cl) - 1;
        o.format_into(" = {}((const uint8_t *)({}.ptr + {} + __sc_c));\n", lds.as_str(), s, st);
        for j in 0..n as u64 / cl {
            o.format_into(
                "  {}((uint8_t *)({}.ptr + {} + __sc_k), {}({}((const uint8_t *)&{} + {}), {}(__sc_ct[{} >> {} & {}u])));\n  __sc_k += __sc_cn[{} >> {} & {}u];\n",
                sts.as_str(),
                s,
                st,
                swz.as_str(),
                lds.as_str(),
                v,
                j * cb,
                lds.as_str(),
                m,
                j * cl,
                bits,
                m,
                j * cl,
                bits,
            );
        }
        o.format_into("  {}((uint8_t *)({}.ptr + {} + __sc_c), __sc_o);\n  }} else {{\n", sts.as_str(), s, st);
        return ok;
    }

    // A contiguous masked load or store of `emit_vec_ops` (`load_or`, `load_masked`, `store_masked` and
    // their pointer forms; operands `sp`, bound once) over `n` lanes of `bt` through the `LoadMasked` or
    // `StoreMasked` entry: the range checks of the active lanes first, as the lane loop does them,
    // then the entry with the elements' address, the active lanes and the fallback or the stored
    // vector; the result in `d`. `load_or`'s active lanes are those inside the slice. False when the
    // planner chose the loop (nothing written).
    fn emit_vec_mem_planned(
        self: &mut Self,
        o: &mut String,
        c: u8,
        sp: &[String; 4],
        n: i64,
        bt: BuiltinType,
        d: str,
        raw: bool,
    ) bool {
        let ptr = c == ir::SIMD_LOAD_MASKED_PTR || c == ir::SIMD_STORE_MASKED_PTR;
        let store = c == ir::SIMD_STORE_MASKED || c == ir::SIMD_STORE_MASKED_PTR;
        if !ptr && c != ir::SIMD_LOAD_OR && c != ir::SIMD_LOAD_MASKED && !store {
            return false;
        }
        let mut vp = vplan_none();
        vp.pl = self.vplan(
            ir::OP_SIMD + pick(store, ir::SIMD_STORE_MASKED, ir::SIMD_LOAD_MASKED) as u32,
            bt,
            pick(store, BuiltinType::BT_VOID, bt),
            n,
        );
        if vp.pl.form == sp::PF_SCALAR {
            return false;
        }
        vp.kinds = [VK_PTR, VK_MASK, VK_VEC];
        vp.res = pick(store, VR_UNIT, VR_VEC);
        let mut psp: [String; 3] = [String::new(), String::new(), String::new()];
        if ptr {
            psp[0].push_string(&sp[0]);
            psp[1].push_string(&sp[1]);
            psp[2].push_string(&sp[2]);
            vp.raw = raw;
            return self.emit_planned(o, &vp, &psp, 3, d);
        }
        let s = sp[0].as_str();
        let st = sp[1].as_str();
        // The start only where the slice holds it: no lane is active past the end.
        psp[0].format_into("{}.ptr + ({} <= {}.len ? {} : 0)", s, st, s, st);
        if c != ir::SIMD_LOAD_OR {
            let m = sp[2].as_str();
            range_bits(o, m, st, s, n);
            psp[1].push_str(m);
            psp[2].push_string(&sp[3]);
            return self.emit_planned(o, &vp, &psp, 3, d);
        }
        psp[1].push_str("__sc_mk");
        psp[2].push_string(&sp[2]);
        // `load_or` with every lane inside the slice, the usual case, is a plain load (`len >= n` is
        // loop-invariant); else the lanes inside the slice are the active ones.
        let mut lp = vplan_none();
        lp.pl = self.vplan(ir::OP_SIMD + ir::SIMD_LOAD as u32, bt, bt, n);
        lp.kinds[0] = VK_PTR;
        let mut ok = true;
        if lp.pl.form != sp::PF_SCALAR {
            let lsp: [String; 3] = [format("{}.ptr + {}", s, st), String::new(), String::new()];
            o.format_into("  if (__builtin_expect({}.len >= {}u && {} <= {}.len - {}u, 1)) {{\n", s, n, st, s, n);
            ok = self.emit_planned(o, &lp, &lsp, 1, d);
            o.push_str("  } else {\n");
        }
        o.format_into(
            "  uint64_t __sc_mk = {} >= {}.len ? 0 : {}.len - {} >= {}u ? {}u : ~0ULL >> (64 - ({}.len - {}));\n",
            st,
            s,
            s,
            st,
            n,
            ~0u64 >> (64 - n) as u64,
            s,
            st,
        );
        ok = self.emit_planned(o, &vp, &psp, 3, d) && ok;
        if lp.pl.form != sp::PF_SCALAR {
            o.push_str("  }\n");
        }
        return ok;
    }

    // The masked and gather memory forms of `emit_vec_ops` (`ir::SR_MLOAD`, `ir::SR_MSTORE`) over `n`
    // lanes: operand spellings `sp` (the slice, pointer or pointer array first), the result in
    // `__sc_r` for a load. `checked`: a planned form wrote a gather's or scatter's index check
    // (`index_check_planned`), or a `compress_store`'s range check and the `else` this lane loop
    // closes (`compress_store_planned`).
    fn emit_vec_mem(self: &mut Self, o: &mut String, c: u8, sp: &[String; 4], n: i64, checked: bool) {
        let op = ir::simd_op(c);
        let s = sp[0].as_str();
        let st = sp[1].as_str();
        let m = unsafe sp[(op.arity - 2) as usize].as_str();
        let v = unsafe sp[(op.arity - 1) as usize].as_str();
        let store = op.rule == ir::SR_MSTORE;
        let gat = c == ir::SIMD_GATHER || c == ir::SIMD_SCATTER;
        let lp = "  for (uint32_t __sc_i = 0; __sc_i < ";
        if c == ir::SIMD_COMPRESS_STORE {
            if !checked {
                o.format_into(
                    "  uint64_t __sc_c = (uint64_t)__builtin_popcountll({}), __sc_k = 0;\n  (void)__sc_bounds_vec({}, {}.len, __sc_c);\n",
                    m,
                    st,
                    s,
                );
            }
            o.format_into(
                "{}{}; __sc_i++) if (({} >> __sc_i) & 1) {}.ptr[{} + __sc_k++] = {}.l[__sc_i];\n",
                lp,
                n,
                m,
                s,
                st,
                v,
            );
            if checked {
                o.push_str("  }\n");
            }
            return;
        }
        // The element of lane i.
        let mut e = String::new();
        if c == ir::SIMD_GATHER_PTR || c == ir::SIMD_SCATTER_PTR {
            e.format_into("*{}[__sc_i]", s);
        } else if c >= ir::SIMD_GATHER_PTR {
            e.format_into("{}[__sc_i]", s);
        } else if gat {
            e.format_into("{}.ptr[{}.l[__sc_i]]", s, st);
        } else {
            e.format_into("{}.ptr[{} + __sc_i]", s, st);
        }
        if c == ir::SIMD_LOAD_OR {
            o.format_into(
                "{}{}; __sc_i++) __sc_r.l[__sc_i] = {} <= {}.len && __sc_i < {}.len - {} ? {} : {}.l[__sc_i];\n",
                lp,
                n,
                st,
                s,
                s,
                st,
                e.as_str(),
                v,
            );
            return;
        }
        if c < ir::SIMD_GATHER_PTR && !checked {
            // Every active lane's check before any access; one trap, at the lowest failing lane.
            if gat {
                index_bits(o, n, m, st, s);
            } else {
                range_bits(o, m, st, s, n);
            }
        }
        if store {
            o.format_into("{}{}; __sc_i++) if (({} >> __sc_i) & 1) {} = {}.l[__sc_i];\n", lp, n, m, e.as_str(), v);
        } else {
            o.format_into(
                "{}{}; __sc_i++) __sc_r.l[__sc_i] = (({} >> __sc_i) & 1) ? {} : {}.l[__sc_i];\n",
                lp,
                n,
                m,
                e.as_str(),
                v,
            );
        }
    }

    // The lane loop of `emit_vec_store`: operand spellings `sp` (`lanes`: a vector, read per lane),
    // `n` lanes of builtin `bt` (operand 0's, or the result's for `iota`), result lanes `rbt`, result
    // type `rt`. A trapping operation writes a scratch result and ORs each lane's failure into a flag,
    // a form the C compiler vectorizes; only when a flag is set does a second loop collect the failing
    // lanes' bits, from the unchanged operands, for `__sc_panic_lane`.
    fn emit_vec_lanes(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        place: ir::PlaceId,
        rv: &ir::Rvalue,
        c: u8,
        ops: &[u32; 3],
        d: &String,
        sp: &[String; 3],
        lanes: &[bool; 3],
        n: i64,
        bt: BuiltinType,
        rbt: BuiltinType,
        pre: str,
        fz: &[bool; 3],
    ) bool {
        assert(n > 0);
        let t = if rv.kind == ir::RV_SIMD {
            mbe::if_s(c == ir::SIMD_CAST_CHANGED, vec_changed_tpl(bt, rbt), vec_simd_tpl(c, bt, rbt));
        } else if rv.kind == ir::RV_CAST {
            vec_cast_tpl(bt, rbt);
        } else {
            vec_op_tpl(rv.kind == ir::RV_UNARY, pick(rv.kind == ir::RV_UNARY, rv.b as u8, rv.c), bt);
        };
        if t.len() == 0 {
            return self.fail("vector operation");
        }
        // The trap: up to two failure kinds (`/` and `%`: a zero divisor, then MIN / -1).
        let tok = pick(rv.kind == ir::RV_UNARY, rv.b as u8, rv.c);
        let traps = t.contains("__sc_f0");
        let two = t.contains("__sc_f1");
        let mask = c != 255u8 && (ir::simd_op(c).rule == ir::SR_MASK || ir::simd_op(c).rule == ir::SR_CHANGED);
        // Through the planner: a lane-mask comparison writes temps named for its local, and a
        // `choose` of such a local reads them.
        let mut vp = vplan_none();
        let planned = self.simd_on && self.vec_plan_of(b, place, rv, c, ops, lanes, n, bt, rbt, &mut vp);
        let mut psp: [String; 3] = [sp[0].clone(), sp[1].clone(), sp[2].clone()];
        let mut pd = d.clone();
        let na: u32 = if rv.kind == ir::RV_SIMD {
            ir::simd_op(c).arity;
        } else if rv.kind == ir::RV_BINARY {
            2;
        } else {
            1;
        };
        if planned && vp.res == VR_LANES {
            pd.clear();
            pd.format_into("__sc_ml{}", b.places.at(place as usize).base);
        }
        if planned && vp.kinds[0] == VK_LANES {
            psp[0].clear();
            psp[0].format_into("__sc_ml{}", self.ml_src(b.places.at(b.operands.at(ops[0] as usize).data as usize).base));
        }
        if planned && !traps {
            return self.emit_planned(o, &vp, &psp, na, pd.as_str());
        }
        if planned && rv.kind == ir::RV_BINARY && self.vec_checks_planned(o, &vp, &psp, rv, n, bt, pd.as_str()) {
            return true;
        }
        o.push_str("  {\n");
        if mask {
            o.push_str("  uint64_t __sc_m = 0;\n");
        }
        // A comparison that only `count` reads sums its lanes instead of packing their bits.
        let sum = mask && rv.kind == ir::RV_SIMD && c >= ir::SIMD_CMP_EQ && c <= ir::SIMD_CMP_GE && b.places.at(
            place as usize,
        ).proj_len == 0 && self.count_kind(b, b.places.at(place as usize).base) == CK_SUM;
        if sum {
            let st = String::from_str(t).replace("|= (uint64_t)", "+= (uint64_t)").replace(" << __sc_i", "");
            self.vec_loop(o, st.as_str(), d.as_str(), sp, lanes, n, bt, rbt, c, mask, pre, fz);
            o.format_into("  {} = __sc_m;\n  }}\n", d.as_str());
            return true;
        }
        if !traps {
            self.vec_loop(o, t, d.as_str(), sp, lanes, n, bt, rbt, c, mask, pre, fz);
            if mask {
                o.format_into("  {} = __sc_m;\n", d.as_str());
            }
            o.push_str("  }\n");
            return true;
        }
        o.push_str("  ");
        let ok = self.ty_c(b.module, rv.target, "", o);
        o.push_str(
            mbe::if_s(two, " __sc_r;\n  uint32_t __sc_f0 = 0, __sc_f1 = 0;\n", " __sc_r;\n  uint32_t __sc_f0 = 0;\n"),
        );
        let fast = String::from_str(t).replace("|= (uint64_t)", "|= ").replace(" << __sc_i", "");
        self.vec_loop(o, fast.as_str(), "__sc_r", sp, lanes, n, bt, rbt, c, mask, pre, fz);
        // `+ - *`, negation and `abs` trap where the build checks overflow (`__sc_lane_ovf`).
        let simd = rv.kind == ir::RV_SIMD;
        let ovf = simd && c == ir::SIMD_ABS || !simd && (tok == tt::TokenType::Plus as u8 || tok == tt::TokenType::Minus as u8 || tok == tt::TokenType::Star as u8);
        o.push_str(
            mbe::if_s(
                ovf,
                "  if (__sc_lane_ovf(__sc_f0)) {\n",
                mbe::if_s(two, "  if (__sc_f0 | __sc_f1) {\n", "  if (__sc_f0) {\n"),
            ),
        );
        o.push_str("  uint64_t __sc_g0 = 0, __sc_g1 = 0;\n");
        let cold = String::from_str(t).replace("__sc_f", "__sc_g");
        self.vec_loop(o, cold.as_str(), "__sc_r", sp, lanes, n, bt, rbt, c, mask, pre, fz);
        o.format_into(
            "  __sc_panic_lane(__sc_g0, __sc_g1, \"{}\", ",
            ir::lane_trap_msg(rv.kind, pick(simd, c, tok), false),
        );
        if two {
            o.format_into("\"{}\");\n  }}\n", ir::lane_trap_msg(rv.kind, pick(simd, c, tok), true));
        } else {
            o.push_str("0);\n  }\n");
        }
        if planned {
            // The checks passed: the entry of the wrapping twin computes the lanes.
            let pok = self.emit_planned(o, &vp, &psp, na, pd.as_str());
            o.push_str("  }\n");
            return ok && pok;
        }
        o.format_into("  {} = __sc_r;\n  }}\n", d.as_str());
        return ok;
    }

    // ---- the lowering planner (`simd_plan`) ---------------------------------------------------------

    // How `op` over `n` lanes of `t`, with result lane or scalar type `r`, lowers under the build's
    // features; SC_SIMD_TRACE reports it when no single entry covers the lanes.
    fn vplan(self: &Self, op: u32, t: BuiltinType, r: BuiltinType, n: i64) sp::Plan {
        let pk = self.p();
        let pl = sp::plan(&pk.simd_table, pk.features, pk.mem_check, op, t, r, n as u64);
        if self.simd_trace && pl.form != sp::PF_NATIVE {
            let nm = ir::op_variant(op);
            eprintln(
                "simd: no native entry for {} on {}x{}: {}",
                nm.as_str(),
                bt_name(t),
                n,
                mbe::if_s(pl.form == sp::PF_SPLIT, "chunks", "the lane loop"),
            );
        }
        return pl;
    }

    // The table index of the entry for `op` over `n` lanes of `t` with result `r`, or -1.
    fn ventry(self: &Self, op: u32, t: BuiltinType, r: BuiltinType, n: u64) i64 {
        return sp::find(&self.p().simd_table, self.p().features, self.p().mem_check, op, t, r, n);
    }

    // The C name of table entry `e`, `__sc_si_<symbol>`, recorded as a need of the current context:
    // the entry's definition header defines it (`static inline`, always inlined).
    fn entry_name(self: &mut Self, e: u32, out: &mut String) {
        let en = *self.p().simd_table.at(e as usize);
        let st = out.len();
        out.push_str("__sc_si_");
        let tg = self.mg.method_target(en.module, en.node);
        let _ = self.mg.fn_sym(en.module, en.node, tg, out);
        self.mg.need_name(out.as_str().slice(st, out.len()).hash(), true);
    }

    // Whether vector statement `rv` writing `place` names a vector whose address the body takes: a raw
    // pointer of the statement may then address it (`VPlan::raw`).
    fn vec_addr_taken(self: &Self, b: &ir::CoreBody, place: ir::PlaceId, rv: &ir::Rvalue) bool {
        if self.addressable(b, place) {
            return true;
        }
        let n = pick(rv.kind == ir::RV_SIMD, rv.b, 0u32);
        for i in 0..n {
            let x = *b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize);
            if x.kind != ir::OP_CONST && self.addressable(b, x.data) {
                return true;
            }
        }
        return false;
    }

    // Whether a pointer may address place `p`: a local whose address the body takes, a static, or a
    // place behind a projection (a field, an element, a dereference).
    fn addressable(self: &Self, b: &ir::CoreBody, p: ir::PlaceId) bool {
        let pl = *b.places.at(p as usize);
        return pl.proj_len != 0 || *self.sx_addr.at(pl.base as usize) || b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF;
    }

    // The bytes of parameter `i` of table entry `e` (its result for VP_RET).
    fn entry_bytes(self: &mut Self, e: u32, i: u32) u64 {
        let en = *self.p().simd_table.at(e as usize);
        let a = unsafe &*self.p().module_ast_const(en.module);
        let f = a.at_const(en.node).as_data.function;
        let tn = if i == VP_RET {
            a.slot_type_node(unsafe a.list(f.returns)[0]);
        } else {
            a.at_const(unsafe a.list(f.params)[i as usize]).as_data.parameter.ty;
        };
        let lo = self.mg.layout_sub(en.module, a.type_of(tn));
        return pick(lo.ok, lo.size, 0);
    }

    // The C declaration of `name` at parameter `i` of table entry `e` (its result for VP_RET).
    fn entry_ty(self: &mut Self, e: u32, i: u32, name: str, o: &mut String) bool {
        let en = *self.p().simd_table.at(e as usize);
        let a = unsafe &*self.p().module_ast_const(en.module);
        let f = a.at_const(en.node).as_data.function;
        let tn = if i == VP_RET {
            a.slot_type_node(unsafe a.list(f.returns)[0]);
        } else {
            a.at_const(unsafe a.list(f.params)[i as usize]).as_data.parameter.ty;
        };
        return self.ty_c(en.module, a.type_of(tn), name, o);
    }

    // The checks of a trapping `+ - *` or shift `rv` over `n` lanes of `bt` without its lane loop, then
    // its wrapping twin's plan `vp` (operand spellings `sp`) into `d`: `+ - *` through the
    // `OverflowAdd`/`Sub`/`Mul` entry of the same chunks, whose bits name the failing lanes; a shift
    // by a scalar count by testing the count once (every lane fails alike, lane 0 first), by a vector
    // count by the bits of the lanes whose count is out of range. False when there is no such entry
    // (nothing written).
    fn vec_checks_planned(
        self: &mut Self,
        o: &mut String,
        vp: &VPlan,
        sp: &[String; 3],
        rv: &ir::Rvalue,
        n: i64,
        bt: BuiltinType,
        d: str,
    ) bool {
        let k = tok_op(rv.c as tt::TokenType);
        let msg = ir::lane_trap_msg(rv.kind, rv.c, false);
        if (k == ir::OP_SHL || k == ir::OP_SHR) && vp.kinds[1] != VK_VEC {
            o.format_into(
                "  if ((uint64_t)({}) >= {}u) __sc_panic_lane(1, 0, \"{}\", 0);\n",
                sp[1].as_str(),
                lane_bytes(bt) * 8,
                msg,
            );
            return self.emit_planned(o, vp, sp, 2, d);
        }
        if k == ir::OP_SHL || k == ir::OP_SHR {
            // A count per lane: the bits of the lanes whose count is below 0 or of the width or more.
            o.format_into(
                "  {{\n  uint64_t __sc_f0 = 0;\n  for (size_t __sc_i = 0; __sc_i < {}; __sc_i++) __sc_f0 |= (uint64_t)((uint64_t){}.l[__sc_i] >= {}u) << __sc_i;\n",
                n,
                sp[1].as_str(),
                lane_bytes(bt) * 8,
            );
            o.format_into("  if (__sc_f0) __sc_panic_lane(__sc_f0, 0, \"{}\", 0);\n", msg);
            let ok = self.emit_planned(o, vp, sp, 2, d);
            o.push_str("  }\n");
            return ok;
        }
        if k > ir::OP_MUL {
            return false;
        }
        let mut ov = *vp;
        ov.pl = self.vplan(ir::OP_SIMD + ir::SIMD_OVF_ADD as u32 + k, bt, BuiltinType::BT_BOOL, n);
        ov.res = VR_MASK;
        if ov.pl.form != vp.pl.form || ov.pl.chunk_lanes != vp.pl.chunk_lanes {
            return false;
        }
        o.push_str("  {\n  uint64_t __sc_f0;\n");
        let ok = self.emit_planned(o, &ov, sp, 2, "__sc_f0");
        o.format_into("  if (__sc_lane_ovf(__sc_f0)) __sc_panic_lane(__sc_f0, 0, \"{}\", 0);\n", msg);
        let ok2 = self.emit_planned(o, vp, sp, 2, d);
        o.push_str("  }\n");
        return ok && ok2;
    }

    // `d = <entry>(args)` for plan `vp`: one call over all the lanes, or one per chunk in lane order.
    // A vector of 16-byte chunks is read and written in place (`v.c[k]`, `Mangler::vec_def`); another,
    // or any operand of a raw form, is copied out before the first call and the result back after the
    // last (the entry's own parameter and result types spell the chunks: no type is made). `sp`
    // spells the arguments (`vp.kinds`); `vp.wres`, when set, applies to each call's result and
    // `vp.warg` to argument 0.
    fn emit_planned(self: &mut Self, o: &mut String, vp: &VPlan, sp: &[String; 3], na: u32, d: str) bool {
        let pl = vp.pl;
        let split = pl.form == sp::PF_SPLIT;
        let re = if vp.wres >= 0 {
            vp.wres as u32;
        } else {
            pl.entry;
        };
        let mut ok = true;
        // In place: a vector operand or result whose chunk is 16 bytes, outside a raw form.
        let mut inp: [bool; 3] = [false; 3];
        for i in 0..na {
            unsafe inp[i as usize] = split && !vp.raw && unsafe vp.kinds[i as usize] == VK_VEC && self.entry_bytes(
                pl.entry,
                i,
            ) == 16;
        }
        let rin = split && !vp.raw && vp.res == VR_VEC && vp.nsteps == 0 && self.entry_bytes(re, VP_RET) == 16;
        if vp.res == VR_LANES {
            // The comparison's lane masks outlive this statement: its `choose` follows in the block;
            // narrowed, they are the last cast's chunks.
            let ne = pick(vp.nsteps > 0, unsafe vp.narrow[(vp.nsteps - pick(vp.nsteps > 0, 1u32, 0u32)) as usize], re);
            for k in 0..pl.chunks >> vp.npairs.count_ones() as u64 {
                o.push_str("  ");
                ok = ok && self.entry_ty(ne as u32, VP_RET, format("{}_{}", d, k).as_str(), o);
                o.push_str(";\n");
            }
        }
        o.push_str("  {\n");
        // A narrowing's comparison calls, in chunk order (`emit_narrow`).
        let mut calls = Vector::<String>::new();
        if split {
            // A vector operand not read in place is copied out before any chunk is written: a raw
            // form's pointer may address it or the result. Pointers, masks and scalars are spelled at
            // each call.
            for i in 0..na {
                if unsafe vp.kinds[i as usize] == VK_VEC && !unsafe inp[i as usize] {
                    o.push_str("  ");
                    ok = ok && self.entry_ty(pl.entry, i, format("__sc_k{}[{}]", i, pl.chunks).as_str(), o);
                    o.format_into(
                        ";\n  memcpy(__sc_k{}, &{}, sizeof(__sc_k{}));\n",
                        i,
                        unsafe sp[i as usize].as_str(),
                        i,
                    );
                }
            }
            if !rin && vp.res == VR_VEC {
                o.push_str("  ");
                ok = ok && self.entry_ty(re, VP_RET, format("__sc_kr[{}]", pl.chunks).as_str(), o);
                o.push_str(";\n");
            } else if vp.res == VR_MASK {
                o.push_str("  uint64_t __sc_m = 0;\n");
            } else if vp.res == VR_ANY || vp.res == VR_ALL {
                o.format_into("  bool __sc_m = {};\n", (vp.res == VR_ALL) as u32);
            }
        }
        let mut call = String::new();
        for k in 0..pl.chunks {
            let lo = k * pl.chunk_lanes;
            call.clear();
            if vp.wres >= 0 {
                self.entry_name(vp.wres as u32, &mut call);
                call.push_byte(b'(');
            }
            self.entry_name(pl.entry, &mut call);
            call.push_byte(b'(');
            for i in 0..na {
                let s = unsafe sp[i as usize].as_str();
                if i != 0 {
                    call.push_str(", ");
                }
                let w0 = i == 0 && vp.warg >= 0;
                if w0 {
                    self.entry_name(vp.warg as u32, &mut call);
                    call.push_byte(b'(');
                }
                let kd = unsafe vp.kinds[i as usize];
                if kd == VK_LANES {
                    call.format_into("{}_{}", s, k);
                } else if unsafe inp[i as usize] {
                    call.format_into("{}.c[{}]", s, k);
                } else if !split {
                    call.push_str(s);
                } else if kd == VK_VEC {
                    call.format_into("__sc_k{}[{}]", i, k);
                } else if kd == VK_MASK {
                    // The chunk's lane bits, as its mask type.
                    call.push_byte(b'(');
                    ok = ok && self.entry_ty(pick(w0, vp.warg as u32, pl.entry), pick(w0, 0, i), "", &mut call);
                    call.format_into(")((uint64_t)({}) >> {} & {}u)", s, lo, (1u64 << pl.chunk_lanes) - 1);
                } else if kd == VK_PTR {
                    call.format_into("{} + {}", s, lo);
                } else {
                    call.push_str(s);
                }
                if w0 {
                    call.push_byte(b')');
                }
            }
            call.push_byte(b')');
            if vp.wres >= 0 {
                call.push_byte(b')');
            }
            if vp.res == VR_FOLD && k == 0 {
                o.push_str("  ");
                ok = ok && self.entry_ty(pl.entry, VP_RET, "__sc_s", o);
                o.format_into(" = {};\n", call.as_str());
            } else if vp.res == VR_FOLD {
                o.push_str("  __sc_s = ");
                self.entry_name(vp.cadd as u32, o);
                o.format_into("(__sc_s, {});\n", call.as_str());
            } else if vp.nsteps > 0 {
                calls.push(call.clone());
            } else if vp.res == VR_LANES {
                o.format_into("  {}_{} = {};\n", d, k, call.as_str());
            } else if vp.res == VR_UNIT {
                o.format_into("  {};\n", call.as_str());
            } else if vp.res == VR_ALL && !split {
                o.format_into("  {} = {} ? {}u : 0;\n", d, call.as_str(), vp.ones);
            } else if vp.res >= VR_ANY && split {
                // The chunks' tests in lane order: the first that decides ends the chain.
                o.format_into("  __sc_m = __sc_m {} {};\n", mbe::if_s(vp.res == VR_ALL, "&&", "||"), call.as_str());
            } else if !split {
                o.format_into("  {} = {};\n", d, call.as_str());
            } else if vp.res == VR_MASK {
                o.format_into("  __sc_m |= (uint64_t){} << {};\n", call.as_str(), lo);
            } else if rin {
                o.format_into("  {}.c[{}] = {};\n", d, k, call.as_str());
            } else {
                o.format_into("  __sc_kr[{}] = {};\n", k, call.as_str());
            }
        }
        if vp.nsteps > 0 {
            ok = ok && self.emit_narrow(o, vp, d, &mut calls);
        }
        if vp.res == VR_FOLD && vp.ones == 0 {
            o.format_into("  {} = ", d);
            self.entry_name(vp.cred as u32, o);
            o.push_str("(__sc_s);\n");
        } else if vp.res == VR_FOLD {
            // Each active lane is all ones (-1): the sum's negation, in the lane type, is the count.
            o.format_into("  {} = (0 - (uint64_t)", d);
            self.entry_name(vp.cred as u32, o);
            o.format_into("(__sc_s)) & {}u;\n", vp.ones);
        } else if split && vp.res == VR_VEC && !rin {
            o.format_into("  memcpy(&{}, __sc_kr, sizeof(__sc_kr));\n", d);
        } else if split && (vp.res == VR_MASK || vp.res == VR_ANY) {
            o.format_into("  {} = __sc_m;\n", d);
        } else if split && vp.res == VR_ALL {
            o.format_into("  {} = __sc_m ? {}u : 0;\n", d, vp.ones);
        }
        o.push_str("  }\n");
        return ok;
    }

    // The narrowing steps (`narrow_plan`) of the comparison calls `calls` into the temps `<d>_<k>`, one
    // expression each: a pair of chunks is the cast's wider operand, a compound literal of its chunks.
    fn emit_narrow(self: &mut Self, o: &mut String, vp: &VPlan, d: str, calls: &mut Vector<String>) bool {
        let mut ok = true;
        for s in 0..vp.nsteps {
            let e = (unsafe vp.narrow[s as usize]) as u32;
            let pair = (vp.npairs >> s & 1) != 0;
            let mut next = Vector::<String>::new();
            for j in 0..pick(pair, calls.len() / 2, calls.len()) {
                let mut x = String::new();
                self.entry_name(e, &mut x);
                x.push_byte(b'(');
                if pair {
                    // The two chunks as the cast's wider operand.
                    x.push_byte(b'(');
                    ok = ok && self.entry_ty(e, 0, "", &mut x);
                    x.format_into("){{ .c = {{ {}, {} }} }}", calls.at(2 * j).as_str(), calls.at(2 * j + 1).as_str());
                } else {
                    x.push_string(calls.at(j));
                }
                x.push_byte(b')');
                next.push(x);
            }
            *calls = next;
        }
        for j in 0..calls.len() {
            o.format_into("  {}_{} = {};\n", d, j, calls.at(j).as_str());
        }
        return ok;
    }

    // The plan of lane-wise vector statement `rv` (`emit_vec_lanes`) writing `place`, operands `ops`
    // (`lanes`: a vector), `n` lanes of `bt` and result lanes `rbt`: the entry of the operation, or of
    // its wrapping twin when the operation traps (the lane loop computes the failures first). A
    // comparison is a lane-mask comparison, then its conversion to bits, or lane-mask temps when the one
    // `choose` that reads it can take them (`lane_only`); `choose` reads such temps, else converts its
    // mask to lanes. False for the lane loop.
    fn vec_plan_of(
        self: &mut Self,
        b: &ir::CoreBody,
        place: ir::PlaceId,
        rv: &ir::Rvalue,
        c: u8,
        ops: &[u32; 3],
        lanes: &[bool; 3],
        n: i64,
        bt: BuiltinType,
        rbt: BuiltinType,
        vp: &mut VPlan,
    ) bool {
        let fl = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
        for i in 0..3usize {
            unsafe vp.kinds[i] = pick(unsafe lanes[i], VK_VEC, VK_SCALAR);
        }
        let mut op = ir::OP_COUNT;
        let mut r = bt;
        if rv.kind == ir::RV_BINARY {
            let k = tok_op(rv.c as tt::TokenType);
            if !lanes[1] {
                op = if k == ir::OP_SHL {
                    ir::OP_SHL_SCALAR;
                } else if k == ir::OP_SHR {
                    ir::OP_SHR_SCALAR;
                } else {
                    ir::OP_COUNT;
                };
            } else if fl {
                op = pick(k <= ir::OP_DIV, k, ir::OP_COUNT);
            } else if k <= ir::OP_MUL {
                op = ir::OP_SIMD + ir::SIMD_WRAP_ADD as u32 + k;
            } else if k == ir::OP_SHL || k == ir::OP_SHR {
                op = ir::OP_SIMD + ir::SIMD_WRAP_SHL as u32 + k - ir::OP_SHL;
            } else {
                op = pick(k >= ir::OP_AND && k <= ir::OP_XOR, k, ir::OP_COUNT);
            }
        } else if rv.kind == ir::RV_UNARY {
            op = if rv.b != tt::TokenType::Minus as u32 {
                ir::OP_NOT;
            } else if fl {
                ir::OP_NEG;
            } else {
                ir::OP_SIMD + ir::SIMD_WRAP_NEG as u32;
            };
        } else if rv.kind == ir::RV_CAST {
            op = ir::OP_CAST;
            r = rbt;
        } else if c >= ir::SIMD_CMP_EQ && c <= ir::SIMD_CMP_GE {
            let u = lane_mask_bt(bt);
            vp.pl = self.vplan(ir::OP_CMP_LANES + (c - ir::SIMD_CMP_EQ) as u32, bt, u, n);
            if vp.pl.form == sp::PF_SCALAR {
                return false;
            }
            let l = b.places.at(place as usize).base;
            let mut to = u;
            if b.places.at(place as usize).proj_len == 0 && self.ml_lanes(b, l, &mut to) {
                let mut cl: u64 = 0;
                let mut ch = vp.pl.chunks;
                if to != u {
                    let pl = vp.pl;
                    let _ = self.narrow_plan(u, to, &pl, vp, &mut cl, &mut ch);
                }
                self.ml_chunks.set(l as usize, ch as u32);
                vp.res = VR_LANES;
                return true;
            }
            // The one read is `count`: the chunks' lane masks summed, then reduced (`count_kind`).
            if b.places.at(place as usize).proj_len == 0 && self.count_kind(b, l) == CK_FOLD {
                let _ = self.count_plan(b, l, vp);
                vp.res = VR_FOLD;
                return true;
            }
            // The one test of the result by `any`, `none`, `all` or `!all`: a lane-mask reduction.
            let mut all = false;
            if b.places.at(place as usize).proj_len == 0 && self.mask_red(b, l, n, &mut all) {
                vp.wres = self.ventry(
                    pick(all, ir::OP_ALL_LANES, ir::OP_ANY_LANES),
                    u,
                    BuiltinType::BT_BOOL,
                    vp.pl.chunk_lanes,
                );
                vp.res = pick(all, VR_ALL, VR_ANY);
                vp.ones = ~0u64 >> (64 - n) as u64;
                if vp.wres >= 0 {
                    return true;
                }
            }
            vp.wres = self.ventry(ir::OP_LANES_TO_MASK, u, BuiltinType::BT_BOOL, vp.pl.chunk_lanes);
            vp.res = VR_MASK;
            return vp.wres >= 0;
        } else if c == ir::SIMD_CHOOSE {
            vp.pl = self.vplan(ir::OP_CHOOSE_LANES, bt, bt, n);
            let m = *b.operands.at(ops[0] as usize);
            if m.kind != ir::OP_CONST && b.places.at(m.data as usize).proj_len == 0 && self.ml_src(
                b.places.at(m.data as usize).base,
            ) != ir::IR_NONE {
                vp.kinds[0] = VK_LANES;
                return true;
            }
            vp.kinds[0] = VK_MASK;
            if vp.pl.form != sp::PF_SCALAR {
                let u = lane_mask_bt(bt);
                vp.warg = self.ventry(ir::OP_MASK_TO_LANES, u, u, vp.pl.chunk_lanes);
                if vp.warg >= 0 {
                    return true;
                }
            }
            vp.pl = self.vplan(ir::OP_SIMD + c as u32, bt, bt, n);
            return vp.pl.form != sp::PF_SCALAR;
        } else {
            op = ir::OP_SIMD + pick(c == ir::SIMD_ABS && !fl, ir::SIMD_WRAP_ABS, c) as u32;
            let rule = ir::simd_op(c).rule;
            if rule == ir::SR_MASK || rule == ir::SR_CHANGED {
                r = BuiltinType::BT_BOOL;
                vp.res = VR_MASK;
                if rule == ir::SR_CHANGED {
                    // The key names the cast result's lanes (`tc_simd_shape`).
                    let mut cn: i64 = 0;
                    let _ = self.vec_ty(b, b.operands.at(ops[1] as usize).ty, &mut cn, &mut r);
                }
            } else if rule == ir::SR_LANES {
                r = rbt;
            } else if rule != ir::SR_VEC {
                return false;
            }
        }
        if op == ir::OP_COUNT {
            if self.simd_trace {
                // No entry form: integer `/` and `%`, a trapping shift by a vector count.
                let k = if rv.kind == ir::RV_SIMD {
                    ir::OP_SIMD + c as u32;
                } else {
                    tok_op(rv.c as tt::TokenType);
                };
                eprintln(
                    "simd: no entry form for {} on {}x{}: the lane loop",
                    ir::op_variant(k).as_str(),
                    bt_name(bt),
                    n,
                );
            }
            return false;
        }
        vp.pl = self.vplan(op, bt, r, n);
        return vp.pl.form != sp::PF_SCALAR;
    }

    // An index, run-time index or reduction operation of `emit_vec_ops` under the planner. A constant
    // index list is the C compiler's shuffle of the lanes, which it lowers to the target's shuffle
    // instructions (`i8x16.shuffle`): the indexes stay constants. A run-time index or a reduction
    // calls its entry, a reduction split into chunks first combining them by halves in its
    // definition's order. False when the planner chose the loop (nothing written).
    fn emit_vec_ops_planned(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        rv: &ir::Rvalue,
        sp: &[String; 4],
        n: i64,
        bt: BuiltinType,
        rn: i64,
        rbt: BuiltinType,
        d: str,
    ) bool {
        let c = rv.c;
        let rule = ir::simd_op(c).rule;
        if rule == ir::SR_INDEX {
            if rv.item.node == ir::IR_NONE {
                return false;
            }
            o.format_into(
                "  {{\n  typedef {} __sc_gv __attribute__((vector_size({})));\n",
                mbe::bt_c_decl(bt),
                n as u64 * lane_bytes(bt),
            );
            let w = ir::simd_op(c).arity as usize;
            for i in 0..w {
                o.format_into(
                    "  __sc_gv __sc_g{};\n  memcpy(&__sc_g{}, &{}, sizeof(__sc_gv));\n",
                    i,
                    i,
                    unsafe sp[i].as_str(),
                );
            }
            o.format_into("  __auto_type __sc_gr = __builtin_shufflevector(__sc_g0, __sc_g{}", w - 1);
            for i in 0..rn as u64 {
                o.format_into(", {}", ir::aux_lane(b, rv.item.node, i));
            }
            o.format_into(");\n  memcpy(&{}, &__sc_gr, sizeof(__sc_gr));\n  }}\n", d);
            return true;
        }
        // A dot product has no combining operation, and compress and expand move lanes across the whole
        // vector: one call over all the lanes, as a run-time index.
        let whole = rule == ir::SR_RT_INDEX || rule == ir::SR_DOT || rule == ir::SR_MASKED;
        if !whole && rule != ir::SR_REDUCE || rule == ir::SR_RT_INDEX && rn != n {
            return false;
        }
        // A run-time index's key names the index lanes' type.
        let mut r = pick(rule == ir::SR_RT_INDEX, bt, rbt);
        if rule == ir::SR_RT_INDEX {
            let mut xn: i64 = 0;
            let _ = self.vec_ty(b, b.operands.at(b.oper_pool[(rv.a + 1) as usize] as usize).ty, &mut xn, &mut r);
        }
        let pl = self.vplan(ir::OP_SIMD + c as u32, bt, r, n);
        if pl.form == sp::PF_SCALAR || whole && pl.form != sp::PF_NATIVE {
            return false;
        }
        let mut call = String::new();
        self.entry_name(pl.entry, &mut call);
        call.push_byte(b'(');
        if rule == ir::SR_MASKED {
            // The mask's bits as the entry's mask type.
            call.push_byte(b'(');
            if !self.entry_ty(pl.entry, 0, "", &mut call) {
                return false;
            }
            call.format_into(")({}), {}, {})", sp[0].as_str(), sp[1].as_str(), sp[2].as_str());
        } else if whole {
            call.format_into("{}, {})", sp[0].as_str(), sp[1].as_str());
        } else if pl.form == sp::PF_NATIVE {
            call.format_into("{})", sp[0].as_str());
        } else if self.entry_bytes(pl.entry, 0) == 16 {
            // The chunks in place, the upper half of them onto the lower half until one is left: one
            // expression.
            let mut cn = String::new();
            self.entry_name(pl.combine, &mut cn);
            let mut levels: u64 = 0;
            while 1u64 << levels < pl.chunks && levels < 6 {
                levels += 1;
            }
            reduce_tree(&mut call, cn.as_str(), sp[0].as_str(), pl.chunks, levels, 0);
            call.push_byte(b')');
        } else {
            // The chunks, then the upper half of them onto the lower half until one is left.
            o.push_str("  {\n");
            for k in 0..pl.chunks {
                o.push_str("  ");
                if !self.entry_ty(pl.entry, 0, format("__sc_q{}", k).as_str(), o) {
                    return false;
                }
                o.format_into(
                    ";\n  memcpy(&__sc_q{}, (char *)&{} + {}, sizeof(__sc_q{}));\n",
                    k,
                    sp[0].as_str(),
                    k * pl.chunk_lanes * lane_bytes(bt),
                    k,
                );
            }
            let mut cn = String::new();
            self.entry_name(pl.combine, &mut cn);
            let mut h = pl.chunks / 2;
            while h >= 1 {
                for i in 0..h {
                    o.format_into("  __sc_q{} = {}(__sc_q{}, __sc_q{});\n", i, cn.as_str(), i, i + h);
                }
                h /= 2;
            }
            o.format_into("  {} = {}__sc_q0);\n  }}\n", d, call.as_str());
            return true;
        }
        o.format_into("  {} = {};\n", d, call.as_str());
        return true;
    }

    // The local whose lane-mask temps local `l` reads (itself, or the comparison result it copies),
    // or IR_NONE when it reads none.
    fn ml_src(self: &Self, l: u32) u32 {
        if self.ml_chunks.len() == 0 {
            return ir::IR_NONE;
        }
        let a = self.ml_alias[l as usize];
        let x = pick(a != ir::IR_NONE, a, l);
        return pick(self.ml_chunks[x as usize] != 0, x, ir::IR_NONE);
    }

    // The statement of the one `choose` that reads mask local `l` as its mask, after the comparison
    // that writes `l` in the same block, when nothing else names `l`; IR_NONE otherwise. The body's
    // uses are counted on the first ask.
    fn lane_only(self: &mut Self, b: &ir::CoreBody, l: u32) u32 {
        if self.ml_ch.len() == 0 {
            let nl = b.locals.len();
            self.ml_cnt.resize_default(nl);
            self.ml_def.resize_default(nl);
            let mut cp = self.uget(); // per local: the statement that copies it whole
            cp.resize_default(nl);
            let mut sb = self.uget(); // per statement: its block
            sb.resize_default(b.statements.len());
            for i in 0..b.blocks.len() {
                let bb = b.blocks.at(i);
                for k in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                    sb.set(k as usize, i as u32);
                }
            }
            self.ml_ch.resize_default(nl);
            self.ml_chunks.resize_default(nl);
            self.ml_alias.resize_default(nl);
            self.ml_use.resize_default(nl);
            for i in 0..nl {
                self.ml_ch.set(i, ir::IR_NONE);
                self.ml_alias.set(i, ir::IR_NONE);
                self.ml_use.set(i, ir::IR_NONE);
                self.ml_def.set(i, ir::IR_NONE);
                cp.set(i, ir::IR_NONE);
            }
            // Every operand names one use; a reference, a second definition or a call result
            // disqualifies the local.
            for i in 0..b.operands.len() {
                let x = *b.operands.at(i);
                if x.kind != ir::OP_CONST {
                    let k = b.places.at(x.data as usize).base as usize;
                    self.ml_cnt.set(k, self.ml_cnt[k] + 1);
                }
            }
            for i in 0..b.statements.len() {
                let st = *b.statements.at(i);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let k = b.places.at(st.place as usize).base as usize;
                self.ml_def.set(k, pick(self.ml_def[k] == ir::IR_NONE, i as u32, ir::IR_NONE - 1));
                let rv = *b.rvalues.at(st.rvalue as usize);
                if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_BINARY {
                    for x in [rv.a, pick(rv.kind == ir::RV_BINARY, rv.b, rv.a)] {
                        let xo = *b.operands.at(x as usize);
                        if xo.kind != ir::OP_CONST && b.places.at(xo.data as usize).proj_len == 0 {
                            self.ml_use.set(b.places.at(xo.data as usize).base as usize, i as u32);
                        }
                    }
                }
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
                    let rk = b.places.at(rv.a as usize).base as usize;
                    self.ml_cnt.set(rk, self.ml_cnt[rk] + 2);
                }
                if rv.kind == ir::RV_SIMD && rv.c == ir::SIMD_CHOOSE {
                    let m = *b.operands.at(b.oper_pool[rv.a as usize] as usize);
                    if m.kind != ir::OP_CONST && b.places.at(m.data as usize).proj_len == 0 {
                        self.ml_ch.set(b.places.at(m.data as usize).base as usize, i as u32);
                    }
                }
                if rv.kind == ir::RV_USE && b.places.at(st.place as usize).proj_len == 0 {
                    let x = *b.operands.at(rv.a as usize);
                    if x.kind != ir::OP_CONST && b.places.at(x.data as usize).proj_len == 0 {
                        cp.set(b.places.at(x.data as usize).base as usize, i as u32);
                    }
                }
            }
            for i in 0..b.blocks.len() {
                let t = &b.blocks.at(i).term;
                if self.popcount_call(t) {
                    let x = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
                    if x.kind != ir::OP_CONST && b.places.at(x.data as usize).proj_len == 0 {
                        self.ml_use.set(b.places.at(x.data as usize).base as usize, ML_POP);
                    }
                }
                if t.kind == ir::TM_CALL {
                    for j in 0..t.dests_len {
                        let k = b.places.at(b.dest_pool[(t.dests_start + j) as usize] as usize).base as usize;
                        self.ml_cnt.set(k, self.ml_cnt[k] + 2);
                    }
                }
            }
            for i in 0..nl {
                let ci = self.ml_ch[i];
                let di = self.ml_def[i];
                if ci == ir::IR_NONE || self.ml_cnt[i] != 1 || di >= ir::IR_NONE - 1 || di > ci || sb[di as usize] != sb[ci as usize] {
                    self.ml_ch.set(i, ir::IR_NONE);
                }
            }
            // A local whose one read is a whole copy into such a local: the copy's `choose` reads it.
            for i in 0..nl {
                let ci = cp[i];
                let di = self.ml_def[i];
                if self.ml_ch[i] != ir::IR_NONE || ci == ir::IR_NONE || self.ml_cnt[i] != 1 || di >= ir::IR_NONE - 1 {
                    continue;
                }
                let t = b.places.at(b.statements.at(ci as usize).place as usize).base as usize;
                let ch = self.ml_ch[t];
                if ch != ir::IR_NONE && self.ml_def[t] == ci && di < ci && sb[di as usize] == sb[ch as usize] {
                    self.ml_ch.set(i, ch);
                    self.ml_alias.set(t, i as u32);
                }
            }
            self.uput(cp);
            self.uput(sb);
        }
        return self.ml_ch[l as usize];
    }

    // Whether comparison result `l` lives in lane-mask temporaries (`__sc_ml<l>_<k>`): its one read
    // is a `choose` (`lane_only`) whose plan takes them chunk for chunk. Its variable then holds
    // nothing, so it is not declared, nor the copy the `choose` reads it through.
    fn ml_lanes(self: &mut Self, b: &ir::CoreBody, l: u32, to: &mut BuiltinType) bool {
        if !self.simd_on {
            return false;
        }
        let ci = self.lane_only(b, l);
        let d = pick(ci == ir::IR_NONE, ir::IR_NONE, self.ml_def[l as usize]);
        if d >= ir::IR_NONE - 1 {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(d as usize).rvalue as usize);
        if rv.kind != ir::RV_SIMD || rv.c < ir::SIMD_CMP_EQ || rv.c > ir::SIMD_CMP_GE {
            return false;
        }
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let _ = self.vec_ty(b, b.operands.at(b.oper_pool[rv.a as usize] as usize).ty, &mut n, &mut bt);
        let cr = *b.rvalues.at(b.statements.at(ci as usize).rvalue as usize);
        let mut cn: i64 = 0;
        let mut cbt = BuiltinType::BT_VOID;
        let _ = self.vec_ty(b, b.operands.at(b.oper_pool[(cr.a + 1) as usize] as usize).ty, &mut cn, &mut cbt);
        let u = lane_mask_bt(bt);
        let pk = self.p();
        let pl = sp::plan(
            &pk.simd_table,
            pk.features,
            pk.mem_check,
            ir::OP_CMP_LANES + (rv.c - ir::SIMD_CMP_EQ) as u32,
            bt,
            u,
            n as u64,
        );
        let cp = sp::plan(&pk.simd_table, pk.features, pk.mem_check, ir::OP_CHOOSE_LANES, cbt, cbt, cn as u64);
        *to = lane_mask_bt(cbt);
        if pl.form == sp::PF_SCALAR || cp.form == sp::PF_SCALAR || cn != n {
            return false;
        }
        if *to == u {
            return cp.form == pl.form && cp.chunk_lanes == pl.chunk_lanes;
        }
        // A `choose` of narrower lanes takes the lane masks narrowed to its chunks.
        let mut vp = vplan_none();
        let mut cl: u64 = 0;
        let mut ch: u64 = 0;
        return lane_bytes(*to) < lane_bytes(u) && self.narrow_plan(u, *to, &pl, &mut vp, &mut cl, &mut ch) && cl == cp.chunk_lanes && ch == cp.chunks;
    }

    // The steps that narrow lane masks of `from` over the chunks of plan `pl` to lanes of `to` (into
    // `vp`), each the truncating cast entry over a pair of chunks into one, else over one chunk; the
    // final chunk lanes in `cl` and chunk count in `ch`. False when a step has no entry.
    fn narrow_plan(
        self: &Self,
        from: BuiltinType,
        to: BuiltinType,
        pl: &sp::Plan,
        vp: &mut VPlan,
        cl: &mut u64,
        ch: &mut u64,
    ) bool {
        *cl = pl.chunk_lanes;
        *ch = pl.chunks;
        vp.nsteps = 0;
        vp.npairs = 0;
        let mut t = from;
        // Each step halves the lane width: three at most (8 bytes to 1).
        for s in 0..3u32 {
            if lane_bytes(t) == lane_bytes(to) {
                break;
            }
            let h = mask_bt_of(lane_bytes(t) / 2);
            // A pair step's operand is two 16-byte chunks (`Mangler::vec_def`'s `c`).
            let pe = pick(*ch % 2 == 0 && *cl * lane_bytes(t) == 16, self.ventry(ir::OP_CAST, t, h, *cl * 2), -1);
            let e = pick(pe >= 0, pe, self.ventry(ir::OP_CAST, t, h, *cl));
            if e < 0 {
                return false;
            }
            unsafe vp.narrow[s as usize] = e;
            if pe >= 0 {
                vp.npairs |= 1u32 << s;
                *cl *= 2;
                *ch /= 2;
            }
            vp.nsteps = s + 1;
            t = h;
        }
        return lane_bytes(t) == lane_bytes(to);
    }

    // Whether comparison result `l` (`n` lanes) reaches only one test, `x != 0` or `x == 0` (`any`,
    // `none`) or, with `all`, `x == ` or `x != ` the `n` low bits (`all`, `!all`), of its cast to u64,
    // through whole copies: each local of the chain defined once and read once. The comparison may
    // then write any value the test reads the same: 1 or 0 for `any`, the `n` bits or 0 for `all`.
    fn mask_red(self: &mut Self, b: &ir::CoreBody, l: u32, n: i64, all: &mut bool) bool {
        let _ = self.lane_only(b, l);
        let mut x = l;
        let mut cast = false;
        // Eight copies at most, then the cast and the test.
        for _ in 0..10 {
            let u = self.ml_use[x as usize];
            if self.ml_cnt[x as usize] != 1 || u >= ML_POP || self.ml_def[x as usize] >= ir::IR_NONE - 1 {
                return false;
            }
            let st = *b.statements.at(u as usize);
            let rv = *b.rvalues.at(st.rvalue as usize);
            if rv.kind == ir::RV_BINARY {
                let t = rv.c as tt::TokenType;
                let ka = *b.operands.at(rv.a as usize);
                let k = pick(ka.kind != ir::OP_CONST && b.places.at(ka.data as usize).base == x, rv.b, rv.a);
                let mut v: u64 = 0;
                if !cast || t != tt::TokenType::EqualEqual && t != tt::TokenType::BangEqual || !self.const_u64(
                    b,
                    k,
                    &mut v,
                    0,
                ) {
                    return false;
                }
                *all = v != 0;
                return v == 0 || v == ~0u64 >> (64 - n) as u64;
            }
            let y = b.places.at(st.place as usize).base;
            let to_u64 = rv.kind == ir::RV_CAST && !cast && self.rty_y(b, rv.target).as_data.builtin == BuiltinType::BT_U64;
            if b.places.at(st.place as usize).proj_len != 0 || self.ml_def[y as usize] != u || rv.kind != ir::RV_USE && !to_u64 {
                return false;
            }
            cast = cast || to_u64;
            x = y;
        }
        return false;
    }

    // The argument local of the one `sc_popcount64` call (`count`) that comparison result `l` reaches,
    // through whole copies and one cast to u64, each local of the chain defined once and read once;
    // IR_NONE otherwise. The comparison may then write its lane count, and the call pass it through.
    fn mask_count(self: &mut Self, b: &ir::CoreBody, l: u32) u32 {
        let _ = self.lane_only(b, l);
        let mut x = l;
        let mut cast = false;
        // Eight copies at most, then the cast and the call.
        for _ in 0..10 {
            let u = self.ml_use[x as usize];
            if self.ml_cnt[x as usize] != 1 || self.ml_def[x as usize] >= ir::IR_NONE - 1 || u > ML_POP || u == ML_POP && !cast {
                return ir::IR_NONE;
            }
            if u == ML_POP {
                return x;
            }
            let st = *b.statements.at(u as usize);
            let rv = *b.rvalues.at(st.rvalue as usize);
            let y = b.places.at(st.place as usize).base;
            let to_u64 = rv.kind == ir::RV_CAST && !cast && self.rty_y(b, rv.target).as_data.builtin == BuiltinType::BT_U64;
            if b.places.at(st.place as usize).proj_len != 0 || self.ml_def[y as usize] != u || rv.kind != ir::RV_USE && !to_u64 {
                return ir::IR_NONE;
            }
            cast = cast || to_u64;
            x = y;
        }
        return ir::IR_NONE;
    }

    // The count plan of comparison result `l` (`mask_count`): its lane-mask plan, the wrapping `+`
    // entry over its chunks (when several) and the `reduce_add` entry. False when one is missing.
    fn count_plan(self: &mut Self, b: &ir::CoreBody, l: u32, vp: &mut VPlan) bool {
        let d = self.ml_def[l as usize];
        let rv = *b.rvalues.at(b.statements.at(d as usize).rvalue as usize);
        if rv.kind != ir::RV_SIMD || rv.c < ir::SIMD_CMP_EQ || rv.c > ir::SIMD_CMP_GE {
            return false;
        }
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let _ = self.vec_ty(b, b.operands.at(b.oper_pool[rv.a as usize] as usize).ty, &mut n, &mut bt);
        let u = lane_mask_bt(bt);
        vp.pl = self.vplan(ir::OP_CMP_LANES + (rv.c - ir::SIMD_CMP_EQ) as u32, bt, u, n);
        let cl = vp.pl.chunk_lanes;
        vp.cred = self.ventry(ir::OP_SIMD + ir::SIMD_REDUCE_ADD as u32, u, u, cl);
        vp.cadd = pick(vp.pl.chunks > 1, self.ventry(ir::OP_SIMD + ir::SIMD_WRAP_ADD as u32, u, u, cl), -1);
        vp.ones = ~0u64 >> 64 - lane_bytes(u) * 8;
        return vp.pl.form != sp::PF_SCALAR && vp.cred >= 0 && (vp.pl.chunks == 1 || vp.cadd >= 0);
    }

    // How comparison result `l` gives `count` its lane count: its bits for the population count
    // (CK_BITS); the entries' lane masks summed (CK_FOLD, `count_plan`) on aarch64, whose Neon has no
    // lane-bits instruction, or over several chunks (one chunk's bits, as wasm's `bitmask`, are
    // shorter); without a plan, the lane loop's sum (CK_SUM). Not CK_BITS only when `count` alone
    // reads it (`mask_count`).
    fn count_kind(self: &mut Self, b: &ir::CoreBody, l: u32) u8 {
        if self.mask_count(b, l) == ir::IR_NONE {
            return CK_BITS;
        }
        let mut vp = vplan_none();
        let fold = self.count_plan(b, l, &mut vp);
        if !self.simd_on || vp.pl.form == sp::PF_SCALAR {
            return CK_SUM;
        }
        return pick(fold && (self.p().arch == 1 || vp.pl.chunks > 1), CK_FOLD, CK_BITS);
    }

    // Whether call `t` is the `sc_popcount64` of a comparison's `count` that the comparison already
    // counted (`mask_count`, `count_plan`): the call then only converts its argument.
    fn counted_call(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if !self.popcount_call(t) {
            return false;
        }
        let x = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
        if x.kind == ir::OP_CONST || b.places.at(x.data as usize).proj_len != 0 {
            return false;
        }
        let a = b.places.at(x.data as usize).base;
        let _ = self.lane_only(b, a);
        let mut y = a;
        // Back through the copies and the cast to the comparison: ten steps at most, as `mask_count`.
        for _ in 0..10 {
            let d = self.ml_def[y as usize];
            if d >= ir::IR_NONE - 1 {
                return false;
            }
            let rv = *b.rvalues.at(b.statements.at(d as usize).rvalue as usize);
            if rv.kind == ir::RV_SIMD {
                return self.mask_count(b, y) == a && self.count_kind(b, y) != CK_BITS;
            }
            let o = *b.operands.at(rv.a as usize);
            if rv.kind != ir::RV_USE && rv.kind != ir::RV_CAST || o.kind == ir::OP_CONST || b.places.at(o.data as usize).proj_len != 0 {
                return false;
            }
            y = b.places.at(o.data as usize).base;
        }
        return false;
    }

    // Whether `t` calls core's `sc_popcount64` with one argument.
    fn popcount_call(self: &Self, t: &ir::Terminator) bool {
        if t.kind != ir::TM_CALL || t.args_len != 1 || t.callee.node == NODE_NONE || t.callee.module != self.p().core_module {
            return false;
        }
        let a = self.p().module_ast_const(t.callee.module);
        let f = unsafe (*a).at_const(t.callee.node);
        if f.kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let sp = unsafe (*a).at_const(f.as_data.function.name).as_data.name.text;
        return self.p().modules.at(t.callee.module as usize).source.as_str().slice(sp.start as usize, sp.end as usize) == "sc_popcount64";
    }

    // The value of operand `opid`: an integer constant, or a single-use temporary (`sx_inline`) of
    // an unsigned type computing one with `~`, `+`, `-`, `<<`, `>>` or a cast, in its type's width.
    fn const_u64(self: &Self, b: &ir::CoreBody, opid: ir::OperandId, out: &mut u64, depth: u32) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            *out = c.val as u64;
            return c.kind == ir::CK_INT;
        }
        if depth > 8 || op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len != 0 || *self.sx_inline.at(pl.base as usize) == ir::IR_NONE {
            return false;
        }
        let y = self.rty_y(b, b.locals.at(pl.base as usize).ty);
        let bt = y.as_data.builtin;
        if y.kind != TypeKind::TYPE_BUILTIN || !bt_is_unsigned(bt) {
            return false;
        }
        let w = bt_int_width(bt, lay::target_for(self.p().arch).ptr == 4) as u64;
        let rv = *b.rvalues.at((*self.sx_inline.at(pl.base as usize)) as usize);
        let mut a: u64 = 0;
        let mut c: u64 = 0;
        if !self.const_u64(b, rv.a, &mut a, depth + 1) {
            return false;
        }
        let t = rv.c as tt::TokenType;
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST {
            *out = a;
        } else if rv.kind == ir::RV_UNARY && rv.b == tt::TokenType::Tilde as u32 {
            *out = ~a;
        } else if rv.kind != ir::RV_BINARY || !self.const_u64(b, rv.b, &mut c, depth + 1) {
            return false;
        } else if t == tt::TokenType::Plus || t == tt::TokenType::Minus {
            *out = pick(t == tt::TokenType::Plus, a.wrapping_add(c), a.wrapping_sub(c));
        } else if (t == tt::TokenType::LeftShift || t == tt::TokenType::RightShift) && c < w {
            *out = pick(t == tt::TokenType::LeftShift, a.wrapping_shl(c as u32), (a & ~0u64 >> 64 - w) >> c);
        } else {
            return false;
        }
        *out = *out & ~0u64 >> 64 - w;
        return true;
    }

    // One lane loop of `emit_vec_lanes` over template `t`, its result lanes in `d`. `pre` computes
    // the lanes of merged operands first (`vec_fusion`); operand `j` with `fz[j]` reads the lane
    // `sp[j]` names, another vector operand its storage lane.
    fn vec_loop(
        self: &Self,
        o: &mut String,
        t: str,
        d: str,
        sp: &[String; 3],
        lanes: &[bool; 3],
        n: i64,
        bt: BuiltinType,
        rbt: BuiltinType,
        c: u8,
        mask: bool,
        pre: str,
        fz: &[bool; 3],
    ) {
        // A loop of 8 lanes or more that updates an operand in place (an accumulator) with more than an
        // operator on its lanes unrolls by eight at most (`__SC_LANES`): the accumulators stay in
        // memory, not in a register per lane (a JIT such as wasmtime's spills them). Another unrolls
        // whole, so one that packs or reads mask bits has constant shifts.
        let bits = mask || c == ir::SIMD_CHOOSE && !fz[0];
        let acc = lanes[0] && !fz[0] && sp[0].as_str() == d || lanes[1] && !fz[1] && sp[1].as_str() == d;
        let work = fz[0] || fz[1] || fz[2] || t.len() > 40;
        o.format_into(
            "  {}for (uint32_t __sc_i = 0; __sc_i < {}; __sc_i++) {{ {}",
            pick(n >= 8 && !bits && acc && work, "__SC_LANES ", ""),
            n,
            pre,
        );
        // Each vector operand's lane in a local: one read, and no self-comparison when two operands
        // are one variable.
        let mut a: [String; 3] = [String::new(), String::new(), String::new()];
        for j in 0..3usize {
            if unsafe lanes[j] && unsafe fz[j] {
                unsafe a[j].push_string(unsafe &sp[j]); // a merged operand's lane, already in a local
            } else if unsafe lanes[j] {
                let ty = lane_c(pick(j == 1 && c == ir::SIMD_CAST_CHANGED, rbt, bt));
                o.format_into("{} __sc_{} = {}.l[__sc_i]; ", ty, unsafe ["a", "b", "c"][j], unsafe sp[j].as_str());
                unsafe a[j].format_into("__sc_{}", unsafe ["a", "b", "c"][j]);
            } else {
                unsafe a[j].push_string(unsafe &sp[j]);
            }
        }
        let dx = format("{}{}", d, pick(mask, "", ".l[__sc_i]"));
        // A `choose` of a merged comparison reads the lane's truth, not its bit.
        let ct = pick(c == ir::SIMD_CHOOSE && fz[0], "$d = $a ? $b : $c;", t);
        self.tpl_expand(o, ct, dx.as_str(), &a, bt, rbt);
        o.push_str(" }\n");
    }

    // Template `t` of a lane operation over lanes of `bt` (result lanes `rbt`) with `$d` spelled `dx`
    // and operands `$a`, `$b`, `$c` spelled `a`.
    fn tpl_expand(self: &Self, o: &mut String, t: str, dx: str, a: &[String; 3], bt: BuiltinType, rbt: BuiltinType) {
        let w = self.int_bits(bt);
        // The integer side of a conversion between a float and an integer: its exact float range.
        let ib = pick(bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64, rbt, bt);
        let iw = self.int_bits(ib) - pick(int_signed(ib), 1i64, 0i64);
        let mut i: usize = 0;
        while i < t.len() {
            let ch = t.byte_at(i);
            i += 1;
            if ch != b'$' {
                o.push_byte(ch);
                continue;
            }
            let k = t.byte_at(i);
            i += 1;
            if k >= b'a' && k <= b'c' {
                o.push_string(unsafe &a[(k - b'a') as usize]);
            } else if k == b'd' {
                o.push_str(dx);
            } else if k == b'T' || k == b'R' {
                o.push_str(lane_c(pick(k == b'T', bt, rbt)));
            } else if k == b'U' || k == b'P' {
                o.push_str(
                    if w == 8 && k == b'U' {
                        "uint8_t";
                    } else if w == 16 && k == b'U' {
                        "uint16_t";
                    } else if w <= 32 {
                        "uint32_t";
                    } else {
                        "uint64_t";
                    },
                );
            } else if k == b'W' {
                o.push_u64(w as u64);
            } else if k == b'X' || k == b'Y' {
                o.push_str(lane_limit(bt, k == b'Y'));
            } else if k == b'x' || k == b'y' {
                o.push_str(lane_limit(rbt, k == b'y'));
            } else if k == b'L' {
                o.push_str(mbe::if_s(int_signed(ib), "-0x1p", "0"));
                if int_signed(ib) {
                    o.push_u64(iw as u64);
                }
            } else if k == b'H' {
                o.format_into("0x1p{}", iw);
            } else if k == b'N' {
                o.push_str(bt_name(rbt));
            } else if k == b'F' {
                o.push_str(mbe::if_s(bt == BuiltinType::BT_F32, "f", ""));
            }
        }
    }

    // `[T; N]` to `Simd<T, N>` or back (`CAST_SIMD_ARRAY`): the vector's compound literal for an
    // array literal or repeat (`vec_literals`), else a lane loop, as C assigns no array.
    fn emit_vec_cast_store(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let to_vec = self.rty_y(b, rv.target).kind == TypeKind::TYPE_SIMD;
        let x = *b.operands.at(rv.a as usize);
        if to_vec && x.kind != ir::OP_CONST && *self.sx_inline.at(b.places.at(x.data as usize).base as usize) != ir::IR_NONE {
            let lv = *b.rvalues.at((*self.sx_inline.at(b.places.at(x.data as usize).base as usize)) as usize);
            let mut n: i64 = 0;
            let mut bt = BuiltinType::BT_VOID;
            let _ = self.vec_ty(b, rv.target, &mut n, &mut bt);
            o.push_str("  ");
            let mut ok = self.emit_place(b, s.place, o);
            o.push_str(" = (");
            ok = ok && self.ty_c(b.module, rv.target, "", o);
            o.push_str("){ .l = { ");
            let mut e = self.sget();
            for i in 0..n as u32 {
                if i != 0 {
                    o.push_str(", ");
                }
                if lv.kind == ir::RV_REPEAT && i == 0 {
                    ok = ok && self.emit_operand(b, lv.a, &mut e);
                } else if lv.kind != ir::RV_REPEAT {
                    e.clear();
                    ok = ok && self.emit_operand(b, b.oper_pool[(lv.a + i) as usize], &mut e);
                }
                o.push_string(&e);
            }
            self.sput(e);
            o.push_str(" } };\n");
            return ok;
        }
        let mut n: i64 = 0;
        let mut bt = BuiltinType::BT_VOID;
        let _ = self.vec_ty(b, pick(to_vec, rv.target, x.ty), &mut n, &mut bt);
        let mut a = self.sget();
        let mut ok = if x.kind == ir::OP_COPY || x.kind == ir::OP_MOVE {
            self.emit_place(b, x.data, &mut a);
        } else {
            self.emit_operand(b, rv.a, &mut a);
        };
        o.format_into("  for (uint32_t __sc_i = 0; __sc_i < {}; __sc_i++) ", n);
        ok = ok && self.emit_place(b, s.place, o);
        o.format_into(
            "{} = {}{};\n",
            pick(to_vec, ".l[__sc_i]", "[__sc_i]"),
            a.as_str(),
            pick(to_vec, "[__sc_i]", ".l[__sc_i]"),
        );
        self.sput(a);
        return ok;
    }

    // `memcpy(&dst, src, sizeof(T[n]));` for fixed-array place `src`. The source is spelled without
    // `&` and sized by its type, not by `sizeof(src)`: an array parameter is a pointer in C. The
    // type is the source's: a designated literal's temp holds only the spelled elements, and the
    // caller zero-fills the rest of `dst`.
    fn emit_array_copy(self: &mut Self, o: &mut String, b: &ir::CoreBody, dst: &String, src: ir::PlaceId) bool {
        o.push_str("  memcpy(&");
        o.push_string(dst);
        o.push_str(", ");
        let mut ok = self.emit_place(b, src, o);
        o.push_str(", sizeof(");
        if self.arr_n(b, b.places.at(src as usize).ty) > 0 {
            ok = ok && self.ty_c(b.module, b.places.at(src as usize).ty, "", o);
        } else {
            o.push_string(dst);
        }
        o.push_str("));\n");
        return ok;
    }

    // `[v; N]` with a small constant count unrolls to element stores (the count operand id rides
    // rv.b); larger repeats stay unfrozen.
    fn emit_repeat_stores(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let cnt = *b.operands.at(rv.b as usize);
        let mut cv: i64 = 0 - 1;
        if cnt.kind == ir::OP_CONST {
            let c0 = *b.constants.at(cnt.data as usize);
            if c0.kind == ir::CK_INT && c0.val >= 0 {
                cv = c0.val;
            }
        }
        if cv < 0 {
            // A symbolic count (a named const or const-generic): the DESTINATION's array length
            // IS the count by typing.
            let nR = self.arr_n(b, b.places.at(s.place as usize).ty);
            if nR > 0 {
                cv = nR;
            }
        }
        if cv < 0 {
            return self.fail("repeat-count");
        }
        let mut base = self.sget();
        let mut el = self.sget();
        let mut ok = self.emit_place(b, s.place, &mut base);
        // C cannot assign an array: an array element (`[[v; M]; N]`) is copied into each slot.
        let eop = *b.operands.at(rv.a as usize);
        if (eop.kind == ir::OP_COPY || eop.kind == ir::OP_MOVE) && self.arr_n(b, b.places.at(eop.data as usize).ty) > 0 {
            let lim = if cv <= 16 {
                cv;
            } else {
                1;
            };
            if cv > 16 {
                o.push_str("  for (size_t __ri = 0; __ri < ");
                o.push_i64(cv);
                o.push_str("; __ri++) {\n");
            }
            for i in 0..lim {
                el.clear();
                el.push_string(&base);
                el.push_str("[");
                if cv <= 16 {
                    el.push_u64(i as u64);
                } else {
                    el.push_str("__ri");
                }
                el.push_str("]");
                ok = ok && self.emit_array_copy(o, b, &el, eop.data);
            }
            if cv > 16 {
                o.push_str("  }\n");
            }
            self.sput(base);
            self.sput(el);
            return ok;
        }
        ok = ok && self.emit_operand(b, rv.a, &mut el);
        if ok && cv <= 16 {
            for i in 0..cv {
                o.push_str("  ");
                o.push_string(&base);
                o.push_str("[");
                o.push_u64(i as u64);
                o.push_str("] = ");
                o.push_string(&el);
                o.push_str(";\n");
            }
        } else if ok {
            o.push_str("  for (size_t __ri = 0; __ri < ");
            o.push_i64(cv);
            o.push_str("; __ri++) { ");
            o.push_string(&base);
            o.push_str("[__ri] = ");
            o.push_string(&el);
            o.push_str("; }\n");
        }
        self.sput(base);
        self.sput(el);
        return ok;
    }

    // Step `(rm, rt)` through up to 4 pointer/reference levels while the pointee resolves; returns the
    // levels peeled.
    fn peel_refs(self: &Self, rm: &mut ModuleId, rt: &mut TypeId) u32 {
        let mut levels: u32 = 0;
        while levels < 4 {
            let y = *unsafe (*self.p().module_ast_const(*rm)).type_at(*rt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            let mut nm = *rm;
            let mut nt = y.as_data.elem;
            if !self.mg.resolve(*rm, y.as_data.elem, &mut nm, &mut nt) {
                break;
            }
            *rm = nm;
            *rt = nt;
            levels += 1;
        }
        return levels;
    }

    // Peel pointer/reference indirection of the resolved type `(rm, rt)` ahead of a member access,
    // leaving it at the aggregate. Returns true when at least one level was peeled, so the caller
    // spells the final access with `->` (which folds in that last dereference); the outer levels
    // wrap as `(*..)`. False -> a direct value member spelled with `.`.
    fn place_field_arrow(self: &Self, rm: &mut ModuleId, rt: &mut TypeId, dst: &mut String, mk: usize) bool {
        let mut levels = 0;
        while levels < 4 {
            let y = *unsafe (*self.p().module_ast_const(*rm)).type_at(*rt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            let mut nm = *rm;
            let mut nt = y.as_data.elem;
            if self.mg.resolve(*rm, y.as_data.elem, &mut nm, &mut nt) {
                *rm = nm;
                *rt = nt;
            } else {
                *rt = y.as_data.elem;
            }
            levels += 1;
        }
        if levels == 0 {
            return false;
        }
        for _k in 0..levels - 1 {
            dst.insert_str(mk, "(*");
            dst.push_str(")");
        }
        return true;
    }

    // True when local `l` spells as its own declared C local (not a forwarded call, a static, or
    // a captured-environment member).
    const fn plain_local(self: &Self, b: &ir::CoreBody, l: u32) bool {
        return !*self.sx_call_fwd.at(l as usize) && b.locals.at(l as usize).storage != ir::LS_STATIC_REF && !(self.cap_on && l >= self.cap_base && l as usize < self.cap_base as usize + self.cap_off.len());
    }

    fn emit_place(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, dst: &mut String) bool {
        return self.emit_place_lim(b, pid, b.places.at(pid as usize).proj_len, dst);
    }

    // Local `l`'s forwarded call text (see sx_call_fwd).
    fn call_str_spell(self: &Self, l: u32, dst: &mut String) {
        let off = self.sx_cs_off[l as usize] as usize;
        let ln = self.sx_cs_len[l as usize] as usize;
        dst.push_str(self.sx_cs_pool.as_str().slice(off, off + ln));
    }

    // The base spelling of local `base` straight into `dst`: forwarded-call parens, static/const
    // symbols (with the demand-time stub record), captured-env members, or the local's C name.
    fn emit_place_base(self: &mut Self, b: &ir::CoreBody, base: u32, dst: &mut String) bool {
        let d0 = dst.len();
        if *self.sx_call_fwd.at(base as usize) {
            dst.push_str("(");
            self.call_str_spell(base, dst);
            dst.push_str(")");
        } else if b.locals.at(base as usize).storage == ir::LS_STATIC_REF {
            let item = b.locals.at(base as usize).item;
            // Its `extern` declaration names an incomplete type; a value use needs the definition.
            self.mg.need_ty(b.module, b.locals.at(base as usize).ty);
            // A CONST-GENERIC parameter bound by the active instantiation is a literal, not a symbol.
            let mut cv8: i64 = 0;
            let mut bt8 = BuiltinType::BT_COUNT;
            let folded = self.mg.fold_param(item.module, item.node, &mut cv8, &mut bt8);
            if folded {
                // i64::MIN has no C literal, and a u64 argument above i64::MAX is stored negative.
                if bt_is_unsigned(bt8) && cv8 < 0 {
                    dst.push_u64(cv8 as u64);
                    dst.push_str("ULL");
                } else if cv8 as u64 == 0x8000000000000000u64 {
                    dst.push_str("(-9223372036854775807LL - 1)");
                } else {
                    dst.push_i64(cv8);
                }
            }
            if !folded && (item.node == NODE_NONE || !self.mg.const_sym(item.module, item.node, dst)) {
                return self.fail("static-sym");
            }
            if self.collect_demand && !folded {
                let h = dst.as_str().slice(d0, dst.len()).hash();
                if self.mg.is_zst(b.module, b.locals.at(base as usize).ty) {
                    // Zero-sized const/static: no stub and no definition entry queue (value reads
                    // are erased; an address binds to the sentinel before this spelling is reached).
                } else {
                    let fresh = !self.stat_seen.contains(&h);
                    if self.mg.rec_on && self.mg.rec_dup_once(h ^ 8) {
                        let mut ev = mbe::RecEv::blank(mbe::RK_STAT);
                        ev.h = h;
                        ev.a = b.module;
                        ev.b = item.module;
                        ev.c = item.node;
                        ev.d = b.locals.at(base as usize).ty;
                        ev.s1.push_str(dst.as_str().slice(d0, dst.len()));
                        self.mg.rec.push(ev);
                    }
                    if fresh {
                        self.stat_seen.insert(h);
                        let idn = unsafe (*self.p().module_ast_const(item.module)).at_const(item.node);
                        let hdr_owned = idn.kind == NodeKind::NODE_CONST && idn.as_data.const_def.is_extern;
                        if !hdr_owned {
                            // Extern-block statics skip the stub: the backing header declares them
                            // (with qualifiers a re-declaration here could contradict).
                            let mut symb = self.sget();
                            symb.push_str(dst.as_str().slice(d0, dst.len()));
                            let mut sd = String::from_str("extern ");
                            if self.ty_c(b.module, b.locals.at(base as usize).ty, symb.as_str(), &mut sd) {
                                sd.push_str(";\n");
                                self.stat_decls.push_string(&sd);
                                self.stat_end.push(self.stat_decls.len() as u32);
                                self.stat_items.push(
                                    StatRef {
                                        em: b.module,
                                        def: item,
                                        sym: symb.clone(),
                                        ty: b.locals.at(base as usize).ty,
                                        args: Vector::<mbe::MSub>::new(),
                                    },
                                );
                            }
                            self.sput(symb);
                        }
                        if self.sh_on {
                            self.sh_stat_k.push(h);
                            self.sh_stat_v.push(self.stat_items.len() as u32);
                        }
                    }
                }
            }
        } else if self.cap_on && base >= self.cap_base && base as usize < self.cap_base as usize + self.cap_off.len() {
            let k = base - self.cap_base;
            let cs = (*self.cap_off.at(k as usize)) as usize;
            let mutated = (self.cap_mut >> k as u64 & 1u64) != 0;
            dst.push_str(mbe::if_s(mutated, "(*__env->", "__env->"));
            dst.push_str(self.cap_pool.as_str().slice(cs, cs + (*self.cap_len.at(k as usize)) as usize));
            dst.push_str(mbe::if_s(mutated, ")", ""));
        } else {
            self.lspell(base, dst);
        }
        return true;
    }

    // Emit a place applying only its first `lim` projections. `&*p` collapses to `p` by emitting the
    // dereferenced place with its trailing deref dropped (lim = proj_len - 1), which the address-of
    // rvalue then spells without the `&`.
    fn emit_place_lim(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, lim: u32, dst: &mut String) bool {
        let pl = *b.places.at(pid as usize);
        if lim == 0 {
            // No projections, no wraps: the base spells straight into the destination.
            return self.emit_place_base(b, pl.base, dst);
        }
        // Wraps (`(*..)`, `(&..)`) insert their opener at `mk`: the place text so far is the tail
        // of the destination, short enough to shift.
        let mk = dst.len();
        if !self.emit_place_base(b, pl.base, dst) {
            return false;
        }
        let mut pre = b.locals.at(pl.base as usize).ty;
        let mut ok = true;
        let mut pend_arrow = false; // a deferred deref whose member access folds it into `->`
        for i in 0..lim {
            if !ok {
                break;
            }
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF {
                // `(*p).f` reads worse than `p->f`: when this deref feeds directly into a member
                // access, defer it so the field/downcast spells the arrow instead of wrapping `(*..)`.
                let nxt = if i + 1 < lim {
                    b.projections.at((pl.proj_start + i + 1) as usize).kind;
                } else {
                    0 as u8;
                };
                if nxt == ir::PJ_FIELD || nxt == ir::PJ_DOWNCAST {
                    pend_arrow = true;
                } else {
                    self.mg.need_ty(b.module, pj.ty);
                    dst.insert_str(mk, "(*");
                    dst.push_str(")");
                    if self.mg.ptr_wraps(b.module, pj.ty) {
                        // The pointer names the array's wrapper struct (`Mangler::ptr_wraps`).
                        dst.push_str(".e");
                    }
                }
            } else if pj.kind == ir::PJ_FIELD || pj.kind == ir::PJ_DOWNCAST {
                let mut arrow = pend_arrow;
                pend_arrow = false;
                let mut fm = b.module;
                let mut ft = pre;
                self.rty(b, pre, &mut fm, &mut ft);
                if !arrow {
                    arrow = self.place_field_arrow(&mut fm, &mut ft, dst, mk);
                }
                // A member access needs the complete aggregate: a declared local's declaration
                // and an enclosing member's definition already give it, everything else records it.
                if arrow || i == 0 && !self.plain_local(b, pl.base) {
                    self.mg.need_ty(fm, ft);
                }
                dst.push_str(mbe::if_s(arrow, "->", "."));
                if pj.kind == ir::PJ_DOWNCAST {
                    dst.push_str("payload.");
                }
                if pj.sub == NODE_NONE {
                    // Positional payload/tuple member: the emitted C names it `_<index>`.
                    dst.push_str("_");
                    dst.push_u64(pj.data);
                } else {
                    let am = self.agg_module_res(fm, ft);
                    let fa = self.p().module_ast_const(am);
                    let sn = unsafe (*fa).at_const(pj.sub);
                    let nm = if pj.kind == ir::PJ_DOWNCAST {
                        sn.as_data.variant.name;
                    } else {
                        sn.as_data.field.name;
                    };
                    self.mg.ident(am, unsafe (*fa).at_const(nm).as_data.name.text, dst);
                }
            } else if pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP {
                // Container instances index through their storage member: Array wraps a C array
                // in `data`, Vector/Slice/SliceMut hold a `ptr`; indexing auto-derefs references.
                let mut rm2 = b.module;
                let mut rt2 = pre;
                self.rty(b, pre, &mut rm2, &mut rt2);
                let mut g2 = 0;
                while g2 < 4 {
                    let py2 = *unsafe (*self.p().module_ast_const(rm2)).type_at(rt2);
                    if py2.kind == TypeKind::TYPE_POINTER {
                        // Raw pointers ARE element storage: C subscripts them directly.
                        break;
                    }
                    if py2.kind != TypeKind::TYPE_REFERENCE {
                        break;
                    }
                    let el2 = py2.as_data.elem;
                    let mut nm2 = rm2;
                    let mut nt2 = el2;
                    if !self.mg.resolve(rm2, el2, &mut nm2, &mut nt2) {
                        break;
                    }
                    let ek2 = unsafe (*self.p().module_ast_const(nm2)).type_at(nt2).kind;
                    let mut hop = ek2 == TypeKind::TYPE_ARRAY || ek2 == TypeKind::TYPE_SIMD;
                    if ek2 == TypeKind::TYPE_INSTANCE {
                        let a3 = self.p().module_ast_const(nm2);
                        let it3 = *unsafe (*a3).instance(unsafe (*a3).type_at(nt2).as_data.inst);
                        let nm3s = self.agg_name(it3.module, it3.decl);
                        hop = nm3s == "Array" || nm3s == "Vector" || nm3s == "Slice" || nm3s == "SliceMut";
                    }
                    if !hop {
                        // Raw pointer arithmetic subscripts the pointer itself.
                        break;
                    }
                    dst.insert_str(mk, "(*");
                    dst.push_str(")");
                    rm2 = nm2;
                    rt2 = nt2;
                    g2 += 1;
                }
                // Subscripting scales by the complete element type.
                self.mg.need_ty(b.module, pj.ty);
                if self.mg.is_zst(rm2, rt2) && !self.mg.is_zst(b.module, pj.ty) {
                    // A zero-length array has no storage: the subscript (never executed, the bounds
                    // check fails first) addresses its element type at the sentinel.
                    dst.truncate(mk);
                    dst.push_str("((");
                    ok = self.ty_c(b.module, pj.ty, "*", dst);
                    dst.push_str(")");
                    ok = ok && self.zst_sentinel_ref(rm2, rt2, dst);
                    dst.push_str(")[");
                    if pj.kind == ir::PJ_INDEX_CONST {
                        dst.push_u64(pj.data);
                    } else {
                        ok = ok && self.emit_operand(b, pj.data, dst);
                    }
                    dst.push_str("]");
                    pre = pj.ty;
                    continue;
                }
                // Checks are explicit Core IR operations (IN_BOUNDS); the emitter only addresses.
                let a2 = self.p().module_ast_const(rm2);
                // Pointer storage (a raw pointer, `.ptr`) of arrays names their wrapper struct.
                let mut wrapped = unsafe (*a2).type_at(rt2).kind == TypeKind::TYPE_POINTER;
                if unsafe (*a2).type_at(rt2).kind == TypeKind::TYPE_INSTANCE {
                    let it2 = *unsafe (*a2).instance(unsafe (*a2).type_at(rt2).as_data.inst);
                    let arr_st = self.agg_name(it2.module, it2.decl) == "Array";
                    dst.push_str(mbe::if_s(arr_st, ".data", ".ptr"));
                    wrapped = !arr_st;
                } else if self.is_str_ty(rm2, rt2) {
                    dst.push_str(".ptr");
                } else if unsafe (*a2).type_at(rt2).kind == TypeKind::TYPE_SIMD {
                    // `((T *)&v)[i]`: a lane of a register-sized vector has no address of its own.
                    let mut pre = String::from_str("((");
                    ok = self.ty_c(b.module, pj.ty, "*", &mut pre);
                    pre.push_str(")&");
                    dst.insert_str(mk, pre.as_str());
                    dst.push_str(")");
                }
                dst.push_str("[");
                if pj.kind == ir::PJ_INDEX_CONST {
                    dst.push_u64(pj.data);
                } else {
                    ok = self.emit_operand(b, pj.data, dst);
                }
                dst.push_str("]");
                if wrapped && self.mg.ptr_wraps(b.module, pj.ty) {
                    dst.push_str(".e");
                }
            } else {
                ok = self.fail("projection");
            }
            pre = pj.ty;
        }
        return ok;
    }

    fn emit_operand(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        if self.sx_nest == RENDER_NEST_MAX {
            return self.fail("nesting");
        }
        self.sx_nest += 1;
        let ok = self.emit_operand_i(b, opid, dst);
        self.sx_nest -= 1;
        return ok;
    }

    fn emit_operand_i(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            let pl = *b.places.at(op.data as usize);
            if pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE {
                return self.emit_rvalue(b, *self.sx_inline.at(pl.base as usize), dst);
            }
            if pl.proj_len == 0 && *self.sx_call_fwd.at(pl.base as usize) {
                self.call_str_spell(pl.base, dst);
                return true;
            }
            return self.emit_place(b, op.data, dst);
        }
        if op.kind != ir::OP_CONST {
            return self.fail("operand");
        }
        return self.emit_const(b, op.data, dst);
    }

    // Resolve a binary operand's VALUE type, peeling one reference (operator position auto-derefs;
    // the C operand is then a pointer). True = a reference was peeled.
    fn bin_op_ty(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        let op = *b.operands.at(opid as usize);
        *rm = b.module;
        *rt = op.ty;
        self.rty(b, op.ty, rm, rt);
        let y = *unsafe (*self.p().module_ast_const(*rm)).type_at(*rt);
        if y.kind == TypeKind::TYPE_REFERENCE {
            let em = *rm;
            let mut nm = em;
            let mut nt = y.as_data.elem;
            if self.mg.resolve(em, y.as_data.elem, &mut nm, &mut nt) {
                *rm = nm;
                *rt = nt;
                return true;
            }
        }
        return false;
    }

    fn emit_op_d(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, deref: bool, dst: &mut String) bool {
        if deref {
            dst.push_str("(*");
            let ok = self.emit_operand(b, opid, dst);
            dst.push_str(")");
            return ok;
        }
        return self.emit_operand(b, opid, dst);
    }

    // The function that computes scalar binary `rv` where the C operator lacks the language's meaning,
    // or "". A float `%` is `fmod`/`fmodf` (the sign of the dividend, as the language defines it). An
    // integer operation returns its super_rt.h helper `__sc_<op>_<bt>` and sets `bt`: `+ - *` (overflow
    // traps or wraps by build), signed `<<` (C leaves shifting into the sign undefined), narrow
    // unsigned `<<` (C computes it in int, the helper truncates), and `/ % >>` and wide unsigned `<<`
    // unless a constant right operand rules their trap out (a nonzero divisor other than a signed -1, a
    // count below the width).
    fn arith_fn(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, bt: &mut BuiltinType) str<'static> {
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let _ = self.bin_op_ty(b, rv.a, &mut rm, &mut rt);
        let t = rv.c as tt::TokenType;
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return "";
        }
        *bt = y.as_data.builtin;
        if t != tt::TokenType::LeftShift && t != tt::TokenType::RightShift && t != tt::TokenType::LeftShiftEqual && t != tt::TokenType::RightShiftEqual {
            // An operand the checker widened (`i32 * i64`) computes at the result's width: a shift
            // keeps its left operand's type, every other scalar operator has the result's.
            let ty = self.rty_y(b, rv.target);
            if ty.kind == TypeKind::TYPE_BUILTIN {
                *bt = ty.as_data.builtin;
            }
        }
        let op = switch t {
            Plus | PlusEqual => "add",
            Minus | MinusEqual => "sub",
            Star | StarEqual => "mul",
            Slash | SlashEqual => "div",
            Percent | PercentEqual => "rem",
            LeftShift | LeftShiftEqual => "shl",
            RightShift | RightShiftEqual => "shr",
            _ => "",
        };
        if op == "rem" && (*bt == BuiltinType::BT_F32 || *bt == BuiltinType::BT_F64) {
            return mbe::if_s(*bt == BuiltinType::BT_F32, "fmodf", "fmod");
        }
        let signed = int_signed(*bt);
        let narrow = *bt == BuiltinType::BT_U8 || *bt == BuiltinType::BT_U16;
        if op.len() == 0 || !signed && !bt_is_unsigned(*bt) {
            return "";
        }
        if op == "add" || op == "sub" || op == "mul" || op == "shl" && (signed || narrow) {
            return op;
        }
        let ro = *b.operands.at(rv.b as usize);
        if ro.kind == ir::OP_CONST {
            // The exact value (`val` holds only a plain decimal spelling): a hex `0x40` shift count
            // must reach the checked helper.
            let c = *b.constants.at(ro.data as usize);
            let mut v: i64 = 0;
            if c.kind == ir::CK_INT && c.int_value(self.const_src(b, &c), &mut v) {
                if op == "div" || op == "rem" {
                    if v != 0 && !(signed && v == -1) {
                        return "";
                    }
                } else if v >= 0 && v < self.int_bits(*bt) {
                    return "";
                }
            }
        }
        return op;
    }

    // The width in bits of integer builtin `bt` on the target.
    const fn int_bits(self: &Self, bt: BuiltinType) i64 {
        return switch bt {
            BT_I8 | BT_U8 => 8,
            BT_I16 | BT_U16 => 16,
            BT_I32 | BT_U32 => 32,
            BT_ISIZE | BT_USIZE => lay::target_for(self.p().arch).ptr as i64 * 8,
            _ => 64,
        };
    }

    // Set `s` to every value of integer builtin `bt` and its C type after integer promotion (a type
    // narrower than `int` promotes to `int`); false when `bt` is no integer. `char` is unsigned.
    const fn cmp_side_ty(self: &Self, bt: BuiltinType, s: &mut CmpSide) bool {
        let uns = bt_is_unsigned(bt) || bt == BuiltinType::BT_CHAR;
        if !uns && !int_signed(bt) {
            return false;
        }
        let w = if bt == BuiltinType::BT_CHAR {
            8;
        } else {
            self.int_bits(bt);
        };
        s.uns = uns;
        s.konst = false;
        if uns {
            s.lo = 0;
            s.hi = if w == 64 {
                0 - 1;
            } else {
                (1i64 << w) - 1;
            };
        } else if w == 64 {
            // Spelled without i64::MIN/MAX: the released compiler that bootstraps this source has no
            // builtin limits.
            s.hi = 0x7FFFFFFFFFFFFFFF;
            s.lo = 0 - s.hi - 1;
        } else {
            s.lo = 0 - (1i64 << w - 1);
            s.hi = (1i64 << w - 1) - 1;
        }
        s.c_uns = uns && w >= 32;
        s.c_w = if w < 32 {
            32u32;
        } else {
            w as u32;
        };
        return true;
    }

    // Integer comparison operand `opid` as C reads it (CmpSide); false when it is no integer. A
    // constant spelling (a literal, a bound const-generic parameter, an inlined copy of either) has
    // one value in the C type of its spelling. Any other operand ranges over its type, seen through
    // inlined copies and value-preserving numeric casts, as the C compiler sees through them.
    fn cmp_side(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, s: &mut CmpSide) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            if c.kind != ir::CK_INT || c.ty != TYPE_NONE && self.rty_y(b, c.ty).kind != TypeKind::TYPE_BUILTIN {
                return false;
            }
            // The spelling of emit_int: `(char)` below int, a parenthesized long long MIN, or the
            // suffix of int_suffix.
            let bt = self.int_builtin(b, c.ty);
            let uns = bt_is_unsigned(bt) || bt == BuiltinType::BT_CHAR;
            if bt != BuiltinType::BT_VOID && !uns && !int_signed(bt) {
                return false;
            }
            let mut v: i64 = 0;
            if !c.int_value(self.const_src(b, &c), &mut v) {
                return false;
            }
            let sfx = self.int_suffix(bt);
            s.konst = true;
            s.lo = v;
            s.hi = v;
            s.uns = uns;
            s.c_uns = sfx != "LL";
            s.c_w = if sfx == "U" || bt == BuiltinType::BT_CHAR && v > 127 {
                32u32;
            } else {
                64u32;
            };
            return true;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len == 0 && !*self.sx_call_fwd.at(pl.base as usize) {
            let ri = *self.sx_inline.at(pl.base as usize);
            if ri != ir::IR_NONE {
                let rv = *b.rvalues.at(ri as usize);
                if rv.kind == ir::RV_USE {
                    return self.cmp_side(b, rv.a, s);
                }
                if rv.kind == ir::RV_UNARY && (rv.b as u8) as tt::TokenType == tt::TokenType::Tilde {
                    // `~c` at a type C computes it at (`~0usize` is `~0ULL`); a narrow unsigned `~`
                    // spells a helper call.
                    let ub = self.int_builtin(b, b.operands.at(rv.a as usize).ty);
                    let spelled = int_signed(ub) || bt_is_unsigned(ub) && self.int_bits(ub) >= 32;
                    if spelled && self.cmp_side(b, rv.a, s) && s.konst {
                        s.lo = if s.uns && self.int_bits(ub) == 32 {
                            ~s.lo & 0xFFFFFFFFi64;
                        } else {
                            ~s.lo;
                        };
                        s.hi = s.lo;
                        return true;
                    }
                }
                if rv.kind == ir::RV_LEN {
                    let n = self.arr_n(b, b.places.at(rv.a as usize).ty);
                    if n >= 0 {
                        s.set_dec(n, true);
                        return true;
                    }
                }
                if rv.kind == ir::RV_CAST && rv.b == ir::CAST_NUMERIC {
                    let tb = self.int_builtin(b, rv.target);
                    if !self.cmp_side_ty(tb, s) {
                        return false;
                    }
                    let mut src = *s;
                    if !self.cmp_side(b, rv.a, &mut src) {
                        return true;
                    }
                    if src.konst {
                        // C converts a constant to the target type: its value modulo 2^width, read
                        // in the target's signedness.
                        let w = if tb == BuiltinType::BT_CHAR {
                            8;
                        } else {
                            self.int_bits(tb);
                        };
                        s.set_val(wrap_to(src.lo, w, s.uns));
                    } else if exact_cmp(s.lo, s.uns, src.lo, src.uns) <= 0 && exact_cmp(src.hi, src.uns, s.hi, s.uns) <= 0 {
                        s.lo = src.lo;
                        s.hi = src.hi;
                        s.uns = src.uns;
                    }
                    return true;
                }
                if rv.kind == ir::RV_BINARY {
                    // A C operator over two constants (`~0ULL >> 1`) is a constant too. arith_fn
                    // spells `+`, `-`, `*` and every division or shift C could leave undefined as a
                    // helper call instead.
                    let mut ab = BuiltinType::BT_VOID;
                    let mut l = *s;
                    let mut r = *s;
                    if self.arith_fn(b, &rv, &mut ab).len() == 0 && self.cmp_side(b, rv.a, &mut l) && l.konst && self.cmp_side(
                        b,
                        rv.b,
                        &mut r,
                    ) && r.konst && c_const_op(rv.c as tt::TokenType, &l, &r, s) {
                        return true;
                    }
                }
            } else if b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF {
                let item = b.locals.at(pl.base as usize).item;
                let mut v: i64 = 0;
                let mut vbt = BuiltinType::BT_COUNT;
                if self.mg.fold_param(item.module, item.node, &mut v, &mut vbt) {
                    s.set_dec(v, bt_is_unsigned(vbt));
                    return true;
                }
            }
        }
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let _ = self.bin_op_ty(b, opid, &mut rm, &mut rt);
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        return y.kind == TypeKind::TYPE_BUILTIN && self.cmp_side_ty(y.as_data.builtin, s);
    }

    // The result of integer comparison `rv` when the range of one operand's C type decides it
    // against the other, a constant (`u < 0` is false, `i8 >= -128` is true): 1 or 0, else -1. `x`
    // receives the other operand. Folds only where C compares exact values (no negative value
    // converts to an unsigned common type), so the result is the one C computes.
    fn cmp_fold(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, x: &mut ir::OperandId) i32 {
        let mut t = rv.c as tt::TokenType;
        if t != tt::TokenType::LessThan && t != tt::TokenType::LessThanEqual && t != tt::TokenType::GreaterThan && t != tt::TokenType::GreaterThanEqual && t != tt::TokenType::EqualEqual && t != tt::TokenType::BangEqual {
            return -1;
        }
        let mut xs = CmpSide { lo: 0, hi: 0, uns: false, c_uns: false, c_w: 0, konst: false };
        let mut cs = xs;
        if !self.cmp_side(b, rv.a, &mut xs) || !self.cmp_side(b, rv.b, &mut cs) || xs.konst == cs.konst {
            return -1;
        }
        *x = rv.a;
        if xs.konst {
            // `c op x` is `x op' c` with the operands swapped.
            let tmp = xs;
            xs = cs;
            cs = tmp;
            *x = rv.b;
            t = (switch t {
                LessThan => tt::TokenType::GreaterThan,
                LessThanEqual => tt::TokenType::GreaterThanEqual,
                GreaterThan => tt::TokenType::LessThan,
                GreaterThanEqual => tt::TokenType::LessThanEqual,
                _ => t,
            });
        }
        let common_uns = if xs.c_uns == cs.c_uns {
            xs.c_uns;
        } else if xs.c_uns {
            xs.c_w >= cs.c_w;
        } else {
            cs.c_w >= xs.c_w;
        };
        if common_uns && (!xs.uns && xs.lo < 0 || !cs.uns && cs.lo < 0) {
            return -1;
        }
        let lo = exact_cmp(xs.lo, xs.uns, cs.lo, cs.uns);
        let hi = exact_cmp(xs.hi, xs.uns, cs.lo, cs.uns);
        return switch t {
            LessThan => fold_result(hi < 0, lo >= 0),
            LessThanEqual => fold_result(hi <= 0, lo > 0),
            GreaterThan => fold_result(lo > 0, hi <= 0),
            GreaterThanEqual => fold_result(lo >= 0, hi < 0),
            EqualEqual => fold_result(lo == 0 && hi == 0, lo > 0 || hi < 0),
            _ => fold_result(lo > 0 || hi < 0, lo == 0 && hi == 0),
        };
    }

    // Spell comparison result `r` for operand `x`, still evaluated (it names the reads C would
    // otherwise report unused): `((void)(x), true)`.
    fn emit_cmp_const(self: &mut Self, b: &ir::CoreBody, x: ir::OperandId, r: bool, dst: &mut String) bool {
        dst.push_str("((void)(");
        let ok = self.emit_operand(b, x, dst);
        dst.push_str(mbe::if_s(r, "), true)", "), false)"));
        return ok;
    }

    // The source a constant's span indexes: an inlined constant's (item marks it) foreign module, else
    // the body's module.
    const fn const_src<'a>(self: &Self, b: &ir::CoreBody, c: &ir::Constant) str<'a> {
        let m = if c.item.node != NODE_NONE {
            c.item.module;
        } else {
            b.module;
        };
        return self.p().modules.at(m as usize).source.as_str();
    }

    fn emit_const(self: &mut Self, b: &ir::CoreBody, cid: u32, dst: &mut String) bool {
        let c = *b.constants.at(cid as usize);
        if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
            if c.kind == ir::CK_INT && c.ty != TYPE_NONE {
                let kz = self.rty_y(b, c.ty).kind;
                if kz == TypeKind::TYPE_STRUCT || kz == TypeKind::TYPE_INSTANCE {
                    // An integer constant carrying an aggregate type is the zeroed value.
                    if self.erased(b, c.ty) {
                        // Erased destinations suppress the store.
                        return self.fail("zst-zero");
                    }
                    dst.push_str("(");
                    let okz = self.ty_c(b.module, c.ty, "", dst);
                    dst.push_str("){");
                    dst.push_str("0");
                    dst.push_str("}");
                    return okz;
                }
            }
            return self.emit_int(b, &c, dst);
        }
        if c.kind == ir::CK_FLOAT {
            // An inlined constant spans a FOREIGN module's source (item marks it, the CK_STR convention).
            let srcf = self.const_src(b, &c);
            push_c_float_lit(srcf.slice(c.raw.start as usize, c.raw.end as usize), self.is_f32(b, c.ty), dst);
            return true;
        }
        if c.kind == ir::CK_STR {
            let mut lit = self.sget();
            let ok = self.emit_str_const(b, cid, &mut lit, dst);
            self.sput(lit);
            return ok;
        }
        if c.kind == ir::CK_ITEM {
            if c.targ_len() != 0 && unsafe (*self.p().module_ast_const(c.item.module)).at_const(c.item.node).kind == NodeKind::NODE_CONST {
                return self.assoc_const_ref(b, &c, dst);
            }
            return self.callee_sym(
                b,
                c.item,
                c.targ_start(),
                c.targ_len(),
                TYPE_NONE,
                TYPE_NONE,
                TYPE_NONE,
                TYPE_NONE,
                dst,
            );
        }
        if c.kind == ir::CK_WIDE {
            // the frozen wide-int shape: `((T){ .bits = { .limbs = { 0x..ULL, ... } } })`.
            let a0 = self.p().module_ast_const(b.module);
            let w = *unsafe (*a0).wide_lits.at(c.val as usize);
            // The CONTEXTUAL type wins (`let mx: i128 = <lit>` spells Int__128, not the default),
            // but only when it resolves to a big-int instance (operand-position literals type
            // as the SCALAR the checker later widens).
            let mut ct = w.ty;
            if c.ty != TYPE_NONE {
                if self.rty_y(b, c.ty).kind == TypeKind::TYPE_INSTANCE {
                    ct = c.ty;
                }
            }
            dst.push_str("((");
            if !self.ty_c(b.module, ct, "", dst) {
                return false;
            }
            dst.push_str("){ .bits = { .limbs = { ");
            let mut last: usize = 0;
            for i in 0..16 {
                if unsafe w.limbs[i as usize] != 0 {
                    last = i as usize;
                }
            }
            for i in 0..last + 1 {
                if i != 0 {
                    dst.push_str(", ");
                }
                dst.push_str("0x");
                dst.push_hex(unsafe w.limbs[i], false);
                dst.push_str("ULL");
            }
            dst.push_str(" } } })");
            return true;
        }
        return self.fail("constant");
    }

    // A string constant spelled for its typed context. `lit` (pooled scratch: it spells twice, as
    // the data and inside `sizeof`) holds the C string literal of its bytes, or past STR_LIT_MAX
    // bytes the name of the body-scope static array holding them (long_lit).
    fn emit_str_const(self: &mut Self, b: &ir::CoreBody, cid: u32, lit: &mut String, dst: &mut String) bool {
        let c = *b.constants.at(cid as usize);
        // Reflection `name` constants span a FOREIGN module's source (item marks it).
        let src = self.const_src(b, &c);
        let mut bytes = self.sget();
        let mut tmp = self.sget();
        str_const_bytes(src.slice(c.raw.start as usize, c.raw.end as usize), c.val, &mut tmp, &mut bytes);
        self.sput(tmp);
        let mut ok = true;
        if bytes.len() > STR_LIT_MAX {
            ok = self.long_lit(cid, bytes.as_str(), lit);
        } else {
            lit.push_str("\"");
            push_c_escaped(bytes.as_str(), lit);
            lit.push_str("\"");
        }
        self.sput(bytes);
        if !ok {
            return false;
        }
        if c.ty != TYPE_NONE {
            let mut rmS = b.module;
            let mut rtS = c.ty;
            self.rty(b, c.ty, &mut rmS, &mut rtS);
            if unsafe (*self.p().module_ast_const(rmS)).type_at(rtS).kind == TypeKind::TYPE_POINTER {
                // A C-string context: the bare data, cast to the target pointer type.
                dst.push_str("(");
                if !self.ty_c(b.module, c.ty, "", dst) {
                    return false;
                }
                dst.push_str(")");
                dst.push_string(lit);
                return true;
            }
        }
        let is_slice = c.ty != TYPE_NONE && unsafe (*self.p().module_ast_const(b.module)).type_at(c.ty).kind == TypeKind::TYPE_INSTANCE;
        dst.push_str("(");
        if c.ty == TYPE_NONE {
            // Untyped string tests (switch patterns) are `str` views.
            self.mg.need_name("str".hash(), true);
            dst.push_str("str");
        } else if !self.ty_c(b.module, c.ty, "", dst) {
            return false;
        }
        if is_slice {
            dst.push_str("){ .ptr = (const uint8_t *)");
            dst.push_string(lit);
            dst.push_str(", .len = sizeof(");
            dst.push_string(lit);
            dst.push_str(") - 1 }");
        } else {
            dst.push_str(")");
            push_c_str_view(lit.as_str(), dst);
        }
        return true;
    }

    // Spell `__sc_lit<cid>`, the body-scope static array holding string constant `cid`'s bytes
    // (`bytes`, past STR_LIT_MAX) and a terminating 0, declared once per body; static storage keeps
    // a view of it valid after the body returns. Only a body declares one (lit_on).
    fn long_lit(self: &mut Self, cid: u32, bytes: str, dst: &mut String) bool {
        if !self.lit_on {
            return self.fail("long-string");
        }
        dst.push_str("__sc_lit");
        dst.push_u64(cid);
        for i in 0..self.lit_ids.len() {
            if self.lit_ids[i] == cid {
                return true;
            }
        }
        self.lit_ids.push(cid);
        self.lit_decls.push_str("  static const uint8_t __sc_lit");
        self.lit_decls.push_u64(cid);
        self.lit_decls.push_str("[] = {");
        push_c_byte_list(bytes, &mut self.lit_decls);
        self.lit_decls.push_str("  };\n");
        return true;
    }

    fn emit_int(self: &mut Self, b: &ir::CoreBody, c: &ir::Constant, dst: &mut String) bool {
        // Integer spellings re-render from the span when present (hex etc. stay exact); the decimal
        // fast path covers synthesized constants. A bool renders from `val`: its span is never
        // read, so an inlined bool (whose span indexes the callee's source) cannot pick up digits.
        let sp = c.raw;
        let mut spelled = false;
        if c.kind == ir::CK_INT {
            // An inlined constant spans a FOREIGN module's source (item marks it).
            let s0 = self.const_src(b, c);
            if sp.end > sp.start && sp.end as usize <= s0.len() {
                let txt = s0.slice(sp.start as usize, sp.end as usize);
                let b0 = txt.byte_at(0);
                if b0 >= 48 && b0 <= 57 {
                    push_c_number(txt, dst);
                    spelled = true;
                }
            }
        }
        if spelled {
            if c.kind == ir::CK_INT {
                dst.push_str(self.int_suffix(self.int_builtin(b, c.ty)));
            }
            return true;
        }
        if c.kind == ir::CK_BOOL {
            if c.val != 0 {
                dst.push_str("true");
            } else {
                dst.push_str("false");
            }
            return true;
        }
        let bt = self.int_builtin(b, c.ty);
        // A char literal above 127 ('\xe9', 'é') is a byte value; the cast states the narrowing C
        // otherwise warns about.
        if bt == BuiltinType::BT_CHAR && c.val > 127 {
            dst.push_str("(char)");
        }
        if c.val as u64 == 0x8000000000000000u64 && !bt_is_unsigned(bt) {
            // `-9223372036854775808LL` negates a literal too wide for `long long`: it is unsigned.
            dst.push_str("(-9223372036854775807LL - 1)");
            return true;
        }
        if c.val < 0 && bt_is_unsigned(bt) && self.int_suffix(bt) == "ULL" {
            dst.push_u64(c.val as u64); // a 64-bit value past i64::MAX, not a negated literal
        } else {
            dst.push_i64(c.val);
        }
        dst.push_str(self.int_suffix(bt));
        return true;
    }

    // The suffix of an integer literal of builtin `bt`. An unsigned literal has its type's width,
    // since the literal's type decides the width C computes at and unsigned arithmetic wraps at
    // the type's width: `x - 1` on a `u32` is `x - 1U` (a type narrower than `unsigned` has no
    // literal and takes `unsigned`; `usize` follows the target's pointer width). A signed literal
    // is `long long`, which holds every value, so an intermediate never overflows `int`.
    const fn int_suffix(self: &Self, bt: BuiltinType) str<'static> {
        if bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_USIZE && lay::target_for(
            self.p().arch,
        ).ptr == 4 {
            return "U";
        }
        return mbe::if_s(bt_is_unsigned(bt), "ULL", "LL");
    }

    // An argument past a variadic callee's parameters. C reads it as its promoted C type, so an
    // integer constant is cast to its declared type (an `i32` literal is `long long`, `int64_t` is
    // `long` on LP64 Linux); only a `u32` literal (`unsigned`) already has it.
    fn emit_vararg(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            let bt = self.int_builtin(b, c.ty);
            if c.kind == ir::CK_INT && bt != BuiltinType::BT_VOID && bt != BuiltinType::BT_U32 {
                dst.push_str("(");
                if !self.ty_c(b.module, c.ty, "", dst) {
                    return false;
                }
                dst.push_str(")");
            }
        }
        return self.emit_operand(b, opid, dst);
    }

    // Close unsuffixed float literal operand `opid` (just spelled) as a C `float` when its peer
    // operand `(pm, pt)` is `f32`: a `double` literal computes the operation at double precision,
    // which rounds differently from the `f32` operation. A literal recorded `f32` has its suffix
    // already (push_c_float_lit).
    fn f32_lit_sfx(self: &Self, b: &ir::CoreBody, opid: ir::OperandId, pm: ModuleId, pt: TypeId, dst: &mut String) {
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_CONST || pt == TYPE_NONE {
            return;
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind != ir::CK_FLOAT || self.is_f32(b, c.ty) {
            return; // an f32 literal is spelled with its suffix already
        }
        let py = *unsafe (*self.p().module_ast_const(pm)).type_at(pt);
        if py.kind != TypeKind::TYPE_BUILTIN || py.as_data.builtin != BuiltinType::BT_F32 {
            return;
        }
        let txt = self.const_src(b, &c).slice(c.raw.start as usize, c.raw.end as usize);
        let n = txt.len();
        if n > 3 && (txt.slice(n - 3, n) == "f32" || txt.slice(n - 3, n) == "f64") {
            return;
        }
        if !float_marked(txt) {
            dst.push_str(".0");
        }
        dst.push_str("f");
    }

    fn is_f32(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        return self.int_builtin(b, t) == BuiltinType::BT_F32;
    }

    // The builtin behind integer type `t`; BT_VOID when `t` is absent or not a builtin.
    fn int_builtin(self: &Self, b: &ir::CoreBody, t: TypeId) BuiltinType {
        if t == TYPE_NONE {
            return BuiltinType::BT_VOID;
        }
        let y = self.rty_y(b, t);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return BuiltinType::BT_VOID;
        }
        return y.as_data.builtin;
    }

    // Peel references/pointers off `t` and answer the receiver instance when it instantiates the
    // generic decl `tgt`; TYPE_NONE-style miss = `it.decl == NODE_NONE`.
    fn recv_inst(self: &Self, b: &ir::CoreBody, t: TypeId, tgt: DefId, rpm: &mut ModuleId) TyInstance {
        let mut cm = b.module;
        let mut cur = t;
        let mut guard = 0;
        while cur != TYPE_NONE && guard < 8 {
            let mut rm = cm;
            let mut rt = cur;
            if !self.mg.resolve(cm, cur, &mut rm, &mut rt) {
                break;
            }
            cm = rm;
            cur = rt;
            let a = self.p().module_ast_const(cm);
            let y = *unsafe (*a).type_at(cur);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                cur = y.as_data.elem;
                guard += 1;
                continue;
            }
            let mut it = TyInstance {};
            if unsafe (*a).targs_of(cur, &mut it) && it.module == tgt.module && it.decl == tgt.node {
                *rpm = cm;
                return it;
            }
            break;
        }
        return TyInstance { decl: NODE_NONE };
    }

    // Journal one demand attempt (see mangle::RecEv). `gate`/`dom` name the dedup gate the live
    // site ran (dom 0 = ungated, 1 = demand_seen, 2 = glue_seen); gated dups journal once per
    // module so a vanished first claimant is still replayable.
    fn rec_demand(self: &mut Self, d9: &Demand, gate: u64, dom: u8) {
        if !self.mg.rec_on {
            return;
        }
        if dom != 0 && !self.mg.rec_dup_once(gate ^ 6) {
            return;
        }
        let mut ev = mbe::RecEv::blank(mbe::RK_DEMAND);
        ev.h = gate;
        ev.a = dom;
        ev.b = d9.def.module;
        ev.c = d9.def.node;
        ev.s1 = d9.sym.clone();
        ev.s2 = d9.sfx.clone();
        ev.subs = mbe::subs_copy(&d9.subs);
        self.mg.rec.push(ev);
    }

    /// Journal replay for the emitter-owned event kinds: each runs the SAME dedup gate its live
    /// site runs, so replayed and re-emitted modules compose into the exact clean-build queues.
    /// The caller keeps rec_on off for the whole replay.
    pub fn tuc_replay(self: &mut Self, ev: &mbe::RecEv) {
        if ev.kind == mbe::RK_DEMAND {
            if ev.a == 1 {
                if self.demand_seen.contains(&ev.h) {
                    return;
                }
                self.demand_seen.insert(ev.h);
            } else if ev.a == 2 {
                let hit = self.glue_seen.contains(&ev.h);
                if hit {
                    return;
                }
                self.glue_seen.insert(ev.h);
            }
            let snap = mbe::subs_copy(&ev.subs);
            self.demand.push(
                Demand {
                    def: DefId { module: ev.b as ModuleId, node: ev.c },
                    sym: ev.s1.clone(),
                    subs: snap,
                    sfx: ev.s2.clone(),
                },
            );
            return;
        }
        if ev.kind == mbe::RK_GLUE {
            let hit = self.glue_seen.contains(&ev.h);
            if hit {
                return;
            }
            self.glue_seen.insert(ev.h);
            let ge = GlueEnv { subs: mbe::subs_copy(&ev.subs) };
            self.glue_envs.push(ge);
            self.glue.push(
                StatRef {
                    em: ev.a as ModuleId,
                    def: DefId { module: 0, node: NODE_NONE },
                    sym: ev.s1.clone(),
                    ty: ev.d,
                    args: Vector::<mbe::MSub>::new(),
                },
            );
            return;
        }
        if ev.kind == mbe::RK_STAT {
            let _ = self.stat_demand(
                ev.h,
                ev.a as ModuleId,
                DefId { module: ev.b as ModuleId, node: ev.c },
                ev.d,
                ev.s1.as_str(),
                &ev.subs,
            );
            return;
        }
        if ev.kind == mbe::RK_EXT {
            let hit = self.extern_seen.contains(&ev.h);
            if hit {
                return;
            }
            self.extern_seen.insert(ev.h);
            self.extern_protos.push_string(&ev.s1);
            return;
        }
        if ev.kind == mbe::RK_DYNREQ {
            let _ = self.dyn_request(ev.a as ModuleId, ev.b);
            return;
        }
        if ev.kind == mbe::RK_DYNTAB {
            let mut pair9 = String::new();
            let mut am9: ModuleId = 0;
            let mut at9 = TYPE_NONE;
            if ev.subs.len() != 0 {
                am9 = ev.subs.at(0).am;
                at9 = ev.subs.at(0).at;
            }
            let _ = self.dyn_pair(ev.a as ModuleId, ev.b, ev.c as ModuleId, ev.d, ev.h != 0, am9, at9, &mut pair9);
            return;
        }
        if ev.kind == mbe::RK_TI {
            let mut mg9 = String::new();
            if !self.mg.type_m(ev.a as ModuleId, ev.b, &mut mg9) {
                return;
            }
            let mut sym = String::from_str("__sc_ti__");
            sym.push_string(&mg9);
            let h = sym.as_str().hash();
            let hit = self.ti_seen.contains(&h);
            if hit {
                return;
            }
            self.ti_seen.insert(h);
            self.ti_reqs.push(
                StatRef {
                    em: ev.a as ModuleId,
                    def: DefId { module: 0, node: NODE_NONE },
                    sym: sym,
                    ty: ev.b,
                    args: Vector::<mbe::MSub>::new(),
                },
            );
            return;
        }
        if ev.kind == mbe::RK_BLK {
            let _ = self.blk_wrapper(DefId { module: ev.a as ModuleId, node: ev.b });
            return;
        }
        if ev.kind == mbe::RK_AGG {
            self.mg.tuc_replay_agg(ev);
            return;
        }
        if ev.kind == mbe::RK_WRAP {
            self.mg.wrap_take(mbe::WrapReq { h: ev.h, elem: ev.s1.clone(), body: ev.s2.clone() });
            return;
        }
        if ev.kind == mbe::RK_PACK {
            self.mg.pack_take(mbe::WrapReq { h: ev.h, elem: ev.s1.clone(), body: ev.s2.clone() });
            return;
        }
        if ev.kind == mbe::RK_MDYN {
            self.mg.dyn_reqs.push(mbe::DynReq { pm: ev.a as ModuleId, t: ev.b });
            return;
        }
        if ev.kind == mbe::RK_EDEF {
            self.env_skip.insert(ev.h, 1);
            self.env_hashes.push(ev.h);
            return;
        }
        if ev.kind == mbe::RK_ZST {
            let mut sc9 = String::new();
            self.sentinel(ev.a, &mut sc9);
            return;
        }
    }

    // Queue the definition and the `extern` declaration of const or static `item` (symbol `sym`, its
    // hash `h`, type `ty` of module `em`, generic extend instance `args`) once; an extern-block
    // static's backing header declares it. False when its type has no C spelling.
    fn stat_demand(self: &mut Self, h: u64, em: ModuleId, item: DefId, ty: TypeId, sym: str, args: &Vector<mbe::MSub>) bool {
        if self.stat_seen.contains(&h) {
            return true;
        }
        self.stat_seen.insert(h);
        let idn = unsafe (*self.p().module_ast_const(item.module)).at_const(item.node);
        if idn.kind == NodeKind::NODE_CONST && idn.as_data.const_def.is_extern {
            return true;
        }
        let mut sd = String::from_str("extern ");
        if !self.ty_c(em, ty, sym, &mut sd) {
            return false;
        }
        sd.push_str(";\n");
        self.stat_decls.push_string(&sd);
        self.stat_end.push(self.stat_decls.len() as u32);
        self.stat_items.push(
            StatRef { em: em, def: item, sym: String::from_str(sym), ty: ty, args: mbe::subs_copy(args) },
        );
        return true;
    }

    // A generic extend's constant `c` spells `<module prefix><InstName>__<NAME>`, a generic function's
    // local constant `<its symbol>__<Args>` (`tc_local_const_env`): static data per instance, which
    // the declaring module defines by evaluating the initializer for that instance.
    fn assoc_const_ref(self: &mut Self, b: &ir::CoreBody, c: &ir::Constant, dst: &mut String) bool {
        let tgt = self.mg.method_target(c.item.module, c.item.node);
        let n = c.targ_len();
        if n > 8 {
            return self.fail("assoc-const-inst");
        }
        let ta = self.p().module_ast_const(tgt.module);
        let tg = if tgt.node != NODE_NONE {
            unsafe (*ta).at_const(tgt.node).as_data.aggregate.generics;
        } else {
            NodeList { start: 0, len: 0 };
        };
        let mut rit = TyInstance { module: tgt.module, decl: tgt.node, n: n as u8 };
        let mut args = Vector::<mbe::MSub>::new();
        for k in 0..n {
            let t0 = b.targ_pool[(c.targ_start() + k) as usize];
            let y0 = *unsafe (*self.p().module_ast_const(b.module)).type_at(t0);
            let mut at = TYPE_NONE;
            // A local constant's arguments are the parameters themselves; an extend constant's bind
            // the target's parameters in order.
            let local_ok = tgt.node == NODE_NONE && y0.kind == TypeKind::TYPE_GENERIC;
            if !local_ok && k >= tg.len || !self.mg.ground(b.module, t0, b.module, &mut at) {
                return self.fail("assoc-const-targ");
            }
            unsafe rit.args[k as usize] = at;
            let mut sb = mbe::MSub { pm: y0.module, pnode: y0.as_data.decl, am: b.module, at: at, lim: 0 };
            if !local_ok {
                sb.pm = tgt.module;
                sb.pnode = unsafe (*ta).list(tg)[k as usize];
            }
            args.push(sb);
        }
        let d0 = dst.len();
        if tgt.node == NODE_NONE {
            if !self.mg.const_sym(c.item.module, c.item.node, dst) || !self.mg.args_m(b.module, &rit, n as u8, dst) {
                return self.fail("assoc-const-inst");
            }
        } else {
            self.mg.modpfx(c.item.module, dst);
            if !self.mg.inst_name(b.module, &rit, dst) {
                return self.fail("assoc-const-inst");
            }
            dst.push_str("__");
            let ca = self.p().module_ast_const(c.item.module);
            self.mg.ident(
                c.item.module,
                unsafe (*ca).at_const(unsafe (*ca).at_const(c.item.node).as_data.const_def.name).as_data.name.text,
                dst,
            );
        }
        let tm = b.module;
        let mut tt = TYPE_NONE;
        if !self.mg.ground(b.module, c.ty, tm, &mut tt) {
            return self.fail("assoc-const-type");
        }
        if !self.collect_demand || self.mg.is_zst(tm, tt) {
            return true;
        }
        let mut sym = self.sget();
        sym.push_str(dst.as_str().slice(d0, dst.len()));
        let h = sym.as_str().hash();
        if self.mg.rec_on && self.mg.rec_dup_once(h ^ 8) {
            let mut ev = mbe::RecEv::blank(mbe::RK_STAT);
            ev.h = h;
            ev.a = tm;
            ev.b = c.item.module;
            ev.c = c.item.node;
            ev.d = tt;
            ev.s1.push_string(&sym);
            ev.subs = mbe::subs_copy(&args);
            self.mg.rec.push(ev);
        }
        let ok = self.stat_demand(h, tm, c.item, tt, sym.as_str(), &args);
        self.sput(sym);
        return ok || self.fail("static-sym");
    }

    /// Queue item `item`, whose storage a constant's static data addresses, as a referenced const
    /// or static is: false when it has no storage of its own (zero-sized, or an associated const).
    pub fn stat_item(self: &mut Self, item: DefId) bool {
        let ty = unsafe (*self.p().module_ast_const(item.module)).type_of(item.node);
        if ty == TYPE_NONE || self.mg.method_target(item.module, item.node).node != NODE_NONE || self.mg.is_zst(
            item.module,
            ty,
        ) {
            return false;
        }
        let mut sym = String::new();
        let _ = self.mg.const_sym(item.module, item.node, &mut sym);
        let none = Vector::<mbe::MSub>::new();
        return self.stat_demand(sym.as_str().hash(), item.module, item, ty, sym.as_str(), &none);
    }

    // Demand the generic-extend impl method `method_by_name` resolved last (its `last_method_def`).
    // These resolve by receiver spelling alone (interface dispatch, switch `eq`, drop `free`),
    // so an unplanned instance receiver reaches them with no demanding call edge.
    fn demand_impl(self: &mut Self, rm6: ModuleId, rt6: TypeId, sym: &String) {
        let idef = self.mg.last_method_def;
        if !self.collect_demand || idef.node == NODE_NONE || !self.mg.in_generic_extend(idef.module, idef.node) {
            return;
        }
        // A vector or mask receiver is the prelude instance it stands for.
        let mut rit = TyInstance {};
        if !unsafe (*self.p().module_ast_const(rm6)).targs_of(rt6, &mut rit) {
            return;
        }
        let ia = self.p().module_ast_const(idef.module);
        let ifd = unsafe (*ia).at_const(idef.node);
        if ifd.kind != NodeKind::NODE_FUNCTION || ifd.as_data.function.is_extern() || ifd.as_data.function.body == NODE_NONE {
            return;
        }
        if !self.mg.rec_on {
            // An identical (impl, receiver instance, env) demand builds the same record: the drain
            // would drop it on the symbol, so it never queues (journal mode records every attempt).
            let dk0 = def_fp(idef);
            let k0 = skey_mix(2, self.env_fp(dk0, rm6, &rit, true));
            if self.demand_seen.contains(&k0) {
                return;
            }
            self.demand_seen.insert(k0);
        }
        let mut snap = mbe::subs_copy(&self.mg.subs);
        let ext = self.mg.extend_of(idef.module, idef.node);
        self.bind_recv(&mut snap, idef.module, ext, rm6, &rit);
        let mut sfx = String::new();
        if !self.mg.args_m(rm6, &rit, rit.n, &mut sfx) {
            return;
        }
        let d9 = Demand { def: idef, sym: sym.clone(), dk: 0, subs: snap, sfx: sfx };
        self.rec_demand(&d9, 0, 0);
        self.demand.push(d9);
    }

    // `demand_impl` for a generic implementation method called through its interface with the
    // call's arguments `tg`: its body under the receiver instance (a generic extend's) and its own
    // parameters bound to `tg` by position, named `sym`.
    fn demand_impl_targs(self: &mut Self, rm6: ModuleId, rt6: TypeId, sym: &String, tg: IfTargs) {
        let idef = self.mg.last_method_def;
        if !self.collect_demand || idef.node == NODE_NONE {
            return;
        }
        let ia = self.p().module_ast_const(idef.module);
        let ifd = unsafe (*ia).at_const(idef.node);
        if ifd.kind != NodeKind::NODE_FUNCTION || ifd.as_data.function.is_extern() || ifd.as_data.function.body == NODE_NONE {
            return;
        }
        if !self.mg.rec_on {
            // The symbol spells the implementation, the receiver instance and every argument under
            // the active env: an equal symbol is an equal demand.
            let k0 = skey_mix(4, skey_mix(def_fp(idef), sym.as_str().hash()));
            if self.demand_seen.contains(&k0) {
                return;
            }
            self.demand_seen.insert(k0);
        }
        let mut snap = mbe::subs_copy(&self.mg.subs);
        let mut sfx = String::new();
        let mut rit = TyInstance {};
        if unsafe (*self.p().module_ast_const(rm6)).targs_of(rt6, &mut rit) && self.mg.in_generic_extend(
            idef.module,
            idef.node,
        ) {
            let ext = self.mg.extend_of(idef.module, idef.node);
            self.bind_recv(&mut snap, idef.module, ext, rm6, &rit);
            if !self.mg.args_m(rm6, &rit, rit.n, &mut sfx) {
                return;
            }
        } else if !self.push_targs(tg, &mut sfx) {
            return;
        }
        self.bind_targs(&mut snap, idef.module, ifd.as_data.function.generics, tg);
        let d9 = Demand { def: idef, sym: sym.clone(), dk: 0, subs: snap, sfx: sfx };
        self.rec_demand(&d9, 0, 0);
        self.demand.push(d9);
    }

    // `callee` (spelled with its open paren) applied to the `n` operands at `b.oper_pool[a..]`.
    fn emit_intrinsic_call(self: &mut Self, b: &ir::CoreBody, callee: str, a: u32, n: u32, dst: &mut String) bool {
        dst.push_str(callee);
        for i in 0..n {
            if i != 0 {
                dst.push_str(", ");
            }
            if !self.emit_operand(b, b.oper_pool[(a + i) as usize], dst) {
                return false;
            }
        }
        dst.push_str(")");
        return true;
    }

    // Spell aggregate `(rm, rt)`'s operator method `mn` into `dst`: its own impl (demanded when
    // generic) or the interface default. False when neither exists.
    fn agg_op_sym(self: &mut Self, rm: ModuleId, rt: TypeId, mn: str, dst: &mut String) bool {
        let mut s = self.sget();
        let ok = if self.mg.method_by_name(rm, rt, mn, &mut s) {
            self.demand_impl(rm, rt, &s);
            true;
        } else {
            self.conf_default_sym(rm, rt, mn, &mut s);
        };
        if ok {
            dst.push_string(&s);
        }
        self.sput(s);
        return ok;
    }

    // `(&a, &b)`: an operator method's arguments, each operand by address.
    fn emit_ref_args(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, aref: bool, bref: bool, dst: &mut String) bool {
        dst.push_str(
            if aref {
                "(";
            } else {
                "(&";
            },
        );
        let mut ok = self.emit_operand(b, rv.a, dst);
        dst.push_str(
            if bref {
                ", ";
            } else {
                ", &";
            },
        );
        if ok {
            ok = self.emit_operand(b, rv.b, dst);
        }
        dst.push_str(")");
        return ok;
    }

    // Aggregate operands that dispatch operators through methods: structs, instances, and
    // payload-carrying enums (their C value is a struct; bare enums compare as integers).
    fn op_dispatch_agg(self: &mut Self, rm: ModuleId, rt: TypeId) bool {
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE {
            return true;
        }
        if y.kind == TypeKind::TYPE_ENUM {
            return unsafe (*self.p().module_ast_const(y.module)).enum_has_payload(y.as_data.decl);
        }
        return false;
    }

    // The interface-DEFAULT instance for `mname` on resolved receiver `(rm, rt)`: scan the decl's
    // conformances for an interface declaring `mname` with a default body, render + demand its
    // per-conformance symbol. False = no conformance supplies it.
    fn conf_default_sym(self: &mut Self, rm: ModuleId, rt: TypeId, mname: str, dst: &mut String) bool {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE {
            return false;
        }
        let da = self.p().module_ast_const(dm);
        let items = unsafe (*da).at_const((*da).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*da).list(items)[i as usize];
            let itn = unsafe (*da).at_const(iid);
            if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE || itn.as_data.extend_def.interface_type == NODE_NONE {
                continue;
            }
            let tg = unsafe (*da).resolution_def(itn.as_data.extend_def.target_type);
            if tg.module != dm || tg.node != dd {
                continue;
            }
            let ifd = unsafe (*da).resolution_def(itn.as_data.extend_def.interface_type);
            if ifd.node == NODE_NONE {
                continue;
            }
            let ia = self.p().module_ast_const(ifd.module);
            if unsafe (*ia).at_const(ifd.node).kind != NodeKind::NODE_INTERFACE {
                continue;
            }
            let ms = unsafe (*ia).at_const(ifd.node).as_data.interface_def.items;
            let isrc = self.p().modules.at(ifd.module as usize).source.as_str();
            for j in 0..ms.len {
                let mid = unsafe (*ia).list(ms)[j as usize];
                let mn = unsafe (*ia).at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.body == NODE_NONE {
                    continue;
                }
                let s2 = unsafe (*ia).at_const(mn.as_data.function.name).as_data.name.text;
                if isrc.slice(s2.start as usize, s2.end as usize) == mname {
                    return self.iface_target_sym(
                        rm,
                        rt,
                        DefId { module: ifd.module, node: mid },
                        DefId { module: 0, node: NODE_NONE },
                        "",
                        IfTargs { m: rm, at: null, n: 0 },
                        rm,
                        null,
                        dst,
                    );
                }
            }
        }
        return false;
    }

    // The symbol an interface-member call on RESOLVED receiver `(rm6, rt6)` dispatches to: a
    // CUSTOM impl when one exists (bound dispatch resolves per instantiation), else the
    // per-target default-method instantiation, whose body is demanded under `Self -> receiver`.
    // `conf`: the conformance extend the caller chose among several (`conf_for_args`), node
    // NODE_NONE for the method found by name; `csfx` then names that conformance (`<I>___<args>`),
    // and its default bodies spell `<Target>__<method>__<csfx>`: each conformance instantiates
    // them under its own interface arguments.
    // `want` (pool `wm`, null when unknown) is the interface instance the call goes through: it
    // solves a keyed conformance's parameters its target does not name.
    fn iface_target_sym(
        self: &mut Self,
        rm6: ModuleId,
        rt6: TypeId,
        callee: DefId,
        conf: DefId,
        csfx: str,
        tg: IfTargs,
        wm: ModuleId,
        want: *const TyInstance,
        dst: &mut String,
    ) bool {
        let mut sym = self.sget();
        let ok = self.iface_target_sym_i(rm6, rt6, callee, conf, csfx, tg, wm, want, &mut sym, dst);
        self.sput(sym);
        return ok;
    }

    // The binding of generic parameter `(pm, pnode)` in `snap` from `from` on (the latest), or -1.
    const fn snap_find(snap: &Vector<mbe::MSub>, from: u32, pm: ModuleId, pnode: NodeId) i64 {
        let mut i = snap.len();
        while i > from as usize {
            i -= 1;
            if snap.at(i).pm == pm && snap.at(i).pnode == pnode {
                return i as i64;
            }
        }
        return -1;
    }

    // Bind the parameters of keyed conformance `ext` (module `em`, `ext_keyed`) for receiver
    // `(rm, rt)` into `snap`: a generic extend's target parameter to the receiver, a target's own
    // through its instance (`bind_recv`), and the ones only the interface's arguments name by unifying
    // those with interface instance `want` (pool `wm`; null: none). False when one stays unbound.
    fn bind_keyed(
        self: &mut Self,
        snap: &mut Vector<mbe::MSub>,
        em: ModuleId,
        ext: NodeId,
        rm: ModuleId,
        rt: TypeId,
        wm: ModuleId,
        want: *const TyInstance,
    ) bool {
        let ea = self.p().module_ast_const(em);
        let ed = unsafe (*ea).at_const(ext).as_data.extend_def;
        let l0 = snap.len() as u32;
        let b = ext_blanket(unsafe &*ea, unsafe (*ea).type_of(ed.target_type), unsafe &*ea, em, ext);
        if b >= 0 {
            self.push_bind(snap, em, unsafe (*ea).list(ed.generics)[b as usize], rm, rt, l0);
        } else {
            let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
            let mut it = TyInstance {};
            if unsafe (*self.p().module_ast_const(rm)).targs_of(rt, &mut it) {
                self.bind_recv(snap, em, ext, rm, &it);
            }
            let _ = y;
        }
        let dt = unsafe (*ea).type_of(ed.interface_type);
        if want != null && dt != TYPE_NONE && unsafe (*ea).type_at(dt).kind == TypeKind::TYPE_DYN {
            let di = *unsafe (*ea).instance(unsafe (*ea).type_at(dt).as_data.inst);
            let mut bp = Vector::<NodeId>::new();
            let mut bm = Vector::<ModuleId>::new();
            let mut bt = Vector::<TypeId>::new();
            let mut k: u8 = 0;
            while k < di.n && k < unsafe (*want).n {
                self.unify_bind(
                    em,
                    unsafe di.args[k as usize],
                    wm,
                    unsafe (*want).args[k as usize],
                    em,
                    ed.generics,
                    &mut bp,
                    &mut bm,
                    &mut bt,
                    0,
                );
                k += 1;
            }
            for i in 0..bp.len() {
                if CEmit::snap_find(snap, l0, em, bp[i]) < 0 {
                    self.push_bind(snap, em, bp[i], bm[i], bt[i], l0);
                }
            }
        }
        for g in 0..ed.generics.len {
            if CEmit::snap_find(snap, l0, em, unsafe (*ea).list(ed.generics)[g as usize]) < 0 {
                return false;
            }
        }
        if want == null || dt == TYPE_NONE || unsafe (*ea).type_at(dt).kind != TypeKind::TYPE_DYN {
            return true;
        }
        // The conformance's arguments, grounded under the bindings, are the interface instance's.
        for k in l0 as usize..snap.len() {
            self.mg.push_msub(snap[k]);
        }
        let di = *unsafe (*ea).instance(unsafe (*ea).type_at(dt).as_data.inst);
        let mut same = di.n == unsafe (*want).n;
        let mut k: u8 = 0;
        while same && k < di.n {
            let mut g1 = TYPE_NONE;
            let mut g2 = TYPE_NONE;
            same = self.mg.ground(em, unsafe di.args[k as usize], wm, &mut g1) && self.mg.ground(
                wm,
                unsafe (*want).args[k as usize],
                wm,
                &mut g2,
            ) && g1 == g2;
            k += 1;
        }
        self.mg.pop_subs(snap.len() - l0 as usize);
        return same;
    }

    // The symbol of method `md` of keyed extend `ext` (module `md.module`) whose parameters `snap`
    // binds from `from` on, then the call's own arguments `tg`, into `sym` (`keyed_sym`, then each
    // argument); its instance is demanded under `snap`.
    fn keyed_call_sym(
        self: &mut Self,
        md: DefId,
        ext: NodeId,
        snap: Vector<mbe::MSub>,
        from: u32,
        tg: IfTargs,
        sym: &mut String,
    ) bool {
        let mut sn = snap;
        if !self.mg.keyed_sym(md.module, md.node, sym) {
            return self.fail("keyed-sym");
        }
        let st = sym.len();
        let ea = self.p().module_ast_const(md.module);
        let gens = unsafe (*ea).at_const(ext).as_data.extend_def.generics;
        for g in 0..gens.len {
            let i = CEmit::snap_find(&sn, from, md.module, unsafe (*ea).list(gens)[g as usize]);
            if i < 0 {
                return self.fail("keyed-arg");
            }
            let b = *sn.at(i as usize);
            sym.push_str("__");
            if !self.mg.type_m(b.am, b.at, sym) {
                return self.fail("keyed-arg");
            }
        }
        if !self.push_targs(tg, sym) {
            return false;
        }
        self.mg.mark_used(md.module);
        let fd = unsafe (*ea).at_const(md.node);
        if !self.collect_demand || fd.as_data.function.is_extern() || fd.as_data.function.body == NODE_NONE {
            return true;
        }
        if !self.mg.rec_on {
            let k0 = skey_mix(5, skey_mix(def_fp(md), sym.as_str().hash()));
            if self.demand_seen.contains(&k0) {
                return true;
            }
            self.demand_seen.insert(k0);
        }
        self.bind_targs(&mut sn, md.module, fd.as_data.function.generics, tg);
        let sfx = String::from_str(sym.as_str().slice(st, sym.len()));
        let d9 = Demand { def: md, sym: sym.clone(), dk: 0, subs: sn, sfx: sfx };
        self.rec_demand(&d9, 0, 0);
        self.demand.push(d9);
        return true;
    }

    // `__<arg>` for each of the call's generic arguments `tg`, spelled under the active env; false
    // when one does not spell.
    fn push_targs(self: &mut Self, tg: IfTargs, sym: &mut String) bool {
        for k in 0..tg.n {
            sym.push_str("__");
            if !self.mg.type_m(tg.m, unsafe tg.at[k as usize], sym) {
                return self.fail("callee-targ");
            }
        }
        return true;
    }

    // Bind generic parameters `gens` (module `fm`) to the call's arguments `tg` into `snap`, by
    // position: an implementation's parameters stand where the interface method's do.
    fn bind_targs(self: &Self, snap: &mut Vector<mbe::MSub>, fm: ModuleId, gens: NodeList, tg: IfTargs) {
        let g0 = snap.len() as u32;
        let fa = self.p().module_ast_const(fm);
        let mut k: u32 = 0;
        while k < gens.len && k < tg.n {
            self.push_bind(snap, fm, unsafe (*fa).list(gens)[k as usize], tg.m, unsafe tg.at[k as usize], g0);
            k += 1;
        }
    }

    fn iface_target_sym_i(
        self: &mut Self,
        rm6: ModuleId,
        rt6: TypeId,
        callee: DefId,
        conf: DefId,
        csfx: str,
        tg: IfTargs,
        wm: ModuleId,
        want: *const TyInstance,
        sym: &mut String,
        dst: &mut String,
    ) bool {
        {
            let ca8 = self.p().module_ast_const(callee.module);
            let msp8 = unsafe (*ca8).at_const(unsafe (*ca8).at_const(callee.node).as_data.function.name).as_data.name.text;
            let msrc8 = self.p().modules.at(callee.module as usize).source.as_str();
            let mname8 = msrc8.slice(msp8.start as usize, msp8.end as usize);
            // `sym` doubles as the impl spelling here; the default-body symbol below starts fresh. The
            // conformance's own method, never a same-named method another extend of the type defines:
            // without its own, the conformance runs the default.
            let mut cm8: ModuleId = 0;
            let mut ce8 = conf.node;
            let ifd8 = DefId { module: callee.module, node: self.mg.in_interface(callee.module, callee.node) };
            if ce8 != NODE_NONE {
                cm8 = conf.module;
            } else {
                ce8 = self.mg.conform_ext(rm6, rt6, ifd8, &mut cm8);
            }
            // A keyed conformance (`ext_keyed`): the one by target, else the generic conformance whose
            // parameters bind for this receiver and interface instance; its method spells every
            // argument of the extend.
            let mut ksnap = mbe::subs_copy(&self.mg.subs);
            let k0 = ksnap.len() as u32;
            let mut keyed8 = ce8 != NODE_NONE && ext_keyed(unsafe &*self.p().module_ast_const(cm8), ce8);
            if ce8 != NODE_NONE && !keyed8 && conf.node == NODE_NONE && want != null {
                // The conformance by target serves another interface instance: a generic one below.
                let mut chk = mbe::subs_copy(&self.mg.subs);
                if !self.bind_keyed(&mut chk, cm8, ce8, rm6, rt6, wm, want) {
                    ce8 = NODE_NONE;
                }
            }
            if keyed8 && !self.bind_keyed(&mut ksnap, cm8, ce8, rm6, rt6, wm, want) {
                // Another keyed conformance of the receiver, its parameters bound by the interface
                // instance the call goes through.
                let mut kc = Vector::<DefId>::new();
                self.mg.keyed_confs(rm6, rt6, ifd8, &mut kc);
                ce8 = NODE_NONE;
                for i in 0..kc.len() {
                    ksnap.truncate(k0 as usize);
                    if self.bind_keyed(&mut ksnap, kc[i].module, kc[i].node, rm6, rt6, wm, want) {
                        cm8 = kc[i].module;
                        ce8 = kc[i].node;
                        break;
                    }
                }
                if ce8 == NODE_NONE {
                    // None by target: a generic conformance below.
                    keyed8 = false;
                    ksnap.truncate(k0 as usize);
                }
            }
            if ce8 == NODE_NONE {
                let mut bl = Vector::<DefId>::new();
                self.mg.blanket_confs(ifd8, &mut bl);
                for i in 0..bl.len() {
                    ksnap.truncate(k0 as usize);
                    if self.bind_keyed(&mut ksnap, bl[i].module, bl[i].node, rm6, rt6, wm, want) {
                        cm8 = bl[i].module;
                        ce8 = bl[i].node;
                        keyed8 = true;
                        break;
                    }
                }
            }
            if keyed8 {
                let mut km = DefId { module: 0, node: NODE_NONE };
                let ka8 = self.p().module_ast_const(cm8);
                let its = unsafe (*ka8).at_const(ce8).as_data.extend_def.items;
                for j in 0..its.len {
                    let iid = unsafe (*ka8).list(its)[j as usize];
                    let inn = unsafe (*ka8).at_const(iid);
                    let isp = unsafe (*ka8).at_const(inn.as_data.function.name).as_data.name.text;
                    if inn.kind == NodeKind::NODE_FUNCTION && self.p().modules.at(cm8 as usize).source.as_str().slice(
                        isp.start as usize,
                        isp.end as usize,
                    ) == mname8 {
                        km = DefId { module: cm8, node: iid };
                    }
                }
                if km.node != NODE_NONE {
                    if !self.keyed_call_sym(km, ce8, ksnap, k0, tg, sym) {
                        return false;
                    }
                    dst.push_string(sym);
                    return true;
                }
            }
            let found = if ce8 != NODE_NONE {
                self.mg.method_in_ext(rm6, rt6, cm8, ce8, mname8, sym);
            } else {
                self.mg.method_by_name(rm6, rt6, mname8, sym);
            };
            if found && (mname8 != "free" || self.user_free_covers(rm6, rt6)) {
                if tg.n != 0 {
                    if !self.push_targs(tg, sym) {
                        return false;
                    }
                    self.demand_impl_targs(rm6, rt6, sym, tg);
                } else {
                    self.demand_impl(rm6, rt6, sym);
                }
                dst.push_string(sym);
                return true;
            }
            sym.clear();
            if mname8 == "free" {
                let interface_decl = self.mg.in_interface(callee.module, callee.node);
                assert(interface_decl != NODE_NONE);
                let interface_name = unsafe (*ca8).at_const(interface_decl).as_data.interface_def.name;
                let interface_span = unsafe (*ca8).at_const(interface_name).as_data.name.text;
                if msrc8.slice(interface_span.start as usize, interface_span.end as usize) == "Free" {
                    if !self.free_expr(rm6, rt6, sym) {
                        return false;
                    }
                    dst.push_string(sym);
                    return true;
                }
            }
        }
        let y7 = *unsafe (*self.p().module_ast_const(rm6)).type_at(rt6);
        if y7.kind == TypeKind::TYPE_BUILTIN {
            self.mg.modpfx(callee.module, sym);
            if !self.mg.type_m(rm6, rt6, sym) {
                return self.fail("iface-default-recv");
            }
        } else if y7.kind == TypeKind::TYPE_INSTANCE {
            let it7 = *unsafe (*self.p().module_ast_const(rm6)).instance(y7.as_data.inst);
            if !self.mg.inst_name(rm6, &it7, sym) {
                return self.fail("iface-default-inst");
            }
        } else {
            self.mg.modpfx(callee.module, sym);
            let da7 = self.p().module_ast_const(y7.module);
            self.mg.ident(
                y7.module,
                unsafe (*da7).at_const(unsafe (*da7).at_const(y7.as_data.decl).as_data.aggregate.name).as_data.name.text,
                sym,
            );
        }
        sym.push_str("__");
        let ca7 = self.p().module_ast_const(callee.module);
        self.mg.ident(
            callee.module,
            unsafe (*ca7).at_const(unsafe (*ca7).at_const(callee.node).as_data.function.name).as_data.name.text,
            sym,
        );
        if conf.node != NODE_NONE {
            sym.push_str("__");
            sym.push_str(csfx);
        }
        if !self.push_targs(tg, sym) {
            return false;
        }
        // The default body's prototype lives in the interface's module.
        self.mg.mark_used(callee.module);
        // Demand the default BODY under `Self -> receiver` (the interface DECL NODE is Self's
        // binding key: the extend-frame convention).
        if self.collect_demand {
            let fd7 = unsafe (*ca7).at_const(callee.node);
            if fd7.kind == NodeKind::NODE_FUNCTION && !fd7.as_data.function.is_extern() && fd7.as_data.function.body != NODE_NONE {
                let idecl = self.mg.in_interface(callee.module, callee.node);
                let mut snap = mbe::subs_copy(&self.mg.subs);
                let l7 = snap.len() as u32;
                snap.push(mbe::MSub { pm: callee.module, pnode: idecl, am: rm6, at: rt6, lim: l7 });
                self.bind_conformance(&mut snap, rm6, rt6, DefId { module: callee.module, node: idecl }, conf);
                self.bind_targs(&mut snap, callee.module, fd7.as_data.function.generics, tg);
                let d9 = Demand { def: callee, sym: sym.clone(), dk: 0, subs: snap, sfx: String::new() };
                self.rec_demand(&d9, 0, 0);
                self.demand.push(d9);
            }
        }
        dst.push_string(sym);
        return true;
    }

    // One vtable member declarator: `<ret> (*<name>)(void *self[, <param types>])`: parameter
    // types `ps` and results `rs` of pool `dm`, from `slot_types`.
    // The C return type of a dyn slot returning `rs` (pool `dm`) into `ret` and `rt`: `void` and
    // TYPE_NONE for no result or a zero-sized one (no C carrier), the result pack for several
    // (`Mangler::ret_pack`). False for an unspellable type.
    fn dyn_ret(self: &mut Self, dm: ModuleId, rs: &Vector<TypeId>, ret: &mut String, rt: &mut TypeId) bool {
        if rs.len() > 1 || rs.len() == 1 && self.mg.arr_result(dm, rs[0]) {
            return self.mg.ret_pack(dm, rs, ret);
        }
        if rs.len() == 1 && !self.mg.is_zst(dm, rs[0]) {
            *rt = rs[0];
            return self.mg.ctype(dm, rs[0], "", ret);
        }
        ret.push_str("void");
        return true;
    }

    // The parameter types of a vtable slot from `start` (interfaces skip the receiver) and its
    // results, read from signature lists `ps`/`rs` of module `dm`.
    fn slot_types(
        self: &mut Self,
        dm: ModuleId,
        ps: NodeList,
        rs: NodeList,
        start: u32,
        tys: &mut Vector<TypeId>,
        rtys: &mut Vector<TypeId>,
    ) bool {
        let da = self.p().module_ast_const(dm);
        rtys.clear();
        for i in 0..rs.len {
            rtys.push(unsafe (*da).type_of(unsafe (*da).slot_type_node(unsafe (*da).list(rs)[i as usize])));
        }
        tys.clear();
        for i in start..ps.len {
            tys.push(unsafe (*da).type_of(unsafe (*da).list(ps)[i as usize]));
        }
        return true;
    }

    // `slot_types` of function-pointer type `sig` (pool `pm`), the signature of a `dyn fn`.
    fn sig_slot_types(self: &mut Self, pm: ModuleId, sig: TypeId, tys: &mut Vector<TypeId>, rtys: &mut Vector<TypeId>) bool {
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(sig);
        rtys.clear();
        for i in 0..unsafe (*a).sig_len(&y, true) {
            rtys.push(unsafe (*a).sig_at(&y, true, i));
        }
        tys.clear();
        for i in 0..unsafe (*a).sig_len(&y, false) {
            tys.push(unsafe (*a).sig_at(&y, false, i));
        }
        return true;
    }

    fn dyn_sig(self: &mut Self, dm: ModuleId, ps: &Vector<TypeId>, rs: &Vector<TypeId>, name: str, o: &mut String) bool {
        let mut ret = String::new();
        let mut rt = TYPE_NONE;
        let mut ok = self.dyn_ret(dm, rs, &mut ret, &mut rt);
        let mark = o.len();
        if ok {
            o.push_string(&ret);
            o.push_str(" (*");
            o.push_str(name);
            o.push_str(")(void *self");
            for i in 0..ps.len() {
                if !ok {
                    break;
                }
                if self.mg.is_zst(dm, ps[i]) {
                    // Zero-sized by-value params take no slot.
                    continue;
                }
                o.push_str(", ");
                ok = self.mg.ctype(dm, ps[i], "", o);
            }
            o.push_str(")");
            ok = ok && self.fn_decl(dm, rt, mark, mark + ret.len() + 1, o);
        }
        if !ok {
            return self.fail("dyn-sig");
        }
        return true;
    }

    /// Ensure the `SC_DYN_<stem>` typedef block (vtable struct + fat value + inline free) is in
    /// `dyn_defs`. Interface vtables carry `__free`/`tid` then every self-taking member in decl
    /// order (defaults included); structural `dyn fn` vtables carry `__free` then `call`.
    pub fn dyn_request(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let y = *unsafe (*self.p().module_ast_const(pm)).type_at(t);
        if y.kind != TypeKind::TYPE_DYN {
            return self.fail("dyn-req");
        }
        if self.mg.rec_on {
            let mut ev = mbe::RecEv::blank(mbe::RK_DYNREQ);
            ev.a = pm;
            ev.b = t;
            self.mg.rec.push(ev);
        }
        let mut stem = self.sget();
        if !self.mg.dyn_stem(pm, &y, &mut stem) {
            self.sput(stem);
            return self.fail("dyn-stem");
        }
        let h = stem.as_str().hash();
        if self.dyn_def_seen.contains(&h) {
            self.sput(stem);
            return true;
        }
        self.dyn_def_seen.insert(h);
        let a = self.p().module_ast_const(pm);
        let it = *unsafe (*a).instance(y.as_data.inst);
        let mut tys = Vector::<TypeId>::new();
        let mut rtys = Vector::<TypeId>::new();
        let r0 = self.mg.dyn_reqs.len();
        let mut o = String::new();
        o.push_str("#ifndef SC_DYN_");
        o.push_string(&stem);
        o.push_str("\n#define SC_DYN_");
        o.push_string(&stem);
        o.push_str("\ntypedef struct ");
        o.push_string(&stem);
        o.push_str("__vt {\n    void (*__free)(void *self);\n");
        let mut ok = true;
        if it.decl == NODE_NONE {
            o.push_str("    ");
            ok = self.sig_slot_types(pm, it.args[0], &mut tys, &mut rtys) && self.dyn_sig(
                pm,
                &tys,
                &rtys,
                "call",
                &mut o,
            );
            o.push_str(";\n");
        } else {
            o.push_str("    const char *tid;\n");
            ok = self.vt_fields(pm, &it, &mut tys, &mut rtys, &mut o);
            // Each superinterface's methods follow under the arguments the hierarchy gives it, then
            // one table pointer per superinterface for an upcast.
            let mut sup = Vector::<TypeId>::new();
            ok = ok && self.dyn_supers(pm, t, &mut sup);
            for si in 1..sup.len() {
                if !ok {
                    break;
                }
                let sit = *unsafe (*a).instance(unsafe (*a).type_at(sup[si]).as_data.inst);
                ok = self.vt_fields(pm, &sit, &mut tys, &mut rtys, &mut o);
            }
            for si in 1..sup.len() {
                if !ok {
                    break;
                }
                let sy = *unsafe (*a).type_at(sup[si]);
                let mut ss = String::new();
                ok = self.dyn_request(pm, sup[si]) && self.mg.dyn_stem(pm, &sy, &mut ss);
                o.push_str("    const ");
                o.push_string(&ss);
                o.push_str("__vt *__super_");
                o.push_string(&ss);
                o.push_str(";\n");
            }
        }
        o.push_str("} ");
        o.push_string(&stem);
        o.push_str("__vt;\ntypedef struct ");
        o.push_string(&stem);
        o.push_str("__dyn { void *data; const ");
        o.push_string(&stem);
        o.push_str("__vt *vt; } ");
        o.push_string(&stem);
        o.push_str("__dyn;\nstatic inline void ");
        o.push_string(&stem);
        o.push_str("__dyn_free(");
        o.push_string(&stem);
        o.push_str("__dyn *const d) { d->vt->__free(d->data); }\n#endif\n");
        self.sput(stem);
        // A dyn type the vtable's signatures name must be declared first: its block goes before
        // this one (the stem gate above ends the recursion).
        let mut ri = r0;
        while ok && ri < self.mg.dyn_reqs.len() {
            let rq = *self.mg.dyn_reqs.at(ri);
            ok = self.dyn_request(rq.pm, rq.t);
            ri += 1;
        }
        if ok {
            self.dyn_defs.push_string(&o);
            if self.sh_on {
                self.sh_dyd_k.push(h);
                self.sh_dyd_e.push(self.dyn_defs.len() as u32);
            }
        }
        return ok;
    }

    // The vtable fields of interface instance `it` (pool `pm`): one function pointer per method that
    // takes a receiver, its signature read under the instance's arguments.
    fn vt_fields(
        self: &mut Self,
        pm: ModuleId,
        it: &TyInstance,
        tys: &mut Vector<TypeId>,
        rtys: &mut Vector<TypeId>,
        o: &mut String,
    ) bool {
        let da = self.p().module_ast_const(it.module);
        let dn = unsafe (*da).at_const(it.decl);
        let nb = self.mg.push_generics(it.module, dn.as_data.interface_def.generics, pm, it);
        let ms = dn.as_data.interface_def.items;
        let mut ok = true;
        for i in 0..ms.len {
            if !ok {
                break;
            }
            let mid = unsafe (*da).list(ms)[i as usize];
            let mn = unsafe (*da).at_const(mid);
            if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
                // Receiver-less members never dyn-dispatch.
                continue;
            }
            o.push_str("    ");
            let mut nm = String::new();
            self.mg.ident(it.module, unsafe (*da).at_const(mn.as_data.function.name).as_data.name.text, &mut nm);
            ok = self.slot_types(it.module, mn.as_data.function.params, mn.as_data.function.returns, 1, tys, rtys) && self.dyn_sig(
                it.module,
                tys,
                rtys,
                nm.as_str(),
                o,
            );
            o.push_str(";\n");
        }
        self.mg.pop_subs(nb);
        return ok;
    }

    // The superinterface closure of dyn type `(pm, t)` into `out`: `t` first, then breadth first and
    // each interface once, the dyn type of the arguments its bound gives it (the checker records it
    // on the bound) grounded into pool `pm`. The checker's dyn-compatibility check bounds the
    // closure at 8 interfaces.
    fn dyn_supers(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut Vector<TypeId>) bool {
        out.push(t);
        let a = self.p().module_ast_const(pm);
        let mut scan: usize = 0;
        while scan < out.len() {
            let it = *unsafe (*a).instance(unsafe (*a).type_at(out[scan]).as_data.inst);
            let da = self.p().module_ast_const(it.module);
            let dn = unsafe (*da).at_const(it.decl);
            let nb = self.mg.push_generics(it.module, dn.as_data.interface_def.generics, pm, &it);
            let bs = dn.as_data.interface_def.bounds;
            let mut ok = true;
            for b in 0..bs.len {
                let bt = unsafe (*da).type_of(unsafe (*da).list(bs)[b as usize]);
                if bt == TYPE_NONE {
                    continue;
                }
                let mut g = TYPE_NONE;
                if !self.mg.ground(it.module, bt, pm, &mut g) {
                    ok = false;
                    break;
                }
                let gd = unsafe (*a).instance(unsafe (*a).type_at(g).as_data.inst).decl;
                let gm = unsafe (*a).instance(unsafe (*a).type_at(g).as_data.inst).module;
                let mut seen = false;
                for k in 0..out.len() {
                    let ki = unsafe (*a).instance(unsafe (*a).type_at(out[k]).as_data.inst);
                    seen = seen || ki.decl == gd && ki.module == gm;
                }
                if !seen {
                    out.push(g);
                }
            }
            self.mg.pop_subs(nb);
            if !ok {
                return self.fail("dyn-super");
            }
            scan += 1;
        }
        return true;
    }

    // The instance of the interface that declares `callee` in the hierarchy of dyn type `(pm, t)`:
    // the dyn type's own, or a superinterface's under the arguments the hierarchy gives it.
    fn dyn_iface_inst(self: &mut Self, pm: ModuleId, t: TypeId, callee: DefId, out: &mut TyInstance) bool {
        let iface = self.mg.in_interface(callee.module, callee.node);
        let mut sup = Vector::<TypeId>::new();
        if !self.dyn_supers(pm, t, &mut sup) {
            return false;
        }
        let a = self.p().module_ast_const(pm);
        for k in 0..sup.len() {
            let it = *unsafe (*a).instance(unsafe (*a).type_at(sup[k]).as_data.inst);
            if it.module == callee.module && it.decl == iface {
                *out = it;
                return true;
            }
        }
        return self.fail("dyn-iface");
    }

    // The thunks and vtable slots of interface instance `it` (pool `pm`) for source type
    // `(srm, srt)`: each method dispatches to the conformance with the instance's arguments, a
    // default under the suffix `csfx`.
    fn vt_slots(
        self: &mut Self,
        pm: ModuleId,
        it: &TyInstance,
        srm: ModuleId,
        srt: TypeId,
        pair: &String,
        srcc: &String,
        csfx: &String,
        tys: &mut Vector<TypeId>,
        rtys: &mut Vector<TypeId>,
        tabs: &mut String,
        slots: &mut String,
    ) bool {
        let da = self.p().module_ast_const(it.module);
        let dn = unsafe (*da).at_const(it.decl);
        // With several conformances to a generic interface, the one with the dyn type's arguments.
        let conf = if it.n != 0 {
            self.conf_for_args(srm, srt, pm, it);
        } else {
            DefId { module: 0, node: NODE_NONE };
        };
        let nb = self.mg.push_generics(it.module, dn.as_data.interface_def.generics, pm, it);
        let ms = dn.as_data.interface_def.items;
        let mut ok = true;
        for i in 0..ms.len {
            if !ok {
                break;
            }
            let mid = unsafe (*da).list(ms)[i as usize];
            let mn = unsafe (*da).at_const(mid);
            if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
                continue;
            }
            let mut nm = String::new();
            self.mg.ident(it.module, unsafe (*da).at_const(mn.as_data.function.name).as_data.name.text, &mut nm);
            ok = self.slot_types(it.module, mn.as_data.function.params, mn.as_data.function.returns, 1, tys, rtys) && self.dyn_thunk(
                it.module,
                mid,
                tys,
                rtys,
                1,
                nm.as_str(),
                pair.as_str(),
                srcc.as_str(),
                srm,
                srt,
                conf,
                csfx.as_str(),
                pm,
                it,
                tabs,
            );
            if ok {
                // The thunk body dispatches like a direct call would (custom impl or default).
                slots.push_str(", ");
                slots.push_string(pair);
                slots.push_str("__");
                slots.push_string(&nm);
            }
        }
        self.mg.pop_subs(nb);
        return ok;
    }

    // Thunks + the vtable definition for one coercion pair (source type -> dyn stem); `own` makes
    // the vtable's `__free` destroy and deallocate the heap payload, through the allocator `(am, at)`
    // (TYPE_NONE: Global) its `Default` rebuilds. Appends `<pair>` to `pair`.
    fn dyn_pair(
        self: &mut Self,
        pm: ModuleId,
        dt: TypeId,
        srm: ModuleId,
        srt: TypeId,
        own: bool,
        am: ModuleId,
        at: TypeId,
        pair: &mut String,
    ) bool {
        if self.mg.rec_on {
            let mut ev = mbe::RecEv::blank(mbe::RK_DYNTAB);
            ev.a = pm;
            ev.b = dt;
            ev.c = srm;
            ev.d = srt;
            ev.h = if own {
                1u64;
            } else {
                0;
            };
            if at != TYPE_NONE {
                ev.subs.push(mbe::MSub { pnode: NODE_NONE, at: at, lim: 0, pm: 0, am: am });
            }
            self.mg.rec.push(ev);
        }
        let y = *unsafe (*self.p().module_ast_const(pm)).type_at(dt);
        if y.kind != TypeKind::TYPE_DYN || !self.dyn_request(pm, dt) {
            return self.fail("dyn-req");
        }
        let mut stem = self.sget();
        let mut src = self.sget();
        let mut ok9 = true;
        if !self.mg.dyn_stem(pm, &y, &mut stem) {
            ok9 = self.fail("dyn-stem");
        } else if !self.mg.type_m(srm, srt, &mut src) {
            ok9 = self.fail("dyn-src");
        } else {
            pair.push_string(&src);
            pair.push_str("__");
            pair.push_string(&stem);
            if own {
                // An owned erasure's table frees the payload, a borrowed one's cannot: two tables,
                // or whichever erasure came first would decide the `__free` slot for both.
                pair.push_str("__box");
            }
            if at != TYPE_NONE {
                // One table per allocator: its `__free` deallocates through that allocator.
                pair.push_str("__");
                ok9 = self.mg.type_m(am, at, pair);
            }
            let h = pair.as_str().hash();
            if !self.dyn_tab_seen.contains(&h) {
                self.dyn_tab_seen.insert(h);
                // The table lands in the receiver type's instance shard (the interface's when the
                // receiver has no owner module): spell its thunks under that context.
                let od9 = self.mg.owner_dep(srm, srt);
                let own9 = if od9 >= 0 {
                    od9 as ModuleId;
                } else {
                    unsafe (*self.p().module_ast_const(pm)).instance(y.as_data.inst).module;
                };
                let ctx0 = self.mg.mark_ctx;
                self.mg.mark_ctx = mbe::CTX_INST | own9 as i64;
                ok9 = ok9 && self.dyn_pair_tabs(pm, dt, &y, srm, srt, own, am, at, pair, &stem, &src, h, own9);
                self.mg.mark_ctx = ctx0;
            }
        }
        self.sput(src);
        self.sput(stem);
        return ok9;
    }

    fn dyn_pair_tabs(
        self: &mut Self,
        pm: ModuleId,
        dt: TypeId,
        y: &Ty,
        srm: ModuleId,
        srt: TypeId,
        own: bool,
        am: ModuleId,
        at: TypeId,
        pair: &mut String,
        stem: &String,
        src: &String,
        h: u64,
        own9: ModuleId,
    ) bool {
        let sy = *unsafe (*self.p().module_ast_const(srm)).type_at(srt);
        let is_clos = sy.kind == TypeKind::TYPE_FUNCTION;
        let mut srcc = String::new();
        let mut ok = self.mg.ctype(srm, srt, "", &mut srcc);
        let a = self.p().module_ast_const(pm);
        let it = *unsafe (*a).instance(y.as_data.inst);
        let mut tabs = String::new();
        let mut slots = String::new();
        let mut tys = Vector::<TypeId>::new();
        let mut rtys = Vector::<TypeId>::new();
        if ok && it.decl == NODE_NONE {
            // One `call` thunk into the hoisted closure body (env passed as the erased data).
            if !is_clos {
                ok = self.fail("dyn-fnval");
            }
            if ok {
                ok = self.sig_slot_types(pm, it.args[0], &mut tys, &mut rtys) && self.dyn_thunk(
                    pm,
                    NODE_NONE,
                    &tys,
                    &rtys,
                    0,
                    "call",
                    pair.as_str(),
                    srcc.as_str(),
                    srm,
                    srt,
                    DefId { module: 0, node: NODE_NONE },
                    "",
                    pm,
                    null,
                    &mut tabs,
                );
                slots.push_str(", ");
                slots.push_string(pair);
                slots.push_str("__call");
            }
        } else if ok {
            slots.push_str(", \"");
            slots.push_string(src);
            slots.push_str("\"");
            ok = self.vt_slots(pm, &it, srm, srt, pair, &srcc, stem, &mut tys, &mut rtys, &mut tabs, &mut slots);
            // Each superinterface's slots under its own conformance, then its table for an upcast
            // (owned like this one).
            let mut sup = Vector::<TypeId>::new();
            ok = ok && self.dyn_supers(pm, dt, &mut sup);
            for si in 1..sup.len() {
                if !ok {
                    break;
                }
                let sy = *unsafe (*a).type_at(sup[si]);
                let sit = *unsafe (*a).instance(sy.as_data.inst);
                let mut ss = String::new();
                ok = self.mg.dyn_stem(pm, &sy, &mut ss) && self.vt_slots(
                    pm,
                    &sit,
                    srm,
                    srt,
                    pair,
                    &srcc,
                    &ss,
                    &mut tys,
                    &mut rtys,
                    &mut tabs,
                    &mut slots,
                );
            }
            for si in 1..sup.len() {
                if !ok {
                    break;
                }
                let mut sp = String::new();
                ok = self.dyn_pair(pm, sup[si], srm, srt, own, am, at, &mut sp);
                slots.push_str(", &");
                slots.push_string(&sp);
                slots.push_str("__vtbl");
            }
        }
        let mut fslot = String::from_str("0");
        if ok && own {
            fslot.truncate(0);
            fslot.push_string(pair);
            fslot.push_str("____free");
            tabs.push_str("static void ");
            tabs.push_string(&fslot);
            tabs.push_str("(void *__self) {\n");
            if self.is_destructible(srm, srt) {
                let mut fe = String::new();
                ok = self.free_expr(srm, srt, &mut fe);
                if ok {
                    tabs.push_str("    ");
                    tabs.push_string(&fe);
                    tabs.push_str("((");
                    tabs.push_string(&srcc);
                    tabs.push_str(" *)__self);\n");
                }
            }
            tabs.push_str("    ");
            if at == TYPE_NONE {
                tabs.push_str("Global__dealloc(");
                self.push_global_arg(&mut tabs);
            } else if ok {
                // The allocator the box was made with, rebuilt by its `Default` (the fat value
                // carries no allocator state; the checker requires `Default`).
                let mut ds = String::new();
                ok = self.mg.method_by_name(am, at, "default", &mut ds) && self.mg.method_by_name(
                    am,
                    at,
                    "dealloc",
                    &mut tabs,
                );
                tabs.push_str("(");
                if self.mg.is_zst(am, at) {
                    tabs.push_str("(");
                    tabs.push_string(&ds);
                    tabs.push_str("(), ");
                    ok = ok && self.zst_sentinel_ref(am, at, &mut tabs);
                    tabs.push_str(")");
                } else {
                    tabs.push_str("&(");
                    ok = ok && self.mg.ctype(am, at, "[1]", &mut tabs);
                    tabs.push_str("){ ");
                    tabs.push_string(&ds);
                    tabs.push_str("() }[0]");
                }
            }
            tabs.push_str(", __self, sizeof(");
            tabs.push_string(&srcc);
            tabs.push_str("), _Alignof(");
            tabs.push_string(&srcc);
            tabs.push_str("));\n}\n");
        }
        if ok {
            tabs.push_str("const ");
            tabs.push_string(stem);
            tabs.push_str("__vt ");
            tabs.push_string(pair);
            tabs.push_str("__vtbl = { ");
            tabs.push_string(&fslot);
            tabs.push_string(&slots);
            tabs.push_str(" };\n");
            self.dyn_tabs.push_string(&tabs);
            self.dyn_decls.push_str("extern const ");
            self.dyn_decls.push_string(stem);
            self.dyn_decls.push_str("__vt ");
            self.dyn_decls.push_string(pair);
            self.dyn_decls.push_str("__vtbl;\n");
            self.sh_dyt_k.push(h);
            self.sh_dyt_e.push(self.dyn_tabs.len() as u32);
            self.sh_dyt_e2.push(self.dyn_decls.len() as u32);
            self.dyt_own.push(own9);
        }
        return ok;
    }

    // The declared single return type of `fnid` (pool `m`), or TYPE_NONE.
    const fn fn_ret_ty(self: &Self, m: ModuleId, fnid: NodeId) TypeId {
        let a = self.p().module_ast_const(m);
        let rs = unsafe (*a).at_const(fnid).as_data.function.returns;
        if rs.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe (*a).list(rs)[0];
        let tn = unsafe (*a).slot_type_node(r0);
        return unsafe (*a).type_of(tn);
    }

    /// One `--test` wrapper: `void __sc_test_w_<m>_<node>(void *__genv)` constructing the fixture
    /// when the case wants one, calling the case, then tearing the fixture down (user teardown
    /// first, then the type's own free).
    pub fn emit_test_wrapper(
        self: &mut Self,
        tm: ModuleId,
        func: NodeId,
        wants: u8,
        fx_init: NodeId,
        fx_free: NodeId,
        genv_m: ModuleId,
        genv_init: NodeId,
    ) bool {
        self.err = "";
        let mut fname = String::new();
        let tgt = self.mg.method_target(tm, func);
        if !self.mg.fn_sym(tm, func, tgt, &mut fname) {
            return self.fail("test-sym");
        }
        self.out.push_str("void __sc_test_w_");
        self.out.push_u64(tm);
        self.out.push_str("_");
        self.out.push_u64(func);
        self.out.push_str("(void *__genv) {\n  (void)__genv;\n");
        let mut ok = true;
        let mut fxt = TYPE_NONE;
        // The fixture's address: a zero-sized fixture has no storage (its init returns void), so it is the
        // ZST sentinel.
        let mut fxref = String::from_str("&__fx");
        if (wants & 1) != 0 {
            fxt = self.fn_ret_ty(tm, fx_init);
            if fxt == TYPE_NONE {
                ok = self.fail("test-fx");
            }
            let zst = ok && self.mg.is_zst(tm, fxt);
            let mut dl = String::new();
            if zst {
                fxref.clear();
                ok = self.zst_sentinel_ref(tm, fxt, &mut fxref);
            } else if ok {
                ok = self.mg.ctype(tm, fxt, "__fx", &mut dl);
            }
            if ok {
                let mut isym = String::new();
                ok = self.mg.fn_sym(tm, fx_init, self.mg.method_target(tm, fx_init), &mut isym);
                if ok {
                    self.out.push_str("  ");
                    if !zst {
                        self.out.push_string(&dl);
                        self.out.push_str(" = ");
                    }
                    self.out.push_string(&isym);
                    self.out.push_str("();\n");
                }
            }
        }
        if ok {
            self.out.push_str("  ");
            self.out.push_string(&fname);
            self.out.push_str("(");
            if (wants & 1) != 0 {
                self.out.push_string(&fxref);
            }
            if (wants & 2) != 0 {
                if (wants & 1) != 0 {
                    self.out.push_str(", ");
                }
                let gt = self.fn_ret_ty(genv_m, genv_init);
                let mut gc = String::new();
                ok = gt != TYPE_NONE && self.mg.ctype(genv_m, gt, "", &mut gc);
                if ok {
                    self.out.push_str("(const ");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__genv");
                } else {
                    let _ = self.fail("test-genv");
                }
            }
            self.out.push_str(");\n");
        }
        if ok && (wants & 1) != 0 && fx_free != NODE_NONE {
            let mut fsym = String::new();
            ok = self.mg.fn_sym(tm, fx_free, self.mg.method_target(tm, fx_free), &mut fsym);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&fsym);
                self.out.push_str("(");
                self.out.push_string(&fxref);
                self.out.push_str(");\n");
            }
        }
        if ok && (wants & 1) != 0 && self.is_destructible(tm, fxt) {
            let mut fe = String::new();
            ok = self.free_expr(tm, fxt, &mut fe);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&fe);
                self.out.push_str("(");
                self.out.push_string(&fxref);
                self.out.push_str(");\n");
            }
        }
        self.out.push_str("}\n");
        return ok;
    }

    /// The global-env hooks: `__sc_test_genv_init` keeps the env in a static cell; `_free` runs the
    /// user teardown then the type's own free.
    pub fn emit_test_genv(self: &mut Self, gm: ModuleId, ginit: NodeId, gfree: NodeId) bool {
        self.err = "";
        let gt = self.fn_ret_ty(gm, ginit);
        if gt == TYPE_NONE {
            return self.fail("test-genv");
        }
        let mut gdecl = String::new();
        let mut gc = String::new();
        let mut isym = String::new();
        let mut ok = self.mg.ctype(gm, gt, "", &mut gc) && self.mg.fn_sym(
            gm,
            ginit,
            self.mg.method_target(gm, ginit),
            &mut isym,
        );
        // A zero-sized env has no storage (its init returns void): its address is the ZST sentinel.
        let zst = ok && self.mg.is_zst(gm, gt);
        let mut gref = String::new();
        if zst {
            ok = self.zst_sentinel_ref(gm, gt, &mut gref);
        } else if ok {
            ok = self.mg.ctype(gm, gt, "__sc_genv", &mut gdecl);
        }
        if ok {
            self.out.push_str("void *__sc_test_genv_init(void) { ");
            if zst {
                self.out.push_string(&isym);
                self.out.push_str("(); return ");
                self.out.push_string(&gref);
                self.out.push_str("; }\n");
            } else {
                self.out.push_str("static ");
                self.out.push_string(&gdecl);
                self.out.push_str("; __sc_genv = ");
                self.out.push_string(&isym);
                self.out.push_str("(); return &__sc_genv; }\n");
            }
            self.out.push_str("void __sc_test_genv_free(void *__p) {\n  (void)__p;\n");
            if gfree != NODE_NONE {
                let mut fsym = String::new();
                ok = self.mg.fn_sym(gm, gfree, self.mg.method_target(gm, gfree), &mut fsym);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&fsym);
                    self.out.push_str("((");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__p);\n");
                }
            }
            if ok && self.is_destructible(gm, gt) {
                let mut fe = String::new();
                ok = self.free_expr(gm, gt, &mut fe);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&fe);
                    self.out.push_str("((");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__p);\n");
                }
            }
            self.out.push_str("}\n");
        }

        if !ok && self.err.len() == 0 {
            return self.fail("test-genv");
        }
        return ok;
    }

    // One dispatch thunk: `static <ret> <pair>__<name>(void *__self, ...) { [return] <impl>((<srcc> *)__self, ...); }`.
    // Interface thunks number args by source param index (`_a1`...); `dyn fn` thunks from `_a0`.
    // `start` numbers the arguments: the receiver an interface slot takes is argument 0.
    fn dyn_thunk(
        self: &mut Self,
        dm: ModuleId,
        mid: NodeId,
        ps: &Vector<TypeId>,
        rs: &Vector<TypeId>,
        start: u32,
        name: str,
        pair: str,
        srcc: str,
        srm: ModuleId,
        srt: TypeId,
        conf: DefId,
        csfx: str,
        wm: ModuleId,
        want: *const TyInstance,
        tabs: &mut String,
    ) bool {
        let mut ret = String::new();
        let mut rt = TYPE_NONE;
        let mut ok = self.dyn_ret(dm, rs, &mut ret, &mut rt);
        let is_void = ret.as_str() == "void";
        let mut head = String::new();
        let mut hdecl: usize = 0;
        if ok {
            head.push_str("static ");
            head.push_string(&ret);
            head.push_str(" ");
            hdecl = head.len();
            head.push_str(pair);
            head.push_str("__");
            head.push_str(name);
            head.push_str("(void *__self");
            for i in 0..ps.len() {
                if !ok {
                    break;
                }
                if self.mg.is_zst(dm, ps[i]) {
                    // Zero-sized by-value params take no slot (forwarding skips them too).
                    continue;
                }
                head.push_str(", ");
                let mut an = String::from_str("_a");
                an.push_u64(start as u64 + i as u64);
                ok = self.mg.ctype(dm, ps[i], an.as_str(), &mut head);
            }
        }
        let sy = *unsafe (*self.p().module_ast_const(srm)).type_at(srt);
        if ok {
            head.push_str(")");
            ok = self.fn_decl(dm, rt, hdecl - ret.len() - 1, hdecl, &mut head);
        }
        if ok {
            head.push_str(" { ");
            if !is_void {
                head.push_str("return ");
            }
            let mut env = true;
            let sa = self.p().module_ast_const(sy.module);
            if sy.kind == TypeKind::TYPE_FUNCTION && unsafe (*sa).closure_fact(sy.as_data.decl) == null {
                // A function item: its value names this one function, so no env is read.
                ok = self.mg.fn_sym(
                    sy.module,
                    sy.as_data.decl,
                    self.mg.method_target(sy.module, sy.as_data.decl),
                    &mut head,
                );
                head.push_str("(");
                env = false;
            } else if sy.kind == TypeKind::TYPE_FUNCTION {
                let mut cs = String::new();
                self.mg.closure_sym(sy.module, sy.as_data.decl, &mut cs);
                head.push_string(&cs);
                head.push_str("(");
                // A closure without captures has no env: its value names this one function.
                env = unsafe (&*(*self.p().module_ast_const(sy.module)).closure_fact(sy.as_data.decl)).ncaps != 0;
                if env {
                    // The closure's env param is NON-const (the body frees its captures on call).
                    head.push_str("(");
                    head.push_str(srcc);
                    head.push_str(" *)__self");
                }
            } else if mid == NODE_NONE {
                ok = self.fail("dyn-thunk");
            } else {
                ok = self.iface_target_sym(
                    srm,
                    srt,
                    DefId { module: dm, node: mid },
                    conf,
                    csfx,
                    IfTargs { m: dm, at: null, n: 0 },
                    wm,
                    want,
                    &mut head,
                );
                head.push_str("((");
                head.push_str(srcc);
                head.push_str(" *)__self");
            }
            for i in 0..ps.len() {
                if self.mg.is_zst(dm, ps[i]) {
                    continue;
                }
                if env {
                    head.push_str(", ");
                }
                env = true;
                head.push_str("_a");
                head.push_u64(start as u64 + i as u64);
            }
            head.push_str("); }\n");
        }
        if ok {
            tabs.push_string(&head);
        }
        return ok;
    }

    // Structural bind: match declared type `(dm, dt)` against concrete `(am, at)`, binding any
    // generic PARAM OF `gens` it names (refs/pointers peel in lockstep; instances match decls and
    // recurse arguments). Bindings append as (param node, pool, type).
    fn unify_bind(
        self: &mut Self,
        dm: ModuleId,
        dt: TypeId,
        am0: ModuleId,
        at0: TypeId,
        gm: ModuleId,
        gens: NodeList,
        out_p: &mut Vector<NodeId>,
        out_m: &mut Vector<ModuleId>,
        out_t: &mut Vector<TypeId>,
        depth: u32,
    ) {
        if depth > 8 || dt == TYPE_NONE || at0 == TYPE_NONE {
            return;
        }
        let mut am = am0;
        let mut at = at0;
        let _ = self.mg.resolve(am0, at0, &mut am, &mut at);
        let dy = *unsafe (*self.p().module_ast_const(dm)).type_at(dt);
        let ay = *unsafe (*self.p().module_ast_const(am)).type_at(at);
        if dy.kind == TypeKind::TYPE_GENERIC {
            let ga = self.p().module_ast_const(gm);
            for i in 0..gens.len {
                if dy.module == gm && dy.as_data.decl == unsafe (*ga).list(gens)[i as usize] {
                    out_p.push(dy.as_data.decl);
                    out_m.push(am);
                    out_t.push(at);
                    return;
                }
            }
            return;
        }
        if dy.kind == TypeKind::TYPE_REFERENCE || dy.kind == TypeKind::TYPE_POINTER {
            // One-sided peel: a by-ref param matches a VALUE argument (the call spelling adds `&`).
            let mut at2 = at;
            if ay.kind == TypeKind::TYPE_REFERENCE || ay.kind == TypeKind::TYPE_POINTER {
                at2 = ay.as_data.elem;
            }
            self.unify_bind(dm, dy.as_data.elem, am, at2, gm, gens, out_p, out_m, out_t, depth + 1);
            return;
        }
        if dy.kind == ay.kind && dy.arr_like() {
            // A vector, mask or array: its lane or element type, and its length (an array's when
            // both are symbolic).
            if dy.kind != TypeKind::TYPE_MASK {
                self.unify_bind(
                    dm,
                    dy.as_data.arr.elem,
                    am,
                    ay.as_data.arr.elem,
                    gm,
                    gens,
                    out_p,
                    out_m,
                    out_t,
                    depth + 1,
                );
            }
            if dy.is_vec() || dy.arr_sym() && ay.arr_sym() {
                self.unify_bind(
                    dm,
                    dy.as_data.arr.len,
                    am,
                    ay.as_data.arr.len,
                    gm,
                    gens,
                    out_p,
                    out_m,
                    out_t,
                    depth + 1,
                );
            } else if dy.arr_sym() {
                // A concrete array holds its length as a count: a length parameter takes it as a
                // constant of the parameter's type.
                let ly = *unsafe (*self.p().module_ast_const(dm)).type_at(dy.as_data.arr.len);
                if ly.kind == TypeKind::TYPE_GENERIC && ly.module == gm {
                    let bt = self.p().const_param_bt(gm, ly.as_data.decl);
                    let ct = unsafe (*(self.p().module_ast_const(am) as *mut Ast)).const_value(ay.as_data.arr.len, bt);
                    self.unify_bind(dm, dy.as_data.arr.len, am, ct, gm, gens, out_p, out_m, out_t, depth + 1);
                }
            }
            return;
        }
        if dy.kind == TypeKind::TYPE_INSTANCE && ay.kind == TypeKind::TYPE_INSTANCE {
            let dit = *unsafe (*self.p().module_ast_const(dm)).instance(dy.as_data.inst);
            let ait = *unsafe (*self.p().module_ast_const(am)).instance(ay.as_data.inst);
            if dit.module == ait.module && dit.decl == ait.decl {
                let mut k: u8 = 0;
                while k < dit.n && k < ait.n {
                    self.unify_bind(
                        dm,
                        unsafe dit.args[k as usize],
                        am,
                        unsafe ait.args[k as usize],
                        gm,
                        gens,
                        out_p,
                        out_m,
                        out_t,
                        depth + 1,
                    );
                    k += 1;
                }
            }
        }
    }

    // A conversion method WITH its own generics: the receiver instance is the coercion TARGET;
    // the method's params bind by unifying its first declared parameter against the argument.
    // Symbol: `<InstName>__<method>__<bound mangles...>` (the spec rule), demanded accordingly.
    fn conv_sym(self: &mut Self, b: &ir::CoreBody, callee: DefId, arg_ty: TypeId, target_ty: TypeId, dst: &mut String) bool {
        let ca = self.p().module_ast_const(callee.module);
        let fd = unsafe (*ca).at_const(callee.node);
        let tgt = self.mg.method_target(callee.module, callee.node);
        let mut rpm = b.module;
        let rit = self.recv_inst(b, target_ty, tgt, &mut rpm);
        if rit.decl == NODE_NONE {
            return self.fail("conv-recv");
        }
        // Bind the method's own generics from the first declared param vs the argument.
        let gens = fd.as_data.function.generics;
        let ps = fd.as_data.function.params;
        let mut bp = Vector::<NodeId>::new();
        let mut bm = Vector::<ModuleId>::new();
        let mut bt = Vector::<TypeId>::new();
        if ps.len != 0 {
            let p0 = unsafe (*ca).list(ps)[0];
            let mut arm = b.module;
            let mut art = arg_ty;
            self.rty(b, arg_ty, &mut arm, &mut art);
            self.unify_bind(
                callee.module,
                unsafe (*ca).type_of(p0),
                arm,
                art,
                callee.module,
                gens,
                &mut bp,
                &mut bm,
                &mut bt,
                0,
            );
        }
        if bp.len() as u32 < gens.len {
            // Generics the argument does not name bind from the RESULT (`from<const M>() UInt<M>`).
            let rt0 = self.fn_ret_ty(callee.module, callee.node);
            if rt0 != TYPE_NONE {
                let mut tm0 = b.module;
                let mut tt0 = target_ty;
                self.rty(b, target_ty, &mut tm0, &mut tt0);
                self.unify_bind(callee.module, rt0, tm0, tt0, callee.module, gens, &mut bp, &mut bm, &mut bt, 0);
            }
        }
        if bp.len() as u32 != gens.len {
            return self.fail("conv-bind");
        }
        let mut sym = String::new();
        if !self.mg.inst_name(rpm, &rit, &mut sym) {
            return self.fail("conv-inst");
        }
        // The instance body's prototype lives in the method's declaring module.
        self.mg.mark_used(callee.module);
        sym.push_str("__");
        self.mg.ident(callee.module, unsafe (*ca).at_const(fd.as_data.function.name).as_data.name.text, &mut sym);
        let mut sfx = String::new();
        let mut sok = true;
        for i in 0..bp.len() {
            sfx.push_str("__");
            if !self.mg.type_m(bm[i], bt[i], &mut sfx) {
                sok = false;
                break;
            }
        }
        if !sok {
            return self.fail("conv-targ");
        }
        sym.push_string(&sfx);
        if self.collect_demand && !fd.as_data.function.is_extern() && fd.as_data.function.body != NODE_NONE {
            let mut snap = mbe::subs_copy(&self.mg.subs);
            let g0 = snap.len() as u32;
            let ext = self.mg.extend_of(callee.module, callee.node);
            self.bind_recv(&mut snap, callee.module, ext, rpm, &rit);
            for i in 0..bp.len() {
                self.push_bind(&mut snap, callee.module, bp[i], bm[i], bt[i], g0);
            }
            let d9 = Demand { def: callee, sym: sym.clone(), dk: 0, subs: snap, sfx: sfx };
            self.rec_demand(&d9, 0, 0);
            self.demand.push(d9);
        }
        dst.push_string(&sym);
        return true;
    }

    fn const_operand_i64(self: &Self, b: &ir::CoreBody, opid: ir::OperandId, out: &mut i64, depth: u32) bool {
        if depth > 8 || opid == ir::IR_NONE {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
                *out = c.val;
                return true;
            }
            return false;
        }
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len != 0 || *self.sx_inline.at(pl.base as usize) == ir::IR_NONE {
            return false;
        }
        return self.const_rvalue_i64(b, *self.sx_inline.at(pl.base as usize), out, depth + 1);
    }

    fn const_rvalue_i64(self: &Self, b: &ir::CoreBody, rid: ir::RvalueId, out: &mut i64, depth: u32) bool {
        if depth > 8 {
            return false;
        }
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST {
            return self.const_operand_i64(b, rv.a, out, depth + 1);
        }
        if rv.kind == ir::RV_UNARY && rv.b as u8 == tt::TokenType::Bang as u8 {
            let mut a: i64 = 0;
            if self.const_operand_i64(b, rv.a, &mut a, depth + 1) {
                *out = (a == 0) as i64;
                return true;
            }
            return false;
        }
        if rv.kind != ir::RV_BINARY {
            return false;
        }
        let mut a: i64 = 0;
        let mut c: i64 = 0;
        if !self.const_operand_i64(b, rv.a, &mut a, depth + 1) || !self.const_operand_i64(b, rv.b, &mut c, depth + 1) {
            return false;
        }
        let t = rv.c as tt::TokenType;
        if t == tt::TokenType::EqualEqual {
            *out = (a == c) as i64;
        } else if t == tt::TokenType::BangEqual {
            *out = (a != c) as i64;
        } else if t == tt::TokenType::LessThan {
            *out = (a < c) as i64;
        } else if t == tt::TokenType::LessThanEqual {
            *out = (a <= c) as i64;
        } else if t == tt::TokenType::GreaterThan {
            *out = (a > c) as i64;
        } else if t == tt::TokenType::GreaterThanEqual {
            *out = (a >= c) as i64;
        } else if t == tt::TokenType::AmpersandAmpersand {
            *out = (a != 0 && c != 0) as i64;
        } else if t == tt::TokenType::PipePipe {
            *out = (a != 0 || c != 0) as i64;
        } else {
            return false;
        }
        return true;
    }

    fn assert_holds_const(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let mut v: i64 = 0;
        return t.kind == ir::TM_ASSERT && self.const_operand_i64(b, t.a, &mut v, 0) && v != 0;
    }

    // The assert helper for the operand's type: 4 bool, 3 float, 2 unsigned, 1 signed, 0 none.
    fn assert_helper_kind(self: &Self, b: &ir::CoreBody, opid: ir::OperandId) u8 {
        return switch self.int_builtin(b, b.operands.at(opid as usize).ty) {
            BT_BOOL => 4,
            BT_F32 | BT_F64 => 3,
            BT_CHAR | BT_U8 | BT_U16 | BT_U32 | BT_U64 | BT_USIZE => 2,
            BT_I8 | BT_I16 | BT_I32 | BT_I64 | BT_ISIZE => 1,
            _ => 0,
        };
    }

    /// Claim assert-helper `bit` for this emitter: true when it was not yet claimed.
    const fn assert_helpers_claim(self: &mut Self, bit: u8) bool {
        if (self.assert_helpers & bit) != 0u8 {
            return false;
        }
        self.assert_helpers |= bit;
        return true;
    }

    fn ensure_assert_helper(self: &mut Self, kind: u8) {
        let bit = 1u8 << kind;
        if !self.assert_helpers_claim(bit) {
            return;
        }
        if kind == 1 {
            self.aux.push_str(
                "static inline void __sc_assert_i64(int64_t l, int64_t r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %lld\\n  right: %lld\\n  at %s:%llu\\n\", e, (long long)l, (long long)r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 2 {
            self.aux.push_str(
                "static inline void __sc_assert_u64(uint64_t l, uint64_t r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %llu\\n  right: %llu\\n  at %s:%llu\\n\", e, (unsigned long long)l, (unsigned long long)r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 3 {
            self.aux.push_str(
                "static inline void __sc_assert_f64(double l, double r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %g\\n  right: %g\\n  at %s:%llu\\n\", e, l, r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 4 {
            self.aux.push_str(
                "static inline void __sc_assert_bool(bool l, bool r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %s\\n  right: %s\\n  at %s:%llu\\n\", e, l ? \"true\" : \"false\", r ? \"true\" : \"false\", f, n); fflush(stderr); abort(); } }\n",
            );
        }
        self.aux_mark(1u64 | bit as u64 << 1, 0xFFFF);
    }

    // `(Global *)&<sentinel>`, the allocator argument of a fixed-text `Global__alloc` /
    // `Global__dealloc` call: the context needs Global's prototypes.
    fn push_global_arg(self: &mut Self, o: &mut String) {
        let g = self.p().prelude_lookup("Global", true);
        self.mg.mark_used(g.mid);
        self.mg.need_name("Global".hash(), false);
        o.push_str("(Global *)&");
        self.sentinel(1, o);
    }

    // Close one `aux` entry: its shard key, end offset and owner (0xFFFF = shared helper).
    fn aux_mark(self: &mut Self, key: u64, own: ModuleId) {
        self.sh_aux_k.push(key);
        self.sh_aux_e.push(self.aux.len() as u32);
        self.aux_own.push(own);
    }

    /// Record that module `own`'s prototype header needs the definition of C type `name` (see
    /// `hdr_k`): a result carrier its `_ret` typedef names.
    fn hdr_dep(self: &mut Self, own: ModuleId, name: str) {
        self.hdr_k.push(own);
        self.hdr_h.push(name.hash());
    }

    /// Replay one cached `aux` entry (see `aux_mark`): a `_ret` typedef lands as is, a shared
    /// assert helper only when this emitter has not defined it yet.
    pub fn aux_replay(self: &mut Self, key: u64, own: ModuleId, text: str) {
        if key != 0 && !self.assert_helpers_claim((key >> 1) as u8) {
            return;
        }
        self.aux.push_str(text);
        self.aux_mark(key, own);
    }

    fn emit_forwarded_assert(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        t: &ir::Terminator,
        line: u64,
        handled: &mut bool,
    ) bool {
        *handled = false;
        if t.args_len != 4 {
            return true;
        }
        let lo = b.oper_pool[t.args_start as usize];
        let ro = b.oper_pool[(t.args_start + 1) as usize];
        let mut forwarded = false;
        let lop = *b.operands.at(lo as usize);
        if lop.kind == ir::OP_COPY || lop.kind == ir::OP_MOVE {
            let pl = *b.places.at(lop.data as usize);
            forwarded = (pl.proj_len == 0 || pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF) && *self.sx_call_fwd.at(
                pl.base as usize,
            );
        }
        if !forwarded {
            let rop = *b.operands.at(ro as usize);
            if rop.kind == ir::OP_COPY || rop.kind == ir::OP_MOVE {
                let pl = *b.places.at(rop.data as usize);
                forwarded = (pl.proj_len == 0 || pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF) && *self.sx_call_fwd.at(
                    pl.base as usize,
                );
            }
        }
        let kind = self.assert_helper_kind(b, lo);
        if !forwarded || kind == 0 || self.assert_helper_kind(b, ro) != kind {
            return true;
        }
        self.ensure_assert_helper(kind);
        o.push_str("  __sc_assert_");
        o.push_str(
            if kind == 1 {
                "i64";
            } else if kind == 2 {
                "u64";
            } else if kind == 3 {
                "f64";
            } else {
                "bool";
            },
        );
        o.push_str("(");
        if !self.emit_operand(b, lo, o) {
            return false;
        }
        o.push_str(", ");
        if !self.emit_operand(b, ro, o) {
            return false;
        }
        o.push_str(", ");
        o.push_str(mbe::if_s(t.sw_len == 2, "true", "false"));
        o.push_str(", \"");
        let src = self.p().modules.at(b.module as usize).source.as_str();
        let lsp = *b.constants.at(b.operands.at(b.oper_pool[(t.args_start + 2) as usize] as usize).data as usize);
        let rsp = *b.constants.at(b.operands.at(b.oper_pool[(t.args_start + 3) as usize] as usize).data as usize);
        push_assert_src(src.slice(lsp.raw.start as usize, lsp.raw.end as usize), false, o);
        o.push_str(mbe::if_s(t.sw_len == 2, " == ", " != "));
        push_assert_src(src.slice(rsp.raw.start as usize, rsp.raw.end as usize), false, o);
        o.push_str("\", \"");
        push_c_escaped(self.p().modules.at(b.module as usize).file.as_str(), o);
        o.push_str("\", ");
        o.push_u64(line);
        o.push_str(");\n");
        *handled = true;
        return true;
    }

    // Emit the negation of a boolean operand into `dst`. When the operand is an inlined comparison,
    // its operator folds (`!(a == b)` reads as `a != b`), so a failing-assert test spells the
    // relation directly. Equality flips for any type; ordering flips only for non-float operands
    // (a NaN makes `!(x < y)` and `x >= y` differ). Anything else falls back to `!(operand)`.
    fn emit_cond_negated(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            let pl = *b.places.at(op.data as usize);
            if pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE {
                let rv = *b.rvalues.at((*self.sx_inline.at(pl.base as usize)) as usize);
                if rv.kind == ir::RV_BINARY {
                    let mut x = rv.a;
                    let r = self.cmp_fold(b, &rv, &mut x);
                    if r >= 0 {
                        return self.emit_cmp_const(b, x, r == 0, dst);
                    }
                    let mut rm = b.module;
                    let mut rt = TYPE_NONE;
                    let aref = self.bin_op_ty(b, rv.a, &mut rm, &mut rt);
                    if !self.is_str_ty(rm, rt) && !self.op_dispatch_agg(rm, rt) {
                        let yk = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
                        let is_float = yk.kind == TypeKind::TYPE_BUILTIN && (yk.as_data.builtin == BuiltinType::BT_F32 || yk.as_data.builtin == BuiltinType::BT_F64);
                        let t = rv.c as tt::TokenType;
                        let mut fop: str<'static> = "";
                        if t == tt::TokenType::EqualEqual {
                            fop = "!=";
                        } else if t == tt::TokenType::BangEqual {
                            fop = "==";
                        } else if !is_float {
                            if t == tt::TokenType::LessThan {
                                fop = ">=";
                            } else if t == tt::TokenType::GreaterThan {
                                fop = "<=";
                            } else if t == tt::TokenType::LessThanEqual {
                                fop = ">";
                            } else if t == tt::TokenType::GreaterThanEqual {
                                fop = "<";
                            }
                        }
                        if fop.len() != 0 {
                            // no enclosing parentheses: the caller wraps this in `if (..)`, and a
                            // second pair around an equality would trip -Wparentheses-equality.
                            let mut bm = b.module;
                            let mut bt = TYPE_NONE;
                            let bref = self.bin_op_ty(b, rv.b, &mut bm, &mut bt);
                            let pc = self.ptr_order_cast(rm, rt, t);
                            dst.push_str(pc);
                            let mut ok = self.emit_op_d(b, rv.a, aref, dst);
                            dst.push_str(" ");
                            dst.push_str(fop);
                            dst.push_str(" ");
                            dst.push_str(pc);
                            if ok {
                                ok = self.emit_op_d(b, rv.b, bref, dst);
                            }
                            return ok;
                        }
                    }
                }
            }
        }
        dst.push_str("!(");
        let ok = self.emit_operand(b, opid, dst);
        dst.push_str(")");
        return ok;
    }

    // `  left:  <value>` diagnostics for a failed assert_eq/ne, formatted per operand type;
    // unprintable types skip the line rather than fail the emission.
    fn assert_value_line(self: &mut Self, o: &mut String, b: &ir::CoreBody, label: str, opid: ir::OperandId) bool {
        let mut ev = self.sget();
        let ok = self.emit_operand(b, opid, &mut ev);
        if ok {
            self.assert_value_line_i(o, b, label, opid, &ev);
        }
        self.sput(ev);
        return ok;
    }

    fn assert_value_line_i(
        self: &mut Self,
        o: &mut String,
        b: &ir::CoreBody,
        label: str,
        opid: ir::OperandId,
        ev: &String,
    ) {
        let k = self.assert_helper_kind(b, opid);
        if k != 0 {
            o.push_str("fprintf(stderr, \"  ");
            o.push_str(label);
            o.push_str(
                switch k {
                    1 => " %lld\\n\", (long long)(",
                    2 => " %llu\\n\", (unsigned long long)(",
                    3 => " %g\\n\", (double)(",
                    _ => " %s\\n\", (",
                },
            );
            o.push_string(ev);
            o.push_str(mbe::if_s(k == 4, ") ? \"true\" : \"false\"); ", ")); "));
            return;
        }
        let y = self.rty_y(b, b.operands.at(opid as usize).ty);
        if y.kind == TypeKind::TYPE_STRUCT {
            let nm = self.agg_name(y.module, y.as_data.decl);
            if nm == "str" {
                o.push_str("fprintf(stderr, \"  ");
                o.push_str(label);
                o.push_str(" \\\"%.*s\\\"\\n\", (int)(");
                o.push_string(ev);
                o.push_str(").len, (const char *)(");
                o.push_string(ev);
                o.push_str(").ptr); ");
                return;
            }
        }
    }

    // Preemption safepoints print only when the package uses the coroutine runtime, and never
    // inside std::parallel itself (its loops hold internal locks across iterations).
    fn safepoints_on(self: &mut Self, m: ModuleId) bool {
        if self.uses_tasks == 0 {
            self.uses_tasks = 1;
            if self.p().find("std::parallel::runtime") >= 0 {
                self.uses_tasks = 2;
            }
        }
        if self.uses_tasks != 2 {
            return false;
        }
        if m as usize < self.p().modules.len() {
            return !self.p().modules.at(m as usize).path.as_str().starts_with("std::parallel");
        }
        return true;
    }

    // Does body `b`, under the current substitutions, print its preemption ticks? A std body whose
    // user code runs only through bound dispatch (`Package::co_inst_on`) prints them only when a
    // binding names a type whose methods can be user code; with std types alone its loops are bounded
    // by their inputs.
    fn ticks_on(self: &mut Self, b: &ir::CoreBody) bool {
        if !self.safepoints_on(b.module) {
            return false;
        }
        if !b.inst_ticks {
            return true;
        }
        let ow = b.owner;
        // The body's own parameters are declared in its module; other frames belong to the
        // instances it is emitted within.
        for i in 0..self.mg.subs.len() {
            let sb = *self.mg.subs.at(i);
            if sb.pm != ow.module {
                continue;
            }
            let mut rm = sb.am;
            let mut rt = sb.at;
            if !self.mg.resolve(sb.am, sb.at, &mut rm, &mut rt) || self.user_type(rm, rt, 0) {
                return true;
            }
        }
        return false;
    }

    // Can a method of type `(m, t)` be user code: does it name, at any depth, a type declared
    // outside std, a function or closure, a `dyn` value, or an unbound parameter?
    fn user_type(self: &Self, m: ModuleId, t: TypeId, depth: u32) bool {
        if depth > 16 || t == TYPE_NONE {
            return true;
        }
        let a = unsafe &*self.p().module_ast_const(m);
        let y = *a.type_at(t);
        let k = y.kind;
        if k == TypeKind::TYPE_BUILTIN || k == TypeKind::TYPE_NEVER || k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
            return self.user_type(m, y.as_data.elem, depth + 1);
        }
        if k == TypeKind::TYPE_ARRAY {
            return self.user_type(m, y.as_data.arr.elem, depth + 1);
        }
        if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_ENUM {
            return !self.std_module(y.module);
        }
        if k == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            if !self.std_module(it.module) {
                return true;
            }
            for i in 0..it.n {
                if self.user_type(m, unsafe it.args[i as usize], depth + 1) {
                    return true;
                }
            }
            return false;
        }
        return true;
    }

    const fn std_module(self: &Self, m: ModuleId) bool {
        let pth = self.p().modules.at(m as usize).path.as_str();
        return pth.starts_with("std::") || pth.starts_with("__std::");
    }

    // A `@blocking` extern function (non-variadic): calls route through a pool wrapper.
    fn blocking_callee(self: &Self, d: DefId) bool {
        let a = unsafe &*self.p().module_ast_const(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION || a.at_const(d.node).as_data.function.is_variadic() {
            return false;
        }
        return a.attr_of(d.node, AttrKind::ATTR_BLOCKING) != null;
    }

    // env typedef + pool trampoline + wrapper for one `@blocking` callee (emitted once, into the
    // shared instance TU; call sites everywhere link against the wrapper).
    fn blk_wrapper(self: &mut Self, d: DefId) bool {
        if self.mg.rec_on {
            let mut ev = mbe::RecEv::blank(mbe::RK_BLK);
            ev.a = d.module;
            ev.b = d.node;
            self.mg.rec.push(ev);
        }
        let key = d.module as u64 << 32 | d.node as u64;
        let hit = self.blk_seen.contains(&key);
        if hit {
            return true;
        }
        self.blk_seen.insert(key);
        // The wrapper lands in the callee module's instance shard: spell it under that context.
        let ctx0 = self.mg.mark_ctx;
        self.mg.mark_ctx = mbe::CTX_INST | d.module as i64;
        let ok = self.blk_wrapper_defs(d, key);
        self.mg.mark_ctx = ctx0;
        return ok;
    }

    fn blk_wrapper_defs(self: &mut Self, d: DefId, key: u64) bool {
        let a = self.p().module_ast_const(d.module);
        let f = unsafe (*a).at_const(d.node).as_data.function;
        let mut nm = String::new();
        self.mg.c_ident(d.module, unsafe (*a).at_const(f.name).as_data.name.text, &mut nm);
        let mut rt = TYPE_NONE;
        if f.returns.len == 1 {
            rt = unsafe (*a).type_of(unsafe (*a).list(f.returns)[0]);
        }
        let mut rty = String::new();
        let mut is_void = rt == TYPE_NONE;
        if !is_void {
            let y = *unsafe (*a).type_at(rt);
            is_void = y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
        }
        if is_void {
            rty.push_str("void");
        } else if !self.mg.ctype(d.module, rt, "", &mut rty) {
            return false;
        }
        let np = f.params.len;
        let mut env = String::from_str("typedef struct { ");
        let mut wrap_params = String::new();
        for k in 0..np {
            let pid = unsafe (*a).list(f.params)[k as usize];
            let pt = unsafe (*a).type_of(unsafe (*a).at_const(pid).as_data.parameter.ty);
            let mut an = String::from_str("a");
            an.push_u64(k);
            if !self.mg.ctype(d.module, pt, an.as_str(), &mut env) {
                return false;
            }
            env.push_str("; ");
            if k != 0 {
                wrap_params.push_str(", ");
            }
            if !self.mg.ctype(d.module, pt, an.as_str(), &mut wrap_params) {
                return false;
            }
        }
        if np == 0 {
            wrap_params.push_str("void");
        }
        if !is_void {
            if !self.mg.ctype(d.module, rt, "r", &mut env) {
                return false;
            }
            env.push_str("; ");
        }
        env.push_str("} __sc_blk_");
        env.push_string(&nm);
        env.push_str("_env;\n");
        self.blk_defs.push_string(&env);
        self.blk_defs.push_str("static void __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_run(void *__e) { __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env *__v = (__sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env *)__e; ");
        // C declares the extern's pointers to arrays of aggregates as pointers to the arrays, the
        // wrapper's as wrapper pointers (`Mangler::ptr_wraps`): those values convert.
        if !is_void {
            self.blk_defs.push_str("__v->r = ");
            if self.wrap_ptr_in(d.module, rt) {
                self.blk_defs.push_str("(void *)");
            }
        }
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("(");
        for k in 0..np {
            if k != 0 {
                self.blk_defs.push_str(", ");
            }
            let pid = unsafe (*a).list(f.params)[k as usize];
            if self.wrap_ptr_in(d.module, unsafe (*a).type_of(unsafe (*a).at_const(pid).as_data.parameter.ty)) {
                self.blk_defs.push_str("(void *)");
            }
            self.blk_defs.push_str("__v->a");
            self.blk_defs.push_u64(k);
        }
        self.blk_defs.push_str("); }\n");
        let bm = self.blk_defs.len();
        self.blk_defs.push_string(&rty);
        self.blk_defs.push_str(" __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("(");
        self.blk_defs.push_string(&wrap_params);
        self.blk_defs.push_str(")");
        let mut bd = replace(&mut self.blk_defs, String::new());
        let okb = self.fn_decl(d.module, rt, bm, bm + rty.len() + 1, &mut bd);
        self.blk_defs = bd;
        if !okb {
            return false;
        }
        self.blk_defs.push_str(" { __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env __v; ");
        for k in 0..np {
            self.blk_defs.push_str("__v.a");
            self.blk_defs.push_u64(k);
            self.blk_defs.push_str(" = a");
            self.blk_defs.push_u64(k);
            self.blk_defs.push_str("; ");
        }
        self.blk_defs.push_str("__sc_blocking_run(__sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_run, &__v); ");
        if !is_void {
            self.blk_defs.push_str("return __v.r; ");
        }
        self.blk_defs.push_str("}\n");
        // Cross-TU call sites see the wrapper through the shared protos.
        let pm = self.blk_protos.len();
        self.blk_protos.push_string(&rty);
        self.blk_protos.push_str(" __sc_blk_");
        self.blk_protos.push_string(&nm);
        self.blk_protos.push_str("(");
        self.blk_protos.push_string(&wrap_params);
        self.blk_protos.push_str(")");
        let mut ep = replace(&mut self.blk_protos, String::new());
        let okp = self.fn_decl(d.module, rt, pm, pm + rty.len() + 1, &mut ep);
        self.blk_protos = ep;
        if !okp {
            return false;
        }
        self.blk_protos.push_str(";\n");
        self.sh_blk_k.push(key);
        self.sh_blk_e.push(self.blk_defs.len() as u32);
        self.sh_blk_e2.push(self.blk_protos.len() as u32);
        return true;
    }

    // The memo keys carry the emission context (the cross-TU edge is per context), so entries
    // of every instance-shard context coexist through the drain; a module context starts empty.
    fn sym_memo_ctx_check(self: &mut Self) {
        if self.sym_memo_ctx != self.mg.mark_ctx {
            if self.sym_memo_ctx < mbe::CTX_INST || self.mg.mark_ctx < mbe::CTX_INST {
                self.sym_memo.clear();
                self.sym_pool.clear();
                self.sym_off.clear();
                self.sym_len.clear();
                self.sym_hash.clear();
            }
            self.sym_memo_ctx = self.mg.mark_ctx;
        }
    }

    // The memo key of `k` under the current context.
    const fn sym_mk(self: &Self, k: u64) u64 {
        return k ^ ((self.mg.mark_ctx + 2) as u64).wrapping_mul(0x9E3779B97F4A7C15u64);
    }

    // The reserved-identifier hash of a plain concrete call's memoized symbol, or 0 when the memo
    // holds none for `callee` (a spelling is then needed).
    fn sym_memo_hash(self: &mut Self, callee: DefId) u64 {
        self.sym_memo_ctx_check();
        let mk = self.sym_mk(skey_mix(0, callee.module as u64 << 32 | callee.node as u64));
        return switch self.sym_memo.get(&mk) {
            Some(s) => self.sym_hash[(*s) as usize],
            None => 0u64,
        };
    }

    // FNV-1a fold of the active substitution env into `h`, then of receiver instance `rit` (pool
    // `rpm`) when `is_minst`: the part every demand fingerprint shares.
    fn env_fp(self: &Self, h0: u64, rpm: ModuleId, rit: &TyInstance, is_minst: bool) u64 {
        let mut h = h0;
        for k in 0..self.mg.subs.len() {
            let sb = *self.mg.subs.at(k);
            h = (h ^ (sb.pm as u64 << 32 | sb.pnode as u64)).wrapping_mul(1099511628211u64);
            h = (h ^ (sb.am as u64 << 32 | sb.at as u64)).wrapping_mul(1099511628211u64);
            h = (h ^ sb.lim as u64).wrapping_mul(1099511628211u64);
        }
        if is_minst {
            h = (h ^ (rpm as u64 << 32 | rit.module as u64)).wrapping_mul(1099511628211u64);
            h = (h ^ (rit.decl as u64 << 32 | rit.n as u64)).wrapping_mul(1099511628211u64);
            for k in 0..rit.n {
                h = (h ^ (unsafe rit.args[k as usize]) as u64).wrapping_mul(1099511628211u64);
            }
        }
        return h;
    }

    // A generic call's fingerprint: `env_fp` plus the call's bound targs (pool `b.module`).
    fn call_fp(
        self: &Self,
        h0: u64,
        b: &ir::CoreBody,
        rpm: ModuleId,
        rit: &TyInstance,
        is_minst: bool,
        targs_start: u32,
        targs_len: u32,
        recv_targs: bool,
    ) u64 {
        let mut h = self.env_fp(h0, rpm, rit, is_minst);
        h = (h ^ (b.module as u64 << 32 | targs_len as u64)).wrapping_mul(1099511628211u64);
        for k in 0..targs_len {
            h = (h ^ b.targ_pool[(targs_start + k) as usize] as u64).wrapping_mul(1099511628211u64);
        }
        if recv_targs {
            h = (h ^ 1).wrapping_mul(1099511628211u64);
        }
        return h;
    }

    // The callee's C symbol: the frozen fn symbol plus `__<targ>` per bound generic argument
    // (free-fn specializations and generic methods share that composition). `iface`: a bound
    // call's conformance (`Terminator.iface`), TYPE_NONE otherwise.
    fn callee_sym(
        self: &mut Self,
        b: &ir::CoreBody,
        callee: DefId,
        targs_start: u32,
        targs_len: u32,
        recv_ty: TypeId,
        dest_ty: TypeId,
        iface: TypeId,
        impl_ty: TypeId,
        dst: &mut String,
    ) bool {
        let sm = self.pr.start();
        let mut sym = self.sget();
        let r = self.callee_sym_i(b, callee, targs_start, targs_len, recv_ty, dest_ty, iface, impl_ty, &mut sym, dst);
        self.sput(sym);
        self.pr.stop(prb::P_SYM, sm);
        return r;
    }

    // callee_sym for call terminator `t`: the receiver type is the first argument's, the destination
    // type the single destination's (when `with_dest`).
    fn term_callee_sym(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator, with_dest: bool, dst: &mut String) bool {
        let mut recv_ty = TYPE_NONE;
        if t.args_len > 0 {
            recv_ty = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
        }
        let mut dest_ty = TYPE_NONE;
        if with_dest && t.dests_len == 1 {
            dest_ty = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
            if self.extern_fn(t.callee) && self.wrap_ptr(b, dest_ty) {
                // C declares the result a pointer to the array itself: convert the value.
                dst.push_str("(void *)");
            }
        }
        return self.callee_sym(b, t.callee, t.targs_start, t.targs_len, recv_ty, dest_ty, t.iface, t.recv, dst);
    }

    // Whether `d` is an `extern "C"` function: C declares its pointers to arrays of aggregates as
    // pointers to the arrays, where the emitted C holds wrapper pointers (`Mangler::ptr_wraps`).
    const fn extern_fn(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE {
            return false;
        }
        let fnn = unsafe (*self.p().module_ast_const(d.module)).at_const(d.node);
        return fnn.kind == NodeKind::NODE_FUNCTION && fnn.as_data.function.is_extern();
    }

    // Whether `(b.module, t)` is a pointer or reference to an array its C spelling wraps.
    fn wrap_ptr(self: &mut Self, b: &ir::CoreBody, t: TypeId) bool {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        return self.wrap_ptr_in(rm, rt);
    }

    // `wrap_ptr` of resolved `(m, t)`.
    fn wrap_ptr_in(self: &mut Self, m: ModuleId, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = *unsafe (*self.p().module_ast_const(m)).type_at(t);
        return (y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE) && self.mg.ptr_wraps(
            m,
            y.as_data.elem,
        );
    }

    // Intern `sym` under `mk` for the current mark_ctx (see sym_memo_ctx_check).
    fn sym_memo_put(self: &mut Self, mk: u64, sym: &String) {
        self.sym_memo.insert(mk, self.sym_off.len() as u64);
        self.sym_off.push(self.sym_pool.len() as u32);
        self.sym_len.push(sym.len() as u32);
        self.sym_hash.push(sym.as_str().hash());
        self.sym_pool.push_string(sym);
    }

    // The memoized spelling under `mk`, appended to `dst`; false when none is interned.
    fn sym_memo_get(self: &Self, mk: u64, dst: &mut String) bool {
        return switch self.sym_memo.get(&mk) {
            Some(s) => {
                let off = self.sym_off[(*s) as usize] as usize;
                let ln = self.sym_len[(*s) as usize] as usize;
                dst.push_str(self.sym_pool.as_str().slice(off, off + ln));
                true;
            },
            None => false,
        };
    }

    // Whether interface member `f`'s first parameter has type `Self`, behind references or pointers.
    fn self_param0(self: &Self, f: DefId) bool {
        let ca0 = self.p().module_ast_const(f.module);
        let ps0 = unsafe (*ca0).at_const(f.node).as_data.function.params;
        if ps0.len == 0 {
            return false;
        }
        let p0 = unsafe (*ca0).at_const(unsafe (*ca0).list(ps0)[0]);
        if p0.kind != NodeKind::NODE_PARAMETER || p0.as_data.parameter.ty == NODE_NONE {
            return false;
        }
        let mut t = unsafe (*ca0).type_of(p0.as_data.parameter.ty);
        for _ in 0..8 {
            if t == TYPE_NONE {
                return false;
            }
            let y = *unsafe (*ca0).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                return y.kind == TypeKind::TYPE_GENERIC && unsafe (*ca0).at_const(y.as_data.decl).kind == NodeKind::NODE_INTERFACE;
            }
            t = y.as_data.elem;
        }
        return false;
    }

    // Whether function `f`'s first parameter is `self` (a method, not an associated function).
    const fn self_first(self: &Self, f: DefId) bool {
        let ca0 = self.p().module_ast_const(f.module);
        let ps0 = unsafe (*ca0).at_const(f.node).as_data.function.params;
        if ps0.len == 0 {
            return false;
        }
        let p0 = unsafe (*ca0).list(ps0)[0];
        let nm0 = unsafe (*ca0).at_const(unsafe (*ca0).at_const(p0).as_data.parameter.name).as_data.name.text;
        let src0 = self.p().modules.at(f.module as usize).source.as_str();
        return src0.slice(nm0.start as usize, nm0.end as usize) == "self";
    }

    fn callee_sym_i(
        self: &mut Self,
        b: &ir::CoreBody,
        callee: DefId,
        targs_start: u32,
        targs_len: u32,
        recv_ty: TypeId,
        dest_ty: TypeId,
        iface: TypeId,
        impl_ty: TypeId,
        sym: &mut String,
        dst: &mut String,
    ) bool {
        let mut ok = true;
        // freshness: `last_method_def` must reflect THIS call's resolution (arg emission reads it).
        self.mg.last_method_def = DefId { module: 0, node: NODE_NONE };
        // `@blocking`: the call goes to the generated wrapper, which hands the work to the
        // blocking pool and parks this coroutine rather than holding a worker thread.
        if callee.node != NODE_NONE && self.blocking_callee(callee) {
            if !self.blk_wrapper(callee) {
                return self.fail("blocking-wrap");
            }
            let ba = self.p().module_ast_const(callee.module);
            dst.push_str("__sc_blk_");
            self.mg.c_ident(
                callee.module,
                unsafe (*ba).at_const(unsafe (*ba).at_const(callee.node).as_data.function.name).as_data.name.text,
                dst,
            );
            return true;
        }
        // An interface member with a DEFAULT body emits once per conforming type:
        // `<ifacepfx><Target>__<method>` for concrete receivers, `<InstName>__<method>` for instances.
        if self.mg.in_interface(callee.module, callee.node) != NODE_NONE {
            let mut rm6 = b.module;
            let mut rt6 = recv_ty;
            let mut got = false;
            // An associated function called through a type parameter names its implementor by the
            // parameter (`Terminator.recv`).
            if impl_ty != TYPE_NONE {
                self.rty(b, impl_ty, &mut rm6, &mut rt6);
                let k6 = unsafe (*self.p().module_ast_const(rm6)).type_at(rt6).kind;
                got = k6 == TypeKind::TYPE_STRUCT || k6 == TypeKind::TYPE_ENUM || k6 == TypeKind::TYPE_INSTANCE || k6 == TypeKind::TYPE_BUILTIN || k6 == TypeKind::TYPE_SIMD || k6 == TypeKind::TYPE_MASK;
            }
            // The first argument names the implementor only when its parameter is `Self` (behind
            // references or pointers): an associated function's other first argument
            // (`T::from(x)`) is an unrelated value, and its `Self` result names the implementor.
            if !got && recv_ty != TYPE_NONE && self.self_param0(callee) {
                self.rty(b, recv_ty, &mut rm6, &mut rt6);
                self.peel_refs(&mut rm6, &mut rt6);
                let k6 = unsafe (*self.p().module_ast_const(rm6)).type_at(rt6).kind;
                got = k6 == TypeKind::TYPE_STRUCT || k6 == TypeKind::TYPE_ENUM || k6 == TypeKind::TYPE_INSTANCE || k6 == TypeKind::TYPE_BUILTIN || k6 == TypeKind::TYPE_SIMD || k6 == TypeKind::TYPE_MASK;
            }
            if !got && dest_ty != TYPE_NONE {
                self.rty(b, dest_ty, &mut rm6, &mut rt6);
                let k6 = unsafe (*self.p().module_ast_const(rm6)).type_at(rt6).kind;
                got = k6 == TypeKind::TYPE_STRUCT || k6 == TypeKind::TYPE_ENUM || k6 == TypeKind::TYPE_INSTANCE || k6 == TypeKind::TYPE_BUILTIN || k6 == TypeKind::TYPE_SIMD || k6 == TypeKind::TYPE_MASK;
            }
            if !got {
                return self.fail("iface-default-recv");
            }
            // A generic interface method's own arguments (the trailing ones of the call's) bind the
            // method the call dispatches to by position.
            let own = unsafe (*self.p().module_ast_const(callee.module)).at_const(callee.node).as_data.function.generics.len;
            let tn = pick(own < targs_len, own, targs_len);
            let tat: *const TypeId = if tn != 0 {
                &b.targ_pool[(targs_start + targs_len - tn) as usize];
            } else {
                null;
            };
            let tg = IfTargs { m: b.module, at: tat, n: tn };
            if iface == TYPE_NONE {
                return self.iface_target_sym(
                    rm6,
                    rt6,
                    callee,
                    DefId { module: 0, node: NODE_NONE },
                    "",
                    tg,
                    rm6,
                    null,
                    dst,
                );
            }
            // A bound call on a generic interface: the conformance with the bound's arguments,
            // resolved under this instance (`conf_for_args`), and its default bodies' suffix.
            let dy = *unsafe (*self.p().module_ast_const(b.module)).type_at(iface);
            let iit = *unsafe (*self.p().module_ast_const(b.module)).instance(dy.as_data.inst);
            let conf = self.conf_for_args(rm6, rt6, b.module, &iit);
            let mut csfx = self.sget();
            let mut ok6 = conf.node == NODE_NONE || self.mg.dyn_stem(b.module, &dy, &mut csfx);
            if !ok6 {
                ok6 = self.fail("dyn-stem");
            } else {
                ok6 = self.iface_target_sym(rm6, rt6, callee, conf, csfx.as_str(), tg, b.module, &iit, dst);
            }
            self.sput(csfx);
            return ok6;
        }
        // A keyed extend's method (`ext_keyed`): the call's arguments are the extend's, then the
        // method's own, and spell the instance as a generic function's do.
        let keyed = self.mg.in_keyed_extend(callee.module, callee.node);
        let is_minst = self.mg.in_generic_extend(callee.module, callee.node) && !keyed;
        let mut rit = TyInstance { decl: NODE_NONE };
        let mut rpm = b.module; // the pool the receiver instance (and its args) live in
        let mut recv_targs = false; // the call's bound args NAME the receiver (turbofish assoc fn)
        if is_minst {
            // A generic extend's method emits per receiver instance: `<InstName>__<method>`.
            let tgt = self.mg.method_target(callee.module, callee.node);
            // arg0 spells the receiver only for methods: a static assoc fn's first argument is an
            // unrelated value (`convert(&narrow)` targets the WIDE instance, named by the dest).
            if self.self_first(callee) {
                rit = self.recv_inst(b, recv_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE && impl_ty != TYPE_NONE {
                // `Type::<Args>::f::<U>()`: the qualifying instance (`Terminator.recv`) names the
                // receiver, and the call's bound args are the function's own.
                rit = self.recv_inst(b, impl_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE {
                rit = self.recv_inst(b, dest_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE && targs_len != 0 && tgt.node != NODE_NONE {
                // `Type::<Args>::assoc()`: no receiver value or typed dest; the checker's bound
                // args ARE the target's generic arguments (inst_name resolves each through the env).
                let tda = self.p().module_ast_const(tgt.module);
                let tk9 = unsafe (*tda).at_const(tgt.node).kind;
                if (tk9 == NodeKind::NODE_STRUCT || tk9 == NodeKind::NODE_ENUM) && unsafe (*tda).at_const(tgt.node).as_data.aggregate.generics.len == targs_len && targs_len <= 8 {
                    rit.module = tgt.module;
                    rit.decl = tgt.node;
                    rit.n = targs_len as u8;
                    for k9 in 0..targs_len {
                        unsafe rit.args[k9 as usize] = b.targ_pool[(targs_start + k9) as usize];
                    }
                    rpm = b.module;
                    recv_targs = true;
                }
            }
            if rit.decl == NODE_NONE && tgt.node != NODE_NONE {
                // Inside a generic-extend instance, `Type::<OwnParams>::assoc()` names the
                // CURRENT receiver: every target generic is bound in the active env (the demand
                // snapshot keys struct params by (target module, param node)).
                let tda = self.p().module_ast_const(tgt.module);
                let tk9 = unsafe (*tda).at_const(tgt.node).kind;
                if tk9 == NodeKind::NODE_STRUCT || tk9 == NodeKind::NODE_ENUM {
                    let gs9 = unsafe (*tda).at_const(tgt.node).as_data.aggregate.generics;
                    if gs9.len != 0 && gs9.len <= 8 {
                        let mut all9 = true;
                        let mut pool9: ModuleId = 0;
                        let mut nb9: u32 = 0;
                        for g9 in 0..gs9.len {
                            let pn9 = unsafe (*tda).list(gs9)[g9 as usize];
                            let mut hit9 = false;
                            let mut i9 = self.mg.subs.len();
                            while i9 > 0 {
                                i9 -= 1;
                                let sb9 = *self.mg.subs.at(i9);
                                if sb9.pm == tgt.module && sb9.pnode == pn9 {
                                    if nb9 == 0 {
                                        pool9 = sb9.am;
                                    }
                                    if sb9.am == pool9 {
                                        unsafe rit.args[nb9 as usize] = sb9.at;
                                        nb9 += 1;
                                        hit9 = true;
                                    }
                                    break;
                                }
                            }
                            if !hit9 {
                                all9 = false;
                                break;
                            }
                        }
                        if all9 && nb9 == gs9.len {
                            rit.module = tgt.module;
                            rit.decl = tgt.node;
                            rit.n = nb9 as u8;
                            rpm = pool9;
                            recv_targs = targs_len == 0 || recv_targs;
                        }
                    }
                }
            }
            if rit.decl == NODE_NONE {
                return self.fail("method-inst");
            }
        } else if targs_len == 0 {
            // Plain concrete call: no targ suffix, no demand record; the symbol depends
            // only on the declaration (and mark_ctx, for the cross-TU edge), so memoize.
            self.sym_memo_ctx_check();
            let mk = self.sym_mk(skey_mix(0, callee.module as u64 << 32 | callee.node as u64));
            if self.sym_memo_get(mk, dst) {
                return true;
            }
            let tgt0 = self.mg.method_target(callee.module, callee.node);
            if !self.mg.fn_sym(callee.module, callee.node, tgt0, sym) {
                return self.fail("callee-sym");
            }
            self.sym_memo_put(mk, sym);
            dst.push_string(sym);
            return true;
        }
        // A generic call's symbol is a pure function of the callee, the receiver instance, the
        // bound targs and the active env: the same fingerprint the demand dedup keys on, minus
        // the spelling itself, interns it (a first spelling records its demand and cross-TU
        // edges; the journal mode replays every attempt, so it spells each time).
        let mut mk1: u64 = 0;
        let memo9 = !self.mg.rec_on && self.collect_demand;
        if memo9 {
            let dk0 = self.call_fp(def_fp(callee), b, rpm, &rit, is_minst, targs_start, targs_len, recv_targs);
            self.sym_memo_ctx_check();
            mk1 = self.sym_mk(skey_mix(1, dk0));
            if self.sym_memo_get(mk1, dst) {
                return true;
            }
        }
        if is_minst {
            if !self.mg.inst_name(rpm, &rit, sym) {
                ok = self.fail("callee-inst");
            }
            // The instance body's prototype lives in the method's declaring module.
            self.mg.mark_used(callee.module);
            if ok {
                sym.push_str("__");
                let ca = self.p().module_ast_const(callee.module);
                self.mg.ident(
                    callee.module,
                    unsafe (*ca).at_const(unsafe (*ca).at_const(callee.node).as_data.function.name).as_data.name.text,
                    sym,
                );
            }
        } else if keyed {
            if !self.mg.keyed_sym(callee.module, callee.node, sym) {
                ok = self.fail("callee-sym");
            }
        } else {
            let tgt = self.mg.method_target(callee.module, callee.node);
            if !self.mg.fn_sym(callee.module, callee.node, tgt, sym) {
                ok = self.fail("callee-sym");
            }
        }
        if !recv_targs {
            for k in 0..targs_len {
                if !ok {
                    break;
                }
                sym.push_str("__");
                if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k) as usize], sym) {
                    ok = self.fail("callee-targ");
                }
            }
        }
        if ok && memo9 {
            self.sym_memo_put(mk1, sym);
        }
        if ok && self.collect_demand && (is_minst || targs_len != 0) {
            let ca = self.p().module_ast_const(callee.module);
            let fd = unsafe (*ca).at_const(callee.node);
            if fd.kind == NodeKind::NODE_FUNCTION && !fd.as_data.function.is_extern() && fd.as_data.function.body != NODE_NONE {
                // fingerprint of what the snapshot + suffix WOULD hold (env, receiver, targs):
                // duplicates skip the clone/snapshot entirely.
                let dk9 = self.call_fp(sym.as_str().hash(), b, rpm, &rit, is_minst, targs_start, targs_len, recv_targs);
                let fresh9 = !self.demand_seen.contains(&dk9);
                if !fresh9 && !self.mg.rec_on {
                    if ok {
                        dst.push_string(sym);
                    }
                    return ok;
                }
                if fresh9 {
                    self.demand_seen.insert(dk9);
                }
                let mut snap = mbe::subs_copy(&self.mg.subs);
                let g0 = snap.len() as u32;
                if is_minst {
                    let ext = self.mg.extend_of(callee.module, callee.node);
                    self.bind_recv(&mut snap, callee.module, ext, rpm, &rit);
                }
                let mut gskip: u32 = 0;
                if keyed {
                    let xg = unsafe (*ca).at_const(self.mg.extend_of(callee.module, callee.node)).as_data.extend_def.generics;
                    while gskip < xg.len && gskip < targs_len {
                        self.push_bind(
                            &mut snap,
                            callee.module,
                            unsafe (*ca).list(xg)[gskip as usize],
                            b.module,
                            b.targ_pool[(targs_start + gskip) as usize],
                            g0,
                        );
                        gskip += 1;
                    }
                }
                let gens = fd.as_data.function.generics;
                let mut gi2: u32 = 0;
                while !recv_targs && gi2 < gens.len && gskip + gi2 < targs_len {
                    self.push_bind(
                        &mut snap,
                        callee.module,
                        unsafe (*ca).list(gens)[gi2 as usize],
                        b.module,
                        b.targ_pool[(targs_start + gskip + gi2) as usize],
                        g0,
                    );
                    gi2 += 1;
                }
                let mut sfx = String::new();
                let mut sok = true;
                if is_minst {
                    sok = self.mg.args_m(rpm, &rit, rit.n, &mut sfx);
                } else {
                    for k2 in 0..targs_len {
                        sfx.push_str("__");
                        if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k2) as usize], &mut sfx) {
                            sok = false;
                            break;
                        }
                    }
                }
                if sok {
                    let d9 = Demand { def: callee, sym: sym.clone(), dk: dk9, subs: snap, sfx: sfx };
                    self.rec_demand(&d9, dk9, 1);
                    if fresh9 {
                        self.demand.push(d9);
                    }
                }
            }
        }
        if ok {
            dst.push_string(sym);
        }
        return ok;
    }

    // A fixed array flowing into a slice-typed destination wraps `{ arr, N }` (the C array decays).
    fn arr_slice_wrap(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, want: TypeId, dst: &mut String) bool {
        let opP = *b.operands.at(opid as usize);
        if opP.kind != ir::OP_COPY && opP.kind != ir::OP_MOVE {
            return false;
        }
        let n = self.arr_n(b, opP.ty);
        let alen = if n >= 0 {
            n;
        } else {
            self.place_c_arr_len(b, opP.data);
        };
        if alen < 0 {
            return false;
        }
        let mut rm = b.module;
        let mut rt = want;
        self.rty(b, want, &mut rm, &mut rt);
        let yw = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if yw.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *unsafe (*self.p().module_ast_const(rm)).instance(yw.as_data.inst);
        let nmi = self.agg_name(it.module, it.decl);
        if nmi != "Slice" && nmi != "SliceMut" {
            return false;
        }
        let mk = dst.len();
        dst.push_str("(");
        if !self.mg.ctype(rm, rt, "", dst) {
            dst.truncate(mk);
            return false;
        }
        dst.push_str("){ .ptr = ");
        // A zero-length array has no element to point at: the view points at the aligned sentinel,
        // like a reference to a zero-sized value. A view of arrays of aggregates holds a pointer
        // to their wrapper struct (`Mangler::ptr_wraps`): the decayed array pointer converts.
        let mut ok = true;
        if alen == 0 {
            let mut am = b.module;
            let mut at = opP.ty;
            self.rty(b, opP.ty, &mut am, &mut at);
            ok = self.zst_sentinel_ref(am, at, dst);
        } else if self.mg.ptr_wraps(rm, it.args[0]) {
            dst.push_str("(void *)");
            ok = self.emit_operand(b, opid, dst);
        } else {
            ok = self.emit_operand(b, opid, dst);
        }
        dst.push_str(", .len = ");
        dst.push_i64(alen);
        dst.push_str(" }");
        return ok;
    }

    fn ref_cast_needed(self: &mut Self, b: &ir::CoreBody, target: TypeId, place: ir::PlaceId) bool {
        if target == TYPE_NONE {
            return false;
        }
        let mut tm = b.module;
        let mut tt9 = target;
        self.rty(b, target, &mut tm, &mut tt9);
        let ty = *unsafe (*self.p().module_ast_const(tm)).type_at(tt9);
        if ty.kind != TypeKind::TYPE_REFERENCE && ty.kind != TypeKind::TYPE_POINTER {
            return true;
        }
        if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return true;
        }
        let mut em = tm;
        let mut et = ty.as_data.elem;
        let _ = self.mg.resolve(tm, ty.as_data.elem, &mut em, &mut et);
        // A pointer to a fixed array spells its element unqualified (`Mangler`), while the address of
        // an array reached through a `const` path is `const T (*)[N]`: C11 converts neither into the
        // other, so the address is cast.
        let ek = unsafe (*self.p().module_ast_const(em)).type_at(et).kind;
        if ek == TypeKind::TYPE_ARRAY && !self.mg.ptr_wraps(em, et) {
            return true;
        }
        let mut pm = b.module;
        let mut pt = b.places.at(place as usize).ty;
        self.rty(b, pt, &mut pm, &mut pt);
        // A pointer to an array of aggregates names the array's wrapper struct (`Mangler::ptr_wraps`).
        return em != pm || et != pt || self.mg.ptr_wraps(em, et);
    }

    fn emit_rvalue(self: &mut Self, b: &ir::CoreBody, rid: ir::RvalueId, dst: &mut String) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            if rv.target != TYPE_NONE && self.arr_slice_wrap(b, rv.a, rv.target, dst) {
                return true;
            }
            if rv.b == 1 && self.rty_y(b, b.operands.at(rv.a as usize).ty).kind == TypeKind::TYPE_INSTANCE {
                // `[]mut T` as `[]T`: the same pointer and length in the shared view's struct.
                let mut sv = self.sget();
                let mut ok = self.emit_operand(b, rv.a, &mut sv);
                dst.push_str("(");
                ok = ok && self.ty_c(b.module, rv.target, "", dst);
                dst.format_into("){{ .ptr = ({}).ptr, .len = ({}).len }}", sv.as_str(), sv.as_str());
                self.sput(sv);
                return ok;
            }
            return self.emit_operand(b, rv.a, dst);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
            // A reference to a zero-sized value binds to the aligned sentinel, EXCEPT `&*p`,
            // which stays the pointer itself (cheaper, and keeps whatever provenance p carried). A
            // void-typed place (a generic member instantiated at `void`) has no C member or variable
            // at all, so its address is the sentinel too.
            {
                let pty9 = b.places.at(rv.a as usize).ty;
                let rpl9 = *b.places.at(rv.a as usize);
                let cancels9 = rpl9.proj_len != 0 && b.projections.at((rpl9.proj_start + rpl9.proj_len - 1) as usize).kind == ir::PJ_DEREF;
                if !cancels9 && pty9 != TYPE_NONE && self.erased(b, pty9) {
                    let mut rm9 = b.module;
                    let mut rt9 = pty9;
                    self.rty(b, pty9, &mut rm9, &mut rt9);
                    return self.zst_sentinel_ref(rm9, rt9, dst);
                }
            }
            // Cast to the recorded result type: u8 buffers reborrowed as char pointers (and
            // const-ness adjustments) are checker-approved.
            let rpl = *b.places.at(rv.a as usize);
            let cancels = rpl.proj_len != 0 && b.projections.at((rpl.proj_start + rpl.proj_len - 1) as usize).kind == ir::PJ_DEREF;
            // An array's address becomes a pointer to its wrapper struct (`Mangler::ptr_wraps`) as a
            // value converted through `__sc_wrap` (`void *`): the elements are only ever accessed
            // as elements, through the member `e`, and no cast applies to the address itself.
            let wrap = !cancels && self.mg.ptr_wraps(b.module, rpl.ty);
            if rv.kind == ir::RV_ADDR || self.ref_cast_needed(b, rv.target, rv.a) {
                dst.push_str("(");
                if !self.ty_c(b.module, rv.target, "", dst) {
                    return false;
                }
                dst.push_str(")");
            }
            // `&*p` is `p`: a place ending in a dereference cancels the address-of, so emit the place
            // with its trailing deref dropped and no `&`.
            if cancels {
                return self.emit_place_lim(b, rv.a, rpl.proj_len - 1, dst);
            }
            // An array parameter is a pointer in C: its value is the array's address.
            let arr_arg = rpl.proj_len == 0 && b.locals.at(rpl.base as usize).storage == ir::LS_ARG && self.rty_y(
                b,
                rpl.ty,
            ).kind == TypeKind::TYPE_ARRAY;
            dst.push_str(mbe::if_s(wrap, "__sc_wrap(", ""));
            if !arr_arg {
                dst.push_str("&");
            }
            let okw = self.emit_place(b, rv.a, dst);
            if wrap {
                dst.push_str(")");
            }
            return okw;
        }
        if rv.kind == ir::RV_CAST {
            if rv.b == ir::CAST_COERCE_FROM {
                // The checker's selected conversion method, called as a plain C expression. A
                // conv with its OWN generics (widen<M>) binds them from the argument, and its
                // receiver is always the coercion TARGET.
                let cvr = b.operands.at(rv.a as usize).ty;
                let cga = self.p().module_ast_const(rv.item.module);
                let has_own = unsafe (*cga).at_const(rv.item.node).kind == NodeKind::NODE_FUNCTION && unsafe (*cga).at_const(
                    rv.item.node,
                ).as_data.function.generics.len != 0;
                let mut ok = if has_own {
                    self.conv_sym(b, rv.item, cvr, rv.target, dst);
                } else {
                    self.callee_sym(b, rv.item, 0, 0, cvr, rv.target, TYPE_NONE, TYPE_NONE, dst);
                };
                if ok {
                    dst.push_str("(");
                    ok = self.emit_call_arg(b, rv.item, 0, rv.a, dst);
                    dst.push_str(")");
                }
                return ok;
            }
            if rv.b != ir::CAST_NUMERIC && rv.b != ir::CAST_MASK_BITS {
                // A vector and its array convert by `memcpy` at their store (`emit_vec_cast_store`).
                return self.fail("cast");
            }
            // A float converts to an integer saturating (`__sc_f2i_*`); C leaves an out-of-range value
            // undefined.
            let fb = self.int_builtin(b, b.operands.at(rv.a as usize).ty);
            let tb = self.int_builtin(b, rv.target);
            if (fb == BuiltinType::BT_F32 || fb == BuiltinType::BT_F64) && (int_signed(tb) || bt_is_unsigned(tb) || tb == BuiltinType::BT_CHAR) {
                dst.push_str("__sc_f2i_");
                dst.push_str(bt_name(tb));
                dst.push_str("(");
                let okf = self.emit_operand(b, rv.a, dst);
                dst.push_str(")");
                return okf;
            }
            dst.push_str("(");
            let mut ok = self.ty_c(b.module, rv.target, "", dst);
            dst.push_str(")");
            if ok {
                ok = self.emit_operand(b, rv.a, dst);
            }
            return ok;
        }
        if rv.kind == ir::RV_UNARY {
            let t = (rv.b as u8) as tt::TokenType;
            let ub = self.int_builtin(b, b.operands.at(rv.a as usize).ty);
            // Signed negation overflows at MIN (the checker rejects unsigned negation); a narrow unsigned
            // `~` truncates to its width.
            let hop = if t == tt::TokenType::Minus && int_signed(ub) {
                "neg";
            } else if t == tt::TokenType::Tilde && (ub == BuiltinType::BT_U8 || ub == BuiltinType::BT_U16) {
                "not";
            } else {
                "";
            };
            if hop.len() != 0 {
                dst.push_str("__sc_");
                dst.push_str(hop);
                dst.push_str("_");
                dst.push_str(bt_name(ub));
                dst.push_str("(");
                let okh = self.emit_operand(b, rv.a, dst);
                dst.push_str(")");
                return okh;
            }
            if t == tt::TokenType::Minus {
                // A negative constant operand parenthesizes: `--5.0` is a decrement.
                let mut ev = self.sget();
                let okm = self.emit_operand(b, rv.a, &mut ev);
                let paren = ev.len() != 0 && ev.as_str().byte_at(0) == b'-';
                dst.push_str(mbe::if_s(paren, "-(", "-"));
                dst.push_string(&ev);
                if paren {
                    dst.push_str(")");
                }
                self.sput(ev);
                return okm;
            }
            if t == tt::TokenType::Unsafe {
                // The `unsafe` prefix carries no C.
            } else if t == tt::TokenType::Bang {
                dst.push_str("!");
            } else if t == tt::TokenType::Tilde {
                dst.push_str("~");
            } else {
                return self.fail("unary");
            }
            return self.emit_operand(b, rv.a, dst);
        }
        if rv.kind == ir::RV_BINARY {
            let t = rv.c as tt::TokenType;
            let mut rm4 = b.module;
            let mut rt4 = TYPE_NONE;
            let aref = self.bin_op_ty(b, rv.a, &mut rm4, &mut rt4);
            let mut bm4 = b.module;
            let mut bt4 = TYPE_NONE;
            let bref = self.bin_op_ty(b, rv.b, &mut bm4, &mut bt4);
            if (t == tt::TokenType::Plus || t == tt::TokenType::Minus) && rt4 != TYPE_NONE {
                // C pointer arithmetic scales by the COMPLETE element type; a zero-sized element
                // has none. `p +- n` is `p` (bytes cannot advance); `p - q` cannot yield a count
                // and traps with its own diagnostic (rule: bytes cannot encode ZST elements).
                let ya4 = *unsafe (*self.p().module_ast_const(rm4)).type_at(rt4);
                if ya4.kind == TypeKind::TYPE_POINTER {
                    let mut em4 = rm4;
                    let mut et4 = ya4.as_data.elem;
                    if !self.mg.resolve(rm4, ya4.as_data.elem, &mut em4, &mut et4) {
                        em4 = rm4;
                        et4 = ya4.as_data.elem;
                    }
                    self.mg.need_ty(em4, et4);
                    if self.mg.is_zst(em4, et4) {
                        let yb4k = if bt4 != TYPE_NONE {
                            unsafe (*self.p().module_ast_const(bm4)).type_at(bt4).kind;
                        } else {
                            TypeKind::TYPE_ERROR;
                        };
                        if t == tt::TokenType::Minus && yb4k == TypeKind::TYPE_POINTER {
                            dst.push_str("(__sc_zst_ptrdiff(), (intptr_t)0)");
                            return true;
                        }
                        dst.push_str("(");
                        let okp = self.emit_op_d(b, rv.a, aref, dst);
                        dst.push_str(")");
                        return okp;
                    }
                }
            }
            if t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual {
                // Pattern tests compare `str` VALUES; C has no struct `==`.
                if self.is_str_ty(rm4, rt4) {
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    self.mg.need_ty(rm4, rt4);
                    dst.push_str("__sc_str_eq(");
                    let mut ok4 = self.emit_op_d(b, rv.a, aref, dst);
                    dst.push_str(", ");
                    if ok4 {
                        ok4 = self.emit_op_d(b, rv.b, bref, dst);
                    }
                    dst.push_str(")");
                    return ok4;
                }
                if self.op_dispatch_agg(rm4, rt4) {
                    // Aggregate equality dispatches through the type's `eq` (checker-approved).
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    if !self.agg_op_sym(rm4, rt4, "eq", dst) {
                        return self.fail("struct-eq");
                    }
                    return self.emit_ref_args(b, &rv, aref, bref, dst);
                }
            }
            if t == tt::TokenType::LessThan || t == tt::TokenType::LessThanEqual || t == tt::TokenType::GreaterThan || t == tt::TokenType::GreaterThanEqual {
                if self.op_dispatch_agg(rm4, rt4) {
                    // Aggregate ordering dispatches through the type's `cmp` (checker-approved).
                    dst.push_str("(");
                    if !self.agg_op_sym(rm4, rt4, "cmp", dst) {
                        return self.fail("struct-cmp");
                    }
                    let ok4 = self.emit_ref_args(b, &rv, aref, bref, dst);
                    dst.push_str(" ");
                    dst.push_str(CEmit::c_binop(t));
                    dst.push_str(" 0)");
                    return ok4;
                }
            }
            {
                // Arithmetic/bitwise on an AGGREGATE dispatches through the overload method the
                // checker approved (compound assigns carry no op_method record; the old emitter
                // re-derived the callee by name at emission, and so does this one).
                let mn = t.op_method();
                if mn.len() != 0 {
                    if self.op_dispatch_agg(rm4, rt4) {
                        if !self.agg_op_sym(rm4, rt4, mn, dst) {
                            return self.fail("struct-op");
                        }
                        dst.push_str("(");
                        if !aref {
                            dst.push_str("&");
                        }
                        let mut ok5 = self.emit_operand(b, rv.a, dst);
                        dst.push_str(", ");
                        let bk5 = unsafe (*self.p().module_ast_const(bm4)).type_at(bt4).kind;
                        let bagg5 = bk5 == TypeKind::TYPE_STRUCT || bk5 == TypeKind::TYPE_INSTANCE;
                        if bagg5 && !bref {
                            dst.push_str("&");
                        }
                        if ok5 {
                            ok5 = self.emit_op_d(b, rv.b, bref && !bagg5, dst);
                        }
                        dst.push_str(")");
                        return ok5;
                    }
                }
            }
            let mut ab = BuiltinType::BT_VOID;
            let fname = self.arith_fn(b, &rv, &mut ab);
            if fname.len() != 0 {
                let libm = fname.starts_with("fmod");
                dst.push_str(mbe::if_s(libm, "", "__sc_"));
                dst.push_str(fname);
                if !libm {
                    dst.push_str("_");
                    dst.push_str(bt_name(ab));
                }
                dst.push_str("(");
                let mut okf = self.emit_op_d(b, rv.a, aref, dst);
                dst.push_str(", ");
                if okf {
                    okf = self.emit_op_d(b, rv.b, bref, dst);
                }
                dst.push_str(")");
                return okf;
            }
            let mut x = rv.a;
            let r = self.cmp_fold(b, &rv, &mut x);
            if r >= 0 {
                return self.emit_cmp_const(b, x, r == 1, dst);
            }
            let op = CEmit::c_binop(t);
            if op.len() == 0 {
                return self.fail("binary");
            }
            let pc = self.ptr_order_cast(rm4, rt4, t);
            dst.push_str("(");
            dst.push_str(pc);
            let mut ok = self.emit_op_d(b, rv.a, aref, dst);
            self.f32_lit_sfx(b, rv.a, bm4, bt4, dst);
            if ok {
                dst.push_str(" ");
                dst.push_str(op);
                dst.push_str(" ");
                dst.push_str(pc);
                ok = self.emit_op_d(b, rv.b, bref, dst);
                self.f32_lit_sfx(b, rv.b, rm4, rt4, dst);
            }
            dst.push_str(")");
            return ok;
        }
        if rv.kind == ir::RV_AGGREGATE {
            return self.emit_aggregate(b, &rv, dst);
        }
        if rv.kind == ir::RV_SLICE {
            return self.emit_slice(b, &rv, dst);
        }
        if rv.kind == ir::RV_LEN {
            let pl = *b.places.at(rv.a as usize);
            let mut rm = b.module;
            let mut rt = pl.ty;
            self.rty(b, pl.ty, &mut rm, &mut rt);
            let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
            if (y.kind == TypeKind::TYPE_ARRAY || y.kind == TypeKind::TYPE_SIMD) && self.mg.arr_len(rm, &y) >= 0 {
                dst.push_u64(self.mg.arr_len(rm, &y) as u64);
                return true;
            }
            if y.kind == TypeKind::TYPE_INSTANCE {
                let dai = self.p().module_ast_const(rm);
                let it = *unsafe (*dai).instance(y.as_data.inst);
                let nm = self.agg_name(it.module, it.decl);
                if nm == "Slice" || nm == "SliceMut" || nm == "Vector" || nm == "String" {
                    dst.push_str("(");
                    let ok = self.emit_place(b, rv.a, dst);
                    dst.push_str(").len");
                    return ok;
                }
                if nm == "Array" {
                    let mut pv = self.sget();
                    let ok = self.emit_place(b, rv.a, &mut pv);
                    dst.push_str("(sizeof((");
                    dst.push_string(&pv);
                    dst.push_str(").data) / sizeof((");
                    dst.push_string(&pv);
                    dst.push_str(").data[0]))");
                    self.sput(pv);
                    return ok;
                }
            }
            if self.is_str_ty(rm, rt) {
                dst.push_str("(");
                let ok = self.emit_place(b, rv.a, dst);
                dst.push_str(").len");
                return ok;
            }
            return self.fail("len");
        }
        if rv.kind == ir::RV_DISCRIMINANT {
            let pl = *b.places.at(rv.a as usize);
            let mut rm0 = b.module;
            let mut rt0 = pl.ty;
            self.rty(b, pl.ty, &mut rm0, &mut rt0);
            let derefs = self.peel_refs(&mut rm0, &mut rt0);
            let decl = self.agg_decl_res(rm0, rt0);
            if decl == NODE_NONE {
                return self.fail("discr");
            }
            self.mg.need_ty(rm0, rt0);
            let am = self.agg_module_res(rm0, rt0);
            // a payload enum's tag reads through `->` on the last dereference: `self->tag`, not
            // `(*self).tag`. A bare enum has no member, so its value stays a plain dereference.
            let payload = unsafe (*self.p().module_ast_const(am)).enum_has_payload(decl);
            if payload && derefs == 0 && pl.proj_len != 0 && b.projections.at(
                (pl.proj_start + pl.proj_len - 1) as usize,
            ).kind == ir::PJ_DEREF {
                // a trailing dereference folds into the arrow: `e->tag`, not `(*e).tag`
                let ok = self.emit_place_lim(b, rv.a, pl.proj_len - 1, dst);
                if ok {
                    dst.push_str("->tag");
                }
                return ok;
            }
            let arrow = payload && derefs >= 1;
            let outer = if arrow {
                derefs - 1;
            } else {
                derefs;
            };
            for _d in 0..outer {
                dst.push_str("(*");
            }
            let ok = self.emit_place(b, rv.a, dst);
            for _d in 0..outer {
                dst.push_str(")");
            }
            if ok && arrow {
                dst.push_str("->tag");
            } else if ok && payload {
                dst.push_str(".tag");
            }
            return ok;
        }
        if rv.kind == ir::RV_INTRINSIC {
            let k = rv.c as u32;
            if k == ir::IN_SIZEOF as u32 || k == ir::IN_ALIGNOF as u32 {
                {
                    // An ARRAY type spells `sizeof(T[N])` (the bare ctype decays to `T *`).
                    let mut rmZ = b.module;
                    let mut rtZ = rv.b;
                    self.rty(b, rv.b, &mut rmZ, &mut rtZ);
                    if self.mg.is_zst(rmZ, rtZ) {
                        // Zero-sized types have no complete C type: sizeof/alignof are semantic.
                        if k == ir::IN_SIZEOF as u32 {
                            dst.push_str("0");
                        } else {
                            let loz = self.mg.layout_sub(rmZ, rtZ);
                            dst.push_u64(pick(loz.ok && loz.align > 1, loz.align, 1));
                        }
                        return true;
                    }
                    let yz = *unsafe (*self.p().module_ast_const(rmZ)).type_at(rtZ);
                    if yz.kind == TypeKind::TYPE_ARRAY {
                        let nz = self.mg.arr_len(rmZ, &yz);
                        if nz < 0 {
                            return self.fail("array-length");
                        }
                        dst.push_str(mbe::if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                        let okz = self.mg.ctype(rmZ, yz.as_data.elem, "", dst);
                        dst.push_str("[");
                        dst.push_u64(nz as u64);
                        dst.push_str("])");
                        return okz;
                    }
                }
                dst.push_str(mbe::if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                let ok = self.ty_c(b.module, rv.b, "", dst);
                dst.push_str(")");
                return ok;
            }
            if k == ir::IN_TYPE_INFO as u32 {
                if rv.b == TYPE_NONE {
                    return self.fail("type-info");
                }
                let mut rm = b.module;
                let mut rt = rv.b;
                self.rty(b, rv.b, &mut rm, &mut rt);
                let mut sym = self.sget();
                sym.push_str("__sc_ti__");
                if !self.mg.type_m(rm, rt, &mut sym) {
                    self.sput(sym);
                    return self.fail("type-info");
                }
                // The descriptor is declared by the type's owner module (`core` for builtins).
                let od9 = self.mg.owner_dep(rm, rt);
                self.mg.mark_used(
                    if od9 >= 0 {
                        od9 as ModuleId;
                    } else {
                        self.p().core_module;
                    },
                );
                let h = sym.as_str().hash();
                let fresh = !self.ti_seen.contains(&h);
                if self.mg.rec_on && self.mg.rec_dup_once(h ^ 12) {
                    let mut ev = mbe::RecEv::blank(mbe::RK_TI);
                    ev.a = rm;
                    ev.b = rt;
                    self.mg.rec.push(ev);
                }
                if fresh {
                    self.ti_seen.insert(h);
                    self.ti_reqs.push(
                        StatRef {
                            em: rm,
                            def: DefId { module: 0, node: NODE_NONE },
                            sym: sym.clone(),
                            ty: rt,
                            args: Vector::<mbe::MSub>::new(),
                        },
                    );
                    if self.sh_on {
                        self.sh_ti_k.push(h);
                        self.sh_ti_v.push(self.ti_reqs.len() as u32);
                    }
                }
                dst.push_string(&sym);
                self.sput(sym);
                return true;
            }
            if k == ir::IN_DANGLING as u32 {
                if rv.b == TYPE_NONE {
                    return self.fail("dangling");
                }
                let mut rmD = b.module;
                let mut rtD = rv.b;
                self.rty(b, rv.b, &mut rmD, &mut rtD);
                return self.zst_sentinel_ref(rmD, rtD, dst);
            }
            if k == ir::IN_ZEROED as u32 {
                if rv.target != TYPE_NONE && self.erased(b, rv.target) {
                    // Erased destinations suppress the whole store.
                    return self.fail("zst-zeroed");
                }
                dst.push_str("(");
                let ok = self.ty_c(b.module, rv.target, "", dst);
                dst.push_str("){");
                dst.push_str("0");
                dst.push_str("}");
                return ok;
            }
            if k == ir::IN_VA_ARG as u32 {
                let mut ts = self.sget();
                if !self.ty_c(b.module, rv.target, "", &mut ts) {
                    self.sput(ts);
                    return self.fail("va-arg");
                }
                dst.push_str("va_arg(");
                let ok = self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
                dst.push_str(", ");
                dst.push_string(&ts);
                dst.push_str(")");
                self.sput(ts);
                return ok;
            }
            if k == ir::IN_DYN_TID as u32 {
                // Vtable identity test: the tid slot holds the concrete source type's mangled
                // spelling (dyn_pair), so equality with the queried type's spelling decides.
                let mut rmT = b.module;
                let mut rtT = rv.target;
                self.rty(b, rv.target, &mut rmT, &mut rtT);
                let yT = *unsafe (*self.p().module_ast_const(rmT)).type_at(rtT);
                if yT.kind != TypeKind::TYPE_REFERENCE {
                    return self.fail("dyn-tid");
                }
                let mut spell = self.sget();
                if !self.mg.type_m(rmT, yT.as_data.elem, &mut spell) {
                    self.sput(spell);
                    return self.fail("dyn-tid");
                }
                dst.push_str("(strcmp((");
                let ok = self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
                dst.push_str(").vt->tid, \"");
                dst.push_string(&spell);
                dst.push_str("\") == 0)");
                self.sput(spell);
                return ok;
            }
            if k == ir::IN_DYN_DATA as u32 {
                dst.push_str("((");
                if !self.ty_c(b.module, rv.target, "", dst) {
                    return self.fail("dyn-data");
                }
                dst.push_str(")(");
                if !self.emit_operand(b, b.oper_pool[rv.a as usize], dst) {
                    return false;
                }
                dst.push_str(").data)");
                return true;
            }
            if k == ir::IN_BOUNDS as u32 {
                // A lane check's helper comes with the vector's definition (`Mangler::vec_pack`).
                return self.emit_intrinsic_call(
                    b,
                    mbe::if_s(rv.item.node == ir::CHECK_LANES, "__sc_lane(", "__sc_bounds("),
                    rv.a,
                    2,
                    dst,
                );
            }
            if k == ir::IN_BOUNDS_PROVEN as u32 {
                // The proof made the panic edge unreachable: only the index value remains.
                return self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
            }
            if k == ir::IN_BOUNDS_GROUP as u32 {
                // A vector access's check names its start, lanes and length (`Mangler::vec_pack`).
                return self.emit_intrinsic_call(
                    b,
                    mbe::if_s(rv.item.node == ir::CHECK_VEC, "__sc_bounds_vec(", "__sc_bounds_group("),
                    rv.a,
                    3,
                    dst,
                );
            }
            if k == ir::IN_BOUNDS_GROUP_PROVEN as u32 {
                return self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
            }
            if k == ir::IN_RANGE_BOUNDS as u32 {
                return self.emit_intrinsic_call(b, "__sc_range(", rv.a, 3, dst);
            }
            if k == ir::IN_RANGE_BOUNDS_PROVEN as u32 {
                // Only the validated exclusive end remains.
                return self.emit_operand(b, b.oper_pool[(rv.a + 1) as usize], dst);
            }
            if k == ir::IN_LIKELY as u32 {
                dst.push_str("__builtin_expect(");
                let ok = self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
                dst.push_str(", 1)");
                return ok;
            }
            if k == ir::IN_CHUNK as u32 {
                // A strip-mined loop's chunk end, through the tick budget; the loop's own end where
                // the body prints no tick. The helper counts in 64-bit two's complement.
                let eop = b.oper_pool[(rv.a + 1) as usize];
                if !self.ticks_on(b) {
                    return self.emit_operand(b, eop, dst);
                }
                let wide = mbe::if_s(int_signed(self.int_builtin(b, rv.target)), "(uint64_t)", "");
                dst.push_str("(");
                let mut ok = self.ty_c(b.module, rv.target, "", dst);
                dst.push_str(")__sc_chunk_end(&__sc_spc, ");
                dst.push_str(wide);
                ok = ok && self.emit_operand(b, b.oper_pool[rv.a as usize], dst);
                dst.push_str(", ");
                dst.push_str(wide);
                ok = ok && self.emit_operand(b, eop, dst);
                dst.push_str(")");
                return ok;
            }
            return self.fail("intrinsic");
        }
        if rv.kind == ir::RV_CLOSURE {
            let none = String::new();
            let mut post = String::new();
            return self.emit_closure_env(b, &rv, &none, dst, &mut post);
        }
        if rv.kind == ir::RV_DYN {
            // Borrowed erasure: the operand is already a pointer. Owned erasures (Box payloads,
            // boxed closure envs) are statement-level (emit_stmt intercepts them).
            let oty = b.operands.at(rv.a as usize).ty;
            let mut om = b.module;
            let mut ot = oty;
            self.rty(b, oty, &mut om, &mut ot);
            let oy = *unsafe (*self.p().module_ast_const(om)).type_at(ot);
            let mut dm = b.module;
            let mut dt = rv.target;
            self.rty(b, rv.target, &mut dm, &mut dt);
            let mut tc = self.sget();
            let mut pair = self.sget();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut tc);
            if ok && oy.kind == TypeKind::TYPE_DYN {
                // An upcast: the data pointer stays, and the table is the superinterface's that the
                // source table points at.
                let dty = *unsafe (*self.p().module_ast_const(dm)).type_at(dt);
                ok = self.dyn_request(om, ot) && self.dyn_request(dm, dt) && self.mg.dyn_stem(dm, &dty, &mut pair);
                if ok {
                    dst.push_str("((");
                    dst.push_string(&tc);
                    dst.push_str("){ .data = (");
                    ok = self.emit_operand(b, rv.a, dst);
                    dst.push_str(").data, .vt = (");
                    ok = ok && self.emit_operand(b, rv.a, dst);
                    dst.push_str(").vt->__super_");
                    dst.push_string(&pair);
                    dst.push_str(" })");
                }
            } else if ok && (oy.kind == TypeKind::TYPE_REFERENCE || oy.kind == TypeKind::TYPE_POINTER) {
                let mut em = om;
                let mut et = oy.as_data.elem;
                if !self.mg.resolve(om, oy.as_data.elem, &mut em, &mut et) {
                    ok = self.fail("dyn-src");
                }
                if ok {
                    ok = self.dyn_pair(dm, dt, em, et, false, 0, TYPE_NONE, &mut pair);
                }
                if ok {
                    dst.push_str("((");
                    dst.push_string(&tc);
                    dst.push_str("){ .data = (void *)");
                    ok = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", .vt = &");
                    dst.push_string(&pair);
                    dst.push_str("__vtbl })");
                }
            } else if ok {
                // Owned Box source: the payload pointer moves into the fat value.
                let mut boxed = false;
                if oy.kind == TypeKind::TYPE_INSTANCE {
                    let a9 = self.p().module_ast_const(om);
                    let it9 = *unsafe (*a9).instance(oy.as_data.inst);
                    if self.agg_name(it9.module, it9.decl) == "Box" && it9.n > 0 {
                        let mut em = om;
                        let mut et = it9.args[0];
                        if !self.mg.resolve(om, it9.args[0], &mut em, &mut et) {
                            ok = self.fail("dyn-src");
                        }
                        // The allocator the checker recorded (TYPE_NONE: Global).
                        let mut alm = b.module;
                        let mut alt = rv.b;
                        if alt != TYPE_NONE {
                            self.rty(b, rv.b, &mut alm, &mut alt);
                            if self.mg.is_global(alm, alt) {
                                alt = TYPE_NONE;
                            }
                        }
                        if ok {
                            ok = self.dyn_pair(dm, dt, em, et, true, alm, alt, &mut pair);
                        }
                        boxed = ok;
                        if ok {
                            dst.push_str("((");
                            dst.push_string(&tc);
                            dst.push_str("){ .data = (void *)(");
                            ok = self.emit_operand(b, rv.a, dst);
                            dst.push_str(").ptr, .vt = &");
                            dst.push_string(&pair);
                            dst.push_str("__vtbl })");
                        }
                    }
                }
                if ok && !boxed {
                    ok = self.fail("dyn-owned");
                }
            }
            self.sput(tc);
            self.sput(pair);
            return ok;
        }
        return self.fail("rvalue");
    }

    // `(View){ .ptr = <base storage> + lo, .len = (<hi>|<container len>) [+1] - lo }`: str,
    // Slice-family instances (ptr/len members) and fixed arrays slice structurally.
    fn emit_slice(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, dst: &mut String) bool {
        let bpl = *b.places.at(rv.a as usize);
        let mut rm = b.module;
        let mut rt = bpl.ty;
        self.rty(b, bpl.ty, &mut rm, &mut rt);
        let by = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let is_arr = by.kind == TypeKind::TYPE_ARRAY;
        if !is_arr && by.kind != TypeKind::TYPE_INSTANCE && !self.is_str_ty(rm, rt) {
            return self.fail("slice-base");
        }
        let mut bv = self.sget();
        let mut sv = self.sget();
        let mut ev = self.sget();
        let mut ok = self.emit_place(b, rv.a, &mut bv);
        if ok && rv.b != ir::IR_NONE {
            ok = self.emit_operand(b, rv.b, &mut sv);
        }
        if ok && rv.item.node != ir::IR_NONE {
            ok = self.emit_operand(b, rv.item.node, &mut ev);
        }
        let mut cast = self.sget();
        if ok {
            ok = self.ty_c(b.module, rv.target, "", &mut cast);
        }
        // An `Array<T, N>` value stores in `data` (a fixed C array), not `ptr`.
        let mut is_arri = false;
        if !is_arr && by.kind == TypeKind::TYPE_INSTANCE {
            let itA = *unsafe (*self.p().module_ast_const(rm)).instance(by.as_data.inst);
            is_arri = self.agg_name(itA.module, itA.decl) == "Array";
        }
        if ok {
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str("){ .ptr = ");
            // A C array of arrays decays to an array pointer; the view of arrays of aggregates
            // holds a pointer to their wrapper struct (`Mangler::ptr_wraps`): convert the value.
            let ty9 = *unsafe (*self.p().module_ast_const(b.module)).type_at(rv.target);
            let wr = (is_arr || is_arri) && ty9.kind == TypeKind::TYPE_INSTANCE && self.mg.ptr_wraps(
                b.module,
                unsafe (*self.p().module_ast_const(b.module)).instance(ty9.as_data.inst).args[0],
            );
            if wr {
                dst.push_str("(void *)(");
            }
            dst.push_string(&bv);
            if is_arri {
                dst.push_str(".data");
            } else if !is_arr {
                dst.push_str(".ptr");
            }
            if sv.len() != 0 {
                dst.push_str(" + ");
                dst.push_string(&sv);
            }
            if wr {
                dst.push_str(")");
            }
            dst.push_str(", .len = ");
            if ev.len() != 0 {
                // The end operand is a VALIDATED exclusive end (IN_RANGE_BOUNDS ran first).
                dst.push_str("(");
                dst.push_string(&ev);
                dst.push_str(")");
            } else if is_arr {
                let nb = self.mg.arr_len(rm, &by);
                ok = ok && nb >= 0;
                dst.push_u64(nb as u64);
            } else if is_arri {
                dst.push_str("sizeof(");
                dst.push_string(&bv);
                dst.push_str(".data) / sizeof(");
                dst.push_string(&bv);
                dst.push_str(".data[0])");
            } else {
                dst.push_string(&bv);
                dst.push_str(".len");
            }
            if sv.len() != 0 {
                dst.push_str(" - ");
                dst.push_string(&sv);
            }
            dst.push_str(" }");
        }
        self.sput(bv);
        self.sput(sv);
        self.sput(ev);
        self.sput(cast);
        return ok;
    }

    // Env literal `(closure_N_env){ .cap = op, ... }`; a capture-less closure value is the bare
    // hoisted function; a mutated capture stores the binding's address. With a non-empty `lhs`
    // (the store's place), a fixed-array capture copied by value is left out of the literal and
    // copied into `lhs.cap` by a statement appended to `post`: C cannot initialize an array member
    // from a variable.
    fn emit_closure_env(
        self: &mut Self,
        b: &ir::CoreBody,
        rv: &ir::Rvalue,
        lhs: &String,
        dst: &mut String,
        post: &mut String,
    ) bool {
        let cm = rv.item.module;
        let cn = rv.item.node;
        let ca = self.p().module_ast_const(cm);
        if rv.b == 0 {
            self.mg.closure_sym(cm, cn, dst);
            return true;
        }
        let cf = unsafe &*(*ca).closure_fact(cn);
        if cf.ncaps != rv.b {
            return self.fail("closure-caps");
        }
        dst.push_str("(");
        let st9 = dst.len();
        self.mg.closure_sym(cm, cn, dst);
        dst.push_str("_env){ ");
        self.mg.need_name(dst.as_str().slice(st9, dst.len() - 3).hash(), true);
        let mut ok = true;
        let mut ne9: u32 = 0;
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let opid9 = b.oper_pool[(rv.a + i) as usize];
            let aty9 = b.operands.at(opid9 as usize).ty;
            if aty9 != TYPE_NONE && self.erased(b, aty9) {
                // Zero-sized captures have no env member (see the env struct).
                continue;
            }
            let csp = unsafe (*ca).caps_of(cf)[i as usize].name;
            if csp.end <= csp.start {
                ok = self.fail("closure-cap-name");
                break;
            }
            let by_ref = ((cf.mut_caps | cf.ref_caps) >> i as u64 & 1u64) != 0;
            let op = *b.operands.at(opid9 as usize);
            if !by_ref && lhs.len() != 0 && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && self.rty_y(b, aty9).kind == TypeKind::TYPE_ARRAY {
                let mut mem = self.sget();
                mem.push_string(lhs);
                mem.push_str(".");
                self.mg.ident(cm, csp, &mut mem);
                ok = self.emit_array_copy(post, b, &mem, op.data);
                self.sput(mem);
                continue;
            }
            if ne9 != 0 {
                dst.push_str(", ");
            }
            ne9 += 1;
            dst.push_str(".");
            self.mg.ident(cm, csp, dst);
            dst.push_str(" = ");
            if by_ref {
                if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                    ok = self.fail("closure-mut-cap");
                    break;
                }
                dst.push_str("&");
                ok = self.emit_place(b, op.data, dst);
            } else {
                ok = self.emit_operand(b, opid9, dst);
            }
        }
        if ne9 == 0 {
            // All captures zero-sized: initialize the carrier byte.
            dst.push_str("0");
        }
        dst.push_str(" }");
        return ok;
    }

    // Does closure rvalue `rv` copy a fixed-array capture by value (see `emit_closure_env`)?
    fn closure_has_array_cap(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        if rv.b == 0 {
            return false;
        }
        let cf = unsafe &*(*self.p().module_ast_const(rv.item.module)).closure_fact(rv.item.node);
        for i in 0..rv.b {
            let op = *b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize);
            let by_ref = ((cf.mut_caps | cf.ref_caps) >> i as u64 & 1u64) != 0;
            if !by_ref && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && self.rty_y(b, op.ty).kind == TypeKind::TYPE_ARRAY {
                return true;
            }
        }
        return false;
    }

    // `lhs = (closure_N_env){ .. };` then one copy per fixed-array capture.
    fn emit_closure_store_arrays(self: &mut Self, o: &mut String, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let mut lhs = self.sget();
        let mut post = self.sget();
        let mut ok = self.emit_place(b, s.place, &mut lhs);
        if ok {
            o.push_str("  ");
            o.push_string(&lhs);
            o.push_str(" = ");
            ok = self.emit_closure_env(b, rv, &lhs, o, &mut post);
            o.push_str(";\n");
            o.push_string(&post);
        }
        self.sput(lhs);
        self.sput(post);
        return ok;
    }

    fn emit_aggregate(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, dst: &mut String) bool {
        if rv.c == ir::AGG_VARIANT {
            let edecl = self.agg_decl(b, rv.target);
            if edecl == NODE_NONE {
                return self.fail("agg-enum");
            }
            let am = self.agg_module(b, rv.target);
            if !unsafe (*self.p().module_ast_const(am)).enum_has_payload(edecl) {
                self.mg.enum_tag(am, edecl, rv.item.node, dst);
                return true;
            }
            let mut tag = self.sget();
            self.mg.enum_tag(am, edecl, rv.item.node, &mut tag);
            dst.push_str("(");
            let mut ok = self.ty_c(b.module, rv.target, "", dst);
            if ok {
                dst.push_str("){ .tag = ");
                dst.push_string(&tag);
                let mut vmat9: u32 = 0;
                for i in 0..rv.b {
                    let aty9 = b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize).ty;
                    if !(aty9 != TYPE_NONE && self.erased(b, aty9)) {
                        vmat9 += 1;
                    }
                }
                if vmat9 != 0 {
                    dst.push_str(", .payload.");
                    let ea = self.p().module_ast_const(am);
                    self.mg.ident(
                        am,
                        unsafe (*ea).at_const(unsafe (*ea).at_const(rv.item.node).as_data.variant.name).as_data.name.text,
                        dst,
                    );
                    dst.push_str(" = { ");
                    let mut ne9: u32 = 0;
                    for i in 0..rv.b {
                        if !ok {
                            break;
                        }
                        let opid9 = b.oper_pool[(rv.a + i) as usize];
                        let aty9 = b.operands.at(opid9 as usize).ty;
                        if aty9 != TYPE_NONE && self.erased(b, aty9) {
                            // Zero-sized payload member: no C storage.
                            continue;
                        }
                        if ne9 != 0 {
                            dst.push_str(", ");
                        }
                        ne9 += 1;
                        ok = self.emit_operand(b, opid9, dst);
                    }
                    if ne9 == 0 {
                        dst.push_str("0");
                    }
                    dst.push_str(" }");
                }
                dst.push_str(" }");
            }
            self.sput(tag);
            return ok;
        }
        if rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE {
            dst.push_str("(");
            let mut ok = self.ty_c(b.module, rv.target, "", dst);
            if !ok {
                return false;
            }
            dst.push_str(")");
            if rv.b == 0 {
                // A stored member always exists (ZST targets are suppressed upstream).
                dst.push_str("{");
                dst.push_str("0");
                dst.push_str("}");
                return true;
            }
            dst.push_str("{ ");
            if rv.c == ir::AGG_TUPLE {
                let mut ne9: u32 = 0;
                for i in 0..rv.b {
                    if !ok {
                        break;
                    }
                    let opid9 = b.oper_pool[(rv.a + i) as usize];
                    let aty9 = b.operands.at(opid9 as usize).ty;
                    if aty9 != TYPE_NONE && self.erased(b, aty9) {
                        // Zero-sized tuple member: no C storage.
                        continue;
                    }
                    if ne9 != 0 {
                        dst.push_str(", ");
                    }
                    ne9 += 1;
                    dst.push_str("._");
                    dst.push_u64(i);
                    dst.push_str(" = ");
                    ok = self.emit_operand(b, opid9, dst);
                }
                if ne9 == 0 {
                    dst.push_str("0");
                }
                dst.push_str(" }");
                return ok;
            }
            let sdecl = self.agg_decl(b, rv.target);
            if sdecl == NODE_NONE {
                return self.fail("agg-struct");
            }
            let am = self.agg_module(b, rv.target);
            let sa = self.p().module_ast_const(am);
            let ms = unsafe (*sa).at_const(sdecl).as_data.aggregate.members;
            if ms.len != rv.b {
                return self.fail("agg-arity");
            }
            // Decl-order operands with IR_NONE holes: omitted members zero-fill in C.
            let mut emitted: u32 = 0;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue;
                }
                {
                    let aty9 = b.operands.at(opid as usize).ty;
                    if aty9 != TYPE_NONE && self.erased(b, aty9) {
                        // Zero-sized field: no C member to initialize.
                        continue;
                    }
                }
                if emitted != 0 {
                    dst.push_str(", ");
                }
                dst.push_str(".");
                let fid = unsafe (*sa).list(ms)[i as usize];
                self.mg.ident(
                    am,
                    unsafe (*sa).at_const(unsafe (*sa).at_const(fid).as_data.field.name).as_data.name.text,
                    dst,
                );
                dst.push_str(" = ");
                ok = self.emit_operand(b, opid, dst);
                emitted += 1;
            }
            if emitted == 0 {
                dst.push_str("0");
            }
            dst.push_str(" }");
            return ok;
        }
        return self.fail("agg-kind");
    }

    // A shim extern's prototype, typed from THIS call site (extern signatures carry no recorded
    // types; call-site operand/dest types resolve under the active env). First caller wins;
    // variadic tails past the declared params are cut at `...`.
    fn collect_extern_proto(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) {
        if t.callee.node == NODE_NONE {
            return;
        }
        let ca = self.p().module_ast_const(t.callee.module);
        let fd = unsafe (*ca).at_const(t.callee.node);
        if fd.kind != NodeKind::NODE_FUNCTION {
            return;
        }
        if !fd.as_data.function.is_extern() {
            return;
        }
        if self.ext_backed.contains(&skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64)) {
            // The extern block's header ships the real prototype.
            return;
        }
        let mut sym = String::new();
        {
            self.mg.ident(t.callee.module, unsafe (*ca).at_const(fd.as_data.function.name).as_data.name.text, &mut sym);
            let s0k = sym.as_str();
            let keep = s0k.len() > 3 && s0k.slice(0, 3) == "sc_";
            if !keep {
                return;
            }
        }
        let h = sym.as_str().hash();
        let fresh = !self.extern_seen.contains(&h);
        if !fresh && !(self.mg.rec_on && self.mg.rec_dup_once(h ^ 9)) {
            return;
        }
        if fresh {
            self.extern_seen.insert(h);
        }
        let mut pr = String::from_str("extern ");
        let mut rty = TYPE_NONE;
        if t.dests_len == 1 {
            rty = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
        }
        let mut pok = self.ty_c(b.module, rty, "", &mut pr);
        let rdecl = pr.len() + 1;
        if pok {
            pr.push_str(" ");
            pr.push_string(&sym);
            pr.push_str("(");
            let np = fd.as_data.function.params.len;
            let mut i: u32 = 0;
            while i < t.args_len && i < np {
                if i != 0 {
                    pr.push_str(", ");
                }
                let aty = b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize).ty;
                if self.is_unit(b, aty) {
                    // An untyped/null arg gives no parameter type: leave it implicit.
                    pok = false;
                    break;
                }
                let k5 = self.rty_y(b, aty).kind;
                if k5 == TypeKind::TYPE_POINTER || k5 == TypeKind::TYPE_REFERENCE {
                    // Parameter-compatible with every pointer arg.
                    pr.push_str("const void *");
                } else if !self.ty_c(b.module, aty, "", &mut pr) {
                    pok = false;
                    break;
                }
                i += 1;
            }
            if fd.as_data.function.is_variadic() {
                pr.push_str(", ...");
            }
            if np == 0 && !fd.as_data.function.is_variadic() {
                pr.push_str("void");
            }
            pr.push_str(")");
            pok = pok && self.fn_decl(b.module, rty, 7, rdecl, &mut pr);
            pr.push_str(";\n");
        }
        if pok {
            if self.mg.rec_on {
                let mut ev = mbe::RecEv::blank(mbe::RK_EXT);
                ev.h = h;
                ev.s1 = pr.clone();
                self.mg.rec.push(ev);
            }
            if fresh {
                self.extern_protos.push_string(&pr);
                if self.sh_on {
                    self.sh_ext_k.push(h);
                    self.sh_ext_e.push(self.extern_protos.len() as u32);
                }
            }
        }
    }

    // Record a destructor use: derived `__free__d` symbols join the glue worklist; user `free`
    // methods on instances join the demand queue (their bodies emit like any method instance).
    fn note_free(self: &mut Self, rm: ModuleId, rt: TypeId, sym: str) {
        let h = sym.hash();
        let fresh = !self.glue_seen.contains(&h);
        if !fresh && !self.mg.rec_on {
            return;
        }
        if fresh {
            self.glue_seen.insert(h);
        }
        let n = sym.len();
        if n > 9 && sym.slice(n - 9, n) == "__free__d" {
            // The recorded type may still name generics: keep the ACTIVE env for emission.
            let ge = GlueEnv { subs: mbe::subs_copy(&self.mg.subs) };
            if self.mg.rec_on && self.mg.rec_dup_once(h ^ 7) {
                let mut ev = mbe::RecEv::blank(mbe::RK_GLUE);
                ev.h = h;
                ev.a = rm;
                ev.d = rt;
                ev.s1 = String::from_str(sym);
                ev.subs = mbe::subs_copy(&ge.subs);
                self.mg.rec.push(ev);
            }
            if fresh {
                self.glue_envs.push(ge);
                self.glue.push(
                    StatRef {
                        em: rm,
                        def: DefId { module: 0, node: NODE_NONE },
                        sym: String::from_str(sym),
                        ty: rt,
                        args: Vector::<mbe::MSub>::new(),
                    },
                );
                if self.sh_on {
                    self.sh_glue_k.push(h);
                    self.sh_glue_v.push(self.glue.len() as u32);
                }
            }
            return;
        }
        // A user free method: demand its instance body when the receiver is generic.
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind != TypeKind::TYPE_INSTANCE {
            // Concrete frees are seeds already.
            return;
        }
        let it = *unsafe (*a).instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        let mut ext = NODE_NONE;
        let mid = self.mg.free_method(it.module, it.decl, &mut ext);
        if mid == NODE_NONE || unsafe (*da).at_const(mid).as_data.function.body == NODE_NONE {
            return;
        }
        let mut snap = mbe::subs_copy(&self.mg.subs);
        self.bind_recv(&mut snap, it.module, ext, rm, &it);
        let mut sfx = String::new();
        // `sym` spelled the context's edges; the key spells every argument (a trailing Global too).
        let ok = self.mg.args_m(rm, &it, it.n, &mut sfx);
        if ok {
            let d9 = Demand {
                def: DefId { module: it.module, node: mid },
                sym: String::from_str(sym),
                subs: snap,
                sfx: sfx,
            };
            self.rec_demand(&d9, h, 2);
            if fresh {
                self.demand.push(d9);
            }
        }
    }

    // Does the user `free` of resolved type `(rm, rt)` apply to it? An instance whose `free`
    // extend bounds a parameter with `Free` is covered only when that argument owns memory;
    // an uncovered instance drops through the derived glue, which frees its owning members.
    fn user_free_covers(self: &mut Self, rm: ModuleId, rt: TypeId) bool {
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return true;
        }
        let it = *unsafe (*self.p().module_ast_const(rm)).instance(y.as_data.inst);
        let mut ext = NODE_NONE;
        if self.mg.free_method(it.module, it.decl, &mut ext) == NODE_NONE {
            return true;
        }
        let da = self.p().module_ast_const(it.module);
        let gens = unsafe (*da).at_const(ext).as_data.extend_def.generics;
        let mut k: u32 = 0;
        while k < gens.len && k < it.n as u32 {
            let gid = unsafe (*da).list(gens)[k as usize];
            if self.param_has_free_bound(it.module, gid) && !self.bound_destructible(rm, unsafe it.args[k as usize]) {
                return false;
            }
            k += 1;
        }
        return true;
    }

    // Does generic parameter `gp` of module `m` carry a `Free` bound?
    fn param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.p().module_ast_const(m);
        let bs = unsafe (*a).at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bd = unsafe (*a).resolution_def(unsafe (*a).list(bs)[i as usize]);
            if bd.node == NODE_NONE {
                continue;
            }
            let ba = self.p().module_ast_const(bd.module);
            let bn = unsafe (*ba).at_const(bd.node);
            if bn.kind == NodeKind::NODE_INTERFACE {
                let ns = unsafe (*ba).at_const(bn.as_data.interface_def.name).as_data.name.text;
                if self.p().modules.at(bd.module as usize).source.as_str().slice(ns.start as usize, ns.end as usize) == "Free" {
                    return true;
                }
            }
        }
        return false;
    }

    /// True when resolved type `(rm, rt)` needs a free call when dropped. The walk follows
    /// by-value members only, and a type that embeds itself by value is rejected before emission,
    /// so it terminates with no depth bound. A verdict that reads no substitution (a concrete type
    /// that is not a closure and not a generic declaration named bare) is memoized per
    /// (module, type), so a member type shared by many fields is judged once.
    pub fn is_destructible(self: &mut Self, rm: ModuleId, rt: TypeId) bool {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        let mut memo = y.kind != TypeKind::TYPE_FUNCTION && unsafe (*a).type_concrete(rt);
        if memo && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM) {
            memo = unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl).as_data.aggregate.generics.len == 0;
        }
        let key = skey_mix(0, rm as u64 << 32 | rt as u64);
        if memo {
            switch self.destr_memo.get(&key) {
                Some(v) => {
                    return *v != 0;
                },
                None => {},
            };
        }
        let r = self.is_destructible_raw(rm, rt, &y);
        if memo {
            self.destr_memo.insert(
                key,
                if r {
                    1u64;
                } else {
                    0u64;
                },
            );
        }
        return r;
    }

    fn is_destructible_raw(self: &mut Self, rm: ModuleId, rt: TypeId, y: &Ty) bool {
        let a = self.p().module_ast_const(rm);
        if y.kind == TypeKind::TYPE_DYN {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            // A zero-length array holds no element to free (an unfolded length may hold some).
            return self.mg.arr_len(rm, y) != 0 && self.is_destructible(rm, y.as_data.arr.elem);
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            // A closure is destructible when any non-mut capture owns memory (mirrors the borrowck
            // owner's rule); a plain function pointer never is.
            let fa = self.p().module_ast_const(y.module);
            let cf = unsafe (*fa).closure_fact(y.as_data.decl);
            if cf == null {
                return false;
            }
            let by_ptr = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
            for i in 0..unsafe (&*cf).ncaps {
                if (by_ptr >> i as u64 & 1u64) != 0 {
                    continue;
                }
                let cty = unsafe (*fa).caps_of(cf)[i as usize].ty;
                if cty == TYPE_NONE {
                    continue;
                }
                let mut crm = y.module;
                let mut crt = cty;
                if !self.mg.resolve(y.module, cty, &mut crm, &mut crt) {
                    continue;
                }
                if self.is_destructible(crm, crt) {
                    return true;
                }
            }
            return false;
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut ftg = DefId { module: 0, node: NODE_NONE };
        if self.mg.find_method(rm, rt, "free", &mut ftg).node != NODE_NONE && self.user_free_covers(rm, rt) {
            return true;
        }
        let decl = self.agg_decl_res(rm, rt);
        if decl == NODE_NONE {
            return false;
        }
        let am = self.agg_module_res(rm, rt);
        let da = self.p().module_ast_const(am);
        let ms2 = unsafe (*da).at_const(decl).as_data.aggregate.members;
        // Bind the decl's generics for field resolution when this is an instance.
        let mut nb: usize = 0;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            nb = self.mg.push_generics(am, unsafe (*da).at_const(decl).as_data.aggregate.generics, rm, &it);
        }
        let mut res = false;
        let is_tuple = unsafe (*da).at_const(decl).as_data.aggregate.is_tuple;
        for i in 0..ms2.len {
            let fid = unsafe (*da).list(ms2)[i as usize];
            let fk = unsafe (*da).at_const(fid).kind;
            if fk == NodeKind::NODE_FIELD || is_tuple {
                let type_node = if is_tuple {
                    fid;
                } else {
                    unsafe (*da).at_const(fid).as_data.field.ty;
                };
                let fty = unsafe (*da).type_of(type_node);
                if fty != TYPE_NONE {
                    if self.bound_destructible(am, fty) {
                        res = true;
                        break;
                    }
                }
            } else if fk == NodeKind::NODE_VARIANT {
                let pl = unsafe (*da).at_const(fid).as_data.variant.payload;
                for k in 0..pl.len {
                    let pid = unsafe (*da).list(pl)[k as usize];
                    let pty = unsafe (*da).type_of(pid);
                    if pty != TYPE_NONE {
                        if self.bound_destructible(am, pty) {
                            res = true;
                            break;
                        }
                    }
                }
                if res {
                    break;
                }
            }
        }
        self.mg.pop_subs(nb);
        return res;
    }

    // Whether member type `(m, t)` owns memory, read through the substitution stack: a param's
    // payload is walked under the env its binding was pushed in (Mangler::hide_from).
    fn bound_destructible(self: &mut Self, m: ModuleId, t: TypeId) bool {
        let mut rm = m;
        let mut rt = t;
        let mut env: usize = 0;
        if !self.mg.resolve_env(m, t, &mut rm, &mut rt, &mut env) {
            return false;
        }
        let h0 = self.mg.hide_from(env, rm, rt);
        let r = self.is_destructible(rm, rt);
        self.mg.unhide(h0);
        return r;
    }

    /// Append a statement that frees `lv`, an lvalue of resolved type `(rm, rt)`. C has no array
    /// destructor, so an array frees element by element (a nested array nests the loop).
    fn free_stmt(self: &mut Self, rm: ModuleId, rt: TypeId, lv: &String, depth: u32, out: &mut String) bool {
        if unsafe (*self.p().module_ast_const(rm)).type_at(rt).kind == TypeKind::TYPE_ARRAY {
            return self.array_free(rm, rt, lv, depth, out);
        }
        if !self.free_expr(rm, rt, out) {
            return false;
        }
        if self.mg.is_zst(rm, rt) {
            // No C storage exists: the destructor runs on the sentinel.
            out.push_str("(");
            let _ = self.zst_sentinel_ref(rm, rt, out);
            out.push_str(");");
            return true;
        }
        out.push_str("(&");
        out.push_string(lv);
        out.push_str(");");
        return true;
    }

    /// `for (size_t __sc_iN = 0; __sc_iN < len; __sc_iN++) { <free lv[__sc_iN]> }` for array `lv`
    /// of resolved type `(rm, rt)`; `depth` names the index so nested loops do not shadow it.
    fn array_free(self: &mut Self, rm: ModuleId, rt: TypeId, lv: &String, depth: u32, out: &mut String) bool {
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut em = rm;
        let mut et = y.as_data.arr.elem;
        if !self.mg.resolve(rm, y.as_data.arr.elem, &mut em, &mut et) {
            return self.fail("drop-array");
        }
        let mut iv = String::from_str("__sc_i");
        iv.push_u64(depth);
        out.push_str("for (size_t ");
        out.push_string(&iv);
        out.push_str(" = 0; ");
        out.push_string(&iv);
        let n = self.mg.arr_len(rm, &y);
        if n < 0 {
            return self.fail("drop-array");
        }
        out.push_str(" < ");
        out.push_u64(n as u64);
        out.push_str("; ");
        out.push_string(&iv);
        out.push_str("++) { ");
        let mut ev = lv.clone();
        ev.push_str("[");
        ev.push_string(&iv);
        ev.push_str("]");
        if !self.free_stmt(em, et, &ev, depth + 1, out) {
            return false;
        }
        out.push_str(" }");
        return true;
    }

    /// Append the C expression that frees resolved type `(rm, rt)` (a callable symbol) and record
    /// the demand/glue the call needs; false when the type is not destructible.
    pub fn free_expr(self: &mut Self, rm: ModuleId, rt: TypeId, out: &mut String) bool {
        let mk = out.len(); // `out` may already hold text: only the symbol appended here is noted
        let yd = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if yd.kind == TypeKind::TYPE_DYN {
            // Owned dyn destroys through the stem's guarded inline helper.
            if !self.dyn_request(rm, rt) {
                return false;
            }
            if !self.mg.dyn_stem(rm, &yd, out) {
                return self.fail("dyn-stem");
            }
            out.push_str("__dyn_free");
            return true;
        }
        let user = self.user_free_covers(rm, rt);
        if !self.mg.free_target(rm, rt, user, out) {
            return false;
        }
        self.note_free(rm, rt, out.as_str().slice(mk, out.len()));
        return true;
    }

    /// Emit derived destructor `idx` from the glue worklist into the shared buffer:
    /// `static void <sym>(<T> *const self) { <memberwise frees> }`. Nested destructible fields
    /// enqueue their own glue/demand entries.
    pub fn emit_glue(self: &mut Self, idx: usize) bool {
        // Re-establish the env the entry was recorded under (its type may name generics).
        let gn0 = self.glue_envs.at(idx).subs.len();
        for gi in 0..gn0 {
            let sb0 = *self.glue_envs.at(idx).subs.at(gi);
            self.mg.push_msub(sb0);
        }
        let ok0x = self.emit_glue_inner(idx);
        self.mg.pop_subs(gn0);
        return ok0x;
    }

    fn emit_glue_inner(self: &mut Self, idx: usize) bool {
        let rm = self.glue.at(idx).em;
        let rt = self.glue.at(idx).ty;
        let sym = self.glue.at(idx).sym.clone();
        self.err = "";
        let mut head = String::new();
        let ok0 = self.ty_c(rm, rt, "", &mut head);
        if ok0 {
            // Extern: drop sites in every TU spell this symbol; the instance TU defines it once.
            self.out.push_str("void ");
            self.out.push_string(&sym);
            self.out.push_str("(");
            self.out.push_string(&head);
            self.out.push_str(" *const self) {\n");
        }
        if !ok0 {
            return false;
        }
        {
            let a9 = self.p().module_ast_const(rm);
            let y9 = *unsafe (*a9).type_at(rt);
            if y9.kind == TypeKind::TYPE_FUNCTION {
                return self.emit_closure_glue(&y9);
            }
        }
        let decl = self.agg_decl_res(rm, rt);
        if decl == NODE_NONE {
            self.out.push_str("}\n");
            return true;
        }
        let am = self.agg_module_res(rm, rt);
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        let da = self.p().module_ast_const(am);
        let mut nb: usize = 0;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            nb = self.mg.push_generics(am, unsafe (*da).at_const(decl).as_data.aggregate.generics, rm, &it);
        }
        let ms = unsafe (*da).at_const(decl).as_data.aggregate.members;
        let is_enum = unsafe (*da).at_const(decl).kind == NodeKind::NODE_ENUM;
        let mut body = String::new();
        let mut ok = true;
        if is_enum {
            if unsafe (*self.p().module_ast_const(am)).enum_has_payload(decl) {
                body.push_str("  switch (self->tag) {\n");
                for i in 0..ms.len {
                    if !ok {
                        break;
                    }
                    let vid = unsafe (*da).list(ms)[i as usize];
                    let vn = unsafe (*da).at_const(vid);
                    if vn.kind != NodeKind::NODE_VARIANT || vn.as_data.variant.payload.len == 0 {
                        continue;
                    }
                    let mut any = String::new();
                    let pl = vn.as_data.variant.payload;
                    for k in 0..pl.len {
                        if !ok {
                            break;
                        }
                        let pid = unsafe (*da).list(pl)[k as usize];
                        let pty = unsafe (*da).type_of(pid);
                        if pty == TYPE_NONE {
                            continue;
                        }
                        let mut prm = am;
                        let mut prt = pty;
                        if !self.mg.resolve(am, pty, &mut prm, &mut prt) || !self.is_destructible(prm, prt) {
                            continue;
                        }
                        let mut lv = String::from_str("self->payload.");
                        self.mg.ident(am, unsafe (*da).at_const(vn.as_data.variant.name).as_data.name.text, &mut lv);
                        if unsafe (*da).at_const(pid).kind == NodeKind::NODE_FIELD {
                            // a struct variant's member carries its field name
                            lv.push_str(".");
                            self.mg.ident(
                                am,
                                unsafe (*da).at_const(unsafe (*da).at_const(pid).as_data.field.name).as_data.name.text,
                                &mut lv,
                            );
                        } else {
                            lv.push_str("._");
                            lv.push_u64(k);
                        }
                        any.push_str("    ");
                        ok = self.free_stmt(prm, prt, &lv, 0, &mut any);
                        any.push_str("\n");
                    }
                    if ok && any.len() != 0 {
                        let mut tag = String::new();
                        self.mg.enum_tag(am, decl, vid, &mut tag);
                        body.push_str("  case ");
                        body.push_string(&tag);
                        body.push_str(":\n");
                        body.push_string(&any);
                        body.push_str("    break;\n");
                    }
                }
                body.push_str("  default: break;\n  }\n");
            }
        } else {
            let is_tuple = unsafe (*da).at_const(decl).as_data.aggregate.is_tuple;
            for i in 0..ms.len {
                if !ok {
                    break;
                }
                let fid = unsafe (*da).list(ms)[i as usize];
                // Tuple members are bare type nodes named `_i`; named members are NODE_FIELD.
                if !is_tuple && unsafe (*da).at_const(fid).kind != NodeKind::NODE_FIELD {
                    continue;
                }
                let type_node = if is_tuple {
                    fid;
                } else {
                    unsafe (*da).at_const(fid).as_data.field.ty;
                };
                let fty = unsafe (*da).type_of(type_node);
                if fty == TYPE_NONE {
                    continue;
                }
                let mut frm = am;
                let mut frt = fty;
                if !self.mg.resolve(am, fty, &mut frm, &mut frt) || !self.is_destructible(frm, frt) {
                    continue;
                }
                let mut lv = String::from_str("self->");
                if is_tuple {
                    lv.push_str("_");
                    lv.push_u64(i);
                } else {
                    self.mg.ident(
                        am,
                        unsafe (*da).at_const(unsafe (*da).at_const(fid).as_data.field.name).as_data.name.text,
                        &mut lv,
                    );
                }
                body.push_str("  ");
                ok = self.free_stmt(frm, frt, &lv, 0, &mut body);
                body.push_str("\n");
            }
        }
        self.mg.pop_subs(nb);
        if ok {
            self.out.push_string(&body);
            self.out.push_str("}\n");
        }
        return ok;
    }

    // The derived destructor body for a closure env dropped without ever being called: one free per
    // owning non-mut capture, in declaration order (the same fields, names and erasure rules as the
    // env struct emission). The caller already opened `void <sym>(<env> *const self) {`.
    fn emit_closure_glue(self: &mut Self, y: &Ty) bool {
        let fa = self.p().module_ast_const(y.module);
        let cf = unsafe (*fa).closure_fact(y.as_data.decl);
        if cf == null {
            return self.fail("closure-glue");
        }
        let by_ptr = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
        let mut body = String::new();
        let mut ok = true;
        for i in 0..unsafe (&*cf).ncaps {
            if !ok {
                break;
            }
            if (by_ptr >> i as u64 & 1u64) != 0 {
                continue;
            }
            let cty = unsafe (*fa).caps_of(cf)[i as usize].ty;
            if cty == TYPE_NONE {
                continue;
            }
            let mut crm = y.module;
            let mut crt = cty;
            if !self.mg.resolve(y.module, cty, &mut crm, &mut crt) || !self.is_destructible(crm, crt) {
                continue;
            }
            let csp = unsafe (*fa).caps_of(cf)[i as usize].name;
            if csp.end <= csp.start {
                ok = self.fail("closure-glue-name");
            } else {
                let mut lv = String::from_str("self->");
                self.mg.ident(y.module, csp, &mut lv);
                body.push_str("  ");
                ok = self.free_stmt(crm, crt, &lv, 0, &mut body);
                body.push_str("\n");
            }
        }
        if ok {
            self.out.push_string(&body);
            self.out.push_str("}\n");
        }
        return ok;
    }

    // The erased dyn receiver, deref-wrapped through its reference stars.
    // The receiver operand of interface-member call `t` when it is a dyn value, which the call then
    // dispatches through the vtable: the pair's type into `(om, ot)` and the references it sits
    // behind into `stars` (a generic `&T` with T = Box<dyn I> stays a reference in the body).
    // IR_NONE for any other call.
    fn dyn_recv_of(
        self: &mut Self,
        b: &ir::CoreBody,
        t: &ir::Terminator,
        om: &mut ModuleId,
        ot: &mut TypeId,
        stars: &mut u32,
    ) ir::OperandId {
        *stars = 0;
        if t.callee.node == NODE_NONE || t.args_len == 0 || self.mg.in_interface(t.callee.module, t.callee.node) == NODE_NONE {
            return ir::IR_NONE;
        }
        let a0 = b.oper_pool[t.args_start as usize];
        let mut om0 = b.module;
        let mut ot0 = b.operands.at(a0 as usize).ty;
        self.rty(b, b.operands.at(a0 as usize).ty, &mut om0, &mut ot0);
        let mut y0 = *unsafe (*self.p().module_ast_const(om0)).type_at(ot0);
        let mut n: u32 = 0;
        while (y0.kind == TypeKind::TYPE_REFERENCE || y0.kind == TypeKind::TYPE_POINTER) && n < 4 {
            let mut nm0 = om0;
            let mut nt0 = y0.as_data.elem;
            if !self.mg.resolve(om0, y0.as_data.elem, &mut nm0, &mut nt0) {
                nm0 = om0;
                nt0 = y0.as_data.elem;
            }
            om0 = nm0;
            ot0 = nt0;
            y0 = *unsafe (*self.p().module_ast_const(om0)).type_at(ot0);
            n += 1;
        }
        if y0.kind != TypeKind::TYPE_DYN {
            return ir::IR_NONE;
        }
        *om = om0;
        *ot = ot0;
        *stars = n;
        return a0;
    }

    fn emit_dyn_recv(self: &mut Self, b: &ir::CoreBody, dyn_recv: u32, dyn_stars: u32, sink: &mut String) bool {
        if dyn_stars != 0 {
            sink.push_str("(");
            for _s in 0..dyn_stars {
                sink.push_str("*");
            }
        }
        let ok = self.emit_operand(b, dyn_recv, sink);
        if dyn_stars != 0 {
            sink.push_str(")");
        }
        return ok;
    }

    // The side effect of a terminator (a drop's free, a call's statement, an assert's check, a
    // return's value, an unreachable abort) with NO control transfer: the structured driver owns
    // every goto, break, continue, and fall-through. GOTO and SWITCH carry no effect here.
    fn emit_term_effect(self: &mut Self, o: &mut String, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind == ir::TM_GOTO {
            return true;
        }
        if t.kind == ir::TM_DROP {
            // Scalar drops are pure control flow; a dyn value frees through its vtable; other
            // destructible values need the declaration plan's free glue and stay unfrozen.
            if self.drop_emits_nothing(b, t) {
                return true;
            }
            let pl = *b.places.at(t.a as usize);
            let mut rm = b.module;
            let mut rt = pl.ty;
            self.rty(b, pl.ty, &mut rm, &mut rt);
            let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
            if y.kind == TypeKind::TYPE_DYN {
                let mut pv = self.sget();
                let ok = self.emit_place(b, t.a, &mut pv);
                if ok {
                    CEmit::open_drop_guard(o, t);
                    o.push_string(&pv);
                    o.push_str(".vt->__free(");
                    o.push_string(&pv);
                    o.push_str(".data);");
                    o.push_str(mbe::if_s(t.args_len == 1, " }", ""));
                    o.push_str("\n");
                }
                self.sput(pv);
                return ok;
            }
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                // An explicit `.free()` THROUGH a pointer (Box's payload drop): the pointee frees
                // by the pointer VALUE; scheduled drops never produce pointer places (borrows).
                let mut em9 = rm;
                let mut et9 = y.as_data.elem;
                if self.mg.resolve(rm, y.as_data.elem, &mut em9, &mut et9) && self.is_destructible(em9, et9) {
                    CEmit::open_drop_guard(o, t);
                    if !self.free_expr(em9, et9, o) {
                        return self.fail("drop-ptr");
                    }
                    o.push_str("(");
                    let ok9 = self.emit_place(b, t.a, o);
                    o.push_str(");");
                    o.push_str(mbe::if_s(t.args_len == 1, " }", ""));
                    o.push_str("\n");
                    return ok9;
                }
            }
            if y.kind == TypeKind::TYPE_FUNCTION && !self.is_destructible(rm, rt) {
                // A called closure freed its captures in its own body (the call is a move, so no
                // drop survives it); a plain fn pointer owns nothing. Only a closure dropped
                // UNCALLED with owning captures falls through to the env-glue free below.
                return true;
            }
            if y.kind == TypeKind::TYPE_ARRAY {
                let mut pv = self.sget();
                let mut ok = self.emit_place(b, t.a, &mut pv);
                if ok {
                    CEmit::open_drop_guard(o, t);
                    ok = self.array_free(rm, rt, &pv, 0, o);
                    o.push_str(mbe::if_s(t.args_len == 1, " }", ""));
                    o.push_str("\n");
                }
                self.sput(pv);
                return ok;
            }
            if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                let mut fs = self.sget();
                let user = self.user_free_covers(rm, rt);
                if !self.mg.free_target(rm, rt, user, &mut fs) {
                    self.sput(fs);
                    return self.fail("drop");
                }
                if self.collect_demand {
                    self.note_free(rm, rt, fs.as_str());
                }
                let mut pv = self.sget();
                let zdrop = self.mg.is_zst(rm, rt);
                let ok = if zdrop {
                    // No storage exists for the dropped value: its destructor runs on the sentinel.
                    self.zst_sentinel_ref(rm, rt, &mut pv);
                } else {
                    self.emit_place(b, t.a, &mut pv);
                };
                if ok {
                    CEmit::open_drop_guard(o, t);
                    o.push_string(&fs);
                    o.push_str(mbe::if_s(zdrop, "(", "(&"));
                    o.push_string(&pv);
                    o.push_str(");");
                    o.push_str(mbe::if_s(t.args_len == 1, " }", ""));
                    o.push_str("\n");
                }
                self.sput(fs);
                self.sput(pv);
                return ok;
            }
            return true;
        }
        if t.kind == ir::TM_RETURN {
            if t.args_len == ir::RET_CANCEL {
                // A cancellation return: this frame's defers and drops already ran, and every caller
                // on the path is itself unwinding, so the value is never read: spell a zero of the
                // return type rather than the (never-assigned) return slot.
                if self.noret {
                    // A noreturn frame has nothing to unwind to.
                    o.push_str("  abort();\n");
                } else if b.returns == 1 && self.arr_ret {
                    o.push_str("  return (");
                    o.push_string(&self.mret);
                    o.push_str("){0};\n");
                } else if b.returns == 1 && !self.erased(b, b.locals.at(0).ty) {
                    o.push_str("  return (");
                    if !self.ty_c(b.module, b.locals.at(0).ty, "", o) {
                        return false;
                    }
                    o.push_str("){");
                    o.push_str("0");
                    o.push_str("};\n");
                } else if b.returns > 1 {
                    let rz9 = self.stored_returns(b);
                    if rz9 == 0 {
                        o.push_str("  return;\n");
                    } else {
                        o.push_str("  return (");
                        o.push_string(&self.mret);
                        o.push_str("){0};\n");
                    }
                } else {
                    o.push_str("  return;\n");
                }
                return true;
            }
            if b.returns == 1 && self.arr_ret {
                o.push_str("  { ");
                o.push_string(&self.mret);
                o.push_str(" __ar; memcpy(__ar._a, _0, sizeof(__ar._a)); return __ar; }\n");
            } else if b.returns == 1 {
                // A declared `void` return counts as one UNIT slot: no value to spell.
                if self.erased(b, b.locals.at(0).ty) {
                    o.push_str("  return;\n");
                } else {
                    o.push_str("  return _0;\n");
                }
            } else if b.returns > 1 {
                // Zero-sized results have no carrier member (an all-erased pack returned void).
                let rmat9 = self.stored_returns(b);
                if rmat9 == 0 {
                    o.push_str("  return;\n");
                    return true;
                }
                o.push_str("  return (");
                o.push_string(&self.mret);
                o.push_str("){ ");
                let mut re9: u32 = 0;
                for r in 0..b.returns {
                    if self.erased(b, b.locals.at(r as usize).ty) {
                        continue;
                    }
                    if re9 != 0 {
                        o.push_str(", ");
                    }
                    re9 += 1;
                    o.push_str("._");
                    o.push_u64(r);
                    o.push_str(" = ");
                    if *self.sx_inline.at(r as usize) != ir::IR_NONE {
                        if !self.emit_rvalue(b, *self.sx_inline.at(r as usize), o) {
                            return false;
                        }
                    } else {
                        o.push_str("_");
                        o.push_u64(r);
                    }
                }
                o.push_str(" };\n");
            } else if self.noret {
                // A noreturn fn's fall-off edge must not return.
                o.push_str("  abort();\n");
            } else {
                o.push_str("  return;\n");
            }
            return true;
        }
        if t.kind == ir::TM_UNREACHABLE {
            o.push_str("  abort();\n");
            return true;
        }
        if t.kind == ir::TM_ASSERT {
            if self.assert_holds_const(b, t) {
                return true;
            }
            let src = self.p().modules.at(b.module as usize).source.as_str();
            let file = self.p().modules.at(b.module as usize).file.as_str();
            let line = self.src_line(b.module, t.span.start);
            let mut handled = false;
            if !self.emit_forwarded_assert(o, b, t, line, &mut handled) {
                return false;
            }
            if handled {
                return true;
            }
            o.push_str("  if (");
            let mut ok = self.emit_cond_negated(b, t.a, o);
            if !ok {
                return false;
            }
            o.push_str(") { ");
            if t.args_len == 4 {
                // The assert_eq/ne expression spellings ride as CK_STR constants [2] and [3].
                let lsp = *b.constants.at(
                    b.operands.at(b.oper_pool[(t.args_start + 2) as usize] as usize).data as usize,
                );
                let rsp = *b.constants.at(
                    b.operands.at(b.oper_pool[(t.args_start + 3) as usize] as usize).data as usize,
                );
                o.push_str("fprintf(stderr, \"assertion failed: `");
                push_assert_src(src.slice(lsp.raw.start as usize, lsp.raw.end as usize), true, o);
                if t.sw_len == 2 {
                    o.push_str(" == ");
                } else {
                    o.push_str(" != ");
                }
                push_assert_src(src.slice(rsp.raw.start as usize, rsp.raw.end as usize), true, o);
                o.push_str("`\\n\"); ");
                ok = self.assert_value_line(o, b, "left: ", b.oper_pool[t.args_start as usize]) && self.assert_value_line(
                    o,
                    b,
                    "right:",
                    b.oper_pool[(t.args_start + 1) as usize],
                );
                if !ok {
                    return false;
                }
            } else if t.args_len == 1 {
                self.mg.need_name("str".hash(), true);
                o.push_str("const str __scm = ");
                if !self.emit_operand(b, b.oper_pool[t.args_start as usize], o) {
                    return false;
                }
                o.push_str("; fprintf(stderr, \"assertion failed: `");
                push_assert_src(src.slice(t.span.start as usize, t.span.end as usize), true, o);
                o.push_str("`: %.*s\\n\", (int)__scm.len, (const char *)__scm.ptr); ");
            } else {
                o.push_str("fprintf(stderr, \"assertion failed: `");
                push_assert_src(src.slice(t.span.start as usize, t.span.end as usize), true, o);
                o.push_str("`\\n\"); ");
            }
            o.push_str("fprintf(stderr, \"  at ");
            push_fmt_escaped(file, o);
            o.push_str(":");
            o.push_u64(line);
            o.push_str("\\n\"); fflush(stderr); abort(); }\n");
            return true;
        }
        if t.kind == ir::TM_SWITCH {
            return true;
        }
        if t.kind == ir::TM_CALL {
            // An interface-member call whose receiver is a dyn value dispatches through the
            // vtable: no symbol, no call-site prototype. A receiver operand may carry the pair
            // behind references (a generic `&T` with T = Box<dyn I> stays a reference in the
            // body): peel to the pair and spell one `*` per level at the dispatch site.
            let mut dyn_stars: u32 = 0;
            let mut om0 = b.module;
            let mut ot0 = TYPE_NONE;
            let dyn_recv = self.dyn_recv_of(b, t, &mut om0, &mut ot0, &mut dyn_stars);
            if dyn_recv != ir::IR_NONE && !self.dyn_request(om0, ot0) {
                return false;
            }
            if self.collect_demand && dyn_recv == ir::IR_NONE {
                self.collect_extern_proto(b, t);
            }
            // a forwarded destination: this call spells `f(..)` at its single read instead of storing
            // to a temporary, so it emits nothing here and builds the expression into sx_call_str.
            let mut fwd_r = ir::IR_NONE;
            if t.dests_len == 1 && b.places.at(b.dest_pool[t.dests_start as usize] as usize).proj_len == 0 {
                let rb = b.places.at(b.dest_pool[t.dests_start as usize] as usize).base;
                if *self.sx_call_fwd.at(rb as usize) {
                    fwd_r = rb;
                    // The result is used in place: C needs its complete type at the call.
                    self.mg.need_ty(b.module, b.locals.at(rb as usize).ty);
                }
            }
            // Destination analysis up front (no text): the common call then spells straight into
            // the output buffer, and only stashed/sliced/decl-fused forms build a side line.
            let mut want = false;
            let mut arrdst = false; // fixed-array dest: `{ <carrier> __ar = f(..); memcpy(dst, __ar._a, ..); }`
            let mut arrty = self.sget(); // that carrier (`Mangler::ret_pack`)
            let mut fuse_sub = false;
            let mut droot: u32 = 0;
            if t.dests_len == 1 && fwd_r == ir::IR_NONE {
                let dp = b.dest_pool[t.dests_start as usize];
                let dty = b.places.at(dp as usize).ty;
                want = !self.erased(b, dty);
                if dty == TYPE_NONE && t.callee.node != NODE_NONE {
                    // Untyped dest: the callee's declared return count decides.
                    let ca9 = self.p().module_ast_const(t.callee.module);
                    let fd9 = unsafe (*ca9).at_const(t.callee.node);
                    want = fd9.kind == NodeKind::NODE_FUNCTION && fd9.as_data.function.returns.len != 0;
                } else if dty == TYPE_NONE && t.a != ir::IR_NONE {
                    // A function value's several results: its result pack.
                    let mut pk9 = self.sget();
                    want = self.mg.fn_ret_pack(b.module, b.operands.at(t.a as usize).ty, &mut pk9);
                    self.sput(pk9);
                }
                if want && dty != TYPE_NONE && self.arr_n(b, dty) > 0 {
                    let mut rtys = Vector::<TypeId>::new();
                    rtys.push(dty);
                    arrdst = self.mg.ret_pack(b.module, &rtys, &mut arrty);
                }
                if want && !arrdst {
                    let pl = *b.places.at(dp as usize);
                    droot = *self.sx_coal.at(pl.base as usize);
                    fuse_sub = pl.proj_len == 0 && *self.sx_fuse.at(droot as usize) && !*self.sx_declared.at(
                        droot as usize,
                    );
                }
            }
            let plain = fwd_r == ir::IR_NONE && !arrdst && !fuse_sub;
            let mut line = self.sget();
            let mut dplace = self.sget();
            let mut ok = true;
            {
                let sink: &mut String = if plain {
                    &mut *o;
                } else {
                    &mut line;
                };
                if plain {
                    sink.push_str("  ");
                }
                if t.dests_len == 1 && fwd_r == ir::IR_NONE {
                    let dp = b.dest_pool[t.dests_start as usize];
                    if want && arrdst {
                        ok = self.emit_place(b, dp, &mut dplace);
                    } else if want {
                        if fuse_sub {
                            let mut lhs = self.sget();
                            ok = self.emit_place(b, dp, &mut lhs);
                            if ok {
                                let mut decl = self.sget();
                                let lty = b.locals.at(droot as usize).ty;
                                if lty == TYPE_NONE {
                                    ok = self.untyped_ret_struct(b, droot, &mut decl);
                                    if ok {
                                        decl.push_str(" ");
                                        decl.push_string(&lhs);
                                    }
                                } else {
                                    ok = self.ty_c(b.module, lty, lhs.as_str(), &mut decl);
                                }
                                if ok {
                                    self.sx_declared.set(droot as usize, true);
                                    sink.push_string(&decl);
                                }
                                self.sput(decl);
                            }
                            self.sput(lhs);
                        } else {
                            ok = self.emit_place(b, dp, sink);
                        }
                        sink.push_str(" = ");
                    }
                }
                // a capturing closure value calls its hoisted function with the env first; a dyn fn
                // value dispatches through its vtable's `call` slot.
                let mut env_first = false;
                let mut dyn_val = false;
                if ok && t.callee.node == NODE_NONE {
                    let cop = *b.operands.at(t.a as usize);
                    let mut cmV = b.module;
                    let mut ctV = cop.ty;
                    self.rty(b, cop.ty, &mut cmV, &mut ctV);
                    let cy = *unsafe (*self.p().module_ast_const(cmV)).type_at(ctV);
                    if cy.kind == TypeKind::TYPE_DYN {
                        ok = self.dyn_request(cmV, ctV);
                        if ok {
                            ok = self.emit_operand(b, t.a, sink);
                        }
                        sink.push_str(".vt->call");
                        dyn_val = true;
                    } else if cy.kind == TypeKind::TYPE_FUNCTION {
                        let cf = unsafe (*self.p().module_ast_const(cy.module)).closure_fact(cy.as_data.decl);
                        if cf != null && unsafe (&*cf).ncaps != 0 {
                            self.mg.closure_sym(cy.module, cy.as_data.decl, sink);
                            env_first = true;
                        }
                    }
                    if ok && !env_first && !dyn_val {
                        ok = self.emit_operand(b, t.a, sink);
                    }
                } else if ok && dyn_recv != ir::IR_NONE {
                    ok = self.emit_dyn_recv(b, dyn_recv, dyn_stars, sink);
                    sink.push_str(".vt->");
                    let ca0 = self.p().module_ast_const(t.callee.module);
                    self.mg.ident(
                        t.callee.module,
                        unsafe (*ca0).at_const(unsafe (*ca0).at_const(t.callee.node).as_data.function.name).as_data.name.text,
                        sink,
                    );
                } else if ok && self.counted_call(b, t) {
                    sink.push_str("(uint32_t)"); // the comparison wrote the count
                } else if ok {
                    ok = self.term_callee_sym(b, t, true, sink);
                }
                if ok {
                    sink.push_str("(");
                    let mut na9: u32 = 0; // arguments spelled (zero-sized ones take no slot)
                    if env_first {
                        sink.push_str("&");
                        ok = self.emit_operand(b, t.a, sink);
                        na9 += 1;
                    }
                    if dyn_val {
                        ok = self.emit_operand(b, t.a, sink);
                        sink.push_str(".data");
                        na9 += 1;
                    }
                    for i in 0..t.args_len {
                        if !ok {
                            break;
                        }
                        if dyn_recv != ir::IR_NONE && i == 0 {
                            // The erased receiver: its data pointer takes the self slot.
                            ok = self.emit_dyn_recv(b, dyn_recv, dyn_stars, sink);
                            sink.push_str(".data");
                            na9 += 1;
                            continue;
                        }
                        let opid2 = b.oper_pool[(t.args_start + i) as usize];
                        if self.arg_slot_erased(b, t.callee, i, opid2) {
                            // Zero-sized by-value argument: no C slot (operands are pure).
                            continue;
                        }
                        if na9 != 0 {
                            sink.push_str(", ");
                        }
                        na9 += 1;
                        ok = self.emit_call_arg(b, t.callee, i, opid2, sink);
                    }
                }
            }
            if ok && fwd_r != ir::IR_NONE {
                // `line` is `f(args` (no destination, no closing paren): close it and stash it for the
                // single read to spell. The call itself emits nothing here.
                line.push_str(")");
                let off = self.sx_cs_pool.len() as u32;
                self.sx_cs_pool.push_string(&line);
                let root = *self.sx_coal.at(fwd_r as usize);
                if root != fwd_r {
                    self.sx_cs_off.set(root as usize, off);
                    self.sx_cs_len.set(root as usize, line.len() as u32);
                }
                self.sx_cs_off.set(fwd_r as usize, off);
                self.sx_cs_len.set(fwd_r as usize, line.len() as u32);
            } else if ok && arrdst {
                o.push_str("  { ");
                o.push_string(&arrty);
                o.push_str(" __ar = ");
                o.push_string(&line);
                o.push_str("); memcpy(");
                o.push_string(&dplace);
                o.push_str(", __ar._a, sizeof(__ar._a)); }\n");
            } else if ok && plain {
                o.push_str(");\n");
            } else if ok {
                o.push_str("  ");
                o.push_string(&line);
                o.push_str(");\n");
            }
            self.sput(line);
            self.sput(dplace);
            self.sput(arrty);
            return ok;
        }
        return self.fail("terminator");
    }
}

// FNV-1a hash of an identifier: the key of the reserved-name set (dedup + O(1) lookup).
const fn ident_in(nm: str, v: &Map<u64, u64>) bool {
    return v.contains_key(&nm.hash());
}

// Append the hash of every maximal C-identifier run in `s` (the typedef names inside a spelled
// type) to `out`.
fn collect_ident_hashes(s: str, out: &mut Vector<u64>) {
    let mut i = 0 as usize;
    while i < s.len() {
        let c = s.byte_at(i);
        if c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 {
            let start = i;
            while i < s.len() {
                let d = s.byte_at(i);
                if d >= 48 && d <= 57 || d >= 65 && d <= 90 || d >= 97 && d <= 122 || d == 95 {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(s.slice(start, i).hash());
        } else {
            i += 1;
        }
    }
}

/// A numeric literal's C spelling: its prefix, digits, point and exponent exactly, minus the
/// digit separators and the width suffix C cannot parse (`0x1Fu8` -> `0x1F`, `1_000` -> `1000`).
/// The longest string literal C11 guarantees (5.2.4.1): 4095 bytes. A longer string constant
/// spells as an array of its bytes.
pub const STR_LIT_MAX: usize = 4095;

/// `{ (const uint8_t *)<lit>, sizeof(<lit>) - 1 }`: a `str` view initializer over C string data
/// `lit`, a string literal or the name of an array holding the bytes and a terminating 0.
pub fn push_c_str_view(lit: str, dst: &mut String) {
    dst.push_str("{ (const uint8_t *)");
    dst.push_str(lit);
    dst.push_str(", sizeof(");
    dst.push_str(lit);
    dst.push_str(") - 1 }");
}

/// A file-scope `str` view initializer over string bytes `bytes`: over a C string literal, or past
/// STR_LIT_MAX bytes over a compound literal array of the bytes and a terminating 0 (outside a
/// function a compound literal has static storage).
pub fn push_c_str_data(bytes: str, dst: &mut String) {
    if bytes.len() > STR_LIT_MAX {
        dst.push_str("{ (const uint8_t[]){");
        push_c_byte_list(bytes, dst);
        dst.push_str("}, ");
        dst.push_u64(bytes.len() as u64);
        dst.push_str(" }");
        return;
    }
    let mut lit = String::from_str("\"");
    push_c_escaped(bytes, &mut lit);
    lit.push_str("\"");
    push_c_str_view(lit.as_str(), dst);
}

/// `bytes` and a terminating 0 as a C initializer list: 32 decimal values per line, each line on a
/// new line indented four spaces, then a newline.
fn push_c_byte_list(bytes: str, dst: &mut String) {
    for i in 0..bytes.len() + 1 {
        dst.push_str(mbe::if_s(i % 32 == 0, "\n    ", " "));
        if i == bytes.len() {
            dst.push_str("0\n");
        } else {
            dst.push_u64(bytes.byte_at(i));
            dst.push_str(",");
        }
    }
}

/// The bytes of string constant text `raw` (the constant's source span) in literal form `form`: the
/// token kind in the low byte, bit 8 set for a FORMAT SEGMENT, whose `{{`/`}}` collapse to one
/// brace. A span keeps its quotes, byte-string prefix or matchertext frame, or has none. Quoted and
/// byte-string bodies decode their escapes; matchertext and raw bodies are the bytes themselves.
/// `tmp` is scratch.
pub fn str_const_bytes(raw: str, form: i64, tmp: &mut String, out: &mut String) {
    let tk = form & 255;
    let seg = (form & 256) != 0;
    let mut r = raw;
    if tk == tt::TokenType::ByteStringLiteral as i64 && r.len() >= 1 && r.byte_at(0) == b'b' {
        // Strip the `b` prefix; the quotes fall to the next check.
        r = r.slice(1, r.len());
    }
    if r.len() >= 2 && r.byte_at(0) == 34 && r.byte_at(r.len() - 1) == 34 {
        r = r.slice(1, r.len() - 1);
    } else if r.len() >= 5 && r.byte_at(0) == b'M' && r.byte_at(r.len() - 1) == 34 {
        // `M`, a delimiter chain, a quote, then the outer matcher pair around the text.
        let mut q: usize = 1;
        while q < r.len() && r.byte_at(q) != 34 {
            q += 1;
        }
        let n = r.len();
        if q + 4 <= n && mt_pair(r.byte_at(q + 1), r.byte_at(n - 2)) {
            r = r.slice(q + 2, n - 2);
        }
    }
    if seg && (tk == tt::TokenType::StringLiteral as i64 || tk == tt::TokenType::RawStringLiteral as i64) {
        tmp.truncate(0);
        let mut i: usize = 0;
        while i < r.len() {
            let c = r.byte_at(i);
            tmp.push_byte(c);
            if (c == 123 || c == 125) && i + 1 < r.len() && r.byte_at(i + 1) == c {
                i += 2;
            } else {
                i += 1;
            }
        }
        r = tmp.as_str();
    }
    if tk == tt::TokenType::StringLiteral as i64 || tk == tt::TokenType::ByteStringLiteral as i64 {
        sc_str_decode(r, out);
    } else {
        out.push_str(r);
    }
}

// Are `o` and `c` a matchertext matcher pair?
const fn mt_pair(o: u8, c: u8) bool {
    return o == b'(' && c == b')' || o == b'[' && c == b']' || o == b'{' && c == b'}';
}

/// Float literal text `txt` as a C literal: the exact spelling without `_` separators, the language
/// width suffix mapped to C's. An unsuffixed literal typed f32 (`single`) gets C's `f`, so the C
/// compiler rounds it once from the text, as compile-time evaluation does.
pub fn push_c_float_lit(txt: str, single: bool, dst: &mut String) {
    let n = txt.len();
    let mut t = txt;
    let mut sfx = "";
    if n > 3 && txt.slice(n - 3, n) == "f32" {
        t = txt.slice(0, n - 3);
        sfx = "f";
    } else if n > 3 && txt.slice(n - 3, n) == "f64" {
        t = txt.slice(0, n - 3);
    } else if single {
        sfx = pick(float_marked(txt), "f", ".0f");
    }
    for i in 0..t.len() {
        if t[i] != b'_' {
            dst.push_byte(t[i]);
        }
    }
    dst.push_str(sfx);
}

pub fn push_c_number(txt: str, dst: &mut String) {
    let n = txt.len();
    // C11 has no `0o` or `0b` prefix: an octal or binary integer is spelled in hex, same value (the
    // checker guarantees it fits u64).
    if n > 2 && txt.byte_at(0) == 48 && (txt.byte_at(1) == 111 || txt.byte_at(1) == 98) {
        let shift: u64 = if txt.byte_at(1) == 111 {
            3u64;
        } else {
            1u64;
        };
        let mut v: u64 = 0;
        let mut i: usize = 2;
        while i < n {
            let ch = txt.byte_at(i);
            if ch != 95 {
                if ch < 48 || ch > 55 {
                    break;
                }
                v = v << shift | (ch - 48) as u64;
            }
            i += 1;
        }
        dst.push_str("0x");
        dst.push_hex(v, false);
        return;
    }
    let hex = n > 2 && txt.byte_at(0) == 48 && (txt.byte_at(1) == 120 || txt.byte_at(1) == 88);
    let mut i: usize = 0;
    while i < n {
        let ch = txt.byte_at(i);
        let body = ch >= 48 && ch <= 57 || ch == 95 || ch == 46 || i < 2 && (ch == 120 || ch == 98 || ch == 111) || hex && (ch >= 97 && ch <= 102 || ch >= 65 && ch <= 70) || !hex && (ch == 101 || ch == 69 || ch == 43 || ch == 45);
        if !body {
            break;
        }
        if ch != 95 {
            dst.push_byte(ch);
        }
        i += 1;
    }
}

/// The most bytes of an expression's source an assertion message spells: two of them and the
/// message text stay under STR_LIT_MAX.
const ASSERT_SRC_MAX: usize = 1000;

/// Expression source `txt` in an assertion message, escaped for an fprintf format (`fmt`) or a
/// plain C string: past ASSERT_SRC_MAX bytes, cut at a character boundary and ended with `...`.
fn push_assert_src(txt: str, fmt: bool, dst: &mut String) {
    let mut n = txt.len();
    if n > ASSERT_SRC_MAX {
        n = ASSERT_SRC_MAX;
        while n > 0 && (txt.byte_at(n) & 0xC0) == 0x80 {
            n -= 1;
        }
    }
    if fmt {
        push_fmt_escaped(txt.slice(0, n), dst);
    } else {
        push_c_escaped(txt.slice(0, n), dst);
    }
    if n < txt.len() {
        dst.push_str("...");
    }
}

/// Escape source text into an fprintf FORMAT string: C-escape quotes/backslashes/controls and
/// double `%` so spelled operators never read as conversions.
fn push_fmt_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        let b = txt.byte_at(i);
        if b == 37 {
            dst.push_str("%%");
        } else if b == 34 {
            dst.push_str("\\\"");
        } else if b == 92 {
            dst.push_str("\\\\");
        } else if b == 10 {
            dst.push_str("\\n");
        } else if b < 32 {
            dst.push_str(" ");
        } else {
            dst.push_byte(b);
        }
    }
}

/// Raw bytes into a C string literal: printable ASCII stays, specials get named escapes, the rest
/// three-digit octal (fixed width, so a following digit can never extend the escape).
pub fn push_c_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        push_c_escaped_byte(txt.byte_at(i), dst);
    }
}

/// One raw byte of `push_c_escaped`.
fn push_c_escaped_byte(b: u8, dst: &mut String) {
    if b == 34 {
        dst.push_str("\\\"");
    } else if b == 92 {
        dst.push_str("\\\\");
    } else if b == 10 {
        dst.push_str("\\n");
    } else if b == 13 {
        dst.push_str("\\r");
    } else if b == 9 {
        dst.push_str("\\t");
    } else if b >= 32 && b <= 126 {
        dst.push_byte(b);
    } else {
        dst.push_str("\\");
        dst.push_byte(48 + (b >> 6 & 7));
        dst.push_byte(48 + (b >> 3 & 7));
        dst.push_byte(48 + (b & 7));
    }
}

const fn hexv(b: u8) u32 {
    if b >= 48 && b <= 57 {
        return b - 48;
    }
    if b >= 97 && b <= 102 {
        return b - 97 + 10;
    }
    if b >= 65 && b <= 70 {
        return b - 65 + 10;
    }
    return 0;
}

// Codepoint `cp` as UTF-8.
fn push_utf8(cp: u32, dst: &mut String) {
    if cp < 0x80 {
        dst.push_byte(cp as u8);
    } else if cp < 0x800 {
        dst.push_byte((0xC0 | cp >> 6) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else if cp < 0x10000 {
        dst.push_byte((0xE0 | cp >> 12) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else {
        dst.push_byte((0xF0 | cp >> 18) as u8);
        dst.push_byte((0x80 | cp >> 12 & 0x3F) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    }
}

// The bytes of a Super-C quoted/byte-string body (escapes intact): each escape decodes to its
// byte(s) (`\xNN` is EXACTLY two hex digits, `\u{H..}` a codepoint as UTF-8).
fn sc_str_decode(raw: str, dst: &mut String) {
    let mut i: usize = 0;
    while i < raw.len() {
        let b = raw.byte_at(i);
        if b != 92 || i + 1 >= raw.len() {
            dst.push_byte(b);
            i += 1;
            continue;
        }
        let e = raw.byte_at(i + 1);
        i += 2;
        if e == b'n' {
            dst.push_byte(10);
        } else if e == b'r' {
            dst.push_byte(13);
        } else if e == b't' {
            dst.push_byte(9);
        } else if e == b'0' {
            dst.push_byte(0);
        } else if e == b'x' && i + 1 < raw.len() {
            dst.push_byte((hexv(raw.byte_at(i)) << 4 | hexv(raw.byte_at(i + 1))) as u8);
            i += 2;
        } else if e == b'u' && i < raw.len() && raw.byte_at(i) == b'{' {
            i += 1;
            let mut cp: u32 = 0;
            while i < raw.len() && raw.byte_at(i) != b'}' {
                cp = cp << 4 | hexv(raw.byte_at(i));
                i += 1;
            }
            if i < raw.len() {
                i += 1;
            }
            push_utf8(cp, dst);
        } else {
            // `\\`, `\"`, `\'`: the escaped byte itself.
            dst.push_byte(e);
        }
    }
}

// Does float literal text `t` carry a fraction, an exponent or a binary exponent (so a C `f` suffix
// may follow it)?
fn float_marked(t: str) bool {
    for i in 0..t.len() {
        let ch = t.byte_at(i);
        if ch == b'.' || ch == b'e' || ch == b'E' || ch == b'p' || ch == b'P' {
            return true;
        }
    }
    return false;
}

// The FNV-1a step over definition `d`: the seed of a demand fingerprint.
const fn def_fp(d: DefId) u64 {
    return (0xcbf29ce484222325u64 ^ (d.module as u64 << 32 | d.node as u64)).wrapping_mul(1099511628211u64);
}

// The C type of a lane builtin.
const fn lane_c(bt: BuiltinType) str<'static> {
    return switch bt {
        BT_I8 => "int8_t",
        BT_I16 => "int16_t",
        BT_I32 => "int32_t",
        BT_I64 => "int64_t",
        BT_U8 => "uint8_t",
        BT_U16 => "uint16_t",
        BT_U32 => "uint32_t",
        BT_U64 => "uint64_t",
        BT_F32 => "float",
        _ => "double",
    };
}

// The `<stdint.h>` limit of an integer lane builtin: its maximum (`max`) or minimum.
const fn lane_limit(bt: BuiltinType, max: bool) str<'static> {
    return switch bt {
        BT_I8 => mbe::if_s(max, "INT8_MAX", "INT8_MIN"),
        BT_I16 => mbe::if_s(max, "INT16_MAX", "INT16_MIN"),
        BT_I32 => mbe::if_s(max, "INT32_MAX", "INT32_MIN"),
        BT_I64 => mbe::if_s(max, "INT64_MAX", "INT64_MIN"),
        BT_U8 => mbe::if_s(max, "UINT8_MAX", "0"),
        BT_U16 => mbe::if_s(max, "UINT16_MAX", "0"),
        BT_U32 => mbe::if_s(max, "UINT32_MAX", "0"),
        _ => mbe::if_s(max, "UINT64_MAX", "0"),
    };
}

// The C statement of lane `__sc_i` of a vector operator (`unary`: RV_UNARY) on lanes of `bt`, with
// the placeholders of `emit_vec_lanes`; "" when the operator has none. A trap sets bit `__sc_i` of
// `__sc_f0`, or of `__sc_f1` for the second failure kind of `/` and `%`, by a predicate on the lane
// values (no `__builtin_*_overflow` below 64-bit products: the C compiler vectorizes the predicates).
const fn vec_op_tpl(unary: bool, op: u8, bt: BuiltinType) str<'static> {
    let fl = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
    let sg = int_signed(bt);
    let t = op as tt::TokenType;
    if unary {
        if t == tt::TokenType::Minus {
            return mbe::if_s(fl, "$d = -$a;", "$d = ($T)(0u - ($P)$a); __sc_f0 |= (uint64_t)($a == $X) << __sc_i;");
        }
        return mbe::if_s(fl || t != tt::TokenType::Tilde, "", "$d = ($T)~($P)$a;");
    }
    if fl {
        return switch t {
            Plus => "$d = $a + $b;",
            Minus => "$d = $a - $b;",
            Star => "$d = $a * $b;",
            Slash => "$d = $a / $b;",
            _ => "",
        };
    }
    let wide = bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_U64;
    return switch t {
        Plus => mbe::if_s(
            sg,
            "$T __sc_s = ($T)(($P)$a + ($P)$b); $d = __sc_s; __sc_f0 |= (uint64_t)((($a ^ __sc_s) & ($b ^ __sc_s)) < 0) << __sc_i;",
            "$T __sc_s = ($T)($a + $b); $d = __sc_s; __sc_f0 |= (uint64_t)(__sc_s < $a) << __sc_i;",
        ),
        Minus => mbe::if_s(
            sg,
            "$T __sc_s = ($T)(($P)$a - ($P)$b); $d = __sc_s; __sc_f0 |= (uint64_t)((($a ^ $b) & ($a ^ __sc_s)) < 0) << __sc_i;",
            "$d = ($T)($a - $b); __sc_f0 |= (uint64_t)($a < $b) << __sc_i;",
        ),
        Star => if wide {
            "$T __sc_w; __sc_f0 |= (uint64_t)__builtin_mul_overflow($a, $b, &__sc_w) << __sc_i; $d = __sc_w;";
        } else if sg {
            "int64_t __sc_s = (int64_t)$a * $b; $d = ($T)__sc_s; __sc_f0 |= (uint64_t)(__sc_s < $X || __sc_s > $Y) << __sc_i;";
        } else {
            "uint64_t __sc_s = (uint64_t)$a * $b; $d = ($T)__sc_s; __sc_f0 |= (uint64_t)(__sc_s > $Y) << __sc_i;";
        },
        Slash => mbe::if_s(
            sg,
            "__sc_f0 |= (uint64_t)($b == 0) << __sc_i; __sc_f1 |= (uint64_t)($b == -1 && $a == $X) << __sc_i; $d = $b == 0 || ($b == -1 && $a == $X) ? 0 : $a / $b;",
            "__sc_f0 |= (uint64_t)($b == 0) << __sc_i; $d = $b == 0 ? 0 : $a / $b;",
        ),
        Percent => mbe::if_s(
            sg,
            "__sc_f0 |= (uint64_t)($b == 0) << __sc_i; __sc_f1 |= (uint64_t)($b == -1 && $a == $X) << __sc_i; $d = $b == 0 || $b == -1 ? 0 : $a % $b;",
            "__sc_f0 |= (uint64_t)($b == 0) << __sc_i; $d = $b == 0 ? 0 : $a % $b;",
        ),
        Ampersand => "$d = $a & $b;",
        Pipe => "$d = $a | $b;",
        Caret => "$d = $a ^ $b;",
        LeftShift => mbe::if_s(
            sg,
            "__sc_f0 |= (uint64_t)($b < 0 || $b >= $W) << __sc_i; $d = ($T)(($P)$a << ($b & ($W - 1)));",
            "__sc_f0 |= (uint64_t)($b >= $W) << __sc_i; $d = ($T)(($P)$a << ($b & ($W - 1)));",
        ),
        RightShift => mbe::if_s(
            sg,
            "__sc_f0 |= (uint64_t)($b < 0 || $b >= $W) << __sc_i; $d = ($T)($a >> ($b & ($W - 1)));",
            "__sc_f0 |= (uint64_t)($b >= $W) << __sc_i; $d = ($T)($a >> ($b & ($W - 1)));",
        ),
        _ => "",
    };
}

// The C statement of lane `__sc_i` of a lane-wise `as` from lanes of `bt` to lanes of `rbt`
// (operations.md: a float to an integer saturates through `__sc_f2i_*`).
const fn vec_cast_tpl(bt: BuiltinType, rbt: BuiltinType) str<'static> {
    let ff = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
    let tf = rbt == BuiltinType::BT_F32 || rbt == BuiltinType::BT_F64;
    return mbe::if_s(ff && !tf, "$d = __sc_f2i_$N($a);", "$d = ($R)$a;");
}

// The mask bit of lane `__sc_i` of SIMD_CAST_CHANGED: `$a` the source lane of `bt`, `$b` its cast to
// `rbt`; set when the value changed or the source is a NaN.
const fn vec_changed_tpl(bt: BuiltinType, rbt: BuiltinType) str<'static> {
    let ff = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
    let tf = rbt == BuiltinType::BT_F32 || rbt == BuiltinType::BT_F64;
    if ff && tf {
        return "__sc_m |= (uint64_t)!($a == $a && ($T)$b == $a) << __sc_i;";
    }
    if ff {
        return "__sc_m |= (uint64_t)!($a >= $L && $a < $H && trunc$F($a) == $a) << __sc_i;";
    }
    if tf {
        return "__sc_m |= (uint64_t)!($b >= $L && $b < $H && ($T)$b == $a) << __sc_i;";
    }
    if int_signed(bt) && !int_signed(rbt) {
        return "__sc_m |= (uint64_t)(($T)$b != $a || $a < 0) << __sc_i;";
    }
    if !int_signed(bt) && int_signed(rbt) {
        return "__sc_m |= (uint64_t)(($T)$b != $a || $b < 0) << __sc_i;";
    }
    return "__sc_m |= (uint64_t)(($T)$b != $a) << __sc_i;";
}

// The C statement of lane `__sc_i` of RV_SIMD code `c` over lanes of `bt` with result lanes `rbt`
// (the placeholders of `emit_vec_lanes`); "" for a code without a lane loop.
const fn vec_simd_tpl(c: u8, bt: BuiltinType, rbt: BuiltinType) str<'static> {
    let fl = bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64;
    let sg = int_signed(bt);
    if c >= ir::SIMD_CMP_EQ && c <= ir::SIMD_CMP_GE {
        let cmp: []str = [
            "__sc_m |= (uint64_t)($a == $b) << __sc_i;",
            "__sc_m |= (uint64_t)($a != $b) << __sc_i;",
            "__sc_m |= (uint64_t)($a < $b) << __sc_i;",
            "__sc_m |= (uint64_t)($a <= $b) << __sc_i;",
            "__sc_m |= (uint64_t)($a > $b) << __sc_i;",
            "__sc_m |= (uint64_t)($a >= $b) << __sc_i;",
        ];
        return cmp[(c - ir::SIMD_CMP_EQ) as usize];
    }
    if c == ir::SIMD_NARROW_CHECKED {
        if sg && !int_signed(rbt) {
            return "$d = ($R)$a; __sc_f0 |= (uint64_t)(($T)$d != $a || $a < 0) << __sc_i;";
        }
        if !sg && int_signed(rbt) {
            return "$d = ($R)$a; __sc_f0 |= (uint64_t)(($T)$d != $a || $d < 0) << __sc_i;";
        }
        return "$d = ($R)$a; __sc_f0 |= (uint64_t)(($T)$d != $a) << __sc_i;";
    }
    if c == ir::SIMD_NARROW_SAT {
        if !sg {
            return "$d = $a > $y ? $y : ($R)$a;";
        }
        return mbe::if_s(
            int_signed(rbt),
            "$d = $a < $x ? $x : $a > $y ? $y : ($R)$a;",
            "$d = $a < 0 ? 0 : $a > $y ? $y : ($R)$a;",
        );
    }
    if c == ir::SIMD_BSWAP {
        return switch bt {
            BT_I8 | BT_U8 => "$d = $a;",
            BT_I16 | BT_U16 => "$d = ($T)__builtin_bswap16(($U)$a);",
            BT_I32 | BT_U32 => "$d = ($T)__builtin_bswap32(($U)$a);",
            _ => "$d = ($T)__builtin_bswap64(($U)$a);",
        };
    }
    if fl {
        return switch c {
            // `a` when `b` is NaN (quieted when both are), when it is less, or for zeros of both signs
            // `-0.0`; else `b` (also when only `a` is NaN).
            ir::SIMD_MIN => "$d = $b != $b ? ($a != $a ? __sc_qnan($a) : $a) : $a < $b || ($a == $b && signbit($a)) ? $a : $b;",
            ir::SIMD_MAX => "$d = $b != $b ? ($a != $a ? __sc_qnan($a) : $a) : $a > $b || ($a == $b && !signbit($a)) ? $a : $b;",
            ir::SIMD_MINIMUM => "$d = $a != $a ? $a : $b != $b ? $b : $a < $b ? $a : $b < $a ? $b : signbit($a) ? $a : $b;",
            ir::SIMD_MAXIMUM => "$d = $a != $a ? $a : $b != $b ? $b : $a > $b ? $a : $b > $a ? $b : signbit($a) ? $b : $a;",
            ir::SIMD_ABS => "$d = fabs$F($a);",
            ir::SIMD_COPYSIGN => "$d = copysign$F($a, $b);",
            ir::SIMD_SQRT => "$d = sqrt$F($a);",
            ir::SIMD_CEIL => "$d = ceil$F($a);",
            ir::SIMD_FLOOR => "$d = floor$F($a);",
            ir::SIMD_TRUNC => "$d = trunc$F($a);",
            ir::SIMD_ROUND_EVEN => "$d = nearbyint$F($a);",
            ir::SIMD_FMA => "$d = fma$F($a, $b, $c);",
            ir::SIMD_IS_NAN => "__sc_m |= (uint64_t)($a != $a) << __sc_i;",
            ir::SIMD_IS_INF => "__sc_m |= (uint64_t)(isinf($a) != 0) << __sc_i;",
            ir::SIMD_IS_FINITE => "__sc_m |= (uint64_t)(isfinite($a) != 0) << __sc_i;",
            ir::SIMD_IS_NORMAL => "__sc_m |= (uint64_t)(isnormal($a) != 0) << __sc_i;",
            ir::SIMD_IS_SUBNORMAL => "__sc_m |= (uint64_t)(fpclassify($a) == FP_SUBNORMAL) << __sc_i;",
            ir::SIMD_IS_SIGN_NEG => "__sc_m |= (uint64_t)(signbit($a) != 0) << __sc_i;",
            ir::SIMD_IOTA => "$d = ($T)__sc_i;",
            ir::SIMD_CHOOSE => "$d = (($a >> __sc_i) & 1) ? $b : $c;",
            _ => "",
        };
    }
    return switch c {
        ir::SIMD_IOTA => "$d = ($T)__sc_i;",
        ir::SIMD_CHOOSE => "$d = (($a >> __sc_i) & 1) ? $b : $c;",
        ir::SIMD_WRAP_ADD => "$T __sc_w; (void)__builtin_add_overflow($a, $b, &__sc_w); $d = __sc_w;",
        ir::SIMD_WRAP_SUB => "$T __sc_w; (void)__builtin_sub_overflow($a, $b, &__sc_w); $d = __sc_w;",
        ir::SIMD_WRAP_MUL => "$T __sc_w; (void)__builtin_mul_overflow($a, $b, &__sc_w); $d = __sc_w;",
        ir::SIMD_WRAP_NEG => "$d = ($T)(0u - ($P)$a);",
        ir::SIMD_WRAP_SHL => "$d = ($T)(($P)$a << ($b & ($W - 1)));",
        ir::SIMD_WRAP_SHR => "$d = ($T)($a >> ($b & ($W - 1)));",
        ir::SIMD_OVF_ADD => "{ $T __sc_r; __sc_m |= (uint64_t)__builtin_add_overflow($a, $b, &__sc_r) << __sc_i; }",
        ir::SIMD_OVF_SUB => "{ $T __sc_r; __sc_m |= (uint64_t)__builtin_sub_overflow($a, $b, &__sc_r) << __sc_i; }",
        ir::SIMD_OVF_MUL => "{ $T __sc_r; __sc_m |= (uint64_t)__builtin_mul_overflow($a, $b, &__sc_r) << __sc_i; }",
        ir::SIMD_SAT_ADD => mbe::if_s(
            sg,
            "$T __sc_s = ($T)(($P)$a + ($P)$b); $d = (($a ^ __sc_s) & ($b ^ __sc_s)) < 0 ? ($b < 0 ? $X : $Y) : __sc_s;",
            "$T __sc_s = ($T)($a + $b); $d = __sc_s < $a ? $Y : __sc_s;",
        ),
        ir::SIMD_SAT_SUB => mbe::if_s(
            sg,
            "$T __sc_s = ($T)(($P)$a - ($P)$b); $d = (($a ^ $b) & ($a ^ __sc_s)) < 0 ? ($b < 0 ? $Y : $X) : __sc_s;",
            "$d = $a < $b ? 0 : ($T)($a - $b);",
        ),
        ir::SIMD_MIN => "$d = $a < $b ? $a : $b;",
        ir::SIMD_MAX => "$d = $a > $b ? $a : $b;",
        ir::SIMD_ABS => "__sc_f0 |= (uint64_t)($a == $X) << __sc_i; $d = $a < 0 ? ($T)(0u - ($P)$a) : $a;",
        ir::SIMD_WRAP_ABS => "$d = $a < 0 ? ($T)(0u - ($P)$a) : $a;",
        ir::SIMD_ABS_DIFF => "$d = $a > $b ? ($R)(($P)$a - ($P)$b) : ($R)(($P)$b - ($P)$a);",
        ir::SIMD_CLZ => "$d = ($T)(sc_clz64((uint64_t)($U)$a) - (64 - $W));",
        ir::SIMD_CTZ => "$d = ($T)($a == 0 ? $Wu : sc_ctz64((uint64_t)($U)$a));",
        ir::SIMD_POPCNT => "$d = ($T)sc_popcount64((uint64_t)($U)$a);",
        ir::SIMD_ROTL => "{ $P __sc_x = ($U)$a; unsigned __sc_n = (unsigned)$b & ($W - 1); $d = ($T)($U)((__sc_x << __sc_n) | (__sc_x >> (($W - __sc_n) & ($W - 1)))); }",
        ir::SIMD_ROTR => "{ $P __sc_x = ($U)$a; unsigned __sc_n = (unsigned)$b & ($W - 1); $d = ($T)($U)((__sc_x >> __sc_n) | (__sc_x << (($W - __sc_n) & ($W - 1)))); }",
        ir::SIMD_BITREV => "$d = ($T)(sc_bitrev64((uint64_t)($U)$a) >> (64 - $W));",
        _ => "",
    };
}

const fn int_signed(bt: BuiltinType) bool {
    return bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE;
}

// The inputs of CEmit::cmp_fold for one comparison operand: every value it can take, `lo..=hi` as
// 64-bit patterns read unsigned when `uns` is set (one value when `konst`), and the signedness and
// width in bits of its C type after integer promotion.
struct CmpSide {
    pub lo: i64,
    pub hi: i64,
    pub uns: bool,
    pub konst: bool,
    pub c_uns: bool,
    pub c_w: u32,
}

// The order of two exact integers, each a 64-bit pattern read unsigned when its flag is set: -1, 0
// or 1.
const fn exact_cmp(a: i64, au: bool, b: i64, bu: bool) i32 {
    let an = !au && a < 0;
    let bn = !bu && b < 0;
    if an != bn {
        return if an {
            -1;
        } else {
            1;
        };
    }
    if a == b {
        return 0;
    }
    // Both negative compare signed, both non-negative compare as unsigned patterns.
    let less = if an {
        a < b;
    } else {
        a as u64 < b as u64;
    };
    return if less {
        -1;
    } else {
        1;
    };
}

// A comparison result: 1 when `yes`, 0 when `no`, -1 when neither decides it.
const fn fold_result(yes: bool, no: bool) i32 {
    if yes {
        return 1;
    }
    if no {
        return 0;
    }
    return -1;
}

// `l op r` over constants, as C computes it, into `s`: a shift in the promoted type of `l`, any other
// operator in the usual arithmetic conversion of both. False for an operator this does not model
// or a result C leaves undefined.
const fn c_const_op(t: tt::TokenType, l: &CmpSide, r: &CmpSide, s: &mut CmpSide) bool {
    let shift = t == tt::TokenType::LeftShift || t == tt::TokenType::RightShift;
    let uns = if shift || l.c_uns == r.c_uns {
        l.c_uns;
    } else if l.c_uns {
        l.c_w >= r.c_w;
    } else {
        r.c_w >= l.c_w;
    };
    let w = if shift || l.c_w >= r.c_w {
        l.c_w;
    } else {
        r.c_w;
    };
    // Each operand's value in the operation type: a bit pattern of width `w` when it is unsigned.
    let a = wrap_to(l.lo, w, uns);
    let bv = wrap_to(r.lo, w, uns);
    let mut v: i64 = 0;
    if shift {
        if !r.uns && r.lo < 0 || r.lo as u64 >= w as u64 {
            return false;
        }
        if t == tt::TokenType::RightShift {
            v = if uns {
                (a as u64 >> r.lo as u64) as i64;
            } else {
                a >> r.lo;
            };
        } else if uns {
            v = (a as u64 << r.lo as u64) as i64;
        } else {
            // A signed left shift can overflow; the emitter spells it as a helper.
            return false;
        }
    } else if t == tt::TokenType::Ampersand {
        v = a & bv;
    } else if t == tt::TokenType::Pipe {
        v = a | bv;
    } else if t == tt::TokenType::Caret {
        v = a ^ bv;
    } else if t == tt::TokenType::Slash || t == tt::TokenType::Percent {
        if bv == 0 || !uns && bv == 0 - 1 {
            return false;
        }
        if uns {
            v = if t == tt::TokenType::Slash {
                (a as u64 / bv as u64) as i64;
            } else {
                (a as u64 % bv as u64) as i64;
            };
        } else {
            v = if t == tt::TokenType::Slash {
                a / bv;
            } else {
                a % bv;
            };
        }
    } else {
        return false;
    }
    s.uns = uns;
    s.c_uns = uns;
    s.c_w = w;
    s.set_val(wrap_to(v, w, uns));
    return true;
}

// Integer `v` (a 64-bit pattern) reduced to `w` bits: zero-extended when `uns`, else sign-extended.
const fn wrap_to(v: i64, w: i64, uns: bool) i64 {
    if w >= 64 {
        return v;
    }
    let m = (1i64 << w) - 1;
    if uns || (v >> w - 1 & 1) == 0 {
        return v & m;
    }
    return v | ~m;
}

extend CmpSide {
    // One value `v`, read in the signedness `uns` already holds, in the C type already set.
    const fn set_val(self: &mut Self, v: i64) {
        self.konst = true;
        self.lo = v;
        self.hi = v;
    }

    // One value, `v` read unsigned when `uns`, spelled as emit_place_base and emit_rvalue spell a
    // folded count or parameter: `ULL` past i64::MAX, a parenthesized long long MIN, or a bare
    // decimal, an `int` when it fits one (`long` or `long long` otherwise).
    const fn set_dec(self: &mut Self, v: i64, uns: bool) {
        self.konst = true;
        self.lo = v;
        self.hi = v;
        self.uns = uns;
        self.c_uns = uns && v < 0;
        self.c_w = if v >= 0 - 2147483648i64 && v <= 2147483647 && !self.c_uns {
            32u32;
        } else {
            64u32;
        };
    }
}

// A planned vector statement (`CEmit::emit_planned`): the plan, what each argument is (a vector, a
// mask, a scalar, or lane-mask temps), what the result is, and the table indexes of the entries
// applied to each call's result and to its argument 0 (-1: none).
/// Whether the planner may call a backend entry: the table has one the build's features hold, and
/// SC_SIMD_SCALAR (a test switch) is not 1.
pub fn simd_enabled(pk: &loader::Package) bool {
    let sw = stdlib::getenv("SC_SIMD_SCALAR");
    if sw != null && str::from_cstr(sw) == "1" {
        return false;
    }
    for i in 0..pk.simd_table.len() {
        if cf::contains(pk.features, pk.simd_table.at(i).fs) {
            return true;
        }
    }
    return false;
}

struct VPlan {
    pub pl: sp::Plan,
    pub kinds: [u8; 3],
    pub res: u8,
    pub wres: i64,
    pub warg: i64,
    /// VR_ALL: the value of a true result, every lane's bit; VR_FOLD: the lane mask type's bits, the
    /// count's width (0: no count).
    pub ones: u64,
    /// VR_FOLD: the entry that folds the chunks' lane masks, and the entry that reduces the fold.
    pub cadd: i64,
    pub cred: i64,
    /// VR_LANES for a `choose` of narrower lanes: the truncating cast entry of each of `nsteps`
    /// steps that halve the lane masks' width, step `s` over chunk pairs when bit `s` of `npairs`.
    pub narrow: [i64; 3],
    pub nsteps: u32,
    pub npairs: u32,
    /// A pointer operand of a raw form (`load_raw`, `store_raw`, the masked pointer forms) may address
    /// a vector operand or the result whose address the body takes (`vec_addr_taken`): every operand
    /// is copied before any chunk is written.
    pub raw: bool,
}

const VK_VEC: u8 = 0;
const VK_MASK: u8 = 1;
const VK_SCALAR: u8 = 2;
const VK_LANES: u8 = 3;
const VK_PTR: u8 = 4; // the elements' address: chunk `k` starts at element `k * chunk_lanes`
const VR_VEC: u8 = 0;
const VR_MASK: u8 = 1;
const VR_LANES: u8 = 2;
const VR_UNIT: u8 = 3;
const VR_ANY: u8 = 4; // a comparison tested once by `any`: 1 or 0 (`mask_red`)
const VR_ALL: u8 = 5; // .. by `all`: `ones` or 0
// A comparison's chunks of lane masks folded by entry `cadd`, then reduced by `cred`: with `ones`, the
// active lane count of a comparison read once by `count` (`mask_count`); else `cred`'s result.
const VR_FOLD: u8 = 6;
// How a comparison gives `count` its lane count (`CEmit::count_kind`).
const CK_BITS: u8 = 0;
const CK_FOLD: u8 = 1;
const CK_SUM: u8 = 2;
// `ml_use` of a local whose one read is the argument of `sc_popcount64` (`count` of a mask).
const ML_POP: u32 = ir::IR_NONE - 2;
const VP_RET: u32 = 0xFFFFFFFF;

// A fresh plan: the lane loop, nothing applied.
const fn vplan_none() VPlan {
    return VPlan {
        pl: sp::Plan { form: sp::PF_SCALAR },
        res: VR_VEC,
        wres: -1,
        warg: -1,
        cadd: -1,
        cred: -1,
        narrow: [-1, -1, -1],
        nsteps: 0,
        npairs: 0,
        raw: false,
    };
}

// The operation (`ir::OP_ADD` to `ir::OP_SHR`) of binary operator token `t`; OP_COUNT for another.
const fn tok_op(t: tt::TokenType) u32 {
    return switch t {
        Plus => ir::OP_ADD,
        Minus => ir::OP_SUB,
        Star => ir::OP_MUL,
        Slash => ir::OP_DIV,
        Percent => ir::OP_REM,
        Ampersand => ir::OP_AND,
        Pipe => ir::OP_OR,
        Caret => ir::OP_XOR,
        LeftShift => ir::OP_SHL,
        RightShift => ir::OP_SHR,
        _ => ir::OP_COUNT,
    };
}

// The lane type of a lane mask of lanes `bt`: the unsigned integer of its width.
const fn lane_mask_bt(bt: BuiltinType) BuiltinType {
    return switch bt {
        BT_I8 | BT_U8 => BuiltinType::BT_U8,
        BT_I16 | BT_U16 => BuiltinType::BT_U16,
        BT_I32 | BT_U32 | BT_F32 => BuiltinType::BT_U32,
        _ => BuiltinType::BT_U64,
    };
}

// The range check of a masked access at `st` of slice `s` over `n` lanes with active lanes `m`: the bits
// of the active lanes past the end (every one when `st` is), then the trap at the lowest.
fn range_bits(o: &mut String, m: str, st: str, s: str, n: i64) {
    // `len >= n` is loop-invariant: an access inside the slice costs one comparison.
    o.format_into(
        "  uint64_t __sc_f = {}.len >= {}u && {} <= {}.len - {}u ? 0 : {} > {}.len ? (uint64_t)({}) : (uint64_t)({}) & ~0ULL << ({}.len - {});\n",
        s,
        n,
        st,
        s,
        n,
        st,
        s,
        m,
        m,
        s,
        st,
    );
    o.format_into("  if (__sc_f) __sc_mem_oob(__sc_f, {}, {}.len, 1);\n", st, s);
}

// The index check of a gather or scatter of slice `s` by index vector `x` over `n` lanes with active
// lanes `m`: the bits of the active lanes whose index is past the end, then the trap at the lowest.
fn index_bits(o: &mut String, n: i64, m: str, x: str, s: str) {
    o.format_into(
        "  uint64_t __sc_f = 0;\n  for (uint32_t __sc_i = 0; __sc_i < {}; __sc_i++) __sc_f |= (uint64_t)((({} >> __sc_i) & 1) && (uint64_t){}.l[__sc_i] >= {}.len) << __sc_i;\n",
        n,
        m,
        x,
        s,
    );
    o.format_into("  if (__sc_f) __sc_mem_oob(__sc_f, (uint64_t){}.l[__builtin_ctzll(__sc_f)], {}.len, 0);\n", x, s);
}

// The halves order of a split reduction of `x`'s `chunks` 16-byte chunks: level `l` of the tree at
// chunk `i` combines (`cn`) level `l - 1` at `i` and at `i + chunks >> l`; level 0 is chunk `i`.
fn reduce_tree(o: &mut String, cn: str, x: str, chunks: u64, l: u64, i: u64) {
    if l == 0 {
        o.format_into("{}.c[{}]", x, i);
        return;
    }
    o.format_into("{}(", cn);
    reduce_tree(o, cn, x, chunks, l - 1, i);
    o.push_str(", ");
    reduce_tree(o, cn, x, chunks, l - 1, i + (chunks >> l));
    o.push_byte(b')');
}

// Whether C spelling `s` is a name or a member of one: reading it twice reads one value and runs
// nothing. (A literal stays bound: compared with an unsigned length, GCC's `-Wtype-limits` rejects
// `0 <= len`.)
fn plain_spelling(s: str) bool {
    if s.len() == 0 || s.byte_at(0) >= b'0' && s.byte_at(0) <= b'9' {
        return false;
    }
    for i in 0..s.len() {
        let c = s.byte_at(i);
        if !(c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_' || c == b'.') {
            return false;
        }
    }
    return true;
}

// The unsigned lane type of `w` bytes.
const fn mask_bt_of(w: u64) BuiltinType {
    return switch w {
        1 => BuiltinType::BT_U8,
        2 => BuiltinType::BT_U16,
        4 => BuiltinType::BT_U32,
        _ => BuiltinType::BT_U64,
    };
}

// The bytes of lane type `bt`.
const fn lane_bytes(bt: BuiltinType) u64 {
    return switch bt {
        BT_I8 | BT_U8 => 1,
        BT_I16 | BT_U16 => 2,
        BT_I32 | BT_U32 | BT_F32 => 4,
        _ => 8,
    };
}
