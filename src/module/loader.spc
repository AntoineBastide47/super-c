// Package construction and module loading: reads the root module plus its transitive imports into
// per-module Asts, auto-imports the std prelude, and seeds the nominal builtin decls. Serves the
// package-level lookups every later stage relies on (O(1) public-decl name index, cached import
// closures). After typechecking, propagates concrete generic instances to their home modules
// (owner-emits, to a fixpoint) and computes the dependency-first module emit order for codegen.
import string as cstring;
import stdio;
import atomic;
import driver_shim as shim;
import lexer::token as tok;
import lexer::lexer as lexer;
import lexer::token_type as tt;
import ast::ast as *;
import ast::parser as parser;
import std::parallel::sync as psy;
import std::parallel::runtime as prt;
import graph::items as gitems;
import ir::layout as lay;

/// The C `SEEK_END` whence value used to size a file before reading it.
pub const SEEK_END: i32 = 2;

/// Number of nominal builtin types; sizes Package.builtin_decls. Pinned to BuiltinType::BT_COUNT.
pub const BT_COUNT_N: usize = BuiltinType::BT_COUNT as usize;

/// One loaded module: its `::`-joined module path (the mangling/lookup key), the file it came from, its
/// source text and parsed Ast. The Ast is held by value, so `has_ast` records whether lex/parse succeeded.
pub struct Module {
    pub path: String, // "std::string"; the root module is its file stem (owned)
    pub file: String, // filesystem path the source was read from (owned)
    pub source: String, // file contents (owned; span offsets index into it)
    pub ast: Ast, // parsed AST; after hir::lower runs it IS the module's HIR (desugared, resolved)
    pub has_ast: bool,
    pub prelude: bool, // part of the auto-imported std prelude
}

/// One shard-policy entry: module `module` (its `::` path) emits `tus` module TUs and `insts`
/// instance shards; a count is a schema, changed only by editing the policy.
pub struct ShardRule {
    pub module: String,
    pub tus: u32,
    pub insts: u32,
}

/// Item readiness states (`ItemSched.state`), monotone per item: a transition only moves up,
/// and every semantic write an item publishes lands before its state does (release store),
/// so a reader that observes a state (acquire load) sees those writes. The batch build's
/// visibility is the static schedule rule (`graph::items::visible`); the states serve the
/// language server's module-order passes, the digest and the tests. An item goes Resolved ->
/// Checking -> Checked -> IrReady; values 2 and 3 are unused.
pub const IS_PARSED: u8 = 0;
pub const IS_RESOLVED: u8 = 1;
pub const IS_CHECKING: u8 = 4;
pub const IS_CHECKED: u8 = 5;
pub const IS_IR_READY: u8 = 6;

/// The item schedule index (`graph::items`): one record per `PkgIndex.items` entry, stored as
/// parallel arrays indexed by ItemId. `key` is the stable item key (module path, top-level
/// ordinal, member ordinal: independent of node ids, so a body edit renumbers nothing);
/// `sig_hash` the post-typecheck signature hash; `pre_off`/`pre_edges` the precheck dependency
/// ranges (CSR by owner, targets ascending) read from the resolution tables after resolution;
/// `fin_off`/`fin_edges` the final ranges refined after the checks (typecheck resolutions and
/// the engine's dynamic body edges); `comp` the precheck strongly connected component of each
/// item in dependency-first order; `state` the readiness state; `by_node` the items of each
/// module (the `mod_items` ranges) ordered by declaration node for the (module, node) lookup.
/// The diagnostic owner of an item is its module (`ItemMeta.module`).
pub struct ItemSched {
    pub key: Vector<u64>,
    pub sig_hash: Vector<u64>,
    pub pre_off: Vector<u32>,
    pub pre_edges: Vector<u32>,
    pub fin_off: Vector<u32>,
    pub fin_edges: Vector<u32>,
    pub comp: Vector<u32>,
    pub ncomp: u32,
    pub state: Vector<u8>,
    /// Per item: 1 when every borrow-carrying `return` of the function is a bare parameter (the
    /// modular lifetime check pinned the result's borrows), 0 when not, 2 while unrecorded. The
    /// driver records a module's verdicts right after its type check (`bc_record_ret_attr`); the
    /// borrow pass reads them at every call, so a callee's body syntax can be released before its
    /// callers are analyzed.
    pub ret_attr: Vector<u8>,
    pub dyn_edges: Set<u64>, // caller item << 32 | callee item, recorded by the master engine
    pub by_node: Vector<u32>,
    /// Per item: the declaration node of the top-level item before it in node order (0 for a
    /// module's first), the exclusive start of the item's own module-arena range; a member
    /// carries its extend's. `body_hi` is a function's body block id (untagged), else 0.
    pub top_lo: Vector<u32>,
    pub body_hi: Vector<u32>,
    /// The member names of the builtin extends outside the prelude (`graph::items::builtin_edges`):
    /// the name's 32-bit hash << 32 | the extend item, sorted; `bmask` a bit per first byte and
    /// length class of those names, the prefilter of the scan.
    pub bnames: Vector<u64>,
    pub bmask: u64,
    /// The component graph (`build`): `cdep` the components each component depends on, `citem`
    /// each component's items ascending. Both CSR by component.
    pub cdep_off: Vector<u32>,
    pub cdep: Vector<u32>,
    pub citem_off: Vector<u32>,
    pub citem: Vector<u32>,
    pub built: bool,
    /// The final ranges hold the post-typecheck edges (`build_final` after the typecheck frontier,
    /// or `finalize`): what the unused-item lint and the emission liveness read.
    pub final_edges: bool,
    pub finalized: bool, // `finalize` ran: final ranges and signature hashes are current
    pub build_ns: u64, // time of the last `build` (the frontier's per-task edges apart)
    pub final_ns: u64, // time of `finalize`'s final-edge scan
    pub hash_ns: u64, // time of `finalize`'s signature hashes
}

extend ItemSched {
    /// Approximate owned bytes.
    pub const fn retained(self: &Self) usize {
        return (self.key.capacity() + self.sig_hash.capacity()) * 8 + (self.pre_off.capacity() + self.pre_edges.capacity() + self.fin_off.capacity() + self.fin_edges.capacity() + self.comp.capacity() + self.by_node.capacity() + self.top_lo.capacity() + self.body_hi.capacity() + self.bnames.capacity() * 2 + self.cdep_off.capacity() + self.cdep.capacity() + self.citem_off.capacity() + self.citem.capacity()) * 4 + self.state.capacity() + self.ret_attr.capacity() + self.dyn_edges.len() * 16;
    }
}

/// The whole compilation: the root module plus every module reachable through `import`. Modules are kept as
/// separate Asts; cross-module references are DefId{module, node} into this array.
pub struct Package {
    pub modules: Vector<Module>,
    /// The module path index `find` reads: FNV hash of a module path -> the newest module with that
    /// hash, and per module the next older module whose path has the same hash (SYM_NONE ends a
    /// chain). `add_module` is the one place modules join the package, and paths never change.
    pub mod_index: Map<u64, u32>,
    pub mod_chain: Vector<u32>,
    /// Instruction set `@arch` items are gated against: 0 x86_64, 1 aarch64, 2 wasm32, -1 unknown.
    /// Defaults to the host the compiler runs on; the driver overwrites it for `--arch=`.
    pub arch: i32,
    /// The settings the build-constant module spells and the early prune decides by: a `--test`
    /// build (TEST), the profile name (PROFILE; empty is `dev`), and the profile names a PROFILE
    /// comparison may name (empty: unchecked). The driver sets them before the platform filter.
    pub test_build: bool,
    pub profile: String,
    pub profiles: Vector<String>,
    /// The build-constant module (`__std::build`), -1 until the platform filter adds it; the
    /// target platform it spells.
    pub build_module: i32,
    pub build_target: i32,
    /// The `--bootstrap-tags` flag the ASTs were loaded under: gating changes item sets while
    /// leaving sources identical, so build caches keyed on sources must include it.
    pub bootstrap: bool,
    pub root_dir: String, // source root: the directory of the root file; imports resolve relative to it
    pub gen_root: String, // where codegen writes the emitted C tree: <build dir>/raw, set by the driver
    pub cc: String, // the C compiler the command line named for a bare build; empty = resolve as usual
    pub std_root: String, // second import search root (parent of std/); empty = none
    pub alt_root: String, // optional search root between the project root and std (manifest src/ dir)
    pub ok: bool, // false if any read/parse/cycle error was reported during loading
    /// Resolved external C inputs (`@c.source` files and implicit backing-header `.c` siblings),
    /// recorded by ext_c_collect: the build engine's emit stamp must dirty on their edits, since
    /// their content is copied into the generated tree at emission time.
    pub ext_inputs: Vector<String>,
    /// Builtins as nominal types: a synthetic decl per builtin is injected into the `core` prelude module so
    /// `extend i32 { .. }` resolves and dispatches like any other type. `core_seeded` gates it.
    pub core_module: ModuleId,
    pub core_seeded: bool,
    pub builtin_decls: [NodeId; BT_COUNT_N],
    /// Demand-driven method emission: method_used[module][node] set for every method referenced during
    /// type-checking. Ragged: outer grown to module count, each inner grown to cover the node id.
    pub method_used: Vector<Vector<bool>>,
    /// Coroutine-reachability for preemption safepoints: 0 = uncomputed (emit everywhere),
    /// 1 = computed (only bodies inside co_spans need safepoints). co_spans[m] holds start<<32|end
    /// body spans, in marking order, of the functions and closures a coroutine can execute
    /// (`co_compute`); everything else can never starve a worker, so its loops need no safepoint tick.
    pub co_state: u8,
    pub co_spans: Vector<Vector<u64>>,
    /// Per module: the decl spans of `co_spans` in std whose bodies run user code only through bound
    /// dispatch, so an instance ticks only when it binds a type that can reach user code (`co_inst_on`).
    pub co_inst: Vector<Vector<u64>>,
    /// The fn values `co_compute` found (module << 32 | decl node): every closure but a coroutine
    /// entry's, every function named as a value outside std::parallel. `cancel_compute` reads them
    /// for `cancel_fnv`.
    pub co_fnv: Vector<u64>,
    /// Per module: the modules that emit before it (`emit_dep_row`), recorded before its body
    /// syntax is released; empty when the rows are computed at emission planning.
    pub emit_deps: Vector<Vector<ModuleId>>,
    /// Cancellation-edge reachability: 0 = uncomputed (no cancellation checks anywhere), 1 =
    /// computed. cancel_marks[m] holds start<<32|end DECL spans of the functions and closures whose
    /// bodies can reach `runtime::cancel_accept`; a call to one of these from a task-reachable
    /// body is followed by a compiled cancellation check with a cleanup edge.
    pub cancel_state: u8,
    pub cancel_marks: Vector<Set<u64>>,
    /// Can a call to a fn value nothing pins reach `runtime::cancel_accept` (some fn value of
    /// `co_fnv` can)? Then such a call in a task-reachable body carries a cancellation check too.
    pub cancel_fnv: bool,
    /// Does any non-std module request cancellation (runtime::request_cancel, runtime::try_shutdown,
    /// or anything in std::parallel::task)? Combined loop safepoints are emitted only then: a
    /// program that never cancels pays no per-loop ladder, and its shutdown reports a spinning task
    /// as unresponsive instead of reclaiming it.
    pub cancel_used: bool,
    /// Methods resolved with NO receiver in hand: the format helpers the print lowering reaches for,
    /// and anything else the compiler names by decl alone. Nothing says which instance wants them, so
    /// every instance does: (module << 32 | node), exempt from the per-instance demand test.
    pub always_methods: Set<u64>,
    /// The Core IR constant interpreter (a *mut ir::interp::Interp, kept opaque here to avoid a type
    /// cycle); owned by the driver, created after load, set before type-checking. Null in library use.
    pub cir: *mut void,
    /// The emission's inline-candidate store (`ir::inline::InlineStore`), set for the emission's
    /// lifetime by `cemit_package`; null outside it.
    pub inl_store: *const void,
    /// Compiler-stage parallelism: worker count for the parallel frontiers (0/1 = serial). Set by
    /// the driver from --jobs before run_package; the parallel cc window reads its own copy.
    pub jobs: u32,
    /// The item schedule index: the readiness states, the component graph the item scheduler
    /// runs, and the visibility rule the constant engine and the checker read (`graph::items`).
    /// Parallel checkers write disjoint items.
    pub sched: ItemSched,
    /// The output shard policy (build.toml `[shards]` / `[instance-shards]`): modules absent
    /// from it emit one TU and one instance shard.
    pub shard_rules: Vector<ShardRule>,
    /// The package type table: every published type, one final id each (`Ast::intern_type_i`).
    /// Boxed so the module Asts can hold its address while the package moves. `bind_types` puts
    /// the modules under it; until then (the LSP, standalone checks) they keep module-local pools.
    pub tt: Box<TypePool>,
    /// The map of the last `publish_types`: per module, provisional pool index to final type id.
    /// Read through `map_type`.
    pub pub_map: Vector<Vector<TypeId>>,
    pub publications: u32, // batches published so far
    /// Per final id: the publication class that numbered it (0 signature-reachable, 1 body-only of
    /// the first batch, 2 a later batch, 3 interned by the instance graph between checkpoints); the
    /// seeds carry 0.
    pub tt_class: Vector<u8>,
    /// Cross-module reference bitset: mod_refs[from*mod_refs_w + to/64] bit (to%64) is set iff module `from`
    /// has any resolution into module `to`, in either arena. `build_mod_refs` fills it once before the
    /// borrow frontier, while every body is live and after the last resolution write (type check); from
    /// then on module_imports is an O(1) query whose answer does not depend on which modules have
    /// released their bodies. `mod_refs_ready` gates it (module_imports falls back to the linear scan
    /// on the paths that never build it).
    pub mod_refs: Vector<u64>,
    pub mod_refs_w: usize,
    pub mod_refs_ready: bool,
    /// The package declaration index: symbols, ItemMeta records, per-module name maps,
    /// import adjacency, and SCCs. Built once on first use after loading
    /// (top-level decl names and imports are parse-final); `ensure_index` rebuilds it when a module
    /// is appended later (the LSP's batch load). `lookup`/`glob_lookup`/`prelude_lookup` and the
    /// import-closure cache are adapters over it.
    pub idx: PkgIndex,
    /// Per-module transitive import closure: clo_lists[mid] = [mid, BFS over its imports...],
    /// built lazily on first glob_lookup into `mid` (imports are load-final). Replaces glob_lookup's
    /// per-call seen/queue vectors and per-import path re-joins with a flat cached walk.
    pub clo_lists: Vector<Vector<ModuleId>>,
    pub clo_built: Vector<bool>,
    /// Recycled token vector: each module's lexer adopts it (capacity kept), the parser hands it back.
    pub tok_scratch: Vector<tok::Token>,
    /// Recycled codegen output buffer, lent to each TU's Codegen through the owner-swap idiom (field
    /// assigns emit no frees, so a PRE-FIX bootstrap compiler lowers the swap correctly: a
    /// reassigned Free LOCAL would trip the conditional-move bug older emitters carry).
    pub cg_scratch: String,
    /// Import-resolution directory cache: each candidate search directory is scanned once (opendir/
    /// readdir) and its entry names cached, so resolve_import_file answers "does <dir>/<file> exist?" from
    /// memory instead of an fopen probe per candidate. Scales: a directory with N modules imported M times
    /// costs 1 scan, not M*<up to 3> fopens. A listing MISS still falls back to fopen (byte-identical vs the
    /// old path_exists even under case-insensitive filesystems).
    pub dir_cache: DirCache,
    pub lint_warnings: u32, // total lint warnings across modules (the `lint` subcommand exits 1 when > 0)
    /// Batch-lint module mask (`super-c lint` over many files sharing ONE package): when non-empty,
    /// the lint passes report exactly the modules set here instead of the only_mod/prelude filter.
    pub lint_set: Vector<bool>,
    /// Binary-project lint (`pub` earns nothing in a program nobody links against): when true, public
    /// functions join the unused-item candidates instead of rooting the reachability graph. Set only
    /// for whole-program lints of manifests without a [lib] target (and for script builds).
    pub lint_pub: bool,
    /// In-memory source overlays (the LSP's open editor buffers): a module whose file resolves to
    /// overlay_files[i] loads overlay_texts[i] instead of the on-disk bytes. Parallel vectors, canonical
    /// (realpath'd) absolute paths preferred: overlay_index falls back to a raw compare for files not on
    /// disk yet. Empty outside the LSP.
    pub overlay_files: Vector<String>,
    pub overlay_texts: Vector<String>,
    /// SC_ITEM_STATS (`graph::items`): per-item costs and dynamic evaluation edges recorded by
    /// the serial pipeline for the item-schedule measurement. `icost_on` gates every record;
    /// `icost_tc` holds one (module << 32 | item node, ns) pair per checked item, `icost_bc` one
    /// per borrow-checked body (owner node), `icost_mod` two per module (seed ns, panics ns),
    /// `ctfe_edges` (caller key, callee key) pairs for every body the engine lowered from
    /// syntax while `cur_item` was checking.
    pub icost_on: bool,
    /// Release each module's body syntax right after its borrow pass (batch builds; the lint driver
    /// and the measurement mode keep it until emission planning).
    pub free_bodies: bool,
    pub icost_tc: Vector<u64>,
    pub icost_rs: Vector<u64>, // per resolved item (module << 32 | item node, ns)
    pub icost_bc: Vector<u64>,
    pub icost_lw: Vector<u64>, // per body lowered to Core IR (owner key, ns)
    pub icost_mod: Vector<u64>,
    pub ctfe_edges: Vector<u64>,
    /// LSP: modules whose body syntax the constant engine read in some analysis round (a fold's
    /// or a `const fn` scan's callee); their bodies stay live when their documents are closed, so
    /// the next round needs no parse-back. Indexed by module; shorter than the module table means
    /// "not held".
    pub body_hold: Vector<bool>,
    /// LSP: per module, the references its items made to declarations of other items when its
    /// last analysis finished (`RefEdge`, ascending by key): what an edit's dependents and a
    /// reference scan read about a module whose bodies are released. Indexed by module; shorter
    /// than the module table means "unrecorded".
    pub def_refs: Vector<Vector<RefEdge>>,
}

/// One recorded reference (`Package.def_refs`): the declaration named (`module << 32 | node`)
/// and the declaration node of the item whose nodes name it (`REF_MODULE_WIDE` for a node no
/// item's ranges hold: a desugar appended past them), with `REF_BODY_EDGE` set when the naming
/// node sits in the body arena (a call or a use inside a releasable body) rather than in a
/// signature, a type, a constant or a body the module arena holds.
pub struct RefEdge {
    pub key: u64,
    pub owner: u32,
}

pub const REF_MODULE_WIDE: u32 = 0x7FFFFFFF;
pub const REF_BODY_EDGE: u32 = 0x80000000;

/// Parallel-table cache of directory listings for import resolution. `ok[i]` = did opendir(dirs[i]) succeed.
/// `entries[i]` is sorted; `heads` maps a directory hash to the newest index with that hash, `next[i]` to
/// the one before it (SYM_NONE ends the chain).
pub struct DirCache {
    pub dirs: Vector<String>,
    pub entries: Vector<Vector<String>>,
    pub ok: Vector<bool>,
    pub heads: Map<u64, u32>,
    pub next: Vector<u32>,
}

/// The parse pipeline's result: an Ast plus whether lex/parse succeeded (mirrors the C `Ast*`/NULL return).
pub struct ParseResult {
    pub ast: Ast,
    pub ok: bool,
    pub tokens: Vector<tok::Token>, // handed back for capacity recycling (Package.tok_scratch)
}

/// A module-qualified declaration hit: the decl's NodeId within module `mid`. `node == NODE_NONE` means miss.
pub struct LookupHit {
    pub node: NodeId,
    pub mid: ModuleId,
}

/// Dense index into PkgIndex.items; assigned in module order then source order, never from hash order.
pub type ItemId = u32;
pub const ITEM_NONE: ItemId = 0xFFFFFFFF;

/// Dense insertion-order id into the package symbol interner.
pub type SymbolId = u32;
pub const SYM_NONE: SymbolId = 0xFFFFFFFF;

/// Item classification in the package declaration index. Append-only: later phases key on the tags.
pub enum ItemKind {
    IK_FUNCTION,
    IK_STRUCT, // struct or union (`is_union` stays on the node)
    IK_ENUM,
    IK_TYPE_ALIAS,
    IK_INTERFACE,
    IK_CONST,
    IK_EXTEND, // associated-item owner; unnamed
    IK_METHOD, // fn inside an extend
    IK_ASSOC_CONST, // const inside an extend
}

/// One record per top-level or associated declaration. `node` is the declaration NodeId:
/// DefId{module, node} identity and C mangling key off it. Signatures and attributes stay
/// reachable through the node (the Ast side tables are their owner). Fields are ordered widest first,
/// so the record is 28 bytes with no interior padding.
pub struct ItemMeta {
    pub node: NodeId,
    pub owner: ItemId, // enclosing IK_EXTEND for methods/assoc consts; ITEM_NONE at top level
    pub name: SymbolId, // SYM_NONE for unnamed declarations (extends)
    pub start: u32, // name span in the module source (the whole-decl span start for unnamed items)
    pub len: u32,
    pub module: ModuleId,
    pub kind: u8, // ItemKind
    pub is_public: bool,
    pub is_type: bool, // occupies the type namespace in name lookup
}

static_assert(sizeof(ItemMeta) == 28, "ItemMeta must stay 28 bytes");

/// Package symbol interner: identifier bytes -> dense insertion-order SymbolId. The hash map only
/// FINDS an entry, identity is the dense `names` vector; same-hash names chain through `chain` and
/// every probe is verified byte-exact, so a 64-bit collision degrades to a short walk, never a wrong
/// answer. Built in deterministic module and source order by build_index.
pub struct SymTab {
    pub names: Vector<String>,
    pub index: Map<u64, u32>, // fnv(name) -> first SymbolId with that hash
    pub chain: Vector<u32>, // SymbolId -> next same-hash SymbolId; SYM_NONE ends the walk
}

/// One function item's signature record: `start` indexes PkgIndex.sig_types, which holds the `np`
/// param types then the `nr` return types (owner-pool TypeIds). `generic` marks a generic function,
/// whose signature types mention its own parameters and substitute per instantiation.
pub struct ItemSig {
    pub start: u32,
    pub np: u16,
    pub nr: u16,
    pub generic: bool,
}

/// Runtime shims the sugar lowering (hir::lower) seeds call resolutions to: free FUNCTIONS in fixed
/// std modules, so they resolve by (module path, name) rather than through the prelude scan. Resolved
/// once per index build; an entry whose module is not loaded stays NODE_NONE and the lowering leaves
/// its marker untouched (the demand-loading of these modules is keyed on the keyword's use).
pub enum SugarItem {
    SI_SUBMIT, // `launch`
    SI_PAR_RANGE, // `parallel for`
    SI_SEL_NEW,
    SI_SEL_ARM_RECV,
    SI_SEL_ARM_SEND,
    SI_SEL_WAIT,
    SI_SEL_WAIT_TIMEOUT,
    SI_SEL_POLL,
    SI_SEL_WON,
    SI_SEL_RECV,
    SI_SEL_SEND,
    SI_CANCEL_PROBE, // the compiled cancellation-edge probe
    SI_CANCEL_LBEGIN, // ladder open: cleanup masked
    SI_CANCEL_LEND, // ladder close: hand the edge to the caller
    SI_COUNT,
}

const SI_COUNT_N: usize = SugarItem::SI_COUNT as usize;

// (module path, function name) per SugarItem, indexed by the enum value.
const SI_MODULES: [str<'static>; SI_COUNT_N] = [
    "std::parallel::runtime",
    "std::parallel::data",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::selector",
    "std::parallel::runtime",
    "std::parallel::runtime",
    "std::parallel::runtime",
];
const SI_NAMES: [str<'static>; SI_COUNT_N] = [
    "submit",
    "range",
    "sugar_new",
    "sugar_arm_recv",
    "sugar_arm_send",
    "sugar_wait",
    "sugar_wait_timeout",
    "sugar_poll",
    "sugar_won",
    "sugar_recv",
    "sugar_send",
    "cancel_probe",
    "cancel_ladder_begin",
    "cancel_ladder_end",
];

/// The package declaration index: the immutable package interface built once after every module has
/// parsed (and rebuilt if a module is appended, e.g. the LSP's batch load). Owns the symbol table,
/// one ItemMeta per declaration (module order, source order), per-module name maps for O(1) lookup,
/// the resolved direct-import adjacency, and its strongly connected components.
pub struct PkgIndex {
    pub syms: SymTab,
    pub items: Vector<ItemMeta>,
    pub mod_items: Vector<u32>, // modules+1 offsets into `items`
    pub name_maps: Vector<Map<u64, u32>>, // per module: sym*4 + is_type*2 + is_pub -> ItemId, first wins
    pub imports: Vector<ModuleId>, // resolved direct imports, declaration order, per-module dedup
    pub mod_imports: Vector<u32>, // modules+1 offsets into `imports`
    pub scc_of: Vector<u32>, // module -> import-graph SCC id (completion order; deterministic)
    pub sugar_items: Vector<LookupHit>, // SugarItem -> std shim fn (node == NODE_NONE when absent)
    pub pl_map: Map<u64, u64>, // sym*2 + want_type -> node << 32 | module: every public top-level prelude name, the first prelude module wins (prelude_lookup)
    /// Function-item signatures as package metadata (see ensure_sigs): sig_of keys
    /// skey_mix(module << 32 | fn node) (MIXED: u64 maps hash by identity and structured keys
    /// cluster) to a `sigs` record whose types live in the `sig_types` CSR pool,
    /// params first then returns, as TypeIds in the OWNER module's pool. Filled once from the owners'
    /// typed facts after the whole package is checked; signature queries read this, not the syntax.
    pub sigs: Vector<ItemSig>,
    pub sig_types: Vector<TypeId>,
    pub sig_of: Map<u64, u32>,
    pub sigs_built: bool,
    pub built_mods: u32, // module count at build time; a later module append invalidates the index
    /// Enum members: skey_mix(module << 32 | member node) -> enum node << 32 | member position.
    pub variants: Map<u64, u64>,
    pub exts: Vector<NodeId>, // top-level extend items, module order then item order
    pub mod_exts: Vector<u32>, // modules+1 offsets into `exts`
}

extend SymTab {
    /// The SymbolId already interned for `name`, or SYM_NONE. Byte-exact.
    @c.always_inline
    pub fn find(self: &Self, name: str) SymbolId {
        return switch self.index.get(&name.hash()) {
            Some(h) => {
                let mut s = *h;
                while s != SYM_NONE && !self.names[s as usize].eq_str(name) {
                    s = self.chain[s as usize];
                }
                s;
            },
            None => SYM_NONE,
        };
    }

    /// Intern `name`, returning its dense SymbolId (existing entries are found byte-exact).
    pub fn intern(self: &mut Self, name: str) SymbolId {
        let h = name.hash();
        let head = switch self.index.get(&h) {
            Some(v) => *v,
            None => SYM_NONE,
        };
        let mut s = head;
        while s != SYM_NONE && !self.names[s as usize].eq_str(name) {
            s = self.chain[s as usize];
        }
        if s != SYM_NONE {
            return s;
        }
        let id = self.names.len() as SymbolId;
        self.names.push(String::from_str(name));
        // New entry heads the (~always empty) same-hash chain.
        self.chain.push(head);
        self.index.insert(h, id);
        return id;
    }
}

// The function call `ni` (callee node `callee`) pins to: the checker's call record, else the callee's
// resolution, else a member callee's; NODE_NONE for a fn value or a dyn dispatch.
fn pin_callee(a: &Ast, ni: NodeId, callee: NodeId) DefId {
    switch a.call_info.get(&ni) {
        Some(v) => {
            let t = DefId { module: (*v >> 40) as ModuleId, node: (*v >> 8 & 0xFFFFFFFFu64) as NodeId };
            if t.node != NODE_NONE {
                return t;
            }
        },
        _ => {},
    };
    let t = a.resolution_def(callee);
    if t.node == NODE_NONE && a.at_const(callee).kind == NodeKind::NODE_MEMBER {
        return a.resolution_def(a.at_const(callee).as_data.member.member);
    }
    return t;
}

// The coroutine entry APIs: calling one runs its entry argument (a parameter, by declaration index)
// on a fresh coroutine. Resolved by (module, extended type or "" for a free function, name). A call
// inside std::parallel is one of its own trampolines, covered by the seed at the public API.
const CO_ENTRY_N: usize = 4;
const CO_ENTRY_MOD: [str<'static>; CO_ENTRY_N] = [
    "std::parallel::runtime",
    "std::parallel::runtime",
    "std::parallel::runtime",
    "std::parallel::task",
];
const CO_ENTRY_TYPE: [str<'static>; CO_ENTRY_N] = ["", "", "", "TaskGroup"];
const CO_ENTRY_FN: [str<'static>; CO_ENTRY_N] = ["submit", "spawn_coroutine", "spawn_coroutine_env", "spawn"];
const CO_ENTRY_PARAM: [u32; CO_ENTRY_N] = [0, 0, 0, 1];

// A declaration index or record target that names none.
const CO_NONE: u32 = 0xFFFFFFFFu32;
// The record target of a call to a fn value that nothing pins: every fn value may run.
const CO_ESC: u32 = 0xFFFFFFFEu32;
// A record without a call site whose arguments to check.
const CO_NO_SITE: u64 = 0xFFFFFFFFFFFFFFFFu64;

// The name of function `n`, as written.
const fn fn_name<'s>(a: &Ast, src: str<'s>, n: NodeId) str<'s> {
    let sp = a.at_const(a.at_const(n).as_data.function.name).as_data.name.text;
    return src.slice(sp.start as usize, sp.end as usize);
}

// The node an argument or callee names a declaration through: `&x`, `move x` and `unsafe x` name
// what `x` names, a turbofish what its expression names, and a path what its last segment names.
fn named_node(a: &Ast, n0: NodeId) NodeId {
    let mut n = n0;
    loop {
        let nd = a.at_const(n);
        if nd.kind == NodeKind::NODE_UNARY && (nd.as_data.unary.op == tt::TokenType::Ampersand || nd.as_data.unary.op == tt::TokenType::Move || nd.as_data.unary.op == tt::TokenType::Unsafe) {
            n = nd.as_data.unary.operand;
        } else if nd.kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            n = nd.as_data.specialization.expression;
        } else {
            return n;
        }
    }
}

// The declaration node `n` names, or NODE_NONE.
fn named_decl(a: &Ast, n: NodeId) DefId {
    let r = a.resolution_def(n);
    if r.node == NODE_NONE && a.at_const(n).kind == NodeKind::NODE_MEMBER {
        return a.resolution_def(a.at_const(n).as_data.member.member);
    }
    return r;
}

// The index of parameter `p` among the parameters of function or closure `d` (module-local), or -1.
fn param_index(a: &Ast, d: NodeId, p: NodeId) i64 {
    let dn = a.at_const(d);
    let ps = if dn.kind == NodeKind::NODE_FUNCTION {
        dn.as_data.function.params;
    } else {
        dn.as_data.closure.params;
    };
    for i in 0..ps.len {
        if unsafe a.list(ps)[i as usize] == p {
            return i;
        }
    }
    return -1;
}

// The argument node call `ni` passes for parameter `p` of its callee, or NODE_NONE: method-call
// syntax passes parameter 0 as its receiver.
const fn site_arg(a: &Ast, ni: NodeId, p: u32) NodeId {
    let cd = a.at_const(ni).as_data.call;
    let c = a.at_const(cd.callee);
    let mut i = p;
    if c.kind == NodeKind::NODE_MEMBER && !c.as_data.member.path {
        if p == 0 {
            return NODE_NONE;
        }
        i = p - 1;
    }
    if i >= cd.args.len {
        return NODE_NONE;
    }
    return unsafe a.list(cd.args)[i as usize];
}

// Is call `ni` a method call through a `dyn` receiver (behind references and pointers)?
fn dyn_receiver(a: &Ast, ni: NodeId) bool {
    let c = a.at_const(a.at_const(ni).as_data.call.callee);
    if c.kind != NodeKind::NODE_MEMBER || c.as_data.member.path {
        return false;
    }
    let mut t = a.type_of(c.as_data.member.object);
    for _ in 0..8 {
        if t == TYPE_NONE {
            return false;
        }
        let y = a.type_at(t);
        if y.kind == TypeKind::TYPE_DYN {
            return true;
        }
        if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
            return false;
        }
        t = y.as_data.elem;
    }
    return false;
}

// Can argument `arg` hold a fn value: is its type a function (behind references and pointers) or a
// type parameter with a fn bound? An unbounded parameter's value cannot be called, nor passed where a
// fn is expected.
fn fn_valued(a: &Ast, arg: NodeId) bool {
    let mut t = a.type_of(arg);
    for _ in 0..8 {
        if t == TYPE_NONE {
            return false;
        }
        let y = a.type_at(t);
        if y.kind == TypeKind::TYPE_FUNCTION {
            return true;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            return fn_bounded(a, y.module, y.as_data.decl);
        }
        if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
            return false;
        }
        t = y.as_data.elem;
    }
    return true;
}

// The method a binary operator or compound assignment `n` calls with no method the checker
// recorded: an aggregate or type-parameter operand (behind references) dispatches `==`/`!=` to
// `eq`, an ordering to `cmp` and arithmetic to its operator method at emission. "" for any other.
fn agg_op_name(a: &Ast, n: &Node) str<'static> {
    let mut t = a.type_of(n.as_data.binary.left);
    for _ in 0..4 {
        let y = a.type_at(t);
        if y.kind != TypeKind::TYPE_REFERENCE {
            break;
        }
        t = y.as_data.elem;
    }
    let k = a.type_at(t).kind;
    if k != TypeKind::TYPE_STRUCT && k != TypeKind::TYPE_INSTANCE && k != TypeKind::TYPE_ENUM && k != TypeKind::TYPE_GENERIC {
        return "";
    }
    let op = n.as_data.binary.op;
    if op == tt::TokenType::EqualEqual || op == tt::TokenType::BangEqual {
        return "eq";
    }
    if op == tt::TokenType::LessThan || op == tt::TokenType::LessThanEqual || op == tt::TokenType::GreaterThan || op == tt::TokenType::GreaterThanEqual {
        return "cmp";
    }
    return op.op_method();
}

// Does type parameter `gp` (module `gm`) carry a fn bound, inline or in a where clause? One declared
// in another module than `a`'s answers yes.
fn fn_bounded(a: &Ast, gm: ModuleId, gp: NodeId) bool {
    if gm != a.module || a.at_const(gp).kind != NodeKind::NODE_GENERIC_PARAM {
        return true;
    }
    let bs = a.at_const(gp).as_data.generic_param.bounds;
    for i in 0..bs.len {
        if a.at_const(unsafe a.list(bs)[i as usize]).kind == NodeKind::NODE_FUNCTION_TYPE {
            return true;
        }
    }
    for w in 0..a.where_bounds.len() {
        let wp = a.at_const(a.where_bounds.at(w).pred).as_data.where_predicate;
        if a.resolution_def(wp.ty).node != gp {
            continue;
        }
        for i in 0..wp.bounds.len {
            if a.at_const(unsafe a.list(wp.bounds)[i as usize]).kind == NodeKind::NODE_FUNCTION_TYPE {
                return true;
            }
        }
    }
    return false;
}

// The coroutine-reachability graph of `Package::co_compute`: every function and closure declaration
// of the package, per module in span order, and the marking state of the closure over them.
struct CoGraph {
    pub start: Vector<u32>, // per module (+ sentinel): its first decl
    pub span: Vector<u64>, // start << 32 | end
    pub parent: Vector<u32>, // innermost enclosing decl, or CO_NONE
    pub lim: Vector<u32>, // one past the last decl of the decl's module
    pub dmod: Vector<u32>, // the decl's module
    pub node: Vector<u32>, // the decl's node
    pub closure: Vector<u8>, // 1 for a closure
    pub need: Vector<u64>, // bit p: parameter p holds a fn value the body may call (checked at call sites)
    pub ix: Vector<u32>, // per node of every module (dense order): its decl + 1, or 0
    pub ix_start: Vector<usize>, // per module: its first `ix` slot
    pub nb: Vector<usize>, // per module: the node count of its main arena (the dense offset of its body arena)
    pub on: Vector<u8>, // the decl runs on a coroutine (marked, or inside a marked decl)
    pub marked: Vector<u8>, // the decl's span is in the output
    pub queue: Vector<u32>,
    pub spans: Vector<Vector<u64>>, // the output, per module
    pub esc: Vector<u32>, // the fn values: every closure, every function named as a value outside std::parallel
    pub in_esc: Vector<u8>,
    pub escaped: bool,
    pub stdm: Vector<u8>, // per module: 0 user code, 1 std, 2 std::parallel
    // Per decl of std: whether its body can run user code (see `co_compute`): 0 no, 1 only through
    // bound dispatch (its instances decide), 2 through a fn value or `dyn`.
    pub ureach: Vector<u8>,
    pub inst: Vector<Vector<u64>>, // the output's spans whose ticks the emitting instance decides
}

extend CoGraph {
    // The decl of module `m` declared at node `n`, or CO_NONE.
    const fn decl_of(self: &Self, m: ModuleId, n: NodeId) u32 {
        let mut k = n as usize;
        if (n & NODE_BODY) != 0 {
            k = self.nb[m as usize] + (n & NODE_BODY_MASK) as usize;
        }
        let v = self.ix[self.ix_start[m as usize] + k];
        if v == 0 {
            return CO_NONE;
        }
        return v - 1;
    }

    // The innermost decl of module `m` whose span covers `sp`, or CO_NONE (a site outside every
    // decl, such as a const initializer, never runs on a coroutine).
    fn decl_at(self: &Self, m: usize, sp: tok::Span) u32 {
        let lo = self.start[m] as usize;
        let mut l = lo;
        let mut h = self.start[m + 1] as usize;
        while l < h {
            let mid = (l + h) / 2;
            if (self.span[mid] >> 32) as u32 <= sp.start {
                l = mid + 1;
            } else {
                h = mid;
            }
        }
        if l == lo {
            return CO_NONE;
        }
        let mut d = (l - 1) as u32;
        while d != CO_NONE && (self.span[d as usize] & 0xFFFFFFFFu64) as u32 < sp.end {
            d = self.parent[d as usize];
        }
        return d;
    }

    // `decl_at` for a site near the one whose innermost decl is `hint` (CO_NONE: none): `hint`
    // itself when it covers `sp` and the next decl starts after `sp` (no decl inside `hint` can
    // cover it), else the search. Sites in node order mostly share their decl.
    fn decl_near(self: &Self, m: usize, sp: tok::Span, hint: u32) u32 {
        if hint != CO_NONE {
            let hs = self.span[hint as usize];
            let nx = hint as usize + 1;
            if (hs >> 32) as u32 <= sp.start && sp.end <= (hs & 0xFFFFFFFFu64) as u32 && (nx >= self.start[m + 1] as usize || (self.span[nx] >> 32) as u32 > sp.start) {
                return hint;
            }
        }
        return self.decl_at(m, sp);
    }

    // The module of decl `d`.
    const fn module_of(self: &Self, d: u32) usize {
        return self.dmod[d as usize] as usize;
    }

    // Mark decl `d`: it turns on, and its span joins the output unless it is std code that runs no
    // user code, or std::parallel.
    fn mark(self: &mut Self, d: u32) {
        if self.marked[d as usize] != 0 {
            return;
        }
        self.marked.set(d as usize, 1);
        let m = self.module_of(d);
        if self.stdm[m] == 0 || self.stdm[m] == 1 && self.ureach[d as usize] != 0 {
            self.spans.index_mut(m).push(self.span[d as usize]);
        }
        if self.stdm[m] == 1 && self.ureach[d as usize] == 1 {
            self.inst.index_mut(m).push(self.span[d as usize]);
        }
        if self.on[d as usize] == 0 {
            self.on.set(d as usize, 1);
            self.queue.push(d);
        }
    }

    // A fn value nothing pins may run: mark every fn value of the package.
    fn escape(self: &mut Self) {
        if self.escaped {
            return;
        }
        self.escaped = true;
        for i in 0..self.esc.len() {
            self.mark(self.esc[i]);
        }
    }

    // Add decl `d` to the fn values.
    fn add_esc(self: &mut Self, d: u32) {
        if self.in_esc[d as usize] == 0 {
            self.in_esc.set(d as usize, 1);
            self.esc.push(d);
        }
    }
}

// Path + string helpers (heap-allocated results; callers own them).

// True if `path` names something that can be opened for reading (replaces access(path, F_OK)).
fn path_exists(path: str) bool {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return false;
    }
    unsafe stdio::fclose(f);
    return true;
}

/// Read a whole file into a String padded with lexer::SOURCE_PAD trailing NULs past len (the lexer's
/// read-ahead sentinel); None on any I/O error.
pub fn read_file(path: str) Option<String> {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return Option::<String>::None;
    }
    if unsafe stdio::fseek(f, 0, SEEK_END) != 0 {
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    let s = unsafe stdio::ftell(f);
    unsafe stdio::rewind(f);
    if s < 0 {
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    let sz = s as usize;
    // Read straight into the result, pre-sized to content + read-ahead padding so pad_nul does not
    // reallocate, then append lexer::SOURCE_PAD trailing NUL bytes PAST len (len stays n): a read-ahead
    // sentinel the lexer relies on to over-read safely (see lexer::SOURCE_PAD).
    let mut out = String::with_capacity(sz + lexer::SOURCE_PAD);
    let n = unsafe stdio::fread(out.spare_mut(sz) as *mut char, 1, sz, f);
    if n != sz && unsafe stdio::ferror(f) != 0 {
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    unsafe stdio::fclose(f);
    out.advance_len(n);
    out.pad_nul(lexer::SOURCE_PAD);
    return Option::<String>::Some(out);
}

/// The directory portion of `path` (a view into it, without the trailing slash), or "." when there is none.
pub const fn dirname_of(path: str) str {
    let k = path.len() - basename_of(path).len();
    if k == 0 {
        return ".";
    }
    return path.slice(0, k - 1);
}

// The file stem (basename without extension): "dir/std/string.spc" -> "string".
fn stem_of(path: str) String {
    let b = basename_of(path);
    let mut k = b.len();
    while k > 0 && b[k - 1] != b'.' {
        k -= 1;
    }
    let end = if k == 0 {
        b.len();
    } else {
        k - 1;
    };
    return String::from_str(b.slice(0, end));
}

/// Join an import's path parts with `sep` ("::" for a module path, "/" for a file path).
pub fn join_parts(ast: &Ast, src: str, parts: NodeList, sep: str) String {
    let ids = ast.list(parts);
    let mut out = String::new();
    let mut i: u32 = 0;
    while i < parts.len {
        if i != 0 {
            out.push_str(sep);
        }
        let sp = ast.at_const(unsafe ids[i as usize]).as_data.name.text;
        out.push_str(src.slice(sp.start as usize, sp.end as usize));
        i = i + 1;
    }
    return out;
}

// "<root_dir>/<parts joined by '/'>.spc".
fn module_file_path(root_dir: str, ast: &Ast, src: str, parts: NodeList) String {
    let rel = join_parts(ast, src, parts, "/");
    let mut out = String::from_str(root_dir);
    out.push_str("/");
    out.push_str(rel.as_str());
    out.push_str(".spc");
    return out;
}

// The directory-index form of the same import: `std::parallel` -> `<root>/std/parallel/parallel.spc`. A
// directory of modules can then name itself, so `import std::parallel;` works alongside the explicit
// `import std::parallel::data as parallel;` instead of the alias being the only spelling.
fn module_index_path(root_dir: str, ast: &Ast, src: str, parts: NodeList) String {
    let rel = join_parts(ast, src, parts, "/");
    let last = join_parts(ast, src, NodeList { start: parts.start + parts.len - 1, len: 1 }, "/");
    let mut out = String::from_str(root_dir);
    out.push_str("/");
    out.push_str(rel.as_str());
    out.push_str("/");
    out.push_str(last.as_str());
    out.push_str(".spc");
    return out;
}

/// Heap "<a>/<b>".
pub fn join2(a: str, b: str) String {
    let mut out = String::with_capacity(a.len() + 1 + b.len());
    out.push_str(a);
    out.push_byte(b'/');
    out.push_str(b);
    return out;
}

extend DirCache {
    // Index of `dir` in the cache, scanning (opendir/readdir) it once on first request.
    fn index_of(self: &mut Self, dir: str) usize {
        let h = dir.hash();
        let head = switch self.heads.get(&h) {
            Some(i) => *i,
            None => SYM_NONE,
        };
        let mut i = head;
        while i != SYM_NONE {
            if self.dirs[i as usize].as_str() == dir {
                return i as usize;
            }
            i = self.next[i as usize];
        }
        let mut names = Vector::<String>::new();
        let mut dok = false;
        let mut db = RealBuf {};
        let dl = dir.len();
        if dl < 4096 {
            unsafe cstring::memcpy(&mut db.b[0], dir.ptr(), dl);
            unsafe db.b[dl] = 0 as char;
            let d = unsafe shim::sc_opendir(&db.b[0]);
            if d != null {
                dok = true;
                loop {
                    let e = unsafe shim::sc_readdir(d);
                    if e == null {
                        break;
                    }
                    names.push(String::from_cstr(unsafe shim::sc_dirent_name(e)));
                }
                let _ = unsafe shim::sc_closedir(d);
            }
        }
        names.sort();
        self.heads.insert(h, self.dirs.len() as u32);
        self.next.push(head);
        self.dirs.push(String::from_str(dir));
        self.entries.push(names);
        self.ok.push(dok);
        return self.dirs.len() - 1;
    }
    /// Does `path` (a <dir>/<file>) exist? Answered from the cached listing; a listing miss (dir present but
    /// the name not listed) falls back to fopen so the result matches path_exists exactly, incl. case-
    /// insensitive filesystems. A missing directory is authoritative (fopen would fail too), saving the probe.
    pub fn exists(self: &mut Self, path: str) bool {
        let n = path.len();
        let mut slash: i64 = -1;
        let mut i: usize = 0;
        while i < n {
            if path.byte_at(i) == b'/' {
                slash = i as i64;
            }
            i = i + 1;
        }
        if slash < 0 {
            return path_exists(path);
        }
        let dir = path.slice(0, slash as usize);
        let file = path.slice(slash as usize + 1, n);
        let idx = self.index_of(dir);
        if !self.ok[idx] {
            return false;
        }
        let ents = self.entries.at(idx);
        let mut lo: usize = 0;
        let mut hi = ents.len();
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let c = ents[mid].as_str().cmp(&file);
            if c == 0 {
                return true;
            }
            if c < 0 {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return path_exists(path);
    }
}
// Resolve an import's file by searching the project root first, then the std root (so `import std::x;`
// finds <std_root>/std/x.spc), then the bundled `ffi/` bindings (so a bare `import stdio;` finds
// <std_root>/ffi/stdio.spc). Returns the first path that exists, else the project-relative path. Owned.
fn resolve_import_file(
    dc: &mut DirCache,
    root_dir: str,
    alt_root: str,
    std_root: str,
    ast: &Ast,
    src: str,
    parts: NodeList,
) String {
    let root_rel = module_file_path(root_dir, ast, src, parts);
    if dc.exists(root_rel.as_str()) {
        return root_rel;
    }
    let root_idx = module_index_path(root_dir, ast, src, parts);
    if dc.exists(root_idx.as_str()) {
        return root_idx;
    }
    // Manifest convention fallback: tests/ and bench/ live beside src/, so a project-root-rooted
    // load still resolves the compiler's own modules (and vice versa) through the src/ alt root.
    if !alt_root.is_empty() {
        let alt_rel = module_file_path(alt_root, ast, src, parts);
        if dc.exists(alt_rel.as_str()) {
            return alt_rel;
        }
    }
    if std_root.is_empty() {
        return root_rel;
    }
    let std_rel = module_file_path(std_root, ast, src, parts);
    if dc.exists(std_rel.as_str()) {
        return std_rel;
    }
    let std_idx = module_index_path(std_root, ast, src, parts);
    if dc.exists(std_idx.as_str()) {
        return std_idx;
    }
    let ffi_base = join2(std_root, "ffi");
    let ffi_rel = module_file_path(ffi_base.as_str(), ast, src, parts);
    if dc.exists(ffi_rel.as_str()) {
        return ffi_rel;
    }
    return root_rel;
}

// Lex + parse one module's source into an Ast, printing diagnostics. ok=false on a lex/parse error.
fn parse_source(source: &mut String, file: str, bootstrap_tags: bool, recycled: Vector<tok::Token>) ParseResult {
    return parse_source_q(source, file, bootstrap_tags, recycled, false);
}

fn parse_source_q(source: &mut String, file: str, bootstrap_tags: bool, recycled: Vector<tok::Token>, quiet: bool) ParseResult {
    let mut lx = lexer::Lexer::new(source, file);
    // Adopt the recycled capacity (caller passes it cleared).
    lx.tokens = recycled;
    lx.scan_tokens();
    if lx.has_errors() {
        if !quiet {
            lx.log_errors();
        }
        return ParseResult { ast: Ast::new(0), ok: false, tokens: lx.take_tokens() };
    }
    let toks = lx.take_tokens();
    let src = source.as_str(); // padding lives past len -> invisible to the parser
    let mut ps = parser::Parser::new(toks, src, file);
    ps.set_bootstrap_tags(bootstrap_tags);
    ps.build_ast();
    if ps.has_errors() {
        if !quiet {
            ps.log_errors();
        }
        return ParseResult { ast: Ast::new(0), ok: false, tokens: ps.take_tokens() };
    }
    let mut out = ps.take_ast();
    // Seed the type tables at load: builtin TypeIds are positional (b + 1), and the constant
    // engine may read a module's pool BEFORE its typecheck (a const initializer demanded by an
    // importer). The checker's init_types re-seeds identically.
    out.init_types();
    return ParseResult { ast: out, ok: true, tokens: ps.take_tokens() };
}

// Package construction + module loading.

/// Parallel analysis pays for itself only past this much user (non-prelude) source. Below it the
/// worker pool costs about as much CPU as the whole serial compile and saves a few milliseconds of
/// wall time at most (release build, serial vs parallel: 30 KiB 24 vs 23 ms, 118 KiB 30 vs 25 ms,
/// 472 KiB 57 vs 36 ms).
pub const PAR_MIN_USER_BYTES: usize = 262144; // 256 KiB

// Worker count for parallel module discovery: 1 = the serial reference loader; 0 or >= 2 lets
// speculative parse tasks run on the coroutine pool. Set by the DRIVER before package_load; the
// LSP and library users keep the serial default (overlaid loads always stay serial).
static mut G_LOAD_JOBS: u32 = 1;

/// Set the worker count for parallel module loading (1 = serial) before the first load.
pub fn set_load_jobs(j: u32) {
    unsafe G_LOAD_JOBS = j;
    if j != 1 {
        // Compiler tasks recurse deeply (parser, checker); reserve thread-sized task stacks
        // BEFORE the pool's first launch (a later call is ignored).
        prt::set_stack_size(8usize << 20);
    }
}

// One speculative parse unit: filled by a worker task; imports are collected and resolved by the
// coordinator between waves (the dir cache is a serial memo), and ids are assigned afterwards by
// a serial DFS replay, so module identity is byte-for-byte the recursive loader's.
struct PUnit {
    pub path: String,
    pub file: String,
    pub source: String,
    pub ast: Ast,
    pub ok: bool,
    pub child_paths: Vector<String>,
    pub child_files: Vector<String>,
    pub next: u32, // the previous unit whose path hashes alike, or SYM_NONE
}

// One module on the serial loader's depth-first stack: its unloaded imports and the next to load.
struct LoadFrame {
    pub paths: Vector<String>,
    pub files: Vector<String>,
    pub next: usize,
}

struct PParse {
    pub u: *mut PUnit,
    pub tags: bool,
}

// The unit slot is pinned for the task's lifetime (units only grow between waves) and each task
// owns exactly one slot.
unsafe extend PParse as Send {}

// Append the unit for `path`, linked into `heads` (path hash -> newest unit with that hash).
fn punit_push(units: &mut Vector<PUnit>, heads: &mut Map<u64, u32>, path: str, file: str) {
    let h = path.hash();
    let next = switch heads.get(&h) {
        Some(u) => *u,
        None => SYM_NONE,
    };
    heads.insert(h, units.len() as u32);
    units.push(
        PUnit {
            path: String::from_str(path),
            file: String::from_str(file),
            source: String::new(),
            ast: Ast::new(0),
            ok: false,
            child_paths: Vector::<String>::new(),
            child_files: Vector::<String>::new(),
            next: next,
        },
    );
}

// The index of the unit for `path`, or `units.len()`.
fn punit_find(units: &Vector<PUnit>, heads: &Map<u64, u32>, path: str) usize {
    let mut u = switch heads.get(&path.hash()) {
        Some(h) => *h,
        None => SYM_NONE,
    };
    while u != SYM_NONE {
        if units.at(u as usize).path.as_str() == path {
            return u as usize;
        }
        u = units.at(u as usize).next;
    }
    return units.len();
}

fn par_parse_one(t: PParse) {
    let u = unsafe &mut *t.u;
    switch read_file(u.file.as_str()) {
        Some(sx) => {
            u.source = sx;
        },
        None => {
            u.ok = false;
            return;
        },
    };
    let mut parsed = parse_source_q(&mut u.source, u.file.as_str(), t.tags, Vector::<tok::Token>::new(), true);
    if !parsed.ok {
        u.ok = false;
        return;
    }
    u.ast = replace(&mut parsed.ast, Ast::new(0));
    u.ok = true;
}

/// Load `root_file` and, transitively, every module it imports, then append the std prelude found under
/// `std_dir` (empty skips it). Diagnostics are printed as encountered. Returns a Package (check `.ok`).
pub fn package_load(root_file: str, std_dir: str, bootstrap_tags: bool, target: i32) Package {
    return package_load_rooted(root_file, dirname_of(root_file), "", std_dir, bootstrap_tags, target);
}

/// Like package_load, but imports resolve against an explicit package root instead of the root
/// file's own directory (`super-c lint <dir>` lints nested package files in their true package).
pub fn package_load_rooted(root_file: str, root_dir: str, alt_dir: str, std_dir: str, bootstrap_tags: bool, target: i32) Package {
    ts_init();
    return package_load_overlaid(
        root_file,
        root_dir,
        alt_dir,
        std_dir,
        bootstrap_tags,
        target,
        Vector::<String>::new(),
        Vector::<String>::new(),
    );
}

/// Like package_load_rooted, with in-memory source overlays (see Package.overlay_files). Takes ownership
/// of both parallel vectors.
pub fn package_load_overlaid(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    bootstrap_tags: bool,
    target: i32,
    overlay_files: Vector<String>,
    overlay_texts: Vector<String>,
) Package {
    let mut p = package_base(root_dir, alt_dir, std_dir, overlay_files, overlay_texts);
    p.load_root(root_file, std_dir, bootstrap_tags, target);
    return p;
}

/// An empty package with its import roots, for a driver that sets the build settings (`arch`,
/// `test_build`, `profile`) before `load_root`: the prelude's build-constant module spells them.
pub fn package_new(root_dir: str, alt_dir: str, std_dir: str) Package {
    ts_init();
    return package_base(root_dir, alt_dir, std_dir, Vector::<String>::new(), Vector::<String>::new());
}

/// Prelude-only package (import roots set, no root module): the batch `lint` driver and the LSP's
/// workspace batch load_module each listed file into it afterwards, so every file shares one closure
/// instead of reloading its own. Takes ownership of the overlay vectors (empty for CLI use).
pub fn package_load_prelude(
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    target: i32,
    overlay_files: Vector<String>,
    overlay_texts: Vector<String>,
) Package {
    let mut p = package_base(root_dir, alt_dir, std_dir, overlay_files, overlay_texts);
    p.load_prelude(std_dir, target);
    p.seed_core();
    p.bind_types();
    return p;
}

// An empty package with its import roots and source overlays set.
fn package_base(root_dir: str, alt_dir: str, std_dir: str, overlay_files: Vector<String>, overlay_texts: Vector<String>) Package {
    let mut p = Package::new();
    p.overlay_files = overlay_files;
    p.overlay_texts = overlay_texts;
    p.root_dir = String::from_str(root_dir);
    p.alt_root = String::from_str(alt_dir);
    if std_dir.len() != 0 {
        p.std_root = String::from_str(dirname_of(std_dir));
    }
    return p;
}

/// A batch-listed file's canonical module path: relative to the alt root when under it (the spelling
/// manifest imports must use: the alt root has no index form), else to the package root, `/` -> `::`.
/// A root-level index file (<root>/x/x.spc with no <root>/x.spc beside it) collapses to `x`, mirroring
/// module_index_path, so imports of it dedup against the listed copy.
pub fn batch_mod_path(file: str, root: str, alt: str) String {
    let mut rel = file;
    if rel.len() > 2 && rel.byte_at(0) == b'.' && rel.byte_at(1) == b'/' {
        rel = rel.slice(2, rel.len());
    }
    let mut from_alt = false;
    if alt.len() != 0 && rel.len() > alt.len() && rel.starts_with(alt) && rel.byte_at(alt.len()) == b'/' {
        rel = rel.slice(alt.len() + 1, rel.len());
        from_alt = true;
    } else if root.len() > 1 && rel.len() > root.len() && rel.starts_with(root) && rel.byte_at(root.len()) == b'/' {
        rel = rel.slice(root.len() + 1, rel.len());
    }
    let mut end = rel.len();
    if rel.ends_with(".spc") {
        end = end - 4;
    }
    let mut ls: i64 = -1;
    let mut pv: i64 = -1;
    for i in 0..end {
        if rel.byte_at(i) == b'/' {
            pv = ls;
            ls = i as i64;
        }
    }
    // The index collapse mirrors module_index_path, which only ever probes the PACKAGE root:
    // an alt-rooted `a/a.spc` is imported as `a::a`, so collapsing it would fork a duplicate module.
    if !from_alt && ls >= 0 && rel.slice(ls as usize + 1, end) == rel.slice((pv + 1) as usize, ls as usize) {
        let mut sib = String::from_str(file.slice(0, file.len() - rel.len() + ls as usize));
        sib.push_str(".spc");
        let sf = stdio::fopen(sib.as_str(), "rb");
        if sf == null {
            end = ls as usize;
        } else {
            unsafe stdio::fclose(sf);
        }
    }
    let mut out = String::new();
    for i in 0..end {
        if rel.byte_at(i) == b'/' {
            out.push_str("::");
        } else {
            out.push_byte(rel.byte_at(i));
        }
    }
    return out;
}

/// Like package_load, but the root module is an in-memory source STRING (path "main"), with no user-import
/// recursion: the analog of tests/test_harness.h's sc_compile. The prelude loads FIRST and the user
/// module is appended LAST (its module id past the prelude), matching sc_compile's layout exactly, so
/// module-order-sensitive checks (Ty interning, generic-arg validation) reproduce the C test verdicts.
/// The user module is always the last one: `p.modules.len() - 1`. Used by selfhost/tests.
pub fn package_from_source(src: str, std_dir: str, target: i32) Package {
    let mut p = package_base(".", "", std_dir, Vector::<String>::new(), Vector::<String>::new());
    p.load_prelude(std_dir, target);
    let mut source = String::from_str(src);
    let mut parsed = parse_source(&mut source, "<harness>", false, Vector::<tok::Token>::new());
    let ok = parsed.ok;
    let id = p.add_module(
        String::from_str("main"),
        String::from_str("<harness>"),
        source,
        replace(&mut parsed.ast, Ast::new(0)),
        ok,
    );
    if ok {
        p.modules[id as usize].ast.module = id as ModuleId;
    } else {
        p.ok = false;
    }
    p.seed_core();
    p.bind_types();
    p.platform_filter(target);
    return p;
}

// A PATH_MAX realpath scratch buffer (the omitted array field zero-fills on partial init).
struct RealBuf {
    pub b: [char; 4096],
}

/// The final path component of `path` (a view into it): "dir/std/string.spc" -> "string.spc".
// Append the `str::hash` of every identifier of `src[lo..hi]` to `out` (a word that starts with a
// digit is a number, not a name).
fn bc_scan_names(src: str, lo: u32, hi: u32, out: &mut Vector<u64>) {
    let mut i = lo as usize;
    while i < hi as usize {
        let c = src[i];
        if !bc_name_byte(c) {
            i += 1;
            continue;
        }
        let st = i;
        while i < hi as usize && bc_name_byte(src[i]) {
            i += 1;
        }
        if c < b'0' || c > b'9' {
            out.push(src.slice(st, i).hash());
        }
    }
}

const fn bc_name_byte(c: u8) bool {
    return c == b'_' || c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9';
}

pub const fn basename_of(path: str) str {
    let mut k = path.len();
    while k > 0 && path[k - 1] != b'/' {
        k -= 1;
    }
    return path.slice(k, path.len());
}

/// One sortable image of a batch record with its children as final ids: kind, qualifier, module
/// and the payload words, compared lexicographically (`pub_key_cmp`). Two distinct records never
/// compare equal: the words hold every field the record's identity has.
struct PubKey {
    pub w: [u64; 11],
    pub idx: u32,
    pub rec: Ty, // the record with every child final, inserted in key order
}

const fn pub_key_cmp(a: &PubKey, b: &PubKey) i32 {
    for i in 0..11 {
        let x = unsafe a.w[i];
        let y = unsafe b.w[i];
        if x != y {
            return if x < y {
                -1;
            } else {
                1;
            };
        }
    }
    return 0;
}

// The depth of batch record `b`: 1 + the deepest batch child, 0 for a record whose children are all
// final (`depth` holds the answers for the smaller batch ids).
fn pub_depth(batch: &TypePool, depth: &Vector<u32>, b: usize) u32 {
    let y = batch.at(b);
    let k = y.kind;
    let mut d: u32 = 0;
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        d = pub_child_depth(depth, y.as_data.elem);
    } else if k == TypeKind::TYPE_ARRAY {
        d = pub_child_depth(depth, y.as_data.arr.elem);
        if y.arr_sym() {
            d = d.max(pub_child_depth(depth, y.as_data.arr.len));
        }
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        d = pub_child_depth(depth, y.as_data.proj.owner);
    } else if y.rec() != NO_REC {
        if (y.rec() & TYPE_PROV) != 0 {
            let it = batch.instance((y.rec() & TYPE_PROV_MASK) as usize);
            for q in 0..it.n {
                let cd = pub_child_depth(depth, unsafe it.args[q as usize]);
                if cd > d {
                    d = cd;
                }
            }
        }
    }
    return d;
}

const fn pub_child_depth(depth: &Vector<u32>, t: TypeId) u32 {
    if (t & TYPE_PROV) == 0 {
        return 0;
    }
    return depth[(t & TYPE_PROV_MASK) as usize] + 1;
}

// Push the batch children of batch record `b`.
fn pub_children(batch: &TypePool, b: usize, out: &mut Vector<u32>) {
    let y = batch.at(b);
    let k = y.kind;
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        pub_push_child(y.as_data.elem, out);
    } else if k == TypeKind::TYPE_ARRAY {
        pub_push_child(y.as_data.arr.elem, out);
        if y.arr_sym() {
            pub_push_child(y.as_data.arr.len, out);
        }
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        pub_push_child(y.as_data.proj.owner, out);
    } else if y.rec() != NO_REC {
        if (y.rec() & TYPE_PROV) != 0 {
            let it = batch.instance((y.rec() & TYPE_PROV_MASK) as usize);
            for q in 0..it.n {
                pub_push_child(unsafe it.args[q as usize], out);
            }
        }
    }
}

const fn pub_push_child(t: TypeId, out: &mut Vector<u32>) {
    if (t & TYPE_PROV) != 0 {
        out.push(t & TYPE_PROV_MASK);
    }
}

// A batch child as its final id (numbered already: lower depth).
const fn pub_fin(fin: &Vector<TypeId>, t: TypeId) TypeId {
    if (t & TYPE_PROV) == 0 {
        return t;
    }
    return fin[(t & TYPE_PROV_MASK) as usize];
}

// Batch record `b` with every child final; a batch instance record is moved into the package table
// on first use (`ifin`).
fn pub_final_rec(batch: &TypePool, fin: &Vector<TypeId>, ifin: &mut Vector<u32>, g: &mut TypePool, b: usize) Ty {
    let mut y = *batch.at(b);
    let k = y.kind;
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        y.as_data.elem = pub_fin(fin, y.as_data.elem);
    } else if k == TypeKind::TYPE_ARRAY {
        y.as_data.arr.elem = pub_fin(fin, y.as_data.arr.elem);
        if y.arr_sym() {
            y.as_data.arr.len = pub_fin(fin, y.as_data.arr.len);
        }
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        y.as_data.proj.owner = pub_fin(fin, y.as_data.proj.owner);
    } else if y.rec() != NO_REC && (y.rec() & TYPE_PROV) != 0 {
        let bi = (y.rec() & TYPE_PROV_MASK) as usize;
        if ifin[bi] == 0xFFFFFFFFu32 {
            let mut it = *batch.instance(bi);
            for q in 0..it.n {
                unsafe it.args[q as usize] = pub_fin(fin, unsafe it.args[q as usize]);
            }
            ifin[bi] = g.insert_inst(&it);
        }
        y.set_rec(ifin[bi]);
    }
    return y;
}

fn pub_key(batch: &TypePool, fin: &Vector<TypeId>, ifin: &mut Vector<u32>, g: &mut TypePool, b: usize) PubKey {
    let y = pub_final_rec(batch, fin, ifin, g, b);
    let mut k = PubKey { w: [[0] = 0u64], idx: b as u32, rec: y };
    k.w[0] = y.kind as u64 << 56 | y.qualifier as u64 << 48 | y.module as u64 << 32;
    let kd = y.kind;
    if kd == TypeKind::TYPE_POINTER || kd == TypeKind::TYPE_REFERENCE || kd == TypeKind::TYPE_SLICE {
        k.w[1] = y.as_data.elem;
    } else if kd == TypeKind::TYPE_ARRAY {
        k.w[1] = y.as_data.arr.elem;
        k.w[2] = y.as_data.arr.len;
    } else if kd == TypeKind::TYPE_FIELD_PROJECTION {
        k.w[1] = y.as_data.proj.owner;
        k.w[2] = y.as_data.proj.binder;
    } else if y.rec() != NO_REC {
        let it = g.instance(y.rec() as usize);
        k.w[1] = it.module as u64 << 40 | it.decl as u64 << 8 | it.n as u64;
        for q in 0..it.n {
            unsafe k.w[2 + q as usize] = unsafe it.args[q as usize];
        }
    } else if kd == TypeKind::TYPE_CONST {
        k.w[1] = y.as_data.value as u64;
    } else {
        k.w[1] = y.as_data.decl; // decl, builtin, or the const-expression form index
    }
    return k;
}

// A provisional child of the record at pool index `i`: it must precede it in the same pool.
fn pub_child(map: &Vector<TypeId>, t: TypeId, i: usize) TypeId {
    if (t & TYPE_PROV) == 0 {
        return t;
    }
    let pi = (t & TYPE_PROV_MASK) as usize;
    if pi >= i || pi >= map.len() {
        eprintln("fatal: provisional type {} references a later or foreign provisional type {}", i, pi);
        unsafe stdlib::exit(1);
    }
    return map[pi];
}

extend Package {
    /// The analysis worker count for this loaded package: `jobs` when the user source is large enough
    /// for the parallel frontiers to pay for themselves, else 1 (see PAR_MIN_USER_BYTES).
    pub fn analysis_jobs(self: &Self, jobs: u32) u32 {
        if jobs == 1 {
            return 1;
        }
        let mut bytes: usize = 0;
        for i in 0..self.modules.len() {
            if !self.modules.at(i).prelude {
                bytes += self.modules.at(i).source.len();
            }
        }
        if bytes < PAR_MIN_USER_BYTES {
            return 1;
        }
        return jobs;
    }

    /// Drop @platform-gated items that don't match the build target BEFORE resolution, so inactive code is
    /// parsed-but-never-resolved and two same-named platform variants collapse to the single active one.
    /// target: 0 windows, 1 macos, 2 linux; Attr.arg is the active-set mask (windows=bit0/macos=bit1/linux=bit2).
    /// It also prunes every module's build-constant sites.
    pub fn platform_filter(self: &mut Self, target: i32) {
        let n = self.modules.len();
        for mi in 0..n {
            self.platform_filter_module(mi, target);
        }
    }

    /// Load `root_file` and, transitively, every module it imports, then append the std prelude
    /// under `std_dir` (empty skips it).
    pub fn load_root(self: &mut Self, root_file: str, std_dir: str, bootstrap_tags: bool, target: i32) {
        self.bootstrap = bootstrap_tags;
        let rp = stem_of(root_file);
        let rf = String::from_str(root_file);
        self.load_module(rp.as_str(), rf.as_str(), bootstrap_tags, target);
        self.load_prelude(std_dir, target);
        self.seed_core();
        self.bind_types();
    }

    /// Add the build-constant module `__std::build`, the prelude's last module: this compilation's
    /// settings as constants, spelled from `target`, `arch`, `test_build` and `profile`. ARCH and
    /// POINTER_WIDTH are absent when the instruction set is unknown.
    fn add_build_module(self: &mut Self, target: i32) {
        if self.build_module >= 0 || self.std_root.len() == 0 {
            return;
        }
        self.build_target = target;
        let mut src = String::from_str(
            "/// The target platform (`--target`).\npub const PLATFORM: Platform = Platform::",
        );
        src.push_str(bc_variants(BC_PLATFORM)[target as usize]);
        src.push_str(";\n/// True in a `--test` build.\npub const TEST: bool = ");
        src.push_str(
            if self.test_build {
                "true";
            } else {
                "false";
            },
        );
        src.push_str(
            ";\n/// The byte order of the target.\npub const ENDIAN: Endian = Endian::Little;\n/// The build profile (`--profile`).\npub const PROFILE: str<'static> = \"",
        );
        let prof = self.profile_name();
        for i in 0..prof.len() {
            if prof[i] == b'"' || prof[i] == b'\\' {
                src.push_byte(b'\\');
            }
            src.push_byte(prof[i]);
        }
        src.push_str("\";\n");
        if self.arch >= 0 {
            src.push_str("/// The target instruction set (`--arch`).\npub const ARCH: Arch = Arch::");
            src.push_str(bc_variants(BC_ARCH)[self.arch as usize]);
            src.push_str(";\n/// The width of a pointer in bits.\npub const POINTER_WIDTH: u32 = ");
            src.push_i64(self.bc_value(BC_POINTER_WIDTH));
            src.push_str(";\n");
        }
        let mut parsed = parse_source(&mut src, "", false, Vector::<tok::Token>::new());
        assert(parsed.ok, "the build-constant module parses");
        let id = self.add_module(
            String::from_str("__std::build"),
            String::new(),
            src,
            replace(&mut parsed.ast, Ast::new(0)),
            true,
        );
        self.modules[id as usize].ast.module = id as ModuleId;
        self.modules[id as usize].prelude = true;
        self.build_module = id;
    }

    /// Whether module `m` is std's `target.spc`, the declarer of the build-constant enums.
    pub fn is_target_module(self: &Self, m: ModuleId) bool {
        return m as usize < self.modules.len() && self.modules[m as usize].prelude && basename_of(
            self.modules[m as usize].file.as_str(),
        ) == "target.spc";
    }

    /// The build profile's name: `profile`, `dev` when the driver named none.
    pub const fn profile_name<'a>(self: &'a Self) str<'a> {
        if self.profile.len() == 0 {
            return "dev";
        }
        return self.profile.as_str();
    }

    /// The value build constant `k` (not PROFILE) has in this compilation, -1 when unknown: a
    /// platform or instruction set as its variant index, TEST as 0 or 1.
    pub const fn bc_value(self: &Self, k: i32) i64 {
        if k == BC_PLATFORM {
            return self.build_target;
        }
        if k == BC_ARCH {
            return self.arch;
        }
        if k == BC_TEST {
            return self.test_build as i64;
        }
        if k == BC_POINTER_WIDTH {
            return if self.arch < 0 {
                -1;
            } else if self.arch == 2 {
                32;
            } else {
                64;
            };
        }
        return if k == BC_ENDIAN {
            0;
        } else {
            -1;
        };
    }

    /// The early prune of module `mi` (idempotent): every build-constant site the settings decide
    /// is replaced in place by its taken branch, an `if` by its taken block (an empty block when
    /// none is), a `switch` by the body of the first arm that matches. Sites are in parse order,
    /// so an `else if` is decided before the `if` that holds it. Each replaced site records its
    /// span and the identifiers of its removed text (`Ast.bc_cuts`, `Ast.bc_names`).
    pub fn prune_build_sites(self: &mut Self, mi: usize) {
        let mut names = Vector::<u64>::new();
        let ns = self.modules[mi].ast.bc_sites.len();
        for i in 0..ns {
            let a = &self.modules[mi].ast;
            let id = a.bc_sites[i];
            let n = *a.at_const(id);
            let mut take = NODE_NONE;
            if n.kind == NodeKind::NODE_IF {
                let v = self.bc_eval(mi, n.as_data.if_stmt.condition);
                if v < 0 {
                    continue;
                }
                take = pick(v == 1, n.as_data.if_stmt.then_branch, n.as_data.if_stmt.else_branch);
            } else if n.kind == NodeKind::NODE_MATCH {
                take = self.bc_arm_body(mi, n.as_data.match_expr.value, n.as_data.match_expr.arms);
                if take == NODE_NONE {
                    continue;
                }
            } else {
                continue;
            }
            // The removed text: the whole site, or the site around its taken branch.
            let mut ks = n.span.end;
            let mut ke = n.span.end;
            if take != NODE_NONE {
                ks = self.modules[mi].ast.at_const(take).span.start;
                ke = self.modules[mi].ast.at_const(take).span.end;
            }
            bc_scan_names(self.modules[mi].source.as_str(), n.span.start, ks, &mut names);
            bc_scan_names(self.modules[mi].source.as_str(), ke, n.span.end, &mut names);
            let ast = &mut self.modules[mi].ast;
            ast.bc_cuts.push(BcCut { node: id, span: n.span });
            if take == NODE_NONE {
                *ast.at(id) = Node {
                    kind: NodeKind::NODE_BLOCK,
                    span: n.span,
                    as_data: NodeAs { block: BlockData { statements: NodeList { start: 0, len: 0 } } },
                };
            } else if ast.at_const(take).kind == NodeKind::NODE_BLOCK || n.kind == NodeKind::NODE_IF {
                *ast.at(id) = *ast.at_const(take);
            } else {
                // An expression arm becomes the value of a one-statement block: the switch node
                // keeps its id, the arm's expression keeps its own.
                let tsp = ast.at_const(take).span;
                ast.sink_body = Ast::in_body(id);
                let es = ast.add(
                    Node {
                        kind: NodeKind::NODE_EXPRESSION_STATEMENT,
                        span: tsp,
                        as_data: NodeAs { single: SingleData { value: take } },
                    },
                );
                let mark = ast.mark();
                ast.push(es);
                let stmts = ast.commit(mark);
                ast.sink_body = false;
                *ast.at(id) = Node {
                    kind: NodeKind::NODE_BLOCK,
                    span: n.span,
                    as_data: NodeAs { block: BlockData { statements: stmts } },
                };
            }
        }
        if names.len() != 0 {
            let all = &mut self.modules[mi].ast.bc_names;
            for k in 0..names.len() {
                all.push(names[k]);
            }
            all.sort();
            all.dedup();
        }
    }

    // A build-constant condition of module `mi`: 1 true, 0 false, -1 not decided here.
    fn bc_eval(self: &Self, mi: usize, id: NodeId) i32 {
        let n = *self.modules[mi].ast.at_const(id);
        if n.kind == NodeKind::NODE_IDENTIFIER {
            return if self.bc_const(mi, id) == BC_TEST {
                self.bc_value(BC_TEST) as i32;
            } else {
                -1;
            };
        }
        if n.kind == NodeKind::NODE_UNARY {
            let v = self.bc_eval(mi, n.as_data.unary.operand);
            return if v < 0 {
                -1;
            } else {
                1 - v;
            };
        }
        if n.kind != NodeKind::NODE_BINARY {
            return -1;
        }
        let b = n.as_data.binary;
        if b.op == tt::TokenType::AmpersandAmpersand || b.op == tt::TokenType::PipePipe {
            let l = self.bc_eval(mi, b.left);
            let r = self.bc_eval(mi, b.right);
            if l < 0 || r < 0 {
                return -1;
            }
            return if b.op == tt::TokenType::AmpersandAmpersand {
                l & r;
            } else {
                l | r;
            };
        }
        let mut e = self.bc_eq(mi, b.left, b.right);
        if e < 0 {
            e = self.bc_eq(mi, b.right, b.left);
        }
        if e < 0 {
            return -1;
        }
        return if b.op == tt::TokenType::EqualEqual {
            e;
        } else {
            1 - e;
        };
    }

    // `c == x` for build constant `c` of module `mi`: 1, 0, or -1 when not decided here.
    fn bc_eq(self: &Self, mi: usize, c: NodeId, x: NodeId) i32 {
        let k = self.bc_const(mi, c);
        if k < 0 || k == BC_PROFILE {
            return -1;
        }
        let cur = self.bc_value(k);
        if cur < 0 {
            return -1;
        }
        let a = &self.modules[mi].ast;
        let src = self.modules[mi].source.as_str();
        let xn = a.at_const(x);
        if k == BC_TEST || k == BC_POINTER_WIDTH {
            if xn.kind != NodeKind::NODE_LITERAL {
                return -1;
            }
            let t = xn.as_data.literal.token_type;
            let v = if t == tt::TokenType::True {
                1;
            } else if t == tt::TokenType::False {
                0;
            } else if k == BC_POINTER_WIDTH && t == tt::TokenType::IntegerLiteral {
                bc_decimal(src, xn.as_data.literal.raw);
            } else {
                -1;
            };
            return if v < 0 {
                -1;
            } else {
                (v == cur) as i32;
            };
        }
        if xn.kind != NodeKind::NODE_MEMBER || !xn.as_data.member.path {
            return -1;
        }
        let sp = a.at_const(xn.as_data.member.member).as_data.name.text;
        return (bc_variant(k, src.slice(sp.start as usize, sp.end as usize)) as i64 == cur) as i32;
    }

    // The body of the first arm of a `switch` over build constant `value` (module `mi`) whose
    // pattern matches the setting; NODE_NONE when no arm does or the setting is unknown.
    fn bc_arm_body(self: &Self, mi: usize, value: NodeId, arms: NodeList) NodeId {
        let k = self.bc_const(mi, value);
        let cur = self.bc_value(k);
        if cur < 0 {
            return NODE_NONE;
        }
        let a = &self.modules[mi].ast;
        for i in 0..arms.len {
            let arm = a.at_const(unsafe a.list(arms)[i as usize]).as_data.match_arm;
            let pn = a.at_const(arm.pattern);
            if pn.kind == NodeKind::NODE_PATTERN_OR {
                for j in 0..pn.as_data.pattern.children.len {
                    if self.bc_arm_hit(mi, k, cur, unsafe a.list(pn.as_data.pattern.children)[j as usize]) {
                        return arm.body;
                    }
                }
            } else if self.bc_arm_hit(mi, k, cur, arm.pattern) {
                return arm.body;
            }
        }
        return NODE_NONE;
    }

    fn bc_arm_hit(self: &Self, mi: usize, k: i32, cur: i64, pat: NodeId) bool {
        let a = &self.modules[mi].ast;
        let pn = a.at_const(pat);
        if pn.kind == NodeKind::NODE_PATTERN_WILDCARD {
            return true;
        }
        let sp = a.at_const(pn.as_data.pattern.name).as_data.name.text;
        return bc_variant(k, self.modules[mi].source.as_str().slice(sp.start as usize, sp.end as usize)) as i64 == cur;
    }

    // The build constant (`BC_*`) identifier `id` of module `mi` names, -1 for any other node.
    fn bc_const(self: &Self, mi: usize, id: NodeId) i32 {
        let n = self.modules[mi].ast.at_const(id);
        if n.kind != NodeKind::NODE_IDENTIFIER {
            return -1;
        }
        let sp = n.as_data.name.text;
        return bc_index(self.modules[mi].source.as_str().slice(sp.start as usize, sp.end as usize));
    }

    /// Filter one module's item list (idempotent): the LSP's incremental rebuild re-filters only the
    /// reparsed module.
    pub fn platform_filter_module(self: &mut Self, mi: usize, target: i32) {
        if self.modules[mi].has_ast {
            self.prune_build_sites(mi);
        }
        let arch = self.arch; // the instruction-set axis rides on the package, so no caller has to thread it
        let m = &mut self.modules[mi];
        let root = m.ast.root;
        if m.ast.at_const(root).kind != NodeKind::NODE_PROGRAM {
            return;
        }
        // The owners of a gate that fails, sorted for the per-item probe: O(A + I log A).
        let mut dropped = Vector::<NodeId>::new();
        for k in 0..m.ast.attrs.len() {
            let at = m.ast.attrs.at(k);
            if at.kind == AttrKind::ATTR_PLATFORM as u8 && (at.arg >> target as u32 & 1u32) == 0 {
                dropped.push(at.owner);
            }
            // `@arch` gates the same way on the instruction set. An unknown host arch (-1)
            // keeps every gated item: dropping them all would silently empty the program.
            if at.kind == AttrKind::ATTR_ARCH as u8 && arch >= 0 && (at.arg >> arch as u32 & 1u32) == 0 {
                dropped.push(at.owner);
            }
        }
        if dropped.len() == 0 {
            return;
        }
        dropped.sort();
        let items = m.ast.at_const(root).as_data.program.items;
        let mut w: u32 = 0;
        for j in 0..items.len {
            let id = unsafe m.ast.list(items)[j as usize];
            if dropped.binary_search(&id).is_err() {
                m.ast.children.set((items.start + w) as usize, id);
                w = w + 1;
            } else {
                // A dropped container's members no longer have one.
                let n = *m.ast.at_const(id);
                if n.kind == NodeKind::NODE_EXTEND {
                    m.ast.set_members(NODE_NONE, n.as_data.extend_def.items);
                } else if n.kind == NodeKind::NODE_INTERFACE {
                    m.ast.set_members(NODE_NONE, n.as_data.interface_def.items);
                }
            }
        }
        m.ast.at(root).as_data.program.items.len = w;
    }

    /// Put every module under the package type table (package identity): each module's pool then
    /// holds only its provisional types, published in batches by `publish_types`.
    pub fn bind_types(self: &mut Self) {
        if self.tt.deref().len() == 0 {
            self.tt.deref_mut().seed();
            self.tt_class.resize_default(self.tt.deref().len());
        }
        let gp = self.tt.deref_mut() as *mut TypePool;
        for i in 0..self.modules.len() {
            if self.modules[i].has_ast {
                self.modules[i].ast.gt = gp;
            }
        }
    }

    /// The final id of `t` as module `m` knew it before the last publication (final ids pass through).
    pub const fn map_type(self: &Self, m: ModuleId, t: TypeId) TypeId {
        if (t & TYPE_PROV) == 0 || m as usize >= self.pub_map.len() {
            return t;
        }
        return self.pub_map.at(m as usize)[(t & TYPE_PROV_MASK) as usize];
    }

    /// A total order over two modules' const-expression forms by content (`module << 32 | pool
    /// index` each): the constant, the term count, the divisor, the types, then each term's
    /// parameter and coefficient.
    fn clin_less(self: &Self, x: u64, y: u64) bool {
        let a = self.modules[(x >> 32) as usize].ast.pool.const_lin_at((x & 0xFFFFFFFFu64) as usize);
        let b = self.modules[(y >> 32) as usize].ast.pool.const_lin_at((y & 0xFFFFFFFFu64) as usize);
        if a.k != b.k {
            return a.k < b.k;
        }
        if a.n != b.n {
            return a.n < b.n;
        }
        if a.div != b.div {
            return a.div < b.div;
        }
        if a.ty != b.ty {
            return a.ty as u8 < b.ty as u8;
        }
        if a.to != b.to {
            return a.to as u8 < b.to as u8;
        }
        for i in 0..a.n {
            let pa = unsafe a.p[i as usize];
            let pb = unsafe b.p[i as usize];
            if pa.module != pb.module {
                return pa.module < pb.module;
            }
            if pa.node != pb.node {
                return pa.node < pb.node;
            }
            if unsafe a.c[i as usize] != unsafe b.c[i as usize] {
                return unsafe a.c[i as usize] < unsafe b.c[i as usize];
            }
        }
        return false;
    }

    /// Publish every provisional type of every module as one batch. The batch's distinct records
    /// (a record two modules both hold is one) get final ids appended after the ids of earlier
    /// batches, in a canonical order that depends on nothing but the set of records: first the
    /// records reachable from function signatures, then the rest, each class by structural depth
    /// (children before parents) and within a depth by the record's structural key. So the ids
    /// are the same under any worker count, and a body-only edit leaves every signature id in
    /// place. Then every module's tables are remapped (`Ast::publish_remap`) and its pool cleared;
    /// the maps stay in `pub_map` for the driver to remap the stores it owns (the constant engine,
    /// the kept lowerings).
    pub fn publish_types(self: &mut Self) {
        let n = self.modules.len();
        self.ensure_index();
        self.pub_map.clear();
        // Pass 1: the batch table, records translated so a provisional child is a batch id (tagged).
        let mut batch = TypePool {};
        let mut bmaps = Vector::<Vector<TypeId>>::new();
        let mut bimaps = Vector::<Vector<u32>>::new();
        // The const-expression forms of every module pool take their package index in one
        // canonical order (their content), not in the order the pools interned them: that order
        // follows the item schedule, and the index is the form's publication key.
        let mut cpre = Vector::<Vector<u32>>::new();
        {
            let mut refs = Vector::<u64>::new(); // module << 32 | pool index
            for m in 0..n {
                let mut cmap = Vector::<u32>::new();
                if self.modules[m].has_ast && self.modules[m].ast.gt != null {
                    let a = &self.modules[m].ast;
                    for pi in 0..a.pool.nclin() {
                        cmap.push(0xFFFFFFFFu32);
                        refs.push(m as u64 << 32 | pi as u64);
                    }
                }
                cpre.push(cmap);
            }
            // Insertion sort by content: the forms of a batch are few.
            for i in 1..refs.len() {
                let v = refs[i];
                let mut j = i;
                while j > 0 && self.clin_less(v, refs[j - 1]) {
                    refs.set(j, refs[j - 1]);
                    j -= 1;
                }
                refs.set(j, v);
            }
            let g = self.tt.deref_mut();
            for i in 0..refs.len() {
                let m = (refs[i] >> 32) as usize;
                let pi = (refs[i] & 0xFFFFFFFFu64) as usize;
                let ci = g.insert_clin(self.modules[m].ast.pool.const_lin_at(pi));
                cpre.index_mut(m).set(pi, ci);
            }
        }
        {
            let g = self.tt.deref_mut();
            for m in 0..n {
                let mut map = Vector::<TypeId>::new();
                let mut imap = Vector::<u32>::new();
                let mut cmap = replace(cpre.index_mut(m), Vector::<u32>::new());
                if self.modules[m].has_ast && self.modules[m].ast.gt != null {
                    let a = &mut self.modules[m].ast;
                    let np = a.pool.len();
                    map.reserve(np);
                    for _ in 0..a.pool.ninst() {
                        imap.push(0xFFFFFFFFu32);
                    }
                    for i in 0..np {
                        let mut y = *a.pool.at(i);
                        let k = y.kind;
                        if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
                            y.as_data.elem = pub_child(&map, y.as_data.elem, i);
                        } else if k == TypeKind::TYPE_ARRAY {
                            y.as_data.arr.elem = pub_child(&map, y.as_data.arr.elem, i);
                            if y.arr_sym() {
                                y.as_data.arr.len = pub_child(&map, y.as_data.arr.len, i);
                            }
                        } else if k == TypeKind::TYPE_FIELD_PROJECTION {
                            y.as_data.proj.owner = pub_child(&map, y.as_data.proj.owner, i);
                        } else if y.rec() != NO_REC {
                            let ii = y.rec();
                            if (ii & TYPE_PROV) != 0 {
                                let pi = (ii & TYPE_PROV_MASK) as usize;
                                if imap[pi] == 0xFFFFFFFFu32 {
                                    let mut it = *a.pool.instance(pi);
                                    for q in 0..it.n {
                                        unsafe it.args[q as usize] = pub_child(&map, unsafe it.args[q as usize], i);
                                    }
                                    imap[pi] = batch.insert_inst(&it) | TYPE_PROV;
                                }
                                y.set_rec(imap[pi]);
                            }
                        } else if k == TypeKind::TYPE_CONST_EXPR {
                            let ci = y.as_data.inst;
                            if (ci & TYPE_PROV) != 0 {
                                let pi = (ci & TYPE_PROV_MASK) as usize;
                                if cmap[pi] == 0xFFFFFFFFu32 {
                                    cmap[pi] = g.insert_clin(a.pool.const_lin_at(pi));
                                }
                                y.as_data.inst = cmap[pi];
                            }
                        }
                        map.push(batch.insert_ty(y) | TYPE_PROV);
                    }
                }
                bmaps.push(map);
                bimaps.push(imap);
            }
        }
        let nb = batch.len();
        // Depth: children precede parents in every pool, so batch ids of children are smaller and
        // one ascending pass settles it. Class: reachable from a function signature.
        let mut depth = Vector::<u32>::new();
        let mut sig = Vector::<bool>::new();
        for b in 0..nb {
            depth.push(pub_depth(&batch, &depth, b));
            sig.push(false);
        }
        {
            let mut stack = Vector::<u32>::new();
            for k in 0..self.idx.items.len() {
                let it = *self.idx.items.at(k);
                if it.kind != ItemKind::IK_FUNCTION as u8 && it.kind != ItemKind::IK_METHOD as u8 {
                    continue;
                }
                let a = unsafe &*self.module_ast_const(it.module);
                if !a.valid(it.node) || a.at_const(it.node).kind != NodeKind::NODE_FUNCTION || a.gt == null {
                    continue;
                }
                let fd = a.at_const(it.node).as_data.function;
                for pi in 0..fd.params.len + fd.returns.len {
                    let nd = if pi < fd.params.len {
                        unsafe a.list(fd.params)[pi as usize];
                    } else {
                        unsafe a.list(fd.returns)[(pi - fd.params.len) as usize];
                    };
                    let t = a.type_of(nd);
                    if (t & TYPE_PROV) != 0 {
                        stack.push(bmaps.at(it.module as usize)[(t & TYPE_PROV_MASK) as usize] & TYPE_PROV_MASK);
                    }
                }
                while stack.len() > 0 {
                    let b = stack[stack.len() - 1] as usize;
                    let _ = stack.pop();
                    if sig[b] {
                        continue;
                    }
                    sig.set(b, true);
                    pub_children(&batch, b, &mut stack);
                }
            }
        }
        // Final ids: class, then depth, then the structural key; the key holds children as final
        // ids, so each (class, depth) group sorts after the groups it depends on are numbered.
        let mut fin = Vector::<TypeId>::new();
        for _ in 0..nb {
            fin.push(TYPE_NONE);
        }
        let mut ifin = Vector::<u32>::new();
        for _ in 0..batch.ninst() {
            ifin.push(0xFFFFFFFFu32);
        }
        let mut maxd: u32 = 0;
        for b in 0..nb {
            if depth[b] > maxd {
                maxd = depth[b];
            }
        }
        // Bucket by (class, depth) in one pass; each bucket is numbered in structural-key order.
        let ngroups = 2 * (maxd as usize + 1);
        let mut groups = Vector::<Vector<u32>>::new();
        groups.resize_default(ngroups);
        for b in 0..nb {
            let cls: usize = if sig[b] {
                0;
            } else {
                1;
            };
            groups.index_mut(cls * (maxd as usize + 1) + depth[b] as usize).push(b as u32);
        }
        let mut keys = Vector::<PubKey>::new();
        {
            let g = self.tt.deref_mut();
            for gi in 0..ngroups {
                let cls = gi / (maxd as usize + 1);
                let grp = groups.at(gi);
                keys.clear();
                for q in 0..grp.len() {
                    keys.push(pub_key(&batch, &fin, &mut ifin, g, grp[q] as usize));
                }
                keys.sort_by(pub_key_cmp);
                {
                    for q in 0..keys.len() {
                        let b = keys.at(q).idx as usize;
                        let y = keys.at(q).rec;
                        let id = g.insert_ty(y);
                        fin.set(b, id);
                        while self.tt_class.len() <= id as usize {
                            self.tt_class.push(3);
                        }
                        self.tt_class[id as usize] = if self.publications == 0 {
                            cls as u8;
                        } else {
                            2;
                        };
                    }
                }
            }
            if g.len() as u64 > TYPE_MAX as u64 {
                eprintln("fatal: the package holds more than {} types", TYPE_MAX);
                unsafe stdlib::exit(1);
            }
        }
        // Per-module maps to final ids, then the tables.
        for m in 0..n {
            let mut map = Vector::<TypeId>::new();
            let mut imap = Vector::<u32>::new();
            let bm = bmaps.at(m);
            for i in 0..bm.len() {
                map.push(fin[(bm[i] & TYPE_PROV_MASK) as usize]);
            }
            let bim = bimaps.at(m);
            for i in 0..bim.len() {
                let bi = bim[i];
                if bi == 0xFFFFFFFFu32 {
                    imap.push(bi);
                } else {
                    imap.push(ifin[(bi & TYPE_PROV_MASK) as usize]);
                }
            }
            if map.len() != 0 {
                self.modules[m].ast.publish_remap(&map, &imap);
            }
            self.pub_map.push(map);
        }
        self.publications += 1;
    }

    /// The package type table as text, one line per record (`class kind qualifier module payload`,
    /// children as final ids; `I module decl n args` for an instance record): the identity every
    /// module shares, compared across worker counts and edits by the validation gates.
    pub fn type_table_dump(self: &Self, out: &mut String) {
        let g = self.tt.deref();
        for t in 0..g.len() {
            let y = g.at(t);
            let cls: u8 = if t < self.tt_class.len() {
                self.tt_class[t];
            } else {
                3;
            };
            out.push_u64(t as u64);
            out.push_byte(b' ');
            out.push_u64(cls);
            out.push_byte(b' ');
            out.push_u64(y.kind as u64);
            out.push_byte(b' ');
            out.push_u64(y.qualifier);
            out.push_byte(b' ');
            out.push_u64(y.module);
            out.push_byte(b' ');
            let k = y.kind;
            if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
                out.push_u64(y.as_data.elem);
            } else if k == TypeKind::TYPE_ARRAY {
                out.push_u64(y.as_data.arr.elem);
                out.push_byte(b' ');
                out.push_u64(y.as_data.arr.len);
            } else if k == TypeKind::TYPE_FIELD_PROJECTION {
                out.push_u64(y.as_data.proj.owner);
                out.push_byte(b' ');
                out.push_u64(y.as_data.proj.binder);
            } else if y.rec() != NO_REC {
                let it = g.instance(y.rec() as usize);
                out.push_str("I ");
                out.push_u64(it.module);
                out.push_byte(b' ');
                out.push_u64(it.decl);
                out.push_byte(b' ');
                out.push_u64(it.n);
                for q in 0..it.n {
                    out.push_byte(b' ');
                    out.push_u64(unsafe it.args[q as usize]);
                }
            } else if k == TypeKind::TYPE_CONST {
                out.push_i64(y.as_data.value);
            } else {
                out.push_u64(y.as_data.decl);
            }
            out.push_byte(b'\n');
        }
    }

    /// Validation after a publication: no module table may still name a provisional id.
    pub fn check_published(self: &Self) bool {
        for m in 0..self.modules.len() {
            if self.modules.at(m).has_ast && self.modules.at(m).ast.has_provisional() {
                eprintln("type-validate: module {} still holds a provisional type id after publication", m);
                return false;
            }
        }
        return true;
    }

    /// An empty package for the host architecture; `load_module` fills it.
    pub fn new() Package {
        return Package {
            arch: unsafe shim::sc_host_arch(),
            build_module: -1,
            tt: Box::<TypePool>::new(TypePool {}),
            ok: true,
            jobs: 1, // serial unless a driver opts in: a bare Package must never launch tasks
        };
    }

    /// True when a loop in the body whose span is `osp` (module `m`) can run inside a coroutine
    /// and therefore needs a preemption safepoint at its backedges.
    pub fn co_on(self: &Self, m: ModuleId, osp: tok::Span) bool {
        if self.co_state != 1 {
            return true;
        }
        if m as usize >= self.co_spans.len() {
            return false;
        }
        let row = self.co_spans.at(m as usize);
        for i in 0..row.len() {
            let e = row[i];
            if (e >> 32) as u32 <= osp.start && osp.end <= (e & 0xFFFFFFFFu64) as u32 {
                return true;
            }
        }
        return false;
    }

    /// Is the std decl declared exactly at `sp` (module `m`) one whose ticks its instances decide
    /// (`co_inst`)?
    pub fn co_inst_on(self: &Self, m: ModuleId, sp: tok::Span) bool {
        if m as usize >= self.co_inst.len() {
            return false;
        }
        let row = self.co_inst.at(m as usize);
        let k = sp.start as u64 << 32 | sp.end as u64;
        for i in 0..row.len() {
            if row[i] == k {
                return true;
            }
        }
        return false;
    }

    /// Compute co_spans: the functions and closures a coroutine can execute. Seeds are the entry
    /// arguments of the coroutine entry APIs (`CO_ENTRY_*`; `launch` desugars to `runtime::submit`);
    /// the closure marks, from every marked decl, everything declared inside it and every decl it
    /// reaches, std included:
    ///   - a pinned call reaches its callee; a call to an interface method reaches the method and
    ///     every conformance method of the same name (a bound or `dyn` dispatch, class-hierarchy
    ///     style);
    ///   - an implicit call reaches its method: a `for` loop's `next`, an operator method, a
    ///     user `Deref` hop, and every `free` of a conformance (a drop runs anywhere); an operator
    ///     on an aggregate or type parameter that emission dispatches (`agg_op_name`) reaches the
    ///     interface methods of that name, and through them their conformances;
    ///   - a function named as a value reaches it;
    ///   - a call to the decl's own parameter makes that parameter a NEED of a function: each call
    ///     site of the function must pass a closure, a named function, or a parameter of its own
    ///     function (which becomes a need in turn); a function entered any other way, or any other
    ///     call to a fn value, reaches every fn value of the package (every closure, every function
    ///     named as a value outside std::parallel).
    /// std::parallel runs fn values only through its own dispatch: coroutine entries (seeded at
    /// their public APIs), jobs and pool threads, and its own commit and hook functions; its calls
    /// to fn values and its functions named as values add nothing. A call into it from outside
    /// passes each argument that can hold a fn value under the need rule (`co_parallel_args_ok`),
    /// so a fn value it stores and runs later is reached.
    /// std decls join co_spans only when their bodies can run user code (a std loop is otherwise
    /// bounded by its inputs), and never in std::parallel; those that run it only through bound
    /// dispatch also join co_inst, whose ticks each instance decides at emission.
    /// One scan of every node builds the decl table and keeps, in node order, the sites the records
    /// come from; the closure is a worklist over decls.
    pub fn co_compute(self: &mut Self) {
        self.co_state = 1;
        self.co_spans.truncate(0);
        self.co_spans.resize_default(self.modules.len());
        self.co_fnv.truncate(0);
        self.co_inst.truncate(0);
        if self.find("std::parallel::runtime") < 0 {
            // No coroutine runtime loaded: nothing can launch.
            return;
        }
        let mut ent = Vector::<u64>::new(); // module << 32 | node
        let mut ent_p = Vector::<u32>::new();
        self.co_entries(&mut ent, &mut ent_p);
        let nm = self.modules.len();
        let mut g = CoGraph {
            start: Vector::<u32>::new(),
            span: Vector::<u64>::new(),
            parent: Vector::<u32>::new(),
            lim: Vector::<u32>::new(),
            dmod: Vector::<u32>::new(),
            node: Vector::<u32>::new(),
            closure: Vector::<u8>::new(),
            need: Vector::<u64>::new(),
            ix: Vector::<u32>::new(),
            ix_start: Vector::<usize>::new(),
            nb: Vector::<usize>::new(),
            on: Vector::<u8>::new(),
            marked: Vector::<u8>::new(),
            queue: Vector::<u32>::new(),
            spans: Vector::<Vector<u64>>::new(),
            esc: Vector::<u32>::new(),
            in_esc: Vector::<u8>::new(),
            escaped: false,
            stdm: Vector::<u8>::new(),
            ureach: Vector::<u8>::new(),
            inst: Vector::<Vector<u64>>::new(),
        };
        for m in 0..nm {
            let pth = self.modules.at(m).path.as_str();
            let mut sm: u8 = 0;
            if pth.starts_with("std::parallel") {
                sm = 2;
            } else if pth.starts_with("std::") || pth.starts_with("__std::") {
                sm = 1;
            }
            g.stdm.push(sm);
        }
        // Decls sorted by span start within each module: the decls inside decl `d` are the run that
        // follows it while their starts stay below its end, and a site's innermost decl is the
        // last start at or before it whose end covers it (else that decl's ancestor).
        let mut dm_span = Vector::<u64>::new(); // per-module collection scratch
        let mut dm_node = Vector::<u32>::new();
        let mut callee = Vector::<u64>::new(); // bit set over `g.ix` slots: nodes in callee position
        // One slot per node of every module, sized once.
        let mut total: usize = 0;
        for m in 0..nm {
            g.ix_start.push(total);
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            g.nb.push(a.nodes.len());
            total += a.nnodes();
        }
        g.ix.resize_default(total);
        callee.resize_default(total / 64 + 1);
        // The one scan of every node also keeps, in node order, the nodes the records come from:
        // calls, `for` loops, `?` conversions, and the nodes of function type that can name a
        // function as a value (outside std::parallel).
        let mut sites = Vector::<u32>::new();
        // Per site: 1 when it may name a function as a value, 2 for an operator `agg_op_name` names.
        let mut site_named = Vector::<u8>::new();
        let mut site_start = Vector::<u32>::new(); // per module (+ sentinel): its first site
        for m in 0..nm {
            g.start.push(g.span.len() as u32);
            site_start.push(sites.len() as u32);
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            let spar = g.stdm[m] == 2;
            dm_span.truncate(0);
            dm_node.truncate(0);
            let nb9 = a.nodes.len();
            let nn9 = a.nnodes();
            let ix0 = g.ix_start[m];
            for k in 0..nn9 {
                let ni = Ast::nth_id_n(nb9, k);
                let n = a.at_const(ni);
                let nk = n.kind;
                if nk == NodeKind::NODE_FUNCTION || nk == NodeKind::NODE_CLOSURE {
                    dm_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                    dm_node.push(ni);
                } else if nk == NodeKind::NODE_FOR {
                    sites.push(ni);
                    site_named.push(0);
                } else if !spar && nk == NodeKind::NODE_UNARY && n.as_data.unary.op == tt::TokenType::Question {
                    sites.push(ni);
                    site_named.push(1);
                } else if nk == NodeKind::NODE_BINARY || nk == NodeKind::NODE_ASSIGNMENT {
                    if agg_op_name(a, n).len() != 0 {
                        sites.push(ni);
                        site_named.push(2);
                    }
                } else if nk != NodeKind::NODE_CALL {
                    // The type test first and without a branch on TYPE_NONE (it reads slot 0, the
                    // error type): it is rarely true, while the kind tests are not.
                    if !spar && a.type_at(a.type_of(ni)).kind == TypeKind::TYPE_FUNCTION && (nk == NodeKind::NODE_IDENTIFIER || nk == NodeKind::NODE_MEMBER && n.as_data.member.path || nk == NodeKind::NODE_GENERIC_SPECIALIZATION) {
                        sites.push(ni);
                        site_named.push(1);
                    }
                } else {
                    sites.push(ni);
                    site_named.push(0);
                    // Mark the callee and the nodes it names through (turbofish, path segment).
                    let mut c = n.as_data.call.callee;
                    loop {
                        let ck = ix0 + a.dense(c);
                        callee.set(ck / 64, callee[ck / 64] | 1u64 << (ck % 64) as u64);
                        let cn = a.at_const(c);
                        if cn.kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
                            c = cn.as_data.specialization.expression;
                        } else if cn.kind == NodeKind::NODE_MEMBER {
                            c = cn.as_data.member.member;
                        } else {
                            break;
                        }
                    }
                }
            }
            // Insertion sort by start: decl order is nearly source order already.
            for x in 1..dm_span.len() {
                let mut y = x;
                while y > 0 && dm_span[y - 1] > dm_span[y] {
                    let ts = dm_span[y - 1];
                    dm_span.set(y - 1, dm_span[y]);
                    dm_span.set(y, ts);
                    let tn = dm_node[y - 1];
                    dm_node.set(y - 1, dm_node[y]);
                    dm_node.set(y, tn);
                    y -= 1;
                }
            }
            let base = g.span.len() as u32;
            let mut open = CO_NONE; // the innermost decl whose span is still open
            for x in 0..dm_span.len() {
                let sp = dm_span[x];
                let st = (sp >> 32) as u32;
                while open != CO_NONE && (g.span[open as usize] & 0xFFFFFFFFu64) as u32 <= st {
                    open = g.parent[open as usize];
                }
                g.span.push(sp);
                g.parent.push(open);
                g.lim.push(base + dm_span.len() as u32);
                g.dmod.push(m as u32);
                g.node.push(dm_node[x]);
                let mut clo: u8 = 0;
                if a.at_const(dm_node[x]).kind == NodeKind::NODE_CLOSURE {
                    clo = 1;
                }
                g.closure.push(clo);
                g.ix.set(ix0 + a.dense(dm_node[x]), base + x as u32 + 1);
                open = base + x as u32;
            }
        }
        g.start.push(g.span.len() as u32);
        site_start.push(sites.len() as u32);
        let nd = g.span.len();
        g.need.resize_default(nd);
        g.on.resize_default(nd);
        g.marked.resize_default(nd);
        g.in_esc.resize_default(nd);
        g.ureach.resize_default(nd);
        g.spans.resize_default(nm);
        g.inst.resize_default(nm);
        for d in 0..nd {
            if g.closure[d] != 0 {
                g.add_esc(d as u32);
            }
        }
        // Records, attached to their innermost decl: the target decl (or CO_ESC), the call site whose
        // arguments a need of the target checks (CO_NO_SITE: none), and whether the entry is checked
        // (a call site, or a conformance reached through its interface method's call sites).
        let mut r_decl = Vector::<u32>::new();
        let mut r_tgt = Vector::<u32>::new();
        let mut r_site = Vector::<u64>::new();
        let mut r_chk = Vector::<u8>::new();
        let mut seeds = Vector::<u32>::new();
        let mut seed_esc = false;
        let mut opn = Vector::<u32>::new(); // per-module scratch: the operator nodes with a method
        // The interface and conformance methods, by name: an operator dispatched at emission reaches
        // the interface methods of its method's name.
        let mut ifm = Vector::<u64>::new(); // name hash << 32 | index into `defs`
        let mut imp = Vector::<u64>::new();
        let mut defs = Vector::<u64>::new(); // module << 32 | node
        self.co_dispatch(&mut ifm, &mut imp, &mut defs);
        // `ifm` sorted: the methods of one name are one run, in `ifm` order (the index ascends).
        let mut ifs = ifm.clone();
        ifs.sort();
        for m in 0..nm {
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            let src = self.modules.at(m).source.as_str();
            let spar = g.stdm[m] == 2;
            let ix0 = g.ix_start[m];
            let mut hint = CO_NONE; // the previous site's decl
            for si in site_start[m]..site_start[m + 1] {
                let ni = sites[si as usize];
                if site_named[si as usize] == 1 {
                    // Most of these sites are callees: test that before reading the node.
                    let ck = ix0 + a.dense(ni);
                    if (callee[ck / 64] >> (ck % 64) as u64 & 1u64) != 0 {
                        continue;
                    }
                }
                let n = a.at_const(ni);
                if site_named[si as usize] == 2 {
                    // A recorded operator method is a record of the operator loop below.
                    if a.op_method.get(&ni).is_some() {
                        continue;
                    }
                    let d = g.decl_near(m, n.span, hint);
                    hint = d;
                    if d == CO_NONE {
                        continue;
                    }
                    let h = agg_op_name(a, n).hash() & 0xFFFFFFFFu64;
                    // The first entry of the name's run.
                    let mut lo: usize = 0;
                    let mut hi = ifs.len();
                    while lo < hi {
                        let mid = lo + (hi - lo) / 2;
                        if ifs[mid] >> 32 < h {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    for i in lo..ifs.len() {
                        if ifs[i] >> 32 != h {
                            break;
                        }
                        let dm = defs[(ifs[i] & 0xFFFFFFFFu64) as usize];
                        let md = g.decl_of((dm >> 32) as ModuleId, (dm & 0xFFFFFFFFu64) as NodeId);
                        if md != CO_NONE {
                            r_decl.push(d);
                            r_tgt.push(md);
                            r_site.push(CO_NO_SITE);
                            r_chk.push(0);
                        }
                    }
                    continue;
                }
                let nk = n.kind;
                if nk == NodeKind::NODE_CALL {
                    let d = g.decl_near(m, n.span, hint);
                    hint = d;
                    let cd = n.as_data.call;
                    let mut t = pin_callee(a, ni, cd.callee);
                    if t.node != NODE_NONE && g.decl_of(t.module, t.node) == CO_NONE {
                        let tk = unsafe (&*self.module_ast_const(t.module)).at_const(t.node).kind;
                        if tk == NodeKind::NODE_STRUCT || tk == NodeKind::NODE_ENUM || tk == NodeKind::NODE_VARIANT || tk == NodeKind::NODE_TYPE_ALIAS {
                            // Ctor/variant/type call: no body to run.
                            continue;
                        }
                        // Pinned to the field or binding that holds the callee: a fn value.
                        t = DefId { module: 0, node: NODE_NONE };
                    }
                    if t.node == NODE_NONE {
                        if a.is_free_call(ni, src) {
                            // An explicit drop: every conformance `free` is marked with the seeds.
                            continue;
                        }
                        if d == CO_NONE {
                            continue;
                        }
                        let cn = named_node(a, cd.callee);
                        if a.at_const(cn).kind == NodeKind::NODE_IDENTIFIER && a.resolution_def(cn).node == NODE_NONE {
                            // A compiler intrinsic (`type_info`, `zeroed`, ..): a fn value is bound.
                            continue;
                        }
                        // A call to the decl's own parameter: a need of a function, checked at its
                        // call sites. A closure's call sites are fn-value calls nothing pins.
                        let pr = a.resolution_def(cd.callee);
                        if g.closure[d as usize] == 0 && pr.node != NODE_NONE && pr.module == m as ModuleId && a.at_const(
                            pr.node,
                        ).kind == NodeKind::NODE_PARAMETER {
                            let pi = param_index(a, g.node[d as usize], pr.node);
                            if pi >= 0 && pi < 64 {
                                g.need.set(d as usize, g.need[d as usize] | 1u64 << pi as u64);
                                continue;
                            }
                        }
                        if spar {
                            continue;
                        }
                        r_decl.push(d);
                        r_tgt.push(CO_ESC);
                        r_site.push(CO_NO_SITE);
                        r_chk.push(0);
                        continue;
                    }
                    let td = g.decl_of(t.module, t.node);
                    // Every entry API lives in std::parallel.
                    if !spar && g.stdm[t.module as usize] == 2 {
                        let tk = t.module as u64 << 32 | t.node as u64;
                        for e in 0..ent.len() {
                            if ent[e] != tk {
                                continue;
                            }
                            let arg = site_arg(a, ni, ent_p[e]);
                            let an = if arg != NODE_NONE {
                                named_node(a, arg);
                            } else {
                                NODE_NONE;
                            };
                            let mut sd = CO_NONE;
                            if an != NODE_NONE && a.at_const(an).kind == NodeKind::NODE_CLOSURE {
                                sd = g.decl_of(m as ModuleId, an);
                            } else if an != NODE_NONE {
                                let fr = named_decl(a, an);
                                if fr.node != NODE_NONE {
                                    sd = g.decl_of(fr.module, fr.node);
                                }
                            }
                            if sd != CO_NONE {
                                seeds.push(sd);
                            } else {
                                // An entry the tracker cannot pin: any fn value may run.
                                seed_esc = true;
                            }
                        }
                    }
                    if d != CO_NONE {
                        r_decl.push(d);
                        r_tgt.push(td);
                        r_site.push(m as u64 << 32 | ni as u64);
                        r_chk.push(1);
                    }
                    continue;
                }
                let mut t = DefId { module: 0, node: NODE_NONE };
                if nk == NodeKind::NODE_FOR {
                    // The loop's `next`, when it iterates an iterator.
                    switch a.call_info.get(&ni) {
                        Some(v) => {
                            t = DefId { module: (*v >> 40) as ModuleId, node: (*v >> 8 & 0xFFFFFFFFu64) as NodeId };
                        },
                        _ => {},
                    };
                } else {
                    // A function named as a value (not called here) has a function type; a `?`
                    // conversion names one too.
                    // Not in callee position (tested above): a function, not the declaration's own name.
                    let r = a.resolution_def(ni);
                    if r.node != NODE_NONE {
                        let rd = g.decl_of(r.module, r.node);
                        if rd != CO_NONE && g.closure[rd as usize] == 0 && !(r.module == m as ModuleId && a.at_const(
                            r.node,
                        ).as_data.function.name == ni) {
                            t = r;
                            g.add_esc(rd);
                        }
                    }
                }
                if t.node == NODE_NONE {
                    continue;
                }
                let d = g.decl_near(m, n.span, hint);
                hint = d;
                let td = g.decl_of(t.module, t.node);
                if d != CO_NONE && td != CO_NONE {
                    r_decl.push(d);
                    r_tgt.push(td);
                    r_site.push(CO_NO_SITE);
                    r_chk.push(0);
                }
            }
            // An operator node calls the method the checker chose, in node order.
            if a.op_method.len() != 0 {
                opn.truncate(0);
                let mut ki = a.op_method.keys();
                loop {
                    switch ki.next() {
                        Some(k) => {
                            opn.push(*k);
                        },
                        _ => {
                            break;
                        },
                    };
                }
                opn.sort();
                for i in 0..opn.len() {
                    let v = *a.op_method.get(&opn[i]).unwrap();
                    let d = g.decl_at(m, a.at_const(opn[i]).span);
                    let td = g.decl_of((v >> 32) as ModuleId, (v & 0xFFFFFFFFu64) as NodeId);
                    if d != CO_NONE && td != CO_NONE {
                        r_decl.push(d);
                        r_tgt.push(td);
                        r_site.push(CO_NO_SITE);
                        r_chk.push(0);
                    }
                }
            }
            // A user `Deref` hop calls its method from the node that dereferences.
            for i in 0..a.deref_uses.len() {
                let du = a.deref_uses.at(i);
                let d = g.decl_at(m, a.at_const(du.node).span);
                if d == CO_NONE {
                    continue;
                }
                for s in 0..du.n {
                    let dm = unsafe du.method[s as usize];
                    if dm.node == NODE_NONE {
                        continue;
                    }
                    let td = g.decl_of(dm.module, dm.node);
                    if td != CO_NONE {
                        r_decl.push(d);
                        r_tgt.push(td);
                        r_site.push(CO_NO_SITE);
                        r_chk.push(0);
                    }
                }
            }
        }
        // Dispatch: an interface method reaches every conformance method of its name, a checked
        // entry (the method's call sites check the conformance's needs, merged below).
        let free_h = "free".hash() & 0xFFFFFFFFu64;
        let mut frees = Vector::<u32>::new();
        for i in 0..imp.len() {
            if imp[i] >> 32 == free_h {
                let df = defs[(imp[i] & 0xFFFFFFFFu64) as usize];
                let fd = g.decl_of((df >> 32) as ModuleId, (df & 0xFFFFFFFFu64) as NodeId);
                if fd != CO_NONE {
                    frees.push(fd);
                }
            }
        }
        let cha0 = r_decl.len();
        for i in 0..ifm.len() {
            let h = ifm[i] >> 32; // the name hash
            // The first conformance of this name: the sorted run starts at the lower bound.
            let mut l: usize = 0;
            let mut hi = imp.len();
            while l < hi {
                let mid = (l + hi) / 2;
                if imp[mid] >> 32 < h {
                    l = mid + 1;
                } else {
                    hi = mid;
                }
            }
            let dm = defs[(ifm[i] & 0xFFFFFFFFu64) as usize];
            let md = g.decl_of((dm >> 32) as ModuleId, (dm & 0xFFFFFFFFu64) as NodeId);
            while l < imp.len() && imp[l] >> 32 == h {
                let di = defs[(imp[l] & 0xFFFFFFFFu64) as usize];
                let id = g.decl_of((di >> 32) as ModuleId, (di & 0xFFFFFFFFu64) as NodeId);
                if md != CO_NONE && id != CO_NONE {
                    r_decl.push(md);
                    r_tgt.push(id);
                    r_site.push(CO_NO_SITE);
                    r_chk.push(1);
                }
                l += 1;
            }
        }
        // A fn value handed to std::parallel may run on a coroutine later: a parameter of the caller
        // handed on is a need of the caller. These bits depend on no other need.
        for i in 0..cha0 {
            let t = r_tgt[i];
            if t == CO_ESC || r_site[i] == CO_NO_SITE {
                continue;
            }
            let d = r_decl[i];
            if g.closure[d as usize] != 0 || g.stdm[g.module_of(t)] != 2 || g.stdm[g.module_of(d)] == 2 {
                continue;
            }
            let sm = (r_site[i] >> 32) as ModuleId;
            let a = unsafe &*self.module_ast_const(sm);
            let args = a.at_const((r_site[i] & 0xFFFFFFFFu64) as NodeId).as_data.call.args;
            for j in 0..args.len {
                let arg = unsafe a.list(args)[j as usize];
                if !fn_valued(a, arg) {
                    continue;
                }
                let pr = a.resolution_def(named_node(a, arg));
                if pr.node == NODE_NONE || pr.module != sm || a.at_const(pr.node).kind != NodeKind::NODE_PARAMETER {
                    continue;
                }
                let q = param_index(a, g.node[d as usize], pr.node);
                if q >= 0 && q < 64 {
                    g.need.set(d as usize, g.need[d as usize] | 1u64 << q as u64);
                }
            }
        }
        // Records by target (counting sort): a need and a user-reach level flow from a record's
        // target to its decl.
        let nr = r_decl.len();
        let mut t_start = Vector::<u32>::new();
        t_start.resize_default(nd + 1);
        for i in 0..nr {
            let t = r_tgt[i];
            if t != CO_ESC {
                t_start.set(t as usize + 1, t_start[t as usize + 1] + 1);
            }
        }
        for d in 0..nd {
            t_start.set(d + 1, t_start[d + 1] + t_start[d]);
        }
        let mut t_ix = Vector::<u32>::new();
        t_ix.resize_default(t_start[nd] as usize);
        let mut cur = Vector::<u32>::new();
        for d in 0..nd {
            cur.push(t_start[d]);
        }
        for i in 0..nr {
            let t = r_tgt[i];
            if t != CO_ESC {
                t_ix.set(cur[t as usize] as usize, i as u32);
                cur.set(t as usize, cur[t as usize] + 1);
            }
        }
        // Needs, by a worklist over decls: a site that passes its own function's parameter for a need
        // makes that parameter a need; an interface method's call sites check its conformances'
        // needs. A decl enters the list once, then again only when it gains a bit.
        let mut wq = Vector::<u32>::new();
        let mut inq = Vector::<u8>::new();
        inq.resize_default(nd);
        for d in 0..nd {
            if g.need[d] != 0 {
                wq.push(d as u32);
                inq.set(d, 1);
            }
        }
        let mut wi: usize = 0;
        while wi < wq.len() {
            assert(wq.len() <= nd * 65, "a decl re-enters the need list only when it gains a bit");
            let t = wq[wi] as usize;
            wi += 1;
            inq.set(t, 0);
            for k in t_start[t]..t_start[t + 1] {
                let i = t_ix[k as usize] as usize;
                let d = r_decl[i] as usize;
                let old = g.need[d];
                if i >= cha0 {
                    g.need.set(d, old | g.need[t]);
                } else if r_site[i] != CO_NO_SITE && g.closure[d] == 0 {
                    let sm = (r_site[i] >> 32) as ModuleId;
                    let a = unsafe &*self.module_ast_const(sm);
                    for p in 0..64u32 {
                        if (g.need[t] >> p as u64 & 1u64) == 0 {
                            continue;
                        }
                        let arg = site_arg(a, (r_site[i] & 0xFFFFFFFFu64) as NodeId, p);
                        if arg == NODE_NONE {
                            continue;
                        }
                        let pr = a.resolution_def(named_node(a, arg));
                        if pr.node == NODE_NONE || pr.module != sm || a.at_const(pr.node).kind != NodeKind::NODE_PARAMETER {
                            continue;
                        }
                        let q = param_index(a, g.node[d], pr.node);
                        if q >= 0 && q < 64 {
                            g.need.set(d, g.need[d] | 1u64 << q as u64);
                        }
                    }
                }
                if g.need[d] != old && inq[d] == 0 {
                    wq.push(d as u32);
                    inq.set(d, 1);
                }
            }
        }
        // A std body can run user code when it calls a fn value or a `dyn` method (always), dispatches
        // through a bound (only in instances binding a type whose methods can be user code), or calls
        // such a std body; any other std loop is bounded by its inputs and gets no tick.
        let mut iface = Vector::<u8>::new();
        iface.resize_default(nd);
        for i in 0..ifm.len() {
            let dm = defs[(ifm[i] & 0xFFFFFFFFu64) as usize];
            let md = g.decl_of((dm >> 32) as ModuleId, (dm & 0xFFFFFFFFu64) as NodeId);
            if md != CO_NONE {
                iface.set(md as usize, 1);
            }
        }
        let mut r_std = Vector::<u8>::new(); // per record below `cha0`: its decl is std code
        r_std.resize_default(cha0);
        for i in 0..cha0 {
            let d = r_decl[i];
            if g.stdm[g.module_of(d)] == 0 {
                continue;
            }
            r_std.set(i, 1);
            let t = r_tgt[i];
            let mut u: u8 = 0;
            if t == CO_ESC {
                u = 2;
            } else if iface[t as usize] != 0 {
                u = 1;
                if r_site[i] != CO_NO_SITE && dyn_receiver(
                    unsafe &*self.module_ast_const((r_site[i] >> 32) as ModuleId),
                    (r_site[i] & 0xFFFFFFFFu64) as NodeId,
                ) {
                    u = 2;
                }
            }
            if u > g.ureach[d as usize] {
                g.ureach.set(d as usize, u);
            }
        }
        for d in 0..nd {
            if g.need[d] != 0 {
                g.ureach.set(d, 2);
            }
        }
        // The levels, by a worklist over decls: a decl enters the list once, then again only when its
        // level rises.
        wq.truncate(0);
        wi = 0;
        for d in 0..nd {
            if g.ureach[d] != 0 {
                wq.push(d as u32);
                inq.set(d, 1);
            }
        }
        while wi < wq.len() {
            assert(wq.len() <= nd * 3, "a decl re-enters the user-reach list only when its level rises");
            let t = wq[wi] as usize;
            wi += 1;
            inq.set(t, 0);
            for k in t_start[t]..t_start[t + 1] {
                let i = t_ix[k as usize] as usize;
                let d = r_decl[i] as usize;
                if i < cha0 && r_std[i] != 0 && g.ureach[t] > g.ureach[d] {
                    g.ureach.set(d, g.ureach[t]);
                    if inq[d] == 0 {
                        wq.push(d as u32);
                        inq.set(d, 1);
                    }
                }
            }
        }
        // Records by decl (counting sort).
        let mut r_start = Vector::<u32>::new();
        r_start.resize_default(nd + 1);
        for i in 0..nr {
            let d = r_decl[i] as usize;
            r_start.set(d + 1, r_start[d + 1] + 1);
        }
        for d in 0..nd {
            r_start.set(d + 1, r_start[d + 1] + r_start[d]);
        }
        let mut r_ix = Vector::<u32>::new();
        r_ix.resize_default(nr);
        cur.truncate(0);
        for d in 0..nd {
            cur.push(r_start[d]);
        }
        for i in 0..nr {
            let d = r_decl[i] as usize;
            r_ix.set(cur[d] as usize, i as u32);
            cur.set(d, cur[d] + 1);
        }
        // The closure: a marked decl turns itself and every decl inside it on; an on decl fires its
        // records once. Every decl turns on at most once.
        if seeds.len() != 0 || seed_esc {
            for i in 0..frees.len() {
                g.mark(frees[i]);
            }
        }
        for si in 0..seeds.len() {
            if g.need[seeds[si] as usize] != 0 {
                g.escape(); // an entry's parameters come from no checked site
            }
            g.mark(seeds[si]);
        }
        if seed_esc {
            g.escape();
        }
        let mut qi: usize = 0;
        while qi < g.queue.len() {
            let d = g.queue[qi] as usize;
            qi += 1;
            // Everything declared inside `d` runs inside its span: the run of the module's
            // decls after `d` whose starts fall below its end (spans nest).
            let dend = (g.span[d] & 0xFFFFFFFFu64) as u32;
            let mut k = d + 1;
            while k < g.lim[d] as usize && (g.span[k] >> 32) as u32 < dend {
                if g.on[k] == 0 {
                    g.on.set(k, 1);
                    g.queue.push(k as u32);
                }
                k += 1;
            }
            for ri in r_start[d]..r_start[d + 1] {
                let i = r_ix[ri as usize] as usize;
                let t = r_tgt[i];
                if t == CO_ESC {
                    g.escape();
                    continue;
                }
                if g.need[t as usize] != 0 && !g.escaped {
                    if r_chk[i] == 0 {
                        g.escape(); // entered other than through a call site that checks its needs
                    } else if r_site[i] != CO_NO_SITE && !self.co_site_ok(&g, r_site[i], d as u32, g.need[t as usize]) {
                        g.escape();
                    }
                }
                if !g.escaped && r_site[i] != CO_NO_SITE && g.stdm[g.module_of(t)] == 2 && !self.co_parallel_args_ok(
                    &g,
                    r_site[i],
                    d as u32,
                ) {
                    // A fn value std::parallel stores and runs later that the tracker cannot pin.
                    g.escape();
                }
                g.mark(t);
            }
        }
        // The fn values, for the cancellation analysis (see `cancel_compute`). A closure written as a
        // coroutine entry is consumed by its spawn call: nothing calls it as a fn value.
        let mut seeded = Vector::<u8>::new();
        seeded.resize_default(nd);
        for si in 0..seeds.len() {
            seeded.set(seeds[si] as usize, 1);
        }
        for i in 0..g.esc.len() {
            let e = g.esc[i];
            if g.closure[e as usize] == 0 || seeded[e as usize] == 0 {
                self.co_fnv.push(g.module_of(e) as u64 << 32 | g.node[e as usize] as u64);
            }
        }
        self.co_spans = replace(&mut g.spans, Vector::<Vector<u64>>::new());
        self.co_inst = replace(&mut g.inst, Vector::<Vector<u64>>::new());
    }

    // Resolve the coroutine entry APIs (`CO_ENTRY_*`) that are loaded: (module << 32 | node) and the
    // entry parameter index of each.
    fn co_entries(self: &Self, out: &mut Vector<u64>, par: &mut Vector<u32>) {
        for e in 0..CO_ENTRY_N {
            let mi = self.find(unsafe CO_ENTRY_MOD[e]);
            if mi < 0 {
                continue;
            }
            let mid = mi as ModuleId;
            if unsafe CO_ENTRY_TYPE[e].len() == 0 {
                let h = self.glob_lookup(mid, unsafe CO_ENTRY_FN[e], false);
                if h.node != NODE_NONE && h.mid == mid {
                    out.push(mid as u64 << 32 | h.node as u64);
                    par.push(unsafe CO_ENTRY_PARAM[e]);
                }
                continue;
            }
            let ty = self.glob_lookup(mid, unsafe CO_ENTRY_TYPE[e], true);
            if ty.node == NODE_NONE || ty.mid != mid {
                continue;
            }
            let a = unsafe &*self.module_ast_const(mid);
            let src = self.modules.at(mid as usize).source.as_str();
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let it = unsafe a.list(items)[i as usize];
                let n = a.at_const(it);
                if n.kind != NodeKind::NODE_EXTEND || n.as_data.extend_def.interface_type != NODE_NONE {
                    continue;
                }
                let tr = a.resolution_def(n.as_data.extend_def.target_type);
                if tr.node != ty.node || tr.module != mid {
                    continue;
                }
                let ms = n.as_data.extend_def.items;
                for j in 0..ms.len {
                    let f = unsafe a.list(ms)[j as usize];
                    if a.at_const(f).kind == NodeKind::NODE_FUNCTION && fn_name(a, src, f) == unsafe CO_ENTRY_FN[e] {
                        out.push(mid as u64 << 32 | f as u64);
                        par.push(unsafe CO_ENTRY_PARAM[e]);
                    }
                }
            }
        }
    }

    // Collect the interface methods (`ifm`) and the conformance methods (`imp`, sorted) of every
    // module as (name hash << 32 | index into `defs`, which holds module << 32 | node), the hash cut
    // to 32 bits: a collision only adds an edge.
    fn co_dispatch(self: &Self, ifm: &mut Vector<u64>, imp: &mut Vector<u64>, defs: &mut Vector<u64>) {
        for m in 0..self.modules.len() {
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            let src = self.modules.at(m).source.as_str();
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let n = a.at_const(unsafe a.list(items)[i as usize]);
                let mut ms = NodeList {};
                let mut conf = false;
                if n.kind == NodeKind::NODE_INTERFACE {
                    ms = n.as_data.interface_def.items;
                } else if n.kind == NodeKind::NODE_EXTEND && n.as_data.extend_def.interface_type != NODE_NONE {
                    ms = n.as_data.extend_def.items;
                    conf = true;
                } else {
                    continue;
                }
                for j in 0..ms.len {
                    let f = unsafe a.list(ms)[j as usize];
                    if a.at_const(f).kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let e = (fn_name(a, src, f).hash() & 0xFFFFFFFFu64) << 32 | defs.len() as u64;
                    defs.push(m as u64 << 32 | f as u64);
                    if conf {
                        imp.push(e);
                    } else {
                        ifm.push(e);
                    }
                }
            }
        }
        imp.sort();
    }

    // Does call site `site` (module << 32 | call node) in decl `d`, calling into std::parallel, pass as
    // each argument that can hold a fn value a closure, a named function, or a parameter of function
    // `d` (a need of `d` by the fixpoint)? A site inside std::parallel is its own dispatch: always yes.
    fn co_parallel_args_ok(self: &Self, g: &CoGraph, site: u64, d: u32) bool {
        let sm = (site >> 32) as ModuleId;
        if g.stdm[sm as usize] == 2 {
            return true;
        }
        let a = unsafe &*self.module_ast_const(sm);
        let args = a.at_const((site & 0xFFFFFFFFu64) as NodeId).as_data.call.args;
        for j in 0..args.len {
            let arg = unsafe a.list(args)[j as usize];
            if !fn_valued(a, arg) {
                continue;
            }
            let an = named_node(a, arg);
            if a.at_const(an).kind == NodeKind::NODE_CLOSURE {
                continue; // declared inside `d`: on with it
            }
            let r = named_decl(a, an);
            if r.node == NODE_NONE {
                return false;
            }
            let rk = unsafe (&*self.module_ast_const(r.module)).at_const(r.node).kind;
            if rk == NodeKind::NODE_FUNCTION {
                continue; // named as a value inside `d`: marked by its own record
            }
            if rk == NodeKind::NODE_PARAMETER && r.module == sm && g.closure[d as usize] == 0 && param_index(
                a,
                g.node[d as usize],
                r.node,
            ) >= 0 {
                continue;
            }
            return false;
        }
        return true;
    }

    // Does call site `site` (module << 32 | call node) in function decl `d` pass, for every parameter
    // in `need`, a closure, a named function, or a parameter of `d` (a need of `d` by the fixpoint)?
    // A site inside std::parallel is its own dispatch: always yes.
    fn co_site_ok(self: &Self, g: &CoGraph, site: u64, d: u32, need: u64) bool {
        let sm = (site >> 32) as ModuleId;
        if g.stdm[sm as usize] == 2 {
            return true;
        }
        let a = unsafe &*self.module_ast_const(sm);
        for p in 0..64u32 {
            if (need >> p as u64 & 1u64) == 0 {
                continue;
            }
            let arg = site_arg(a, (site & 0xFFFFFFFFu64) as NodeId, p);
            if arg == NODE_NONE {
                continue;
            }
            let an = named_node(a, arg);
            if a.at_const(an).kind == NodeKind::NODE_CLOSURE {
                continue; // declared inside `d`: on with it
            }
            let r = named_decl(a, an);
            if r.node == NODE_NONE {
                return false;
            }
            let rk = unsafe (&*self.module_ast_const(r.module)).at_const(r.node).kind;
            if rk == NodeKind::NODE_FUNCTION {
                continue; // named as a value inside `d`: marked by its own record
            }
            if rk == NodeKind::NODE_PARAMETER && r.module == sm && g.closure[d as usize] == 0 && param_index(
                a,
                g.node[d as usize],
                r.node,
            ) >= 0 {
                continue;
            }
            return false;
        }
        return true;
    }

    /// Can the function or closure declared exactly at `sp` reach the runtime's cancellation
    /// acceptance? False whenever the pass has not run (no coroutine runtime loaded): no
    /// cancellation checks. Exact-span membership: the queried span is always a decl's own span.
    pub fn cancel_on(self: &Self, m: ModuleId, sp: tok::Span) bool {
        if self.cancel_state != 1 {
            return false;
        }
        if m as usize >= self.cancel_marks.len() {
            return false;
        }
        return self.cancel_marks.at(m as usize).contains(&(sp.start as u64 << 32 | sp.end as u64));
    }

    /// Compute cancel_marks: the decl spans of every function and closure whose body can reach
    /// `runtime::cancel_accept`. Seeded at direct calls to the acceptance leaf, then closed upward:
    /// a call to a marked callee (a `for` loop's `next` included) marks the decls enclosing the call
    /// site, and a marked conformance method marks the interface methods of its name, whose call
    /// sites a bound or `dyn` dispatch pins. A call to a fn value nothing pins marks nothing: when
    /// some fn value of `co_fnv` is marked (`cancel_fnv`), every such call carries its own check.
    pub fn cancel_compute(self: &mut Self) {
        self.cancel_state = 1;
        self.cancel_fnv = false;
        self.cancel_marks.truncate(0);
        self.cancel_marks.resize_default(self.modules.len());
        let rt = self.find("std::parallel::runtime");
        if rt < 0 {
            // No coroutine runtime loaded: nothing can accept a cancellation.
            return;
        }
        let acc = self.glob_lookup(rt as ModuleId, "cancel_accept", false);
        if acc.node == NODE_NONE {
            return;
        }
        let req = self.glob_lookup(rt as ModuleId, "request_cancel", false);
        let tsh = self.glob_lookup(rt as ModuleId, "try_shutdown", false);
        let task_mid = self.find("std::parallel::task");
        // The enclosing-decl index: per module, the span of every function and closure, so marking
        // a call site's owners is a scan of decls rather than of every node.
        let mut decls = Vector::<Vector<u64>>::new();
        // Pinned calls, collected in ONE pass over each module's nodes: the fixpoint below then
        // iterates only these records, never the full node arrays again.
        let mut rec_m = Vector::<u32>::new();
        let mut rec_span = Vector::<u64>::new();
        let mut rec_t = Vector::<u64>::new();
        let mut opn = Vector::<u32>::new(); // per-module scratch: the operator nodes with a method
        for m in 0..self.modules.len() {
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            let mut row = Vector::<u64>::new();
            let nb9 = a.nodes.len();
            let nn9 = a.nnodes();
            for k in 0..nn9 {
                let ni = Ast::nth_id_n(nb9, k);
                let n = a.at_const(ni);
                if n.kind == NodeKind::NODE_FUNCTION || n.kind == NodeKind::NODE_CLOSURE {
                    row.push(n.span.start as u64 << 32 | n.span.end as u64);
                }
                if n.kind == NodeKind::NODE_FOR {
                    // The loop's `next`, when it iterates an iterator.
                    switch a.call_info.get(&ni) {
                        Some(v) => {
                            rec_m.push(m as u32);
                            rec_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                            rec_t.push(*v >> 40 << 32 | *v >> 8 & 0xFFFFFFFFu64);
                        },
                        _ => {},
                    };
                    continue;
                }
                if n.kind != NodeKind::NODE_CALL {
                    continue;
                }
                let cd = n.as_data.call;
                let t = pin_callee(a, ni, cd.callee);
                if t.node == NODE_NONE {
                    // A fn value: `cancel_fnv` covers it.
                    continue;
                }
                if !self.cancel_used && !self.modules.at(m).path.as_str().starts_with("std::") {
                    if task_mid >= 0 && t.module == task_mid as ModuleId {
                        self.cancel_used = true;
                    } else if t.module == acc.mid && (t.node == req.node || t.node == tsh.node) {
                        self.cancel_used = true;
                    }
                }
                if t.module != acc.mid || t.node != acc.node {
                    let ta = unsafe &*self.module_ast_const(t.module);
                    if ta.at_const(t.node).kind != NodeKind::NODE_FUNCTION {
                        // Ctor/variant/type call: no body to run.
                        continue;
                    }
                }
                rec_m.push(m as u32);
                rec_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                rec_t.push(t.module as u64 << 32 | t.node as u64);
            }
            // Implicit calls: an operator's method and a user `Deref` hop, from the node that makes them.
            if a.op_method.len() != 0 {
                opn.truncate(0);
                let mut ki = a.op_method.keys();
                loop {
                    switch ki.next() {
                        Some(k) => {
                            opn.push(*k);
                        },
                        _ => {
                            break;
                        },
                    };
                }
                opn.sort();
                for i in 0..opn.len() {
                    let osp = a.at_const(opn[i]).span;
                    rec_m.push(m as u32);
                    rec_span.push(osp.start as u64 << 32 | osp.end as u64);
                    rec_t.push(*a.op_method.get(&opn[i]).unwrap());
                }
            }
            for i in 0..a.deref_uses.len() {
                let du = a.deref_uses.at(i);
                let dsp = a.at_const(du.node).span;
                for s in 0..du.n {
                    let dm = unsafe du.method[s as usize];
                    if dm.node != NODE_NONE {
                        rec_m.push(m as u32);
                        rec_span.push(dsp.start as u64 << 32 | dsp.end as u64);
                        rec_t.push(dm.module as u64 << 32 | dm.node as u64);
                    }
                }
            }
            decls.push(row);
        }
        // Dispatch: a conformance method that reaches acceptance marks each interface method of its
        // name, as a call from that method's own span.
        {
            let mut ifm = Vector::<u64>::new();
            let mut imp = Vector::<u64>::new();
            let mut defs = Vector::<u64>::new();
            self.co_dispatch(&mut ifm, &mut imp, &mut defs);
            for i in 0..ifm.len() {
                let h = ifm[i] >> 32; // the name hash
                let dm = defs[(ifm[i] & 0xFFFFFFFFu64) as usize];
                let msp = unsafe (&*self.module_ast_const((dm >> 32) as ModuleId)).at_const(
                    (dm & 0xFFFFFFFFu64) as NodeId,
                ).span;
                let mut l: usize = 0;
                let mut hi = imp.len();
                while l < hi {
                    let mid = (l + hi) / 2;
                    if imp[mid] >> 32 < h {
                        l = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                while l < imp.len() && imp[l] >> 32 == h {
                    rec_m.push((dm >> 32) as u32);
                    rec_span.push(msp.start as u64 << 32 | msp.end as u64);
                    rec_t.push(defs[(imp[l] & 0xFFFFFFFFu64) as usize]);
                    l += 1;
                }
            }
        }
        // Fixpoint over the call records. A record fires at most once: firing marks its enclosing
        // decls, and only a fresh mark can make another record's target newly reach acceptance.
        let mut fired = Vector::<u8>::new();
        fired.resize_default(rec_m.len());
        let acck = acc.mid as u64 << 32 | acc.node as u64;
        let mut changed = true;
        while changed {
            changed = false;
            for i in 0..rec_m.len() {
                if fired[i] != 0 {
                    continue;
                }
                let tk = rec_t[i];
                if tk != acck {
                    let tm = (tk >> 32) as ModuleId;
                    let ta = unsafe &*self.module_ast_const(tm);
                    let tsp = ta.at_const((tk & 0xFFFFFFFFu64) as NodeId).span;
                    if !self.cancel_on(tm, tsp) {
                        continue;
                    }
                }
                fired.set(i, 1);
                let m = rec_m[i] as usize;
                let cs = (rec_span[i] >> 32) as u32;
                let ce = (rec_span[i] & 0xFFFFFFFFu64) as u32;
                let row = decls.at(m);
                for di in 0..row.len() {
                    let e = *row.at(di);
                    if (e >> 32) as u32 <= cs && ce <= (e & 0xFFFFFFFFu64) as u32 {
                        if !self.cancel_marks.at(m).contains(&e) {
                            self.cancel_marks.index_mut(m).insert(e);
                            changed = true;
                        }
                    }
                }
            }
        }
        for i in 0..self.co_fnv.len() {
            let e = self.co_fnv[i];
            let em = (e >> 32) as ModuleId;
            let esp = unsafe (&*self.module_ast_const(em)).at_const((e & 0xFFFFFFFFu64) as NodeId).span;
            if self.cancel_on(em, esp) {
                self.cancel_fnv = true;
                break;
            }
        }
    }

    /// Read-only view of module `mid`'s Ast for consumers outside the package (the Core IR lowerer). Asts
    /// live IN PLACE in the module table for their whole life: a stage mutates its module's Ast through a
    /// raw pointer into this slot, never by moving it out, so this read is always the live tree.
    pub const fn module_ast_const(self: &Self, mid: ModuleId) *const Ast {
        return &self.modules[mid as usize].ast;
    }

    /// Approximate owned bytes across the package's retained analyses (the LSP budget's accounting
    /// unit): per-module sources + arenas.
    pub const fn retained_bytes(self: &Self) usize {
        let mut b: usize = 0;
        for i in 0..self.modules.len() {
            let m = self.modules.at(i);
            b += m.source.capacity() + m.ast.retained_bytes();
        }
        for i in 0..self.def_refs.len() {
            b += self.def_refs.at(i).capacity() * 16;
        }
        return b;
    }

    /// The index record of declaration node `node` in module `m`, or ITEM_NONE when the node is
    /// not a top-level or associated declaration (`by_node` binary search over the module).
    pub const fn item_of(self: &Self, m: ModuleId, node: NodeId) ItemId {
        if !self.sched.built || m as usize + 1 >= self.idx.mod_items.len() {
            return ITEM_NONE;
        }
        let mut lo = self.idx.mod_items[m as usize] as usize;
        let mut hi = self.idx.mod_items[m as usize + 1] as usize;
        while lo < hi {
            let mid = (lo + hi) / 2;
            let it = self.sched.by_node[mid];
            let n = self.idx.items.at(it as usize).node;
            if n < node {
                lo = mid + 1;
            } else if n > node {
                hi = mid;
            } else {
                return it;
            }
        }
        return ITEM_NONE;
    }

    /// The readiness state of item `it` (acquire: the item's published writes are visible).
    pub fn item_state_at(self: &Self, it: ItemId) u8 {
        return unsafe atomic::load_u8(unsafe (self.sched.state.as_ptr() + it as usize), 1);
    }

    /// The readiness state of declaration `node` of module `m`; IS_PARSED for a node with no
    /// record (an unindexed declaration is never checked as an item).
    pub fn item_state(self: &Self, m: ModuleId, node: NodeId) u8 {
        let it = self.item_of(m, node);
        if it == ITEM_NONE {
            return IS_PARSED;
        }
        return self.item_state_at(it);
    }

    /// Move item `it` to state `st` (release: every write before the call is published with the
    /// state). Monotone: a lower state is a programmer error.
    pub fn set_item_state(self: &mut Self, it: ItemId, st: u8) {
        let cur = self.item_state_at(it);
        assert(st >= cur, "item readiness states only move up");
        unsafe atomic::store_u8(unsafe (self.sched.state.as_ptr() as *mut u8 + it as usize), st, 2);
    }

    /// Record the result-attributability verdict of function `node` of module `m` (`ItemSched.ret_attr`).
    pub fn set_item_ret_attr(self: &mut Self, m: ModuleId, node: NodeId, v: bool) {
        let it = self.item_of(m, node);
        if it == ITEM_NONE {
            return;
        }
        unsafe atomic::store_u8(
            unsafe (self.sched.ret_attr.as_ptr() as *mut u8 + it as usize),
            if v {
                1u8;
            } else {
                0u8;
            },
            2,
        );
    }

    /// The recorded verdict of function `node` of module `m`: 1 or 0, 2 while unrecorded, -1 when
    /// it is not an item.
    pub fn item_ret_attr(self: &Self, m: ModuleId, node: NodeId) i32 {
        let it = self.item_of(m, node);
        if it == ITEM_NONE {
            return 0 - 1;
        }
        return unsafe atomic::load_u8(unsafe (self.sched.ret_attr.as_ptr() + it as usize), 1);
    }

    /// Move item `it` and, for an extend, its member records (the records following it that name
    /// it as owner: a member is checked with its extend) to state `st`.
    pub fn set_item_state_deep(self: &mut Self, it: ItemId, st: u8) {
        self.set_item_state(it, st);
        let n = self.idx.items.len();
        for k in it as usize + 1..n {
            if self.idx.items.at(k).owner != it {
                break;
            }
            self.set_item_state(k as ItemId, st);
        }
    }

    /// Move every item of module `m` to `st` when it is below (a module-wide transition).
    pub fn set_module_states(self: &mut Self, m: usize, st: u8) {
        if !self.sched.built {
            return;
        }
        for it in self.idx.mod_items[m] as usize..self.idx.mod_items[m + 1] as usize {
            if self.item_state_at(it as ItemId) < st {
                self.set_item_state(it as ItemId, st);
            }
        }
    }

    /// The coordinator's re-analysis reset (the language server checks a module again): every
    /// item of module `m` returns to Resolved. Not a monotone transition; no reader runs meanwhile.
    pub fn reset_module_states(self: &mut Self, m: usize) {
        if !self.sched.built {
            return;
        }
        for it in self.idx.mod_items[m] as usize..self.idx.mod_items[m + 1] as usize {
            self.sched.state.set(it, IS_RESOLVED);
        }
    }

    /// Free every module's body arena: the checked release point of releasable body syntax, once
    /// the last consumer of it (the constant flush) has run. Every retained record a later stage
    /// reads (kept Core IR, closure and asm facts) was copied out before.
    pub fn release_bodies(self: &mut Self) {
        for i in 0..self.modules.len() {
            if self.modules[i].has_ast {
                self.modules[i].ast.release_bodies();
            }
        }
    }

    /// The enum declaring member `vd` (NODE_NONE when `vd` is no enum member) and `vd`'s position
    /// in it (-1 when none), from the package index.
    pub const fn variant_enum(self: &Self, vd: DefId, pos: &mut i64) NodeId {
        if let Some(v) = self.idx.variants.get(&skey_mix(0, vd.module as u64 << 32 | vd.node as u64)) {
            *pos = (*v & 0xFFFFFFFFu64) as i64;
            return (*v >> 32) as NodeId;
        }
        *pos = -1;
        return NODE_NONE;
    }

    /// Find a module by its `::`-joined path; returns its ModuleId, or -1 if absent.
    pub fn find(self: &Self, path: str) i32 {
        let mut m = switch self.mod_index.get(&path.hash()) {
            Some(h) => *h,
            None => SYM_NONE,
        };
        while m != SYM_NONE {
            if self.modules[m as usize].path.as_str() == path {
                return m as i32;
            }
            m = self.mod_chain[m as usize];
        }
        return -1;
    }

    // Add a module slot (taking ownership of `path`/`file`/`source`/`ast`) and return its id.
    fn add_module(self: &mut Self, path: String, file: String, source: String, ast: Ast, has_ast: bool) i32 {
        let id = self.modules.len() as i32;
        let h = path.as_str().hash();
        self.mod_chain.push(
            switch self.mod_index.get(&h) {
                Some(v) => *v,
                None => SYM_NONE,
            },
        );
        self.mod_index.insert(h, id as u32);
        self.modules.push(Module { path: path, file: file, source: source, ast: ast, has_ast: has_ast, prelude: false });
        // A module loaded after `bind_types` (an import resolved on demand) joins the package
        // identity at once: every module of a bound package interns into the one table.
        if has_ast && self.tt.deref().len() != 0 {
            self.modules[id as usize].ast.gt = self.tt.deref_mut();
        }
        return id;
    }

    // Overlay slot naming the same file as `path`: load paths are root-relative, overlay keys canonical
    // absolute, so `path` is realpath'd when possible (raw compare stays as the fallback for files not on
    // disk). -1 = none.
    fn overlay_index(self: &Self, path: str) i32 {
        if self.overlay_files.len() == 0 {
            return -1;
        }
        let mut key = path;
        let mut pb = RealBuf {};
        let mut rb = RealBuf {};
        let pl = path.len();
        if pl < 4096 {
            unsafe cstring::memcpy(&mut pb.b[0], path.ptr(), pl);
            unsafe pb.b[pl] = 0 as char;
            if unsafe shim::sc_realpath(&pb.b[0], &mut rb.b[0]) != null {
                key = str::from_cstr(&rb.b[0]);
            }
        }
        for i in 0..self.overlay_files.len() {
            let f = self.overlay_files.at(i).as_str();
            if f == key || f == path {
                return i as i32;
            }
        }
        return -1;
    }

    // Module `id`'s imports as a frame for the serial loader's stack. Collected before any import loads:
    // loading pushes to self.modules, which may realloc and move this module's by-value Ast.
    fn import_frame(self: &mut Self, id: i32, target: i32) LoadFrame {
        let mut dc = replace(&mut self.dir_cache, DirCache {});
        let mut f = LoadFrame { paths: Vector::<String>::new(), files: Vector::<String>::new(), next: 0 };
        let ap = (&self.modules.at(id as usize).ast) as *const Ast;
        let src = self.modules.at(id as usize).source.as_str();
        self.collect_imports(unsafe &*ap, src, &mut dc, target, &mut f.paths, &mut f.files);
        self.dir_cache = dc;
        return f;
    }

    // Every module `a` imports that is not loaded yet, as (module path, file path) pairs, plus the
    // dependencies a sugar keyword pulls in (`launch` -> the runtime, `select` -> the selector, `@blocking`
    // -> the pool). Skipping a loaded import saves resolve_import_file its filesystem probes: a hot std/ffi
    // module imported by many others would otherwise be probed once per importer. A path can still repeat;
    // load_module returns the existing id for a loaded path.
    //
    // `a`/`src` come in as raw views because the caller holds them inside `self.modules` and cannot lend them
    // across a `&mut self` call. `dc` is the package's dir cache, which the caller takes out of `self` for
    // the call.
    fn collect_imports(
        self: &Self,
        a: &Ast,
        src: str,
        dc: &mut DirCache,
        target: i32,
        child_paths: &mut Vector<String>,
        child_files: &mut Vector<String>,
    ) {
        let root_dir = self.root_dir.as_str();
        let alt_root = self.alt_root.as_str();
        let std_root = self.std_root.as_str();
        let items = a.at_const(a.root).as_data.program.items;
        let ids = a.list(items);
        for i in 0..items.len {
            let n = a.at_const(unsafe ids[i as usize]);
            if n.kind == NodeKind::NODE_IMPORT {
                // `@platform`-gated OUT for this target: the module is not loaded at all, so its file
                // need not exist here and nothing in it has to compile for a platform it disclaims.
                // An owner carries each attribute kind at most once, so one indexed lookup per gate.
                let id = unsafe ids[i as usize];
                let pl = a.attr_of(id, AttrKind::ATTR_PLATFORM);
                let ar = a.attr_of(id, AttrKind::ATTR_ARCH);
                let gated_out = pl != null && (unsafe (*pl).arg >> target as u32 & 1u32) == 0 || ar != null && self.arch >= 0 && (unsafe (*ar).arg >> self.arch as u32 & 1u32) == 0;
                if gated_out {
                    continue;
                }
                let parts = n.as_data.import_decl.path;
                let cp = join_parts(a, src, parts, "::");
                if self.find(cp.as_str()) >= 0 {
                    continue;
                }
                child_paths.push(cp);
                child_files.push(resolve_import_file(dc, root_dir, alt_root, std_root, a, src, parts));
            }
        }
        // Sugar-keyword dependency: the `launch` statement lowers to std::parallel::runtime::submit, so
        // pull that module in (transitively) ONLY when the keyword is used: a program that
        // never launches never loads the runtime. load_module returns the existing id for a loaded path, so a
        // duplicate push is harmless.
        if std_root.len() != 0 {
            let mut has_launch = false;
            let mut has_select = false;
            let mut has_parfor = false;
            let nb9 = a.nodes.len();
            let nn = a.nnodes();
            for ni in 0..nn {
                let k = a.at_const(Ast::nth_id_n(nb9, ni)).kind;
                if k == NodeKind::NODE_LAUNCH {
                    has_launch = true;
                } else if k == NodeKind::NODE_SELECT {
                    has_select = true;
                } else if k == NodeKind::NODE_PARALLEL_FOR {
                    has_parfor = true;
                }
                if has_launch && has_select && has_parfor {
                    break;
                }
            }
            if has_launch {
                let mut rf = String::from_str(std_root);
                rf.push_str("/std/parallel/runtime.spc");
                child_paths.push(String::from_str("std::parallel::runtime"));
                child_files.push(rf);
            }
            // Same for `select`, which lowers to std::parallel::selector's `sugar_*` shims.
            if has_select {
                let mut sf = String::from_str(std_root);
                sf.push_str("/std/parallel/selector.spc");
                child_paths.push(String::from_str("std::parallel::selector"));
                child_files.push(sf);
            }
            // Same for `parallel for`, which lowers to std::parallel::data's `range`.
            if has_parfor {
                let mut df = String::from_str(std_root);
                df.push_str("/std/parallel/data.spc");
                child_paths.push(String::from_str("std::parallel::data"));
                child_files.push(df);
            }
            // Same bargain for `@blocking`: a call to one of those functions is emitted as a wrapper
            // that hands the work to the blocking pool, so that module has to be linked in, but only
            // for a program that declares one.
            let mut has_blocking = false;
            for ai in 0..a.attrs.len() {
                if a.attrs[ai].kind == AttrKind::ATTR_BLOCKING as u8 {
                    has_blocking = true;
                    break;
                }
            }
            if has_blocking {
                let mut bf = String::from_str(std_root);
                bf.push_str("/std/parallel/blocking.spc");
                child_paths.push(String::from_str("std::parallel::blocking"));
                child_files.push(bf);
            }
        }
    }

    /// Load `file_path` as module `mod_path` with its whole import closure (parallel when load jobs
    /// are set and no overlays are active). Returns the module's id, or -1 when the root is unreadable.
    pub fn load_module(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        if unsafe G_LOAD_JOBS != 1 && self.overlay_files.len() == 0 {
            return self.load_module_par(mod_path, file_path, bootstrap_tags, target);
        }
        return self.load_module_serial(mod_path, file_path, bootstrap_tags, target);
    }

    // Speculative wave-parallel subtree load: parse tasks fan out per wave; the coordinator
    // resolves each finished unit's imports (dir-cache memo stays serial) and enqueues unseen
    // files; a serial DFS replay then assigns module ids exactly as the recursive loader would.
    // A unit that failed to read or parse falls back to the serial loader at replay, so its
    // diagnostics print with the serial wording, position and order.
    fn load_module_par(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        let existing = self.find(mod_path);
        if existing >= 0 {
            return existing;
        }
        // The replay's serial loads use the dir cache again: it is out of `self` until then.
        let mut dc = replace(&mut self.dir_cache, DirCache {});
        let mut units = Vector::<PUnit>::new();
        let mut heads = Map::<u64, u32>::new();
        punit_push(&mut units, &mut heads, mod_path, file_path);
        let mut next: usize = 0;
        while next < units.len() {
            let wave_end = units.len();
            if wave_end - next == 1 {
                // A one-unit wave (the root, every prelude file) parses inline: a task could overlap
                // with nothing and would start the worker pool for it.
                par_parse_one(PParse { u: units.index_mut(next), tags: bootstrap_tags });
            } else {
                let wg = psy::WaitGroup::new();
                wg.add((wave_end - next) as i64);
                for k in next..wave_end {
                    let t = PParse { u: units.index_mut(k), tags: bootstrap_tags };
                    let wgc = wg.clone();
                    launch || {
                        par_parse_one(t);
                        wgc.done();
                    };
                }
                wg.wait_masked();
            }
            for k in next..wave_end {
                if !units.at(k).ok {
                    continue;
                }
                let ap = (&units.at(k).ast) as *const Ast;
                let sp2 = units.at(k).source.as_str();
                let mut all_paths = Vector::<String>::new();
                let mut all_files = Vector::<String>::new();
                self.collect_imports(unsafe &*ap, sp2, &mut dc, target, &mut all_paths, &mut all_files);
                for c in 0..all_paths.len() {
                    let cp = all_paths[c].as_str();
                    if self.find(cp) >= 0 {
                        continue;
                    }
                    let seen = punit_find(&units, &heads, cp) < units.len();
                    units.index_mut(k).child_paths.push(String::from_str(cp));
                    units.index_mut(k).child_files.push(String::from_str(all_files[c].as_str()));
                    if !seen {
                        punit_push(&mut units, &mut heads, cp, all_files[c].as_str());
                    }
                }
            }
            next = wave_end;
        }
        self.dir_cache = dc;
        return self.par_replay(&mut units, &heads, bootstrap_tags, target);
    }

    // DFS in recorded import order over the parsed units: the id-assignment replay. Consumes
    // each unit's source/ast on first visit (later visits of the same path are find() hits).
    fn par_replay(self: &mut Self, units: &mut Vector<PUnit>, heads: &Map<u64, u32>, bootstrap_tags: bool, target: i32) i32 {
        let mut expand = false;
        let root = self.par_visit(units, 0, bootstrap_tags, target, &mut expand);
        // (unit << 32 | next import) pairs: an explicit stack, bounded by the unit count, so a long import
        // chain cannot exhaust the call stack.
        let mut stack = Vector::<u64>::new();
        if expand {
            stack.push(0u64);
        }
        while stack.len() != 0 {
            let top = stack.len() - 1;
            let ui = (stack[top] >> 32) as usize;
            let c = (stack[top] & 0xFFFFFFFFu64) as usize;
            if c == units.at(ui).child_paths.len() {
                let _ = stack.pop();
                continue;
            }
            stack.set(top, stack[top] + 1);
            let cp = units.at(ui).child_paths.at(c).as_str();
            // A visited unit gave its path away, so a loaded import is found here, not among the units.
            if self.find(cp) >= 0 {
                continue;
            }
            // The wave loop gave every recorded import its own unit.
            let ci = punit_find(units, heads, cp);
            assert(ci < units.len());
            let _ = self.par_visit(units, ci, bootstrap_tags, target, &mut expand);
            if expand {
                stack.push(ci as u64 << 32);
            }
        }
        return root;
    }

    // Give unit `ui` its module id: a loaded path keeps its id, a unit that failed to read or parse goes
    // through the serial loader (which prints its diagnostics and loads its imports), and a parsed unit
    // is added. `expand` reports the last case: its imports are the replay's to visit.
    fn par_visit(
        self: &mut Self,
        units: &mut Vector<PUnit>,
        ui: usize,
        bootstrap_tags: bool,
        target: i32,
        expand: &mut bool,
    ) i32 {
        *expand = false;
        let ex = self.find(units.at(ui).path.as_str());
        if ex >= 0 {
            return ex;
        }
        if !units.at(ui).ok {
            let pth = String::from_str(units.at(ui).path.as_str());
            let fl = String::from_str(units.at(ui).file.as_str());
            return self.load_module_serial(pth.as_str(), fl.as_str(), bootstrap_tags, target);
        }
        let u = units.index_mut(ui);
        let id = self.add_module(
            replace(&mut u.path, String::new()),
            replace(&mut u.file, String::new()),
            replace(&mut u.source, String::new()),
            replace(&mut u.ast, Ast::new(0)),
            true,
        );
        self.modules[id as usize].ast.module = id as ModuleId;
        *expand = true;
        return id;
    }

    // Load `mod_path` and its import closure depth-first. A module gets its id before its imports, which
    // load in declaration order; a module already loaded (an import cycle) keeps its id: modules are
    // parsed whole before any resolution, so mutual imports need no special handling. The stack is
    // explicit, bounded by the module count, so a long import chain cannot exhaust the call stack.
    fn load_module_serial(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        let existing = self.find(mod_path);
        if existing >= 0 {
            return existing;
        }
        let root = self.parse_module(mod_path, file_path, bootstrap_tags);
        if root < 0 || !self.modules[root as usize].has_ast {
            return root;
        }
        let mut stack = Vector::<LoadFrame>::new();
        stack.push(self.import_frame(root, target));
        while stack.len() != 0 {
            let top = stack.len() - 1;
            let k = stack.at(top).next;
            if k == stack.at(top).paths.len() {
                let _ = stack.pop();
                continue;
            }
            stack.index_mut(top).next = k + 1;
            let cp = replace(stack.index_mut(top).paths.index_mut(k), String::new());
            let cf = replace(stack.index_mut(top).files.index_mut(k), String::new());
            if self.find(cp.as_str()) >= 0 {
                continue;
            }
            if unsafe G_LOAD_JOBS != 1 && self.overlay_files.len() == 0 {
                // A unit the parallel replay handed back (it failed to parse): its imports return to the
                // parallel loader, as load_module routes them.
                let _ = self.load_module_par(cp.as_str(), cf.as_str(), bootstrap_tags, target);
                continue;
            }
            let id = self.parse_module(cp.as_str(), cf.as_str(), bootstrap_tags);
            if id >= 0 && self.modules[id as usize].has_ast {
                stack.push(self.import_frame(id, target));
            }
        }
        return root;
    }

    // Read, parse and add one module (not its imports). -1 when the file cannot be read; a module that
    // fails to parse is added without an Ast. Either failure clears `ok`.
    fn parse_module(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool) i32 {
        let mut source = String::new();
        let ovi = self.overlay_index(file_path);
        if ovi >= 0 {
            // Clone + pad exactly like read_file (the lexer relies on the read-ahead NUL sentinel).
            let t = self.overlay_texts.at(ovi as usize);
            let mut s = String::with_capacity(t.len() + lexer::SOURCE_PAD);
            s.push_str(t.as_str());
            s.pad_nul(lexer::SOURCE_PAD);
            source = s;
        } else {
            switch read_file(file_path) {
                Some(s) => {
                    source = s;
                },
                None => {
                    unsafe stdio::fprintf(
                        stdio::stderr(),
                        "error: cannot open module '%.*s' (%.*s)\n".ptr() as *const char,
                        mod_path.len() as i32,
                        mod_path.ptr(),
                        file_path.len() as i32,
                        file_path.ptr(),
                    );
                    self.ok = false;
                    return -1;
                },
            };
        }

        let mut tsc = replace(&mut self.tok_scratch, Vector::<tok::Token>::new());
        tsc.clear();
        let mut parsed = parse_source(&mut source, file_path, bootstrap_tags, tsc);
        self.tok_scratch = replace(&mut parsed.tokens, Vector::<tok::Token>::new());
        let ok = parsed.ok;
        let id = self.add_module(
            String::from_str(mod_path),
            String::from_str(file_path),
            source,
            replace(&mut parsed.ast, Ast::new(0)),
            ok,
        );
        if !ok {
            self.ok = false;
            return id;
        }
        self.modules[id as usize].ast.module = id as ModuleId;
        return id;
    }

    /// Inject one synthetic decl per builtin into the core prelude module, so builtins are nominal types
    /// that `extend i32 { .. }` can target. The decls live in the node pool only. Run after loading, before
    /// resolve.
    ///
    /// Identified by FILE, not by module path: the prelude normally loads it as `__std::core`, but an
    /// explicit `import std::core` loads the same file first under the user's own path and `load_prelude`
    /// then only flags it. Matching the path alone left the builtins un-seeded there, so every
    /// `extend i8 as Ord` in that very file failed its `Eq` superinterface.
    pub fn seed_core(self: &mut Self) {
        self.core_seeded = false;
        for i in 0..self.modules.len() {
            let is_core = self.modules[i].has_ast && self.modules[i].prelude && basename_of(
                self.modules[i].file.as_str(),
            ) == "core.spc";
            if is_core {
                for b in 0..BT_COUNT_N {
                    let id = self.modules[i].ast.add(
                        Node {
                            kind: NodeKind::NODE_STRUCT,
                            as_data: NodeAs { aggregate: AggregateData { name: NODE_NONE, is_public: true } },
                        },
                    );
                    unsafe self.builtin_decls[b] = id;
                }
                self.core_module = i as ModuleId;
                self.core_seeded = true;
                return;
            }
        }
    }

    /// The synthetic decl node anchoring builtin `b` in the core module, or NODE_NONE if builtins weren't seeded.
    pub const fn builtin_decl(self: &Self, b: BuiltinType) NodeId {
        if self.core_seeded && b as usize < BT_COUNT_N {
            return unsafe self.builtin_decls[b as usize];
        }
        return NODE_NONE;
    }

    /// If (module, node) names a builtin's synthetic core decl, its BuiltinType; else -1.
    pub fn builtin_of_decl(self: &Self, module: ModuleId, node: NodeId) i32 {
        if !self.core_seeded || module != self.core_module || node == NODE_NONE {
            return -1;
        }
        for b in 0..BT_COUNT_N {
            if unsafe self.builtin_decls[b] == node {
                return b as i32;
            }
        }
        return -1;
    }

    /// The type associated type `ai` (an interface's `type Name;`, arguments concrete types of pool
    /// `dm`: the projected type, then the interface's arguments) names: the `type Name = ..` of the
    /// conformance of `ai.args[0]` whose interface arguments are these (as the checker recorded them
    /// on its interface path), grounded under the parameters its target solves, into `out` (pool
    /// `dm`). False when no conformance applies. Emission (`Mangler::ground`) and compile-time
    /// evaluation resolve `T::Output` through it; the instance graph mirrors it on final ids.
    pub fn assoc_norm(self: &Self, dm: ModuleId, ai: &TyInstance, out: &mut TypeId, depth: u32) bool {
        if depth > 16 {
            return false;
        }
        let da = self.module_ast_const(dm) as *mut Ast;
        let y = *unsafe (*da).type_at(ai.args[0]);
        let mut it = TyInstance { module: y.module, decl: NODE_NONE, n: 0 };
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            it.decl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            it = *unsafe (*da).instance(y.as_data.inst);
        } else if y.kind == TypeKind::TYPE_BUILTIN {
            it.module = self.core_module;
            it.decl = self.builtin_decl(y.as_data.builtin);
        }
        let ia = self.module_ast_const(ai.module);
        let iface = iface_of_member(unsafe &*ia, ai.decl);
        if it.decl == NODE_NONE || iface == NODE_NONE {
            return false;
        }
        let want = unsafe (*da).intern_dyn(
            ai.module,
            iface,
            unsafe ((&ai.args[0]) as *const TypeId + 1),
            ai.n - 1,
            TypeQualifier::TYPE_QUAL_NONE as u8,
        );
        let an = unsafe (*ia).at_const(unsafe (*ia).at_const(ai.decl).as_data.type_alias.name).as_data.name.text;
        let aname = self.modules.at(ai.module as usize).source.as_str().slice(an.start as usize, an.end as usize);
        for xm in 0..self.modules.len() {
            if !self.modules.at(xm).has_ast {
                continue;
            }
            let em = xm as ModuleId;
            let ea = self.module_ast_const(em);
            let items = unsafe (*ea).at_const((*ea).root).as_data.program.items;
            for i in 0..items.len {
                let ext = unsafe (*ea).list(items)[i as usize];
                if unsafe (*ea).at_const(ext).kind != NodeKind::NODE_EXTEND {
                    continue;
                }
                let ed = unsafe (*ea).at_const(ext).as_data.extend_def;
                if ed.interface_type == NODE_NONE {
                    continue;
                }
                let ir = unsafe (*ea).resolution_def(ed.interface_type);
                let tg = unsafe (*ea).resolution_def(ed.target_type);
                let dt = unsafe (*ea).type_of(ed.interface_type);
                if ir.module != ai.module || ir.node != iface || tg.module != it.module || tg.node != it.decl || dt == TYPE_NONE {
                    continue;
                }
                let mut lp: [DefId; 8] = [[0] = DefId { module: 0, node: NODE_NONE }];
                let mut la: [TypeId; 8] = [[0] = TYPE_NONE];
                let mut ln: u32 = 0;
                if !self.ext_solve(em, ext, dm, &it, &mut lp[0], &mut la[0], &mut ln) {
                    continue;
                }
                let mut g = TYPE_NONE;
                if !self.ground_local(em, dt, dm, &lp[0], &la[0], ln, &mut g, depth + 1) || g != want {
                    continue;
                }
                for j in 0..ed.items.len {
                    let hid = unsafe (*ea).list(ed.items)[j as usize];
                    let hn = unsafe (*ea).at_const(hid);
                    if hn.kind != NodeKind::NODE_TYPE_ALIAS || hn.as_data.type_alias.ty == NODE_NONE {
                        continue;
                    }
                    let hs = unsafe (*ea).at_const(hn.as_data.type_alias.name).as_data.name.text;
                    if self.modules.at(xm).source.as_str().slice(hs.start as usize, hs.end as usize) != aname {
                        continue;
                    }
                    let at = unsafe (*ea).type_of(hn.as_data.type_alias.ty);
                    return at != TYPE_NONE && self.ground_local(em, at, dm, &lp[0], &la[0], ln, out, depth + 1);
                }
                return false;
            }
        }
        return false;
    }

    // The values extend `ext` (module `em`) gives its parameters for instance `it` of its target
    // (arguments concrete types of pool `dm`), as the bindings `lp[i]` -> `la[i]` (pool `dm`), `ln` of
    // them. False when the extend does not apply to the instance.
    fn ext_solve(
        self: &Self,
        em: ModuleId,
        ext: NodeId,
        dm: ModuleId,
        it: &TyInstance,
        lp: *mut DefId,
        la: *mut TypeId,
        ln: &mut u32,
    ) bool {
        let ea = self.module_ast_const(em);
        let da = self.module_ast_const(dm) as *mut Ast;
        let gens = unsafe (*ea).at_const(ext).as_data.extend_def.generics;
        if gens.len > 8 {
            return false;
        }
        *ln = gens.len;
        for i in 0..gens.len {
            unsafe lp[i as usize] = DefId { module: em, node: unsafe (*ea).list(gens)[i as usize] };
            unsafe la[i as usize] = TYPE_NONE;
        }
        let pat = unsafe (*ea).type_of(unsafe (*ea).at_const(ext).as_data.extend_def.target_type);
        if ext_is_identity(unsafe &*ea, pat, unsafe &*ea, em, ext) {
            for i in 0..gens.len {
                if i >= it.n as u32 {
                    return false;
                }
                unsafe la[i as usize] = unsafe it.args[i as usize];
            }
            return true;
        }
        let pi = *unsafe (*ea).instance(unsafe (*ea).type_at(pat).as_data.inst);
        let np = ext_arity(unsafe &*ea, ext, pi.n);
        if np > it.n {
            return false;
        }
        for j in 0..np {
            let pj = unsafe pi.args[j as usize];
            let aj = unsafe it.args[j as usize];
            let x = xarg_of(unsafe &*ea, pj, unsafe &*ea, em, gens);
            if x.kind == XA_FIXED {
                if unsafe (*da).reintern(unsafe &*ea, pj) != aj {
                    return false;
                }
                continue;
            }
            let mut v = TYPE_NONE;
            if x.kind == XA_PARAM {
                v = aj;
            } else if x.kind == XA_FORM {
                let ay = *unsafe (*da).type_at(aj);
                let bt = self.const_param_bt(em, unsafe (*ea).list(gens)[x.par as usize]);
                let mut q = i128::zero();
                if ay.kind != TypeKind::TYPE_CONST || !xarg_solve(
                    &x,
                    ay.cval(),
                    bt,
                    lay::target_for(self.arch).ptr == 4,
                    &mut q,
                ) {
                    return false;
                }
                v = unsafe (*da).const_value(cval_bits(q), bt);
            } else {
                return false;
            }
            let prev = unsafe la[x.par as usize];
            if prev != TYPE_NONE && prev != v {
                return false;
            }
            unsafe la[x.par as usize] = v;
        }
        for i in 0..gens.len {
            if unsafe la[i as usize] == TYPE_NONE {
                return false;
            }
        }
        return true;
    }

    /// `(pm, t)` with the parameters `lp[i]` bound to `la[i]` (`ln` of them, concrete types of pool
    /// `dm`), as a concrete type interned into pool `dm`; an associated type grounds through its
    /// conformance (`assoc_norm`). False when another parameter remains.
    pub fn ground_local(
        self: &Self,
        pm: ModuleId,
        t: TypeId,
        dm: ModuleId,
        lp: *const DefId,
        la: *const TypeId,
        ln: u32,
        out: &mut TypeId,
        depth: u32,
    ) bool {
        if depth > 16 || t == TYPE_NONE {
            return false;
        }
        let pa = self.module_ast_const(pm);
        let da = self.module_ast_const(dm) as *mut Ast;
        let y = *unsafe (*pa).type_at(t);
        if unsafe (*pa).type_concrete(t) {
            *out = unsafe (*da).reintern(unsafe &*pa, t);
            return true;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..ln {
                if unsafe lp[i as usize].module == y.module && unsafe lp[i as usize].node == y.as_data.decl {
                    *out = unsafe la[i as usize];
                    return true;
                }
            }
            return false;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let l = *unsafe (*pa).const_lin_at(y.as_data.inst);
            let mut dl = ConstLin::new(l.ty);
            dl.to = l.to;
            let ptr32 = lay::target_for(self.arch).ptr == 4;
            let mut v = i128::zero();
            if !lin_subst_form(unsafe &*da, &l, lp, la, ln as i32, &mut dl, ptr32, 0) || !dl.is_concrete() || !dl.finish(
                dl.k,
                ptr32,
                &mut v,
            ) {
                return false;
            }
            *out = unsafe (*da).const_value(cval_bits(v), dl.to);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let mut e = TYPE_NONE;
            if !self.ground_local(pm, y.as_data.elem, dm, lp, la, ln, &mut e, depth + 1) {
                return false;
            }
            if y.arr_sym() {
                let mut lt = TYPE_NONE;
                if !self.ground_local(pm, y.as_data.arr.len, dm, lp, la, ln, &mut lt, depth + 1) {
                    return false;
                }
                *out = unsafe (*da).intern_array(e, lt);
                return true;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            *out = unsafe (*da).intern_type(nt);
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE || y.kind == TypeKind::TYPE_ASSOC || y.kind == TypeKind::TYPE_DYN || y.fn_sig() {
            let mut it = *unsafe (*pa).instance(y.rec());
            if y.kind == TypeKind::TYPE_DYN && it.decl == NODE_NONE {
                return false;
            }
            for i in 0..it.n {
                let mut g = TYPE_NONE;
                if !self.ground_local(pm, unsafe it.args[i as usize], dm, lp, la, ln, &mut g, depth + 1) {
                    return false;
                }
                unsafe it.args[i as usize] = g;
            }
            if y.kind == TypeKind::TYPE_ASSOC {
                return self.assoc_norm(dm, &it, out, depth + 1);
            }
            *out = if y.fn_sig() {
                unsafe (*da).intern_sig_rec(&it, y.qualifier);
            } else if y.kind == TypeKind::TYPE_DYN {
                unsafe (*da).intern_dyn(it.module, it.decl, &it.args[0], it.n, y.qualifier);
            } else {
                unsafe (*da).intern_instance(it.module, it.decl, &it.args[0], it.n);
            };
            return true;
        }
        return false;
    }

    /// The integer type of const generic parameter `gp` of module `m`, from its declared type: the
    /// builtin it names (through type aliases), i32 for an enum (a value is its discriminant), and
    /// BT_COUNT for any other type.
    pub fn const_param_bt(self: &Self, m: ModuleId, gp: NodeId) BuiltinType {
        let mut tm = m;
        let mut a = self.module_ast_const(m);
        let mut tn = unsafe (*a).at_const(gp).as_data.generic_param.const_type;
        let mut hops: u32 = 0;
        while tn != NODE_NONE && hops < 8 {
            let d = unsafe (*a).resolution_def(tn);
            if d.node == NODE_NONE {
                // A builtin type name resolves to nothing: it is known by its spelling.
                let n = unsafe (*a).at_const(tn);
                let sp = if n.kind == NodeKind::NODE_TYPE_PATH && n.as_data.type_path.parts.len == 1 {
                    unsafe (*a).at_const(unsafe (*a).list(n.as_data.type_path.parts)[0]).as_data.name.text;
                } else if n.kind == NodeKind::NODE_IDENTIFIER {
                    n.as_data.name.text;
                } else {
                    break;
                };
                let b = bt_of_name(self.modules[tm as usize].source.as_str(), sp);
                if b >= 0 {
                    return b as BuiltinType;
                }
                break;
            }
            let b = self.builtin_of_decl(d.module, d.node);
            if b >= 0 {
                return b as BuiltinType;
            }
            tm = d.module;
            a = self.module_ast_const(d.module);
            let dn = unsafe (*a).at_const(d.node);
            if dn.kind == NodeKind::NODE_ENUM {
                return BuiltinType::BT_I32;
            }
            if dn.kind != NodeKind::NODE_TYPE_ALIAS {
                break;
            }
            tn = dn.as_data.type_alias.ty;
            hops += 1;
        }
        return BuiltinType::BT_COUNT;
    }

    /// The enum type node `tn` of module `m` names, through type aliases; node NODE_NONE for any
    /// other type.
    pub fn type_enum(self: &Self, m: ModuleId, tn: NodeId) DefId {
        let mut a = self.module_ast_const(m);
        let mut t = tn;
        let mut hops: u32 = 0;
        while t != NODE_NONE && hops < 8 {
            let d = unsafe (*a).resolution_def(t);
            if d.node == NODE_NONE {
                break;
            }
            a = self.module_ast_const(d.module);
            let dn = unsafe (*a).at_const(d.node);
            if dn.kind == NodeKind::NODE_ENUM {
                return d;
            }
            if dn.kind != NodeKind::NODE_TYPE_ALIAS {
                break;
            }
            t = dn.as_data.type_alias.ty;
            hops += 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    /// Record a method DefId as referenced, for demand-driven instance-method emission.
    pub fn mark_method_used(self: &mut Self, d: DefId) {
        if d.node == NODE_NONE {
            return;
        }
        let m = d.module as usize;
        while self.method_used.len() <= m {
            self.method_used.push(Vector::<bool>::new());
        }
        assert((d.node & NODE_BODY) == 0, "a method declaration is module syntax");
        if self.method_used[m].len() <= d.node as usize {
            // Size once to the module's node count so later marks are pure set()s.
            let mut n = unsafe (*self.module_ast_const(d.module)).nodes.len();
            if n <= d.node as usize {
                n = d.node as usize + 1;
            }
            let inner = &mut self.method_used[m];
            inner.reserve(n - inner.len());
            while inner.len() < n {
                inner.push(false);
            }
        }
        self.method_used[m].set(d.node as usize, true);
    }

    /// True when method `d` was marked used (demanded) by any module.
    pub const fn method_used_get(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE {
            return false;
        }
        let m = d.module as usize;
        if m >= self.method_used.len() {
            return false;
        }
        let inner = self.method_used.at(m);
        if d.node as usize >= inner.len() {
            return false;
        }
        return inner[d.node as usize];
    }

    // Cross-module name lookup.

    /// (Re)build the package declaration index: symbols, items, name maps, import adjacency, and
    /// SCCs, in deterministic module and source order. Called through ensure_index
    /// on first lookup after loading; a module appended later (the LSP's batch load) triggers a full
    /// rebuild. Declaration names, spans, and imports are parse-final, so the result stays valid for
    /// the whole pipeline.
    pub fn build_index(self: &mut Self) {
        let n = self.modules.len();
        let mut idx = PkgIndex {};
        idx.built_mods = n as u32;
        for m in 0..n {
            idx.mod_items.push(idx.items.len() as u32);
            idx.name_maps.push(Map::<u64, u32>::new());
            idx.mod_imports.push(idx.imports.len() as u32);
            idx.mod_exts.push(idx.exts.len() as u32);
            if self.modules[m].has_ast {
                self.index_module(&mut idx, m as ModuleId);
            }
        }
        idx.mod_items.push(idx.items.len() as u32);
        idx.mod_imports.push(idx.imports.len() as u32);
        idx.mod_exts.push(idx.exts.len() as u32);
        // Strongly connected components of the import graph (mutually importing modules share one),
        // numbered in completion order.
        let mut tgt = Vector::<u32>::with_capacity(idx.imports.len());
        for e in 0..idx.imports.len() {
            tgt.push(idx.imports[e]);
        }
        let _ = gitems::condense(n, &idx.mod_imports, &tgt, &mut idx.scc_of);
        // The prelude name map: every public top-level name of every prelude module, keyed by
        // (symbol, namespace), the first prelude module in module order winning (the order a walk
        // over the modules would answer in). prelude_lookup answers from it alone.
        for m in 0..n {
            if !self.modules[m].prelude {
                continue;
            }
            for it in idx.mod_items[m] as usize..idx.mod_items[m + 1] as usize {
                let im = idx.items.at(it);
                if im.owner != ITEM_NONE || !im.is_public || im.name == SYM_NONE {
                    continue;
                }
                let key = im.name as u64 * 2u64 + if im.is_type {
                    1u64;
                } else {
                    0u64;
                };
                if idx.pl_map.get(&key).is_none() {
                    idx.pl_map.insert(key, im.node as u64 << 32 | m as u64);
                }
            }
        }
        self.idx = idx;
        // Sugar-shim table: (module path, fn name) hooks, resolved through the finished index (find
        // and glob_lookup read self.idx). glob_lookup only warms closure caches; the index tables it
        // answers from are final above, so resolving after the swap sees exactly the built state.
        for si in 0..SI_COUNT_N {
            let mods: []str = SI_MODULES;
            let names: []str = SI_NAMES;
            let mut hit = LookupHit { node: NODE_NONE, mid: 0 };
            let m = self.find(mods[si]);
            if m >= 0 {
                hit = self.glob_lookup(m as ModuleId, names[si], false);
            }
            self.idx.sugar_items.push(hit);
        }
    }

    /// The resolved decl behind a sugar-lowering shim (NODE_NONE DefId when its module is not loaded).
    pub const fn sugar_item(self: &Self, k: SugarItem) DefId {
        let h = self.idx.sugar_items.at(k as usize);
        return DefId { module: h.mid, node: h.node };
    }

    /// Fill the function-signature metadata from the owners' typed facts: one ItemSig per indexed
    /// fn/method, its param and return TypeIds copied out of the owner's per-node type table. Runs
    /// once, after the whole package is type-checked (the driver calls it before instance planning);
    /// an index rebuild (a module appended later) clears the table, and the next call refills it.
    pub fn ensure_sigs(self: &mut Self) {
        self.ensure_index();
        if self.idx.sigs_built {
            return;
        }
        self.idx.sigs_built = true;
        for k in 0..self.idx.items.len() {
            let it = *self.idx.items.at(k);
            if it.kind != ItemKind::IK_FUNCTION as u8 && it.kind != ItemKind::IK_METHOD as u8 {
                continue;
            }
            let a = unsafe &*self.module_ast_const(it.module);
            // An unchecked module (or a node past its typed range) records nothing: the query
            // then answers null exactly where the typed facts hold no signature either.
            if !a.valid(it.node) || a.at_const(it.node).kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let fd = a.at_const(it.node).as_data.function;
            let start = self.idx.sig_types.len() as u32;
            for pi in 0..fd.params.len {
                self.idx.sig_types.push(a.type_of(unsafe a.list(fd.params)[pi as usize]));
            }
            for ri in 0..fd.returns.len {
                self.idx.sig_types.push(a.type_of(unsafe a.list(fd.returns)[ri as usize]));
            }
            self.idx.sig_of.insert(skey_mix(0, it.module as u64 << 32 | it.node as u64), self.idx.sigs.len() as u32);
            self.idx.sigs.push(
                ItemSig {
                    start: start,
                    np: fd.params.len as u16,
                    nr: fd.returns.len as u16,
                    generic: fd.generics.len != 0,
                },
            );
        }
    }

    /// The signature metadata for fn decl (m, node), or null when none is recorded.
    pub const fn item_sig(self: &Self, m: ModuleId, node: NodeId) *const ItemSig {
        if let Some(i) = self.idx.sig_of.get(&skey_mix(0, m as u64 << 32 | node as u64)) {
            return self.idx.sigs.at((*i) as usize);
        }
        return null;
    }

    /// Entry `i` of the signature type pool (see `sigs`).
    pub const fn sig_type(self: &Self, i: u32) TypeId {
        return self.idx.sig_types[i as usize];
    }

    /// Build the index if it does not cover the current module set (cheap check; see build_index).
    pub fn ensure_index(self: &mut Self) {
        if self.idx.built_mods as usize != self.modules.len() {
            self.build_index();
        }
    }

    // Record one named declaration: intern the name, append its ItemMeta, and (for top-level names
    // only, owner == ITEM_NONE) claim its (name, namespace, visibility) key first-occurrence-wins.
    // A function or const under an extend (`owner`) is a method or an associated const; a node of
    // any other kind records nothing.
    fn index_decl(self: &mut Self, idx: &mut PkgIndex, mid: ModuleId, srcp: *const char, node: NodeId, owner: ItemId) {
        let ast = unsafe &*self.module_ast_const(mid);
        let n = ast.at_const(node);
        let mut is_type = true;
        let mut is_public = false;
        let mut name_node = NODE_NONE;
        let mut kind = ItemKind::IK_STRUCT;
        switch n.kind {
            NODE_STRUCT | NODE_ENUM => {
                name_node = n.as_data.aggregate.name;
                is_public = n.as_data.aggregate.is_public;
                if n.kind == NodeKind::NODE_ENUM {
                    kind = ItemKind::IK_ENUM;
                }
            },
            NODE_TYPE_ALIAS => {
                name_node = n.as_data.type_alias.name;
                is_public = n.as_data.type_alias.is_public;
                kind = ItemKind::IK_TYPE_ALIAS;
            },
            NODE_INTERFACE => {
                name_node = n.as_data.interface_def.name;
                is_public = n.as_data.interface_def.is_public;
                kind = ItemKind::IK_INTERFACE;
            },
            NODE_FUNCTION => {
                name_node = n.as_data.function.name;
                is_public = n.as_data.function.is_public();
                is_type = false;
                kind = if owner == ITEM_NONE {
                    ItemKind::IK_FUNCTION;
                } else {
                    ItemKind::IK_METHOD;
                };
            },
            NODE_CONST => {
                name_node = n.as_data.const_def.name;
                is_public = n.as_data.const_def.is_public;
                is_type = false;
                kind = if owner == ITEM_NONE {
                    ItemKind::IK_CONST;
                } else {
                    ItemKind::IK_ASSOC_CONST;
                };
            },
            _ => {},
        };
        if name_node == NODE_NONE {
            return;
        }
        let sp = ast.at_const(name_node).as_data.name.text;
        let len = sp.end - sp.start;
        let np = (unsafe (srcp + sp.start as usize)) as *const u8;
        let sym = idx.syms.intern(str::from_raw(np, len as usize));
        let it = idx.items.len() as ItemId;
        idx.items.push(
            ItemMeta {
                module: mid,
                node: node,
                owner: owner,
                kind: kind as u8,
                name: sym,
                is_public: is_public,
                is_type: is_type,
                start: sp.start,
                len: len,
            },
        );
        if owner == ITEM_NONE {
            let key = sym as u64 * 4u64 + if is_type {
                2u64;
            } else {
                0u64;
            } + if is_public {
                1u64;
            } else {
                0u64;
            };
            let nm = &mut idx.name_maps[mid as usize];
            if nm.get(&key).is_none() {
                nm.insert(key, it);
            }
        }
    }

    // Collect module `mid`'s declarations, associated items, and resolved imports into `idx`.
    // Classification matches the pre-index lookup scan exactly (same kinds, same first-wins order);
    // extend bodies additionally contribute IK_EXTEND/IK_METHOD/IK_ASSOC_CONST records.
    fn index_module(self: &mut Self, idx: &mut PkgIndex, mid: ModuleId) {
        let m = mid as usize;
        // Srcp is raw (Copy) so no borrow of self lingers across the &mut self index_decl calls below;
        // `ast` comes from a raw ptr (not a tracked self-borrow), so reading it across them is fine.
        let srcp = self.modules[m].source.as_str().ptr() as *const char;
        let src = str::from_raw(srcp as *const u8, self.modules[m].source.len());
        let ast = unsafe &*self.module_ast_const(mid);
        let items = ast.at_const(ast.root).as_data.program.items;
        let ids = ast.list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let n = ast.at_const(nid);
            if n.kind == NodeKind::NODE_IMPORT {
                let path = join_parts(ast, src, n.as_data.import_decl.path, "::");
                let c = self.find(path.as_str());
                if c >= 0 {
                    let mut dup = false;
                    let from = idx.mod_imports[m];
                    for e in from as usize..idx.imports.len() {
                        if idx.imports[e] == c as ModuleId {
                            dup = true;
                        }
                    }
                    if !dup {
                        idx.imports.push(c as ModuleId);
                    }
                }
            } else if n.kind == NodeKind::NODE_EXTERN_BLOCK {
                // `pub` raw bindings / opaque handles live one level down, inside the extern block;
                // they name package-level items exactly like top-level decls (an extern enum's
                // variants come from the C header, so they get no variant records).
                let inner = n.as_data.extern_block.items;
                for j in 0..inner.len {
                    self.index_decl(idx, mid, srcp, unsafe ast.list(inner)[j as usize], ITEM_NONE);
                }
            } else if n.kind == NodeKind::NODE_EXTEND {
                // The extend itself anchors its associated items (owner links); it claims no name.
                idx.exts.push(nid);
                let eid = idx.items.len() as ItemId;
                let esp = n.span;
                idx.items.push(
                    ItemMeta {
                        module: mid,
                        node: nid,
                        owner: ITEM_NONE,
                        kind: ItemKind::IK_EXTEND as u8,
                        name: SYM_NONE,
                        is_public: false,
                        is_type: false,
                        start: esp.start,
                        len: esp.end - esp.start,
                    },
                );
                // Only methods and associated consts: an extend-body type alias is not indexed.
                let inner = n.as_data.extend_def.items;
                for j in 0..inner.len {
                    let iid = unsafe ast.list(inner)[j as usize];
                    let ik = ast.at_const(iid).kind;
                    if ik == NodeKind::NODE_FUNCTION || ik == NodeKind::NODE_CONST {
                        self.index_decl(idx, mid, srcp, iid, eid);
                    }
                }
            } else {
                self.index_decl(idx, mid, srcp, nid, ITEM_NONE);
                if n.kind == NodeKind::NODE_ENUM {
                    let ms = n.as_data.aggregate.members;
                    for k in 0..ms.len {
                        let vk = mid as u64 << 32 | (unsafe ast.list(ms)[k as usize]) as u64;
                        idx.variants.insert(skey_mix(0, vk), nid as u64 << 32 | k as u64);
                    }
                }
            }
        }
    }

    /// Find a *public* top-level declaration named `name` in module `mid`: a type when `want_type`,
    /// otherwise a value. Returns the decl's NodeId within module `mid`'s Ast, or NODE_NONE. O(1):
    /// a byte-exact symbol probe plus one name-map probe into the package declaration index.
    @c.always_inline
    pub fn lookup(self: &Self, mid: ModuleId, name: str, want_type: bool) NodeId {
        if !self.modules[mid as usize].has_ast {
            return NODE_NONE;
        }
        let mp = (self as *const Package) as *mut Package;
        unsafe (*mp).ensure_index();
        let s = self.idx.syms.find(name);
        if s == SYM_NONE {
            return NODE_NONE;
        }
        let key = s as u64 * 4u64 + if want_type {
            2u64;
        } else {
            0u64;
        } + 1u64;
        return switch self.idx.name_maps[mid as usize].get(&key) {
            Some(it) => self.idx.items[(*it) as usize].node,
            None => NODE_NONE,
        };
    }

    /// Like lookup but across every prelude module (the first in module order wins); the hit's `mid`
    /// is the owning module. One probe of the index's prelude name map.
    pub fn prelude_lookup(self: &Self, name: str, want_type: bool) LookupHit {
        let mp = (self as *const Package) as *mut Package;
        unsafe (*mp).ensure_index();
        let s = self.idx.syms.find(name);
        if s == SYM_NONE {
            return LookupHit { node: NODE_NONE, mid: 0 };
        }
        let lk = s as u64 * 2u64 + if want_type {
            1u64;
        } else {
            0u64;
        };
        return switch self.idx.pl_map.get(&lk) {
            Some(v) => LookupHit { node: (*v >> 32) as NodeId, mid: (*v & 0xFFFFFFFFu64) as ModuleId },
            None => LookupHit { node: NODE_NONE, mid: 0 },
        };
    }

    // Build (once) the cached [mid, transitive imports...] walk order for glob_lookup. Imports are
    // load-final, so the list stays valid for the whole pipeline.
    fn ensure_closure(self: &mut Self, mid: ModuleId) {
        let n = self.modules.len();
        while self.clo_lists.len() < n {
            self.clo_lists.push(Vector::<ModuleId>::new());
            self.clo_built.push(false);
        }
        if self.clo_built[mid as usize] {
            return;
        }
        let clo = self.import_closure(mid);
        let lst = &mut self.clo_lists[mid as usize];
        lst.push(mid);
        for i in 0..clo.len() {
            lst.push(clo[i]);
        }
        self.clo_built.set(mid as usize, true);
    }

    /// `mid`'s cached [mid, transitive imports...] list (built on first use; imports are load-final).
    /// The LSP's incremental rebuild reads it to decide which modules an edit can reach. NOTE: the
    /// implicit prelude is NOT in the list: a prelude edit must be treated as reaching everything.
    pub fn module_closure(self: &mut Self, mid: ModuleId) *const Vector<ModuleId> {
        self.ensure_closure(mid);
        return self.clo_lists.at(mid as usize);
    }

    /// Lookup extended over `mid`'s transitive imports (imports are public, C-style): searches `mid` itself,
    /// then every module it imports breadth-first in declaration order (the cached closure list). First hit
    /// wins.
    pub fn glob_lookup(self: &Self, mid: ModuleId, name: str, want_type: bool) LookupHit {
        if mid as usize >= self.modules.len() {
            return LookupHit { node: NODE_NONE, mid: 0 };
        }
        let mp = (self as *const Package) as *mut Package;
        unsafe (*mp).ensure_closure(mid);
        let lst = self.clo_lists.at(mid as usize);
        for i in 0..lst.len() {
            let mo = lst[i];
            let d = self.lookup(mo, name, want_type);
            if d != NODE_NONE {
                return LookupHit { node: d, mid: mo };
            }
        }
        return LookupHit { node: NODE_NONE, mid: 0 };
    }

    /// The modules `mid` transitively imports (excluding `mid` itself), breadth-first in declaration
    /// order: a BFS over the index import adjacency (identical order to the old per-call AST walk).
    pub fn import_closure(self: &Self, mid: ModuleId) Vector<ModuleId> {
        let n = self.modules.len();
        let mut out = Vector::<ModuleId>::new();
        if mid as usize > n {
            return out;
        } // the standalone Ast (module == count) has no imports to walk
        let mp = (self as *const Package) as *mut Package;
        unsafe (*mp).ensure_index();
        let mut seen = Vector::<bool>::new();
        for s in 0..n + 1 {
            seen.push(false);
        }
        seen.set(mid as usize, true);
        let mut head: usize = 0;
        let mut cur = mid;
        let mut go = true;
        while go {
            if cur as usize < n {
                let from = self.idx.mod_imports[cur as usize] as usize;
                let to = self.idx.mod_imports[cur as usize + 1] as usize;
                for e in from..to {
                    let c = self.idx.imports[e];
                    if !seen[c as usize] {
                        seen.set(c as usize, true);
                        out.push(c);
                    }
                }
            }
            if head >= out.len() {
                go = false;
            } else {
                cur = out[head];
                head = head + 1;
            }
        }
        return out;
    }

    // Is `m` a user (non-prelude) module? The standalone test Ast lives at module == count (outside modules).
    const fn module_is_user(self: &Self, m: ModuleId) bool {
        return m as usize >= self.modules.len() || !self.modules[m as usize].prelude;
    }

    /// Fill `mod_refs` from every module's resolutions, both arenas. Call once all resolutions are
    /// final and before any body arena is released; one pass over the package's resolutions.
    pub fn build_mod_refs(self: &mut Self) {
        let n = self.modules.len();
        let w = (n + 63) / 64;
        self.mod_refs_w = w;
        self.mod_refs.truncate(0);
        self.mod_refs.resize_default(n * w);
        for from in 0..n {
            if !self.modules[from].has_ast {
                continue;
            }
            let base = from * w;
            let ra = &self.modules[from].ast;
            let nb = ra.nodes.len();
            for i in 0..ra.nnodes() {
                let d = ra.resolution_def(Ast::nth_id_n(nb, i));
                let to = d.module as usize;
                if d.node != NODE_NONE && to < n {
                    let idx = base + to / 64;
                    self.mod_refs[idx] = self.mod_refs[idx] | 1u64 << (to % 64) as u64;
                }
            }
        }
        self.mod_refs_ready = true;
    }

    // Does module `from`'s code reference anything in module `to` (a cross-module use edge)?
    fn module_imports(self: &Self, from: ModuleId, to: ModuleId) bool {
        let n = self.modules.len();
        if from as usize >= n || !self.modules[from as usize].has_ast {
            return false;
        }
        // Fast path: O(1) bitset query once built (see build_mod_refs). `to >= n` is untracked, so fall
        // through to the linear scan (preserves exact semantics for the standalone-test Ast at module==n).
        if self.mod_refs_ready && to as usize < n {
            let word = self.mod_refs[from as usize * self.mod_refs_w + to as usize / 64];
            return (word & 1u64 << (to as usize % 64) as u64) != 0;
        }
        let ra = &self.modules[from as usize].ast;
        let nb9 = ra.nodes.len();
        let nn9 = ra.nnodes();
        for i in 0..nn9 {
            let d = ra.resolution_def(Ast::nth_id_n(nb9, i));
            if d.node != NODE_NONE && d.module == to {
                return true;
            }
        }
        return false;
    }

    // The user module a type argument's layout is complete in, or MODULE_NONE (self-contained / builtin).
    // `am` names the module whose Ast pool `t` lives in (re-derived each call so no borrow spans a recursion).
    fn type_user_home(self: &Self, am: ModuleId, t: TypeId) ModuleId {
        let y = *self.modules[am as usize].ast.type_at(t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_ARRAY {
            return self.type_user_home(am, y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_SLICE {
            return 0xFFFF;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig() {
            if self.module_is_user(y.module) {
                return y.module;
            }
            return 0xFFFF;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.modules[am as usize].ast.instance(y.as_data.inst);
            return self.instance_home_in(am, &it);
        }
        return 0xFFFF;
    }

    /// The module that emits instance `it` seen from module `am`: the first argument type whose
    /// home is a user module or imports the instance's own module, else the instance's module.
    pub fn instance_home_in(self: &Self, am: ModuleId, it: &TyInstance) ModuleId {
        for i in 0..it.n {
            let h = self.type_user_home(am, unsafe it.args[i as usize]);
            if h != 0xFFFF as ModuleId && (self.module_is_user(h) || self.module_imports(h, it.module)) {
                return h;
            }
        }
        return it.module;
    }

    /// The modules whose emission precedes module `a`'s: an instance `a` re-homes, a method
    /// instance on a foreign generic, and a generic call into a foreign function. Reads `a`'s
    /// instance, method-instance and generic-call tables and the callees' declarations; the
    /// generic-call table names body nodes, so the row is computed while `a`'s body syntax is
    /// live (`record_emit_deps`) when the driver releases it early.
    pub fn emit_dep_row(self: &Self, a: usize, out: &mut Vector<ModuleId>) {
        let n = self.modules.len();
        out.truncate(0);
        if !self.modules[a].has_ast {
            return;
        }
        let mut dep = Set::<ModuleId>::new();
        let aa = self.module_ast_const(a as ModuleId);
        let mut i: usize = 0;
        while i < unsafe (*aa).ninstances() {
            let it = *unsafe (*aa).used_instance(i);
            let bi = it.module as usize;
            if bi >= n || bi == a || dep.contains(&it.module) {
                i = i + 1;
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe (*aa).type_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if concrete && self.instance_home_in(a as ModuleId, &it) == a as ModuleId {
                dep.insert(it.module);
                out.push(bi as ModuleId);
            }
            i = i + 1;
        }
        i = 0;
        while i < unsafe (*aa).mono.len() {
            let mnode = unsafe (*aa).mono[i].node;
            if unsafe (*aa).at_const(mnode).kind != NodeKind::NODE_CALL {
                i = i + 1;
                continue;
            }
            let callee_id = unsafe (*aa).at_const(mnode).as_data.call.callee;
            let ck = unsafe (*aa).at_const(callee_id).kind;
            let fd = if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let e = unsafe (*aa).at_const(callee_id).as_data.specialization.expression;
                unsafe (*aa).resolution_def(e);
            } else {
                unsafe (*aa).resolution_def(callee_id);
            };
            let bi = fd.module as usize;
            if fd.node == NODE_NONE || bi >= n || bi == a || dep.contains(&fd.module) {
                i = i + 1;
                continue;
            }
            if !self.modules[bi].has_ast {
                i = i + 1;
                continue;
            }
            let bast = self.module_ast_const(fd.module);
            if unsafe (*bast).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                i = i + 1;
                continue;
            }
            dep.insert(fd.module);
            out.push(bi as ModuleId);
            i = i + 1;
        }
    }

    /// Size `emit_deps` for every module (before a parallel borrow frontier records rows).
    pub fn emit_deps_reserve(self: &mut Self) {
        self.emit_deps.truncate(0);
        self.emit_deps.resize_default(self.modules.len());
    }

    /// Record module `a`'s emission dependency row while its body syntax is live.
    pub fn record_emit_deps(self: &mut Self, a: usize) {
        let mut row = replace(self.emit_deps.index_mut(a), Vector::<ModuleId>::new());
        self.emit_dep_row(a, &mut row);
        *self.emit_deps.index_mut(a) = row;
    }

    /// Dependency-first module emit order: if module `a` full-monomorphizes a generic owned by `b` (re-homing a
    /// concrete instance to `a` itself), `b` must be emitted first. Kahn topo-sort with a lowest-id tiebreak;
    /// `order` is filled with `modules.len()` entries.
    pub fn emit_order(self: &Self, order: &mut Vector<ModuleId>) {
        let n = self.modules.len();
        if n == 0 {
            return;
        }
        // Reverse edges in CSR form (`users[user_off[b]..user_off[b + 1]]` are the modules that emit
        // after `b`) and a min-heap of the ready modules: O(E + M log M).
        let recorded = self.emit_deps.len() == n;
        let mut rows = Vector::<Vector<ModuleId>>::new();
        if !recorded {
            rows.resize_default(n);
            for a in 0..n {
                self.emit_dep_row(a, rows.index_mut(a));
            }
        }
        let deps = if recorded {
            &self.emit_deps;
        } else {
            &rows;
        };
        let mut indeg = Vector::<u32>::new();
        indeg.resize_default(n);
        let mut user_off = Vector::<u32>::new();
        user_off.resize_default(n + 1);
        for a in 0..n {
            let r = deps.at(a);
            indeg.set(a, r.len() as u32);
            for k in 0..r.len() {
                let bi = r[k] as usize + 1;
                user_off.set(bi, user_off[bi] + 1);
            }
        }
        for b in 0..n {
            user_off.set(b + 1, user_off[b + 1] + user_off[b]);
        }
        let mut fill = Vector::<u32>::new();
        fill.resize_default(n);
        let mut users = Vector::<u32>::new();
        users.resize_default(user_off[n] as usize);
        for a in 0..n {
            let r = deps.at(a);
            for k in 0..r.len() {
                let bi = r[k] as usize;
                users.set((user_off[bi] + fill[bi]) as usize, a as u32);
                fill.set(bi, fill[bi] + 1);
            }
        }
        let mut done = Vector::<bool>::new();
        done.resize_default(n);
        let mut ready = Vector::<u64>::new();
        for a in 0..n {
            if indeg[a] == 0 {
                gitems::heap_push(&mut ready, a as u64);
            }
        }
        // A cycle leaves no ready module: the lowest one not yet emitted goes next.
        let mut low: usize = 0;
        for _ in 0..n {
            if ready.len() == 0 {
                while done[low] {
                    low = low + 1;
                }
                gitems::heap_push(&mut ready, low as u64);
            }
            let pick = gitems::heap_pop(&mut ready) as usize;
            order.push(pick as ModuleId);
            done.set(pick, true);
            for k in user_off[pick] as usize..user_off[pick + 1] as usize {
                let x = users[k] as usize;
                if !done[x] {
                    indeg.set(x, indeg[x] - 1);
                    if indeg[x] == 0 {
                        gitems::heap_push(&mut ready, x as u64);
                    }
                }
            }
        }
    }

    // Auto-import the prelude: every TOP-LEVEL `<std_dir>/*.spc` (not subdirectories) becomes a prelude module
    // whose public items resolve unqualified. A file already loaded (explicitly imported) is flagged in place;
    // otherwise it is loaded under the reserved `__std::` namespace so its build output never collides with a
    // user's own `std/` folder. Names are sorted for deterministic module ids regardless of readdir order.
    fn load_prelude(self: &mut Self, std_dir: str, target: i32) {
        if std_dir.len() == 0 {
            return;
        }
        let mut sd = String::from_str(std_dir);
        let dir = unsafe shim::sc_opendir(sd.cstr());
        if dir == null {
            return;
        }
        let mut names = Vector::<String>::new();
        loop {
            let e = unsafe shim::sc_readdir(dir);
            if e == null {
                break;
            }
            let nm = unsafe shim::sc_dirent_name(e);
            let l = unsafe cstring::strlen(nm);
            if l < 5 {
                continue;
            }
            if unsafe cstring::strcmp(nm + (l - 4), ".spc".ptr() as *const char) != 0 {
                continue;
            }
            // Skip subdirectories named "*.spc" straight from readdir's d_type; only DT_UNKNOWN needs a stat.
            let dt = unsafe shim::sc_dirent_isdir(e);
            if dt == 1 {
                continue;
            }
            if dt < 0 {
                let mut probe = join2(std_dir, str::from_cstr(nm));
                if unsafe shim::sc_stat_isdir(probe.cstr()) == 1 {
                    continue;
                }
            }
            names.push(String::from_cstr(nm));
        }
        let _ = unsafe shim::sc_closedir(dir);
        // Sort by name (small: the std/ file list), byte-lexicographic with a length tiebreak (equivalent to
        // strcmp over these NUL-free views).
        names.sort();
        // Dedup: a std file is already loaded iff some already-loaded module has the SAME basename AND is the
        // same physical file (dev+ino). The basename pre-filter (a plain string compare, no syscall) keeps this
        // O(std files) even for huge projects (user modules almost never share a std/ basename, so we stat-
        // confirm only the rare collisions), and inode identity is exact + realpath-free (no getdirentries). The
        // __std:: modules appended below have distinct names and never match, so scanning only the initial m0 is
        // sufficient.
        let m0 = self.modules.len();
        for k in 0..names.len() {
            let mut file = join2(std_dir, names[k].as_str());
            let mut dup = false;
            for i2 in 0..m0 {
                if basename_of(self.modules[i2].file.as_str()) != names[k].as_str() {
                    continue;
                }
                if unsafe shim::sc_same_file(file.cstr(), self.modules[i2].file.cstr()) == 1 {
                    self.modules[i2].prelude = true;
                    dup = true;
                    break;
                }
            }
            if !dup {
                let stem = stem_of(names[k].as_str());
                let mut modpath = String::from_str("__std::");
                modpath.push_str(stem.as_str());
                let id = self.load_module(modpath.as_str(), file.as_str(), self.bootstrap, target);
                if id >= 0 {
                    self.modules[id as usize].prelude = true;
                }
            }
        }
        self.add_build_module(target);
    }
}
