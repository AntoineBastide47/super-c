// Package construction and module loading: reads the root module plus its transitive imports into
// per-module Asts, auto-imports the std prelude, and seeds the nominal builtin decls. Serves the
// package-level lookups every later stage relies on (O(1) public-decl name index, cached import
// closures). After typechecking, propagates concrete generic instances to their home modules
// (owner-emits, to a fixpoint) and computes the dependency-first module emit order for codegen.
import string as cstring;
import stdio;
import stdlib;
import driver_shim as shim;
import lexer::token as tok;
import lexer::lexer as lexer;
import ast::ast as *;
import ast::parser as parser;

pub const SEEK_END: i32 = 2;

/// Number of nominal builtin types; sizes Package.builtin_decls. Pinned to BuiltinType::BT_COUNT.
pub const BT_COUNT_N: usize = BuiltinType::BT_COUNT as usize;

/// One loaded module: its `::`-joined module path (the mangling/lookup key), the file it came from, its
/// source text and parsed Ast. The C loader used a NULL `Ast*` to mean "failed to lex/parse"; here the Ast
/// is held by value (like Parser.ast), so `has_ast` records that validity instead.
pub struct Module {
    pub path: String, // "std::string"; the root module is its file stem (owned)
    pub file: String, // filesystem path the source was read from (owned)
    pub source: String, // file contents (owned; span offsets index into it)
    pub ast: Ast, // parsed AST (empty + has_ast=false if the file failed to lex/parse)
    pub has_ast: bool,
    pub prelude: bool, // part of the auto-imported std prelude
}

extend Module as Free {
    pub fn free(self: &mut Self) {
        self.path.free();
        self.file.free();
        self.source.free();
        self.ast.free();
    }
}

/// The whole compilation: the root module plus every module reachable through `import`. Modules are kept as
/// separate Asts; cross-module references are DefId{module, node} into this array. (`ceval` and the codegen
/// emit-order/instance-propagation fields are added when those stages are ported.)
pub struct Package {
    pub modules: Vector<Module>,
    /// Instruction set `@arch` items are gated against: 0 x86_64, 1 aarch64, 2 wasm32, -1 unknown.
    /// Defaults to the host the compiler runs on; the driver overwrites it for `--arch=`.
    pub arch: i32,
    pub root_dir: String, // source root: the directory of the root file; imports resolve relative to it
    pub gen_root: String, // where codegen writes the emitted C tree: <build dir>/raw, set by the driver
    pub std_root: String, // second import search root (parent of std/); empty = none
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
    /// Methods resolved with NO receiver in hand -- the format helpers the print lowering reaches for,
    /// and anything else the compiler names by decl alone. Nothing says which instance wants them, so
    /// every instance does: (module << 32 | node), exempt from the per-instance demand test.
    pub always_methods: Set<u64>,
    /// Private, non-generic functions referenced from a GENERIC body of their own module, as
    /// (module << 32 | node). That generic may be monomorphized into ANOTHER TU, which cannot reach a
    /// `static` symbol -- so its owner emits it with external linkage and declares it in its header.
    /// Filled once, serially, before codegen forks: every worker must answer this the same way.
    pub extern_privates: Set<u64>,
    /// The compile-time evaluator (a *mut consteval::ConstEval, kept opaque here to avoid a type cycle);
    /// owned by the driver, created after load, set before type-checking. Null in library/test use.
    pub ceval: *mut void,
    /// While a stage (resolver/typechecker/borrowck) holds a module's Ast BY VALUE (moved out of
    /// `modules[m].ast`), package-level lookups on THAT module must see the held Ast, not the empty
    /// placeholder left behind. One slot PER MODULE, in lockstep with `modules`: several modules are in
    /// flight at once when a stage runs in parallel, and each worker writes only its own module's slot --
    /// disjoint addresses, so publishing needs no lock. Held as `usize` (0 = inactive) because a raw
    /// pointer to a `Free` pointee is move-tracked and would be moved out of the slot on assignment.
    pub override_asts: Vector<usize>,
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
    /// Per-module transitive import closure (LD-3): clo_lists[mid] = [mid, BFS over its imports...],
    /// built lazily on first glob_lookup into `mid` (imports are load-final). Replaces glob_lookup's
    /// per-call seen/queue vectors and per-import path re-joins with a flat cached walk.
    pub clo_lists: Vector<Vector<ModuleId>>,
    pub clo_built: Vector<bool>,
    /// Recycled token vector: each module's lexer adopts it (capacity kept), the parser hands it back.
    pub tok_scratch: Vector<tok::Token>,
    /// Recycled codegen output buffer, lent to each TU's Codegen through the owner-swap idiom (field
    /// assigns emit no frees, so a PRE-FIX bootstrap compiler lowers the swap correctly -- a
    /// reassigned Free LOCAL would trip the conditional-move bug older emitters carry).
    pub cg_scratch: String,
    /// Import-resolution directory cache (Opt 1): each candidate search directory is scanned ONCE (opendir/
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
    /// (realpath'd) absolute paths preferred -- overlay_index falls back to a raw compare for files not on
    /// disk yet. Empty outside the LSP.
    pub overlay_files: Vector<String>,
    pub overlay_texts: Vector<String>,
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

extend ParseResult as Free {
    pub fn free(self: &mut Self) {
        self.ast.free();
        self.tokens.free();
    }
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

/// One record per top-level or associated declaration. `node` is the legacy declaration NodeId:
/// DefId{module, node} identity and C mangling key off it. Signatures and
/// attributes stay reachable through the node (the Ast side tables are their owner).
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
    pub li_map: Map<u64, u32>, // sym*2 + want_type -> LangItem, the prelude_lookup fast path
    pub built_mods: u32, // module count at build time; a later module append invalidates the index
}

extend SymTab {
    pub fn new() SymTab {
        return SymTab { names: Vector::<String>::new(), index: Map::<u64, u32>::new(), chain: Vector::<u32>::new() };
    }

    /// The SymbolId already interned for `name`, or SYM_NONE. Byte-exact.
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
        self.chain.push(head); // new entry heads the (~always empty) same-hash chain
        self.index.insert(h, id);
        return id;
    }
}

extend SymTab as Free {
    pub fn free(self: &mut Self) {
        self.names.free();
        self.index.free();
        self.chain.free();
    }
}

extend PkgIndex {
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
            li_map: Map::<u64, u32>::new(),
            built_mods: 0,
        };
    }
}

extend PkgIndex as Free {
    pub fn free(self: &mut Self) {
        self.syms.free();
        self.items.free();
        self.mod_items.free();
        self.name_maps.free();
        self.imports.free();
        self.mod_imports.free();
        self.scc_of.free();
        self.lang_items.free();
        self.li_map.free();
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

// ---------------------------------------------------------------------------------------------------------
// Path + string helpers (heap-allocated results; callers own them).
// ---------------------------------------------------------------------------------------------------------

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
    let buf = (unsafe stdlib::malloc(sz + 1)) as *mut char;
    if buf == null {
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    let n = unsafe stdio::fread(buf, 1, sz, f);
    if n != sz && unsafe stdio::ferror(f) != 0 {
        unsafe stdlib::free(buf);
        unsafe stdio::fclose(f);
        return Option::<String>::None;
    }
    unsafe stdio::fclose(f);
    // Pre-size to content + read-ahead padding so neither the content copy nor pad_nul reallocates, then
    // append lexer::SOURCE_PAD trailing NUL bytes PAST len (len stays n) -- a read-ahead sentinel the lexer
    // relies on to over-read safely (see lexer::SOURCE_PAD).
    let mut out = String::with_capacity(n + lexer::SOURCE_PAD);
    out.push_str(str::from_raw(buf as *const u8, n));
    unsafe stdlib::free(buf);
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
extend DirCache as Free {
    pub fn free(self: &mut Self) {
        self.dirs.free();
        self.entries.free();
        self.ok.free();
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
    let mut lx = lexer::Lexer::new(source, file);
    lx.tokens = recycled; // adopt the recycled capacity (caller passes it cleared)
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        return ParseResult { ast: Ast::new(0), ok: false, tokens: lx.take_tokens() };
    }
    let toks = lx.take_tokens();
    let src = source.as_str(); // padding lives past len -> invisible to the parser
    let mut ps = parser::Parser::new(toks, src, file);
    ps.set_bootstrap_tags(bootstrap_tags);
    ps.build_ast();
    if ps.has_errors() {
        ps.log_errors();
        return ParseResult { ast: Ast::new(0), ok: false, tokens: ps.take_tokens() };
    }
    let out = ps.take_ast();
    return ParseResult { ast: out, ok: true, tokens: ps.take_tokens() };
}

// ---------------------------------------------------------------------------------------------------------
// Package construction + module loading.
// ---------------------------------------------------------------------------------------------------------

extend Package {
    pub fn new() Package {
        return Package {
            arch: unsafe shim::sc_host_arch(),
            modules: Vector::<Module>::new(),
            root_dir: String::new(),
            gen_root: String::new(),
            std_root: String::new(),
            alt_root: String::new(),
            ok: true,
            core_module: 0,
            core_seeded: false,
            method_used: Vector::<Vector<bool>>::new(),
            inst_methods: Set::<u64>::new(),
            always_methods: Set::<u64>::new(),
            method_edges: Vector::<u64>::new(),
            edge_seen: Set::<u64>::new(),
            extern_privates: Set::<u64>::new(),
            ceval: null,
            override_asts: Vector::<usize>::new(),
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
        };
    }

    // The Ast to read for module `mid` from package-level lookups: the in-flight (moved-out) Ast when a
    // stage is holding it, else the module's own held Ast. Callers that read a module's Ast for a lookup
    // during resolve/typecheck must go through this so the current module resolves against the real Ast.
    const fn module_ast_ptr(self: &Self, mid: ModuleId) *const Ast {
        if mid as usize < self.override_asts.len() && self.override_asts[mid as usize] != 0 {
            return self.override_asts[mid as usize] as *const Ast;
        }
        return &self.modules[mid as usize].ast;
    }

    /// Read-only view of module `mid`'s Ast for consumers outside the package (the Core IR
    /// lowerer); honors in-flight overrides like every package-level lookup.
    pub const fn module_ast_const(self: &Self, mid: ModuleId) *const Ast {
        return self.module_ast_ptr(mid);
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
        self.override_asts.push(0); // lockstep with `modules`, so a slot always exists to publish into
        return id;
    }

    /// Publish the in-flight Ast a stage is holding for module `mid`, so package-level lookups into `mid`
    /// read it instead of the placeholder left in the module table. Paired with `clear_override`.
    pub fn set_override(self: &mut Self, mid: ModuleId, a: *mut Ast) {
        while self.override_asts.len() <= mid as usize {
            self.override_asts.push(0);
        }
        self.override_asts[mid as usize] = a as usize;
    }

    /// The published in-flight Ast for `mid` as a raw address, or 0 when no stage holds it. `pub` because
    /// the const-evaluator reaches modules through the package too.
    pub const fn override_at(self: &Self, mid: ModuleId) usize {
        if mid as usize >= self.override_asts.len() {
            return 0;
        }
        return self.override_asts[mid as usize];
    }

    pub const fn clear_override(self: &mut Self, mid: ModuleId) {
        if mid as usize < self.override_asts.len() {
            self.override_asts[mid as usize] = 0;
        }
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
    // A module already loaded (an import cycle) simply resolves to its id: modules are parsed whole before
    // any resolution, so mutual imports need no special handling.
    // Load everything module `id` imports, depth-first, and return `id`.
    fn walk_children(self: &mut Self, id: i32, bootstrap_tags: bool, target: i32) i32 {
        // Collected BEFORE recursing: recursion pushes to self.modules, which may realloc and move this
        // module's by-value Ast, invalidating a live borrow. The dir-cache address is taken first for the same
        // reason -- the cast releases the &mut immediately, and dir_cache is disjoint from modules.
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
        // pull that module in (transitively) ONLY when the keyword is actually used -- a program that
        // never launches never loads the runtime. load_module dedups, so a duplicate push is harmless.
        if std_root.len() != 0 {
            let mut has_launch = false;
            let mut has_select = false;
            let mut has_parfor = false;
            let nn = a.nodes.len();
            for ni in 0..nn {
                let k = a.at_const(ni as NodeId).kind;
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
            // that hands the work to the blocking pool, so that module has to be linked in -- but only
            // for a program that actually declares one.
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

    pub fn load_module(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool, target: i32) i32 {
        let existing = self.find(mod_path);
        if existing >= 0 {
            return existing;
        }

        let mut source = String::new();
        let ovi = self.overlay_index(file_path);
        if ovi >= 0 {
            // clone + pad exactly like read_file (the lexer relies on the read-ahead NUL sentinel)
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
        if self.method_used[m].len() <= d.node as usize {
            // Size once to the module's node count so later marks are pure set()s.
            let mut n = unsafe self.module_ast_ptr(d.module).nodes.len();
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

    // ------------------------------------------------------------------------------------------------------
    // Cross-module name lookup.
    // ------------------------------------------------------------------------------------------------------

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
        // LangItem table: resolve each fixed prelude hook once, in prelude_lookup's own module order,
        // and key the fast path by (symbol, namespace). An unresolved hook (no std loaded, or the
        // name never interned) stays NODE_NONE and gets no fast-path entry, so the scan fallback
        // answers those queries identically.
        for li in 0..LI_COUNT_N {
            let names: []str = LI_NAMES;
            let s = idx.syms.find(names[li]);
            let mut hit = LookupHit { node: NODE_NONE, mid: 0 };
            if s != SYM_NONE {
                let key = s as u64 * 4u64 + 3u64; // is_type, public
                for i in 0..n {
                    if hit.node == NODE_NONE && self.modules[i].prelude {
                        switch idx.name_maps[i].get(&key) {
                            Some(it) => {
                                hit = LookupHit { node: idx.items[(*it) as usize].node, mid: i as ModuleId };
                            },
                            None => {},
                        };
                    }
                }
                if hit.node != NODE_NONE {
                    idx.li_map.insert(s as u64 * 2u64 + 1u64, li as u32);
                }
            }
            idx.lang_items.push(hit);
        }
        self.idx = idx;
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
        let ast = unsafe &*self.module_ast_ptr(mid);
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
        // srcp is raw (Copy) so no borrow of self lingers across the &mut self index_decl calls below;
        // `ast` comes from a raw ptr (not a tracked self-borrow), so reading it across them is fine.
        let srcp = self.modules[m].source.as_str().ptr() as *const char;
        let src = str::from_raw(srcp as *const u8, self.modules[m].source.len());
        let ast = unsafe &*self.module_ast_ptr(mid);
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

    /// Like lookup but across every prelude module; the hit's `mid` is the owning module. The fixed
    /// compiler hooks answer O(1) from the LangItem table (resolved by the same scan at index build);
    /// dynamic names fall back to the module walk.
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
        switch self.idx.li_map.get(&lk) {
            Some(li) => {
                return self.idx.lang_items[(*li) as usize];
            },
            None => {},
        };
        for i in 0..self.modules.len() {
            if self.modules[i].prelude {
                let d = self.lookup(i as ModuleId, name, want_type);
                if d != NODE_NONE {
                    return LookupHit { node: d, mid: i as ModuleId };
                }
            }
        }
        return LookupHit { node: NODE_NONE, mid: 0 };
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

    /// lookup extended over `mid`'s transitive imports (imports are public, C-style): searches `mid` itself,
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
    /// order -- a BFS over the index import adjacency (identical order to the old per-call AST walk).
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
        for i in 0..ra.resolutions_len() {
            let d = ra.resolution_def(i as NodeId);
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
    fn instance_home_in(self: &Self, am: ModuleId, it: &TyInstance) ModuleId {
        for i in 0..it.n {
            let h = self.type_user_home(am, unsafe it.args[i as usize]);
            if h != 0xFFFF as ModuleId && (self.module_is_user(h) || self.module_imports(h, it.module)) {
                return h;
            }
        }
        return it.module;
    }

    /// Mid-based entry for the free-function propagation/emit-order ports (they hold raw `*mut Ast`).
    pub fn instance_home_mid(self: &Self, am: ModuleId, it: &TyInstance) ModuleId {
        return self.instance_home_in(am, it);
    }
}

extend Package as Free {
    pub fn free(self: &mut Self) {
        self.modules.free();
        self.root_dir.free();
        self.gen_root.free();
        self.std_root.free();
        self.alt_root.free();
        self.method_used.free();
        self.method_edges.free();
        self.edge_seen.free();
        self.inst_methods.free();
        self.always_methods.free();
        self.extern_privates.free();
        self.mod_refs.free();
        self.idx.free();
        self.clo_lists.free();
        self.clo_built.free();
        self.tok_scratch.free();
        self.cg_scratch.free();
        self.dir_cache.free();
        self.lint_set.free();
        self.overlay_files.free();
        self.overlay_texts.free();
    }
}

// ---------------------------------------------------------------------------------------------------------
// Cross-module instance propagation + emit ordering (ports of loader.c's file-scope helpers). These thread
// raw `*mut Ast`/`*const Ast` pointers to sidestep the by-value move rules on `&Ast`; the modules Vector is
// never grown during propagation, so pointers into `modules[x].ast` stay valid throughout.
// ---------------------------------------------------------------------------------------------------------

const fn pkg_ast_c(p: &Package, m: ModuleId) *const Ast {
    return &p.modules[m as usize].ast;
}

/// Dependency-first module emit order: if module `a` full-monomorphizes a generic owned by `b` (re-homing a
/// concrete instance to `a` itself), `b` must be emitted first. Kahn topo-sort with a lowest-id tiebreak;
/// `order` is caller-allocated with `modules.len()` entries.
pub fn package_emit_order(p: &Package, order: *mut ModuleId) {
    let n = p.modules.len();
    if n == 0 {
        return;
    }
    let done = (unsafe stdlib::calloc(n, 1)) as *mut bool;
    let dep = (unsafe stdlib::calloc(n * n, 1)) as *mut bool;
    let indeg = (unsafe stdlib::calloc(n, 4)) as *mut u32;
    if done == null || dep == null || indeg == null {
        for i in 0..n {
            unsafe order[i] = i as ModuleId;
        }
        unsafe stdlib::free(done);
        unsafe stdlib::free(dep);
        unsafe stdlib::free(indeg);
        return;
    }
    for a in 0..n {
        if !p.modules[a].has_ast {
            continue;
        }
        let aa = pkg_ast_c(p, a as ModuleId);
        let mut i: usize = 0;
        while i < unsafe aa.instances.len() {
            let it = *aa.instance(i as u32);
            let bi = it.module as usize;
            if bi >= n || bi == a || unsafe dep[a * n + bi] {
                i = i + 1;
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe aa.type_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if concrete && p.instance_home_mid(a as ModuleId, &it) == a as ModuleId {
                unsafe dep[a * n + bi] = true;
                unsafe {
                    indeg[a] = indeg[a] + 1;
                }
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
            if bi >= n || bi == a || unsafe dep[a * n + bi] {
                i = i + 1;
                continue;
            }
            unsafe dep[a * n + bi] = true;
            unsafe {
                indeg[a] = indeg[a] + 1;
            }
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
            if fd.node == NODE_NONE || bi >= n || bi == a || unsafe dep[a * n + bi] {
                i = i + 1;
                continue;
            }
            if !p.modules[bi].has_ast {
                i = i + 1;
                continue;
            }
            let bast = pkg_ast_c(p, fd.module);
            if bast.at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                i = i + 1;
                continue;
            }
            unsafe dep[a * n + bi] = true;
            unsafe {
                indeg[a] = indeg[a] + 1;
            }
            i = i + 1;
        }
    }
    for kk in 0..n {
        let mut pick = n;
        let mut i: usize = 0;
        while i < n {
            if !unsafe done[i] && unsafe indeg[i] == 0 {
                pick = i;
                break;
            }
            i = i + 1;
        }
        if pick == n {
            i = 0;
            while i < n {
                if !unsafe done[i] {
                    pick = i;
                    break;
                }
                i = i + 1;
            }
        }
        unsafe order[kk] = pick as ModuleId;
        unsafe done[pick] = true;
        for x in 0..n {
            if !unsafe done[x] && unsafe dep[x * n + pick] && unsafe indeg[x] > 0 {
                unsafe {
                    indeg[x] = indeg[x] - 1;
                }
            }
        }
    }
    unsafe stdlib::free(done);
    unsafe stdlib::free(dep);
    unsafe stdlib::free(indeg);
}

/// Load `root_file` and, transitively, every module it imports, then append the std prelude found under
/// `std_dir` (NULL skips it). Diagnostics are printed as encountered. Returns a Package (check `.ok`).
pub fn package_load(root_file: str, std_dir: *const char, bootstrap_tags: bool, target: i32) Package {
    let d = dir_of(root_file);
    let p = package_load_rooted(root_file, d.as_str(), "", std_dir, bootstrap_tags, target);
    return p;
}

/// Like package_load, but imports resolve against an explicit package root instead of the root
/// file's own directory (`super-c lint <dir>` lints nested package files in their true package).
pub fn package_load_rooted(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: *const char,
    bootstrap_tags: bool,
    target: i32,
) Package {
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
    std_dir: *const char,
    bootstrap_tags: bool,
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
    if std_dir != null {
        p.std_root = dir_of(str::from_cstr(std_dir));
    }
    let rp = stem_of(root_file);
    let rf = String::from_str(root_file);
    p.load_module(rp.as_str(), rf.as_str(), bootstrap_tags, target);
    load_prelude(&mut p, std_dir, target);
    p.seed_core();
    return p;
}

/// Prelude-only package (import roots set, no root module): the batch `lint` driver and the LSP's
/// workspace batch load_module each listed file into it afterwards, so every file shares one closure
/// instead of reloading its own. Takes ownership of the overlay vectors (empty for CLI use).
pub fn package_load_prelude(
    root_dir: str,
    alt_dir: str,
    std_dir: *const char,
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
    if std_dir != null {
        p.std_root = dir_of(str::from_cstr(std_dir));
    }
    load_prelude(&mut p, std_dir, target);
    p.seed_core();
    return p;
}

/// A batch-listed file's canonical module path: relative to the alt root when under it (the spelling
/// manifest imports must use -- the alt root has no index form), else to the package root, `/` -> `::`.
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
/// recursion -- the analog of tests/test_harness.h's sc_compile. The prelude loads FIRST and the user
/// module is appended LAST (its module id past the prelude), matching sc_compile's layout exactly, so
/// module-order-sensitive checks (Ty interning, generic-arg validation) reproduce the C test verdicts.
/// The user module is always the last one: `p.modules.len() - 1`. Used by selfhost/tests.
pub fn package_from_source(src: *const char, len: usize, std_dir: *const char, target: i32) Package {
    let mut p = Package::new();
    p.ok = true;
    p.root_dir = String::from_str(".");
    if std_dir != null {
        p.std_root = dir_of(str::from_cstr(std_dir));
    }
    load_prelude(&mut p, std_dir, target);
    let mut source = String::from_str(str::from_raw(src as *const u8, len));
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
    return p;
}

// A PATH_MAX realpath scratch buffer (the omitted array field zero-fills on partial init).
struct RealBuf {
    pub b: [char; 4096],
}

// The final path component of `path` (a view into it) -- "dir/std/string.spc" -> "string.spc".
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

// Auto-import the prelude: every TOP-LEVEL `<std_dir>/*.spc` (not subdirectories) becomes a prelude module
// whose public items resolve unqualified. A file already loaded (explicitly imported) is flagged in place;
// otherwise it is loaded under the reserved `__std::` namespace so its build output never collides with a
// user's own `std/` folder. Names are sorted for deterministic module ids regardless of readdir order.
fn load_prelude(p: &mut Package, std_dir: *const char, target: i32) {
    if std_dir == null {
        return;
    }
    let dir = unsafe shim::sc_opendir(std_dir);
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
            let mut probe = join2(str::from_cstr(std_dir), str::from_cstr(nm));
            if unsafe shim::sc_stat_isdir(probe.cstr()) == 1 {
                continue;
            }
        }
        names.push(String::from_cstr(nm));
    }
    let _ = unsafe shim::sc_closedir(dir);
    // sort by name (small: the std/ file list) -- byte-lexicographic with a length tiebreak (equivalent to
    // strcmp over these NUL-free views).
    names.sort_by(|a: &String, b: &String| name_cmp(a, b));
    // Dedup: a std file is already loaded iff some already-loaded module has the SAME basename AND is the
    // same physical file (dev+ino). The basename pre-filter (a plain string compare, no syscall) keeps this
    // O(std files) even for huge projects -- user modules almost never share a std/ basename, so we stat-
    // confirm only the rare collisions -- and inode identity is exact + realpath-free (no getdirentries). The
    // __std:: modules appended below have distinct names and never match, so scanning only the initial m0 is
    // sufficient.
    let m0 = p.modules.len();
    for k in 0..names.len() {
        let mut file = join2(str::from_cstr(std_dir), names[k].as_str());
        let mut dup = false;
        for i2 in 0..m0 {
            if basename_of(p.modules[i2].file.as_str()) != names[k].as_str() {
                continue;
            }
            if unsafe shim::sc_same_file(file.cstr(), p.modules[i2].file.cstr()) == 1 {
                p.modules[i2].prelude = true;
                dup = true;
                break;
            }
        }
        if !dup {
            let stem = stem_of(names[k].as_str());
            let mut modpath = String::from_str("__std::");
            modpath.push_str(stem.as_str());
            let id = p.load_module(modpath.as_str(), file.as_str(), false, target);
            if id >= 0 {
                p.modules[id as usize].prelude = true;
            }
        }
    }
}
