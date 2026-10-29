// Refactorings and structural matching. A refactoring computes a workspace edit from a session's syntax and
// semantics at a selection; `prepare` checks it before it is offered: the edited files must parse, and with
// semantic validation a scratch session with the edits must report no more errors than the session does. A
// refactoring never changes the session: applying the offer is the client's step (`WorkspaceEdit::apply`).
// Matching walks a syntax tree with ordinary predicates; the semantic predicates read the session's analysis.
import api::errors as *;
import api::session as ses;
import api::syntax as syn;
import api::semantic as sem;
import api::source as *;
import lsp::features as feat;
import lsp::analysis as an;
import module::loader as loader;
import driver::emit as emit;
import ast::ast as *;

/// A range of a file the user selected; an empty range is a cursor.
pub struct Selection {
    pub file: String,
    pub start: u32,
    pub end: u32,
}

/// How far `prepare` checks an edit: the edited files parse, or also no error is added.
@derive(Eq)
pub enum Validation {
    Syntax,
    Semantic,
}

/// A refactoring action.
pub interface Refactoring {
    /// Its stable name: `organize-imports`.
    fn id(self: &Self) str;

    /// Whether it applies at `sel`.
    fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool;

    /// Its edit at `sel` with the parameters `params` (each action documents their form).
    fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, params: str) Result<syn::WorkspaceEdit, ApiError>;
}

/// A checked edit: the edit and the text it gives each file it changes. Preview and apply use the same edit.
pub struct Offer {
    pub edit: syn::WorkspaceEdit,
    pub files: Vector<syn::EditedFile>,
}

/// Compute `r`'s edit at `sel` and check it at level `v`: the session must be checked; the edit is checked
/// as `WorkspaceEdit::preview` checks one; with `Validation::Semantic` a scratch session with the edited texts
/// must report no more errors than the session (`VerificationFailed` otherwise). The session does not change.
pub fn prepare<R: Refactoring>(r: &mut R, s: &mut ses::Session, selection: Selection, params: str, v: Validation) Result<
    Offer,
    ApiError
> {
    let sel = &selection;
    if !s.checked() {
        return Result::<Offer, ApiError>::Err(
            ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
        );
    }
    if !r.applies(s, sel) {
        return Result::<Offer, ApiError>::Err(
            ApiError::at(
                Code::InvalidArgument,
                "the refactoring does not apply here",
                sel.file.as_str(),
                sel.start,
                sel.end,
            ),
        );
    }
    let e = r.edit(s, sel, params)?;
    let files = e.preview(s)?;
    if v == Validation::Semantic {
        let mut before: usize = 0;
        for d in s.diagnostics()? {
            if d.severity() == ses::SEV_ERROR {
                before += 1;
            }
        }
        let mut paths = Vector::<String>::with_capacity(files.len());
        let mut texts = Vector::<String>::with_capacity(files.len());
        for i in 0..files.len() {
            paths.push(files[i].file.clone());
            texts.push(files[i].text.clone());
        }
        let after = s.errors_with(paths.as_slice(), texts.as_slice())?;
        if after > before {
            return Result::<Offer, ApiError>::Err(ApiError::new(Code::VerificationFailed, "the edit adds errors"));
        }
    }
    return Result::<Offer, ApiError>::Ok(Offer { edit: e, files: files });
}

// The module index of `file`; `InvalidArgument` when the analysis has none.
fn module_of(s: &ses::Session, file: str) Result<usize, ApiError> {
    return switch s.module_of(file) {
        Some(m) => Result::<usize, ApiError>::Ok(m.index() as usize),
        None => Result::<usize, ApiError>::Err(
            ApiError::at(Code::InvalidArgument, "the file is not part of the analysis", file, 0, 0),
        ),
    };
}

fn src_of(s: &ses::Session, m: usize) str {
    return s.package().modules[m].source.as_str();
}

// The start of the line holding byte `at`.
fn line_start(src: str, at: u32) u32 {
    let mut i = at as usize;
    while i > 0 && src.byte_at(i - 1) != b'\n' {
        i -= 1;
    }
    return i as u32;
}

// One past the end of the line holding byte `at`, its line feed included.
fn line_end(src: str, at: u32) u32 {
    let mut i = at as usize;
    while i < src.len() && src.byte_at(i) != b'\n' {
        i += 1;
    }
    if i < src.len() {
        i += 1;
    }
    return i as u32;
}

// --- Organize imports ---------------------------------------------------------------------------------

/// `organize-imports`: in the selected file, remove the imports it uses nothing of and, when its imports
/// form one block (only blank lines between them), sort the block by path. No parameters.
pub struct OrganizeImports {}

extend OrganizeImports as Refactoring {
    pub fn id(self: &Self) str {
        return "organize-imports";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        return s.module_of(sel.file.as_str()).is_some();
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, _params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let m = module_of(s, sel.file.as_str())?;
        let mut unused = Vector::<NodeId>::new();
        emit::unused_imports(s.package_mut(), m, &mut unused);
        let p = s.package();
        let a = &p.modules[m].ast;
        let src = src_of(s, m);
        let mut kept = Vector::<String>::new();
        let mut spans = Vector::<(u32, u32)>::new(); // every import's whole lines
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_IMPORT {
                continue;
            }
            let sp = a.at_const(iid).span;
            spans.push((line_start(src, sp.start), line_end(src, sp.end)));
            if !unused.contains(&iid) {
                kept.push(String::from_str(src.slice(sp.start as usize, sp.end as usize)));
            }
        }
        let mut we = syn::WorkspaceEdit::new();
        we.expect(sel.file.as_str(), s.version(sel.file.as_str()));
        if spans.len() == 0 {
            return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
        }
        // One block: only whitespace between consecutive imports.
        let mut block = true;
        for k in 1..spans.len() {
            block = block && src.slice(spans[k - 1].1 as usize, spans[k].0 as usize).trim().len() == 0;
        }
        if block {
            kept.sort();
            let mut text = String::new();
            for k in 0..kept.len() {
                text.push_str(kept[k].as_str());
                text.push_byte(b'\n');
            }
            we.replace(sel.file.as_str(), spans[0].0, spans[spans.len() - 1].1, text.as_str());
        } else {
            for k in 0..spans.len() {
                let line = src.slice(spans[k].0 as usize, spans[k].1 as usize);
                let mut drop = true;
                for j in 0..kept.len() {
                    drop = drop && line.trim() != kept[j].as_str();
                }
                if drop {
                    we.replace(sel.file.as_str(), spans[k].0, spans[k].1, "");
                }
            }
        }
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Add import ---------------------------------------------------------------------------------------

/// `add-import`: import the module that declares the name at the selection, which resolves to nothing.
/// `params`: the module path to import, or empty for the first module that declares the name publicly.
pub struct AddImport {}

// The identifier text at `off` of module `m`, empty when none.
fn word_at(src: str, off: u32) str {
    let mut a = off as usize;
    let mut b = off as usize;
    while a > 0 && ident_byte(src.byte_at(a - 1)) {
        a -= 1;
    }
    while b < src.len() && ident_byte(src.byte_at(b)) {
        b += 1;
    }
    return src.slice(a, b);
}

const fn ident_byte(c: u8) bool {
    return c == b'_' || c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9';
}

extend AddImport as Refactoring {
    pub fn id(self: &Self) str {
        return "add-import";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        let m = switch s.module_of(sel.file.as_str()) {
            Some(md) => md.index() as usize,
            None => {
                return false;
            },
        };
        let name = word_at(src_of(s, m), sel.start);
        return name.len() != 0 && feat::import_candidates(s.package(), m, name).len() != 0;
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let m = module_of(s, sel.file.as_str())?;
        let name = word_at(src_of(s, m), sel.start);
        let cands = feat::import_candidates(s.package(), m, name);
        let mut path = String::new();
        for i in 0..cands.len() {
            if params.len() == 0 && path.len() == 0 || cands[i].as_str() == params {
                path = cands[i].clone();
            }
        }
        if path.len() == 0 {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(
                ApiError::at(
                    Code::InvalidArgument,
                    "no module to import declares the name",
                    sel.file.as_str(),
                    sel.start,
                    sel.end,
                ),
            );
        }
        let at = feat::import_insert_at(s.package(), m);
        let mut we = syn::WorkspaceEdit::new();
        we.expect(sel.file.as_str(), s.version(sel.file.as_str()));
        we.replace(sel.file.as_str(), at, at, format("import {};\n", path.as_str()).as_str());
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Extract local ------------------------------------------------------------------------------------

/// `extract-local`: bind the selected expression to a new local before the statement that holds it and use
/// the local in its place. `params`: the local's name (default `value`).
pub struct ExtractLocal {}

// The expression node the selection names exactly in `t`, and the statement that holds it (the node whose
// parent is a block); None when the selection names no expression inside a block.
fn extract_site(t: &syn::SyntaxTree, sel: &Selection) Option<(syn::TextRange, syn::TextRange)> {
    let mut n = t.node_at(sel.start);
    // The outermost node with exactly the selected range.
    let mut found = Option::<syn::Node>::None;
    for _ in 0..1024 {
        let r = n.range();
        if r.start == sel.start && r.end == sel.end {
            found = Option::<syn::Node>::Some(n);
        }
        if r.start < sel.start || r.end > sel.end {
            break;
        }
        switch n.parent() {
            Some(q) => {
                n = q;
            },
            None => {
                break;
            },
        };
    }
    let e = found?;
    let k = e.kind();
    if k == syn::SyntaxKind::Block || k == syn::SyntaxKind::Let || k == syn::SyntaxKind::Return || k == syn::SyntaxKind::ExpressionStatement || k == syn::SyntaxKind::Function {
        return Option::<(syn::TextRange, syn::TextRange)>::None;
    }
    let mut st = e;
    for _ in 0..1024 {
        let q = st.parent()?;
        if q.kind() == syn::SyntaxKind::Block {
            return Option::<(syn::TextRange, syn::TextRange)>::Some((e.range(), st.range()));
        }
        st = q;
    }
    return Option::<(syn::TextRange, syn::TextRange)>::None;
}

extend ExtractLocal as Refactoring {
    pub fn id(self: &Self) str {
        return "extract-local";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        let t = switch syn::tree_of(s, sel.file.as_str()) {
            Ok(t) => t,
            Err(_) => {
                return false;
            },
        };
        return sel.end > sel.start && extract_site(&t, sel).is_some();
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let name = if params.len() == 0 {
            "value";
        } else {
            params;
        };
        let t = syn::tree_of(s, sel.file.as_str())?;
        let (er, sr) = switch extract_site(&t, sel) {
            Some(x) => x,
            None => {
                return Result::<syn::WorkspaceEdit, ApiError>::Err(
                    ApiError::at(
                        Code::InvalidArgument,
                        "the selection names no expression inside a block",
                        sel.file.as_str(),
                        sel.start,
                        sel.end,
                    ),
                );
            },
        };
        let text = t.text();
        let ls = line_start(text, sr.start);
        let indent = text.slice(ls as usize, sr.start as usize);
        let mut ins = String::new();
        ins.format_into("let {} = {};\n{}", name, text.slice(er.start as usize, er.end as usize), indent);
        let mut we = syn::WorkspaceEdit::new();
        we.expect(sel.file.as_str(), s.version(sel.file.as_str()));
        we.replace(sel.file.as_str(), sr.start, sr.start, ins.as_str());
        we.replace(sel.file.as_str(), er.start, er.end, name);
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Change signature ---------------------------------------------------------------------------------

/// `change-signature`: reorder the parameters of the function named at the selection (at its declaration or
/// a use), and the arguments of every call of it. `params`: the new order of the parameters after `self`, as
/// comma-separated old positions (`1,0` swaps two).
pub struct ChangeSignature {}

// The new order `params` gives `n` parameters; None when it is no permutation of 0..n.
fn parse_order(params: str, n: usize) Option<Vector<usize>> {
    let mut out = Vector::<usize>::new();
    let mut seen = Vector::<bool>::new();
    seen.resize_default(n);
    for part in params.split(",") {
        let v = part.trim().parse_u64()?;
        if v as usize >= n || seen[v as usize] {
            return Option::<Vector<usize>>::None;
        }
        seen[v as usize] = true;
        out.push(v as usize);
    }
    if out.len() != n {
        return Option::<Vector<usize>>::None;
    }
    return Option::<Vector<usize>>::Some(out);
}

// The function declaration `sel` names, or NODE_NONE.
fn fn_at(s: &ses::Session, sel: &Selection) DefId {
    let m = switch s.module_of(sel.file.as_str()) {
        Some(md) => md.index() as usize,
        None => {
            return DefId { module: 0, node: NODE_NONE };
        },
    };
    let d = feat::def_at(s.package(), m, sel.start);
    if d.node == NODE_NONE || s.package().modules[d.module as usize].ast.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
        return DefId { module: 0, node: NODE_NONE };
    }
    return d;
}

// Reorder the items of list text `texts` (the source of each) by `order` into one comma-separated text.
fn joined(texts: &Vector<String>, order: &Vector<usize>, skip: usize) String {
    let mut out = String::new();
    for k in 0..skip {
        if k != 0 {
            out.push_str(", ");
        }
        out.push_str(texts[k].as_str());
    }
    for k in 0..order.len() {
        if skip + k != 0 {
            out.push_str(", ");
        }
        out.push_str(texts[skip + order[k]].as_str());
    }
    return out;
}

extend ChangeSignature as Refactoring {
    pub fn id(self: &Self) str {
        return "change-signature";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        return fn_at(s, sel).node != NODE_NONE;
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let d = fn_at(s, sel);
        if d.node == NODE_NONE {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(
                ApiError::at(Code::InvalidArgument, "no function is named here", sel.file.as_str(), sel.start, sel.end),
            );
        }
        let dfile = s.package().modules[d.module as usize].file.clone();
        // The declaration's parameter texts; a `self` parameter stays first.
        let mut ptexts = Vector::<String>::new();
        let mut has_self = false;
        let mut prange = syn::TextRange { start: 0, end: 0 };
        {
            let a = &s.package().modules[d.module as usize].ast;
            let src = src_of(s, d.module as usize);
            let ps = a.ext(d.node).function.params;
            for i in 0..ps.len {
                let pid = unsafe a.list(ps)[i as usize];
                let sp = a.at_const(pid).span;
                if i == 0 {
                    prange.start = sp.start;
                    let nm = a.at_const(a.at_const(pid).as_data.parameter.name).span;
                    has_self = src.slice(nm.start as usize, nm.end as usize) == "self";
                }
                prange.end = sp.end;
                ptexts.push(String::from_str(src.slice(sp.start as usize, sp.end as usize)));
            }
        }
        let skip: usize = if has_self {
            1;
        } else {
            0;
        };
        let order = switch parse_order(params, ptexts.len() - skip) {
            Some(o) => o,
            None => {
                return Result::<syn::WorkspaceEdit, ApiError>::Err(
                    ApiError::new(
                        Code::InvalidArgument,
                        "the parameters are no permutation of the function's parameters",
                    ),
                );
            },
        };
        let mut we = syn::WorkspaceEdit::new();
        if ptexts.len() != 0 {
            we.replace(dfile.as_str(), prange.start, prange.end, joined(&ptexts, &order, skip).as_str());
        }
        an::hydrate_refs(s.package_mut(), d);
        let refs = feat::references_of_def(s.package(), d, false);
        let mut trees = Vector::<syn::SyntaxTree>::new();
        let mut tree_of = Vector::<u32>::new(); // module of each tree
        for i in 0..refs.len() {
            let rm = refs[i].module;
            let mut ti = tree_of.len();
            for k in 0..tree_of.len() {
                if tree_of[k] == rm {
                    ti = k;
                }
            }
            if ti == tree_of.len() {
                let md = &s.package().modules[rm as usize];
                trees.push(syn::SyntaxTree::parse(md.file.as_str(), md.source.as_str()));
                tree_of.push(rm);
            }
            let t = &trees[ti];
            // The call whose callee holds the reference.
            let mut n = t.node_at(refs[i].start);
            let mut call = Option::<syn::Node>::None;
            for _ in 0..64 {
                if let Some(c) = n.as_call() {
                    if let Some(cl) = c.callee() {
                        if cl.range().start <= refs[i].start && refs[i].end <= cl.range().end {
                            call = Option::<syn::Node>::Some(n);
                        }
                    }
                    break;
                }
                switch n.parent() {
                    Some(q) => {
                        n = q;
                    },
                    None => {
                        break;
                    },
                };
            }
            let cn = switch call {
                Some(c) => c,
                None => {
                    continue;
                },
            };
            let cv = cn.as_call().unwrap();
            let mut atexts = Vector::<String>::new();
            let mut ar = syn::TextRange { start: 0, end: 0 };
            for arg in cv.args() {
                if atexts.len() == 0 {
                    ar.start = arg.range().start;
                }
                ar.end = arg.range().end;
                atexts.push(String::from_str(arg.text()));
            }
            // A method call through a receiver passes `self` before the parentheses.
            let callee = cv.callee().unwrap();
            let through = has_self && callee.kind() == syn::SyntaxKind::Member && atexts.len() + 1 == ptexts.len();
            let askip = if has_self && !through {
                1 as usize;
            } else {
                0 as usize;
            };
            if atexts.len() != order.len() + askip {
                return Result::<syn::WorkspaceEdit, ApiError>::Err(
                    ApiError::at(
                        Code::InvalidArgument,
                        "a call passes another argument count",
                        t.path(),
                        cn.range().start,
                        cn.range().end,
                    ),
                );
            }
            if atexts.len() != 0 {
                we.replace(t.path(), ar.start, ar.end, joined(&atexts, &order, askip).as_str());
            }
        }
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Implement members --------------------------------------------------------------------------------

/// `implement-members`: in the `extend T as I` block at the selection, add a stub for every method of `I`
/// that has no default body and the block does not define. No parameters.
pub struct ImplementMembers {}

// The `extend .. as ..` node at `off` of module `m` and the interface it names, or NODE_NONE.
fn conformance_at(p: &loader::Package, m: usize, off: u32) (NodeId, DefId) {
    let a = &p.modules[m].ast;
    let mut ext = NODE_NONE;
    let mut blen: u32 = 0xFFFFFFFF;
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        let nd = a.at_const(iid);
        if nd.kind == NodeKind::NODE_EXTEND && nd.span.start <= off && off < nd.span.end && nd.span.end - nd.span.start < blen {
            ext = iid;
            blen = nd.span.end - nd.span.start;
        }
    }
    if ext == NODE_NONE {
        return NODE_NONE, DefId { module: 0, node: NODE_NONE };
    }
    let it = a.ext(ext).extend_def.interface_type;
    if it == NODE_NONE || !a.valid(it) {
        return NODE_NONE, DefId { module: 0, node: NODE_NONE };
    }
    let idf = a.resolution_def(it);
    if idf.node == NODE_NONE || p.modules[idf.module as usize].ast.at_const(idf.node).kind != NodeKind::NODE_INTERFACE {
        return NODE_NONE, DefId { module: 0, node: NODE_NONE };
    }
    return ext, idf;
}

// The names of the methods interface `idf` requires that extend `ext` of module `m` does not define.
fn missing_methods(p: &loader::Package, m: usize, ext: NodeId, idf: DefId) Vector<String> {
    let a = &p.modules[m].ast;
    let src = p.modules[m].source.as_str();
    let mut have = Vector::<String>::new();
    let es = a.ext(ext).extend_def.items;
    for i in 0..es.len {
        let f = a.at_const(unsafe a.list(es)[i as usize]);
        if f.kind == NodeKind::NODE_FUNCTION {
            let sp = a.at_const(a.ext_name(unsafe a.list(es)[i as usize])).span;
            have.push(String::from_str(src.slice(sp.start as usize, sp.end as usize)));
        }
    }
    let ia = &p.modules[idf.module as usize].ast;
    let isrc = p.modules[idf.module as usize].source.as_str();
    let mut out = Vector::<String>::new();
    let ms = ia.ext(idf.node).interface_def.items;
    for i in 0..ms.len {
        let f = ia.at_const(unsafe ia.list(ms)[i as usize]);
        if f.kind != NodeKind::NODE_FUNCTION || ia.ext(unsafe ia.list(ms)[i as usize]).function.body != NODE_NONE {
            continue;
        }
        let sp = ia.at_const(ia.ext_name(unsafe ia.list(ms)[i as usize])).span;
        let name = String::from_str(isrc.slice(sp.start as usize, sp.end as usize));
        if !have.contains(&name) {
            out.push(name);
        }
    }
    return out;
}

extend ImplementMembers as Refactoring {
    pub fn id(self: &Self) str {
        return "implement-members";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        let m = switch s.module_of(sel.file.as_str()) {
            Some(md) => md.index() as usize,
            None => {
                return false;
            },
        };
        let (ext, idf) = conformance_at(s.package(), m, sel.start);
        return ext != NODE_NONE && missing_methods(s.package(), m, ext, idf).len() != 0;
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, _params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let m = module_of(s, sel.file.as_str())?;
        let p = s.package();
        let (ext, idf) = conformance_at(p, m, sel.start);
        if ext == NODE_NONE {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(
                ApiError::at(Code::InvalidArgument, "no conformance is here", sel.file.as_str(), sel.start, sel.end),
            );
        }
        let names = missing_methods(p, m, ext, idf);
        let mut text = String::new();
        let mut at: u32 = 0;
        for i in 0..names.len() {
            if let Some(st) = feat::iface_stub(p, m, sel.start, names[i].as_str()) {
                at = st.at;
                text.push_string(&st.text);
            }
        }
        let mut we = syn::WorkspaceEdit::new();
        we.expect(sel.file.as_str(), s.version(sel.file.as_str()));
        if text.len() != 0 {
            we.replace(sel.file.as_str(), at, at, text.as_str());
        }
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Move item ----------------------------------------------------------------------------------------

/// `move-item`: move the top-level declaration named at the selection to another module of the session,
/// and rewrite its uses: a use qualified by its old module takes the new one, a use in its old module is
/// qualified by the new one, and a file that now names the new module imports it. Uses in the declaration of
/// the items of its old module are qualified by that module, which the new module then imports. `params`:
/// the target file. A declaration that is not `pub` and is used outside itself cannot move.
pub struct MoveItem {}

// The top-level declaration whose name `sel` is on, in module `m`, or NODE_NONE.
fn item_at(p: &loader::Package, m: usize, off: u32) NodeId {
    let d = feat::def_at(p, m, off);
    if d.node == NODE_NONE || d.module as usize != m {
        return NODE_NONE;
    }
    let it = p.item_of(d.module, d.node);
    if it == loader::ITEM_NONE || p.idx().items[it as usize].owner != loader::ITEM_NONE {
        return NODE_NONE;
    }
    let k = p.modules[m].ast.at_const(d.node).kind;
    if k == NodeKind::NODE_EXTEND || k == NodeKind::NODE_IMPORT {
        return NODE_NONE;
    }
    return d.node;
}

// The bytes of declaration `node` of module `m` with its comment and attribute lines and its trailing line
// feed.
fn item_bytes(p: &loader::Package, m: usize, node: NodeId) (u32, u32) {
    let src = p.modules[m].source.as_str();
    let sp = p.modules[m].ast.at_const(node).span;
    let mut start = line_start(src, sp.start);
    // Each step takes one line above.
    for _ in 0..src.len() {
        if start == 0 {
            break;
        }
        let pl = line_start(src, start - 1);
        let line = src.slice(pl as usize, start as usize).trim();
        if !line.starts_with("//") && !line.starts_with("@") {
            break;
        }
        start = pl;
    }
    return start, line_end(src, sp.end);
}

// Whether module `m` imports module path `path` (an import line names it).
fn imports_path(p: &loader::Package, m: usize, path: str) bool {
    let a = &p.modules[m].ast;
    let src = p.modules[m].source.as_str();
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_IMPORT && loader::join_parts(
            a,
            src,
            a.at_const(iid).as_data.import_decl.path,
            "::",
        ).as_str() == path {
            return true;
        }
    }
    return false;
}

// The last segment of module path `path`: the qualifier its import gives.
fn last_segment(path: str) str {
    let mut i = path.len();
    while i > 0 && path.byte_at(i - 1) != b':' {
        i -= 1;
    }
    return path.slice(i, path.len());
}

// The start of the qualifier (`a::b::`) right before byte `at` of `src`, or `at` when none.
fn qualifier_start(src: str, at: u32) u32 {
    let mut i = at as usize;
    // Each step takes one `ident::` segment.
    for _ in 0..64 {
        if i < 2 || src.byte_at(i - 1) != b':' || src.byte_at(i - 2) != b':' {
            break;
        }
        let mut k = i - 2;
        while k > 0 && ident_byte(src.byte_at(k - 1)) {
            k -= 1;
        }
        if k == i - 2 {
            break;
        }
        i = k;
    }
    return i as u32;
}

extend MoveItem as Refactoring {
    pub fn id(self: &Self) str {
        return "move-item";
    }

    pub fn applies(self: &mut Self, s: &mut ses::Session, sel: &Selection) bool {
        return switch s.module_of(sel.file.as_str()) {
            Some(md) => item_at(s.package(), md.index() as usize, sel.start) != NODE_NONE,
            None => false,
        };
    }

    pub fn edit(self: &mut Self, s: &mut ses::Session, sel: &Selection, params: str) Result<
        syn::WorkspaceEdit,
        ApiError
    > {
        let ma = module_of(s, sel.file.as_str())?;
        let mb = module_of(s, params)?;
        let node = item_at(s.package(), ma, sel.start);
        if node == NODE_NONE || ma == mb {
            return Result::<syn::WorkspaceEdit, ApiError>::Err(
                ApiError::at(
                    Code::InvalidArgument,
                    "no top-level declaration to move is named here",
                    sel.file.as_str(),
                    sel.start,
                    sel.end,
                ),
            );
        }
        let d = DefId { module: ma as ModuleId, node: node };
        an::hydrate_refs(s.package_mut(), d);
        let p = s.package();
        let afile = p.modules[ma].file.clone();
        let bfile = p.modules[mb].file.clone();
        let apath = p.modules[ma].path.clone();
        let bpath = p.modules[mb].path.clone();
        let asrc = p.modules[ma].source.as_str();
        let (istart, iend) = item_bytes(p, ma, node);
        let it = p.item_of(d.module, d.node);
        let public = p.idx().items[it as usize].vis == VIS_PUB;
        let mut we = syn::WorkspaceEdit::new();
        // The declaration's own uses of the items of its old module.
        let mut inner = Vector::<Edit>::new();
        let mut needs_a = false;
        {
            let a = &p.modules[ma].ast;
            let n = a.nnodes();
            for i0 in 1..n {
                let i = a.nth_id(i0);
                let sp = a.at_const(i).span;
                if sp.start < istart || sp.end > iend || !a.valid(i) {
                    continue;
                }
                let rd = a.resolution_def(i);
                if rd.node == NODE_NONE || rd.module as usize != ma && rd.module as usize != mb || rd.node == node {
                    continue;
                }
                let ri = p.item_of(rd.module, rd.node);
                if ri == loader::ITEM_NONE || p.idx().items[ri as usize].owner != loader::ITEM_NONE {
                    continue;
                }
                let k = a.at_const(i).kind;
                if k != NodeKind::NODE_IDENTIFIER && k != NodeKind::NODE_TYPE_PATH {
                    continue;
                }
                let qs = qualifier_start(asrc, sp.start);
                if rd.module as usize == mb {
                    // An item of the new module, qualified here: it is local there.
                    if qs != sp.start {
                        inner.push(Edit { start: qs - istart, end: sp.start - istart, text: String::new() });
                    }
                    continue;
                }
                if qs != sp.start {
                    continue;
                }
                let mut q = String::from_str(last_segment(apath.as_str()));
                q.push_str("::");
                inner.push(Edit { start: sp.start - istart, end: sp.start - istart, text: q });
                needs_a = true;
            }
        }
        let mut moved = String::new();
        apply_edits(asrc.slice(istart as usize, iend as usize), inner.as_slice(), &mut moved)?;
        we.replace(afile.as_str(), istart, iend, "");
        let bsrc = p.modules[mb].source.as_str();
        let mut tail = String::new();
        if bsrc.len() != 0 && !bsrc.ends_with("\n") {
            tail.push_byte(b'\n');
        }
        tail.push_byte(b'\n');
        tail.push_string(&moved);
        we.replace(bfile.as_str(), bsrc.len() as u32, bsrc.len() as u32, tail.as_str());
        if needs_a && !imports_path(p, mb, apath.as_str()) {
            let at = feat::import_insert_at(p, mb);
            we.replace(bfile.as_str(), at, at, format("import {};\n", apath.as_str()).as_str());
        }
        // The uses outside the declaration.
        let refs = feat::references_of_def(p, d, false);
        let mut importers = Vector::<u32>::new();
        for i in 0..refs.len() {
            let rm = refs[i].module as usize;
            let rsrc = p.modules[rm].source.as_str();
            let rfile = p.modules[rm].file.as_str();
            let r = refs[i];
            if rm == ma && r.start >= istart && r.end <= iend {
                continue;
            }
            let qs = qualifier_start(rsrc, r.start);
            if rm == mb {
                if qs != r.start {
                    we.replace(rfile, qs, r.start, "");
                }
                continue;
            }
            if qs == r.start && rm != ma {
                return Result::<syn::WorkspaceEdit, ApiError>::Err(
                    ApiError::at(
                        Code::InvalidArgument,
                        "a use names the declaration through a glob import",
                        rfile,
                        r.start,
                        r.end,
                    ),
                );
            }
            if !public {
                return Result::<syn::WorkspaceEdit, ApiError>::Err(
                    ApiError::at(
                        Code::InvalidArgument,
                        "the declaration is not 'pub' and is used outside itself",
                        rfile,
                        r.start,
                        r.end,
                    ),
                );
            }
            let mut q = String::from_str(last_segment(bpath.as_str()));
            q.push_str("::");
            we.replace(rfile, qs, r.start, q.as_str());
            if !imports_path(p, rm, bpath.as_str()) && !importers.contains(&(rm as u32)) {
                importers.push(rm as u32);
                let at = feat::import_insert_at(p, rm);
                we.replace(rfile, at, at, format("import {};\n", bpath.as_str()).as_str());
            }
        }
        return Result::<syn::WorkspaceEdit, ApiError>::Ok(we);
    }
}

// --- Structural matching ------------------------------------------------------------------------------

/// What one match found: the matched node and the nodes it bound, by name, as node identities of the tree
/// (`syn::Node::id`), so a match holds no borrow.
pub struct Match {
    pub(file) names: Vector<String>,
    pub(file) ids: Vector<u32>,
}

extend Match {
    /// Bind `name` to `n`, replacing an earlier binding of the name.
    pub fn bind(self: &mut Self, name: str, n: syn::Node) {
        for i in 0..self.names.len() {
            if self.names[i].as_str() == name {
                self.ids[i] = n.id();
                return;
            }
        }
        self.names.push(String::from_str(name));
        self.ids.push(n.id());
    }

    /// The node of tree `t` bound to `name`; the matched node itself is bound to "".
    pub fn get<'t>(self: &Self, t: &'t syn::SyntaxTree, name: str) Option<syn::Node<'t>> {
        for i in 0..self.names.len() {
            if self.names[i].as_str() == name {
                return t.node(self.ids[i]);
            }
        }
        return Option::<syn::Node<'t>>::None;
    }
}

/// A match for every node of `t`, in preorder, for which `pred` holds, with what `pred` bound for it.
pub fn find_all<F: fn(syn::Node, &mut Match) bool>(t: &syn::SyntaxTree, pred: F) Vector<Match> {
    let mut out = Vector::<Match>::new();
    for n in t.root().descendants() {
        let mut m = Match { names: Vector::<String>::new(), ids: Vector::<u32>::new() };
        if pred(n, &mut m) {
            m.bind("", n);
            out.push(m);
        }
    }
    return out;
}

/// Whether node `n` of `file`, parsed from the session's text, names the declaration `key` names.
pub fn refers_to(s: &ses::Session, file: str, n: syn::Node, key: &sem::SymbolKey) bool {
    return switch sem::symbol_at(s, file, n.range().start) {
        Ok(Some(y)) => switch y.key() {
            Some(k) => k.module.as_str() == key.module.as_str() && k.owner.as_str() == key.owner.as_str() && k.kind == key.kind && k.name.as_str() == key.name.as_str() && k.ordinal == key.ordinal,
            None => false,
        },
        _ => false,
    };
}

/// Whether node `n` of `file` is a call of the declaration `key` names.
pub fn calls(s: &ses::Session, file: str, n: syn::Node, key: &sem::SymbolKey) bool {
    return switch n.as_call() {
        Some(c) => switch c.callee() {
            Some(cl) => refers_to(s, file, last_name(cl), key),
            None => false,
        },
        None => false,
    };
}

// The last identifier inside node `n` (the member of `a.b`, the last segment of a path).
fn last_name(n: syn::Node) syn::Node {
    let mut best = n;
    for d in n.descendants() {
        if d.kind() == syn::SyntaxKind::Identifier {
            best = d;
        }
    }
    return best;
}

/// Whether the expression node `n` of `file` has the type the compiler spells `display`.
pub fn has_type(s: &ses::Session, file: str, n: syn::Node, display: str) bool {
    return switch sem::type_of_range(s, file, n.range().start, n.range().end) {
        Ok(Some(t)) => t.display().as_str() == display,
        _ => false,
    };
}

/// Whether a node of kind `k` holds `n`.
pub fn inside(n: syn::Node, k: syn::SyntaxKind) bool {
    let mut c = n;
    // Each step climbs one level.
    for _ in 0..4096 {
        switch c.parent() {
            Some(q) => {
                if q.kind() == k {
                    return true;
                }
                c = q;
            },
            None => {
                return false;
            },
        };
    }
    return false;
}
