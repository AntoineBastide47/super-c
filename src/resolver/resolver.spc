import string as cstring;
import stdlib;
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;
import utils::errors as diag;

// A scratch buffer to NUL-terminate a module's file path (a `str` view into an owned String) before
// handing it to the C-string diagnostic renderer.

// Value vs type namespace. Stored on each Symbol so a scope-exit can recompute its index key.
pub enum Namespace {
    NS_VALUE,
    NS_TYPE,
}

// One live binding on the scope stack. 16 bytes (a power-of-2 stride for the hot linear scope scan): the
// namespace rides in the top bit of `decl` -- NodeIds are far below 2^31 -- so no separate `ns` byte is
// needed. Mask `decl & 0x7FFFFFFF` for the real NodeId; `decl >> 31` recovers the Namespace.
pub struct Symbol {
    pub hash: u32,
    pub decl: NodeId,
    pub name: tok::Span,
}

// An open closure being resolved: a value ref binding below `floor` is a CAPTURE (copied into its env by
// codegen), collected here (deduped, discovery order) and committed to the node's `captures` at exit.
pub struct ClosureScope {
    pub node: NodeId,
    pub floor: u32,
    pub caps: Vector<NodeId>,
}

extend ClosureScope as Free {
    pub fn free(self: &mut Self) void {
        self.caps.free();
    }
}

pub struct Resolver {
    pub ast: Ast,
    pub source: *const u8,
    pub len: usize,
    pub symbols: Vector<Symbol>, // flat stack of live symbols across all open scopes
    pub symbol_previous: Vector<u32>, // chain links parallel to symbols, encoded as index + 1
    pub scope_starts: Vector<u32>, // stack of symbols.len at each scope entry
    pub symbol_index: Map<u64, u32>, // (namespace, name hash) -> newest matching symbol index + 1
    pub current_self: DefId, // decl 'Self' refers to inside the current interface/extension
    pub in_generic: bool, // resolving inside a generic fn/extend
    pub closures: Vector<ClosureScope>, // open closures, innermost last
    pub package: *const loader::Package, // for resolving `import`ed module-qualified names (null = none)
    pub mod_names: Vector<ModEntry>, // leading-segment module names (alias / single-segment path), import order
    pub glob_mids: Vector<ModuleId>, // module ids of `import P as *;` imports, import order
    pub errors: diag::Errors,
}

// A symbol-stack lookup result: the declaring node and its 1-based stack position (0 = not found).
pub struct SymLookup {
    pub decl: NodeId,
    pub idx: u32,
}
// A module-qualified type split: module id (-1 = not qualified) and the final type-name node.
pub struct ModQual {
    pub mid: i32,
    pub type_node: NodeId,
}
// A leading-segment-as-module test result.
pub struct ModName {
    pub found: bool,
    pub mid: ModuleId,
}
// One import usable as a leading path segment (its `as` alias, or a single-segment path), resolved once
// by scan_imports so per-reference probes never rescan the item list.
pub struct ModEntry {
    pub name: tok::Span,
    pub mid: ModuleId,
}

// ---------------------------------------------------------------------------------------------------------
// Span-based helpers (no resolver state).
// ---------------------------------------------------------------------------------------------------------

fn name_hash(src: *const u8, s: tok::Span) u32 {
    let mut h: u32 = 2166136261u32;
    let mut i = s.start;
    while i < s.end {
        h = h ^ unsafe src[i as usize] as u32;
        h = h * 16777619u32;
        i = i + 1;
    }
    return h;
}

fn span_eq(src: *const u8, a: tok::Span, b: tok::Span) bool {
    let la = a.end - a.start;
    if la != b.end - b.start {
        return false;
    }
    return unsafe cstring::memcmp(src + a.start as usize, src + b.start as usize, la as usize) == 0;
}

fn span_is(src: *const u8, s: tok::Span, lit: str) bool {
    let n = lit.len();
    if (s.end - s.start) as usize != n {
        return false;
    }
    return unsafe cstring::memcmp(src + s.start as usize, lit.ptr(), n) == 0;
}

// The BuiltinType index of name `s` (matching ast's enum order), or -1. Pointer/reference forms wrap one
// of these, which resolves on its own.
fn builtin_index(src: *const u8, s: tok::Span) i32 {
    let names: [str; 18] = [
        "bool",
        "char",
        "i8",
        "i16",
        "i32",
        "i64",
        "isize",
        "u8",
        "u16",
        "u32",
        "u64",
        "usize",
        "f32",
        "f64",
        "c32",
        "c64",
        "va_list",
        "void",
    ];
    for i in 0..18 {
        if span_is(src, s, names[i]) {
            return i as i32;
        }
    }
    return -1;
}

fn is_builtin_type(src: *const u8, s: tok::Span) bool {
    return builtin_index(src, s) >= 0;
}

fn symbol_key(hash: u32, ns: u8) u64 {
    return ns as u64 << 32 | hash as u64;
}

// ---------------------------------------------------------------------------------------------------------

extend Resolver {
    pub fn new(ast: Ast, source: str, package: *const loader::Package) Resolver {
        return Resolver {
            ast: ast,
            source: source.ptr(),
            len: source.len(),
            symbols: Vector::<Symbol>::new(),
            symbol_previous: Vector::<u32>::new(),
            scope_starts: Vector::<u32>::new(),
            symbol_index: Map::<u64, u32>::new(),
            current_self: DefId { module: 0, node: NODE_NONE },
            in_generic: false,
            closures: Vector::<ClosureScope>::new(),
            package: package,
            mod_names: Vector::<ModEntry>::new(),
            glob_mids: Vector::<ModuleId>::new(),
            errors: diag::Errors::new(),
        };
    }

    pub fn take_ast(self: &mut Self) Ast {
        let out = self.ast;
        self.ast = Ast::new(0);
        return out;
    }

    // The i-th element of `list` -- refetched each call so a closure-capture commit that grows ast.children
    // never leaves a dangling base pointer mid-iteration.
    fn child(self: &Self, list: NodeList, i: u32) NodeId {
        return unsafe self.ast.list(list)[i as usize];
    }

    fn name_span(self: &Self, name_node: NodeId) tok::Span {
        return self.ast.at_const(name_node).as_data.name.text;
    }

    // -- scope stack ---------------------------------------------------------------------------------------

    fn scope_enter(self: &mut Self) void {
        self.scope_starts.push(self.symbols.len() as u32);
    }

    fn scope_exit(self: &mut Self) void {
        let sn = self.scope_starts.len();
        let start = self.scope_starts[sn - 1];
        self.scope_starts.truncate(sn - 1);
        while self.symbols.len() as u32 > start {
            let index = self.symbols.len() - 1;
            let hash = self.symbols[index].hash;
            let ns = (self.symbols[index].decl >> 31) as u8;
            let previous = self.symbol_previous[index];
            self.symbols.truncate(index);
            let key = symbol_key(hash, ns);
            if previous != 0 {
                self.symbol_index.insert(key, previous);
            } else {
                self.symbol_index.remove(&key);
            }
        }
        self.symbol_previous.truncate(start as usize);
    }

    fn declare(self: &mut Self, name_node: NodeId, decl: NodeId, ns: Namespace) void {
        if name_node == NODE_NONE {
            return;
        }
        let name = self.name_span(name_node);
        if ns == Namespace::NS_VALUE && span_is(self.source, name, "_") {
            return;
        }
        let hash = name_hash(self.source, name);
        let key = symbol_key(hash, ns as u8);
        let mut head: u32 = 0;
        switch self.symbol_index.get(&key) {
            Some(v) => {
                head = *v;
            },
            _ => {},
        };
        let scope_start = self.scope_starts[self.scope_starts.len() - 1];
        let mut current = head;
        while current != 0 {
            let i = (current - 1) as usize;
            if i < scope_start as usize {
                break;
            }
            let sname = self.symbols[i].name;
            if span_eq(self.source, sname, name) {
                self.errors.emit(
                    name.start,
                    name.end - name.start,
                    format("duplicate definition of '{}'", diag::span_str(self.source, name.start, name.end)),
                );
                return;
            }
            current = self.symbol_previous[i];
        }
        self.symbols.push(Symbol { hash: hash, decl: decl | ns as u32 << 31, name: name });
        self.symbol_previous.push(head);
        self.symbol_index.insert(key, self.symbols.len() as u32);
    }

    // Symbol-stack lookup. `idx` is the matched symbol's 1-based stack position (0 = not found), used to
    // tell whether a reference inside a closure binds to a variable declared OUTSIDE it (a capture).
    fn sym_lookup(self: &Self, name: tok::Span, ns: Namespace) SymLookup {
        let hash = name_hash(self.source, name);
        let key = symbol_key(hash, ns as u8);
        let mut current: u32 = 0;
        switch self.symbol_index.get(&key) {
            Some(v) => {
                current = *v;
            },
            _ => {},
        };
        while current != 0 {
            let i = (current - 1) as usize;
            let sname = self.symbols[i].name;
            let sdecl = self.symbols[i].decl & 0x7FFFFFFF;
            if span_eq(self.source, sname, name) {
                return SymLookup { decl: sdecl, idx: current };
            }
            current = self.symbol_previous[i];
        }
        return SymLookup { decl: NODE_NONE, idx: 0 };
    }

    // -- module-qualified resolution -----------------------------------------------------------------------

    // Heap-join `count` name-span segments with "::". Caller frees.
    fn join_segs(self: &Self, seg_ids: *const NodeId, count: u32) *mut char {
        let mut total: usize = 0;
        let mut i: u32 = 0;
        while i < count {
            let s = self.name_span(unsafe seg_ids[i as usize]);
            total = total + (s.end - s.start) as usize;
            if i != 0 {
                total = total + 2;
            }
            i = i + 1;
        }
        let out = unsafe stdlib::malloc(total + 1) as *mut char;
        let mut at: usize = 0;
        i = 0;
        while i < count {
            if i != 0 {
                unsafe out[at] = ':' as char;
                unsafe out[at + 1] = ':' as char;
                at = at + 2;
            }
            let s = self.name_span(unsafe seg_ids[i as usize]);
            let l = (s.end - s.start) as usize;
            unsafe cstring::memcpy((out + at), self.source + s.start as usize, l);
            at = at + l;
            i = i + 1;
        }
        unsafe out[at] = 0 as char;
        return out;
    }

    // The module id named by an import's path parts (its loaded "::"-joined path), or -1.
    fn import_target(self: &Self, parts: NodeList) i32 {
        if self.package == null {
            return -1;
        }
        let pkg = unsafe &*self.package;
        let ids = self.ast.list(parts);
        let buf = self.join_segs(ids, parts.len);
        let m = pkg.find(str::from_raw(buf as *const u8, unsafe cstring::strlen(buf)));
        unsafe stdlib::free(buf);
        return m;
    }

    // Resolve every import ONCE, up front: which names denote modules as a single leading segment (the
    // `as` alias, or a single-segment path) and which module ids are glob-imported. name_is_module and
    // glob_lookup then probe these tables instead of rescanning the item list per reference.
    fn scan_imports(self: &mut Self) void {
        if self.package == null {
            return;
        }
        let items = self.ast.at_const(self.ast.root).as_data.program.items;
        for i in 0..items.len {
            let id = self.child(items, i);
            if self.ast.at_const(id).kind != NodeKind::NODE_IMPORT {
                continue;
            }
            let alias = self.ast.at_const(id).as_data.import_decl.alias;
            let parts = self.ast.at_const(id).as_data.import_decl.path;
            let glob = self.ast.at_const(id).as_data.import_decl.glob;
            let m = self.import_target(parts);
            if m < 0 {
                continue;
            }
            if glob {
                self.glob_mids.push(m as ModuleId);
            }
            let mut nm = NODE_NONE;
            if alias != NODE_NONE {
                nm = alias;
            } else if parts.len == 1 {
                nm = self.child(parts, 0);
            }
            if nm != NODE_NONE {
                let nsp = self.name_span(nm);
                self.mod_names.push(ModEntry { name: nsp, mid: m as ModuleId });
            }
        }
    }

    // True if `name` names an imported module usable as a single leading segment (via scan_imports' table).
    fn name_is_module(self: &Self, name: tok::Span) ModName {
        let n = self.mod_names.len();
        for i in 0..n {
            if span_eq(self.source, self.mod_names[i].name, name) {
                return ModName { found: true, mid: self.mod_names[i].mid };
            }
        }
        return ModName { found: false, mid: 0 };
    }

    // If a type path is module-qualified (`std::string::String`, or `alias::Type`), return its module id
    // and the final segment node; otherwise mid = -1.
    fn module_qualified_type(self: &Self, parts: NodeList) ModQual {
        if self.package == null || parts.len < 2 {
            return ModQual { mid: -1, type_node: NODE_NONE };
        }
        let pkg = unsafe &*self.package;
        let ids = self.ast.list(parts);
        let buf = self.join_segs(ids, parts.len - 1); // module = every segment but the last
        let m = pkg.find(str::from_raw(buf as *const u8, unsafe cstring::strlen(buf)));
        unsafe stdlib::free(buf);
        if m >= 0 {
            return ModQual { mid: m, type_node: unsafe ids[(parts.len - 1) as usize] };
        }
        if parts.len == 2 {
            // `alias::Type`
            let nm = self.name_is_module(self.name_span(unsafe ids[0]));
            if nm.found {
                return ModQual { mid: nm.mid as i32, type_node: unsafe ids[1] };
            }
        }
        return ModQual { mid: -1, type_node: NODE_NONE };
    }

    // Look up `name` among the modules this module glob-imports (via scan_imports' table).
    fn glob_lookup(self: &Self, name: tok::Span, want_type: bool) loader::LookupHit {
        let miss = loader::LookupHit { node: NODE_NONE, mid: 0 };
        if self.package == null {
            return miss;
        }
        let pkg = unsafe &*self.package;
        let nm = unsafe (self.source + name.start as usize) as *const char;
        let nl = (name.end - name.start) as usize;
        let ng = self.glob_mids.len();
        for i in 0..ng {
            let hit = pkg.glob_lookup(self.glob_mids[i], str::from_raw(nm as *const u8, nl), want_type);
            if hit.node != NODE_NONE {
                return hit;
            }
        }
        return miss;
    }

    // Resolve a public top-level decl `name` in module `mid` and record it (cross-module) on `ref`.
    fn resolve_module_decl(self: &mut Self, refn: NodeId, mid: ModuleId, name: tok::Span, want_type: bool, kind: str) void {
        let pkg = unsafe &*self.package;
        let nm = unsafe (self.source + name.start as usize) as *const char;
        let nl = (name.end - name.start) as usize;
        let decl = pkg.lookup(mid, str::from_raw(nm as *const u8, nl), want_type);
        if decl != NODE_NONE {
            self.ast.set_resolution_def(refn, DefId { module: mid, node: decl });
        } else {
            self.errors.emit(
                name.start,
                name.end - name.start,
                format(
                    "no public {} '{}' in the imported module",
                    kind,
                    diag::span_str(self.source, name.start, name.end),
                ),
            );
            self.errors.note(format("only 'pub' top-level items are visible across module boundaries"));
        }
    }

    // Resolve a path-member expression `id` as `<module>::<decl>` (module may be many segments). Returns
    // true if a module prefix matched (it has then handled or errored on the node).
    fn resolve_qualified_member(self: &mut Self, id: NodeId) bool {
        if self.package == null {
            return false;
        }
        let mut chain: [NodeId; 32] = [[0] = NODE_NONE]; // `::` member nodes, outermost..innermost
        let mut cc: u32 = 0;
        let mut base = NODE_NONE;
        let mut curid = id;
        let mut bail = false;
        let mut go = true;
        while go {
            let cn = self.ast.at_const(curid);
            if cn.kind != NodeKind::NODE_MEMBER || !cn.as_data.member.path || cc >= 32 {
                bail = true;
                go = false;
            } else {
                chain[cc as usize] = curid;
                cc = cc + 1;
                let o = cn.as_data.member.object;
                let on = self.ast.at_const(o);
                if on.kind == NodeKind::NODE_IDENTIFIER {
                    base = o;
                    go = false;
                } else if on.kind != NodeKind::NODE_MEMBER || !on.as_data.member.path {
                    bail = true;
                    go = false;
                } else {
                    curid = o;
                }
            }
        }
        if bail {
            return false;
        }
        let nn = cc + 1; // segment count: base + one per chain link
        let mut seg: [NodeId; 33] = [[0] = NODE_NONE];
        seg[0] = base;
        let mut i: u32 = 1;
        while i < nn {
            let link = chain[(nn - 1 - i) as usize];
            let mem = self.ast.at_const(link).as_data.member.member;
            seg[i as usize] = mem;
            i = i + 1;
        }
        let pkg = unsafe &*self.package;
        // Join the LONGEST candidate module prefix once; every shorter prefix is a byte prefix of it, so
        // the probe loop just shrinks the viewed length instead of re-joining (and re-allocating) per try.
        let buf = self.join_segs((&seg[0]) as *const NodeId, nn - 1);
        let mut lens: [usize; 32] = [[0] = 0usize];
        let mut plen: usize = 0;
        i = 0;
        while i < nn - 1 {
            let s = self.name_span(seg[i as usize]);
            lens[i as usize] = (s.end - s.start) as usize;
            plen = plen + lens[i as usize];
            if i != 0 {
                plen = plen + 2;
            }
            i = i + 1;
        }
        let mut handled = false;
        let mut done = false;
        let mut m = nn - 1; // longest module prefix leaving >=1 trailing segment
        while m >= 1 && !done {
            let found = pkg.find(str::from_raw(buf as *const u8, plen));
            if found >= 0 {
                unsafe buf[plen] = 0 as char; // NUL-terminate the matched prefix for diagnostics
                let mid = found as ModuleId;
                if nn - m == 1 {
                    // module::decl -- a function (preferred) or type
                    let dn = self.name_span(seg[m as usize]);
                    let dnm = unsafe (self.source + dn.start as usize) as *const char;
                    let dl = (dn.end - dn.start) as usize;
                    let mut decl = pkg.lookup(mid, str::from_raw(dnm as *const u8, dl), false);
                    if decl == NODE_NONE {
                        decl = pkg.lookup(mid, str::from_raw(dnm as *const u8, dl), true);
                    }
                    if decl != NODE_NONE {
                        self.ast.set_resolution_def(id, DefId { module: mid, node: decl });
                    } else {
                        self.errors.emit(
                            dn.start,
                            dn.end - dn.start,
                            format(
                                "no public item '{}' in module '{}'",
                                diag::span_str(self.source, dn.start, dn.end),
                                diag::cstr(buf),
                            ),
                        );
                        self.errors.note(format("the module was found, but this item is missing or not public"));
                    }
                    handled = true;
                } else if nn - m == 2 {
                    // module::Type::method -- record the Type
                    let chain1 = chain[1];
                    let tspan = self.name_span(seg[m as usize]);
                    self.resolve_module_decl(chain1, mid, tspan, true, "type");
                    handled = true;
                }
                done = true; // deeper than module::Type::method is not supported here
            }
            if !done {
                m = m - 1;
                if m >= 1 {
                    plen = plen - lens[m as usize] - 2;
                }
            }
        }
        unsafe stdlib::free(buf);
        return handled;
    }

    // -- references ----------------------------------------------------------------------------------------

    // Commit a scope-stack hit: record captures and the resolution. `idx` is the matched symbol's 1-based
    // stack position from sym_lookup.
    fn resolve_ref_hit(self: &mut Self, refn: NodeId, decl: NodeId, idx: u32, ns: Namespace) void {
        // A value binding declared outside an enclosing closure is a CAPTURE. Record it on every nested
        // closure whose floor it sits below. Module-level items (functions/consts) never capture.
        if ns == Namespace::NS_VALUE && self.closures.len() != 0 && idx != 0 && idx - 1 < self.closures[self.closures.len() - 1].floor {
            let dk = self.ast.at_const(decl).kind;
            if dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_FOR || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_PATTERN_NAME {
                let mut f = self.closures.len();
                while f > 0 {
                    f = f - 1;
                    if idx - 1 >= self.closures[f].floor {
                        break;
                    }
                    let mut seen = false;
                    let nc = self.closures[f].caps.len();
                    for k in 0..nc {
                        if self.closures[f].caps[k] == decl {
                            seen = true;
                            break;
                        }
                    }
                    if !seen {
                        self.closures[f].caps.push(decl);
                    }
                }
            }
        }
        self.ast.set_resolution(refn, decl);
    }

    // A name that missed the scope stack: builtin types, then the prelude/glob fallback, else an error.
    fn resolve_ref_miss(self: &mut Self, refn: NodeId, name: tok::Span, ns: Namespace, kind: str) void {
        if ns == Namespace::NS_TYPE && is_builtin_type(self.source, name) {
            return;
        }
        // Unqualified fallback: the std prelude and this module's glob imports.
        if self.package != null {
            let pkg = unsafe &*self.package;
            let nm = unsafe (self.source + name.start as usize) as *const char;
            let nl = (name.end - name.start) as usize;
            let want_type = ns == Namespace::NS_TYPE;
            let mut hit = pkg.prelude_lookup(str::from_raw(nm as *const u8, nl), want_type);
            if hit.node == NODE_NONE {
                hit = self.glob_lookup(name, want_type);
            }
            if hit.node != NODE_NONE {
                self.ast.set_resolution_def(refn, DefId { module: hit.mid, node: hit.node });
                return;
            }
        }
        self.errors.emit(
            name.start,
            name.end - name.start,
            format("cannot find {} '{}'", kind, diag::span_str(self.source, name.start, name.end)),
        );
        self.errors.note(format("check spelling, imports, and whether the item is declared before this use"));
    }

    fn resolve_ref(self: &mut Self, refn: NodeId, name_node: NodeId, ns: Namespace, kind: str) void {
        if name_node == NODE_NONE {
            return;
        }
        let name = self.name_span(name_node);
        let look = self.sym_lookup(name, ns);
        if look.decl != NODE_NONE {
            self.resolve_ref_hit(refn, look.decl, look.idx, ns);
            return;
        }
        self.resolve_ref_miss(refn, name, ns, kind);
    }

    // -- types ---------------------------------------------------------------------------------------------

    fn resolve_bounds(self: &mut Self, bounds: NodeList) void {
        for i in 0..bounds.len {
            let cid = self.child(bounds, i);
            self.resolve_type(cid);
        }
    }

    fn declare_generics(self: &mut Self, generics: NodeList) void {
        let mut i: u32 = 0;
        while i < generics.len {
            let gid = self.child(generics, i);
            let gp = self.ast.at_const(gid).as_data.generic_param;
            self.declare(gp.name, gid, Namespace::NS_TYPE);
            // A const-generic param is also a value, so it resolves in value position (e.g. `[T; N]`).
            if gp.is_const {
                self.declare(gp.name, gid, Namespace::NS_VALUE);
            }
            i = i + 1;
        }
        // Bounds and defaults after every parameter is in scope, so they may refer to each other.
        i = 0;
        while i < generics.len {
            let gid = self.child(generics, i);
            let gp = self.ast.at_const(gid).as_data.generic_param;
            self.resolve_bounds(gp.bounds);
            if gp.default_type != NODE_NONE {
                self.resolve_type(gp.default_type);
            }
            if gp.const_type != NODE_NONE {
                self.resolve_type(gp.const_type);
            }
            i = i + 1;
        }
    }

    fn resolve_where(self: &mut Self, where_clause: NodeList) void {
        for i in 0..where_clause.len {
            let wid = self.child(where_clause, i);
            let w = self.ast.at_const(wid).as_data.where_predicate;
            self.resolve_type(w.ty);
            self.resolve_bounds(w.bounds);
        }
    }

    fn resolve_type(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        let kind = self.ast.at_const(id).kind;
        if kind == NodeKind::NODE_TYPE_PATH {
            let tp = self.ast.at_const(id).as_data.type_path;
            let mq = self.module_qualified_type(tp.parts);
            if mq.mid >= 0 {
                let tspan = self.name_span(mq.type_node);
                self.resolve_module_decl(id, mq.mid as ModuleId, tspan, true, "type");
                for i in 0..tp.args.len {
                    let a = self.child(tp.args, i);
                    self.resolve_type(a);
                }
                return;
            }
            if tp.parts.len > 0 {
                let first = self.child(tp.parts, 0);
                let name = self.name_span(first);
                if span_is(self.source, name, "Self") {
                    if self.current_self.node != NODE_NONE {
                        let cs = self.current_self;
                        self.ast.set_resolution_def(id, cs);
                    } else {
                        self.errors.emit(
                            name.start,
                            name.end - name.start,
                            format("'Self' is only valid inside an interface or extension"),
                        );
                    }
                } else {
                    self.resolve_ref(id, first, Namespace::NS_TYPE, "type");
                }
            }
            for i in 0..tp.args.len {
                let a = self.child(tp.args, i);
                self.resolve_type(a);
            }
            return;
        }
        if kind == NodeKind::NODE_POINTER_TYPE || kind == NodeKind::NODE_REFERENCE_TYPE || kind == NodeKind::NODE_SLICE_TYPE || kind == NodeKind::NODE_DYN_TYPE {
            let t = self.ast.at_const(id).as_data.indirect_type.ty;
            self.resolve_type(t);
            return;
        }
        if kind == NodeKind::NODE_TUPLE_TYPE {
            let elems = self.ast.at_const(id).as_data.array_literal.elements;
            for i in 0..elems.len {
                let e = self.child(elems, i);
                self.resolve_type(e);
            }
            return;
        }
        if kind == NodeKind::NODE_ARRAY_TYPE {
            let at = self.ast.at_const(id).as_data.array_type;
            self.resolve_type(at.element);
            self.resolve_expr(at.length);
            return;
        }
        if kind == NodeKind::NODE_FUNCTION_TYPE {
            let ft = self.ast.at_const(id).as_data.function_type;
            let mut i: u32 = 0;
            while i < ft.params.len {
                let p = self.child(ft.params, i);
                self.resolve_type(p);
                i = i + 1;
            }
            i = 0;
            while i < ft.returns.len {
                let rr = self.child(ft.returns, i);
                self.resolve_type(rr);
                i = i + 1;
            }
            return;
        }
    }

    // A struct-initializer / new target may be a bare identifier or a full type path.
    fn resolve_type_name(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        if self.ast.at_const(id).kind == NodeKind::NODE_IDENTIFIER {
            self.resolve_ref(id, id, Namespace::NS_TYPE, "type");
        } else {
            self.resolve_type(id);
        }
    }

    // -- items ---------------------------------------------------------------------------------------------

    fn resolve_function(self: &mut Self, id: NodeId) void {
        let fd = self.ast.at_const(id).as_data.function;
        let saved_generic = self.in_generic;
        self.in_generic = saved_generic || fd.generics.len > 0;
        self.scope_enter();
        self.declare_generics(fd.generics);
        let mut i: u32 = 0;
        while i < fd.params.len {
            let pid = self.child(fd.params, i);
            let param = self.ast.at_const(pid).as_data.parameter;
            self.declare(param.name, pid, Namespace::NS_VALUE);
            self.resolve_type(param.ty);
            i = i + 1;
        }
        i = 0;
        while i < fd.returns.len {
            let rid = self.child(fd.returns, i);
            let rk = self.ast.at_const(rid).kind;
            if rk == NodeKind::NODE_PARAMETER {
                let rt = self.ast.at_const(rid).as_data.parameter.ty;
                self.resolve_type(rt);
            } else {
                self.resolve_type(rid);
            }
            i = i + 1;
        }
        self.resolve_where(fd.where_clause);
        if fd.body != NODE_NONE {
            self.resolve_block(fd.body);
        }
        self.scope_exit();
        self.in_generic = saved_generic;
    }

    fn resolve_type_alias(self: &mut Self, id: NodeId) void {
        let ta = self.ast.at_const(id).as_data.type_alias;
        self.scope_enter();
        self.declare_generics(ta.generics);
        self.resolve_type(ta.ty);
        self.scope_exit();
    }

    fn resolve_members(self: &mut Self, members: NodeList) void {
        for i in 0..members.len {
            let mid = self.child(members, i);
            let mk = self.ast.at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD {
                let fld = self.ast.at_const(mid).as_data.field;
                self.declare(fld.name, mid, Namespace::NS_VALUE);
                self.resolve_type(fld.ty);
            } else {
                // NODE_VARIANT
                let vr = self.ast.at_const(mid).as_data.variant;
                self.declare(vr.name, mid, Namespace::NS_VALUE);
                self.resolve_expr(vr.value); // explicit discriminant (NODE_NONE when absent)
                for j in 0..vr.payload.len {
                    let pid = self.child(vr.payload, j);
                    let pk = self.ast.at_const(pid).kind;
                    if pk == NodeKind::NODE_FIELD {
                        let pt = self.ast.at_const(pid).as_data.field.ty;
                        self.resolve_type(pt);
                    } else {
                        self.resolve_type(pid);
                    }
                }
            }
        }
    }

    fn resolve_associated_items(self: &mut Self, items: NodeList) void {
        for i in 0..items.len {
            let iid = self.child(items, i);
            switch self.ast.at_const(iid).kind {
                NODE_FUNCTION => {
                    self.resolve_function(iid);
                },
                NODE_TYPE_ALIAS => {
                    self.resolve_type_alias(iid);
                },
                NODE_CONST => {
                    let cd = self.ast.at_const(iid).as_data.const_def;
                    self.resolve_type(cd.ty);
                    self.resolve_expr(cd.value);
                },
                _ => {},
            };
        }
    }

    fn resolve_item(self: &mut Self, id: NodeId) void {
        let kind = self.ast.at_const(id).kind;
        switch kind {
            NODE_FUNCTION => {
                self.resolve_function(id);
            },
            NODE_STRUCT | NODE_ENUM => {
                let ag = self.ast.at_const(id).as_data.aggregate;
                self.scope_enter();
                self.declare_generics(ag.generics);
                if ag.is_tuple {
                    // tuple struct: members ARE type nodes
                    for i in 0..ag.members.len {
                        let mid = self.child(ag.members, i);
                        self.resolve_type(mid);
                    }
                } else {
                    self.resolve_members(ag.members);
                }
                self.scope_exit();
            },
            NODE_INTERFACE => {
                let it = self.ast.at_const(id).as_data.interface_def;
                self.scope_enter();
                self.declare_generics(it.generics);
                self.resolve_bounds(it.bounds);
                let old_self = self.current_self;
                self.current_self = DefId { module: self.ast.module, node: id };
                self.resolve_associated_items(it.items);
                self.current_self = old_self;
                self.scope_exit();
            },
            NODE_EXTEND => {
                let ex = self.ast.at_const(id).as_data.extend_def;
                self.scope_enter();
                self.declare_generics(ex.generics);
                self.resolve_type(ex.target_type);
                self.resolve_type(ex.interface_type);
                // `extend i32 { .. }`: a builtin target is not a name binding. Point it at the builtin's synthetic
                // core decl so this extend matches `i32` receivers like any extension.
                if ex.target_type != NODE_NONE && self.package != null && self.ast.resolution(ex.target_type) == NODE_NONE {
                    let tk = self.ast.at_const(ex.target_type).kind;
                    if tk == NodeKind::NODE_TYPE_PATH {
                        let tparts = self.ast.at_const(ex.target_type).as_data.type_path.parts;
                        if tparts.len == 1 {
                            let seg0 = self.child(tparts, 0);
                            let b = builtin_index(self.source, self.name_span(seg0));
                            let pkg = unsafe &*self.package;
                            let mut bd = NODE_NONE;
                            if b >= 0 {
                                bd = pkg.builtin_decl(b as BuiltinType);
                            }
                            if bd != NODE_NONE {
                                self.ast.set_resolution_def(ex.target_type, DefId { module: pkg.core_module, node: bd });
                            }
                        }
                    }
                }
                // `Self` here resolves to the extend target (alias-anchored) if it resolved, else the extend node.
                let old_self = self.current_self;
                let mut resolved = DefId { module: self.ast.module, node: NODE_NONE };
                if ex.target_type != NODE_NONE {
                    resolved = self.ast.resolution_def(ex.target_type);
                }
                if resolved.node != NODE_NONE {
                    self.current_self = resolved;
                } else {
                    self.current_self = DefId { module: self.ast.module, node: id };
                }
                let saved_generic = self.in_generic;
                self.in_generic = saved_generic || ex.generics.len > 0; // methods inherit the extend's generics
                self.resolve_associated_items(ex.items);
                self.in_generic = saved_generic;
                self.current_self = old_self;
                self.scope_exit();
            },
            NODE_TYPE_ALIAS => {
                self.resolve_type_alias(id);
            },
            NODE_CONST => {
                let cd = self.ast.at_const(id).as_data.const_def;
                self.resolve_type(cd.ty);
                self.resolve_expr(cd.value);
            },
            NODE_EXTERN_BLOCK => {
                let inner = self.ast.at_const(id).as_data.extern_block.items;
                self.resolve_associated_items(inner);
            },
            NODE_STATIC_ASSERT => {
                let left = self.ast.at_const(id).as_data.binary.left;
                self.resolve_expr(left);
            },
            _ => {},
        };
    }

    // -- statements ----------------------------------------------------------------------------------------

    fn resolve_if(self: &mut Self, id: NodeId) void {
        let ifd = self.ast.at_const(id).as_data.if_stmt;
        self.resolve_expr(ifd.condition);
        self.resolve_stmt(ifd.then_branch);
        self.resolve_stmt(ifd.else_branch);
    }

    fn resolve_block(self: &mut Self, id: NodeId) void {
        let stmts = self.ast.at_const(id).as_data.block.statements;
        self.scope_enter();
        for i in 0..stmts.len {
            let cid = self.child(stmts, i);
            self.resolve_stmt(cid);
        }
        self.scope_exit();
    }

    fn resolve_stmt(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        let kind = self.ast.at_const(id).kind;
        switch kind {
            NODE_BLOCK => {
                self.resolve_block(id);
            },
            NODE_LET => {
                let ld = self.ast.at_const(id).as_data.let_stmt;
                self.resolve_type(ld.ty);
                self.resolve_expr(ld.value);
                let nmkind = self.ast.at_const(ld.name).kind;
                if nmkind == NodeKind::NODE_PATTERN_TUPLE {
                    // `let (a, b) = ..`: each element declares itself
                    let children = self.ast.at_const(ld.name).as_data.pattern.children;
                    for i in 0..children.len {
                        let cid = self.child(children, i);
                        self.declare(cid, cid, Namespace::NS_VALUE);
                        self.ast.set_resolution(cid, id); // back-point to the let so mutability is recoverable
                    }
                } else {
                    self.declare(ld.name, id, Namespace::NS_VALUE); // bound only after its initializer
                }
            },
            NODE_CONST => {
                let cd = self.ast.at_const(id).as_data.const_def;
                self.resolve_type(cd.ty);
                self.resolve_expr(cd.value);
                self.declare(cd.name, id, Namespace::NS_VALUE);
            },
            NODE_RETURN => {
                let values = self.ast.at_const(id).as_data.return_stmt.values;
                for i in 0..values.len {
                    let v = self.child(values, i);
                    self.resolve_expr(v);
                }
            },
            NODE_DEFER => {
                let v = self.ast.at_const(id).as_data.single.value;
                self.resolve_expr(v);
            },
            NODE_IF => {
                self.resolve_if(id);
            },
            NODE_WHILE => {
                let wd = self.ast.at_const(id).as_data.while_stmt;
                self.resolve_expr(wd.condition);
                self.resolve_block(wd.body);
            },
            NODE_FOR => {
                let fr = self.ast.at_const(id).as_data.for_stmt;
                self.resolve_expr(fr.iterable); // evaluated before the binding is in scope
                self.scope_enter();
                self.declare(fr.binding, id, Namespace::NS_VALUE);
                self.resolve_block(fr.body);
                self.scope_exit();
            },
            NODE_EXPRESSION_STATEMENT => {
                let v = self.ast.at_const(id).as_data.single.value;
                self.resolve_expr(v);
            },
            NODE_STATIC_ASSERT => {
                let left = self.ast.at_const(id).as_data.binary.left;
                self.resolve_expr(left);
            },
            NODE_BREAK => {
                let v = self.ast.at_const(id).as_data.flow.value;
                self.resolve_expr(v);
            },
            _ => {}, // NODE_CONTINUE and leaves: nothing to resolve
        };
    }

    // -- expressions ---------------------------------------------------------------------------------------

    fn resolve_expr(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        let kind = self.ast.at_const(id).kind;
        switch kind {
            NODE_IDENTIFIER => {
                self.resolve_ref(id, id, Namespace::NS_VALUE, "value"); // also covers 'self'
            },
            NODE_UNARY => {
                let op = self.ast.at_const(id).as_data.unary.operand;
                self.resolve_expr(op);
            },
            NODE_BINARY | NODE_ASSIGNMENT => {
                let bd = self.ast.at_const(id).as_data.binary;
                self.resolve_expr(bd.left);
                self.resolve_expr(bd.right);
            },
            NODE_CALL => {
                let cd = self.ast.at_const(id).as_data.call;
                // `Pair(1, 2)`: a callee identifier that is not a value may name a TYPE (tuple-struct
                // construction). One lookup per namespace; the hit commits directly (no re-lookup).
                let callee_kind = self.ast.at_const(cd.callee).kind;
                if callee_kind == NodeKind::NODE_IDENTIFIER {
                    let cname = self.name_span(cd.callee);
                    let v = self.sym_lookup(cname, Namespace::NS_VALUE);
                    if v.decl != NODE_NONE {
                        self.resolve_ref_hit(cd.callee, v.decl, v.idx, Namespace::NS_VALUE);
                    } else {
                        let t = self.sym_lookup(cname, Namespace::NS_TYPE);
                        if t.decl != NODE_NONE {
                            self.resolve_ref_hit(cd.callee, t.decl, t.idx, Namespace::NS_TYPE);
                        } else {
                            self.resolve_ref_miss(cd.callee, cname, Namespace::NS_VALUE, "value");
                        }
                    }
                } else {
                    self.resolve_expr(cd.callee);
                }
                for i in 0..cd.args.len {
                    let a = self.child(cd.args, i);
                    self.resolve_expr(a);
                }
            },
            NODE_INDEX => {
                let ix = self.ast.at_const(id).as_data.index;
                self.resolve_expr(ix.object);
                self.resolve_expr(ix.index);
            },
            NODE_MEMBER => {
                self.resolve_member(id);
            },
            NODE_CAST => {
                let ct = self.ast.at_const(id).as_data.cast;
                self.resolve_expr(ct.expression);
                self.resolve_type(ct.ty);
            },
            NODE_SIZEOF | NODE_ALIGNOF => {
                self.resolve_sizeof(id);
            },
            NODE_VA_EXPR => {
                let vo = self.ast.at_const(id).as_data.va_op;
                self.resolve_expr(vo.ap);
                if vo.op == VA_ARG {
                    self.resolve_type(vo.extra);
                } else if vo.op == VA_START {
                    self.resolve_expr(vo.extra);
                }
            },
            NODE_GENERIC_SPECIALIZATION => {
                let sp = self.ast.at_const(id).as_data.specialization;
                let inner_kind = self.ast.at_const(sp.expression).kind;
                if inner_kind == NodeKind::NODE_IDENTIFIER {
                    let iname = self.name_span(sp.expression);
                    let v = self.sym_lookup(iname, Namespace::NS_VALUE);
                    if v.decl != NODE_NONE {
                        self.resolve_ref_hit(sp.expression, v.decl, v.idx, Namespace::NS_VALUE);
                    } else {
                        self.resolve_ref(sp.expression, sp.expression, Namespace::NS_TYPE, "type");
                    }
                } else {
                    self.resolve_expr(sp.expression);
                }
                for i in 0..sp.types.len {
                    let t = self.child(sp.types, i);
                    self.resolve_type(t);
                }
            },
            NODE_MATCH => {
                let md = self.ast.at_const(id).as_data.match_expr;
                self.resolve_expr(md.value);
                for i in 0..md.arms.len {
                    let aid = self.child(md.arms, i);
                    let arm = self.ast.at_const(aid).as_data.match_arm;
                    self.scope_enter();
                    self.resolve_pattern(arm.pattern);
                    self.resolve_expr(arm.guard);
                    self.resolve_expr(arm.body);
                    self.scope_exit();
                }
            },
            NODE_NEW => {
                let ne = self.ast.at_const(id).as_data.new_expr;
                if ne.initializer != NODE_NONE {
                    self.resolve_expr(ne.initializer);
                } else {
                    self.resolve_type(ne.ty);
                }
            },
            NODE_WHILE => {
                // `loop { .. }` as an expression
                let body = self.ast.at_const(id).as_data.while_stmt.body;
                self.resolve_block(body);
            },
            NODE_ARRAY_LITERAL | NODE_TUPLE => {
                let elements = self.ast.at_const(id).as_data.array_literal.elements;
                for i in 0..elements.len {
                    let eid = self.child(elements, i);
                    let ek = self.ast.at_const(eid).kind;
                    if ek == NodeKind::NODE_FIELD_INITIALIZER {
                        // designated `[index] = value`
                        let fi = self.ast.at_const(eid).as_data.field_initializer;
                        self.resolve_expr(fi.name);
                        self.resolve_expr(fi.value);
                    } else {
                        self.resolve_expr(eid);
                    }
                }
            },
            NODE_STRUCT_INITIALIZER => {
                let si = self.ast.at_const(id).as_data.struct_initializer;
                self.resolve_type_name(si.ty);
                for i in 0..si.fields.len {
                    let fid = self.child(si.fields, i);
                    let val = self.ast.at_const(fid).as_data.field_initializer.value; // field names deferred
                    self.resolve_expr(val);
                }
            },
            NODE_BLOCK => {
                self.resolve_block(id);
            },
            NODE_CLOSURE => {
                self.resolve_closure(id);
            },
            NODE_IF => {
                self.resolve_if(id);
            },
            NODE_RANGE => {
                let pr = self.ast.at_const(id).as_data.pattern_range;
                self.resolve_expr(pr.start);
                self.resolve_expr(pr.end);
            },
            _ => {}, // NODE_LITERAL and other leaves: nothing to resolve
        };
    }

    fn resolve_member(self: &mut Self, id: NodeId) void {
        let mb = self.ast.at_const(id).as_data.member;
        // A full module-PATH qualifier is resolved against the loaded modules.
        if mb.path && self.resolve_qualified_member(id) {
            return;
        }
        let obj_kind = self.ast.at_const(mb.object).kind;
        if mb.path && obj_kind == NodeKind::NODE_IDENTIFIER {
            let nm = self.name_is_module(self.name_span(mb.object));
            if nm.found {
                let mn = self.name_span(mb.member);
                let pkg = unsafe &*self.package;
                let nmp = unsafe (self.source + mn.start as usize) as *const char;
                let nl = (mn.end - mn.start) as usize;
                let decl = pkg.lookup(nm.mid, str::from_raw(nmp as *const u8, nl), false); // a value (function) export takes priority
                if decl != NODE_NONE {
                    self.ast.set_resolution_def(id, DefId { module: nm.mid, node: decl });
                } else {
                    self.resolve_module_decl(id, nm.mid, mn, true, "item");
                }
            } else {
                self.resolve_ref(mb.object, mb.object, Namespace::NS_TYPE, "type");
            }
        } else {
            self.resolve_expr(mb.object); // member name needs a type; deferred to the type checker
        }
    }

    fn resolve_sizeof(self: &mut Self, id: NodeId) void {
        // `sizeof(T)`/`sizeof(x)`: a LONE identifier prefers the type namespace, then a value binding.
        let v = self.ast.at_const(id).as_data.single.value;
        let vk = self.ast.at_const(v).kind;
        if vk == NodeKind::NODE_TYPE_PATH {
            let tp = self.ast.at_const(v).as_data.type_path;
            if tp.parts.len == 1 && tp.args.len == 0 {
                let first = self.child(tp.parts, 0);
                let name = self.name_span(first);
                if is_builtin_type(self.source, name) || span_is(self.source, name, "Self") {
                    self.resolve_type(v);
                    return;
                }
                let look = self.sym_lookup(name, Namespace::NS_TYPE);
                if look.decl != NODE_NONE {
                    // a scope-stack type: commit it directly (no re-lookup)
                    self.resolve_ref_hit(v, look.decl, look.idx, Namespace::NS_TYPE);
                    return;
                }
                if self.package != null {
                    // a prelude/glob type: commit the hit found while probing
                    let pkg = unsafe &*self.package;
                    let nm = unsafe (self.source + name.start as usize) as *const char;
                    let nl = (name.end - name.start) as usize;
                    let mut hit = pkg.prelude_lookup(str::from_raw(nm as *const u8, nl), true);
                    if hit.node == NODE_NONE {
                        hit = self.glob_lookup(name, true);
                    }
                    if hit.node != NODE_NONE {
                        self.ast.set_resolution_def(v, DefId { module: hit.mid, node: hit.node });
                        return;
                    }
                }
                self.resolve_ref(v, first, Namespace::NS_VALUE, "type or value");
                return;
            }
        }
        self.resolve_type(v);
    }

    fn resolve_closure(self: &mut Self, id: NodeId) void {
        if self.in_generic {
            let sp = self.ast.at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("closures inside generic functions are not yet supported"),
            );
        }
        if self.closures.len() >= 8 {
            let sp = self.ast.at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("closures nested too deeply (max 8)"));
            return;
        }
        let cl = self.ast.at_const(id).as_data.closure;
        self.scope_enter();
        self.closures.push(ClosureScope { node: id, floor: self.symbols.len() as u32, caps: Vector::<NodeId>::new() });
        for i in 0..cl.params.len {
            let pid = self.child(cl.params, i);
            let param = self.ast.at_const(pid).as_data.parameter;
            self.declare(param.name, pid, Namespace::NS_VALUE);
            self.resolve_type(param.ty);
        }
        if cl.expr_body {
            self.resolve_expr(cl.body);
        } else {
            self.resolve_block(cl.body);
        }
        // Commit the collected captures onto the closure node (discovery order, deduped).
        let top = self.closures.len() - 1;
        let ncaps = self.closures[top].caps.len();
        let mark = self.ast.mark();
        for k in 0..ncaps {
            let cap = self.closures[top].caps[k];
            self.ast.push(cap);
        }
        let list = self.ast.commit(mark);
        self.ast.at(id).as_data.closure.captures = list;
        self.closures.truncate(top); // frees the popped ClosureScope's caps (Vector::truncate drops removed elems)
        self.scope_exit();
    }

    // -- patterns ------------------------------------------------------------------------------------------

    fn resolve_pattern(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        let kind = self.ast.at_const(id).kind;
        switch kind {
            NODE_IDENTIFIER => {
                // shorthand struct-pattern field binding
                self.declare(id, id, Namespace::NS_VALUE);
            },
            NODE_PATTERN_NAME => {
                let pd = self.ast.at_const(id).as_data.pattern;
                self.declare(pd.name, id, Namespace::NS_VALUE);
                for i in 0..pd.children.len {
                    let s = self.child(pd.children, i);
                    self.resolve_pattern(s);
                }
            },
            NODE_PATTERN_TUPLE | NODE_PATTERN_STRUCT | NODE_PATTERN_FIELD => {
                let children = self.ast.at_const(id).as_data.pattern.children;
                for i in 0..children.len {
                    let c = self.child(children, i);
                    self.resolve_pattern(c);
                }
            },
            NODE_PATTERN_OR => {
                // alternatives bind the same names; declare the first's
                let children = self.ast.at_const(id).as_data.pattern.children;
                if children.len != 0 {
                    let c0 = self.child(children, 0);
                    self.resolve_pattern(c0);
                }
            },
            _ => {}, // NODE_PATTERN_WILDCARD, NODE_PATTERN_LITERAL, NODE_PATTERN_RANGE: nothing to bind
        };
    }

    // -- driver --------------------------------------------------------------------------------------------

    // Top-level items are visible regardless of order, so declare them all before resolving bodies.
    fn collect_items(self: &mut Self, items: NodeList) void {
        for i in 0..items.len {
            let id = self.child(items, i);
            switch self.ast.at_const(id).kind {
                NODE_FUNCTION => {
                    let nm = self.ast.at_const(id).as_data.function.name;
                    self.declare(nm, id, Namespace::NS_VALUE);
                },
                NODE_CONST => {
                    let nm = self.ast.at_const(id).as_data.const_def.name;
                    self.declare(nm, id, Namespace::NS_VALUE);
                },
                NODE_STRUCT | NODE_ENUM => {
                    let nm = self.ast.at_const(id).as_data.aggregate.name;
                    self.declare(nm, id, Namespace::NS_TYPE);
                },
                NODE_INTERFACE => {
                    let nm = self.ast.at_const(id).as_data.interface_def.name;
                    self.declare(nm, id, Namespace::NS_TYPE);
                },
                NODE_TYPE_ALIAS => {
                    let nm = self.ast.at_const(id).as_data.type_alias.name;
                    self.declare(nm, id, Namespace::NS_TYPE);
                },
                NODE_EXTERN_BLOCK => {
                    let inner = self.ast.at_const(id).as_data.extern_block.items;
                    for j in 0..inner.len {
                        let iid = self.child(inner, j);
                        switch self.ast.at_const(iid).kind {
                            NODE_FUNCTION => {
                                let nm = self.ast.at_const(iid).as_data.function.name;
                                self.declare(nm, iid, Namespace::NS_VALUE);
                            },
                            NODE_TYPE_ALIAS => {
                                let nm = self.ast.at_const(iid).as_data.type_alias.name;
                                self.declare(nm, iid, Namespace::NS_TYPE);
                            },
                            NODE_CONST => {
                                let nm = self.ast.at_const(iid).as_data.const_def.name;
                                self.declare(nm, iid, Namespace::NS_VALUE);
                            },
                            _ => {},
                        };
                    }
                },
                _ => {}, // NODE_EXTEND has no module-scope name
            };
        }
    }

    fn package_file(self: &Self) str {
        if self.package == null {
            return "";
        }
        let pkg = unsafe &*self.package;
        let m = self.ast.module;
        if m as usize < pkg.modules.len() {
            return pkg.modules[m as usize].file.as_str();
        }
        return "";
    }

    pub fn resolve(self: &mut Self) void {
        let items = self.ast.at_const(self.ast.root).as_data.program.items;
        self.ast.init_resolutions();
        self.scan_imports();
        self.scope_enter();
        self.collect_items(items);
        for i in 0..items.len {
            let cid = self.child(items, i);
            self.resolve_item(cid);
        }
        self.scope_exit();
        let fstr = self.package_file();
        self.errors.finalize(self.source, self.len, fstr);
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) void {
        self.errors.log();
    }
}

extend Resolver as Free {
    pub fn free(self: &mut Self) void {
        self.ast.free();
        self.symbols.free();
        self.symbol_previous.free();
        self.scope_starts.free();
        self.symbol_index.free();
        self.closures.free();
        self.mod_names.free();
        self.glob_mids.free();
        self.errors.free();
    }
}
