// Positional LSP queries over a built package: hover (rendered type + declaration signature),
// go-to-definition, and find-references/rename spans. All package-scoped -- the server maps modules to
// URIs and byte spans to LSP ranges. Queries read the semantic tables the typechecker left on each
// module's Ast (`types`, `resolutions`); nothing here mutates the package.
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;
import typechecker::typechecker as tc;
import ast::parser as par;

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
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let sp = a.at_const(i as NodeId).span;
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
    let n = a.at_const(id);
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
    let mut nn = a.resolutions_len();
    if unsafe a.nodes.len() < nn {
        nn = unsafe a.nodes.len();
    }
    for i in 1..nn {
        let sp = a.at_const(i as NodeId).span;
        if sp.start <= off && off < sp.end && sp.end - sp.start <= blen {
            let d = a.resolution_def(i as NodeId);
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
        let n = unsafe a.nodes.len();
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
    let n = da.at_const(d.node);
    let s = n.span.start;
    let mut e = n.span.end;
    if n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.body != NODE_NONE {
        e = da.at_const(n.as_data.function.body).span.start;
    } else if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
        e = da.at_const(n.as_data.aggregate.name).span.end;
    } else if n.kind == NodeKind::NODE_INTERFACE {
        e = da.at_const(n.as_data.interface_def.name).span.end;
    } else if n.kind == NodeKind::NODE_LET {
        e = da.at_const(n.as_data.let_stmt.name).span.end;
        if n.as_data.let_stmt.ty != NODE_NONE {
            e = da.at_const(n.as_data.let_stmt.ty).span.end;
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
    let sp = da.at_const(d.node).span;
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
    if id as usize < unsafe a.types.len() {
        t = a.type_of(id);
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
        let doc = decl_doc(p, d);
        if doc.len() != 0 {
            out.push_str("\n\n");
            out.push_string(&doc);
        }
    }
    if out.len() == 0 {
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
    let mut sp = da.at_const(d.node).span;
    let nm = decl_name(da, d.node);
    if nm != NODE_NONE {
        sp = da.at_const(nm).span;
    }
    return Option::<Loc>::Some(Loc { module: d.module, start: sp.start, end: sp.end });
}

// The span rename/references should touch for a resolved node: a path member or type path narrows to
// its final NAME segment (replacing the whole `util::Point` span would eat the qualifier).
const fn ref_span(a: *const Ast, i: NodeId) tok::Span {
    let n = a.at_const(i);
    if n.kind == NodeKind::NODE_MEMBER {
        return a.at_const(n.as_data.member.member).span;
    }
    if n.kind == NodeKind::NODE_TYPE_PATH {
        let parts = n.as_data.type_path.parts;
        if parts.len > 0 {
            return a.at_const(unsafe a.list(parts)[(parts.len - 1) as usize]).span;
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
        let mut nn = am.resolutions_len();
        if unsafe am.nodes.len() < nn {
            nn = unsafe am.nodes.len();
        }
        for i in 1..nn {
            let r = am.resolution_def(i as NodeId);
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
            let sp = da.at_const(nm).span;
            out.push(Loc { module: d.module, start: sp.start, end: sp.end });
        }
    }
    return out;
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

// A method is a function declared inside an `extend` block. The first parameter's SOURCE SPELLING
// being `self` is checked as an assertion of the same fact, not inferred from its length.
// Per-request cache for method classification: one extend-membership bitset per touched module,
// so semantic tokens pay one item scan per module instead of one per token.
struct MethodCache {
    pub mods: Vector<u32>,
    pub sets: Vector<Vector<bool>>,
}

fn fn_is_method(p: &loader::Package, dm: usize, id: NodeId, mc: &mut MethodCache) bool {
    let mut slot = mc.mods.len();
    for i in 0..mc.mods.len() {
        if *mc.mods.at(i) == dm as u32 {
            slot = i;
        }
    }
    if slot == mc.mods.len() {
        let a = mod_ast(p, dm);
        let mut set = Vector::<bool>::new();
        set.resize_default(unsafe a.nodes.len());
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let eis = a.at_const(iid).as_data.extend_def.items;
            for k in 0..eis.len {
                let eid = unsafe a.list(eis)[k as usize];
                if a.at_const(eid).kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let ps = a.at_const(eid).as_data.function.params;
                // an associated fn (constructor-shaped) still renders as a method
                let mut m = true;
                if ps.len > 0 {
                    let p0 = unsafe a.list(ps)[0];
                    m = name_str(p, dm, a.at_const(p0).as_data.parameter.name) == "self";
                }
                set[eid as usize] = m;
            }
        }
        mc.mods.push(dm as u32);
        mc.sets.push(set);
    }
    return *mc.sets.at(slot).at(id as usize);
}

// Legend index for a resolved declaration; -1 = unclassified (skip the token).
fn token_type_of(p: &loader::Package, d: DefId, mc: &mut MethodCache) i32 {
    let da = mod_ast(p, d.module as usize);
    let n = da.at_const(d.node);
    if n.kind == NodeKind::NODE_FUNCTION {
        if fn_is_method(p, d.module as usize, d.node, mc) {
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
    // duplicates (a member and its name node classifying the same span) are removed after the sort
    out.push(Tok { start: start, end: end, ty: ty, mods: mods });
}

const fn tok_cmp(a: &Tok, b: &Tok) i32 {
    if a.start != b.start {
        if a.start < b.start {
            return -1;
        }
        return 1;
    }
    if a.end != b.end {
        if a.end < b.end {
            return -1;
        }
        return 1;
    }
    return 0;
}

/// Every classifiable token in module `mi`: resolved references (through their name spans) plus each
/// declaration's own name (with the `declaration` modifier). Sorted by start offset.
pub fn semantic_tokens(p: &loader::Package, mi: usize) Vector<Tok> {
    let a = mod_ast(p, mi);
    let mut out = Vector::<Tok>::new();
    let mut mc = MethodCache { mods: Vector::<u32>::new(), sets: Vector::<Vector<bool>>::new() };
    let mut nn = a.resolutions_len();
    if unsafe a.nodes.len() < nn {
        nn = unsafe a.nodes.len();
    }
    for i in 1..nn {
        let d = a.resolution_def(i as NodeId);
        if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
            continue;
        }
        let sp = ref_span(a, i as NodeId);
        let mut mods: u32 = 0;
        let dk = mod_ast(p, d.module as usize).at_const(d.node).kind;
        if dk == NodeKind::NODE_CONST {
            mods = 2; // readonly
        }
        tok_push(&mut out, sp.start, sp.end, token_type_of(p, d, &mut mc), mods);
    }
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let nm = decl_name(a, i as NodeId);
        if nm == NODE_NONE || nm == i as NodeId {
            continue;
        }
        let sp = a.at_const(nm).span;
        let mut mods: u32 = 1; // declaration
        if a.at_const(i as NodeId).kind == NodeKind::NODE_CONST {
            mods = 3;
        }
        tok_push(
            &mut out,
            sp.start,
            sp.end,
            token_type_of(p, DefId { module: mi as ModuleId, node: i as NodeId }, &mut mc),
            mods,
        );
    }
    out.sort_by(tok_cmp);
    // one pass over the sorted list removes the duplicate spans -- O(n log n) total, never quadratic
    let mut w: usize = 0;
    for i in 0..out.len() {
        if w != 0 && out.at(w - 1).start == out.at(i).start && out.at(w - 1).end == out.at(i).end {
            continue;
        }
        let t = *out.at(i);
        out.set(w, t);
        w += 1;
    }
    out.truncate(w);
    return out;
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
        return;
    }
    for k in 0..out.len() {
        if out.at(k).label.as_str() == label {
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
    let k = a.at_const(name_node).kind;
    if k != NodeKind::NODE_IDENTIFIER && k != NodeKind::NODE_PATTERN_NAME {
        return "";
    }
    let sp = a.at_const(name_node).as_data.name.text;
    let src = p.modules.at(m).source.as_str();
    if sp.start > sp.end || sp.end as usize > src.len() {
        return "";
    }
    return src.slice(sp.start as usize, sp.end as usize);
}

// Fields and methods of the aggregate decl (dm, dn): fields from its member list, methods from every
// module's `extend` blocks whose target resolves to it. `req_mod` is the module the request came
// from: private fields and methods are offered only inside their owning module.
fn comp_aggregate(p: &loader::Package, dm: usize, dn: NodeId, req_mod: usize, out: &mut Vector<CompItem>) {
    let da = mod_ast(p, dm);
    let n = da.at_const(dn);
    if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe da.list(ms)[i as usize];
            let mk = da.at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD {
                if !da.at_const(mid).as_data.field.is_public && dm != req_mod {
                    continue;
                }
                let d = decl_signature(p, DefId { module: dm as ModuleId, node: mid });
                comp_push(out, name_str(p, dm, da.at_const(mid).as_data.field.name), 5, d);
            }
        }
    }
    for mm in 0..p.modules.len() {
        let am = mod_ast(p, mm);
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let items = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe am.list(items)[i as usize];
            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let tgt = am.at_const(iid).as_data.extend_def.target_type;
            if tgt == NODE_NONE || tgt as usize >= am.resolutions_len() {
                continue;
            }
            let td = am.resolution_def(tgt);
            if td.module as usize != dm || td.node != dn {
                continue;
            }
            let eis = am.at_const(iid).as_data.extend_def.items;
            for k in 0..eis.len {
                let fid = unsafe am.list(eis)[k as usize];
                if am.at_const(fid).kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                if !am.at_const(fid).as_data.function.is_public && mm != req_mod {
                    continue;
                }
                let sig = decl_signature(p, DefId { module: mm as ModuleId, node: fid });
                comp_push(out, name_str(p, mm, am.at_const(fid).as_data.function.name), 2, sig);
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
    let items = unsafe am.at_const(am.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe am.list(items)[i as usize];
        let n = am.at_const(iid);
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
    let n = unsafe a.nodes.len();
    for i in 1..n {
        if a.at_const(i as NodeId).kind != NodeKind::NODE_MEMBER {
            continue;
        }
        let mn = a.at_const(i as NodeId).as_data.member.member;
        if mn == NODE_NONE {
            continue;
        }
        let sp = a.at_const(mn).span;
        if sp.start <= off && off < sp.end {
            mem = i as NodeId;
            break;
        }
    }
    if mem == NODE_NONE {
        return out;
    }
    let mo = a.at_const(mem).as_data.member.object;
    // a path object resolving to an enum or an import: variants / module publics
    if mo as usize < a.resolutions_len() {
        let od = a.resolution_def(mo);
        if od.node != NODE_NONE && od.module as usize < p.modules.len() {
            let oa = mod_ast(p, od.module as usize);
            let ok = oa.at_const(od.node).kind;
            if ok == NodeKind::NODE_ENUM {
                let ms = oa.at_const(od.node).as_data.aggregate.members;
                for i in 0..ms.len {
                    let vid = unsafe oa.list(ms)[i as usize];
                    if oa.at_const(vid).kind == NodeKind::NODE_VARIANT {
                        comp_push(
                            &mut out,
                            name_str(p, od.module as usize, oa.at_const(vid).as_data.variant.name),
                            20,
                            String::new(),
                        );
                    }
                }
                comp_aggregate(p, od.module as usize, od.node, mi, &mut out);
                return out;
            }
            if ok == NodeKind::NODE_IMPORT {
                // resolve the import to its module by the '::'-joined path
                let parts = oa.at_const(od.node).as_data.import_decl.path;
                let mut mp = String::new();
                for i in 0..parts.len {
                    if i != 0 {
                        mp.push_str("::");
                    }
                    mp.push_str(name_str(p, od.module as usize, unsafe oa.list(parts)[i as usize]));
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
    if mo as usize >= unsafe a.types.len() {
        return out;
    }
    let mut t = a.type_of(mo);
    let mut guard = 0;
    while t != TYPE_NONE && guard < 8 {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            t = y.as_data.elem;
            guard += 1;
            continue;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            comp_aggregate(p, y.module as usize, y.as_data.decl, mi, &mut out);
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            comp_aggregate(p, it.module as usize, it.decl, mi, &mut out);
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
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            let n = a.at_const(iid);
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
                    nm = unsafe a.list(parts)[(parts.len - 1) as usize];
                }
                if nm != NODE_NONE {
                    comp_push(&mut out, name_str(p, mi, nm), 9, String::new());
                }
            }
        }
        // locals, lexically scoped: the enclosing function's parameters, plus each binder whose
        // OWN scope contains the cursor -- a `let` from its statement to its enclosing block's end,
        // a pattern name within its match arm / for loop / closure, a closure parameter within the
        // closure. Bindings from closed or sibling scopes are never offered.
        let nn = unsafe a.nodes.len();
        let mut fnode: NodeId = NODE_NONE;
        let mut flen: u32 = 0xFFFFFFFF;
        for i in 1..nn {
            let nd = a.at_const(i as NodeId);
            if nd.kind == NodeKind::NODE_FUNCTION && nd.span.start <= off && off < nd.span.end && nd.span.end - nd.span.start < flen {
                fnode = i as NodeId;
                flen = nd.span.end - nd.span.start;
            }
        }
        if fnode != NODE_NONE {
            let ps = a.at_const(fnode).as_data.function.params;
            for i in 0..ps.len {
                let pid = unsafe a.list(ps)[i as usize];
                let nm = a.at_const(pid).as_data.parameter.name;
                if nm != NODE_NONE {
                    comp_push(&mut out, name_str(p, mi, nm), 6, String::new());
                }
            }
            let fsp = a.at_const(fnode).span;
            for i in 1..nn {
                let nd = a.at_const(i as NodeId);
                if nd.span.start < fsp.start || nd.span.end > fsp.end {
                    continue;
                }
                if nd.kind == NodeKind::NODE_LET && nd.as_data.let_stmt.name != NODE_NONE {
                    if nd.span.start < off && binder_scope_has(a, nd.span.start, off) {
                        comp_push(&mut out, name_str(p, mi, nd.as_data.let_stmt.name), 6, String::new());
                    }
                } else if nd.kind == NodeKind::NODE_PATTERN_NAME {
                    if pattern_scope_has(a, i as NodeId, off) {
                        comp_push(&mut out, name_str(p, mi, i as NodeId), 6, String::new());
                    }
                } else if nd.kind == NodeKind::NODE_CLOSURE {
                    if nd.span.start <= off && off < nd.span.end {
                        let cps = nd.as_data.closure.params;
                        for k in 0..cps.len {
                            let pid = unsafe a.list(cps)[k as usize];
                            if a.at_const(pid).kind == NodeKind::NODE_PARAMETER {
                                let nm = a.at_const(pid).as_data.parameter.name;
                                if nm != NODE_NONE {
                                    comp_push(&mut out, name_str(p, mi, nm), 6, String::new());
                                }
                            }
                        }
                    }
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

// ---------------------------------------------------------------------------------------------------------
// Lexical scope helpers for completion.
// ---------------------------------------------------------------------------------------------------------

// True when the innermost block containing a binder declared at `decl_start` also contains `off`:
// the `let`-binding visibility rule (from its statement to its block's closing brace).
fn binder_scope_has(a: *const Ast, decl_start: u32, off: u32) bool {
    let mut best: u32 = 0xFFFFFFFF;
    let mut bs: u32 = 0;
    let mut be: u32 = 0;
    let n = unsafe a.nodes.len();
    for i in 1..n {
        if a.at_const(i as NodeId).kind != NodeKind::NODE_BLOCK {
            continue;
        }
        let sp = a.at_const(i as NodeId).span;
        if sp.start <= decl_start && decl_start < sp.end && sp.end - sp.start < best {
            best = sp.end - sp.start;
            bs = sp.start;
            be = sp.end;
        }
    }
    if best == 0xFFFFFFFF {
        return false;
    }
    return bs <= off && off < be;
}

// The scope of a pattern binder: its match arm, for loop, or closure when one encloses it (that
// node's whole span), else the let rule against its enclosing block.
fn pattern_scope_has(a: *const Ast, pid: NodeId, off: u32) bool {
    let psp = a.at_const(pid).span;
    let mut best: u32 = 0xFFFFFFFF;
    let mut owner: NodeId = NODE_NONE;
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let k = a.at_const(i as NodeId).kind;
        let scoped = k == NodeKind::NODE_MATCH_ARM || k == NodeKind::NODE_FOR || k == NodeKind::NODE_INLINE_FOR || k == NodeKind::NODE_PARALLEL_FOR || k == NodeKind::NODE_CLOSURE;
        if !scoped {
            continue;
        }
        let sp = a.at_const(i as NodeId).span;
        if sp.start <= psp.start && psp.end <= sp.end && sp.end - sp.start < best {
            best = sp.end - sp.start;
            owner = i as NodeId;
        }
    }
    if owner != NODE_NONE {
        let sp = a.at_const(owner).span;
        return sp.start <= off && off < sp.end;
    }
    return psp.start < off && binder_scope_has(a, psp.start, off);
}

// ---------------------------------------------------------------------------------------------------------
// Attribute completion (the parser's inventory is the single source of truth).
// ---------------------------------------------------------------------------------------------------------

/// Every attribute the parser accepts, spelled as typed after `@`.
pub fn complete_attributes() Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    let mut names = Vector::<String>::new();
    par::known_attributes(&mut names);
    for i in 0..names.len() {
        comp_push(&mut out, names.at(i).as_str(), 14, String::from_str("attribute"));
    }
    return out;
}

/// Identifiers valid inside `@platform(...)`.
pub fn complete_platform_args() Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    let mut names = Vector::<String>::new();
    par::platform_arg_names(&mut names);
    for i in 0..names.len() {
        comp_push(&mut out, names.at(i).as_str(), 14, String::from_str("platform"));
    }
    return out;
}

/// Identifiers valid inside `@arch(...)`.
pub fn complete_arch_args() Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    let mut names = Vector::<String>::new();
    par::arch_arg_names(&mut names);
    for i in 0..names.len() {
        comp_push(&mut out, names.at(i).as_str(), 14, String::from_str("architecture"));
    }
    return out;
}

/// Interface names visible from module `mi` (for `@derive(...)` arguments): the module's own
/// interfaces plus public interfaces of the prelude and of every imported module.
pub fn complete_interfaces(p: &loader::Package, mi: usize) Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    if !p.modules.at(mi).has_ast {
        return out;
    }
    let a = mod_ast(p, mi);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_INTERFACE {
            comp_push(&mut out, name_str(p, mi, a.at_const(iid).as_data.interface_def.name), 8, String::new());
        }
    }
    let mut visible = Vector::<bool>::new();
    visible.resize_default(p.modules.len());
    for mm in 0..p.modules.len() {
        if p.modules.at(mm).prelude {
            visible[mm] = true;
        }
    }
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind != NodeKind::NODE_IMPORT {
            continue;
        }
        let path = loader::join_parts(
            unsafe &*a,
            p.modules.at(mi).source.as_str(),
            a.at_const(iid).as_data.import_decl.path,
            "::",
        );
        let target = p.find(path.as_str());
        if target >= 0 {
            visible[target as usize] = true;
        }
    }
    for mm in 0..p.modules.len() {
        if mm == mi || !p.modules.at(mm).has_ast || !visible[mm] {
            continue;
        }
        let am = mod_ast(p, mm);
        let its = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..its.len {
            let iid = unsafe am.list(its)[i as usize];
            if am.at_const(iid).kind == NodeKind::NODE_INTERFACE && am.at_const(iid).as_data.interface_def.is_public {
                comp_push(&mut out, name_str(p, mm, am.at_const(iid).as_data.interface_def.name), 8, String::new());
            }
        }
    }
    return out;
}

/// Module paths for `import` completion: every module the package knows, "::"-joined.
pub fn complete_import_paths(p: &loader::Package) Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    for mm in 0..p.modules.len() {
        let path = p.modules.at(mm).path.as_str();
        if path.len() != 0 {
            comp_push(&mut out, path, 9, String::new());
        }
    }
    return out;
}

/// Loop labels of the function enclosing `off` (for `'label` completion after a quote).
pub fn complete_labels(p: &loader::Package, mi: usize, off: u32) Vector<CompItem> {
    let mut out = Vector::<CompItem>::new();
    if !p.modules.at(mi).has_ast {
        return out;
    }
    let a = mod_ast(p, mi);
    let src = p.modules.at(mi).source.as_str();
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        let mut lab = tok::Span::empty();
        if nd.kind == NodeKind::NODE_WHILE {
            lab = nd.as_data.while_stmt.label;
        } else if nd.kind == NodeKind::NODE_FOR || nd.kind == NodeKind::NODE_INLINE_FOR || nd.kind == NodeKind::NODE_PARALLEL_FOR {
            lab = nd.as_data.for_stmt.label;
        } else {
            continue;
        }
        if lab.end <= lab.start || !(nd.span.start <= off && off < nd.span.end) {
            continue;
        }
        if lab.end as usize <= src.len() {
            let mut s = lab.start as usize;
            if src[s] == b'\'' {
                s += 1; // the token span includes the quote; the user already typed it
            }
            comp_push(&mut out, src.slice(s, lab.end as usize), 14, String::from_str("label"));
        }
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------
// Navigation queries: document symbols, workspace symbols, signature help, highlights, type
// definition, implementations, folding, selection ranges, inlay hints.
// ---------------------------------------------------------------------------------------------------------

/// One document symbol; `parent` indexes the owning symbol in the same vector (-1 = top level).
pub struct Sym {
    pub name: String,
    pub detail: String,
    pub kind: i32, // LSP SymbolKind
    pub start: u32,
    pub end: u32,
    pub sel_start: u32,
    pub sel_end: u32,
    pub parent: i32,
}

extend Sym as Free {
    pub fn free(self: &mut Self) {
        self.name.free();
        self.detail.free();
    }
}

fn sym_push(p: &loader::Package, mi: usize, out: &mut Vector<Sym>, id: NodeId, nm: NodeId, kind: i32, parent: i32) i32 {
    let a = mod_ast(p, mi);
    let name = name_str(p, mi, nm);
    if name.len() == 0 {
        return -1;
    }
    let sp = a.at_const(id).span;
    let nsp = a.at_const(nm).span;
    out.push(
        Sym {
            name: String::from_str(name),
            detail: decl_signature(p, DefId { module: mi as ModuleId, node: id }),
            kind: kind,
            start: sp.start,
            end: sp.end,
            sel_start: nsp.start,
            sel_end: nsp.end,
            parent: parent,
        },
    );
    return out.len() as i32 - 1;
}

/// The module's symbol tree in source order (functions, types with their fields/variants,
/// interfaces with their methods, extends with their methods, consts, aliases).
pub fn document_symbols(p: &loader::Package, mi: usize) Vector<Sym> {
    let mut out = Vector::<Sym>::new();
    if !p.modules.at(mi).has_ast {
        return out;
    }
    let a = mod_ast(p, mi);
    let src = p.modules.at(mi).source.as_str();
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        let n = a.at_const(iid);
        if n.kind == NodeKind::NODE_FUNCTION {
            sym_push(p, mi, &mut out, iid, n.as_data.function.name, 12, -1);
        } else if n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM {
            let mut kind = 23;
            if n.kind == NodeKind::NODE_ENUM {
                kind = 10;
            }
            let me = sym_push(p, mi, &mut out, iid, n.as_data.aggregate.name, kind, -1);
            if me >= 0 {
                let ms = n.as_data.aggregate.members;
                for k in 0..ms.len {
                    let mid = unsafe a.list(ms)[k as usize];
                    let mk = a.at_const(mid).kind;
                    if mk == NodeKind::NODE_FIELD {
                        sym_push(p, mi, &mut out, mid, a.at_const(mid).as_data.field.name, 8, me);
                    } else if mk == NodeKind::NODE_VARIANT {
                        sym_push(p, mi, &mut out, mid, a.at_const(mid).as_data.variant.name, 22, me);
                    }
                }
            }
        } else if n.kind == NodeKind::NODE_INTERFACE {
            let me = sym_push(p, mi, &mut out, iid, n.as_data.interface_def.name, 11, -1);
            if me >= 0 {
                let ms = n.as_data.interface_def.items;
                for k in 0..ms.len {
                    let mid = unsafe a.list(ms)[k as usize];
                    if a.at_const(mid).kind == NodeKind::NODE_FUNCTION {
                        sym_push(p, mi, &mut out, mid, a.at_const(mid).as_data.function.name, 6, me);
                    }
                }
            }
        } else if n.kind == NodeKind::NODE_EXTEND {
            // name the extend by its target's source text ("extend Vector as Free")
            let tgt = n.as_data.extend_def.target_type;
            let mut label = String::from_str("extend");
            if tgt != NODE_NONE {
                let tsp = a.at_const(tgt).span;
                if tsp.end as usize <= src.len() && tsp.start < tsp.end {
                    label.push_byte(b' ');
                    label.push_str(src.slice(tsp.start as usize, tsp.end as usize));
                }
            }
            out.push(
                Sym {
                    name: label,
                    detail: String::new(),
                    kind: 3,
                    start: n.span.start,
                    end: n.span.end,
                    sel_start: n.span.start,
                    sel_end: n.span.start + 6,
                    parent: -1,
                },
            );
            let me = out.len() as i32 - 1;
            let ms = n.as_data.extend_def.items;
            for k in 0..ms.len {
                let mid = unsafe a.list(ms)[k as usize];
                if a.at_const(mid).kind == NodeKind::NODE_FUNCTION {
                    sym_push(p, mi, &mut out, mid, a.at_const(mid).as_data.function.name, 6, me);
                }
            }
        } else if n.kind == NodeKind::NODE_CONST {
            sym_push(p, mi, &mut out, iid, n.as_data.const_def.name, 14, -1);
        } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
            sym_push(p, mi, &mut out, iid, n.as_data.type_alias.name, 5, -1);
        }
    }
    return out;
}

/// One workspace-symbol hit.
pub struct WsSym {
    pub name: String,
    pub kind: i32,
    pub module: u32,
    pub start: u32,
    pub end: u32,
}

extend WsSym as Free {
    pub fn free(self: &mut Self) {
        self.name.free();
    }
}

const fn ascii_low(b: u8) u8 {
    if b >= b'A' && b <= b'Z' {
        return b + 32;
    }
    return b;
}

// Case-insensitive substring match (an empty query matches everything).
fn fuzzy_has(name: str, q: str) bool {
    if q.len() == 0 {
        return true;
    }
    if q.len() > name.len() {
        return false;
    }
    for i in 0..name.len() - q.len() + 1 {
        let mut hit = true;
        for k in 0..q.len() {
            if ascii_low(name[i + k]) != ascii_low(q[k]) {
                hit = false;
            }
        }
        if hit {
            return true;
        }
    }
    return false;
}

/// Top-level declarations (and extend methods) across the whole package matching `query`, bounded
/// by `cap` results.
pub fn workspace_symbols(p: &loader::Package, query: str, cap: usize, out: &mut Vector<WsSym>) {
    for mm in 0..p.modules.len() {
        if out.len() >= cap {
            return;
        }
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let syms = document_symbols(p, mm);
        for i in 0..syms.len() {
            if out.len() >= cap {
                break;
            }
            let s = syms.at(i);
            if fuzzy_has(s.name.as_str(), query) {
                out.push(
                    WsSym { name: s.name.clone(), kind: s.kind, module: mm as u32, start: s.sel_start, end: s.sel_end },
                );
            }
        }
    }
}

/// Signature help for the innermost call containing `off`.
pub struct SigInfo {
    pub label: String,
    pub params: Vector<String>,
    pub active: i32,
}

extend SigInfo as Free {
    pub fn free(self: &mut Self) {
        self.label.free();
        self.params.free();
    }
}

pub fn signature_help(p: &loader::Package, mi: usize, off: u32) Option<SigInfo> {
    let a = mod_ast(p, mi);
    let mut call: NodeId = NODE_NONE;
    let mut blen: u32 = 0xFFFFFFFF;
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        if nd.kind != NodeKind::NODE_CALL {
            continue;
        }
        if nd.span.start <= off && off <= nd.span.end && nd.span.end - nd.span.start <= blen {
            call = i as NodeId;
            blen = nd.span.end - nd.span.start;
        }
    }
    if call == NODE_NONE {
        return Option::<SigInfo>::None;
    }
    let callee = a.at_const(call).as_data.call.callee;
    if callee as usize >= a.resolutions_len() {
        return Option::<SigInfo>::None;
    }
    let d = a.resolution_def(callee);
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return Option::<SigInfo>::None;
    }
    let da = mod_ast(p, d.module as usize);
    if da.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
        return Option::<SigInfo>::None;
    }
    let dsrc = p.modules.at(d.module as usize).source.as_str();
    let mut params = Vector::<String>::new();
    let ps = da.at_const(d.node).as_data.function.params;
    let mut skip_self = false;
    if ps.len > 0 && a.at_const(callee).kind == NodeKind::NODE_MEMBER {
        let p0 = unsafe da.list(ps)[0];
        if name_str(p, d.module as usize, da.at_const(p0).as_data.parameter.name) == "self" {
            skip_self = true; // the receiver is not an argument slot
        }
    }
    for i in 0..ps.len {
        if i == 0 && skip_self {
            continue;
        }
        let pid = unsafe da.list(ps)[i as usize];
        let sp = da.at_const(pid).span;
        if sp.start < sp.end && sp.end as usize <= dsrc.len() {
            params.push(String::from_str(dsrc.slice(sp.start as usize, sp.end as usize)));
        }
    }
    let args = a.at_const(call).as_data.call.args;
    let mut active: i32 = 0;
    for i in 0..args.len {
        let asp = a.at_const(unsafe a.list(args)[i as usize]).span;
        if asp.end < off {
            active += 1;
        }
    }
    if params.len() != 0 && active as usize >= params.len() {
        active = params.len() as i32 - 1;
    }
    return Option::<SigInfo>::Some(SigInfo { label: decl_signature(p, d), params: params, active: active });
}

/// All same-document reference spans for the symbol under `off` (document highlights).
pub fn document_highlights(p: &loader::Package, mi: usize, off: u32) Vector<Loc> {
    let all = references(p, mi, off, true);
    let mut out = Vector::<Loc>::new();
    for i in 0..all.len() {
        if all.at(i).module as usize == mi {
            out.push(*all.at(i));
        }
    }
    return out;
}

/// The declaration of the TYPE of the expression under `off` (references and pointers peeled).
pub fn type_definition(p: &loader::Package, mi: usize, off: u32) Option<Loc> {
    let a = mod_ast(p, mi);
    let id = node_at_or_before(a, off);
    if id == NODE_NONE || id as usize >= unsafe a.types.len() {
        return Option::<Loc>::None;
    }
    let mut t = a.type_of(id);
    let mut guard = 0;
    while t != TYPE_NONE && guard < 8 {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            t = y.as_data.elem;
            guard += 1;
            continue;
        }
        let mut dm: usize = 0;
        let mut dn: NodeId = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dm = y.module as usize;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            dm = it.module as usize;
            dn = it.decl;
        }
        if dn == NODE_NONE || dm >= p.modules.len() {
            return Option::<Loc>::None;
        }
        let da = mod_ast(p, dm);
        let nm = decl_name(da, dn);
        let mut sp = da.at_const(dn).span;
        if nm != NODE_NONE {
            sp = da.at_const(nm).span;
        }
        return Option::<Loc>::Some(Loc { module: dm as u32, start: sp.start, end: sp.end });
    }
    return Option::<Loc>::None;
}

// The interface declaration owning method `fnid` in module `im`, or NODE_NONE.
fn owning_interface(p: &loader::Package, im: usize, fnid: NodeId) NodeId {
    let a = mod_ast(p, im);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind != NodeKind::NODE_INTERFACE {
            continue;
        }
        let ms = a.at_const(iid).as_data.interface_def.items;
        for k in 0..ms.len {
            if unsafe a.list(ms)[k as usize] == fnid {
                return iid;
            }
        }
    }
    return NODE_NONE;
}

/// Implementations of the interface (or interface method) under `off`: for an interface, every
/// conforming `extend ... as I` block's target span; for one of its methods, each conformer's method.
pub fn implementations(p: &loader::Package, mi: usize, off: u32) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    let d = def_at(p, mi, off);
    if d.node == NODE_NONE {
        return out;
    }
    let dm = d.module as usize;
    let da = mod_ast(p, dm);
    let dk = da.at_const(d.node).kind;
    let mut iface = DefId { module: 0, node: NODE_NONE };
    let mut method_name = "";
    if dk == NodeKind::NODE_INTERFACE {
        iface = d;
    } else if dk == NodeKind::NODE_FUNCTION {
        let own = owning_interface(p, dm, d.node);
        if own == NODE_NONE {
            return out;
        }
        iface = DefId { module: d.module, node: own };
        method_name = name_str(p, dm, da.at_const(d.node).as_data.function.name);
    } else {
        return out;
    }
    for mm in 0..p.modules.len() {
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let am = mod_ast(p, mm);
        let items = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe am.list(items)[i as usize];
            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let it = am.at_const(iid).as_data.extend_def.interface_type;
            if it == NODE_NONE || it as usize >= am.resolutions_len() {
                continue;
            }
            let idf = am.resolution_def(it);
            if idf.module != iface.module || idf.node != iface.node {
                continue;
            }
            if method_name.len() == 0 {
                let tgt = am.at_const(iid).as_data.extend_def.target_type;
                let sp = if tgt != NODE_NONE {
                    am.at_const(tgt).span;
                } else {
                    am.at_const(iid).span;
                };
                out.push(Loc { module: mm as u32, start: sp.start, end: sp.end });
            } else {
                let ms = am.at_const(iid).as_data.extend_def.items;
                for k in 0..ms.len {
                    let fid = unsafe am.list(ms)[k as usize];
                    if am.at_const(fid).kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    if name_str(p, mm, am.at_const(fid).as_data.function.name) == method_name {
                        let sp = am.at_const(am.at_const(fid).as_data.function.name).span;
                        out.push(Loc { module: mm as u32, start: sp.start, end: sp.end });
                    }
                }
            }
        }
    }
    return out;
}

/// Foldable spans: multi-line item bodies and blocks, plus runs of full-line comments.
pub fn folding_ranges(p: &loader::Package, mi: usize) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    let src = p.modules.at(mi).source.as_str();
    if p.modules.at(mi).has_ast {
        let a = mod_ast(p, mi);
        let n = unsafe a.nodes.len();
        for i in 1..n {
            let nd = a.at_const(i as NodeId);
            let k = nd.kind;
            let foldable = k == NodeKind::NODE_BLOCK || k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_INTERFACE || k == NodeKind::NODE_EXTEND || k == NodeKind::NODE_MATCH;
            if !foldable {
                continue;
            }
            let mut multiline = false;
            let mut q = nd.span.start as usize;
            while q < nd.span.end as usize && q < src.len() {
                if src[q] == b'\n' {
                    multiline = true;
                    break;
                }
                q += 1;
            }
            if multiline {
                out.push(Loc { module: mi as u32, start: nd.span.start, end: nd.span.end });
            }
        }
    }
    // comment runs: two or more consecutive lines whose first token is '//'
    let mut i: usize = 0;
    let mut run_start: i64 = -1;
    let mut run_lines = 0;
    let mut last_end: usize = 0;
    while i < src.len() {
        let mut le = i;
        while le < src.len() && src[le] != b'\n' {
            le += 1;
        }
        let line = src.slice(i, le).trim();
        if line.starts_with("//") {
            if run_start < 0 {
                run_start = i as i64;
                run_lines = 0;
            }
            run_lines += 1;
            last_end = le;
        } else {
            if run_start >= 0 && run_lines >= 2 {
                out.push(Loc { module: mi as u32, start: run_start as u32, end: last_end as u32 });
            }
            run_start = -1;
        }
        i = le + 1;
    }
    if run_start >= 0 && run_lines >= 2 {
        out.push(Loc { module: mi as u32, start: run_start as u32, end: last_end as u32 });
    }
    return out;
}

/// Enclosing-node spans at `off`, innermost first, deduplicated (selection ranges).
pub fn selection_ranges(p: &loader::Package, mi: usize, off: u32) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    if !p.modules.at(mi).has_ast {
        return out;
    }
    let a = mod_ast(p, mi);
    let n = unsafe a.nodes.len();
    let mut spans = Vector::<u64>::new(); // (len << 32 | start), sorted by length
    for i in 1..n {
        let sp = a.at_const(i as NodeId).span;
        if sp.start <= off && off < sp.end {
            spans.push((sp.end - sp.start) as u64 << 32 | sp.start as u64);
        }
    }
    spans.sort();
    let mut prev_s: u32 = 0xFFFFFFFF;
    let mut prev_e: u32 = 0xFFFFFFFF;
    for i in 0..spans.len() {
        if out.len() >= 32 {
            break;
        }
        let v = *spans.at(i);
        let s = (v & 0xFFFFFFFF) as u32;
        let e = s + (v >> 32) as u32;
        if s == prev_s && e == prev_e {
            continue;
        }
        // each range must CONTAIN the previous (LSP requires a strict chain)
        if prev_s != 0xFFFFFFFF && (s > prev_s || e < prev_e) {
            continue;
        }
        out.push(Loc { module: mi as u32, start: s, end: e });
        prev_s = s;
        prev_e = e;
    }
    return out;
}

/// One inlay hint: `label` rendered after byte `off`.
pub struct Hint {
    pub off: u32,
    pub label: String,
}

extend Hint as Free {
    pub fn free(self: &mut Self) {
        self.label.free();
    }
}

/// Type hints for `let` bindings without a written type in [start, end).
pub fn inlay_hints(p: &loader::Package, mi: usize, start: u32, end: u32) Vector<Hint> {
    let mut out = Vector::<Hint>::new();
    if !p.modules.at(mi).has_ast {
        return out;
    }
    let a = mod_ast(p, mi);
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        if nd.kind != NodeKind::NODE_LET {
            continue;
        }
        let ls = nd.as_data.let_stmt;
        if ls.ty != NODE_NONE || ls.value == NODE_NONE || ls.name == NODE_NONE {
            continue;
        }
        if nd.span.start < start || nd.span.start >= end {
            continue;
        }
        if ls.value as usize >= unsafe a.types.len() {
            continue;
        }
        let t = a.type_of(ls.value);
        if t == TYPE_NONE {
            continue;
        }
        let mut buf = HovBuf {};
        tc::render_type_into(p, a, p.modules.at(mi).source.as_str(), t, &mut buf[0], 512);
        let rendered = str::from_cstr(&buf[0]);
        if rendered.len() == 0 || rendered.len() > 60 {
            continue;
        }
        let mut label = String::from_str(": ");
        label.push_str(rendered);
        out.push(Hint { off: a.at_const(ls.name).span.end, label: label });
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------
// Cross-package symbol identity + rename validation. Until the compiler API owns stable symbol ids,
// a definition travels between packages as (defining file, declaration kind, name text) -- the
// documented temporary adapter. Same-name same-kind decls in ONE file cannot collide at top level.
// ---------------------------------------------------------------------------------------------------------

/// The resolved definition under `off` (public wrapper over the internal resolver).
pub fn def_ref(p: &loader::Package, mi: usize, off: u32) DefId {
    return def_at(p, mi, off);
}

/// The defining module's FILE (as the loader spelled it), declaration kind, and name text of `d`.
pub struct SymKey {
    pub file: String,
    pub kind: u8,
    pub name: String,
}

extend SymKey as Free {
    pub fn free(self: &mut Self) {
        self.file.free();
        self.name.free();
    }
}

pub fn sym_key(p: &loader::Package, d: DefId) Option<SymKey> {
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return Option::<SymKey>::None;
    }
    let da = mod_ast(p, d.module as usize);
    let nm = decl_name(da, d.node);
    if nm == NODE_NONE {
        return Option::<SymKey>::None;
    }
    let name = name_str(p, d.module as usize, nm);
    if name.len() == 0 {
        return Option::<SymKey>::None;
    }
    return Option::<SymKey>::Some(
        SymKey {
            file: p.modules.at(d.module as usize).file.clone(),
            kind: da.at_const(d.node).kind as u8,
            name: String::from_str(name),
        },
    );
}

/// The declaration in module `mi` matching (kind, name), or NODE_NONE. The span tiebreak keeps the
/// FIRST (outermost source order) match, which is the declaration itself.
pub fn find_decl_by_key(p: &loader::Package, mi: usize, kind: u8, name: str) NodeId {
    let a = mod_ast(p, mi);
    let n = unsafe a.nodes.len();
    for i in 1..n {
        if a.at_const(i as NodeId).kind as u8 != kind {
            continue;
        }
        let nm = decl_name(a, i as NodeId);
        if nm == NODE_NONE || nm == i as NodeId {
            continue;
        }
        if name_str(p, mi, nm) == name {
            return i as NodeId;
        }
    }
    return NODE_NONE;
}

/// Every reference to definition `d` across the package (the span-narrowed reference sites);
/// `include_decl` appends the declaration's own name span.
pub fn references_of_def(p: &loader::Package, d: DefId, include_decl: bool) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    if d.node == NODE_NONE {
        return out;
    }
    for mm in 0..p.modules.len() {
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let am = mod_ast(p, mm);
        let mut nn = am.resolutions_len();
        if unsafe am.nodes.len() < nn {
            nn = unsafe am.nodes.len();
        }
        for i in 1..nn {
            let r = am.resolution_def(i as NodeId);
            if r.module == d.module && r.node == d.node {
                let sp = ref_span(am, i as NodeId);
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
            let sp = da.at_const(nm).span;
            out.push(Loc { module: d.module, start: sp.start, end: sp.end });
        }
    }
    return out;
}

/// The reference (or declaration-name) span AT the cursor, for prepareRename's editable range.
pub fn cursor_ref_span(p: &loader::Package, mi: usize, off: u32) Option<Loc> {
    let d = def_at(p, mi, off);
    if d.node == NODE_NONE {
        return Option::<Loc>::None;
    }
    let a = mod_ast(p, mi);
    // the narrowed span of the resolved node under the cursor
    let mut best: u32 = 0xFFFFFFFF;
    let mut hit = tok::Span::empty();
    let mut nn = a.resolutions_len();
    if unsafe a.nodes.len() < nn {
        nn = unsafe a.nodes.len();
    }
    for i in 1..nn {
        let r = a.resolution_def(i as NodeId);
        if r.module != d.module || r.node != d.node {
            continue;
        }
        let sp = ref_span(a, i as NodeId);
        if sp.start <= off && off < sp.end && sp.end - sp.start < best {
            best = sp.end - sp.start;
            hit = sp;
        }
    }
    if best == 0xFFFFFFFF && d.module as usize == mi {
        let nm = decl_name(a, d.node);
        if nm != NODE_NONE {
            let sp = a.at_const(nm).span;
            if sp.start <= off && off <= sp.end {
                hit = sp;
                best = 0;
            }
        }
    }
    if best == 0xFFFFFFFF {
        return Option::<Loc>::None;
    }
    return Option::<Loc>::Some(Loc { module: mi as u32, start: hit.start, end: hit.end });
}

// The extend block owning method `fnid` in module `im`, or NODE_NONE.
fn owning_extend(p: &loader::Package, im: usize, fnid: NodeId) NodeId {
    let a = mod_ast(p, im);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
            continue;
        }
        let ms = a.at_const(iid).as_data.extend_def.items;
        for k in 0..ms.len {
            if unsafe a.list(ms)[k as usize] == fnid {
                return iid;
            }
        }
    }
    return NODE_NONE;
}

/// The rename set for `d`: the definition itself plus its interface relations -- an interface
/// method renames its declaration AND every conformer's method; a conformance method renames the
/// interface declaration and the sibling conformances with it.
pub fn related_decls(p: &loader::Package, d: DefId, out: &mut Vector<DefId>) {
    out.push(d);
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return;
    }
    let dm = d.module as usize;
    let da = mod_ast(p, dm);
    if da.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
        return;
    }
    let mut iface = DefId { module: 0, node: NODE_NONE };
    let own_if = owning_interface(p, dm, d.node);
    if own_if != NODE_NONE {
        iface = DefId { module: d.module, node: own_if };
    } else {
        let ext = owning_extend(p, dm, d.node);
        if ext != NODE_NONE {
            let it = da.at_const(ext).as_data.extend_def.interface_type;
            if it != NODE_NONE && it as usize < da.resolutions_len() {
                let idf = da.resolution_def(it);
                if idf.node != NODE_NONE {
                    iface = idf;
                }
            }
        }
    }
    if iface.node == NODE_NONE {
        return;
    }
    let name = name_str(p, dm, da.at_const(d.node).as_data.function.name);
    // the interface's own declaration of this method
    let ia = mod_ast(p, iface.module as usize);
    if ia.at_const(iface.node).kind == NodeKind::NODE_INTERFACE {
        let ms = ia.at_const(iface.node).as_data.interface_def.items;
        for k in 0..ms.len {
            let fid = unsafe ia.list(ms)[k as usize];
            if ia.at_const(fid).kind == NodeKind::NODE_FUNCTION && name_str(
                p,
                iface.module as usize,
                ia.at_const(fid).as_data.function.name,
            ) == name {
                let cand = DefId { module: iface.module, node: fid };
                let mut have = false;
                for q in 0..out.len() {
                    if out.at(q).module == cand.module && out.at(q).node == cand.node {
                        have = true;
                    }
                }
                if !have {
                    out.push(cand);
                }
            }
        }
    }
    // every conformer's method with this name
    for mm in 0..p.modules.len() {
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let am = mod_ast(p, mm);
        let items = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe am.list(items)[i as usize];
            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let it = am.at_const(iid).as_data.extend_def.interface_type;
            if it == NODE_NONE || it as usize >= am.resolutions_len() {
                continue;
            }
            let idf = am.resolution_def(it);
            if idf.module != iface.module || idf.node != iface.node {
                continue;
            }
            let ms = am.at_const(iid).as_data.extend_def.items;
            for k in 0..ms.len {
                let fid = unsafe am.list(ms)[k as usize];
                if am.at_const(fid).kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                if name_str(p, mm, am.at_const(fid).as_data.function.name) != name {
                    continue;
                }
                let cand = DefId { module: mm as ModuleId, node: fid };
                let mut have = false;
                for q in 0..out.len() {
                    if out.at(q).module == cand.module && out.at(q).node == cand.node {
                        have = true;
                    }
                }
                if !have {
                    out.push(cand);
                }
            }
        }
    }
}

// True when `iid` is a top-level item of its module.
fn is_top_level(a: *const Ast, iid: NodeId) bool {
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        if unsafe a.list(items)[i as usize] == iid {
            return true;
        }
    }
    return false;
}

/// Why renaming `d` to `new_name` would break resolution; "" when no conflict is detected.
/// Simulates the lookup that matters for each declaration class: top-level items against their
/// module's item table, fields against their aggregate, methods against the target's method set,
/// locals and parameters against every binder of the enclosing function.
pub fn rename_conflict(p: &loader::Package, d: DefId, new_name: str) String {
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return String::new();
    }
    let dm = d.module as usize;
    let a = mod_ast(p, dm);
    let k = a.at_const(d.node).kind;
    // top-level item: another item of the same module with the new name
    if is_top_level(a, d.node) {
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if iid == d.node {
                continue;
            }
            let nm = decl_name(a, iid);
            if nm != NODE_NONE && name_str(p, dm, nm) == new_name {
                return String::from_str("a declaration with that name already exists in this module");
            }
        }
        return String::new();
    }
    // field: sibling members of the owning aggregate
    if k == NodeKind::NODE_FIELD || k == NodeKind::NODE_VARIANT {
        let n = unsafe a.nodes.len();
        for i in 1..n {
            let nd = a.at_const(i as NodeId);
            if nd.kind != NodeKind::NODE_STRUCT && nd.kind != NodeKind::NODE_ENUM {
                continue;
            }
            let ms = nd.as_data.aggregate.members;
            let mut mine = false;
            for q in 0..ms.len {
                if unsafe a.list(ms)[q as usize] == d.node {
                    mine = true;
                }
            }
            if !mine {
                continue;
            }
            for q in 0..ms.len {
                let mid = unsafe a.list(ms)[q as usize];
                if mid == d.node {
                    continue;
                }
                let nm = decl_name(a, mid);
                if nm != NODE_NONE && name_str(p, dm, nm) == new_name {
                    return String::from_str("a member with that name already exists on this type");
                }
            }
            return String::new();
        }
        return String::new();
    }
    // method in an extend: the target type's other methods (any module)
    if k == NodeKind::NODE_FUNCTION {
        let ext = owning_extend(p, dm, d.node);
        if ext != NODE_NONE {
            let tgt = a.at_const(ext).as_data.extend_def.target_type;
            if tgt != NODE_NONE && tgt as usize < a.resolutions_len() {
                let td = a.resolution_def(tgt);
                if td.node != NODE_NONE {
                    for mm in 0..p.modules.len() {
                        if !p.modules.at(mm).has_ast {
                            continue;
                        }
                        let am = mod_ast(p, mm);
                        let its = unsafe am.at_const(am.root).as_data.program.items;
                        for i in 0..its.len {
                            let iid = unsafe am.list(its)[i as usize];
                            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                                continue;
                            }
                            let t2 = am.at_const(iid).as_data.extend_def.target_type;
                            if t2 == NODE_NONE || t2 as usize >= am.resolutions_len() {
                                continue;
                            }
                            let td2 = am.resolution_def(t2);
                            if td2.module != td.module || td2.node != td.node {
                                continue;
                            }
                            let ms = am.at_const(iid).as_data.extend_def.items;
                            for q in 0..ms.len {
                                let fid = unsafe am.list(ms)[q as usize];
                                if fid == d.node && mm == dm {
                                    continue;
                                }
                                if am.at_const(fid).kind == NodeKind::NODE_FUNCTION && name_str(
                                    p,
                                    mm,
                                    am.at_const(fid).as_data.function.name,
                                ) == new_name {
                                    return String::from_str("a method with that name already exists on this type");
                                }
                            }
                        }
                    }
                }
            }
            return String::new();
        }
    }
    // local binder or parameter: any other binder of the enclosing function
    if k == NodeKind::NODE_LET || k == NodeKind::NODE_PATTERN_NAME || k == NodeKind::NODE_PARAMETER {
        let dsp = a.at_const(d.node).span;
        let n = unsafe a.nodes.len();
        let mut fnode: NodeId = NODE_NONE;
        let mut flen: u32 = 0xFFFFFFFF;
        for i in 1..n {
            let nd = a.at_const(i as NodeId);
            if nd.kind == NodeKind::NODE_FUNCTION && nd.span.start <= dsp.start && dsp.end <= nd.span.end && nd.span.end - nd.span.start < flen {
                fnode = i as NodeId;
                flen = nd.span.end - nd.span.start;
            }
        }
        if fnode != NODE_NONE {
            let fsp = a.at_const(fnode).span;
            for i in 1..n {
                if i as NodeId == d.node {
                    continue;
                }
                let nd = a.at_const(i as NodeId);
                if nd.span.start < fsp.start || nd.span.end > fsp.end {
                    continue;
                }
                let is_binder = nd.kind == NodeKind::NODE_LET || nd.kind == NodeKind::NODE_PATTERN_NAME || nd.kind == NodeKind::NODE_PARAMETER;
                if !is_binder {
                    continue;
                }
                let nm = decl_name(a, i as NodeId);
                if nm != NODE_NONE && name_str(p, dm, nm) == new_name {
                    return String::from_str(
                        "the new name would collide with or shadow another binding in this function",
                    );
                }
            }
        }
    }
    return String::new();
}

// ---------------------------------------------------------------------------------------------------------
// Call / type hierarchy and code-action queries.
// ---------------------------------------------------------------------------------------------------------

/// The smallest function item whose span contains `off` (NODE_NONE when none does).
pub fn enclosing_function(p: &loader::Package, mi: usize, off: u32) NodeId {
    if !p.modules.at(mi).has_ast {
        return NODE_NONE;
    }
    let a = mod_ast(p, mi);
    let n = unsafe a.nodes.len();
    let mut best = NODE_NONE;
    let mut blen: u32 = 0xFFFFFFFF;
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        if nd.kind != NodeKind::NODE_FUNCTION || nd.as_data.function.body == NODE_NONE {
            continue;
        }
        if nd.span.start <= off && off < nd.span.end && nd.span.end - nd.span.start < blen {
            best = i as NodeId;
            blen = nd.span.end - nd.span.start;
        }
    }
    return best;
}

/// One resolved call site inside a function body.
pub struct CallSite {
    pub callee: DefId,
    pub start: u32,
    pub end: u32,
}

/// Every call inside `fnid`'s span whose callee resolves to a function declaration.
pub fn calls_in(p: &loader::Package, mi: usize, fnid: NodeId) Vector<CallSite> {
    let mut out = Vector::<CallSite>::new();
    let a = mod_ast(p, mi);
    let fsp = a.at_const(fnid).span;
    let n = unsafe a.nodes.len();
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        if nd.kind != NodeKind::NODE_CALL || nd.span.start < fsp.start || nd.span.end > fsp.end {
            continue;
        }
        let mut callee = nd.as_data.call.callee;
        if callee == NODE_NONE {
            continue;
        }
        // a generic specialization call resolves through its expression
        if a.at_const(callee).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            callee = a.at_const(callee).as_data.specialization.expression;
        }
        if callee == NODE_NONE || callee as usize >= a.resolutions_len() {
            continue;
        }
        let d = a.resolution_def(callee);
        if d.node == NODE_NONE {
            continue;
        }
        let da = mod_ast(p, d.module as usize);
        if da.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        let sp = a.at_const(callee).span;
        out.push(CallSite { callee: d, start: sp.start, end: sp.end });
    }
    return out;
}

/// Module paths (import spellings) whose PUBLIC top-level declarations contain `name`. Prelude
/// modules are auto-imported and the requesting module itself is excluded.
pub fn import_candidates(p: &loader::Package, mi: usize, name: str) Vector<String> {
    let mut out = Vector::<String>::new();
    for mm in 0..p.modules.len() {
        if mm == mi || p.modules.at(mm).prelude || !p.modules.at(mm).has_ast {
            continue;
        }
        if p.modules.at(mm).path.len() == 0 {
            continue;
        }
        let mut pubs = Vector::<CompItem>::new();
        comp_module_publics(p, mm, &mut pubs);
        for i in 0..pubs.len() {
            if pubs.at(i).label.as_str() == name {
                out.push(p.modules.at(mm).path.clone());
                break;
            }
        }
    }
    return out;
}

/// Byte offset where a new `import ...;` line belongs in module `mi`: right after the last existing
/// top-level import line, else at the top of the file.
pub fn import_insert_at(p: &loader::Package, mi: usize) u32 {
    let src = p.modules.at(mi).source.as_str();
    let mut at: u32 = 0;
    let mut i: usize = 0;
    while i < src.len() {
        let mut e = i;
        while e < src.len() && src[e] != b'\n' {
            e += 1;
        }
        if src.slice(i, e).trim().starts_with("import ") {
            at = if e < src.len() {
                (e + 1) as u32;
            } else {
                e as u32;
            };
        }
        i = e + 1;
    }
    return at;
}

/// An insertion produced for a code action: byte offset plus the text.
pub struct StubIns {
    pub at: u32,
    pub text: String,
}

extend StubIns as Free {
    pub fn free(self: &mut Self) {
        self.text.free();
    }
}

/// The stub for interface method `method_name`, inserted before the closing brace of the extend
/// block containing `off` (the span the missing-method diagnostic points into).
pub fn iface_stub(p: &loader::Package, mi: usize, off: u32, method_name: str) Option<StubIns> {
    let none = Option::<StubIns>::None;
    if !p.modules.at(mi).has_ast {
        return none;
    }
    let a = mod_ast(p, mi);
    let n = unsafe a.nodes.len();
    let mut ext = NODE_NONE;
    let mut blen: u32 = 0xFFFFFFFF;
    for i in 1..n {
        let nd = a.at_const(i as NodeId);
        if nd.kind != NodeKind::NODE_EXTEND {
            continue;
        }
        if nd.span.start <= off && off < nd.span.end && nd.span.end - nd.span.start < blen {
            ext = i as NodeId;
            blen = nd.span.end - nd.span.start;
        }
    }
    if ext == NODE_NONE {
        return none;
    }
    let it = a.at_const(ext).as_data.extend_def.interface_type;
    if it == NODE_NONE || it as usize >= a.resolutions_len() {
        return none;
    }
    let idf = a.resolution_def(it);
    if idf.node == NODE_NONE {
        return none;
    }
    let ia = mod_ast(p, idf.module as usize);
    if ia.at_const(idf.node).kind != NodeKind::NODE_INTERFACE {
        return none;
    }
    let isrc = p.modules.at(idf.module as usize).source.as_str();
    let ms = ia.at_const(idf.node).as_data.interface_def.items;
    for k in 0..ms.len {
        let fid = unsafe ia.list(ms)[k as usize];
        if ia.at_const(fid).kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        if name_str(p, idf.module as usize, ia.at_const(fid).as_data.function.name) != method_name {
            continue;
        }
        let sp = ia.at_const(fid).span;
        let mut sig = String::from_str(isrc.slice(sp.start as usize, sp.end as usize));
        // the interface declaration ends in ';' (no body); the stub replaces it with a panicking body
        while sig.len() != 0 && (sig.as_str()[sig.len() - 1] == b';' || sig.as_str()[sig.len() - 1] == b' ' || sig.as_str()[sig.len() - 1] == b'\n') {
            sig.truncate(sig.len() - 1);
        }
        let mut text = String::from_str("\n    ");
        text.push_string(&sig);
        text.push_str(" {\n        panic(\"todo: implement\");\n    }\n");
        let esp = a.at_const(ext).span;
        if esp.end == 0 {
            return none;
        }
        return Option::<StubIns>::Some(StubIns { at: esp.end - 1, text: text });
    }
    return none;
}

/// Interfaces the aggregate `d` conforms to: each `extend T as I` block's interface name span.
pub fn type_ifaces(p: &loader::Package, d: DefId) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    for mm in 0..p.modules.len() {
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let am = mod_ast(p, mm);
        let items = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe am.list(items)[i as usize];
            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let tgt = am.at_const(iid).as_data.extend_def.target_type;
            let it = am.at_const(iid).as_data.extend_def.interface_type;
            if tgt == NODE_NONE || it == NODE_NONE || tgt as usize >= am.resolutions_len() || it as usize >= am.resolutions_len() {
                continue;
            }
            let td = am.resolution_def(tgt);
            if td.module != d.module || td.node != d.node {
                continue;
            }
            let idf = am.resolution_def(it);
            if idf.node == NODE_NONE {
                continue;
            }
            let ia = mod_ast(p, idf.module as usize);
            let nm = ia.at_const(idf.node).as_data.interface_def.name;
            let sp = ia.at_const(nm).span;
            out.push(Loc { module: idf.module, start: sp.start, end: sp.end });
        }
    }
    return out;
}

/// Conforming target-type declaration name spans for interface `d` (`extend T as I` -> T's decl).
pub fn iface_conformers(p: &loader::Package, d: DefId) Vector<Loc> {
    let mut out = Vector::<Loc>::new();
    for mm in 0..p.modules.len() {
        if !p.modules.at(mm).has_ast {
            continue;
        }
        let am = mod_ast(p, mm);
        let items = unsafe am.at_const(am.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe am.list(items)[i as usize];
            if am.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let tgt = am.at_const(iid).as_data.extend_def.target_type;
            let it = am.at_const(iid).as_data.extend_def.interface_type;
            if tgt == NODE_NONE || it == NODE_NONE || tgt as usize >= am.resolutions_len() || it as usize >= am.resolutions_len() {
                continue;
            }
            let idf = am.resolution_def(it);
            if idf.module != d.module || idf.node != d.node {
                continue;
            }
            let td = am.resolution_def(tgt);
            if td.node == NODE_NONE {
                continue;
            }
            let ta = mod_ast(p, td.module as usize);
            let tn = ta.at_const(td.node);
            let nm = if tn.kind == NodeKind::NODE_STRUCT || tn.kind == NodeKind::NODE_ENUM {
                tn.as_data.aggregate.name;
            } else {
                NODE_NONE;
            };
            if nm == NODE_NONE {
                continue;
            }
            let sp = ta.at_const(nm).span;
            out.push(Loc { module: td.module, start: sp.start, end: sp.end });
        }
    }
    return out;
}
