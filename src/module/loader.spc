// Package construction and module loading: reads the root module plus its transitive imports into
// per-module Asts, auto-imports the std prelude, and seeds the nominal builtin decls. Serves the
// package-level lookups every later stage relies on (O(1) public-decl name index, cached import
// closures). After typechecking, propagates concrete generic instances to their home modules
// (owner-emits, to a fixpoint) and computes the dependency-first module emit order for codegen.
import stdio;
import atomic;
import driver_shim as shim;
import std::platform::fs;
import lexer::token as tok;
import lexer::lexer as lexer;
import lexer::token_type as tt;
import ast::ast as *;
import ast::parser as parser;
import std::parallel::sync as psy;
import std::parallel::runtime as prt;
import graph::items as gitems;
import ir::layout as lay;
import ir::cpu_features as cf;
import ir::recursion as recur;
import target::table as tgt;
import utils::persist as *;
import driver::util as dutil;
import emit::rt_h as rth;
import utils::errors as errs;

/// Number of nominal builtin types; sizes Package.builtin_decls. Pinned to BuiltinType::BT_COUNT.
pub const BT_COUNT_N: usize = BuiltinType::BT_COUNT as usize;

/// One loaded module: its `::`-joined module path (the mangling/lookup key), the file it came from, its
/// source text and parsed Ast. The Ast is held by value, so `has_ast` records whether lex/parse succeeded.
@derive(Persist)
pub struct Module {
    pub path: String, // "std::string"; the root module is its file stem (owned)
    pub file: String, // filesystem path the source was read from (owned)
    pub source: String, // file contents (owned; span offsets index into it)
    /// `str_id(source)`: the content this build read, what the emit stamp, the prelude image and the
    /// per-TU cache record for the module.
    pub src_id: u64,
    /// The file's mtime from the stat taken before the read (`read_file_mt`); 0 when the source is not
    /// a file's.
    pub mtime: i64,
    pub ast: Ast, // parsed AST; after hir::lower runs it IS the module's HIR (desugared, resolved)
    pub has_ast: bool,
    pub prelude: bool, // part of the auto-imported std prelude
    /// The vector backend file (`std/simd/backend/<isa>.spc`): its entries render apart, so the
    /// module emits no unit of its own.
    pub backend: bool,
    /// The import root the file came from (`PKG_*`, or `PKG_VENDOR + k` for the k-th `vendor/<name>`):
    /// what `pub(package)` reaches.
    pub pkg: u16,
    /// What `pub(module)` reaches: the files whose path is this one or starts with it and `::` (the
    /// declaring file's path minus its last segment, the whole path for a directory index; `std` for the
    /// prelude). Empty: the whole package.
    pub scope: String,
    /// A directory imported without an index file: its source glob-imports every `.spc` file in it.
    pub implicit_index: bool,
}

/// `Module.pkg` values: std (the prelude, the runtime and `std::`), the `ffi/` bindings, the project (its
/// root, `src/`, `tests/`, `bench/`), then one per `vendor/<name>`.
pub const PKG_STD: u16 = 0;
pub const PKG_FFI: u16 = 1;
pub const PKG_PROJECT: u16 = 2;
pub const PKG_VENDOR: u16 = 3;

/// `lookup`'s asking module for a lookup the compiler makes itself: every exported item answers.
pub const FROM_ANY: u32 = 0xFFFFFFFF;

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
    /// `std::` paths that name a prelude file loaded before them under its `__std::` path (the batch
    /// `lint` and the LSP load the prelude first), and that module: `find` falls back to them, so an
    /// explicit import gets the prelude module, as `load_prelude` gives a file imported first.
    pub alias_path: Vector<String>,
    pub alias_id: Vector<u32>,
    /// Instruction set `@arch` items are gated against: 0 x86_64, 1 aarch64, 2 wasm32, -1 unknown.
    /// Defaults to the host the compiler runs on; the driver overwrites it for `--arch=`.
    pub arch: i32,
    /// The resolved CPU features of the build (`--target-feature`, `target-features`): the baseline of
    /// `arch` unless the driver sets them.
    pub features: cf::CpuFeatureSet,
    /// The vector width in bits the planner prefers where AVX-512 is enabled: 256 (the default) or 512.
    pub simd_width: u32,
    /// `--simd-dispatch` / `simd-dispatch`: `off`, or the x86-64 levels (comma-separated) each function
    /// with vector code gets a copy for, chosen at run time; empty: `x86-64-v3` (`build::dispatch_for`
    /// sets `off` for a profile at opt-level 0 or 1).
    pub simd_dispatch: String,
    /// The copies' feature sets: `simd_dispatch`'s levels beyond the build's, closed, by size (the
    /// load computes them). Empty off x86_64 and with `off`.
    pub simd_levels: Vector<cf::CpuFeatureSet>,
    /// The effective features of the `@target_feature` functions, joined (`check_feature_calls`): what
    /// some function of the program may plan with beyond `features`.
    pub fn_union: cf::CpuFeatureSet,
    /// The backend table: every `@simd_impl` entry by key, then by feature count, the largest first
    /// (built once every module is typed; `emit::simd_plan` reads it).
    pub simd_table: Vector<cf::SimdEntry>,
    /// The build runs under a memory checker (an address, memory or thread sanitizer in its C flags):
    /// the planner keeps the checked lane loop of every masked or gather access.
    pub mem_check: bool,
    /// The build makes a shared library: its code is position-independent (the C compile's `-fPIC`).
    pub pic: bool,
    /// The C compile's configuration (`bsys::build_cfg`): bit `k - BC_THREAD_SANITIZER` holds build
    /// constant `k`, except that the OVERFLOW_CHECKS bit is set where the profile wraps.
    pub build_cfg: u32,
    /// The settings the build-constant module spells and the early prune decides by: a `--test`
    /// build (TEST), the profile name (PROFILE; empty is `debug`), and the profile names a PROFILE
    /// comparison may name (empty: unchecked). The driver sets them before the platform filter.
    pub test_build: bool,
    pub profile: String,
    pub profiles: Vector<String>,
    /// The build-constant module (`__std::build`), -1 until the platform filter adds it; the
    /// target platform it spells.
    pub build_module: i32,
    pub build_target: i32,
    /// The runtime every program links (`std::rt::base`, loaded with the vector backend); -1 when the
    /// package has no std directory.
    pub rt_module: i32,
    /// The test runner a `--test` build links (`std::rt::test`, loaded with the runtime); -1 in any
    /// other build.
    pub rt_test: i32,
    /// The C library of a wasm build (`std::rt::libc` and `std::rt::libm`, loaded with the runtime): wasm
    /// has no system C library, and these call WASI directly; -1 for any other target.
    pub rt_libc: i32,
    pub rt_libm: i32,
    /// The traps of the native backends' vector code (`std::rt::lanes`), loaded with a vector; -1 else.
    pub rt_lanes: i32,
    /// The module the package was loaded from, whose top-level `main` is the program entry; -1 when
    /// the package has none (a batch lint, whose listed files `lint_set` marks as roots instead).
    pub root: i32,
    /// The user's root module: 0 when the root loads first, the first module after the prelude in a
    /// prelude-first build (`load_user`).
    pub root_module: u32,
    /// The `--bootstrap-tags` flag the ASTs were loaded under: gating changes item sets while
    /// leaving sources identical, so build caches keyed on sources must include it.
    pub bootstrap: bool,
    pub root_dir: String, // source root: the directory of the root file; imports resolve relative to it
    pub gen_root: String, // where codegen writes the emitted C tree: <build dir>/raw, set by the driver
    pub c_files: u64, // the `.c` files the emission left under gen_root (`run_package`), for the emit stamp
    pub cc: String, // the C compiler the command line or manifest named; empty = resolve as usual
    pub cstd: String, // the base C flags the command line named for a bare build (`--cstd`); empty = the default
    pub std_root: String, // second import search root (parent of std/); empty = none
    /// The project's manifest sets `std_internals = true`: its files see std's `pub(package)` items.
    pub std_internals: bool,
    /// The build emits the manifest's `[lib]` target: the project's exported functions are its API, so
    /// each is emitted whether or not the library calls it (`reach_roots`).
    pub lib_build: bool,
    /// The `vendor/<name>` packages in load order: `Module.pkg` is `PKG_VENDOR` plus the index.
    pub vendors: Vector<String>,
    pub alt_root: String, // optional search root between the project root and std (manifest src/ dir)
    pub ok: bool, // false if any read/parse/cycle error was reported during loading
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
    /// (`reach_solve`); everything else can never starve a worker, so its loops need no safepoint tick.
    pub co_state: u8,
    pub co_spans: Vector<Vector<u64>>,
    /// Per module: the decl spans of `co_spans` in std whose bodies run user code only through bound
    /// dispatch, so an instance ticks only when it binds a type that can reach user code (`co_inst_on`).
    pub co_inst: Vector<Vector<u64>>,
    /// The fn values `reach_solve` found (module << 32 | decl node): every closure but a coroutine
    /// entry's, every function named as a value outside std::parallel. The cancellation half reads them
    /// for `cancel_fnv`.
    pub co_fnv: Vector<u64>,
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
    /// The parallel type check's module write locks are on (`Ast::wl_sem`): the engine lock's
    /// holder (`wl_eng`, its task token) takes a module's lock in `module_ast_const`, and drops the
    /// locks it took (`wl_got`) with the engine lock (`wl_eng_end`).
    pub wl_on: bool,
    pub wl_eng: usize,
    pub wl_got: Vector<u32>,
    /// The emission's inline-candidate store (`ir::inline::InlineStore`), set for the emission's
    /// lifetime by `cemit_package`; null outside it.
    pub inl_store: *const void,
    /// The items of the extern blocks whose header is scoped, as `module << 32 | node`
    /// (`scope_extern_items`); empty outside an emission.
    pub xscoped: Set<u64>,
    /// The values of the integer constants of extern blocks with a header, as `module << 32 | node`, that a
    /// native build reads from the headers (`driver::emit::native_header_facts`); empty otherwise.
    pub extern_ints: Map<u64, i64>,
    /// The functions of extern blocks that only a C compile defines, as `module << 32 | node`, in a native
    /// build: the instruction set's intrinsics (`Isa.intrinsics`) and a header's `static` functions. Empty
    /// otherwise.
    pub c_fns: Set<u64>,
    /// The scalar class (`bindgen::SC_*`) of the opaque `@layout` types of extern blocks with a header, as
    /// `module << 32 | node`, in a native build: what the calling conventions pass them as.
    pub opaque_cls: Map<u64, u8>,
    /// The C header files those facts were read from (`extern_ints`, `c_fns`, `opaque_cls`): inputs of the
    /// emission.
    pub header_files: Vector<String>,
    /// Per module, the offsets where its source's lines start, for the locations of LIR
    /// (`driver::emit::lir_lines`); empty in a build that lowers no LIR.
    pub lines: Vector<Vector<u32>>,
    /// Whether the build writes native objects for its modules (`SC_NATIVE` on a target the native backend
    /// supports, in a build whose link takes objects); set by `driver::emit::run_package`.
    pub native: bool,
    /// Per module, in a native build: its function bodies render to C (`cemit::backends_of`). The others
    /// render no body: their native objects need none.
    pub nat_render: Vector<bool>,
    /// The paths of the modules whose bodies render in a native build though the backend would take them:
    /// the caller's input, and `run_package`'s output when it returns `RC_NATIVE_RETRY`.
    pub nat_retry: Vector<String>,
    /// The C dialect, the manifest's and the profile's C flags of a manifest build; empty for a bare build,
    /// whose dialect is `cstd`.
    pub cflags: String,
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
    /// has any resolution into module `to`, in either arena. The borrow stage fills it once
    /// (`mod_refs_row` per module), while every body is live and after the last resolution write (type check); from
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
    /// The batch driver frees it once the load is done.
    pub tok_scratch: Vector<tok::Token>,
    /// Import-resolution directory cache: each candidate search directory is scanned once (opendir/
    /// readdir) and its entry names cached, so resolve_import_file answers "does <dir>/<file> exist?" from
    /// memory instead of an fopen probe per candidate. Scales: a directory with N modules imported M times
    /// costs 1 scan, not M*<up to 3> fopens. A listing MISS still falls back to fopen (byte-identical vs the
    /// old path_exists even under case-insensitive filesystems).
    pub dir_cache: DirCache,
    /// The user closure `adopt_user` took from a `UserSpec`, which `load_user` replays.
    spec: PUnits,
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
    /// LSP: per module, the post-typecheck item edges of its last analysis
    /// (`graph::items::module_edges`), keyed by declaration nodes so they survive a rebuild of the
    /// item index: `key` names the target item (`module << 32 | node`), `owner` the declaration
    /// node of the module's item that names it. The unused-item lint reads them while the module's
    /// bodies are released. Indexed by module; shorter than the module table means "unrecorded".
    pub item_edges: Vector<Vector<RefEdge>>,
    /// LSP: per module, the borrow check an analysis still owes it (the module was analyzed again
    /// and its borrow records are not current). Its body syntax stays live until the check ran.
    pub bc_pending: Vector<bool>,
    /// LSP: the unbounded-recursion summaries of the borrow-checked modules, per module from its last
    /// borrow round (`ir::recursion::Summaries`).
    pub recur: recur::Summaries,
    /// LSP: per module, its reachability scan from its last analysis (`co_scan`; empty when the
    /// coroutine runtime is not loaded or the module was not typed), and whether one changed since
    /// the last `reach_solve` over them.
    pub reach_scans: Vector<ReachScan>,
    pub reach_stale: bool,
    /// LSP: the reachability the last solve over `reach_scans` gave (`driver::tuc::reach_fold`).
    pub reach_key: u64,
    /// LSP: the constant engine budgets of the build the analysis stands for (build.toml's
    /// `const-eval-steps` and `const-eval-memory`); 0 = the engine default.
    pub ce_steps: u32,
    pub ce_mem: u64,
    /// What the checked prelude stage left for the second one (`driver::emit::check_prelude`).
    pub carry: PreludeCarry,
}

/// The prelude stage's results the second stage's item schedule starts from: the prelude items'
/// resolution edges and post-typecheck edges (`graph::items` raw edges), and their readiness
/// states, result-attributability verdicts and dynamic evaluation edges. `items` 0: no prelude
/// stage ran (the one-stage pipeline).
@derive(Persist)
pub struct PreludeCarry {
    pub items: u32,
    /// The package runs the prelude stage: its analysis keeps its raw edges here.
    pub keep: bool,
    pub rs_edges: Vector<u64>,
    pub tc_edges: Vector<u64>,
    pub state: Vector<u8>,
    pub ret_attr: Vector<u8>,
    pub dyn_edges: Set<u64>,
}

extend ItemMeta as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &ItemMeta, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut ItemMeta, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend ItemSig as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &ItemSig, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut ItemSig, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend LookupHit as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &LookupHit, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut LookupHit, r: &mut Reader) {
        load_bytes(self, r);
    }
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

/// Parallel-table cache of directory listings for import resolution. `state[i]` is what `dir_listing`
/// gave for `dirs[i]`, `entries[i]` its sorted names; `heads` maps a directory hash to the newest index
/// with that hash, `next[i]` to the one before it (SYM_NONE ends the chain).
pub struct DirCache {
    pub dirs: Vector<String>,
    pub entries: Vector<Vector<String>>,
    pub state: Vector<u8>,
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
    pub vis: u8, // VIS_*
    pub is_type: bool, // occupies the type namespace in name lookup
}

static_assert(sizeof(ItemMeta) == 28, "ItemMeta must stay 28 bytes");

/// Package symbol interner: identifier bytes -> dense insertion-order SymbolId. The hash map only
/// FINDS an entry, identity is the dense `names` vector; same-hash names chain through `chain` and
/// every probe is verified byte-exact, so a 64-bit collision degrades to a short walk, never a wrong
/// answer. Built in deterministic module and source order by build_index.
@derive(Persist)
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
    SI_CANCEL_MENTER, // a destructor's masked region: open
    SI_CANCEL_MEXIT, // a destructor's masked region: close
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
    "cancel_mask_enter",
    "cancel_mask_exit",
];

/// The package declaration index: the immutable package interface built once after every module has
/// parsed (and rebuilt if a module is appended, e.g. the LSP's batch load). Owns the symbol table,
/// one ItemMeta per declaration (module order, source order), per-module name maps for O(1) lookup,
/// the resolved direct-import adjacency, and its strongly connected components.
@derive(Persist)
pub struct PkgIndex {
    pub syms: SymTab,
    pub items: Vector<ItemMeta>,
    pub mod_items: Vector<u32>, // modules+1 offsets into `items`
    pub name_maps: Vector<Map<u64, u32>>, // per module: sym*4 + is_type*2 + exported -> ItemId, first wins
    pub globs: Vector<ModuleId>, // the modules each module glob-imports, declaration order, per-module dedup
    pub mod_globs: Vector<u32>, // modules+1 offsets into `globs`
    pub imports: Vector<ModuleId>, // resolved direct imports, declaration order, per-module dedup
    pub mod_imports: Vector<u32>, // modules+1 offsets into `imports`
    pub scc_of: Vector<u32>, // module -> import-graph SCC id (completion order; deterministic)
    pub sugar_items: Vector<LookupHit>, // SugarItem -> std shim fn (node == NODE_NONE when absent)
    pub pl_map: Map<u64, u64>, // sym*2 + want_type -> node << 32 | module: every exported top-level prelude name, the first prelude module wins (prelude_lookup)
    /// Every top-level prelude declaration's name, public or not: the prelude's bare C symbols.
    pub pl_names: Set<SymbolId>,
    /// The `pl_names` that begin longer prelude C symbols: a type's, an interface's or a generic
    /// function's (`String__new`, `Vector__i32`, `replace__u64`). `Mangler::prelude_stem` reads them.
    pub pl_stems: Set<SymbolId>,
    /// With one program module besides the runtime, whose symbols take no module prefix: each of its
    /// top-level non-extern names that a top-level prelude declaration also has, so would spell the
    /// prelude's C symbol. The mangler escapes them (`Mangler::ident`). Empty with more user modules.
    pub shadow: Set<SymbolId>,
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
    /// The conformances by interface (see ensure_sigs): module << 32 | extend node of every extend in
    /// `exts` whose interface path resolves, grouped by interface, each group in `exts` order.
    /// `conf_of` maps skey_mix(0, interface module << 32 | node) to its group, start << 32 | end.
    pub confs: Vector<u64>,
    pub conf_of: Map<u64, u64>,
}

extend SymTab {
    /// The SymbolId already interned for `name`, or SYM_NONE. Byte-exact.
    @always_inline
    pub fn find(self: &Self, name: str) SymbolId {
        return switch self.index.get(&fnv(name)) {
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
        let h = fnv(name);
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
// Sort `key` ascending, `val` alongside, stably: one scan when the keys are in order already (node
// order is nearly source order), else a least-significant-digit radix sort, one counting pass of
// O(n + 256) per key byte that differs among the keys.
fn sort_spans(key: &mut Vector<u64>, val: &mut Vector<u32>) {
    let n = key.len();
    let mut sorted = true;
    let mut diff: u64 = 0;
    for i in 1..n {
        if key[i - 1] > key[i] {
            sorted = false;
        }
        diff = diff | key[i] ^ key[0];
    }
    if sorted {
        return;
    }
    let mut k2 = Vector::<u64>::new();
    let mut v2 = Vector::<u32>::new();
    k2.resize_default(n);
    v2.resize_default(n);
    let mut at = Array::<u32, 257>::new();
    for d in 0..8u64 {
        let sh = d * 8;
        if (diff >> sh & 0xFFu64) == 0 {
            continue;
        }
        for c in 0..257usize {
            at[c] = 0;
        }
        for i in 0..n {
            let b = (key[i] >> sh & 0xFFu64) as usize;
            at[b + 1] += 1;
        }
        for c in 0..256usize {
            at[c + 1] += at[c];
        }
        for i in 0..n {
            let b = (key[i] >> sh & 0xFFu64) as usize;
            k2.set(at[b] as usize, key[i]);
            v2.set(at[b] as usize, val[i]);
            at[b] += 1;
        }
        let kt = replace(key, k2);
        k2 = kt;
        let vt = replace(val, v2);
        v2 = vt;
    }
}

fn pin_callee(a: &Ast, ni: NodeId, callee: NodeId) DefId {
    switch a.call_info_of(ni) {
        Some(v) => {
            let t = DefId { module: (v >> 40) as ModuleId, node: (v >> 8 & 0xFFFFFFFFu64) as NodeId };
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
    if k != TypeKind::TYPE_STRUCT && k != TypeKind::TYPE_INSTANCE && k != TypeKind::TYPE_ENUM && k != TypeKind::TYPE_GENERIC && k != TypeKind::TYPE_MASK {
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

// The coroutine-reachability graph of `Package::reach_solve`: every function and closure declaration
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
    pub ix_start: Vector<usize>, // per module (+ sentinel): its first `ix` slot
    pub nb: Vector<usize>, // per module: the node count of its main arena (the dense offset of its body arena)
    pub on: Vector<u8>, // the decl runs on a coroutine (marked, or inside a marked decl)
    pub marked: Vector<u8>, // the decl's span is in the output
    pub queue: Vector<u32>,
    pub spans: Vector<Vector<u64>>, // the output, per module
    pub esc: Vector<u32>, // the fn values: every closure, every function named as a value outside std::parallel
    pub in_esc: Vector<u8>,
    pub escaped: bool,
    pub stdm: Vector<u8>, // per module: 0 user code, 1 std, 2 std::parallel
    // Per decl of std: whether its body can run user code (see `reach_solve`): 0 no, 1 only through
    // bound dispatch (its instances decide), 2 through a fn value or `dyn`.
    pub ureach: Vector<u8>,
    pub inst: Vector<Vector<u64>>, // the output's spans whose ticks the emitting instance decides
}

extend CoGraph {
    // The decl of module `m` declared at node `n`, or CO_NONE (also for a module without a scan).
    const fn decl_of(self: &Self, m: ModuleId, n: NodeId) u32 {
        let mut k = n as usize;
        if (n & NODE_BODY) != 0 {
            k = self.nb[m as usize] + (n & NODE_BODY_MASK) as usize;
        }
        if k >= self.ix_start[m as usize + 1] - self.ix_start[m as usize] {
            return CO_NONE;
        }
        let v = self.ix[self.ix_start[m as usize] + k];
        if v == 0 {
            return CO_NONE;
        }
        return v - 1;
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

// A coroutine record target (`ReachScan.r_tgt`) other than a declaration key: a call to a fn value
// nothing pins, and the interface methods of an operator's method name (the low 32 bits hash it).
const CO_TGT_ESC: u64 = 0xFFFFFFFFFFFFFFFFu64;
const CO_TGT_OP: u64 = 1u64 << 63;

// `ReachScan.s_par` bits: the call into std::parallel passes a fn value the tracker cannot pin; the
// call dispatches through a `dyn` receiver.
const CO_PAR_BAD: u8 = 1;
const CO_DYN: u8 = 2;

const fn def_key(d: DefId) u64 {
    return d.module as u64 << 32 | d.node as u64;
}

/// The inputs every module's reachability scan shares (`Package::co_scan`), resolved once.
pub struct ReachCtx {
    pub rt: bool, // std::parallel::runtime is loaded: without it nothing launches or cancels
    pub ent: Vector<u64>, // the coroutine entry APIs (`co_entries`)
    pub ent_p: Vector<u32>,
    pub acc: DefId, // runtime::cancel_accept; NODE_NONE: no cancellation analysis
    pub req: NodeId, // runtime::request_cancel
    pub tsh: NodeId, // runtime::try_shutdown
    pub task_mid: i32, // std::parallel::task, or -1
}

/// One module's part of the coroutine and cancellation reachability (`Package::reach_solve`): what
/// one scan of its nodes finds while its bodies and checked tables are live (`Package::co_scan`). A
/// target is a declaration key (`module << 32 | node`), so the scan of a module stays valid while the
/// module and the declarations it names keep their ids; the language server keeps one per module.
pub struct ReachScan {
    pub nb: u32, // nodes of the module arena
    pub nn: u32, // nodes of both arenas
    // The function and closure declarations, sorted by span start.
    pub d_span: Vector<u64>, // start << 32 | end
    pub d_node: Vector<u32>,
    pub d_parent: Vector<u32>, // the innermost enclosing declaration (an index here), or CO_NONE
    pub d_clo: Vector<u8>, // 1 for a closure
    pub d_need: Vector<u64>, // the parameters whose fn value the body calls or hands to std::parallel
    // The coroutine records, in site order: the declaration (an index here), the target (a
    // declaration key, CO_TGT_ESC or CO_TGT_OP), the call site (an index into `s_*`, or CO_NONE),
    // and whether the entry is checked.
    pub r_decl: Vector<u32>,
    pub r_tgt: Vector<u64>,
    pub r_site: Vector<u32>,
    pub r_chk: Vector<u8>,
    // Per call site: the parameters whose argument no need check accepts, the CO_PAR_BAD and CO_DYN
    // bits, and its run in `prop` (+ sentinel): parameter p << 8 | the caller's parameter q passed
    // for it, by ascending p.
    pub s_bad: Vector<u64>,
    pub s_par: Vector<u8>,
    pub s_prop: Vector<u32>,
    pub prop: Vector<u16>,
    pub seeds: Vector<u64>, // the coroutine entry arguments: declaration keys, CO_TGT_ESC when unpinned
    pub esc: Vector<u64>, // the functions named as values, in site order
    // The cancellation records: the declaration spans in node order, and per call the site span and
    // the target key, in node order, then the operator methods and the `Deref` hops.
    pub c_row: Vector<u64>,
    pub c_span: Vector<u64>,
    pub c_tgt: Vector<u64>,
    pub c_used: bool, // the module requests cancellation (only a module outside std)
}

extend ReachScan {
    pub fn new() ReachScan {
        return ReachScan {
            nb: 0,
            nn: 0,
            d_span: Vector::<u64>::new(),
            d_node: Vector::<u32>::new(),
            d_parent: Vector::<u32>::new(),
            d_clo: Vector::<u8>::new(),
            d_need: Vector::<u64>::new(),
            r_decl: Vector::<u32>::new(),
            r_tgt: Vector::<u64>::new(),
            r_site: Vector::<u32>::new(),
            r_chk: Vector::<u8>::new(),
            s_bad: Vector::<u64>::new(),
            s_par: Vector::<u8>::new(),
            s_prop: Vector::<u32>::new(),
            prop: Vector::<u16>::new(),
            seeds: Vector::<u64>::new(),
            esc: Vector::<u64>::new(),
            c_row: Vector::<u64>::new(),
            c_span: Vector::<u64>::new(),
            c_tgt: Vector::<u64>::new(),
            c_used: false,
        };
    }

    /// Heap bytes held (capacity).
    pub const fn retained_bytes(self: &Self) usize {
        return (self.d_span.capacity() + self.d_need.capacity() + self.r_tgt.capacity() + self.s_bad.capacity() + self.seeds.capacity() + self.esc.capacity() + self.c_row.capacity() + self.c_span.capacity() + self.c_tgt.capacity()) * 8 + (self.d_node.capacity() + self.d_parent.capacity() + self.r_decl.capacity() + self.r_site.capacity() + self.s_prop.capacity()) * 4 + self.prop.capacity() * 2 + self.d_clo.capacity() + self.r_chk.capacity() + self.s_par.capacity();
    }

    // The innermost declaration whose span covers `sp`, or CO_NONE (a site outside every
    // declaration, such as a const initializer, never runs on a coroutine).
    const fn decl_at(self: &Self, sp: tok::Span) u32 {
        let mut l: usize = 0;
        let mut h = self.d_span.len();
        while l < h {
            let mid = (l + h) / 2;
            if (self.d_span[mid] >> 32) as u32 <= sp.start {
                l = mid + 1;
            } else {
                h = mid;
            }
        }
        if l == 0 {
            return CO_NONE;
        }
        let mut d = (l - 1) as u32;
        while d != CO_NONE && (self.d_span[d as usize] & 0xFFFFFFFFu64) as u32 < sp.end {
            d = self.d_parent[d as usize];
        }
        return d;
    }

    // `decl_at` for a site near the one whose innermost declaration is `hint` (CO_NONE: none): `hint`
    // itself when it covers `sp` and the next declaration starts after `sp` (none inside `hint` can
    // cover it), else the search. Sites in node order mostly share their declaration.
    const fn decl_near(self: &Self, sp: tok::Span, hint: u32) u32 {
        if hint != CO_NONE {
            let hs = self.d_span[hint as usize];
            let nx = hint as usize + 1;
            if (hs >> 32) as u32 <= sp.start && sp.end <= (hs & 0xFFFFFFFFu64) as u32 && (nx >= self.d_span.len() || (self.d_span[nx] >> 32) as u32 > sp.start) {
                return hint;
            }
        }
        return self.decl_at(sp);
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
/// read-ahead sentinel); None when `path` is no regular file (a directory opens on Linux, and its size
/// reads as the largest offset) or on any I/O error.
pub fn read_file(path: str) Option<String> {
    let mut mt: i64 = 0;
    return read_file_mt(path, &mut mt);
}

/// `read_file`, and the file's mtime (`dutil::file_mtime`) into `mt` from the fstat taken before the read: a
/// later edit changes the mtime, so the pair vouches for the content read.
pub fn read_file_mt(path: str, mt: &mut i64) Option<String> {
    let opened = fs::open(path, fs::OpenOptions { read: true });
    if opened.is_err() {
        return Option::<String>::None;
    }
    let mut f = opened.unwrap();
    let md = f.metadata();
    if md.is_err() {
        return Option::<String>::None;
    }
    let m = md.unwrap();
    if m.kind != fs::FileKind::File {
        return Option::<String>::None;
    }
    *mt = dutil::mtime_s(m.modified_ns);
    // Read straight into the result, pre-sized to content + read-ahead padding so pad_nul does not
    // reallocate, then append lexer::SOURCE_PAD trailing NUL bytes PAST len (len stays n): a read-ahead
    // sentinel the lexer relies on to over-read safely (see lexer::SOURCE_PAD).
    let sz = m.size as usize;
    let mut out = String::with_capacity(sz + lexer::SOURCE_PAD);
    let n = f.read_full(unsafe SliceMut::<u8> { ptr: out.spare_mut(sz), len: sz });
    if n.is_err() || f.close().is_err() {
        return Option::<String>::None;
    }
    out.advance_len(n.unwrap());
    out.pad_nul(lexer::SOURCE_PAD);
    return Option::<String>::Some(out);
}

/// The source of module `path` read from `file`: the file's text (`read_file_mt`), or for an implicit
/// directory index (`file` is the directory and a '/'), one glob import of `path::<stem>` per `.spc` file
/// directly in the directory whose stem is an identifier, in name order. Subdirectories stay modules of
/// their own. `id` takes the identity (`str_id`) of the text read from `file`.
pub fn read_module(path: str, file: str, mt: &mut i64, id: &mut u64) Option<String> {
    if path == "__std::target" {
        // The target table is the source of the build-setting enums: the file serves only releases that
        // predate the table, and its text is what a cache records.
        let disk = read_file_mt(file, mt);
        if disk.is_none() {
            return disk;
        }
        *id = dutil::str_id(disk.unwrap().as_str());
        return Option::<String>::Some(target_module_source());
    }
    if !file.ends_with("/") {
        let t = read_file_mt(file, mt);
        if let Some(x) = &t {
            *id = dutil::str_id(x.as_str());
        }
        return t;
    }
    let mut names = Vector::<String>::new();
    if dir_listing(file.slice(0, file.len() - 1), &mut names) != DIR_LISTED {
        return Option::<String>::None;
    }
    let mut out = String::new();
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        if !n.ends_with(".spc") || !ident_text(n.slice(0, n.len() - 4)) {
            continue;
        }
        out.push_str("import ");
        out.push_str(path);
        out.push_str("::");
        out.push_str(n.slice(0, n.len() - 4));
        out.push_str(" as *;\n");
    }
    *id = dutil::str_id(out.as_str());
    out.pad_nul(lexer::SOURCE_PAD);
    return Option::<String>::Some(out);
}

// The source of std's `target` module: `Platform` and `Arch` with one variant per name of the target
// table's `@platform` and `@arch` axes, in mask-bit order, and `Endian`.
fn target_module_source() String {
    let mut out = String::from_str(
        "// The build-setting enums, built by the compiler from its target table. The compiler defines the\n// constants `PLATFORM: Platform`, `ARCH: Arch` and `ENDIAN: Endian` from its flags; the variant order is\n// the bit order of `@platform` and `@arch`.\n\n/// An operating system target: the names `@platform(...)` accepts.\npub enum Platform {\n",
    );
    for is_isa in [false, true] {
        if is_isa {
            out.push_str("}\n\n/// An instruction set: the names `@arch(...)` accepts.\npub enum Arch {\n");
        }
        let vs = tgt::axis_variants(is_isa);
        for i in 0..vs.len() {
            out.push_str("    ");
            out.push_str(vs[i]);
            out.push_str(",\n");
        }
    }
    out.push_str("}\n\n/// The byte order of the target.\npub enum Endian {\n    Little,\n    Big,\n}\n");
    out.pad_nul(lexer::SOURCE_PAD);
    return out;
}

// Whether `s` spells an identifier: a letter or '_', then letters, digits and '_'.
const fn ident_text(s: str) bool {
    for i in 0..s.len() {
        let c = s.byte_at(i);
        let alpha = c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_';
        if !alpha && (i == 0 || c < b'0' || c > b'9') {
            return false;
        }
    }
    return s.len() != 0;
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

/// Returns a new string containing `a`/`b`
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
        let h = fnv(dir);
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
        let st = dir_listing(dir, &mut names);
        self.heads.insert(h, self.dirs.len() as u32);
        self.next.push(head);
        self.dirs.push(String::from_str(dir));
        self.entries.push(names);
        self.state.push(st);
        return self.dirs.len() - 1;
    }
    // Order the directories by name, rebuilding the hash chains.
    fn sort(self: &mut Self) {
        let n = self.dirs.len();
        let mut ix = Vector::<u32>::with_capacity(n);
        for i in 0..n {
            ix.push(i as u32);
        }
        ix.sort_by(|a: &u32, b: &u32| self.dirs[(*a) as usize].cmp(&self.dirs[(*b) as usize]));
        let mut d = DirCache {};
        for j in 0..n {
            let i = ix[j] as usize;
            let h = fnv(self.dirs[i].as_str());
            d.next.push(
                switch d.heads.get(&h) {
                    Some(v) => *v,
                    None => SYM_NONE,
                },
            );
            d.heads.insert(h, j as u32);
            d.dirs.push(replace(self.dirs.index_mut(i), String::new()));
            d.entries.push(replace(self.entries.index_mut(i), Vector::<String>::new()));
            d.state.push(self.state[i]);
        }
        *self = d;
    }
    /// Whether `dir` is a directory that lists.
    pub fn listed(self: &mut Self, dir: str) bool {
        let i = self.index_of(dir);
        return self.state[i] == DIR_LISTED;
    }
    /// Does `path` (a <dir>/<file>) exist? Answered from the cached listing; a listing miss (dir present but
    /// the name not listed) falls back to fopen so the result matches path_exists exactly, incl. case-
    /// insensitive filesystems. A missing directory is authoritative (fopen would fail too), saving the probe;
    /// a directory that exists but does not list asks fopen.
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
        if self.state[idx] == DIR_ABSENT {
            return false;
        }
        if self.state[idx] == DIR_UNREAD {
            return path_exists(path);
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
/// The source of item `n` with its visibility modifier, which its span starts after.
const fn item_span(src: str, n: &Node) tok::Span {
    let v = node_vis(n);
    let mut i = n.span.start as usize;
    while i > 0 && (src.byte_at(i - 1) == b' ' || src.byte_at(i - 1) == b'\t') {
        i -= 1;
    }
    let t = vis_text(v).trim();
    if v == VIS_PRIVATE || i < t.len() || src.slice(i - t.len(), i) != t {
        return n.span;
    }
    return tok::Span { start: (i - t.len()) as u32, end: n.span.end };
}

/// `dir_listing` results: the directory listed, does not exist (nothing under it does), or exists but
/// does not list (no read permission, no descriptor left): only an open of a file under it tells.
pub const DIR_ABSENT: u8 = 0;
pub const DIR_LISTED: u8 = 1;
pub const DIR_UNREAD: u8 = 2;

/// The entry names of `dir`, sorted, into `names`, and whether it listed (`DIR_LISTED`, `DIR_ABSENT`,
/// `DIR_UNREAD`). What `DirCache` answers from, and what the prelude image checks its directories against.
pub fn dir_listing(dir: str, names: &mut Vector<String>) u8 {
    let opened = fs::read_dir(dir);
    if opened.is_err() {
        if opened.unwrap_err().kind == IoErrorKind::NotFound {
            return DIR_ABSENT;
        }
        return DIR_UNREAD;
    }
    let mut d = opened.unwrap();
    // Bounded by the entries of the directory; a read error ends the listing, as the end does.
    while let Some(Ok(e)) = d.next() {
        names.push(String::from_str(e.name));
    }
    names.sort();
    return DIR_LISTED;
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
    // Last, a directory without an index file: an implicit index (`read_module`), named by the directory
    // and a '/'.
    for r in [root_dir, alt_root, std_root] {
        if !r.is_empty() {
            let f = module_file_path(r, ast, src, parts);
            let d = f.as_str().slice(0, f.len() - 4);
            if dc.listed(d) {
                let mut out = String::from_str(d);
                out.push_byte(b'/');
                return out;
            }
        }
    }
    return root_rel;
}

/// Whether every import of the module in file `path` names a file a load rooted at `root_dir` (alt
/// root `alt_root`, std/ in `std_dir`) finds, as `resolve_import_file` searches; true when the file
/// does not read, lex or parse (the load reports it).
pub fn imports_resolve(path: str, root_dir: str, alt_root: str, std_dir: str) bool {
    let r = read_file(path);
    if r.is_none() {
        return true;
    }
    let mut src = r.unwrap();
    let pr = parse_source_q(&mut src, path, false, Vector::<tok::Token>::new(), true);
    if !pr.ok {
        return true;
    }
    let a = &pr.ast;
    let mut dc = DirCache {};
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let n = a.at_const(unsafe a.list(items)[i as usize]);
        if n.kind == NodeKind::NODE_IMPORT {
            let f = resolve_import_file(
                &mut dc,
                root_dir,
                alt_root,
                dirname_of(std_dir),
                a,
                src.as_str(),
                n.as_data.import_decl.path,
            );
            if !f.as_str().ends_with("/") && !dc.exists(f.as_str()) {
                return false;
            }
        }
    }
    return true;
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
    let vectors = lx.vectors;
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
    out.names_vectors = vectors;
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

// The instruction set and features of every package `Package::new` makes; arch -1: the host's. The
// lint driver sets them from `--arch` and `--target-feature` before its loads.
static mut G_ARCH: i32 = -1;
static mut G_FEATURES: cf::CpuFeatureSet = cf::CpuFeatureSet { w: [0, 0] };

/// Set the instruction set and features of the packages loaded from now on.
pub fn set_load_target(arch: i32, features: cf::CpuFeatureSet) {
    unsafe G_ARCH = arch;
    unsafe G_FEATURES = features;
}

/// Set the worker count for parallel module loading (1 = serial; 0 = one per CPU) before the first
/// load. It is the task pool's worker count too: the load launches the pool's first tasks, and the
/// analysis that follows runs on the same pool.
pub fn set_load_jobs(j: u32) {
    unsafe G_LOAD_JOBS = j;
    if j != 1 {
        // Compiler tasks recurse deeply (parser, checker); reserve thread-sized task stacks
        // BEFORE the pool's first launch (a later call is ignored), as the worker count.
        prt::set_stack_size(8usize << 20);
        prt::set_worker_count(j as usize);
    }
}

// One speculative parse unit: filled by a worker task; imports are collected and resolved by the
// coordinator as each unit finishes (the dir cache is a serial memo), and ids are assigned afterwards
// by a serial DFS replay, so module identity is byte-for-byte the recursive loader's.
pub struct PUnit {
    pub path: String,
    pub file: String,
    pub source: String,
    pub src_id: u64,
    pub mtime: i64,
    pub ast: Ast,
    pub ok: bool,
    pub resolved: bool, // `file` is what resolve_import_file gives for `path`
    pub child_paths: Vector<String>,
    pub child_files: Vector<String>,
    pub child_offs: Vector<u32>, // where each import is written (IMPORT_OFF_NONE: a keyword's dependency)
    pub log: String, // the errors its imports gave (`std_shadowed`), printed when it gets its id
    pub next: u32, // the previous unit whose path hashes alike, or SYM_NONE
}

// The units of one parallel load, each in a box of its own so a task's unit stays in place while the
// vector grows, and `heads`: a path hash -> the newest unit with that hash.
pub struct PUnits {
    pub units: Vector<Box<PUnit>>,
    pub heads: Map<u64, u32>,
}

extend PUnits {
    // Append the unit for `path`, read from `file`; `resolved` as PUnit.resolved.
    fn push(self: &mut Self, path: str, file: str, resolved: bool) {
        let h = fnv(path);
        let next = switch self.heads.get(&h) {
            Some(u) => *u,
            None => SYM_NONE,
        };
        self.heads.insert(h, self.units.len() as u32);
        self.units.push(
            Box::<PUnit>::new(
                PUnit {
                    path: String::from_str(path),
                    file: String::from_str(file),
                    source: String::new(),
                    src_id: 0,
                    mtime: 0,
                    ast: Ast::new(0),
                    ok: false,
                    resolved: resolved,
                    child_paths: Vector::<String>::new(),
                    child_files: Vector::<String>::new(),
                    child_offs: Vector::<u32>::new(),
                    log: String::new(),
                    next: next,
                },
            ),
        );
    }

    // The index of the unit for `path`, or `units.len()`.
    fn find(self: &Self, path: str) usize {
        let mut u = switch self.heads.get(&fnv(path)) {
            Some(h) => *h,
            None => SYM_NONE,
        };
        while u != SYM_NONE {
            if self.units.at(u as usize).path.as_str() == path {
                return u as usize;
            }
            u = self.units.at(u as usize).next;
        }
        return self.units.len();
    }

    // The parse task of unit `k`, which reports to `done`.
    const fn task(self: &mut Self, k: usize, tags: bool, done: *const PDone) PParse {
        return PParse { u: self.units.index_mut(k).deref_mut(), k: k as u32, tags: tags, done: done };
    }
}

// The units whose parse tasks finished, in the order they finished, for the discovery's coordinator.
struct PDone {
    pub m: psy::Mutex<Vector<u32>>,
    pub cv: psy::Condvar,
}

// One module on the serial loader's depth-first stack: its unloaded imports and the next to load.
// The offset of an import a keyword implies (`launch`, `select`, `parallel for`, `@blocking`): it is
// written nowhere.
const IMPORT_OFF_NONE: u32 = 0xFFFFFFFF;

struct LoadFrame {
    pub owner: i32, // the importing module
    pub paths: Vector<String>,
    pub files: Vector<String>,
    pub offs: Vector<u32>, // where each import is written (IMPORT_OFF_NONE: a keyword's dependency)
    pub next: usize,
}

struct PParse {
    pub u: *mut PUnit,
    pub k: u32,
    pub tags: bool,
    pub done: *const PDone,
}

// The unit is boxed, so it stays in place for the task's lifetime, and each task owns exactly one unit;
// the coordinator keeps `done` until every task has finished.
unsafe extend PParse as Send {}

/// A user closure read and parsed while the prelude stage checks (`Package::spec_user`): its units, and
/// the package it loads against, a copy of the prelude's module table, which holds its dir cache.
pub struct UserSpec {
    pub v: Package,
    pub units: PUnits,
    pub wg: psy::WaitGroup,
}

extend UserSpec {
    /// A spec that loads nothing.
    pub fn new() Box<UserSpec> {
        return Box::<UserSpec>::new(UserSpec { v: Package::new(), units: PUnits {}, wg: psy::WaitGroup::new() });
    }

    /// Wait for the tasks of the load.
    pub fn join(self: &Self) {
        self.wg.wait_masked();
    }
}

struct SpecTask {
    pub s: *mut UserSpec,
    pub target: i32,
}

// The spec is boxed and joined before it drops; until then only the task reaches its package.
unsafe extend SpecTask as Send {}

// Parse the unit of `t`, then report it to the coordinator.
fn par_parse_task(t: PParse) {
    par_parse_one(t);
    let d = unsafe &*t.done;
    let mut g = d.m.lock();
    g.get_mut().push(t.k);
    d.cv.notify_one();
}

fn par_parse_one(t: PParse) {
    let u = unsafe &mut *t.u;
    switch read_module(u.path.as_str(), u.file.as_str(), &mut u.mtime, &mut u.src_id) {
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

/// The real path of file `path`, or empty when it does not resolve.
pub fn real_path_of(path: str) String {
    return fs::realpath(path).unwrap_or(String::new());
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
    return package_load_prelude_as(root_dir, alt_dir, std_dir, target, false, overlay_files, overlay_texts);
}

/// `package_load_prelude` for a test build when `test_build` (the TEST build constant).
pub fn package_load_prelude_as(
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    target: i32,
    test_build: bool,
    overlay_files: Vector<String>,
    overlay_texts: Vector<String>,
) Package {
    let mut p = package_base(root_dir, alt_dir, std_dir, overlay_files, overlay_texts);
    p.test_build = test_build;
    p.load_prelude(std_dir, target, false);
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
/// recursion. The source lexes first, as a real build loads its root before the prelude, so whether it
/// names a vector decides the vector backend; the module is appended LAST, after the prelude: the user
/// module is always `p.modules.len() - 1`. Used by tests.
pub fn package_from_source(src: str, std_dir: str, target: i32) Package {
    return package_from_source_arch(src, std_dir, target, unsafe shim::sc_host_arch());
}

/// `package_from_source` for instruction set `arch` (loader arch codes) with its baseline features.
pub fn package_from_source_arch(src: str, std_dir: str, target: i32, arch: i32) Package {
    let mut p = prelude_package_arch(std_dir, target, arch, source_names_vectors(src));
    p.add_source_module(src, target);
    return p;
}

/// Whether in-memory source `src` names a vector (`Ast.names_vectors`), which decides whether its
/// prelude loads the vector backend; false when it does not lex.
pub fn source_names_vectors(src: str) bool {
    let mut source = String::from_str(src);
    let mut lx = lexer::Lexer::new(&mut source, "<harness>");
    lx.scan_tokens();
    return !lx.has_errors() && lx.vectors;
}

/// The package `package_from_source_arch` builds before its source module joins: the std prelude for
/// `target` and instruction set `arch`, with the vector backend when `vectors` (the source names a
/// vector). `Package::add_source_module` appends the source.
pub fn prelude_package_arch(std_dir: str, target: i32, arch: i32, vectors: bool) Package {
    let mut p = package_base(".", "", std_dir, Vector::<String>::new(), Vector::<String>::new());
    p.arch = arch;
    p.features = tgt::baseline(target, arch);
    p.load_prelude(std_dir, target, vectors);
    p.seed_core();
    p.bind_types();
    p.platform_filter(target);
    return p;
}

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
            out.push(fnv(src.slice(st, i)));
        }
    }
}

const fn bc_name_byte(c: u8) bool {
    return c == b'_' || c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9';
}

/// Whether module `path` is part of the runtime: std::parallel, its platform substrate `sc_runtime`, and
/// the runtime every program links (`std::rt`). Their loops never tick and their calls carry no
/// cancellation edge of a task: they hold spinlocks, OS locks and signal handlers that a preemption or an
/// unwind must not cross.
pub const fn runtime_path(path: str) bool {
    return path.starts_with("std::parallel") || path.starts_with("std::rt::") || path == "sc_runtime";
}

/// The final path component of `path` (a view into it): "dir/std/string.spc" -> "string.spc".
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
const fn pub_depth(batch: &TypePool, depth: &Vector<u32>, b: usize) u32 {
    let y = batch.at(b);
    let k = y.kind;
    let mut d: u32 = 0;
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        d = pub_child_depth(depth, y.as_data.elem);
    } else if y.arr_like() {
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
    } else if y.arr_like() {
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
    } else if y.arr_like() {
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
    } else if y.arr_like() {
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
        k.w[10] = it.lts;
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

/// The variance of an aggregate's parameters, for `Package::lt_walk`.
pub interface SlotVariance {
    /// The variance (`V_*`) of slot `i` (its lifetime parameters, then its type parameters) of
    /// declaration `d` of module `m`.
    fn slot_variance(self: &mut Self, m: ModuleId, d: NodeId, i: u32) u32;
}

/// Every slot invariant: for a walk that reads only positions and reference flags.
pub struct Invariant {}

extend Invariant as SlotVariance {
    fn slot_variance(self: &mut Self, m: ModuleId, d: NodeId, i: u32) u32 {
        return V_INVARIANT;
    }
}

// Flags `f` of a position under a slot of variance `v`: a bivariant slot (one its declaration does
// not use) counts as invariant.
const fn ltf_vary(f: u8, v: u32) u8 {
    if (f & LTF_INV) != 0 || v != V_COVARIANT && v != V_CONTRAVARIANT {
        return f & ~LTF_CONTRA | LTF_INV;
    }
    if v == V_CONTRAVARIANT {
        return f ^ LTF_CONTRA;
    }
    return f;
}

/// Whether C unit `rel` of a generated tree (`std/rt/libc.c`, `std/rt/libm__inst.c`, a shard
/// `std/rt/libc__p1.c`) belongs to wasm's C library (`Package::is_libc`). It compiles with
/// `-fno-builtin`, as a C library compiles: its functions implement `memset`, `calloc` and the others, so
/// the C compiler must not turn their code into calls of those functions. A function attribute cannot
/// say it: clang ignores `no_builtin` on a definition that a call in its unit precedes.
pub const fn libc_unit(rel: str) bool {
    for stem in ["std/rt/libc", "std/rt/libm"] {
        if rel.starts_with(stem) {
            let rest = rel.slice(stem.len(), rel.len());
            if rest == ".c" || rest.starts_with("__") {
                return true;
            }
        }
    }
    return false;
}

extend Package {
    /// Whether module `m` is a runtime module: the runtime every program links, a test build's runner, or
    /// wasm's C library. None is a program module: its symbols always take their module prefix, it shadows
    /// no name, its allocations are not tracked, and its extern headers stay out of the forward header.
    pub const fn is_rt(self: &Self, m: i32) bool {
        return m >= 0 && (m == self.rt_module || m == self.rt_test || self.is_libc(m));
    }

    /// Whether module `m` is wasm's C library (`std::rt::libc` or `std::rt::libm`): its units compile
    /// alone, with `-fno-builtin` (`libc_unit`).
    pub const fn is_libc(self: &Self, m: i32) bool {
        return m >= 0 && (m == self.rt_libc || m == self.rt_libm);
    }

    /// The number of lifetime parameters declaration `d` of module `m` declares (`a` is the
    /// reading module's tree, whose tables may not be in the module table yet).
    pub fn decl_nlt(self: &Self, a: &Ast, m: ModuleId, d: NodeId) u32 {
        if d == NODE_NONE {
            return 0;
        }
        if m == a.module {
            return a.lifetimes_of(d).len;
        }
        return self.modules.at(m as usize).ast.lifetimes_of(d).len;
    }

    /// Append the flags (`LTF_*`) of the lifetime positions of type `t` (read through `a`) in walk
    /// order: a reference, a slice and a borrowed `dyn` hold one ahead of what they point at; a
    /// struct, an enum, an instance and an interface `dyn` hold one per lifetime parameter of their
    /// declaration, ahead of their type arguments'; a raw pointer and an array hold their element's.
    /// A function type (or `dyn fn`) binds its own and holds one per lifetime it takes from outside
    /// it (`sig_outer`). `f` holds the flags inherited from above; `v` gives the variance of an
    /// aggregate's parameters (an interface's are invariant).
    pub fn lt_walk<V: SlotVariance>(self: &Self, a: &Ast, t: TypeId, f: u8, out: &mut Vector<u8>, depth: u32, v: &mut V) {
        if t == TYPE_NONE || depth > 16 {
            return;
        }
        let y = *a.type_at(t);
        let k = y.kind;
        if k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
            out.push(f);
            let mut g = f | LTF_REF | LTF_BEHIND;
            if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                g = g | LTF_INV;
            }
            self.lt_walk(a, y.as_data.elem, g, out, depth + 1, v);
        } else if k == TypeKind::TYPE_POINTER {
            self.lt_walk(a, y.as_data.elem, f | LTF_INV | LTF_REF | LTF_BEHIND, out, depth + 1, v);
        } else if y.arr_like() {
            self.lt_walk(a, y.as_data.arr.elem, f, out, depth + 1, v);
        } else if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_ENUM {
            for i in 0..self.decl_nlt(a, y.module, y.as_data.decl) {
                out.push(ltf_vary(f, v.slot_variance(y.module, y.as_data.decl, i)) | LTF_BEHIND);
            }
        } else if y.fn_sig() {
            self.lt_outer(a, &y, f, out, depth, v);
        } else if k == TypeKind::TYPE_DYN || k == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            let mut g = f;
            if k == TypeKind::TYPE_DYN {
                g = g | LTF_BEHIND;
                if y.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 {
                    out.push(f);
                    g = g | LTF_REF;
                }
                if it.decl == NODE_NONE {
                    let s = a.dyn_fn_sig(&y);
                    if s != TYPE_NONE {
                        self.lt_outer(a, a.type_at(s), g, out, depth, v);
                    }
                    return;
                }
                g = g | LTF_INV;
            }
            let nlt = self.decl_nlt(a, it.module, it.decl);
            for i in 0..nlt {
                out.push(ltf_vary(g, v.slot_variance(it.module, it.decl, i)) | LTF_BEHIND);
            }
            for i in 0..it.n {
                let w = ltf_vary(g, v.slot_variance(it.module, it.decl, nlt + i));
                self.lt_walk(a, unsafe it.args[i as usize], w, out, depth + 1, v);
            }
        }
    }

    // The positions of function-pointer type `y` (`lt_walk`, flags `f` from above): one per lifetime
    // it takes from outside it, which it holds.
    fn lt_outer<V: SlotVariance>(self: &Self, a: &Ast, y: &Ty, f: u8, out: &mut Vector<u8>, depth: u32, v: &mut V) {
        let mut vs = Vector::<u32>::new();
        self.sig_outer(a, y, &mut vs, depth + 1, v);
        for g in 0..vs.len() {
            out.push(ltf_vary(f, vs[g]) | LTF_BEHIND);
        }
    }

    /// The variance (`V_*`) of each lifetime function-pointer type `y` takes from outside it, in
    /// class order: how its positions of that class use it (`v` as in `lt_walk`).
    pub fn sig_outer<V: SlotVariance>(self: &Self, a: &Ast, y: &Ty, out: &mut Vector<u32>, depth: u32, v: &mut V) {
        out.truncate(0);
        let lts = a.instance(y.as_data.fnp.sig).lts;
        if lts == 0 || lts == LTS_WIDE || depth > 16 {
            return;
        }
        let mut cls = Vector::<u8>::new();
        let mut fl = Vector::<u8>::new();
        let mut nres: u32 = 0;
        self.sig_classes_at(a, y, &mut cls, &mut fl, &mut nres, depth, v);
        for k in 0..cls.len() {
            if cls[k] < LC_OUTER {
                continue;
            }
            let g = (cls[k] - LC_OUTER) as usize;
            while out.len() <= g {
                out.push(V_BIVARIANT);
            }
            let mut d = if k as u32 < nres {
                V_COVARIANT;
            } else {
                V_CONTRAVARIANT;
            };
            if (fl[k] & LTF_INV) != 0 {
                d = V_INVARIANT;
            } else if (fl[k] & LTF_CONTRA) != 0 {
                d = d ^ V_INVARIANT;
            }
            out.set(g, out[g] | d);
        }
    }

    /// The number of lifetime positions of type `t` (`lt_walk`).
    pub fn lt_count(self: &Self, a: &Ast, t: TypeId) u32 {
        let mut fl = Vector::<u8>::new();
        self.lt_walk(a, t, 0, &mut fl, 0, &mut Invariant {});
        return fl.len() as u32;
    }

    /// The lifetime class of each position of function-pointer type `y` (`LTS_*`), results first:
    /// its `lts`, or with none every position its own lifetime but elided results, which take the
    /// only input position's. `fl` gets each position's flags (`LTF_*`, relative to its slot; `v`
    /// gives the variance as in `lt_walk`) and `*nres` the result positions.
    pub fn sig_classes<V: SlotVariance>(
        self: &Self,
        a: &Ast,
        y: &Ty,
        cls: &mut Vector<u8>,
        fl: &mut Vector<u8>,
        nres: &mut u32,
        v: &mut V,
    ) {
        self.sig_classes_at(a, y, cls, fl, nres, 0, v);
    }

    // `sig_classes` at walk depth `depth`.
    fn sig_classes_at<V: SlotVariance>(
        self: &Self,
        a: &Ast,
        y: &Ty,
        cls: &mut Vector<u8>,
        fl: &mut Vector<u8>,
        nres: &mut u32,
        depth: u32,
        v: &mut V,
    ) {
        cls.truncate(0);
        fl.truncate(0);
        let it = *a.instance(y.as_data.fnp.sig);
        for i in 0..it.module as u32 {
            self.lt_walk(a, a.sig_at(y, true, i), 0, fl, depth, v);
        }
        *nres = fl.len() as u32;
        for i in 0..it.decl {
            self.lt_walk(a, a.sig_at(y, false, i), 0, fl, depth, v);
        }
        let total = fl.len() as u32;
        for k in 0..total {
            if it.lts != 0 {
                cls.push(a.sig_lt_class(y, k));
            } else if *nres != 0 && total == *nres + 1 {
                cls.push(LC_GROUP);
            } else {
                cls.push(LC_FREE);
            }
        }
    }

    /// Whether the header of extern block `nid` of module `m` reaches only the C files that use its
    /// items (`driver::emit::cemit_extern_includes`): a header `super_rt.h` does not include, or any
    /// header of the runtime module, of a block with a function that needs no CPU feature. Its macros would rename the identifiers of
    /// other files, so the inliner splices no use of its items into another module (`ir::inline`).
    pub fn extern_header_scoped(self: &Self, m: ModuleId, nid: NodeId) bool {
        let a = &self.modules[m as usize].ast;
        let eb = a.at_const(nid).as_data.extern_block;
        if eb.header == NODE_NONE {
            return false;
        }
        // A block whose functions all need CPU features is included where its functions are.
        let mut fns = false;
        let mut plain = false;
        for j in 0..eb.items.len {
            let f = unsafe a.list(eb.items)[j as usize];
            if a.at_const(f).kind == NodeKind::NODE_FUNCTION {
                fns = true;
                plain = plain || cf::is_empty(self.fn_features(m, f));
            }
        }
        if fns && !plain {
            return false;
        }
        // The runtime's bindings serve its own unit: their header checks (POSIX types and constants) stay
        // out of the forward header, which C code built at another feature level includes.
        if self.is_rt(m) {
            return true;
        }
        let hs = a.at_const(eb.header).span;
        let src = self.modules[m as usize].source.as_str();
        return !rth::rt_has_header(src.slice((hs.start + 1) as usize, (hs.end - 1) as usize));
    }

    /// Fill `xscoped` with the items of every extern block whose header is scoped
    /// (`extern_header_scoped`). The emission calls it before the inliner and the emitter read it.
    pub fn scope_extern_items(self: &mut Self) {
        let mut set = Set::<u64>::new();
        for m in 0..self.modules.len() {
            if !self.modules[m].has_ast {
                continue;
            }
            let a = &self.modules[m].ast;
            let its = a.at_const(a.root).as_data.program.items;
            for i in 0..its.len {
                let b = unsafe a.list(its)[i as usize];
                if a.at_const(b).kind != NodeKind::NODE_EXTERN_BLOCK || !self.extern_header_scoped(m as ModuleId, b) {
                    continue;
                }
                let items = a.at_const(b).as_data.extern_block.items;
                for j in 0..items.len {
                    set.insert(m as u64 << 32 | (unsafe a.list(items)[j as usize]) as u64);
                }
            }
        }
        self.xscoped = set;
    }

    /// Whether item `d` is declared in an extern block whose header is scoped (`xscoped`).
    pub fn extern_item_scoped(self: &Self, d: DefId) bool {
        return self.xscoped.contains(&(d.module as u64 << 32 | d.node as u64));
    }

    /// The CPU features function `f` of module `m` states (`@target_feature`, `@simd_impl`); empty for
    /// another.
    pub fn fn_features(self: &Self, m: ModuleId, f: NodeId) cf::CpuFeatureSet {
        let a = &self.modules[m as usize].ast;
        let ks: [AttrKind; 2] = [AttrKind::ATTR_TARGET_FEATURE, AttrKind::ATTR_SIMD_IMPL];
        for k in ks {
            if a.attr_of(f, k) != null {
                let v = a.attr_value(f, k);
                if v.ok {
                    return cf::CpuFeatureSet { w: v.w };
                }
            }
        }
        return cf::CpuFeatureSet { w: [0, 0] };
    }

    /// Whether type `t` of `a` is a function value's type that `FnPtr` admits: a function pointer, or a
    /// named function's type; never a closure's.
    pub const fn fn_value_type(self: &Self, a: &Ast, t: TypeId) bool {
        let y = a.type_at(t);
        return y.kind == TypeKind::TYPE_FUNCTION && (y.fn_sig() || unsafe (*self.module_ast_const(y.module)).at_const(
            y.as_data.decl,
        ).kind == NodeKind::NODE_FUNCTION);
    }

    /// The effective features of function `f` of module `m` (NODE_NONE: none): the build's and those
    /// it states, closed under `implies`. On wasm32 features are per build: the build's alone.
    pub fn fn_set(self: &Self, m: ModuleId, f: NodeId) cf::CpuFeatureSet {
        if f == NODE_NONE || !tgt::isa(self.arch).fn_features {
            return self.features;
        }
        return cf::close(cf::join(self.features, self.fn_features(m, f)));
    }

    /// The analysis worker count for this loaded package: `jobs` when the user source is large enough
    /// for the parallel frontiers to pay for themselves, else 1 (see PAR_MIN_USER_BYTES).
    pub const fn analysis_jobs(self: &Self, jobs: u32) u32 {
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
        // The prelude stage filtered its modules.
        for mi in self.root_module as usize..n {
            self.platform_filter_module(mi, target);
        }
    }

    /// A package with this one's search roots and build settings and nothing loaded: the package the
    /// prelude stage checks in (`driver::emit::prelude_stage`).
    pub fn settings_copy(self: &Self) Package {
        let mut q = Package::new();
        q.root_dir = self.root_dir.clone();
        q.alt_root = self.alt_root.clone();
        q.std_root = self.std_root.clone();
        q.arch = self.arch;
        q.features = self.features;
        q.simd_width = self.simd_width;
        q.simd_dispatch = self.simd_dispatch.clone();
        q.mem_check = self.mem_check;
        q.pic = self.pic;
        q.build_cfg = self.build_cfg;
        q.cflags = self.cflags.clone();
        q.test_build = self.test_build;
        q.profile = self.profile.clone();
        for i in 0..self.profiles.len() {
            q.profiles.push(self.profiles.at(i).clone());
        }
        q.bootstrap = self.bootstrap;
        return q;
    }

    /// The first stage of a driver build: the std prelude under `std_dir` and the build-constant
    /// module, before any user module (`load_user` appends them), so the prelude's module and item
    /// ids are the same in every build with these settings, and its analysis reads nothing else.
    pub fn load_prelude_stage(self: &mut Self, std_dir: str, bootstrap_tags: bool, target: i32) {
        self.bootstrap = bootstrap_tags;
        if self.std_missing(std_dir) {
            return;
        }
        self.simd_levels_compute();
        if self.load_prelude_files(std_dir, target) {
            self.add_build_module(target);
        }
        self.seed_core();
        self.bind_types();
    }

    /// Start reading and parsing `root_file`'s module closure in tasks, for a package with this one's
    /// settings whose prelude is the one `q` loaded (`load_prelude_stage`), while `q` is checked. Nothing
    /// starts when loading is serial or the root names a loaded module.
    pub fn spec_user(self: &Self, q: &Package, root_file: str, target: i32) Box<UserSpec> {
        let rp = stem_of(root_file);
        if unsafe G_LOAD_JOBS == 1 || self.overlay_files.len() != 0 || q.find(rp.as_str()) >= 0 {
            return UserSpec::new();
        }
        let mut s = Box::<UserSpec>::new(
            UserSpec { v: self.settings_copy(), units: PUnits {}, wg: psy::WaitGroup::new() },
        );
        // The prelude's module table, which `find`, `find_file` and `std_shadowed` read.
        let v = &mut s.v;
        for i in 0..q.modules.len() {
            let m = q.modules.at(i);
            let _ = v.add_module(m.path.clone(), m.file.clone(), String::new(), m.src_id, m.mtime, Ast::new(0), false);
            v.modules[i].prelude = m.prelude;
        }
        for i in 0..q.alias_path.len() {
            v.alias_path.push(q.alias_path.at(i).clone());
            v.alias_id.push(q.alias_id[i]);
        }
        v.root_module = q.modules.len() as u32;
        s.units.push(rp.as_str(), root_file, false);
        s.wg.add(1);
        let t = SpecTask { s: s.deref_mut(), target: target };
        let wgc = s.wg.clone();
        launch || {
            let us = unsafe &mut *t.s;
            us.v.par_discover(&mut us.units, us.v.bootstrap, t.target);
            wgc.done();
        };
        return s;
    }

    /// Take the user closure of `s` (`spec_user`), started against the prelude this package holds, for
    /// `load_user`. Waits for its tasks.
    pub fn adopt_user(self: &mut Self, mut s: Box<UserSpec>) {
        s.join();
        if s.units.units.len() == 0 {
            return;
        }
        assert(
            self.modules.len() == s.v.modules.len(),
            "the package holds the prelude the user closure was read against",
        );
        self.dir_cache = replace(&mut s.v.dir_cache, DirCache {});
        for i in self.alias_path.len()..s.v.alias_path.len() {
            self.alias_path.push(s.v.alias_path.at(i).clone());
            self.alias_id.push(s.v.alias_id[i]);
        }
        self.spec = replace(&mut s.units, PUnits {});
    }

    /// The second stage: append `root_file`'s module closure after the prelude (from `adopt_user` when
    /// it took one), then the vector backend when a module names a vector. Every module joins the
    /// package type table as it loads; `index_append` indexes them once the platform filter has run.
    pub fn load_user(self: &mut Self, root_file: str, std_dir: str, target: i32) {
        self.root_module = self.modules.len() as u32;
        let rp = stem_of(root_file);
        let rf = String::from_str(root_file);
        let m = self.find(rp.as_str());
        if m >= 0 {
            eprint(
                "error: the root file '{}' names module '{}', which the std prelude loads from '{}': rename the root file\n",
                root_file,
                rp.as_str(),
                self.modules.at(m as usize).file.as_str(),
            );
            self.ok = false;
            return;
        }
        if self.spec.units.len() != 0 {
            let mut us = replace(&mut self.spec, PUnits {});
            self.root = self.par_replay(&mut us, 0, self.bootstrap, target);
        } else {
            self.root = self.load_module(rp.as_str(), rf.as_str(), self.bootstrap, target);
        }
        self.load_backend(std_dir, target, false);
    }

    /// Load `root_file` and, transitively, every module it imports, then append the std prelude
    /// under `std_dir` (empty skips it).
    pub fn load_root(self: &mut Self, root_file: str, std_dir: str, bootstrap_tags: bool, target: i32) {
        self.bootstrap = bootstrap_tags;
        if self.std_missing(std_dir) {
            return;
        }
        let rp = stem_of(root_file);
        let rf = String::from_str(root_file);
        self.root = self.load_module(rp.as_str(), rf.as_str(), bootstrap_tags, target);
        self.load_prelude(std_dir, target, false);
        self.seed_core();
        self.bind_types();
    }

    /// Add the build-constant module `__std::build`, the prelude's last module: this compilation's
    /// settings as constants, spelled from `target`, `arch`, `features`, `test_build` and `profile`. ARCH and
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
        let cfg: []str = [
            "/// The C compile has ThreadSanitizer (`-fsanitize=thread`).\npub const THREAD_SANITIZER: bool = ",
            "/// The C compile has AddressSanitizer (`-fsanitize=address`).\npub const ADDRESS_SANITIZER: bool = ",
            "/// The runtime tracks lock order (`-DSC_LOCKDEP`).\npub const LOCKDEP: bool = ",
            "/// Integer overflow traps; false where the profile wraps it.\npub const OVERFLOW_CHECKS: bool = ",
        ];
        for i in 0..cfg.len() {
            src.push_str(cfg[i]);
            src.push_str(pick(self.bc_value(BC_THREAD_SANITIZER + i as i32) != 0, "true;\n", "false;\n"));
        }
        src.format_into(
            "/// The CPU features the build enables: the platform's baseline, `target-features`, `--target-feature`\n/// and what they imply. Bit `i` of word `i / 64` is the `cpu::Feature` variant of discriminant `i`.\npub const TARGET_FEATURES: [u64; 2] = [{}, {}];\n",
            self.features.w[0],
            self.features.w[1],
        );
        if self.arch >= 0 {
            src.push_str("/// The target instruction set (`--arch`).\npub const ARCH: Arch = Arch::");
            src.push_str(bc_variants(BC_ARCH)[self.arch as usize]);
            src.push_str(";\n/// The width of a pointer in bits.\npub const POINTER_WIDTH: u32 = ");
            src.push_i64(self.bc_value(BC_POINTER_WIDTH));
            src.push_str(";\n");
        }
        let mut parsed = parse_source(&mut src, "", false, Vector::<tok::Token>::new());
        assert(parsed.ok, "the build-constant module parses");
        let sid = dutil::str_id(src.as_str());
        let id = self.add_module(
            String::from_str("__std::build"),
            String::new(),
            src,
            sid,
            0,
            replace(&mut parsed.ast, Ast::new(0)),
            true,
        );
        self.modules[id as usize].ast.module = id as ModuleId;
        self.modules[id as usize].prelude = true;
        self.build_module = id;
    }

    /// Whether module `m` is a root: the module the package was loaded from, or a file a batch lint
    /// lists (each is a program of its own there).
    pub const fn is_root_module(self: &Self, m: ModuleId) bool {
        return m as i32 == self.root || m as usize < self.lint_set.len() && self.lint_set[m as usize];
    }

    /// Whether function `f` of module `m` is the program entry: a root module's top-level `main`.
    /// Every other function named `main` is an ordinary function.
    pub fn is_entry(self: &Self, m: ModuleId, f: NodeId) bool {
        if !self.is_root_module(m) {
            return false;
        }
        let a = &self.modules[m as usize].ast;
        let nm = a.at_const(a.at_const(f).as_data.function.name).as_data.name.text;
        if self.modules[m as usize].source.as_str().slice(nm.start as usize, nm.end as usize) != "main" {
            return false;
        }
        let items = a.at_const(a.root).as_data.program.items;
        for j in 0..items.len {
            if unsafe a.list(items)[j as usize] == f {
                return true;
            }
        }
        return false;
    }

    /// Whether module `m` is std's `target.spc`, the declarer of the build-constant enums.
    pub const fn is_target_module(self: &Self, m: ModuleId) bool {
        return m as usize < self.modules.len() && self.modules[m as usize].prelude && basename_of(
            self.modules[m as usize].file.as_str(),
        ) == "target.spc";
    }

    /// The build profile's name: `profile`, `debug` when the driver named none.
    pub const fn profile_name<'a>(self: &'a Self) str<'a> {
        if self.profile.len() == 0 {
            return "debug";
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
        if k >= BC_THREAD_SANITIZER {
            // The overflow bit records a wrapping profile, so a package with no configuration checks.
            let bit = (self.build_cfg >> (k - BC_THREAD_SANITIZER) as u32 & 1u32) as i64;
            return pick(k == BC_OVERFLOW_CHECKS, 1 - bit, bit);
        }
        if k == BC_POINTER_WIDTH {
            return if self.arch < 0 {
                -1;
            } else {
                tgt::isa(self.arch).ptr_bytes as i64 * 8;
            };
        }
        return if k == BC_ENDIAN {
            switch tgt::target_of(self.build_target, self.arch) {
                Some(t) => t.big_endian as i64,
                None => 0,
            };
        } else {
            -1;
        };
    }

    /// The index of this compilation's settings in a `@when` truth table: bit `when_var(k)` is the
    /// value of boolean build constant `k`.
    pub const fn when_index(self: &Self) u32 {
        let mut w = self.bc_value(BC_TEST) as u32;
        for k in BC_THREAD_SANITIZER..BC_OVERFLOW_CHECKS + 1 {
            w = w | self.bc_value(k) as u32 << when_var(k);
        }
        return w;
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
            // The branches not taken, as written (an inner site decided first keeps its span in its cut).
            if n.kind == NodeKind::NODE_IF {
                for b in [n.as_data.if_stmt.then_branch, n.as_data.if_stmt.else_branch] {
                    if b != NODE_NONE && b != take {
                        ast.bc_dead.push(ast.written_span(b));
                    }
                }
            } else {
                let arms = n.as_data.match_expr.arms;
                for k in 0..arms.len {
                    let arm = unsafe ast.list(arms)[k as usize];
                    if ast.at_const(arm).as_data.match_arm.body != take {
                        ast.bc_dead.push(ast.at_const(arm).span);
                    }
                }
            }
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
            let k = self.bc_const(mi, id);
            return if bc_is_bool(k) {
                self.bc_value(k) as i32;
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
        if bc_is_bool(k) || k == BC_POINTER_WIDTH {
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
        let when = self.when_index();
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
            if at.kind == AttrKind::ATTR_WHEN as u8 && (at.arg >> when & 1u32) == 0 {
                dropped.push(at.owner);
            }
        }
        if dropped.len() == 0 {
            m.ast.settle_dead();
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
                // A kept extend or extern block loses its gated members, as the program loses its gated
                // items (an interface member takes no attribute).
                let n = *m.ast.at_const(id);
                let is_ext = n.kind == NodeKind::NODE_EXTEND;
                if is_ext || n.kind == NodeKind::NODE_EXTERN_BLOCK {
                    let its = pick(is_ext, n.as_data.extend_def.items, n.as_data.extern_block.items);
                    let mut kept: u32 = 0;
                    for k in 0..its.len {
                        let mid = unsafe m.ast.list(its)[k as usize];
                        if dropped.binary_search(&mid).is_err() {
                            m.ast.children.set((its.start + kept) as usize, mid);
                            kept = kept + 1;
                        } else {
                            let _ = m.ast.member_of.remove(&mid);
                            let msp = item_span(m.source.as_str(), m.ast.at_const(mid));
                            m.ast.bc_dead.push(msp);
                        }
                    }
                    if is_ext {
                        m.ast.at(id).as_data.extend_def.items.len = kept;
                    } else {
                        m.ast.at(id).as_data.extern_block.items.len = kept;
                    }
                }
            } else {
                // A dropped container's members no longer have one.
                let n = *m.ast.at_const(id);
                m.ast.bc_dead.push(item_span(m.source.as_str(), &n));
                if n.kind == NodeKind::NODE_EXTEND {
                    m.ast.set_members(NODE_NONE, n.as_data.extend_def.items);
                } else if n.kind == NodeKind::NODE_INTERFACE {
                    m.ast.set_members(NODE_NONE, n.as_data.interface_def.items);
                }
            }
        }
        m.ast.at(root).as_data.program.items.len = w;
        m.ast.settle_dead();
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
                self.modules[i].ast.gt.p = gp;
                if self.modules[i].prelude && basename_of(self.modules[i].file.as_str()) == "simd.spc" {
                    self.tt.deref_mut().simd = self.top_struct(i as ModuleId, "Simd", NodeKind::NODE_STRUCT);
                    self.tt.deref_mut().mask = self.top_struct(i as ModuleId, "Mask", NodeKind::NODE_STRUCT);
                    self.tt.deref_mut().simd_op = self.top_struct(i as ModuleId, "Op", NodeKind::NODE_ENUM);
                }
                if self.modules[i].prelude && basename_of(self.modules[i].file.as_str()) == "cpu.spc" {
                    self.tt.deref_mut().cpu_feature = self.top_struct(i as ModuleId, "Feature", NodeKind::NODE_ENUM);
                }
            }
        }
    }

    // The top-level struct or enum (`kind`) `name` of module `m`, or node NODE_NONE.
    fn top_struct(self: &Self, m: ModuleId, name: str, kind: NodeKind) DefId {
        let a = &self.modules[m as usize].ast;
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let id = unsafe a.list(items)[i as usize];
            let n = a.at_const(id);
            if n.kind == kind {
                let sp = a.at_const(n.as_data.aggregate.name).as_data.name.text;
                if self.modules[m as usize].source.as_str().slice(sp.start as usize, sp.end as usize) == name {
                    return DefId { module: m, node: id };
                }
            }
        }
        return DefId { module: m, node: NODE_NONE };
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
    const fn clin_less(self: &Self, x: u64, y: u64) bool {
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
        let mut batch = TypePool::new();
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
                if self.modules[m].has_ast && self.modules[m].ast.gt.p != null {
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
                if self.modules[m].has_ast && self.modules[m].ast.gt.p != null {
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
                        } else if y.arr_like() {
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
                if !a.valid(it.node) || a.at_const(it.node).kind != NodeKind::NODE_FUNCTION || a.gt.p == null {
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
            } else if y.arr_like() {
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
                if it.lts != 0 {
                    out.push_str(" L");
                    out.push_u64(it.lts);
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
            arch: if unsafe G_ARCH < 0 {
                unsafe shim::sc_host_arch();
            } else {
                unsafe G_ARCH;
            },
            features: if unsafe G_ARCH < 0 {
                tgt::baseline(unsafe shim::sc_host_platform(), unsafe shim::sc_host_arch());
            } else {
                unsafe G_FEATURES;
            },
            build_module: -1,
            rt_module: -1,
            rt_test: -1,
            rt_libc: -1,
            rt_libm: -1,
            rt_lanes: -1,
            root: -1,
            tt: Box::<TypePool>::new(TypePool::new()),
            ok: true,
            jobs: 1, // serial unless a driver opts in: a bare Package must never launch tasks
        };
    }

    /// True when a loop in the body whose span is `osp` (module `m`) can run inside a coroutine
    /// and therefore needs a preemption safepoint at its backedges.
    pub const fn co_on(self: &Self, m: ModuleId, osp: tok::Span) bool {
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
    pub const fn co_inst_on(self: &Self, m: ModuleId, sp: tok::Span) bool {
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

    /// The coroutine and cancellation reachability of the whole package from its current syntax: one
    /// scan per module (`co_scan`), then `reach_solve`. Every body must be live.
    pub fn reach_compute(self: &mut Self) {
        let cx = self.reach_ctx();
        let mut scans = Vector::<ReachScan>::with_capacity(self.modules.len());
        for m in 0..self.modules.len() {
            scans.push(self.co_scan(m, &cx));
        }
        self.reach_solve(&scans);
    }

    /// The inputs every module's scan shares (`co_scan`).
    pub fn reach_ctx(self: &Self) ReachCtx {
        let mut cx = ReachCtx {
            rt: false,
            ent: Vector::<u64>::new(),
            ent_p: Vector::<u32>::new(),
            acc: DefId { module: 0, node: NODE_NONE },
            req: NODE_NONE,
            tsh: NODE_NONE,
            task_mid: -1,
        };
        let rt = self.find("std::parallel::runtime");
        if rt < 0 {
            return cx;
        }
        cx.rt = true;
        self.co_entries(&mut cx.ent, &mut cx.ent_p);
        let acc = self.glob_lookup(rt as ModuleId, "cancel_accept", false);
        cx.acc = DefId { module: acc.mid, node: acc.node };
        cx.req = self.glob_lookup(rt as ModuleId, "request_cancel", false).node;
        cx.tsh = self.glob_lookup(rt as ModuleId, "try_shutdown", false).node;
        cx.task_mid = self.find("std::parallel::task");
        return cx;
    }

    // The kind of declaration `d`: a node of another module is in its module arena, which every
    // module keeps (a call or a name reaches another module's body arena never).
    fn decl_kind(self: &Self, m: usize, d: DefId) NodeKind {
        assert(d.module as usize == m || (d.node & NODE_BODY) == 0, "another module's body node is never named");
        return unsafe (&*self.module_ast_const(d.module)).at_const(d.node).kind;
    }

    /// Scan module `m` for the reachability (`ReachScan`): its bodies and checked tables must be live.
    /// One pass over its nodes builds the declaration table and keeps, in node order, the sites the
    /// records come from; a second pass over the sites writes the records.
    pub fn co_scan(self: &Self, m: usize, cx: &ReachCtx) ReachScan {
        let mut s = ReachScan::new();
        if !cx.rt || !self.modules.at(m).has_ast {
            return s;
        }
        let a = unsafe &*self.module_ast_const(m as ModuleId);
        let src = self.modules.at(m).source.as_str();
        let pth = self.modules.at(m).path.as_str();
        let spar = runtime_path(pth);
        let in_std = pth.starts_with("std::") || pth.starts_with("__std::");
        let cancel = cx.acc.node != NODE_NONE;
        let nb9 = a.nodes.len();
        let nn9 = a.nnodes();
        s.nb = nb9 as u32;
        s.nn = nn9 as u32;
        let mut dm_span = Vector::<u64>::new();
        let mut dm_node = Vector::<u32>::new();
        let mut callee = Vector::<u64>::new(); // bit set over dense nodes: nodes in callee position
        callee.resize_default(nn9 / 64 + 1);
        // The nodes the records come from: calls, `for` loops, `?` conversions, and the nodes of
        // function type that can name a function as a value (outside std::parallel).
        let mut sites = Vector::<u32>::new();
        // Per site: 1 when it may name a function as a value, 2 for an operator `agg_op_name` names.
        let mut site_named = Vector::<u8>::new();
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
                    let ck = a.dense(c);
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
        if cancel {
            s.c_row = dm_span.clone();
        }
        // Sorted by start: the declarations inside one are the run that follows it while their
        // starts stay below its end.
        sort_spans(&mut dm_span, &mut dm_node);
        let mut open = CO_NONE; // the innermost declaration whose span is still open
        let nd = dm_span.len();
        s.d_span.reserve(nd);
        s.d_parent.reserve(nd);
        s.d_node.reserve(nd);
        s.d_clo.reserve(nd);
        s.d_need.reserve(nd);
        for x in 0..nd {
            let sp = dm_span[x];
            let st = (sp >> 32) as u32;
            while open != CO_NONE && (s.d_span[open as usize] & 0xFFFFFFFFu64) as u32 <= st {
                open = s.d_parent[open as usize];
            }
            s.d_span.push(sp);
            s.d_parent.push(open);
            s.d_node.push(dm_node[x]);
            let mut clo: u8 = 0;
            if a.at_const(dm_node[x]).kind == NodeKind::NODE_CLOSURE {
                clo = 1;
            }
            s.d_clo.push(clo);
            s.d_need.push(0);
            open = x as u32;
        }
        s.s_prop.push(0);
        let mut hint = CO_NONE; // the previous site's declaration
        for si in 0..sites.len() {
            let ni = sites[si];
            if site_named[si] == 1 {
                // Most of these sites are callees: test that before reading the node.
                let ck = a.dense(ni);
                if (callee[ck / 64] >> (ck % 64) as u64 & 1u64) != 0 {
                    continue;
                }
            }
            let n = a.at_const(ni);
            if site_named[si] == 2 {
                // A recorded operator method is a record of the operator loop below.
                if a.op_method.get(&ni).is_some() {
                    continue;
                }
                let d = s.decl_near(n.span, hint);
                hint = d;
                if d != CO_NONE {
                    s.r_decl.push(d);
                    s.r_tgt.push(CO_TGT_OP | fnv(agg_op_name(a, n)) & 0xFFFFFFFFu64);
                    s.r_site.push(CO_NONE);
                    s.r_chk.push(0);
                }
                continue;
            }
            let nk = n.kind;
            if nk == NodeKind::NODE_CALL {
                let d = s.decl_near(n.span, hint);
                hint = d;
                let cd = n.as_data.call;
                let mut t = pin_callee(a, ni, cd.callee);
                if cancel && t.node != NODE_NONE {
                    if !s.c_used && !pth.starts_with("std::") && (cx.task_mid >= 0 && t.module == cx.task_mid as ModuleId || t.module == cx.acc.module && (t.node == cx.req || t.node == cx.tsh)) {
                        s.c_used = true;
                    }
                    // A ctor, variant or type call runs no body.
                    if t.module == cx.acc.module && t.node == cx.acc.node || self.decl_kind(m, t) == NodeKind::NODE_FUNCTION {
                        s.c_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                        s.c_tgt.push(def_key(t));
                    }
                }
                if t.node != NODE_NONE {
                    let tk = self.decl_kind(m, t);
                    if tk != NodeKind::NODE_FUNCTION && tk != NodeKind::NODE_CLOSURE {
                        if tk == NodeKind::NODE_STRUCT || tk == NodeKind::NODE_ENUM || tk == NodeKind::NODE_VARIANT || tk == NodeKind::NODE_TYPE_ALIAS {
                            // Ctor/variant/type call: no body to run.
                            continue;
                        }
                        // Pinned to the field or binding that holds the callee: a fn value.
                        t = DefId { module: 0, node: NODE_NONE };
                    }
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
                    // A call to the declaration's own parameter: a need of a function, checked at its
                    // call sites. A closure's call sites are fn-value calls nothing pins.
                    let pr = a.resolution_def(cd.callee);
                    if s.d_clo[d as usize] == 0 && pr.node != NODE_NONE && pr.module == m as ModuleId && a.at_const(
                        pr.node,
                    ).kind == NodeKind::NODE_PARAMETER {
                        let pi = param_index(a, s.d_node[d as usize], pr.node);
                        if pi >= 0 && pi < 64 {
                            s.d_need.set(d as usize, s.d_need[d as usize] | 1u64 << pi as u64);
                            continue;
                        }
                    }
                    if spar {
                        continue;
                    }
                    s.r_decl.push(d);
                    s.r_tgt.push(CO_TGT_ESC);
                    s.r_site.push(CO_NONE);
                    s.r_chk.push(0);
                    continue;
                }
                // Every entry API lives in std::parallel.
                let tpar = self.modules.at(t.module as usize).path.as_str().starts_with("std::parallel");
                if !spar && tpar {
                    let tk = def_key(t);
                    for e in 0..cx.ent.len() {
                        if cx.ent[e] != tk {
                            continue;
                        }
                        let arg = site_arg(a, ni, cx.ent_p[e]);
                        let an = if arg != NODE_NONE {
                            named_node(a, arg);
                        } else {
                            NODE_NONE;
                        };
                        if an != NODE_NONE && a.at_const(an).kind == NodeKind::NODE_CLOSURE {
                            s.seeds.push(def_key(DefId { module: m as ModuleId, node: an }));
                        } else if an != NODE_NONE && named_decl(a, an).node != NODE_NONE {
                            s.seeds.push(def_key(named_decl(a, an)));
                        } else {
                            // An entry the tracker cannot pin: any fn value may run.
                            s.seeds.push(CO_TGT_ESC);
                        }
                    }
                }
                if d != CO_NONE {
                    self.co_site(&mut s, a, m, ni, d, spar, in_std, tpar);
                    s.r_decl.push(d);
                    s.r_tgt.push(def_key(t));
                    s.r_site.push(s.s_bad.len() as u32 - 1);
                    s.r_chk.push(1);
                }
                continue;
            }
            let mut t = DefId { module: 0, node: NODE_NONE };
            if nk == NodeKind::NODE_FOR {
                // The loop's `next`, when it iterates an iterator.
                switch a.call_info_of(ni) {
                    Some(v) => {
                        t = DefId { module: (v >> 40) as ModuleId, node: (v >> 8 & 0xFFFFFFFFu64) as NodeId };
                        if cancel {
                            s.c_span.push(n.span.start as u64 << 32 | n.span.end as u64);
                            s.c_tgt.push(def_key(t));
                        }
                    },
                    _ => {},
                };
            } else {
                // A function named as a value (not called here) has a function type; a `?`
                // conversion names one too. Not in callee position (tested above): a function, not
                // the declaration's own name.
                let r = a.resolution_def(ni);
                if r.node != NODE_NONE && self.decl_kind(m, r) == NodeKind::NODE_FUNCTION && !(r.module == m as ModuleId && a.at_const(
                    r.node,
                ).as_data.function.name == ni) {
                    t = r;
                    s.esc.push(def_key(r));
                }
            }
            if t.node == NODE_NONE {
                continue;
            }
            let d = s.decl_near(n.span, hint);
            hint = d;
            if d != CO_NONE {
                s.r_decl.push(d);
                s.r_tgt.push(def_key(t));
                s.r_site.push(CO_NONE);
                s.r_chk.push(0);
            }
        }
        // An operator node calls the method the checker chose, in node order.
        if a.op_method.len() != 0 {
            let mut opn = Vector::<u32>::new();
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
                let osp = a.at_const(opn[i]).span;
                let d = s.decl_at(osp);
                if d != CO_NONE {
                    s.r_decl.push(d);
                    s.r_tgt.push(v);
                    s.r_site.push(CO_NONE);
                    s.r_chk.push(0);
                }
                if cancel {
                    s.c_span.push(osp.start as u64 << 32 | osp.end as u64);
                    s.c_tgt.push(v);
                }
            }
        }
        // A user `Deref` hop calls its method from the node that dereferences.
        for i in 0..a.deref_uses.len() {
            let du = a.deref_uses.at(i);
            let dsp = a.at_const(du.node).span;
            let d = s.decl_at(dsp);
            for k in 0..du.n {
                let dm = unsafe du.method[k as usize];
                if dm.node == NODE_NONE {
                    continue;
                }
                if d != CO_NONE {
                    s.r_decl.push(d);
                    s.r_tgt.push(def_key(dm));
                    s.r_site.push(CO_NONE);
                    s.r_chk.push(0);
                }
                if cancel {
                    s.c_span.push(dsp.start as u64 << 32 | dsp.end as u64);
                    s.c_tgt.push(def_key(dm));
                }
            }
        }
        return s;
    }

    // The facts the solve reads of call site `ni` in declaration `d` of module `m` (`ReachScan.s_*`):
    // which parameters' arguments a need check rejects, which of the caller's parameters it passes
    // for them, whether a call into std::parallel (`tpar`) passes a fn value the tracker cannot pin
    // (and hands a caller's parameter on: a need of the caller), and whether it dispatches through a
    // `dyn` receiver (read for std code only). An argument passes a check when it is a closure (on
    // with `d`), a named function (marked by its own record) or a parameter of function `d` (a need
    // of `d` by the fixpoint). A site inside std::parallel is its own dispatch: every check passes.
    fn co_site(
        self: &Self,
        s: &mut ReachScan,
        a: &Ast,
        m: usize,
        ni: NodeId,
        d: u32,
        spar: bool,
        in_std: bool,
        tpar: bool,
    ) {
        let clo = s.d_clo[d as usize] != 0;
        let dn = s.d_node[d as usize];
        let mut bad: u64 = 0;
        let mut par: u8 = 0;
        let nargs = a.at_const(ni).as_data.call.args.len;
        for p in 0..64u32 {
            if p > nargs {
                break; // past the receiver and every argument
            }
            let arg = site_arg(a, ni, p);
            if arg == NODE_NONE {
                continue;
            }
            let an = named_node(a, arg);
            if !clo {
                let pr = a.resolution_def(an);
                if pr.node != NODE_NONE && pr.module == m as ModuleId && a.at_const(pr.node).kind == NodeKind::NODE_PARAMETER {
                    let q = param_index(a, dn, pr.node);
                    if q >= 0 && q < 64 {
                        s.prop.push((p << 8 | q as u32) as u16);
                    }
                }
            }
            if !spar && !self.co_arg_ok(a, m, an, clo, dn) {
                bad = bad | 1u64 << p as u64;
            }
        }
        if !spar && tpar {
            let args = a.at_const(ni).as_data.call.args;
            for j in 0..args.len {
                let arg = unsafe a.list(args)[j as usize];
                if !fn_valued(a, arg) {
                    continue;
                }
                let an = named_node(a, arg);
                if !self.co_arg_ok(a, m, an, clo, dn) {
                    par = par | CO_PAR_BAD;
                }
                // A fn value handed to std::parallel may run on a coroutine later: a parameter of
                // the caller handed on is a need of the caller.
                let pr = a.resolution_def(an);
                if !clo && pr.node != NODE_NONE && pr.module == m as ModuleId && a.at_const(pr.node).kind == NodeKind::NODE_PARAMETER {
                    let q = param_index(a, dn, pr.node);
                    if q >= 0 && q < 64 {
                        s.d_need.set(d as usize, s.d_need[d as usize] | 1u64 << q as u64);
                    }
                }
            }
        }
        if in_std && dyn_receiver(a, ni) {
            par = par | CO_DYN;
        }
        s.s_bad.push(bad);
        s.s_par.push(par);
        s.s_prop.push(s.prop.len() as u32);
    }

    // Does argument `an` (its named node) of a call in declaration `dn` (a closure when `clo`) pass a
    // need check: a closure, a named function, or a parameter of function `dn`?
    fn co_arg_ok(self: &Self, a: &Ast, m: usize, an: NodeId, clo: bool, dn: NodeId) bool {
        if a.at_const(an).kind == NodeKind::NODE_CLOSURE {
            return true;
        }
        let r = named_decl(a, an);
        if r.node == NODE_NONE {
            return false;
        }
        let rk = self.decl_kind(m, r);
        if rk == NodeKind::NODE_FUNCTION {
            return true;
        }
        return rk == NodeKind::NODE_PARAMETER && r.module == m as ModuleId && !clo && param_index(a, dn, r.node) >= 0;
    }

    /// Solve the coroutine and cancellation reachability over one scan per module (`co_scan`):
    /// co_spans, co_inst and co_fnv, then cancel_marks, cancel_fnv and cancel_used.
    ///
    /// co_spans holds the functions and closures a coroutine can execute. Seeds are the entry
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
    /// passes each argument that can hold a fn value under the need rule (`co_site`), so a fn
    /// value it stores and runs later is reached.
    /// std decls join co_spans only when their bodies can run user code (a std loop is otherwise
    /// bounded by its inputs), and never in std::parallel; those that run it only through bound
    /// dispatch also join co_inst, whose ticks each instance decides at emission.
    ///
    /// cancel_marks holds the decl spans of every function and closure whose body can reach
    /// `runtime::cancel_accept`. Seeded at direct calls to the acceptance leaf, then closed upward:
    /// a call to a marked callee (a `for` loop's `next` included) marks the decls enclosing the call
    /// site, and a marked conformance method marks the interface methods of its name, whose call
    /// sites a bound or `dyn` dispatch pins. A call to a fn value nothing pins marks nothing: when
    /// some fn value of `co_fnv` is marked (`cancel_fnv`), every such call carries its own check.
    pub fn reach_solve(self: &mut Self, scans: &Vector<ReachScan>) {
        let nm = self.modules.len();
        assert(scans.len() == nm, "one reachability scan per module");
        self.co_state = 1;
        self.co_spans.truncate(0);
        self.co_spans.resize_default(nm);
        self.co_fnv.truncate(0);
        self.co_inst.truncate(0);
        self.cancel_state = 1;
        self.cancel_fnv = false;
        self.cancel_used = false;
        self.cancel_marks.truncate(0);
        self.cancel_marks.resize_default(nm);
        let rt = self.find("std::parallel::runtime");
        if rt < 0 {
            // No coroutine runtime loaded: nothing can launch or accept a cancellation.
            return;
        }
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
            if runtime_path(pth) {
                sm = 2;
            } else if pth.starts_with("std::") || pth.starts_with("__std::") {
                sm = 1;
            }
            g.stdm.push(sm);
        }
        // One slot per node of every scanned module.
        let mut total: usize = 0;
        for m in 0..nm {
            g.ix_start.push(total);
            g.nb.push(scans.at(m).nb as usize);
            total += scans.at(m).nn as usize;
        }
        g.ix_start.push(total);
        g.ix.resize_default(total);
        for m in 0..nm {
            let sc = scans.at(m);
            let base = g.span.len() as u32;
            g.start.push(base);
            let ix0 = g.ix_start[m];
            for x in 0..sc.d_span.len() {
                g.span.push(sc.d_span[x]);
                let pa = sc.d_parent[x];
                g.parent.push(
                    if pa == CO_NONE {
                        CO_NONE;
                    } else {
                        base + pa;
                    },
                );
                g.lim.push(base + sc.d_span.len() as u32);
                g.dmod.push(m as u32);
                let dn = sc.d_node[x];
                g.node.push(dn);
                g.closure.push(sc.d_clo[x]);
                g.need.push(sc.d_need[x]);
                let k = if (dn & NODE_BODY) != 0 {
                    sc.nb as usize + (dn & NODE_BODY_MASK) as usize;
                } else {
                    dn as usize;
                };
                g.ix.set(ix0 + k, base + x as u32 + 1);
            }
        }
        g.start.push(g.span.len() as u32);
        let nd = g.span.len();
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
        // The interface and conformance methods, by name: an operator dispatched at emission reaches
        // the interface methods of its method's name.
        let mut ifm = Vector::<u64>::new(); // name hash << 32 | index into `defs`
        let mut imp = Vector::<u64>::new();
        let mut defs = Vector::<u64>::new(); // module << 32 | node
        self.co_dispatch(&mut ifm, &mut imp, &mut defs);
        // `ifm` sorted: the methods of one name are one run, in `ifm` order (the index ascends).
        let mut ifs = ifm.clone();
        ifs.sort();
        // Records, attached to their innermost decl: the target decl (or CO_ESC), the call site whose
        // arguments a need of the target checks (module << 32 | its index in that module's scan;
        // CO_NO_SITE: none), and whether the entry is checked (a call site, or a conformance reached
        // through its interface method's call sites).
        let mut r_decl = Vector::<u32>::new();
        let mut r_tgt = Vector::<u32>::new();
        let mut r_site = Vector::<u64>::new();
        let mut r_chk = Vector::<u8>::new();
        let mut seeds = Vector::<u32>::new();
        let mut seed_esc = false;
        for m in 0..nm {
            let sc = scans.at(m);
            let base = g.start[m];
            for i in 0..sc.r_decl.len() {
                let d = base + sc.r_decl[i];
                let tk = sc.r_tgt[i];
                if tk == CO_TGT_ESC {
                    r_decl.push(d);
                    r_tgt.push(CO_ESC);
                    r_site.push(CO_NO_SITE);
                    r_chk.push(0);
                    continue;
                }
                if (tk & CO_TGT_OP) != 0 {
                    let h = tk & 0xFFFFFFFFu64;
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
                    for j in lo..ifs.len() {
                        if ifs[j] >> 32 != h {
                            break;
                        }
                        let dm = defs[(ifs[j] & 0xFFFFFFFFu64) as usize];
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
                let td = g.decl_of((tk >> 32) as ModuleId, (tk & 0xFFFFFFFFu64) as NodeId);
                if td == CO_NONE {
                    continue;
                }
                r_decl.push(d);
                r_tgt.push(td);
                r_site.push(
                    if sc.r_site[i] == CO_NONE {
                        CO_NO_SITE;
                    } else {
                        m as u64 << 32 | sc.r_site[i] as u64;
                    },
                );
                r_chk.push(sc.r_chk[i]);
            }
            for i in 0..sc.seeds.len() {
                let k = sc.seeds[i];
                let sd = if k == CO_TGT_ESC {
                    CO_NONE;
                } else {
                    g.decl_of((k >> 32) as ModuleId, (k & 0xFFFFFFFFu64) as NodeId);
                };
                if sd != CO_NONE {
                    seeds.push(sd);
                } else {
                    // An entry the tracker cannot pin: any fn value may run.
                    seed_esc = true;
                }
            }
            for i in 0..sc.esc.len() {
                let k = sc.esc[i];
                let rd = g.decl_of((k >> 32) as ModuleId, (k & 0xFFFFFFFFu64) as NodeId);
                if rd != CO_NONE {
                    g.add_esc(rd);
                }
            }
        }
        // Dispatch: an interface method reaches every conformance method of its name, a checked
        // entry (the method's call sites check the conformance's needs, merged below).
        let free_h = fnv("free") & 0xFFFFFFFFu64;
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
                    let sc = scans.at((r_site[i] >> 32) as usize);
                    let si = (r_site[i] & 0xFFFFFFFFu64) as usize;
                    for j in sc.s_prop[si]..sc.s_prop[si + 1] {
                        let pq = sc.prop[j as usize];
                        if (g.need[t] >> (pq >> 8) as u64 & 1u64) != 0 {
                            g.need.set(d, g.need[d] | 1u64 << (pq & 0xFFu16) as u64);
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
                if r_site[i] != CO_NO_SITE && (scans.at((r_site[i] >> 32) as usize).s_par[(r_site[i] & 0xFFFFFFFFu64) as usize] & CO_DYN) != 0 {
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
                let site = r_site[i];
                let sp = if site != CO_NO_SITE {
                    scans.at((site >> 32) as usize).s_par[(site & 0xFFFFFFFFu64) as usize];
                } else {
                    0u8;
                };
                if g.need[t as usize] != 0 && !g.escaped {
                    if r_chk[i] == 0 {
                        g.escape(); // entered other than through a call site that checks its needs
                    } else if site != CO_NO_SITE && (scans.at((site >> 32) as usize).s_bad[(site & 0xFFFFFFFFu64) as usize] & g.need[t as usize]) != 0 {
                        g.escape();
                    }
                }
                if !g.escaped && site != CO_NO_SITE && g.stdm[g.module_of(t)] == 2 && (sp & CO_PAR_BAD) != 0 {
                    // A fn value std::parallel stores and runs later that the tracker cannot pin.
                    g.escape();
                }
                g.mark(t);
            }
        }
        // The fn values, for the cancellation analysis below. A closure written as a coroutine entry
        // is consumed by its spawn call: nothing calls it as a fn value.
        let mut seeded = Vector::<u8>::new();
        seeded.resize_default(nd);
        for si in 0..seeds.len() {
            seeded.set(seeds[si] as usize, 1);
        }
        let mut fnv = Vector::<u32>::new(); // the decls of `co_fnv`
        for i in 0..g.esc.len() {
            let e = g.esc[i];
            if g.closure[e as usize] == 0 || seeded[e as usize] == 0 {
                self.co_fnv.push(g.module_of(e) as u64 << 32 | g.node[e as usize] as u64);
                fnv.push(e);
            }
        }
        self.co_spans = replace(&mut g.spans, Vector::<Vector<u64>>::new());
        self.co_inst = replace(&mut g.inst, Vector::<Vector<u64>>::new());
        // Cancellation.
        let acc = self.glob_lookup(rt as ModuleId, "cancel_accept", false);
        if acc.node == NODE_NONE {
            return;
        }
        // The call records of every module, then the dispatch ones: a conformance method that reaches
        // acceptance marks each interface method of its name, as a call from that method's own span.
        let mut rec_m = Vector::<u32>::new();
        let mut rec_span = Vector::<u64>::new();
        let mut rec_t = Vector::<u64>::new();
        for m in 0..nm {
            let sc = scans.at(m);
            self.cancel_used = self.cancel_used || sc.c_used;
            for i in 0..sc.c_span.len() {
                rec_m.push(m as u32);
                rec_span.push(sc.c_span[i]);
                rec_t.push(sc.c_tgt[i]);
            }
        }
        for i in 0..ifm.len() {
            let h = ifm[i] >> 32; // the name hash
            let dm = defs[(ifm[i] & 0xFFFFFFFFu64) as usize];
            let msp = unsafe (&*self.module_ast_const((dm >> 32) as ModuleId)).at_const((dm & 0xFFFFFFFFu64) as NodeId).span;
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
        // Fixpoint over the call records. A record fires at most once: firing marks its enclosing
        // decls, and only a fresh mark can make another record's target newly reach acceptance. A
        // target is a decl, read at its span (a target that is no decl never reaches acceptance).
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
                    let td = g.decl_of(tm, (tk & 0xFFFFFFFFu64) as NodeId);
                    if td == CO_NONE || !self.cancel_marks.at(tm as usize).contains(&g.span[td as usize]) {
                        continue;
                    }
                }
                fired.set(i, 1);
                let m = rec_m[i] as usize;
                let cs = (rec_span[i] >> 32) as u32;
                let ce = (rec_span[i] & 0xFFFFFFFFu64) as u32;
                let row = &scans.at(m).c_row;
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
        for i in 0..fnv.len() {
            let e = fnv[i] as usize;
            if self.cancel_marks.at(g.module_of(e as u32)).contains(&g.span[e]) {
                self.cancel_fnv = true;
                break;
            }
        }
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
                    let e = (fnv(fn_name(a, src, f)) & 0xFFFFFFFFu64) << 32 | defs.len() as u64;
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

    /// Read-only view of module `mid`'s Ast for consumers outside the package (the Core IR lowerer). Asts
    /// live IN PLACE in the module table for their whole life: a stage mutates its module's Ast through a
    /// raw pointer into this slot, never by moving it out, so this read is always the live tree.
    pub const fn module_ast_const(self: &Self, mid: ModuleId) *const Ast {
        if self.wl_on {
            self.wl_take(mid);
        }
        return &self.modules[mid as usize].ast;
    }

    /// Module `mid`'s syntax and resolutions without its write lock (`module_ast_const`): what a scan
    /// over every module reads before it picks a candidate; both are frozen in a parallel stage.
    pub const fn module_syntax(self: &Self, mid: ModuleId) *const Ast {
        return &self.modules[mid as usize].ast;
    }

    // Take module `mid`'s write lock when the running task holds the engine lock and not yet the
    // module's lock.
    fn wl_take(self: &Self, mid: ModuleId) {
        if unsafe atomic::load_usize(&self.wl_eng, 0) != Ast::itok() {
            return;
        }
        let mp = (self as *const Package) as *mut Package;
        let a = unsafe &mut (*mp).modules[mid as usize].ast;
        if a.wl_held() {
            return;
        }
        a.wl_wait();
        unsafe (*mp).wl_got.push(mid);
    }

    /// Before the running task waits for the engine lock: release the module write lock it holds
    /// as a checker, and return that module (-1 for none). A holder of a write lock never waits
    /// for the engine lock, so the engine's wait for a write lock ends.
    pub fn wl_eng_begin(self: &mut Self) i64 {
        let tok = Ast::itok();
        for m in 0..self.modules.len() {
            if unsafe atomic::load_usize(&self.modules[m].ast.wl_owner, 0) == tok {
                self.modules[m].ast.wl_leave();
                return m as i64;
            }
        }
        return -1;
    }

    /// The running task now holds the engine lock: the modules it reads from here on are locked.
    pub fn wl_eng_hold(self: &mut Self) {
        unsafe atomic::store_usize(&mut self.wl_eng, Ast::itok(), 0);
    }

    /// Before the engine lock's release: drop every write lock the engine took.
    pub fn wl_eng_end(self: &mut Self) {
        unsafe atomic::store_usize(&mut self.wl_eng, 0, 0);
        for i in 0..self.wl_got.len() {
            self.modules[self.wl_got[i] as usize].ast.wl_leave();
        }
        self.wl_got.clear();
    }

    /// Whether interface method `f`'s first parameter is of type `Self` (behind references or
    /// pointers): its argument then names the implementor.
    pub const fn self_typed_param0(self: &Self, f: DefId) bool {
        let a = unsafe &*self.module_ast_const(f.module);
        let ps = a.at_const(f.node).as_data.function.params;
        if ps.len == 0 {
            return false;
        }
        let p0 = a.at_const(unsafe a.list(ps)[0]);
        if p0.kind != NodeKind::NODE_PARAMETER || p0.as_data.parameter.ty == NODE_NONE {
            return false;
        }
        let mut t = a.type_of(p0.as_data.parameter.ty);
        for _ in 0..8 {
            if t == TYPE_NONE {
                return false;
            }
            let y = *a.type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                return y.kind == TypeKind::TYPE_GENERIC && a.at_const(y.as_data.decl).kind == NodeKind::NODE_INTERFACE;
            }
            t = y.as_data.elem;
        }
        return false;
    }

    /// Whether function `f`'s first parameter is `self` (a method, not an associated function).
    pub const fn self_first(self: &Self, f: DefId) bool {
        let a = unsafe &*self.module_ast_const(f.module);
        let ps = a.at_const(f.node).as_data.function.params;
        if ps.len == 0 {
            return false;
        }
        let nm = a.at_const(a.at_const(unsafe a.list(ps)[0]).as_data.parameter.name).as_data.name.text;
        return self.modules[f.module as usize].source.as_str().slice(nm.start as usize, nm.end as usize) == "self";
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
        for i in 0..self.item_edges.len() {
            b += self.item_edges.at(i).capacity() * 16;
        }
        for i in 0..self.reach_scans.len() {
            b += self.reach_scans.at(i).retained_bytes();
        }
        return b + self.recur.retained_bytes();
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
    /// the last consumer of it (the instance graph's static_assert check) has run. Every retained record a later stage
    /// reads (kept Core IR, closure and asm facts) was copied out before.
    pub fn release_bodies(self: &mut Self) {
        for i in 0..self.modules.len() {
            if self.modules[i].has_ast {
                self.modules[i].ast.release_bodies();
                if !self.modules[i].ast.call_info_rel.on {
                    self.modules[i].ast.release_body_facts();
                }
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
        let mut m = switch self.mod_index.get(&fnv(path)) {
            Some(h) => *h,
            None => SYM_NONE,
        };
        while m != SYM_NONE {
            if self.modules[m as usize].path.as_str() == path {
                return m as i32;
            }
            m = self.mod_chain[m as usize];
        }
        for i in 0..self.alias_path.len() {
            if self.alias_path[i].as_str() == path {
                return self.alias_id[i] as i32;
            }
        }
        return -1;
    }

    // `find`, or the prelude module of `file` when a `std::` path names it: recorded as an alias.
    fn find_file(self: &mut Self, path: str, file: str) i32 {
        let ex = self.find(path);
        if ex >= 0 || !path.starts_with("std::") {
            return ex;
        }
        for i in 0..self.modules.len() {
            if self.modules[i].prelude && basename_of(self.modules[i].file.as_str()) == basename_of(file) && dutil::same_file(
                file,
                self.modules[i].file.as_str(),
            ) {
                self.alias_path.push(String::from_str(path));
                self.alias_id.push(i as u32);
                return i as i32;
            }
        }
        return -1;
    }

    /// Append in-memory source `src` as module "main" (file "<harness>"), last, to a package from
    /// `prelude_package_arch`, as `package_from_source_arch` appends it. A source that does not parse
    /// clears `ok`.
    pub fn add_source_module(self: &mut Self, src: str, target: i32) {
        let mut source = String::from_str(src);
        let mut parsed = parse_source(&mut source, "<harness>", false, Vector::<tok::Token>::new());
        let ok = parsed.ok;
        let sid = dutil::str_id(source.as_str());
        let id = self.add_module(
            String::from_str("main"),
            String::from_str("<harness>"),
            source,
            sid,
            0,
            replace(&mut parsed.ast, Ast::new(0)),
            ok,
        ) as usize;
        self.root = id as i32;
        if ok {
            self.modules[id].ast.module = id as ModuleId;
        } else {
            self.ok = false;
        }
        self.platform_filter_module(id, target);
    }

    // Add a module slot (taking ownership of `path`/`file`/`source`/`ast`; `src_id` and `mtime` as
    // `Module` records them) and return its id.
    fn add_module(
        self: &mut Self,
        path: String,
        file: String,
        source: String,
        src_id: u64,
        mtime: i64,
        ast: Ast,
        has_ast: bool,
    ) i32 {
        let id = self.modules.len() as i32;
        let h = fnv(path.as_str());
        self.mod_chain.push(
            switch self.mod_index.get(&h) {
                Some(v) => *v,
                None => SYM_NONE,
            },
        );
        self.mod_index.insert(h, id as u32);
        let (pkg, scope) = self.module_place(path.as_str(), file.as_str());
        self.modules.push(
            Module {
                path: path,
                file: file,
                source: source,
                src_id: src_id,
                mtime: mtime,
                ast: ast,
                has_ast: has_ast,
                prelude: false,
                pkg: pkg,
                scope: scope,
                implicit_index: file.as_str().ends_with("/"),
            },
        );
        // A module loaded after `bind_types` (an import resolved on demand) joins the package
        // identity at once: every module of a bound package interns into the one table.
        if has_ast && self.tt.deref().len() != 0 {
            self.modules[id as usize].ast.gt.p = self.tt.deref_mut();
        }
        return id;
    }

    // The package and the `pub(module)` scope of module `path`, read from `file` (`Module.pkg`, `Module.scope`).
    // The prelude's `__std::` paths are std's.
    fn module_place(self: &mut Self, path: str, file: str) (u16, String) {
        let p = if path.starts_with("__std::") {
            path.slice(2, path.len());
        } else {
            path;
        };
        let mut pkg = PKG_PROJECT;
        if p.starts_with("std::") {
            pkg = PKG_STD;
        } else if p.starts_with("vendor::") {
            let rest = p.slice(8, p.len());
            let f = rest.find("::");
            let name = rest.slice(
                0,
                if f < 0 {
                    rest.len();
                } else {
                    f as usize;
                },
            );
            let mut k: usize = 0;
            while k < self.vendors.len() && self.vendors[k].as_str() != name {
                k += 1;
            }
            if k == self.vendors.len() {
                self.vendors.push(String::from_str(name));
            }
            pkg = PKG_VENDOR + k as u16;
        } else if !self.std_root.is_empty() && file.starts_with(self.std_root.as_str()) && file.slice(
            self.std_root.len(),
            file.len(),
        ).starts_with("/ffi/") {
            pkg = PKG_FFI;
        }
        // `p` minus its last segment; a directory index (`a/b/b.spc` for `a::b`, or an implicit one) is its
        // directory's module, so its scope is `p` itself.
        let mut tail = String::with_capacity(p.len() + 16);
        let mut cut: usize = 0;
        let mut last: usize = 0;
        let mut i: usize = 0;
        while i < p.len() {
            if p.byte_at(i) == b':' {
                cut = i;
                last = i + 2;
                tail.push_byte(b'/');
                i += 2;
            } else {
                tail.push_byte(p.byte_at(i));
                i += 1;
            }
        }
        tail.push_byte(b'/');
        tail.push_str(p.slice(last, p.len()));
        tail.push_str(".spc");
        if file.ends_with("/") || file.ends_with(tail.as_str()) && file.len() > tail.len() && file.byte_at(
            file.len() - tail.len() - 1,
        ) == b'/' {
            return pkg, String::from_str(p);
        }
        return pkg, String::from_str(p.slice(0, cut));
    }

    /// Whether module `from` (`FROM_ANY`: the compiler itself) sees an item of module `owner` declared with
    /// visibility `vis` (`VIS_*`, `VIS_MODULE` or wider). A module outside the package (the standalone test
    /// Ast) is a project file at the root.
    pub const fn vis_ok(self: &Self, from: u32, owner: ModuleId, vis: u8) bool {
        if vis == VIS_PUB || from == owner as u32 || from == FROM_ANY {
            return true;
        }
        let o = self.modules.at(owner as usize);
        let fm = from as usize < self.modules.len();
        let fpkg = if fm {
            self.modules[from as usize].pkg;
        } else {
            PKG_PROJECT;
        };
        if vis == VIS_PACKAGE {
            return fpkg == o.pkg || o.pkg == PKG_STD && fpkg == PKG_PROJECT && self.std_internals;
        }
        if vis < VIS_MODULE || fpkg != o.pkg {
            return false;
        }
        let d = o.scope.as_str();
        if d.is_empty() {
            return true;
        }
        let fp = if fm {
            self.modules[from as usize].path.as_str();
        } else {
            "";
        };
        let f = if fp.starts_with("__std::") {
            fp.slice(2, fp.len());
        } else {
            fp;
        };
        return f.starts_with(d) && (f.len() == d.len() || f.slice(d.len(), f.len()).starts_with("::"));
    }

    /// Whether every module that sees an item of module `im` with visibility `iv` also sees an item of
    /// module `tm` with visibility `tv` (`VIS_*`; an item without a modifier is its file's).
    pub const fn vis_covers(self: &Self, im: ModuleId, iv: u8, tm: ModuleId, tv: u8) bool {
        if tv == VIS_PUB || im == tm && (tv >= iv || iv < VIS_MODULE) {
            return true;
        }
        let a = self.modules.at(im as usize);
        let b = self.modules.at(tm as usize);
        if iv == VIS_PUB || tv < VIS_MODULE || a.pkg != b.pkg {
            return false;
        }
        if tv == VIS_PACKAGE {
            return true;
        }
        let d = b.scope.as_str();
        if iv == VIS_PACKAGE || d.is_empty() {
            return d.is_empty();
        }
        let x = if iv == VIS_MODULE {
            a.scope.as_str();
        } else if a.path.as_str().starts_with("__std::") {
            a.path.as_str().slice(2, a.path.len());
        } else {
            a.path.as_str();
        };
        return x.starts_with(d) && (x.len() == d.len() || x.slice(d.len(), x.len()).starts_with("::"));
    }

    // Overlay slot naming the same file as `path`: load paths are root-relative, overlay keys canonical
    // absolute, so `path` is realpath'd when possible (raw compare stays as the fallback for files not on
    // disk). -1 = none.
    fn overlay_index(self: &Self, path: str) i32 {
        if self.overlay_files.len() == 0 {
            return -1;
        }
        let real = real_path_of(path);
        let key = if real.len() != 0 {
            real.as_str();
        } else {
            path;
        };
        for i in 0..self.overlay_files.len() {
            let f = self.overlay_files.at(i).as_str();
            if f == key || f == path {
                return i as i32;
            }
        }
        return -1;
    }

    // When a project file (under the root, then the alt root) names import path `parts` of `a` while the
    // prelude stage loaded module `m` for that path from another file (the import would get the std
    // module), append the error to `log`.
    fn std_shadowed(self: &Self, dc: &mut DirCache, a: &Ast, src: str, parts: NodeList, m: usize, log: &mut String) {
        let mut f = module_file_path(self.root_dir.as_str(), a, src, parts);
        if !dc.exists(f.as_str()) {
            f = module_index_path(self.root_dir.as_str(), a, src, parts);
            if !dc.exists(f.as_str()) {
                if self.alt_root.is_empty() {
                    return;
                }
                f = module_file_path(self.alt_root.as_str(), a, src, parts);
                if !dc.exists(f.as_str()) {
                    return;
                }
            }
        }
        let sf = self.modules.at(m).file.clone();
        if dutil::same_file(f.as_str(), sf.as_str()) {
            return;
        }
        let path = self.modules.at(m).path.as_str();
        log.format_into(
            "error: '{}' names module '{}', which the std prelude loads from '{}': rename the project file\n",
            f.as_str(),
            path,
            sf.as_str(),
        );
    }

    // Module `id`'s imports as a frame for the serial loader's stack. Collected before any import loads:
    // loading pushes to self.modules, which may realloc and move this module's by-value Ast.
    fn import_frame(self: &mut Self, id: i32, target: i32) LoadFrame {
        let mut dc = replace(&mut self.dir_cache, DirCache {});
        let mut f = LoadFrame {
            owner: id,
            paths: Vector::<String>::new(),
            files: Vector::<String>::new(),
            offs: Vector::<u32>::new(),
            next: 0,
        };
        let ap = (&self.modules.at(id as usize).ast) as *const Ast;
        let src = self.modules.at(id as usize).source.as_str();
        let mut log = String::new();
        self.collect_imports(
            unsafe &*ap,
            src,
            &mut dc,
            &PUnits {},
            target,
            &mut f.paths,
            &mut f.files,
            &mut f.offs,
            &mut log,
        );
        self.dir_cache = dc;
        self.print_log(&log);
        return f;
    }

    // Print the import errors `log` of a module as it gets its id; any clears `ok`.
    fn print_log(self: &mut Self, log: &String) {
        if log.len() != 0 {
            log.eprint();
            self.ok = false;
        }
    }

    // Every module `a` imports that is not loaded yet, as (module path, file path) pairs, plus the
    // dependencies a sugar keyword pulls in (`launch` -> the runtime, `select` -> the selector, `@blocking`
    // -> the pool). Skipping a loaded import saves resolve_import_file its filesystem probes: a hot std/ffi
    // module imported by many others would otherwise be probed once per importer; an import a unit of
    // `queued` resolved already takes that unit's file. A path can still repeat; load_module returns the
    // existing id for a loaded path. The errors of the imports go to `log`.
    //
    // `a`/`src` come in as raw views because the caller holds them inside `self.modules` and cannot lend them
    // across a `&mut self` call. `dc` is the package's dir cache, which the caller takes out of `self` for
    // the call.
    fn collect_imports(
        self: &Self,
        a: &Ast,
        src: str,
        dc: &mut DirCache,
        queued: &PUnits,
        target: i32,
        child_paths: &mut Vector<String>,
        child_files: &mut Vector<String>,
        child_offs: &mut Vector<u32>,
        log: &mut String,
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
                let wh = a.attr_of(id, AttrKind::ATTR_WHEN);
                let gated_out = pl != null && (unsafe (*pl).arg >> target as u32 & 1u32) == 0 || ar != null && self.arch >= 0 && (unsafe (*ar).arg >> self.arch as u32 & 1u32) == 0 || wh != null && (unsafe (*wh).arg >> self.when_index() & 1u32) == 0;
                if gated_out {
                    continue;
                }
                let parts = n.as_data.import_decl.path;
                let cp = join_parts(a, src, parts, "::");
                let found = self.find(cp.as_str());
                if found >= 0 {
                    if found as u32 < self.root_module {
                        self.std_shadowed(dc, a, src, parts, found as usize, log);
                    }
                    continue;
                }
                let u = queued.find(cp.as_str());
                if u < queued.units.len() && queued.units.at(u).resolved {
                    child_files.push(queued.units.at(u).file.clone());
                } else {
                    child_files.push(resolve_import_file(dc, root_dir, alt_root, std_root, a, src, parts));
                }
                child_paths.push(cp);
                child_offs.push(n.span.start);
            }
        }
        // Sugar-keyword dependency: the `launch` statement lowers to std::parallel::runtime::submit, so
        // pull that module in (transitively) ONLY when the keyword is used: a program that
        // never launches never loads the runtime. load_module returns the existing id for a loaded path, so a
        // duplicate push is harmless.
        if std_root.len() != 0 {
            if (a.sugar_marks & SUGAR_LAUNCH) != 0 {
                let mut rf = String::from_str(std_root);
                rf.push_str("/std/parallel/runtime.spc");
                child_paths.push(String::from_str("std::parallel::runtime"));
                child_files.push(rf);
                child_offs.push(IMPORT_OFF_NONE);
            }
            // Same for `select`, which lowers to std::parallel::selector's `sugar_*` shims.
            if (a.sugar_marks & SUGAR_SELECT) != 0 {
                let mut sf = String::from_str(std_root);
                sf.push_str("/std/parallel/selector.spc");
                child_paths.push(String::from_str("std::parallel::selector"));
                child_files.push(sf);
                child_offs.push(IMPORT_OFF_NONE);
            }
            // Same for `parallel for`, which lowers to std::parallel::data's `range`.
            if (a.sugar_marks & SUGAR_PARFOR) != 0 {
                let mut df = String::from_str(std_root);
                df.push_str("/std/parallel/data.spc");
                child_paths.push(String::from_str("std::parallel::data"));
                child_files.push(df);
                child_offs.push(IMPORT_OFF_NONE);
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
                child_offs.push(IMPORT_OFF_NONE);
            }
        }
    }

    /// Load `file_path` as module `mod_path` with its whole import closure (parallel when load jobs
    /// are set and no overlays are active). Returns the module's id, or -1 when the root is unreadable.
    pub fn load_module(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        if unsafe G_LOAD_JOBS != 1 && self.overlay_files.len() == 0 {
            return self.load_module_par(mod_path, file_path, bootstrap_tags, target);
        }
        return self.load_module_serial(mod_path, file_path, -1, IMPORT_OFF_NONE, bootstrap_tags, target);
    }

    // Speculative wave-parallel subtree load: parse tasks fan out per wave; the coordinator
    // resolves each finished unit's imports (dir-cache memo stays serial) and enqueues unseen
    // files; a serial DFS replay then assigns module ids exactly as the recursive loader would.
    // A unit that failed to read or parse falls back to the serial loader at replay, so its
    // diagnostics print with the serial wording, position and order.
    fn load_module_par(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        let existing = self.find_file(mod_path, file_path);
        if existing >= 0 {
            return existing;
        }
        let mut us = PUnits {};
        us.push(mod_path, file_path, false);
        self.par_discover(&mut us, bootstrap_tags, target);
        return self.par_replay(&mut us, 0, bootstrap_tags, target);
    }

    // Parse the units of `us` and, transitively, the imports they name that are neither loaded nor
    // queued, as units of their own: a unit's imports start parsing as soon as it is parsed. The dir
    // cache is sorted at the end, so its order does not depend on the order the tasks finish in. The
    // replay's serial loads use the dir cache again: it is out of `self` until then.
    fn par_discover(self: &mut Self, us: &mut PUnits, bootstrap_tags: bool, target: i32) {
        let mut dc = replace(&mut self.dir_cache, DirCache {});
        let done = PDone { m: psy::Mutex::<Vector<u32>>::new(Vector::<u32>::new()), cv: psy::Condvar::new() };
        let wg = psy::WaitGroup::new();
        let mut started: usize = 0; // the units before it are parsing or parsed
        let mut busy: usize = 0; // the tasks not reported yet
        let mut ready = Vector::<u32>::new(); // the units parsed and not yet resolved
        // Each pass starts the units queued since the last one, or takes at least one finished unit:
        // every unit starts and finishes once.
        loop {
            if busy == 0 && us.units.len() - started == 1 {
                // A lone unit (the root of a load, mostly) parses inline: a task could overlap with
                // nothing and would start the worker pool for it.
                par_parse_one(us.task(started, bootstrap_tags, &done));
                ready.push(started as u32);
                started += 1;
            }
            while started < us.units.len() {
                let t = us.task(started, bootstrap_tags, &done);
                wg.add(1);
                let wgc = wg.clone();
                launch || {
                    par_parse_task(t);
                    wgc.done();
                };
                busy += 1;
                started += 1;
            }
            if ready.len() == 0 {
                if busy == 0 {
                    break;
                }
                let mut g = done.m.lock();
                while g.get().len() == 0 {
                    done.cv.wait_masked(&g);
                }
                ready = replace(g.get_mut(), ready);
                busy -= ready.len();
            }
            for r in 0..ready.len() {
                let k = ready[r] as usize;
                if !us.units.at(k).ok {
                    continue;
                }
                let ap = (&us.units.at(k).ast) as *const Ast;
                let sp2 = us.units.at(k).source.as_str();
                let mut all_paths = Vector::<String>::new();
                let mut all_files = Vector::<String>::new();
                let mut all_offs = Vector::<u32>::new();
                let mut log = String::new();
                self.collect_imports(
                    unsafe &*ap,
                    sp2,
                    &mut dc,
                    us,
                    target,
                    &mut all_paths,
                    &mut all_files,
                    &mut all_offs,
                    &mut log,
                );
                us.units.index_mut(k).log = log;
                for c in 0..all_paths.len() {
                    let cp = all_paths[c].as_str();
                    if self.find_file(cp, all_files[c].as_str()) >= 0 {
                        continue;
                    }
                    let seen = us.find(cp) < us.units.len();
                    us.units.index_mut(k).child_paths.push(String::from_str(cp));
                    us.units.index_mut(k).child_files.push(String::from_str(all_files[c].as_str()));
                    us.units.index_mut(k).child_offs.push(all_offs[c]);
                    if !seen {
                        us.push(cp, all_files[c].as_str(), true);
                    }
                }
            }
            ready.clear();
        }
        // A task touches `done` until its report: it may not outlive this frame.
        wg.wait_masked();
        dc.sort();
        self.dir_cache = dc;
    }

    // DFS in recorded import order over the parsed units from unit `r`: the id-assignment replay. Consumes
    // each unit's source/ast on first visit (later visits of the same path are find() hits).
    fn par_replay(self: &mut Self, us: &mut PUnits, r: usize, bootstrap_tags: bool, target: i32) i32 {
        let mut expand = false;
        let root = self.par_visit(us, r, -1, IMPORT_OFF_NONE, bootstrap_tags, target, &mut expand);
        // (unit << 32 | next import) pairs: an explicit stack, bounded by the unit count, so a long import
        // chain cannot exhaust the call stack.
        // `ids`: the module id of each stack entry's unit, the importer a child's read failure names.
        let mut stack = Vector::<u64>::new();
        let mut ids = Vector::<i32>::new();
        if expand {
            stack.push(r as u64 << 32);
            ids.push(root);
        }
        while stack.len() != 0 {
            let top = stack.len() - 1;
            let ui = (stack[top] >> 32) as usize;
            let c = (stack[top] & 0xFFFFFFFFu64) as usize;
            if c == us.units.at(ui).child_paths.len() {
                let _ = stack.pop();
                let _ = ids.pop();
                continue;
            }
            stack.set(top, stack[top] + 1);
            let cp = us.units.at(ui).child_paths.at(c).as_str();
            // A visited unit gave its path away, so a loaded import is found here, not among the units.
            if self.find_file(cp, us.units.at(ui).child_files.at(c).as_str()) >= 0 {
                continue;
            }
            // The discovery gave every recorded import its own unit.
            let ci = us.find(cp);
            assert(ci < us.units.len());
            let off = us.units.at(ui).child_offs[c];
            let id = self.par_visit(us, ci, ids[top], off, bootstrap_tags, target, &mut expand);
            if expand {
                stack.push(ci as u64 << 32);
                ids.push(id);
            }
        }
        return root;
    }

    // Give unit `ui` its module id: a loaded path keeps its id, a unit that failed to read or parse goes
    // through the serial loader (which prints its diagnostics, at the import `from` writes at `off`, and
    // loads its imports), and a parsed unit is added and prints its import errors. `expand` reports the
    // last case: its imports are the replay's to visit.
    fn par_visit(
        self: &mut Self,
        us: &mut PUnits,
        ui: usize,
        from: i32,
        off: u32,
        bootstrap_tags: bool,
        target: i32,
        expand: &mut bool,
    ) i32 {
        *expand = false;
        let ex = self.find_file(us.units.at(ui).path.as_str(), us.units.at(ui).file.as_str());
        if ex >= 0 {
            return ex;
        }
        if !us.units.at(ui).ok {
            let pth = String::from_str(us.units.at(ui).path.as_str());
            let fl = String::from_str(us.units.at(ui).file.as_str());
            return self.load_module_serial(pth.as_str(), fl.as_str(), from, off, bootstrap_tags, target);
        }
        let u = us.units.index_mut(ui).deref_mut();
        let id = self.add_module(
            replace(&mut u.path, String::new()),
            replace(&mut u.file, String::new()),
            replace(&mut u.source, String::new()),
            u.src_id,
            u.mtime,
            replace(&mut u.ast, Ast::new(0)),
            true,
        );
        self.modules[id as usize].ast.module = id as ModuleId;
        let log = replace(&mut us.units.index_mut(ui).log, String::new());
        self.print_log(&log);
        *expand = true;
        return id;
    }

    // Load `mod_path` and its import closure depth-first. A module gets its id before its imports, which
    // load in declaration order; a module already loaded (an import cycle) keeps its id: modules are
    // parsed whole before any resolution, so mutual imports need no special handling. The stack is
    // explicit, bounded by the module count, so a long import chain cannot exhaust the call stack. `from`
    // and `off` name the import that asks for `mod_path` (-1: none), for a read failure's location.
    fn load_module_serial(
        self: &mut Self,
        mod_path: str,
        file_path: str,
        from: i32,
        off: u32,
        bootstrap_tags: bool,
        target: i32,
    ) i32 {
        let existing = self.find_file(mod_path, file_path);
        if existing >= 0 {
            return existing;
        }
        let root = self.parse_module(mod_path, file_path, from, off, bootstrap_tags);
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
            let from = stack.at(top).owner;
            let off = stack.at(top).offs[k];
            if self.find_file(cp.as_str(), cf.as_str()) >= 0 {
                continue;
            }
            if unsafe G_LOAD_JOBS != 1 && self.overlay_files.len() == 0 {
                // A unit the parallel replay handed back (it failed to parse): its imports return to the
                // parallel loader, as load_module routes them.
                let _ = self.load_module_par(cp.as_str(), cf.as_str(), bootstrap_tags, target);
                continue;
            }
            let id = self.parse_module(cp.as_str(), cf.as_str(), from, off, bootstrap_tags);
            if id >= 0 && self.modules[id as usize].has_ast {
                stack.push(self.import_frame(id, target));
            }
        }
        return root;
    }

    // Read, parse and add one module (not its imports). -1 when the file cannot be read, reported at the
    // import module `from` writes at `off` (`file:line: `, or `file: ` for a keyword's dependency; none
    // when `from` is -1); a module that fails to parse is added without an Ast. Either failure clears `ok`.
    fn parse_module(self: &mut Self, mod_path: str, file_path: str, from: i32, off: u32, bootstrap_tags: bool) i32 {
        let mut source = String::new();
        let mut mt: i64 = 0;
        let mut sid: u64 = 0;
        let ovi = self.overlay_index(file_path);
        if ovi >= 0 {
            // Clone + pad exactly like read_file (the lexer relies on the read-ahead NUL sentinel).
            let t = self.overlay_texts.at(ovi as usize);
            let mut s = String::with_capacity(t.len() + lexer::SOURCE_PAD);
            s.push_str(t.as_str());
            s.pad_nul(lexer::SOURCE_PAD);
            sid = dutil::str_id(s.as_str());
            source = s;
        } else {
            switch read_module(mod_path, file_path, &mut mt, &mut sid) {
                Some(s) => {
                    source = s;
                },
                None => {
                    let mut msg = String::new();
                    if from >= 0 {
                        let m = self.modules.at(from as usize);
                        msg.push_string(&m.file);
                        if off != IMPORT_OFF_NONE {
                            msg.format_into(":{}", errs::line_of(m.source.as_str(), off));
                        }
                        msg.push_str(": ");
                    }
                    msg.format_into("error: cannot open module '{}' ({})\n", mod_path, file_path);
                    msg.eprint();
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
            sid,
            mt,
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
                            as_data: NodeAs { aggregate: AggregateData { name: NODE_NONE, vis: VIS_PUB } },
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
    pub const fn builtin_of_decl(self: &Self, module: ModuleId, node: NodeId) i32 {
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

    /// Whether concrete type `t` (pool `dm`) conforms to interface `iface` with arguments `wa[0..wn]`
    /// (pool `dm`), as the backend tells apart conformances whose interface arguments all fit (`i32 as
    /// Count<T>` with `T: Num` against `i32 as Count<W<T>>`): a conformance by target, then a generic
    /// one, whose arguments match and whose parameters' bounds hold (`ext_bounds_concrete`). The
    /// marker interfaces (`Copy`, `Send`, `Sync`, `Free`, `FnPtr`), a type parameter and a nesting past
    /// the bound answer true: the checker proved the program's bounds, this only chooses.
    pub fn conf_holds(self: &Self, dm: ModuleId, t: TypeId, iface: DefId, wa: *const TypeId, wn: u32, depth: u32) bool {
        if depth > 8 || t == TYPE_NONE || iface.node == NODE_NONE {
            return true;
        }
        let ia = self.module_ast_const(iface.module);
        let inn = unsafe (*ia).at_const(iface.node);
        if inn.kind != NodeKind::NODE_INTERFACE {
            return true;
        }
        for marker in ["Copy", "Send", "Sync", "Free", "FnPtr"] {
            if self.is_prelude_item(iface, marker) {
                return true;
            }
        }
        let da = self.module_ast_const(dm) as *mut Ast;
        let y = *unsafe (*da).type_at(t);
        let mut it = TyInstance { module: y.module, decl: NODE_NONE, n: 0 };
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            it.decl = y.as_data.decl;
        } else if unsafe (*da).targs_of(t, &mut it) {} else if y.kind == TypeKind::TYPE_BUILTIN {
            it.module = self.core_module;
            it.decl = self.builtin_decl(y.as_data.builtin);
        }
        if it.decl == NODE_NONE {
            // A type parameter, `dyn`, a reference, a pointer, an array: conformances the checker
            // derives beyond the written ones.
            return true;
        }
        let want = unsafe (*da).intern_dyn(iface.module, iface.node, wa, wn as u8, TypeQualifier::TYPE_QUAL_NONE as u8);
        // The extends conforming to `iface` in package order: the index once the package metadata
        // is built (`ensure_sigs`), else a scan.
        let mut scan = Vector::<u64>::new();
        let mut lo: usize = 0;
        let mut hi: usize = 0;
        if self.idx.sigs_built {
            switch self.idx.conf_of.get(&skey_mix(0, iface.module as u64 << 32 | iface.node as u64)) {
                Some(v) => {
                    lo = (*v >> 32) as usize;
                    hi = (*v & 0xFFFFFFFFu64) as usize;
                },
                None => {},
            };
        } else {
            for m in 0..self.modules.len() {
                for k in self.idx.mod_exts[m] as usize..self.idx.mod_exts[m + 1] as usize {
                    let row = m as u64 << 32 | self.idx.exts[k] as u64;
                    let d = self.ext_iface(row);
                    if d.module == iface.module && d.node == iface.node {
                        scan.push(row);
                    }
                }
            }
            hi = scan.len();
        }
        let rows = if self.idx.sigs_built {
            &self.idx.confs;
        } else {
            &scan;
        };
        for pass in 0..2 {
            for x in lo..hi {
                let em = (rows[x] >> 32) as ModuleId;
                let ext = rows[x] as NodeId;
                let ea = self.module_ast_const(em);
                let ed = unsafe (*ea).at_const(ext).as_data.extend_def;
                if ed.generics.len > 8 {
                    continue;
                }
                let bp = ext_blanket(unsafe &*ea, unsafe (*ea).type_of(ed.target_type), unsafe &*ea, em, ext);
                if bp >= 0 != (pass == 1) {
                    continue;
                }
                let tg = unsafe (*ea).resolution_def(ed.target_type);
                let dt = unsafe (*ea).type_of(ed.interface_type);
                if bp < 0 && (tg.module != it.module || tg.node != it.decl) || dt == TYPE_NONE {
                    continue;
                }
                let mut lp: [DefId; 8] = [[0] = DefId { module: 0, node: NODE_NONE }];
                let mut la: [TypeId; 8] = [[0] = TYPE_NONE];
                let mut ln: u32 = 0;
                if bp >= 0 {
                    ln = ed.generics.len;
                    for g in 0..ln {
                        unsafe lp[g as usize] = DefId { module: em, node: unsafe (*ea).list(ed.generics)[g as usize] };
                    }
                    unsafe la[bp as usize] = t;
                } else if !self.ext_solve(em, ext, dm, &it, &mut lp[0], &mut la[0], &mut ln) {
                    continue;
                }
                let mut open = false;
                for g in 0..ln {
                    open = open || unsafe la[g as usize] == TYPE_NONE;
                }
                if open && !self.lunify(em, dt, dm, want, ed.generics, &mut la[0], 0) {
                    continue;
                }
                let mut g = TYPE_NONE;
                if !self.ground_local(em, dt, dm, &lp[0], &la[0], ln, &mut g, depth + 1) || g != want {
                    continue;
                }
                if self.ext_bounds_concrete(em, ext, &lp[0], &la[0], ln, dm, depth + 1) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Whether the bounds of extend `ext`'s parameters (module `em`) hold for their values `la[0..ln]`
    /// (pool `dm`; TYPE_NONE: unbound, not checked), as `conf_holds` decides a bound.
    pub fn ext_bounds_concrete(
        self: &Self,
        em: ModuleId,
        ext: NodeId,
        lp: *const DefId,
        la: *const TypeId,
        ln: u32,
        dm: ModuleId,
        depth: u32,
    ) bool {
        let ea = self.module_ast_const(em);
        let gens = unsafe (*ea).at_const(ext).as_data.extend_def.generics;
        let da = self.module_ast_const(dm) as *mut Ast;
        let mut g: u32 = 0;
        while g < gens.len && g < ln {
            let v = unsafe la[g as usize];
            let gp = unsafe (*ea).at_const(unsafe (*ea).list(gens)[g as usize]);
            g += 1;
            if v == TYPE_NONE || gp.as_data.generic_param.is_const {
                continue;
            }
            let bs = gp.as_data.generic_param.bounds;
            for b in 0..bs.len {
                let bid = unsafe (*ea).list(bs)[b as usize];
                let bi = unsafe (*ea).resolution_def(bid);
                if bi.node == NODE_NONE {
                    continue;
                }
                // The bound's interface arguments under the extend's values (its recorded `dyn I<..>`).
                let mut wa = TyInstance {};
                let bt = unsafe (*ea).type_of(bid);
                if bt != TYPE_NONE && unsafe (*ea).type_at(bt).kind == TypeKind::TYPE_DYN {
                    let mut gb = TYPE_NONE;
                    if !self.ground_local(em, bt, dm, lp, la, ln, &mut gb, depth + 1) || unsafe (*da).type_at(gb).kind != TypeKind::TYPE_DYN {
                        continue;
                    }
                    wa = *unsafe (*da).instance(unsafe (*da).type_at(gb).rec());
                } else if unsafe (*ea).at_const(bid).kind != NodeKind::NODE_TYPE_PATH || unsafe (*ea).at_const(bid).as_data.type_path.args.len != 0 {
                    continue;
                }
                if !self.conf_holds(dm, v, bi, &wa.args[0], wa.n, depth + 1) {
                    return false;
                }
            }
        }
        return true;
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
        } else if unsafe (*da).targs_of(ai.args[0], &mut it) {} else if y.kind == TypeKind::TYPE_BUILTIN {
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
        // The conformances by target first, then the generic ones (`T as I`), as every other
        // conformance lookup orders them: a generic one applies only where no own one does.
        for pass in 0..2 {
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
                    let bp = ext_blanket(unsafe &*ea, unsafe (*ea).type_of(ed.target_type), unsafe &*ea, em, ext);
                    if bp >= 0 != (pass == 1) {
                        continue;
                    }
                    if ir.module != ai.module || ir.node != iface || bp < 0 && (tg.module != it.module || tg.node != it.decl) || dt == TYPE_NONE || ed.generics.len > 8 {
                        continue;
                    }
                    let mut lp: [DefId; 8] = [[0] = DefId { module: 0, node: NODE_NONE }];
                    let mut la: [TypeId; 8] = [[0] = TYPE_NONE];
                    let mut ln: u32 = 0;
                    if bp >= 0 {
                        // A generic extend: its target parameter is the type itself.
                        ln = ed.generics.len;
                        for g in 0..ln {
                            unsafe lp[g as usize] = DefId {
                                module: em,
                                node: unsafe (*ea).list(ed.generics)[g as usize],
                            };
                        }
                        unsafe la[bp as usize] = ai.args[0];
                    } else if !self.ext_solve(em, ext, dm, &it, &mut lp[0], &mut la[0], &mut ln) {
                        continue;
                    }
                    // The parameters the target does not name: the bound's interface arguments solve them.
                    let mut open = false;
                    for g in 0..ln {
                        open = open || unsafe la[g as usize] == TYPE_NONE;
                    }
                    if open && !self.lunify(em, dt, dm, want, ed.generics, &mut la[0], 0) {
                        continue;
                    }
                    let mut g = TYPE_NONE;
                    if !self.ground_local(em, dt, dm, &lp[0], &la[0], ln, &mut g, depth + 1) || g != want {
                        continue;
                    }
                    // Of conformances whose arguments fit, the one whose bounds hold.
                    if !self.ext_bounds_concrete(em, ext, &lp[0], &la[0], ln, dm, depth + 1) {
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
        }
        return false;
    }

    // The values extend `ext` (module `em`) gives its parameters for instance `it` of its target
    // (arguments concrete types of pool `dm`), as the bindings `lp[i]` -> `la[i]` (pool `dm`), `ln` of
    // them. False when the extend does not apply to the instance.
    pub fn ext_solve(
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
        let free = ext_free_params(unsafe &*ea, pat, unsafe &*ea, em, ext);
        if ext_is_identity(unsafe &*ea, pat, unsafe &*ea, em, ext) {
            for i in 0..gens.len {
                if (free >> i as u64 & 1u64) != 0 {
                    continue;
                }
                if i >= it.n as u32 {
                    return false;
                }
                unsafe la[i as usize] = unsafe it.args[i as usize];
            }
            return true;
        }
        let mut pi = TyInstance {};
        let _ = unsafe (*ea).targs_of(pat, &mut pi);
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
            if unsafe la[i as usize] == TYPE_NONE && (free >> i as u64 & 1u64) == 0 {
                return false;
            }
        }
        return true;
    }

    // Bind each parameter `gens` (module `em`) left TYPE_NONE in `la` that pattern type `pt` (module
    // `em`) names so that it equals type `at` (pool `dm`): a parameter takes the type (or must equal
    // its value), an instance, `dyn`, vector, mask, array, slice, reference or pointer matches part by
    // part, and a type naming no parameter must be the same. False when they cannot match.
    fn lunify(
        self: &Self,
        em: ModuleId,
        pt: TypeId,
        dm: ModuleId,
        at: TypeId,
        gens: NodeList,
        la: *mut TypeId,
        depth: u32,
    ) bool {
        if depth > 8 || pt == TYPE_NONE || at == TYPE_NONE {
            return false;
        }
        let ea = self.module_ast_const(em);
        let da = self.module_ast_const(dm) as *mut Ast;
        let py = *unsafe (*ea).type_at(pt);
        if py.kind == TypeKind::TYPE_GENERIC && py.module == em {
            for i in 0..gens.len {
                if unsafe (*ea).list(gens)[i as usize] == py.as_data.decl {
                    if unsafe la[i as usize] == TYPE_NONE {
                        unsafe la[i as usize] = at;
                    }
                    return unsafe la[i as usize] == at;
                }
            }
        }
        if unsafe (*ea).type_concrete(pt) {
            return unsafe (*da).reintern(unsafe &*ea, pt) == at;
        }
        let ay = *unsafe (*da).type_at(at);
        if py.kind != ay.kind {
            return false;
        }
        if py.kind == TypeKind::TYPE_INSTANCE || py.kind == TypeKind::TYPE_DYN {
            let pi = *unsafe (*ea).instance(py.as_data.inst);
            let ai = *unsafe (*da).instance(ay.as_data.inst);
            if pi.module != ai.module || pi.decl != ai.decl || pi.n != ai.n {
                return false;
            }
            for k in 0..pi.n {
                if !self.lunify(em, unsafe pi.args[k as usize], dm, unsafe ai.args[k as usize], gens, la, depth + 1) {
                    return false;
                }
            }
            return true;
        }
        if py.arr_like() {
            if py.kind != TypeKind::TYPE_MASK && !self.lunify(
                em,
                py.as_data.arr.elem,
                dm,
                ay.as_data.arr.elem,
                gens,
                la,
                depth + 1,
            ) {
                return false;
            }
            if py.is_vec() || py.arr_sym() && ay.arr_sym() {
                return self.lunify(em, py.as_data.arr.len, dm, ay.as_data.arr.len, gens, la, depth + 1);
            }
            if py.arr_sym() && !ay.arr_sym() {
                // A concrete array holds its length as a count: a length parameter takes it as a
                // constant of the parameter's type.
                let ly = *unsafe (*ea).type_at(py.as_data.arr.len);
                if ly.kind == TypeKind::TYPE_GENERIC && ly.module == em {
                    let ct = unsafe (*da).const_value(ay.as_data.arr.len, self.const_param_bt(em, ly.as_data.decl));
                    return self.lunify(em, py.as_data.arr.len, dm, ct, gens, la, depth + 1);
                }
                return true;
            }
            return py.arr_sym() || py.as_data.arr.len == ay.as_data.arr.len;
        }
        if py.kind == TypeKind::TYPE_REFERENCE || py.kind == TypeKind::TYPE_POINTER || py.kind == TypeKind::TYPE_SLICE {
            return self.lunify(em, py.as_data.elem, dm, ay.as_data.elem, gens, la, depth + 1);
        }
        return false;
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
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.arr_like() {
            let mut e = TYPE_NONE;
            if !self.ground_local(pm, y.as_data.elem, dm, lp, la, ln, &mut e, depth + 1) {
                return false;
            }
            if y.arr_sym() {
                let mut lt = TYPE_NONE;
                if !self.ground_local(pm, y.as_data.arr.len, dm, lp, la, ln, &mut lt, depth + 1) {
                    return false;
                }
                *out = unsafe (*da).intern_array(y.kind, e, lt);
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
            idx.mod_globs.push(idx.globs.len() as u32);
            idx.mod_exts.push(idx.exts.len() as u32);
            if self.modules[m].has_ast {
                self.index_module(&mut idx, m as ModuleId);
            }
        }
        idx.mod_items.push(idx.items.len() as u32);
        idx.mod_imports.push(idx.imports.len() as u32);
        idx.mod_globs.push(idx.globs.len() as u32);
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
                if im.owner != ITEM_NONE || im.name == SYM_NONE {
                    continue;
                }
                idx.pl_names.insert(im.name);
                if im.is_type || im.kind == ItemKind::IK_FUNCTION as u8 && unsafe (*self.module_ast_const(m as ModuleId)).at_const(
                    im.node,
                ).as_data.function.generics.len != 0 {
                    idx.pl_stems.insert(im.name);
                }
                if !vis_exported(im.vis) {
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
        self.index_shadows(&mut idx);
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

    /// Index the modules appended since the index was built (`load_user` after a checked prelude),
    /// keeping every existing module's items, symbols and ids: the modules before them import none of
    /// them. The import components, the sugar shims and the signature table are computed again.
    pub fn index_append(self: &mut Self) {
        let n = self.modules.len();
        let from = self.idx.built_mods as usize;
        if from == n {
            return;
        }
        // Drop the end sentinels, append the new modules' rows, put the sentinels back.
        let _ = self.idx.mod_items.pop();
        let _ = self.idx.mod_imports.pop();
        let _ = self.idx.mod_globs.pop();
        let _ = self.idx.mod_exts.pop();
        let mut idx = replace(&mut self.idx, PkgIndex {});
        for m in from..n {
            idx.mod_items.push(idx.items.len() as u32);
            idx.name_maps.push(Map::<u64, u32>::new());
            idx.mod_imports.push(idx.imports.len() as u32);
            idx.mod_globs.push(idx.globs.len() as u32);
            idx.mod_exts.push(idx.exts.len() as u32);
            if self.modules[m].has_ast {
                self.index_module(&mut idx, m as ModuleId);
            }
        }
        idx.mod_items.push(idx.items.len() as u32);
        idx.mod_imports.push(idx.imports.len() as u32);
        idx.mod_globs.push(idx.globs.len() as u32);
        idx.mod_exts.push(idx.exts.len() as u32);
        idx.built_mods = n as u32;
        let mut tgt = Vector::<u32>::with_capacity(idx.imports.len());
        for e in 0..idx.imports.len() {
            tgt.push(idx.imports[e]);
        }
        idx.scc_of.clear();
        let _ = gitems::condense(n, &idx.mod_imports, &tgt, &mut idx.scc_of);
        idx.sugar_items.clear();
        idx.sigs.clear();
        idx.sig_types.clear();
        idx.sig_of = Map::<u64, u32>::new();
        idx.confs.clear();
        idx.conf_of = Map::<u64, u64>::new();
        idx.sigs_built = false;
        idx.shadow = Set::<SymbolId>::new();
        self.index_shadows(&mut idx);
        self.idx = idx;
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
    /// fn/method, its param and return TypeIds copied out of the owner's per-node type table, then
    /// the conformances by interface (`PkgIndex.confs`). Runs once, after the whole package is
    /// type-checked (the driver calls it before instance planning); an index rebuild (a module
    /// appended later) clears the tables, and the next call refills them.
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
        let mut rows = Vector::<u64>::with_capacity(self.idx.exts.len());
        let mut keys = Vector::<u64>::with_capacity(self.idx.exts.len());
        for m in 0..self.modules.len() {
            for k in self.idx.mod_exts[m] as usize..self.idx.mod_exts[m + 1] as usize {
                let row = m as u64 << 32 | self.idx.exts[k] as u64;
                let d = self.ext_iface(row);
                if d.node != NODE_NONE {
                    rows.push(row);
                    keys.push(skey_mix(0, d.module as u64 << 32 | d.node as u64));
                }
            }
        }
        // Chain the rows per interface back to front, then lay each chain out at its first row.
        let mut head = Map::<u64, u32>::new();
        let mut next = Vector::<u32>::new();
        next.resize_default(rows.len());
        let mut x = rows.len();
        while x > 0 {
            x -= 1;
            next[x] = (switch head.get(&keys[x]) {
                Some(v) => *v,
                None => CO_NONE,
            });
            head.insert(keys[x], x as u32);
        }
        self.idx.confs.reserve(rows.len());
        for x in 0..rows.len() {
            if *head.get(&keys[x]).unwrap() != x as u32 {
                continue;
            }
            let lo = self.idx.confs.len() as u64;
            let mut r = x as u32;
            while r != CO_NONE {
                self.idx.confs.push(rows[r as usize]);
                r = next[r as usize];
            }
            self.idx.conf_of.insert(keys[x], lo << 32 | self.idx.confs.len() as u64);
        }
    }

    // The interface the extend of `row` (module << 32 | extend node) conforms its target to, node
    // NONE for a plain extend.
    fn ext_iface(self: &Self, row: u64) DefId {
        let a = self.module_ast_const((row >> 32) as ModuleId);
        let ip = unsafe (*a).at_const(row as NodeId).as_data.extend_def.interface_type;
        if ip == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        return unsafe (*a).resolution_def(ip);
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
        let mut vis = VIS_PRIVATE;
        let mut name_node = NODE_NONE;
        let mut kind = ItemKind::IK_STRUCT;
        switch n.kind {
            NODE_STRUCT | NODE_ENUM => {
                name_node = n.as_data.aggregate.name;
                vis = n.as_data.aggregate.vis;
                if n.kind == NodeKind::NODE_ENUM {
                    kind = ItemKind::IK_ENUM;
                }
            },
            NODE_TYPE_ALIAS => {
                name_node = n.as_data.type_alias.name;
                vis = n.as_data.type_alias.vis;
                kind = ItemKind::IK_TYPE_ALIAS;
            },
            NODE_INTERFACE => {
                name_node = n.as_data.interface_def.name;
                vis = n.as_data.interface_def.vis;
                kind = ItemKind::IK_INTERFACE;
            },
            NODE_FUNCTION => {
                name_node = n.as_data.function.name;
                vis = n.as_data.function.vis;
                is_type = false;
                kind = if owner == ITEM_NONE {
                    ItemKind::IK_FUNCTION;
                } else {
                    ItemKind::IK_METHOD;
                };
            },
            NODE_CONST => {
                name_node = n.as_data.const_def.name;
                vis = n.as_data.const_def.vis;
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
        let sym = idx.syms.intern(unsafe str::from_raw(np, len as usize));
        let it = idx.items.len() as ItemId;
        idx.items.push(
            ItemMeta {
                module: mid,
                node: node,
                owner: owner,
                kind: kind as u8,
                name: sym,
                vis: vis,
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
            } + if vis_exported(vis) {
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

    // Fill `idx.shadow` (see PkgIndex) when the package holds exactly one program module besides the
    // runtime.
    fn index_shadows(self: &Self, idx: &mut PkgIndex) {
        let n = self.modules.len();
        let mut user = n;
        for m in 0..n {
            if !self.modules[m].prelude && !self.is_rt(m as i32) {
                if user != n {
                    return;
                }
                user = m;
            }
        }
        if user == n {
            return;
        }
        let ast = unsafe &*self.module_ast_const(user as ModuleId);
        for it in idx.mod_items[user] as usize..idx.mod_items[user + 1] as usize {
            let im = idx.items.at(it);
            if im.owner != ITEM_NONE || im.name == SYM_NONE || !idx.pl_names.contains(&im.name) {
                continue;
            }
            // An extern item IS its C symbol.
            let d = ast.at_const(im.node);
            let ext = switch d.kind {
                NODE_FUNCTION => d.as_data.function.is_extern(),
                NODE_STRUCT | NODE_ENUM => d.as_data.aggregate.is_extern,
                NODE_CONST => d.as_data.const_def.is_extern,
                _ => false,
            };
            if !ext {
                idx.shadow.insert(im.name);
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
        let src = unsafe str::from_raw(srcp as *const u8, self.modules[m].source.len());
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
                    let mut gdup = !n.as_data.import_decl.glob;
                    for e in idx.mod_globs[m] as usize..idx.globs.len() {
                        gdup = gdup || idx.globs[e] == c as ModuleId;
                    }
                    if !gdup {
                        idx.globs.push(c as ModuleId);
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
                        vis: VIS_PRIVATE,
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

    /// Find a top-level declaration named `name` in module `mid` that module `from` sees (`vis_ok`;
    /// `FROM_ANY`: every exported one): a type when `want_type`, otherwise a value. Returns the decl's
    /// NodeId within module `mid`'s Ast, or NODE_NONE. O(1): a byte-exact symbol probe plus one name-map
    /// probe into the package declaration index.
    @always_inline
    pub fn lookup(self: &Self, from: u32, mid: ModuleId, name: str, want_type: bool) NodeId {
        if !self.modules[mid as usize].has_ast {
            return NODE_NONE;
        }
        let mp = (self as *const Package) as *mut Package;
        unsafe (*mp).ensure_index();
        let s = self.idx.syms.find(name);
        if s == SYM_NONE {
            return NODE_NONE;
        }
        return self.lookup_sym(from, mid, s, want_type);
    }

    /// `lookup` by the name's interned symbol `s`, for a caller that probes many modules with one
    /// name. The index must cover `mid` (`ensure_index`); a module without an Ast has no entry.
    @always_inline
    pub fn lookup_sym(self: &Self, from: u32, mid: ModuleId, s: SymbolId, want_type: bool) NodeId {
        let key = s as u64 * 4u64 + if want_type {
            2u64;
        } else {
            0u64;
        } + 1u64;
        let it = self.idx.name_maps[mid as usize].get(&key);
        if it.is_none() {
            return NODE_NONE;
        }
        let im = self.idx.items.at((*it.unwrap()) as usize);
        if !self.vis_ok(from, mid, im.vis) {
            return NODE_NONE;
        }
        return im.node;
    }

    /// What `<mid>::<s>` names for module `from`: an item `mid` declares, else the first in import order
    /// that a module `mid` glob-imports declares, or one of that module's imports. An implicit directory
    /// index reaches its files' own items only, and sets `amb` when two of its files declare the name.
    pub fn qual_lookup(self: &Self, from: u32, mid: ModuleId, s: SymbolId, want_type: bool, amb: &mut bool) LookupHit {
        let d = self.lookup_sym(from, mid, s, want_type);
        if d != NODE_NONE {
            return LookupHit { node: d, mid: mid };
        }
        let ii = self.modules[mid as usize].implicit_index;
        let mut hit = LookupHit { node: NODE_NONE, mid: 0 };
        let mp = (self as *const Package) as *mut Package;
        for g in self.idx.mod_globs[mid as usize] as usize..self.idx.mod_globs[mid as usize + 1] as usize {
            let gm = self.idx.globs[g];
            let mut h = LookupHit { node: self.lookup_sym(from, gm, s, want_type), mid: gm };
            if !ii {
                unsafe (*mp).ensure_closure(gm);
                let lst = self.clo_lists.at(gm as usize);
                let mut i: usize = 1; // the closure starts with `gm` itself
                while h.node == NODE_NONE && i < lst.len() {
                    h = LookupHit { node: self.lookup_sym(from, lst[i], s, want_type), mid: lst[i] };
                    i += 1;
                }
            }
            if h.node != NODE_NONE {
                if hit.node != NODE_NONE {
                    *amb = true;
                    break;
                }
                hit = h;
                if !ii {
                    break;
                }
            }
        }
        return hit;
    }

    /// The `VIS_*` of declaration `node` of module `mid`.
    pub fn decl_vis(self: &Self, mid: ModuleId, node: NodeId) u8 {
        return node_vis(unsafe (*self.module_ast_const(mid)).at_const(node));
    }

    /// Like lookup but across every prelude module (the first in module order wins); the hit's `mid`
    /// is the owning module. One probe of the index's prelude name map.
    /// Is declaration `d` the prelude's type or interface `name`? A program's item of that name is not.
    pub fn is_prelude_item(self: &Self, d: DefId, name: str) bool {
        let h = self.prelude_lookup(name, true);
        return h.node != NODE_NONE && d.node == h.node && d.module == h.mid;
    }

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
            let d = self.lookup(FROM_ANY, mo, name, want_type);
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

    /// Fill row `from` of `mod_refs` (`row`: its `mod_refs_w` words, zero on entry) from the
    /// module's resolutions, both arenas. Call once all resolutions are final and before any body
    /// arena is released; one pass over the module's resolutions, independent of every other row.
    pub fn mod_refs_row(self: &Self, from: usize, row: []mut u64) {
        let n = self.modules.len();
        if !self.modules[from].has_ast {
            return;
        }
        let ra = &self.modules[from].ast;
        let nb = ra.nodes.len();
        for i in 0..ra.nnodes() {
            let d = ra.resolution_def(Ast::nth_id_n(nb, i));
            let to = d.module as usize;
            if d.node != NODE_NONE && to < n {
                row[to / 64] = row[to / 64] | 1u64 << (to % 64) as u64;
            }
        }
    }

    // Does module `from`'s code reference anything in module `to` (a cross-module use edge)?
    fn module_imports(self: &Self, from: ModuleId, to: ModuleId) bool {
        let n = self.modules.len();
        if from as usize >= n || !self.modules[from as usize].has_ast {
            return false;
        }
        // Fast path: O(1) bitset query once built (see mod_refs_row). `to >= n` is untracked, so fall
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
    /// live.
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
        let mut deps = Vector::<Vector<ModuleId>>::new();
        deps.resize_default(n);
        for a in 0..n {
            self.emit_dep_row(a, deps.index_mut(a));
        }
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
    // `user_vectors`: a module the caller loads after the prelude names a vector (`package_from_source_arch`).
    /// Whether a loaded module names a vector (`Ast.names_vectors`; std's own simd.spc aside).
    pub const fn names_vectors(self: &Self) bool {
        for i in 0..self.modules.len() {
            let md = &self.modules[i];
            if md.has_ast && md.ast.names_vectors && !(md.prelude && basename_of(md.file.as_str()) == "simd.spc") {
                return true;
            }
        }
        return false;
    }

    // The copies' feature sets (`simd_levels`) of `simd_dispatch` over the build's features.
    fn simd_levels_compute(self: &mut Self) {
        self.simd_levels.clear();
        if !tgt::isa(self.arch).levels || cf::is_empty(self.features) || self.simd_dispatch.as_str() == "off" {
            return;
        }
        let spec = if self.simd_dispatch.len() == 0 {
            "x86-64-v3";
        } else {
            self.simd_dispatch.as_str();
        };
        let build = cf::close(self.features);
        let mut at: usize = 0;
        while at <= spec.len() {
            let mut end = at;
            while end < spec.len() && spec[end] != b',' {
                end += 1;
            }
            let mut s = self.features;
            let mut err = String::new();
            if cf::level(spec.slice(at, end), 0, true, &mut s, &mut err) {
                s = cf::close(s);
                let mut dup = cf::contains(build, s);
                for i in 0..self.simd_levels.len() {
                    dup = dup || cf::contains(self.simd_levels[i], s) && cf::contains(s, self.simd_levels[i]);
                }
                if !dup {
                    let mut k = self.simd_levels.len();
                    self.simd_levels.push(s);
                    while k > 0 && cf::count(self.simd_levels[k - 1]) > cf::count(s) {
                        self.simd_levels.set(k, self.simd_levels[k - 1]);
                        k -= 1;
                    }
                    self.simd_levels.set(k, s);
                }
            }
            at = end + 1;
        }
    }

    // Whether the std directory `std_dir` names is missing (empty names none): reported once, here,
    // instead of as one failed import per module that needs it.
    fn std_missing(self: &mut Self, std_dir: str) bool {
        if std_dir.len() == 0 || dutil::is_dir(std_dir) {
            return false;
        }
        unsafe stdio::fprintf(
            stdio::stderr(),
            "error: cannot find the standard library: '%.*s' is not a directory\n  = note: std is looked up beside the compiler and in its two parent directories; SC_STD_DIR names another one\n".ptr() as *const char,
            std_dir.len() as i32,
            std_dir.ptr(),
        );
        self.ok = false;
        return true;
    }

    fn load_prelude(self: &mut Self, std_dir: str, target: i32, user_vectors: bool) {
        self.simd_levels_compute();
        if self.std_missing(std_dir) || !self.load_prelude_files(std_dir, target) {
            return;
        }
        self.load_backend(std_dir, target, user_vectors);
        self.add_build_module(target);
    }

    // Load every top-level std file under `std_dir` as a prelude module; false when there is no
    // std directory to read.
    fn load_prelude_files(self: &mut Self, std_dir: str, target: i32) bool {
        if std_dir.len() == 0 {
            return false;
        }
        let opened = fs::read_dir(std_dir);
        if opened.is_err() {
            return false;
        }
        let mut d = opened.unwrap();
        let mut names = Vector::<String>::new();
        // Bounded by the entries of the directory; a read error ends the listing, as the end does.
        while let Some(Ok(e)) = d.next() {
            if e.name.len() < 5 || !e.name.ends_with(".spc") {
                continue;
            }
            // Skip subdirectories named "*.spc" straight from the listing's kind; only an unknown kind
            // needs a stat.
            let dir = if let Some(k) = e.kind {
                k == fs::FileKind::Dir;
            } else {
                dutil::is_dir(join2(std_dir, e.name).as_str());
            };
            if !dir {
                names.push(String::from_str(e.name));
            }
        }
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
        // With parallel loading every file parses in one wave, then each takes its id in name order.
        let par = unsafe G_LOAD_JOBS != 1 && self.overlay_files.len() == 0;
        let mut us = PUnits {};
        for k in 0..names.len() {
            let file = join2(std_dir, names[k].as_str());
            let mut dup = false;
            for i2 in 0..m0 {
                if basename_of(self.modules[i2].file.as_str()) != names[k].as_str() {
                    continue;
                }
                if dutil::same_file(file.as_str(), self.modules[i2].file.as_str()) {
                    self.modules[i2].prelude = true;
                    dup = true;
                    break;
                }
            }
            if !dup {
                let stem = stem_of(names[k].as_str());
                let mut modpath = String::from_str("__std::");
                modpath.push_str(stem.as_str());
                if par {
                    us.push(modpath.as_str(), file.as_str(), false);
                } else {
                    let id = self.load_module(modpath.as_str(), file.as_str(), self.bootstrap, target);
                    if id >= 0 {
                        self.modules[id as usize].prelude = true;
                    }
                }
            }
        }
        let roots = us.units.len();
        if roots != 0 {
            self.par_discover(&mut us, self.bootstrap, target);
        }
        for k in 0..roots {
            let id = self.par_replay(&mut us, k, self.bootstrap, target);
            if id >= 0 {
                self.modules[id as usize].prelude = true;
            }
        }
        return true;
    }

    /// The vector backend file of the instruction set, when std has one, the build has a feature and a
    /// module names a vector (`Ast.names_vectors`, or `user_vectors`; std's own simd.spc aside): its
    /// `@simd_impl` entries are what the lowering planner calls. A program without vectors loads none,
    /// so it pays nothing for it.
    fn load_backend(self: &mut Self, std_dir: str, target: i32, user_vectors: bool) {
        if std_dir.len() == 0 {
            return;
        }
        // The runtime the emitted code calls (traps, allocation tracking, the stack-overflow report).
        let rf = join2(std_dir, "rt/base.spc");
        if self.rt_module < 0 && dutil::file_mtime(rf.as_str()) != 0 {
            self.rt_module = self.load_module("std::rt::base", rf.as_str(), self.bootstrap, target);
        }
        // The runner the generated `main` of a test build calls (`sc_test_main`).
        let tf = join2(std_dir, "rt/test.spc");
        if self.test_build && self.rt_test < 0 && dutil::file_mtime(tf.as_str()) != 0 {
            self.rt_test = self.load_module("std::rt::test", tf.as_str(), self.bootstrap, target);
        }
        // wasm has no system C library: these implement the subset the program uses, over WASI.
        if tgt::os(target).own_libc && self.rt_libc < 0 {
            let cf = join2(std_dir, "rt/libc.spc");
            let mf = join2(std_dir, "rt/libm.spc");
            if dutil::file_mtime(cf.as_str()) != 0 && dutil::file_mtime(mf.as_str()) != 0 {
                self.rt_libc = self.load_module("std::rt::libc", cf.as_str(), self.bootstrap, target);
                self.rt_libm = self.load_module("std::rt::libm", mf.as_str(), self.bootstrap, target);
            }
        }
        let vectors = user_vectors || self.names_vectors();
        // The traps the native backends' vector code calls.
        let lf = join2(std_dir, "rt/lanes.spc");
        if vectors && self.rt_lanes < 0 && dutil::file_mtime(lf.as_str()) != 0 {
            self.rt_lanes = self.load_module("std::rt::lanes", lf.as_str(), self.bootstrap, target);
        }
        let bn = tgt::isa(self.arch).simd_backend;
        if bn.len() != 0 && !cf::is_empty(self.features) && vectors {
            let bf = join2(std_dir, format("simd/backend/{}.spc", bn).as_str());
            if dutil::file_mtime(bf.as_str()) != 0 {
                let id = self.load_module(
                    format("std::simd::backend::{}", bn).as_str(),
                    bf.as_str(),
                    self.bootstrap,
                    target,
                );
                if id >= 0 {
                    self.modules[id as usize].backend = true;
                }
            }
            // The run-time choice of the copies reads the CPU detector (`sc_cpu_words`).
            if self.simd_levels.len() != 0 {
                let cf9 = join2(dirname_of(std_dir), "ffi/sc_cpu.spc");
                if dutil::file_mtime(cf9.as_str()) != 0 {
                    let _ = self.load_module("sc_cpu", cf9.as_str(), self.bootstrap, target);
                }
            }
        }
    }
}
