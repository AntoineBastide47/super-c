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
import ast::ast as *;
import ast::parser as parser;
import std::parallel::sync as psy;
import std::parallel::runtime as prt;

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

/// The whole compilation: the root module plus every module reachable through `import`. Modules are kept as
/// separate Asts; cross-module references are DefId{module, node} into this array.
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
/// language server's module-order passes, the digest and the tests. The two signature states
/// are reserved for a signature-first scheduler; today an item goes Resolved -> Checking ->
/// Checked -> IrReady. Failed marks an item whose analysis did not complete.
pub const IS_PARSED: u8 = 0;
pub const IS_RESOLVED: u8 = 1;
pub const IS_SIG_CHECKING: u8 = 2;
pub const IS_SIG_READY: u8 = 3;
pub const IS_CHECKING: u8 = 4;
pub const IS_CHECKED: u8 = 5;
pub const IS_IR_READY: u8 = 6;
pub const IS_FAILED: u8 = 7;

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
    /// The component graph (`build`): `cdep` the components each component depends on,
    /// `csucc` the reverse, `citem` each component's items ascending. All CSR by component.
    pub cdep_off: Vector<u32>,
    pub cdep: Vector<u32>,
    pub csucc_off: Vector<u32>,
    pub csucc: Vector<u32>,
    pub citem_off: Vector<u32>,
    pub citem: Vector<u32>,
    /// Per component, `reach_w` words: the bits of every component it depends on, transitively
    /// (`build`); what a check of the component may read as checked (`graph::items::visible`).
    pub reach: Vector<u64>,
    pub reach_w: usize,
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
    pub fn new() ItemSched {
        return ItemSched {
            key: Vector::<u64>::new(),
            sig_hash: Vector::<u64>::new(),
            pre_off: Vector::<u32>::new(),
            pre_edges: Vector::<u32>::new(),
            fin_off: Vector::<u32>::new(),
            fin_edges: Vector::<u32>::new(),
            comp: Vector::<u32>::new(),
            ncomp: 0,
            state: Vector::<u8>::new(),
            ret_attr: Vector::<u8>::new(),
            dyn_edges: Set::<u64>::new(),
            by_node: Vector::<u32>::new(),
            top_lo: Vector::<u32>::new(),
            body_hi: Vector::<u32>::new(),
            cdep_off: Vector::<u32>::new(),
            cdep: Vector::<u32>::new(),
            csucc_off: Vector::<u32>::new(),
            csucc: Vector::<u32>::new(),
            citem_off: Vector::<u32>::new(),
            citem: Vector::<u32>::new(),
            reach: Vector::<u64>::new(),
            reach_w: 0,
            built: false,
            final_edges: false,
            finalized: false,
            build_ns: 0,
            final_ns: 0,
            hash_ns: 0,
        };
    }

    /// Approximate owned bytes.
    pub const fn retained(self: &Self) usize {
        return (self.key.capacity() + self.sig_hash.capacity()) * 8 + (self.pre_off.capacity() + self.pre_edges.capacity() + self.fin_off.capacity() + self.fin_edges.capacity() + self.comp.capacity() + self.by_node.capacity() + self.top_lo.capacity() + self.body_hi.capacity() + self.cdep_off.capacity() + self.cdep.capacity() + self.csucc_off.capacity() + self.csucc.capacity() + self.citem_off.capacity() + self.citem.capacity()) * 4 + self.reach.capacity() * 8 + self.state.capacity() + self.ret_attr.capacity() + self.dyn_edges.len() * 16;
    }
}

pub struct Package {
    pub modules: Vector<Module>,
    /// Instruction set `@arch` items are gated against: 0 x86_64, 1 aarch64, 2 wasm32, -1 unknown.
    /// Defaults to the host the compiler runs on; the driver overwrites it for `--arch=`.
    pub arch: i32,
    /// The `--bootstrap-tags` flag the ASTs were loaded under: gating changes item sets while
    /// leaving sources identical, so build caches keyed on sources must include it.
    pub bootstrap: bool,
    pub root_dir: String, // source root: the directory of the root file; imports resolve relative to it
    pub gen_root: String, // where codegen writes the emitted C tree: <build dir>/raw, set by the driver
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
    /// Caller->callee references fired from inside bodies of methods that are THEMSELVES gated by
    /// method_used (non-generic methods of plain generic extends): deferred as packed
    /// ((module<<24|node) caller <<32 | callee) edges and resolved by finalize_method_used once
    /// every module has typechecked, so a method kept alive only by pruned callers is pruned too.
    pub method_edges: Vector<u64>,
    pub edge_seen: Set<u64>,
    /// The same demand one level finer, for the methods whose signature can name a WIDER instance of
    /// their own receiver: keyed by inst_method_key, so a pair is emitted for the instances that reach it
    /// and for no others. Filled by seed_mono_body_instances, read by codegen.
    pub inst_methods: Set<u64>,
    /// Coroutine-reachability for preemption safepoints: 0 = uncomputed (emit everywhere),
    /// 1 = computed (only bodies inside co_spans need safepoints), 2 = widened (a coroutine entry
    /// could not be tracked: emit everywhere). co_spans[m] holds sorted start<<32|end body spans
    /// of the functions and closures a `launch`ed coroutine can execute; everything else can never
    /// starve a worker, so its loops need no safepoint tick.
    pub co_state: u8,
    pub co_spans: Vector<Vector<u64>>,
    /// Per module: the modules that emit before it (`emit_dep_row`), recorded before its body
    /// syntax is released; empty when the rows are computed at emission planning.
    pub emit_deps: Vector<Vector<ModuleId>>,
    /// Cancellation-edge reachability: 0 = uncomputed (no cancellation checks anywhere), 1 =
    /// computed. cancel_marks[m] holds start<<32|end DECL spans of the functions and closures whose
    /// bodies can reach `runtime::cancel_accept`; a call to one of these from a task-reachable
    /// body is followed by a compiled cancellation check with a cleanup edge.
    pub cancel_state: u8,
    pub cancel_marks: Vector<Set<u64>>,
    /// Does any non-std module request cancellation (runtime::request_cancel, runtime::try_shutdown,
    /// or anything in std::parallel::task)? Combined loop safepoints are emitted only then: a
    /// program that never cancels pays no per-loop ladder, and its shutdown reports a spinning task
    /// as unresponsive instead of reclaiming it.
    pub cancel_used: bool,
    /// Methods resolved with NO receiver in hand: the format helpers the print lowering reaches for,
    /// and anything else the compiler names by decl alone. Nothing says which instance wants them, so
    /// every instance does: (module << 32 | node), exempt from the per-instance demand test.
    pub always_methods: Set<u64>,
    /// Private, non-generic functions referenced from a GENERIC body of their own module, as
    /// (module << 32 | node). That generic may be monomorphized into ANOTHER TU, which cannot reach a
    /// `static` symbol, so its owner emits it with external linkage and declares it in its header.
    /// Filled once, serially, before codegen forks: every worker must answer this the same way.
    pub extern_privates: Set<u64>,
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
    /// The maps of the last `publish_types`: per module, provisional pool index to final type id,
    /// instance record index, and const-expression index. Read through `map_type`.
    pub pub_map: Vector<Vector<TypeId>>,
    pub pub_imap: Vector<Vector<u32>>,
    pub pub_cmap: Vector<Vector<u32>>,
    pub publications: u32, // batches published so far
    /// Per final id: the publication class that numbered it (0 signature-reachable, 1 body-only of
    /// the first batch, 2 a later batch, 3 interned by the instance graph between checkpoints); the
    /// seeds carry 0.
    pub tt_class: Vector<u8>,
    /// Cross-module reference bitset: mod_refs[from*mod_refs_w + to/64] bit (to%64) is set iff module `from`
    /// has any resolution into module `to`. Built once (resolve-final) at the start of instance propagation;
    /// makes module_imports an O(1) query instead of a linear resolutions scan. `mod_refs_ready` gates it
    /// (module_imports falls back to the linear scan if queried before the build).
    pub mod_refs: Vector<u64>,
    pub mod_refs_w: usize,
    pub mod_refs_ready: bool,
    /// The package declaration index: symbols, ItemMeta records, per-module name maps,
    /// import adjacency + SCCs, and the LangItem table. Built once on first use after loading
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
    pub lint_errs: u32, // total errors across the lint pipeline stages
    pub lint_fixable: u32, // errors carrying a machine fix; `lint --fix` proceeds when lint_errs == lint_fixable
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
}

/// Parallel-table cache of directory listings for import resolution. `ok[i]` = did opendir(dirs[i]) succeed.
pub struct DirCache {
    pub dirs: Vector<String>,
    pub entries: Vector<Vector<String>>,
    pub ok: Vector<bool>,
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
    IK_COUNT,
}

/// One record per top-level or associated declaration. `node` is the declaration NodeId:
/// DefId{module, node} identity and C mangling key off it. Signatures and attributes stay
/// reachable through the node (the Ast side tables are their owner).
pub struct ItemMeta {
    pub module: ModuleId,
    pub node: NodeId,
    pub owner: ItemId, // enclosing IK_EXTEND for methods/assoc consts; ITEM_NONE at top level
    pub kind: u8, // ItemKind
    pub name: SymbolId, // SYM_NONE for unnamed declarations (extends)
    pub is_public: bool,
    pub is_type: bool, // occupies the type namespace in name lookup
    pub start: u32, // name span in the module source (the whole-decl span start for unnamed items)
    pub len: u32,
}

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

/// Compiler-referenced prelude hooks (`prelude_lookup` with a fixed name), resolved to their decl
/// once per index build. Append-only.
pub enum LangItem {
    LI_STR,
    LI_STRING,
    LI_SLICE,
    LI_SLICEMUT,
    LI_RANGE,
    LI_GLOBAL,
    LI_OPTION,
    LI_VECTOR,
    LI_TYPEINFO,
    LI_TYPETAG,
    LI_UNSAFECELL,
    LI_ALLOCATOR,
    LI_DEFAULT,
    LI_COUNT,
}

const LI_COUNT_N: usize = LangItem::LI_COUNT as usize;

// The prelude name each LangItem resolves (all in the type namespace), indexed by the enum value.
const LI_NAMES: [str<'static>; LI_COUNT_N] = [
    "str",
    "String",
    "Slice",
    "SliceMut",
    "Range",
    "Global",
    "Option",
    "Vector",
    "TypeInfo",
    "TypeTag",
    "UnsafeCell",
    "Allocator",
    "Default",
];

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
/// the resolved direct-import adjacency, its strongly connected components, and the LangItem table.
pub struct PkgIndex {
    pub syms: SymTab,
    pub items: Vector<ItemMeta>,
    pub mod_items: Vector<u32>, // modules+1 offsets into `items`
    pub name_maps: Vector<Map<u64, u32>>, // per module: sym*4 + is_type*2 + is_pub -> ItemId, first wins
    pub imports: Vector<ModuleId>, // resolved direct imports, declaration order, per-module dedup
    pub mod_imports: Vector<u32>, // modules+1 offsets into `imports`
    pub scc_of: Vector<u32>, // module -> import-graph SCC id (completion order; deterministic)
    pub lang_items: Vector<LookupHit>, // LangItem -> prelude decl (node == NODE_NONE when absent)
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
}

extend SymTab {
    /// An empty interner.
    pub fn new() SymTab {
        return SymTab { names: Vector::<String>::new(), index: Map::<u64, u32>::new(), chain: Vector::<u32>::new() };
    }

    /// The SymbolId already interned for `name`, or SYM_NONE. Byte-exact.
    @c.always_inline
    pub fn find(self: &Self, name: str) SymbolId {
        return switch self.index.get(&fnv_name(name)) {
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
        let h = fnv_name(name);
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

extend PkgIndex {
    /// An empty index; `ensure_index` on the package builds it.
    pub fn new() PkgIndex {
        return PkgIndex {
            syms: SymTab::new(),
            items: Vector::<ItemMeta>::new(),
            mod_items: Vector::<u32>::new(),
            name_maps: Vector::<Map<u64, u32>>::new(),
            imports: Vector::<ModuleId>::new(),
            mod_imports: Vector::<u32>::new(),
            scc_of: Vector::<u32>::new(),
            lang_items: Vector::<LookupHit>::new(),
            sugar_items: Vector::<LookupHit>::new(),
            pl_map: Map::<u64, u64>::new(),
            sigs: Vector::<ItemSig>::new(),
            sig_types: Vector::<TypeId>::new(),
            sig_of: Map::<u64, u32>::new(),
            sigs_built: false,
            built_mods: 0,
        };
    }
}

// FNV-1a over a name's bytes; the symbol interner and per-module name maps key on it.
fn fnv_name(name: str) u64 {
    let p = name.ptr();
    let mut h: u64 = 1469598103934665603u64;
    for i in 0..name.len() {
        h = h ^ (unsafe p[i]) as u64;
        h = h * 1099511628211u64;
    }
    return h;
}

// Iterative Tarjan over the import adjacency: fills scc_of[m] with a strongly-connected-component id
// per module (mutually-importing modules share one). Components are numbered in completion order,
// which is deterministic for a fixed module set. No recursion: the DFS keeps its own frame stack, so
// an adversarial import chain cannot exhaust the call stack.
fn scc_build(n: usize, imports: &Vector<ModuleId>, mod_imports: &Vector<u32>, scc_of: &mut Vector<u32>) {
    scc_of.clear();
    let mut order = Vector::<i64>::new(); // discovery index per module; -1 = unvisited
    let mut low = Vector::<i64>::new();
    let mut on = Vector::<bool>::new();
    for i in 0..n {
        scc_of.push(0);
        order.push(-1);
        low.push(-1);
        on.push(false);
    }
    let mut stk = Vector::<u32>::new(); // Tarjan's component stack
    let mut fv = Vector::<u32>::new(); // DFS frames: module
    let mut fc = Vector::<u32>::new(); // DFS frames: next out-edge cursor
    let mut next: i64 = 0;
    let mut comp: u32 = 0;
    for root in 0..n {
        if order[root] >= 0 {
            continue;
        }
        order.set(root, next);
        low.set(root, next);
        next += 1;
        stk.push(root as u32);
        on.set(root, true);
        fv.push(root as u32);
        fc.push(0);
        while fv.len() != 0 {
            let v = fv[fv.len() - 1] as usize;
            let c = fc[fc.len() - 1] as usize;
            let from = mod_imports[v] as usize;
            let deg = mod_imports[v + 1] as usize - from;
            if c < deg {
                fc.set(fc.len() - 1, (c + 1) as u32);
                let w = imports[from + c] as usize;
                if order[w] < 0 {
                    order.set(w, next);
                    low.set(w, next);
                    next += 1;
                    stk.push(w as u32);
                    on.set(w, true);
                    fv.push(w as u32);
                    fc.push(0);
                } else if on[w] && order[w] < low[v] {
                    low.set(v, order[w]);
                }
            } else {
                let _ = fv.pop();
                let _ = fc.pop();
                if fv.len() != 0 {
                    let p = fv[fv.len() - 1] as usize;
                    if low[v] < low[p] {
                        low.set(p, low[v]);
                    }
                }
                if low[v] == order[v] {
                    loop {
                        let w = stk[stk.len() - 1] as usize;
                        let _ = stk.pop();
                        on.set(w, false);
                        scc_of.set(w, comp);
                        if w == v {
                            break;
                        }
                    }
                    comp += 1;
                }
            }
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
    let mut buf = Vector::<u8>::new();
    buf.resize_default(sz + 1);
    let n = unsafe stdio::fread(buf.as_ptr() as *mut char, 1, sz, f);
    if n != sz && unsafe stdio::ferror(f) != 0 {
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    unsafe stdio::fclose(f);
    // Pre-size to content + read-ahead padding so neither the content copy nor pad_nul reallocates, then
    // append lexer::SOURCE_PAD trailing NUL bytes PAST len (len stays n): a read-ahead sentinel the lexer
    // relies on to over-read safely (see lexer::SOURCE_PAD).
    let mut out = String::with_capacity(n + lexer::SOURCE_PAD);
    out.push_str(str::from_raw(buf.as_ptr(), n));
    out.pad_nul(lexer::SOURCE_PAD);
    return Option::<String>::Some(out);
}

// The directory portion of `path` (without trailing slash), or "." when there is none.
fn dir_of(path: str) String {
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
        return String::from_str(".");
    }
    return String::from_str(path.slice(0, slash as usize));
}

// The file stem (basename without extension): "dir/std/string.spc" -> "string".
fn stem_of(path: str) String {
    let n = path.len();
    let mut bstart: usize = 0;
    let mut i: usize = 0;
    while i < n {
        if path.byte_at(i) == b'/' {
            bstart = i + 1;
        }
        i = i + 1;
    }
    let mut dot: i64 = -1;
    i = bstart;
    while i < n {
        if path.byte_at(i) == b'.' {
            dot = i as i64;
        }
        i = i + 1;
    }
    let end = if dot >= 0 {
        dot as usize;
    } else {
        n;
    };
    return String::from_str(path.slice(bstart, end));
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

// Heap "<a>/<b>".
fn join2(a: str, b: str) String {
    let mut out = String::from_str(a);
    out.push_str("/");
    out.push_str(b);
    return out;
}

extend DirCache {
    /// An empty cache of directory listings.
    pub fn new() DirCache {
        return DirCache {
            dirs: Vector::<String>::new(),
            entries: Vector::<Vector<String>>::new(),
            ok: Vector::<bool>::new(),
        };
    }
    // Index of `dir` in the cache, scanning (opendir/readdir) it once on first request.
    fn index_of(self: &mut Self, dir: str) usize {
        for i in 0..self.dirs.len() {
            if self.dirs[i].as_str() == dir {
                return i;
            }
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
        for k in 0..ents.len() {
            if ents[k].as_str() == file {
                return true;
            }
        }
        return path_exists(path);
    }
}
// Resolve an import's file by searching the project root first, then the std root (so `import std::x;`
// finds <std_root>/std/x.spc), then the bundled `ffi/` bindings (so a bare `import stdio;` finds
// <std_root>/ffi/stdio.spc). Returns the first path that exists, else the project-relative path. Owned.
fn resolve_import_file(dca: usize, root_dir: str, alt_root: str, std_root: str, ast: &Ast, src: str, parts: NodeList) String {
    let dc = dca as *mut DirCache;
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

/// Worker count for parallel module discovery: 1 = the serial reference loader; 0 or >= 2 lets
/// speculative parse tasks run on the coroutine pool. Set by the DRIVER before package_load; the
/// LSP and library users keep the serial default (overlaid loads always stay serial).
/// Parallel analysis pays for itself only past this much user (non-prelude) source. Below it the
/// worker pool costs about as much CPU as the whole serial compile and saves a few milliseconds of
/// wall time at most (release build, serial vs parallel: 30 KiB 24 vs 23 ms, 118 KiB 30 vs 25 ms,
/// 472 KiB 57 vs 36 ms).
pub const PAR_MIN_USER_BYTES: usize = 262144; // 256 KiB

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
}

struct PParse {
    pub u: *mut PUnit,
    pub tags: bool,
}

// The unit slot is pinned for the task's lifetime (units only grow between waves) and each task
// owns exactly one slot.
unsafe extend PParse as Send {}

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

// Cross-module instance propagation + emit ordering. These thread raw `*mut Ast`/`*const Ast` pointers to
// sidestep the by-value move rules on `&Ast`; the modules Vector is never grown during propagation, so
// pointers into `modules[x].ast` stay valid throughout.

/// Load `root_file` and, transitively, every module it imports, then append the std prelude found under
/// `std_dir` (empty skips it). Diagnostics are printed as encountered. Returns a Package (check `.ok`).
pub fn package_load(root_file: str, std_dir: str, bootstrap_tags: bool, target: i32) Package {
    let d = dir_of(root_file);
    let p = package_load_rooted(root_file, d.as_str(), "", std_dir, bootstrap_tags, target);
    return p;
}

/// Like package_load, but imports resolve against an explicit package root instead of the root
/// file's own directory (`super-c lint <dir>` lints nested package files in their true package).
pub fn package_load_rooted(root_file: str, root_dir: str, alt_dir: str, std_dir: str, bootstrap_tags: bool, target: i32) Package {
    ts_init();
    let mut p = package_load_rooted_i(root_file, root_dir, alt_dir, std_dir, bootstrap_tags, target);
    p.bind_types();
    return p;
}

fn package_load_rooted_i(root_file: str, root_dir: str, alt_dir: str, std_dir: str, bootstrap_tags: bool, target: i32) Package {
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
    let mut p = Package::new();
    p.ok = true;
    p.bootstrap = bootstrap_tags;
    p.overlay_files = overlay_files;
    p.overlay_texts = overlay_texts;
    p.root_dir = String::from_str(root_dir);
    p.alt_root = String::from_str(alt_dir);
    if std_dir.len() != 0 {
        p.std_root = dir_of(std_dir);
    }
    let rp = stem_of(root_file);
    let rf = String::from_str(root_file);
    p.load_module(rp.as_str(), rf.as_str(), bootstrap_tags, target);
    p.load_prelude(std_dir, target);
    p.seed_core();
    p.bind_types();
    return p;
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
    let mut p = Package::new();
    p.ok = true;
    p.overlay_files = overlay_files;
    p.overlay_texts = overlay_texts;
    p.root_dir = String::from_str(root_dir);
    p.alt_root = String::from_str(alt_dir);
    if std_dir.len() != 0 {
        p.std_root = dir_of(std_dir);
    }
    p.load_prelude(std_dir, target);
    p.seed_core();
    p.bind_types();
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
    if !from_alt && ls >= 0 && rel.slice(ls as usize + 1, end) == rel.slice(pv as usize + 1, ls as usize) {
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
    let mut p = Package::new();
    p.ok = true;
    p.root_dir = String::from_str(".");
    if std_dir.len() != 0 {
        p.std_root = dir_of(std_dir);
    }
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
    return p;
}

// A PATH_MAX realpath scratch buffer (the omitted array field zero-fills on partial init).
struct RealBuf {
    pub b: [char; 4096],
}

// The final path component of `path` (a view into it): "dir/std/string.spc" -> "string.spc".
fn basename_of(path: str) str {
    let n = path.len();
    let mut b: usize = 0;
    let mut i: usize = 0;
    while i < n {
        if path.byte_at(i) == b'/' {
            b = i + 1;
        }
        i = i + 1;
    }
    return path.slice(b, n);
}

// Byte-lexicographic order of two names with a length tiebreak (equivalent to strcmp over NUL-free views).
const fn name_cmp(a: &String, b: &String) i32 {
    let la = a.len();
    let lb = b.len();
    let m = if la < lb {
        la;
    } else {
        lb;
    };
    let c = unsafe cstring::memcmp(a.as_str().ptr(), b.as_str().ptr(), m);
    if c != 0 {
        return c;
    }
    return la as i32 - lb as i32;
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
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        d = pub_child_depth(depth, y.as_data.proj.owner);
    } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
        if (y.as_data.inst & TYPE_PROV) != 0 {
            let it = batch.instance((y.as_data.inst & TYPE_PROV_MASK) as usize);
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
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        pub_push_child(y.as_data.proj.owner, out);
    } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
        if (y.as_data.inst & TYPE_PROV) != 0 {
            let it = batch.instance((y.as_data.inst & TYPE_PROV_MASK) as usize);
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
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        y.as_data.proj.owner = pub_fin(fin, y.as_data.proj.owner);
    } else if (k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN) && (y.as_data.inst & TYPE_PROV) != 0 {
        let bi = (y.as_data.inst & TYPE_PROV_MASK) as usize;
        if ifin[bi] == 0xFFFFFFFFu32 {
            let mut it = *batch.instance(bi);
            for q in 0..it.n {
                unsafe it.args[q as usize] = pub_fin(fin, unsafe it.args[q as usize]);
            }
            ifin[bi] = g.insert_inst(&it);
        }
        y.as_data.inst = ifin[bi];
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
    } else if kd == TypeKind::TYPE_INSTANCE || kd == TypeKind::TYPE_DYN {
        let it = g.instance(y.as_data.inst as usize);
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

    /// Put every module under the package type table (package identity): each module's pool then
    /// holds only its provisional types, published in batches by `publish_types`.
    pub fn bind_types(self: &mut Self) {
        if self.tt.deref().len() == 0 {
            self.tt.deref_mut().seed();
            for _ in 0..self.tt.deref().len() {
                self.tt_class.push(0);
            }
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

    /// Publish every provisional type of every module as one batch. The batch's distinct records
    /// (a record two modules both hold is one) get final ids appended after the ids of earlier
    /// batches, in a canonical order that depends on nothing but the set of records: first the
    /// records reachable from function signatures, then the rest, each class by structural depth
    /// (children before parents) and within a depth by the record's structural key. So the ids
    /// are the same under any worker count, and a body-only edit leaves every signature id in
    /// place. Then every module's tables are remapped (`Ast::publish_remap`) and its pool cleared;
    /// the maps stay in `pub_map` for the driver to remap the stores it owns (the constant engine,
    /// the kept lowerings).
    /// A total order over two modules' const-expression forms by content (`module << 32 | pool
    /// index` each): the constant, the term count, the divisor, then each term's parameter and
    /// coefficient.
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

    pub fn publish_types(self: &mut Self) {
        let n = self.modules.len();
        self.ensure_index();
        self.pub_map.clear();
        self.pub_imap.clear();
        self.pub_cmap.clear();
        // Pass 1: the batch table, records translated so a provisional child is a batch id (tagged).
        let mut batch = TypePool::new();
        let mut bmaps = Vector::<Vector<TypeId>>::new();
        let mut bimaps = Vector::<Vector<u32>>::new();
        let mut cmaps = Vector::<Vector<u32>>::new();
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
                        } else if k == TypeKind::TYPE_FIELD_PROJECTION {
                            y.as_data.proj.owner = pub_child(&map, y.as_data.proj.owner, i);
                        } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
                            let ii = y.as_data.inst;
                            if (ii & TYPE_PROV) != 0 {
                                let pi = (ii & TYPE_PROV_MASK) as usize;
                                if imap[pi] == 0xFFFFFFFFu32 {
                                    let mut it = *a.pool.instance(pi);
                                    for q in 0..it.n {
                                        unsafe it.args[q as usize] = pub_child(&map, unsafe it.args[q as usize], i);
                                    }
                                    imap[pi] = batch.insert_inst(&it) | TYPE_PROV;
                                }
                                y.as_data.inst = imap[pi];
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
                cmaps.push(cmap);
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
        for _ in 0..ngroups {
            groups.push(Vector::<u32>::new());
        }
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
                self.modules[m].ast.publish_remap(&map, &imap, cmaps.at(m));
            }
            self.pub_map.push(map);
            self.pub_imap.push(imap);
        }
        self.pub_cmap = cmaps;
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
            } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
                let it = g.instance(y.as_data.inst as usize);
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
            bootstrap: false,
            modules: Vector::<Module>::new(),
            tt: Box::<TypePool>::new(TypePool::new()),
            pub_map: Vector::<Vector<TypeId>>::new(),
            pub_imap: Vector::<Vector<u32>>::new(),
            pub_cmap: Vector::<Vector<u32>>::new(),
            publications: 0,
            tt_class: Vector::<u8>::new(),
            root_dir: String::new(),
            gen_root: String::new(),
            std_root: String::new(),
            alt_root: String::new(),
            ok: true,
            ext_inputs: Vector::<String>::new(),
            core_module: 0,
            core_seeded: false,
            method_used: Vector::<Vector<bool>>::new(),
            inst_methods: Set::<u64>::new(),
            co_state: 0,
            co_spans: Vector::<Vector<u64>>::new(),
            emit_deps: Vector::<Vector<ModuleId>>::new(),
            cancel_state: 0,
            cancel_marks: Vector::<Set<u64>>::new(),
            cancel_used: false,
            always_methods: Set::<u64>::new(),
            method_edges: Vector::<u64>::new(),
            edge_seen: Set::<u64>::new(),
            extern_privates: Set::<u64>::new(),
            cir: null,
            inl_store: null,
            jobs: 1, // serial unless a driver opts in: a bare Package must never launch tasks
            sched: ItemSched::new(),
            shard_rules: Vector::<ShardRule>::new(),
            mod_refs: Vector::<u64>::new(),
            mod_refs_w: 0,
            mod_refs_ready: false,
            idx: PkgIndex::new(),
            clo_lists: Vector::<Vector<ModuleId>>::new(),
            clo_built: Vector::<bool>::new(),
            tok_scratch: Vector::<tok::Token>::new(),
            cg_scratch: String::new(),
            dir_cache: DirCache::new(),
            lint_set: Vector::<bool>::new(),
            lint_pub: false,
            overlay_files: Vector::<String>::new(),
            overlay_texts: Vector::<String>::new(),
            body_hold: Vector::<bool>::new(),
            icost_on: false,
            free_bodies: false,
            icost_tc: Vector::<u64>::new(),
            icost_rs: Vector::<u64>::new(),
            icost_bc: Vector::<u64>::new(),
            icost_lw: Vector::<u64>::new(),
            icost_mod: Vector::<u64>::new(),
            ctfe_edges: Vector::<u64>::new(),
        };
    }

    // The Ast to read for module `mid` from package-level lookups. Asts live IN PLACE in the module
    // table for their whole life: a stage mutates its module's Ast through a raw pointer into this
    // slot, never by moving it out, so this read is always the live tree (no override indirection).
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

    /// Compute co_spans: seed with the closure/function arguments of `std::parallel::runtime::submit`
    /// (what `launch` desugars to), then close over direct calls made inside marked spans. A callee
    /// that cannot be pinned to a declaration (a fn value, a dyn method) widens to everywhere.
    /// One pass over the nodes builds a decl table (every function and closure, per module in span
    /// order) and attaches each pinned call to its innermost decl; the closure is then a worklist
    /// over decls, never a rescan of the node arrays.
    pub fn co_compute(self: &mut Self) {
        self.co_state = 1;
        self.co_spans.truncate(0);
        for _m in 0..self.modules.len() {
            self.co_spans.push(Vector::<u64>::new());
        }
        let rt = self.find("std::parallel::runtime");
        if rt < 0 {
            // No coroutine runtime loaded: nothing can launch.
            return;
        }
        let sub = self.glob_lookup(rt as ModuleId, "submit", false);
        if sub.node == NODE_NONE {
            return;
        }
        let nm = self.modules.len();
        // Decls sorted by span start within each module: the decls inside decl `d` are the run that
        // follows it while their starts stay below its end, and a site's innermost decl is the
        // last start at or before it whose end covers it (else that decl's ancestor).
        let mut d_start = Vector::<u32>::new(); // per module (+ sentinel): first decl
        let mut d_span = Vector::<u64>::new(); // start << 32 | end
        let mut d_parent = Vector::<u32>::new(); // innermost enclosing decl, or NONE
        let mut d_lim = Vector::<u32>::new(); // per decl: one past its module's last decl
        let mut d_of = Map::<u64, u32>::new(); // (module << 32 | node) -> decl
        let mut dm_span = Vector::<u64>::new(); // per-module collection scratch
        let mut dm_node = Vector::<u32>::new();
        let none: u32 = 0xFFFFFFFFu32;
        for m in 0..nm {
            d_start.push(d_span.len() as u32);
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            dm_span.truncate(0);
            dm_node.truncate(0);
            let nb9 = a.nodes.len();
            let nn9 = a.nnodes();
            for k in 0..nn9 {
                let ni = Ast::nth_id_n(nb9, k);
                let n = a.at_const(ni);
                if n.kind == NodeKind::NODE_FUNCTION || n.kind == NodeKind::NODE_CLOSURE {
                    dm_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                    dm_node.push(ni);
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
            let base = d_span.len() as u32;
            let mut open = none; // the innermost decl whose span is still open
            for x in 0..dm_span.len() {
                let sp = dm_span[x];
                let st = (sp >> 32) as u32;
                while open != none && (d_span[open as usize] & 0xFFFFFFFFu64) as u32 <= st {
                    open = d_parent[open as usize];
                }
                d_span.push(sp);
                d_parent.push(open);
                d_lim.push(base + dm_span.len() as u32);
                d_of.insert(m as u64 << 32 | dm_node[x] as u64, base + x as u32);
                open = base + x as u32;
            }
        }
        d_start.push(d_span.len() as u32);
        // Call records attached to their innermost decl: a pinned target outside std (a decl to
        // mark), or NONE for a callee the tracker cannot pin (fires: everything widens).
        let mut r_decl = Vector::<u32>::new();
        let mut r_tgt = Vector::<u32>::new();
        let mut seeds = Vector::<u32>::new();
        for m in 0..nm {
            let a = unsafe &*self.module_ast_const(m as ModuleId);
            let lo = d_start[m] as usize;
            let hi = d_start[m + 1] as usize;
            let nb9 = a.nodes.len();
            let nn9 = a.nnodes();
            for k in 0..nn9 {
                let ni = Ast::nth_id_n(nb9, k);
                let n = a.at_const(ni);
                if n.kind != NodeKind::NODE_CALL {
                    continue;
                }
                let cd = n.as_data.call;
                let cr = a.resolution_def(cd.callee);
                if cr.module == sub.mid && cr.node == sub.node {
                    if cd.args.len < 1 {
                        continue;
                    }
                    let a0 = unsafe a.list(cd.args)[0];
                    let mut sk: u64 = 0;
                    if a.at_const(a0).kind == NodeKind::NODE_CLOSURE {
                        sk = m as u64 << 32 | a0 as u64;
                    } else {
                        let fr = a.resolution_def(a0);
                        if fr.node != NODE_NONE && unsafe (&*self.module_ast_const(fr.module)).at_const(fr.node).kind == NodeKind::NODE_FUNCTION {
                            sk = fr.module as u64 << 32 | fr.node as u64;
                        } else {
                            // A coroutine entry the tracker cannot pin.
                            self.co_state = 2;
                            return;
                        }
                    }
                    switch d_of.get(&sk) {
                        Some(d) => {
                            seeds.push(*d);
                        },
                        _ => {},
                    };
                    continue;
                }
                // The innermost decl around the site; a site outside every decl (a const
                // initializer) never runs inside a coroutine.
                let mut d = none;
                {
                    let mut l = lo;
                    let mut h = hi;
                    while l < h {
                        let mid = (l + h) / 2;
                        if (d_span[mid] >> 32) as u32 <= n.span.start {
                            l = mid + 1;
                        } else {
                            h = mid;
                        }
                    }
                    if l > lo {
                        d = (l - 1) as u32;
                    }
                    while d != none && (d_span[d as usize] & 0xFFFFFFFFu64) as u32 < n.span.end {
                        d = d_parent[d as usize];
                    }
                }
                if d == none {
                    continue;
                }
                let mut t = DefId { module: 0, node: NODE_NONE };
                let ni32 = ni;
                switch a.call_info.get(&ni32) {
                    Some(v) => {
                        t = DefId { module: (*v >> 40) as ModuleId, node: (*v >> 8 & 0xFFFFFFFFu64) as NodeId };
                    },
                    _ => {},
                };
                if t.node == NODE_NONE {
                    t = a.resolution_def(cd.callee);
                }
                if t.node == NODE_NONE {
                    let ck = a.at_const(cd.callee).kind;
                    if ck == NodeKind::NODE_MEMBER {
                        t = a.resolution_def(a.at_const(cd.callee).as_data.member.member);
                    }
                }
                if t.node == NODE_NONE {
                    if a.is_free_call(ni, self.modules.at(m).source.as_str()) {
                        // An explicit drop: no callee body to run.
                        continue;
                    }
                    // Fn value or dyn dispatch: cannot pin the callee.
                    r_decl.push(d);
                    r_tgt.push(none);
                    continue;
                }
                let ta = unsafe &*self.module_ast_const(t.module);
                if ta.at_const(t.node).kind != NodeKind::NODE_FUNCTION {
                    // Ctor/variant/type call: no body to run.
                    continue;
                }
                // The scan stops at the std boundary: std loops are bounded by their inputs
                // (containers, strings), so they always return to a marked frame, and a closure
                // built in coroutine code is covered lexically by its enclosing marked span.
                // std::parallel additionally never emits safepoints at all.
                let tp9 = self.modules.at(t.module as usize).path.as_str();
                if tp9.starts_with("std") || tp9.starts_with("__std") {
                    continue;
                }
                switch d_of.get(&(t.module as u64 << 32 | t.node as u64)) {
                    Some(td) => {
                        r_decl.push(d);
                        r_tgt.push(*td);
                    },
                    _ => {},
                };
            }
        }
        // Records by decl (counting sort).
        let nd = d_span.len();
        let mut r_start = Vector::<u32>::new();
        for _i in 0..nd + 1 {
            r_start.push(0);
        }
        for i in 0..r_decl.len() {
            let d = r_decl[i] as usize;
            r_start.set(d + 1, r_start[d + 1] + 1);
        }
        for d in 0..nd {
            r_start.set(d + 1, r_start[d + 1] + r_start[d]);
        }
        let mut r_flat = Vector::<u32>::new();
        for _i in 0..r_decl.len() {
            r_flat.push(0);
        }
        let mut cur = Vector::<u32>::new();
        for d in 0..nd {
            cur.push(r_start[d]);
        }
        for i in 0..r_decl.len() {
            let d = r_decl[i] as usize;
            r_flat.set(cur[d] as usize, r_tgt[i]);
            cur.set(d, cur[d] + 1);
        }
        // The closure: a marked decl (a span) turns itself and every decl inside it on; an on decl
        // fires its records once, marking each target. Every decl turns on at most once.
        let mut on = Vector::<u8>::new();
        let mut marked = Vector::<u8>::new();
        for _i in 0..nd {
            on.push(0);
            marked.push(0);
        }
        let mut queue = Vector::<u32>::new();
        let mut m_of = 0 as usize; // the module of the decl being marked, found by d_start
        for si in 0..seeds.len() {
            let d = seeds[si] as usize;
            if marked[d] == 0 {
                marked.set(d, 1);
                while d_start[m_of + 1] as usize <= d {
                    m_of += 1;
                }
                while d_start[m_of] as usize > d {
                    m_of -= 1;
                }
                self.co_spans.index_mut(m_of).push(d_span[d]);
                if on[d] == 0 {
                    on.set(d, 1);
                    queue.push(d as u32);
                }
            }
        }
        let mut qi: usize = 0;
        while qi < queue.len() {
            let d = queue[qi] as usize;
            qi += 1;
            // Everything declared inside `d` runs inside its span: the run of the module's
            // decls after `d` whose starts fall below its end (spans nest).
            let dend = (d_span[d] & 0xFFFFFFFFu64) as u32;
            let mut k = d + 1;
            while k < d_lim[d] as usize && (d_span[k] >> 32) as u32 < dend {
                if on[k] == 0 {
                    on.set(k, 1);
                    queue.push(k as u32);
                }
                k += 1;
            }
            for ri in r_start[d]..r_start[d + 1] {
                let t = r_flat[ri as usize];
                if t == none {
                    // Fn value or dyn dispatch inside coroutine code: cannot pin the callee.
                    self.co_state = 2;
                    return;
                }
                if marked[t as usize] == 0 {
                    marked.set(t as usize, 1);
                    while d_start[m_of + 1] as usize <= t as usize {
                        m_of += 1;
                    }
                    while d_start[m_of] as usize > t as usize {
                        m_of -= 1;
                    }
                    self.co_spans.index_mut(m_of).push(d_span[t as usize]);
                    if on[t as usize] == 0 {
                        on.set(t as usize, 1);
                        queue.push(t);
                    }
                }
            }
        }
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
    /// a call to a marked callee marks the decls enclosing the call site. A callee that cannot be
    /// pinned (a fn value, a dyn method) is cancellation-MASKED: the request stays
    /// pending across it and the next pinned cancellation point delivers the edge. Treating unknown
    /// callees as reaching would mark nearly every task-reachable body and put a probe after nearly
    /// every call.
    pub fn cancel_compute(self: &mut Self) {
        self.cancel_state = 1;
        self.cancel_marks.truncate(0);
        for _m in 0..self.modules.len() {
            self.cancel_marks.push(Set::<u64>::new());
        }
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
                if n.kind != NodeKind::NODE_CALL {
                    continue;
                }
                let cd = n.as_data.call;
                let mut t = DefId { module: 0, node: NODE_NONE };
                let ni32 = ni;
                switch a.call_info.get(&ni32) {
                    Some(v) => {
                        t = DefId { module: (*v >> 40) as ModuleId, node: (*v >> 8 & 0xFFFFFFFFu64) as NodeId };
                    },
                    _ => {},
                };
                if t.node == NODE_NONE {
                    t = a.resolution_def(cd.callee);
                }
                if t.node == NODE_NONE {
                    let ck = a.at_const(cd.callee).kind;
                    if ck == NodeKind::NODE_MEMBER {
                        t = a.resolution_def(a.at_const(cd.callee).as_data.member.member);
                    }
                }
                if t.node == NODE_NONE {
                    // Fn value or dyn dispatch: cancellation-masked.
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
            decls.push(row);
        }
        // Fixpoint over the call records. A record fires at most once: firing marks its enclosing
        // decls, and only a fresh mark can make another record's target newly reach acceptance.
        let mut fired = Vector::<u8>::new();
        for _i in 0..rec_m.len() {
            fired.push(0);
        }
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
    }

    /// Read-only view of module `mid`'s Ast for consumers outside the package (the Core IR lowerer).
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
        return atomic::load_u8(unsafe (self.sched.state.as_ptr() + it as usize), 1);
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
        atomic::store_u8(unsafe (self.sched.state.as_ptr() as *mut u8 + it as usize), st, 2);
    }

    /// Record the result-attributability verdict of function `node` of module `m` (`ItemSched.ret_attr`).
    pub fn set_item_ret_attr(self: &mut Self, m: ModuleId, node: NodeId, v: bool) {
        let it = self.item_of(m, node);
        if it == ITEM_NONE {
            return;
        }
        atomic::store_u8(
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
        return atomic::load_u8(unsafe (self.sched.ret_attr.as_ptr() + it as usize), 1);
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

    /// Find a module by its `::`-joined path; returns its ModuleId, or -1 if absent.
    pub fn find(self: &Self, path: str) i32 {
        for i in 0..self.modules.len() {
            if self.modules[i].path.as_str() == path {
                return i as i32;
            }
        }
        return -1;
    }

    // Add a module slot (taking ownership of `path`/`file`/`source`/`ast`) and return its id.
    fn add_module(self: &mut Self, path: String, file: String, source: String, ast: Ast, has_ast: bool) i32 {
        let id = self.modules.len() as i32;
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

    // DFS load: takes ownership of `mod_path` and `file_path`. Returns the module's id (or -1 if unreadable).
    // A module already loaded (an import cycle) resolves to its id: modules are parsed whole before
    // any resolution, so mutual imports need no special handling.
    // Load everything module `id` imports, depth-first, and return `id`.
    fn walk_children(self: &mut Self, id: i32, bootstrap_tags: bool, target: i32) i32 {
        // Collected BEFORE recursing: recursion pushes to self.modules, which may realloc and move this
        // module's by-value Ast, invalidating a live borrow. The dir-cache address is taken first for the same
        // reason: the cast releases the &mut immediately, and dir_cache is disjoint from modules.
        let dca = ((&mut self.dir_cache) as *mut DirCache) as usize;
        let mut child_paths = Vector::<String>::new();
        let mut child_files = Vector::<String>::new();
        {
            let ap = (&self.modules.at(id as usize).ast) as *const Ast;
            let src = self.modules.at(id as usize).source.as_str();
            let mut all_paths = Vector::<String>::new();
            let mut all_files = Vector::<String>::new();
            self.collect_imports(unsafe &*ap, src, dca, target, &mut all_paths, &mut all_files);
            // The dedupe belongs here and not in the collector: skipping an already-loaded module saves
            // resolve_import_file its filesystem probes, and a hot std/ffi module imported by many others
            // would otherwise be probed once per importer.
            for k in 0..all_paths.len() {
                if self.find(all_paths[k].as_str()) < 0 {
                    child_paths.push(String::from_str(all_paths[k].as_str()));
                    child_files.push(String::from_str(all_files[k].as_str()));
                }
            }
        }
        for k in 0..child_paths.len() {
            self.load_module(child_paths[k].as_str(), child_files[k].as_str(), bootstrap_tags, target);
        }
        return id;
    }

    // Every module `a` imports, as (module path, file path) pairs, plus the dependencies a sugar keyword
    // pulls in (`launch` -> the runtime, `select` -> the selector, `@blocking` -> the pool). NO dedupe against
    // what is already loaded: `load_module` applies that itself, because skipping an already-loaded module is
    // what saves `resolve_import_file` its filesystem probes.
    //
    // `a`/`src` come in as raw views because the caller holds them inside `self.modules` and cannot lend them
    // across a `&mut self` call; `dca` is the dir cache's address for the same reason (see `load_module`).
    fn collect_imports(
        self: &Self,
        a: &Ast,
        src: str,
        dca: usize,
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
                let mut gated_out = false;
                for k in 0..a.attrs.len() {
                    let at = a.attrs.at(k);
                    if at.owner == unsafe ids[i as usize] && at.kind == AttrKind::ATTR_PLATFORM as u8 && (at.arg >> target as u32 & 1u32) == 0 {
                        gated_out = true;
                    }
                    if at.owner == unsafe ids[i as usize] && at.kind == AttrKind::ATTR_ARCH as u8 && self.arch >= 0 && (at.arg >> self.arch as u32 & 1u32) == 0 {
                        gated_out = true;
                    }
                }
                if gated_out {
                    continue;
                }
                let parts = n.as_data.import_decl.path;
                let cp = join_parts(a, src, parts, "::");
                // Skip already-loaded modules here: resolve_import_file probes the filesystem (up to 3
                // path_exists per edge) only for load_module's own dedup to discard the result. A hot std/
                // ffi module imported by many modules would otherwise be re-probed once per importer.
                child_paths.push(cp);
                child_files.push(resolve_import_file(dca, root_dir, alt_root, std_root, a, src, parts));
            }
        }
        // Sugar-keyword dependency: the `launch` statement lowers to std::parallel::runtime::submit, so
        // pull that module in (transitively) ONLY when the keyword is used: a program that
        // never launches never loads the runtime. load_module dedups, so a duplicate push is harmless.
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
        let dca = ((&mut self.dir_cache) as *mut DirCache) as usize;
        let mut units = Vector::<PUnit>::new();
        units.push(
            PUnit {
                path: String::from_str(mod_path),
                file: String::from_str(file_path),
                source: String::new(),
                ast: Ast::new(0),
                ok: false,
                child_paths: Vector::<String>::new(),
                child_files: Vector::<String>::new(),
            },
        );
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
                self.collect_imports(unsafe &*ap, sp2, dca, target, &mut all_paths, &mut all_files);
                for c in 0..all_paths.len() {
                    let cp = all_paths[c].as_str();
                    if self.find(cp) >= 0 {
                        continue;
                    }
                    let mut seen = false;
                    for q in 0..units.len() {
                        if units.at(q).path.as_str() == cp {
                            seen = true;
                            break;
                        }
                    }
                    units.index_mut(k).child_paths.push(String::from_str(cp));
                    units.index_mut(k).child_files.push(String::from_str(all_files[c].as_str()));
                    if !seen {
                        units.push(
                            PUnit {
                                path: String::from_str(cp),
                                file: String::from_str(all_files[c].as_str()),
                                source: String::new(),
                                ast: Ast::new(0),
                                ok: false,
                                child_paths: Vector::<String>::new(),
                                child_files: Vector::<String>::new(),
                            },
                        );
                    }
                }
                all_paths.free();
                all_files.free();
            }
            next = wave_end;
        }
        let root9 = self.par_replay(&mut units, 0, bootstrap_tags, target);
        units.free();
        return root9;
    }

    // DFS in recorded import order over the parsed units: the id-assignment replay. Consumes
    // each unit's source/ast on first visit (later visits of the same path are find() hits).
    fn par_replay(self: &mut Self, units: &mut Vector<PUnit>, ui: usize, bootstrap_tags: bool, target: i32) i32 {
        {
            let ex = self.find(units.at(ui).path.as_str());
            if ex >= 0 {
                return ex;
            }
        }
        if !units.at(ui).ok {
            // The serial loader re-reads, re-parses, prints, and recurses its own children.
            let pth = String::from_str(units.at(ui).path.as_str());
            let fl = String::from_str(units.at(ui).file.as_str());
            let r = self.load_module_serial(pth.as_str(), fl.as_str(), bootstrap_tags, target);
            pth.free();
            fl.free();
            return r;
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
        let nkids = units.at(ui).child_paths.len();
        for c in 0..nkids {
            let cp = units.at(ui).child_paths.at(c).as_str();
            if self.find(cp) >= 0 {
                continue;
            }
            let mut ci: i64 = 0 - 1;
            for q in 0..units.len() {
                if units.at(q).path.as_str() == cp {
                    ci = q as i64;
                    break;
                }
            }
            if ci >= 0 {
                let _ = self.par_replay(units, ci as usize, bootstrap_tags, target);
            } else {
                let cf = String::from_str(units.at(ui).child_files.at(c).as_str());
                let cp2 = String::from_str(cp);
                let _ = self.load_module_serial(cp2.as_str(), cf.as_str(), bootstrap_tags, target);
                cp2.free();
                cf.free();
            }
        }
        return id;
    }

    fn load_module_serial(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        let existing = self.find(mod_path);
        if existing >= 0 {
            return existing;
        }

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

        return self.walk_children(id, bootstrap_tags, target);
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
            let mut n = unsafe self.module_ast_const(d.module).nodes.len();
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

    /// A method reference from inside a gated (demand-emitted) method body: deferred, so the callee
    /// is only marked used if the caller is ultimately emitted. Ids that do not fit the packed key
    /// fall back to a direct mark (conservative, never under-marks).
    pub fn record_method_edge(self: &mut Self, c: DefId, d: DefId) {
        if d.node == NODE_NONE {
            return;
        }
        if c.node == NODE_NONE || c.module as u32 >= 256 || c.node >= 16777216 || d.module as u32 >= 256 || d.node >= 16777216 {
            self.mark_method_used(d);
            return;
        }
        if self.method_used_get(d) {
            return;
        }
        let key = (c.module as u64 << 24 | c.node as u64) << 32 | d.module as u64 << 24 | d.node as u64;
        if !self.edge_seen.contains(&key) {
            self.edge_seen.insert(key);
            self.method_edges.push(key);
        }
    }

    // Cross-module name lookup.

    /// (Re)build the package declaration index: symbols, items, name maps, import adjacency, SCCs,
    /// and the LangItem table, in deterministic module and source order. Called through ensure_index
    /// on first lookup after loading; a module appended later (the LSP's batch load) triggers a full
    /// rebuild. Declaration names, spans, and imports are parse-final, so the result stays valid for
    /// the whole pipeline.
    pub fn build_index(self: &mut Self) {
        let n = self.modules.len();
        let mut idx = PkgIndex::new();
        idx.built_mods = n as u32;
        for m in 0..n {
            idx.mod_items.push(idx.items.len() as u32);
            idx.name_maps.push(Map::<u64, u32>::new());
            idx.mod_imports.push(idx.imports.len() as u32);
            if self.modules[m].has_ast {
                self.index_module(&mut idx, m as ModuleId);
            }
        }
        idx.mod_items.push(idx.items.len() as u32);
        idx.mod_imports.push(idx.imports.len() as u32);
        scc_build(n, &idx.imports, &idx.mod_imports, &mut idx.scc_of);
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
        // LangItem table: each fixed prelude hook resolved once. An unresolved hook (no std loaded,
        // or the name never interned) stays NODE_NONE.
        for li in 0..LI_COUNT_N {
            let names: []str = LI_NAMES;
            let s = idx.syms.find(names[li]);
            let mut hit = LookupHit { node: NODE_NONE, mid: 0 };
            if s != SYM_NONE {
                switch idx.pl_map.get(&(s as u64 * 2u64 + 1u64)) {
                    Some(v) => {
                        hit = LookupHit { node: (*v >> 32) as NodeId, mid: (*v & 0xFFFFFFFFu64) as ModuleId };
                    },
                    None => {},
                };
            }
            idx.lang_items.push(hit);
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
        switch self.idx.sig_of.get(&skey_mix(0, m as u64 << 32 | node as u64)) {
            Some(i) => {
                return self.idx.sigs.at((*i) as usize);
            },
            None => {},
        };
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
    fn index_decl(
        self: &mut Self,
        idx: &mut PkgIndex,
        mid: ModuleId,
        srcp: *const char,
        node: NodeId,
        name_node: NodeId,
        owner: ItemId,
        kind: ItemKind,
        is_public: bool,
        is_type: bool,
    ) {
        let ast = unsafe &*self.module_ast_const(mid);
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
            } else if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
                let kd = if n.kind == NodeKind::NODE_STRUCT {
                    ItemKind::IK_STRUCT;
                } else {
                    ItemKind::IK_ENUM;
                };
                self.index_decl(
                    idx,
                    mid,
                    srcp,
                    nid,
                    n.as_data.aggregate.name,
                    ITEM_NONE,
                    kd,
                    n.as_data.aggregate.is_public,
                    true,
                );
            } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
                self.index_decl(
                    idx,
                    mid,
                    srcp,
                    nid,
                    n.as_data.type_alias.name,
                    ITEM_NONE,
                    ItemKind::IK_TYPE_ALIAS,
                    n.as_data.type_alias.is_public,
                    true,
                );
            } else if n.kind == NodeKind::NODE_INTERFACE {
                self.index_decl(
                    idx,
                    mid,
                    srcp,
                    nid,
                    n.as_data.interface_def.name,
                    ITEM_NONE,
                    ItemKind::IK_INTERFACE,
                    n.as_data.interface_def.is_public,
                    true,
                );
            } else if n.kind == NodeKind::NODE_FUNCTION {
                self.index_decl(
                    idx,
                    mid,
                    srcp,
                    nid,
                    n.as_data.function.name,
                    ITEM_NONE,
                    ItemKind::IK_FUNCTION,
                    n.as_data.function.is_public,
                    false,
                );
            } else if n.kind == NodeKind::NODE_CONST {
                self.index_decl(
                    idx,
                    mid,
                    srcp,
                    nid,
                    n.as_data.const_def.name,
                    ITEM_NONE,
                    ItemKind::IK_CONST,
                    n.as_data.const_def.is_public,
                    false,
                );
            } else if n.kind == NodeKind::NODE_EXTERN_BLOCK {
                // `pub` raw bindings / opaque handles live one level down, inside the extern block;
                // they name package-level items exactly like top-level decls.
                let inner = n.as_data.extern_block.items;
                let iids = ast.list(inner);
                for j in 0..inner.len {
                    let iid = unsafe iids[j as usize];
                    let it = ast.at_const(iid);
                    if it.kind == NodeKind::NODE_FUNCTION {
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.function.name,
                            ITEM_NONE,
                            ItemKind::IK_FUNCTION,
                            it.as_data.function.is_public,
                            false,
                        );
                    } else if it.kind == NodeKind::NODE_TYPE_ALIAS {
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.type_alias.name,
                            ITEM_NONE,
                            ItemKind::IK_TYPE_ALIAS,
                            it.as_data.type_alias.is_public,
                            true,
                        );
                    } else if it.kind == NodeKind::NODE_CONST {
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.const_def.name,
                            ITEM_NONE,
                            ItemKind::IK_CONST,
                            it.as_data.const_def.is_public,
                            false,
                        );
                    } else if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
                        // An extern struct/union/enum names a type across module boundaries exactly
                        // like a top-level one; only its DEFINITION comes from the C header.
                        let kd = if it.kind == NodeKind::NODE_STRUCT {
                            ItemKind::IK_STRUCT;
                        } else {
                            ItemKind::IK_ENUM;
                        };
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.aggregate.name,
                            ITEM_NONE,
                            kd,
                            it.as_data.aggregate.is_public,
                            true,
                        );
                    }
                }
            } else if n.kind == NodeKind::NODE_EXTEND {
                // The extend itself anchors its associated items (owner links); it claims no name.
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
                let inner = n.as_data.extend_def.items;
                let iids = ast.list(inner);
                for j in 0..inner.len {
                    let iid = unsafe iids[j as usize];
                    let it = ast.at_const(iid);
                    if it.kind == NodeKind::NODE_FUNCTION {
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.function.name,
                            eid,
                            ItemKind::IK_METHOD,
                            it.as_data.function.is_public,
                            false,
                        );
                    } else if it.kind == NodeKind::NODE_CONST {
                        self.index_decl(
                            idx,
                            mid,
                            srcp,
                            iid,
                            it.as_data.const_def.name,
                            eid,
                            ItemKind::IK_ASSOC_CONST,
                            it.as_data.const_def.is_public,
                            false,
                        );
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
        mp.ensure_index();
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
        mp.ensure_index();
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
        mp.ensure_closure(mid);
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
        mp.ensure_index();
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
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION {
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

    // The module a concrete instance must be emitted in (re-homed to a by-value user-type arg, else the owner).
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

    /// Dependency-first module emit order: if module `a` full-monomorphizes a generic owned by `b` (re-homing a
    /// concrete instance to `a` itself), `b` must be emitted first. Kahn topo-sort with a lowest-id tiebreak;
    /// `order` is filled with `modules.len()` entries.
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
        let mut dep = Vector::<bool>::new();
        dep.resize_default(n);
        let aa = self.module_ast_const(a as ModuleId);
        let mut i: usize = 0;
        while i < aa.ninstances() {
            let it = *aa.used_instance(i);
            let bi = it.module as usize;
            if bi >= n || bi == a || dep[bi] {
                i = i + 1;
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe aa.type_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if concrete && self.instance_home_in(a as ModuleId, &it) == a as ModuleId {
                dep[bi] = true;
                out.push(bi as ModuleId);
            }
            i = i + 1;
        }
        i = 0;
        while i < unsafe aa.method_insts.len() {
            let miinst = unsafe aa.method_insts[i].instance;
            let y = *aa.type_at(miinst);
            if y.kind != TypeKind::TYPE_INSTANCE {
                i = i + 1;
                continue;
            }
            let bi = aa.instance(y.as_data.inst).module as usize;
            if bi >= n || bi == a || dep[bi] {
                i = i + 1;
                continue;
            }
            dep[bi] = true;
            out.push(bi as ModuleId);
            i = i + 1;
        }
        i = 0;
        while i < unsafe aa.mono.len() {
            let mnode = unsafe aa.mono[i].node;
            if aa.at_const(mnode).kind != NodeKind::NODE_CALL {
                i = i + 1;
                continue;
            }
            let callee_id = aa.at_const(mnode).as_data.call.callee;
            let ck = aa.at_const(callee_id).kind;
            let fd = if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let e = aa.at_const(callee_id).as_data.specialization.expression;
                aa.resolution_def(e);
            } else {
                aa.resolution_def(callee_id);
            };
            let bi = fd.module as usize;
            if fd.node == NODE_NONE || bi >= n || bi == a || dep[bi] {
                i = i + 1;
                continue;
            }
            if !self.modules[bi].has_ast {
                i = i + 1;
                continue;
            }
            let bast = self.module_ast_const(fd.module);
            if bast.at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                i = i + 1;
                continue;
            }
            dep[bi] = true;
            out.push(bi as ModuleId);
            i = i + 1;
        }
    }

    /// Size `emit_deps` for every module (before a parallel borrow frontier records rows).
    pub fn emit_deps_reserve(self: &mut Self) {
        self.emit_deps.truncate(0);
        for _ in 0..self.modules.len() {
            self.emit_deps.push(Vector::<ModuleId>::new());
        }
    }

    /// Record module `a`'s emission dependency row while its body syntax is live.
    pub fn record_emit_deps(self: &mut Self, a: usize) {
        let mut row = replace(self.emit_deps.index_mut(a), Vector::<ModuleId>::new());
        self.emit_dep_row(a, &mut row);
        *self.emit_deps.index_mut(a) = row;
    }

    pub fn emit_order(self: &Self, order: &mut Vector<ModuleId>) {
        let n = self.modules.len();
        if n == 0 {
            return;
        }
        let mut done = Vector::<bool>::new();
        done.resize_default(n);
        let mut dep = Vector::<bool>::new();
        dep.resize_default(n * n);
        let mut indeg = Vector::<u32>::new();
        indeg.resize_default(n);
        let recorded = self.emit_deps.len() == n;
        let mut row = Vector::<ModuleId>::new();
        for a in 0..n {
            if !recorded {
                self.emit_dep_row(a, &mut row);
            }
            let r = if recorded {
                self.emit_deps.at(a);
            } else {
                &row;
            };
            for k in 0..r.len() {
                let bi = r[k] as usize;
                dep[a * n + bi] = true;
                indeg[a] = indeg[a] + 1;
            }
        }
        for kk in 0..n {
            let mut pick = n;
            let mut i: usize = 0;
            while i < n {
                if !done[i] && indeg[i] == 0 {
                    pick = i;
                    break;
                }
                i = i + 1;
            }
            if pick == n {
                i = 0;
                while i < n {
                    if !done[i] {
                        pick = i;
                        break;
                    }
                    i = i + 1;
                }
            }
            order.push(pick as ModuleId);
            done[pick] = true;
            for x in 0..n {
                if !done[x] && dep[x * n + pick] && indeg[x] > 0 {
                    indeg[x] = indeg[x] - 1;
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
        names.sort_by(|a: &String, b: &String| name_cmp(a, b));
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
                let id = self.load_module(modpath.as_str(), file.as_str(), false, target);
                if id >= 0 {
                    self.modules[id as usize].prelude = true;
                }
            }
        }
    }
}
