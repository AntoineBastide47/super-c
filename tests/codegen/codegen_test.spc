// Codegen coverage driven in-process through tests::harness: the C shapes that are a contract (plain
// single-file names, pointer spellings, attributes, includes, exports) by substring, everything else by
// the behavior of a built program.
import tests::harness as h;

const BROAD: str = "struct Point { pub x: i32, }\nextend Point { fn get(self: &Point) i32 { return self.x; } }\n@noinline\nfn add(a: i32, b: i32) i32 { return a + b; }\nfn main() i32 {\n  let p: Point = Point { x: 1, };\n  let y: i32 = p.get();\n  let z: i32 = add(1, 2);\n  if (true) { let w: i32 = 0; }\n  while (false) { }\n  return y + z;\n}\n";

const CONTROL: str = "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\nfn sum(xs: [i32; 3]) i32 {\n  let mut total: i32 = 0;\n  for x in xs { total = total + x; }\n  return total;\n}\n";

const RANGES: str = "fn f() i32 {\n  let mut s: i32 = 0;\n  for i in 0..10 { s = s + i; }\n  for i in 1..=5 { s = s + i; }\n  for i in ..4 { s = s + 1; }\n  for i in 100.. { if i >= 103 { break; } s = s + i; }\n  while s < 0 { s = s + 1; }\n  return s;\n}\nfn main() i32 { return f() - 367; }\n";

const SWITCH_RANGES: str = "fn classify(n: i32) i32 {\n  return switch n {\n    10..20 => 1,\n    20..=30 => 2,\n    ..5 => 3,\n    99.. => 4,\n    _ => 0,\n  };\n}\n";

const REFS: str = "struct P { pub x: i32, }\nfn reads(r: &P) i32 { return r.x; }\nfn writes(w: &mut P) { w.x = 1; }\nfn raw_c(pc: *const i32) i32 { return unsafe *pc; }\nfn raw_m(pm: *mut i32) { unsafe *pm = 1; }\n";

const EXTERN: str = "extern \"C\" {\n  fn putchar(c: i32) i32;\n}\nfn main() i32 { let r: i32 = unsafe putchar(72); return r - 72; }\n";

const STR: str = "fn f(s: str) usize { return s.len(); }\nfn main() i32 { let g: str = \"hi\"; return f(g) as i32; }\n";

// The streaming backend reconstructs structured C (if/else, native switch, while) from Core IR and
// forwards return slots, instead of the raw block/goto CFG. These assertions pin the readable shape.
const STRUCT: str = "@noinline\nfn f(n: i32) i32 { if n > 0 { return 1; } return 0; }\n@noinline\nfn g(n: i32) i32 { let mut s: i32 = 0; let mut i: i32 = 0; while i < n { s = s + i; i = i + 1; } return s; }\nfn main() i32 { return f(1) + g(3) - 4; }\n";

// These pin the structured SHAPES the backend produces, plus behavior. (The whole-program goto
// reduction is measured separately.)
@test
fn structured_backend() {
    let mut b = h::ExitBatch::new();
    h::expect_c("branches emit structured if", STRUCT, "if (");
    h::expect_c("loops emit a structured while", STRUCT, "while (i < n)");
    h::expect_c("an early return forwards its value", STRUCT, "return 1LL;");
    b.add("structured straight-line + branch + loop behave", STRUCT, 0);

    // sugar_fmt_str: one call, then a direct forwarded return of the owning value.
    let SUGAR: str = "struct S { pub n: i32 }\nextend S { fn bump(self: &mut S, v: i32) { self.n = self.n + v; } }\nfn sugar(s: S, v: i32) S { let mut r = s; r.bump(v); return r; }\nfn main() i32 { let a = sugar(S { n: 1 }, 2); return a.n - 3; }\n";
    h::expect_c("the owning parameter is coalesced and returned directly", SUGAR, "return s;");
    b.add("owning-value forwarding behaves", SUGAR, 0);

    // A discriminant match lowers to a native C switch, not a goto chain.
    let ENUM: str = "enum C { Red, Green, Blue }\n@noinline\nfn f(c: C) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\nfn main() i32 { return f(C::Green) - 2; }\n";
    h::expect_c("discriminant match is a native switch", ENUM, "switch (");
    h::expect_c("switch case on the tag", ENUM, "case 1:");
    b.add("native switch behaves", ENUM, 0);

    // An early return inside a loop stays fully structured (a while plus an inner if).
    let EARLY: str = "@noinline\nfn e(n: i32) i32 { let mut i: i32 = 0; while i < n { if i == 5 { return i; } i = i + 1; } return -1; }\nfn main() i32 { return e(10) - 5; }\n";
    h::expect_c("early-return-in-loop is structured", EARLY, "while (i < n)");
    b.add("early-return-in-loop behaves", EARLY, 0);

    // A root module's items keep their bare C names (a module prefixes its own), so the collision
    // programs build alone.
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

    // A user item cannot spell a generated symbol (`id__i32_1` beside the instance `id__i32`): the
    // name is reserved, so no item collides with an instance.
    let GCOLLIDE2: str = "fn id<T>(x: T) T { return x; }\nfn id__i32_1(x: i32) i32 { return x + 1; }\nfn collide(id__i32: i32) i32 { return id::<i32>(7) + id__i32_1(id__i32); }\nfn main() i32 { return collide(1) - 9; }\n";
    h::expect_err_msg("an item named like an instance symbol", GCOLLIDE2, "the name 'id__i32_1' is reserved");

    // A never-read local is a dead store: dropping it must preserve behavior. (The structural check
    // that neither declaration nor assignment is emitted: is in cemit_test on an isolated
    // function, since the whole program includes the -Wunused pragma text.)
    let DEADL: str = "fn dead() i32 { let unused: i32 = 9; return 0; }\nfn main() i32 { return dead(); }\n";
    b.add("dropping the dead store preserves behavior", DEADL, 0);

    // A labeled multi-level break is not simple: the body uses the goto layout as its fallback, and
    // still runs correctly.
    let IRRED: str = "@noinline\nfn f(n: i32) i32 { let mut s: i32 = 0; 'outer: for i in 0..n { for j in 0..n { if i + j == 3 { break 'outer; } s = s + 1; } } return s; }\nfn main() i32 { return f(3) - 5; }\n";
    h::expect_c("labeled multi-level control uses the goto fallback", IRRED, "goto ");
    b.add("the goto-fallback body still behaves", IRRED, 0);
    b.run();
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

fn switch_ranges(b: &mut h::ExitBatch) {
    // Each arm takes exactly its range: both ends of the exclusive and inclusive arms, the open ends.
    let mut run = String::from_str(SWITCH_RANGES);
    run.push_str(
        "fn main() i32 {\n  let ins = classify(10) == 1 && classify(19) == 1 && classify(20) == 2 && classify(30) == 2 && classify(4) == 3 && classify(99) == 4;\n  let outs = classify(9) == 0 && classify(31) == 0 && classify(5) == 0 && classify(98) == 0;\n  return if ins && outs { 0; } else { 1; };\n}\n",
    );
    b.add("every arm covers its range and nothing else", run.as_str(), 0);
}

fn pointer_arith(b: &mut h::ExitBatch) {
    // A pointer offset and a pointer difference count elements, not bytes.
    b.add(
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

// A function that copies an array parameter on entry reads the caller's array through a plain pointer, so no
// `&mut` or `[]mut` parameter of it is `restrict` (a write through one to those bytes would be undefined).
@test
fn array_parameter_clears_restrict() {
    let src = "fn f(a: [u8; 4], r: &mut u8, v: []mut u8) u8 { *r = a[0]; v[0] = a[1]; return a[2]; }\nfn g(r: &mut u8, v: []mut u8) u8 { *r = 1; v[0] = 2; return *r; }\n";
    h::expect_c(
        "a function with no array parameter keeps restrict",
        src,
        "g__r(uint8_t *restrict r, uint8_t *restrict ",
    );
    h::expect_c(
        "an array parameter clears restrict on a &mut parameter and a split view",
        src,
        "f__r(uint8_t const __sc_ap1[4], uint8_t *r, uint8_t *__sc_sp3, size_t __sc_sn3)",
    );
}

@test
fn externs() {
    h::expect_c_absent("extern prototype suppressed", EXTERN, "(putchar)(");
    h::expect_c("extern call site", EXTERN, "putchar(72");

    h::expect_c(
        "extern system header include",
        "extern \"C\" \"pthread.h\" { @layout(sizeof(usize), sizeof(usize)) type pthread_t; fn pthread_self() pthread_t; }\nfn main() i32 { let t: pthread_t = unsafe pthread_self(); return 0; }\n",
        "#include <pthread.h>",
    );
    h::expect_c(
        "extern local header include",
        "extern \"C\" \"./lib.h\" { fn answer() i32; }\nfn main() i32 { return unsafe answer(); }\n",
        "#include \"./lib.h\"",
    );

    // A constant argument of a C function has the parameter's C type: an `i32` is an `int` literal,
    // never the `long long` one that would pass `abs` a wider argument (clang's -Wabsolute-value).
    let ab = h::compile_c(
        "extern \"C\" { @unsafe(safe) fn abs(x: i32) i32; @unsafe(safe) fn labs(x: i64) i64; }\nfn main() i32 { return abs(-3) + labs(-4) as i32 - 7; }\n",
    );
    assert(ab.ok(), "a C call with constant arguments compiles");
    assert(ab.code_has("abs(-3)"), "an i32 constant is an int literal");
    assert(ab.code_has("labs(-4LL)"), "an i64 constant keeps its suffix");

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
        "@noinline\nfn id(z: c64) c64 { return z; }\nfn main() i32 { let _ = id(3.0); return 0; }\n",
        "double _Complex",
    );
    h::expect_c(
        "c32 renders to float _Complex",
        "@noinline\nfn id(w: c32) c32 { return w; }\nfn main() i32 { let _ = id(1.0); return 0; }\n",
        "float _Complex",
    );
}

fn str(b: &mut h::ExitBatch) {
    b.add("a str literal, a str parameter and len()", STR, 2);
}

fn alias_extend(b: &mut h::ExitBatch) {
    // Methods on an alias of a builtin: an associated constructor, a `Self` receiver, a chained call.
    b.add(
        "alias methods",
        "pub type Token = u64;\nextend Token {\n  pub fn new(v: u32) Token { return v as u64; }\n  pub fn start(self: Self) u32 { return self as u32; }\n  pub fn next(self: Self) Token { return Token::new(self.start() + 1); }\n}\nfn main() i32 { let t = Token::new(3); let u = t.next(); return u.start() as i32 - 4; }\n",
        0,
    );
}

// Matches on enum values whose variant the compiler sees: an immutable `let` of a variant, a variant
// scrutinee (with a guard), an inlined callee's argument, a destructuring `let`, and a struct field,
// tuple member or payload of a value it saw built.
const KNOWN_VARIANT: str = "enum S { Dot, Circle(i32), Rect { w: i32, h: i32 }, }\nstruct P { pub s: S, }\nfn area(s: S) i32 { return switch s { Dot => 0, Circle(r) => r, Rect { w: w, h: h } => w * h, }; }\nfn f() i32 {\n  let s = S::Circle(3);\n  let a = switch s { Dot => 0, Circle(r) => r, Rect { w: w, h: h } => w * h, };\n  let b = switch S::Circle(4) { Rect { w: w, h: h } if w > 1 => w * h, Circle(r) => r, _ => 0, };\n  let p = P { s: S::Circle(6) };\n  let c = switch p.s { Rect { w: w, h: h } => w * h, _ => 7, };\n  let t = (S::Dot, S::Circle(8));\n  let d = switch t.1 { Circle(r) => r, _ => 0, };\n  let o = Option::<S>::Some(S::Circle(9));\n  let e = switch o { Some(x) => switch x { Circle(r) => r, _ => 0, }, None => 0, };\n  let g = switch o { Some(Circle(r)) => r, _ => 0, };\n  let (u, v) = (S::Dot, S::Circle(10));\n  let k = switch v { Circle(r) => r, _ => 0, } + switch u { Dot => 1, _ => 0, };\n  return a + b + c + d + e + g + k + area(S::Circle(5));\n}\nfn main() i32 { return f() - 56; }\n";

// Values whose variant a write through `&mut` changes before the match (a call, an inlined call, a
// reference, a field, a payload binding, a `let mut` pattern, a loop): each match takes the arm of
// the value it reads, not of the variant the value was built with.
const KNOWN_REWRITE: str = "enum S { Dot, Circle(i32), Rect { w: i32, h: i32 }, }\nstruct P { pub s: S, }\nfn area(s: S) i32 { return switch s { Dot => 1, Circle(r) => r, Rect { w: w, h: h } => w * h, }; }\nfn flip(s: &mut S) { *s = S::Rect { w: 2, h: 3 }; }\n@noinline\nfn flip_call(s: &mut S) { *s = S::Dot; }\nfn main() i32 {\n  let mut a = S::Circle(1);\n  flip(&mut a);\n  let ka = switch a { Circle(r) => r, Rect { w: w, h: h } => w * h, Dot => 0, };\n  let mut b = S::Circle(1);\n  flip_call(&mut b);\n  let kb = switch b { Circle(r) => r, Dot => 10, _ => 0, };\n  let mut c = S::Circle(1);\n  let r = &mut c;\n  *r = S::Rect { w: 4, h: 5 };\n  let kc = area(c);\n  let mut p = P { s: S::Circle(1) };\n  flip(&mut p.s);\n  let kp = switch p.s { Circle(r) => r, Rect { w: w, h: h } => w + h, Dot => 0, };\n  let mut q = P { s: S::Circle(1) };\n  let qs = &mut q.s;\n  *qs = S::Dot;\n  let kq = switch q.s { Circle(r) => r, Dot => 7, _ => 0, };\n  let mut o = Option::<S>::Some(S::Circle(1));\n  switch &mut o { Some(x) => { *x = S::Rect { w: 1, h: 9 }; }, None => {}, };\n  let ko = switch o { Some(Circle(r)) => r, Some(Rect { w: w, h: h }) => w * h, _ => 0, };\n  let mut (m, n) = (S::Circle(1), 2);\n  flip(&mut m);\n  let km = switch m { Circle(r) => r, _ => 11, } + n;\n  let mut t = S::Circle(1);\n  let mut kt = 0;\n  for i in 0..3 {\n    kt += switch t { Circle(r) => r, Dot => 100, Rect { w: w, h: h } => w * h * 1000, };\n    if i == 0 { t = S::Dot; } else { flip(&mut t); }\n  }\n  let ok = ka == 6 && kb == 10 && kc == 20 && kp == 5 && kq == 7 && ko == 9 && km == 13 && kt == 6101;\n  return if ok { 0; } else { 1; };\n}\n";

fn enums(b: &mut h::ExitBatch) {
    b.add("each known variant takes its arm", KNOWN_VARIANT, 0);
    b.add("a value rewritten through &mut takes its new arm", KNOWN_REWRITE, 0);
    b.add(
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

fn multi_return(b: &mut h::ExitBatch) {
    // A multi-value return destructures in order, called and inlined.
    b.add(
        "multi-return",
        "@noinline\nfn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\nfn di(a: i32, b: i32) (i32, i32) { return a * b, a / b; }\nfn main() i32 {\n  let (x, y) = dm(3, 1);\n  let (p, q) = di(6, 2);\n  return if x == 4 && y == 2 && p == 12 && q == 3 { 0; } else { 1; };\n}\n",
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

// A match on a value whose variant the compiler sees takes that arm alone: the other arms would read
// payload bytes the value never set, which GCC 16 reports as maybe uninitialized under -Wall.
@test
fn known_variant_takes_its_arm() {
    let c = h::compile_c_user(KNOWN_VARIANT);
    assert(c.ok(), "the program compiles");
    let body = h::c_fn(unsafe str::from_cstr(c.code), "int32_t f(");
    assert(!body.contains("payload.Rect"), "no dead arm reads the other variant's payload");
    assert(!body.contains("switch (") && !body.contains("if ("), "no test of a known tag is left");
    assert(!body.contains("int32_t w"), "the dead guarded arm's bindings declare nothing");
}

fn slices_and_arrays(b: &mut h::ExitBatch) {
    // A slice parameter reads and writes through its view, an array parameter keeps its extent, and an
    // array argument coerces to a view of its whole length.
    b.add(
        "slices and arrays",
        "fn first(s: []i32) i32 { return s[0]; }\nfn set0(s: []mut i32) { s[0] = 7; }\nfn g(a: [i32; 3]) i32 { return a[2]; }\nfn len(s: []i32) usize { return s.len(); }\nfn main() i32 {\n  let mut a: [i32; 3] = [4, 5, 6];\n  set0(a);\n  return if first(a) == 7 && g(a) == 6 && len(a) == 3 { 0; } else { 1; };\n}\n",
        0,
    );
}

fn errors(b: &mut h::ExitBatch) {
    // A defer runs at scope exit, after the body; a designated initializer fills its slots in order.
    b.add(
        "defer and designated initializers",
        "static mut G: i32 = 0;\nfn cleanup() { unsafe G = unsafe G * 10 + 2; }\nfn run() { defer cleanup(); unsafe G = unsafe G * 10 + 1; }\nfn m(k: i32) i32 { let t: [i32; 4] = [[2] = 9, k]; return t[2] * 10 + t[3]; }\nfn main() i32 {\n  run();\n  return if unsafe G == 12 && m(5) == 95 { 0; } else { 1; };\n}\n",
        0,
    );
    b.add(
        "local const reads fold or materialize",
        "extern \"C\" { fn exit(c: i32) void; }\nfn m() i32 { const T: [i32; 2] = [1, 2]; return T[0]; }\nfn main() i32 { return m() - 1; }\n",
        0,
    );
    b.add(
        "do/while runs the body first",
        "extern \"C\" { fn exit(c: i32) void; }\nfn m() i32 { let mut i: i32 = 0; do { i = i + 1; } while i < 3; return i; }\nfn main() i32 { return m() - 3; }\n",
        0,
    );
}

// `@align(expr)` emits the same C as the integer literal it evaluates to: the whole emitted tree
// of the two programs is byte-identical.
@test
fn align_constant_expression_matches_literal() {
    let lit = h::compile_c(
        "const N: u32 = 32;\n@align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32 + sizeof(L) as i32 - 64; }\n",
    );
    let ex = h::compile_c(
        "const N: u32 = 32;\n@align(N * 2)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32 + sizeof(L) as i32 - 64; }\n",
    );
    assert(lit.ok() && ex.ok(), "both forms compile");
    assert(lit.code_has("__attribute__((aligned(64)))"), "the literal form aligns");
    assert(unsafe str::from_cstr(lit.code) == unsafe str::from_cstr(ex.code), "the expression form emits the same C");
}

// `@align(N)` on a `static mut` aligns its C object: the definition and the `extern` declaration
// spell `_Alignas(N)` in every definition path (an array literal, a repeat and a struct through the
// static graph, a scalar, an empty struct); a value at most the type's own alignment spells nothing,
// as C rejects a weaker specifier.
@test
fn aligned_statics() {
    let src = M"(struct P { pub a: i32, pub b: f32 }
const W: u32 = 128;
@align(64)
static mut A: [f32; 16] = [0.0; 16];
@align(32)
static mut B: [i32; 3] = [1, 2, 3];
@align(W)
static mut S: P = P { a: 1, b: 2.0 };
@align(256)
static mut X: u8 = 7;
@align(2)
static mut Y: u64 = 9;
@align(64)
static mut Z: P = P {};
fn main() i32 {
    unsafe {
        A[1] = 1.0;
        B[0] = 4;
        S.a = 3;
        Y = 2;
        let bad = (&A as *const [f32; 16] as usize) % 64 + (&B as *const [i32; 3] as usize) % 32 + (&S as *const P as usize) % 128 + (&X as *const u8 as usize) % 256 + (&Z as *const P as usize) % 64;
        return bad as i32 + (Y as i32 - 2) + (X as i32 - 7);
    }
}
)";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("_Alignas(64) float A[16] = {"), "a repeat");
    assert(c.code_has("extern _Alignas(64) float A[16];"), "the declaration");
    assert(c.code_has("_Alignas(32) int32_t B[3] = {"), "an array literal");
    assert(c.code_has("_Alignas(128) P S = {"), "a struct, its alignment a constant expression");
    assert(c.code_has("_Alignas(256) uint8_t X = 7;"), "a scalar");
    assert(c.code_has("_Alignas(64) P Z = {0};"), "an empty struct");
    assert(!c.code_has("_Alignas(2)"), "a weaker alignment spells nothing");
    h::expect_exit("aligned statics", src, 0);
}

// An all-zero member or element of a static is left out of its initializer, which C zero-fills: a nested
// `{0}` for an aggregate whose first member is an aggregate is an error under gcc's -Wmissing-braces. The
// element after a left-out one names its index.
const ZERO_MEMBERS: str = M"(struct In { pub arr: [i32; 2], pub n: i32 }
struct Out { pub i: In, pub r: i32 }
union U { pub i: In, pub r: i32 }
static mut G: Out = Out { i: In { arr: [0, 0], n: 0 }, r: 1 };
static mut H: [In; 3] = [In { arr: [0, 0], n: 0 }, In { arr: [0, 0], n: 2 }, In { arr: [0, 0], n: 3 }];
static mut Z: U = U { i: In { arr: [0, 0], n: 0 } };
fn main() i32 {
    return unsafe (G.r + H[0].n + H[1].n + H[2].n + G.i.n + G.i.arr[1] + Z.i.n) - 6;
}
)";

@test
fn static_initializers_leave_out_zero_members() {
    let c = h::compile_c(ZERO_MEMBERS);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("Out G = { .r = 1 };"), "an all-zero field");
    assert(c.code_has("In H[3] = { [1] = { .n = 2 }, { .n = 3 } };"), "an all-zero element");
    assert(c.code_has("U Z = {0};"), "an all-zero union");
}

@test
fn attributes() {
    h::expect_c("noreturn", "@noreturn\n@used\nfn die() {}\nfn main() i32 { return 0; }\n", "_Noreturn void die(");
    h::expect_c(
        "always_inline",
        "@always_inline\nfn a(x: i32) i32 { return x; }\nfn main() i32 { let f: fn(i32) i32 = a; return f(0); }\n",
        "inline __attribute__((always_inline))",
    );
    h::expect_c(
        "section + used",
        "@platform(macos | ios)\n@unsafe(link_section = \"__TEXT,__hot\")\n@used\nfn a() i32 { return 0; }\n@platform(windows | linux | android)\n@unsafe(link_section = \".hot\")\n@used\nfn a() i32 { return 0; }\nfn main() i32 { return a(); }\n",
        "__attribute__((used, section(\"",
    );
    h::expect_c(
        "packed struct",
        "@packed\nstruct H { pub x: u32 }\nfn main() i32 { let h = H { x: 1 }; return h.x as i32; }\n",
        "struct __attribute__((packed)) H",
    );
    h::expect_c(
        "aligned struct",
        "@align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32; }\n",
        "__attribute__((aligned(64)))",
    );

    let EX: str = "extern \"C\" { fn putchar(c: i32) i32; }\n@export(\"sc_init\")\nfn init() i32 { unsafe putchar(0); return 0; }\nfn main() i32 { return init(); }\n";
    h::expect_c("export defines the exact symbol", EX, "int32_t (sc_init)(void)");
    h::expect_c("export rewrites the call site", EX, "return sc_init()");
    h::expect_c_absent("export elides the Super-C name", EX, " init(");

    h::expect_c(
        "import binds to the C symbol",
        "extern \"C\" { @import(\"puts\") fn line(s: *const char) i32; }\nfn main() i32 { unsafe line(\"x\"); return 0; }\n",
        "puts(",
    );
}

fn generics(b: &mut h::ExitBatch) {
    // Two instances of one generic, a transitive chain whose leaf only the chain reaches, and a generic
    // enum used at two types: each instance exists once and behaves.
    b.add(
        "generic instances",
        "fn id<T>(x: T) T { return x; }\nfn h<T>(x: T) T { return x; }\nfn g<T>(x: T) T { return h(x); }\nfn f<T>(x: T) T { return g(x); }\nenum Opt<T> { Some(T), None }\nfn main() i32 {\n  let a: i32 = id::<i32>(5);\n  let b: bool = id::<bool>(true);\n  let o: Opt<i32> = Opt::<i32>::Some(1);\n  let n: Opt<bool> = Opt::<bool>::None;\n  let s = switch o { Some(v) => v, None => 0, } + switch n { Some(_) => 1, None => 0, };\n  return if a == 5 && b && f(41) == 41 && s == 1 { 0; } else { 1; };\n}\n",
        0,
    );
}

fn literals(b: &mut h::ExitBatch) {
    b.add(
        "binary literals, digit separators, C-keyword identifiers",
        "fn main() i32 {\n  let a: i32 = 0b101;\n  let b: i32 = 1_000;\n  let register: i32 = 1;\n  return if a == 5 && b == 1000 && register == 1 { 0; } else { 1; };\n}\n",
        0,
    );
}

fn const_generics(b: &mut h::ExitBatch) {
    // Two instances of a const-generic type: each array has its own extent and each method sees its own N.
    let mut run = String::from_str(
        "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\n",
    );
    run.push_str(
        "fn main() i32 {\n  let a = Buff::<i32, 4> { b: [1, 2, 3, 4] };\n  let c = Buff::<u8, 2> { b: [1u8, 2u8] };\n  return if a.cap() == 4 && c.cap() == 2 && sizeof(Buff<i32, 4>) == 16 && sizeof(Buff<u8, 2>) == 2 && unsafe a.b[3] == 4 { 0; } else { 1; };\n}\n",
    );
    b.add("const generics", run.as_str(), 0);
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

// Prelude `likely`/`unlikely`: they return their condition (also in a constant), and the branch that
// tests one carries the hint to the C compiler (std/core.spc).
const HINTS: str<'static> = "@noinline\nfn pick(n: i32) i32 { if unlikely(n < 0) { return -1; } if likely(n < 100) { return 1; } return 2; }\nfn main() i32 { if pick(-5) != -1 || pick(7) != 1 || pick(500) != 2 { return 1; } const F: bool = likely(true); if !F { return 1; } return 0; }\n";

fn branch_hints(b: &mut h::ExitBatch) {
    b.add("branch hints keep value semantics", HINTS, 0);
}

@test
fn branch_hints_reach_the_branch() {
    let c = h::compile_c(HINTS);
    assert(c.ok(), "the hinted program compiles");
    assert(c.code_has("if (__builtin_expect((n < 0LL), 0))"), "unlikely tests its branch as usually false");
    assert(c.code_has("if (__builtin_expect((n < 100LL), 1))"), "likely tests its branch as usually true");
}

// An integer match lowers to a native C `switch` (each value of a range piece one case label), so the
// C compiler builds a jump table; the behavior is checked against `if` chains over every value.
const BYTE_SWITCH: str = M"(fn sw_byte(c: u8) i32 {
    return switch c {
        b'M' => 4,
        b'0'..=b'9' => 1,
        b'a'..=b'z' | b'A'..=b'Z' | b'_' => 2,
        b' ' | b'\t' | b'\n' => 3,
        0x80..=0xFF => 5,
        _ => 0,
    };
}
fn rf_byte(c: u8) i32 {
    if c == b'M' {
        return 4;
    }
    if c >= b'0' && c <= b'9' {
        return 1;
    }
    if c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' {
        return 2;
    }
    if c == b' ' || c == b'\t' || c == b'\n' {
        return 3;
    }
    if c >= 0x80 {
        return 5;
    }
    return 0;
}
fn main() i32 {
    for i in 0..256 {
        if sw_byte(i as u8) != rf_byte(i as u8) {
            return 1;
        }
    }
    return 0;
}
)";

@test
fn integer_switch_is_native() {
    h::expect_c("an integer match is a native switch", BYTE_SWITCH, "switch (c)");
    h::expect_c("a range piece lists each value", BYTE_SWITCH, "case 48: case 49:");
}

fn int_switches(b: &mut h::ExitBatch) {
    b.add("a byte switch takes the arm of every value", BYTE_SWITCH, 0);
    // Complete coverage with no catch-all (the widest piece is the default edge) and negative cases.
    b.add(
        "a signed switch covering its type takes the arm of every value",
        M"(fn sw_i8(x: i8) i32 {
    return switch x { -128 => 1, -5..=-1 => 2, 0 => 3, 1..=126 => 4, 127 => 5, -127..=-6 => 6 };
}
fn rf_i8(x: i8) i32 {
    if x == -128 {
        return 1;
    }
    if x >= -5 && x <= -1 {
        return 2;
    }
    if x == 0 {
        return 3;
    }
    if x >= 1 && x <= 126 {
        return 4;
    }
    if x == 127 {
        return 5;
    }
    return 6;
}
fn main() i32 {
    for i in -128..128 {
        if sw_i8(i as i8) != rf_i8(i as i8) {
            return 1;
        }
    }
    return 0;
}
)",
        0,
    );
    // A piece too wide to list keeps its comparison beside the switch; cases past i32::MAX of a u32.
    b.add(
        "wide pieces and high unsigned cases take their arms",
        M"(fn sw_u16(x: u16) i32 {
    return switch x { 0..=999 => 1, 1000 => 2, 1001..=1010 => 3, 60000..=65535 => 4, _ => 0 };
}
fn rf_u16(x: u16) i32 {
    if x <= 999 {
        return 1;
    }
    if x == 1000 {
        return 2;
    }
    if x >= 1001 && x <= 1010 {
        return 3;
    }
    if x >= 60000 {
        return 4;
    }
    return 0;
}
fn sw_u32(x: u32) i32 {
    return switch x { 0xFFFFFFFF => 1, 0x80000000 => 2, 7 => 3, _ => 0 };
}
fn main() i32 {
    for i in 0..65536 {
        if sw_u16(i as u16) != rf_u16(i as u16) {
            return 1;
        }
    }
    let ok = sw_u32(0xFFFFFFFF) == 1 && sw_u32(0x80000000) == 2 && sw_u32(7) == 3 && sw_u32(0x7FFFFFFF) == 0 && sw_u32(8) == 0;
    return if ok { 0; } else { 1; };
}
)",
        0,
    );
    // A switch inside a loop: an arm's `break` leaves the loop and `continue` takes the next round;
    // enum arms that share one body.
    b.add(
        "a switch in a loop breaks and continues the loop",
        M"(enum K { A, B, C, D }
fn count(s: str) i32 {
    let mut n: i32 = 0;
    let mut i: usize = 0;
    while i < s.len() {
        let c = s.byte_at(i);
        i += 1;
        switch c {
            b' ' => {
                continue;
            },
            b'.' => {
                break;
            },
            b'0'..=b'9' => {
                n += 10;
            },
            _ => {
                n += 1;
            },
        };
        n += 100;
    }
    return n;
}
fn kind(k: K) i32 {
    let mut t: i32 = 0;
    for _ in 0..3 {
        switch k {
            A | C => {
                t += 1;
            },
            B => {
                break;
            },
            D => {
                t += 5;
            },
        };
    }
    return t;
}
fn main() i32 {
    let ok = count("a 1b2. zz") == 422 && kind(K::A) == 3 && kind(K::C) == 3 && kind(K::B) == 0 && kind(K::D) == 15;
    return if ok { 0; } else { 1; };
}
)",
        0,
    );
}

// A `const` of a scalar, an array of scalars or a `str` is a read-only C object (its definition and
// every declaration say `const`); a constant of a struct, which may hold an `UnsafeCell`, stays
// writable C data.
const RO_CONSTS: str = M"(const K: u8 = 3;
const T: [u16; 3] = [1, 2, 3];
const S: str = "hi";
struct P { pub x: i32 }
const Q: P = P { x: 4 };
static mut M: i32 = 5;
fn main() i32 {
    unsafe M += 1;
    return K as i32 + T[2] as i32 + S.len() as i32 + Q.x + unsafe M - 18;
}
)";

@test
fn read_only_constants() {
    h::expect_c("a scalar constant is const", RO_CONSTS, "const uint8_t K = 3;");
    h::expect_c("an array constant is const", RO_CONSTS, "const uint16_t T[3]");
    h::expect_c("a str constant is const", RO_CONSTS, "const str S");
    h::expect_c_absent("a struct constant stays writable", RO_CONSTS, "const P Q");
    h::expect_c_absent("a static mut stays writable", RO_CONSTS, "const int32_t M");
    h::expect_exit("read-only constants read their values", RO_CONSTS, 0);
}

// A bounds check the compiler proves leaves no store of its condition: the folded jump keeps the
// condition only for the IR re-proof, and no C reads it.
const PROVEN_INDEX: str = M"(fn sum(s: str) u32 {
    let mut t: u32 = 0;
    let mut i: usize = 0;
    while i < s.len() {
        t += s.byte_at(i) as u32;
        i += 1;
    }
    return t;
}
fn main() i32 {
    return sum("ab") as i32 - 195;
}
)";

@test
fn a_proven_bounds_check_stores_no_condition() {
    h::expect_c_absent("no dead condition store", PROVEN_INDEX, "(i >= s.len)");
    h::expect_exit("the loop reads every byte", PROVEN_INDEX, 0);
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`):
// a group builds once where each case built alone.
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    switch_ranges(&mut b);
    pointer_arith(&mut b);
    str(&mut b);
    alias_extend(&mut b);
    enums(&mut b);
    multi_return(&mut b);
    slices_and_arrays(&mut b);
    errors(&mut b);
    generics(&mut b);
    literals(&mut b);
    const_generics(&mut b);
    branch_hints(&mut b);
    int_switches(&mut b);
    b.run();
}

// A local reached only through borrows (each indexing borrows it) declares at its initializer: a
// separate declaration and assignment of a returned struct whose address escapes costs C a temporary
// and a copy, a whole extra frame of the struct in a recursion.
@test
fn borrowed_local_declares_at_its_initializer() {
    h::expect_c(
        "an indexed array wrapper",
        "fn f(n: u64) u64 {\n    let mut pad = Array::<u64, 8>::new();\n    pad[7] = n;\n    return pad[7] + n;\n}\nfn main() i32 { return f(1) as i32 - 2; }\n",
        "Array__u64__8 pad = ",
    );
}
