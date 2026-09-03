// Unit tests for the document IR + width-aware renderer (fmt::doc): flat-vs-broken groups, nested
// groups, hard/blank lines, IfBreak trailing commas, indentation, and the flat-width memo.
import fmt::doc as d;

// `group( "foo(" indent(softline join("," line, args)) softline ")" )`.
fn call_doc(p: &mut d::DocPool, args: []str) d::DocId {
    let mut parts = Vector::<d::DocId>::new();
    parts.push(p.txt("foo("));
    let mut inner = Vector::<d::DocId>::new();
    inner.push(p.softline());
    for i in 0..args.len() {
        if i > 0 {
            inner.push(p.txt(","));
            inner.push(p.line());
        }
        inner.push(p.txt(args[i]));
    }
    // Trailing comma only when broken.
    inner.push(p.ifbreak(",", false));
    let ic = p.concat(&inner);
    parts.push(p.indent(ic));
    parts.push(p.softline());
    parts.push(p.txt(")"));
    let body = p.concat(&parts);
    let g = p.group(body);
    return g;
}

fn render_of(p: &d::DocPool, root: d::DocId, width: i32) String {
    let mut out = String::new();
    p.render(root, width, &mut out);
    return out;
}

fn expect_render(p: &d::DocPool, root: d::DocId, width: i32, want: str) {
    let got = render_of(p, root, width);
    let gs = got.as_str();
    assert(gs == want, "render mismatch");
}

@test
fn group_fits_flat() {
    let mut p = d::DocPool::new(null);
    let g = call_doc(&mut p, ["first", "second", "third"]);
    expect_render(&p, g, 80, "foo(first, second, third)\n");
}

@test
fn group_breaks_when_too_wide() {
    let mut p = d::DocPool::new(null);
    let g = call_doc(&mut p, ["first", "second", "third"]);
    expect_render(&p, g, 20, "foo(\n    first,\n    second,\n    third,\n)\n");
}

@test
fn nested_groups_break_outer_first() {
    // Outer group breaks, inner still fits flat on its own line.
    let mut p = d::DocPool::new(null);
    let inner = call_doc(&mut p, ["a", "b"]);
    let mut parts = Vector::<d::DocId>::new();
    parts.push(p.txt("let x ="));
    let l = p.line();
    parts.push(l);
    parts.push(inner);
    parts.push(p.txt(";"));
    let cc = p.concat(&parts);
    let ind = p.indent(cc);
    let outer = p.group(ind);
    expect_render(&p, outer, 80, "let x = foo(a, b);\n");
    expect_render(&p, outer, 14, "let x =\n    foo(a, b);\n");
    expect_render(&p, outer, 12, "let x =\n    foo(\n        a,\n        b,\n    );\n");
}

@test
fn hardline_forces_group_broken() {
    let mut p = d::DocPool::new(null);
    let mut parts = Vector::<d::DocId>::new();
    parts.push(p.txt("{"));
    let mut body = Vector::<d::DocId>::new();
    body.push(p.hardline());
    body.push(p.txt("stmt;"));
    let bc = p.concat(&body);
    parts.push(p.indent(bc));
    parts.push(p.hardline());
    parts.push(p.txt("}"));
    let cc = p.concat(&parts);
    let g = p.group(cc);
    // Even at huge width a hardline group breaks.
    expect_render(&p, g, 1000, "{\n    stmt;\n}\n");
}

@test
fn blankline_and_span_text() {
    let src = "hello world";
    let mut p = d::DocPool::new(src.ptr());
    let mut parts = Vector::<d::DocId>::new();
    parts.push(p.span(0, 5));
    parts.push(p.blankline());
    parts.push(p.span(6, 11));
    let cc = p.concat(&parts);
    expect_render(&p, cc, 80, "hello\n\nworld\n");
}

@test
fn flat_width_memo() {
    let mut p = d::DocPool::new(null);
    let t = p.txt("abcd");
    let l = p.line();
    let mut parts = Vector::<d::DocId>::new();
    parts.push(t);
    parts.push(l);
    // Shared DocId: DAG reuse is legal.
    parts.push(t);
    let cc = p.concat(&parts);
    // 4 + 1 + 4.
    assert_eq(p.docs.at(cc as usize).w, 9u32);
    let h = p.hardline();
    let mut pair = Vector::<d::DocId>::new();
    pair.push(cc);
    pair.push(h);
    let ph = p.concat(&pair);
    assert_eq(p.docs.at(ph as usize).w, d::W_INF);
}
