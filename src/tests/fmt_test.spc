// Formatter tests (fmt::formatter): golden spacing/indent/comment output, blank-line capping,
// idempotence (fmt(fmt(x)) == fmt(x)), parse preservation, and the semantic oracle -- the emitted C of
// an ugly program and of its formatted form must be byte-identical.
import fmt::formatter as fmtr;
import tests::harness as h;
import string as cstring;

fn fmt_of(src: str) String {
    let mut out = String::new();
    let ok = fmtr::format_source(src, null, &mut out);
    assert(ok, "format_source rejected a lexable source");
    return out;
}

fn expect_fmt(src: str, want: str) {
    let mut out = fmt_of(src);
    let got = out.as_str();
    assert(got.eq(&want), "formatted output mismatch");
    // Idempotence and parse preservation hold for every golden.
    let mut again = fmt_of(got);
    let got2 = again.as_str();
    assert(got2.eq(&got), "formatting is not idempotent");
    // Parse preservation is only checkable when the golden is a full program (not a fragment).
    if !h::parse_has_error(src) { assert(!h::parse_has_error(got), "formatted output does not parse"); }
    again.free();
    out.free();
}

@test
fn golden_basic() {
    expect_fmt("fn add(a:i32,b:i32)i32{\nreturn a+b;\n}", "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n");
}

@test
fn golden_spacing() {
    // Generics vs comparison, turbofish, ranges, unary ops, pointers, casts, indexing.
    expect_fmt("let v:Vector<i32> =Vector::<i32>::new();", "let v: Vector<i32> = Vector::<i32>::new();\n");
    expect_fmt("if a<b&&c>d{return -1;}", "if a < b && c > d { return -1; }\n");
    expect_fmt("for i in 0..self.len{unsafe self.ptr [ i ].free();}",
        "for i in 0..self.len { unsafe self.ptr[i].free(); }\n");
    expect_fmt("fn at(self:&Vector<T,A>,index:usize)&T{return &unsafe self.ptr[index];}",
        "fn at(self: &Vector<T, A>, index: usize) &T { return &unsafe self.ptr[index]; }\n");
    expect_fmt("let p=self.alloc.alloc(cap*sizeof (T),alignof (T))as*mut T;",
        "let p = self.alloc.alloc(cap * sizeof(T), alignof(T)) as *mut T;\n");
    expect_fmt("fn f(x:i32)(u64,usize){return (0,0);}", "fn f(x: i32) (u64, usize) { return (0, 0); }\n");
    expect_fmt("let m=Map::<u64,Vector<NodeId>>::new();", "let m = Map::<u64, Vector<NodeId>>::new();\n");
    expect_fmt("v.sort_by(|a:&i32,b:&i32|*b- *a);", "v.sort_by(|a: &i32, b: &i32| *b - *a);\n");
    expect_fmt("fn map<U,F:fn (&T)U>(self:&Self,f:F)U{}", "fn map<U, F: fn(&T) U>(self: &Self, f: F) U {}\n");
    // Slice-type heads glue to their element; `import` glues before `(` in @c attributes.
    expect_fmt("fn w(bytes:[] u8)usize{return 0;}", "fn w(bytes: []u8) usize { return 0; }\n");
    expect_fmt("fn r(x:[] mut T)[] mut T{return x;}", "fn r(x: []mut T) []mut T { return x; }\n");
    expect_fmt("@c.import (\"fopen\")\nfn q(){}", "@c.import(\"fopen\")\nfn q() {}\n");
}

@test
fn golden_indent() {
    expect_fmt("struct P{\nx:i32,\ny:i32,\n}\nextend P{\nfn go(self:&Self)i32{\nif self.x>0{\nreturn self.x;\n}\nreturn self.y;\n}\n}",
        "struct P {\n    x: i32,\n    y: i32,\n}\nextend P {\n    fn go(self: &Self) i32 {\n        if self.x > 0 {\n            return self.x;\n        }\n        return self.y;\n    }\n}\n");
    // A call broken across lines: arguments one level in, closer back at statement level.
    expect_fmt("f(\na,\nb,\n);", "f(\n    a,\n    b,\n);\n");
}

@test
fn golden_comments() {
    // A trailing line comment keeps its line, one space before it; standalone comments keep theirs.
    expect_fmt("let x=1;// tail\n// lead\nlet y=2;", "let x = 1; // tail\n// lead\nlet y = 2;\n");
    // Doc comments and block comments (multiline contents verbatim).
    expect_fmt("/// doc line\nfn f(){}", "/// doc line\nfn f() {}\n");
    expect_fmt("/* a\n   b */\nlet z=3;", "/* a\n   b */\nlet z = 3;\n");
    // A comment between tokens on one line is spaced on both sides.
    expect_fmt("let a=/*mid*/1;", "let a = /*mid*/ 1;\n");
}

@test
fn blank_lines_capped() {
    expect_fmt("let a=1;\n\n\n\nlet b=2;", "let a = 1;\n\nlet b = 2;\n");
    // Leading blank lines dropped; exactly one trailing newline.
    expect_fmt("\n\nlet a=1;", "let a = 1;\n");
}

@test
fn preserves_single_line_blocks() {
    // Author line breaks are preserved: single-line bodies stay single-line, multiline stays multiline.
    expect_fmt("pub fn len(self:&Self)usize{return self.len;}",
        "pub fn len(self: &Self) usize { return self.len; }\n");
}

@test
fn emitted_c_identical() {
    let ugly = "struct Pair{pub a:i32,pub b:i32}\nextend Pair{fn sum(self:&Self)i32{return self.a+self.b;}}\nfn main()i32{\nlet p=Pair{a:1,b:2,};\nlet mut t=0;\nfor i in 0..10{t=t+p.sum()*i;}\nreturn t&0;\n}";
    let mut f = fmt_of(ugly);
    let mut c1 = h::compile_c(ugly);
    let mut c2 = h::compile_c(f.as_str());
    assert(c1.ok(), "ugly variant does not compile");
    assert(c2.ok(), "formatted variant does not compile");
    assert(unsafe cstring::strcmp(c1.code as *const char, c2.code as *const char) == 0,
        "emitted C differs between ugly and formatted variants");
    c1.free();
    c2.free();
    f.free();
}
