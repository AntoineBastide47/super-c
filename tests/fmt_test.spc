// Canonical (document) formatter tests: goldens for spacing/indent/width breaking/comments/@fmt.skip,
// idempotence (fmt(fmt(x)) == fmt(x)) baked into every golden, and the semantic oracle -- the emitted
// C of an ugly program and of its formatted form must be byte-identical.
import fmt::builder as fbld;
import ast::ast as *;
import tests::harness as h;
import string as cstring;

// Parse + format at `width`. Asserts the source parses (goldens are full programs).
fn fmt_of(src: str, width: i32) String {
    let pa = h::parse_ast(src);
    assert(pa.errors == 0, "golden source does not parse");
    let mut out = String::new();
    fbld::format_program(&pa.ast, src, width, &mut out);
    return out;
}

fn expect_fmt_w(src: str, want: str, width: i32) {
    let out = fmt_of(src, width);
    let got = out.as_str();
    assert(got == want, "formatted output mismatch");
    // Idempotence and parse preservation for every golden.
    assert(!h::parse_has_error(got), "formatted output does not parse");
    let again = fmt_of(got, width);
    let got2 = again.as_str();
    assert(got2 == got, "formatting is not idempotent");
}

fn expect_fmt(src: str, want: str) {
    expect_fmt_w(src, want, 120);
}

@test
fn golden_unsafe_fn() {
    expect_fmt(
        "pub unsafe fn f(p:*const i32)i32{return unsafe *p;}",
        "pub unsafe fn f(p: *const i32) i32 {\n    return unsafe *p;\n}\n",
    );
}

@test
fn golden_basic() {
    // Fully canonical: single-line input becomes the one true form.
    expect_fmt("fn add(a:i32,b:i32)i32{return a+b;}", "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n");
}

@test
fn golden_param_groups() {
    // A `a, b: T` group (shared ty node) round-trips as written; separately-typed params never merge,
    // even when the types read the same -- the formatter preserves the author's form both ways.
    expect_fmt(
        "fn f(a,b:*const void,n:usize)i32{return 0;}",
        "fn f(a, b: *const void, n: usize) i32 {\n    return 0;\n}\n",
    );
    expect_fmt("fn g(x:i32,a,mut b,c:f32,y:f32){}", "fn g(x: i32, a, mut b, c: f32, y: f32) {}\n");
    expect_fmt("fn h(a:f32,b:f32){}", "fn h(a: f32, b: f32) {}\n");
}

@test
fn golden_spacing() {
    expect_fmt(
        "fn t(){let v:Vector<i32> =Vector::<i32>::new();}",
        "fn t() {\n    let v: Vector<i32> = Vector::<i32>::new();\n}\n",
    );
    expect_fmt(
        "fn t(a:i32,b:i32,c:i32,d:i32)i32{if a<b&&c>d{return -1;}return 0;}",
        "fn t(a: i32, b: i32, c: i32, d: i32) i32 {\n    if a < b && c > d {\n        return -1;\n    }\n    return 0;\n}\n",
    );
    expect_fmt(
        "struct V{p:*mut i32}extend V{fn at(self:&V,index:usize)&i32{return &unsafe self.p[index];}}",
        "struct V {\n    p: *mut i32,\n}\nextend V {\n    fn at(self: &V, index: usize) &i32 {\n        return &unsafe self.p[index];\n    }\n}\n",
    );
    expect_fmt(
        "fn t(cap:usize)usize{return (cap*sizeof(i64))as usize;}",
        "fn t(cap: usize) usize {\n    return (cap * sizeof(i64)) as usize;\n}\n",
    );
    expect_fmt("fn f(x:i32)(u64,usize){return (0,0);}", "fn f(x: i32) (u64, usize) {\n    return (0, 0);\n}\n");
}

@test
fn golden_parens() {
    // The parser drops parentheses; precedence re-inserts exactly the needed ones.
    expect_fmt(
        "fn t(a:i32,b:i32,c:i32)i32{return (a+b)*c;}",
        "fn t(a: i32, b: i32, c: i32) i32 {\n    return (a + b) * c;\n}\n",
    );
    expect_fmt(
        "fn t(a:i32,b:i32,c:i32)i32{return a+b*c;}",
        "fn t(a: i32, b: i32, c: i32) i32 {\n    return a + b * c;\n}\n",
    );
    expect_fmt("fn t(p:*mut i32)i32{return (*p)+1;}", "fn t(p: *mut i32) i32 {\n    return *p + 1;\n}\n");
}

@test
fn golden_width_break() {
    // A call that does not fit breaks with one argument per line and a trailing comma.
    expect_fmt_w(
        "fn t(){takes_many(first_argument,second_argument,third_argument);}",
        "fn t() {\n    takes_many(\n        first_argument,\n        second_argument,\n        third_argument,\n    );\n}\n",
        40,
    );
    // The same call at a comfortable width stays flat.
    expect_fmt_w(
        "fn t(){takes_many(first_argument,second_argument,third_argument);}",
        "fn t() {\n    takes_many(first_argument, second_argument, third_argument);\n}\n",
        120,
    );
}

@test
fn golden_comments() {
    expect_fmt(
        "// lead\nfn t(){let x=1;// tail\nlet y=2;}",
        "// lead\nfn t() {\n    let x = 1; // tail\n    let y = 2;\n}\n",
    );
    expect_fmt("/// doc line\nfn f(){}", "/// doc line\nfn f() {}\n");
    expect_fmt("fn f(){\n// dangling\n}", "fn f() {\n    // dangling\n}\n");
    expect_fmt("fn f(){let a=1;\n\n\n\nlet b=2;}", "fn f() {\n    let a = 1;\n\n    let b = 2;\n}\n");
}

@test
fn golden_fmt_skip() {
    expect_fmt(
        "@fmt.skip\nfn weird(  a:i32 )i32{ return   a; }\nfn n(a:i32)i32{return a;}",
        "@fmt.skip\nfn weird(  a:i32 )i32{ return   a; }\nfn n(a: i32) i32 {\n    return a;\n}\n",
    );
}

@test
fn emitted_c_identical() {
    let ugly = "struct Pair{pub a:i32,pub b:i32}\nextend Pair{fn sum(self:&Self)i32{return self.a+self.b;}}\nfn main()i32{\nlet p=Pair{a:1,b:2,};\nlet mut t=0;\nfor i in 0..10{t=t+p.sum()*i;}\nreturn t&0;\n}";
    let f = fmt_of(ugly, 120);
    let c1 = h::compile_c(ugly);
    let c2 = h::compile_c(f.as_str());
    assert(c1.ok(), "ugly variant does not compile");
    assert(c2.ok(), "formatted variant does not compile");
    assert(unsafe cstring::strcmp(c1.code, c2.code) == 0, "emitted C differs between ugly and formatted variants");
}

@test
fn golden_const_fn() {
    expect_fmt("pub   const   fn sq(a:i32)i32{return a*a;}", "pub const fn sq(a: i32) i32 {\n    return a * a;\n}\n");
    expect_fmt(
        "extend Pt{const fn zero()Pt{return Pt{x:0,y:0};}}\nstruct Pt{x:i32,y:i32}",
        "extend Pt {\n    const fn zero() Pt {\n        return Pt { x: 0, y: 0 };\n    }\n}\nstruct Pt {\n    x: i32,\n    y: i32,\n}\n",
    );
}

@test
fn golden_lifetimes() {
    // Lifetime params print merged back into the one `<...>`, lifetimes first; `&'a T` keeps its
    // annotation and `&'a mut T` keeps lifetime-before-mut. (The formatter must round-trip this
    // BEFORE any src/std source uses it -- otherwise fmt would silently delete annotations.)
    expect_fmt("struct Ref<'a>{pub p:&'a i32}", "struct Ref<'a> {\n    pub p: &'a i32,\n}\n");
    expect_fmt("fn borrow<'a>(x:&'a i32)&'a i32{return x;}", "fn borrow<'a>(x: &'a i32) &'a i32 {\n    return x;\n}\n");
    expect_fmt("fn m<'a>(x:&'a mut i32){*x=1;}", "fn m<'a>(x: &'a mut i32) {\n    *x = 1;\n}\n");
    expect_fmt(
        "fn two<'a,'b:'a,T>(x:&'a T,y:&'b T)&'a T where T:'a{return x;}",
        "fn two<'a, 'b: 'a, T>(x: &'a T, y: &'b T) &'a T where T: 'a {\n    return x;\n}\n",
    );
    // higher-ranked bound: the `for<..>` prefix must survive, or fmt would silently drop the ranking
    expect_fmt(
        "fn apply<F:for<'a>fn(&'a i32)i32>(f:F,x:&i32)i32{return f(x);}",
        "fn apply<F: for<'a> fn(&'a i32) i32>(f: F, x: &i32) i32 {\n    return f(x);\n}\n",
    );
    // a lifetime-parameterised associated type (GAT)
    expect_fmt("interface Lend{type Item<'a>;}", "interface Lend {\n    type Item<'a>;\n}\n");
}
