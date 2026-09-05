// AST -> Doc builder for the canonical formatter: format_node lowers every NodeKind to the document
// IR in fmt::doc; the renderer then chooses line breaks by width. Layout policy (user-approved):
// fully canonical: blocks always break, lists group with IfBreak trailing commas, indentation is
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

/// Per-file formatter state: the doc pool, the AST being printed, and the source bytes trivia is read from.
pub struct Builder<'a> {
    pub p: d::DocPool<'a>,
    pub ast: *const Ast,
    pub src: str<'a>,
    pub emitted_trivia: usize, // comment segments emitted (attrs are separate and not counted)
}

struct TriviaSeg {
    pub start: u32,
    pub end: u32,
    pub trailing: bool, // began before the gap's first newline: belongs to the previous element
    pub is_attr: bool,
    pub blank_before: bool, // a blank line separated this segment from what precedes it
}

/// Build and render the whole program. Returns the number of comment segments emitted (the caller
/// checks it against the lexer's comment-token count and refuses to write on a mismatch).
pub fn format_program(ast: *const Ast, source: str, width: i32, out: &mut String) usize {
    let root = unsafe ast.root;
    let mut b = Builder { p: d::DocPool::new(source.ptr()), ast: ast, src: source, emitted_trivia: 0 };
    let items = b.nd(root).as_data.program.items;
    let mut parts = Vector::<d::DocId>::new();
    let mut prev_end = 0u32;
    for i in 0..items.len {
        let iid = b.list_at(items, i);
        let isp = b.nd(iid).span;
        if i == 0 {
            b.emit_lead_list(0, isp.start, &mut parts);
        } else {
            b.emit_gap_vertical(prev_end, isp.start, &mut parts, false);
        }
        parts.push(b.b_item(iid));
        prev_end = isp.end;
    }
    b.emit_tail_list(prev_end, source.len() as u32, &mut parts);
    let doc = b.p.concat(&parts);
    b.p.render(doc, width, out);
    let n = b.emitted_trivia;
    return n;
}

/// Precedence ladder for parenthesis re-insertion; binary operators use Parser::precedence (2..11).
pub const PREC_ASSIGN: i32 = 0;
pub const PREC_RANGE: i32 = 1;
pub const PREC_CAST: i32 = 12; // `as`: looser than prefix ops, tighter than any binary op (parser binary max = 11)
pub const PREC_UNARY: i32 = 13;
pub const PREC_POSTFIX: i32 = 14;
pub const PREC_PRIMARY: i32 = 20;

extend Builder {
    const fn nd(self: &Self, id: NodeId) Node {
        return *self.ast.at_const(id);
    }

    const fn list_at(self: &Self, l: NodeList, i: u32) NodeId {
        return unsafe self.ast.list(l)[i as usize];
    }

    fn span_doc(self: &mut Self, s: tok::Span) d::DocId {
        return self.p.span(s.start, s.end);
    }

    fn node_text(self: &mut Self, id: NodeId) d::DocId {
        let s = self.nd(id).span;
        return self.p.span(s.start, s.end);
    }

    // Scan src[from..to) for comment and @attribute segments. Everything else in an inter-element gap is
    // whitespace or separator punctuation and is ignored.
    fn scan_gap(self: &Self, from: u32, to: u32, out: &mut Vector<TriviaSeg>) {
        let s = self.src;
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
                    // Strip trailing spaces/commas of the attr line.
                    while en > st && (s.byte_at(en - 1) == b' ' || s.byte_at(en - 1) == b'\t' || s.byte_at(en - 1) == b'\r') {
                        en = en - 1;
                    }
                    is_seg = true;
                    is_attr = true;
                }
                if is_seg {
                    // Trim trailing blanks of line comments.
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

    fn count_gap_newlines(self: &Self, from: u32, to: u32) i32 {
        let mut c: i32 = 0;
        let mut i = from as usize;
        while i < to as usize {
            if self.src.byte_at(i) == b'\n' {
                c = c + 1;
            }
            i = i + 1;
        }
        return c;
    }

    // Emit the gap between two vertical elements (statements/items/fields/arms): trailing comments stay
    // on the previous line, then a hard/blank separation, then leading comments/attrs each on their own
    // line. Pushes onto `parts`; the caller emits the next element right after.
    fn emit_gap_vertical(self: &mut Self, from: u32, to: u32, parts: &mut Vector<d::DocId>, _first: bool) {
        let mut segs = Vector::<TriviaSeg>::new();
        self.scan_gap(from, to, &mut segs);
        let mut i: usize = 0;
        while i < segs.len() && segs.at(i).trailing {
            let sg = *segs.at(i);
            parts.push(self.p.txt(" "));
            parts.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
            i = i + 1;
        }
        // Separation after the previous element (before the first leading seg or the next element).
        let mut blank = false;
        if i < segs.len() {
            blank = segs.at(i).blank_before;
        } else {
            blank = self.count_gap_newlines(from, to) >= 2;
        }
        if blank {
            parts.push(self.p.blankline());
        } else {
            parts.push(self.p.hardline());
        }
        while i < segs.len() {
            let sg = *segs.at(i);
            parts.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
            let mut nb = false;
            if i + 1 < segs.len() {
                nb = segs.at(i + 1).blank_before;
            } else {
                nb = self.count_gap_newlines(sg.end, to) >= 2;
            }
            if nb {
                parts.push(self.p.blankline());
            } else {
                parts.push(self.p.hardline());
            }
            i = i + 1;
        }
    }

    // Leading trivia at the start of a braced body or file: each segment on its own line, followed by
    // its separation to whatever comes next.
    fn emit_lead_list(self: &mut Self, from: u32, to: u32, parts: &mut Vector<d::DocId>) {
        let mut segs = Vector::<TriviaSeg>::new();
        self.scan_gap(from, to, &mut segs);
        for k in 0..segs.len() {
            let sg = *segs.at(k);
            parts.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
            let mut nb = false;
            if k + 1 < segs.len() {
                nb = segs.at(k + 1).blank_before;
            } else {
                nb = self.count_gap_newlines(sg.end, to) >= 2;
            }
            if nb {
                parts.push(self.p.blankline());
            } else {
                parts.push(self.p.hardline());
            }
        }
    }

    // Dangling/trailing trivia before a closing brace or end of file.
    fn emit_tail_list(self: &mut Self, from: u32, to: u32, parts: &mut Vector<d::DocId>) {
        let mut segs = Vector::<TriviaSeg>::new();
        self.scan_gap(from, to, &mut segs);
        for k in 0..segs.len() {
            let sg = *segs.at(k);
            if sg.trailing {
                parts.push(self.p.txt(" "));
            } else if sg.blank_before {
                parts.push(self.p.blankline());
            } else {
                parts.push(self.p.hardline());
            }
            parts.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
        }
    }

    const fn expr_prec(self: &Self, id: NodeId) i32 {
        let n = self.nd(id);
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

    fn b_expr_prec(self: &mut Self, id: NodeId, min_prec: i32) d::DocId {
        let e = self.b_expr(id);
        if self.expr_prec(id) < min_prec {
            let mut v = Vector::<d::DocId>::new();
            v.push(self.p.txt("("));
            v.push(e);
            v.push(self.p.txt(")"));
            let r = self.p.concat(&v);
            return r;
        }
        return e;
    }

    // Does src[from..to) hold a comment or attribute? Decides up front whether a list must print broken.
    fn gap_has_trivia(self: &Self, from: u32, to: u32) bool {
        let mut segs = Vector::<TriviaSeg>::new();
        self.scan_gap(from, to, &mut segs);
        return segs.len() != 0;
    }

    // Push the segments of one inter-element gap, splitting them around the element separator: a segment that
    // began before the gap's first newline trails the PREVIOUS element (`a, // note`), the rest lead the next
    // one, each on its own line. `sep` is emitted between the two halves.
    fn push_gap_inline(self: &mut Self, from: u32, to: u32, sep: d::DocId, out: &mut Vector<d::DocId>) {
        let mut segs = Vector::<TriviaSeg>::new();
        self.scan_gap(from, to, &mut segs);
        let mut i: usize = 0;
        while i < segs.len() && segs.at(i).trailing {
            let sg = *segs.at(i);
            out.push(self.p.txt(" "));
            out.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
            i = i + 1;
        }
        out.push(sep);
        while i < segs.len() {
            let sg = *segs.at(i);
            out.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
            out.push(self.p.hardline());
            i = i + 1;
        }
    }

    // The byte offset of the delimiter closing a list, scanning from `from` (the last element's end) and
    // skipping comments. Only trivia and a separator can sit between the last element and its closer, so no
    // nesting has to be tracked. `to` bounds the search; on failure it returns `from`, which makes the tail gap
    // empty and the list keeps its old shape.
    fn find_close(self: &Self, from: u32, to: u32, close: u8) u32 {
        let src = self.src;
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
    // the trivia-aware shape at all; every list keeps its existing output byte for byte when it does not.
    fn list_has_trivia(self: &Self, ids: NodeList, open_end: u32, close_pos: u32) bool {
        let mut prev = open_end;
        for i in 0..ids.len {
            let sp = self.nd(self.list_at(ids, i)).span;
            if self.gap_has_trivia(prev, sp.start) {
                return true;
            }
            prev = sp.end;
        }
        return self.gap_has_trivia(prev, close_pos);
    }

    // `b_comma_list`, plus the comments living in the gaps between elements. `ids` are the source nodes the
    // element docs came from (index-aligned), `open_end` the byte just past the opening delimiter and
    // `close_pos` the closing one, so every gap is scanned exactly once and by exactly one list.
    //
    // Any comment forces the list to print BROKEN (a line comment printed flat would swallow the rest of the
    // line, closing delimiter included), which the `hardline` separators do by making the group's width
    // infinite. Without this, a comment inside an expression list is dropped, and the whole-file
    // comment-preservation check then refuses to write the file.
    fn b_comma_list_tr(
        self: &mut Self,
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
            let sp = self.nd(self.list_at(ids, i as u32)).span;
            if self.gap_has_trivia(prev, sp.start) {
                hard = true;
            }
            prev = sp.end;
        }
        if self.gap_has_trivia(prev, close_pos) {
            hard = true;
        }
        if !hard {
            return self.b_comma_list(open, elems, close, trailing_comma);
        }
        let mut inner = Vector::<d::DocId>::new();
        prev = open_end;
        for i in 0..elems.len() {
            let sp = self.nd(self.list_at(ids, i as u32)).span;
            if i > 0 {
                inner.push(self.p.txt(","));
            }
            let sep = self.p.hardline();
            self.push_gap_inline(prev, sp.start, sep, &mut inner);
            inner.push(*elems.at(i));
            prev = sp.end;
        }
        if trailing_comma && elems.len() != 0 {
            inner.push(self.p.txt(","));
        }
        // Anything left before the closing delimiter: a trailing comment stays on the last element's line.
        let mut tsegs = Vector::<TriviaSeg>::new();
        self.scan_gap(prev, close_pos, &mut tsegs);
        for k in 0..tsegs.len() {
            let sg = *tsegs.at(k);
            if sg.trailing {
                inner.push(self.p.txt(" "));
            } else {
                inner.push(self.p.hardline());
            }
            inner.push(self.p.span(sg.start, sg.end));
            if !sg.is_attr {
                self.emitted_trivia = self.emitted_trivia + 1;
            }
        }
        let ic = self.p.concat(&inner);
        let mut parts = Vector::<d::DocId>::new();
        parts.push(self.p.txt(open));
        parts.push(self.p.indent(ic));
        parts.push(self.p.hardline());
        parts.push(self.p.txt(close));
        let body = self.p.concat(&parts);
        return self.p.group(body);
    }

    // group( open indent(softline join(", "-line, elems)) ifbreak(",") softline close )
    fn b_comma_list(self: &mut Self, open: str, elems: &Vector<d::DocId>, close: str, trailing_comma: bool) d::DocId {
        if elems.len() == 0 {
            let mut v0 = Vector::<d::DocId>::new();
            v0.push(self.p.txt(open));
            v0.push(self.p.txt(close));
            let r0 = self.p.concat(&v0);
            return r0;
        }
        let mut inner = Vector::<d::DocId>::new();
        inner.push(self.p.softline());
        for i in 0..elems.len() {
            if i > 0 {
                inner.push(self.p.txt(","));
                inner.push(self.p.line());
            }
            inner.push(*elems.at(i));
        }
        if trailing_comma {
            inner.push(self.p.ifbreak(",", false));
        }
        let ic = self.p.concat(&inner);
        let mut parts = Vector::<d::DocId>::new();
        parts.push(self.p.txt(open));
        parts.push(self.p.indent(ic));
        parts.push(self.p.softline());
        parts.push(self.p.txt(close));
        let body = self.p.concat(&parts);
        return self.p.group(body);
    }

    // Lower each node of `l` with `what`: 0 = expr, 1 = type, 2 = pattern, 3 = parameter, 4 = generic param.
    fn b_each(self: &mut Self, l: NodeList, what: i32, out: &mut Vector<d::DocId>) {
        if what == 3 {
            self.b_params(l, out);
            return;
        }
        for i in 0..l.len {
            let id = self.list_at(l, i);
            if what == 0 {
                out.push(self.b_expr(id));
            } else if what == 1 {
                out.push(self.b_type(id));
            } else if what == 2 {
                out.push(self.b_pattern(id));
            } else {
                out.push(self.b_generic_param(id));
            }
        }
    }

    // Parameters. A `a, self: T` group parses into consecutive NODE_PARAMETERs SHARING one `ty` node id
    // (separately written params each parse their own type), so the written form is recoverable: a
    // shared-type run prints back as one `a, self: T` group instead of being desugared per name.
    fn b_params(self: &mut Self, l: NodeList, out: &mut Vector<d::DocId>) {
        let mut i: u32 = 0;
        while i < l.len {
            let id = self.list_at(l, i);
            let n = self.nd(id);
            let named = n.kind == NodeKind::NODE_PARAMETER && n.as_data.parameter.name != NODE_NONE && n.as_data.parameter.ty != NODE_NONE;
            let mut j = i + 1;
            while named && j < l.len {
                let m = self.nd(self.list_at(l, j));
                if m.kind != NodeKind::NODE_PARAMETER || m.as_data.parameter.name == NODE_NONE || m.as_data.parameter.ty != n.as_data.parameter.ty {
                    break;
                }
                j += 1;
            }
            if j == i + 1 {
                out.push(self.b_param(id));
                i = j;
                continue;
            }
            let mut v = Vector::<d::DocId>::new();
            for k in i..j {
                let p = self.nd(self.list_at(l, k));
                if k > i {
                    v.push(self.p.txt(", "));
                }
                if p.as_data.parameter.is_mutable {
                    v.push(self.p.txt("mut "));
                }
                v.push(self.node_text(p.as_data.parameter.name));
            }
            v.push(self.p.txt(": "));
            v.push(self.b_type(n.as_data.parameter.ty));
            out.push(self.p.concat(&v));
            i = j;
        }
    }

    fn b_type(self: &mut Self, id: NodeId) d::DocId {
        if id == NODE_NONE {
            return self.p.nil();
        }
        let n = self.nd(id);
        let mut v = Vector::<d::DocId>::new();
        switch n.kind {
            NODE_TYPE_PATH => {
                let parts = n.as_data.type_path.parts;
                for i in 0..parts.len {
                    if i > 0 {
                        v.push(self.p.txt("::"));
                    }
                    let __h = self.list_at(parts, i);
                    v.push(self.node_text(__h));
                }
                let args = n.as_data.type_path.args;
                if args.len > 0 {
                    let mut az = Vector::<d::DocId>::new();
                    for i in 0..args.len {
                        let a = self.list_at(args, i);
                        if self.nd(a).kind == NodeKind::NODE_LITERAL {
                            az.push(self.node_text(a));
                        } else if self.fmt_const_arg(a) {
                            az.push(self.b_const_arg(a));
                        } else {
                            az.push(self.b_type(a));
                        }
                    }
                    v.push(self.b_comma_list("<", &az, ">", false));
                }
            },
            NODE_POINTER_TYPE => {
                if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                    v.push(self.p.txt("*mut "));
                } else {
                    v.push(self.p.txt("*const "));
                }
                v.push(self.b_type(n.as_data.indirect_type.ty));
            },
            NODE_REFERENCE_TYPE => {
                // `&T` / `&mut T`, with an optional lifetime binding first: `&'a T` / `&'a mut T`.
                v.push(self.p.txt("&"));
                if n.as_data.indirect_type.lifetime != NODE_NONE {
                    v.push(self.node_text(n.as_data.indirect_type.lifetime));
                    v.push(self.p.txt(" "));
                }
                if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                    v.push(self.p.txt("mut "));
                }
                v.push(self.b_type(n.as_data.indirect_type.ty));
            },
            NODE_SLICE_TYPE => {
                if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                    v.push(self.p.txt("[]mut "));
                } else {
                    v.push(self.p.txt("[]"));
                }
                v.push(self.b_type(n.as_data.indirect_type.ty));
            },
            NODE_ARRAY_TYPE => {
                v.push(self.p.txt("["));
                v.push(self.b_type(n.as_data.array_type.element));
                v.push(self.p.txt("; "));
                v.push(self.b_expr(n.as_data.array_type.length));
                v.push(self.p.txt("]"));
            },
            NODE_FUNCTION_TYPE => {
                self.b_hrtb(id, &mut v);
                if n.as_data.function_type.is_move {
                    v.push(self.p.txt("fn move"));
                } else {
                    v.push(self.p.txt("fn"));
                }
                let mut ps = Vector::<d::DocId>::new();
                self.b_each(n.as_data.function_type.params, 1, &mut ps);
                v.push(self.b_comma_list("(", &ps, ")", false));
                let rets = n.as_data.function_type.returns;
                if rets.len > 0 {
                    v.push(self.p.txt(" "));
                    v.push(self.b_returns(rets));
                }
            },
            NODE_DYN_TYPE => {
                // `&dyn T` / `&mut dyn T` fold the borrow into the dyn node as its qualifier; bare `dyn T`
                // (as in `Box<dyn T>`) carries TYPE_QUAL_NONE.
                if n.as_data.indirect_type.qualifier != TypeQualifier::TYPE_QUAL_NONE {
                    v.push(self.p.txt("&"));
                    if n.as_data.indirect_type.lifetime != NODE_NONE {
                        v.push(self.node_text(n.as_data.indirect_type.lifetime));
                        v.push(self.p.txt(" "));
                    }
                    if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                        v.push(self.p.txt("mut "));
                    }
                }
                v.push(self.p.txt("dyn "));
                v.push(self.b_type(n.as_data.indirect_type.ty));
            },
            NODE_TUPLE_TYPE => {
                let mut ts = Vector::<d::DocId>::new();
                self.b_each(n.as_data.array_literal.elements, 1, &mut ts);
                v.push(self.b_comma_list("(", &ts, ")", false));
            },
            NODE_IDENTIFIER => {
                v.push(self.node_text(id));
            },
            _ => {
                v.push(self.node_text(id));
            },
        };
        let r = self.p.concat(&v);
        return r;
    }

    // Return types: one type bare, several as "(A, B)".
    fn b_returns(self: &mut Self, rets: NodeList) d::DocId {
        let __h = self.list_at(rets, 0);
        // A single NAMED return keeps its parens (`(ret: bool)`); a single unnamed one never has them.
        if rets.len == 1 && self.nd(__h).kind != NodeKind::NODE_PARAMETER {
            return self.b_type(__h);
        }
        let mut ts = Vector::<d::DocId>::new();
        self.b_each(rets, 1, &mut ts);
        let r = self.b_comma_list("(", &ts, ")", false);
        return r;
    }

    fn b_param(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let mut v = Vector::<d::DocId>::new();
        if n.kind != NodeKind::NODE_PARAMETER {
            // Function-type params may be bare types.
            let r0 = self.b_type(id);
            return r0;
        }
        if n.as_data.parameter.is_mutable {
            v.push(self.p.txt("mut "));
        }
        if n.as_data.parameter.name != NODE_NONE {
            v.push(self.node_text(n.as_data.parameter.name));
            if n.as_data.parameter.ty != NODE_NONE {
                v.push(self.p.txt(": "));
                v.push(self.b_type(n.as_data.parameter.ty));
            }
        } else if n.as_data.parameter.ty != NODE_NONE {
            v.push(self.b_type(n.as_data.parameter.ty));
        }
        let r = self.p.concat(&v);
        return r;
    }

    fn b_generic_param(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let g = n.as_data.generic_param;
        let mut v = Vector::<d::DocId>::new();
        if g.is_const {
            v.push(self.p.txt("const "));
        }
        v.push(self.node_text(g.name));
        if g.is_const && g.const_type != NODE_NONE {
            v.push(self.p.txt(": "));
            v.push(self.b_type(g.const_type));
        }
        if g.bounds.len > 0 {
            v.push(self.p.txt(": "));
            for i in 0..g.bounds.len {
                if i > 0 {
                    v.push(self.p.txt(" + "));
                }
                let __h = self.list_at(g.bounds, i);
                v.push(self.b_type(__h));
            }
        }
        if g.default_type != NODE_NONE {
            v.push(self.p.txt(" = "));
            v.push(self.b_type(g.default_type));
        }
        let r = self.p.concat(&v);
        return r;
    }

    // `for<'a, 'b> `: the higher-ranked prefix of a bound, held in the lifetime side table.
    fn b_hrtb(self: &mut Self, id: NodeId, v: &mut Vector<d::DocId>) {
        let lts = self.ast.lifetimes_of(id);
        if lts.len == 0 {
            return;
        }
        let mut gs = Vector::<d::DocId>::new();
        self.b_each(lts, 4, &mut gs);
        v.push(self.p.txt("for"));
        v.push(self.b_comma_list("<", &gs, ">", false));
        v.push(self.p.txt(" "));
    }

    // Lifetime params live in their own list (erasure is structural), but they are SOURCE-level part of
    // the same `<...>` and must print back merged, lifetimes first: `<'a, 'b: 'a, T>`.
    fn b_generics_lt(self: &mut Self, lts: NodeList, gens: NodeList, v: &mut Vector<d::DocId>) {
        if lts.len == 0 && gens.len == 0 {
            return;
        }
        let mut gs = Vector::<d::DocId>::new();
        if lts.len != 0 {
            self.b_each(lts, 4, &mut gs);
        }
        if gens.len != 0 {
            self.b_each(gens, 4, &mut gs);
        }
        v.push(self.b_comma_list("<", &gs, ">", false));
    }

    fn b_pattern(self: &mut Self, id: NodeId) d::DocId {
        if id == NODE_NONE {
            return self.p.nil();
        }
        let n = self.nd(id);
        let mut v = Vector::<d::DocId>::new();
        switch n.kind {
            NODE_PATTERN_WILDCARD => {
                v.push(self.p.txt("_"));
            },
            NODE_PATTERN_LITERAL | NODE_PATTERN_RANGE => {
                v.push(self.node_text(id));
            },
            NODE_PATTERN_NAME => {
                let p = n.as_data.pattern;
                if p.children.len > 0 {
                    // Binding @ subpattern or `mut x`: emitted from the span (rare shapes).
                    v.push(self.node_text(id));
                } else {
                    v.push(self.node_text(id));
                }
            },
            NODE_PATTERN_TUPLE => {
                let p = n.as_data.pattern;
                if p.name != NODE_NONE {
                    v.push(self.b_pattern_path(p.name));
                }
                let mut cs = Vector::<d::DocId>::new();
                self.b_each(p.children, 2, &mut cs);
                v.push(self.b_comma_list("(", &cs, ")", false));
            },
            NODE_PATTERN_STRUCT => {
                let p = n.as_data.pattern;
                if p.name != NODE_NONE {
                    v.push(self.b_pattern_path(p.name));
                }
                v.push(self.p.txt(" { "));
                for i in 0..p.children.len {
                    if i > 0 {
                        v.push(self.p.txt(", "));
                    }
                    let __h = self.list_at(p.children, i);
                    v.push(self.b_pattern(__h));
                }
                v.push(self.p.txt(" }"));
            },
            NODE_PATTERN_FIELD => {
                let p = n.as_data.pattern;
                v.push(self.node_text(p.name));
                if p.children.len > 0 {
                    v.push(self.p.txt(": "));
                    let __h = self.list_at(p.children, 0);
                    v.push(self.b_pattern(__h));
                }
            },
            NODE_PATTERN_OR => {
                let p = n.as_data.pattern;
                for i in 0..p.children.len {
                    if i > 0 {
                        v.push(self.p.txt(" | "));
                    }
                    let __h = self.list_at(p.children, i);
                    v.push(self.b_pattern(__h));
                }
            },
            _ => {
                v.push(self.node_text(id));
            },
        };
        let r = self.p.concat(&v);
        return r;
    }

    // A pattern head (`Option::Some`, `Some`): identifier or type path.
    fn b_pattern_path(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        if n.kind == NodeKind::NODE_TYPE_PATH {
            return self.b_type(id);
        }
        return self.node_text(id);
    }

    const fn is_block_node(self: &Self, id: NodeId) bool {
        return id != NODE_NONE && self.nd(id).kind == NodeKind::NODE_BLOCK;
    }

    // Flat constraint/expression pairs printed as `"c" (expr)`, comma separated.
    fn b_asm_operands(self: &mut Self, v: &mut Vector<d::DocId>, ops: NodeList) {
        let mut i: u32 = 0;
        while i + 1 < ops.len {
            if i != 0 {
                v.push(self.p.txt(", "));
            }
            v.push(self.b_expr(self.list_at(ops, i)));
            v.push(self.p.txt("("));
            v.push(self.b_expr(self.list_at(ops, i + 1)));
            v.push(self.p.txt(")"));
            i = i + 2;
        }
    }

    fn b_expr(self: &mut Self, id: NodeId) d::DocId {
        if id == NODE_NONE {
            return self.p.nil();
        }
        let n = self.nd(id);
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_LITERAL {
            return self.node_text(id);
        }
        let mut v = Vector::<d::DocId>::new();
        switch n.kind {
            NODE_UNARY => {
                let u = n.as_data.unary;
                if u.op == tt::TokenType::Question {
                    v.push(self.b_expr_prec(u.operand, PREC_POSTFIX));
                    v.push(self.p.txt("?"));
                } else if u.op == tt::TokenType::Unsafe || u.op == tt::TokenType::Move {
                    if u.op == tt::TokenType::Unsafe {
                        v.push(self.p.txt("unsafe "));
                    } else {
                        v.push(self.p.txt("move "));
                    }
                    if self.is_block_node(u.operand) {
                        v.push(self.b_block(u.operand));
                    } else {
                        v.push(self.b_expr_prec(u.operand, PREC_UNARY));
                    }
                } else {
                    if u.op == tt::TokenType::Ampersand {
                        if u.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                            v.push(self.p.txt("&mut "));
                        } else {
                            v.push(self.p.txt("&"));
                        }
                    } else if u.op == tt::TokenType::Minus {
                        v.push(self.p.txt("-"));
                    } else if u.op == tt::TokenType::Bang {
                        v.push(self.p.txt("!"));
                    } else if u.op == tt::TokenType::Tilde {
                        v.push(self.p.txt("~"));
                    } else if u.op == tt::TokenType::Star {
                        v.push(self.p.txt("*"));
                    }
                    v.push(self.b_expr_prec(u.operand, PREC_UNARY));
                }
            },
            NODE_BINARY => {
                let bi = n.as_data.binary;
                let pr = par::Parser::precedence(bi.op);
                v.push(self.b_expr_prec(bi.left, pr));
                v.push(self.p.txt(" "));
                v.push(self.op_text(bi.op));
                v.push(self.p.txt(" "));
                v.push(self.b_expr_prec(bi.right, pr + 1));
            },
            NODE_ASSIGNMENT => {
                let bi = n.as_data.binary;
                v.push(self.b_expr_prec(bi.left, PREC_RANGE));
                v.push(self.p.txt(" "));
                v.push(self.op_text(bi.op));
                v.push(self.p.txt(" "));
                v.push(self.b_expr_prec(bi.right, PREC_RANGE));
            },
            NODE_RANGE => {
                let r = n.as_data.pattern_range;
                if r.start != NODE_NONE {
                    v.push(self.b_expr_prec(r.start, PREC_RANGE + 1));
                }
                if r.inclusive {
                    v.push(self.p.txt("..="));
                } else {
                    v.push(self.p.txt(".."));
                }
                if r.end != NODE_NONE {
                    v.push(self.b_expr_prec(r.end, PREC_RANGE + 1));
                }
            },
            NODE_CALL => {
                v.push(self.b_expr_prec(n.as_data.call.callee, PREC_POSTFIX));
                let mut az = Vector::<d::DocId>::new();
                self.b_each(n.as_data.call.args, 0, &mut az);
                v.push(
                    self.b_comma_list_tr(
                        "(",
                        &az,
                        n.as_data.call.args,
                        self.nd(n.as_data.call.callee).span.end,
                        n.span.end,
                        ")",
                        true,
                    ),
                );
            },
            NODE_INDEX => {
                v.push(self.b_expr_prec(n.as_data.index.object, PREC_POSTFIX));
                v.push(self.p.txt("["));
                v.push(self.b_expr(n.as_data.index.index));
                v.push(self.p.txt("]"));
            },
            NODE_MEMBER => {
                v.push(self.b_expr_prec(n.as_data.member.object, PREC_POSTFIX));
                if n.as_data.member.path {
                    v.push(self.p.txt("::"));
                } else {
                    v.push(self.p.txt("."));
                }
                v.push(self.node_text(n.as_data.member.member));
            },
            NODE_CAST => {
                // Print the operand at POSTFIX, not CAST: prefix-op and chained-cast operands keep
                // their parens, so the output parses identically under a bootstrap grammar in which
                // `as` binds tighter than prefix ops. Relax to PREC_CAST once every bootstrap
                // release contains the precedence flip.
                v.push(self.b_expr_prec(n.as_data.cast.expression, PREC_POSTFIX));
                v.push(self.p.txt(" as "));
                v.push(self.b_type(n.as_data.cast.ty));
            },
            NODE_GENERIC_SPECIALIZATION => {
                v.push(self.b_expr_prec(n.as_data.specialization.expression, PREC_POSTFIX));
                let mut az = Vector::<d::DocId>::new();
                let types = n.as_data.specialization.types;
                for i in 0..types.len {
                    let a = self.list_at(types, i);
                    if self.nd(a).kind == NodeKind::NODE_LITERAL {
                        az.push(self.node_text(a));
                    } else if self.fmt_const_arg(a) {
                        az.push(self.b_const_arg(a));
                    } else {
                        az.push(self.b_type(a));
                    }
                }
                v.push(self.p.txt("::"));
                v.push(self.b_comma_list("<", &az, ">", false));
            },
            NODE_CLOSURE => {
                let c = n.as_data.closure;
                let mut ps = Vector::<d::DocId>::new();
                self.b_each(c.params, 3, &mut ps);
                // `|..|` has no return-type slot; only the `fn(..) T { .. }` spelling does. Both parse to this
                // node, so a closure that DECLARES a return type has to print in that form: normalising it to
                // `||` would drop the type from the source.
                if c.returns.len != 0 {
                    v.push(self.p.txt("fn"));
                    v.push(self.b_comma_list("(", &ps, ")", true));
                    v.push(self.p.txt(" "));
                    v.push(self.b_returns(c.returns));
                    v.push(self.p.txt(" "));
                    if c.expr_body {
                        v.push(self.b_expr(c.body));
                    } else {
                        v.push(self.b_block(c.body));
                    }
                    let rc = self.p.concat(&v);
                    return rc;
                }
                if ps.len() == 0 {
                    v.push(self.p.txt("||"));
                } else {
                    v.push(self.p.txt("|"));
                    for i in 0..ps.len() {
                        if i > 0 {
                            v.push(self.p.txt(", "));
                        }
                        v.push(*ps.at(i));
                    }
                    v.push(self.p.txt("|"));
                }
                v.push(self.p.txt(" "));
                if c.expr_body {
                    v.push(self.b_expr(c.body));
                } else {
                    v.push(self.b_block(c.body));
                }
            },
            NODE_MATCH => {
                v.push(self.b_match(id));
            },
            NODE_NEW => {
                v.push(self.p.txt("new "));
                v.push(self.b_type(n.as_data.new_expr.ty));
                if n.as_data.new_expr.initializer != NODE_NONE {
                    let init = self.nd(n.as_data.new_expr.initializer);
                    if init.kind == NodeKind::NODE_STRUCT_INITIALIZER {
                        v.push(self.p.txt(" "));
                        v.push(
                            self.b_struct_init_fields(
                                init.as_data.struct_initializer.fields,
                                self.nd(init.as_data.struct_initializer.ty).span.end,
                                init.span.end,
                            ),
                        );
                    } else {
                        v.push(self.p.txt(" ("));
                        v.push(self.b_expr(n.as_data.new_expr.initializer));
                        v.push(self.p.txt(")"));
                    }
                }
            },
            NODE_SIZEOF => {
                v.push(self.p.txt("sizeof("));
                v.push(self.b_type(n.as_data.single.value));
                v.push(self.p.txt(")"));
            },
            NODE_ALIGNOF => {
                v.push(self.p.txt("alignof("));
                v.push(self.b_type(n.as_data.single.value));
                v.push(self.p.txt(")"));
            },
            NODE_VA_EXPR => {
                let va = n.as_data.va_op;
                if va.op == VA_START {
                    v.push(self.p.txt("va_start("));
                } else if va.op == VA_ARG {
                    v.push(self.p.txt("va_arg("));
                } else {
                    v.push(self.p.txt("va_end("));
                }
                v.push(self.b_expr(va.ap));
                if va.extra != NODE_NONE {
                    v.push(self.p.txt(", "));
                    if va.op == VA_ARG {
                        v.push(self.b_type(va.extra));
                    } else {
                        v.push(self.b_expr(va.extra));
                    }
                }
                v.push(self.p.txt(")"));
            },
            NODE_ARRAY_LITERAL => {
                let mut az = Vector::<d::DocId>::new();
                let elems = n.as_data.array_literal.elements;
                if n.as_data.array_literal.repeat && elems.len == 2 {
                    v.push(self.p.txt("["));
                    v.push(self.b_expr(self.list_at(elems, 0)));
                    v.push(self.p.txt("; "));
                    v.push(self.b_expr(self.list_at(elems, 1)));
                    v.push(self.p.txt("]"));
                    return self.p.concat(&v);
                }
                for i in 0..elems.len {
                    let e = self.list_at(elems, i);
                    if self.nd(e).kind == NodeKind::NODE_FIELD_INITIALIZER {
                        // Designated element `[index] = value`.
                        let fi = self.nd(e).as_data.field_initializer;
                        let mut dv = Vector::<d::DocId>::new();
                        dv.push(self.p.txt("["));
                        dv.push(self.b_expr(fi.name));
                        dv.push(self.p.txt("] = "));
                        dv.push(self.b_expr(fi.value));
                        let dd = self.p.concat(&dv);
                        az.push(dd);
                    } else {
                        az.push(self.b_expr(e));
                    }
                }
                v.push(self.b_comma_list_tr("[", &az, elems, n.span.start + 1, n.span.end, "]", true));
            },
            NODE_TUPLE => {
                let mut az = Vector::<d::DocId>::new();
                let tel = n.as_data.array_literal.elements;
                self.b_each(tel, 0, &mut az);
                v.push(self.b_comma_list_tr("(", &az, tel, n.span.start + 1, n.span.end, ")", false));
            },
            NODE_STRUCT_INITIALIZER => {
                v.push(self.b_expr_type_path(n.as_data.struct_initializer.ty));
                v.push(self.p.txt(" "));
                v.push(
                    self.b_struct_init_fields(
                        n.as_data.struct_initializer.fields,
                        self.nd(n.as_data.struct_initializer.ty).span.end,
                        n.span.end,
                    ),
                );
            },
            NODE_FIELD_INITIALIZER => {
                v.push(self.node_text(n.as_data.field_initializer.name));
                v.push(self.p.txt(": "));
                v.push(self.b_expr(n.as_data.field_initializer.value));
            },
            NODE_IF => {
                // If-expression (`let x = if c { a; } else { self; };`).
                v.push(self.b_if(id));
            },
            NODE_BLOCK => {
                v.push(self.b_block(id));
            },
            _ => {
                v.push(self.node_text(id));
            },
        };
        let r = self.p.concat(&v);
        return r;
    }

    // A type path in EXPRESSION position (struct initializer heads): generic args need the turbofish
    // (`Vector::<T, A> { .. }`), unlike type position.
    fn b_expr_type_path(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return self.b_type(id);
        }
        let mut v = Vector::<d::DocId>::new();
        let parts = n.as_data.type_path.parts;
        for i in 0..parts.len {
            if i > 0 {
                v.push(self.p.txt("::"));
            }
            let __h = self.list_at(parts, i);
            v.push(self.node_text(__h));
        }
        let args = n.as_data.type_path.args;
        if args.len > 0 {
            v.push(self.p.txt("::"));
            let mut az = Vector::<d::DocId>::new();
            for i in 0..args.len {
                let a = self.list_at(args, i);
                if self.nd(a).kind == NodeKind::NODE_LITERAL {
                    az.push(self.node_text(a));
                } else if self.fmt_const_arg(a) {
                    az.push(self.b_const_arg(a));
                } else {
                    az.push(self.b_type(a));
                }
            }
            v.push(self.b_comma_list("<", &az, ">", false));
        }
        let r = self.p.concat(&v);
        return r;
    }

    // A const-generic argument written as an expression. It reaches here as an ordinary expression node
    // (nothing a TYPE position can otherwise hold), and the braces have to come back or it will not re-parse.
    const fn fmt_const_arg(self: &Self, id: NodeId) bool {
        let k = self.nd(id).kind;
        return k == NodeKind::NODE_BINARY || k == NodeKind::NODE_UNARY || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF || k == NodeKind::NODE_CALL;
    }

    fn b_const_arg(self: &mut Self, id: NodeId) d::DocId {
        let mut v = Vector::<d::DocId>::new();
        v.push(self.p.txt("{"));
        v.push(self.b_expr(id));
        v.push(self.p.txt("}"));
        return self.p.concat(&v);
    }

    fn b_struct_init_fields(self: &mut Self, fields: NodeList, open_end: u32, close_pos: u32) d::DocId {
        let mut fz = Vector::<d::DocId>::new();
        if fields.len == 0 {
            if !self.gap_has_trivia(open_end, close_pos) {
                return self.p.txt("{}");
            }
            return self.b_comma_list_tr("{", &fz, fields, open_end, close_pos, "}", false);
        }
        self.b_each(fields, 0, &mut fz);
        // A comment between the fields only fits the broken shape, which is what the trivia-aware list builds;
        // without one, keep the flat `{ a: 1 }` form below byte for byte.
        let mut has = self.gap_has_trivia(open_end, self.nd(self.list_at(fields, 0)).span.start);
        for i in 1..fields.len {
            let pe = self.nd(self.list_at(fields, i - 1)).span.end;
            if self.gap_has_trivia(pe, self.nd(self.list_at(fields, i)).span.start) {
                has = true;
            }
        }
        if self.gap_has_trivia(self.nd(self.list_at(fields, fields.len - 1)).span.end, close_pos) {
            has = true;
        }
        if has {
            return self.b_comma_list_tr("{", &fz, fields, open_end, close_pos, "}", true);
        }
        // Struct literals: `{ a: 1, self: 2 }` flat, or broken one per line with a trailing comma.
        let mut inner = Vector::<d::DocId>::new();
        inner.push(self.p.line());
        for i in 0..fz.len() {
            if i > 0 {
                inner.push(self.p.txt(","));
                inner.push(self.p.line());
            }
            inner.push(*fz.at(i));
        }
        inner.push(self.p.ifbreak(",", false));
        let ic = self.p.concat(&inner);
        let mut parts = Vector::<d::DocId>::new();
        parts.push(self.p.txt("{"));
        parts.push(self.p.indent(ic));
        parts.push(self.p.line());
        parts.push(self.p.txt("}"));
        let body = self.p.concat(&parts);
        return self.p.group(body);
    }

    fn op_text(self: &mut Self, op: tt::TokenType) d::DocId {
        switch op {
            Plus => {
                return self.p.txt("+");
            },
            Minus => {
                return self.p.txt("-");
            },
            Star => {
                return self.p.txt("*");
            },
            Slash => {
                return self.p.txt("/");
            },
            Percent => {
                return self.p.txt("%");
            },
            EqualEqual => {
                return self.p.txt("==");
            },
            BangEqual => {
                return self.p.txt("!=");
            },
            LessThan => {
                return self.p.txt("<");
            },
            LessThanEqual => {
                return self.p.txt("<=");
            },
            GreaterThan => {
                return self.p.txt(">");
            },
            GreaterThanEqual => {
                return self.p.txt(">=");
            },
            AmpersandAmpersand => {
                return self.p.txt("&&");
            },
            PipePipe => {
                return self.p.txt("||");
            },
            Ampersand => {
                return self.p.txt("&");
            },
            Pipe => {
                return self.p.txt("|");
            },
            Caret => {
                return self.p.txt("^");
            },
            LeftShift => {
                return self.p.txt("<<");
            },
            RightShift => {
                return self.p.txt(">>");
            },
            Equal => {
                return self.p.txt("=");
            },
            PlusEqual => {
                return self.p.txt("+=");
            },
            MinusEqual => {
                return self.p.txt("-=");
            },
            StarEqual => {
                return self.p.txt("*=");
            },
            SlashEqual => {
                return self.p.txt("/=");
            },
            PercentEqual => {
                return self.p.txt("%=");
            },
            AmpersandEqual => {
                return self.p.txt("&=");
            },
            PipeEqual => {
                return self.p.txt("|=");
            },
            CaretEqual => {
                return self.p.txt("^=");
            },
            LeftShiftEqual => {
                return self.p.txt("<<=");
            },
            RightShiftEqual => {
                return self.p.txt(">>=");
            },
            _ => {
                return self.p.txt("?op?");
            },
        };
        return self.p.txt("?op?");
    }

    fn stmt_starts_with(self: &Self, id: NodeId, kw: str) bool {
        let s = self.nd(id).span;
        if (s.end - s.start) as usize < kw.len() {
            return false;
        }
        let mut i: usize = 0;
        while i < kw.len() {
            if self.src.byte_at(s.start as usize + i) != kw.byte_at(i) {
                return false;
            }
            i = i + 1;
        }
        return true;
    }

    fn b_stmt(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let mut v = Vector::<d::DocId>::new();
        switch n.kind {
            NODE_LET => {
                let l = n.as_data.let_stmt;
                if l.is_mutable {
                    v.push(self.p.txt("let mut "));
                } else {
                    v.push(self.p.txt("let "));
                }
                v.push(self.node_text(l.name));
                if l.ty != NODE_NONE {
                    v.push(self.p.txt(": "));
                    v.push(self.b_type(l.ty));
                }
                if l.value != NODE_NONE {
                    v.push(self.p.txt(" = "));
                    v.push(self.b_expr(l.value));
                }
                v.push(self.p.txt(";"));
            },
            NODE_RETURN => {
                let vals = n.as_data.return_stmt.values;
                // A bare `return;` in a named-return fn carries parser-synthesized identifiers whose
                // spans point back INTO the signature: print the bare form the user wrote.
                let mut synthetic = vals.len > 0;
                if synthetic {
                    synthetic = self.nd(self.list_at(vals, 0)).span.start < n.span.start;
                }
                if vals.len == 0 || synthetic {
                    v.push(self.p.txt("return;"));
                } else {
                    v.push(self.p.txt("return "));
                    for i in 0..vals.len {
                        if i > 0 {
                            v.push(self.p.txt(", "));
                        }
                        let __h = self.list_at(vals, i);
                        v.push(self.b_expr(__h));
                    }
                    v.push(self.p.txt(";"));
                }
            },
            NODE_BREAK | NODE_CONTINUE => {
                if n.kind == NodeKind::NODE_BREAK {
                    v.push(self.p.txt("break"));
                } else {
                    v.push(self.p.txt("continue"));
                }
                let f = n.as_data.flow;
                if f.label.end > f.label.start {
                    v.push(self.p.txt(" "));
                    v.push(self.span_doc(f.label));
                }
                if f.value != NODE_NONE {
                    v.push(self.p.txt(" "));
                    v.push(self.b_expr(f.value));
                }
                v.push(self.p.txt(";"));
            },
            NODE_ASM => {
                let d = n.as_data.asm_stmt;
                v.push(self.p.txt("asm("));
                v.push(self.b_expr(d.template));
                if d.outputs.len != 0 || d.inputs.len != 0 || d.clobbers.len != 0 {
                    v.push(self.p.txt(" : "));
                    self.b_asm_operands(&mut v, d.outputs);
                }
                if d.inputs.len != 0 || d.clobbers.len != 0 {
                    v.push(self.p.txt(" : "));
                    self.b_asm_operands(&mut v, d.inputs);
                }
                if d.clobbers.len != 0 {
                    v.push(self.p.txt(" : "));
                    for k in 0..d.clobbers.len {
                        if k != 0 {
                            v.push(self.p.txt(", "));
                        }
                        v.push(self.b_expr(self.list_at(d.clobbers, k)));
                    }
                }
                v.push(self.p.txt(");"));
            },
            NODE_DEFER => {
                v.push(self.p.txt("defer "));
                v.push(self.b_expr(n.as_data.single.value));
                v.push(self.p.txt(";"));
            },
            NODE_LAUNCH => {
                // Sugar marker (pre-desugar): SingleData wraps the placeholder call; print its sole operand.
                let inner = n.as_data.single.value;
                v.push(self.p.txt("launch "));
                v.push(self.b_expr(self.list_at(self.nd(inner).as_data.call.args, 0)));
                v.push(self.p.txt(";"));
            },
            NODE_SELECT => {
                v.push(self.b_select(id));
            },
            NODE_IF => {
                v.push(self.b_if(id));
            },
            NODE_WHILE => {
                let w = n.as_data.while_stmt;
                if w.label.end > w.label.start {
                    v.push(self.span_doc(w.label));
                    v.push(self.p.txt(": "));
                }
                if w.is_do {
                    v.push(self.p.txt("do "));
                    v.push(self.b_block(w.body));
                    v.push(self.p.txt(" while "));
                    v.push(self.b_expr(w.condition));
                    v.push(self.p.txt(";"));
                } else if w.condition == NODE_NONE {
                    v.push(self.p.txt("loop "));
                    v.push(self.b_block(w.body));
                } else {
                    v.push(self.p.txt("while "));
                    v.push(self.b_expr(w.condition));
                    v.push(self.p.txt(" "));
                    v.push(self.b_block(w.body));
                }
            },
            NODE_FOR | NODE_INLINE_FOR => {
                let f = n.as_data.for_stmt;
                if f.label.end > f.label.start {
                    v.push(self.span_doc(f.label));
                    v.push(self.p.txt(": "));
                }
                if n.kind == NodeKind::NODE_INLINE_FOR {
                    v.push(self.p.txt("inline "));
                }
                v.push(self.p.txt("for "));
                v.push(self.node_text(f.binding));
                v.push(self.p.txt(" in "));
                v.push(self.b_expr(f.iterable));
                v.push(self.p.txt(" "));
                v.push(self.b_block(f.body));
            },
            NODE_PARALLEL_FOR => {
                // The marker's body is the closure the parser wrapped the block in; print the block.
                let f = n.as_data.for_stmt;
                v.push(self.p.txt("parallel for "));
                v.push(self.node_text(f.binding));
                v.push(self.p.txt(" in "));
                v.push(self.b_expr(f.iterable));
                v.push(self.p.txt(" "));
                v.push(self.b_block(self.nd(f.body).as_data.closure.body));
            },
            NODE_EXPRESSION_STATEMENT => {
                let e = n.as_data.single.value;
                v.push(self.b_expr(e));
                let en = self.nd(e);
                let mut block_form = en.kind == NodeKind::NODE_BLOCK;
                if en.kind == NodeKind::NODE_UNARY && (en.as_data.unary.op == tt::TokenType::Unsafe || en.as_data.unary.op == tt::TokenType::Move) && self.is_block_node(
                    en.as_data.unary.operand,
                ) {
                    block_form = true;
                }
                if !block_form {
                    v.push(self.p.txt(";"));
                }
            },
            NODE_MATCH => {
                // if-let / while-let desugar to a match spanning the original statement: emit verbatim.
                if self.stmt_starts_with(id, "if") || self.stmt_starts_with(id, "while") {
                    v.push(self.node_text(id));
                } else {
                    v.push(self.b_match(id));
                    v.push(self.p.txt(";"));
                }
            },
            NODE_BLOCK => {
                v.push(self.b_block(id));
            },
            NODE_CONST | NODE_STATIC_ASSERT => {
                v.push(self.b_item(id));
            },
            _ => {
                v.push(self.node_text(id));
                v.push(self.p.txt(";"));
            },
        };
        let r = self.p.concat(&v);
        return r;
    }

    fn b_if(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let f = n.as_data.if_stmt;
        let mut v = Vector::<d::DocId>::new();
        v.push(self.p.txt("if "));
        v.push(self.b_expr(f.condition));
        v.push(self.p.txt(" "));
        v.push(self.b_block(f.then_branch));
        if f.else_branch != NODE_NONE {
            v.push(self.p.txt(" else "));
            if self.nd(f.else_branch).kind == NodeKind::NODE_IF {
                v.push(self.b_if(f.else_branch));
            } else {
                v.push(self.b_block(f.else_branch));
            }
        }
        let r = self.p.concat(&v);
        return r;
    }

    fn b_match(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let m = n.as_data.match_expr;
        let mut v = Vector::<d::DocId>::new();
        // `switch` and `match` are keyword synonyms parsed to the same node; keep the author's.
        if self.src.byte_at(n.span.start as usize) == b'm' {
            v.push(self.p.txt("match "));
        } else {
            v.push(self.p.txt("switch "));
        }
        v.push(self.b_expr(m.value));
        v.push(self.p.txt(" {"));
        let mut body = Vector::<d::DocId>::new();
        let mut prev_end = 0u32;
        for i in 0..m.arms.len {
            let arm = self.list_at(m.arms, i);
            let asp = self.nd(arm).span;
            if i == 0 {
                body.push(self.p.hardline());
                let floor = self.item_gap_floor(n.span.start, asp.start);
                self.emit_lead_list(floor, asp.start, &mut body);
            } else {
                self.emit_gap_vertical(prev_end, asp.start, &mut body, false);
            }
            body.push(self.b_match_arm(arm));
            prev_end = asp.end;
        }
        if m.arms.len > 0 {
            self.emit_tail_list(prev_end, n.span.end - 1, &mut body);
            let ic = self.p.concat(&body);
            v.push(self.p.indent(ic));
            v.push(self.p.hardline());
        }
        v.push(self.p.txt("}"));
        let r = self.p.concat(&v);
        return r;
    }

    // `select { .. }` (sugar marker, pre-desugar). Laid out like `switch`, but its arms carry no separator and
    // the operation is REBUILT from the pieces the parser kept: `ch.recv()` survives as `ch` alone.
    fn b_select(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let arms = n.as_data.block.statements;
        let mut v = Vector::<d::DocId>::new();
        v.push(self.p.txt("select {"));
        let mut body = Vector::<d::DocId>::new();
        let mut prev_end = 0u32;
        for i in 0..arms.len {
            let arm = self.list_at(arms, i);
            let asp = self.nd(arm).span;
            if i == 0 {
                body.push(self.p.hardline());
                let floor = self.item_gap_floor(n.span.start, asp.start);
                self.emit_lead_list(floor, asp.start, &mut body);
            } else {
                self.emit_gap_vertical(prev_end, asp.start, &mut body, false);
            }
            body.push(self.b_select_arm(arm));
            prev_end = asp.end;
        }
        if arms.len > 0 {
            self.emit_tail_list(prev_end, n.span.end - 1, &mut body);
            let ic = self.p.concat(&body);
            v.push(self.p.indent(ic));
            v.push(self.p.hardline());
        }
        v.push(self.p.txt("}"));
        let r = self.p.concat(&v);
        return r;
    }

    fn b_select_arm(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let a = n.as_data.select_arm;
        let mut v = Vector::<d::DocId>::new();
        if a.binding != NODE_NONE {
            v.push(self.b_expr(self.nd(a.binding).as_data.let_stmt.name));
            v.push(self.p.txt(" = "));
        }
        switch a.kind {
            SELECT_RECV => {
                v.push(self.b_expr(a.op));
                v.push(self.p.txt(".recv()"));
            },
            SELECT_SEND => {
                v.push(self.b_expr(a.op));
                v.push(self.p.txt(".send("));
                v.push(self.b_expr(a.value));
                v.push(self.p.txt(")"));
            },
            SELECT_TIMEOUT => {
                v.push(self.p.txt("timeout("));
                v.push(self.b_expr(a.op));
                v.push(self.p.txt(")"));
            },
            SELECT_DEFAULT => {
                v.push(self.p.txt("default"));
            },
        };
        v.push(self.p.txt(" => "));
        v.push(self.b_block(a.body));
        let r = self.p.concat(&v);
        return r;
    }

    fn b_match_arm(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let a = n.as_data.match_arm;
        let mut v = Vector::<d::DocId>::new();
        v.push(self.b_pattern(a.pattern));
        if a.guard != NODE_NONE {
            v.push(self.p.txt(" if "));
            v.push(self.b_expr(a.guard));
        }
        v.push(self.p.txt(" => "));
        if self.is_block_node(a.body) {
            v.push(self.b_block(a.body));
        } else {
            v.push(self.b_expr(a.body));
        }
        v.push(self.p.txt(","));
        let r = self.p.concat(&v);
        return r;
    }

    // A block: `{}` when empty (dangling comments kept), otherwise always broken.
    fn b_block(self: &mut Self, id: NodeId) d::DocId {
        let n = self.nd(id);
        let stmts = n.as_data.block.statements;
        let mut v = Vector::<d::DocId>::new();
        v.push(self.p.txt("{"));
        let mut body = Vector::<d::DocId>::new();
        let mut prev_end = n.span.start + 1;
        let mut first = true;
        for i in 0..stmts.len {
            let sid = self.list_at(stmts, i);
            let ssp = self.nd(sid).span;
            // Parser-synthesized statements (named-return bindings) are not in the source text.
            if ssp.start < n.span.start {
                continue;
            }
            if first {
                body.push(self.p.hardline());
                self.emit_lead_list(prev_end, ssp.start, &mut body);
                first = false;
            } else {
                self.emit_gap_vertical(prev_end, ssp.start, &mut body, false);
            }
            body.push(self.b_stmt(sid));
            prev_end = ssp.end;
        }
        if !first {
            self.emit_tail_list(prev_end, n.span.end - 1, &mut body);
            let ic = self.p.concat(&body);
            v.push(self.p.indent(ic));
            v.push(self.p.hardline());
        } else {
            let mut segs = Vector::<TriviaSeg>::new();
            self.scan_gap(prev_end, n.span.end - 1, &mut segs);
            if segs.len() > 0 {
                let mut inner = Vector::<d::DocId>::new();
                for k in 0..segs.len() {
                    let sg = *segs.at(k);
                    if sg.blank_before && k > 0 {
                        inner.push(self.p.blankline());
                    } else {
                        inner.push(self.p.hardline());
                    }
                    inner.push(self.p.span(sg.start, sg.end));
                    if !sg.is_attr {
                        self.emitted_trivia = self.emitted_trivia + 1;
                    }
                }
                let ic = self.p.concat(&inner);
                v.push(self.p.indent(ic));
                v.push(self.p.hardline());
            }
        }
        v.push(self.p.txt("}"));
        let r = self.p.concat(&v);
        return r;
    }

    // True when the item carries @fmt.skip: it is then emitted verbatim from its source span.
    fn fmt_skipped(self: &Self, id: NodeId) bool {
        let na = unsafe self.ast.attrs.len();
        for i in 0..na {
            let a = *unsafe self.ast.attrs.at(i);
            if a.owner == id && a.kind == AttrKind::ATTR_FMT_SKIP as u8 {
                return true;
            }
        }
        return false;
    }

    fn b_item(self: &mut Self, id: NodeId) d::DocId {
        if self.fmt_skipped(id) {
            return self.node_text(id);
        }
        let n = self.nd(id);
        let mut v = Vector::<d::DocId>::new();
        switch n.kind {
            NODE_FUNCTION => {
                let f = n.as_data.function;
                if f.is_public {
                    v.push(self.p.txt("pub "));
                }
                if f.is_extern && f.body == NODE_NONE {}
                if f.is_unsafe {
                    v.push(self.p.txt("unsafe "));
                }
                if f.is_const {
                    v.push(self.p.txt("const "));
                }
                v.push(self.p.txt("fn "));
                v.push(self.node_text(f.name));
                self.b_generics_lt(self.ast.lifetimes_of(id), f.generics, &mut v);
                let mut ps = Vector::<d::DocId>::new();
                self.b_each(f.params, 3, &mut ps);
                if f.is_variadic {
                    ps.push(self.p.txt("..."));
                }
                // Parameters normally GROUP (`a, self: i32`), which is not index-aligned with the node list, so a
                // list carrying comments is built one parameter per doc instead. Grouping is a flat-form
                // nicety, and a comment forces the broken form anyway.
                let popen = if f.generics.len != 0 {
                    self.nd(self.list_at(f.generics, f.generics.len - 1)).span.end;
                } else {
                    self.nd(f.name).span.end;
                };
                let pclose = if f.params.len != 0 {
                    self.find_close(self.nd(self.list_at(f.params, f.params.len - 1)).span.end, n.span.end, b')');
                } else {
                    popen;
                };
                if f.params.len != 0 && self.list_has_trivia(f.params, popen, pclose) {
                    let mut pu = Vector::<d::DocId>::new();
                    for pi in 0..f.params.len {
                        pu.push(self.b_param(self.list_at(f.params, pi)));
                    }
                    v.push(self.b_comma_list_tr("(", &pu, f.params, popen, pclose, ")", true));
                } else {
                    v.push(self.b_comma_list("(", &ps, ")", true));
                }
                if f.returns.len > 0 {
                    v.push(self.p.txt(" "));
                    v.push(self.b_returns(f.returns));
                }
                if f.where_clause.len > 0 {
                    v.push(self.p.txt(" where "));
                    for i in 0..f.where_clause.len {
                        if i > 0 {
                            v.push(self.p.txt(", "));
                        }
                        let w = self.nd(self.list_at(f.where_clause, i)).as_data.where_predicate;
                        v.push(self.b_type(w.ty));
                        v.push(self.p.txt(": "));
                        for k in 0..w.bounds.len {
                            if k > 0 {
                                v.push(self.p.txt(" + "));
                            }
                            let __h = self.list_at(w.bounds, k);
                            v.push(self.b_type(__h));
                        }
                    }
                }
                if f.body != NODE_NONE {
                    v.push(self.p.txt(" "));
                    v.push(self.b_block(f.body));
                } else {
                    v.push(self.p.txt(";"));
                }
            },
            NODE_STRUCT | NODE_ENUM => {
                let a = n.as_data.aggregate;
                if a.is_public {
                    v.push(self.p.txt("pub "));
                }
                if n.kind == NodeKind::NODE_ENUM {
                    v.push(self.p.txt("enum "));
                } else if a.is_union {
                    v.push(self.p.txt("union "));
                } else {
                    v.push(self.p.txt("struct "));
                }
                v.push(self.node_text(a.name));
                self.b_generics_lt(self.ast.lifetimes_of(id), a.generics, &mut v);
                if a.is_tuple {
                    // Tuple members are bare type nodes, not NODE_FIELD: render each directly.
                    let mut fz = Vector::<d::DocId>::new();
                    for i in 0..a.members.len {
                        fz.push(self.b_type(self.list_at(a.members, i)));
                    }
                    v.push(self.b_comma_list("(", &fz, ")", false));
                    v.push(self.p.txt(";"));
                } else if a.members.len == 0 {
                    if n.span.end > n.span.start && self.src.byte_at((n.span.end - 1) as usize) == b';' {
                        v.push(self.p.txt(";"));
                    } else {
                        v.push(self.p.txt(" {}"));
                    }
                } else {
                    v.push(self.p.txt(" {"));
                    let mut body = Vector::<d::DocId>::new();
                    let first_sp = self.nd(self.list_at(a.members, 0)).span;
                    let mut prev_end = first_sp.start;
                    for i in 0..a.members.len {
                        let mid = self.list_at(a.members, i);
                        let msp = self.nd(mid).span;
                        if i == 0 {
                            body.push(self.p.hardline());
                            let floor = self.item_gap_floor(n.span.start, msp.start);
                            self.emit_lead_list(floor, msp.start, &mut body);
                        } else {
                            self.emit_gap_vertical(prev_end, msp.start, &mut body, false);
                        }
                        if n.kind == NodeKind::NODE_ENUM {
                            body.push(self.b_variant(mid));
                        } else {
                            body.push(self.b_field(mid));
                        }
                        body.push(self.p.txt(","));
                        prev_end = msp.end;
                    }
                    self.emit_tail_list(prev_end, n.span.end - 1, &mut body);
                    let ic = self.p.concat(&body);
                    v.push(self.p.indent(ic));
                    v.push(self.p.hardline());
                    v.push(self.p.txt("}"));
                }
            },
            NODE_INTERFACE => {
                let itf = n.as_data.interface_def;
                if itf.is_public {
                    v.push(self.p.txt("pub "));
                }
                v.push(self.p.txt("interface "));
                v.push(self.node_text(itf.name));
                self.b_generics_lt(self.ast.lifetimes_of(id), itf.generics, &mut v);
                if itf.bounds.len > 0 {
                    v.push(self.p.txt(": "));
                    for i in 0..itf.bounds.len {
                        if i > 0 {
                            v.push(self.p.txt(" + "));
                        }
                        let __h = self.list_at(itf.bounds, i);
                        v.push(self.b_type(__h));
                    }
                }
                v.push(self.p.txt(" "));
                v.push(self.b_item_body(itf.items, n.span));
            },
            NODE_EXTEND => {
                let e = n.as_data.extend_def;
                if e.is_unsafe {
                    v.push(self.p.txt("unsafe "));
                }
                v.push(self.p.txt("extend"));
                if e.generics.len > 0 {
                    self.b_generics_lt(self.ast.lifetimes_of(id), e.generics, &mut v);
                }
                v.push(self.p.txt(" "));
                v.push(self.b_type(e.target_type));
                if e.interface_type != NODE_NONE {
                    v.push(self.p.txt(" as "));
                    v.push(self.b_type(e.interface_type));
                }
                v.push(self.p.txt(" "));
                v.push(self.b_item_body(e.items, n.span));
            },
            NODE_TYPE_ALIAS => {
                let t = n.as_data.type_alias;
                if t.is_public {
                    v.push(self.p.txt("pub "));
                }
                v.push(self.p.txt("type "));
                v.push(self.node_text(t.name));
                self.b_generics_lt(self.ast.lifetimes_of(id), t.generics, &mut v);
                if t.ty != NODE_NONE {
                    v.push(self.p.txt(" = "));
                    v.push(self.b_type(t.ty));
                }
                v.push(self.p.txt(";"));
            },
            NODE_CONST => {
                let c = n.as_data.const_def;
                if c.is_public {
                    v.push(self.p.txt("pub "));
                }
                if c.is_static_mut {
                    v.push(self.p.txt("static mut "));
                } else {
                    v.push(self.p.txt("const "));
                }
                v.push(self.node_text(c.name));
                if c.ty != NODE_NONE {
                    v.push(self.p.txt(": "));
                    v.push(self.b_type(c.ty));
                }
                if c.value != NODE_NONE {
                    v.push(self.p.txt(" = "));
                    v.push(self.b_expr(c.value));
                }
                v.push(self.p.txt(";"));
            },
            NODE_STATIC_ASSERT => {
                v.push(self.p.txt("static_assert("));
                v.push(self.b_expr(n.as_data.binary.left));
                if n.as_data.binary.right != NODE_NONE {
                    v.push(self.p.txt(", "));
                    v.push(self.b_expr(n.as_data.binary.right));
                }
                v.push(self.p.txt(");"));
            },
            NODE_EXTERN_BLOCK => {
                let e = n.as_data.extern_block;
                v.push(self.p.txt("extern "));
                if e.abi != NODE_NONE {
                    v.push(self.node_text(e.abi));
                    v.push(self.p.txt(" "));
                }
                if e.header != NODE_NONE {
                    v.push(self.node_text(e.header));
                    v.push(self.p.txt(" "));
                }
                v.push(self.b_item_body(e.items, n.span));
            },
            NODE_IMPORT => {
                let im = n.as_data.import_decl;
                v.push(self.p.txt("import "));
                for i in 0..im.path.len {
                    if i > 0 {
                        v.push(self.p.txt("::"));
                    }
                    let __h = self.list_at(im.path, i);
                    v.push(self.node_text(__h));
                }
                if im.glob {
                    v.push(self.p.txt(" as *"));
                } else if im.alias != NODE_NONE {
                    v.push(self.p.txt(" as "));
                    v.push(self.node_text(im.alias));
                }
                v.push(self.p.txt(";"));
            },
            _ => {
                v.push(self.node_text(id));
            },
        };
        let r = self.p.concat(&v);
        return r;
    }

    fn b_field(self: &mut Self, id: NodeId) d::DocId {
        let f = self.nd(id).as_data.field;
        let mut v = Vector::<d::DocId>::new();
        if f.is_public {
            v.push(self.p.txt("pub "));
        }
        v.push(self.node_text(f.name));
        v.push(self.p.txt(": "));
        v.push(self.b_type(f.ty));
        let r = self.p.concat(&v);
        return r;
    }

    fn b_variant(self: &mut Self, id: NodeId) d::DocId {
        let va = self.nd(id).as_data.variant;
        let mut v = Vector::<d::DocId>::new();
        v.push(self.node_text(va.name));
        if va.payload.len > 0 {
            if va.struct_payload {
                v.push(self.p.txt(" { "));
                for i in 0..va.payload.len {
                    if i > 0 {
                        v.push(self.p.txt(", "));
                    }
                    let __h = self.list_at(va.payload, i);
                    v.push(self.b_field(__h));
                }
                v.push(self.p.txt(" }"));
            } else {
                let mut pz = Vector::<d::DocId>::new();
                self.b_each(va.payload, 1, &mut pz);
                v.push(self.b_comma_list("(", &pz, ")", false));
            }
        }
        if va.value != NODE_NONE {
            v.push(self.p.txt(" = "));
            v.push(self.b_expr(va.value));
        }
        let r = self.p.concat(&v);
        return r;
    }

    // The `{ items }` body of interfaces, extends, extern blocks: items with gap trivia, always broken.
    fn b_item_body(self: &mut Self, items: NodeList, outer: tok::Span) d::DocId {
        let mut v = Vector::<d::DocId>::new();
        if items.len == 0 {
            v.push(self.p.txt("{}"));
            let r0 = self.p.concat(&v);
            return r0;
        }
        v.push(self.p.txt("{"));
        let mut body = Vector::<d::DocId>::new();
        let mut prev_end = 0u32;
        for i in 0..items.len {
            let iid = self.list_at(items, i);
            let isp = self.nd(iid).span;
            if i == 0 {
                body.push(self.p.hardline());
                let floor = self.item_gap_floor(outer.start, isp.start);
                self.emit_lead_list(floor, isp.start, &mut body);
            } else {
                self.emit_gap_vertical(prev_end, isp.start, &mut body, false);
            }
            body.push(self.b_item(iid));
            prev_end = isp.end;
        }
        self.emit_tail_list(prev_end, outer.end - 1, &mut body);
        let ic = self.p.concat(&body);
        v.push(self.p.indent(ic));
        v.push(self.p.hardline());
        v.push(self.p.txt("}"));
        let r = self.p.concat(&v);
        return r;
    }

    // Find the `{` between `from` and `to` so leading trivia scans start after it. Scans FORWARD and
    // skips comment interiors: the first member's leading comment may itself contain a brace, and a
    // backward scan would land inside it, dropping the comment from the lead-trivia window.
    fn item_gap_floor(self: &Self, from: u32, to: u32) u32 {
        let mut i = from as usize;
        while i < to as usize {
            let c = self.src.byte_at(i);
            if c == b'/' && i + 1 < to as usize && self.src.byte_at(i + 1) == b'/' {
                while i < to as usize && self.src.byte_at(i) != b'\n' {
                    i = i + 1;
                }
                continue;
            }
            if c == b'/' && i + 1 < to as usize && self.src.byte_at(i + 1) == b'*' {
                i = i + 2;
                while i + 1 < to as usize && !(self.src.byte_at(i) == b'*' && self.src.byte_at(i + 1) == b'/') {
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
}
