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
    /// The compile-time evaluator (a *mut consteval::ConstEval, kept opaque here to avoid a type cycle);
    /// owned by the driver, created after load, set before type-checking. Null in library/test use.
    pub ceval: *mut void,
    /// While a stage (resolver/typechecker) holds a module's Ast BY VALUE (moved out of `modules[m].ast`),
    /// package-level lookups on THAT module must see the held Ast, not the empty placeholder left behind.
    /// The driver points these at the in-flight Ast for the duration of the stage. (MODULE_NONE = inactive.)
    pub override_mod: ModuleId,
    pub override_ast: *mut Ast,
    /// Cross-module reference bitset: mod_refs[from*mod_refs_w + to/64] bit (to%64) is set iff module `from`
    /// has any resolution into module `to`. Built once (resolve-final) at the start of instance propagation;
    /// makes module_imports an O(1) query instead of a linear resolutions scan. `mod_refs_ready` gates it
    /// (module_imports falls back to the linear scan if queried before the build).
    pub mod_refs: Vector<u64>,
    pub mod_refs_w: usize,
    pub mod_refs_ready: bool,
    /// Per-module public-decl name index (LD-2): lk_index[mid] maps fnv_name(name)*2+is_type -> LkEnt, built
    /// lazily on first lookup into `mid` (top-level decl names are parse-final, so it stays valid for the whole
    /// pipeline). Replaces Package::lookup's linear item scan with an O(1) probe.
    pub lk_index: Vector<Map<u64, LkEnt>>,
    pub lk_built: Vector<bool>,
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

/// One entry in a module's public-decl name index (LD-2): the decl node to return plus the source span of its
/// name, kept so a lookup can VERIFY the name bytes match (guarding against the ~impossible 64-bit hash
/// collision — on a verify miss we fall back to the linear scan, so the result is always exact).
pub struct LkEnt {
    pub node: NodeId,
    pub start: u32,
    pub len: u32,
}

// FNV-1a over a name's bytes; the per-module lookup index keys on `fnv_name(name)*2 + is_type`.
fn fnv_name(name: str) u64 {
    let p = name.ptr();
    let mut h: u64 = 1469598103934665603u64;
    for i in 0..name.len() {
        h = h ^ (unsafe p[i]) as u64;
        h = h * 1099511628211u64;
    }
    return h;
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
    if unsafe (*dc).exists(root_rel.as_str()) {
        return root_rel;
    }
    // Manifest convention fallback: tests/ and bench/ live beside src/, so a project-root-rooted
    // load still resolves the compiler's own modules (and vice versa) through the src/ alt root.
    if !alt_root.is_empty() {
        let alt_rel = module_file_path(alt_root, ast, src, parts);
        if unsafe (*dc).exists(alt_rel.as_str()) {
            return alt_rel;
        }
    }
    if std_root.is_empty() {
        return root_rel;
    }
    let std_rel = module_file_path(std_root, ast, src, parts);
    if unsafe (*dc).exists(std_rel.as_str()) {
        return std_rel;
    }
    let ffi_base = join2(std_root, "ffi");
    let ffi_rel = module_file_path(ffi_base.as_str(), ast, src, parts);
    if unsafe (*dc).exists(ffi_rel.as_str()) {
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
            modules: Vector::<Module>::new(),
            root_dir: String::new(),
            gen_root: String::new(),
            std_root: String::new(),
            alt_root: String::new(),
            ok: true,
            core_module: 0,
            core_seeded: false,
            method_used: Vector::<Vector<bool>>::new(),
            method_edges: Vector::<u64>::new(),
            edge_seen: Set::<u64>::new(),
            ceval: null,
            override_mod: 0xFFFF,
            override_ast: null,
            mod_refs: Vector::<u64>::new(),
            mod_refs_w: 0,
            mod_refs_ready: false,
            lk_index: Vector::<Map<u64, LkEnt>>::new(),
            lk_built: Vector::<bool>::new(),
            clo_lists: Vector::<Vector<ModuleId>>::new(),
            clo_built: Vector::<bool>::new(),
            tok_scratch: Vector::<tok::Token>::new(),
            cg_scratch: String::new(),
            dir_cache: DirCache::new(),
            overlay_files: Vector::<String>::new(),
            overlay_texts: Vector::<String>::new(),
        };
    }

    // The Ast to read for module `mid` from package-level lookups: the in-flight (moved-out) Ast when a
    // stage is holding it, else the module's own held Ast. Callers that read a module's Ast for a lookup
    // during resolve/typecheck must go through this so the current module resolves against the real Ast.
    const fn module_ast_ptr(self: &Self, mid: ModuleId) *const Ast {
        if mid == self.override_mod && self.override_ast != null {
            return self.override_ast;
        }
        return &self.modules[mid as usize].ast;
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
    // A module already loaded (an import cycle) simply resolves to its id: modules are parsed whole before
    // any resolution, so mutual imports need no special handling.
    fn load_module(self: &mut Self, mod_path: str, file_path: str, bootstrap_tags: bool) i32 {
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

        // Collect this module's import (path, file) pairs BEFORE recursing: recursion pushes to
        // self.modules, which may realloc and move this module's by-value Ast, invalidating a live borrow.
        let root_dir = self.root_dir.as_str();
        let alt_root = self.alt_root.as_str();
        let std_root = self.std_root.as_str();
        // Address of the dir_cache field, taken BEFORE borrowing self.modules below (the cast releases the
        // &mut immediately; dir_cache is a disjoint field so mutating it doesn't alias the `m` borrow). Passed
        // as a usize because `*mut DirCache` is move-tracked (Free pointee) and would move out of the loop.
        let dca = ((&mut self.dir_cache) as *mut DirCache) as usize;
        let mut child_paths = Vector::<String>::new();
        let mut child_files = Vector::<String>::new();
        {
            let m = self.modules.at(id as usize);
            let items = m.ast.at_const(m.ast.root).as_data.program.items;
            let ids = m.ast.list(items);
            let src = m.source.as_str();
            for i in 0..items.len {
                let n = m.ast.at_const(unsafe ids[i as usize]);
                if n.kind == NodeKind::NODE_IMPORT {
                    let parts = n.as_data.import_decl.path;
                    let cp = join_parts(&m.ast, src, parts, "::");
                    // Skip already-loaded modules here: resolve_import_file probes the filesystem (up to 3
                    // path_exists per edge) only for load_module's own dedup to discard the result. A hot std/
                    // ffi module imported by many modules would otherwise be re-probed once per importer.
                    if self.find(cp.as_str()) < 0 {
                        child_paths.push(cp);
                        child_files.push(resolve_import_file(dca, root_dir, alt_root, std_root, &m.ast, src, parts));
                    }
                }
            }
        }
        for k in 0..child_paths.len() {
            self.load_module(child_paths[k].as_str(), child_files[k].as_str(), bootstrap_tags);
        }
        return id;
    }

    /// Inject one synthetic decl per builtin into the core prelude module (`__std::core`), so builtins are
    /// nominal types that `extend i32 { .. }` can target. The decls live in the node pool only. Run after
    /// loading, before resolve.
    pub fn seed_core(self: &mut Self) {
        self.core_seeded = false;
        for i in 0..self.modules.len() {
            let is_core = self.modules[i].has_ast && self.modules[i].path.as_str() == "__std::core";
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
        let inner = &mut self.method_used[m];
        if inner.len() <= d.node as usize {
            // Size once to the module's node count so later marks are pure set()s.
            let mut n = unsafe (*self.module_ast_ptr(d.module)).nodes.len();
            if n <= d.node as usize {
                n = d.node as usize + 1;
            }
            inner.reserve(n - inner.len());
            while inner.len() < n {
                inner.push(false);
            }
        }
        inner.set(d.node as usize, true);
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

    /// Fixpoint over the deferred edges: an edge's callee is used once its caller is. Must run after
    /// every module has typechecked and before codegen consults method_used_get.
    pub fn finalize_method_used(self: &mut Self) {
        let mut changed = true;
        while changed {
            changed = false;
            for i in 0..self.method_edges.len() {
                let key = self.method_edges[i];
                let c = DefId { module: (key >> 56) as ModuleId, node: (key >> 32) as NodeId & 16777215 };
                let d = DefId { module: (key >> 24 & 255) as ModuleId, node: key as NodeId & 16777215 };
                if !self.method_used_get(d) && self.method_used_get(c) {
                    self.mark_method_used(d);
                    changed = true;
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------
    // Cross-module name lookup.
    // ------------------------------------------------------------------------------------------------------

    /// Build module `mid`'s public-decl name index on first use (idempotent). Mirrors lookup_linear's exact
    /// traversal + classification, inserting the FIRST occurrence per (name, is_type) key. Top-level decl
    /// names/spans are parse-final, so the index stays valid for the whole pipeline.
    pub fn ensure_lk_index(self: &mut Self, mid: ModuleId) {
        let m = mid as usize;
        while self.lk_index.len() <= m {
            self.lk_index.push(Map::<u64, LkEnt>::new());
        }
        while self.lk_built.len() <= m {
            self.lk_built.push(false);
        }
        if self.lk_built[m] {
            return;
        }
        self.lk_built[m] = true;
        if !self.modules[m].has_ast {
            return;
        }
        // srcp is raw (Copy) so no borrow of self lingers while lk_emit takes &mut self below; `ast` comes
        // from a raw ptr (not a tracked self-borrow), so reading through it across lk_emit calls is fine.
        let srcp = self.modules[m].source.as_str().ptr() as *const char;
        let ast = unsafe &*self.module_ast_ptr(mid);
        let items = ast.at_const(ast.root).as_data.program.items;
        let ids = ast.list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let n = ast.at_const(nid);
            if n.kind == NodeKind::NODE_EXTERN_BLOCK {
                let inner = n.as_data.extern_block.items;
                let iids = ast.list(inner);
                for j in 0..inner.len {
                    let iid = unsafe iids[j as usize];
                    let it = ast.at_const(iid);
                    let mut nn: NodeId = NODE_NONE;
                    let mut ip = false;
                    let mut it_type = false;
                    let mut ok = true;
                    if it.kind == NodeKind::NODE_FUNCTION {
                        nn = it.as_data.function.name;
                        ip = it.as_data.function.is_public;
                        it_type = false;
                    } else if it.kind == NodeKind::NODE_TYPE_ALIAS {
                        nn = it.as_data.type_alias.name;
                        ip = it.as_data.type_alias.is_public;
                        it_type = true;
                    } else if it.kind == NodeKind::NODE_CONST {
                        nn = it.as_data.const_def.name;
                        ip = it.as_data.const_def.is_public;
                        it_type = false;
                    } else {
                        ok = false;
                    }
                    if ok && ip {
                        let sp = ast.at_const(nn).as_data.name.text;
                        self.lk_emit(m, srcp, sp.start, sp.end, it_type, iid);
                    }
                }
            } else {
                let mut name_node: NodeId = NODE_NONE;
                let mut is_pub = false;
                let mut is_type = false;
                let mut consider = true;
                if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
                    name_node = n.as_data.aggregate.name;
                    is_pub = n.as_data.aggregate.is_public;
                    is_type = true;
                } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
                    name_node = n.as_data.type_alias.name;
                    is_pub = n.as_data.type_alias.is_public;
                    is_type = true;
                } else if n.kind == NodeKind::NODE_INTERFACE {
                    name_node = n.as_data.interface_def.name;
                    is_pub = n.as_data.interface_def.is_public;
                    is_type = true;
                } else if n.kind == NodeKind::NODE_FUNCTION {
                    name_node = n.as_data.function.name;
                    is_pub = n.as_data.function.is_public;
                    is_type = false;
                } else if n.kind == NodeKind::NODE_CONST {
                    name_node = n.as_data.const_def.name;
                    is_pub = n.as_data.const_def.is_public;
                    is_type = false;
                } else {
                    consider = false;
                }
                if consider && is_pub {
                    let sp = ast.at_const(name_node).as_data.name.text;
                    self.lk_emit(m, srcp, sp.start, sp.end, is_type, nid);
                }
            }
        }
    }

    // Hash a decl's name (bytes at srcp[start..end]) into a (name-hash*2+is_type) key and insert into
    // module-slot `m`'s index, first occurrence wins (matches lookup_linear's first-match order).
    fn lk_emit(self: &mut Self, m: usize, srcp: *const char, start: u32, end: u32, is_type: bool, node: NodeId) {
        let len = end - start;
        let np = (unsafe (srcp + start as usize)) as *const u8;
        let nm = str::from_raw(np, len as usize);
        let key = fnv_name(nm) * 2u64 + if is_type {
            1u64;
        } else {
            0u64;
        };
        let ent = LkEnt { node: node, start: start, len: len };
        let mp = &mut self.lk_index[m];
        if mp.get(&key).is_none() {
            mp.insert(key, ent);
        }
    }

    /// Find a *public* top-level declaration named `name` in module `mid`: a type when `want_type`, otherwise
    /// a value. Returns the decl's NodeId within module `mid`'s Ast, or NODE_NONE. O(1) via the name index.
    pub fn lookup(self: &Self, mid: ModuleId, name: str, want_type: bool) NodeId {
        if !self.modules[mid as usize].has_ast {
            return NODE_NONE;
        }
        let mp = (self as *const Package) as *mut Package;
        unsafe {
            (*mp).ensure_lk_index(mid);
        }
        let src = self.modules[mid as usize].source.as_str().ptr() as *const char;
        let key = fnv_name(name) * 2u64 + if want_type {
            1u64;
        } else {
            0u64;
        };
        return switch self.lk_index[mid as usize].get(&key) {
            Some(e) => {
                let mut r: NodeId = NODE_NONE;
                if e.len as usize == name.len() && unsafe cstring::memcmp(
                    src + e.start as usize,
                    name.ptr(),
                    name.len(),
                ) == 0 {
                    r = e.node;
                } else {
                    r = self.lookup_linear(mid, name, want_type);
                } // 64-bit key collision (~never) -> exact scan
                r;
            },
            None => NODE_NONE,
        };
    }

    // Linear public-decl scan (LD-2 collision fallback; the original lookup body, semantics unchanged).
    fn lookup_linear(self: &Self, mid: ModuleId, name: str, want_type: bool) NodeId {
        if !self.modules[mid as usize].has_ast {
            return NODE_NONE;
        }
        let ast = unsafe &*self.module_ast_ptr(mid);
        let src = self.modules[mid as usize].source.as_str().ptr() as *const char;
        let items = ast.at_const(ast.root).as_data.program.items;
        let ids = ast.list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let n = ast.at_const(nid);
            let mut name_node: NodeId = NODE_NONE;
            let mut is_pub = false;
            let mut is_type = false;
            let mut consider = true;
            if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
                name_node = n.as_data.aggregate.name;
                is_pub = n.as_data.aggregate.is_public;
                is_type = true;
            } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
                name_node = n.as_data.type_alias.name;
                is_pub = n.as_data.type_alias.is_public;
                is_type = true;
            } else if n.kind == NodeKind::NODE_INTERFACE {
                name_node = n.as_data.interface_def.name;
                is_pub = n.as_data.interface_def.is_public;
                is_type = true;
            } else if n.kind == NodeKind::NODE_FUNCTION {
                name_node = n.as_data.function.name;
                is_pub = n.as_data.function.is_public;
                is_type = false;
            } else if n.kind == NodeKind::NODE_CONST {
                name_node = n.as_data.const_def.name;
                is_pub = n.as_data.const_def.is_public;
                is_type = false;
            } else if n.kind == NodeKind::NODE_EXTERN_BLOCK {
                // `pub` raw bindings / opaque handles live one level down, inside the extern block.
                let inner = n.as_data.extern_block.items;
                let iids = ast.list(inner);
                for j in 0..inner.len {
                    let iid = unsafe iids[j as usize];
                    let it = ast.at_const(iid);
                    let mut nn: NodeId = NODE_NONE;
                    let mut ip = false;
                    let mut it_type = false;
                    let mut ok = true;
                    if it.kind == NodeKind::NODE_FUNCTION {
                        nn = it.as_data.function.name;
                        ip = it.as_data.function.is_public;
                        it_type = false;
                    } else if it.kind == NodeKind::NODE_TYPE_ALIAS {
                        nn = it.as_data.type_alias.name;
                        ip = it.as_data.type_alias.is_public;
                        it_type = true;
                    } else if it.kind == NodeKind::NODE_CONST {
                        nn = it.as_data.const_def.name;
                        ip = it.as_data.const_def.is_public;
                        it_type = false;
                    } else {
                        ok = false;
                    }
                    if ok && ip && it_type == want_type {
                        let sp = ast.at_const(nn).as_data.name.text;
                        let l = (sp.end - sp.start) as usize;
                        if l == name.len() && unsafe cstring::memcmp(src + sp.start as usize, name.ptr(), name.len()) == 0 {
                            return iid;
                        }
                    }
                }
                consider = false;
            } else {
                consider = false;
            }
            if consider && is_pub && is_type == want_type {
                let sp = ast.at_const(name_node).as_data.name.text;
                let l = (sp.end - sp.start) as usize;
                if l == name.len() && unsafe cstring::memcmp(src + sp.start as usize, name.ptr(), name.len()) == 0 {
                    return nid;
                }
            }
        }
        return NODE_NONE;
    }

    /// Like lookup but across every prelude module; the hit's `mid` is the owning module.
    pub fn prelude_lookup(self: &Self, name: str, want_type: bool) LookupHit {
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
        unsafe {
            (*mp).ensure_closure(mid);
        }
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

    /// The modules `mid` transitively imports (excluding `mid` itself), breadth-first in declaration order.
    pub fn import_closure(self: &Self, mid: ModuleId) Vector<ModuleId> {
        let n = self.modules.len();
        let mut out = Vector::<ModuleId>::new();
        if mid as usize > n {
            return out;
        } // the standalone Ast (module == count) has no imports to walk
        let mut seen = Vector::<bool>::new();
        for s in 0..n + 1 {
            seen.push(false);
        }
        seen.set(mid as usize, true);
        let mut head: usize = 0;
        let mut cur = mid;
        let mut go = true;
        while go {
            if cur as usize < n && self.modules[cur as usize].has_ast {
                let ast = unsafe &*self.module_ast_ptr(cur);
                let items = ast.at_const(ast.root).as_data.program.items;
                let ids = ast.list(items);
                let src = self.modules[cur as usize].source.as_str();
                for i in 0..items.len {
                    let it = ast.at_const(unsafe ids[i as usize]);
                    if it.kind == NodeKind::NODE_IMPORT {
                        let path = join_parts(ast, src, it.as_data.import_decl.path, "::");
                        let c = self.find(path.as_str());
                        if c >= 0 && !seen[c as usize] {
                            seen.set(c as usize, true);
                            out.push(c as ModuleId);
                        }
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

    /// Build the cross-module reference bitset from every module's (resolve-final) resolutions. One pass over
    /// all resolutions, O(total resolutions), done once before instance propagation. Idempotent.
    pub fn build_mod_refs(self: &mut Self) {
        let n = self.modules.len();
        let w = (n + 63) / 64;
        self.mod_refs_w = w;
        self.mod_refs.clear();
        let total = n * w;
        for _z in 0..total {
            self.mod_refs.push(0u64);
        }
        for from in 0..n {
            if !self.modules[from].has_ast {
                continue;
            }
            let base = from * w;
            let ra = &self.modules[from].ast;
            for k in 0..ra.resolutions_len() {
                let d = ra.resolution_def(k as NodeId);
                let to = d.module as usize;
                if d.node != NODE_NONE && to < n {
                    let idx = base + to / 64;
                    let cur = self.mod_refs[idx];
                    self.mod_refs[idx] = cur | 1u64 << (to % 64) as u64;
                }
            }
        }
        self.mod_refs_ready = true;
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

    /// Public entry: `a` is the Ast currently being emitted (== self.modules[a.module].ast).
    pub fn instance_home(self: &Self, a: &Ast, it: &TyInstance) ModuleId {
        return self.instance_home_in(a.module, it);
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
        self.mod_refs.free();
        self.lk_index.free();
        self.lk_built.free();
        self.clo_lists.free();
        self.clo_built.free();
        self.tok_scratch.free();
        self.cg_scratch.free();
        self.dir_cache.free();
        self.overlay_files.free();
        self.overlay_texts.free();
    }
}

// ---------------------------------------------------------------------------------------------------------
// Cross-module instance propagation + emit ordering (ports of loader.c's file-scope helpers). These thread
// raw `*mut Ast`/`*const Ast` pointers to sidestep the by-value move rules on `&Ast`; the modules Vector is
// never grown during propagation, so pointers into `modules[x].ast` stay valid throughout.
// ---------------------------------------------------------------------------------------------------------

const fn pkg_ast_m(p: &mut Package, m: ModuleId) *mut Ast {
    return &mut p.modules[m as usize].ast;
}
const fn pkg_ast_c(p: &Package, m: ModuleId) *const Ast {
    return &p.modules[m as usize].ast;
}

// True when `t` mentions a function VALUE type anywhere (a TYPE_FUNCTION, possibly nested): its C symbol
// (and env struct) is local to the module defining it, so a use over it must stay in the calling module.
fn type_mentions_fnval(p: &Package, mid: ModuleId, t: TypeId) bool {
    let y = *pkg_ast_c(p, mid).type_at(t);
    if y.kind == TypeKind::TYPE_FUNCTION {
        return true;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return type_mentions_fnval(p, mid, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *pkg_ast_c(p, mid).instance(y.as_data.inst);
        for i in 0..it.n {
            if type_mentions_fnval(p, mid, unsafe it.args[i as usize]) {
                return true;
            }
        }
        return false;
    }
    return false;
}

// Substitute the generic params `gids`->`args` while reinterning `owner`'s type `t` into `dest`'s pools.
fn subst_reintern_type(
    p: &mut Package,
    dm: ModuleId,
    om: ModuleId,
    t: TypeId,
    gmod: ModuleId,
    gids: *const NodeId,
    args: *const TypeId,
    nargs: u8,
) TypeId {
    if t == TYPE_NONE {
        return TYPE_NONE;
    }
    let ty = *pkg_ast_c(p, om).type_at(t);
    if ty.kind == TypeKind::TYPE_GENERIC {
        for i in 0..nargs {
            if ty.module == gmod && ty.as_data.decl == unsafe gids[i as usize] {
                return unsafe args[i as usize];
            }
        }
        let d = pkg_ast_m(p, dm);
        let o = pkg_ast_c(p, om);
        return unsafe (*d).reintern(&*o, t);
    }
    if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE || ty.kind == TypeKind::TYPE_SLICE || ty.kind == TypeKind::TYPE_ARRAY {
        let mut nt = ty;
        nt.as_data.elem = subst_reintern_type(p, dm, om, ty.as_data.elem, gmod, gids, args, nargs);
        let d = pkg_ast_m(p, dm);
        return unsafe (*d).intern_type(nt);
    }
    if ty.kind == TypeKind::TYPE_INSTANCE {
        let inst = *pkg_ast_c(p, om).instance(ty.as_data.inst);
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let m = if inst.n < 4 {
            inst.n;
        } else {
            4 as u8;
        };
        for i in 0..m {
            unsafe na[i as usize] = subst_reintern_type(
                p,
                dm,
                om,
                unsafe inst.args[i as usize],
                gmod,
                gids,
                args,
                nargs,
            );
        }
        let d = pkg_ast_m(p, dm);
        return unsafe (*d).intern_instance(inst.module, inst.decl, &na[0], m);
    }
    let d = pkg_ast_m(p, dm);
    let o = pkg_ast_c(p, om);
    return unsafe (*d).reintern(&*o, t);
}

// Reintern one member/param/return type after substitution; if it lands on a concrete instance whose home
// differs from `dest`, also seed that home's table. Sets `*changed` only on the final growth path (parity).
fn reintern_nested_type(
    p: &mut Package,
    dm: ModuleId,
    om: ModuleId,
    t: TypeId,
    gmod: ModuleId,
    gids: *const NodeId,
    args: *const TypeId,
    nargs: u8,
    changed: *mut bool,
) {
    if t == TYPE_NONE {
        return;
    }
    let before = unsafe (*pkg_ast_c(p, dm)).instances.len();
    let mut st = subst_reintern_type(p, dm, om, t, gmod, gids, args, nargs);
    let mut y = *pkg_ast_c(p, dm).type_at(st);
    while y.kind == TypeKind::TYPE_ARRAY {
        st = y.as_data.elem;
        y = *pkg_ast_c(p, dm).type_at(st);
    }
    if y.kind != TypeKind::TYPE_INSTANCE {
        return;
    }
    let it = *pkg_ast_c(p, dm).instance(y.as_data.inst);
    let mut concrete = true;
    for i in 0..it.n {
        if !unsafe (*pkg_ast_c(p, dm)).type_concrete(it.args[i as usize]) {
            concrete = false;
        }
    }
    if !concrete {
        return;
    }
    let np = p.modules.len();
    let home = p.instance_home_mid(dm, &it);
    let mut has_h = false;
    let mut hm: ModuleId = 0;
    if home as usize < np {
        has_h = true;
        hm = home;
    } else if dm == home {
        has_h = true;
        hm = dm;
    }
    if has_h && hm != dm {
        let m = if it.n < 4 {
            it.n;
        } else {
            4 as u8;
        };
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let hbefore = unsafe (*pkg_ast_c(p, hm)).instances.len();
        for k in 0..m {
            let h = pkg_ast_m(p, hm);
            let d = pkg_ast_c(p, dm);
            unsafe na[k as usize] = unsafe (*h).reintern(&*d, it.args[k as usize]);
        }
        let h = pkg_ast_m(p, hm);
        let _ = unsafe (*h).intern_instance(it.module, it.decl, &na[0], m);
        let hafter = unsafe (*pkg_ast_c(p, hm)).instances.len();
        if hafter != hbefore {
            unsafe *changed = true;
        }
    }
    let after = unsafe (*pkg_ast_c(p, dm)).instances.len();
    if after != before {
        unsafe *changed = true;
    }
}

// Seed `dest` with the concrete instances nested in a generic aggregate's member/variant types.
fn reintern_nested_instance_deps(
    p: &mut Package,
    dm: ModuleId,
    it: &TyInstance,
    args: *const TypeId,
    nargs: u8,
    changed: *mut bool,
) {
    let np = p.modules.len();
    let itmod = it.module;
    if itmod as usize >= np || !p.modules[itmod as usize].has_ast {
        return;
    }
    let decl = it.decl;
    let dn_kind = unsafe (*pkg_ast_c(p, itmod)).at_const(decl).kind;
    let generics = unsafe (*pkg_ast_c(p, itmod)).at_const(decl).as_data.aggregate.generics;
    if dn_kind != NodeKind::NODE_STRUCT && dn_kind != NodeKind::NODE_ENUM || generics.len == 0 {
        return;
    }
    let members = unsafe (*pkg_ast_c(p, itmod)).at_const(decl).as_data.aggregate.members;
    let gids = unsafe (*pkg_ast_c(p, itmod)).list(generics);
    let mids = unsafe (*pkg_ast_c(p, itmod)).list(members);
    for m in 0..members.len {
        let mid = unsafe mids[m as usize];
        let mnk = unsafe (*pkg_ast_c(p, itmod)).at_const(mid).kind;
        if dn_kind == NodeKind::NODE_STRUCT && mnk == NodeKind::NODE_FIELD {
            let fty = unsafe (*pkg_ast_c(p, itmod)).at_const(mid).as_data.field.ty;
            let tt = unsafe (*pkg_ast_c(p, itmod)).type_of(fty);
            reintern_nested_type(p, dm, itmod, tt, itmod, gids, args, nargs, changed);
        } else if dn_kind == NodeKind::NODE_ENUM && mnk == NodeKind::NODE_VARIANT {
            let payload = unsafe (*pkg_ast_c(p, itmod)).at_const(mid).as_data.variant.payload;
            let pids = unsafe (*pkg_ast_c(p, itmod)).list(payload);
            for k in 0..payload.len {
                let pfid = unsafe pids[k as usize];
                let pfk = unsafe (*pkg_ast_c(p, itmod)).at_const(pfid).kind;
                let tn = if pfk == NodeKind::NODE_FIELD {
                    unsafe (*pkg_ast_c(p, itmod)).at_const(pfid).as_data.field.ty;
                } else {
                    pfid;
                };
                let tt = unsafe (*pkg_ast_c(p, itmod)).type_of(tn);
                reintern_nested_type(p, dm, itmod, tt, itmod, gids, args, nargs, changed);
            }
        }
    }
}

// Seed `dest` with concrete instances nested in a generic extend's method signatures over this instance.
fn reintern_method_signature_deps(
    p: &mut Package,
    dm: ModuleId,
    it: &TyInstance,
    args: *const TypeId,
    nargs: u8,
    changed: *mut bool,
) {
    let np = p.modules.len();
    let itmod = it.module;
    if itmod as usize >= np || !p.modules[itmod as usize].has_ast {
        return;
    }
    let itdecl = it.decl;
    let root = unsafe (*pkg_ast_c(p, itmod)).root;
    let items = unsafe (*pkg_ast_c(p, itmod)).at_const(root).as_data.program.items;
    let ids = unsafe (*pkg_ast_c(p, itmod)).list(items);
    for i in 0..items.len {
        let eid = unsafe ids[i as usize];
        let ek = unsafe (*pkg_ast_c(p, itmod)).at_const(eid).kind;
        if ek != NodeKind::NODE_EXTEND {
            continue;
        }
        let egen = unsafe (*pkg_ast_c(p, itmod)).at_const(eid).as_data.extend_def.generics;
        if egen.len == 0 {
            continue;
        }
        let etgt = unsafe (*pkg_ast_c(p, itmod)).at_const(eid).as_data.extend_def.target_type;
        if unsafe (*pkg_ast_c(p, itmod)).resolution(etgt) != itdecl {
            continue;
        }
        let gids = unsafe (*pkg_ast_c(p, itmod)).list(egen);
        let eitems = unsafe (*pkg_ast_c(p, itmod)).at_const(eid).as_data.extend_def.items;
        let emids = unsafe (*pkg_ast_c(p, itmod)).list(eitems);
        for mm in 0..eitems.len {
            let fnid = unsafe emids[mm as usize];
            let fnk = unsafe (*pkg_ast_c(p, itmod)).at_const(fnid).kind;
            if fnk != NodeKind::NODE_FUNCTION {
                continue;
            }
            let fgen = unsafe (*pkg_ast_c(p, itmod)).at_const(fnid).as_data.function.generics;
            let frets = unsafe (*pkg_ast_c(p, itmod)).at_const(fnid).as_data.function.returns;
            if fgen.len != 0 || frets.len > 1 {
                continue;
            }
            let fparams = unsafe (*pkg_ast_c(p, itmod)).at_const(fnid).as_data.function.params;
            let pids = unsafe (*pkg_ast_c(p, itmod)).list(fparams);
            let mut k: u32 = 0;
            while k < fparams.len {
                let pid = unsafe pids[k as usize];
                let pty = unsafe (*pkg_ast_c(p, itmod)).at_const(pid).as_data.parameter.ty;
                let tt = unsafe (*pkg_ast_c(p, itmod)).type_of(pty);
                reintern_nested_type(p, dm, itmod, tt, itmod, gids, args, nargs, changed);
                k = k + 1;
            }
            let rids = unsafe (*pkg_ast_c(p, itmod)).list(frets);
            k = 0;
            while k < frets.len {
                let rid = unsafe rids[k as usize];
                let rk = unsafe (*pkg_ast_c(p, itmod)).at_const(rid).kind;
                let tn = if rk == NodeKind::NODE_PARAMETER {
                    unsafe (*pkg_ast_c(p, itmod)).at_const(rid).as_data.parameter.ty;
                } else {
                    rid;
                };
                let tt = unsafe (*pkg_ast_c(p, itmod)).type_of(tn);
                reintern_nested_type(p, dm, itmod, tt, itmod, gids, args, nargs, changed);
                k = k + 1;
            }
        }
    }
}

// Re-intern `src`'s concrete cross-module generic instantiations into their HOME module's table. Returns
// true if any table grew (drives the fixpoint in package_propagate_instances).
fn reintern_cross_module(p: &mut Package, sm: ModuleId, start: usize) bool {
    let mut changed = false;
    // sm's Ast lives inline in `p.modules`, which never reallocs during propagation, so its address is stable
    // for the whole call. Cache it once: interleaved pkg_ast_m writes stop the C compiler from proving the
    // reload invariant, so re-deriving it per use cost a bounds-check + offset every time.
    let s = pkg_ast_c(p, sm);
    let n = unsafe (*s).instances.len();
    let np = p.modules.len();
    for i in start..n {
        let it = *s.instance(i as u32);
        let mut concrete = true;
        for k in 0..it.n {
            if !unsafe (*s).type_concrete(it.args[k as usize]) {
                concrete = false;
            }
        }
        if !concrete {
            continue;
        }
        let home = p.instance_home_mid(sm, &it);
        if home as usize >= np {
            continue;
        }
        let dm = home;
        let m = if it.n < 4 {
            it.n;
        } else {
            4 as u8;
        };
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        for k2 in 0..m {
            if dm == sm {
                unsafe na[k2 as usize] = unsafe it.args[k2 as usize];
            } else {
                let d = pkg_ast_m(p, dm);
                unsafe na[k2 as usize] = unsafe (*d).reintern(&*s, it.args[k2 as usize]);
            }
        }
        if dm != sm {
            let before = unsafe (*pkg_ast_c(p, dm)).instances.len();
            let d = pkg_ast_m(p, dm);
            let _ = unsafe (*d).intern_instance(it.module, it.decl, &na[0], m);
            let after = unsafe (*pkg_ast_c(p, dm)).instances.len();
            if after != before {
                changed = true;
            }
        }
        let cp = (&mut changed) as *mut bool;
        reintern_nested_instance_deps(p, dm, &it, &na[0], m, cp);
        reintern_method_signature_deps(p, dm, &it, &na[0], m, cp);
    }
    return changed;
}

// Record `src`'s generic-method calls into the method's OWNING module (or the receiver instance's home),
// so that module emits the matching `Inst__method__targs` specialization. Returns true on growth.
fn reintern_method_insts(p: &mut Package, sm: ModuleId) bool {
    let mut changed = false;
    let s = pkg_ast_c(p, sm); // stable for the call (see reintern_cross_module); avoids re-deriving per node
    let n = unsafe (*s).nodes.len();
    let np = p.modules.len();
    let mut i: NodeId = 0;
    while i as usize < n {
        let ck = unsafe (*s).at_const(i).kind;
        if ck != NodeKind::NODE_CALL {
            i = i + 1;
            continue;
        }
        let callee_id = unsafe (*s).at_const(i).as_data.call.callee;
        let cek = unsafe (*s).at_const(callee_id).kind;
        if cek != NodeKind::NODE_MEMBER {
            i = i + 1;
            continue;
        }
        let member_id = unsafe (*s).at_const(callee_id).as_data.member.member;
        let md = unsafe (*s).resolution_def(member_id);
        if md.node == NODE_NONE {
            i = i + 1;
            continue;
        }
        if md.module as usize >= np || !p.modules[md.module as usize].has_ast {
            i = i + 1;
            continue;
        }
        let om = md.module;
        let mnk = unsafe (*pkg_ast_c(p, om)).at_const(md.node).kind;
        let mgen = unsafe (*pkg_ast_c(p, om)).at_const(md.node).as_data.function.generics;
        if mnk != NodeKind::NODE_FUNCTION || mgen.len == 0 {
            i = i + 1;
            continue;
        }
        let mu = unsafe (*s).type_args(i);
        if mu == null || unsafe (*mu).n == 0 {
            i = i + 1;
            continue;
        }
        let object_id = unsafe (*s).at_const(callee_id).as_data.member.object;
        let mut rty = unsafe (*s).type_of(object_id);
        let du = unsafe (*s).deref_use_at(member_id);
        if du != null {
            rty = unsafe (*du).target;
        }
        let mut yk = unsafe (*s).type_at(rty).kind;
        while yk == TypeKind::TYPE_POINTER || yk == TypeKind::TYPE_REFERENCE {
            rty = unsafe (*s).type_at(rty).as_data.elem;
            yk = unsafe (*s).type_at(rty).kind;
        }
        if unsafe (*s).type_at(rty).kind != TypeKind::TYPE_INSTANCE || !unsafe (*s).type_concrete(rty) {
            i = i + 1;
            continue;
        }
        let mtn = if unsafe (*mu).n < 4 {
            unsafe (*mu).n;
        } else {
            4 as u8;
        };
        let mut concrete = true;
        for k in 0..mtn {
            if !unsafe (*s).type_concrete((*mu).args[k as usize]) {
                concrete = false;
            }
        }
        if !concrete {
            i = i + 1;
            continue;
        }
        let recv_inst = unsafe (*s).type_at(rty).as_data.inst;
        let recv = *s.instance(recv_inst);
        let home = p.instance_home_mid(sm, &recv);
        let mut dm = om;
        if home as usize < np {
            dm = home;
        }
        for kk in 0..mtn {
            if type_mentions_fnval(p, sm, unsafe (*mu).args[kk as usize]) {
                dm = sm;
                break;
            }
        }
        let rinst = if dm == sm {
            rty;
        } else {
            let d = pkg_ast_m(p, dm);
            unsafe (*d).reintern(&*s, rty);
        };
        let mut targs: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        for t in 0..mtn {
            if dm == sm {
                unsafe targs[t as usize] = unsafe (*mu).args[t as usize];
            } else {
                let d = pkg_ast_m(p, dm);
                unsafe targs[t as usize] = unsafe (*d).reintern(&*s, (*mu).args[t as usize]);
            }
        }
        let d = pkg_ast_m(p, dm);
        if unsafe (*d).add_method_inst(rinst, md.node, &targs[0], mtn) {
            changed = true;
        }
        i = i + 1;
    }
    return changed;
}

// True when every generic parameter `t` mentions belongs to `gids` (the target fn's own params):
// substituting foreign params would intern partially-substituted garbage instances into the owner
// pool, which later emit as undefined C type names.
fn type_params_subset(p: &Package, m: ModuleId, t: TypeId, gmod: ModuleId, gids: *const NodeId, n: u32) bool {
    if t == TYPE_NONE {
        return true;
    }
    let y = *pkg_ast_c(p, m).type_at(t);
    if y.kind == TypeKind::TYPE_GENERIC {
        if y.module != gmod {
            return false;
        }
        for i in 0..n {
            if unsafe gids[i as usize] == y.as_data.decl {
                return true;
            }
        }
        return false;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return type_params_subset(p, m, y.as_data.elem, gmod, gids, n);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *pkg_ast_c(p, m).instance(y.as_data.inst);
        for i in 0..it.n {
            if !type_params_subset(p, m, unsafe it.args[i as usize], gmod, gids, n) {
                return false;
            }
        }
        return true;
    }
    return true;
}

// Body-only generic types of MONOMORPHIZED functions: a `W<T> { .. }` literal inside a generic
// fn's body appears in no signature, so nothing else interns its concrete instance -- the emitted
// C then names a struct that was never defined. For every fn instantiation (MonoUse) substitute
// its args through the owner module's non-concrete pool types (only those can mention the params;
// foreign params never match, so unrelated types pass through untouched). Runs single-threaded
// BEFORE the propagation fixpoint -- codegen's own seeding (expand_nested_insts) is restricted to
// same-module instantiations because foreign asts are read-only under parallel codegen.
fn seed_mono_body_instances(p: &mut Package) {
    let n = p.modules.len();
    let mut changed = false;
    for u in 0..n {
        if !p.modules[u].has_ast {
            continue;
        }
        let ua = pkg_ast_c(p, u as ModuleId);
        let nm = unsafe (*ua).mono.len();
        for mi in 0..nm {
            let mu = unsafe (*ua).mono[mi];
            if unsafe (*ua).at_const(mu.node).kind != NodeKind::NODE_CALL {
                continue;
            }
            let callee_id = unsafe (*ua).at_const(mu.node).as_data.call.callee;
            let fd = if unsafe (*ua).at_const(callee_id).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let e = unsafe (*ua).at_const(callee_id).as_data.specialization.expression;
                unsafe (*ua).resolution_def(e);
            } else {
                unsafe (*ua).resolution_def(callee_id);
            };
            if fd.node == NODE_NONE || fd.module as usize >= n || !p.modules[fd.module as usize].has_ast {
                continue;
            }
            let fma = pkg_ast_c(p, fd.module);
            if unsafe (*fma).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let gens = unsafe (*fma).at_const(fd.node).as_data.function.generics;
            if gens.len == 0 || gens.len > 8 || mu.n as u32 < gens.len {
                continue;
            }
            let mut concrete = true;
            for k in 0..gens.len {
                if !unsafe (*ua).type_concrete(mu.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            let mut fargs: [TypeId; 8] = [0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32];
            for k in 0..gens.len {
                unsafe fargs[k as usize] = if fd.module == u as ModuleId {
                    unsafe mu.args[k as usize];
                } else {
                    let fmm = pkg_ast_m(p, fd.module);
                    unsafe (*fmm).reintern(&*ua, mu.args[k as usize]);
                };
            }
            let gids = unsafe (*pkg_ast_c(p, fd.module)).list(gens);
            let np = unsafe (*pkg_ast_c(p, fd.module)).type_pool.len();
            let cp = (&mut changed) as *mut bool;
            let mut t: usize = 1;
            while t < np {
                if !unsafe (*pkg_ast_c(p, fd.module)).type_concrete(t as TypeId) && type_params_subset(
                    p,
                    fd.module,
                    t as TypeId,
                    fd.module,
                    gids,
                    gens.len,
                ) {
                    reintern_nested_type(
                        p,
                        fd.module,
                        fd.module,
                        t as TypeId,
                        fd.module,
                        gids,
                        &fargs[0],
                        gens.len as u8,
                        cp,
                    );
                }
                t = t + 1;
            }
        }
    }
}

/// Owner-emits generic instances used across module boundaries: re-intern every concrete instance (and
/// generic-method specialization) into its home module's tables, iterating to a fixpoint. Must run after
/// every module has typechecked and before codegen.
pub fn package_propagate_instances(p: &mut Package) {
    // Typechecking is done for every module here: resolve the deferred caller->callee method-use
    // edges before codegen starts consulting method_used_get.
    p.finalize_method_used();
    seed_mono_body_instances(p);
    let n = p.modules.len();
    // Resolutions are final now; build the cross-module reference bitset once so module_imports (hot inside
    // instance_home_in, called per instance-arg here and in codegen) is an O(1) query, not a linear scan.
    p.build_mod_refs();
    // Instances are only ever appended and re-interning one is idempotent, so each needs processing exactly
    // once; the fixpoint exists only to reach instances CREATED while processing earlier ones. Track how far
    // each module's instance table has been consumed and re-scan only the newly-appended tail per sweep -- the
    // confirming sweep then touches just the handful the productive sweep added, not every instance again.
    let mut proc_inst = Vector::<usize>::new();
    for u in 0..n {
        proc_inst.push(0);
    }
    let mut changed = true;
    while changed {
        changed = false;
        for u in 0..n {
            if p.modules[u].has_ast {
                let start = proc_inst[u];
                let ni = unsafe (*pkg_ast_c(p, u as ModuleId)).instances.len();
                if start < ni {
                    if reintern_cross_module(p, u as ModuleId, start) {
                        changed = true;
                    }
                    proc_inst[u] = ni;
                }
                if reintern_method_insts(p, u as ModuleId) {
                    changed = true;
                }
            }
        }
    }
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
        while i < unsafe (*aa).instances.len() {
            let it = unsafe *(*aa).instance(i as u32);
            let bi = it.module as usize;
            if bi >= n || bi == a || unsafe dep[a * n + bi] {
                i = i + 1;
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe (*aa).type_concrete(it.args[k as usize]) {
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
        while i < unsafe (*aa).method_insts.len() {
            let miinst = unsafe (*aa).method_insts[i].instance;
            let y = unsafe *(*aa).type_at(miinst);
            if y.kind != TypeKind::TYPE_INSTANCE {
                i = i + 1;
                continue;
            }
            let bi = (unsafe (*aa).instance(y.as_data.inst).module) as usize;
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
            if fd.node == NODE_NONE || bi >= n || bi == a || unsafe dep[a * n + bi] {
                i = i + 1;
                continue;
            }
            if !p.modules[bi].has_ast {
                i = i + 1;
                continue;
            }
            let bast = pkg_ast_c(p, fd.module);
            if unsafe (*bast).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
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
pub fn package_load(root_file: str, std_dir: *const char, bootstrap_tags: bool) Package {
    let d = dir_of(root_file);
    let p = package_load_rooted(root_file, d.as_str(), "", std_dir, bootstrap_tags);
    return p;
}

/// Like package_load, but imports resolve against an explicit package root instead of the root
/// file's own directory (`super-c lint <dir>` lints nested package files in their true package).
pub fn package_load_rooted(root_file: str, root_dir: str, alt_dir: str, std_dir: *const char, bootstrap_tags: bool) Package {
    return package_load_overlaid(
        root_file,
        root_dir,
        alt_dir,
        std_dir,
        bootstrap_tags,
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
    p.load_module(rp.as_str(), rf.as_str(), bootstrap_tags);
    load_prelude(&mut p, std_dir);
    p.seed_core();
    return p;
}

/// Like package_load, but the root module is an in-memory source STRING (path "main"), with no user-import
/// recursion -- the analog of tests/test_harness.h's sc_compile. The prelude loads FIRST and the user
/// module is appended LAST (its module id past the prelude), matching sc_compile's layout exactly, so
/// module-order-sensitive checks (Ty interning, generic-arg validation) reproduce the C test verdicts.
/// The user module is always the last one: `p.modules.len() - 1`. Used by selfhost/tests.
pub fn package_from_source(src: *const char, len: usize, std_dir: *const char) Package {
    let mut p = Package::new();
    p.ok = true;
    p.root_dir = String::from_str(".");
    if std_dir != null {
        p.std_root = dir_of(str::from_cstr(std_dir));
    }
    load_prelude(&mut p, std_dir);
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
fn load_prelude(p: &mut Package, std_dir: *const char) {
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
            if basename_of(p.modules[i2].file.as_str()) == names[k].as_str() && unsafe shim::sc_same_file(
                file.cstr(),
                p.modules[i2].file.cstr(),
            ) == 1 {
                p.modules[i2].prelude = true;
                dup = true;
                break;
            }
        }
        if !dup {
            let stem = stem_of(names[k].as_str());
            let mut modpath = String::from_str("__std::");
            modpath.push_str(stem.as_str());
            let id = p.load_module(modpath.as_str(), file.as_str(), false);
            if id >= 0 {
                p.modules[id as usize].prelude = true;
            }
        }
    }
}
