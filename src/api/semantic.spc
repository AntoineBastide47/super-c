// Semantic queries over a checked session: what a position names, where it is declared and used, the symbols
// of a file or of the whole analysis, types with their target layout, calls, interface relations, and rename.
// Each reads the analysis the session holds, through the language server's own queries: none resolves a name
// or checks a type again. A position is a file path and a byte offset in the text the session analyzed.
import api::session as ses;
import api::errors as *;
import api::syntax as syn;
import lsp::features as feat;
import lsp::analysis as an;
import module::loader as loader;
import ast::ast as *;
import typechecker::render as rnd;
import ir::layout as lay;

/// A byte range of a file.
pub struct Location {
    pub file: String,
    pub start: u32,
    pub end: u32,
}

/// What a symbol declares.
@derive(Eq, Format)
pub enum SymbolKind {
    Function,
    Method, // a function of an `extend` or an interface
    Struct,
    Union,
    Enum,
    Variant,
    Field,
    Interface,
    TypeAlias,
    Const,
    Static, // a `static mut`
    Param,
    Local,
    GenericParam,
    Module, // an import
    Extend, // an `extend` block (an outline entry)
    Other,
}

/// The identity of a declaration that survives edits: its module path, its owner (for a method or an
/// associated constant, the `extend` it is in, spelled as written: `Vector<T, A>` or `String as Writer`; for
/// a field or a variant, its type's name; else empty), its kind, its name, and its position among the
/// declarations of the module with the same owner, kind and name (0 for the first). Locals and parameters
/// have none.
pub struct SymbolKey {
    pub module: String,
    pub owner: String,
    pub kind: SymbolKind,
    pub name: String,
    pub ordinal: u32,
}

/// A declaration of a checked session.
pub struct Symbol<'s> {
    pub(file) s: &'s ses::Session,
    pub(file) d: DefId,
}

extend<'s> Symbol<'s> as Copy {}

// The module index of file `file` in the session's analysis.
fn module_index(s: &ses::Session, file: str) Result<usize, ApiError> {
    if !s.checked() {
        return Result::<usize, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    return switch s.module_of(file) {
        Some(m) => Result::<usize, ApiError>::Ok(m.index() as usize),
        None => Result::<usize, ApiError>::Err(
            ApiError::at(Code::InvalidArgument, "the file is not part of the analysis", file, 0, 0),
        ),
    };
}

fn ast_of(p: &loader::Package, m: u32) &Ast {
    return &p.modules[m as usize].ast;
}

// The text of name node `nm` of module `m`.
fn name_text(p: &loader::Package, m: u32, nm: NodeId) str {
    let sp = ast_of(p, m).at_const(nm).span;
    return p.modules[m as usize].source.as_str().slice(sp.start as usize, sp.end as usize);
}

fn loc_of(p: &loader::Package, l: &feat::Loc) Location {
    return Location { file: p.modules[l.module as usize].file.clone(), start: l.start, end: l.end };
}

fn locs_of(p: &loader::Package, ls: &Vector<feat::Loc>) Vector<Location> {
    let mut out = Vector::<Location>::with_capacity(ls.len());
    for i in 0..ls.len() {
        out.push(loc_of(p, &ls[i]));
    }
    return out;
}

extend<'s> Symbol<'s> {
    fn p(self: &Self) &'s loader::Package {
        return self.s.package();
    }

    fn node(self: &Self) &'s ast::Node {
        return ast_of(self.p(), self.d.module).at_const(self.d.node);
    }

    // The payload the declaration's node keeps outside itself (`ast::Ast::ext`).
    fn node_ext(self: &Self) &'s ast::NodeExt {
        return ast_of(self.p(), self.d.module).ext(self.d.node);
    }

    /// Its name; empty for a declaration without one.
    pub fn name(self: &Self) str<'s> {
        let nm = feat::decl_name(ast_of(self.p(), self.d.module), self.d.node);
        if nm == NODE_NONE {
            return "";
        }
        return name_text(self.p(), self.d.module, nm);
    }

    /// What it declares.
    pub fn kind(self: &Self) SymbolKind {
        let p = self.p();
        let n = self.node();
        let it = p.item_of(self.d.module, self.d.node);
        // A function the item index does not hold is an interface member.
        let method = it == loader::ITEM_NONE || p.idx().items[it as usize].kind == loader::ItemKind::IK_METHOD as u8;
        return switch n.kind {
            NODE_FUNCTION => if method {
                SymbolKind::Method;
            } else {
                SymbolKind::Function;
            },
            NODE_STRUCT => if self.node_ext().aggregate.is_union {
                SymbolKind::Union;
            } else {
                SymbolKind::Struct;
            },
            NODE_ENUM => SymbolKind::Enum,
            NODE_VARIANT => SymbolKind::Variant,
            NODE_FIELD => SymbolKind::Field,
            NODE_INTERFACE => SymbolKind::Interface,
            NODE_TYPE_ALIAS => SymbolKind::TypeAlias,
            NODE_CONST => if n.as_data.const_def.is_static_mut {
                SymbolKind::Static;
            } else {
                SymbolKind::Const;
            },
            NODE_PARAMETER => SymbolKind::Param,
            NODE_GENERIC_PARAM => SymbolKind::GenericParam,
            NODE_IMPORT => SymbolKind::Module,
            NODE_LET | NODE_PATTERN_NAME | NODE_IDENTIFIER => SymbolKind::Local,
            _ => SymbolKind::Other,
        };
    }

    /// The path of the module that declares it.
    pub fn module_path(self: &Self) str<'s> {
        return self.p().modules[self.d.module as usize].path.as_str();
    }

    /// Where it is declared: its name, else the whole declaration. None for a declaration of a generated
    /// module (the build constants).
    pub fn location(self: &Self) Option<Location> {
        let p = self.p();
        if p.modules[self.d.module as usize].file.len() == 0 {
            return Option::<Location>::None;
        }
        let a = ast_of(p, self.d.module);
        let nm = feat::decl_name(a, self.d.node);
        let sp = a.at_const(
            if nm != NODE_NONE {
                nm;
            } else {
                self.d.node;
            },
        ).span;
        return Option::<Location>::Some(
            Location { file: p.modules[self.d.module as usize].file.clone(), start: sp.start, end: sp.end },
        );
    }

    /// Its declaration's head as written: a function up to its body, a type up to its generic parameters.
    pub fn signature(self: &Self) String {
        return feat::decl_signature(self.p(), self.d);
    }

    /// The comment block written directly above it, comment markers removed.
    pub fn doc(self: &Self) String {
        return feat::decl_doc(self.p(), self.d);
    }

    /// Its stable identity; None for a local, a parameter or a generic parameter.
    pub fn key(self: &Self) Option<SymbolKey> {
        let k = self.kind();
        if k == SymbolKind::Local || k == SymbolKind::Param || k == SymbolKind::GenericParam || k == SymbolKind::Module || k == SymbolKind::Extend || k == SymbolKind::Other {
            return Option::<SymbolKey>::None;
        }
        let p = self.p();
        let owner = owner_text(p, self.d);
        let name = String::from_str(self.name());
        let mut ordinal: u32 = 0;
        let it = p.item_of(self.d.module, self.d.node);
        if it != loader::ITEM_NONE {
            let lo = p.idx().mod_items[self.d.module as usize];
            for j in lo..it {
                let o = Symbol { s: self.s, d: DefId { module: self.d.module, node: p.idx().items[j as usize].node } };
                if o.kind() == k && o.name() == name.as_str() && owner_text(p, o.d).as_str() == owner.as_str() {
                    ordinal += 1;
                }
            }
        }
        return Option::<SymbolKey>::Some(
            SymbolKey {
                module: String::from_str(self.module_path()),
                owner: owner,
                kind: k,
                name: name,
                ordinal: ordinal,
            },
        );
    }
}

// The owner part of the key of `d`: the `extend` of a method or an associated constant, as written, or the
// type of a field or a variant.
fn owner_text(p: &loader::Package, d: DefId) String {
    let it = p.item_of(d.module, d.node);
    let a = ast_of(p, d.module);
    let src = p.modules[d.module as usize].source.as_str();
    if it != loader::ITEM_NONE {
        let ow = p.idx().items[it as usize].owner;
        if ow == loader::ITEM_NONE {
            return String::new();
        }
        let e = a.at_const(p.idx().items[ow as usize].node);
        if e.kind != NodeKind::NODE_EXTEND {
            return String::new();
        }
        let ts = a.at_const(a.ext(p.idx().items[ow as usize].node).extend_def.target_type).span;
        let mut out = String::from_str(src.slice(ts.start as usize, ts.end as usize));
        if a.ext(p.idx().items[ow as usize].node).extend_def.interface_type != NODE_NONE {
            let is = a.at_const(a.ext(p.idx().items[ow as usize].node).extend_def.interface_type).span;
            out.push_str(" as ");
            out.push_str(src.slice(is.start as usize, is.end as usize));
        }
        return out;
    }
    let k = a.at_const(d.node).kind;
    if k != NodeKind::NODE_FIELD && k != NodeKind::NODE_VARIANT {
        return String::new();
    }
    // The aggregate whose members hold it.
    let lo = p.idx().mod_items[d.module as usize];
    let hi = p.idx().mod_items[d.module as usize + 1];
    for j in lo..hi {
        let n = a.at_const(p.idx().items[j as usize].node);
        if n.kind != NodeKind::NODE_STRUCT && n.kind != NodeKind::NODE_ENUM {
            continue;
        }
        let ms = a.ext(p.idx().items[j as usize].node).aggregate.members;
        for i in 0..ms.len {
            if unsafe a.list(ms)[i as usize] == d.node {
                return String::from_str(name_text(p, d.module, a.ext_name(p.idx().items[j as usize].node)));
            }
        }
    }
    return String::new();
}

/// The key of declaration `d` of the session's analysis (`Symbol::key`). Not part of the API.
pub(package) fn key_of(s: &ses::Session, d: DefId) Option<SymbolKey> {
    return Symbol { s: s, d: d }.key();
}

/// The declaration `key` names in the session's analysis, or None.
pub fn resolve<'s>(s: &'s ses::Session, key: &SymbolKey) Option<Symbol<'s>> {
    if !s.checked() {
        return Option::<Symbol>::None;
    }
    let p = s.package();
    let m = p.find(key.module.as_str());
    if m < 0 {
        return Option::<Symbol>::None;
    }
    let lo = p.idx().mod_items[m as usize];
    let hi = p.idx().mod_items[m as usize + 1];
    let a = ast_of(p, m as u32);
    for j in lo..hi {
        let node = p.idx().items[j as usize].node;
        let sy = Symbol { s: s, d: DefId { module: m as ModuleId, node: node } };
        if key.kind == SymbolKind::Field || key.kind == SymbolKind::Variant {
            // A member: its type by name, then the member by name.
            let n = a.at_const(node);
            if (n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM) && sy.name() == key.owner.as_str() {
                let ms = a.ext(node).aggregate.members;
                for i in 0..ms.len {
                    let md = Symbol { s: s, d: DefId { module: m as ModuleId, node: unsafe a.list(ms)[i as usize] } };
                    if md.kind() == key.kind && md.name() == key.name.as_str() {
                        return Option::<Symbol>::Some(md);
                    }
                }
            }
            continue;
        }
        if sy.kind() != key.kind || sy.name() != key.name.as_str() {
            continue;
        }
        let k = sy.key();
        if k.is_some() {
            let kk = k.unwrap();
            if kk.owner.as_str() == key.owner.as_str() && kk.ordinal == key.ordinal {
                return Option::<Symbol>::Some(sy);
            }
        }
    }
    return Option::<Symbol>::None;
}

/// The declaration the name at `off` of `file` refers to, or the declaration whose name is there (an
/// operator names the method the checker chose for it). None when nothing resolves there.
pub fn symbol_at<'s>(s: &'s ses::Session, file: str, off: u32) Result<Option<Symbol<'s>>, ApiError> {
    let m = module_index(s, file)?;
    let d = feat::target_at(s.package(), m, off);
    if d.node == NODE_NONE {
        return Result::<Option<Symbol>, ApiError>::Ok(Option::<Symbol>::None);
    }
    return Result::<Option<Symbol>, ApiError>::Ok(Option::<Symbol>::Some(Symbol { s: s, d: d }));
}

/// A type of a checked session.
pub struct TypeView<'s> {
    pub(file) s: &'s ses::Session,
    pub(file) m: u32,
    pub(file) t: TypeId,
}

extend<'s> TypeView<'s> {
    /// The type as the compiler spells it in a diagnostic (`Vector<i32>`, `&mut String`).
    pub fn display(self: &Self) String {
        let p = self.s.package();
        let mut out = String::new();
        rnd::render_type_str(p, ast_of(p, self.m), p.modules[self.m as usize].source.as_str(), self.t, &mut out);
        return out;
    }

    /// Its size and alignment in bytes on the session's target; None for a type without a layout (an
    /// unbound generic parameter, `void`).
    pub fn layout(self: &Self) Option<(u64, u64)> {
        let mut svc = lay::Svc::new(self.s.package());
        let l = svc.layout(self.m as ModuleId, self.t);
        if !l.ok {
            return Option::<(u64, u64)>::None;
        }
        return Option::<(u64, u64)>::Some((l.size, l.align));
    }
}

/// The type of the expression at `off` of `file`, or of the binding, parameter or field whose name is there;
/// None where the analysis has none.
pub fn type_at<'s>(s: &'s ses::Session, file: str, off: u32) Result<Option<TypeView<'s>>, ApiError> {
    let m = module_index(s, file)?;
    let p = s.package();
    let a = ast_of(p, m as u32);
    let mut id = feat::node_at(a, off);
    if id == NODE_NONE && off > 0 {
        id = feat::node_at(a, off - 1);
    }
    let mut t = TYPE_NONE;
    if id != NODE_NONE && a.valid(id) {
        t = a.type_of(id);
    }
    if t == TYPE_NONE {
        // A declaration's name: the type it is written with, else its initializer's.
        let d = feat::def_at(p, m, off);
        if d.node != NODE_NONE && d.module as usize == m {
            let n = a.at_const(d.node);
            let (ty, value) = switch n.kind {
                NODE_LET => (n.as_data.let_stmt.ty, n.as_data.let_stmt.value),
                NODE_PARAMETER => (n.as_data.parameter.ty, NODE_NONE),
                NODE_FIELD => (n.as_data.field.ty, NODE_NONE),
                NODE_CONST => (n.as_data.const_def.ty, n.as_data.const_def.value),
                _ => (NODE_NONE, NODE_NONE),
            };
            for k in [ty, value] {
                if t == TYPE_NONE && k != NODE_NONE && a.valid(k) {
                    t = a.type_of(k);
                }
            }
        }
    }
    if t == TYPE_NONE {
        return Result::<Option<TypeView>, ApiError>::Ok(Option::<TypeView>::None);
    }
    return Result::<Option<TypeView>, ApiError>::Ok(Option::<TypeView>::Some(TypeView { s: s, m: m as u32, t: t }));
}

/// The type of the expression whose range in `file` is exactly `[start, end)` (a syntax node's range); None
/// where the analysis has none.
pub fn type_of_range<'s>(s: &'s ses::Session, file: str, start: u32, end: u32) Result<Option<TypeView<'s>>, ApiError> {
    let m = module_index(s, file)?;
    let a = ast_of(s.package(), m as u32);
    let n = a.nnodes();
    for i0 in 1..n {
        let i = a.nth_id(i0);
        let sp = a.at_const(i).span;
        if sp.start == start && sp.end == end && a.valid(i) && a.type_of(i) != TYPE_NONE {
            return Result::<Option<TypeView>, ApiError>::Ok(
                Option::<TypeView>::Some(TypeView { s: s, m: m as u32, t: a.type_of(i) }),
            );
        }
    }
    return Result::<Option<TypeView>, ApiError>::Ok(Option::<TypeView>::None);
}

/// The text an editor shows for `off` of `file` (Markdown: the type, the declaration's head, its
/// documentation); None where there is none.
pub fn hover(s: &ses::Session, file: str, off: u32) Result<Option<String>, ApiError> {
    let m = module_index(s, file)?;
    return Result::<Option<String>, ApiError>::Ok(feat::hover(s.package(), m, off));
}

/// Every reference to the declaration at `off` of `file`, by file then position; `include_decl` adds the
/// declaration's own name. Empty where nothing resolves. Parses back the bodies the search reads. `Limit`
/// past `opts.result_limit` bytes of results.
pub fn references_at(s: &mut ses::Session, file: str, off: u32, include_decl: bool, opts: &ses::RequestOptions) Result<
    Vector<Location>,
    ApiError
> {
    let m = module_index(s, file)?;
    let d = feat::def_at(s.package(), m, off);
    return refs_of(s, d, include_decl, opts);
}

/// `references_at` for the declaration `key` names; `InvalidArgument` when it names none.
pub fn references_to(s: &mut ses::Session, key: &SymbolKey, include_decl: bool, opts: &ses::RequestOptions) Result<
    Vector<Location>,
    ApiError
> {
    let mut d = DefId { module: 0, node: NODE_NONE };
    if let Some(y) = resolve(s, key) {
        d = y.d;
    }
    if d.node == NODE_NONE {
        return Result::<Vector<Location>, ApiError>::Err(
            ApiError::new(Code::InvalidArgument, "the key names no declaration of the analysis"),
        );
    }
    return refs_of(s, d, include_decl, opts);
}

fn refs_of(s: &mut ses::Session, d: DefId, include_decl: bool, opts: &ses::RequestOptions) Result<
    Vector<Location>,
    ApiError
> {
    if !s.checked() {
        return Result::<Vector<Location>, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    if d.node == NODE_NONE {
        return Result::<Vector<Location>, ApiError>::Ok(Vector::<Location>::new());
    }
    an::hydrate_refs(s.package_mut(), d);
    let ls = feat::references_of_def(s.package(), d, include_decl);
    let mut out = locs_of(s.package(), &ls);
    out.sort_by(|x: &Location, y: &Location| loc_cmp(x, y));
    let mut bytes: usize = 0;
    for i in 0..out.len() {
        bytes += sizeof(Location) + out[i].file.len();
    }
    if opts.result_limit != 0 && bytes > opts.result_limit {
        return Result::<Vector<Location>, ApiError>::Err(
            ApiError::new(Code::Limit, "the references pass the request's result limit"),
        );
    }
    return Result::<Vector<Location>, ApiError>::Ok(out);
}

fn loc_cmp(x: &Location, y: &Location) i32 {
    let c = x.file.cmp(&y.file);
    if c != 0 {
        return c;
    }
    if x.start != y.start {
        return x.start.cmp(&y.start);
    }
    return x.end.cmp(&y.end);
}

/// One declaration of a file, as an outline: its name, kind, whole range, name range, and the index of
/// the entry it is nested in (-1 at the top).
pub struct OutlineEntry {
    pub name: String,
    pub kind: SymbolKind,
    pub detail: String,
    pub range: syn::TextRange,
    pub name_range: syn::TextRange,
    pub parent: i32,
}

// The symbol kind of an LSP SymbolKind number.
fn lsp_kind(k: i32) SymbolKind {
    return switch k {
        2 => SymbolKind::Module,
        3 => SymbolKind::Extend,
        5 => SymbolKind::TypeAlias,
        6 => SymbolKind::Method,
        8 => SymbolKind::Field,
        10 => SymbolKind::Enum,
        11 => SymbolKind::Interface,
        12 => SymbolKind::Function,
        13 => SymbolKind::Local,
        14 => SymbolKind::Const,
        22 => SymbolKind::Variant,
        23 => SymbolKind::Struct,
        26 => SymbolKind::GenericParam,
        _ => SymbolKind::Other,
    };
}

/// The declarations of `file`, in text order, nested as written.
pub fn outline(s: &ses::Session, file: str) Result<Vector<OutlineEntry>, ApiError> {
    let m = module_index(s, file)?;
    let syms = feat::document_symbols(s.package(), m, true);
    let mut out = Vector::<OutlineEntry>::with_capacity(syms.len());
    for i in 0..syms.len() {
        let y = &syms[i];
        out.push(
            OutlineEntry {
                name: y.name.clone(),
                kind: lsp_kind(y.kind),
                detail: y.detail.clone(),
                range: syn::TextRange { start: y.start, end: y.end },
                name_range: syn::TextRange { start: y.sel_start, end: y.sel_end },
                parent: y.parent,
            },
        );
    }
    return Result::<Vector<OutlineEntry>, ApiError>::Ok(out);
}

/// The declarations of every analyzed module outside std whose name holds the letters of `query` in order
/// (empty: all), at most `limit`.
pub fn find_symbols(s: &ses::Session, query: str, limit: usize) Result<Vector<Location>, ApiError> {
    if !s.checked() {
        return Result::<Vector<Location>, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    let p = s.package();
    let mut searched = Vector::<bool>::with_capacity(p.modules.len());
    for i in 0..p.modules.len() {
        searched.push(!p.modules[i].prelude && p.modules[i].pkg != loader::PKG_STD && p.modules[i].file.len() != 0);
    }
    let mut hits = Vector::<feat::WsSym>::new();
    feat::workspace_symbols(p, query, limit, &searched, &mut hits);
    let mut out = Vector::<Location>::with_capacity(hits.len());
    for i in 0..hits.len() {
        out.push(
            Location { file: p.modules[hits[i].module as usize].file.clone(), start: hits[i].start, end: hits[i].end },
        );
    }
    return Result::<Vector<Location>, ApiError>::Ok(out);
}

/// The implementations of the interface, interface method or type at `off` of `file`: the conformances of an
/// interface, the methods that implement an interface method.
pub fn implementations(s: &ses::Session, file: str, off: u32) Result<Vector<Location>, ApiError> {
    let m = module_index(s, file)?;
    let ls = feat::implementations(s.package(), m, off);
    return Result::<Vector<Location>, ApiError>::Ok(locs_of(s.package(), &ls));
}

/// The interfaces `sym` (a type) conforms to with `up`, or the types that conform to `sym` (an interface)
/// without it.
pub fn relations(sym: Symbol, up: bool) Vector<Location> {
    let ls = feat::extend_relations(sym.p(), sym.d, up);
    return locs_of(sym.p(), &ls);
}

/// A call inside a function body: the function it calls and the call's range.
pub struct Call<'s> {
    pub callee: Symbol<'s>,
    pub range: syn::TextRange,
}

/// The calls the function around `off` of `file` makes, in text order; empty outside a function body.
pub fn calls_from<'s>(s: &'s ses::Session, file: str, off: u32) Result<Vector<Call<'s>>, ApiError> {
    let m = module_index(s, file)?;
    let p = s.package();
    let mut out = Vector::<Call>::new();
    let f = feat::enclosing_function(p, m, off);
    if f == NODE_NONE {
        return Result::<Vector<Call>, ApiError>::Ok(out);
    }
    let cs = feat::calls_in(p, m, f);
    for i in 0..cs.len() {
        out.push(
            Call {
                callee: Symbol { s: s, d: cs[i].callee },
                range: syn::TextRange { start: cs[i].start, end: cs[i].end },
            },
        );
    }
    return Result::<Vector<Call>, ApiError>::Ok(out);
}

/// The names visible at `off` of `file`: locals, parameters, items of the module and of its imports, and the
/// prelude's.
pub fn visible_names(s: &ses::Session, file: str, off: u32) Result<Vector<String>, ApiError> {
    let m = module_index(s, file)?;
    let items = feat::complete_general(s.package(), m, off);
    let mut out = Vector::<String>::with_capacity(items.len());
    for i in 0..items.len() {
        out.push(items[i].label.clone());
    }
    return Result::<Vector<String>, ApiError>::Ok(out);
}

/// The edit that renames the declaration at `off` of `file`, its interface relations (an interface method
/// and every method that implements it) and every reference to them, to `new_name`. `InvalidArgument` for
/// a name that is not an identifier or a declaration outside the project (std); `SemanticFailed` with the
/// reason when the new name would clash.
pub fn rename(s: &mut ses::Session, file: str, off: u32, new_name: str) Result<syn::WorkspaceEdit, ApiError> {
    let m = module_index(s, file)?;
    if !feat::valid_ident(new_name) {
        return Result::<syn::WorkspaceEdit, ApiError>::Err(
            ApiError::new(Code::InvalidArgument, "the new name is not an identifier"),
        );
    }
    let d = feat::def_at(s.package(), m, off);
    if d.node == NODE_NONE {
        return Result::<syn::WorkspaceEdit, ApiError>::Err(
            ApiError::at(Code::InvalidArgument, "nothing to rename here", file, off, off),
        );
    }
    let mut related = Vector::<DefId>::new();
    feat::related_decls(s.package(), d, &mut related);
    for i in 0..related.len() {
        let rm = &s.package().modules[related[i].module as usize];
        if rm.pkg == loader::PKG_STD || rm.pkg == loader::PKG_FFI || rm.file.len() == 0 {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(
                ApiError::new(Code::InvalidArgument, "a declaration to rename is outside the project"),
            );
        }
        let c = feat::rename_conflict(s.package(), related[i], new_name);
        if c.len() != 0 {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(ApiError::new(Code::SemanticFailed, c.as_str()));
        }
    }
    let mut sites = Vector::<Location>::new();
    for i in 0..related.len() {
        an::hydrate_refs(s.package_mut(), related[i]);
        let ls = feat::references_of_def(s.package(), related[i], true);
        for k in 0..ls.len() {
            sites.push(loc_of(s.package(), &ls[k]));
        }
    }
    sites.sort_by(|x: &Location, y: &Location| loc_cmp(x, y));
    let mut we = syn::WorkspaceEdit::new();
    for i in 0..sites.len() {
        if i > 0 && loc_cmp(&sites[i - 1], &sites[i]) == 0 {
            continue;
        }
        we.replace(sites[i].file.as_str(), sites[i].start, sites[i].end, new_name);
        if i == 0 || sites[i - 1].file.as_str() != sites[i].file.as_str() {
            we.expect(sites[i].file.as_str(), s.version(sites[i].file.as_str()));
        }
    }
    return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
}
