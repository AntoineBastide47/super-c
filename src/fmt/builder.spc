// AST -> Doc builder for the canonical formatter: format_node lowers every NodeKind to the document
// IR in fmt::doc; the renderer then chooses line breaks by width. Layout policy (user-approved):
// fully canonical -- blocks always break, lists group with IfBreak trailing commas, indentation is
// structural. Two things the AST does not carry are reconstructed here:
//   - Parentheses (the parser drops them): re-inserted by precedence. The ladder mirrors the parser:
//     postfix (call/index/member/cast/?/turbofish) = 14, unary prefix = 12, binary ops use
//     Parser::precedence (2..11), range = 1, assignment = 0, closures/switch = lowest.
//   - Trivia (comments and @attributes): the bytes BETWEEN sibling elements are trivia-only (comments,
//     attrs, separators, whitespace), so every list emitter extracts comment/attr segments from its
//     inter-element gaps by byte scanning: a segment starting before the gap's first newline is a
//     trailing comment of the previous element (one space before it), the rest lead the next element.
//     Blank-line runs between elements are preserved capped at one. `emitted_trivia` counts segments;
//     the caller compares it against the lexer's comment-token count and refuses to write on mismatch.
// If-let / while-let statements are parser-desugared to NODE_MATCH; they are detected by their source
// prefix and emitted verbatim from their span (canonicalizing them would rewrite user syntax).

import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::parser as par;
import fmt::doc as d;

pub struct Builder<'a> {
    pub p: d::DocPool<'a>,
    pub ast: *const Ast,
    pub src: str<'a>,
    pub emitted_trivia: usize, // comment segments emitted (attrs are separate and not counted)
}

extend Builder as Free {
    pub fn free(self: &mut Self) {
        self.p.free();
    }
}

const fn nd(b: &Builder, id: NodeId) Node {
    return *b.ast.at_const(id);
}

const fn list_at(b: &Builder, l: NodeList, i: u32) NodeId {
    return unsafe b.ast.list(l)[i as usize];
}

fn span_doc(b: &mut Builder, s: tok::Span) d::DocId {
    return b.p.span(s.start, s.end);
}

fn node_text(b: &mut Builder, id: NodeId) d::DocId {
    let s = nd(b, id).span;
    return b.p.span(s.start, s.end);
}

// ---- trivia gaps ----------------------------------------------------------------------------------

struct TriviaSeg {
    pub start: u32,
    pub end: u32,
    pub trailing: bool, // began before the gap's first newline: belongs to the previous element
    pub is_attr: bool,
    pub blank_before: bool, // a blank line separated this segment from what precedes it
}

// Scan src[from..to) for comment and @attribute segments. Everything else in an inter-element gap is
// whitespace or separator punctuation and is ignored.
fn scan_gap(b: &Builder, from: u32, to: u32, out: &mut Vector<TriviaSeg>) {
    let s = b.src;
    let mut i = from as usize;
    let mut seen_nl = false;
    let mut nl_run = 0;
    while i < to as usize {
        let c = s.byte_at(i);
        if c == b'\n' {
            seen_nl = true;
            nl_run = nl_run + 1;
            i = i + 1;
            continue;
        }
        if c != b' ' && c != b'\t' && c != b'\r' {
            let st = i;
            let mut en = i;
            let mut is_seg = false;
            let mut is_attr = false;
            if c == b'/' && i + 1 < to as usize && s.byte_at(i + 1) == b'/' {
                en = i;
                while en < to as usize && s.byte_at(en) != b'\n' {
                    en = en + 1;
                }
                is_seg = true;
            } else if c == b'/' && i + 1 < to as usize && s.byte_at(i + 1) == b'*' {
                en = i + 2;
                while en + 1 < to as usize && !(s.byte_at(en) == b'*' && s.byte_at(en + 1) == b'/') {
                    en = en + 1;
                }
                en = en + 2;
                if en > to as usize {
                    en = to as usize;
                }
                is_seg = true;
            } else if c == b'@' {
                en = i;
                while en < to as usize && s.byte_at(en) != b'\n' {
                    en = en + 1;
                }
                // strip trailing spaces/commas of the attr line
                while en > st && (s.byte_at(en - 1) == b' ' || s.byte_at(en - 1) == b'\t' || s.byte_at(en - 1) == b'\r') {
                    en = en - 1;
                }
                is_seg = true;
                is_attr = true;
            }
            if is_seg {
                // trim trailing blanks of line comments
                let mut e2 = en;
                while e2 > st && (s.byte_at(e2 - 1) == b' ' || s.byte_at(e2 - 1) == b'\t') {
                    e2 = e2 - 1;
                }
                out.push(
                    TriviaSeg {
                        start: st as u32,
                        end: e2 as u32,
                        trailing: !seen_nl,
                        is_attr: is_attr,
                        blank_before: nl_run >= 2,
                    },
                );
                nl_run = 0;
                i = en;
                continue;
            }
            nl_run = 0; // separator punctuation: , ; etc.
        }
        i = i + 1;
    }
}

fn count_gap_newlines(b: &Builder, from: u32, to: u32) i32 {
    let mut c: i32 = 0;
    let mut i = from as usize;
    while i < to as usize {
        if b.src.byte_at(i) == b'\n' {
            c = c + 1;
        }
        i = i + 1;
    }
    return c;
}

// Emit the gap between two vertical elements (statements/items/fields/arms): trailing comments stay
// on the previous line, then a hard/blank separation, then leading comments/attrs each on their own
// line. Pushes onto `parts`; the caller emits the next element right after.
fn emit_gap_vertical(b: &mut Builder, from: u32, to: u32, parts: &mut Vector<d::DocId>, _first: bool) {
    let mut segs = Vector::<TriviaSeg>::new();
    scan_gap(b, from, to, &mut segs);
    let mut i: usize = 0;
    while i < segs.len() && segs.at(i).trailing {
        let sg = *segs.at(i);
        parts.push(b.p.txt(" "));
        parts.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
        i = i + 1;
    }
    // separation after the previous element (before the first leading seg or the next element)
    let mut blank = false;
    if i < segs.len() {
        blank = segs.at(i).blank_before;
    } else {
        blank = count_gap_newlines(b, from, to) >= 2;
    }
    if blank {
        parts.push(b.p.blankline());
    } else {
        parts.push(b.p.hardline());
    }
    while i < segs.len() {
        let sg = *segs.at(i);
        parts.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
        let mut nb = false;
        if i + 1 < segs.len() {
            nb = segs.at(i + 1).blank_before;
        } else {
            nb = count_gap_newlines(b, sg.end, to) >= 2;
        }
        if nb {
            parts.push(b.p.blankline());
        } else {
            parts.push(b.p.hardline());
        }
        i = i + 1;
    }
}

// Leading trivia at the start of a braced body or file: each segment on its own line, followed by
// its separation to whatever comes next.
fn emit_lead_list(b: &mut Builder, from: u32, to: u32, parts: &mut Vector<d::DocId>) {
    let mut segs = Vector::<TriviaSeg>::new();
    scan_gap(b, from, to, &mut segs);
    for k in 0..segs.len() {
        let sg = *segs.at(k);
        parts.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
        let mut nb = false;
        if k + 1 < segs.len() {
            nb = segs.at(k + 1).blank_before;
        } else {
            nb = count_gap_newlines(b, sg.end, to) >= 2;
        }
        if nb {
            parts.push(b.p.blankline());
        } else {
            parts.push(b.p.hardline());
        }
    }
}

// Dangling/trailing trivia before a closing brace or end of file.
fn emit_tail_list(b: &mut Builder, from: u32, to: u32, parts: &mut Vector<d::DocId>) {
    let mut segs = Vector::<TriviaSeg>::new();
    scan_gap(b, from, to, &mut segs);
    for k in 0..segs.len() {
        let sg = *segs.at(k);
        if sg.trailing {
            parts.push(b.p.txt(" "));
        } else if sg.blank_before {
            parts.push(b.p.blankline());
        } else {
            parts.push(b.p.hardline());
        }
        parts.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
    }
}

// ---- precedence -----------------------------------------------------------------------------------

pub const PREC_ASSIGN: i32 = 0;
pub const PREC_RANGE: i32 = 1;
pub const PREC_CAST: i32 = 12; // `as`: looser than prefix ops, tighter than any binary op (parser binary max = 11)
pub const PREC_UNARY: i32 = 13;
pub const PREC_POSTFIX: i32 = 14;
pub const PREC_PRIMARY: i32 = 20;

const fn expr_prec(b: &Builder, id: NodeId) i32 {
    let n = nd(b, id);
    switch n.kind {
        NODE_BINARY => {
            return par::Parser::precedence(n.as_data.binary.op);
        },
        NODE_ASSIGNMENT => {
            return PREC_ASSIGN;
        },
        NODE_RANGE => {
            return PREC_RANGE;
        },
        NODE_UNARY => {
            if n.as_data.unary.op == tt::TokenType::Question {
                return PREC_POSTFIX;
            }
            return PREC_UNARY;
        },
        NODE_CAST => {
            return PREC_CAST;
        },
        NODE_CALL | NODE_INDEX | NODE_MEMBER | NODE_GENERIC_SPECIALIZATION => {
            return PREC_POSTFIX;
        },
        NODE_CLOSURE | NODE_MATCH => {
            return PREC_ASSIGN;
        },
        _ => {
            return PREC_PRIMARY;
        },
    };
    return PREC_PRIMARY;
}

fn b_expr_prec(b: &mut Builder, id: NodeId, min_prec: i32) d::DocId {
    let e = b_expr(b, id);
    if expr_prec(b, id) < min_prec {
        let mut v = Vector::<d::DocId>::new();
        v.push(b.p.txt("("));
        v.push(e);
        v.push(b.p.txt(")"));
        let r = b.p.concat(&v);
        return r;
    }
    return e;
}

// ---- shared list shapes ---------------------------------------------------------------------------

// Does src[from..to) hold a comment or attribute? Decides up front whether a list must print broken.
fn gap_has_trivia(b: &Builder, from: u32, to: u32) bool {
    let mut segs = Vector::<TriviaSeg>::new();
    scan_gap(b, from, to, &mut segs);
    return segs.len() != 0;
}

// Push the segments of one inter-element gap, splitting them around the element separator: a segment that
// began before the gap's first newline trails the PREVIOUS element (`a, // note`), the rest lead the next
// one, each on its own line. `sep` is emitted between the two halves.
fn push_gap_inline(b: &mut Builder, from: u32, to: u32, sep: d::DocId, out: &mut Vector<d::DocId>) {
    let mut segs = Vector::<TriviaSeg>::new();
    scan_gap(b, from, to, &mut segs);
    let mut i: usize = 0;
    while i < segs.len() && segs.at(i).trailing {
        let sg = *segs.at(i);
        out.push(b.p.txt(" "));
        out.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
        i = i + 1;
    }
    out.push(sep);
    while i < segs.len() {
        let sg = *segs.at(i);
        out.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
        out.push(b.p.hardline());
        i = i + 1;
    }
}

// The byte offset of the delimiter closing a list, scanning from `from` (the last element's end) and
// skipping comments. Only trivia and a separator can sit between the last element and its closer, so no
// nesting has to be tracked. `to` bounds the search; on failure it returns `from`, which makes the tail gap
// empty and the list simply keeps its old shape.
fn find_close(b: &Builder, from: u32, to: u32, close: u8) u32 {
    let src = b.src;
    let mut i = from as usize;
    let hi = if to as usize > src.len() {
        src.len();
    } else {
        to as usize;
    };
    while i < hi {
        let c = src.byte_at(i);
        if c == b'/' && i + 1 < hi && src.byte_at(i + 1) == b'/' {
            while i < hi && src.byte_at(i) != b'\n' {
                i = i + 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < hi && src.byte_at(i + 1) == b'*' {
            i = i + 2;
            while i + 1 < hi && !(src.byte_at(i) == b'*' && src.byte_at(i + 1) == b'/') {
                i = i + 1;
            }
            i = i + 2;
            continue;
        }
        if c == close {
            return i as u32;
        }
        i = i + 1;
    }
    return from;
}

// Does any gap in `ids` (between `open_end` and `close_pos`) hold trivia? What decides whether a list needs
// the trivia-aware shape at all -- every list keeps its existing output byte for byte when it does not.
fn list_has_trivia(b: &Builder, ids: NodeList, open_end: u32, close_pos: u32) bool {
    let mut prev = open_end;
    for i in 0..ids.len {
        let sp = nd(b, list_at(b, ids, i)).span;
        if gap_has_trivia(b, prev, sp.start) {
            return true;
        }
        prev = sp.end;
    }
    return gap_has_trivia(b, prev, close_pos);
}

// `b_comma_list`, plus the comments living in the gaps between elements. `ids` are the source nodes the
// element docs came from (index-aligned), `open_end` the byte just past the opening delimiter and
// `close_pos` the closing one, so every gap is scanned exactly once and by exactly one list.
//
// Any comment forces the list to print BROKEN -- a line comment printed flat would swallow the rest of the
// line, closing delimiter included -- which the `hardline` separators do by making the group's width
// infinite. Without this, a comment inside an expression list is simply dropped, and the whole-file
// comment-preservation check then refuses to write the file.
fn b_comma_list_tr(
    b: &mut Builder,
    open: str,
    elems: &Vector<d::DocId>,
    ids: NodeList,
    open_end: u32,
    close_pos: u32,
    close: str,
    trailing_comma: bool,
) d::DocId {
    // One pass to decide the shape: a comment in ANY gap breaks the whole list.
    let mut hard = false;
    let mut prev = open_end;
    for i in 0..elems.len() {
        let sp = nd(b, list_at(b, ids, i as u32)).span;
        if gap_has_trivia(b, prev, sp.start) {
            hard = true;
        }
        prev = sp.end;
    }
    if gap_has_trivia(b, prev, close_pos) {
        hard = true;
    }
    if !hard {
        return b_comma_list(b, open, elems, close, trailing_comma);
    }
    let mut inner = Vector::<d::DocId>::new();
    prev = open_end;
    for i in 0..elems.len() {
        let sp = nd(b, list_at(b, ids, i as u32)).span;
        if i > 0 {
            inner.push(b.p.txt(","));
        }
        let sep = b.p.hardline();
        push_gap_inline(b, prev, sp.start, sep, &mut inner);
        inner.push(*elems.at(i));
        prev = sp.end;
    }
    if trailing_comma && elems.len() != 0 {
        inner.push(b.p.txt(","));
    }
    // Anything left before the closing delimiter: a trailing comment stays on the last element's line.
    let mut tsegs = Vector::<TriviaSeg>::new();
    scan_gap(b, prev, close_pos, &mut tsegs);
    for k in 0..tsegs.len() {
        let sg = *tsegs.at(k);
        if sg.trailing {
            inner.push(b.p.txt(" "));
        } else {
            inner.push(b.p.hardline());
        }
        inner.push(b.p.span(sg.start, sg.end));
        if !sg.is_attr {
            b.emitted_trivia = b.emitted_trivia + 1;
        }
    }
    let ic = b.p.concat(&inner);
    let mut parts = Vector::<d::DocId>::new();
    parts.push(b.p.txt(open));
    parts.push(b.p.indent(ic));
    parts.push(b.p.hardline());
    parts.push(b.p.txt(close));
    let body = b.p.concat(&parts);
    return b.p.group(body);
}

// group( open indent(softline join(", "-line, elems)) ifbreak(",") softline close )
fn b_comma_list(b: &mut Builder, open: str, elems: &Vector<d::DocId>, close: str, trailing_comma: bool) d::DocId {
    if elems.len() == 0 {
        let mut v0 = Vector::<d::DocId>::new();
        v0.push(b.p.txt(open));
        v0.push(b.p.txt(close));
        let r0 = b.p.concat(&v0);
        return r0;
    }
    let mut inner = Vector::<d::DocId>::new();
    inner.push(b.p.softline());
    for i in 0..elems.len() {
        if i > 0 {
            inner.push(b.p.txt(","));
            inner.push(b.p.line());
        }
        inner.push(*elems.at(i));
    }
    if trailing_comma {
        inner.push(b.p.ifbreak(",", false));
    }
    let ic = b.p.concat(&inner);
    let mut parts = Vector::<d::DocId>::new();
    parts.push(b.p.txt(open));
    parts.push(b.p.indent(ic));
    parts.push(b.p.softline());
    parts.push(b.p.txt(close));
    let body = b.p.concat(&parts);
    return b.p.group(body);
}

// Lower each node of `l` with `what`: 0 = expr, 1 = type, 2 = pattern, 3 = parameter, 4 = generic param.
fn b_each(b: &mut Builder, l: NodeList, what: i32, out: &mut Vector<d::DocId>) {
    if what == 3 {
        b_params(b, l, out);
        return;
    }
    for i in 0..l.len {
        let id = list_at(b, l, i);
        if what == 0 {
            out.push(b_expr(b, id));
        } else if what == 1 {
            out.push(b_type(b, id));
        } else if what == 2 {
            out.push(b_pattern(b, id));
        } else {
            out.push(b_generic_param(b, id));
        }
    }
}

// Parameters. A `a, b: T` group parses into consecutive NODE_PARAMETERs SHARING one `ty` node id
// (separately written params each parse their own type), so the written form is recoverable: a
// shared-type run prints back as one `a, b: T` group instead of being desugared per name.
fn b_params(b: &mut Builder, l: NodeList, out: &mut Vector<d::DocId>) {
    let mut i: u32 = 0;
    while i < l.len {
        let id = list_at(b, l, i);
        let n = nd(b, id);
        let named = n.kind == NodeKind::NODE_PARAMETER && n.as_data.parameter.name != NODE_NONE && n.as_data.parameter.ty != NODE_NONE;
        let mut j = i + 1;
        while named && j < l.len {
            let m = nd(b, list_at(b, l, j));
            if m.kind != NodeKind::NODE_PARAMETER || m.as_data.parameter.name == NODE_NONE || m.as_data.parameter.ty != n.as_data.parameter.ty {
                break;
            }
            j += 1;
        }
        if j == i + 1 {
            out.push(b_param(b, id));
            i = j;
            continue;
        }
        let mut v = Vector::<d::DocId>::new();
        for k in i..j {
            let p = nd(b, list_at(b, l, k));
            if k > i {
                v.push(b.p.txt(", "));
            }
            if p.as_data.parameter.is_mutable {
                v.push(b.p.txt("mut "));
            }
            v.push(node_text(b, p.as_data.parameter.name));
        }
        v.push(b.p.txt(": "));
        v.push(b_type(b, n.as_data.parameter.ty));
        out.push(b.p.concat(&v));
        i = j;
    }
}

// ---- types ----------------------------------------------------------------------------------------

fn b_type(b: &mut Builder, id: NodeId) d::DocId {
    if id == NODE_NONE {
        return b.p.nil();
    }
    let n = nd(b, id);
    let mut v = Vector::<d::DocId>::new();
    switch n.kind {
        NODE_TYPE_PATH => {
            let parts = n.as_data.type_path.parts;
            for i in 0..parts.len {
                if i > 0 {
                    v.push(b.p.txt("::"));
                }
                let __h = list_at(b, parts, i);
                v.push(node_text(b, __h));
            }
            let args = n.as_data.type_path.args;
            if args.len > 0 {
                let mut az = Vector::<d::DocId>::new();
                for i in 0..args.len {
                    let a = list_at(b, args, i);
                    if nd(b, a).kind == NodeKind::NODE_LITERAL {
                        az.push(node_text(b, a));
                    } else if fmt_const_arg(b, a) {
                        az.push(b_const_arg(b, a)); // `{N * 2}`: the braces are what make it an expression
                    } else {
                        az.push(b_type(b, a));
                    }
                }
                v.push(b_comma_list(b, "<", &az, ">", false));
            }
        },
        NODE_POINTER_TYPE => {
            if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                v.push(b.p.txt("*mut "));
            } else {
                v.push(b.p.txt("*const "));
            }
            v.push(b_type(b, n.as_data.indirect_type.ty));
        },
        NODE_REFERENCE_TYPE => {
            // `&T` / `&mut T`, with an optional lifetime binding first: `&'a T` / `&'a mut T`.
            v.push(b.p.txt("&"));
            if n.as_data.indirect_type.lifetime != NODE_NONE {
                v.push(node_text(b, n.as_data.indirect_type.lifetime));
                v.push(b.p.txt(" "));
            }
            if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                v.push(b.p.txt("mut "));
            }
            v.push(b_type(b, n.as_data.indirect_type.ty));
        },
        NODE_SLICE_TYPE => {
            if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                v.push(b.p.txt("[]mut "));
            } else {
                v.push(b.p.txt("[]"));
            }
            v.push(b_type(b, n.as_data.indirect_type.ty));
        },
        NODE_ARRAY_TYPE => {
            v.push(b.p.txt("["));
            v.push(b_type(b, n.as_data.array_type.element));
            v.push(b.p.txt("; "));
            v.push(b_expr(b, n.as_data.array_type.length));
            v.push(b.p.txt("]"));
        },
        NODE_FUNCTION_TYPE => {
            b_hrtb(b, id, &mut v);
            if n.as_data.function_type.is_move {
                v.push(b.p.txt("fn move"));
            } else {
                v.push(b.p.txt("fn"));
            }
            let mut ps = Vector::<d::DocId>::new();
            b_each(b, n.as_data.function_type.params, 1, &mut ps);
            v.push(b_comma_list(b, "(", &ps, ")", false));
            let rets = n.as_data.function_type.returns;
            if rets.len > 0 {
                v.push(b.p.txt(" "));
                v.push(b_returns(b, rets));
            }
        },
        NODE_DYN_TYPE => {
            v.push(b.p.txt("dyn "));
            v.push(b_type(b, n.as_data.indirect_type.ty));
        },
        NODE_TUPLE_TYPE => {
            let mut ts = Vector::<d::DocId>::new();
            b_each(b, n.as_data.array_literal.elements, 1, &mut ts);
            v.push(b_comma_list(b, "(", &ts, ")", false));
        },
        NODE_IDENTIFIER => {
            v.push(node_text(b, id));
        },
        _ => {
            v.push(node_text(b, id));
        }, // ellipsis `...` and friends: span verbatim
    };
    let r = b.p.concat(&v);
    return r;
}

// Return types: one type bare, several as "(A, B)".
fn b_returns(b: &mut Builder, rets: NodeList) d::DocId {
    let __h = list_at(b, rets, 0);
    // a single NAMED return keeps its parens (`(ret: bool)`); a single unnamed one never has them
    if rets.len == 1 && nd(b, __h).kind != NodeKind::NODE_PARAMETER {
        return b_type(b, __h);
    }
    let mut ts = Vector::<d::DocId>::new();
    b_each(b, rets, 1, &mut ts);
    let r = b_comma_list(b, "(", &ts, ")", false);
    return r;
}

fn b_param(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let mut v = Vector::<d::DocId>::new();
    if n.kind != NodeKind::NODE_PARAMETER {
        // function-type params may be bare types
        let r0 = b_type(b, id);
        return r0;
    }
    if n.as_data.parameter.is_mutable {
        v.push(b.p.txt("mut "));
    }
    if n.as_data.parameter.name != NODE_NONE {
        v.push(node_text(b, n.as_data.parameter.name));
        if n.as_data.parameter.ty != NODE_NONE {
            v.push(b.p.txt(": "));
            v.push(b_type(b, n.as_data.parameter.ty));
        }
    } else if n.as_data.parameter.ty != NODE_NONE {
        v.push(b_type(b, n.as_data.parameter.ty));
    }
    let r = b.p.concat(&v);
    return r;
}

fn b_generic_param(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let g = n.as_data.generic_param;
    let mut v = Vector::<d::DocId>::new();
    if g.is_const {
        v.push(b.p.txt("const "));
    }
    v.push(node_text(b, g.name));
    if g.is_const && g.const_type != NODE_NONE {
        v.push(b.p.txt(": "));
        v.push(b_type(b, g.const_type));
    }
    if g.bounds.len > 0 {
        v.push(b.p.txt(": "));
        for i in 0..g.bounds.len {
            if i > 0 {
                v.push(b.p.txt(" + "));
            }
            let __h = list_at(b, g.bounds, i);
            v.push(b_type(b, __h));
        }
    }
    if g.default_type != NODE_NONE {
        v.push(b.p.txt(" = "));
        v.push(b_type(b, g.default_type));
    }
    let r = b.p.concat(&v);
    return r;
}

// `for<'a, 'b> ` -- the higher-ranked prefix of a bound, held in the lifetime side table.
fn b_hrtb(b: &mut Builder, id: NodeId, v: &mut Vector<d::DocId>) {
    let lts = b.ast.lifetimes_of(id);
    if lts.len == 0 {
        return;
    }
    let mut gs = Vector::<d::DocId>::new();
    b_each(b, lts, 4, &mut gs);
    v.push(b.p.txt("for"));
    v.push(b_comma_list(b, "<", &gs, ">", false));
    v.push(b.p.txt(" "));
}

// Lifetime params live in their own list (erasure is structural), but they are SOURCE-level part of
// the same `<...>` and must print back merged, lifetimes first: `<'a, 'b: 'a, T>`.
fn b_generics_lt(b: &mut Builder, lts: NodeList, gens: NodeList, v: &mut Vector<d::DocId>) {
    if lts.len == 0 && gens.len == 0 {
        return;
    }
    let mut gs = Vector::<d::DocId>::new();
    if lts.len != 0 {
        b_each(b, lts, 4, &mut gs);
    }
    if gens.len != 0 {
        b_each(b, gens, 4, &mut gs);
    }
    v.push(b_comma_list(b, "<", &gs, ">", false));
}

// ---- patterns -------------------------------------------------------------------------------------

fn b_pattern(b: &mut Builder, id: NodeId) d::DocId {
    if id == NODE_NONE {
        return b.p.nil();
    }
    let n = nd(b, id);
    let mut v = Vector::<d::DocId>::new();
    switch n.kind {
        NODE_PATTERN_WILDCARD => {
            v.push(b.p.txt("_"));
        },
        NODE_PATTERN_LITERAL | NODE_PATTERN_RANGE => {
            v.push(node_text(b, id));
        },
        NODE_PATTERN_NAME => {
            let p = n.as_data.pattern;
            if p.children.len > 0 {
                // binding @ subpattern or `mut x` -- emit from span (rare shapes)
                v.push(node_text(b, id));
            } else {
                v.push(node_text(b, id));
            }
        },
        NODE_PATTERN_TUPLE => {
            let p = n.as_data.pattern;
            if p.name != NODE_NONE {
                v.push(b_pattern_path(b, p.name));
            }
            let mut cs = Vector::<d::DocId>::new();
            b_each(b, p.children, 2, &mut cs);
            v.push(b_comma_list(b, "(", &cs, ")", false));
        },
        NODE_PATTERN_STRUCT => {
            let p = n.as_data.pattern;
            if p.name != NODE_NONE {
                v.push(b_pattern_path(b, p.name));
            }
            v.push(b.p.txt(" { "));
            for i in 0..p.children.len {
                if i > 0 {
                    v.push(b.p.txt(", "));
                }
                let __h = list_at(b, p.children, i);
                v.push(b_pattern(b, __h));
            }
            v.push(b.p.txt(" }"));
        },
        NODE_PATTERN_FIELD => {
            let p = n.as_data.pattern;
            v.push(node_text(b, p.name));
            if p.children.len > 0 {
                v.push(b.p.txt(": "));
                let __h = list_at(b, p.children, 0);
                v.push(b_pattern(b, __h));
            }
        },
        NODE_PATTERN_OR => {
            let p = n.as_data.pattern;
            for i in 0..p.children.len {
                if i > 0 {
                    v.push(b.p.txt(" | "));
                }
                let __h = list_at(b, p.children, i);
                v.push(b_pattern(b, __h));
            }
        },
        _ => {
            v.push(node_text(b, id));
        },
    };
    let r = b.p.concat(&v);
    return r;
}

// A pattern head (`Option::Some`, `Some`): identifier or type path.
fn b_pattern_path(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    if n.kind == NodeKind::NODE_TYPE_PATH {
        return b_type(b, id);
    }
    return node_text(b, id);
}

// ---- expressions ----------------------------------------------------------------------------------

const fn is_block_node(b: &Builder, id: NodeId) bool {
    return id != NODE_NONE && nd(b, id).kind == NodeKind::NODE_BLOCK;
}

// Flat constraint/expression pairs printed as `"c" (expr)`, comma separated.
fn b_asm_operands(b: &mut Builder, v: &mut Vector<d::DocId>, ops: NodeList) {
    let mut i: u32 = 0;
    while i + 1 < ops.len {
        if i != 0 {
            v.push(b.p.txt(", "));
        }
        v.push(b_expr(b, list_at(b, ops, i)));
        v.push(b.p.txt("("));
        v.push(b_expr(b, list_at(b, ops, i + 1)));
        v.push(b.p.txt(")"));
        i = i + 2;
    }
}

fn b_expr(b: &mut Builder, id: NodeId) d::DocId {
    if id == NODE_NONE {
        return b.p.nil();
    }
    let n = nd(b, id);
    if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_LITERAL {
        return node_text(b, id);
    }
    let mut v = Vector::<d::DocId>::new();
    switch n.kind {
        NODE_UNARY => {
            let u = n.as_data.unary;
            if u.op == tt::TokenType::Question {
                v.push(b_expr_prec(b, u.operand, PREC_POSTFIX));
                v.push(b.p.txt("?"));
            } else if u.op == tt::TokenType::Unsafe || u.op == tt::TokenType::Move {
                if u.op == tt::TokenType::Unsafe {
                    v.push(b.p.txt("unsafe "));
                } else {
                    v.push(b.p.txt("move "));
                }
                if is_block_node(b, u.operand) {
                    v.push(b_block(b, u.operand));
                } else {
                    v.push(b_expr_prec(b, u.operand, PREC_UNARY));
                }
            } else {
                if u.op == tt::TokenType::Ampersand {
                    if u.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                        v.push(b.p.txt("&mut "));
                    } else {
                        v.push(b.p.txt("&"));
                    }
                } else if u.op == tt::TokenType::Minus {
                    v.push(b.p.txt("-"));
                } else if u.op == tt::TokenType::Bang {
                    v.push(b.p.txt("!"));
                } else if u.op == tt::TokenType::Tilde {
                    v.push(b.p.txt("~"));
                } else if u.op == tt::TokenType::Star {
                    v.push(b.p.txt("*"));
                }
                v.push(b_expr_prec(b, u.operand, PREC_UNARY));
            }
        },
        NODE_BINARY => {
            let bi = n.as_data.binary;
            let pr = par::Parser::precedence(bi.op);
            v.push(b_expr_prec(b, bi.left, pr));
            v.push(b.p.txt(" "));
            v.push(op_text(b, bi.op));
            v.push(b.p.txt(" "));
            v.push(b_expr_prec(b, bi.right, pr + 1));
        },
        NODE_ASSIGNMENT => {
            let bi = n.as_data.binary;
            v.push(b_expr_prec(b, bi.left, PREC_RANGE));
            v.push(b.p.txt(" "));
            v.push(op_text(b, bi.op));
            v.push(b.p.txt(" "));
            v.push(b_expr_prec(b, bi.right, PREC_RANGE));
        },
        NODE_RANGE => {
            let r = n.as_data.pattern_range;
            if r.start != NODE_NONE {
                v.push(b_expr_prec(b, r.start, PREC_RANGE + 1));
            }
            if r.inclusive {
                v.push(b.p.txt("..="));
            } else {
                v.push(b.p.txt(".."));
            }
            if r.end != NODE_NONE {
                v.push(b_expr_prec(b, r.end, PREC_RANGE + 1));
            }
        },
        NODE_CALL => {
            v.push(b_expr_prec(b, n.as_data.call.callee, PREC_POSTFIX));
            let mut az = Vector::<d::DocId>::new();
            b_each(b, n.as_data.call.args, 0, &mut az);
            v.push(
                b_comma_list_tr(
                    b,
                    "(",
                    &az,
                    n.as_data.call.args,
                    nd(b, n.as_data.call.callee).span.end,
                    n.span.end,
                    ")",
                    true,
                ),
            );
        },
        NODE_INDEX => {
            v.push(b_expr_prec(b, n.as_data.index.object, PREC_POSTFIX));
            v.push(b.p.txt("["));
            v.push(b_expr(b, n.as_data.index.index));
            v.push(b.p.txt("]"));
        },
        NODE_MEMBER => {
            v.push(b_expr_prec(b, n.as_data.member.object, PREC_POSTFIX));
            if n.as_data.member.path {
                v.push(b.p.txt("::"));
            } else {
                v.push(b.p.txt("."));
            }
            v.push(node_text(b, n.as_data.member.member));
        },
        NODE_CAST => {
            // Print the operand at POSTFIX, not CAST: prefix-op and chained-cast operands keep
            // their parens, so the output parses identically under the pre-flip bootstrap
            // grammar (`as` used to bind tighter than prefix ops). Relax to PREC_CAST once
            // every bootstrap release contains the precedence flip.
            v.push(b_expr_prec(b, n.as_data.cast.expression, PREC_POSTFIX));
            v.push(b.p.txt(" as "));
            v.push(b_type(b, n.as_data.cast.ty));
        },
        NODE_GENERIC_SPECIALIZATION => {
            v.push(b_expr_prec(b, n.as_data.specialization.expression, PREC_POSTFIX));
            let mut az = Vector::<d::DocId>::new();
            let types = n.as_data.specialization.types;
            for i in 0..types.len {
                let a = list_at(b, types, i);
                if nd(b, a).kind == NodeKind::NODE_LITERAL {
                    az.push(node_text(b, a));
                } else if fmt_const_arg(b, a) {
                    az.push(b_const_arg(b, a));
                } else {
                    az.push(b_type(b, a));
                }
            }
            v.push(b.p.txt("::"));
            v.push(b_comma_list(b, "<", &az, ">", false));
        },
        NODE_CLOSURE => {
            let c = n.as_data.closure;
            let mut ps = Vector::<d::DocId>::new();
            b_each(b, c.params, 3, &mut ps);
            // `|..|` has no return-type slot -- only the `fn(..) T { .. }` spelling does. Both parse to this
            // node, so a closure that DECLARES a return type has to print in that form: normalising it to
            // `||` would drop the type from the source, which is how this arm used to corrupt a file.
            if c.returns.len != 0 {
                v.push(b.p.txt("fn"));
                v.push(b_comma_list(b, "(", &ps, ")", true));
                v.push(b.p.txt(" "));
                v.push(b_returns(b, c.returns));
                v.push(b.p.txt(" "));
                if c.expr_body {
                    v.push(b_expr(b, c.body));
                } else {
                    v.push(b_block(b, c.body));
                }
                let rc = b.p.concat(&v);
                return rc;
            }
            if ps.len() == 0 {
                v.push(b.p.txt("||"));
            } else {
                v.push(b.p.txt("|"));
                for i in 0..ps.len() {
                    if i > 0 {
                        v.push(b.p.txt(", "));
                    }
                    v.push(*ps.at(i));
                }
                v.push(b.p.txt("|"));
            }
            v.push(b.p.txt(" "));
            if c.expr_body {
                v.push(b_expr(b, c.body));
            } else {
                v.push(b_block(b, c.body));
            }
        },
        NODE_MATCH => {
            v.push(b_match(b, id));
        },
        NODE_NEW => {
            v.push(b.p.txt("new "));
            v.push(b_type(b, n.as_data.new_expr.ty));
            if n.as_data.new_expr.initializer != NODE_NONE {
                let init = nd(b, n.as_data.new_expr.initializer);
                if init.kind == NodeKind::NODE_STRUCT_INITIALIZER {
                    v.push(b.p.txt(" "));
                    v.push(
                        b_struct_init_fields(
                            b,
                            init.as_data.struct_initializer.fields,
                            nd(b, init.as_data.struct_initializer.ty).span.end,
                            init.span.end,
                        ),
                    );
                } else {
                    v.push(b.p.txt(" ("));
                    v.push(b_expr(b, n.as_data.new_expr.initializer));
                    v.push(b.p.txt(")"));
                }
            }
        },
        NODE_SIZEOF => {
            v.push(b.p.txt("sizeof("));
            v.push(b_sizeof_arg(b, n.as_data.single.value));
            v.push(b.p.txt(")"));
        },
        NODE_ALIGNOF => {
            v.push(b.p.txt("alignof("));
            v.push(b_sizeof_arg(b, n.as_data.single.value));
            v.push(b.p.txt(")"));
        },
        NODE_VA_EXPR => {
            let va = n.as_data.va_op;
            if va.op == VA_START {
                v.push(b.p.txt("va_start("));
            } else if va.op == VA_ARG {
                v.push(b.p.txt("va_arg("));
            } else {
                v.push(b.p.txt("va_end("));
            }
            v.push(b_expr(b, va.ap));
            if va.extra != NODE_NONE {
                v.push(b.p.txt(", "));
                if va.op == VA_ARG {
                    v.push(b_type(b, va.extra));
                } else {
                    v.push(b_expr(b, va.extra));
                }
            }
            v.push(b.p.txt(")"));
        },
        NODE_ARRAY_LITERAL => {
            let mut az = Vector::<d::DocId>::new();
            let elems = n.as_data.array_literal.elements;
            if n.as_data.array_literal.repeat && elems.len == 2 {
                v.push(b.p.txt("["));
                v.push(b_expr(b, list_at(b, elems, 0)));
                v.push(b.p.txt("; "));
                v.push(b_expr(b, list_at(b, elems, 1)));
                v.push(b.p.txt("]"));
                return b.p.concat(&v);
            }
            for i in 0..elems.len {
                let e = list_at(b, elems, i);
                if nd(b, e).kind == NodeKind::NODE_FIELD_INITIALIZER {
                    // designated element `[index] = value`
                    let fi = nd(b, e).as_data.field_initializer;
                    let mut dv = Vector::<d::DocId>::new();
                    dv.push(b.p.txt("["));
                    dv.push(b_expr(b, fi.name));
                    dv.push(b.p.txt("] = "));
                    dv.push(b_expr(b, fi.value));
                    let dd = b.p.concat(&dv);
                    az.push(dd);
                } else {
                    az.push(b_expr(b, e));
                }
            }
            v.push(b_comma_list_tr(b, "[", &az, elems, n.span.start + 1, n.span.end, "]", true));
        },
        NODE_TUPLE => {
            let mut az = Vector::<d::DocId>::new();
            let tel = n.as_data.array_literal.elements;
            b_each(b, tel, 0, &mut az);
            v.push(b_comma_list_tr(b, "(", &az, tel, n.span.start + 1, n.span.end, ")", false));
        },
        NODE_STRUCT_INITIALIZER => {
            v.push(b_expr_type_path(b, n.as_data.struct_initializer.ty));
            v.push(b.p.txt(" "));
            v.push(
                b_struct_init_fields(
                    b,
                    n.as_data.struct_initializer.fields,
                    nd(b, n.as_data.struct_initializer.ty).span.end,
                    n.span.end,
                ),
            );
        },
        NODE_FIELD_INITIALIZER => {
            v.push(node_text(b, n.as_data.field_initializer.name));
            v.push(b.p.txt(": "));
            v.push(b_expr(b, n.as_data.field_initializer.value));
        },
        NODE_IF => {
            // if-expression (`let x = if c { a; } else { b; };`)
            v.push(b_if(b, id));
        },
        NODE_BLOCK => {
            v.push(b_block(b, id));
        },
        _ => {
            v.push(node_text(b, id));
        },
    };
    let r = b.p.concat(&v);
    return r;
}

// A type path in EXPRESSION position (struct initializer heads): generic args need the turbofish
// (`Vector::<T, A> { .. }`), unlike type position.
fn b_expr_type_path(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    if n.kind != NodeKind::NODE_TYPE_PATH {
        return b_type(b, id);
    }
    let mut v = Vector::<d::DocId>::new();
    let parts = n.as_data.type_path.parts;
    for i in 0..parts.len {
        if i > 0 {
            v.push(b.p.txt("::"));
        }
        let __h = list_at(b, parts, i);
        v.push(node_text(b, __h));
    }
    let args = n.as_data.type_path.args;
    if args.len > 0 {
        v.push(b.p.txt("::"));
        let mut az = Vector::<d::DocId>::new();
        for i in 0..args.len {
            let a = list_at(b, args, i);
            if nd(b, a).kind == NodeKind::NODE_LITERAL {
                az.push(node_text(b, a));
            } else if fmt_const_arg(b, a) {
                az.push(b_const_arg(b, a));
            } else {
                az.push(b_type(b, a));
            }
        }
        v.push(b_comma_list(b, "<", &az, ">", false));
    }
    let r = b.p.concat(&v);
    return r;
}

// A const-generic argument written as an expression. It reaches here as an ordinary expression node --
// nothing a TYPE position can otherwise hold -- and the braces have to come back or it will not re-parse.
const fn fmt_const_arg(b: &Builder, id: NodeId) bool {
    let k = nd(b, id).kind;
    return k == NodeKind::NODE_BINARY || k == NodeKind::NODE_UNARY || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF || k == NodeKind::NODE_CALL;
}

fn b_const_arg(b: &mut Builder, id: NodeId) d::DocId {
    let mut v = Vector::<d::DocId>::new();
    v.push(b.p.txt("{"));
    v.push(b_expr(b, id));
    v.push(b.p.txt("}"));
    return b.p.concat(&v);
}

// sizeof/alignof accept a type (usual) -- the parser stores a type node.
fn b_sizeof_arg(b: &mut Builder, id: NodeId) d::DocId {
    return b_type(b, id);
}

fn b_struct_init_fields(b: &mut Builder, fields: NodeList, open_end: u32, close_pos: u32) d::DocId {
    let mut fz = Vector::<d::DocId>::new();
    if fields.len == 0 {
        if !gap_has_trivia(b, open_end, close_pos) {
            return b.p.txt("{}");
        }
        return b_comma_list_tr(b, "{", &fz, fields, open_end, close_pos, "}", false);
    }
    b_each(b, fields, 0, &mut fz);
    // A comment between the fields only fits the broken shape, which is what the trivia-aware list builds;
    // without one, keep the flat `{ a: 1 }` form below byte for byte.
    let mut has = gap_has_trivia(b, open_end, nd(b, list_at(b, fields, 0)).span.start);
    for i in 1..fields.len {
        let pe = nd(b, list_at(b, fields, i - 1)).span.end;
        if gap_has_trivia(b, pe, nd(b, list_at(b, fields, i)).span.start) {
            has = true;
        }
    }
    if gap_has_trivia(b, nd(b, list_at(b, fields, fields.len - 1)).span.end, close_pos) {
        has = true;
    }
    if has {
        return b_comma_list_tr(b, "{", &fz, fields, open_end, close_pos, "}", true);
    }
    // struct literals: `{ a: 1, b: 2 }` flat / broken one per line with trailing comma
    let mut inner = Vector::<d::DocId>::new();
    inner.push(b.p.line());
    for i in 0..fz.len() {
        if i > 0 {
            inner.push(b.p.txt(","));
            inner.push(b.p.line());
        }
        inner.push(*fz.at(i));
    }
    inner.push(b.p.ifbreak(",", false));
    let ic = b.p.concat(&inner);
    let mut parts = Vector::<d::DocId>::new();
    parts.push(b.p.txt("{"));
    parts.push(b.p.indent(ic));
    parts.push(b.p.line());
    parts.push(b.p.txt("}"));
    let body = b.p.concat(&parts);
    return b.p.group(body);
}

fn op_text(b: &mut Builder, op: tt::TokenType) d::DocId {
    switch op {
        Plus => {
            return b.p.txt("+");
        },
        Minus => {
            return b.p.txt("-");
        },
        Star => {
            return b.p.txt("*");
        },
        Slash => {
            return b.p.txt("/");
        },
        Percent => {
            return b.p.txt("%");
        },
        EqualEqual => {
            return b.p.txt("==");
        },
        BangEqual => {
            return b.p.txt("!=");
        },
        LessThan => {
            return b.p.txt("<");
        },
        LessThanEqual => {
            return b.p.txt("<=");
        },
        GreaterThan => {
            return b.p.txt(">");
        },
        GreaterThanEqual => {
            return b.p.txt(">=");
        },
        AmpersandAmpersand => {
            return b.p.txt("&&");
        },
        PipePipe => {
            return b.p.txt("||");
        },
        Ampersand => {
            return b.p.txt("&");
        },
        Pipe => {
            return b.p.txt("|");
        },
        Caret => {
            return b.p.txt("^");
        },
        LeftShift => {
            return b.p.txt("<<");
        },
        RightShift => {
            return b.p.txt(">>");
        },
        Equal => {
            return b.p.txt("=");
        },
        PlusEqual => {
            return b.p.txt("+=");
        },
        MinusEqual => {
            return b.p.txt("-=");
        },
        StarEqual => {
            return b.p.txt("*=");
        },
        SlashEqual => {
            return b.p.txt("/=");
        },
        PercentEqual => {
            return b.p.txt("%=");
        },
        AmpersandEqual => {
            return b.p.txt("&=");
        },
        PipeEqual => {
            return b.p.txt("|=");
        },
        CaretEqual => {
            return b.p.txt("^=");
        },
        LeftShiftEqual => {
            return b.p.txt("<<=");
        },
        RightShiftEqual => {
            return b.p.txt(">>=");
        },
        _ => {
            return b.p.txt("?op?");
        },
    };
    return b.p.txt("?op?");
}

// ---- statements -----------------------------------------------------------------------------------

fn stmt_starts_with(b: &Builder, id: NodeId, kw: str) bool {
    let s = nd(b, id).span;
    if (s.end - s.start) as usize < kw.len() {
        return false;
    }
    let mut i: usize = 0;
    while i < kw.len() {
        if b.src.byte_at(s.start as usize + i) != kw.byte_at(i) {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn b_stmt(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let mut v = Vector::<d::DocId>::new();
    switch n.kind {
        NODE_LET => {
            let l = n.as_data.let_stmt;
            if l.is_mutable {
                v.push(b.p.txt("let mut "));
            } else {
                v.push(b.p.txt("let "));
            }
            v.push(node_text(b, l.name));
            if l.ty != NODE_NONE {
                v.push(b.p.txt(": "));
                v.push(b_type(b, l.ty));
            }
            if l.value != NODE_NONE {
                v.push(b.p.txt(" = "));
                v.push(b_expr(b, l.value));
            }
            v.push(b.p.txt(";"));
        },
        NODE_RETURN => {
            let vals = n.as_data.return_stmt.values;
            // a bare `return;` in a named-return fn carries parser-synthesized identifiers whose
            // spans point back INTO the signature: print the bare form the user wrote
            let mut synthetic = vals.len > 0;
            if synthetic {
                synthetic = nd(b, list_at(b, vals, 0)).span.start < n.span.start;
            }
            if vals.len == 0 || synthetic {
                v.push(b.p.txt("return;"));
            } else {
                v.push(b.p.txt("return "));
                for i in 0..vals.len {
                    if i > 0 {
                        v.push(b.p.txt(", "));
                    }
                    let __h = list_at(b, vals, i);
                    v.push(b_expr(b, __h));
                }
                v.push(b.p.txt(";"));
            }
        },
        NODE_BREAK | NODE_CONTINUE => {
            if n.kind == NodeKind::NODE_BREAK {
                v.push(b.p.txt("break"));
            } else {
                v.push(b.p.txt("continue"));
            }
            let f = n.as_data.flow;
            if f.label.end > f.label.start {
                v.push(b.p.txt(" "));
                v.push(span_doc(b, f.label));
            }
            if f.value != NODE_NONE {
                v.push(b.p.txt(" "));
                v.push(b_expr(b, f.value));
            }
            v.push(b.p.txt(";"));
        },
        NODE_ASM => {
            let d = n.as_data.asm_stmt;
            v.push(b.p.txt("asm("));
            v.push(b_expr(b, d.template));
            if d.outputs.len != 0 || d.inputs.len != 0 || d.clobbers.len != 0 {
                v.push(b.p.txt(" : "));
                b_asm_operands(b, &mut v, d.outputs);
            }
            if d.inputs.len != 0 || d.clobbers.len != 0 {
                v.push(b.p.txt(" : "));
                b_asm_operands(b, &mut v, d.inputs);
            }
            if d.clobbers.len != 0 {
                v.push(b.p.txt(" : "));
                for k in 0..d.clobbers.len {
                    if k != 0 {
                        v.push(b.p.txt(", "));
                    }
                    v.push(b_expr(b, list_at(b, d.clobbers, k)));
                }
            }
            v.push(b.p.txt(");"));
        },
        NODE_DEFER => {
            v.push(b.p.txt("defer "));
            v.push(b_expr(b, n.as_data.single.value));
            v.push(b.p.txt(";"));
        },
        NODE_LAUNCH => {
            // Sugar marker (pre-desugar): SingleData wraps the placeholder call; print its sole operand.
            let inner = n.as_data.single.value;
            v.push(b.p.txt("launch "));
            v.push(b_expr(b, list_at(b, nd(b, inner).as_data.call.args, 0)));
            v.push(b.p.txt(";"));
        },
        NODE_SELECT => {
            v.push(b_select(b, id));
        },
        NODE_IF => {
            v.push(b_if(b, id));
        },
        NODE_WHILE => {
            let w = n.as_data.while_stmt;
            if w.label.end > w.label.start {
                v.push(span_doc(b, w.label));
                v.push(b.p.txt(": "));
            }
            if w.is_do {
                v.push(b.p.txt("do "));
                v.push(b_block(b, w.body));
                v.push(b.p.txt(" while "));
                v.push(b_expr(b, w.condition));
                v.push(b.p.txt(";"));
            } else if w.condition == NODE_NONE {
                v.push(b.p.txt("loop "));
                v.push(b_block(b, w.body));
            } else {
                v.push(b.p.txt("while "));
                v.push(b_expr(b, w.condition));
                v.push(b.p.txt(" "));
                v.push(b_block(b, w.body));
            }
        },
        NODE_FOR | NODE_INLINE_FOR => {
            let f = n.as_data.for_stmt;
            if f.label.end > f.label.start {
                v.push(span_doc(b, f.label));
                v.push(b.p.txt(": "));
            }
            if n.kind == NodeKind::NODE_INLINE_FOR {
                v.push(b.p.txt("inline "));
            }
            v.push(b.p.txt("for "));
            v.push(node_text(b, f.binding));
            v.push(b.p.txt(" in "));
            v.push(b_expr(b, f.iterable));
            v.push(b.p.txt(" "));
            v.push(b_block(b, f.body));
        },
        NODE_PARALLEL_FOR => {
            // The marker's body is the closure the parser wrapped the block in; print the block.
            let f = n.as_data.for_stmt;
            v.push(b.p.txt("parallel for "));
            v.push(node_text(b, f.binding));
            v.push(b.p.txt(" in "));
            v.push(b_expr(b, f.iterable));
            v.push(b.p.txt(" "));
            v.push(b_block(b, nd(b, f.body).as_data.closure.body));
        },
        NODE_EXPRESSION_STATEMENT => {
            let e = n.as_data.single.value;
            v.push(b_expr(b, e));
            let en = nd(b, e);
            let mut block_form = en.kind == NodeKind::NODE_BLOCK;
            if en.kind == NodeKind::NODE_UNARY && (en.as_data.unary.op == tt::TokenType::Unsafe || en.as_data.unary.op == tt::TokenType::Move) && is_block_node(
                b,
                en.as_data.unary.operand,
            ) {
                block_form = true;
            }
            if !block_form {
                v.push(b.p.txt(";"));
            }
        },
        NODE_MATCH => {
            // if-let / while-let desugar to a match spanning the original statement: emit verbatim.
            if stmt_starts_with(b, id, "if") || stmt_starts_with(b, id, "while") {
                v.push(node_text(b, id));
            } else {
                v.push(b_match(b, id));
                v.push(b.p.txt(";"));
            }
        },
        NODE_BLOCK => {
            v.push(b_block(b, id));
        },
        NODE_CONST | NODE_STATIC_ASSERT => {
            v.push(b_item(b, id));
        },
        _ => {
            v.push(node_text(b, id));
            v.push(b.p.txt(";"));
        },
    };
    let r = b.p.concat(&v);
    return r;
}

fn b_if(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let f = n.as_data.if_stmt;
    let mut v = Vector::<d::DocId>::new();
    v.push(b.p.txt("if "));
    v.push(b_expr(b, f.condition));
    v.push(b.p.txt(" "));
    v.push(b_block(b, f.then_branch));
    if f.else_branch != NODE_NONE {
        v.push(b.p.txt(" else "));
        if nd(b, f.else_branch).kind == NodeKind::NODE_IF {
            v.push(b_if(b, f.else_branch));
        } else {
            v.push(b_block(b, f.else_branch));
        }
    }
    let r = b.p.concat(&v);
    return r;
}

fn b_match(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let m = n.as_data.match_expr;
    let mut v = Vector::<d::DocId>::new();
    // `switch` and `match` are keyword synonyms parsed to the same node; keep the author's.
    if b.src.byte_at(n.span.start as usize) == b'm' {
        v.push(b.p.txt("match "));
    } else {
        v.push(b.p.txt("switch "));
    }
    v.push(b_expr(b, m.value));
    v.push(b.p.txt(" {"));
    let mut body = Vector::<d::DocId>::new();
    let mut prev_end = 0u32;
    for i in 0..m.arms.len {
        let arm = list_at(b, m.arms, i);
        let asp = nd(b, arm).span;
        if i == 0 {
            body.push(b.p.hardline());
            let floor = item_gap_floor(b, n.span.start, asp.start);
            emit_lead_list(b, floor, asp.start, &mut body);
        } else {
            emit_gap_vertical(b, prev_end, asp.start, &mut body, false);
        }
        body.push(b_match_arm(b, arm));
        prev_end = asp.end;
    }
    if m.arms.len > 0 {
        emit_tail_list(b, prev_end, n.span.end - 1, &mut body);
        let ic = b.p.concat(&body);
        v.push(b.p.indent(ic));
        v.push(b.p.hardline());
    }
    v.push(b.p.txt("}"));
    let r = b.p.concat(&v);
    return r;
}

// `select { .. }` (sugar marker, pre-desugar). Laid out like `switch`, but its arms carry no separator and
// the operation is REBUILT from the pieces the parser kept: `ch.recv()` survives as just `ch`.
fn b_select(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let arms = n.as_data.block.statements;
    let mut v = Vector::<d::DocId>::new();
    v.push(b.p.txt("select {"));
    let mut body = Vector::<d::DocId>::new();
    let mut prev_end = 0u32;
    for i in 0..arms.len {
        let arm = list_at(b, arms, i);
        let asp = nd(b, arm).span;
        if i == 0 {
            body.push(b.p.hardline());
            let floor = item_gap_floor(b, n.span.start, asp.start);
            emit_lead_list(b, floor, asp.start, &mut body);
        } else {
            emit_gap_vertical(b, prev_end, asp.start, &mut body, false);
        }
        body.push(b_select_arm(b, arm));
        prev_end = asp.end;
    }
    if arms.len > 0 {
        emit_tail_list(b, prev_end, n.span.end - 1, &mut body);
        let ic = b.p.concat(&body);
        v.push(b.p.indent(ic));
        v.push(b.p.hardline());
    }
    v.push(b.p.txt("}"));
    let r = b.p.concat(&v);
    return r;
}

fn b_select_arm(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let a = n.as_data.select_arm;
    let mut v = Vector::<d::DocId>::new();
    if a.binding != NODE_NONE {
        v.push(b_expr(b, nd(b, a.binding).as_data.let_stmt.name));
        v.push(b.p.txt(" = "));
    }
    switch a.kind {
        SELECT_RECV => {
            v.push(b_expr(b, a.op));
            v.push(b.p.txt(".recv()"));
        },
        SELECT_SEND => {
            v.push(b_expr(b, a.op));
            v.push(b.p.txt(".send("));
            v.push(b_expr(b, a.value));
            v.push(b.p.txt(")"));
        },
        SELECT_TIMEOUT => {
            v.push(b.p.txt("timeout("));
            v.push(b_expr(b, a.op));
            v.push(b.p.txt(")"));
        },
        SELECT_DEFAULT => {
            v.push(b.p.txt("default"));
        },
    };
    v.push(b.p.txt(" => "));
    v.push(b_block(b, a.body));
    let r = b.p.concat(&v);
    return r;
}

fn b_match_arm(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let a = n.as_data.match_arm;
    let mut v = Vector::<d::DocId>::new();
    v.push(b_pattern(b, a.pattern));
    if a.guard != NODE_NONE {
        v.push(b.p.txt(" if "));
        v.push(b_expr(b, a.guard));
    }
    v.push(b.p.txt(" => "));
    if is_block_node(b, a.body) {
        v.push(b_block(b, a.body));
    } else {
        v.push(b_expr(b, a.body));
    }
    v.push(b.p.txt(","));
    let r = b.p.concat(&v);
    return r;
}

// A block: `{}` when empty (dangling comments kept), otherwise always broken.
fn b_block(b: &mut Builder, id: NodeId) d::DocId {
    let n = nd(b, id);
    let stmts = n.as_data.block.statements;
    let mut v = Vector::<d::DocId>::new();
    v.push(b.p.txt("{"));
    let mut body = Vector::<d::DocId>::new();
    let mut prev_end = n.span.start + 1;
    let mut first = true;
    for i in 0..stmts.len {
        let sid = list_at(b, stmts, i);
        let ssp = nd(b, sid).span;
        if ssp.start < n.span.start {
            continue; // parser-synthesized (named-return bindings): not in the source text
        }
        if first {
            body.push(b.p.hardline());
            emit_lead_list(b, prev_end, ssp.start, &mut body);
            first = false;
        } else {
            emit_gap_vertical(b, prev_end, ssp.start, &mut body, false);
        }
        body.push(b_stmt(b, sid));
        prev_end = ssp.end;
    }
    if !first {
        emit_tail_list(b, prev_end, n.span.end - 1, &mut body);
        let ic = b.p.concat(&body);
        v.push(b.p.indent(ic));
        v.push(b.p.hardline());
    } else {
        let mut segs = Vector::<TriviaSeg>::new();
        scan_gap(b, prev_end, n.span.end - 1, &mut segs);
        if segs.len() > 0 {
            let mut inner = Vector::<d::DocId>::new();
            for k in 0..segs.len() {
                let sg = *segs.at(k);
                if sg.blank_before && k > 0 {
                    inner.push(b.p.blankline());
                } else {
                    inner.push(b.p.hardline());
                }
                inner.push(b.p.span(sg.start, sg.end));
                if !sg.is_attr {
                    b.emitted_trivia = b.emitted_trivia + 1;
                }
            }
            let ic = b.p.concat(&inner);
            v.push(b.p.indent(ic));
            v.push(b.p.hardline());
        }
    }
    v.push(b.p.txt("}"));
    let r = b.p.concat(&v);
    return r;
}

// ---- items ----------------------------------------------------------------------------------------

// True when the item carries @fmt.skip: it is then emitted verbatim from its source span.
fn fmt_skipped(b: &Builder, id: NodeId) bool {
    let na = unsafe b.ast.attrs.len();
    for i in 0..na {
        let a = *unsafe b.ast.attrs.at(i);
        if a.owner == id && a.kind == AttrKind::ATTR_FMT_SKIP as u8 {
            return true;
        }
    }
    return false;
}

fn b_item(b: &mut Builder, id: NodeId) d::DocId {
    if fmt_skipped(b, id) {
        return node_text(b, id);
    }
    let n = nd(b, id);
    let mut v = Vector::<d::DocId>::new();
    switch n.kind {
        NODE_FUNCTION => {
            let f = n.as_data.function;
            if f.is_public {
                v.push(b.p.txt("pub "));
            }
            if f.is_extern && f.body == NODE_NONE {}
            if f.is_unsafe {
                v.push(b.p.txt("unsafe "));
            }
            if f.is_const {
                v.push(b.p.txt("const "));
            }
            v.push(b.p.txt("fn "));
            v.push(node_text(b, f.name));
            b_generics_lt(b, b.ast.lifetimes_of(id), f.generics, &mut v);
            let mut ps = Vector::<d::DocId>::new();
            b_each(b, f.params, 3, &mut ps);
            if f.is_variadic {
                ps.push(b.p.txt("..."));
            }
            // Parameters normally GROUP (`a, b: i32`), which is not index-aligned with the node list -- so a
            // list carrying comments is built one parameter per doc instead. Grouping is a flat-form
            // nicety, and a comment forces the broken form anyway.
            let popen = if f.generics.len != 0 {
                nd(b, list_at(b, f.generics, f.generics.len - 1)).span.end;
            } else {
                nd(b, f.name).span.end;
            };
            let pclose = if f.params.len != 0 {
                find_close(b, nd(b, list_at(b, f.params, f.params.len - 1)).span.end, n.span.end, b')');
            } else {
                popen;
            };
            if f.params.len != 0 && list_has_trivia(b, f.params, popen, pclose) {
                let mut pu = Vector::<d::DocId>::new();
                for pi in 0..f.params.len {
                    pu.push(b_param(b, list_at(b, f.params, pi)));
                }
                v.push(b_comma_list_tr(b, "(", &pu, f.params, popen, pclose, ")", true));
            } else {
                v.push(b_comma_list(b, "(", &ps, ")", true));
            }
            if f.returns.len > 0 {
                v.push(b.p.txt(" "));
                v.push(b_returns(b, f.returns));
            }
            if f.where_clause.len > 0 {
                v.push(b.p.txt(" where "));
                for i in 0..f.where_clause.len {
                    if i > 0 {
                        v.push(b.p.txt(", "));
                    }
                    let w = nd(b, list_at(b, f.where_clause, i)).as_data.where_predicate;
                    v.push(b_type(b, w.ty));
                    v.push(b.p.txt(": "));
                    for k in 0..w.bounds.len {
                        if k > 0 {
                            v.push(b.p.txt(" + "));
                        }
                        let __h = list_at(b, w.bounds, k);
                        v.push(b_type(b, __h));
                    }
                }
            }
            if f.body != NODE_NONE {
                v.push(b.p.txt(" "));
                v.push(b_block(b, f.body));
            } else {
                v.push(b.p.txt(";"));
            }
        },
        NODE_STRUCT | NODE_ENUM => {
            let a = n.as_data.aggregate;
            if a.is_public {
                v.push(b.p.txt("pub "));
            }
            if n.kind == NodeKind::NODE_ENUM {
                v.push(b.p.txt("enum "));
            } else if a.is_union {
                v.push(b.p.txt("union "));
            } else {
                v.push(b.p.txt("struct "));
            }
            v.push(node_text(b, a.name));
            b_generics_lt(b, b.ast.lifetimes_of(id), a.generics, &mut v);
            if a.is_tuple {
                let mut fz = Vector::<d::DocId>::new();
                for i in 0..a.members.len {
                    let fd = nd(b, list_at(b, a.members, i)).as_data.field;
                    fz.push(b_type(b, fd.ty));
                }
                v.push(b_comma_list(b, "(", &fz, ")", false));
                v.push(b.p.txt(";"));
            } else if a.members.len == 0 {
                if n.span.end > n.span.start && b.src.byte_at((n.span.end - 1) as usize) == b';' {
                    v.push(b.p.txt(";"));
                } else {
                    v.push(b.p.txt(" {}"));
                }
            } else {
                v.push(b.p.txt(" {"));
                let mut body = Vector::<d::DocId>::new();
                let first_sp = nd(b, list_at(b, a.members, 0)).span;
                let mut prev_end = first_sp.start;
                for i in 0..a.members.len {
                    let mid = list_at(b, a.members, i);
                    let msp = nd(b, mid).span;
                    if i == 0 {
                        body.push(b.p.hardline());
                        let floor = item_gap_floor(b, n.span.start, msp.start);
                        emit_lead_list(b, floor, msp.start, &mut body);
                    } else {
                        emit_gap_vertical(b, prev_end, msp.start, &mut body, false);
                    }
                    if n.kind == NodeKind::NODE_ENUM {
                        body.push(b_variant(b, mid));
                    } else {
                        body.push(b_field(b, mid));
                    }
                    body.push(b.p.txt(","));
                    prev_end = msp.end;
                }
                emit_tail_list(b, prev_end, n.span.end - 1, &mut body);
                let ic = b.p.concat(&body);
                v.push(b.p.indent(ic));
                v.push(b.p.hardline());
                v.push(b.p.txt("}"));
            }
        },
        NODE_INTERFACE => {
            let itf = n.as_data.interface_def;
            if itf.is_public {
                v.push(b.p.txt("pub "));
            }
            v.push(b.p.txt("interface "));
            v.push(node_text(b, itf.name));
            b_generics_lt(b, b.ast.lifetimes_of(id), itf.generics, &mut v);
            if itf.bounds.len > 0 {
                v.push(b.p.txt(": "));
                for i in 0..itf.bounds.len {
                    if i > 0 {
                        v.push(b.p.txt(" + "));
                    }
                    let __h = list_at(b, itf.bounds, i);
                    v.push(b_type(b, __h));
                }
            }
            v.push(b.p.txt(" "));
            v.push(b_item_body(b, itf.items, n.span));
        },
        NODE_EXTEND => {
            let e = n.as_data.extend_def;
            if e.is_unsafe {
                v.push(b.p.txt("unsafe "));
            }
            v.push(b.p.txt("extend"));
            if e.generics.len > 0 {
                b_generics_lt(b, b.ast.lifetimes_of(id), e.generics, &mut v);
            }
            v.push(b.p.txt(" "));
            v.push(b_type(b, e.target_type));
            if e.interface_type != NODE_NONE {
                v.push(b.p.txt(" as "));
                v.push(b_type(b, e.interface_type));
            }
            v.push(b.p.txt(" "));
            v.push(b_item_body(b, e.items, n.span));
        },
        NODE_TYPE_ALIAS => {
            let t = n.as_data.type_alias;
            if t.is_public {
                v.push(b.p.txt("pub "));
            }
            v.push(b.p.txt("type "));
            v.push(node_text(b, t.name));
            b_generics_lt(b, b.ast.lifetimes_of(id), t.generics, &mut v);
            if t.ty != NODE_NONE {
                v.push(b.p.txt(" = "));
                v.push(b_type(b, t.ty));
            }
            v.push(b.p.txt(";"));
        },
        NODE_CONST => {
            let c = n.as_data.const_def;
            if c.is_public {
                v.push(b.p.txt("pub "));
            }
            if c.is_static_mut {
                v.push(b.p.txt("static mut "));
            } else {
                v.push(b.p.txt("const "));
            }
            v.push(node_text(b, c.name));
            if c.ty != NODE_NONE {
                v.push(b.p.txt(": "));
                v.push(b_type(b, c.ty));
            }
            if c.value != NODE_NONE {
                v.push(b.p.txt(" = "));
                v.push(b_expr(b, c.value));
            }
            v.push(b.p.txt(";"));
        },
        NODE_STATIC_ASSERT => {
            v.push(b.p.txt("static_assert("));
            v.push(b_expr(b, n.as_data.binary.left));
            if n.as_data.binary.right != NODE_NONE {
                v.push(b.p.txt(", "));
                v.push(b_expr(b, n.as_data.binary.right));
            }
            v.push(b.p.txt(");"));
        },
        NODE_EXTERN_BLOCK => {
            let e = n.as_data.extern_block;
            v.push(b.p.txt("extern "));
            if e.abi != NODE_NONE {
                v.push(node_text(b, e.abi));
                v.push(b.p.txt(" "));
            }
            if e.header != NODE_NONE {
                v.push(node_text(b, e.header));
                v.push(b.p.txt(" "));
            }
            v.push(b_item_body(b, e.items, n.span));
        },
        NODE_IMPORT => {
            let im = n.as_data.import_decl;
            v.push(b.p.txt("import "));
            for i in 0..im.path.len {
                if i > 0 {
                    v.push(b.p.txt("::"));
                }
                let __h = list_at(b, im.path, i);
                v.push(node_text(b, __h));
            }
            if im.glob {
                v.push(b.p.txt(" as *"));
            } else if im.alias != NODE_NONE {
                v.push(b.p.txt(" as "));
                v.push(node_text(b, im.alias));
            }
            v.push(b.p.txt(";"));
        },
        _ => {
            v.push(node_text(b, id));
        },
    };
    let r = b.p.concat(&v);
    return r;
}

fn b_field(b: &mut Builder, id: NodeId) d::DocId {
    let f = nd(b, id).as_data.field;
    let mut v = Vector::<d::DocId>::new();
    if f.is_public {
        v.push(b.p.txt("pub "));
    }
    v.push(node_text(b, f.name));
    v.push(b.p.txt(": "));
    v.push(b_type(b, f.ty));
    let r = b.p.concat(&v);
    return r;
}

fn b_variant(b: &mut Builder, id: NodeId) d::DocId {
    let va = nd(b, id).as_data.variant;
    let mut v = Vector::<d::DocId>::new();
    v.push(node_text(b, va.name));
    if va.payload.len > 0 {
        if va.struct_payload {
            v.push(b.p.txt(" { "));
            for i in 0..va.payload.len {
                if i > 0 {
                    v.push(b.p.txt(", "));
                }
                let __h = list_at(b, va.payload, i);
                v.push(b_field(b, __h));
            }
            v.push(b.p.txt(" }"));
        } else {
            let mut pz = Vector::<d::DocId>::new();
            b_each(b, va.payload, 1, &mut pz);
            v.push(b_comma_list(b, "(", &pz, ")", false));
        }
    }
    if va.value != NODE_NONE {
        v.push(b.p.txt(" = "));
        v.push(b_expr(b, va.value));
    }
    let r = b.p.concat(&v);
    return r;
}

// The `{ items }` body of interfaces, extends, extern blocks: items with gap trivia, always broken.
fn b_item_body(b: &mut Builder, items: NodeList, outer: tok::Span) d::DocId {
    let mut v = Vector::<d::DocId>::new();
    if items.len == 0 {
        v.push(b.p.txt("{}"));
        let r0 = b.p.concat(&v);
        return r0;
    }
    v.push(b.p.txt("{"));
    let mut body = Vector::<d::DocId>::new();
    let mut prev_end = 0u32;
    for i in 0..items.len {
        let iid = list_at(b, items, i);
        let isp = nd(b, iid).span;
        if i == 0 {
            body.push(b.p.hardline());
            let floor = item_gap_floor(b, outer.start, isp.start);
            emit_lead_list(b, floor, isp.start, &mut body);
        } else {
            emit_gap_vertical(b, prev_end, isp.start, &mut body, false);
        }
        body.push(b_item(b, iid));
        prev_end = isp.end;
    }
    emit_tail_list(b, prev_end, outer.end - 1, &mut body);
    let ic = b.p.concat(&body);
    v.push(b.p.indent(ic));
    v.push(b.p.hardline());
    v.push(b.p.txt("}"));
    let r = b.p.concat(&v);
    return r;
}

// Find the `{` between `from` and `to` so leading trivia scans start after it. Scans FORWARD and
// skips comment interiors: the first member's leading comment may itself contain a brace, and a
// backward scan would land inside it -- dropping the comment from the lead-trivia window.
fn item_gap_floor(b: &Builder, from: u32, to: u32) u32 {
    let mut i = from as usize;
    while i < to as usize {
        let c = b.src.byte_at(i);
        if c == b'/' && i + 1 < to as usize && b.src.byte_at(i + 1) == b'/' {
            while i < to as usize && b.src.byte_at(i) != b'\n' {
                i = i + 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < to as usize && b.src.byte_at(i + 1) == b'*' {
            i = i + 2;
            while i + 1 < to as usize && !(b.src.byte_at(i) == b'*' && b.src.byte_at(i + 1) == b'/') {
                i = i + 1;
            }
            i = i + 2;
            continue;
        }
        if c == b'{' {
            return (i + 1) as u32;
        }
        i = i + 1;
    }
    return from;
}

// ---- entry ----------------------------------------------------------------------------------------

/// Build and render the whole program. Returns the number of comment segments emitted (the caller
/// checks it against the lexer's comment-token count and refuses to write on a mismatch).
pub fn format_program(ast: *const Ast, source: str, width: i32, out: &mut String) usize {
    let root = unsafe ast.root;
    let mut b = Builder { p: d::DocPool::new(source.ptr()), ast: ast, src: source, emitted_trivia: 0 };
    let items = nd(&b, root).as_data.program.items;
    let mut parts = Vector::<d::DocId>::new();
    let mut prev_end = 0u32;
    for i in 0..items.len {
        let iid = list_at(&b, items, i);
        let isp = nd(&b, iid).span;
        if i == 0 {
            emit_lead_list(&mut b, 0, isp.start, &mut parts);
        } else {
            emit_gap_vertical(&mut b, prev_end, isp.start, &mut parts, false);
        }
        parts.push(b_item(&mut b, iid));
        prev_end = isp.end;
    }
    emit_tail_list(&mut b, prev_end, source.len() as u32, &mut parts);
    let doc = b.p.concat(&parts);
    d::render(&b.p, doc, width, out);
    let n = b.emitted_trivia;
    return n;
}
