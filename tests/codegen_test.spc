// Self-hosted port of tests/codegen_test.c: structural codegen coverage (emitted-C substring assertions)
// driven in-process through tests::harness (compile_c), pinned to the Core-IR streaming backend's shapes.
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

// `expect_c` scans the whole program including any prelude functions that use the goto-layout
// fallback, so it cannot assert the absence of `goto bb_`; these pin the structured SHAPES the
// backend now produces, plus behavior. (The whole-program goto reduction is measured separately.)
@test
fn structured_backend() {
    h::expect_c("branches emit structured if", STRUCT, "if (");
    h::expect_c("loops emit a structured while", STRUCT, "while (1)");
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
    h::expect_c("early-return-in-loop is structured", EARLY, "while (1)");
    h::expect_exit("early-return-in-loop behaves", EARLY, 0);

    // A parameter named after a type in scope must not hide the typedef -- the whole TU stays legal
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
    // -- that neither declaration nor assignment is emitted -- is in cemit_test on an isolated
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
    h::expect_c("function", BROAD, "int32_t add(");
    h::expect_c("struct decl", BROAD, "struct Point");
    h::expect_c("struct field", BROAD, "int32_t x;");
    h::expect_c("method proto", BROAD, "Point__get(");
    h::expect_c("method call self", BROAD, "Point__get(&p");
    h::expect_c(
        "associated new call",
        "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n",
        "String__new()",
    );
    h::expect_c("struct initializer", BROAD, "(Point){ .x = 1");
    h::expect_c("if statement", BROAD, "if (");
    h::expect_c("loops emit a structured while", BROAD, "while (1)");
    h::expect_c("new", BROAD, "malloc(sizeof(int32_t))");
}

@test
fn control() {
    h::expect_c("for lowers to a structured while", CONTROL, "while (1)");
    h::expect_c("switch lowered to if", CONTROL, "if (");
    h::expect_c("switch literal test", CONTROL, " == ");
}

@test
fn ranges() {
    // range loops lower to head/body/step blocks; the arithmetic is the observable contract
    h::expect_c("exclusive bound test", RANGES, "< 10LL");
    h::expect_c("inclusive bound test", RANGES, "<= 5LL");
    h::expect_c("open-start counts from zero", RANGES, "< 4LL");
    h::expect_c("bare if lowers", RANGES, ">= 103LL");
    h::expect_c("bare while lowers", RANGES, "< 0LL");
    h::expect_exit("every range form iterates its extent", RANGES, 0);
}

@test
fn switch_ranges() {
    h::expect_c("exclusive arm lower bound", SWITCH_RANGES, ">= 10LL");
    h::expect_c("exclusive arm upper bound", SWITCH_RANGES, "< 20LL");
    h::expect_c("inclusive arm upper bound", SWITCH_RANGES, "<= 30LL");
    h::expect_c("open-start arm is upper-only", SWITCH_RANGES, "< 5LL");
    h::expect_c_absent("open-start arm has no lower bound", SWITCH_RANGES, ">= 5LL");
    h::expect_c("open-end arm is lower-only", SWITCH_RANGES, ">= 99LL");
    h::expect_c_absent("open-end arm has no upper bound", SWITCH_RANGES, "< 99LL");
}

@test
fn pointer_arith() {
    h::expect_c("pointer offset", "fn f(p: *i32) i32 { return unsafe *(p + 1); }\n", "+ 1LL)");
    h::expect_c("pointer difference", "fn f(a: *i32, b: *i32) isize { return unsafe (a - b); }\n", "(a - b)");
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

    h::expect_c(
        "variadic call passes all args",
        "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { let f: char = '%'; unsafe printf(&f, 1, 2, 3); return 0; }\n",
        "1LL, 2LL, 3LL)",
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
    h::expect_c("str forward typedef", STR, "typedef struct str str;");
    h::expect_c("str body has the view pair", STR, "const uint8_t *ptr;");
    h::expect_c("str param", STR, "size_t f(str ");
    h::expect_c("str len() emits method call", STR, "str__len(&");
    h::expect_c("str literal", STR, "(str){ (const uint8_t *)\"hi\", sizeof(\"hi\") - 1 }");
}

// Binding constness is a language rule the CHECKER enforces; the emitted locals are plain C
// storage. What the C must preserve is reference/pointer const-ness (covered by `references`)
// and behavior.
@test
fn constness() {
    h::expect_exit(
        "mutation through a mut binding only",
        "fn f(a: i32) i32 {\n  let x: i32 = a;\n  let mut y: i32 = a;\n  y = y + 1;\n  return x + y;\n}\nfn main() i32 { return f(1) - 3; }\n",
        0,
    );
}

@test
fn binding_constness() {
    h::expect_exit(
        "owning and scalar bindings behave",
        "struct Buf { pub ptr: *mut u8, }\nfn main() i32 { let b: Buf = Buf { ptr: null, }; let mut m: Buf = Buf { ptr: null, };\n  let x: i32 = 5; let mut y: i32 = 6; y = y + 1; return x + y - 12; }\n",
        0,
    );
}

@test
fn alias_extend() {
    let A: str = "pub type Token = u64;\nextend Token {\n  pub fn new(v: u32) Token { return v as u64; }\n  pub fn start(self: Self) u32 { return self as u32; }\n  pub fn next(self: Self) Token { return Token::new(self.start() + 1); }\n}\nfn main() i32 { let t = Token::new(3); let u = t.next(); return u.start() as i32; }\n";
    h::expect_c("alias method mangles by the alias name", A, "uint64_t Token__new(");
    h::expect_c("Self receiver spells the underlying value", A, "uint32_t Token__start(uint64_t");
    h::expect_c("method call resolves to the alias symbol", A, "Token__start(");
    h::expect_c_absent("no method dissolves into the underlying builtin", A, "u64__start");
    h::expect_c_absent("no constructor dissolves into the underlying builtin", A, "u64__new");
}

@test
fn enums() {
    let PLAIN: str = "enum Color { Red, Green, Blue, }\nfn f(c: Color) i32 { return 0; }\n";
    h::expect_c("payload-less enum is a C enum", PLAIN, "Color_Red");
    h::expect_c("payload-less enum typedef", PLAIN, "} Color;");

    let TAGGED: str = "enum Shape { Dot, Circle(i32), }\nfn f(s: Shape) i32 { return 0; }\n";
    h::expect_c("tagged enum: tag type", TAGGED, "ShapeTag");
    h::expect_c("tagged enum: tag constant", TAGGED, "Shape_Circle");
    h::expect_c("tagged enum: union member", TAGGED, "union {");
    h::expect_c("tagged enum: discriminant field", TAGGED, "tag;");

    let CTOR: str = "enum E { A, B(i32), }\nfn f() E { return E::B(7); }\n";
    h::expect_c("variant construct: tag", CTOR, ".tag = E_B");
    h::expect_c("variant construct: payload", CTOR, ".payload.B = {");
    h::expect_c("plain variant value", "enum C { Red, Green, }\nfn f() C { return C::Green; }\n", "C_Green");

    let MATCH: str = "enum C { Red, Green, }\nfn f(c: C) i32 { return switch c { Red => 1, Green => 2, }; }\n";
    h::expect_c("plain enum arm tests the tag", MATCH, "C_Red");
    h::expect_c_absent("plain enum arm is not a binding", MATCH, "C Red =");

    h::expect_c(
        "explicit discriminant",
        "enum Code { Ok = 0, Bad = 404, }\nfn f(c: Code) i32 { return c as i32; }\n",
        "Code_Bad = 404",
    );
}

@test
fn if_expression() {
    let SRC: str = "fn f(n: i32) i32 { let x: i32 = if n > 0 { 1; } else { 2; }; return x; }\n";
    h::expect_c("then arm assigns the result temp", SRC, "= 1LL;");
    h::expect_c("else arm assigns the result temp", SRC, "= 2LL;");
    h::expect_c("the chain branches structurally", SRC, "if (");
}

@test
fn array_literals() {
    h::expect_c("array literal stores each element", "fn f() { let a: [i32; 3] = [1, 2, 3]; }\n", "[0] = 1LL");
    h::expect_c("array literal stores the last element", "fn f() { let a: [i32; 3] = [1, 2, 3]; }\n", "[2] = 3LL");
    h::expect_exit(
        "array literal argument reaches the callee by value",
        "extern \"C\" { fn exit(c: i32) void; }\nfn g(a: [i32; 3]) i32 { return a[0] + a[2]; }\nfn f() i32 { return g([1, 2, 3]); }\nfn main() i32 { unsafe exit(f() - 4); }\n",
        0,
    );
}

@test
fn multi_return() {
    let MR: str = "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\n";
    h::expect_c("multi-return struct typedef", MR, "dm_ret");
    h::expect_c("multi-return field", MR, "int32_t _0;");
    h::expect_c("multi-return compound literal", MR, "(dm_ret){");

    let DESTR: str = "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\nfn f() i32 { let (x, y) = dm(3, 1); return x + y; }\n";
    h::expect_c("destructure reads _0", DESTR, "._0;");
    h::expect_c("destructure reads _1", DESTR, "._1;");
}

@test
fn slices_and_arrays() {
    h::expect_c("slice param is Slice__T", "fn first(s: []i32) i32 { return s[0]; }\n", "first(Slice__i32 ");
    h::expect_c("mut slice param is SliceMut__T", "fn set0(s: []mut i32) { s[0] = 1; }\n", "set0(SliceMut__i32 ");
    h::expect_c(
        "slice index uses typed ptr, bounds-checked",
        "fn first(s: []i32) i32 { return s[0]; }\n",
        ".ptr[__sc_bounds(0, ",
    );
    h::expect_c("array param keeps extent", "fn g(a: [i32; 3]) i32 { return a[0]; }\n", "[3])");
    h::expect_c(
        "array arg coerces to slice view",
        "fn take(s: []i32) i32 { return s[0]; }\nfn m() i32 { let a: [i32; 2] = [4, 5]; return take(a); }\n",
        ".len = 2 }",
    );
}

@test
fn errors() {
    h::expect_c("defer lowers to scope-exit call", "fn cleanup() {}\nfn run() { defer cleanup(); }\n", "cleanup()");
    h::expect_c(
        "designated array init",
        "fn m(k: i32) i32 { let t: [i32; 4] = [[2] = 9, k]; return t[2]; }\n",
        "[2] = 9",
    );
    h::expect_c("static_assert lowers", "static_assert(1 == 1);\nfn m() i32 { return 0; }\n", "_Static_assert(");
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
    let ID: str = "fn id<T>(x: T) T { return x; }\nfn main() i32 { let a: i32 = id::<i32>(5); let b: bool = id::<bool>(true); return a; }\n";
    h::expect_c("generic specialization with substituted return", ID, "int32_t id__i32(");
    h::expect_c("second instantiation", ID, "id__bool(");
    h::expect_c_absent("no generic template emitted", ID, " id(");

    // Transitive same-module chain: expanding f<i32> records g<i32>, whose expansion must
    // itself run to reach h<i32> (regression: the expand worklist must re-read its bound).
    let CHAIN: str = "fn h<T>(x: T) T { return x; }\nfn g<T>(x: T) T { return h(x); }\nfn f<T>(x: T) T { return g(x); }\nfn main() i32 { return f(41); }\n";
    h::expect_c("transitive nested instantiation emits leaf", CHAIN, "int32_t h__i32(");

    let ENUM: str = "enum Opt<T> { Some(T), None }\nfn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(1); let b: Opt<bool> = Opt::<bool>::None;\n  return switch a { Some(v) => v, None => 0, } + switch b { Some(_) => 1, None => 0, }; }\n";
    h::expect_c("generic enum tag is include-guarded", ENUM, "SUPER_ENUMTAG_Opt");
    h::expect_c("generic enum tag emitted once", ENUM, "} OptTag;");
}

@test
fn literals() {
    h::expect_c("binary literal keeps its spelling", "fn f() i32 { let a: i32 = 0b101; return a; }\n", "0b101");
    h::expect_c("digit separators strip", "fn f() i32 { let a: i32 = 1_000; return a; }\n", "1000");
    h::expect_exit(
        "C-keyword identifiers stay legal",
        "extern \"C\" { fn exit(c: i32) void; }\nfn f() i32 { let register: i32 = 1; return register; }\nfn main() i32 { unsafe exit(f() - 1); }\n",
        0,
    );
}

@test
fn const_generics() {
    let CG: str = "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\nfn main() i32 { let a = Buff::<i32, 4> { b: [1, 2, 3, 4] }; let c = Buff::<u8, 2> { b: [1u8, 2u8] }; return unsafe a.b[0] + unsafe c.b[1] as i32 + a.cap() as i32 + c.cap() as i32; }\n";
    h::expect_c("const-generic instance name (i32, 4)", CG, "Buff__i32__4");
    h::expect_c("const-generic instance name (u8, 2)", CG, "Buff__u8__2");
    h::expect_c("const-generic array field sized (i32)", CG, "int32_t b[4]");
    h::expect_c("const-generic array field sized (u8)", CG, "uint8_t b[2]");
    h::expect_c_absent("const param does not leak as `N` into C", CG, "b[N]");
    h::expect_c("const param value in method body (4)", CG, "= 4ULL");
    h::expect_c("const param value in method body (2)", CG, "= 2ULL");
}

// The old backend specialized known-callee callbacks (`apply__cb_inc`); the streaming backend
// keeps the pointer-taking original for BOTH shapes -- one body, callee passed as a value.
@test
fn callback_specialization() {
    let KNOWN: str = "extern \"C\" { fn putchar(c: i32) i32; }\nfn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\nfn inc(x: i32) i32 { unsafe putchar(0); return x + 1; }\nfn use() i32 { return apply(10, inc); }\n";
    h::expect_c("the pointer-taking original emits", KNOWN, "int32_t apply(int32_t ");
    h::expect_c("the callback passes as a value", KNOWN, "= inc;");
    h::expect_c_absent("no specialization symbols", KNOWN, "__cb_");

    let RUNTIME: str = "fn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\nfn inc(x: i32) i32 { return x + 1; }\nfn use() i32 { let k: fn(i32) i32 = inc; return apply(10, k); }\n";
    h::expect_c("runtime callback keeps the pointer original", RUNTIME, "int32_t apply(int32_t ");
    h::expect_c_absent("runtime callback is not specialized", RUNTIME, "__cb_");
}

// Lifetimes are ERASED before monomorphization: they are checked, then dropped. They must never
// reach an instance's type args, the mangled symbol, or the emitted C -- otherwise `Slice<'a,T>`
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

// Prelude `likely`/`unlikely`: value-semantic identity hints; the streaming backend keeps the
// calls (const-evaluable, inlined by C), so conditions still carry them.
@test
fn branch_hints() {
    let SRC: str = "fn pick(n: i32) i32 { if unlikely(n < 0) { return -1; } if likely(n < 100) { return 1; } return 2; }\nfn main() i32 { if pick(-5) != -1 || pick(7) != 1 || pick(500) != 2 { return 1; } const F: bool = likely(true); if !F { return 1; } return 0; }\n";
    h::expect_c("unlikely threads the hint call", SRC, "unlikely(");
    h::expect_c("likely threads the hint call", SRC, "likely(");
    h::expect_exit("branch hints keep value semantics", SRC, 0);
}
