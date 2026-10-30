// The syntax API: source-ordered trees over the compiler's parser that keep every token, stay traversable on
// invalid text, typed views of declarations, checked workspace edits, the builder, and the formatter.
import api::syntax as *;
import api::session as ses;
import api::errors as *;
import tests::cli_harness as cli;
import driver::util as dutil;

const SRC: str = M"(import std::vector as v;

// Adds one.
fn inc(x: i32, y: i32) i32 {
    let z: i32 = (x + 1);
    return add(z, y);
}

struct P {
    a: i32,
    b: u8,
}
)";

@test
fn trees_keep_text_order_and_every_token() {
    let t = SyntaxTree::parse("a.spc", SRC);
    assert(t.is_valid(), "valid");
    let root = t.root();
    assert(root.kind() == SyntaxKind::Program, "the root is the file");
    assert_eq(root.range().end as usize, SRC.len());
    let mut kinds = Vector::<SyntaxKind>::new();
    for c in root.children() {
        kinds.push(c.kind());
    }
    assert_eq(kinds.len(), 3);
    assert(
        kinds[0] == SyntaxKind::Import && kinds[1] == SyntaxKind::Function && kinds[2] == SyntaxKind::Struct,
        "items in order",
    );
    // Preorder is text order: each node starts at or after the one before.
    let mut last: u32 = 0;
    let mut n: usize = 0;
    for d in root.descendants() {
        assert(d.range().start >= last, "source order");
        last = d.range().start;
        let p = d.parent().unwrap();
        assert(p.range().start <= d.range().start && d.range().end <= p.range().end, "a child lies inside its parent");
        n += 1;
    }
    assert(n > 20, "the whole tree is reachable");
    let mut comments: usize = 0;
    let mut parens: usize = 0;
    for k in t.tokens() {
        if k.kind() == TokenKind::Comment {
            comments += 1;
            assert_eq(k.text(), "// Adds one.");
        }
        if k.text() == "(" {
            parens += 1;
        }
    }
    assert_eq(comments, 1);
    assert_eq(parens, 3);
    let at = SRC.find("add(") as u32;
    let call = t.node_at(at).parent().unwrap();
    assert(call.kind() == SyntaxKind::Call, "the call holds its callee");
    let cv = call.as_call().unwrap();
    assert_eq(cv.callee().unwrap().text(), "add");
    let mut args = Vector::<String>::new();
    for a in cv.args() {
        args.push(String::from_str(a.text()));
    }
    assert_eq(args.len(), 2);
    assert_eq(args[1].as_str(), "y");
    assert(t.token_at(at).unwrap().kind() == TokenKind::Ident, "an identifier token");
    assert(t.token_at(0).unwrap().kind() == TokenKind::Keyword, "a keyword token");
}

@test
fn typed_views_read_declarations() {
    let t = SyntaxTree::parse("a.spc", SRC);
    let mut fns: usize = 0;
    for c in t.root().children() {
        if let Some(f) = c.as_fn() {
            fns += 1;
            assert_eq(f.name().unwrap().text(), "inc");
            let mut ps = Vector::<String>::new();
            for p in f.params() {
                ps.push(format("{}:{}", p.name().unwrap().text(), p.ty().unwrap().text()));
            }
            assert_eq(ps.len(), 2);
            assert_eq(ps[0].as_str(), "x:i32");
            let mut rs: usize = 0;
            for r in f.returns() {
                assert_eq(r.text(), "i32");
                rs += 1;
            }
            assert_eq(rs, 1);
            let body = f.body().unwrap();
            assert(body.kind() == SyntaxKind::Block, "a block body");
            let first = body.children().next().unwrap();
            let l = first.as_let().unwrap();
            assert_eq(l.pattern().unwrap().text(), "z");
            assert_eq(l.ty().unwrap().text(), "i32");
            assert(!l.is_mutable(), "an immutable binding");
            // The dropped parentheses stay in the let's tokens.
            let mut toks = String::new();
            for k in first.tokens() {
                toks.push_str(k.text());
            }
            assert_eq(toks.as_str(), "letz:i32=(x+1);");
        }
        if let Some(s) = c.as_aggregate() {
            assert_eq(s.name().unwrap().text(), "P");
            let mut fs = Vector::<String>::new();
            for m in s.members() {
                fs.push(String::from_str(m.name().unwrap().text()));
            }
            assert_eq(fs.len(), 2);
            assert_eq(fs[1].as_str(), "b");
        }
        if let Some(im) = c.as_import() {
            let mut segs = String::new();
            for sg in im.path() {
                segs.push_str(sg.text());
                segs.push_str("/");
            }
            assert_eq(segs.as_str(), "std/vector/");
            assert_eq(im.alias().unwrap().text(), "v");
            assert(!im.is_glob(), "not a glob");
        }
    }
    assert_eq(fns, 1);
}

@test
fn invalid_text_stays_traversable() {
    let bad = "fn broken( {\n    let = ;\n}\n\nfn fine() i32 {\n    return 1;\n}\n";
    let t = SyntaxTree::parse("b.spc", bad);
    assert(!t.is_valid(), "errors are reported");
    assert(t.errors()[0].range.start < bad.len() as u32, "at a range of the text");
    let mut names = Vector::<String>::new();
    for d in t.root().descendants() {
        if let Some(f) = d.as_fn() {
            if let Some(nm) = f.name() {
                names.push(String::from_str(nm.text()));
            }
        }
    }
    assert(names.len() >= 1 && names[names.len() - 1].as_str() == "fine", "the declaration after the error is found");
}

@test
fn formats_as_super_c_fmt() {
    let messy = "fn   main( )i32{return 0;}\n";
    let out = format_file("m.spc", messy, 120).unwrap();
    let mut want = String::new();
    let src = String::from_str(messy);
    assert(dutil::format_source(&src, "m.spc", 120, false, &mut want), "the CLI formatter formats it");
    assert_eq(out.as_str(), want.as_str());
    let e = format_file("m.spc", "fn main( {", 120).unwrap_err();
    assert(e.code == Code::ParseFailed, "unparsable text does not format");
}

@test
fn builds_checked_source() {
    let mut b = Builder::new();
    b.open("pub fn three() i32");
    b.line("return 3;");
    b.close();
    assert_eq(b.finish().unwrap().as_str(), "pub fn three() i32 {\n    return 3;\n}\n");
    let mut bad = Builder::new();
    bad.line("fn ( {");
    assert(bad.finish().unwrap_err().code == Code::ParseFailed, "an unparsable fragment rejects");
    let mut open = Builder::new();
    open.open("fn f()");
    assert(open.finish().unwrap_err().code == Code::ParseFailed, "an open block rejects");
}

@test
fn workspace_edits_check_before_they_apply() {
    let proj = cli::proj_new();
    proj.mkfile("a.spc", SRC);
    let a = format("{}/a.spc", proj.dir());
    let mut s = ses::Session::open_file(a.as_str(), ses::Config::host("std")).unwrap();
    let at = SRC.find("x + 1") as u32;
    let mut overlap = WorkspaceEdit::new();
    overlap.replace(a.as_str(), at, at + 5, "x");
    overlap.replace(a.as_str(), at + 2, at + 3, "-");
    assert(overlap.preview(&mut s).unwrap_err().code == Code::InvalidArgument, "overlapping edits reject");
    let mut stale = WorkspaceEdit::new();
    stale.replace(a.as_str(), at, at + 5, "x");
    stale.expect(a.as_str(), 3);
    assert(stale.apply(&mut s).unwrap_err().code == Code::InvalidArgument, "a stale version rejects");
    let mut breaks = WorkspaceEdit::new();
    breaks.replace(a.as_str(), at, at + 5, "x +");
    assert(breaks.apply(&mut s).unwrap_err().code == Code::VerificationFailed, "an edit that breaks the parse rejects");
    assert_eq(s.version(a.as_str()), -1);
    let mut good = WorkspaceEdit::new();
    good.replace(a.as_str(), at, at + 5, "x * 2");
    good.expect(a.as_str(), -1);
    let pv = good.preview(&mut s).unwrap();
    assert_eq(pv.len(), 1);
    let rev = good.apply(&mut s).unwrap();
    assert_eq(rev, s.revision());
    let now = s.text(a.as_str()).unwrap().unwrap();
    assert_eq(now.as_str(), pv[0].text.as_str());
    let t = tree_of(&mut s, a.as_str()).unwrap();
    assert(t.text().find("(x * 2)") >= 0, "the tree reads the session's buffer");
}

@test
fn typed_views_reach_their_nodes() {
    let src = "union U {\n    a: i32,\n    b: f32,\n}\n\nfn g<T>(x: T) T {\n    let y = f(x);\n    return y;\n}\n";
    let t = SyntaxTree::parse("u.spc", src);
    assert_eq(t.path(), "u.spc");
    let mut seen: u32 = 0;
    for c in t.root().children() {
        if let Some(a) = c.as_aggregate() {
            assert(a.is_union() && a.node().kind() == SyntaxKind::Struct, "a union");
            seen += 1;
        }
        if let Some(f) = c.as_fn() {
            assert(f.node().kind() == SyntaxKind::Function, "a function");
            assert_eq(f.generics().next().unwrap().text(), "T");
            let l = f.body().unwrap().children().next().unwrap().as_let().unwrap();
            assert(l.node().kind() == SyntaxKind::Let, "a let");
            let v = l.value().unwrap();
            let call = v.as_call().unwrap();
            assert(call.node().kind() == SyntaxKind::Call, "a call");
            let tok = t.token_at(v.range().start).unwrap();
            assert(tok.parent().range().start == v.range().start, "a token's node holds it");
            seen += 1;
        }
    }
    assert_eq(seen, 2);
    let imp = SyntaxTree::parse("i.spc", "import a::b;\n");
    let iv = imp.root().children().next().unwrap().as_import().unwrap();
    assert(iv.node().kind() == SyntaxKind::Import, "an import");
    let mut b = Builder::new();
    b.line("const K: i32 = 1;");
    assert_eq(b.text(), "const K: i32 = 1;\n");
}
