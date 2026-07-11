// Unit tests for the document IR + width-aware renderer (fmt::doc): flat-vs-broken groups, nested
// groups, hard/blank lines, IfBreak trailing commas, indentation, and the flat-width memo.
import fmt::doc as d;

// group( "foo(" indent(softline join("," line, args)) softline ")" )
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
    inner.push(p.ifbreak(",", false)); // trailing comma only when broken
    let ic = p.concat(&inner);
    parts.push(p.indent(ic));
    parts.push(p.softline());
    parts.push(p.txt(")"));
    let body = p.concat(&parts);
    let g = p.group(body);
    inner.free();
    parts.free();
    return g;
}

fn render_of(p: &d::DocPool, root: d::DocId, width: i32) String {
    let mut out = String::new();
    d::render(p, root, width, &mut out);
    return out;
}

fn expect_render(p: &d::DocPool, root: d::DocId, width: i32, want: str) {
    let mut got = render_of(p, root, width);
    let gs = got.as_str();
    assert(gs.eq(&want), "render mismatch");
    got.free();
}

@test
fn group_fits_flat() {
    let mut p = d::DocPool::new(null);
    let g = call_doc(&mut p, ["first", "second", "third"]);
    expect_render(&p, g, 80, "foo(first, second, third)\n");
    p.free();
}

@test
fn group_breaks_when_too_wide() {
    let mut p = d::DocPool::new(null);
    let g = call_doc(&mut p, ["first", "second", "third"]);
    expect_render(&p, g, 20, "foo(\n    first,\n    second,\n    third,\n)\n");
    p.free();
}

@test
fn nested_groups_break_outer_first() {
    // outer group breaks, inner still fits flat on its own line.
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
    parts.free();
    expect_render(&p, outer, 80, "let x = foo(a, b);\n");
    expect_render(&p, outer, 14, "let x =\n    foo(a, b);\n");
    expect_render(&p, outer, 12, "let x =\n    foo(\n        a,\n        b,\n    );\n");
    p.free();
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
    body.free();
    parts.free();
    // Even at huge width a hardline group breaks.
    expect_render(&p, g, 1000, "{\n    stmt;\n}\n");
    p.free();
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
    parts.free();
    expect_render(&p, cc, 80, "hello\n\nworld\n");
    p.free();
}

@test
fn flat_width_memo() {
    let mut p = d::DocPool::new(null);
    let t = p.txt("abcd");
    let l = p.line();
    let mut parts = Vector::<d::DocId>::new();
    parts.push(t);
    parts.push(l);
    parts.push(t); // shared DocId: DAG reuse is legal
    let cc = p.concat(&parts);
    parts.free();
    assert_eq((*p.docs.at(cc as usize)).w, 9u32); // 4 + 1 + 4
    let h = p.hardline();
    let ph = p.pair(cc, h);
    assert_eq((*p.docs.at(ph as usize)).w, d::W_INF);
    p.free();
}
