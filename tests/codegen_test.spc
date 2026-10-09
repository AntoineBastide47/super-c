// Codegen coverage driven in-process through tests::harness: the C shapes that are a contract (plain
// single-file names, pointer spellings, attributes, includes, exports) by substring, everything else by
// the behavior of a built program.
import tests::harness as h;

const BROAD: str = "struct Point { pub x: i32, }\nextend Point { fn get(self: &Point) i32 { return self.x; } }\nfn add(a: i32, b: i32) i32 { return a + b; }\nfn main() i32 {\n  let p: Point = Point { x: 1, };\n  let y: i32 = p.get();\n  let z: i32 = add(1, 2);\n  if (true) { let w: i32 = 0; }\n  while (false) { }\n  let q: *i32 = new i32;\n}\n";

const CONTROL: str = "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\nfn sum(xs: [i32; 3]) i32 {\n  let mut total: i32 = 0;\n  for x in xs { total = total + x; }\n  return total;\n}\n";

const RANGES: str = "fn f() i32 {\n  let mut s: i32 = 0;\n  for i in 0..10 { s = s + i; }\n  for i in 1..=5 { s = s + i; }\n  for i in ..4 { s = s + 1; }\n  for i in 100.. { if i >= 103 { break; } s = s + i; }\n  while s < 0 { s = s + 1; }\n  return s;\n}\nfn main() i32 { return f() - 367; }\n";

const SWITCH_RANGES: str = "fn classify(n: i32) i32 {\n  return switch n {\n    10..20 => 1,\n    20..=30 => 2,\n    ..5 => 3,\n    99.. => 4,\n    _ => 0,\n  };\n}\n";

const REFS: str = "struct P { pub x: i32, }\nfn reads(r: &P) i32 { return r.x; }\nfn writes(w: &mut P) { w.x = 1; }\nfn raw_c(pc: *const i32) i32 { return unsafe *pc; }\nfn raw_m(pm: *mut i32) { unsafe *pm = 1; }\n";

const EXTERN: str = "extern \"C\" {\n  fn putchar(c: i32) i32;\n}\nfn main() i32 { let r: i32 = unsafe putchar(72); }\n";

const STR: str = "fn f(s: str) usize { return s.len(); }\nfn main() i32 { let g: str = \"hi\"; return f(g) as i32; }\n";

// The streaming backend reconstructs structured C (if/else, native switch, while) from Core IR and
// forwards return slots, instead of the raw block/goto CFG. These assertions pin the readable shape.
const STRUCT: str = "fn f(n: i32) i32 { if n > 0 { return 1; } return 0; }\nfn g(n: i32) i32 { let mut s: i32 = 0; let mut i: i32 = 0; while i < n { s = s + i; i = i + 1; } return s; }\nfn main() i32 { return f(1) + g(3) - 4; }\n";

// These pin the structured SHAPES the backend produces, plus behavior. (The whole-program goto
// reduction is measured separately.)
@test
fn structured_backend() {
    h::expect_c("branches emit structured if", STRUCT, "if (");
    h::expect_c("loops emit a structured while", STRUCT, "while (i < n)");
    h::expect_c("an early return forwards its value", STRUCT, "return 1LL;");
    h::expect_exit("structured straight-line + branch + loop behave", STRUCT, 0);

    // sugar_fmt_str: one call, then a direct forwarded return of the owning value.
    let SUGAR: str = "struct S { pub n: i32 }\nextend S { fn bump(self: &mut S, v: i32) { self.n = self.n + v; } }\nfn sugar(s: S, v: i32) S { let mut r = s; r.bump(v); return r; }\nfn main() i32 { let a = sugar(S { n: 1 }, 2); return a.n - 3; }\n";
    h::expect_c("the owning parameter is coalesced and returned directly", SUGAR, "return s;");
    h::expect_exit("owning-value forwarding behaves", SUGAR, 0);

    // A discriminant match lowers to a native C switch, not a goto chain.
    let ENUM: str = "enum C { Red, Green, Blue }\nfn f(c: C) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\nfn main() i32 { return f(C::Green) - 2; }\n";
    h::expect_c("discriminant match is a native switch", ENUM, "switch (");
    h::expect_c("switch case on the tag", ENUM, "case 1:");
    h::expect_exit("native switch behaves", ENUM, 0);

    // An early return inside a loop stays fully structured (a while plus an inner if).
    let EARLY: str = "fn e(n: i32) i32 { let mut i: i32 = 0; while i < n { if i == 5 { return i; } i = i + 1; } return -1; }\nfn main() i32 { return e(10) - 5; }\n";
    h::expect_c("early-return-in-loop is structured", EARLY, "while (i < n)");
    h::expect_exit("early-return-in-loop behaves", EARLY, 0);

    // A parameter named after a type in scope must not hide the typedef: the whole TU stays legal
    // C and behaves (the emitter disambiguates the variable name).
    let COLLIDE: str = "struct Node { pub v: i32 }\nfn take(Node: i32, n: Node) i32 { return Node + n.v; }\nfn main() i32 { return take(2, Node { v: 3 }) - 5; }\n";
    h::expect_exit("a variable named after a type stays legal C", COLLIDE, 0);

    // A parameter named after an enum constant the body constructs must not hide it: the emitted
    // `return C::Red` still reads the constant, not the parameter.
    let ECOLLIDE: str = "enum C { Red, Green }\nfn pick(C_Red: i32) C { return C::Red; }\nfn main() i32 { return pick(1) as i32; }\n";
    h::expect_exit("a variable named after an enum constant stays correct", ECOLLIDE, 0);

    // A parameter named after the MANGLED symbol of a generic call (`id__i32`) must not hide it.
    let GCOLLIDE: str = "fn id<T>(x: T) T { return x; }\nfn collide(id__i32: i32) i32 { return id::<i32>(7) + id__i32; }\nfn main() i32 { return collide(1) - 8; }\n";
    h::expect_exit("a variable named after a mangled call symbol stays correct", GCOLLIDE, 0);

    // Both the name AND its `_1` suffix are reserved (a generic call plus a real `id__i32_1`): the
    // parameter must fall all the way back to `_N`, hiding neither symbol.
    let GCOLLIDE2: str = "fn id<T>(x: T) T { return x; }\nfn id__i32_1(x: i32) i32 { return x + 1; }\nfn collide(id__i32: i32) i32 { return id::<i32>(7) + id__i32_1(id__i32); }\nfn main() i32 { return collide(1) - 9; }\n";
    h::expect_exit("a doubly-colliding variable falls back to a temp name", GCOLLIDE2, 0);

    // A never-read local is a dead store: dropping it must preserve behavior. (The structural check
    // that neither declaration nor assignment is emitted: is in cemit_test on an isolated
    // function, since the whole program includes the -Wunused pragma text.)
    let DEADL: str = "fn dead() i32 { let unused: i32 = 9; return 0; }\nfn main() i32 { return dead(); }\n";
    h::expect_exit("dropping the dead store preserves behavior", DEADL, 0);

    // A labeled multi-level break is not simple: the body uses the goto layout as its fallback, and
    // still runs correctly.
    let IRRED: str = "fn f(n: i32) i32 { let mut s: i32 = 0; 'outer: for i in 0..n { for j in 0..n { if i + j == 3 { break 'outer; } s = s + 1; } } return s; }\nfn main() i32 { return f(3) - 5; }\n";
    h::expect_c("labeled multi-level control uses the goto fallback", IRRED, "goto ");
    h::expect_exit("the goto-fallback body still behaves", IRRED, 0);
}

@test
fn broad() {
    // A single-file program keeps plain C names for its functions and types.
    h::expect_c("function", BROAD, "int32_t add(");
    h::expect_c("struct decl", BROAD, "struct Point");
    h::expect_c("struct field", BROAD, "int32_t x;");
    h::expect_exit(
        "a method call, an associated constructor and a struct literal behave",
        "struct Point { pub x: i32, }\nextend Point { fn get(self: &Point) i32 { return self.x; } fn new(x: i32) Point { return Point { x: x }; } }\nfn add(a: i32, b: i32) i32 { return a + b; }\nfn main() i32 {\n  let p = Point { x: 1 };\n  let q = Point::new(5);\n  return p.get() + q.get() + add(1, 2) - 9;\n}\n",
        0,
    );
}

@test
fn control() {
    h::expect_c("a for over an array lowers to a counted C for", CONTROL, "for (size_t ");
    h::expect_c("switch lowered to if", CONTROL, "if (");
    h::expect_c("switch literal test", CONTROL, " == ");
    let mut run = String::from_str(CONTROL);
    run.push_str("fn main() i32 { return classify(0) * 100 + classify(7) * 10 + sum([1, 2, 3]) - 126; }\n");
    h::expect_exit("the switch picks its arm and the for sums every element", run.as_str(), 0);
}

@test
fn ranges() {
    // Range loops lower to head/body/step blocks; the arithmetic is the observable contract.
    h::expect_c("exclusive bound test", RANGES, "< 10LL");
    h::expect_c("inclusive bound test", RANGES, "<= 5LL");
    h::expect_c("open-start counts from zero", RANGES, "< 4LL");
    h::expect_c("bare if lowers", RANGES, ">= 103LL");
    h::expect_c("bare while lowers", RANGES, "< 0LL");
    h::expect_exit("every range form iterates its extent", RANGES, 0);
}

@test
fn switch_ranges() {
    // Each arm takes exactly its range: both ends of the exclusive and inclusive arms, the open ends.
    let mut run = String::from_str(SWITCH_RANGES);
    run.push_str(
        "fn main() i32 {\n  let ins = classify(10) == 1 && classify(19) == 1 && classify(20) == 2 && classify(30) == 2 && classify(4) == 3 && classify(99) == 4;\n  let outs = classify(9) == 0 && classify(31) == 0 && classify(5) == 0 && classify(98) == 0;\n  return if ins && outs { 0; } else { 1; };\n}\n",
    );
    h::expect_exit("every arm covers its range and nothing else", run.as_str(), 0);
}

@test
fn pointer_arith() {
    // A pointer offset and a pointer difference count elements, not bytes.
    h::expect_exit(
        "pointer offset and difference",
        "fn main() i32 {\n  let a: [i32; 4] = [1, 2, 3, 4];\n  let p: *const i32 = &a[0];\n  let q: *const i32 = &a[3];\n  let second = unsafe *(p + 1);\n  let gap = unsafe (q - p);\n  return second + gap as i32 - 5;\n}\n",
        0,
    );
}

// An ordered raw-pointer comparison compares addresses as integers (C defines `<` only within one
// object); equality stays a pointer comparison.
@test
fn pointer_compare() {
    h::expect_c("ordered", "fn f(p: *const i32, q: *mut i32) bool { return p < q; }\n", "((uintptr_t)p < (uintptr_t)q)");
    h::expect_c(
        "negated in an assert",
        "fn f(p: *const i32, q: *const i32) { assert(p <= q, \"o\"); }\n",
        "if ((uintptr_t)p > (uintptr_t)q)",
    );
    h::expect_c("equality", "fn f(p: *const i32, q: *const i32) bool { return p == q; }\n", "(p == q)");
    h::expect_c_absent("integer order", "fn f(a: usize, b: usize) bool { return a < b; }\n", "uintptr_t");
}

// A bare `*T` is `*const T`: a shared borrow converts to it, it spells `const T *` in C, and it never
// converts to `*mut T`.
@test
fn bare_pointer_is_const() {
    h::expect_c("bare pointer spelling", "fn f(p: *i32) i32 { return unsafe *p; }\n", "const int32_t *p");
    h::expect_err_msg(
        "bare pointer to *mut",
        "fn m(p: *mut i32) {}\nfn f(p: *i32) { m(p); }\n",
        "expected '*mut i32', found '*const i32'",
    );
}

@test
fn references() {
    h::expect_c("&T is const pointee", REFS, "reads(const P *");
    h::expect_c("&mut T is mutable pointee", REFS, "writes(P *");
    h::expect_c_absent("&mut T is not const", REFS, "writes(const P");
    h::expect_c("*const T is const pointee", REFS, "raw_c(const int32_t *");
    h::expect_c("*mut T is mutable pointee", REFS, "raw_m(int32_t *");
    h::expect_c_absent("*mut T is not const", REFS, "raw_m(const int32_t");
}

@test
fn externs() {
    h::expect_c_absent("extern prototype suppressed", EXTERN, "(putchar)(");
    h::expect_c("extern call site", EXTERN, "putchar(72");

    h::expect_c(
        "extern system header include",
        "extern \"C\" \"pthread.h\" { type pthread_t; fn pthread_self() pthread_t; }\nfn main() i32 { let t: pthread_t = unsafe pthread_self(); return 0; }\n",
        "#include <pthread.h>",
    );
    h::expect_c(
        "extern local header include",
        "extern \"C\" \"./lib.h\" { fn answer() i32; }\nfn main() i32 { return unsafe answer(); }\n",
        "#include \"./lib.h\"",
    );

    // A variadic argument is read as its promoted C type: an `i32` constant is cast to `int32_t`.
    h::expect_c(
        "variadic call passes all args",
        "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { let f: char = '%'; unsafe printf(&f, 1, 2, 3); return 0; }\n",
        "(int32_t)1LL, (int32_t)2LL, (int32_t)3LL)",
    );

    h::expect_c(
        "string literal -> bare C string in fmt position",
        "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { unsafe printf(\"%s\\n\", \"hi\"); return 0; }\n",
        "(const char *)\"%s\\n\"",
    );
    h::expect_c(
        "string literal -> *const u8 adds cast",
        "extern \"C\" { fn f(s: *const u8) i32; }\nfn main() i32 { return unsafe f(\"hi\"); }\n",
        "(const uint8_t *)\"hi\"",
    );
    h::expect_c(
        "string literal stays str view by default",
        "fn main() i32 { let s: str = \"zq9\"; return s.len() as i32; }\n",
        "(str){ (const uint8_t *)\"zq9\"",
    );

    h::expect_c(
        "complex builtin renders to _Complex",
        "fn main() i32 { let z: c64 = 3.0; let w: c32 = 1.0; return 0; }\n",
        "double _Complex",
    );
    h::expect_c("c32 renders to float _Complex", "fn main() i32 { let w: c32 = 1.0; return 0; }\n", "float _Complex");
}

@test
fn str() {
    h::expect_exit("a str literal, a str parameter and len()", STR, 2);
}

@test
fn alias_extend() {
    // Methods on an alias of a builtin: an associated constructor, a `Self` receiver, a chained call.
    h::expect_exit(
        "alias methods",
        "pub type Token = u64;\nextend Token {\n  pub fn new(v: u32) Token { return v as u64; }\n  pub fn start(self: Self) u32 { return self as u32; }\n  pub fn next(self: Self) Token { return Token::new(self.start() + 1); }\n}\nfn main() i32 { let t = Token::new(3); let u = t.next(); return u.start() as i32 - 4; }\n",
        0,
    );
}

@test
fn enums() {
    h::expect_exit(
        "plain and tagged enums: construction, matching, explicit discriminants",
        "enum Color { Red, Green, Blue, }\nenum Shape { Dot, Circle(i32), }\nenum Code { Ok = 0, Bad = 404, }\nfn col(c: Color) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\nfn area(s: Shape) i32 { return switch s { Dot => 0, Circle(r) => r * r, }; }\nfn main() i32 {\n  let ok = col(Color::Green) == 2 && area(Shape::Circle(3)) == 9 && area(Shape::Dot) == 0 && Code::Bad as i32 == 404 && Code::Ok as i32 == 0;\n  return if ok { 0; } else { 1; };\n}\n",
        0,
    );
}

@test
fn if_expression() {
    let SRC: str = "fn f(n: i32) i32 { let x: i32 = if n > 0 { 1; } else { 2; }; return x; }\n";
    h::expect_c("then arm assigns the result temp", SRC, "= 1LL;");
    h::expect_c("else arm assigns the result temp", SRC, "= 2LL;");
    h::expect_c("the chain branches structurally", SRC, "if (");
    let mut run = String::from_str(SRC);
    run.push_str("fn main() i32 { return f(5) * 10 + f(-5) - 12; }\n");
    h::expect_exit("each arm gives its own value", run.as_str(), 0);
}

@test
fn array_literals() {
    // Every element of a literal; a designated literal re-made in a loop zero-fills its tail each time
    // (the 50 written into the tail must not survive into the next iteration); a repeat evaluates its
    // element once, a call included; a literal argument reaches the callee by value.
    h::expect_exit(
        "array literals",
        "static mut G: i32 = 0;\nfn tick() u8 {\n  unsafe G += 1;\n  return 3;\n}\nfn probe(n: i32) u32 {\n  let mut s: u32 = 0;\n  for i in 0..n {\n    if i == 0 {\n      continue;\n    }\n    let mut fp: [u32; 4] = [[0] = 1];\n    s += fp[3] + fp[2];\n    fp[3] = 50;\n  }\n  return s;\n}\nfn g(a: [i32; 3]) i32 { return a[0] + a[2]; }\nfn rep(k: u8) u8 { let a = [k * 3; 4]; return a[0] + a[3]; }\nfn main() i32 {\n  let a: [i32; 3] = [1, 2, 3];\n  let t = [tick(); 4];\n  let ok = a[0] + a[1] + a[2] == 6 && probe(4) == 0 && rep(2) == 12 && t[0] + t[3] == 6 && unsafe G == 1 && g([1, 2, 3]) == 4;\n  return if ok { 0; } else { 1; };\n}\n",
        0,
    );
    // An emission property, not behavior: a repeat computes a pure element once and copies it.
    h::expect_c_absent(
        "a repeat computes its element once",
        "fn f(k: u8) u8 { let a = [k * 3; 4]; return a[3]; }\n",
        "a[1] = __sc_mul_u8",
    );
}

@test
fn multi_return() {
    // A multi-value return destructures in order, called and inlined.
    h::expect_exit(
        "multi-return",
        "@c.noinline\nfn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\nfn di(a: i32, b: i32) (i32, i32) { return a * b, a / b; }\nfn main() i32 {\n  let (x, y) = dm(3, 1);\n  let (p, q) = di(6, 2);\n  return if x == 4 && y == 2 && p == 12 && q == 3 { 0; } else { 1; };\n}\n",
        0,
    );
}

// A callee generic over a const parameter inlines with the parameter's value, and its
// per-instantiation static_assert still runs.
@test
fn const_generic_callee_inlines() {
    let FILL: str = "fn fill<const N: usize>(v: i32) [i32; N] {\n    static_assert(N > 1, \"two lanes\");\n    return [v; N];\n}\n";
    let mut ok = String::from_str(FILL);
    ok.push_str("fn f() i32 {\n    let a = fill::<4>(2);\n    return a[3];\n}\n");
    h::expect_c_absent("the call is inlined", ok.as_str(), "fill__4(2");
    let mut bad = String::from_str(FILL);
    bad.push_str("fn main() i32 {\n    let a = fill::<1>(2);\n    return a[0];\n}\n");
    let r = h::diff_build(bad.as_str(), []);
    assert(!r.built && r.diag.as_str().contains("two lanes"), "the static_assert of the inlined instance runs");
}

@test
fn slices_and_arrays() {
    // A slice parameter reads and writes through its view, an array parameter keeps its extent, and an
    // array argument coerces to a view of its whole length.
    h::expect_exit(
        "slices and arrays",
        "fn first(s: []i32) i32 { return s[0]; }\nfn set0(s: []mut i32) { s[0] = 7; }\nfn g(a: [i32; 3]) i32 { return a[2]; }\nfn len(s: []i32) usize { return s.len(); }\nfn main() i32 {\n  let mut a: [i32; 3] = [4, 5, 6];\n  set0(a);\n  return if first(a) == 7 && g(a) == 6 && len(a) == 3 { 0; } else { 1; };\n}\n",
        0,
    );
}

@test
fn errors() {
    // A defer runs at scope exit, after the body; a designated initializer fills its slots in order.
    h::expect_exit(
        "defer and designated initializers",
        "static mut G: i32 = 0;\nfn cleanup() { unsafe G = unsafe G * 10 + 2; }\nfn run() { defer cleanup(); unsafe G = unsafe G * 10 + 1; }\nfn m(k: i32) i32 { let t: [i32; 4] = [[2] = 9, k]; return t[2] * 10 + t[3]; }\nfn main() i32 {\n  run();\n  return if unsafe G == 12 && m(5) == 95 { 0; } else { 1; };\n}\n",
        0,
    );
    h::expect_exit(
        "local const reads fold or materialize",
        "extern \"C\" { fn exit(c: i32) void; }\nfn m() i32 { const T: [i32; 2] = [1, 2]; return T[0]; }\nfn main() i32 { unsafe exit(m() - 1); }\n",
        0,
    );
    h::expect_exit(
        "do/while runs the body first",
        "extern \"C\" { fn exit(c: i32) void; }\nfn m() i32 { let mut i: i32 = 0; do { i = i + 1; } while i < 3; return i; }\nfn main() i32 { unsafe exit(m() - 3); }\n",
        0,
    );
}

// `@c.align(expr)` emits the same C as the integer literal it evaluates to: the whole emitted tree
// of the two programs is byte-identical.
@test
fn align_constant_expression_matches_literal() {
    let lit = h::compile_c(
        "const N: u32 = 32;\n@c.align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32 + sizeof(L) as i32 - 64; }\n",
    );
    let ex = h::compile_c(
        "const N: u32 = 32;\n@c.align(N * 2)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32 + sizeof(L) as i32 - 64; }\n",
    );
    assert(lit.ok() && ex.ok(), "both forms compile");
    assert(lit.code_has("__attribute__((aligned(64)))"), "the literal form aligns");
    assert(str::from_cstr(lit.code) == str::from_cstr(ex.code), "the expression form emits the same C");
}

@test
fn attributes() {
    h::expect_c("noreturn", "@c.noreturn\nfn die() {}\nfn main() i32 { return 0; }\n", "_Noreturn");
    h::expect_c(
        "always_inline",
        "@c.always_inline\nfn a(x: i32) i32 { return x; }\nfn main() i32 { return a(0); }\n",
        "inline __attribute__((always_inline))",
    );
    h::expect_c(
        "section + used",
        "@c.section(\"hot\")\n@c.used\nfn a() i32 { return 0; }\nfn main() i32 { return a(); }\n",
        "__attribute__((used, section(\"hot\")))",
    );
    h::expect_c(
        "packed struct",
        "@c.packed\nstruct H { pub x: u32 }\nfn main() i32 { let h = H { x: 1 }; return h.x as i32; }\n",
        "struct __attribute__((packed)) H",
    );
    h::expect_c(
        "aligned struct",
        "@c.align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32; }\n",
        "__attribute__((aligned(64)))",
    );

    let EX: str = "extern \"C\" { fn putchar(c: i32) i32; }\n@c.export(\"sc_init\")\nfn init() i32 { unsafe putchar(0); return 0; }\nfn main() i32 { return init(); }\n";
    h::expect_c("export defines the exact symbol", EX, "int32_t sc_init(void)");
    h::expect_c("export rewrites the call site", EX, "return sc_init()");
    h::expect_c_absent("export elides the Super-C name", EX, " init(");

    h::expect_c(
        "import binds to the C symbol",
        "extern \"C\" { @c.import(\"puts\") fn line(s: *const char) i32; }\nfn main() i32 { unsafe line(\"x\"); return 0; }\n",
        "puts(",
    );
}

@test
fn generics() {
    // Two instances of one generic, a transitive chain whose leaf only the chain reaches, and a generic
    // enum used at two types: each instance exists once and behaves.
    h::expect_exit(
        "generic instances",
        "fn id<T>(x: T) T { return x; }\nfn h<T>(x: T) T { return x; }\nfn g<T>(x: T) T { return h(x); }\nfn f<T>(x: T) T { return g(x); }\nenum Opt<T> { Some(T), None }\nfn main() i32 {\n  let a: i32 = id::<i32>(5);\n  let b: bool = id::<bool>(true);\n  let o: Opt<i32> = Opt::<i32>::Some(1);\n  let n: Opt<bool> = Opt::<bool>::None;\n  let s = switch o { Some(v) => v, None => 0, } + switch n { Some(_) => 1, None => 0, };\n  return if a == 5 && b && f(41) == 41 && s == 1 { 0; } else { 1; };\n}\n",
        0,
    );
}

@test
fn literals() {
    h::expect_exit(
        "binary literals, digit separators, C-keyword identifiers",
        "fn main() i32 {\n  let a: i32 = 0b101;\n  let b: i32 = 1_000;\n  let register: i32 = 1;\n  return if a == 5 && b == 1000 && register == 1 { 0; } else { 1; };\n}\n",
        0,
    );
}

@test
fn const_generics() {
    // Two instances of a const-generic type: each array has its own extent and each method sees its own N.
    let mut run = String::from_str(
        "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\n",
    );
    run.push_str(
        "fn main() i32 {\n  let a = Buff::<i32, 4> { b: [1, 2, 3, 4] };\n  let c = Buff::<u8, 2> { b: [1u8, 2u8] };\n  return if a.cap() == 4 && c.cap() == 2 && sizeof(Buff<i32, 4>) == 16 && sizeof(Buff<u8, 2>) == 2 && unsafe a.b[3] == 4 { 0; } else { 1; };\n}\n",
    );
    h::expect_exit("const generics", run.as_str(), 0);
}

// Lifetimes are ERASED before monomorphization: they are checked, then dropped. They must never
// reach an instance's type args, the mangled symbol, or the emitted C: otherwise `Slice<'a,T>`
// and `Slice<'b,T>` would become two distinct monomorphizations of the same code.
@test
fn lifetimes_are_erased() {
    // A lifetime-only generic is NOT generic for codegen: `Ref<'a>` emits a plain `Ref`.
    let LT: str = "struct Ref<'a> { pub p: &'a i32 }\nfn borrow<'a>(x: &'a i32) &'a i32 { return x; }\nfn main() i32 { let v = 5; let r = Ref::<'static> { p: &v }; return *borrow(&v) + *r.p - 10; }\n";
    h::expect_c("lifetime-only struct emits an unmangled name", LT, "typedef struct Ref Ref;");
    h::expect_c_absent("no lifetime in the struct symbol", LT, "Ref__");
    h::expect_c_absent("no lifetime in the fn symbol", LT, "borrow__");

    // Mixed `<'a, T>`: only the TYPE arg mangles, so two lifetimes collapse to one instance.
    let MIX: str = "struct Pair<'a, T> { pub p: &'a T, pub n: T }\nfn main() i32 { let a = 3; let b = 4; let p1 = Pair::<i32> { p: &a, n: 1 }; let p2 = Pair::<i32> { p: &b, n: 2 }; return *p1.p + *p2.p - 7; }\n";
    h::expect_c("mixed lifetime+type generic mangles only the type arg", MIX, "Pair__i32");
    h::expect_c_absent("the lifetime never appears in the mangled name", MIX, "Pair__a");
}

// Prelude `likely`/`unlikely`: value-semantic identity hints, const-evaluable; the inliner removes
// the calls, so the emitted C carries no hint (std/core.spc).
@test
fn branch_hints() {
    let SRC: str = "fn pick(n: i32) i32 { if unlikely(n < 0) { return -1; } if likely(n < 100) { return 1; } return 2; }\nfn main() i32 { if pick(-5) != -1 || pick(7) != 1 || pick(500) != 2 { return 1; } const F: bool = likely(true); if !F { return 1; } return 0; }\n";
    h::expect_exit("branch hints keep value semantics", SRC, 0);
}
