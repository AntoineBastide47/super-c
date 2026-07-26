// Self-hosted port of tests/cli_test.c: drives $SUPERC as a subprocess over on-disk source trees, dogfooding
// the self-hosted driver's CLI surface (usage/argc/missing-file/error-exit/retired-flag) AND the end-to-end
// multi-file build pipeline (cross-module, generics, dyn, ffi, imports, extern-C, defaults, CTFE, --test).
// Each @test writes a source tree with cli::Proj, compiles it (compile-only, emitting build/), then cc's the
// emitted tree -Werror and runs it. Source trees are embedded verbatim as multi-line raw strings.
import tests::cli_harness as cli;
import stdio;

struct Cmd {
    pub b: [char; 2048],
}

// A valid file compiles (exit 0), emits its module .c under build/, and that C compiles + runs with the exit
// code the program requests.
@test
fn compiles_file() {
    let p = cli::proj_new();
    p.mkfile("prog.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(7); }\n");
    let r = p.compile("prog.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_exists("prog.c"), "module .c is emitted under build/");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 7);
}

// A second module's enums used across the boundary: value return, payload-less match, payload construction
// and match. Drives the multi-file build/ tree (subdirs) through cc + run.
@test
fn cross_module_enum() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        r#"pub enum Color { Red, Green = 5, Blue }
pub enum Box { Empty, Filled(i32) }
pub fn red() Color { return Color::Red; }
"#,
    );
    p.mkfile(
        "xm.spc",
        r#"import lib::lib;
extern "C" { fn exit(code: i32) void; }
fn color_code(c: lib::lib::Color) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }
fn box_amt(b: lib::lib::Box) i32 { return switch b { Filled(n) => n, Empty => -1, }; }
fn main() i32 { let c = lib::lib::red(); let b = lib::lib::Box::Filled(20);
  unsafe exit(color_code(c) + box_amt(b)); }
"#,
    );
    let r = p.compile("xm.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 21);
}

// --const-eval end to end: folded static_assert (true passes / false errors at Super-C level), folded
// designated indices, folded sizeof over the computed layout, [T; N] as a generic arg, and the layout
// _Static_asserts landing in the C and PASSING under -Werror.
@test
fn const_eval_flag() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"extern "C" { fn exit(code: i32) void; }
const K: i32 = 2;
struct Pt { pub x: i32, pub y: u8 }
struct Wrap<T> { pub v: T }
static_assert(sizeof(Pt) == 8, "padded to 8");
static_assert(K * 2 == 4, "folds");
static_assert(sizeof(Wrap<[i32; 4]>) == 16, "array arg layout");
fn main() i32 {
  let a: [i32; 2 + 2] = [[K] = 30, [K + 1] = 10, [1 - 1] = 2];
  let w = Wrap::<[i32; 4]> { v: [1, 2, 3, 4] };
  unsafe exit(a[2] + a[3] + a[0] + w.v[3] + (sizeof((i32, bool)) as i32));
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "[2] = 30"), "const designator index folded into the C output");
    assert(p.gen_has("main.c", "_Static_assert(sizeof(Pt) == 8"), "layout verification assert emitted");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 54);

    // a folded-FALSE static_assert is a SUPER-C error (with our span), not a downstream C error
    p.mkfile("main.spc", "static_assert(1 + 1 == 3, \"nope\");\nfn main() i32 { return 0; }\n");
    let e = p.compile("main.spc");
    assert(e.exit != 0, "folded-false static_assert fails the build");
    assert(e.out_has("static assertion failed"), "and names the failure");
    // tiny budgets keep plain scalar folding working
    let b = p.compile_flags("--const-eval-steps=4096 --const-eval-memory=1M", "main.spc");
    assert(b.exit != 0, "tiny budgets still fold scalar asserts");
    assert(b.out_has("static assertion failed"), "same failure under tiny budgets");
    // the retired --const-eval flag is rejected with usage
    let rt = p.compile_flags("--const-eval", "main.spc");
    assert(rt.exit != 0, "the retired --const-eval flag is rejected");
    assert(rt.out_has("USAGE:"), "and prints usage");
}

// Implicit CTFE: folded-argument calls RUN at compile time (recursion, loops, switch, compound assignment),
// call sites emit the literal, pure statement-position calls vanish, unfoldable/over-budget callees degrade
// to runtime calls, and the compile stays fast.
@test
fn ctfe() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"extern "C" { fn rand() i32; }
fn fib(n: i32) i32 {
  if n < 2 { return n; }
  return fib(n - 1) + fib(n - 2);
}
fn collatz(mut n: u64) i32 {
  let mut c = 0;
  while n != 1 { n = switch n % 2 { 0 => n / 2, _ => 3 * n + 1 }; c += 1; }
  return c;
}
fn half(x: f64) f64 { return x / 2.0; }
fn late() i32 { return unsafe rand(); }
static_assert(fib(20) == 6_765, "ctfe");
static_assert(collatz(27) == 111, "loops fold");
static_assert(half(3.0) == 1.5, "floats fold");
fn main() i32 {
  fib(9);
  let x = fib(10) - 47;
  if late() < 0 { return 1; }
  return x;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", r#"_Static_assert(true, "ctfe")"#), "fib(20) ran at compile time");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "loops fold")"#), "collatz(27) ran at compile time");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "floats fold")"#), "float CTFE ran at compile time");
    assert(p.gen_has("main.c", "x = 8;"), "the call site folded to its value");
    assert(!p.gen_has("main.c", "fib(10"), "no interpreted call survives in main (fib(10))");
    assert(!p.gen_has("main.c", "fib(9"), "no interpreted call survives in main (fib(9))");
    assert(p.gen_has("main.c", "late()"), "an un-intercepted extern callee stays a runtime call");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 8);

    // an over-budget callee bails to a runtime call instead of hanging the compiler
    p.mkfile(
        "main.spc",
        r#"fn spin() i32 {
  let mut i = 0;
  while true { i += 1; if i > 100_000_000 { return i; } }
  return 0;
}
fn main() i32 { if spin() > 0 { return 3; } return 4; }
"#,
    );
    let s = p.compile("main.spc");
    assert_eq(s.exit, 0);
    assert(p.gen_has("main.c", "spin()"), "over-budget callee stays a runtime call");

    // --const-eval-steps starves a loop-driven assert -> reports the budget
    p.mkfile(
        "main.spc",
        r#"fn burn() i32 { let mut i = 0; while i < 1_000_000 { i += 1; } return i; }
static_assert(burn() == 1_000_000, "needs execution");
fn main() i32 { return 0; }
"#,
    );
    let b = p.compile_flags("--const-eval-steps=4096", "main.spc");
    assert(b.exit != 0, "a starved assert fails the build");
    assert(b.out_has("step budget exceeded"), "and blames the budget");

    // the (fn, args) call memo folds fib(40) comfortably inside a 100k-step budget
    p.mkfile(
        "main.spc",
        r#"fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }
static_assert(fib(40) == 102_334_155, "memoized");
fn main() i32 { return 0; }
"#,
    );
    let m = p.compile_flags("--const-eval-steps=100000", "main.spc");
    assert_eq(m.exit, 0);
    assert(p.gen_has("main.c", r#"_Static_assert(true, "memoized")"#), "the call cache collapsed the recursion");

    // raw strings are CTFE-visible (hash-delimited content with an interior quote folds like any literal)
    p.mkfile(
        "main.spc",
        r##"const G: str = r#"say "hi""#;
static_assert(G.len() == 8, "raw folds");
fn main() i32 { return 0; }
"##,
    );
    let rw = p.compile("main.spc");
    assert_eq(rw.exit, 0);
    assert(p.gen_has("main.c", r#"_Static_assert(true, "raw folds")"#), "raw string len folded at compile time");
}

// CTFE over aggregates and the abstract heap: structs + methods + extend dispatch, local arrays, generics,
// intercepted malloc/free, payload enums through switch, and a std Vector round trip -- all interpreted.
// Also: an assert may precede its callee (deferred re-check) and a would-be trap reports its reason.
@test
fn ctfe_memory() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"static_assert(vec_sum() == 44, "deferred: asserts may precede their callee");
struct Pt { x: i32, y: i32 }
extend Pt {
  pub fn mag2(self: &Pt) i32 { return self.x * self.x + self.y * self.y; }
  pub fn shift(self: &mut Pt, dx: i32) { self.x += dx; }
  pub fn make(x: i32, y: i32) Pt { return Pt { x: x, y: y }; }
}
extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
fn structs() i32 {
  let mut p = Pt::make(3, 4);
  p.shift(1);
  let a: [i32; 4] = [[1] = p.mag2(), 1];
  let mut s = 0;
  for v in a { s += v; }
  return s;
}
static_assert(structs() == 33, "aggregates fold");
fn heap() i32 {
  let p = unsafe malloc(2 * sizeof(i64)) as *mut i64;
  unsafe p[0] = 40;
  unsafe p[1] = unsafe p[0] + 2;
  let r = unsafe p[1];
  unsafe free(p);
  return (r as i32);
}
static_assert(heap() == 42, "the abstract heap folds");
fn opt(k: i32) i32 {
  let o = if k > 0 { Option::<i32>::Some(k); } else { Option::<i32>::None; };
  return switch o { Some(v) => v + 1, None => -1, };
}
static_assert(opt(4) == 5 && opt(-4) == -1, "payload enums fold");
fn vec_sum() i32 {
  let mut x = Vector::<i32>::with_capacity(2);
  x.push(7);
  x.push(35);
  let s = x[0] + x[1] + (x.len() as i32);
  return s;
}
fn main() i32 { return structs() + heap() - 75 + vec_sum() - 44; }
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(
        p.gen_has("main.c", r#"_Static_assert(true, "deferred: asserts may precede their callee")"#),
        "assert above its callee folds",
    );
    assert(p.gen_has("main.c", r#"_Static_assert(true, "aggregates fold")"#), "structs/arrays/methods fold");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "the abstract heap folds")"#), "malloc/free fold");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "payload enums fold")"#), "Option + switch folds");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);

    // a would-be runtime trap in a required-const context reports its reason
    p.mkfile(
        "main.spc",
        r#"fn div0(n: i32) i32 { return 10 / n; }
static_assert(div0(0) == 1, "traps");
fn main() i32 { return 0; }
"#,
    );
    let d = p.compile("main.spc");
    assert(d.exit != 0, "a trapping assert fails the build");
    assert(d.out_has("division by zero"), "and names the trap");

    // use-after-free is caught by the abstract heap
    p.mkfile(
        "main.spc",
        r#"extern "C" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }
fn uaf() i32 {
  let p = unsafe malloc(sizeof(i32)) as *mut i32;
  unsafe p[0] = 1;
  unsafe free(p);
  return unsafe p[0];
}
static_assert(uaf() == 1, "uaf");
fn main() i32 { return 0; }
"#,
    );
    let u = p.compile("main.spc");
    assert(u.exit != 0, "use-after-free fails the build");
    assert(u.out_has("use after free"), "and names it");
}

// The last CTFE surface: `?` early return, array->slice coercion, range indexing into a Vector, struct-
// payload variants + struct patterns, &CONST, interface DEFAULT bodies, and Map/Set.
@test
fn ctfe_gaps() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"const K: i32 = 40;
fn check(k: i32) Result<i32, i32> {
  if k < 0 { return Result::<i32, i32>::Err(-1); }
  return Result::<i32, i32>::Ok(k + 1);
}
fn step1(k: i32) Result<i32, i32> {
  let v = check(k)?;
  return Result::<i32, i32>::Ok(v * 2);
}
fn g1(k: i32) i32 { return switch step1(k) { Ok(v) => v, Err(e) => e, }; }
static_assert(g1(20) == 42 && g1(-5) == -1, "try both paths");
fn g2() i32 {
  let a: [i32; 5] = [1, 2, 3, 4, 5];
  let s: []i32 = a;
  let mut x = Vector::<i32>::with_capacity(4);
  x.push(10); x.push(20); x.push(30);
  let w = x[1..3];
  let r = (s.len() as i32) + *s.get(4) + *w.get(0) + *w.get(1) + (w.len() as i32);
  return r;
}
static_assert(g2() == 62, "slices + range indexing");
enum Shape { Dot, Rect { w: i32, h: i32 }, }
fn g3(w: i32, h: i32) i32 {
  let s = Shape::Rect { w: w, h: h };
  let p = &K;
  return switch s { Dot => 0, Rect { w, h } => w * h + *p, };
}
static_assert(g3(6, 7) == 82, "struct patterns + &const");
interface Doubler {
  fn base(self: &Self) i32;
  fn twice(self: &Self) i32 { return self.base() * 2; }
}
struct G { pub v: i32 }
extend G as Doubler { pub fn base(self: &G) i32 { return self.v; } }
fn g4() i32 { let g = G { v: 21 }; return g.twice(); }
static_assert(g4() == 42, "interface default body");
fn g5() i32 {
  let mut m = Map::<i32, i32>::new();
  m.insert(1, 40);
  m.insert(2, 60);
  let v = switch m.get(&1) { Some(x) => *x, None => -1, };
  let mut s = Set::<i32>::new();
  s.insert(7);
  s.insert(7);
  let r = v + (m.len() as i32) + (s.len() as i32);
  return r;
}
static_assert(g5() == 43, "Map and Set fold");
fn main() i32 { return g1(20) - 42 + g2() - 62 + g3(6, 7) - 82 + g4() - 42 + g5() - 43; }
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", r#"_Static_assert(true, "try both paths")"#), "? folds both ways");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "slices + range indexing")"#), "slices fold");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "struct patterns + &const")"#), "struct patterns fold");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "interface default body")"#), "interface defaults fold");
    assert(p.gen_has("main.c", r#"_Static_assert(true, "Map and Set fold")"#), "Map/Set fold");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}

// RAII lowering of a reassignment to a binding whose move sits under control flow (a call argument
// inside a loop): the free-before-assign must be guarded by the binding's runtime move flag and the
// flag reset after -- an unguarded free double-frees the moved-out buffer (miscompile, not a
// borrow-check error: the source is legal).
@test
fn raii_cond_move_reassign() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn consume(s: String) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    let mut buf = String::from_str(\"seed\");\n    let mut total: usize = 0;\n    for _i in 0..3 {\n        total = total + consume(buf);\n        buf = String::from_str(\"abcd\");\n    }\n    return (total + buf.len()) as i32 - 16;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "if (!__mv"), "reassign free is flag-guarded");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}

// Drop-on-assign: `place = v` frees the place's old value for fields and indexes too, not just
// locals -- overwriting a live Free field neither leaks nor needs manual glue. The owner-swap idiom
// (`let a = s.f; s.f = fresh;`) still lowers to a bare store (the previous statement moved the
// place out), so no double-free.
@test
fn raii_drop_on_field_assign() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Holder {\n    pub name: String,\n}\n\nextend Holder as Free {\n    pub fn free(self: &mut Holder) {\n        self.name.free();\n    }\n}\n\nfn take_name(h: &mut Holder) String {\n    return replace(&mut h.name, String::new());\n}\n\nfn main() i32 {\n    let mut h = Holder { name: String::from_str(\"first\") };\n    let mut n: usize = 0;\n    for _i in 0..3 {\n        h.name = String::from_str(\"abcdefgh\");\n        n = n + h.name.len();\n    }\n    let taken = take_name(&mut h);\n    n = n + taken.len();\n    return n as i32 - 32;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "String__free"), "field overwrite frees the old value");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);

    // a field moved out ANYWHERE in the body (even conditionally) guards the assign-free for that
    // place -- the take goes through an `unsafe` ref-take (the safe form is rejected: E0507)
    p.mkfile(
        "cond.spc",
        "struct H {\n    pub name: String,\n}\n\nextend H as Free {\n    pub fn free(self: &mut H) {\n        self.name.free();\n    }\n}\n\nfn sink(s: String) usize {\n    return s.len();\n}\n\nfn shuffle(h: &mut H) usize {\n    let mut n: usize = 0;\n    if h.name.len() > 3 {\n        let a = unsafe h.name;\n        n = n + sink(a);\n    }\n    h.name = String::from_str(\"next\");\n    return n + h.name.len();\n}\n\nfn main() i32 {\n    let mut h = H { name: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\") };\n    let n = shuffle(&mut h);\n    return n as i32 - 36;\n}\n",
    );
    let c2 = p.compile("cond.spc");
    assert_eq(c2.exit, 0);
    assert(p.gen_has("cond.c", ") String__free"), "conditionally-moved field assign-free is flag-guarded");
    let cc2 = p.cc_build("");
    assert_eq(cc2.exit, 0);
    assert_eq(p.run_bin(), 0);

    // moving a field out of a value implementing Free is REJECTED (Rust's rule): the free body
    // cannot run on a partial value -- `replace` is the sanctioned way
    p.mkfile(
        "condfree.spc",
        "struct G {\n    pub name: String,\n}\n\nextend G as Free {\n    pub fn free(self: &mut G) {\n        self.name.free();\n    }\n}\n\nfn sink(s: String) usize {\n    return s.len();\n}\n\nfn main() i32 {\n    let g = G { name: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\") };\n    let mut n: usize = 0;\n    if g.name.len() > 3 {\n        let a = g.name;\n        n = n + sink(a);\n    }\n    return n as i32 - 32;\n}\n",
    );
    let c3 = p.compile("condfree.spc");
    assert(c3.exit != 0, "field move out of a Free-implementing value is rejected");
    assert(c3.out_has("cannot move a field out of a value implementing Free"));
}

// Transpiler-inserted auto-free of untouched fields: a Free impl's body runs, then every owning
// Free-typed field it never referenced is freed by generated glue (early returns covered by the
// wrapper form). Complete impls emit without a wrapper; raw-pointer fields are borrows and exempt.
@test
fn raii_free_glue_untouched_fields() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Pair {\n    pub a: String,\n    pub b: String,\n    pub n: i32,\n    pub peek: *const String,\n}\n\nextend Pair as Free {\n    pub fn free(self: &mut Pair) {\n        self.a.free();\n    }\n}\n\nstruct Whole {\n    pub s: String,\n}\n\nextend Whole as Free {\n    pub fn free(self: &mut Whole) {\n        self.s.free();\n    }\n}\n\nfn main() i32 {\n    let mut q = Pair {\n        a: String::from_str(\"abcdefghijklmnopqrstuvwxyz\"),\n        b: String::from_str(\"abcdefghijklmnopqrstuvwxyz012345\"),\n        n: 0,\n        peek: null,\n    };\n    q.n = q.a.len() as i32 + q.b.len() as i32;\n    let w = Whole { s: String::from_str(\"zz\") };\n    return q.n + w.s.len() as i32 - 60;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "Pair__free__fb("), "incomplete impl gets the wrapper");
    assert(p.gen_has("main.c", "String__free(&self->b);"), "untouched field is glue-freed");
    assert(!p.gen_has("main.c", "Whole__free__fb"), "complete impl emits no wrapper");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}

// Local consts of owning types are runtime values freed at scope exit (a plain local, not a
// `static const`); a global one is still rejected, and moving one out is rejected. A local VALUE
// const with a `const fn` initializer folds to static data instead of emitting a bare call.
@test
fn local_const_lifecycle() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct P {\n    pub x: i32,\n    pub y: i32,\n}\n\nconst fn mk() P {\n    return P { x: 3, y: 4 };\n}\n\nfn build() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(5u32);\n    v.push(9u32);\n    return v;\n}\n\nfn main() i32 {\n    const A: P = mk();\n    const L: Vector<u32> = build();\n    return A.x + A.y + L.len() as i32 + *L.at(0) as i32 - 14;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "Vector__u32 L = build();"), "owning local const is a runtime local");
    assert(p.gen_has("main.c", "Vector__u32__free(&L);"), "owning local const is freed at scope exit");
    assert(p.gen_has("main.c", "static const P A = { .x = 3, .y = 4 };"), "value const folds to static data");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(lk.exit, 0); // runs, and the owning const is freed (no leak under the fatal gate)

    // a global owning const is rejected
    p.mkfile(
        "g.spc",
        "fn mk() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(1u32);\n    return v;\n}\n\nconst V: Vector<u32> = mk();\n\nfn main() i32 {\n    return 0;\n}\n",
    );
    p.expect_fail("g.spc", "a constant cannot hold an owning (Free) type");
    // moving an owning const out is rejected
    p.mkfile(
        "m.spc",
        "fn eat(v: Vector<u32>) usize {\n    return v.len();\n}\n\nfn build() Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(1u32);\n    return v;\n}\n\nfn main() i32 {\n    const L: Vector<u32> = build();\n    return (eat(L) - 1) as i32;\n}\n",
    );
    p.expect_fail("m.spc", "cannot move a value out of a 'const' binding");
}

// A boxed `dyn fn` (an owning capturing closure moved to the heap) is allocated and freed through
// the default Global allocator by generated glue. A module that uses no container still needs
// `interfaces.h` for those Global references -- exercised here by a `Box<dyn fn>` returned, called,
// and freed, with nothing else pulling the allocator in.
@test
fn dyn_fn_box_roundtrip() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn make_adder(k: i32) Box<dyn fn(i32) i32> {\n    return |x: i32| x + k;\n}\n\nfn main() i32 {\n    let f = make_adder(10);\n    return f(5) - 15;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "#include \"__std/interfaces.h\""), "owned dyn pulls in the Global allocator header");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(lk.exit, 0); // the boxed closure env is freed -- no leak under the fatal gate
}

// The self-hosted leak tracker: super_rt.h interposes the emitted code's malloc/realloc/free call
// sites over super_rt.c's registry, gated at runtime by SC_LEAK_CHECK. A survivor (here a raw
// extern-malloc'd block nothing frees) is reported at exit with its byte count; leak-free runs and
// disabled runs print nothing.
@test
fn leak_tracker() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "fn main() i32 {\n    forget(String::from_str(\"deliberately abandoned, past the inline budget\"));\n    return 0;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_exists("super_rt.c"), "tracker runtime is written");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let lk = p.run_bin_env("SC_LEAK_CHECK=1 ");
    assert_eq(lk.exit, 0);
    assert(lk.out_has("super-c leaks: 1 allocation"), "survivor reported at exit");
    let off = p.run_bin_env("SC_LEAK_CHECK=0 "); // =0 disables even when the suite itself runs traced
    assert_eq(off.exit, 0);
    assert(!off.out_has("super-c leaks"), "inert when disabled");

    let q = cli::proj_new();
    q.mkfile(
        "main.spc",
        "fn main() i32 {\n    let mut v = Vector::<String>::new();\n    v.push(String::from_str(\"owned and freed\"));\n    v.push(String::from_str(\"also freed\"));\n    return (v.len() - 2) as i32;\n}\n",
    );
    let r2 = q.compile("main.spc");
    assert_eq(r2.exit, 0);
    let cc2 = q.cc_build("");
    assert_eq(cc2.exit, 0);
    let ok = q.run_bin_env("SC_LEAK_CHECK=1 ");
    assert_eq(ok.exit, 0);
    assert(!ok.out_has("super-c leaks"), "leak-free run reports nothing");

    // fatal mode: survivors turn the exit code nonzero (23), so CI can gate on leak-freedom
    let ft = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(ft.exit, 23);
    assert(ft.out_has("super-c leaks: 1 allocation"), "fatal mode still prints the report");
    let ftc = q.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(ftc.exit, 0);

    // double frees are detected via the freed-entry history: both stacks reported, exit 0 in
    // report mode, abort in fatal mode
    let d = cli::proj_new();
    d.mkfile(
        "main.spc",
        "extern \"C\" {\n    fn malloc(n: usize) *mut void;\n    fn free(pt: *mut void) void;\n}\n\nfn main(args: Vector<str>) i32 {\n    let pt = unsafe malloc(64 + args.len());\n    unsafe free(pt);\n    unsafe free(pt);\n    return 0;\n}\n",
    );
    let rd = d.compile("main.spc");
    assert_eq(rd.exit, 0);
    let ccd = d.cc_build("");
    assert_eq(ccd.exit, 0);
    let dbl = d.run_bin_env("SC_LEAK_CHECK=1 ");
    assert_eq(dbl.exit, 0);
    assert(dbl.out_has("super-c double free:"), "double free detected");
    assert(dbl.out_has("freed again at:"), "both sites reported");
    let dblf = d.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert(dblf.exit != 0, "fatal mode aborts on double free");
}

// Auto-derived Free: structs and enums whose members own memory get a SYNTHESIZED per-TU free
// (`<T>__free__d`) -- fields, nested aggregates, enum payloads and container elements all free
// without an impl being written; partial moves out of derived values are rejected exactly like
// explicit Free types (replace() is the take idiom).
@test
fn auto_derive_free() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct Plain {\n    pub s: String,\n    pub n: i32,\n}\n\nstruct Nested {\n    pub p: Plain,\n    pub tag: String,\n}\n\nenum Ev {\n    None,\n    Named(String),\n}\n\nfn main() i32 {\n    let a = Plain { s: String::from_str(\"plain owning field, long past the sso budget\"), n: 1 };\n    let b = Nested {\n        p: Plain { s: String::from_str(\"nested owning field, long past the sso\"), n: 2 },\n        tag: String::from_str(\"nested tag string, also long past the sso\"),\n    };\n    let e = Ev::Named(String::from_str(\"enum payload string, long past the sso\"));\n    let mut v = Vector::<Plain>::new();\n    v.push(Plain { s: String::from_str(\"vector element string, long past sso\"), n: 3 });\n    let k = a.n + b.p.n + v.len() as i32;\n    let ok = switch e {\n        Named(sx) => sx.len() > 0,\n        _ => false,\n    };\n    return k + (ok as i32) - 5;\n}\n",
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("main.c", "static void Plain__free__d(Plain *const self)"), "struct free synthesized");
    assert(p.gen_has("main.c", "Plain__free__d(&self->p);"), "nested derive composes");
    assert(
        p.gen_has("main.c", "if (self->tag == Ev_Named) String__free(&self->payload.Named._0);"),
        "enum payload freed per variant",
    );
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let lk = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(lk.exit, 0);
    assert(!lk.out_has("super-c leaks"), "derived aggregates are leak-free");

    // partial moves out of a derived value are rejected (same rule as explicit Free impls)
    p.mkfile(
        "take.spc",
        "struct Plain {\n    pub s: String,\n}\n\nfn main() i32 {\n    let a = Plain { s: String::from_str(\"x\") };\n    let t = a.s;\n    return (t.len() - t.len()) as i32;\n}\n",
    );
    let r2 = p.compile("take.spc");
    assert(r2.exit != 0, "partial move out of a derived value is rejected");
    assert(r2.out_has("cannot move a field out of a value implementing Free"));
}

// Cross-module language features: a public const, a public type alias used as a type, qualified struct
// construction, and a local extension method on an imported type.
@test
fn module_features() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        r#"pub struct Vec2 { pub x: i32, pub y: i32 }
pub type V = Vec2;
pub const BASE: i32 = 100;
pub fn mk(a: i32, b: i32) Vec2 { return Vec2 { x: a, y: b }; }
"#,
    );
    p.mkfile(
        "feat.spc",
        r#"import lib::lib;
extern "C" { fn exit(code: i32) void; }
extend lib::lib::Vec2 { fn sum(self: &lib::lib::Vec2) i32 { return self.x + self.y; } }
fn main() i32 {
  let v: lib::lib::V = lib::lib::Vec2 { x: 5, y: 7 };
  let w = lib::lib::mk(1, 2);
  unsafe exit(v.sum() + w.sum() + lib::lib::BASE); }
"#,
    );
    let r = p.compile("feat.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 115);
}

// A public `static mut` global: extern-declared in its header, defined once, readable/assignable across
// modules (both through the owning module's functions and directly by path).
@test
fn cross_module_static_mut() {
    let p = cli::proj_new();
    p.mkfile("state.spc", r#"pub static mut hits: i64 = 0;
pub fn record() { hits += 1; }
"#);
    p.mkfile(
        "main.spc",
        r#"import state;
fn main() i32 {
  state::record();
  state::record();
  state::hits += 3;
  return (state::hits - 5) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}

// The --test pipeline end to end: @test collection across modules, per-module and global fixtures, method
// suites (fixture-as-self), should_panic, fork isolation of a failing assertion, --test-filter, --test-no-fork.
@test
fn test_pipeline() {
    let p = cli::proj_new();
    p.mkfile(
        "env.spc",
        r#"pub struct Env { pub tag: String }
extend Env as Free {
  pub fn free(self: &mut Env) { self.tag.free(); }
}
@test_init(global)
fn suite() Env { return Env { tag: String::from_str("suite") }; }
@test_free(global)
fn suite_down(env: &mut Env) { eprintln("teardown {}", env.tag.as_str()); }
"#,
    );
    p.mkfile(
        "main.spc",
        r#"import env;
struct Fx { pub v: Vector<i32> }
extend Fx as Free {
  pub fn free(self: &mut Fx) { self.v.free(); }
}
@test_init
fn setup() Fx { let mut v = Vector::<i32>::new(); v.push(1); v.push(2); return Fx { v: v }; }
@test
fn drains(fx: &mut Fx, e: &env::Env) {
  let mut s = 0;
  while let Some(x) = fx.v.pop() { s += x; }
  assert_eq(s, 3);
  assert_eq(e.tag.len(), 5);
}
@test
fn fails() { assert_eq(2 * 3, 7); }
@test(should_panic)
fn boom() { panic("boom"); }
struct Counter { pub n: i32 }
extend Counter {
  @test_init
  fn setup() Counter { return Counter { n: 0 }; }
  @test_free
  fn teardown(self: &mut Counter) { assert(self.n >= 0, "non-negative"); }
  pub fn bump(self: &mut Counter) { self.n += 1; }
  @test
  fn bumps(self: &mut Counter, e: &env::Env) {
    self.bump();
    assert_eq(self.n * e.tag.len() as i32, 5);
  }
}
fn main() i32 { return 0; }
"#,
    );
    let r = p.compile_flags("--test", "main.spc");
    assert_eq(r.exit, 1);
    assert(r.out_has("running 4 tests"), "collected 4 tests");
    assert(r.out_has("test main::drains ... ok"), "drains passed");
    assert(r.out_has("test main::Counter::bumps ... ok"), "method suite: fixture-as-self + global env");
    assert(r.out_has("test main::boom ... ok (panicked as expected)"), "should_panic recognized");
    assert(r.out_has("test main::fails ... FAILED"), "failing test reported");
    assert(r.out_has("assertion failed: `2 * 3 == 7`"), "assert message carries the expression");
    assert(r.out_has("left:  6"), "assert shows left value");
    assert(r.out_has("right: 7"), "assert shows right value");
    assert(r.out_has("teardown suite"), "global @test_free ran");
    assert(r.out_has("3 passed, 1 failed"), "final tally");
    // --test-filter narrows selection; a fully passing selection exits 0
    let f = p.compile_flags("--test --test-filter=drains --test-jobs=2", "main.spc");
    assert_eq(f.exit, 0);
    assert(f.out_has("running 1 test"), "filter selected one");
    assert(f.out_has("1 passed, 0 failed"), "filtered run passes");
    // --test-no-fork runs in-process and skips should_panic tests
    let nf = p.compile_flags("--test --test-no-fork --test-filter=boom", "main.spc");
    assert_eq(nf.exit, 0);
    assert(nf.out_has("skipped (should_panic needs fork)"), "no-fork skips should_panic");
    // a normal (non---test) build still compiles and runs its own main (tests not emitted)
    let nb = p.compile("main.spc");
    assert_eq(nb.exit, 0);
    let cc = p.cc_build_plain("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}

// A generic defined in one module, instantiated over a user struct held BY VALUE in another: the instance is
// re-homed to the user module and full-monomorphized there. -Werror is the placement proof.
@test
fn cross_module_generic_by_value() {
    let p = cli::proj_new();
    p.mkfile(
        "opt/opt.spc",
        r#"pub enum Opt<T> { Some(T), None }
extend<T> Opt<T> {
  pub fn unwrap_or(self: &Opt<T>, d: T) T { return switch self { Some(v) => *v, None => d, }; }
  pub fn map<U>(self: &Opt<T>, f: fn(T) U) Opt<U> {
    return switch self { Some(v) => Opt::<U>::Some(f(*v)), None => Opt::<U>::None, }; }
}
"#,
    );
    p.mkfile(
        "genbv.spc",
        r#"import opt::opt;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
fn bx(b: Bar) i32 { return b.x; }
fn main() i32 {
  let o = opt::opt::Opt::<Bar>::Some(Bar { x: 30 });
  let a = o.unwrap_or(Bar { x: 0 }).x;
  let m = o.map(bx).unwrap_or(0);
  unsafe exit(a + m); }
"#,
    );
    let r = p.compile("genbv.spc");
    assert_eq(r.exit, 0);
    assert(
        p.gen_has("genbv.h", "struct opt__Opt__genbv__Bar {"),
        "instance full-monomorphized in the user module's header",
    );
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 60);
}

// A cross-module generic instance whose bounded extend calls a BOUND METHOD on the element; the bound call
// dispatches through the subst (T -> Bar) to the concrete Bar__clone.
@test
fn cross_module_generic_bound_dispatch() {
    let p = cli::proj_new();
    p.mkfile(
        "bx/bx.spc",
        r#"pub interface Clone { fn clone(self: &Self) Self; }
pub struct Bx<T> { pub v: T }
extend<T: Clone> Bx<T> {
  pub fn dup(self: &Bx<T>) Bx<T> { return Bx::<T> { v: self.v.clone() }; }
}
"#,
    );
    p.mkfile(
        "genbd.spc",
        r#"import bx::bx;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
extend Bar as bx::bx::Clone { fn clone(self: &Self) Bar { return Bar { x: self.x }; } }
fn main() i32 {
  let b = bx::bx::Bx::<Bar> { v: Bar { x: 21 } };
  let d = b.dup();
  unsafe exit(d.v.x + b.v.x); }
"#,
    );
    let r = p.compile("genbd.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);
}

// @emit_macro on a generic type emits reusable C DECLARE/DEFINE templates into its header; Super-C's own
// instances stay full-monomorphized; a plain-C consumer can instantiate the template; rejected on non-generics.
@test
fn emit_macro_export() {
    let p = cli::proj_new();
    p.mkfile(
        "emac.spc",
        r#"extern "C" { fn exit(code: i32) void; }
@emit_macro
pub struct Pair<T> { pub a: T, pub b: T }
extend<T> Pair<T> { pub fn pick(self: &Pair<T>, second: bool) T { if second { return self.b; } return self.a; } }
fn main() i32 { let p = Pair::<i32> { a: 3, b: 4 }; unsafe exit(p.pick(true) + p.a); }
"#,
    );
    let r = p.compile("emac.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("emac.h", "PAIR_DECLARE("), "@emit_macro emits DECLARE template");
    assert(p.gen_has("emac.h", "PAIR_DEFINE("), "@emit_macro emits DEFINE template");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 7);

    // a plain-C consumer instantiates the template over its own C type (no Super-C compiler involved)
    p.mkfile(
        "cuser.c",
        r#"#include "emac.h"
typedef struct { int n; } CT;
PAIR_DECLARE(CT, CT, Pair__CT)
PAIR_DEFINE(CT, CT, Pair__CT)
int main(void) { Pair__CT p = { .a = { 5 }, .b = { 9 } };
  return Pair__CT__pick(&p, 1).n == 9 ? 0 : 1; }
"#,
    );
    let mut cc2 = Cmd {};
    unsafe stdio::snprintf(
        &mut cc2.b[0],
        2048,
        "cc -std=c11 -Wall -Wextra -Werror -I'%s/build/raw' '%s/cuser.c' -o '%s/cbin' 2>/dev/null".ptr() as *const char,
        p.rootp(),
        p.rootp(),
        p.rootp(),
    );
    assert_eq(cli::run_shell(&cc2.b[0]), 0);
    let mut cr = Cmd {};
    unsafe stdio::snprintf(&mut cr.b[0], 2048, "'%s/cbin'".ptr() as *const char, p.rootp());
    assert_eq(cli::run_shell(&cr.b[0]), 0);

    // the attribute is rejected on a non-generic type
    p.mkfile("bad.spc", "@emit_macro\npub struct Plain { pub a: i32 }\nfn main() i32 { return 0; }\n");
    let bad = p.compile("bad.spc");
    assert(bad.exit != 0, "@emit_macro on a non-generic is rejected");
    assert(bad.out_has("generic struct or enum"), "the rejection names the constraint");
}

// Per-extend bound filtering: a bounded extension block instantiated over a type that does NOT satisfy the
// bound must not be specialized (its body would call an unprovided method); only the unbounded block emits.
@test
fn per_extend_bound_filtering() {
    let p = cli::proj_new();
    p.mkfile(
        "pibf.spc",
        r#"extern "C" { fn exit(code: i32) void; }
pub interface Marker { fn mark(self: &Self) i32; }
pub struct Wrap<T> { pub v: T }
extend<T> Wrap<T> { pub fn raw(self: &Wrap<T>) i32 { return 7; } }
extend<T: Marker> Wrap<T> { pub fn marked(self: &Wrap<T>) i32 { return self.v.mark(); } }
struct Plain { pub n: i32 }
fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 5 } }; unsafe exit(w.raw()); }
"#,
    );
    let r = p.compile("pibf.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 7);
}

// A non-Default allocator must still get all String<A> methods/conformances that only need an explicit or
// stored allocator (a multi-file regression: warning-clean without a sentinel `RawAlloc: Default`).
@test
fn string_non_default_allocator() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"extern "C" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; fn exit(code: i32) void; }
struct RawAlloc {}
extend RawAlloc as Allocator {
  fn alloc(self: &mut RawAlloc, n: usize, align: usize) *mut void { return unsafe malloc(n); }
  fn realloc(self: &mut RawAlloc, p: *mut void, old_n: usize, n: usize, align: usize) *mut void { return unsafe realloc(p, n); }
  fn dealloc(self: &mut RawAlloc, p: *mut void, n: usize, align: usize) { unsafe free(p); }
}
fn main() i32 {
  let a = RawAlloc {};
  let mut s = String::<RawAlloc>::from_str_in(a, "abcdefghijklmnopqrstuvwxyz");
  s.push_str("0123456789");
  let mut c = s.clone();
  let mut f = s.fmt();
  let ok = s.eq_str("abcdefghijklmnopqrstuvwxyz0123456789") && s.cmp(&c) == 0 && s.hash() == c.hash() && f.len() == s.len();
  if ok { return 42; }
  return 1;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);
}

// Eager emission must stay warning-clean under -Wunused-function: generic methods, inherited defaults and
// private functions may be omitted or explicitly marked unused.
@test
fn warning_clean_unused_emission() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"extern "C" { fn exit(code: i32) void; }
fn unused_private() i32 { return 99; }
interface I { fn value(self: &Self) i32; fn unused_default(self: &Self) i32 { return 123; } }
struct S { pub x: i32 }
extend S as I { fn value(self: &Self) i32 { return self.x; } }
struct Wrap<T> { pub v: T }
extend<T> Wrap<T> {
  fn get(self: &Self) T { return self.v; }
  fn unused_method(self: &Self) T { return self.v; }
}
fn main() i32 { let s = S { x: 20 }; let w = Wrap::<i32> { v: 22 }; unsafe exit(s.value() + w.get()); }
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);
}

// OS threads (std/parallel): an owning closure (a moved-in String) returns its value through the
// JoinHandle, and four threads share one Atomic<i64> through an Arc -- the Send-safe way -- and race on
// fetch_add, so the total is exact. Leak-checked, so the String, the Arc block and every payload/slot are
// accounted for.
@test
fn threads_and_atomics() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::thread as thread;
import std::parallel::atomics as atom;
import std::parallel::arc as arc;

fn main() i32 {
    let msg = String::from_str("payload");
    let owned = thread::spawn(fn() usize { return msg.len(); });

    let counter = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let mut handles = Vector::<thread::JoinHandle<i32>>::new();
    for _t in 0..4 {
        let c = counter.clone();
        handles.push(thread::spawn(fn() i32 {
            for _i in 0..1000 {
                let _ = c.get().fetch_add(1, atom::MemoryOrder::Relaxed);
            }
            return 0;
        }));
    }
    while handles.len() > 0 {
        let _ = handles.pop().unwrap().join();
    }
    handles.free();

    let n = owned.join();
    let total = counter.get().load(atom::MemoryOrder::SeqCst);
    counter.free();
    return (n as i32 - 7) + (total - 4000) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// spawn requires F: Send, and a raw pointer is not Send (nor is a closure that captures one), so sending a
// stack borrow to another thread is rejected at compile time -- the single-threaded escape hatch is closed.
@test
fn thread_send_rejects_raw_pointer() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::thread as thread;
fn main() i32 {
    let mut x: i32 = 5;
    let ptr = &mut x as *mut i32;
    let h = thread::spawn(fn() i32 { return unsafe { ptr[0]; }; });
    return h.join();
}
"#,
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "capturing a raw pointer into a spawned thread is rejected");
    assert(r.out_has("Send"), "the rejection cites the Send bound");
}

// The concurrency platform substrate (ffi/sc_rt.c via std/parallel): CPU count and monotonic clock, a
// guard-paged stack driving a stackful ucontext/fiber context switch (the coroutine runs, writes a marker,
// and switches back), and cross-thread address parking (a spawned thread publishes a word and unparks the
// main thread, which was parked on it). Leak-checked.
@test
fn platform_substrate() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import sc_runtime;
import std::parallel::platform as platform;
import std::parallel::thread as thread;
import atomic;
import std::parallel::atomics as atom;

struct CoState {
    pub root: *mut void,
    pub me: *mut void,
    pub hit: i32,
}

fn co_entry(arg: *mut void) {
    let s = arg as *mut CoState;
    unsafe (*s).hit = 42;
    unsafe sc_runtime::sc_rt_ctx_switch((*s).me, (*s).root);
}

fn main() i32 {
    let n = platform::ncpu();
    let a = platform::now_ns();
    let b = platform::now_ns();
    if n < 1 || b < a {
        return 1;
    }
    let root = unsafe sc_runtime::sc_rt_ctx_alloc();
    let co = unsafe sc_runtime::sc_rt_ctx_alloc();
    let sz: usize = 65536;
    let stk = unsafe sc_runtime::sc_rt_stack_alloc(sz);
    let mut st = CoState { root: root, me: co, hit: 0 };
    unsafe sc_runtime::sc_rt_ctx_init(co, stk, sz, co_entry, &mut st as *mut void);
    unsafe sc_runtime::sc_rt_ctx_switch(root, co);
    unsafe sc_runtime::sc_rt_stack_free(stk, sz);
    unsafe sc_runtime::sc_rt_ctx_free(co);
    unsafe sc_runtime::sc_rt_ctx_free(root);
    if st.hit != 42 {
        return 2;
    }
    let mut g = Global {};
    let wp = g.alloc(4, 4) as *mut i32;
    unsafe wp[0] = 0;
    let waddr = wp as usize;
    let h = thread::spawn(fn() i32 {
        let w = waddr as *mut i32;
        for _i in 0..200000 {}
        unsafe atomic::store_i32(w, 1, atom::MemoryOrder::SeqCst as i32);
        unsafe sc_runtime::sc_rt_unpark_all(w);
        return 0;
    });
    let mut spins = 0;
    while unsafe atomic::load_i32(wp, atom::MemoryOrder::Acquire as i32) == 0 {
        unsafe sc_runtime::sc_rt_park(wp, 0, 1000000);
        spins = spins + 1;
        if spins > 100000 {
            break;
        }
    }
    let _ = h.join();
    let fin = unsafe wp[0];
    g.dealloc(wp, 4, 4);
    if fin != 1 {
        return 3;
    }
    return 0;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// @platform gates @c.source/@c.link: a windows-only extern block (backing header + link flag) must not
// contribute its wrapper TU or -l flag on a non-windows build -- else every target links every OS's runtime
// C. Regression guard for the extc gating fix (M2 prerequisite).
@test
fn platform_gates_ext_c() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"@platform(windows)
@c.link("scrt_win_only_lib")
extern "C" "scrt_no_such_header.h" {
    pub fn scrt_win_only() i32;
}

@c.link("m")
extern "C" {
    fn scrt_needs_m() f64;
}

fn main() i32 {
    return 0;
}
"#,
    );
    // Builds on the host even though the windows block names a header that does not exist: it is gated out.
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    // The always-on link is present; the windows-only one is not.
    assert(p.gen_has("__ldflags", "-lm"), "ungated @c.link lands in __ldflags");
    assert(!p.gen_has("__ldflags", "scrt_win_only_lib"), "windows @c.link is filtered out on the host");
}

// The task runtime (std/parallel/runtime): a lazily-started worker pool runs detached tasks submitted with
// `launch`. One hundred owning closures each move in a clone of a shared Arc<Atomic> and a WaitGroup, run on
// the pool, increment the counter and signal done; the main thread awaits them, reads the exact total, then
// shuts the pool down (draining, joining, freeing). Leak-checked end to end.
@test
fn launch_runtime() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    let counter = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(100);
    for _i in 0..100 {
        let c = counter.clone();
        let w = wg.clone();
        launch fn() {
            let _ = c.get().fetch_add(1, atom::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    let total = counter.get().load(atom::MemoryOrder::SeqCst);
    wg.free();
    counter.free();
    rt::shutdown();
    return (total - 100) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// A bounded MPMC channel (std/parallel/channel): four producer tasks each push 25 items into a bounded(8)
// channel -- forcing the ring buffer to block and drain -- while the main thread receives until the channel
// closes (every producer's Sender dropped). The receiver is taken before launching, so no early send is
// rejected; the exact item count and sum verify nothing is lost or duplicated. Leak-checked, so the slot
// array, every buffered payload, and all Arc handles are accounted for. Also exercises the cross-module
// generic-method monomorphization fix (`Condvar::wait<ChannelState<i64>>`).
@test
fn channel_mpmc() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::channel as chan;

fn main() i32 {
    let ch = chan::Channel::<i64>::bounded(8);
    let rx = ch.receiver();
    for _p in 0..4 {
        let s = ch.sender();
        launch fn() {
            for i in 0..25 {
                let _ = s.send(i);
            }
        };
    }
    ch.free();
    let mut total: i64 = 0;
    let mut n = 0;
    loop {
        switch rx.recv() {
            Some(v) => {
                total = total + v;
                n = n + 1;
            },
            None => {
                break;
            },
        };
    }
    rx.free();
    rt::shutdown();
    return (n - 100) + (total - 1200) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// Task-aware parking: 50 coroutines (30 producers + 20 consumers) share a bounded(2) channel -- MORE
// coroutines than worker threads. When a coroutine blocks on send/recv it PARKS (via the dual-mode
// `Condvar`), freeing its worker to run others; under the old block-the-OS-thread model this would deadlock
// (every worker stuck inside a blocked coroutine, none left to make progress). All 300 items are delivered
// exactly once. Every handle is created before any coroutine launches, so no send is rejected for want of a
// receiver. Leak-checked.
@test
fn channel_parking_oversubscribed() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    let ch = chan::Channel::<i64>::bounded(2);
    let cnt = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(50);
    let mut senders = Vector::<chan::Sender<i64>>::new();
    for _p in 0..30 {
        senders.push(ch.sender());
    }
    let mut recvs = Vector::<chan::Receiver<i64>>::new();
    for _c in 0..20 {
        recvs.push(ch.receiver());
    }
    while senders.len() > 0 {
        let s = senders.pop().unwrap();
        let w = wg.clone();
        launch fn() {
            for _i in 0..10 {
                let _ = s.send(7);
            }
            w.done();
        };
    }
    while recvs.len() > 0 {
        let r = recvs.pop().unwrap();
        let ct = cnt.clone();
        let w = wg.clone();
        launch fn() {
            loop {
                switch r.recv() {
                    Some(_) => {
                        let _ = ct.get().fetch_add(1, atom::MemoryOrder::Relaxed);
                    },
                    None => {
                        break;
                    },
                };
            }
            w.done();
        };
    }
    senders.free();
    recvs.free();
    ch.free();
    wg.wait();
    let n = cnt.get().load(atom::MemoryOrder::SeqCst);
    wg.free();
    cnt.free();
    rt::shutdown();
    return (n - 300) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// `sleep` and the scheduler's timer list: a sleeping coroutine parks on its deadline instead of holding its
// worker. Proven structurally, not by timing -- with exactly ONE worker, a task that sleeps 50ms and a task
// that sleeps not at all race to claim an atomic; only a parking sleep lets the second one win. The elapsed
// time then confirms the sleep really slept, and the plain-thread path (no coroutine) sleeps outright.
@test
fn coroutine_sleep_and_timers() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::time as time;
import std::parallel::platform as platform;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    rt::set_worker_count(1); // one worker: a blocking sleep would serialize the two tasks below

    let t0 = platform::now_ns();
    time::sleep(time::Duration::from_millis(5)); // off a coroutine: sleeps the thread
    if platform::now_ns() - t0 < 4000000 {
        return 1;
    }

    let order = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let oa = order.clone();
    let wa = wg.clone();
    launch fn() {
        time::sleep(time::Duration::from_millis(50));
        let _ = oa.get().compare_exchange(0, 1, atom::MemoryOrder::SeqCst, atom::MemoryOrder::Relaxed);
        wa.done();
    };
    let ob = order.clone();
    let wb = wg.clone();
    launch fn() {
        let _ = ob.get().compare_exchange(0, 2, atom::MemoryOrder::SeqCst, atom::MemoryOrder::Relaxed);
        wb.done();
    };
    let t1 = platform::now_ns();
    wg.wait();
    let waited = platform::now_ns() - t1;
    let first = order.get().load(atom::MemoryOrder::SeqCst);
    wg.free();
    order.free();
    rt::shutdown();
    if first != 2 {
        return 2; // the sleeper kept the only worker: sleep did not park
    }
    if waited < 40000000 {
        return 3; // the sleep did not actually wait
    }
    return 0;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// Task-aware `Mutex` / `RwLock` acquisition. On ONE worker: task A takes the mutex and then blocks on a
// semaphore (parking while HOLDING the lock), task B tries to take that mutex (it must park, not sit on the
// worker), and task C sleeps, releases the semaphore and lets both finish. Under an OS-blocking acquire, B
// would occupy the only worker and C could never run -- the run deadlocks instead of returning. Also covers
// read/write guards taken from coroutines and a timed acquire that expires and then succeeds. Leak-checked.
@test
fn task_aware_locks() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::time as time;
import std::parallel::arc as arc;
import std::parallel::atomics as atom;

fn main() i32 {
    rt::set_worker_count(1);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let rw = arc::Arc::<sync::RwLock<i64>>::new(sync::RwLock::<i64>::new(0));
    let sem = sync::Semaphore::new(0);
    let wg = sync::WaitGroup::new();
    wg.add(3);

    let ma = m.clone();
    let sa = sem.clone();
    let wa = wg.clone();
    launch fn() {
        let mut g = ma.get().lock();
        sa.acquire(); // parks while holding the lock
        let v = g.get_mut();
        *v = *v + 1;
        wa.done();
    };
    let mb = m.clone();
    let rb = rw.clone();
    let wb = wg.clone();
    launch fn() {
        let mut g = mb.get().lock(); // contended: must park
        let v = g.get_mut();
        *v = *v + 10;
        let mut w = rb.get().write();
        let n = w.get_mut();
        *n = *n + 5;
        wb.done();
    };
    let sc = sem.clone();
    let rc = rw.clone();
    let wc = wg.clone();
    launch fn() {
        {
            let g = rc.get().read();
            let _ = *g.get();
        }
        time::sleep(time::Duration::from_millis(10));
        sc.release();
        wc.done();
    };
    wg.wait();

    let lg = m.get().lock();
    let total = *lg.get();
    lg.free();
    let rg = rw.get().read();
    let written = *rg.get();
    rg.free();

    // A timed acquire on an exhausted semaphore expires; once a permit is back it succeeds.
    let flags = arc::Arc::<atom::Atomic<i64>>::new(atom::Atomic::<i64>::new(0));
    let wg2 = sync::WaitGroup::new();
    wg2.add(1);
    let s2 = sem.clone();
    let fl = flags.clone();
    let w2 = wg2.clone();
    launch fn() {
        if !s2.acquire_timeout(time::Duration::from_millis(10)) {
            let _ = fl.get().fetch_add(1, atom::MemoryOrder::Relaxed);
        }
        s2.release();
        if s2.acquire_timeout(time::Duration::from_millis(2000)) {
            let _ = fl.get().fetch_add(10, atom::MemoryOrder::Relaxed);
        }
        w2.done();
    };
    wg2.wait();
    let f = flags.get().load(atom::MemoryOrder::SeqCst);

    wg2.free();
    flags.free();
    wg.free();
    sem.free();
    rw.free();
    m.free();
    rt::shutdown();
    if total != 11 {
        return 1;
    }
    if written != 5 {
        return 2;
    }
    if f != 11 {
        return 3;
    }
    return 0;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// Unbounded channels and channel timeouts: 100 sends with nobody draining must all be accepted (the ring
// grows, no sender ever waits), a timed `recv` on an empty channel expires after its deadline and then takes
// a value that arrives, and a timed `send` into a full bounded(1) channel hands the value back instead of
// waiting forever. Leak-checked, so the grown slot array and every payload are accounted for.
@test
fn channel_unbounded_and_timeouts() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::channel as chan;
import std::parallel::time as time;
import std::parallel::platform as platform;

fn main() i32 {
    let ch = chan::Channel::<i64>::unbounded();
    let rx = ch.receiver();
    let tx = ch.sender();
    ch.free();
    let mut sum: i64 = 0;
    for i in 0..100 {
        switch tx.send(i) {
            Sent => {},
            Rejected(_) => {
                return 1;
            },
        };
    }
    for _i in 0..100 {
        switch rx.recv() {
            Some(v) => {
                sum = sum + v;
            },
            None => {
                return 2;
            },
        };
    }

    let t0 = platform::now_ns();
    switch rx.recv_timeout(time::Duration::from_millis(10)) {
        Some(_) => {
            return 3;
        },
        None => {},
    };
    if platform::now_ns() - t0 < 9000000 {
        return 4;
    }
    let _ = tx.send(41);
    switch rx.recv_timeout(time::Duration::from_millis(2000)) {
        Some(v) => {
            sum = sum + v;
        },
        None => {
            return 5;
        },
    };

    let b = chan::Channel::<i64>::bounded(1);
    let brx = b.receiver();
    let btx = b.sender();
    b.free();
    let _ = btx.send(1);
    switch btx.send_timeout(2, time::Duration::from_millis(10)) {
        Sent => {
            return 6;
        },
        Rejected(v) => {
            sum = sum + v;
        },
    };
    btx.free();
    brx.free();
    tx.free();
    rx.free();
    rt::shutdown();
    return (sum - 4993) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// Every timed wait racing its own deadline, on purpose: with one-nanosecond timeouts the timer fires while
// the parking worker is still handing the coroutine off, so a wakeup must be claimed by exactly ONE waker
// (notify or deadline) and the hand-off must not read fields the resumed coroutine has already reused. Both
// were real bugs -- a stale wait node resuming a later park, and a double release through a cleared commit
// argument (`pthread_mutex_unlock(NULL)`). 40 tasks x 25 rounds over a semaphore, a bounded channel, sleeps,
// yields and a shared mutex; the exact counter proves no wakeup was lost or double-spent. Leak-checked.
@test
fn timed_wait_deadline_races() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::time as time;
import std::parallel::arc as arc;

fn main() i32 {
    let sem = sync::Semaphore::new(0);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    let ch = chan::Channel::<i64>::bounded(1);
    let rxs = ch.receiver();
    let txs = ch.sender();
    wg.add(40);
    for _i in 0..40 {
        let s = sem.clone();
        let w = wg.clone();
        let mm = m.clone();
        let tx = txs.clone();
        let rx = rxs.clone();
        launch fn() {
            for _k in 0..25 {
                let _ = s.acquire_timeout(time::Duration::from_nanos(1));
                let _ = rx.recv_timeout(time::Duration::from_nanos(1));
                let _ = tx.send_timeout(1, time::Duration::from_nanos(1));
                time::sleep(time::Duration::from_nanos(1));
                rt::yield_now();
                {
                    let mut g = mm.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
            }
            w.done();
        };
    }
    if !wg.wait_timeout(time::Duration::from_secs(120)) {
        return 9;
    }
    let lg = m.get().lock();
    let locked = *lg.get();
    lg.free();
    loop {
        switch rxs.try_recv() {
            Some(_) => {},
            None => {
                break;
            },
        };
    }
    txs.free();
    rxs.free();
    ch.free();
    wg.free();
    sem.free();
    m.free();
    rt::shutdown();
    return (locked - 1000) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// Interior mutability is gated: casting an immutable `&T` to `*mut T` is a hard error (it launders the
// shared-borrow guarantee), so mutation through a shared reference must go through `UnsafeCell`, whose
// contents are stored non-`const` and mutated soundly -- exercised here by an `UnsafeCell<i32>` in an
// IMMUTABLE binding whose value is still changed through `get()`.
@test
fn interior_mutability_via_unsafe_cell() {
    let bad = cli::proj_new();
    bad.mkfile(
        "main.spc",
        "fn main() i32 {\n    let x: i32 = 5;\n    let q = (&x) as *mut i32;\n    return unsafe {\n        q[0];\n    };\n}\n",
    );
    let rb = bad.compile("main.spc");
    assert(rb.exit != 0, "casting an immutable &T to *mut T is rejected");
    assert(rb.out_has("immutable reference"), "the diagnostic names the laundering");

    let ok = cli::proj_new();
    ok.mkfile(
        "main.spc",
        "fn main() i32 {\n    let cell = UnsafeCell::<i32>::new(7);\n    unsafe {\n        cell.get()[0] = 42;\n    }\n    return unsafe {\n        cell.get()[0];\n    } - 42;\n}\n",
    );
    let ro = ok.compile("main.spc");
    assert_eq(ro.exit, 0);
    let cc = ok.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(ok.run_bin(), 0);
}

// Blocking sync primitives (std/parallel/sync, backed by pthread through the auto-discovered pthread_ext.c
// shim): a shared Arc<Mutex<i64>> counter with RAII guards, a WaitGroup barrier for completion, and an
// RwLock -- all leak-checked. Exercises the cross-module include scan (Arc's atomic/Global deps pulled into
// the sync TU) and the C-shim backing-.c discovery.
@test
fn sync_primitives() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import std::parallel::thread as thread;
import std::parallel::arc as arc;
import std::parallel::sync as sync;

fn main() i32 {
    let counter = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(4);
    let mut hs = Vector::<thread::JoinHandle<i32>>::new();
    for _t in 0..4 {
        let c = counter.clone();
        let w = wg.clone();
        hs.push(thread::spawn(fn() i32 {
            for _i in 0..2000 {
                let mut g = c.get().lock();
                let v = g.get_mut();
                *v = *v + 1;
            }
            w.done();
            return 0;
        }));
    }
    wg.wait();
    while hs.len() > 0 {
        let _ = hs.pop().unwrap().join();
    }
    hs.free();
    let rw = sync::RwLock::<i64>::new(0);
    {
        let mut wr = rw.write();
        let v = wr.get_mut();
        *v = 7;
    }
    let mut r: i64 = 0;
    {
        let rd = rw.read();
        r = *rd.get();
    }
    rw.free();
    let mut total: i64 = 0;
    {
        let g = counter.get().lock();
        total = *g.get();
    }
    counter.free();
    return (total - 8000) as i32 + (r - 7) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    let run = p.run_bin_env("SC_LEAK_CHECK=fatal ");
    assert_eq(run.exit, 0);
}

// A trivial app should not dump the whole std prelude tree (Vector/Map/String not written).
@test
fn prelude_output_is_demand_driven() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(42); }\n");
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(!p.gen_exists("__std/vector.c"), "trivial output should not emit unused std vector.c");
    assert(!p.gen_exists("__std/map.c"), "trivial output should not emit unused std map.c");
    assert(!p.gen_exists("__std/string.c"), "trivial output should not emit unused std string.c");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);
}

// Cross-module re-homed generic instances must discover by-value nested generic fields before emission:
// Outer<Bar> contains Inner<Bar> by value; both must be re-homed and emitted in dependency order.
@test
fn cross_module_nested_rehomed_instance() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/lib.spc",
        r#"pub struct Inner<T> { pub value: T }
pub struct Outer<T> { pub inner: Inner<T> }
extend<T> Outer<T> { pub fn get(self: &Self) T { return self.inner.value; } }
"#,
    );
    p.mkfile(
        "main.spc",
        r#"import lib::lib;
extern "C" { fn exit(code: i32) void; }
struct Bar { pub x: i32 }
fn main() i32 {
  let o = lib::lib::Outer::<Bar> { inner: lib::lib::Inner::<Bar> { value: Bar { x: 42 } } };
  unsafe exit(o.get().x);
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);
}

// A pub interface in one module, implemented over a local type and consumed by a bounded generic in another:
// the bound resolves across the import, the extend satisfies it, and the bounded call dispatches.
@test
fn cross_module_interface() {
    let p = cli::proj_new();
    p.mkfile("shapes.spc", "pub interface Area { fn area(self: *mut Self) i32; }\n");
    p.mkfile(
        "main.spc",
        r#"import shapes;
extern "C" { fn exit(code: i32) void; }
struct Sq { pub s: i32 }
extend Sq as shapes::Area { fn area(self: *mut Self) i32 { return unsafe (self.s * self.s); } }
fn total<T: shapes::Area>(x: &mut T) i32 { return x.area(); }
fn main() i32 { let mut q = Sq { s: 6 }; unsafe exit(total(&mut q)); }
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 36);
}

// Cross-module trait objects: a pub interface (with a default) erased over a foreign type AND a local type
// in another module; both modules erase; the foreign default's synthesized tag exports for the user TU.
@test
fn cross_module_dyn() {
    let p = cli::proj_new();
    p.mkfile(
        "shapes.spc",
        r#"pub interface Shape {
    fn area(self: &Self) i32;
    fn tag(self: &Self) i32 { return 7; }
}
pub struct Circle { pub r: i32 }
extend Circle as Shape {
    pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; }
}
pub fn local_view(s: &dyn Shape) i32 { return s.area(); }
"#,
    );
    p.mkfile(
        "main.spc",
        r#"import shapes;
extern "C" { fn exit(code: i32) void; }
struct Sq { pub s: i32 }
extend Sq as shapes::Shape {
    pub fn area(self: &Sq) i32 { return self.s * self.s; }
    pub fn tag(self: &Sq) i32 { return 4; }
}
fn total(a: &dyn shapes::Shape, b: &dyn shapes::Shape) i32 { return a.area() + b.area(); }
fn main() i32 {
    let c = shapes::Circle { r: 1 };
    let q = Sq { s: 2 };
    let d: &dyn shapes::Shape = &c;
    let t = total(&c, &q);
    let u = shapes::local_view(&q);
    let w = d.tag() + q.tag();
    unsafe exit(t + u + w + d.area());
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 25);
}

// The bundled ffi/ bindings, imported by a C header's bare name (import math; -> ffi/math.spc): a raw pub
// extern binding with its real unmangled C symbol, and a thin wrapper -- compiled -Werror + linked -lm.
@test
fn ffi_bindings() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        r#"import math;
import ctype;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let s = unsafe math::sqrt(144.0) as i32;
  let mut acc = 0;
  if ctype::is_digit(53) { acc = acc + 1; }
  if ctype::is_alpha(53) { acc = acc + 10; }
  unsafe exit(s + acc);
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("-lm");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 13);
}

// Import forms + mangling: an alias import, a glob import, two modules with a same-named public function
// (module mangling keeps them distinct), and a module named like a C stdlib header (string).
@test
fn module_imports() {
    let p = cli::proj_new();
    p.mkfile("string.spc", "pub fn tag() i32 { return 10; }\n");
    p.mkfile("math.spc", "pub fn tag() i32 { return 20; }\n");
    p.mkfile("deep.spc", "pub fn dtag() i32 { return 100; }\npub struct D { pub v: i32 }\n");
    p.mkfile("facade.spc", "import deep;\n");
    p.mkfile(
        "main.spc",
        r#"import string as s;
import math as *;
import facade as *;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let d = D { v: deep::dtag() / 10 };
  unsafe exit(s::tag() + tag() + dtag() + d.v);
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 140);
}

// External C code imports: a backing header auto-discovers its same-stem .c sibling; @c.source pulls a
// differently-named impl; @c.link lands in build/__ldflags; removing the code prunes the wrappers + flags;
// a missing @c.source is a hard error.
@test
fn external_c_sources() {
    let p = cli::proj_new();
    p.mkfile("helper.h", "int helper_add(int a, int b);\n");
    p.mkfile("helper.c", "#include \"helper.h\"\nint helper_add(int a, int b) { return a + b; }\n");
    p.mkfile("extra.h", "int extra_mul(int a, int b);\n");
    p.mkfile("impl_extra.c", "#include \"extra.h\"\nint extra_mul(int a, int b) { return a * b; }\n");
    p.mkfile(
        "main.spc",
        r#"extern "C" "helper.h" {
  fn helper_add(a: i32, b: i32) i32;
}
@c.source("impl_extra.c")
@c.link("m")
extern "C" "extra.h" {
  fn extra_mul(a: i32, b: i32) i32;
}
extern "C" { fn exit(code: i32) void; }
fn main() i32 { unsafe exit(helper_add(20, 22) + extra_mul(2, 3)); }
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("__ldflags", "-lm"), "@c.link lands in build/__ldflags");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 48);

    // drop the extern blocks: the wrapper TUs and __ldflags must disappear
    p.mkfile("main.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(0); }\n");
    let r2 = p.compile("main.spc");
    assert_eq(r2.exit, 0);
    let mut prune = Cmd {};
    unsafe stdio::snprintf(
        &mut prune.b[0],
        2048,
        "test $(find '%s/build' -name '__ext*' | wc -l) -eq 0 && test ! -e '%s/build/__ldflags'".ptr() as *const char,
        p.rootp(),
        p.rootp(),
    );
    assert_eq(cli::run_shell(&prune.b[0]), 0);

    // a missing source file is a hard error
    p.mkfile(
        "main.spc",
        "@c.source(\"nope.c\")\nextern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(0); }\n",
    );
    let miss = p.compile("main.spc");
    assert(miss.exit != 0, "missing @c.source errors");
    assert(miss.out_has("cannot find C source"), "and names it");
}

// Cross-module interface DEFAULT methods: the interface (with bodied defaults) lives in its own module,
// conformances elsewhere (type's home, a local extension of an imported type, and a builtin target `i32`).
@test
fn cross_module_defaults() {
    let p = cli::proj_new();
    p.mkfile(
        "shapes.spc",
        r#"pub interface Shape {
  fn area(self: &Self) i32;
  fn double_area(self: &Self) i32 { return self.area() * 2; }
  fn describe(self: &Self) i32 { return self.double_area() + 1; }
}
"#,
    );
    p.mkfile(
        "circle.spc",
        r#"import shapes;
pub struct Circle { pub r: i32 }
extend Circle as shapes::Shape {
  pub fn area(self: &Circle) i32 { return self.r * self.r * 3; }
}
"#,
    );
    p.mkfile("point.spc", "pub struct Point { pub x: i32 }\n");
    p.mkfile(
        "main.spc",
        r#"import circle;
import shapes;
import point;
extend point::Point as shapes::Shape {
  pub fn area(self: &point::Point) i32 { return self.x; }
}
extend i32 as shapes::Shape {
  pub fn area(self: &i32) i32 { return *self; }
}
fn dyn_describe(sh: &dyn shapes::Shape) i32 { return sh.describe(); }
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let c = circle::Circle { r: 2 };
  let p = point::Point { x: 5 };
  let n: i32 = 4;
  unsafe exit(c.describe() + dyn_describe(&c) + p.describe() + n.describe());
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 70);
}

// Format conformances across the prelude, built multi-file: String/Vector/Option/Result render to a String.
// A value type conforming to a prelude interface must NOT pull the interface module's header (no cycle).
@test
fn format_conformances() {
    let p = cli::proj_new();
    p.mkfile(
        "fmt.spc",
        r#"fn main() i32 {
  let mut v = Vector::<String>::new();
  v.push(String::from_str("a")); v.push(String::from_str("b"));
  let vs = v.fmt();
  let o = Option::<String>::Some(String::from_str("x"));
  let os = o.fmt();
  let r = Result::<String, String>::Ok(String::from_str("y"));
  let rs = r.fmt();
  return vs.len() as i32 + os.len() as i32 + rs.len() as i32;
}
"#,
    );
    let r = p.compile("fmt.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 18);
}

// Mutually-recursive modules: import cycles are legal; mutual fn calls and mutual POINTER-linked types work;
// a mutual BY-VALUE embedding is the one impossible shape (infinite size) and gets its own diagnostic.
@test
fn module_cycles() {
    let p = cli::proj_new();
    p.mkfile(
        "a.spc",
        r#"import b;
pub struct AN { pub v: i32, pub link: *mut b::BN }
pub fn even(n: i32) i32 { if n == 0 { return 1; } return b::odd(n - 1); }
"#,
    );
    p.mkfile(
        "b.spc",
        r#"import a;
pub struct BN { pub v: i32, pub link: *mut a::AN }
pub fn odd(n: i32) i32 { if n == 0 { return 0; } return a::even(n - 1); }
"#,
    );
    p.mkfile(
        "main.spc",
        r#"import a;
import b;
extern "C" { fn exit(code: i32) void; }
fn main() i32 {
  let mut an = a::AN { v: 30, link: null };
  let mut bn = b::BN { v: 2, link: (&mut an) as *mut a::AN };
  let linked = unsafe (*bn.link).v + bn.v;
  unsafe exit(linked + a::even(10) * 10);
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 42);

    // a mutual by-value embedding is infinite size
    let bad = cli::proj_new();
    bad.mkfile("main.spc", "import a;\nfn main() i32 { return 0; }\n");
    bad.mkfile("a.spc", "import b;\npub struct A { pub x: b::B }\n");
    bad.mkfile("b.spc", "import a;\npub struct B { pub y: a::A }\n");
    bad.expect_fail("main.spc", "infinite size");
}

// Module-layer negative paths: missing modules and using a non-public type/const/field across modules.
@test
fn module_errors() {
    let miss = cli::proj_new();
    miss.mkfile("main.spc", "import nope::nope;\nfn main() i32 { return 0; }\n");
    miss.expect_fail("main.spc", "cannot open module");

    let privty = cli::proj_new();
    privty.mkfile(
        "main.spc",
        "import lib::lib;\nfn use_it(p: lib::lib::Secret) i32 { return 0; }\nfn main() i32 { return 0; }\n",
    );
    privty.mkfile("lib/lib.spc", "enum Secret { A, B }\npub fn ok() i32 { return 1; }\n");
    privty.expect_fail("main.spc", "no public type");

    let privc = cli::proj_new();
    privc.mkfile("main.spc", "import lib::lib;\nfn main() i32 { return lib::lib::K; }\n");
    privc.mkfile("lib/lib.spc", "const K: i32 = 9;\n");
    privc.expect_fail("main.spc", "no public");

    let privf = cli::proj_new();
    privf.mkfile("main.spc", "import lib::lib;\nfn main() i32 { let p = lib::lib::mk(); return p.x; }\n");
    privf.mkfile("lib/lib.spc", "pub struct P { x: i32 }\npub fn mk() P { return P { x: 5 }; }\n");
    privf.expect_fail("main.spc", "is private");
}

// An extensionless input still produces build/<stem>.c.
@test
fn extensionless_appends() {
    let p = cli::proj_new();
    p.mkfile("noext", "fn main() i32 { }\n");
    let mut _r = p.compile("noext"); // result held for RAII only
    assert(p.gen_exists("noext.c"), "an extensionless input still produces build/<stem>.c");
}

// A missing input file is a nonzero exit and the path is named.
@test
fn missing_file() {
    let p = cli::proj_new();
    let r = p.compile("does_not_exist.spc");
    assert(r.exit != 0, "a missing input file is a nonzero exit");
    assert(r.out_has("does_not_exist.spc"), "the error names the path");
}

// argc > 2 exits 1 with usage.
@test
fn usage() {
    let p = cli::proj_new();
    let r = p.run_raw("a b");
    assert_eq(r.exit, 1);
    assert(r.out_has("USAGE:"), "usage is printed");
}

// A type error: no output file is written, the diagnostic is reported, and the exit is nonzero.
@test
fn error_exit_code() {
    let p = cli::proj_new();
    p.mkfile("bad.spc", "fn main() i32 { let x: bool = 1; }\n");
    let r = p.compile("bad.spc");
    assert(!p.gen_exists("bad.c"), "no output file is written when compilation fails");
    assert(r.out_has("mismatched types"), "the diagnostic is reported");
    assert(r.exit != 0, "CLI exits nonzero on a compile error");
}

// CTFE hardening: const-dependency cycles are diagnosed (not budget-burned), proven UB in an
// emitted expression fails the build with call-stack detail, a short-circuited RHS never
// false-positives, an unfoldable array length is a hard error, and a provable panic in a plain
// function keeps its defined runtime behavior.
@test
fn ctfe_hardening() {
    let p = cli::proj_new();
    p.mkfile("cyc.spc", r#"const A: i32 = B;
const B: i32 = A;
static_assert(A == 0);
fn main() i32 { return 0; }
"#);
    p.expect_fail("cyc.spc", "cyclic constant dependency");

    let p2 = cli::proj_new();
    p2.mkfile(
        "ub.spc",
        r#"const Z: i32 = 0;
fn scale(x: i32) i32 { return x * 2 / Z; }
fn main() i32 { return scale(4); }
"#,
    );
    p2.expect_fail("ub.spc", "undefined behavior");

    let p3 = cli::proj_new();
    p3.mkfile("sc.spc", r#"const Z: i32 = 0;
fn main() i32 { if Z != 0 && 10 / Z > 1 { return 1; } return 0; }
"#);
    let r3 = p3.compile("sc.spc");
    assert_eq(r3.exit, 0);
    let cc3 = p3.cc_build("");
    assert_eq(cc3.exit, 0);
    assert_eq(p3.run_bin(), 0);

    let p4 = cli::proj_new();
    p4.mkfile("len.spc", r#"fn main() i32 { let n = 4; let a: [i32; n] = [1, 2, 3, 4]; return a[0] - 1; }
"#);
    p4.expect_fail("len.spc", "array length must be a constant expression");

    // a provable panic in a NON-const fn stays runtime behavior (build ok, binary aborts)
    let p5 = cli::proj_new();
    p5.mkfile("pan.spc", r#"fn boom() i32 { panic("boom"); }
fn main() i32 { return boom(); }
"#);
    let r5 = p5.compile("pan.spc");
    assert_eq(r5.exit, 0);
    let cc5 = p5.cc_build("");
    assert_eq(cc5.exit, 0);
    assert(p5.run_bin() != 0, "the panic still aborts at runtime");
}

// const fn: definition-site validation (direct and transitive disqualifiers), the hard use-site
// guarantee (any failed fold of a const fn call is an error; the same body without `const` falls
// back to runtime), and legal recursion between const fns.
@test
fn const_fn_semantics() {
    let p = cli::proj_new();
    p.mkfile(
        "bad.spc",
        r#"import stdlib;
const fn bad() i32 { return unsafe stdlib::rand(); }
fn main() i32 { return 0; }
"#,
    );
    p.expect_fail("bad.spc", "declared 'const fn' but calls an extern function");

    let p2 = cli::proj_new();
    p2.mkfile(
        "trans.spc",
        r#"import stdlib;
fn helper() i32 { return unsafe stdlib::rand(); }
const fn outer() i32 { return helper(); }
fn main() i32 { return 0; }
"#,
    );
    p2.expect_fail("trans.spc", "calls a function that cannot be evaluated at compile time");

    let p3 = cli::proj_new();
    p3.mkfile(
        "budget.spc",
        r#"const fn spin(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s = s + i; i = i + 1; }
    return s;
}
fn main() i32 { let x = spin(100000000u64); if x == 0 { return 1; } return 0; }
"#,
    );
    p3.expect_fail("budget.spc", "'const fn' call has compile-time-known arguments but failed to evaluate");

    // identical body without `const`: silent fallback to a runtime call
    let p4 = cli::proj_new();
    p4.mkfile(
        "runtime.spc",
        r#"fn spin(n: u64) u64 {
    let mut s: u64 = 0;
    let mut i: u64 = 0;
    while i < n { s = s + i; i = i + 1; }
    return s;
}
fn main() i32 { let x = spin(1000u64); if x != 499500u64 { return 1; } return 0; }
"#,
    );
    let r4 = p4.compile("runtime.spc");
    assert_eq(r4.exit, 0);
    let cc4 = p4.cc_build("");
    assert_eq(cc4.exit, 0);
    assert_eq(p4.run_bin(), 0);

    // mutually recursive const fns are legal; const fn also runs as a normal function at runtime
    let p5 = cli::proj_new();
    p5.mkfile(
        "rec.spc",
        r#"const fn is_even(n: u32) bool { if n == 0 { return true; } return is_odd(n - 1); }
const fn is_odd(n: u32) bool { if n == 0 { return false; } return is_even(n - 1); }
static_assert(is_even(10));
fn main(argv: Vector<str>) i32 { if is_even(argv.len() as u32 * 2) { return 0; } return 1; }
"#,
    );
    let r5 = p5.compile("rec.spc");
    assert_eq(r5.exit, 0);
    let cc5 = p5.cc_build("");
    assert_eq(cc5.exit, 0);
    assert_eq(p5.run_bin(), 0);
}

// Mandatory evaluation of call-bearing const initializers: a non-evaluable initializer is a hard
// error (even when the failure is silent, via the flush pass), a trapping one carries the trap,
// and cross-module const-fn initializers work.
@test
fn mandatory_consts() {
    let p = cli::proj_new();
    p.mkfile(
        "silent.spc",
        r#"import stdlib;
fn noisy() i32 { return unsafe stdlib::rand(); }
const X: i32 = noisy() + 1;
fn main() i32 { return X * 0; }
"#,
    );
    p.expect_fail("silent.spc", "constant cannot be evaluated at compile time");

    let p2 = cli::proj_new();
    p2.mkfile(
        "trap.spc",
        r#"fn div(a: i32, b: i32) i32 { return a / b; }
const D: i32 = div(1, 0);
fn main() i32 { return D; }
"#,
    );
    p2.expect_fail("trap.spc", "division by zero");

    let p3 = cli::proj_new();
    p3.mkfile("lib/cf.spc", "pub const fn triple(x: i32) i32 { return x * 3; }\n");
    p3.mkfile(
        "use.spc",
        r#"import lib::cf;
const T: i32 = lib::cf::triple(9);
static_assert(T == 27);
fn main() i32 { return T - 27; }
"#,
    );
    let r3 = p3.compile("use.spc");
    assert_eq(r3.exit, 0);
    let cc3 = p3.cc_build("");
    assert_eq(cc3.exit, 0);
    assert_eq(p3.run_bin(), 0);

    // a const pointing at freed compile-time memory is rejected
    let p4 = cli::proj_new();
    p4.mkfile(
        "dang.spc",
        r#"import stdlib;
pub struct Holder { pub p: *mut i32 }
fn mk() Holder {
    let q = unsafe stdlib::malloc(4) as *mut i32;
    unsafe stdlib::free(q as *mut void);
    return Holder { p: q };
}
const H: Holder = mk();
fn main() i32 { return 0; }
"#,
    );
    p4.expect_fail("dang.spc", "freed compile-time memory");
}

// Aggregate materialization: compile-time-computed structs, Vectors, strings, shared pointers, and
// cyclic heap graphs land as deterministic static C data (with relocations) and behave at runtime.
@test
fn materialized_consts() {
    let p = cli::proj_new();
    p.mkfile(
        "mat.spc",
        r#"import stdlib;
pub struct Pt { pub x: i32, pub y: i32 }
pub struct Node { pub v: i32, pub next: *mut Node }
pub struct Pair { pub a: *mut Node, pub b: *mut Node }
fn mid(a: Pt, b: Pt) Pt { return Pt { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; }
fn evens(n: u32) Vector<u32> {
    let mut v = Vector::<u32>::new();
    for i in 0..n { v.push(i * 2); }
    return v;
}
fn evens_arr() Array<u32, 5> {
    let src = evens(5);
    let mut a = Array::<u32, 5>::new();
    for i in 0..a.len() { a.set(i, *src.at(i)); }
    return a;
}
fn greet() str<'static> { return "hello"; }
fn ring() Pair {
    let a = unsafe stdlib::malloc(sizeof(Node)) as *mut Node;
    let b = unsafe stdlib::malloc(sizeof(Node)) as *mut Node;
    unsafe {
        *a = Node { v: 1, next: b };
        *b = Node { v: 2, next: a };
    }
    return Pair { a: a, b: b };
}
const M: Pt = mid(Pt { x: 2, y: 10 }, Pt { x: 6, y: 30 });
const V: Array<u32, 5> = evens_arr();
const S: str = greet();
const P: Pair = ring();
fn main() i32 {
    if M.x != 4 || M.y != 20 { return 1; }
    if V.len() != 5 || *V.at(4) != 8u32 { return 2; }
    if S.len() != 5 { return 3; }
    unsafe {
        if (*(*P.a).next).v != 2 { return 4; }
        if (*(*P.b).next).v != 1 { return 5; }
    }
    let lv = evens(3); // a LOCAL owning value is fine: real scope exit, real ownership
    if lv.len() != 3 { return 6; }
    return 0;
}
"#,
    );
    let r = p.compile("mat.spc");
    assert_eq(r.exit, 0);
    assert(p.gen_has("mat.c", "__ct0"), "auxiliary statics are emitted");
    assert(p.gen_has("mat.c", ".next = (void *)"), "pointer relocations are emitted");
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);

    // an owning (Free) type is unrepresentable as a global const: its data would be static,
    // but any by-value copy would free()/mutate it
    let p2 = cli::proj_new();
    p2.mkfile(
        "own.spc",
        r#"fn evens(n: u32) Vector<u32> {
    let mut v = Vector::<u32>::new();
    for i in 0..n { v.push(i * 2); }
    return v;
}
const V: Vector<u32> = evens(5);
fn main() i32 { return 0; }
"#,
    );
    p2.expect_fail("own.spc", "a constant cannot hold an owning (Free) type");
}

// Differential: a const fn produces the same value at compile time (const initializer) and at
// runtime (plain call), for arithmetic- and branch-heavy bodies.
@test
fn ctfe_differential() {
    let p = cli::proj_new();
    p.mkfile(
        "diff.spc",
        r#"const fn mix(n: u32) u64 {
    let mut h: u64 = 1469598103934665603u64;
    let mut i: u32 = 0;
    while i < n {
        h = (h ^ i as u64) * 1099511628211u64;
        if (h & 1u64) == 0u64 { h = h >> 1; } else { h = h * 3u64 + 1u64; }
        i = i + 1;
    }
    return h;
}
const CT: u64 = mix(500);
fn main(argv: Vector<str>) i32 {
    let rt = mix(499 + argv.len() as u32);
    if rt == CT { return 0; }
    return 1;
}
"#,
    );
    let r = p.compile("diff.spc");
    assert_eq(r.exit, 0);
    let cc = p.cc_build("");
    assert_eq(cc.exit, 0);
    assert_eq(p.run_bin(), 0);
}
