// Positional LSP queries over a built package: hover (rendered type + declaration signature),
// go-to-definition, and find-references/rename spans. All package-scoped -- the server maps modules to
// URIs and byte spans to LSP ranges. Queries read the semantic tables the typechecker left on each
// module's Ast (`types`, `resolutions`); nothing here mutates the package.
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;
import typechecker::typechecker as tc;

type HovBuf = Array<char, 512>;

/// A definition/reference site: a byte span in `module`'s source.
pub struct Loc {
    pub module: u32,
    pub start: u32,
    pub end: u32,
}

const fn mod_ast(p: &loader::Package, m: usize) *const Ast {
    return &p.modules.at(m).ast;
}

/// The innermost node whose span contains `off` (ties prefer the later, more specific node). Linear over
/// the node pool -- microseconds at compiler scale.
pub fn node_at(a: *const Ast, off: u32) NodeId {
    let mut best: NodeId = NODE_NONE;
    let mut blen: u32 = 0xFFFFFFFF;
    let n = unsafe (*a).nodes.len();
    for i in 1..n {
        let sp = unsafe (*a).at_const(i as NodeId).span;
        if sp.start <= off && off < sp.end && sp.end - sp.start <= blen {
            best = i as NodeId;
            blen = sp.end - sp.start;
        }
    }
    return best;
}

// node_at with the editor convention that a cursor sitting just past a word still means that word.
fn node_at_or_before(a: *const Ast, off: u32) NodeId {
    let id = node_at(a, off);
    if id == NODE_NONE && off > 0 {
        return node_at(a, off - 1);
    }
    return id;
}

/// The declaration's NAME node (whose span is the go-to/rename target); NODE_NONE when the kind has no
/// distinct name node (callers fall back to the decl span).
pub const fn decl_name(a: *const Ast, id: NodeId) NodeId {
    let n = unsafe (*a).at_const(id);
    if n.kind == NodeKind::NODE_FUNCTION {
        return n.as_data.function.name;
    }
    if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
        return n.as_data.aggregate.name;
    }
    if n.kind == NodeKind::NODE_PARAMETER {
        return n.as_data.parameter.name;
    }
    if n.kind == NodeKind::NODE_FIELD {
        return n.as_data.field.name;
    }
    if n.kind == NodeKind::NODE_VARIANT {
        return n.as_data.variant.name;
    }
    if n.kind == NodeKind::NODE_INTERFACE {
        return n.as_data.interface_def.name;
    }
    if n.kind == NodeKind::NODE_TYPE_ALIAS {
        return n.as_data.type_alias.name;
    }
    if n.kind == NodeKind::NODE_CONST {
        return n.as_data.const_def.name;
    }
    if n.kind == NodeKind::NODE_GENERIC_PARAM {
        return n.as_data.generic_param.name;
    }
    if n.kind == NodeKind::NODE_LET {
        return n.as_data.let_stmt.name;
    }
    if n.kind == NodeKind::NODE_PATTERN_NAME || n.kind == NodeKind::NODE_IDENTIFIER {
        return id;
    }
    return NODE_NONE;
}

// The smallest node containing `off` that carries a resolution (a name node's resolution sometimes
// lives on its enclosing member/path node, so innermost-alone is not enough).
fn resolved_at(p: &loader::Package, a: *const Ast, off: u32) DefId {
    let mut best = DefId { module: 0, node: NODE_NONE };
    let mut blen: u32 = 0xFFFFFFFF;
    let mut nn = unsafe (*a).resolutions_len();
    if unsafe (*a).nodes.len() < nn {
        nn = unsafe (*a).nodes.len();
    }
    for i in 1..nn {
        let sp = unsafe (*a).at_const(i as NodeId).span;
        if sp.start <= off && off < sp.end && sp.end - sp.start <= blen {
            let d = unsafe (*a).resolution_def(i as NodeId);
            if d.node != NODE_NONE && d.module as usize < p.modules.len() {
                best = d;
                blen = sp.end - sp.start;
            }
        }
    }
    return best;
}

// The resolved definition under `off` in module `mi`; DefId{0, NODE_NONE} when nothing resolves. A
// cursor ON a declaration's own name resolves to that declaration (so rename/references work from the
// definition site too).
fn def_at(p: &loader::Package, mi: usize, off: u32) DefId {
    let a = mod_ast(p, mi);
    let mut d = resolved_at(p, a, off);
    if d.node == NODE_NONE && off > 0 {
        d = resolved_at(p, a, off - 1); // cursor just past the word
    }
    if d.node != NODE_NONE {
        return d;
    }
    // maybe the cursor is on a decl's own name: find the decl this name node belongs to
    let id = node_at_or_before(a, off);
    if id != NODE_NONE {
        let n = unsafe (*a).nodes.len();
        for i in 1..n {
            if decl_name(a, i as NodeId) == id && i as NodeId != id {
                return DefId { module: mi as ModuleId, node: i as NodeId };
            }
        }
    }
    return DefId { module: 0, node: NODE_NONE };
}

// Trimmed source slice of a declaration's head -- a function up to its body, a type up to its name, a
// binding up to its type -- capped so hover stays a one-liner-ish.
fn decl_signature(p: &loader::Package, d: DefId) String {
    let da = mod_ast(p, d.module as usize);
    let src = p.modules.at(d.module as usize).source.as_str();
    let n = unsafe (*da).at_const(d.node);
    let s = n.span.start;
    let mut e = n.span.end;
    if n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.body != NODE_NONE {
        e = unsafe (*da).at_const(n.as_data.function.body).span.start;
    } else if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
        e = unsafe (*da).at_const(n.as_data.aggregate.name).span.end;
    } else if n.kind == NodeKind::NODE_INTERFACE {
        e = unsafe (*da).at_const(n.as_data.interface_def.name).span.end;
    } else if n.kind == NodeKind::NODE_LET {
        e = unsafe (*da).at_const(n.as_data.let_stmt.name).span.end;
        if n.as_data.let_stmt.ty != NODE_NONE {
            e = unsafe (*da).at_const(n.as_data.let_stmt.ty).span.end;
        }
    }
    if e as usize > src.len() {
        e = src.len() as u32;
    }
    if e > s + 300 {
        e = s + 300; // cap pathological heads
    }
    if s >= e {
        return String::new();
    }
    return String::from_str(src.slice(s as usize, e as usize).trim());
}

// Start of the line containing `pos` (the byte after the previous newline).
fn line_start_of(src: str, pos: usize) usize {
    let mut i = pos;
    while i > 0 && src[i - 1] != b'\n' {
        i -= 1;
    }
    return i;
}

// The contiguous `//`/`///` comment block sitting directly above the declaration (attribute lines
// between the comments and the item are skipped) -- the item's documentation. Comments are lexer
// trivia, dropped before the AST, so hover recovers them straight from the defining module's source.
fn decl_doc(p: &loader::Package, d: DefId) String {
    let da = mod_ast(p, d.module as usize);
    let src = p.modules.at(d.module as usize).source.as_str();
    let sp = unsafe (*da).at_const(d.node).span;
    if sp.start as usize > src.len() {
        return String::new();
    }
    let decl_ls = line_start_of(src, sp.start as usize);
    // only a declaration that STARTS its line owns the comment block above it: a parameter's node
    // sits mid-line inside the fn header and must not inherit the function's docs. Item spans begin
    // after their visibility keyword, so a lone `pub` prefix still counts as line-leading.
    let pre = src.slice(decl_ls, sp.start as usize).trim();
    if pre.len() != 0 && pre != "pub" {
        return String::new();
    }
    let mut top = decl_ls;
    let mut cur = decl_ls;
    while cur > 0 {
        let pls = line_start_of(src, cur - 1);
        let line = src.slice(pls, cur - 1).trim();
        if line.starts_with("//") {
            top = pls;
            cur = pls;
        } else if line.starts_with("@") {
            cur = pls; // an attribute between the comments and the item
        } else {
            break;
        }
    }
    let mut out = String::new();
    let mut i = top;
    while i < decl_ls {
        let mut le = i;
        while le < src.len() && src[le] != b'\n' {
            le += 1;
        }
        let line = src.slice(i, le).trim();
        let mut body = "";
        if line.starts_with("///") {
            body = line.slice(3, line.len());
        } else if line.starts_with("//") {
            body = line.slice(2, line.len());
        } else {
            i = le + 1;
            continue; // a skipped attribute line
        }
        if body.starts_with(" ") {
            body = body.slice(1, body.len());
        }
        if out.len() != 0 {
            out.push_byte(b'\n');
        }
        out.push_str(body);
        i = le + 1;
    }
    // a trailing comment on the declaration's own line documents it too (the house style for
    // fields: `pub obj: Vector<JSONPair>, // JT_OBJECT members`). Scanning AFTER the span end keeps
    // string literals containing "//" out of reach.
    let mut j = sp.end as usize;
    while j < src.len() && src[j] != b'\n' {
        j += 1;
    }
    if sp.end as usize < j {
        let tail = src.slice(sp.end as usize, j);
        let ci = tail.find("//");
        if ci >= 0 {
            let mut body = tail.slice(ci as usize + 2, tail.len());
            if body.starts_with("/") {
                body = body.slice(1, body.len());
            }
            let t = body.trim();
            if t.len() != 0 {
                if out.len() != 0 {
                    out.push_byte(b'\n');
                }
                out.push_str(t);
            }
        }
    }
    return out;
}

/// Markdown hover for the position: the expression's rendered type, then the resolved declaration's
/// head. None when the position carries neither.
pub fn hover(p: &loader::Package, mi: usize, off: u32) Option<String> {
    let a = mod_ast(p, mi);
    let id = node_at_or_before(a, off);
    if id == NODE_NONE {
        return Option::<String>::None;
    }
    let mut out = String::new();
    let mut t: TypeId = TYPE_NONE;
    if id as usize < unsafe (*a).types.len() {
        t = unsafe (*a).type_of(id);
    }
    if t != TYPE_NONE {
        let mut buf = HovBuf {};
        tc::render_type_into(p, a, p.modules.at(mi).source.as_str(), t, &mut buf[0], 512);
        out.push_str("```super-c\n");
        out.push_str(str::from_cstr(&buf[0]));
        out.push_str("\n```");
    }
    let d = def_at(p, mi, off);
    if d.node != NODE_NONE {
        let sig = decl_signature(p, d);
        if sig.len() != 0 {
            if out.len() != 0 {
                out.push_str("\n\n---\n");
            }
            out.push_str("```super-c\n");
            out.push_string(&sig);
            out.push_str("\n```");
        }
        let s = sig;
        s.free();
        let doc = decl_doc(p, d);
        if doc.len() != 0 {
            out.push_str("\n\n");
            out.push_string(&doc);
        }
        let dd = doc;
        dd.free();
    }
    if out.len() == 0 {
        let o = out;
        o.free();
        return Option::<String>::None;
    }
    return Option::<String>::Some(out);
}

/// The definition site for the position: the resolved decl's name span (decl span as the fallback).
pub fn definition(p: &loader::Package, mi: usize, off: u32) Option<Loc> {
    let d = def_at(p, mi, off);
    if d.node == NODE_NONE {
        return Option::<Loc>::None;
    }
    let da = mod_ast(p, d.module as usize);
    let mut sp = unsafe (*da).at_const(d.node).span;
    let nm = decl_name(da, d.node);
    if nm != NODE_NONE {
        sp = unsafe (*da).at_const(nm).span;
    }
    return Option::<Loc>::Some(Loc { module: d.module, start: sp.start, end: sp.end });
}

// The span rename/references should touch for a resolved node: a path member or type path narrows to
// its final NAME segment (replacing the whole `util::Point` span would eat the qualifier).
const fn ref_span(a: *const Ast, i: NodeId) tok::Span {
    let n = unsafe (*a).at_const(i);
    if n.kind == NodeKind::NODE_MEMBER {
        return unsafe (*a).at_const(n.as_data.member.member).span;
    }
    if n.kind == NodeKind::NODE_TYPE_PATH {
        let parts = n.as_data.type_path.parts;
        if parts.len > 0 {
            return unsafe (*a).at_const(unsafe (*a).list(parts)[(parts.len - 1) as usize]).span;
        }
    }
    return n.span;
}

/// Every reference to the definition under the position, DefId-exact across all modules (same-name
/// different-def sites never match). `include_decl` appends the declaration's name span.
pub fn references(p: &loader::Package, mi: usize, off: u32, include_decl: bool) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    let d = def_at(p, mi, off);
    if d.node == NODE_NONE {
        return out;
    }
    for mm in 0..p.modules.len() {
        let am = mod_ast(p, mm);
        let mut nn = unsafe (*am).resolutions_len();
        if unsafe (*am).nodes.len() < nn {
            nn = unsafe (*am).nodes.len();
        }
        for i in 1..nn {
            let r = unsafe (*am).resolution_def(i as NodeId);
            if r.module == d.module && r.node == d.node {
                let sp = ref_span(am, i as NodeId);
                // dedupe identical spans (a member and its name node can both resolve here)
                let mut seen = false;
                for k in 0..out.len() {
                    if out.at(k).module == mm as u32 && out.at(k).start == sp.start && out.at(k).end == sp.end {
                        seen = true;
                    }
                }
                if !seen {
                    out.push(Loc { module: mm as u32, start: sp.start, end: sp.end });
                }
            }
        }
    }
    if include_decl {
        let da = mod_ast(p, d.module as usize);
        let nm = decl_name(da, d.node);
        if nm != NODE_NONE {
            let sp = unsafe (*da).at_const(nm).span;
            out.push(Loc { module: d.module, start: sp.start, end: sp.end });
        }
    }
    return out;
}

/// The module owning the definition under the position (-1 if none) -- the server refuses renames whose
/// definition lives in the prelude or the ffi tree.
pub fn def_module(p: &loader::Package, mi: usize, off: u32) i32 {
    let d = def_at(p, mi, off);
    if d.node == NODE_NONE {
        return -1;
    }
    return d.module;
}

// ---------------------------------------------------------------------------------------------------------
// Semantic tokens.
// ---------------------------------------------------------------------------------------------------------

/// One classified token: a byte span + the server's legend indexes.
pub struct Tok {
    pub start: u32,
    pub end: u32,
    pub ty: i32, // legend: 0 namespace, 1 type, 2 enum, 3 enumMember, 4 interface, 5 typeParameter,
    // 6 parameter, 7 variable, 8 property, 9 function, 10 method
    pub mods: u32, // bit 0 declaration, bit 1 readonly
}

// A method is a function whose first parameter is named `self` (extend items always are).
const fn fn_is_method(a: *const Ast, id: NodeId) bool {
    let ps = unsafe (*a).at_const(id).as_data.function.params;
    if ps.len == 0 {
        return false;
    }
    let p0 = unsafe (*a).list(ps)[0];
    let nm = unsafe (*a).at_const(p0).as_data.parameter.name;
    if nm == NODE_NONE {
        return false;
    }
    let sp = unsafe (*a).at_const(nm).span;
    return sp.end - sp.start == 4;
}

// Legend index for a resolved declaration; -1 = unclassified (skip the token).
const fn token_type_of(p: &loader::Package, d: DefId) i32 {
    let da = mod_ast(p, d.module as usize);
    let n = unsafe (*da).at_const(d.node);
    if n.kind == NodeKind::NODE_FUNCTION {
        if fn_is_method(da, d.node) {
            return 10;
        }
        return 9;
    }
    if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_TYPE_ALIAS {
        return 1;
    }
    if n.kind == NodeKind::NODE_ENUM {
        return 2;
    }
    if n.kind == NodeKind::NODE_VARIANT {
        return 3;
    }
    if n.kind == NodeKind::NODE_INTERFACE {
        return 4;
    }
    if n.kind == NodeKind::NODE_GENERIC_PARAM {
        return 5;
    }
    if n.kind == NodeKind::NODE_PARAMETER {
        return 6;
    }
    if n.kind == NodeKind::NODE_LET || n.kind == NodeKind::NODE_PATTERN_NAME {
        return 7;
    }
    if n.kind == NodeKind::NODE_FIELD {
        return 8;
    }
    if n.kind == NodeKind::NODE_CONST {
        return 7;
    }
    if n.kind == NodeKind::NODE_IMPORT {
        return 0;
    }
    return -1;
}

fn tok_push(out: &mut Vector<Tok>, start: u32, end: u32, ty: i32, mods: u32) {
    if ty < 0 || start >= end {
        return;
    }
    for k in 0..out.len() {
        if out.at(k).start == start && out.at(k).end == end {
            return; // a member and its name node can classify the same span twice
        }
    }
    out.push(Tok { start: start, end: end, ty: ty, mods: mods });
}

/// Every classifiable token in module `mi`: resolved references (through their name spans) plus each
/// declaration's own name (with the `declaration` modifier). Sorted by start offset.
pub fn semantic_tokens(p: &loader::Package, mi: usize) Vector<Tok> {
    let a = mod_ast(p, mi);
    let mut out = Vector::<Tok>::new();
    let mut nn = unsafe (*a).resolutions_len();
    if unsafe (*a).nodes.len() < nn {
        nn = unsafe (*a).nodes.len();
    }
    for i in 1..nn {
        let d = unsafe (*a).resolution_def(i as NodeId);
        if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
            continue;
        }
        let sp = ref_span(a, i as NodeId);
        let mut mods: u32 = 0;
        let dk = unsafe (*mod_ast(p, d.module as usize)).at_const(d.node).kind;
        if dk == NodeKind::NODE_CONST {
            mods = 2; // readonly
        }
        tok_push(&mut out, sp.start, sp.end, token_type_of(p, d), mods);
    }
    let n = unsafe (*a).nodes.len();
    for i in 1..n {
        let nm = decl_name(a, i as NodeId);
        if nm == NODE_NONE || nm == i as NodeId {
            continue;
        }
        let sp = unsafe (*a).at_const(nm).span;
        let mut mods: u32 = 1; // declaration
        if unsafe (*a).at_const(i as NodeId).kind == NodeKind::NODE_CONST {
            mods = 3;
        }
        tok_push(
            &mut out,
            sp.start,
            sp.end,
            token_type_of(p, DefId { module: mi as ModuleId, node: i as NodeId }),
            mods,
        );
    }
    out.sort_by_key(tok_key);
    return out;
}

const fn tok_key(t: &Tok) u32 {
    return t.start;
}

// ---------------------------------------------------------------------------------------------------------
// Completion.
// ---------------------------------------------------------------------------------------------------------

/// One completion candidate; `kind` is the LSP CompletionItemKind.
pub struct CompItem {
    pub label: String,
    pub kind: i32,
    pub detail: String,
}

extend CompItem as Free {
    pub fn free(self: &mut Self) {
        self.label.free();
        self.detail.free();
    }
}

fn comp_push(out: &mut Vector<CompItem>, label: str, kind: i32, detail: String) {
    if label.len() == 0 {
        let d = detail;
        d.free();
        return;
    }
    for k in 0..out.len() {
        if out.at(k).label.as_str() == label {
            let d = detail;
            d.free();
            return;
        }
    }
    out.push(CompItem { label: String::from_str(label), kind: kind, detail: detail });
}

// A name node's text; "" when the node is not a name-bearing kind or its span is malformed.
// NodeAs is an untagged union: reading `name.text` of any other kind reinterprets a different
// payload as a Span -- the negative-length slice that once made completion malloc 16 EB.
const fn name_str(p: &loader::Package, m: usize, name_node: NodeId) str {
    if name_node == NODE_NONE {
        return "";
    }
    let a = mod_ast(p, m);
    let k = unsafe (*a).at_const(name_node).kind;
    if k != NodeKind::NODE_IDENTIFIER && k != NodeKind::NODE_PATTERN_NAME {
        return "";
    }
    let sp = unsafe (*a).at_const(name_node).as_data.name.text;
    let src = p.modules.at(m).source.as_str();
    if sp.start > sp.end || sp.end as usize > src.len() {
        return "";
    }
    return src.slice(sp.start as usize, sp.end as usize);
}

// Fields and methods of the aggregate decl (dm, dn): fields from its member list, methods from every
// module's `extend` blocks whose target resolves to it.
fn comp_aggregate(p: &loader::Package, dm: usize, dn: NodeId, out: &mut Vector<CompItem>) {
    let da = mod_ast(p, dm);
    let n = unsafe (*da).at_const(dn);
    if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe (*da).list(ms)[i as usize];
            let mk = unsafe (*da).at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD {
                let d = decl_signature(p, DefId { module: dm as ModuleId, node: mid });
                comp_push(out, name_str(p, dm, unsafe (*da).at_const(mid).as_data.field.name), 5, d);
            }
        }
    }
    for mm in 0..p.modules.len() {
        let am = mod_ast(p, mm);
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let items = unsafe (*am).at_const((*am).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*am).list(items)[i as usize];
            if unsafe (*am).at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let tgt = unsafe (*am).at_const(iid).as_data.extend_def.target_type;
            if tgt == NODE_NONE || tgt as usize >= unsafe (*am).resolutions_len() {
                continue;
            }
            let td = unsafe (*am).resolution_def(tgt);
            if td.module as usize != dm || td.node != dn {
                continue;
            }
            let eis = unsafe (*am).at_const(iid).as_data.extend_def.items;
            for k in 0..eis.len {
                let fid = unsafe (*am).list(eis)[k as usize];
                if unsafe (*am).at_const(fid).kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let sig = decl_signature(p, DefId { module: mm as ModuleId, node: fid });
                comp_push(out, name_str(p, mm, unsafe (*am).at_const(fid).as_data.function.name), 2, sig);
            }
        }
    }
}

// Public top-level declarations of module `mm`.
fn comp_module_publics(p: &loader::Package, mm: usize, out: &mut Vector<CompItem>) {
    let am = mod_ast(p, mm);
    if !p.modules.at(mm).has_ast {
        return;
    }
    let items = unsafe (*am).at_const((*am).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*am).list(items)[i as usize];
        let n = unsafe (*am).at_const(iid);
        if n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.is_public {
            comp_push(
                out,
                name_str(p, mm, n.as_data.function.name),
                3,
                decl_signature(p, DefId { module: mm as ModuleId, node: iid }),
            );
        } else if (n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM) && n.as_data.aggregate.is_public {
            let mut kind = 22;
            if n.kind == NodeKind::NODE_ENUM {
                kind = 13;
            }
            comp_push(out, name_str(p, mm, n.as_data.aggregate.name), kind, String::new());
        } else if n.kind == NodeKind::NODE_CONST && n.as_data.const_def.is_public {
            comp_push(
                out,
                name_str(p, mm, n.as_data.const_def.name),
                21,
                decl_signature(p, DefId { module: mm as ModuleId, node: iid }),
            );
        } else if n.kind == NodeKind::NODE_TYPE_ALIAS && n.as_data.type_alias.is_public {
            comp_push(out, name_str(p, mm, n.as_data.type_alias.name), 7, String::new());
        } else if n.kind == NodeKind::NODE_INTERFACE && n.as_data.interface_def.is_public {
            comp_push(out, name_str(p, mm, n.as_data.interface_def.name), 8, String::new());
        }
    }
}

/// Member completion at `off`, which must sit inside the probe identifier the server spliced in after
/// `.`/`::` (the buffer usually does not parse mid-edit; the probe makes it parse, and the typechecker
/// still assigns the receiver's type even though the probe itself errors). Offers fields + methods for a
/// value receiver, variants + methods for an enum path, and public items for a module path.
pub fn complete_member(p: &loader::Package, mi: usize, off: u32) Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    let a = mod_ast(p, mi);
    // the enclosing member node whose NAME span contains the probe
    let mut mem: NodeId = NODE_NONE;
    let n = unsafe (*a).nodes.len();
    for i in 1..n {
        if unsafe (*a).at_const(i as NodeId).kind != NodeKind::NODE_MEMBER {
            continue;
        }
        let mn = unsafe (*a).at_const(i as NodeId).as_data.member.member;
        if mn == NODE_NONE {
            continue;
        }
        let sp = unsafe (*a).at_const(mn).span;
        if sp.start <= off && off < sp.end {
            mem = i as NodeId;
            break;
        }
    }
    if mem == NODE_NONE {
        return out;
    }
    let mo = unsafe (*a).at_const(mem).as_data.member.object;
    // a path object resolving to an enum or an import: variants / module publics
    if mo as usize < unsafe (*a).resolutions_len() {
        let od = unsafe (*a).resolution_def(mo);
        if od.node != NODE_NONE && od.module as usize < p.modules.len() {
            let oa = mod_ast(p, od.module as usize);
            let ok = unsafe (*oa).at_const(od.node).kind;
            if ok == NodeKind::NODE_ENUM {
                let ms = unsafe (*oa).at_const(od.node).as_data.aggregate.members;
                for i in 0..ms.len {
                    let vid = unsafe (*oa).list(ms)[i as usize];
                    if unsafe (*oa).at_const(vid).kind == NodeKind::NODE_VARIANT {
                        comp_push(
                            &mut out,
                            name_str(p, od.module as usize, unsafe (*oa).at_const(vid).as_data.variant.name),
                            20,
                            String::new(),
                        );
                    }
                }
                comp_aggregate(p, od.module as usize, od.node, &mut out);
                return out;
            }
            if ok == NodeKind::NODE_IMPORT {
                // resolve the import to its module by the '::'-joined path
                let parts = unsafe (*oa).at_const(od.node).as_data.import_decl.path;
                let mut mp = String::new();
                for i in 0..parts.len {
                    if i != 0 {
                        mp.push_str("::");
                    }
                    mp.push_str(name_str(p, od.module as usize, unsafe (*oa).list(parts)[i as usize]));
                }
                let mid = p.find(mp.as_str());
                if mid >= 0 {
                    comp_module_publics(p, mid as usize, &mut out);
                }
                return out;
            }
        }
    }
    // a value receiver: its type, references/pointers peeled, names the aggregate
    if mo as usize >= unsafe (*a).types.len() {
        return out;
    }
    let mut t = unsafe (*a).type_of(mo);
    let mut guard = 0;
    while t != TYPE_NONE && guard < 8 {
        let y = *unsafe (*a).type_at(t);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            t = y.as_data.elem;
            guard += 1;
            continue;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            comp_aggregate(p, y.module as usize, y.as_data.decl, &mut out);
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            comp_aggregate(p, it.module as usize, it.decl, &mut out);
        }
        break;
    }
    return out;
}

/// Keywords + builtin type names alone -- the floor every general completion includes, and the
/// fallback when no build (not even a probe build) parses the buffer.
pub fn complete_keywords() Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    let kws = "as do fn if in dyn for let mut new pub case else enum loop move null self Self true type break const defer false union where while extend extern import launch return select static struct switch sizeof unsafe alignof continue interface static_assert";
    let mut it = kws.split(" ");
    loop {
        let w = it.next();
        if w.is_none() {
            break;
        }
        comp_push(&mut out, w.unwrap(), 14, String::new());
    }
    for b in 0..BuiltinType::BT_COUNT as i32 {
        comp_push(&mut out, bt_name(b as BuiltinType), 14, String::new());
    }
    return out;
}

/// General identifier completion from the last good build: keywords, builtin type names, the module's
/// own top-level declarations, import aliases, prelude publics, and locals in scope (the enclosing
/// function's parameters and earlier bindings).
pub fn complete_general(p: &loader::Package, mi: usize, off: u32) Vector<CompItem> {
    let mut out = complete_keywords();
    let a = mod_ast(p, mi);
    if p.modules.at(mi).has_ast {
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            let n = unsafe (*a).at_const(iid);
            if n.kind == NodeKind::NODE_FUNCTION {
                comp_push(
                    &mut out,
                    name_str(p, mi, n.as_data.function.name),
                    3,
                    decl_signature(p, DefId { module: mi as ModuleId, node: iid }),
                );
            } else if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
                let mut kind = 22;
                if n.kind == NodeKind::NODE_ENUM {
                    kind = 13;
                }
                comp_push(&mut out, name_str(p, mi, n.as_data.aggregate.name), kind, String::new());
            } else if n.kind == NodeKind::NODE_CONST {
                comp_push(&mut out, name_str(p, mi, n.as_data.const_def.name), 21, String::new());
            } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
                comp_push(&mut out, name_str(p, mi, n.as_data.type_alias.name), 7, String::new());
            } else if n.kind == NodeKind::NODE_INTERFACE {
                comp_push(&mut out, name_str(p, mi, n.as_data.interface_def.name), 8, String::new());
            } else if n.kind == NodeKind::NODE_IMPORT {
                let alias = n.as_data.import_decl.alias;
                let parts = n.as_data.import_decl.path;
                let mut nm = alias;
                if nm == NODE_NONE && parts.len > 0 {
                    nm = unsafe (*a).list(parts)[(parts.len - 1) as usize];
                }
                if nm != NODE_NONE {
                    comp_push(&mut out, name_str(p, mi, nm), 9, String::new());
                }
            }
        }
        // locals: the enclosing function's params + bindings declared before the cursor
        let nn = unsafe (*a).nodes.len();
        let mut fnode: NodeId = NODE_NONE;
        let mut flen: u32 = 0xFFFFFFFF;
        for i in 1..nn {
            let nd = unsafe (*a).at_const(i as NodeId);
            if nd.kind == NodeKind::NODE_FUNCTION && nd.span.start <= off && off < nd.span.end && nd.span.end - nd.span.start < flen {
                fnode = i as NodeId;
                flen = nd.span.end - nd.span.start;
            }
        }
        if fnode != NODE_NONE {
            let fsp = unsafe (*a).at_const(fnode).span;
            let ps = unsafe (*a).at_const(fnode).as_data.function.params;
            for i in 0..ps.len {
                let pid = unsafe (*a).list(ps)[i as usize];
                let nm = unsafe (*a).at_const(pid).as_data.parameter.name;
                if nm != NODE_NONE {
                    comp_push(&mut out, name_str(p, mi, nm), 6, String::new());
                }
            }
            for i in 1..nn {
                let nd = unsafe (*a).at_const(i as NodeId);
                let inside = nd.span.start >= fsp.start && nd.span.start < off;
                if !inside {
                    continue;
                }
                if nd.kind == NodeKind::NODE_LET && nd.as_data.let_stmt.name != NODE_NONE {
                    comp_push(&mut out, name_str(p, mi, nd.as_data.let_stmt.name), 6, String::new());
                } else if nd.kind == NodeKind::NODE_PATTERN_NAME {
                    comp_push(&mut out, name_str(p, mi, i as NodeId), 6, String::new());
                }
            }
        }
    }
    for mm in 0..p.modules.len() {
        if p.modules.at(mm).prelude {
            comp_module_publics(p, mm, &mut out);
        }
    }
    return out;
}
