import string as cstring;
import stdio;
import stdlib;
import driver_shim as shim;
import lexer::token as tok;
import lexer::lexer as lexer;
import ast::ast as *;
import ast::parser as parser;

pub const SEEK_END: i32 = 2;

// Number of nominal builtin types; sizes Package.builtin_decls. Pinned to BuiltinType::BT_COUNT.
pub const BT_COUNT_N: usize = BuiltinType::BT_COUNT as usize;

// One loaded module: its `::`-joined module path (the mangling/lookup key), the file it came from, its
// source text and parsed Ast. The C loader used a NULL `Ast*` to mean "failed to lex/parse"; here the Ast
// is held by value (like Parser.ast), so `has_ast` records that validity instead.
pub struct Module {
    pub path: *mut char,   // "std::string"; the root module is its file stem (owned)
    pub file: *mut char,   // filesystem path the source was read from (owned)
    pub source: *mut char, // NUL-terminated file contents (owned)
    pub source_len: usize,
    pub ast: Ast,          // parsed AST (empty + has_ast=false if the file failed to lex/parse)
    pub has_ast: bool,
    pub prelude: bool,     // part of the auto-imported std prelude
}

extend Module as Free {
    pub fn free(self: &mut Self) void {
        unsafe stdlib::free(self.path as *mut void);
        unsafe stdlib::free(self.file as *mut void);
        unsafe stdlib::free(self.source as *mut void);
        self.ast.free();
    }
}

// The whole compilation: the root module plus every module reachable through `import`. Modules are kept as
// separate Asts; cross-module references are DefId{module, node} into this array. (`ceval` and the codegen
// emit-order/instance-propagation fields are added when those stages are ported.)
pub struct Package {
    pub modules: Vector<Module>,
    pub root_dir: *mut char, // source root: the directory of the root file; imports resolve relative to it
    pub std_root: *mut char, // second import search root (parent of std/)
    pub ok: bool,            // false if any read/parse/cycle error was reported during loading
    // Builtins as nominal types: a synthetic decl per builtin is injected into the `core` prelude module so
    // `extend i32 { .. }` resolves and dispatches like any other type. `core_seeded` gates it.
    pub core_module: ModuleId,
    pub core_seeded: bool,
    pub builtin_decls: [NodeId; BT_COUNT_N],
    // Demand-driven method emission: method_used[module][node] set for every method referenced during
    // type-checking. Ragged: outer grown to module count, each inner grown to cover the node id.
    pub method_used: Vector<Vector<bool>>,
    // The compile-time evaluator (a *mut consteval::ConstEval, kept opaque here to avoid a type cycle);
    // owned by the driver, created after load, set before type-checking. Null in library/test use.
    pub ceval: *mut void,
    // While a stage (resolver/typechecker) holds a module's Ast BY VALUE (moved out of `modules[m].ast`),
    // package-level lookups on THAT module must see the held Ast, not the empty placeholder left behind.
    // The driver points these at the in-flight Ast for the duration of the stage. (MODULE_NONE = inactive.)
    pub override_mod: ModuleId,
    pub override_ast: *mut Ast,
}

// The parse pipeline's result: an Ast plus whether lex/parse succeeded (mirrors the C `Ast*`/NULL return).
pub struct ParseResult { pub ast: Ast, pub ok: bool }

// The bytes of a file plus their length; `ptr == null` signals any I/O error (mirrors read_file's NULL).
pub struct FileContents { pub ptr: *mut char, pub len: usize }

// A module-qualified declaration hit: the decl's NodeId within module `mid`. `node == NODE_NONE` means miss.
pub struct LookupHit { pub node: NodeId, pub mid: ModuleId }

// ---------------------------------------------------------------------------------------------------------
// Path + string helpers (heap-allocated results; callers own them).
// ---------------------------------------------------------------------------------------------------------

fn dup_cstr(s: *const char) *mut char {
    let n = unsafe cstring::strlen(s);
    let d = unsafe stdlib::malloc(n + 1) as *mut char;
    unsafe cstring::memcpy(d as *mut void, s, n + 1);
    return d;
}

// True if `path` names something that can be opened for reading (replaces access(path, F_OK)).
fn path_exists(path: *const char) bool {
    let f = stdio::fopen(str::from_cstr(path), "rb");
    if f == null { return false; }
    unsafe stdio::fclose(f);
    return true;
}

// Read a whole file into a NUL-terminated, heap-allocated buffer; ptr==null on any I/O error.
fn read_file(path: *const char) FileContents {
    let f = stdio::fopen(str::from_cstr(path), "rb");
    if f == null { return FileContents { ptr: null, len: 0 }; }
    if unsafe stdio::fseek(f, 0, SEEK_END) != 0 { unsafe stdio::fclose(f); return FileContents { ptr: null, len: 0 }; }
    let s = unsafe stdio::ftell(f);
    unsafe stdio::rewind(f);
    if s < 0 { unsafe stdio::fclose(f); return FileContents { ptr: null, len: 0 }; }
    let sz = s as usize;
    let buf = unsafe stdlib::malloc(sz + 1) as *mut char;
    if buf == null { unsafe stdio::fclose(f); return FileContents { ptr: null, len: 0 }; }
    let n = unsafe stdio::fread(buf as *mut void, 1, sz, f);
    if n != sz && unsafe stdio::ferror(f) != 0 {
        unsafe stdlib::free(buf as *mut void);
        unsafe stdio::fclose(f);
        return FileContents { ptr: null, len: 0 };
    }
    unsafe stdio::fclose(f);
    unsafe buf[n] = 0 as char;
    return FileContents { ptr: buf, len: n };
}

// The directory portion of `path` (without trailing slash), or "." when there is none.
fn dir_of(path: *const char) *mut char {
    let slash = unsafe cstring::strrchr(path, '/' as i32);
    if slash == null { return dup_cstr(".".ptr() as *const char); }
    let n = (slash as usize) - (path as usize);
    let d = unsafe stdlib::malloc(n + 1) as *mut char;
    unsafe cstring::memcpy(d as *mut void, path, n);
    unsafe d[n] = 0 as char;
    return d;
}

// The file stem (basename without extension): "dir/std/string.spc" -> "string".
fn stem_of(path: *const char) *mut char {
    let slash = unsafe cstring::strrchr(path, '/' as i32);
    let mut base = path;
    if slash != null { base = unsafe (slash + 1) as *const char; }
    let dot = unsafe cstring::strrchr(base, '.' as i32);
    let mut n = unsafe cstring::strlen(base);
    if dot != null { n = (dot as usize) - (base as usize); }
    let d = unsafe stdlib::malloc(n + 1) as *mut char;
    unsafe cstring::memcpy(d as *mut void, base, n);
    unsafe d[n] = 0 as char;
    return d;
}

// Join an import's path parts with `sep` ("::" for a module path, "/" for a file path).
fn join_parts(ast: &Ast, src: *const char, parts: NodeList, sep: *const char) *mut char {
    let ids = ast.list(parts);
    let seplen = unsafe cstring::strlen(sep);
    let mut total: usize = 0;
    let mut i: u32 = 0;
    while i < parts.len {
        let sp = ast.at_const(unsafe ids[i as usize]).as_data.name.text;
        total = total + (sp.end - sp.start) as usize;
        if i != 0 { total = total + seplen; }
        i = i + 1;
    }
    let out = unsafe stdlib::malloc(total + 1) as *mut char;
    let mut at: usize = 0;
    i = 0;
    while i < parts.len {
        if i != 0 {
            unsafe cstring::memcpy((out + at) as *mut void, sep, seplen);
            at = at + seplen;
        }
        let sp = ast.at_const(unsafe ids[i as usize]).as_data.name.text;
        let l = (sp.end - sp.start) as usize;
        unsafe cstring::memcpy((out + at) as *mut void, (src + sp.start as usize), l);
        at = at + l;
        i = i + 1;
    }
    unsafe out[at] = 0 as char;
    return out;
}

// "<root_dir>/<parts joined by '/'>.spc".
fn module_file_path(root_dir: *const char, ast: &Ast, src: *const char, parts: NodeList) *mut char {
    let rel = join_parts(&*ast, src, parts, "/".ptr() as *const char);
    let n = unsafe cstring::strlen(root_dir) + 1 + unsafe cstring::strlen(rel as *const char) + 4 + 1;
    let out = unsafe stdlib::malloc(n) as *mut char;
    unsafe stdio::snprintf(out, n, "%s/%s.spc".ptr() as *const char, root_dir, rel);
    unsafe stdlib::free(rel as *mut void);
    return out;
}

// Heap "<a>/<b>".
fn join2(a: *const char, b: *const char) *mut char {
    let n = unsafe cstring::strlen(a) + 1 + unsafe cstring::strlen(b) + 1;
    let out = unsafe stdlib::malloc(n) as *mut char;
    unsafe stdio::snprintf(out, n, "%s/%s".ptr() as *const char, a, b);
    return out;
}

// Resolve an import's file by searching the project root first, then the std root (so `import std::x;`
// finds <std_root>/std/x.spc), then the bundled `ffi/` bindings (so a bare `import stdio;` finds
// <std_root>/ffi/stdio.spc). Returns the first path that exists, else the project-relative path. Owned.
fn resolve_import_file(root_dir: *const char, std_root: *const char, ast: &Ast, src: *const char,
                       parts: NodeList) *mut char {
    let root_rel = module_file_path(root_dir, &*ast, src, parts);
    if path_exists(root_rel as *const char) || std_root == null { return root_rel; }
    let std_rel = module_file_path(std_root, &*ast, src, parts);
    if path_exists(std_rel as *const char) {
        unsafe stdlib::free(root_rel as *mut void);
        return std_rel;
    }
    unsafe stdlib::free(std_rel as *mut void);
    let ffi_base = join2(std_root, "ffi".ptr() as *const char);
    let ffi_rel = module_file_path(ffi_base as *const char, &*ast, src, parts);
    unsafe stdlib::free(ffi_base as *mut void);
    if path_exists(ffi_rel as *const char) {
        unsafe stdlib::free(root_rel as *mut void);
        return ffi_rel;
    }
    unsafe stdlib::free(ffi_rel as *mut void);
    return root_rel;
}

// Lex + parse one module's source into an Ast, printing diagnostics. ok=false on a lex/parse error.
fn parse_source(source: *const char, len: usize, file: *const char) ParseResult {
    let src = str::from_raw(source as *const u8, len);
    let mut lx = lexer::Lexer::new(src);
    lx.set_file(file);
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        lx.free();
        return ParseResult { ast: Ast::new(0), ok: false };
    }
    let toks = lx.take_tokens();
    lx.free();
    let mut ps = parser::Parser::new(toks, src);
    ps.set_file(file);
    ps.build_ast();
    if ps.has_errors() {
        ps.log_errors();
        ps.free();
        return ParseResult { ast: Ast::new(0), ok: false };
    }
    let out = ps.take_ast();
    ps.free();
    return ParseResult { ast: out, ok: true };
}

// ---------------------------------------------------------------------------------------------------------
// Package construction + module loading.
// ---------------------------------------------------------------------------------------------------------

extend Package {
    pub fn new() Package {
        return Package {
            modules: Vector::<Module>::new(),
            root_dir: null,
            std_root: null,
            ok: true,
            core_module: 0,
            core_seeded: false,
            method_used: Vector::<Vector<bool>>::new(),
            ceval: null,
            override_mod: 0xFFFF as ModuleId,
            override_ast: null,
        };
    }

    // The Ast to read for module `mid` from package-level lookups: the in-flight (moved-out) Ast when a
    // stage is holding it, else the module's own held Ast. Callers that read a module's Ast for a lookup
    // during resolve/typecheck must go through this so the current module resolves against the real Ast.
    fn module_ast_ptr(self: &Self, mid: ModuleId) *const Ast {
        if mid == self.override_mod && self.override_ast != null { return self.override_ast as *const Ast; }
        return (&self.modules[mid as usize].ast) as *const Ast;
    }

    // Find a module by its `::`-joined path; returns its ModuleId, or -1 if absent.
    pub fn find(self: &Self, path: str) i32 {
        for i in 0..self.modules.len() {
            let mp = self.modules[i].path;
            if unsafe cstring::strlen(mp) == path.len()
                && unsafe cstring::memcmp(mp, path.ptr(), path.len()) == 0 {
                return i as i32;
            }
        }
        return -1;
    }

    // Add a module slot (taking ownership of `path`/`file`/`source`/`ast`) and return its id.
    fn add_module(self: &mut Self, path: *mut char, file: *mut char, source: *mut char, source_len: usize,
                  ast: Ast, has_ast: bool) i32 {
        let id = self.modules.len() as i32;
        self.modules.push(Module {
            path: path, file: file, source: source, source_len: source_len,
            ast: ast, has_ast: has_ast, prelude: false,
        });
        return id;
    }

    // DFS load: takes ownership of `mod_path` and `file_path`. Returns the module's id (or -1 if unreadable).
    // A module already loaded (an import cycle) simply resolves to its id: modules are parsed whole before
    // any resolution, so mutual imports need no special handling.
    fn load_module(self: &mut Self, mod_path: *mut char, file_path: *mut char) i32 {
        let existing = self.find(str::from_raw(mod_path as *const u8, unsafe cstring::strlen(mod_path)));
        if existing >= 0 {
            unsafe stdlib::free(mod_path as *mut void);
            unsafe stdlib::free(file_path as *mut void);
            return existing;
        }

        let fc = read_file(file_path);
        if fc.ptr == null {
            unsafe stdio::fprintf(stdio::stderr(), "error: cannot open module '%s' (%s)\n".ptr() as *const char,
                                  mod_path, file_path);
            self.ok = false;
            unsafe stdlib::free(mod_path as *mut void);
            unsafe stdlib::free(file_path as *mut void);
            return -1;
        }

        let parsed = parse_source(fc.ptr as *const char, fc.len, file_path);
        let ok = parsed.ok;
        let id = self.add_module(mod_path, file_path, fc.ptr, fc.len, parsed.ast, ok);
        if !ok {
            self.ok = false;
            return id;
        }
        self.modules[id as usize].ast.module = id as ModuleId;

        // Collect this module's import (path, file) pairs BEFORE recursing: recursion pushes to
        // self.modules, which may realloc and move this module's by-value Ast, invalidating a live borrow.
        let root_dir = self.root_dir;
        let std_root = self.std_root;
        let mut child_paths = Vector::<*mut char>::new();
        let mut child_files = Vector::<*mut char>::new();
        {
            let m = self.modules.at(id as usize);
            let items = m.ast.at_const(m.ast.root).as_data.program.items;
            let ids = m.ast.list(items);
            let src = m.source;
            for i in 0..items.len {
                let n = m.ast.at_const(unsafe ids[i as usize]);
                if n.kind == NodeKind::NODE_IMPORT {
                    let parts = n.as_data.import_decl.path;
                    let cp = join_parts(&m.ast, src, parts, "::".ptr() as *const char);
                    // Skip already-loaded modules here: resolve_import_file probes the filesystem (up to 3
                    // path_exists per edge) only for load_module's own dedup to discard the result. A hot std/
                    // ffi module imported by many modules would otherwise be re-probed once per importer.
                    if self.find(str::from_raw(cp as *const u8, unsafe cstring::strlen(cp))) >= 0 {
                        unsafe stdlib::free(cp as *mut void);
                    } else {
                        child_paths.push(cp);
                        child_files.push(resolve_import_file(root_dir, std_root, &m.ast, src, parts));
                    }
                }
            }
        }
        for k in 0..child_paths.len() {
            self.load_module(child_paths[k] as *mut char, child_files[k] as *mut char);
        }
        return id;
    }

    // Inject one synthetic decl per builtin into the core prelude module (`__std::core`), so builtins are
    // nominal types that `extend i32 { .. }` can target. The decls live in the node pool only. Run after
    // loading, before resolve.
    pub fn seed_core(self: &mut Self) void {
        self.core_seeded = false;
        for i in 0..self.modules.len() {
            let is_core = self.modules[i].has_ast
                && unsafe cstring::strcmp(self.modules[i].path,
                                          "__std::core".ptr() as *const char) == 0;
            if is_core {
                for b in 0..BT_COUNT_N {
                    let id = self.modules[i].ast.add(Node {
                        kind: NodeKind::NODE_STRUCT,
                        as_data: NodeAs { aggregate: AggregateData { name: NODE_NONE, is_public: true } },
                    });
                    self.builtin_decls[b] = id;
                }
                self.core_module = i as ModuleId;
                self.core_seeded = true;
                return;
            }
        }
    }

    // The synthetic decl node anchoring builtin `b` in the core module, or NODE_NONE if builtins weren't seeded.
    pub fn builtin_decl(self: &Self, b: BuiltinType) NodeId {
        if self.core_seeded && (b as usize) < BT_COUNT_N { return self.builtin_decls[b as usize]; }
        return NODE_NONE;
    }

    // If (module, node) names a builtin's synthetic core decl, its BuiltinType; else -1.
    pub fn builtin_of_decl(self: &Self, module: ModuleId, node: NodeId) i32 {
        if !self.core_seeded || module != self.core_module || node == NODE_NONE { return -1; }
        for b in 0..BT_COUNT_N {
            if self.builtin_decls[b] == node { return b as i32; }
        }
        return -1;
    }

    // Record / test a method DefId as referenced, for demand-driven instance-method emission.
    pub fn mark_method_used(self: &mut Self, d: DefId) void {
        if d.node == NODE_NONE { return; }
        let m = d.module as usize;
        while self.method_used.len() <= m { self.method_used.push(Vector::<bool>::new()); }
        let inner = &mut self.method_used[m];
        while inner.len() <= d.node as usize { inner.push(false); }
        inner.set(d.node as usize, true);
    }

    pub fn method_used_get(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE { return false; }
        let m = d.module as usize;
        if m >= self.method_used.len() { return false; }
        let inner = self.method_used.at(m);
        if d.node as usize >= inner.len() { return false; }
        return inner[d.node as usize];
    }

    // ------------------------------------------------------------------------------------------------------
    // Cross-module name lookup.
    // ------------------------------------------------------------------------------------------------------

    // Find a *public* top-level declaration named `name` in module `mid`: a type when `want_type`, otherwise
    // a value. Returns the decl's NodeId within module `mid`'s Ast, or NODE_NONE.
    pub fn lookup(self: &Self, mid: ModuleId, name: str, want_type: bool) NodeId {
        if !self.modules[mid as usize].has_ast { return NODE_NONE; }
        let ast = unsafe &*self.module_ast_ptr(mid);
        let src = self.modules[mid as usize].source;
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
                        if l == name.len()
                            && unsafe cstring::memcmp((src + sp.start as usize),
                                                      name.ptr(), name.len()) == 0 {
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
                if l == name.len()
                    && unsafe cstring::memcmp((src + sp.start as usize),
                                              name.ptr(), name.len()) == 0 {
                    return nid;
                }
            }
        }
        return NODE_NONE;
    }

    // Like lookup but across every prelude module; the hit's `mid` is the owning module.
    pub fn prelude_lookup(self: &Self, name: str, want_type: bool) LookupHit {
        for i in 0..self.modules.len() {
            if self.modules[i].prelude {
                let d = self.lookup(i as ModuleId, name, want_type);
                if d != NODE_NONE { return LookupHit { node: d, mid: i as ModuleId }; }
            }
        }
        return LookupHit { node: NODE_NONE, mid: 0 };
    }

    // lookup extended over `mid`'s transitive imports (imports are public, C-style): searches `mid` itself,
    // then every module it imports breadth-first in declaration order. First hit wins.
    pub fn glob_lookup(self: &Self, mid: ModuleId, name: str,
                       want_type: bool) LookupHit {
        let n = self.modules.len();
        let mut result = LookupHit { node: NODE_NONE, mid: 0 };
        if (mid as usize) >= n { return result; }
        let mut seen = Vector::<bool>::new();
        for s in 0..n { seen.push(false); }
        let mut queue = Vector::<ModuleId>::new();
        queue.push(mid);
        seen.set(mid as usize, true);
        let mut head: usize = 0;
        while head < queue.len() {
            let mo = queue[head];
            head = head + 1;
            let d = self.lookup(mo, name, want_type);
            if d != NODE_NONE {
                result = LookupHit { node: d, mid: mo };
                break;
            }
            if self.modules[mo as usize].has_ast {
                let md = self.modules.at(mo as usize);
                let items = md.ast.at_const(md.ast.root).as_data.program.items;
                let ids = md.ast.list(items);
                let src = md.source;
                for i in 0..items.len {
                    let it = md.ast.at_const(unsafe ids[i as usize]);
                    if it.kind == NodeKind::NODE_IMPORT {
                        let path = join_parts(&md.ast, src, it.as_data.import_decl.path, "::".ptr() as *const char);
                        let c = self.find(str::from_raw(path as *const u8, unsafe cstring::strlen(path)));
                        unsafe stdlib::free(path as *mut void);
                        if c >= 0 && !seen[c as usize] {
                            seen.set(c as usize, true);
                            queue.push(c as ModuleId);
                        }
                    }
                }
            }
        }
        return result;
    }

    // The modules `mid` transitively imports (excluding `mid` itself), breadth-first in declaration order.
    pub fn import_closure(self: &Self, mid: ModuleId) Vector<ModuleId> {
        let n = self.modules.len();
        let mut out = Vector::<ModuleId>::new();
        if (mid as usize) > n { return out; } // the standalone Ast (module == count) has no imports to walk
        let mut seen = Vector::<bool>::new();
        for s in 0..n + 1 { seen.push(false); }
        seen.set(mid as usize, true);
        let mut head: usize = 0;
        let mut cur = mid;
        let mut go = true;
        while go {
            if (cur as usize) < n && self.modules[cur as usize].has_ast {
                let ast = unsafe &*self.module_ast_ptr(cur);
                let items = ast.at_const(ast.root).as_data.program.items;
                let ids = ast.list(items);
                let src = self.modules[cur as usize].source;
                for i in 0..items.len {
                    let it = ast.at_const(unsafe ids[i as usize]);
                    if it.kind == NodeKind::NODE_IMPORT {
                        let path = join_parts(&*ast, src, it.as_data.import_decl.path, "::".ptr() as *const char);
                        let c = self.find(str::from_raw(path as *const u8, unsafe cstring::strlen(path)));
                        unsafe stdlib::free(path as *mut void);
                        if c >= 0 && !seen[c as usize] {
                            seen.set(c as usize, true);
                            out.push(c as ModuleId);
                        }
                    }
                }
            }
            if head >= out.len() { go = false; }
            else { cur = out[head]; head = head + 1; }
        }
        return out;
    }

    // Is `m` a user (non-prelude) module? The standalone test Ast lives at module == count (outside modules).
    fn module_is_user(self: &Self, m: ModuleId) bool {
        return (m as usize) >= self.modules.len() || !self.modules[m as usize].prelude;
    }

    // Does module `from`'s code reference anything in module `to` (a cross-module use edge)?
    fn module_imports(self: &Self, from: ModuleId, to: ModuleId) bool {
        if (from as usize) >= self.modules.len() || !self.modules[from as usize].has_ast { return false; }
        let r = &self.modules[from as usize].ast.resolutions;
        for i in 0..r.len() {
            let d = r[i];
            if d.node != NODE_NONE && d.module == to { return true; }
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
        if y.kind == TypeKind::TYPE_SLICE { return 0xFFFF as ModuleId; }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION {
            if self.module_is_user(y.module) { return y.module; }
            return 0xFFFF as ModuleId;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.modules[am as usize].ast.instance(y.as_data.inst);
            return self.instance_home_in(am, &it);
        }
        return 0xFFFF as ModuleId;
    }

    // The module a concrete instance must be emitted in (re-homed to a by-value user-type arg, else the owner).
    fn instance_home_in(self: &Self, am: ModuleId, it: &TyInstance) ModuleId {
        for i in 0..it.n {
            let h = self.type_user_home(am, it.args[i as usize]);
            if h != 0xFFFF as ModuleId && (self.module_is_user(h) || self.module_imports(h, it.module)) {
                return h;
            }
        }
        return it.module;
    }

    // Public entry: `a` is the Ast currently being emitted (== self.modules[a.module].ast).
    pub fn instance_home(self: &Self, a: &Ast, it: &TyInstance) ModuleId {
        return self.instance_home_in(a.module, it);
    }

    // Mid-based entry for the free-function propagation/emit-order ports (they hold raw `*mut Ast`).
    pub fn instance_home_mid(self: &Self, am: ModuleId, it: &TyInstance) ModuleId {
        return self.instance_home_in(am, it);
    }
}

extend Package as Free {
    pub fn free(self: &mut Self) void {
        self.modules.free();
        unsafe stdlib::free(self.root_dir as *mut void);
        unsafe stdlib::free(self.std_root as *mut void);
        self.method_used.free();
    }
}

// ---------------------------------------------------------------------------------------------------------
// Cross-module instance propagation + emit ordering (ports of loader.c's file-scope helpers). These thread
// raw `*mut Ast`/`*const Ast` pointers to sidestep the by-value move rules on `&Ast`; the modules Vector is
// never grown during propagation, so pointers into `modules[x].ast` stay valid throughout.
// ---------------------------------------------------------------------------------------------------------

fn pkg_ast_m(p: &mut Package, m: ModuleId) *mut Ast {
    return (&mut p.modules[m as usize].ast) as *mut Ast;
}
fn pkg_ast_c(p: &Package, m: ModuleId) *const Ast {
    return (&p.modules[m as usize].ast) as *const Ast;
}

// True when `t` mentions a function VALUE type anywhere (a TYPE_FUNCTION, possibly nested): its C symbol
// (and env struct) is local to the module defining it, so a use over it must stay in the calling module.
fn type_mentions_fnval(p: &Package, mid: ModuleId, t: TypeId) bool {
    let y = unsafe *(pkg_ast_c(&*p, mid)).type_at(t);
    if y.kind == TypeKind::TYPE_FUNCTION { return true; }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE ||
       y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return type_mentions_fnval(&*p, mid, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = unsafe *(pkg_ast_c(&*p, mid)).instance(y.as_data.inst);
        for i in 0..it.n {
            if type_mentions_fnval(&*p, mid, it.args[i as usize]) { return true; }
        }
        return false;
    }
    return false;
}

// Substitute the generic params `gids`->`args` while reinterning `owner`'s type `t` into `dest`'s pools.
fn subst_reintern_type(p: &mut Package, dm: ModuleId, om: ModuleId, t: TypeId, gmod: ModuleId,
                       gids: *const NodeId, args: *const TypeId, nargs: u8) TypeId {
    if t == TYPE_NONE { return TYPE_NONE; }
    let ty = unsafe *(pkg_ast_c(&*p, om)).type_at(t);
    if ty.kind == TypeKind::TYPE_GENERIC {
        for i in 0..nargs {
            if ty.module == gmod && ty.as_data.decl == unsafe gids[i as usize] { return unsafe args[i as usize]; }
        }
        let d = pkg_ast_m(&mut *p, dm);
        let o = pkg_ast_c(&*p, om);
        return unsafe (*d).reintern(&*o, t);
    }
    if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE ||
       ty.kind == TypeKind::TYPE_SLICE || ty.kind == TypeKind::TYPE_ARRAY {
        let mut nt = ty;
        nt.as_data.elem = subst_reintern_type(&mut *p, dm, om, ty.as_data.elem, gmod, gids, args, nargs);
        let d = pkg_ast_m(&mut *p, dm);
        return unsafe (*d).intern_type(nt);
    }
    if ty.kind == TypeKind::TYPE_INSTANCE {
        let inst = unsafe *(pkg_ast_c(&*p, om)).instance(ty.as_data.inst);
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let m = if inst.n < 4 { inst.n; } else { 4 as u8; };
        for i in 0..m {
            na[i as usize] = subst_reintern_type(&mut *p, dm, om, inst.args[i as usize], gmod, gids, args, nargs);
        }
        let d = pkg_ast_m(&mut *p, dm);
        return unsafe (*d).intern_instance(inst.module, inst.decl, &na[0], m);
    }
    let d = pkg_ast_m(&mut *p, dm);
    let o = pkg_ast_c(&*p, om);
    return unsafe (*d).reintern(&*o, t);
}

// Reintern one member/param/return type after substitution; if it lands on a concrete instance whose home
// differs from `dest`, also seed that home's table. Sets `*changed` only on the final growth path (parity).
fn reintern_nested_type(p: &mut Package, dm: ModuleId, om: ModuleId, t: TypeId, gmod: ModuleId,
                        gids: *const NodeId, args: *const TypeId, nargs: u8, changed: *mut bool) void {
    if t == TYPE_NONE { return; }
    let before = unsafe (*(pkg_ast_c(&*p, dm))).instances.len();
    let mut st = subst_reintern_type(&mut *p, dm, om, t, gmod, gids, args, nargs);
    let mut y = unsafe *(pkg_ast_c(&*p, dm)).type_at(st);
    while y.kind == TypeKind::TYPE_ARRAY {
        st = y.as_data.elem;
        y = unsafe *(pkg_ast_c(&*p, dm)).type_at(st);
    }
    if y.kind != TypeKind::TYPE_INSTANCE { return; }
    let it = unsafe *(pkg_ast_c(&*p, dm)).instance(y.as_data.inst);
    let mut concrete = true;
    for i in 0..it.n {
        if !unsafe (*(pkg_ast_c(&*p, dm))).type_concrete(it.args[i as usize]) { concrete = false; }
    }
    if !concrete { return; }
    let np = p.modules.len();
    let home = p.instance_home_mid(dm, &it);
    let mut has_h = false;
    let mut hm: ModuleId = 0;
    if (home as usize) < np { has_h = true; hm = home; }
    else if dm == home { has_h = true; hm = dm; }
    if has_h && hm != dm {
        let m = if it.n < 4 { it.n; } else { 4 as u8; };
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let hbefore = unsafe (*(pkg_ast_c(&*p, hm))).instances.len();
        for k in 0..m {
            let h = pkg_ast_m(&mut *p, hm);
            let d = pkg_ast_c(&*p, dm);
            na[k as usize] = unsafe (*h).reintern(&*d, it.args[k as usize]);
        }
        let h = pkg_ast_m(&mut *p, hm);
        let _ = unsafe (*h).intern_instance(it.module, it.decl, &na[0], m);
        let hafter = unsafe (*(pkg_ast_c(&*p, hm))).instances.len();
        if hafter != hbefore { unsafe *changed = true; }
    }
    let after = unsafe (*(pkg_ast_c(&*p, dm))).instances.len();
    if after != before { unsafe *changed = true; }
}

// Seed `dest` with the concrete instances nested in a generic aggregate's member/variant types.
fn reintern_nested_instance_deps(p: &mut Package, dm: ModuleId, it: &TyInstance, args: *const TypeId,
                                 nargs: u8, changed: *mut bool) void {
    let np = p.modules.len();
    let itmod = it.module;
    if (itmod as usize) >= np || !p.modules[itmod as usize].has_ast { return; }
    let decl = it.decl;
    let dn_kind = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(decl).kind;
    let generics = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(decl).as_data.aggregate.generics;
    if (dn_kind != NodeKind::NODE_STRUCT && dn_kind != NodeKind::NODE_ENUM) || generics.len == 0 { return; }
    let members = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(decl).as_data.aggregate.members;
    let gids = unsafe (*(pkg_ast_c(&*p, itmod))).list(generics);
    let mids = unsafe (*(pkg_ast_c(&*p, itmod))).list(members);
    for m in 0..members.len {
        let mid = unsafe mids[m as usize];
        let mnk = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(mid).kind;
        if dn_kind == NodeKind::NODE_STRUCT && mnk == NodeKind::NODE_FIELD {
            let fty = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(mid).as_data.field.ty;
            let tt = unsafe (*(pkg_ast_c(&*p, itmod))).type_of(fty);
            reintern_nested_type(&mut *p, dm, itmod, tt, itmod, gids, args, nargs, changed);
        } else if dn_kind == NodeKind::NODE_ENUM && mnk == NodeKind::NODE_VARIANT {
            let payload = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(mid).as_data.variant.payload;
            let pids = unsafe (*(pkg_ast_c(&*p, itmod))).list(payload);
            for k in 0..payload.len {
                let pfid = unsafe pids[k as usize];
                let pfk = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(pfid).kind;
                let tn = if pfk == NodeKind::NODE_FIELD { unsafe (*(pkg_ast_c(&*p, itmod))).at_const(pfid).as_data.field.ty; } else { pfid; };
                let tt = unsafe (*(pkg_ast_c(&*p, itmod))).type_of(tn);
                reintern_nested_type(&mut *p, dm, itmod, tt, itmod, gids, args, nargs, changed);
            }
        }
    }
}

// Seed `dest` with concrete instances nested in a generic extend's method signatures over this instance.
fn reintern_method_signature_deps(p: &mut Package, dm: ModuleId, it: &TyInstance, args: *const TypeId,
                                  nargs: u8, changed: *mut bool) void {
    let np = p.modules.len();
    let itmod = it.module;
    if (itmod as usize) >= np || !p.modules[itmod as usize].has_ast { return; }
    let itdecl = it.decl;
    let root = unsafe (*(pkg_ast_c(&*p, itmod))).root;
    let items = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(root).as_data.program.items;
    let ids = unsafe (*(pkg_ast_c(&*p, itmod))).list(items);
    for i in 0..items.len {
        let eid = unsafe ids[i as usize];
        let ek = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(eid).kind;
        if ek != NodeKind::NODE_EXTEND { continue; }
        let egen = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(eid).as_data.extend_def.generics;
        if egen.len == 0 { continue; }
        let etgt = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(eid).as_data.extend_def.target_type;
        if unsafe (*(pkg_ast_c(&*p, itmod))).resolution(etgt) != itdecl { continue; }
        let gids = unsafe (*(pkg_ast_c(&*p, itmod))).list(egen);
        let eitems = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(eid).as_data.extend_def.items;
        let emids = unsafe (*(pkg_ast_c(&*p, itmod))).list(eitems);
        for mm in 0..eitems.len {
            let fnid = unsafe emids[mm as usize];
            let fnk = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(fnid).kind;
            if fnk != NodeKind::NODE_FUNCTION { continue; }
            let fgen = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(fnid).as_data.function.generics;
            let frets = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(fnid).as_data.function.returns;
            if fgen.len != 0 || frets.len > 1 { continue; }
            let fparams = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(fnid).as_data.function.params;
            let pids = unsafe (*(pkg_ast_c(&*p, itmod))).list(fparams);
            let mut k: u32 = 0;
            while k < fparams.len {
                let pid = unsafe pids[k as usize];
                let pty = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(pid).as_data.parameter.ty;
                let tt = unsafe (*(pkg_ast_c(&*p, itmod))).type_of(pty);
                reintern_nested_type(&mut *p, dm, itmod, tt, itmod, gids, args, nargs, changed);
                k = k + 1;
            }
            let rids = unsafe (*(pkg_ast_c(&*p, itmod))).list(frets);
            k = 0;
            while k < frets.len {
                let rid = unsafe rids[k as usize];
                let rk = unsafe (*(pkg_ast_c(&*p, itmod))).at_const(rid).kind;
                let tn = if rk == NodeKind::NODE_PARAMETER { unsafe (*(pkg_ast_c(&*p, itmod))).at_const(rid).as_data.parameter.ty; } else { rid; };
                let tt = unsafe (*(pkg_ast_c(&*p, itmod))).type_of(tn);
                reintern_nested_type(&mut *p, dm, itmod, tt, itmod, gids, args, nargs, changed);
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
    let s = pkg_ast_c(&*p, sm);
    let n = unsafe (*s).instances.len();
    let np = p.modules.len();
    for i in start..n {
        let it = unsafe *s.instance(i as u32);
        let mut concrete = true;
        for k in 0..it.n {
            if !unsafe (*s).type_concrete(it.args[k as usize]) { concrete = false; }
        }
        if !concrete { continue; }
        let home = p.instance_home_mid(sm, &it);
        if (home as usize) >= np { continue; }
        let dm = home;
        let m = if it.n < 4 { it.n; } else { 4 as u8; };
        let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        for k2 in 0..m {
            if dm == sm { na[k2 as usize] = it.args[k2 as usize]; }
            else {
                let d = pkg_ast_m(&mut *p, dm);
                na[k2 as usize] = unsafe (*d).reintern(&*s, it.args[k2 as usize]);
            }
        }
        if dm != sm {
            let before = unsafe (*(pkg_ast_c(&*p, dm))).instances.len();
            let d = pkg_ast_m(&mut *p, dm);
            let _ = unsafe (*d).intern_instance(it.module, it.decl, &na[0], m);
            let after = unsafe (*(pkg_ast_c(&*p, dm))).instances.len();
            if after != before { changed = true; }
        }
        let cp = (&mut changed) as *mut bool;
        reintern_nested_instance_deps(&mut *p, dm, &it, &na[0], m, cp);
        reintern_method_signature_deps(&mut *p, dm, &it, &na[0], m, cp);
    }
    return changed;
}

// Record `src`'s generic-method calls into the method's OWNING module (or the receiver instance's home),
// so that module emits the matching `Inst__method__targs` specialization. Returns true on growth.
fn reintern_method_insts(p: &mut Package, sm: ModuleId) bool {
    let mut changed = false;
    let s = pkg_ast_c(&*p, sm); // stable for the call (see reintern_cross_module); avoids re-deriving per node
    let n = unsafe (*s).nodes.len();
    let np = p.modules.len();
    let mut i: NodeId = 0;
    while (i as usize) < n {
        let ck = unsafe (*s).at_const(i).kind;
        if ck != NodeKind::NODE_CALL { i = i + 1; continue; }
        let callee_id = unsafe (*s).at_const(i).as_data.call.callee;
        let cek = unsafe (*s).at_const(callee_id).kind;
        if cek != NodeKind::NODE_MEMBER { i = i + 1; continue; }
        let member_id = unsafe (*s).at_const(callee_id).as_data.member.member;
        let md = unsafe (*s).resolution_def(member_id);
        if md.node == NODE_NONE { i = i + 1; continue; }
        if (md.module as usize) >= np || !p.modules[md.module as usize].has_ast { i = i + 1; continue; }
        let om = md.module;
        let mnk = unsafe (*(pkg_ast_c(&*p, om))).at_const(md.node).kind;
        let mgen = unsafe (*(pkg_ast_c(&*p, om))).at_const(md.node).as_data.function.generics;
        if mnk != NodeKind::NODE_FUNCTION || mgen.len == 0 { i = i + 1; continue; }
        let mu = unsafe (*s).type_args(i);
        if mu == null || unsafe (*mu).n == 0 { i = i + 1; continue; }
        let object_id = unsafe (*s).at_const(callee_id).as_data.member.object;
        let mut rty = unsafe (*s).type_of(object_id);
        let du = unsafe (*s).deref_use_at(member_id);
        if du != null { rty = unsafe (*du).target; }
        let mut yk = unsafe (*s).type_at(rty).kind;
        while yk == TypeKind::TYPE_POINTER || yk == TypeKind::TYPE_REFERENCE {
            rty = unsafe (*s).type_at(rty).as_data.elem;
            yk = unsafe (*s).type_at(rty).kind;
        }
        if unsafe (*s).type_at(rty).kind != TypeKind::TYPE_INSTANCE || !unsafe (*s).type_concrete(rty) { i = i + 1; continue; }
        let mtn = if unsafe (*mu).n < 4 { unsafe (*mu).n; } else { 4 as u8; };
        let mut concrete = true;
        for k in 0..mtn {
            if !unsafe (*s).type_concrete((*mu).args[k as usize]) { concrete = false; }
        }
        if !concrete { i = i + 1; continue; }
        let recv_inst = unsafe (*s).type_at(rty).as_data.inst;
        let recv = unsafe *s.instance(recv_inst);
        let home = p.instance_home_mid(sm, &recv);
        let mut dm = om;
        if (home as usize) < np { dm = home; }
        for kk in 0..mtn {
            if type_mentions_fnval(&*p, sm, unsafe (*mu).args[kk as usize]) { dm = sm; break; }
        }
        let rinst = if dm == sm { rty; } else { let d = pkg_ast_m(&mut *p, dm); unsafe (*d).reintern(&*s, rty); };
        let mut targs: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        for t in 0..mtn {
            if dm == sm { targs[t as usize] = unsafe (*mu).args[t as usize]; }
            else { let d = pkg_ast_m(&mut *p, dm); targs[t as usize] = unsafe (*d).reintern(&*s, (*mu).args[t as usize]); }
        }
        let d = pkg_ast_m(&mut *p, dm);
        if unsafe (*d).add_method_inst(rinst, md.node, &targs[0], mtn) { changed = true; }
        i = i + 1;
    }
    return changed;
}

// Owners emit the generic instances used across module boundaries: iterate to a fixpoint.
pub fn package_propagate_instances(p: &mut Package) void {
    let n = p.modules.len();
    // Instances are only ever appended and re-interning one is idempotent, so each needs processing exactly
    // once; the fixpoint exists only to reach instances CREATED while processing earlier ones. Track how far
    // each module's instance table has been consumed and re-scan only the newly-appended tail per sweep -- the
    // confirming sweep then touches just the handful the productive sweep added, not every instance again.
    let mut proc_inst = Vector::<usize>::new();
    for u in 0..n { proc_inst.push(0); }
    let mut changed = true;
    while changed {
        changed = false;
        for u in 0..n {
            if p.modules[u].has_ast {
                let start = proc_inst[u];
                let ni = unsafe (*(pkg_ast_c(&*p, u as ModuleId))).instances.len();
                if start < ni {
                    if reintern_cross_module(&mut *p, u as ModuleId, start) { changed = true; }
                    proc_inst[u] = ni;
                }
                if reintern_method_insts(&mut *p, u as ModuleId) { changed = true; }
            }
        }
    }
}

// Dependency-first module emit order: if module `a` full-monomorphizes a generic owned by `b` (re-homing a
// concrete instance to `a` itself), `b` must be emitted first. Kahn topo-sort with a lowest-id tiebreak;
// `order` is caller-allocated with `modules.len()` entries.
pub fn package_emit_order(p: &Package, order: *mut ModuleId) void {
    let n = p.modules.len();
    if n == 0 { return; }
    let done = unsafe stdlib::calloc(n, 1) as *mut bool;
    let dep = unsafe stdlib::calloc(n * n, 1) as *mut bool;
    let indeg = unsafe stdlib::calloc(n, 4) as *mut u32;
    if done == null || dep == null || indeg == null {
        for i in 0..n { unsafe order[i] = i as ModuleId; }
        unsafe stdlib::free(done as *mut void);
        unsafe stdlib::free(dep as *mut void);
        unsafe stdlib::free(indeg as *mut void);
        return;
    }
    for a in 0..n {
        if !p.modules[a].has_ast { continue; }
        let aa = pkg_ast_c(&*p, a as ModuleId);
        let mut i: usize = 0;
        while i < unsafe (*aa).instances.len() {
            let it = unsafe *(*aa).instance(i as u32);
            let bi = it.module as usize;
            if bi >= n || bi == a || (unsafe dep[a * n + bi]) { i = i + 1; continue; }
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe (*aa).type_concrete(it.args[k as usize]) { concrete = false; }
            }
            if concrete && p.instance_home_mid(a as ModuleId, &it) == a as ModuleId {
                unsafe dep[a * n + bi] = true;
                unsafe { indeg[a] = indeg[a] + 1; }
            }
            i = i + 1;
        }
        i = 0;
        while i < unsafe (*aa).method_insts.len() {
            let miinst = unsafe (*aa).method_insts[i].instance;
            let y = unsafe *(*aa).type_at(miinst);
            if y.kind != TypeKind::TYPE_INSTANCE { i = i + 1; continue; }
            let bi = unsafe (*aa).instance(y.as_data.inst).module as usize;
            if bi >= n || bi == a || (unsafe dep[a * n + bi]) { i = i + 1; continue; }
            unsafe dep[a * n + bi] = true;
            unsafe { indeg[a] = indeg[a] + 1; }
            i = i + 1;
        }
        i = 0;
        while i < unsafe (*aa).mono.len() {
            let mnode = unsafe (*aa).mono[i].node;
            if unsafe (*aa).at_const(mnode).kind != NodeKind::NODE_CALL { i = i + 1; continue; }
            let callee_id = unsafe (*aa).at_const(mnode).as_data.call.callee;
            let ck = unsafe (*aa).at_const(callee_id).kind;
            let fd = if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let e = unsafe (*aa).at_const(callee_id).as_data.specialization.expression;
                unsafe (*aa).resolution_def(e);
            } else {
                unsafe (*aa).resolution_def(callee_id);
            };
            let bi = fd.module as usize;
            if fd.node == NODE_NONE || bi >= n || bi == a || (unsafe dep[a * n + bi]) { i = i + 1; continue; }
            if !p.modules[bi].has_ast { i = i + 1; continue; }
            let bast = pkg_ast_c(&*p, fd.module);
            if unsafe (*bast).at_const(fd.node).kind != NodeKind::NODE_FUNCTION { i = i + 1; continue; }
            unsafe dep[a * n + bi] = true;
            unsafe { indeg[a] = indeg[a] + 1; }
            i = i + 1;
        }
    }
    for kk in 0..n {
        let mut pick = n;
        let mut i: usize = 0;
        while i < n {
            if !(unsafe done[i]) && (unsafe indeg[i]) == 0 { pick = i; break; }
            i = i + 1;
        }
        if pick == n {
            i = 0;
            while i < n { if !(unsafe done[i]) { pick = i; break; } i = i + 1; }
        }
        unsafe order[kk] = pick as ModuleId;
        unsafe done[pick] = true;
        for x in 0..n {
            if !(unsafe done[x]) && (unsafe dep[x * n + pick]) && (unsafe indeg[x]) > 0 {
                unsafe { indeg[x] = indeg[x] - 1; }
            }
        }
    }
    unsafe stdlib::free(done as *mut void);
    unsafe stdlib::free(dep as *mut void);
    unsafe stdlib::free(indeg as *mut void);
}

// Load `root_file` and, transitively, every module it imports, then append the std prelude found under
// `std_dir` (NULL skips it). Diagnostics are printed as encountered. Returns a Package (check `.ok`).
pub fn package_load(root_file: *const char, std_dir: *const char) Package {
    let mut p = Package::new();
    p.ok = true;
    p.root_dir = dir_of(root_file);
    if std_dir != null { p.std_root = dir_of(std_dir); }
    p.load_module(stem_of(root_file), dup_cstr(root_file));
    load_prelude(&mut p, std_dir);
    p.seed_core();
    return p;
}

// Like package_load, but the root module is an in-memory source STRING (path "main"), with no user-import
// recursion -- the analog of tests/test_harness.h's sc_compile. The prelude loads FIRST and the user
// module is appended LAST (its module id past the prelude), matching sc_compile's layout exactly, so
// module-order-sensitive checks (Ty interning, generic-arg validation) reproduce the C test verdicts.
// The user module is always the last one: `p.modules.len() - 1`. Used by selfhost/tests.
pub fn package_from_source(src: *const char, len: usize, std_dir: *const char) Package {
    let mut p = Package::new();
    p.ok = true;
    p.root_dir = dup_cstr(".".ptr() as *const char);
    if std_dir != null { p.std_root = dir_of(std_dir); }
    load_prelude(&mut p, std_dir);
    let parsed = parse_source(src, len, "<harness>".ptr() as *const char);
    let ok = parsed.ok;
    let id = p.add_module(dup_cstr("main".ptr() as *const char), dup_cstr("<harness>".ptr() as *const char),
                          dup_cstr(src), len, parsed.ast, ok);
    if ok { p.modules[id as usize].ast.module = id as ModuleId; }
    else { p.ok = false; }
    p.seed_core();
    return p;
}

// A PATH_MAX realpath scratch buffer (the omitted array field zero-fills on partial init).
struct RealBuf { pub b: [char; 4096] }

// Canonical (realpath) form of `path` as a fresh heap string, or null if it can't be resolved.
// Two paths name the same file iff their canon_of results are non-null and strcmp-equal.
fn canon_of(path: *const char) *mut char {
    if path == null { return null; }
    let mut r = RealBuf { };
    if unsafe shim::sc_realpath(path, (&mut r.b[0]) as *mut char) == null { return null; }
    return dup_cstr((&r.b[0]) as *const char);
}

// Auto-import the prelude: every TOP-LEVEL `<std_dir>/*.spc` (not subdirectories) becomes a prelude module
// whose public items resolve unqualified. A file already loaded (explicitly imported) is flagged in place;
// otherwise it is loaded under the reserved `__std::` namespace so its build output never collides with a
// user's own `std/` folder. Names are sorted for deterministic module ids regardless of readdir order.
fn load_prelude(p: &mut Package, std_dir: *const char) void {
    if std_dir == null { return; }
    let dir = unsafe shim::sc_opendir(std_dir);
    if dir == null { return; }
    let mut names = Vector::<*mut char>::new();
    loop {
        let e = unsafe shim::sc_readdir(dir);
        if e == null { break; }
        let nm = unsafe shim::sc_dirent_name(e);
        let l = unsafe cstring::strlen(nm);
        if l < 5 { continue; }
        if unsafe cstring::strcmp((nm + (l - 4)) as *const char, ".spc".ptr() as *const char) != 0 { continue; }
        names.push(dup_cstr(nm));
    }
    let _ = unsafe shim::sc_closedir(dir);
    // sort by name (small: the std/ file list)
    names.sort_by(|a: &*mut char, b: &*mut char| unsafe cstring::strcmp((*a) as *const char, (*b) as *const char));
    // Canonicalize the already-loaded modules' paths ONCE (the user's explicit import closure). A std file
    // is a duplicate iff it was explicitly imported, so only these initial modules can match; the __std::
    // modules appended below have distinct names and never do. Precomputing here makes the dedup O(S+M)
    // realpaths instead of O(S*M) -- realpath walks the filesystem, so it dominated the profile otherwise.
    let m0 = p.modules.len();
    let mut canon = Vector::<*mut char>::new();
    for ci in 0..m0 { 
        canon.push(canon_of(p.modules[ci].file));
    }

    for k in 0..names.len() {
        let nmk = names[k];
        let dl = unsafe cstring::strlen(std_dir);
        let nl = unsafe cstring::strlen(nmk as *const char);
        let fl = dl + 1 + nl + 1;
        let file = unsafe stdlib::malloc(fl) as *mut char;
        unsafe stdio::snprintf(file, fl, "%s/%s".ptr() as *const char, std_dir, nmk);
        if unsafe shim::sc_stat_isdir(file) == 1 { // a dir literally named "*.spc"
            unsafe stdlib::free(file as *mut void);
            unsafe stdlib::free(nmk as *mut void);
            continue;
        }
        let rf = canon_of(file as *const char);
        let mut dup = false;
        if rf != null {
            for i2 in 0..canon.len() {
                let c = canon[i2];
                if c != null && unsafe cstring::strcmp(c as *const char, rf as *const char) == 0 {
                    p.modules[i2].prelude = true;
                    dup = true;
                    break;
                }
            }
        }
        if rf != null { unsafe stdlib::free(rf as *mut void); }
        if !dup {
            let stem = stem_of(nmk as *const char);
            let sl = unsafe cstring::strlen(stem);
            let pl = 7 + sl + 1; // "__std::" is 7 chars
            let modpath = unsafe stdlib::malloc(pl) as *mut char;
            unsafe stdio::snprintf(modpath, pl, "__std::%s".ptr() as *const char, stem);
            unsafe stdlib::free(stem as *mut void);
            let id = p.load_module(modpath, file); // takes ownership of modpath + file
            if id >= 0 { p.modules[id as usize].prelude = true; }
        } else {
            unsafe stdlib::free(file as *mut void);
        }
        unsafe stdlib::free(nmk as *mut void);
    }

    for ci in 0..canon.len() {
        let c = canon[ci];
        if c != null { unsafe stdlib::free(c as *mut void); }
    }
}
